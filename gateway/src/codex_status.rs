//! Codex subscription limits through the agent's own `/status` command.
//!
//! Codex on an SSH host writes its rollout files there, out of the gateway's reach, but
//! codex-acp answers `/status` locally (no model call) with the current limits. The gateway
//! keeps one service thread for this, hidden from the phone, and asks it when the phone
//! opens the limits and every 10 minutes while a Codex turn runs.

use super::*;
use chrono::{DateTime, Datelike, Local, NaiveDate, NaiveTime, TimeZone};

const TITLE: &str = "ZLink: лимиты Codex";
const ON_DEMAND: Duration = Duration::from_secs(2 * 60);
const WHILE_WORKING: Duration = Duration::from_secs(10 * 60);
/// A new service thread at most this often, so a thread that cannot be reopened after a
/// Zed restart does not pile up copies.
const CREATE_EVERY: i64 = 6 * 60 * 60;
const REPLY_WAIT: Duration = Duration::from_secs(45);
const KEPT_THREADS: usize = 16;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub(super) struct State {
    /// Every service thread created, newest last; all of them stay hidden.
    threads: Vec<ServiceThread>,
    last_created: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
struct ServiceThread {
    target_id: String,
    thread_id: String,
}

impl State {
    pub(super) fn is_service_thread(&self, thread_id: &str) -> bool {
        self.threads
            .iter()
            .any(|thread| thread.thread_id == thread_id)
    }

    fn current(&self, target_id: &str) -> Option<String> {
        self.threads
            .iter()
            .rev()
            .find(|thread| thread.target_id == target_id)
            .map(|thread| thread.thread_id.clone())
    }
}

/// Where Codex was last seen working: the project a service thread can be created in.
#[derive(Clone, Debug)]
struct Hint {
    target_id: String,
    project_id: String,
    agent_id: String,
    remote: bool,
}

#[derive(Default)]
pub(super) struct Runtime {
    running: bool,
    last_attempt: Option<Instant>,
    hint: Option<Hint>,
    last_problem: String,
}

/// Removes the service threads from a bridge result the phone is about to receive.
pub(super) fn hide_threads(value: &mut Value, state: &State) {
    match value {
        Value::Array(items) => {
            items.retain(|item| {
                !item["thread_id"]
                    .as_str()
                    .is_some_and(|id| state.is_service_thread(id))
            });
            for item in items {
                hide_threads(item, state);
            }
        }
        Value::Object(fields) => {
            for field in fields.values_mut() {
                hide_threads(field, state);
            }
        }
        _ => {}
    }
}

fn window_kind(label: &str) -> Option<(String, &str)> {
    let rest = label.strip_suffix(" limit")?;
    if let Some(prefix) = rest.strip_suffix("Weekly") {
        return Some((limits::codex_window_kind(10_080), prefix.trim()));
    }
    let (prefix, window) = rest.rsplit_once(' ').unwrap_or(("", rest));
    let (count, minutes_each) = if let Some(count) = window.strip_suffix('h') {
        (count, 60)
    } else if let Some(count) = window.strip_suffix('d') {
        (count, 1440)
    } else {
        (window.strip_suffix('m')?, 1)
    };
    let minutes = count.parse::<i64>().ok()?.checked_mul(minutes_each)?;
    Some((limits::codex_window_kind(minutes), prefix.trim()))
}

/// `(resets 14:30)` (today) or `(resets 09:00 on 4 Dec)` / `on Dec 4`, in the host's local
/// time, which is taken to be the gateway's.
fn reset_time<Tz: TimeZone>(text: &str, now: &DateTime<Tz>) -> Option<i64> {
    let inside = text.split_once("(resets ")?.1.split_once(')')?.0;
    let (clock, date) = match inside.split_once(" on ") {
        Some((clock, date)) => (clock, Some(date)),
        None => (inside, None),
    };
    let time = NaiveTime::parse_from_str(clock.trim(), "%H:%M").ok()?;
    let today = now.date_naive();
    let at = |date: NaiveDate| {
        now.timezone()
            .from_local_datetime(&date.and_time(time))
            .earliest()
            .map(|moment| moment.timestamp())
    };
    let Some(date) = date else {
        let moment = at(today)?;
        return if moment + 60 < now.timestamp() {
            at(today.succ_opt()?)
        } else {
            Some(moment)
        };
    };
    let mut day = None;
    let mut month = None;
    for part in date.split_whitespace() {
        if let Ok(number) = part.trim_matches(|c: char| !c.is_ascii_digit()).parse() {
            day = Some(number);
        } else {
            let names = [
                "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
            ];
            let lower = part.to_ascii_lowercase();
            month = names
                .iter()
                .position(|name| lower.starts_with(name))
                .and_then(|index| u32::try_from(index + 1).ok());
        }
    }
    let (day, month) = (day?, month?);
    let this_year = NaiveDate::from_ymd_opt(today.year(), month, day)?;
    if this_year.succ_opt()? < today {
        at(NaiveDate::from_ymd_opt(today.year() + 1, month, day)?)
    } else {
        at(this_year)
    }
}

/// The limit lines of a `/status` reply, e.g. `**5h limit:** 32% left (resets 14:30)`.
fn parse_status<Tz: TimeZone>(text: &str, now: &DateTime<Tz>) -> Vec<limits::StoredWindow> {
    let mut windows = Vec::<limits::StoredWindow>::new();
    for line in text.lines() {
        let Some((label, rest)) = line
            .split_once("**")
            .and_then(|(_, rest)| rest.split_once(":**"))
        else {
            continue;
        };
        let Some(left) = rest
            .split_once("% left")
            .and_then(|(percent, _)| percent.trim().parse::<f64>().ok())
        else {
            continue;
        };
        let Some((kind, prefix)) = window_kind(label.trim()) else {
            continue;
        };
        // Other prefixes are separate per-model limits, not the subscription windows.
        if !(prefix.is_empty() || prefix.eq_ignore_ascii_case("codex")) {
            continue;
        }
        if windows.iter().any(|window| window.kind == kind) {
            continue;
        }
        windows.push(limits::StoredWindow {
            kind,
            used_percent: (100.0 - left).clamp(0.0, 100.0),
            resets_at: reset_time(rest, now),
            status: None,
            observed_at: now.timestamp(),
        });
    }
    windows
}

/// The text of the reply that closes the snapshot's transcript tail.
fn closing_reply(snapshot: &Value) -> Option<String> {
    let entry = snapshot["entries_meta"].as_array()?.last()?;
    if entry["kind"] != "assistant" {
        return None;
    }
    Some(
        entry["segments"]
            .as_array()?
            .iter()
            .filter_map(|segment| segment["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

impl Gateway {
    pub(super) async fn is_service_thread(&self, thread_id: &str) -> bool {
        self.0
            .persisted
            .lock()
            .await
            .codex_status
            .is_service_thread(thread_id)
    }

    pub(super) async fn hide_service_threads(&self, result: &mut Value) {
        let persisted = self.0.persisted.lock().await;
        hide_threads(result, &persisted.codex_status);
    }

    /// Monitor hook: remembers where Codex runs and refreshes while it works.
    pub(super) async fn codex_status_seen(&self, target_id: &str, threads: &[Value]) {
        let mut working = false;
        let mut hint: Option<Hint> = None;
        for row in threads {
            let agent_id = row["agent"]["id"].as_str().unwrap_or("");
            let name = row["agent"]["name"].as_str().unwrap_or("");
            if limits::agent_key(agent_id, name) != Some("codex")
                || row["thread_id"].as_str().is_none()
            {
                continue;
            }
            if self
                .is_service_thread(row["thread_id"].as_str().unwrap_or(""))
                .await
            {
                continue;
            }
            let generating = row["status"] == "Generating";
            working |= generating;
            let Some(project_id) = nonempty(&row["project_id"]) else {
                continue;
            };
            let remote = nonempty(&row["host_id"]).is_some_and(|host| host != "local");
            // A remote project wins: local Codex is already read from its rollout files.
            if hint
                .as_ref()
                .is_none_or(|known| (remote, generating) > (known.remote, false))
            {
                hint = Some(Hint {
                    target_id: target_id.to_owned(),
                    project_id: project_id.to_owned(),
                    agent_id: agent_id.to_owned(),
                    remote,
                });
            }
        }
        if let Some(hint) = hint
            && let Ok(mut runtime) = self.0.codex_status_runtime.lock()
            && runtime
                .hint
                .as_ref()
                .is_none_or(|known| hint.remote || !known.remote)
        {
            runtime.hint = Some(hint);
        }
        if working {
            self.codex_status_refresh(WHILE_WORKING);
        }
    }

    pub(super) fn codex_status_on_demand(&self) {
        self.codex_status_refresh(ON_DEMAND);
    }

    /// Starts one refresh in the background unless one ran less than `every` ago.
    fn codex_status_refresh(&self, every: Duration) {
        if std::env::var_os("ZEDLINK_CODEX_STATUS").is_some_and(|value| value == "0") {
            return;
        }
        let hint = {
            let Ok(mut runtime) = self.0.codex_status_runtime.lock() else {
                return;
            };
            if runtime.running
                || runtime
                    .last_attempt
                    .is_some_and(|attempt| attempt.elapsed() < every)
            {
                return;
            }
            let Some(hint) = runtime.hint.clone() else {
                return;
            };
            runtime.running = true;
            runtime.last_attempt = Some(Instant::now());
            hint
        };
        let state = self.clone();
        tokio::spawn(async move {
            let outcome = state.ask_codex_status(&hint).await;
            if let Ok(mut runtime) = state.0.codex_status_runtime.lock() {
                runtime.running = false;
                let problem = outcome.err().unwrap_or_default();
                if problem != runtime.last_problem {
                    if !problem.is_empty() {
                        eprintln!("codex limits via /status: {problem}");
                    }
                    runtime.last_problem = problem;
                }
            }
        });
    }

    async fn ask_codex_status(&self, hint: &Hint) -> Result<(), String> {
        let target = hint.target_id.as_str();
        let info = self
            .native_call(target, "instance.info", json!({}), None)
            .await?;
        let (instance, epoch) = (info["instance_id"].clone(), info["epoch"].clone());
        let current = self.0.persisted.lock().await.codex_status.current(target);
        let mut ready = None;
        if let Some(thread_id) = current
            && let Ok(snapshot) = self.service_snapshot(target, &thread_id).await
        {
            ready = Some((thread_id, snapshot));
        } else if let Some(thread_id) = self.0.persisted.lock().await.codex_status.current(target)
            && self
                .native_call(
                    target,
                    "thread.open",
                    json!({"instance_id": instance, "epoch": epoch, "thread_id": thread_id}),
                    None,
                )
                .await
                .is_ok()
        {
            for _ in 0..10 {
                tokio::time::sleep(Duration::from_secs(1)).await;
                if let Ok(snapshot) = self.service_snapshot(target, &thread_id).await {
                    ready = Some((thread_id.clone(), snapshot));
                    break;
                }
            }
        }
        let (thread_id, snapshot) = match ready {
            Some(ready) => ready,
            None => {
                let thread_id = self.create_service_thread(hint, &instance, &epoch).await?;
                let snapshot = self.service_snapshot(target, &thread_id).await?;
                (thread_id, snapshot)
            }
        };
        if snapshot["status"] != "Idle" {
            return Err("service thread is busy".to_owned());
        }
        let before = snapshot["last_sequence"].as_u64().unwrap_or(0);
        let request_id = format!("codex-status:{}", Uuid::new_v4());
        self.native_call(
            target,
            "thread.send",
            json!({"instance_id": instance, "epoch": epoch, "thread_id": thread_id, "text": "/status"}),
            Some(&request_id),
        )
        .await?;
        let deadline = Instant::now() + REPLY_WAIT;
        while Instant::now() < deadline {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let snapshot = self.service_snapshot(target, &thread_id).await?;
            if snapshot["status"] != "Idle"
                || snapshot["last_sequence"].as_u64().unwrap_or(0) <= before
            {
                continue;
            }
            let Some(reply) = closing_reply(&snapshot) else {
                continue;
            };
            let windows = parse_status(&reply, &Local::now());
            if windows.is_empty() {
                return Err("the /status reply has no limit lines".to_owned());
            }
            self.change_persisted(|state| {
                let changed = limits::merge(
                    &mut state.limits,
                    limits::Observation {
                        agent: "codex",
                        source: "codex_status",
                        windows,
                    },
                );
                (changed, ())
            })
            .await;
            return Ok(());
        }
        Err("no /status reply".to_owned())
    }

    async fn service_snapshot(&self, target: &str, thread_id: &str) -> Result<Value, String> {
        self.native_call(
            target,
            "thread.snapshot",
            json!({"thread_id": thread_id, "tail_entry_count": 2}),
            None,
        )
        .await
    }

    async fn create_service_thread(
        &self,
        hint: &Hint,
        instance: &Value,
        epoch: &Value,
    ) -> Result<String, String> {
        let now = now_seconds();
        let allowed = self
            .change_persisted(|state| {
                let allowed = now - state.codex_status.last_created >= CREATE_EVERY;
                if allowed {
                    state.codex_status.last_created = now;
                }
                (allowed, allowed)
            })
            .await;
        if !allowed {
            return Err(
                "service thread unavailable; a new one is created at most every 6 h".into(),
            );
        }
        let request_id = format!("codex-status:{}", Uuid::new_v4());
        let params = json!({"instance_id": instance, "epoch": epoch, "title": TITLE,
            "agent_id": hint.agent_id, "project_id": hint.project_id});
        for _ in 0..60 {
            let result = self
                .native_call(
                    &hint.target_id,
                    "thread.create",
                    params.clone(),
                    Some(&request_id),
                )
                .await?;
            if let Some(thread_id) = result["thread_id"].as_str() {
                let thread = ServiceThread {
                    target_id: hint.target_id.clone(),
                    thread_id: thread_id.to_owned(),
                };
                self.change_persisted(|state| {
                    let threads = &mut state.codex_status.threads;
                    threads.push(thread);
                    if threads.len() > KEPT_THREADS {
                        threads.remove(0);
                    }
                    (true, ())
                })
                .await;
                return Ok(thread_id.to_owned());
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        Err("service thread was not created in time".to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn parses_the_limit_lines_of_a_status_reply() {
        let now = at("2026-11-28T10:00:00Z");
        let reply = "**Model:** gpt  \n**Context window:** 90% left  \n\
            **codex 5h limit:** 32% left (resets 14:30)  \n\
            **codex Weekly limit:** 83% left (resets 09:00 on 4 Dec)  \n\
            **other-model 5h limit:** 1% left (resets 11:00)";
        let windows = parse_status(reply, &now);
        let summary = windows
            .iter()
            .map(|window| (window.kind.as_str(), window.used_percent, window.resets_at))
            .collect::<Vec<_>>();
        assert_eq!(
            summary,
            vec![
                (
                    "five_hour",
                    68.0,
                    Some(at("2026-11-28T14:30:00Z").timestamp())
                ),
                (
                    "seven_day",
                    17.0,
                    Some(at("2026-12-04T09:00:00Z").timestamp())
                ),
            ]
        );
        assert!(parse_status("**Limits:** data not available yet", &now).is_empty());
    }

    #[test]
    fn reset_dates_accept_both_orders_and_cross_the_year() {
        let now = at("2026-12-30T10:00:00Z");
        assert_eq!(
            reset_time("(resets 09:00 on Jan 3)", &now),
            Some(at("2027-01-03T09:00:00Z").timestamp())
        );
        assert_eq!(
            reset_time("(resets 01:00)", &now),
            Some(at("2026-12-31T01:00:00Z").timestamp())
        );
        assert_eq!(reset_time("", &now), None);
    }

    #[test]
    fn service_threads_are_hidden_everywhere() {
        let state = State {
            threads: vec![ServiceThread {
                target_id: "t".into(),
                thread_id: "service".into(),
            }],
            last_created: 0,
        };
        let mut result = json!({
            "threads": [{"thread_id": "service"}, {"thread_id": "real"}],
            "hosts": [{"projects": [{"threads": [{"thread_id": "service"}]}]}],
        });
        hide_threads(&mut result, &state);
        assert_eq!(result["threads"], json!([{"thread_id": "real"}]));
        assert_eq!(result["hosts"][0]["projects"][0]["threads"], json!([]));
    }
}
