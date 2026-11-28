//! Starting and restarting the Zed that a target's bridge belongs to.
//!
//! Zed runs as a systemd --user unit (see `gateway/systemd/zed-zlink.service`); the gateway
//! only ever runs `systemctl --user start|reset-failed|is-active <that unit>` and signals the
//! process that owns the target's private bridge socket. There is no generic command endpoint.

use super::*;
use std::os::unix::fs::MetadataExt;
use tokio::process::Command;

const WATCHDOG_POLL: Duration = Duration::from_secs(10);
/// A bridge that accepts connections but does not answer for this long counts as hung.
const HUNG_AFTER: Duration = Duration::from_secs(60);
const QUIT_WAIT: Duration = Duration::from_secs(15);
const TERM_WAIT: Duration = Duration::from_secs(6);
const START_WAIT: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum BridgeState {
    Up,
    /// Socket accepts connections, but no reply in time.
    Hung,
    /// No socket or connection refused: Zed is not running.
    Down,
}

impl BridgeState {
    fn label(self) -> &'static str {
        match self {
            Self::Up => "up",
            Self::Hung => "hung",
            Self::Down => "down",
        }
    }
}

pub(super) struct BridgeCheck {
    pub(super) state: BridgeState,
    pid: Option<i32>,
    info: Option<Value>,
}

pub(super) fn valid_unit(unit: &str) -> bool {
    unit.len() <= 128
        && unit.len() > ".service".len()
        && unit.ends_with(".service")
        && !unit.starts_with('-')
        && unit
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "@._-".contains(character))
}

/// `ZEDLINK_ZED_UNIT` names the unit of the first target when the target file does not.
pub(super) fn apply_unit_from_environment(
    mut targets: Vec<ProbeTarget>,
) -> Result<Vec<ProbeTarget>> {
    if let Ok(unit) = std::env::var("ZEDLINK_ZED_UNIT")
        && !unit.is_empty()
        && let Some(first) = targets.first_mut()
        && first.zed_unit.is_none()
    {
        first.zed_unit = Some(unit);
    }
    for target in &targets {
        if let Some(unit) = &target.zed_unit
            && !valid_unit(unit)
        {
            bail!("invalid zed_unit for target {}", target.id);
        }
    }
    Ok(targets)
}

fn error_value(code: &str) -> Value {
    json!({ "code": code })
}

fn process_alive(pid: i32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

fn own_uid() -> Option<u32> {
    fs::metadata("/proc/self")
        .ok()
        .map(|metadata| metadata.uid())
}

/// Only a process of this user whose executable is Zed may be signalled.
fn is_own_zed_process(pid: i32) -> bool {
    let Ok(metadata) = fs::metadata(format!("/proc/{pid}")) else {
        return false;
    };
    let executable = fs::read_link(format!("/proc/{pid}/exe")).ok();
    Some(metadata.uid()) == own_uid()
        && executable
            .as_deref()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("zed"))
}

async fn signal(pid: i32, name: &str) -> Result<()> {
    let status = tokio::time::timeout(
        Duration::from_secs(5),
        Command::new("kill")
            .arg(format!("-{name}"))
            .arg(pid.to_string())
            .status(),
    )
    .await??;
    if !status.success() {
        bail!("kill -{name} {pid} failed");
    }
    Ok(())
}

async fn wait_for_exit(pid: i32, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if !process_alive(pid) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    !process_alive(pid)
}

pub(super) async fn systemctl(verb: &str, unit: &str) -> Result<(bool, String)> {
    let output = tokio::time::timeout(
        Duration::from_secs(30),
        Command::new("systemctl")
            .args(["--user", verb, "--", unit])
            .output(),
    )
    .await??;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    Ok((output.status.success(), text))
}

