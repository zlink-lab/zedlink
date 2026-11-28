//! Remaining subscription budget per agent (`limits.list`).
//!
//! Sources: the bridge's `agent.limits` (Claude rate-limit events forwarded by claude-acp) and
//! the newest Codex rollout file (`$CODEX_HOME|~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`),
//! of which only the tail is read. Only numbers, window kinds and statuses are kept; nothing
//! from either source is logged.

use super::*;
use std::collections::BTreeMap;
use std::io::{Read, Seek, SeekFrom};

pub(super) const LIMITS_POLL: Duration = Duration::from_secs(120);
const ROLLOUT_TAIL: u64 = 256 * 1024;
/// Day directories scanned for the newest rollout (a long session keeps writing to the file
/// of the day it started).
const ROLLOUT_DAYS: usize = 7;
const ROLLOUT_FILES: usize = 8;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub(super) struct StoredWindow {
    pub(super) kind: String,
    pub(super) used_percent: f64,
    #[serde(default)]
    pub(super) resets_at: Option<i64>,
    #[serde(default)]
    pub(super) status: Option<String>,
    pub(super) observed_at: i64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub(super) struct StoredAgent {
    pub(super) source: String,
    pub(super) observed_at: i64,
    pub(super) windows: Vec<StoredWindow>,
}

/// One observation from a source, before merging.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Observation {
    pub(super) agent: &'static str,
    pub(super) source: &'static str,
    pub(super) windows: Vec<StoredWindow>,
}

/// `agent_id`/`agent_name` containing `claude` → claude, `codex` → codex.
pub(super) fn agent_key(id: &str, name: &str) -> Option<&'static str> {
    let text = format!("{id} {name}").to_ascii_lowercase();
    if text.contains("claude") {
        Some("claude")
    } else if text.contains("codex") {
        Some("codex")
    } else {
        None
    }
}

pub(super) fn agent_label(agent: &str) -> &str {
    match agent {
        "claude" => "Claude",
        "codex" => "Codex",
        other => other,
    }
}

/// Codex `window_minutes`: 300 → `five_hour`, 10080 → `seven_day`, else `"<n>m"`.
pub(super) fn codex_window_kind(minutes: i64) -> String {
    match minutes {
        300 => "five_hour".to_owned(),
        10080 => "seven_day".to_owned(),
        other => format!("{other}m"),
    }
}

fn percent(value: f64) -> f64 {
    let value = if value <= 1.0 { value * 100.0 } else { value };
    value.clamp(0.0, 100.0)
}

/// Parses the bridge `agent.limits` result.
pub(super) fn bridge_observations(result: &Value) -> Vec<Observation> {
    let mut observations = Vec::<Observation>::new();
    for row in result["limits"].as_array().into_iter().flatten().take(64) {
        let Some(agent) = agent_key(
            row["agent_id"].as_str().unwrap_or(""),
            row["agent_name"].as_str().unwrap_or(""),
        ) else {
            continue;
        };
        let limit = &row["rate_limit"];
        if !limit.is_object() {
            continue;
        }
        let status = limit["status"].as_str().map(|status| bounded(status, 32));
        // Without utilization the status still tells the threshold or a rejection. With
        // neither, the usage is unknown and must not be shown as 0 %.
        let used_percent = match limit["utilization"].as_f64() {
            Some(value) => percent(value),
            None => match (status.as_deref(), limit["surpassed_threshold"].as_f64()) {
                (Some("rejected"), _) => 100.0,
                (_, Some(threshold)) => percent(threshold),
                _ => continue,
            },
        };
        let observed_at = row["observed_at_ms"]
            .as_i64()
            .map_or_else(now_seconds, |ms| ms / 1000);
        let window = StoredWindow {
            kind: limit["rate_limit_type"]
                .as_str()
                .map_or_else(|| "unknown".to_owned(), |kind| bounded(kind, 32)),
            used_percent,
            resets_at: limit["resets_at"].as_i64(),
            status,
            observed_at,
        };
        match observations.iter_mut().find(|item| item.agent == agent) {
            Some(observation) => observation.windows.push(window),
            None => observations.push(Observation {
                agent,
                source: "acp",
                windows: vec![window],
            }),
        }
    }
    observations
}

