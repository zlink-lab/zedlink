//! Installs a patched Zed release that `gateway/systemd/zed-zlink-update` has staged, at a
//! moment when no thread is working: every turn stopped, nothing waits for an approval or an
//! input, no autopilot job is about to run, and that has held for `SETTLE`.
//!
//! The updater downloads and verifies the release next to the installed app
//! (`<app parent>/.zed.app.next-<tag>`) and writes `pending.json`; it never touches a running
//! Zed. The gateway then quits Zed the way `zed.restart` does, swaps the directories (the old
//! app is kept as `.zed.app.prev`), starts the unit and waits for the bridge. A release whose
//! bridge does not come up is rolled back and marked `failed-<tag>` so it is not retried.

use super::zed_control::{BridgeState, start_unit, systemctl};
use super::*;
use std::os::unix::fs::MetadataExt;

const POLL: Duration = Duration::from_secs(30);
const SETTLE: Duration = Duration::from_secs(3 * 60);
const START_LIMIT: Duration = Duration::from_secs(90);
/// An autopilot job due this soon keeps Zed as it is.
const JOB_MARGIN_SECONDS: i64 = 5 * 60;

#[derive(Clone, Debug, Default, Serialize)]
pub(super) struct Status {
    pub(super) pending_tag: Option<String>,
    /// Why the staged release is not installed yet: `turns_running`, `waiting_approval`,
    /// `waiting_input`, `autopilot_job_due`, `zed_hung`, `bridge_busy`, `settling`,
    /// `no_zed_control`.
    pub(super) waiting: Option<&'static str>,
    pub(super) applying: bool,
    /// Skip the settle time once (`zed.update {"now": true}`).
    pub(super) now: bool,
    pub(super) last_result: Option<String>,
}

enum Plan {
    /// `zed-zlink-update` staged a release next to the app.
    Staged(Pending),
    /// The app on disk is already newer than the running Zed (dev, inode of the new binary).
    Restart { disk: (u64, u64) },
}

enum Applied {
    /// Nothing changed on disk (Zed could not be stopped).
    NotStarted(anyhow::Error),
    /// The new release was tried and the old one put back.
    RolledBack(anyhow::Error),
}

#[derive(Debug, Deserialize)]
struct Pending {
    tag: String,
    staged: PathBuf,
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn update_directory() -> Option<PathBuf> {
    std::env::var_os("ZEDLINK_ZED_UPDATE_DIR")
        .map(PathBuf::from)
        .or_else(|| home().map(|home| home.join(".local/share/zedlink/zed")))
}

fn app_directory() -> Option<PathBuf> {
    std::env::var_os("ZEDLINK_ZED_APP")
        .map(PathBuf::from)
        .or_else(|| home().map(|home| home.join(".local/zed.app")))
}

pub(super) fn valid_release_tag(tag: &str) -> bool {
    tag.strip_prefix("zed-v").is_some_and(|rest| {
        !rest.is_empty()
            && rest.len() <= 64
            && rest.chars().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '.' | '-')
            })
    })
}

/// The staged directory must be exactly where the updater puts it, so a tampered
/// `pending.json` cannot make the gateway move some other directory into place.
fn staged_path_is_expected(pending: &Pending, app: &Path) -> bool {
    valid_release_tag(&pending.tag)
        && app.parent().is_some_and(|parent| {
            pending.staged == parent.join(format!(".zed.app.next-{}", pending.tag))
        })
        && pending.staged.join("libexec/zed-editor").is_file()
}

fn read_pending(directory: &Path) -> Option<Pending> {
    let text = fs::read_to_string(directory.join("pending.json")).ok()?;
    serde_json::from_str(&text).ok()
}

pub(super) fn installed_tag() -> Option<String> {
    let app = app_directory()?;
    fs::read_to_string(app.join(".zlink-release"))
        .ok()
        .map(|text| text.trim().to_owned())
        .filter(|tag| valid_release_tag(tag))
}