impl Gateway {
    pub(super) async fn check_bridge(&self, target: &ProbeTarget) -> BridgeCheck {
        let down = BridgeCheck {
            state: BridgeState::Down,
            pid: None,
            info: None,
        };
        if validate_probe_socket(&target.probe).is_err() {
            return down;
        }
        let stream =
            match tokio::time::timeout(Duration::from_secs(3), UnixStream::connect(&target.probe))
                .await
            {
                Err(_) => {
                    return BridgeCheck {
                        state: BridgeState::Hung,
                        ..down
                    };
                }
                Ok(Err(_)) => return down,
                Ok(Ok(stream)) => stream,
            };
        let pid = stream
            .peer_cred()
            .ok()
            .filter(|credentials| Some(credentials.uid()) == own_uid())
            .and_then(|credentials| credentials.pid());
        // Talk to the socket directly rather than through `probe`: its slot limit must not
        // make a busy gateway look like a hung Zed.
        let request = json!({
            "version": 1, "request_id": Uuid::new_v4().to_string(),
            "method": "instance.info", "params": {},
        });
        let exchange = async {
            let mut stream = stream;
            stream.write_all(request.to_string().as_bytes()).await?;
            stream.write_all(b"\n").await?;
            let mut response = Vec::new();
            BufReader::new(stream)
                .take(MAX_PROBE_RESPONSE + 1)
                .read_until(b'\n', &mut response)
                .await?;
            anyhow::Ok(response)
        };
        match tokio::time::timeout(Duration::from_secs(6), exchange).await {
            Err(_) => BridgeCheck {
                state: BridgeState::Hung,
                pid,
                info: None,
            },
            Ok(Err(_)) => BridgeCheck { pid, ..down },
            Ok(Ok(response)) => {
                let info = serde_json::from_slice::<Value>(&response)
                    .ok()
                    .and_then(|response| response.get("result").cloned());
                BridgeCheck {
                    state: if response.is_empty() {
                        BridgeState::Down
                    } else {
                        BridgeState::Up
                    },
                    pid,
                    info,
                }
            }
        }
    }

    async fn generating_threads(&self, target: &ProbeTarget) -> usize {
        let request = json!({
            "version": 1, "request_id": Uuid::new_v4().to_string(),
            "method": "thread.list", "params": {},
        });
        self.probe(Some(&target.id), &request)
            .await
            .ok()
            .and_then(|response| {
                response["result"]["threads"].as_array().map(|threads| {
                    threads
                        .iter()
                        .filter(|thread| thread["status"] == "Generating")
                        .count()
                })
            })
            .unwrap_or(0)
    }

    pub(super) fn restart_in_progress(&self, target_id: &str) -> bool {
        self.0
            .zed_restarts
            .lock()
            .is_ok_and(|restarts| restarts.contains(target_id))
    }

    /// `zed.status`, `zed.start`, `zed.restart`, `zed.update`. Errors use the bridge's `{code}` shape.
    pub(super) async fn zed_rpc(
        &self,
        method: &str,
        target_id: Option<&str>,
        params: &Value,
    ) -> (StatusCode, Result<Value, Value>) {
        let Ok(target) = self.target(target_id).cloned() else {
            return (StatusCode::NOT_FOUND, Err(error_value("UNKNOWN_TARGET")));
        };
        match method {
            "zed.status" => (StatusCode::OK, Ok(self.zed_status(&target).await)),
            "zed.update" if params["now"] == true => self.zed_update_now(),
            "zed.update" => (StatusCode::OK, Ok(self.zed_update_status())),
            "zed.start" => self.zed_start(&target).await,
            "zed.restart" => {
                let force = params["force"].as_bool().unwrap_or(false);
                self.zed_restart(&target, force).await
            }
            _ => (
                StatusCode::FORBIDDEN,
                Err(error_value("UNSUPPORTED_CAPABILITY")),
            ),
        }
    }

    async fn zed_status(&self, target: &ProbeTarget) -> Value {
        let check = self.check_bridge(target).await;
        let unit_active = match &target.zed_unit {
            Some(unit) => systemctl("is-active", unit)
                .await
                .ok()
                .map(|(_, state)| state == "active" || state == "activating"),
            None => None,
        };
        let generating = if check.state == BridgeState::Up {
            self.generating_threads(target).await
        } else {
            0
        };
        json!({
            "target_id": target.id,
            "control": target.zed_unit.is_some(),
            "unit": target.zed_unit,
            "unit_active": unit_active,
            "bridge": check.state.label(),
            "pid": check.pid,
            "instance_id": check.info.as_ref().map(|info| info["instance_id"].clone()),
            "epoch": check.info.as_ref().map(|info| info["epoch"].clone()),
            "generating": generating,
            "restarting": self.restart_in_progress(&target.id),
            "update": target.zed_unit.as_ref().map(|_| self.zed_update_status()),
        })
    }