fn bounded(text: &str, max: usize) -> String {
    text.chars()
        .filter(|character| !character.is_control())
        .take(max)
        .collect()
}

/// The last `token_count` event with `rate_limits` in a rollout tail. `partial_start` drops
/// the first line, which a tail read usually cuts.
pub(super) fn parse_rollout_tail(
    tail: &[u8],
    partial_start: bool,
    fallback_observed_at: i64,
) -> Option<Observation> {
    let mut lines = tail.split(|byte| *byte == b'\n').collect::<Vec<_>>();
    if partial_start && !lines.is_empty() {
        lines.remove(0);
    }
    for line in lines.into_iter().rev() {
        if !line
            .windows(b"rate_limits".len())
            .any(|window| window == b"rate_limits")
        {
            continue;
        }
        let Ok(event) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if event["payload"]["type"] != "token_count" {
            continue;
        }
        let limits = &event["payload"]["rate_limits"];
        if !limits.is_object() {
            continue;
        }
        let observed_at = event["timestamp"]
            .as_str()
            .and_then(|stamp| chrono::DateTime::parse_from_rfc3339(stamp).ok())
            .map_or(fallback_observed_at, |stamp| stamp.timestamp());
        let windows = ["primary", "secondary"]
            .iter()
            .filter_map(|name| {
                let window = &limits[*name];
                Some(StoredWindow {
                    kind: codex_window_kind(window["window_minutes"].as_i64()?),
                    used_percent: window["used_percent"].as_f64()?.clamp(0.0, 100.0),
                    resets_at: window["resets_at"].as_i64(),
                    status: None,
                    observed_at,
                })
            })
            .collect::<Vec<_>>();
        if windows.is_empty() {
            continue;
        }
        return Some(Observation {
            agent: "codex",
            source: "codex_rollout",
            windows,
        });
    }
    None
}

fn numbered_dirs(path: &Path) -> Vec<PathBuf> {
    let mut dirs =
        fs::read_dir(path)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|entry| {
                entry.file_name().to_str().is_some_and(|name| {
                    !name.is_empty() && name.bytes().all(|b| b.is_ascii_digit())
                }) && entry.file_type().is_ok_and(|kind| kind.is_dir())
            })
            .map(|entry| entry.path())
            .collect::<Vec<_>>();
    dirs.sort();
    dirs.reverse();
    dirs
}

/// The most recently modified rollout files among the newest day directories, newest first.
pub(super) fn recent_rollouts(sessions: &Path) -> Vec<(PathBuf, SystemTime)> {
    let mut days = Vec::new();
    'years: for year in numbered_dirs(sessions) {
        for month in numbered_dirs(&year) {
            for day in numbered_dirs(&month) {
                days.push(day);
                if days.len() >= ROLLOUT_DAYS {
                    break 'years;
                }
            }
        }
    }
    let mut rollouts = days
        .iter()
        .flat_map(|day| fs::read_dir(day).into_iter().flatten().flatten())
        .filter(|entry| {
            entry
                .file_name()
                .to_str()
                .is_some_and(|name| name.starts_with("rollout-") && name.ends_with(".jsonl"))
        })
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            metadata
                .is_file()
                .then(|| Some((entry.path(), metadata.modified().ok()?)))?
        })
        .collect::<Vec<_>>();
    rollouts.sort_by_key(|(_, modified)| std::cmp::Reverse(*modified));
    rollouts.truncate(ROLLOUT_FILES);
    rollouts
}

pub(super) fn codex_sessions_dir() -> Option<PathBuf> {
    let home = match std::env::var_os("CODEX_HOME").filter(|value| !value.is_empty()) {
        Some(home) => PathBuf::from(home),
        None => PathBuf::from(std::env::var_os("HOME")?).join(".codex"),
    };
    Some(home.join("sessions"))
}

/// The newest observation among the most recently written rollout files: the very newest
/// one (a session that just started, or a sub-agent) may not hold any limits yet.
pub(super) fn read_codex_limits(sessions: &Path) -> Option<Observation> {
    recent_rollouts(sessions)
        .into_iter()
        .filter_map(|(path, modified)| read_rollout_limits(&path, modified))
        .max_by_key(|observation| {
            observation
                .windows
                .iter()
                .map(|window| window.observed_at)
                .max()
        })
}