fn swap_in(app: &Path, staged: &Path) -> Result<()> {
    let previous = app.with_file_name(".zed.app.prev");
    if previous.exists() {
        fs::remove_dir_all(&previous).context("remove the previous Zed backup")?;
    }
    if app.exists() {
        fs::rename(app, &previous).context("move the installed Zed aside")?;
    }
    if let Err(error) = fs::rename(staged, app) {
        if previous.exists() {
            fs::rename(&previous, app).ok();
        }
        return Err(error).context("move the staged Zed into place");
    }
    Ok(())
}

fn roll_back(app: &Path, tag: &str) -> Result<()> {
    let previous = app.with_file_name(".zed.app.prev");
    if !previous.exists() {
        bail!("no previous Zed to roll back to");
    }
    let failed = app.with_file_name(format!(".zed.app.failed-{tag}"));
    if failed.exists() {
        fs::remove_dir_all(&failed).ok();
    }
    fs::rename(app, &failed).context("move the failed Zed aside")?;
    fs::rename(&previous, app).context("restore the previous Zed")?;
    Ok(())
}

impl Gateway {
    fn set_update_status(&self, change: impl FnOnce(&mut Status)) {
        if let Ok(mut status) = self.0.zed_update.lock() {
            change(&mut status);
        }
    }

    pub(super) fn zed_update_status(&self) -> Value {
        let status = self
            .0
            .zed_update
            .lock()
            .map(|status| status.clone())
            .unwrap_or_default();
        json!({
            "installed_tag": installed_tag(),
            "pending_tag": status.pending_tag,
            "waiting": status.waiting,
            "applying": status.applying,
            "last_result": status.last_result,
        })
    }

    /// `zed.update {"now": true}`: install the staged release as soon as Zed is idle,
    /// without the settle time. Running turns are never interrupted for an update.
    pub(super) fn zed_update_now(&self) -> (StatusCode, Result<Value, Value>) {
        let mut accepted = false;
        self.set_update_status(|status| {
            if status.pending_tag.is_some() {
                status.now = true;
                accepted = true;
            }
        });
        if accepted {
            (StatusCode::OK, Ok(json!({"accepted": true})))
        } else {
            (
                StatusCode::CONFLICT,
                Err(json!({"code": "NO_PENDING_UPDATE"})),
            )
        }
    }