    async fn zed_start(&self, target: &ProbeTarget) -> (StatusCode, Result<Value, Value>) {
        let Some(unit) = target.zed_unit.clone() else {
            return (
                StatusCode::FORBIDDEN,
                Err(error_value("UNSUPPORTED_CAPABILITY")),
            );
        };
        if self.restart_in_progress(&target.id) {
            return (StatusCode::CONFLICT, Err(error_value("BUSY")));
        }
        if self.check_bridge(target).await.state != BridgeState::Down {
            return (StatusCode::OK, Ok(json!({"already_running": true})));
        }
        match start_unit(&unit).await {
            Ok(()) => {
                eprintln!("zed control: started {unit} for target {}", target.id);
                (StatusCode::OK, Ok(json!({"started": true})))
            }
            Err(error) => {
                eprintln!("zed control: start {unit} failed: {error:#}");
                (StatusCode::BAD_GATEWAY, Err(error_value("START_FAILED")))
            }
        }
    }

    async fn zed_restart(
        &self,
        target: &ProbeTarget,
        force: bool,
    ) -> (StatusCode, Result<Value, Value>) {
        let Some(unit) = target.zed_unit.clone() else {
            return (
                StatusCode::FORBIDDEN,
                Err(error_value("UNSUPPORTED_CAPABILITY")),
            );
        };
        let check = self.check_bridge(target).await;
        if check.state == BridgeState::Up && !force {
            let generating = self.generating_threads(target).await;
            if generating > 0 {
                return (
                    StatusCode::CONFLICT,
                    Err(json!({"code": "TURNS_RUNNING", "generating": generating})),
                );
            }
        }
        {
            let Ok(mut restarts) = self.0.zed_restarts.lock() else {
                return (StatusCode::CONFLICT, Err(error_value("BUSY")));
            };
            if !restarts.insert(target.id.clone()) {
                return (StatusCode::CONFLICT, Err(error_value("BUSY")));
            }
        }
        let state = self.clone();
        let target = target.clone();
        tokio::spawn(async move {
            let outcome = state.restart_zed(&target, &unit, check).await;
            match &outcome {
                Ok(()) => eprintln!("zed control: restarted {unit} for target {}", target.id),
                Err(error) => eprintln!("zed control: restart {unit} failed: {error:#}"),
            }
            if let Ok(mut restarts) = state.0.zed_restarts.lock() {
                restarts.remove(&target.id);
            }
        });
        // The phone polls `zed.status` (`restarting`, then `bridge: up` with a new epoch).
        (StatusCode::OK, Ok(json!({"accepted": true})))
    }

    async fn restart_zed(
        &self,
        target: &ProbeTarget,
        unit: &str,
        check: BridgeCheck,
    ) -> Result<()> {
        self.stop_zed(target, check).await?;
        start_unit(unit).await?;
        self.wait_for_bridge(target, START_WAIT).await
    }