fn read_rollout_limits(path: &Path, modified: SystemTime) -> Option<Observation> {
    let mut file = fs::File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    let start = length.saturating_sub(ROLLOUT_TAIL);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut tail = Vec::with_capacity((length - start) as usize);
    file.take(ROLLOUT_TAIL).read_to_end(&mut tail).ok()?;
    let fallback = modified
        .duration_since(UNIX_EPOCH)
        .map_or_else(|_| now_seconds(), |elapsed| elapsed.as_secs() as i64);
    parse_rollout_tail(&tail, start > 0, fallback)
}

/// Keeps per window kind the newest observation. Returns whether anything changed.
pub(super) fn merge(store: &mut BTreeMap<String, StoredAgent>, observation: Observation) -> bool {
    let agent = store.entry(observation.agent.to_owned()).or_default();
    let before = agent.clone();
    for window in observation.windows {
        match agent
            .windows
            .iter_mut()
            .find(|item| item.kind == window.kind)
        {
            Some(existing) if existing.observed_at > window.observed_at => {}
            Some(existing) => *existing = window.clone(),
            None => agent.windows.push(window.clone()),
        }
        if window.observed_at >= agent.observed_at {
            agent.observed_at = window.observed_at;
            agent.source = observation.source.to_owned();
        }
    }
    agent.windows.truncate(16);
    *agent != before
}

/// A window as reported: one whose reset has passed counts as empty.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct WindowView {
    pub(super) kind: String,
    pub(super) used_percent: f64,
    pub(super) resets_at: Option<i64>,
    pub(super) status: Option<String>,
    pub(super) reset: bool,
}

pub(super) fn window_views(agent: &StoredAgent, now: i64) -> Vec<WindowView> {
    let order = |kind: &str| match kind {
        "five_hour" => 0,
        "seven_day" => 1,
        "seven_day_opus" => 2,
        "seven_day_sonnet" => 3,
        _ => 4,
    };
    let mut views = agent
        .windows
        .iter()
        .map(|window| {
            let reset = window.resets_at.is_some_and(|at| at <= now);
            WindowView {
                kind: window.kind.clone(),
                used_percent: if reset { 0.0 } else { window.used_percent },
                resets_at: window.resets_at,
                status: if reset { None } else { window.status.clone() },
                reset,
            }
        })
        .collect::<Vec<_>>();
    views.sort_by(|a, b| {
        order(&a.kind)
            .cmp(&order(&b.kind))
            .then_with(|| a.kind.cmp(&b.kind))
    });
    views
}

pub(super) fn limits_report(store: &BTreeMap<String, StoredAgent>, now: i64) -> Value {
    let agents = store
        .iter()
        .map(|(agent, stored)| {
            let windows = window_views(stored, now)
                .into_iter()
                .map(|view| {
                    let mut window = json!({
                        "kind": view.kind,
                        "used_percent": (view.used_percent * 10.0).round() / 10.0,
                        "resets_at": view.resets_at,
                    });
                    if let Some(status) = view.status {
                        window["status"] = json!(status);
                    }
                    if view.reset {
                        window["reset"] = json!(true);
                    }
                    window
                })
                .collect::<Vec<_>>();
            json!({
                "agent": agent,
                "label": agent_label(agent),
                "source": stored.source,
                "observed_at": stored.observed_at,
                "windows": windows,
            })
        })
        .collect::<Vec<_>>();
    json!({ "agents": agents })
}

/// Last stored sample per (agent, kind): used percent, reset, time.
pub(super) type SampleMemory = HashMap<(String, String), (f64, Option<i64>, i64)>;
const SAMPLE_EVERY: i64 = 10 * 60;

/// A limit sample is stored when the value changed or ten minutes after the last one.
pub(super) fn sample_due(
    last: Option<&(f64, Option<i64>, i64)>,
    used: f64,
    resets_at: Option<i64>,
    now: i64,
) -> bool {
    match last {
        None => true,
        Some((last_used, last_reset, at)) => {
            (last_used - used).abs() >= 0.05 || *last_reset != resets_at || now - at >= SAMPLE_EVERY
        }
    }
}