    /// What keeps the staged release from being installed right now, if anything.
    async fn update_blocker(&self, target: &ProbeTarget) -> Option<&'static str> {
        let request = |method: &str, params: Value| json!({"version": 1, "request_id": Uuid::new_v4().to_string(), "method": method, "params": params});
        let Ok(list) = self
            .probe(Some(&target.id), &request("thread.list", json!({})))
            .await
        else {
            return Some("bridge_busy");
        };
        let Some(threads) = list["result"]["threads"].as_array() else {
            return Some("bridge_busy");
        };
        if threads
            .iter()
            .any(|thread| thread["status"] == "Generating")
        {
            return Some("turns_running");
        }
        let (instance, epoch) = (&list["result"]["instance_id"], &list["result"]["epoch"]);
        for thread in threads {
            let Some(thread_id) = thread["thread_id"].as_str() else {
                continue;
            };
            let Ok(snapshot) = self
                .probe(
                    Some(&target.id),
                    &request(
                        "thread.snapshot",
                        json!({"thread_id": thread_id, "tail_entry_count": 1}),
                    ),
                )
                .await
            else {
                return Some("bridge_busy");
            };
            if !pending_approval_keys(&snapshot["result"]).is_empty() {
                return Some("waiting_approval");
            }
            let inputs = self
                .probe(
                    Some(&target.id),
                    &request(
                        "thread.elicitations",
                        json!({"thread_id": thread_id, "instance_id": instance, "epoch": epoch}),
                    ),
                )
                .await
                .ok();
            if inputs.is_some_and(|inputs| {
                inputs["result"]["elicitations"]
                    .as_array()
                    .is_some_and(|rows| rows.iter().any(|row| row["status"] == "pending"))
            }) {
                return Some("waiting_input");
            }
        }
        let now = now_seconds();
        let job_due = self
            .0
            .persisted
            .lock()
            .await
            .autopilot
            .jobs
            .iter()
            .any(|job| job.target_id == target.id && job.at - now < JOB_MARGIN_SECONDS);
        if job_due {
            return Some("autopilot_job_due");
        }
        None
    }

    /// The Zed binary on disk differs from the one the running Zed was started from (installed
    /// by hand or by another tool while Zed ran). Returns the on-disk file's identity.
    fn running_zed_outdated(check: &zed_control::BridgeCheck, app: &Path) -> Option<(u64, u64)> {
        let pid = check.pid?;
        let editor = app.join("libexec/zed-editor");
        let running = fs::read_link(format!("/proc/{pid}/exe")).ok()?;
        let running_path = running.to_string_lossy();
        let running_path = running_path
            .strip_suffix(" (deleted)")
            .unwrap_or(&running_path);
        // Only a Zed started from this app directory: a stock Zed elsewhere is not ours to update.
        if Path::new(running_path) != fs::canonicalize(&editor).ok()?.as_path() {
            return None;
        }
        let image = fs::metadata(format!("/proc/{pid}/exe")).ok()?;
        let disk = fs::metadata(&editor).ok()?;
        if !disk.is_file() || disk.permissions().mode() & 0o111 == 0 {
            return None;
        }
        let disk_identity = (disk.dev(), disk.ino());
        (disk_identity != (image.dev(), image.ino())).then_some(disk_identity)
    }

    pub(super) async fn zed_update_loop(&self) {
        let (Some(directory), Some(app)) = (update_directory(), app_directory()) else {
            return;
        };
        let mut idle_since: Option<Instant> = None;
        // A binary already on disk is restarted into once; if Zed still runs something else
        // afterwards (started outside the unit), it is not retried in a loop.
        let mut restarted_for: Option<(u64, u64)> = None;
        let mut interval = tokio::time::interval(POLL);
        loop {
            interval.tick().await;
            let Some(target) = self
                .0
                .targets
                .iter()
                .find(|target| target.zed_unit.is_some())
                .cloned()
            else {
                continue;
            };
            if self.restart_in_progress(&target.id) {
                continue;
            }
            let pending = match read_pending(&directory) {
                Some(pending)
                    if !staged_path_is_expected(&pending, &app)
                        || directory.join(format!("failed-{}", pending.tag)).exists() =>
                {
                    eprintln!(
                        "zed update: ignoring pending.json (unexpected path or failed release)"
                    );
                    fs::remove_file(directory.join("pending.json")).ok();
                    None
                }
                pending => pending,
            };
            let check = self.check_bridge(&target).await;
            let plan = match pending {
                Some(pending) => Plan::Staged(pending),
                None => match Self::running_zed_outdated(&check, &app)
                    .filter(|disk| restarted_for != Some(*disk))
                {
                    Some(disk) => Plan::Restart { disk },
                    None => {
                        idle_since = None;
                        self.set_update_status(|status| {
                            status.pending_tag = None;
                            status.waiting = None;
                            status.now = false;
                        });
                        continue;
                    }
                },
            };
            let tag = match &plan {
                Plan::Staged(pending) => pending.tag.clone(),
                Plan::Restart { .. } => {
                    installed_tag().unwrap_or_else(|| "новая версия на диске".to_owned())
                }
            };
            self.set_update_status(|status| status.pending_tag = Some(tag.clone()));
            let blocker = match check.state {
                BridgeState::Down => None,
                BridgeState::Hung => Some("zed_hung"),
                BridgeState::Up => self.update_blocker(&target).await,
            };
            if let Some(blocker) = blocker {
                idle_since = None;
                self.set_update_status(|status| status.waiting = Some(blocker));
                continue;
            }
            let since = *idle_since.get_or_insert_with(Instant::now);
            let now = self
                .0
                .zed_update
                .lock()
                .map(|status| status.now)
                .unwrap_or(false);
            if check.state == BridgeState::Up && since.elapsed() < SETTLE && !now {
                self.set_update_status(|status| status.waiting = Some("settling"));
                continue;
            }
            idle_since = None;
            {
                let Ok(mut restarts) = self.0.zed_restarts.lock() else {
                    continue;
                };
                if !restarts.insert(target.id.clone()) {
                    continue;
                }
            }
            self.set_update_status(|status| {
                status.applying = true;
                status.waiting = None;
            });
            let outcome = match &plan {
                Plan::Staged(pending) => {
                    self.apply_update(&target, check, pending, &app, &directory)
                        .await
                }
                Plan::Restart { disk } => {
                    restarted_for = Some(*disk);
                    self.restart_into_disk_zed(&target, check, &app).await
                }
            };
            if let Ok(mut restarts) = self.0.zed_restarts.lock() {
                restarts.remove(&target.id);
            }
            if let Err(Applied::NotStarted(error)) = &outcome {
                // Zed could not be stopped and nothing changed: try again on a later poll.
                eprintln!("zed update: {tag} postponed: {error:#}");
                if matches!(plan, Plan::Restart { .. }) {
                    restarted_for = None;
                }
                self.set_update_status(|status| {
                    status.applying = false;
                    status.last_result = Some(format!("postponed {tag}"));
                });
                continue;
            }
            if matches!(plan, Plan::Staged(_)) {
                fs::remove_file(directory.join("pending.json")).ok();
            }
            let (title, body, result) = match (&outcome, &plan) {
                (Ok(()), Plan::Staged(_)) => {
                    eprintln!("zed update: installed {tag} for target {}", target.id);
                    (
                        "Zed обновлён".to_owned(),
                        format!(
                            "Установлен {tag}. Все треды были остановлены, работа не прервана."
                        ),
                        format!("installed {tag}"),
                    )
                }
                (Ok(()), Plan::Restart { .. }) => {
                    eprintln!("zed update: restarted into the Zed on disk ({tag})");
                    (
                        "Zed перезапущен на новой версии".to_owned(),
                        format!(
                            "Запущен {tag}, уже лежавший на диске. Все треды были остановлены."
                        ),
                        format!("restarted {tag}"),
                    )
                }
                (Err(Applied::NotStarted(error) | Applied::RolledBack(error)), Plan::Staged(_)) => {
                    eprintln!("zed update: {tag} failed: {error:#}");
                    (
                        "Обновление Zed не удалось".to_owned(),
                        format!("{tag} не запустился, оставлена прежняя версия."),
                        format!("failed {tag}"),
                    )
                }
                (
                    Err(Applied::NotStarted(error) | Applied::RolledBack(error)),
                    Plan::Restart { .. },
                ) => {
                    eprintln!("zed update: restart into the Zed on disk failed: {error:#}");
                    (
                        "Zed не запустился".to_owned(),
                        "Zed на диске не поднялся после перезапуска. Нужна проверка на компьютере."
                            .to_owned(),
                        format!("broken {tag}"),
                    )
                }
            };
            self.set_update_status(|status| {
                status.applying = false;
                status.now = false;
                status.pending_tag = None;
                status.last_result = Some(result);
            });
            self.notify_all(&PushMessage {
                title,
                subtitle: Some(target.label.clone()),
                body,
                event: NotificationEvent::ZedUpdate,
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

    /// Restart without a swap: the new Zed is already in place. There is no previous copy to
    /// roll back to, so a Zed on disk that does not even report its version is left alone.
    async fn restart_into_disk_zed(
        &self,
        target: &ProbeTarget,
        check: zed_control::BridgeCheck,
        app: &Path,
    ) -> Result<(), Applied> {
        let unit = target
            .zed_unit
            .clone()
            .ok_or_else(|| Applied::NotStarted(anyhow::anyhow!("no Zed unit")))?;
        let version = tokio::time::timeout(
            Duration::from_secs(20),
            tokio::process::Command::new(app.join("bin/zed"))
                .arg("--version")
                .output(),
        )
        .await;
        if !matches!(&version, Ok(Ok(output)) if output.status.success()) {
            return Err(Applied::RolledBack(anyhow::anyhow!(
                "the Zed on disk does not run `zed --version`; not restarting into it"
            )));
        }
        self.stop_zed(target, check)
            .await
            .map_err(Applied::NotStarted)?;
        let started = match start_unit(&unit).await {
            Ok(()) => self.wait_for_bridge(target, START_LIMIT).await,
            Err(error) => Err(error),
        };
        started.map_err(Applied::RolledBack)
    }

    async fn apply_update(
        &self,
        target: &ProbeTarget,
        check: zed_control::BridgeCheck,
        pending: &Pending,
        app: &Path,
        directory: &Path,
    ) -> Result<(), Applied> {
        let unit = target
            .zed_unit
            .clone()
            .ok_or_else(|| Applied::NotStarted(anyhow::anyhow!("no Zed unit")))?;
        let was_running = check.state != BridgeState::Down;
        self.stop_zed(target, check)
            .await
            .map_err(Applied::NotStarted)?;
        {
            let (app, staged) = (app.to_owned(), pending.staged.clone());
            let swapped = tokio::task::spawn_blocking(move || swap_in(&app, &staged))
                .await
                .map_err(anyhow::Error::from)
                .and_then(|swapped| swapped);
            if let Err(error) = swapped {
                // swap_in restored the old app; Zed is stopped, so bring it back.
                if was_running {
                    start_unit(&unit).await.ok();
                }
                fs::write(directory.join(format!("failed-{}", pending.tag)), b"").ok();
                return Err(Applied::RolledBack(error));
            }
        }
        if !was_running {
            return Ok(());
        }
        let started = match start_unit(&unit).await {
            Ok(()) => self.wait_for_bridge(target, START_LIMIT).await,
            Err(error) => Err(error),
        };
        let Err(error) = started else {
            return Ok(());
        };
        systemctl("stop", &unit).await.ok();
        let (app_path, tag) = (app.to_owned(), pending.tag.clone());
        let restored = tokio::task::spawn_blocking(move || roll_back(&app_path, &tag))
            .await
            .map_err(anyhow::Error::from)
            .and_then(|restored| restored);
        fs::write(directory.join(format!("failed-{}", pending.tag)), b"").ok();
        if let Err(restore_error) = restored {
            return Err(Applied::RolledBack(error.context(format!(
                "the new Zed did not start and rollback failed: {restore_error:#}"
            ))));
        }
        start_unit(&unit).await.ok();
        Err(Applied::RolledBack(
            error.context("the new Zed did not start; rolled back"),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_tags_are_plain() {
        assert!(valid_release_tag("zed-v1.29.3-zlink.7"));
        assert!(!valid_release_tag("zed-v"));
        assert!(!valid_release_tag("zed-v1.29.3/../x"));
        assert!(!valid_release_tag("gateway-v2"));
    }

    #[test]
    fn staged_path_must_sit_next_to_the_app() {
        let root = std::env::temp_dir().join(format!("zlink-update-test-{}", Uuid::new_v4()));
        let app = root.join("zed.app");
        let staged = root.join(".zed.app.next-zed-v1.29.3-zlink.7");
        fs::create_dir_all(staged.join("libexec")).unwrap();
        fs::write(staged.join("libexec/zed-editor"), b"").unwrap();
        let good = Pending {
            tag: "zed-v1.29.3-zlink.7".into(),
            staged: staged.clone(),
        };
        assert!(staged_path_is_expected(&good, &app));
        let elsewhere = Pending {
            tag: "zed-v1.29.3-zlink.7".into(),
            staged: root.join("other"),
        };
        assert!(!staged_path_is_expected(&elsewhere, &app));
        let wrong_tag = Pending {
            tag: "zed-v1.29.3-zlink.8".into(),
            staged,
        };
        assert!(!staged_path_is_expected(&wrong_tag, &app));

        fs::create_dir_all(&app).unwrap();
        fs::write(app.join("old"), b"").unwrap();
        swap_in(&app, &good.staged).unwrap();
        assert!(app.join("libexec/zed-editor").is_file());
        assert!(root.join(".zed.app.prev/old").is_file());
        roll_back(&app, &good.tag).unwrap();
        assert!(app.join("old").is_file());
        assert!(
            root.join(".zed.app.failed-zed-v1.29.3-zlink.7/libexec/zed-editor")
                .is_file()
        );
        fs::remove_dir_all(&root).unwrap();
    }
}