    pub(super) async fn wait_for_bridge(
        &self,
        target: &ProbeTarget,
        limit: Duration,
    ) -> Result<()> {
        let deadline = Instant::now() + limit;
        while Instant::now() < deadline {
            if self.check_bridge(target).await.state == BridgeState::Up {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        bail!("bridge did not come back within {}s", limit.as_secs())
    }

    /// Quits Zed through `instance.quit` when the bridge offers it, else by signals.
    pub(super) async fn stop_zed(&self, target: &ProbeTarget, check: BridgeCheck) -> Result<()> {
        if let Some(pid) = check.pid.filter(|pid| is_own_zed_process(*pid)) {
            let can_quit = check.info.as_ref().is_some_and(|info| {
                info["capabilities"].as_array().is_some_and(|capabilities| {
                    capabilities.iter().any(|item| item == "instance.quit")
                })
            });
            let mut exited = false;
            if can_quit && let Some(info) = &check.info {
                let request = json!({
                    "version": 1, "request_id": Uuid::new_v4().to_string(),
                    "method": "instance.quit",
                    "params": {"instance_id": info["instance_id"], "epoch": info["epoch"]},
                });
                if self.probe(Some(&target.id), &request).await.is_ok() {
                    exited = wait_for_exit(pid, QUIT_WAIT).await;
                }
            }
            if !exited {
                // Zed has no SIGTERM handler; this is the fallback for a hung or old bridge.
                signal(pid, "TERM").await.ok();
                exited = wait_for_exit(pid, TERM_WAIT).await;
            }
            if !exited {
                signal(pid, "KILL").await?;
                if !wait_for_exit(pid, Duration::from_secs(3)).await {
                    bail!("Zed process {pid} did not exit");
                }
            }
        } else if check.state != BridgeState::Down {
            bail!("Zed is running but its process could not be identified");
        }
        Ok(())
    }

    /// Pushes once per outage when a running Zed stops answering. A closed Zed is not an
    /// outage (the user may have quit it); the phone shows that through `zed.status`.
    pub(super) async fn zed_watchdog(&self) {
        let mut hung_since = HashMap::<String, Instant>::new();
        let mut notified = HashSet::<String>::new();
        let mut interval = tokio::time::interval(WATCHDOG_POLL);
        loop {
            interval.tick().await;
            for target in self.0.targets.clone() {
                if self.restart_in_progress(&target.id) {
                    hung_since.remove(&target.id);
                    continue;
                }
                let check = self.check_bridge(&target).await;
                if check.state != BridgeState::Hung {
                    if notified.remove(&target.id) {
                        eprintln!(
                            "zed watchdog: target {} is {}",
                            target.id,
                            check.state.label()
                        );
                    }
                    hung_since.remove(&target.id);
                    continue;
                }
                let since = *hung_since
                    .entry(target.id.clone())
                    .or_insert_with(Instant::now);
                if since.elapsed() < HUNG_AFTER || notified.contains(&target.id) {
                    continue;
                }
                eprintln!(
                    "zed watchdog: target {} has not answered for {}s",
                    target.id,
                    since.elapsed().as_secs()
                );
                notified.insert(target.id.clone());
                let body = if target.zed_unit.is_some() {
                    "Мост не отвечает больше минуты. Нажмите, чтобы перезапустить Zed."
                } else {
                    "Мост не отвечает больше минуты."
                };
                self.notify_all(&PushMessage {
                    title: "Zed не отвечает".into(),
                    subtitle: Some(target.label.clone()),
                    body: body.into(),
                    event: NotificationEvent::ZedHung,
                    target_id: target.id.clone(),
                    thread_id: String::new(),
                    instance_id: String::new(),
                    epoch: String::new(),
                    project_id: None,
                    host_id: None,
                })
                .await;
            }
        }
    }
}

pub(super) async fn start_unit(unit: &str) -> Result<()> {
    // A unit whose Zed was killed is "failed"; start would refuse it otherwise.
    systemctl("reset-failed", unit).await.ok();
    let (started, _) = systemctl("start", unit).await?;
    if !started {
        bail!("systemctl --user start {unit} failed");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_plain_service_units_are_accepted() {
        assert!(valid_unit("zed-zlink.service"));
        assert!(valid_unit("zed@main.service"));
        assert!(!valid_unit(".service"));
        assert!(!valid_unit("zed.timer"));
        assert!(!valid_unit("--user.service"));
        assert!(!valid_unit("zed;rm.service"));
        assert!(!valid_unit("../zed.service"));
        assert!(!valid_unit(&format!("{}.service", "a".repeat(130))));
    }

    #[test]
    fn hung_push_is_routed_to_the_target_not_a_thread() {
        let message = PushMessage {
            title: "Zed не отвечает".into(),
            subtitle: None,
            body: "…".into(),
            event: NotificationEvent::ZedHung,
            target_id: "desktop".into(),
            thread_id: String::new(),
            instance_id: String::new(),
            epoch: String::new(),
            project_id: None,
            host_id: None,
        };
        let payload = apns_payload(&message, "g1", 1, 2);
        assert_eq!(payload["type"], "zed_hung");
        assert_eq!(payload["aps"]["badge"], 2);
        assert_eq!(payload["aps"]["category"], "ZEDLINK_ZED");
        assert_eq!(payload["target"], "desktop");
        assert!(payload.get("thread").is_none());
        assert_eq!(apns_collapse_id(&message), "desktop:zed_hung");
    }
}