impl Gateway {
    pub(super) async fn limits_poller(&self) {
        let mut interval = tokio::time::interval(LIMITS_POLL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut pruned_at = 0;
        loop {
            interval.tick().await;
            self.refresh_limits(true).await;
            self.sample_limits().await;
            let now = now_seconds();
            if now - pruned_at >= 86_400 {
                pruned_at = now;
                if let Some(removed) = self
                    .0
                    .database
                    .run(move |connection| db::prune(connection, now))
                    .await
                    && removed > 0
                {
                    eprintln!("history database: removed {removed} rows past retention");
                }
            }
        }
    }

    /// Writes the current windows to `limit_samples` (changed values, else every 10 min).
    async fn sample_limits(&self) {
        let now = now_seconds();
        let store = self.0.persisted.lock().await.limits.clone();
        let mut rows = Vec::new();
        if let Ok(mut memory) = self.0.limit_samples.lock() {
            for (agent, stored) in &store {
                for view in window_views(stored, now) {
                    let key = (agent.clone(), view.kind.clone());
                    if sample_due(memory.get(&key), view.used_percent, view.resets_at, now) {
                        memory.insert(key, (view.used_percent, view.resets_at, now));
                        rows.push((agent.clone(), view.kind, view.used_percent, view.resets_at));
                    }
                }
            }
        }
        if rows.is_empty() {
            return;
        }
        self.0
            .database
            .run(move |connection| {
                for (agent, kind, used, resets_at) in &rows {
                    db::insert_limit_sample(connection, agent, kind, now, *used, *resets_at)?;
                }
                Ok(())
            })
            .await;
    }

    /// `with_bridge: false` only rereads the local Codex file (cheap, for `limits.list`).
    pub(super) async fn refresh_limits(&self, with_bridge: bool) {
        let mut observations = Vec::new();
        if with_bridge {
            for target in &self.0.targets {
                let request = json!({
                    "version": 1, "request_id": Uuid::new_v4().to_string(),
                    "method": "agent.limits", "params": {},
                });
                // Older bridges lack the method or Zed is closed; that is simply "no data", so
                // this goes around `probe` and its failure log.
                if let Ok(response) = self.probe_native(Some(&target.id), &request).await
                    && let Some(result) = response.get("result")
                {
                    observations.extend(bridge_observations(result));
                }
            }
        }
        if let Some(sessions) = codex_sessions_dir()
            && let Ok(Some(observation)) =
                tokio::task::spawn_blocking(move || read_codex_limits(&sessions)).await
        {
            observations.push(observation);
        }
        if observations.is_empty() {
            return;
        }
        self.change_persisted(|state| {
            let mut changed = false;
            for observation in observations {
                changed |= merge(&mut state.limits, observation);
            }
            (changed, ())
        })
        .await;
    }

    pub(super) async fn limits_list(&self) -> Value {
        self.refresh_limits(false).await;
        // Answers with what is known; a newer Codex value arrives on the next request.
        self.codex_status_on_demand();
        limits_report(&self.0.persisted.lock().await.limits, now_seconds())
    }

    pub(super) async fn agent_windows(&self, agent: Option<&str>) -> Vec<WindowView> {
        let Some(agent) = agent else {
            return Vec::new();
        };
        self.0
            .persisted
            .lock()
            .await
            .limits
            .get(agent)
            .map(|stored| window_views(stored, now_seconds()))
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rollout_line(stamp: &str, primary: f64) -> String {
        json!({"timestamp": stamp, "type": "event_msg", "payload": {"type": "token_count",
            "info": {"total_token_usage": {"input_tokens": 1}},
            "rate_limits": {"limit_id": "codex", "limit_name": null,
                "primary": {"used_percent": primary, "window_minutes": 300, "resets_at": 1795787661},
                "secondary": {"used_percent": 17.0, "window_minutes": 10080, "resets_at": 1796196895},
                "credits": {"has_credits": false, "unlimited": false, "balance": "0"},
                "plan_type": "plus"}}})
        .to_string()
    }

    #[test]
    fn limit_samples_are_due_on_change_or_every_ten_minutes() {
        assert!(sample_due(None, 10.0, Some(5), 0));
        let last = (10.0, Some(5), 1000);
        assert!(!sample_due(Some(&last), 10.0, Some(5), 1000 + 599));
        assert!(sample_due(Some(&last), 10.0, Some(5), 1000 + 600));
        assert!(sample_due(Some(&last), 11.0, Some(5), 1001));
        assert!(sample_due(Some(&last), 10.0, Some(6), 1001));
    }

    #[test]
    fn codex_windows_map_minutes_to_kinds() {
        assert_eq!(codex_window_kind(300), "five_hour");
        assert_eq!(codex_window_kind(10080), "seven_day");
        assert_eq!(codex_window_kind(60), "60m");
    }

    #[test]
    fn parses_last_rate_limits_of_a_rollout_tail() {
        let tail = format!(
            "{{\"cut\": tru\n{}\n{}\n{}\n{{\"type\":\"response_item\",\"payload\":{{\"type\":\"message\"}}}}\n",
            rollout_line("2026-11-27T15:00:00.000Z", 50.0),
            rollout_line("2026-11-27T15:10:00.000Z", 68.0),
            json!({"type": "event_msg", "payload": {"type": "token_count", "rate_limits": null}}),
        );
        let observation = parse_rollout_tail(tail.as_bytes(), true, 7).unwrap();
        assert_eq!(observation.agent, "codex");
        assert_eq!(observation.source, "codex_rollout");
        assert_eq!(observation.windows.len(), 2);
        assert_eq!(observation.windows[0].kind, "five_hour");
        assert_eq!(observation.windows[0].used_percent, 68.0);
        assert_eq!(observation.windows[0].resets_at, Some(1795787661));
        assert_eq!(observation.windows[1].kind, "seven_day");
        assert_eq!(observation.windows[0].observed_at, 1795792200);
        assert!(parse_rollout_tail(b"{}\n{\"x\":1}\n", false, 0).is_none());
        // Current Codex writes `secondary: null` on some plans.
        let primary_only = json!({"timestamp": "2026-11-27T15:00:00Z", "type": "event_msg",
            "payload": {"type": "token_count", "info": null, "rate_limits": {
                "limit_id": "codex", "primary": {"used_percent": 12.5, "window_minutes": 300,
                "resets_at": 1795787661}, "secondary": null, "rate_limit_reached_type": null}}})
        .to_string();
        let observation = parse_rollout_tail(primary_only.as_bytes(), false, 0).unwrap();
        assert_eq!(observation.windows.len(), 1);
        assert_eq!(observation.windows[0].used_percent, 12.5);
        // A line with the marker in some other event is ignored.
        let other = json!({"type": "event_msg", "payload": {"type": "agent_message",
            "message": "rate_limits"}})
        .to_string();
        assert!(parse_rollout_tail(other.as_bytes(), false, 0).is_none());
    }

    #[test]
    fn reads_newest_rollout_file_and_only_its_tail() -> Result<()> {
        let root = std::env::temp_dir().join(format!("zlink-limits-{}", Uuid::new_v4()));
        let old_day = root.join("2026/11/25");
        let new_day = root.join("2026/11/27");
        fs::create_dir_all(&old_day)?;
        fs::create_dir_all(&new_day)?;
        fs::write(
            old_day.join("rollout-a.jsonl"),
            rollout_line("2026-11-25T10:00:00Z", 10.0),
        )?;
        std::thread::sleep(Duration::from_millis(20));
        let padding = "x".repeat(300 * 1024);
        fs::write(
            new_day.join("rollout-b.jsonl"),
            format!(
                "{}\n{{\"pad\":\"{padding}\"}}\n{}\n",
                rollout_line("2026-11-27T09:00:00Z", 1.0),
                rollout_line("2026-11-27T10:00:00Z", 42.0)
            ),
        )?;
        fs::write(new_day.join("notes.txt"), "rate_limits")?;
        let observation = read_codex_limits(&root).context("no observation")?;
        assert_eq!(observation.windows[0].used_percent, 42.0);
        std::thread::sleep(Duration::from_millis(20));
        fs::write(
            new_day.join("rollout-c.jsonl"),
            "{\"type\":\"session_meta\"}\n",
        )?;
        let observation = read_codex_limits(&root).context("no observation")?;
        assert_eq!(observation.windows[0].used_percent, 42.0);
        fs::remove_dir_all(&root)?;
        Ok(())
    }

    #[test]
    fn real_codex_rollout_parses_when_present() {
        // Uses this machine's Codex sessions if there are any; prints nothing from them.
        let Some(sessions) = codex_sessions_dir().filter(|path| path.is_dir()) else {
            return;
        };
        if recent_rollouts(&sessions).is_empty() {
            return;
        }
        if let Some(observation) = read_codex_limits(&sessions) {
            assert!(!observation.windows.is_empty());
            assert!(observation.windows.iter().all(|window| {
                (0.0..=100.0).contains(&window.used_percent) && !window.kind.is_empty()
            }));
        }
    }

    #[test]
    fn bridge_claude_limits_become_percent_windows() {
        let result = json!({"instance_id": "i", "epoch": "e", "limits": [
            {"agent_id": "claude-acp", "agent_name": "Claude Agent", "thread_id": "t",
             "observed_at_ms": 1795780000000_i64,
             "rate_limit": {"status": "allowed_warning", "resets_at": 1795787661,
                "rate_limit_type": "five_hour", "utilization": 0.91,
                "surpassed_threshold": 0.9, "is_using_overage": false}},
            {"agent_id": "claude-acp", "agent_name": "Claude Agent", "thread_id": "t",
             "observed_at_ms": 1795780000000_i64,
             "rate_limit": {"status": "rejected", "rate_limit_type": "seven_day_opus"}},
            {"agent_id": "claude-acp", "agent_name": "Claude Agent",
             "rate_limit": {"status": "allowed", "rate_limit_type": "seven_day"}},
            {"agent_id": "gemini", "agent_name": "Gemini", "rate_limit": {"utilization": 5}}]});
        let observations = bridge_observations(&result);
        assert_eq!(observations.len(), 1);
        let claude = &observations[0];
        assert_eq!(claude.agent, "claude");
        assert_eq!(claude.windows[0].used_percent.round(), 91.0);
        assert_eq!(claude.windows[0].status.as_deref(), Some("allowed_warning"));
        assert_eq!(claude.windows[0].observed_at, 1795780000);
        assert_eq!(claude.windows[1].kind, "seven_day_opus");
        assert_eq!(claude.windows[1].used_percent, 100.0);
        assert_eq!(claude.windows.len(), 2, "unknown usage is not a 0 % window");
        assert_eq!(agent_key("codex-acp", "Codex"), Some("codex"));
        assert_eq!(agent_key("zed", "Zed Agent"), None);
    }

    #[test]
    fn report_zeroes_windows_whose_reset_passed_and_merge_keeps_newest() {
        let mut store = BTreeMap::new();
        let window = |kind: &str, used: f64, resets: i64, observed: i64| StoredWindow {
            kind: kind.into(),
            used_percent: used,
            resets_at: Some(resets),
            status: Some("allowed".into()),
            observed_at: observed,
        };
        assert!(merge(
            &mut store,
            Observation {
                agent: "claude",
                source: "acp",
                windows: vec![
                    window("seven_day", 30.0, 2000, 100),
                    window("five_hour", 91.0, 500, 100)
                ],
            }
        ));
        // An older observation does not replace a newer one.
        assert!(!merge(
            &mut store,
            Observation {
                agent: "claude",
                source: "acp",
                windows: vec![window("five_hour", 10.0, 500, 50)],
            }
        ));
        let report = limits_report(&store, 1000);
        let claude = &report["agents"][0];
        assert_eq!(claude["agent"], "claude");
        assert_eq!(claude["label"], "Claude");
        assert_eq!(claude["observed_at"], 100);
        assert_eq!(claude["windows"][0]["kind"], "five_hour");
        assert_eq!(claude["windows"][0]["used_percent"], 0.0);
        assert_eq!(claude["windows"][0]["reset"], true);
        assert!(claude["windows"][0].get("status").is_none());
        assert_eq!(claude["windows"][1]["kind"], "seven_day");
        assert_eq!(claude["windows"][1]["used_percent"], 30.0);
        assert!(claude["windows"][1].get("reset").is_none());
    }
}
