//! Autopilot: scheduled and automatic "continue" messages for exposed threads.
//!
//! State lives in `state.json` (`autopilot: {settings, jobs, threads, log}`); the full log is
//! also written to the history database. Jobs go through the same bridge methods as the phone
//! (`thread.open`, `thread.snapshot`, `thread.send`, `thread.cancel`), never approve anything,
//! and wait while a thread needs approval or input. Every thread is on unless the phone turned
//! it off. The log keeps short codes only, never thread text or error messages.

use super::*;
use chrono::{DateTime, Days, Local, TimeZone};

pub(super) const JOB_POLL: Duration = Duration::from_secs(15);
const MAX_JOBS: usize = 100;
const MAX_LOG: usize = 50;
const MAX_THREADS: usize = 256;
/// Defers (not ready, Zed down, transient failures) before a job is dropped with a push.
const MAX_DEFERS: u32 = 12;
const SCHEDULE_HORIZON: i64 = 7 * 86_400;
const BRIDGE_WAIT: Duration = Duration::from_secs(90);
const THREAD_OPEN_WAIT: Duration = Duration::from_secs(30);
const NOT_READY_DEFER: i64 = 5 * 60;
const ZED_DEFER: i64 = 10 * 60;
const AFTER_RESET: i64 = 2 * 60;
const SOON: i64 = 30;
const RATE_LIMIT_FALLBACK: i64 = 30 * 60;
const MAX_TEXT_BYTES: usize = 3000;
/// Warm pings are not sent at or above this.
const WARM_MAX_PERCENT: f64 = 99.0;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub(super) struct Settings {
    /// Master switch: off stops automatic triggers, automatic jobs and hard stops; times the
    /// user scheduled still run.
    pub(super) enabled: bool,
    pub(super) continue_text: String,
    pub(super) daily_limit: u32,
    pub(super) allow_zed_start: bool,
    pub(super) allow_zed_restart: bool,
    pub(super) hold_percent: u32,
    /// At or above this, Generating turns are cancelled while the reset is far away.
    pub(super) stop_percent: u32,
    pub(super) hold_min_reset_minutes: u32,
    pub(super) warm_enabled: bool,
    pub(super) warm_text: String,
    pub(super) warm_max_interval_minutes: u32,
    pub(super) stall_minutes: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            enabled: true,
            continue_text: "продолжай".into(),
            daily_limit: 5,
            allow_zed_start: true,
            allow_zed_restart: false,
            hold_percent: 95,
            stop_percent: 98,
            hold_min_reset_minutes: 60,
            warm_enabled: true,
            warm_text: "Кратко, одной фразой: на чём остановились? Работу пока не продолжай."
                .into(),
            warm_max_interval_minutes: 55,
            stall_minutes: 15,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub(super) struct Job {
    pub(super) job_id: Uuid,
    pub(super) target_id: String,
    pub(super) thread_id: String,
    /// `continue` or `warm`.
    pub(super) kind: String,
    pub(super) at: i64,
    pub(super) text: String,
    /// `user`, `rate_limit`, `max_turn_requests`, `stalled`, `budget_hold`, `budget_stop`,
    /// `warm`.
    pub(super) reason: String,
    pub(super) created_at: i64,
    pub(super) attempts: u32,
    /// `autopilot:<uuid>`, kept across retries so the bridge deduplicates a resend.
    #[serde(default)]
    pub(super) request_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub(super) struct ThreadFlags {
    pub(super) target_id: String,
    pub(super) thread_id: String,
    pub(super) auto_continue: bool,
    pub(super) actions_today: u32,
    pub(super) day: String,
    /// Day on which the daily-limit push was sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) limit_notified: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub(super) struct LogEntry {
    pub(super) at: i64,
    pub(super) target_id: String,
    pub(super) thread_id: String,
    pub(super) action: String,
    #[serde(default)]
    pub(super) reason: String,
    pub(super) detail: String,
}

/// Hard-stop bookkeeping that does not need to survive a gateway restart.
#[derive(Default)]
pub(super) struct Runtime {
    /// `target:thread` → turns there are not hard-stopped before this (a turn the user
    /// started, or a warm ping).
    exempt_until: HashMap<String, Instant>,
    /// `target:thread` → the turn a hard stop already cancelled.
    stopped_turns: HashMap<String, u64>,
    /// `target:thread` → the reset whose hard-stop push was sent.
    stop_pushed: HashMap<String, i64>,
}

/// A turn started by the user after a hard stop is left alone this long.
const USER_OVERRIDE: Duration = Duration::from_secs(10 * 60);

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub(super) struct AutopilotState {
    pub(super) settings: Settings,
    pub(super) jobs: Vec<Job>,
    pub(super) threads: Vec<ThreadFlags>,
    pub(super) log: Vec<LogEntry>,
}

fn today() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}

fn default_flags(target_id: &str, thread_id: &str, day: &str) -> ThreadFlags {
    ThreadFlags {
        target_id: target_id.to_owned(),
        thread_id: thread_id.to_owned(),
        auto_continue: true,
        actions_today: 0,
        day: day.to_owned(),
        limit_notified: None,
    }
}

impl AutopilotState {
    /// A thread without a record is on (wave 3 §6.1).
    pub(super) fn auto_continue(&self, target_id: &str, thread_id: &str) -> bool {
        self.flags(target_id, thread_id)
            .is_none_or(|flags| flags.auto_continue)
    }

    /// Automatic actions may happen on this thread.
    pub(super) fn active(&self, target_id: &str, thread_id: &str) -> bool {
        self.settings.enabled && self.auto_continue(target_id, thread_id)
    }

    fn flags(&self, target_id: &str, thread_id: &str) -> Option<&ThreadFlags> {
        self.threads
            .iter()
            .find(|flags| flags.target_id == target_id && flags.thread_id == thread_id)
    }

    fn flags_mut(&mut self, target_id: &str, thread_id: &str, day: &str) -> &mut ThreadFlags {
        let index = match self
            .threads
            .iter()
            .position(|flags| flags.target_id == target_id && flags.thread_id == thread_id)
        {
            Some(index) => index,
            None => {
                if self.threads.len() >= MAX_THREADS {
                    // An explicit "off" is kept longest; an "on" record equals the default.
                    let evict = self
                        .threads
                        .iter()
                        .position(|flags| flags.auto_continue && flags.day != day)
                        .or_else(|| self.threads.iter().position(|flags| flags.auto_continue))
                        .unwrap_or(0);
                    self.threads.remove(evict);
                }
                self.threads.push(default_flags(target_id, thread_id, day));
                self.threads.len() - 1
            }
        };
        let flags = &mut self.threads[index];
        if flags.day != day {
            flags.day = day.to_owned();
            flags.actions_today = 0;
        }
        flags
    }

    fn push_log(&mut self, entry: LogEntry) {
        self.log.push(entry);
        if self.log.len() > MAX_LOG {
            let excess = self.log.len() - MAX_LOG;
            self.log.drain(..excess);
        }
    }

    fn add_job(&mut self, job: Job) -> bool {
        if self.jobs.len() >= MAX_JOBS {
            return false;
        }
        self.jobs.push(job);
        self.jobs.sort_by_key(|job| job.at);
        true
    }

    fn recent_history(&self, query: &db::HistoryQuery) -> Value {
        let rows = self
            .log
            .iter()
            .rev()
            .filter(|entry| {
                query
                    .target_id
                    .as_ref()
                    .is_none_or(|id| *id == entry.target_id)
                    && query
                        .thread_id
                        .as_ref()
                        .is_none_or(|id| *id == entry.thread_id)
                    && query.before.is_none_or(|before| entry.at < before)
            })
            .take(query.limit as usize)
            .collect::<Vec<_>>();
        json!({ "rows": rows })
    }

    fn status(&self) -> Value {
        json!({
            "settings": self.settings,
            "jobs": self.jobs,
            "threads": self.threads,
            "log": self.log,
        })
    }
}

pub(super) fn new_job(
    target_id: &str,
    thread_id: &str,
    kind: &str,
    at: i64,
    text: &str,
    reason: &str,
    now: i64,
) -> Job {
    Job {
        job_id: Uuid::new_v4(),
        target_id: target_id.to_owned(),
        thread_id: thread_id.to_owned(),
        kind: kind.to_owned(),
        at,
        text: text.to_owned(),
        reason: reason.to_owned(),
        created_at: now,
        attempts: 0,
        request_id: format!("autopilot:{}", Uuid::new_v4()),
    }
}

// ---------------------------------------------------------------------------------------------
// Pure decisions (unit tested)

/// Texts the bridge accepts as a plain message (not a slash command).
pub(super) fn valid_job_text(text: &str) -> bool {
    !text.trim().is_empty()
        && text.len() <= MAX_TEXT_BYTES
        && !text.trim_start().starts_with('/')
        && !text
            .chars()
            .any(|character| character.is_control() && character != '\n' && character != '\t')
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AutoCommand {
    On,
    Off,
    At(u32, u32),
    Status,
}

/// A `thread.send` text that starts with `/auto` (as a whole word).
pub(super) fn parse_auto(text: &str) -> Option<AutoCommand> {
    let rest = text.trim().strip_prefix("/auto")?;
    if !(rest.is_empty() || rest.starts_with(char::is_whitespace)) {
        return None;
    }
    let words = rest
        .split_whitespace()
        .map(str::to_lowercase)
        .collect::<Vec<_>>();
    let words = words.iter().map(String::as_str).collect::<Vec<_>>();
    Some(match words.as_slice() {
        ["continue"] | ["on"] => AutoCommand::On,
        ["off"] => AutoCommand::Off,
        ["at", time] => match parse_hh_mm(time) {
            Some((hour, minute)) => AutoCommand::At(hour, minute),
            None => AutoCommand::Status,
        },
        _ => AutoCommand::Status,
    })
}

fn parse_hh_mm(text: &str) -> Option<(u32, u32)> {
    let (hour, minute) = text.split_once(':')?;
    if hour.is_empty() || hour.len() > 2 || minute.len() != 2 {
        return None;
    }
    let hour = hour.parse::<u32>().ok()?;
    let minute = minute.parse::<u32>().ok()?;
    (hour < 24 && minute < 60).then_some((hour, minute))
}

/// The next moment after `now` at `hour:minute` local time of `now`'s zone.
pub(super) fn next_occurrence<Tz: TimeZone>(
    now: &DateTime<Tz>,
    hour: u32,
    minute: u32,
) -> Option<i64> {
    let date = now.date_naive();
    (0..3).find_map(|offset| {
        let naive = date
            .checked_add_days(Days::new(offset))?
            .and_hms_opt(hour, minute, 0)?;
        let moment = now.timezone().from_local_datetime(&naive).earliest()?;
        (moment.timestamp() > now.timestamp()).then(|| moment.timestamp())
    })
}

/// Agent error texts that mean a usage or rate limit.
pub(super) fn looks_like_rate_limit(text: &str) -> bool {
    let text = text.to_lowercase();
    [
        "usage limit",
        "rate limit",
        "rate_limit",
        "rate-limit",
        "429",
        "limit reached",
        "hit your limit",
        "resets at",
        "try again at",
        "лимит",
    ]
    .iter()
    .any(|needle| text.contains(needle))
}

fn digit_runs(text: &str) -> impl Iterator<Item = &str> {
    text.split(|character: char| !character.is_ascii_digit())
        .filter(|run| !run.is_empty())
}

fn unix_stamp(text: &str, now: i64) -> Option<i64> {
    digit_runs(text).find_map(|run| {
        let value = run.parse::<i64>().ok()?;
        let seconds = match run.len() {
            10 => value,
            13 => value / 1000,
            _ => return None,
        };
        (now - 86_400..=now + 8 * 86_400)
            .contains(&seconds)
            .then_some(seconds)
    })
}

fn rfc3339_stamp(text: &str) -> Option<i64> {
    text.split_whitespace().find_map(|token| {
        let token = token.trim_matches(|character: char| "()[]{},;\"'«»".contains(character));
        let token = token.strip_suffix('.').unwrap_or(token);
        DateTime::parse_from_rfc3339(token)
            .ok()
            .map(|stamp| stamp.timestamp())
    })
}

fn unit_seconds(unit: &str) -> Option<i64> {
    let unit = unit.trim_end_matches('.');
    match unit {
        "d" | "day" | "days" | "д" | "дн" | "день" | "дня" | "дней" => Some(86_400),
        "h" | "hr" | "hrs" | "hour" | "hours" | "ч" | "час" | "часа" | "часов" => {
            Some(3_600)
        }
        "m" | "min" | "mins" | "minute" | "minutes" | "мин" | "минута" | "минуту" | "минуты"
        | "минут" => Some(60),
        "s" | "sec" | "secs" | "second" | "seconds" | "с" | "сек" | "секунд" | "секунды" => {
            Some(1)
        }
        _ => None,
    }
}

/// "in 2 hours 5 minutes", "in 4h12m", "через 3 ч 10 мин".
fn relative_delay(text: &str) -> Option<i64> {
    for marker in ["in ", "через "] {
        for (index, _) in text.match_indices(marker) {
            if index > 0
                && text[..index]
                    .chars()
                    .next_back()
                    .is_some_and(char::is_alphanumeric)
            {
                continue;
            }
            let mut tokens = Vec::<String>::new();
            let mut current = String::new();
            for character in text[index + marker.len()..].chars() {
                let same_class = current
                    .chars()
                    .next()
                    .is_some_and(|first| first.is_ascii_digit() == character.is_ascii_digit());
                if character.is_ascii_digit() || character.is_alphabetic() || character == '.' {
                    if !current.is_empty() && !same_class {
                        tokens.push(std::mem::take(&mut current));
                    }
                    current.push(character);
                } else if character.is_whitespace() || character == ',' {
                    if !current.is_empty() {
                        tokens.push(std::mem::take(&mut current));
                    }
                } else {
                    break;
                }
                if tokens.len() > 8 {
                    break;
                }
            }
            if !current.is_empty() {
                tokens.push(current);
            }
            let mut total = 0;
            let mut pairs = 0;
            let mut iterator = tokens.iter().peekable();
            while let Some(token) = iterator.next() {
                if matches!(token.as_str(), "and" | "и") {
                    continue;
                }
                let Ok(number) = token.parse::<i64>() else {
                    break;
                };
                let Some(unit) = iterator.next().and_then(|unit| unit_seconds(unit)) else {
                    break;
                };
                total += number.min(1_000) * unit;
                pairs += 1;
            }
            if pairs > 0 {
                return Some(total);
            }
        }
    }
    None
}

/// The first clock time ("15:30", "3pm", "3:45 PM") in a lowercased text.
fn clock_time(text: &str) -> Option<(u32, u32)> {
    let characters = text.chars().collect::<Vec<_>>();
    let digits_at = |start: usize| {
        characters[start..]
            .iter()
            .take_while(|character| character.is_ascii_digit())
            .count()
    };
    let mut index = 0;
    while index < characters.len() {
        let starts_number = characters[index].is_ascii_digit()
            && (index == 0
                || !(characters[index - 1].is_ascii_digit() || characters[index - 1] == ':'));
        if !starts_number {
            index += 1;
            continue;
        }
        let hour_digits = digits_at(index);
        let mut cursor = index + hour_digits;
        let hour = characters[index..cursor].iter().collect::<String>();
        let mut minute = None;
        if hour_digits <= 2 && characters.get(cursor) == Some(&':') && digits_at(cursor + 1) == 2 {
            minute = characters[cursor + 1..cursor + 3]
                .iter()
                .collect::<String>()
                .parse::<u32>()
                .ok();
            cursor += 3;
            // Seconds.
            if characters.get(cursor) == Some(&':') && digits_at(cursor + 1) == 2 {
                cursor += 3;
            }
        }
        let rest = characters[cursor..].iter().collect::<String>();
        let rest = rest.trim_start();
        let meridiem = if rest.starts_with("am") || rest.starts_with("a.m.") {
            Some(false)
        } else if rest.starts_with("pm") || rest.starts_with("p.m.") {
            Some(true)
        } else {
            None
        };
        if hour_digits <= 2
            && (minute.is_some() || meridiem.is_some())
            && let Ok(mut hour) = hour.parse::<u32>()
        {
            let minute = minute.unwrap_or(0);
            let valid = match meridiem {
                Some(pm) if (1..=12).contains(&hour) => {
                    hour = match (pm, hour) {
                        (false, 12) => 0,
                        (true, 12) => 12,
                        (true, hour) => hour + 12,
                        (false, hour) => hour,
                    };
                    true
                }
                Some(_) => false,
                None => hour < 24,
            };
            if valid && minute < 60 {
                return Some((hour, minute));
            }
        }
        index = cursor.max(index + 1);
    }
    None
}

/// The reset moment named in an error text, if any.
pub(super) fn parse_reset_text<Tz: TimeZone>(text: &str, now: &DateTime<Tz>) -> Option<i64> {
    let seconds = now.timestamp();
    let lower = text.to_lowercase();
    unix_stamp(&lower, seconds)
        .or_else(|| rfc3339_stamp(text))
        .or_else(|| relative_delay(&lower).map(|delay| seconds + delay))
        .or_else(|| {
            let (hour, minute) = clock_time(&lower)?;
            next_occurrence(now, hour, minute)
        })
        .filter(|at| *at > seconds - 3_600)
}

/// The latest reset among windows at or above `hold_percent` that have not reset yet.
pub(super) fn holding_until(
    windows: &[limits::WindowView],
    now: i64,
    hold_percent: u32,
) -> Option<i64> {
    windows
        .iter()
        .filter(|window| !window.reset && window.used_percent >= f64::from(hold_percent))
        .filter_map(|window| window.resets_at.filter(|at| *at > now))
        .max()
}

/// Budget hold for a `continue` job: the reset to wait for, when it is far enough away.
pub(super) fn hold_until(
    windows: &[limits::WindowView],
    now: i64,
    hold_percent: u32,
    hold_min_reset_minutes: u32,
) -> Option<i64> {
    holding_until(windows, now, hold_percent)
        .filter(|reset| reset - now > i64::from(hold_min_reset_minutes) * 60)
}

/// Warm jobs while holding: next at now + min((reset − now)/2, max), repeated while the reset
/// is more than ten minutes after the next one.
pub(super) fn warm_schedule(now: i64, reset: i64, max_interval_minutes: u32) -> Vec<i64> {
    let max_interval = i64::from(max_interval_minutes.max(1)) * 60;
    let mut times = Vec::new();
    let mut at = now;
    while times.len() < 64 {
        let next = at + ((reset - at) / 2).min(max_interval);
        if reset - next <= 600 || next <= at {
            break;
        }
        times.push(next);
        at = next;
    }
    times
}

/// When to continue after a rate-limit error.
pub(super) fn rate_limit_resume_at<Tz: TimeZone>(
    text: &str,
    now: &DateTime<Tz>,
    windows: &[limits::WindowView],
    hold_percent: u32,
) -> i64 {
    let seconds = now.timestamp();
    let reset = parse_reset_text(text, now)
        .filter(|at| *at > seconds)
        .or_else(|| holding_until(windows, seconds, hold_percent))
        .unwrap_or(seconds + RATE_LIMIT_FALLBACK);
    reset + AFTER_RESET
}

fn short_title(snapshot: &Value) -> String {
    nonempty(&snapshot["title"])
        .map_or_else(|| "тред".to_owned(), |title| truncate_chars(title, 60))
}

fn local_clock(at: i64) -> String {
    let Some(moment) = Local.timestamp_opt(at, 0).single() else {
        return String::new();
    };
    if moment.date_naive() == Local::now().date_naive() {
        moment.format("%H:%M").to_string()
    } else {
        moment.format("%d.%m %H:%M").to_string()
    }
}

enum Outcome {
    Sent,
    Defer {
        at: i64,
        action: &'static str,
        detail: String,
        counted: bool,
        reason: Option<&'static str>,
    },
    Drop {
        action: &'static str,
        detail: String,
        push: Option<String>,
    },
}

fn defer(seconds: i64, action: &'static str, detail: impl Into<String>) -> Outcome {
    Outcome::Defer {
        at: now_seconds() + seconds,
        action,
        detail: detail.into(),
        counted: true,
        reason: None,
    }
}

fn drop_job(action: &'static str, detail: impl Into<String>, push: Option<String>) -> Outcome {
    Outcome::Drop {
        action,
        detail: detail.into(),
        push,
    }
}

fn bad_request() -> (StatusCode, Result<Value, Value>) {
    (
        StatusCode::BAD_REQUEST,
        Err(json!({"code": "INVALID_REQUEST"})),
    )
}

fn log_entry(
    target_id: &str,
    thread_id: &str,
    action: &str,
    reason: &str,
    detail: &str,
) -> LogEntry {
    LogEntry {
        at: now_seconds(),
        target_id: target_id.to_owned(),
        thread_id: thread_id.to_owned(),
        action: action.to_owned(),
        reason: reason.chars().take(32).collect(),
        detail: detail.chars().take(64).collect(),
    }
}

fn agent_of(snapshot: &Value) -> Option<&'static str> {
    limits::agent_key(
        snapshot["agent"]["id"].as_str().unwrap_or(""),
        snapshot["agent"]["name"].as_str().unwrap_or(""),
    )
}

impl Gateway {
    pub(super) async fn native_call(
        &self,
        target_id: &str,
        method: &str,
        params: Value,
        request_id: Option<&str>,
    ) -> Result<Value, String> {
        let request = json!({
            "version": 1,
            "request_id": request_id.map_or_else(|| Uuid::new_v4().to_string(), str::to_owned),
            "method": method,
            "params": params,
        });
        match self.probe(Some(target_id), &request).await {
            Ok(response) => match response.get("result") {
                Some(result) if response.get("error").is_none_or(Value::is_null) => {
                    Ok(result.clone())
                }
                _ => Err(response["error"]["code"]
                    .as_str()
                    .or_else(|| response["error"].as_str())
                    .unwrap_or("UNKNOWN")
                    .chars()
                    .take(48)
                    .collect()),
            },
            Err(_) => Err("TRANSPORT".to_owned()),
        }
    }

    async fn autopilot_push(
        &self,
        target_id: &str,
        thread_id: &str,
        snapshot: &Value,
        body: String,
    ) {
        let (title, subtitle) = push_heading(snapshot, snapshot);
        self.notify_all(&PushMessage {
            title,
            subtitle,
            body,
            event: NotificationEvent::Autopilot,
            target_id: target_id.to_owned(),
            thread_id: thread_id.to_owned(),
            instance_id: snapshot["instance_id"].as_str().unwrap_or("").to_owned(),
            epoch: snapshot["epoch"].as_str().unwrap_or("").to_owned(),
            project_id: nonempty(&snapshot["project_id"]).map(str::to_owned),
            host_id: nonempty(&snapshot["host_id"]).map(str::to_owned),
        })
        .await;
    }

    /// Appends to the recent log in `state.json` and to the history database.
    async fn autopilot_log(&self, entry: LogEntry) {
        let row = db::LogRow {
            at: entry.at,
            target_id: entry.target_id.clone(),
            thread_id: entry.thread_id.clone(),
            action: entry.action.clone(),
            reason: entry.reason.clone(),
            detail: entry.detail.clone(),
        };
        self.mutate_persisted(|state| state.autopilot.push_log(entry))
            .await;
        self.0
            .database
            .run(move |connection| db::insert_log(connection, &row))
            .await;
    }

    async fn job_log(&self, job: &Job, action: &str, detail: &str) {
        self.autopilot_log(log_entry(
            &job.target_id,
            &job.thread_id,
            action,
            &job.reason,
            detail,
        ))
        .await;
    }

    /// Adds an automatic continue job unless the thread already has one.
    async fn schedule_auto_continue(
        &self,
        target_id: &str,
        thread_id: &str,
        at: i64,
        reason: &str,
    ) -> bool {
        self.change_persisted(|state| {
            let autopilot = &mut state.autopilot;
            if autopilot.jobs.iter().any(|job| {
                job.target_id == target_id && job.thread_id == thread_id && job.kind == "continue"
            }) {
                return (false, false);
            }
            let text = autopilot.settings.continue_text.clone();
            let added = autopilot.add_job(new_job(
                target_id,
                thread_id,
                "continue",
                at,
                &text,
                reason,
                now_seconds(),
            ));
            (added, added)
        })
        .await
    }

    async fn autopilot_active(&self, target_id: &str, thread_id: &str) -> (bool, Settings) {
        let persisted = self.0.persisted.lock().await;
        (
            persisted.autopilot.active(target_id, thread_id),
            persisted.autopilot.settings.clone(),
        )
    }

    /// Monitor hook for a detected agent event: stop reasons and errors.
    pub(super) async fn autopilot_observe(
        &self,
        target_id: &str,
        thread_id: &str,
        event: NotificationEvent,
        stop_reason: Option<&str>,
        snapshot: &Value,
    ) {
        let (active, settings) = self.autopilot_active(target_id, thread_id).await;
        if !active {
            return;
        }
        let now = now_seconds();
        if stop_reason == Some("max_turn_requests") {
            if self
                .schedule_auto_continue(target_id, thread_id, now + SOON, "max_turn_requests")
                .await
            {
                self.autopilot_log(log_entry(
                    target_id,
                    thread_id,
                    "scheduled",
                    "max_turn_requests",
                    "",
                ))
                .await;
            }
            return;
        }
        if event != NotificationEvent::Error {
            return;
        }
        // The error text is only classified here; it is never logged or stored.
        let error = &snapshot["agent_error"];
        let text = ["kind", "title", "message"]
            .iter()
            .filter_map(|field| error[*field].as_str())
            .collect::<Vec<_>>()
            .join(" ");
        if !looks_like_rate_limit(&text) {
            return;
        }
        let windows = self.agent_windows(agent_of(snapshot)).await;
        let at = rate_limit_resume_at(&text, &Local::now(), &windows, settings.hold_percent);
        if self
            .schedule_auto_continue(target_id, thread_id, at, "rate_limit")
            .await
        {
            self.autopilot_log(log_entry(
                target_id,
                thread_id,
                "scheduled",
                "rate_limit",
                &format!("at {}", local_clock(at)),
            ))
            .await;
        }
    }

    /// Monitor hook: a Generating thread without new events for `stall_minutes`.
    pub(super) async fn autopilot_stalled(
        &self,
        target_id: &str,
        thread_id: &str,
        snapshot: &Value,
    ) {
        if !self.autopilot_active(target_id, thread_id).await.0 {
            return;
        }
        let cancelled = match snapshot["current_turn_id"].as_u64() {
            Some(turn_id) => self
                .native_call(
                    target_id,
                    "thread.cancel",
                    json!({"instance_id": snapshot["instance_id"], "epoch": snapshot["epoch"],
                        "thread_id": thread_id, "turn_id": turn_id}),
                    None,
                )
                .await
                .map(|_| ()),
            None => Err("NO_TURN".to_owned()),
        };
        match cancelled {
            Ok(()) => {
                self.autopilot_log(log_entry(
                    target_id,
                    thread_id,
                    "stall_cancelled",
                    "stalled",
                    "",
                ))
                .await;
            }
            Err(code) => {
                self.autopilot_log(log_entry(
                    target_id,
                    thread_id,
                    "failed",
                    "stalled",
                    &format!("cancel {code}"),
                ))
                .await;
                return;
            }
        }
        self.schedule_auto_continue(target_id, thread_id, now_seconds() + SOON, "stalled")
            .await;
    }

    /// The user (phone send or a message typed in Zed) or a warm ping started a turn: a hard
    /// stop leaves it alone for a while.
    pub(super) fn autopilot_exempt_turns(&self, target_id: &str, thread_id: &str) {
        if let Ok(mut runtime) = self.0.autopilot_runtime.lock() {
            let now = Instant::now();
            runtime.exempt_until.retain(|_, until| *until > now);
            runtime
                .exempt_until
                .insert(remote_thread_key(target_id, thread_id), now + USER_OVERRIDE);
        }
    }

    /// Monitor hook for a Generating thread: at ≥ `stop_percent` with a distant reset the
    /// turn is cancelled and a continue job waits for the reset (wave 3 §6.2).
    pub(super) async fn autopilot_budget_stop(
        &self,
        target_id: &str,
        thread_id: &str,
        snapshot: &Value,
    ) {
        let Some(turn_id) = snapshot["current_turn_id"].as_u64() else {
            return;
        };
        let (active, settings) = self.autopilot_active(target_id, thread_id).await;
        if !active {
            return;
        }
        let windows = self.agent_windows(agent_of(snapshot)).await;
        let now = now_seconds();
        let Some(reset) = hold_until(
            &windows,
            now,
            settings.stop_percent,
            settings.hold_min_reset_minutes,
        ) else {
            return;
        };
        let key = remote_thread_key(target_id, thread_id);
        {
            let Ok(mut runtime) = self.0.autopilot_runtime.lock() else {
                return;
            };
            if runtime
                .exempt_until
                .get(&key)
                .is_some_and(|until| *until > Instant::now())
                || runtime.stopped_turns.get(&key) == Some(&turn_id)
            {
                return;
            }
            if runtime.stopped_turns.len() > 1024 {
                runtime.stopped_turns.clear();
            }
            runtime.stopped_turns.insert(key.clone(), turn_id);
        }
        let used = windows
            .iter()
            .filter(|window| !window.reset)
            .map(|window| window.used_percent)
            .fold(0.0_f64, f64::max);
        let cancelled = self
            .native_call(
                target_id,
                "thread.cancel",
                json!({"instance_id": snapshot["instance_id"], "epoch": snapshot["epoch"],
                    "thread_id": thread_id, "turn_id": turn_id}),
                None,
            )
            .await;
        if let Err(code) = cancelled {
            self.autopilot_log(log_entry(
                target_id,
                thread_id,
                "failed",
                "budget_stop",
                &format!("cancel {code}"),
            ))
            .await;
            return;
        }
        self.autopilot_log(log_entry(
            target_id,
            thread_id,
            "stopped",
            "budget_stop",
            &format!("{used:.0}%"),
        ))
        .await;
        self.schedule_auto_continue(target_id, thread_id, reset + AFTER_RESET, "budget_stop")
            .await;
        let first_push = self.0.autopilot_runtime.lock().is_ok_and(|mut runtime| {
            if runtime.stop_pushed.len() > 1024 {
                runtime.stop_pushed.clear();
            }
            runtime.stop_pushed.insert(key, reset) != Some(reset)
        });
        if first_push {
            self.autopilot_push(
                target_id,
                thread_id,
                snapshot,
                format!(
                    "Автопилот: остановил «{}» на {used:.0} %, продолжу после сброса в {}",
                    short_title(snapshot),
                    local_clock(reset + AFTER_RESET)
                ),
            )
            .await;
        }
    }

    pub(super) async fn autopilot_runner(&self) {
        let mut interval = tokio::time::interval(JOB_POLL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let now = now_seconds();
            let due = self
                .0
                .persisted
                .lock()
                .await
                .autopilot
                .jobs
                .iter()
                .filter(|job| job.at <= now)
                .cloned()
                .collect::<Vec<_>>();
            for job in due {
                let (settings, active) = {
                    let persisted = self.0.persisted.lock().await;
                    // Cancelled meanwhile?
                    if !persisted
                        .autopilot
                        .jobs
                        .iter()
                        .any(|item| item.job_id == job.job_id)
                    {
                        continue;
                    }
                    (
                        persisted.autopilot.settings.clone(),
                        persisted.autopilot.active(&job.target_id, &job.thread_id),
                    )
                };
                let mut snapshot = Value::Null;
                let outcome = if job.reason != "user" && !active {
                    drop_job("skipped", "autopilot_off", None)
                } else {
                    self.run_job(&job, &settings, &mut snapshot).await
                };
                self.finish_job(&job, outcome, &snapshot).await;
            }
        }
    }

    async fn finish_job(&self, job: &Job, outcome: Outcome, snapshot: &Value) {
        let title = short_title(snapshot);
        let mut push = None;
        match outcome {
            Outcome::Sent => {
                self.mutate_persisted(|state| {
                    state
                        .autopilot
                        .jobs
                        .retain(|item| item.job_id != job.job_id);
                })
                .await;
            }
            Outcome::Drop {
                action,
                detail,
                push: message,
            } => {
                push = message;
                self.mutate_persisted(|state| {
                    state
                        .autopilot
                        .jobs
                        .retain(|item| item.job_id != job.job_id);
                })
                .await;
                self.job_log(job, action, &detail).await;
            }
            Outcome::Defer {
                at,
                action,
                detail,
                counted,
                reason,
            } => {
                let exhausted = counted && job.attempts + 1 >= MAX_DEFERS;
                self.mutate_persisted(|state| {
                    if exhausted {
                        state
                            .autopilot
                            .jobs
                            .retain(|item| item.job_id != job.job_id);
                        return;
                    }
                    if let Some(item) = state
                        .autopilot
                        .jobs
                        .iter_mut()
                        .find(|item| item.job_id == job.job_id)
                    {
                        item.at = at;
                        if counted {
                            item.attempts += 1;
                        }
                        if let Some(reason) = reason {
                            item.reason = reason.to_owned();
                        }
                    }
                    state.autopilot.jobs.sort_by_key(|item| item.at);
                })
                .await;
                if exhausted {
                    self.job_log(job, "failed", &format!("gave up: {detail}"))
                        .await;
                    push = Some(format!("Автопилот: не удалось продолжить «{title}»"));
                } else {
                    self.job_log(job, action, &detail).await;
                }
            }
        }
        if let Some(body) = push {
            self.autopilot_push(&job.target_id, &job.thread_id, snapshot, body)
                .await;
        }
    }

    /// Step 1: the bridge must be up; start or restart Zed when the settings allow it.
    async fn ensure_bridge(
        &self,
        job: &Job,
        target: &ProbeTarget,
        settings: &Settings,
    ) -> Result<(), Outcome> {
        let check = self.check_bridge(target).await;
        match check.state {
            zed_control::BridgeState::Up => return Ok(()),
            zed_control::BridgeState::Down => {
                if !settings.allow_zed_start || target.zed_unit.is_none() {
                    return Err(defer(ZED_DEFER, "skipped", "zed_down"));
                }
                let (_, result) = self
                    .zed_rpc("zed.start", Some(&target.id), &json!({}))
                    .await;
                if let Err(error) = result {
                    let code = error["code"].as_str().unwrap_or("START_FAILED").to_owned();
                    return Err(defer(ZED_DEFER, "failed", code));
                }
                self.job_log(job, "zed_started", "zed_down").await;
            }
            zed_control::BridgeState::Hung => {
                if !settings.allow_zed_restart || target.zed_unit.is_none() {
                    return Err(defer(ZED_DEFER, "skipped", "zed_hung"));
                }
                let (_, result) = self
                    .zed_rpc("zed.restart", Some(&target.id), &json!({"force": false}))
                    .await;
                if let Err(error) = result {
                    let code = error["code"]
                        .as_str()
                        .unwrap_or("RESTART_FAILED")
                        .to_owned();
                    return Err(defer(ZED_DEFER, "failed", code));
                }
                self.job_log(job, "zed_restarted", "zed_hung").await;
            }
        }
        let deadline = Instant::now() + BRIDGE_WAIT;
        while Instant::now() < deadline {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if self.check_bridge(target).await.state == zed_control::BridgeState::Up {
                return Ok(());
            }
        }
        Err(defer(ZED_DEFER, "failed", "bridge_timeout"))
    }

    /// Step 2: the thread's snapshot, opening the thread when it is not loaded.
    async fn job_snapshot(
        &self,
        job: &Job,
        instance: &Value,
        epoch: &Value,
    ) -> Result<Value, Outcome> {
        let params = json!({"thread_id": job.thread_id, "tail_entry_count": 8});
        let first = self
            .native_call(&job.target_id, "thread.snapshot", params.clone(), None)
            .await;
        let missing = |code: &str| {
            drop_job(
                "failed",
                code.to_owned(),
                Some("Автопилот: тред не найден, задание снято".to_owned()),
            )
        };
        match first {
            Ok(snapshot) => return Ok(snapshot),
            Err(code) if code == "THREAD_NOT_LOADED" => {}
            Err(code) if code == "THREAD_NOT_EXPOSED" || code == "THREAD_NOT_FOUND" => {
                return Err(missing(&code));
            }
            Err(code) => return Err(defer(NOT_READY_DEFER, "deferred", code)),
        }
        if let Err(code) = self
            .native_call(
                &job.target_id,
                "thread.open",
                json!({"instance_id": instance, "epoch": epoch, "thread_id": job.thread_id}),
                None,
            )
            .await
        {
            if code == "THREAD_NOT_FOUND" {
                return Err(missing(&code));
            }
            return Err(defer(NOT_READY_DEFER, "deferred", format!("open {code}")));
        }
        let deadline = Instant::now() + THREAD_OPEN_WAIT;
        while Instant::now() < deadline {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if let Ok(snapshot) = self
                .native_call(&job.target_id, "thread.snapshot", params.clone(), None)
                .await
            {
                return Ok(snapshot);
            }
        }
        Err(defer(NOT_READY_DEFER, "deferred", "thread_loading"))
    }

    async fn run_job(&self, job: &Job, settings: &Settings, snapshot_out: &mut Value) -> Outcome {
        let Ok(target) = self.target(Some(&job.target_id)).cloned() else {
            return drop_job("failed", "unknown_target", None);
        };
        if let Err(outcome) = self.ensure_bridge(job, &target, settings).await {
            return outcome;
        }
        let info = match self
            .native_call(&target.id, "instance.info", json!({}), None)
            .await
        {
            Ok(info) if info["instance_id"].is_string() && info["epoch"].is_string() => info,
            Ok(_) => return defer(NOT_READY_DEFER, "deferred", "instance_unavailable"),
            Err(code) => return defer(NOT_READY_DEFER, "deferred", code),
        };
        let (instance, epoch) = (&info["instance_id"], &info["epoch"]);
        let snapshot = match self.job_snapshot(job, instance, epoch).await {
            Ok(snapshot) => snapshot,
            Err(outcome) => return outcome,
        };
        if &snapshot["instance_id"] != instance || &snapshot["epoch"] != epoch {
            return defer(NOT_READY_DEFER, "deferred", "instance_changed");
        }
        *snapshot_out = snapshot.clone();
        let title = short_title(&snapshot);

        // Step 3: Idle, nothing waiting for the user.
        let inputs = self
            .native_call(
                &target.id,
                "thread.elicitations",
                json!({"thread_id": job.thread_id, "instance_id": instance, "epoch": epoch}),
                None,
            )
            .await
            .ok()
            .and_then(|result| {
                result["elicitations"]
                    .as_array()
                    .map(|rows| rows.iter().filter(|row| row["status"] == "pending").count())
            })
            .unwrap_or(0);
        if !pending_approval_keys(&snapshot).is_empty() || inputs > 0 {
            if job.attempts == 0 {
                self.autopilot_push(
                    &job.target_id,
                    &job.thread_id,
                    &snapshot,
                    format!("Автопилот ждёт вашего ответа в «{title}»"),
                )
                .await;
            }
            return defer(NOT_READY_DEFER, "deferred", "waiting_user");
        }
        if snapshot["status"] != "Idle" || !snapshot["current_turn_id"].is_null() {
            return defer(NOT_READY_DEFER, "deferred", "busy");
        }

        // Step 4: budget hold.
        let now = now_seconds();
        let windows = self.agent_windows(agent_of(&snapshot)).await;
        if job.kind == "warm" {
            if windows
                .iter()
                .any(|window| !window.reset && window.used_percent >= WARM_MAX_PERCENT)
            {
                return drop_job("skipped", "budget_99", None);
            }
            if holding_until(&windows, now, settings.hold_percent).is_none() {
                return drop_job("skipped", "no_hold", None);
            }
        } else if let Some(reset) = hold_until(
            &windows,
            now,
            settings.hold_percent,
            settings.hold_min_reset_minutes,
        ) {
            if settings.warm_enabled {
                let warm_text = settings.warm_text.clone();
                self.mutate_persisted(|state| {
                    let autopilot = &mut state.autopilot;
                    autopilot.jobs.retain(|item| {
                        !(item.kind == "warm"
                            && item.target_id == job.target_id
                            && item.thread_id == job.thread_id)
                    });
                    for at in warm_schedule(now, reset, settings.warm_max_interval_minutes) {
                        autopilot.add_job(new_job(
                            &job.target_id,
                            &job.thread_id,
                            "warm",
                            at,
                            &warm_text,
                            "warm",
                            now,
                        ));
                    }
                })
                .await;
            }
            return Outcome::Defer {
                at: reset + AFTER_RESET,
                action: "deferred",
                detail: format!("until {}", local_clock(reset)),
                counted: false,
                reason: Some("budget_hold"),
            };
        }

        // Step 5: daily limit (warm jobs count too).
        let day = today();
        let (over_limit, notify) = self
            .mutate_persisted(|state| {
                let limit = state.autopilot.settings.daily_limit;
                let flags = state
                    .autopilot
                    .flags_mut(&job.target_id, &job.thread_id, &day);
                let over = flags.actions_today >= limit;
                let notify = over && flags.limit_notified.as_deref() != Some(day.as_str());
                if notify {
                    flags.limit_notified = Some(day.clone());
                }
                (over, notify)
            })
            .await;
        if over_limit {
            return drop_job(
                "skipped",
                "daily_limit",
                notify.then(|| format!("Автопилот: дневной лимит автодействий для «{title}»")),
            );
        }

        // Step 6: send, as the phone would.
        if job.kind == "warm" {
            self.autopilot_exempt_turns(&target.id, &job.thread_id);
        }
        let sent = self
            .native_call(
                &target.id,
                "thread.send",
                json!({"instance_id": instance, "epoch": epoch,
                    "thread_id": job.thread_id, "text": job.text}),
                Some(&job.request_id),
            )
            .await;
        let delivered = match sent {
            Ok(_) => true,
            Err(code) if code == "TRANSPORT" => self
                .native_call(
                    &target.id,
                    "request.status",
                    json!({"instance_id": instance, "epoch": epoch,
                        "original_request_id": job.request_id}),
                    None,
                )
                .await
                .is_ok_and(|status| status["known"] == true),
            Err(code)
                if matches!(
                    code.as_str(),
                    "INSTANCE_UNAVAILABLE" | "RATE_LIMITED" | "BUSY"
                ) =>
            {
                return defer(NOT_READY_DEFER, "deferred", code);
            }
            Err(code) => {
                return drop_job(
                    "failed",
                    code,
                    Some(format!("Автопилот: не удалось отправить в «{title}»")),
                );
            }
        };
        if !delivered {
            // Unknown delivery stays unknown: never resend blindly.
            return drop_job(
                "failed",
                "delivery_unknown",
                Some(format!(
                    "Автопилот: неизвестно, дошло ли сообщение в «{title}»"
                )),
            );
        }
        self.set_remote_thread(&target.id, &job.thread_id, true)
            .await;
        let (action, body) = if job.kind == "warm" {
            ("warmed", format!("Автопилот: прогрел «{title}»"))
        } else {
            ("continued", format!("Автопилот: продолжил «{title}»"))
        };
        self.mutate_persisted(|state| {
            state
                .autopilot
                .flags_mut(&job.target_id, &job.thread_id, &day)
                .actions_today += 1;
        })
        .await;
        self.job_log(job, action, "").await;
        self.autopilot_push(&job.target_id, &job.thread_id, &snapshot, body)
            .await;
        Outcome::Sent
    }

    /// `autopilot.status|schedule|cancel|thread|settings|history`.
    pub(super) async fn autopilot_rpc(
        &self,
        method: &str,
        target_id: Option<&str>,
        params: &Value,
    ) -> (StatusCode, Result<Value, Value>) {
        if !params.is_object() && !params.is_null() {
            return bad_request();
        }
        let target = || {
            self.target(params["target_id"].as_str().or(target_id))
                .map(|target| target.id.clone())
        };
        match method {
            "autopilot.status" => (
                StatusCode::OK,
                Ok(self.0.persisted.lock().await.autopilot.status()),
            ),
            "autopilot.schedule" => {
                let Ok(target_id) = target() else {
                    return unknown_target();
                };
                let Some(thread_id) = valid_thread_id(&params["thread_id"]) else {
                    return bad_request();
                };
                let now = now_seconds();
                let Some(at) = params["at"].as_i64() else {
                    return bad_request();
                };
                if at <= now || at > now + SCHEDULE_HORIZON {
                    return bad_request();
                }
                let text = match params.get("text").filter(|text| !text.is_null()) {
                    None => None,
                    Some(text) => match text.as_str().filter(|text| valid_job_text(text)) {
                        Some(text) => Some(text.to_owned()),
                        None => return bad_request(),
                    },
                };
                self.schedule_user_job(&target_id, thread_id, at, text)
                    .await
            }
            "autopilot.cancel" => {
                let Some(job_id) = params["job_id"]
                    .as_str()
                    .and_then(|id| Uuid::parse_str(id).ok())
                else {
                    return bad_request();
                };
                let cancelled = self
                    .change_persisted(|state| {
                        let job = state
                            .autopilot
                            .jobs
                            .iter()
                            .position(|job| job.job_id == job_id)
                            .map(|index| state.autopilot.jobs.remove(index));
                        (job.is_some(), job)
                    })
                    .await;
                if let Some(job) = &cancelled {
                    self.job_log(job, "cancelled", "user").await;
                }
                (
                    StatusCode::OK,
                    Ok(json!({"cancelled": cancelled.is_some()})),
                )
            }
            "autopilot.thread" => {
                let Ok(target_id) = target() else {
                    return unknown_target();
                };
                let Some(thread_id) = valid_thread_id(&params["thread_id"]) else {
                    return bad_request();
                };
                match params.get("auto_continue").filter(|value| !value.is_null()) {
                    None => {}
                    Some(Value::Bool(enabled)) => {
                        self.set_auto_continue(&target_id, thread_id, *enabled)
                            .await;
                    }
                    Some(_) => return bad_request(),
                }
                (
                    StatusCode::OK,
                    Ok(self.thread_status(&target_id, thread_id).await),
                )
            }
            "autopilot.settings" => {
                let current = self.0.persisted.lock().await.autopilot.settings.clone();
                let Some(settings) = updated_settings(&current, params) else {
                    return bad_request();
                };
                let saved = settings.clone();
                self.mutate_persisted(|state| state.autopilot.settings = saved)
                    .await;
                (StatusCode::OK, Ok(json!({"settings": settings})))
            }
            "autopilot.history" => {
                let target_id = match params.get("target_id").filter(|value| !value.is_null()) {
                    None => None,
                    Some(_) => match target() {
                        Ok(target_id) => Some(target_id),
                        Err(_) => return unknown_target(),
                    },
                };
                let thread_id = match params.get("thread_id").filter(|value| !value.is_null()) {
                    None => None,
                    Some(value) => match valid_thread_id(value) {
                        Some(thread_id) => Some(thread_id.to_owned()),
                        None => return bad_request(),
                    },
                };
                let optional_number = |name: &str| match params.get(name).filter(|v| !v.is_null()) {
                    None => Ok(None),
                    Some(value) => value.as_i64().map(Some).ok_or(()),
                };
                let (Ok(before), Ok(before_id), Ok(limit)) = (
                    optional_number("before"),
                    optional_number("before_id"),
                    optional_number("limit"),
                ) else {
                    return bad_request();
                };
                let limit = limit.unwrap_or(50);
                if !(1..=200).contains(&limit) {
                    return bad_request();
                }
                let query = db::HistoryQuery {
                    target_id,
                    thread_id,
                    before,
                    before_id,
                    limit: limit as u32,
                };
                let rows = {
                    let query = query.clone();
                    self.0
                        .database
                        .run(move |connection| db::history(connection, &query))
                        .await
                };
                match rows {
                    Some(rows) => (StatusCode::OK, Ok(rows)),
                    // Without the database only the recent log in state.json is there.
                    None => (
                        StatusCode::OK,
                        Ok(self
                            .0
                            .persisted
                            .lock()
                            .await
                            .autopilot
                            .recent_history(&query)),
                    ),
                }
            }
            _ => (
                StatusCode::FORBIDDEN,
                Err(json!({"code": "UNSUPPORTED_CAPABILITY"})),
            ),
        }
    }

    async fn thread_status(&self, target_id: &str, thread_id: &str) -> Value {
        let persisted = self.0.persisted.lock().await;
        let autopilot = &persisted.autopilot;
        let day = today();
        let mut flags = autopilot
            .flags(target_id, thread_id)
            .cloned()
            .unwrap_or_else(|| default_flags(target_id, thread_id, &day));
        if flags.day != day {
            flags.day = day;
            flags.actions_today = 0;
        }
        let jobs = autopilot
            .jobs
            .iter()
            .filter(|job| job.target_id == target_id && job.thread_id == thread_id)
            .collect::<Vec<_>>();
        json!({
            "thread": flags,
            "enabled": autopilot.settings.enabled,
            "active": autopilot.active(target_id, thread_id),
            "daily_limit": autopilot.settings.daily_limit,
            "jobs": jobs,
        })
    }

    async fn schedule_user_job(
        &self,
        target_id: &str,
        thread_id: &str,
        at: i64,
        text: Option<String>,
    ) -> (StatusCode, Result<Value, Value>) {
        let job = self
            .change_persisted(|state| {
                let autopilot = &mut state.autopilot;
                let text = text.unwrap_or_else(|| autopilot.settings.continue_text.clone());
                let job = new_job(
                    target_id,
                    thread_id,
                    "continue",
                    at,
                    &text,
                    "user",
                    now_seconds(),
                );
                let added = autopilot.add_job(job.clone());
                (added, added.then_some(job))
            })
            .await;
        match job {
            Some(job) => {
                self.job_log(&job, "scheduled", &format!("at {}", local_clock(at)))
                    .await;
                (StatusCode::OK, Ok(json!({"job": job})))
            }
            None => (
                StatusCode::TOO_MANY_REQUESTS,
                Err(json!({"code": "RATE_LIMITED"})),
            ),
        }
    }

    async fn set_auto_continue(
        &self,
        target_id: &str,
        thread_id: &str,
        enabled: bool,
    ) -> ThreadFlags {
        let day = today();
        let flags = self
            .mutate_persisted(|state| {
                let autopilot = &mut state.autopilot;
                if !enabled {
                    // Automatic jobs of this thread go; times the user set stay.
                    autopilot.jobs.retain(|job| {
                        !(job.target_id == target_id
                            && job.thread_id == thread_id
                            && job.reason != "user")
                    });
                }
                let flags = autopilot.flags_mut(target_id, thread_id, &day);
                flags.auto_continue = enabled;
                flags.clone()
            })
            .await;
        self.autopilot_log(log_entry(
            target_id,
            thread_id,
            if enabled { "auto_on" } else { "auto_off" },
            "user",
            "",
        ))
        .await;
        flags
    }

    /// A phone `thread.send` whose text is `/auto …`: handled here, never sent to the agent.
    pub(super) async fn autopilot_command(
        &self,
        target_id: &str,
        thread_id: &str,
        command: AutoCommand,
    ) -> Result<String, &'static str> {
        match command {
            AutoCommand::On => {
                self.set_auto_continue(target_id, thread_id, true).await;
                let enabled = self.0.persisted.lock().await.autopilot.settings.enabled;
                Ok(if enabled {
                    "Автопродолжение включено для этого треда".into()
                } else {
                    "Автопродолжение включено для этого треда, но автопилот выключен в настройках"
                        .into()
                })
            }
            AutoCommand::Off => {
                self.set_auto_continue(target_id, thread_id, false).await;
                Ok("Автопродолжение выключено для этого треда".into())
            }
            AutoCommand::At(hour, minute) => {
                let at = next_occurrence(&Local::now(), hour, minute).ok_or("INVALID_REQUEST")?;
                match self.schedule_user_job(target_id, thread_id, at, None).await {
                    (_, Ok(_)) => Ok(format!("Продолжу в {}", local_clock(at))),
                    (_, Err(_)) => Err("RATE_LIMITED"),
                }
            }
            AutoCommand::Status => {
                let persisted = self.0.persisted.lock().await;
                let autopilot = &persisted.autopilot;
                let flags = autopilot.flags(target_id, thread_id);
                let day = today();
                let actions = flags
                    .filter(|flags| flags.day == day)
                    .map_or(0, |flags| flags.actions_today);
                let jobs = autopilot
                    .jobs
                    .iter()
                    .filter(|job| job.target_id == target_id && job.thread_id == thread_id)
                    .collect::<Vec<_>>();
                let state = if !autopilot.settings.enabled {
                    "выключен в настройках"
                } else if autopilot.auto_continue(target_id, thread_id) {
                    "включено"
                } else {
                    "выключено"
                };
                let mut message = format!("Автопродолжение {state}. Заданий: {}", jobs.len());
                if let Some(next) = jobs.iter().map(|job| job.at).min() {
                    message.push_str(&format!(", ближайшее в {}", local_clock(next)));
                }
                message.push_str(&format!(
                    ". Автодействий сегодня: {actions} из {}. Команды: /auto on, /auto off, /auto at ЧЧ:ММ, /auto status",
                    autopilot.settings.daily_limit
                ));
                Ok(message)
            }
        }
    }
}

fn unknown_target() -> (StatusCode, Result<Value, Value>) {
    (
        StatusCode::NOT_FOUND,
        Err(json!({"code": "UNKNOWN_TARGET"})),
    )
}

/// Applies a partial `autopilot.settings` request; `None` for unknown keys or bad values.
pub(super) fn updated_settings(current: &Settings, params: &Value) -> Option<Settings> {
    let mut settings = current.clone();
    let Some(changes) = params.as_object() else {
        return params.is_null().then_some(settings);
    };
    let number = |value: &Value, range: std::ops::RangeInclusive<u64>| {
        value
            .as_u64()
            .filter(|value| range.contains(value))
            .and_then(|value| u32::try_from(value).ok())
    };
    for (key, value) in changes {
        match key.as_str() {
            "continue_text" => {
                settings.continue_text = value
                    .as_str()
                    .filter(|text| valid_job_text(text))?
                    .to_owned();
            }
            "warm_text" => {
                settings.warm_text = value
                    .as_str()
                    .filter(|text| valid_job_text(text))?
                    .to_owned();
            }
            "enabled" => settings.enabled = value.as_bool()?,
            "daily_limit" => settings.daily_limit = number(value, 0..=50)?,
            "allow_zed_start" => settings.allow_zed_start = value.as_bool()?,
            "allow_zed_restart" => settings.allow_zed_restart = value.as_bool()?,
            "warm_enabled" => settings.warm_enabled = value.as_bool()?,
            "hold_percent" => settings.hold_percent = number(value, 50..=100)?,
            "stop_percent" => settings.stop_percent = number(value, 50..=100)?,
            "hold_min_reset_minutes" => settings.hold_min_reset_minutes = number(value, 0..=1440)?,
            "warm_max_interval_minutes" => {
                settings.warm_max_interval_minutes = number(value, 5..=240)?;
            }
            "stall_minutes" => settings.stall_minutes = number(value, 2..=240)?,
            _ => return None,
        }
    }
    (settings.hold_percent <= settings.stop_percent).then_some(settings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    fn at(text: &str) -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339(text).unwrap()
    }

    fn window(kind: &str, used: f64, resets_at: i64) -> limits::WindowView {
        limits::WindowView {
            kind: kind.into(),
            used_percent: used,
            resets_at: Some(resets_at),
            status: None,
            reset: false,
        }
    }

    #[test]
    fn parses_auto_commands() {
        assert_eq!(parse_auto("/auto continue"), Some(AutoCommand::On));
        assert_eq!(parse_auto("  /auto ON "), Some(AutoCommand::On));
        assert_eq!(parse_auto("/auto off"), Some(AutoCommand::Off));
        assert_eq!(parse_auto("/auto at 14:30"), Some(AutoCommand::At(14, 30)));
        assert_eq!(parse_auto("/auto at 7:05"), Some(AutoCommand::At(7, 5)));
        assert_eq!(parse_auto("/auto at 25:00"), Some(AutoCommand::Status));
        assert_eq!(parse_auto("/auto"), Some(AutoCommand::Status));
        assert_eq!(parse_auto("/auto status"), Some(AutoCommand::Status));
        assert_eq!(parse_auto("/auto whatever"), Some(AutoCommand::Status));
        assert_eq!(parse_auto("/autocomplete"), None);
        assert_eq!(parse_auto("please /auto on"), None);
        assert_eq!(parse_auto("продолжай"), None);
    }

    #[test]
    fn next_occurrence_is_today_or_tomorrow() {
        let now = at("2026-11-27T14:00:00+03:00");
        assert_eq!(
            next_occurrence(&now, 14, 30),
            Some(at("2026-11-27T14:30:00+03:00").timestamp())
        );
        assert_eq!(
            next_occurrence(&now, 9, 0),
            Some(at("2026-11-28T09:00:00+03:00").timestamp())
        );
        assert_eq!(
            next_occurrence(&now, 14, 0),
            Some(at("2026-11-28T14:00:00+03:00").timestamp())
        );
    }

    #[test]
    fn classifies_rate_limit_errors() {
        for text in [
            "rate_limit_exceeded Rate limit reached Anthropic's rate limit was reached.",
            "Claude AI usage limit reached|1795787661",
            "You've hit your usage limit. Try again at 3:45 PM.",
            "HTTP 429 Too Many Requests",
            "5-hour limit reached ∙ resets 3pm",
            "Достигнут лимит использования",
        ] {
            assert!(looks_like_rate_limit(text), "{text}");
        }
        for text in [
            "prompt_too_large Context too large",
            "authentication_required Authentication required",
            "The selected model refused this request.",
        ] {
            assert!(!looks_like_rate_limit(text), "{text}");
        }
    }

    #[test]
    fn parses_reset_moments_from_error_text() {
        let now = at("2026-11-27T14:00:00+03:00");
        let base = now.timestamp();
        assert_eq!(
            parse_reset_text("Claude AI usage limit reached|1795787661", &now),
            Some(1795787661)
        );
        assert_eq!(
            parse_reset_text("limit reached, resets at 2026-11-27T16:30:00Z.", &now),
            Some(at("2026-11-27T16:30:00Z").timestamp())
        );
        assert_eq!(
            parse_reset_text(
                "You've hit your usage limit, try again in 2 hours 5 minutes.",
                &now
            ),
            Some(base + 2 * 3600 + 5 * 60)
        );
        assert_eq!(
            parse_reset_text("usage limit; try again in 4h12m", &now),
            Some(base + 4 * 3600 + 12 * 60)
        );
        assert_eq!(
            parse_reset_text("Лимит исчерпан, попробуйте через 3 ч 10 мин", &now),
            Some(base + 3 * 3600 + 600)
        );
        assert_eq!(
            parse_reset_text("Try again at 3:45 PM.", &now),
            Some(at("2026-11-27T15:45:00+03:00").timestamp())
        );
        assert_eq!(
            parse_reset_text("5-hour limit reached ∙ resets 1am (Europe/Moscow)", &now),
            Some(at("2026-11-28T01:00:00+03:00").timestamp())
        );
        assert_eq!(
            parse_reset_text("лимит, сброс в 18:20", &now),
            Some(at("2026-11-27T18:20:00+03:00").timestamp())
        );
        assert_eq!(parse_reset_text("HTTP 429 Too Many Requests", &now), None);
        assert_eq!(
            parse_reset_text("rate limit reached in the API", &now),
            None
        );
    }

    #[test]
    fn rate_limit_resume_falls_back_to_limits_then_half_an_hour() {
        let now = at("2026-11-27T14:00:00+03:00");
        let base = now.timestamp();
        assert_eq!(
            rate_limit_resume_at("try again in 10 minutes", &now, &[], 95),
            base + 600 + 120
        );
        let windows = [
            window("five_hour", 97.0, base + 5000),
            window("seven_day", 40.0, base + 90_000),
        ];
        assert_eq!(
            rate_limit_resume_at("usage limit reached", &now, &windows, 95),
            base + 5000 + 120
        );
        assert_eq!(
            rate_limit_resume_at("usage limit reached", &now, &[], 95),
            base + 1800 + 120
        );
    }

    #[test]
    fn budget_hold_needs_a_full_window_with_a_distant_reset() {
        let now = 1_000_000;
        let full_far = [
            window("five_hour", 96.0, now + 7200),
            window("seven_day", 50.0, now + 90_000),
        ];
        assert_eq!(hold_until(&full_far, now, 95, 60), Some(now + 7200));
        let full_near = [window("five_hour", 96.0, now + 1800)];
        assert_eq!(hold_until(&full_near, now, 95, 60), None);
        assert_eq!(holding_until(&full_near, now, 95), Some(now + 1800));
        let below = [window("five_hour", 80.0, now + 7200)];
        assert_eq!(hold_until(&below, now, 95, 60), None);
        let mut reset = window("five_hour", 0.0, now - 10);
        reset.reset = true;
        assert_eq!(hold_until(&[reset], now, 95, 60), None);
        // Both windows full: wait for the later reset.
        let both = [
            window("five_hour", 99.0, now + 7200),
            window("seven_day", 100.0, now + 80_000),
        ];
        assert_eq!(hold_until(&both, now, 95, 60), Some(now + 80_000));
    }

    #[test]
    fn hard_stop_needs_stop_percent_and_a_distant_reset() {
        let now = 1_000_000;
        let settings = Settings::default();
        let stop = |windows: &[limits::WindowView]| {
            hold_until(
                windows,
                now,
                settings.stop_percent,
                settings.hold_min_reset_minutes,
            )
        };
        // 97 %: held (no automatic continues) but not stopped.
        let held = [window("five_hour", 97.0, now + 3 * 3600)];
        assert_eq!(stop(&held), None);
        assert_eq!(
            hold_until(
                &held,
                now,
                settings.hold_percent,
                settings.hold_min_reset_minutes
            ),
            Some(now + 3 * 3600)
        );
        assert_eq!(
            stop(&[window("five_hour", 98.0, now + 3 * 3600)]),
            Some(now + 3 * 3600)
        );
        // Reset within the hour: the turn may finish.
        assert_eq!(stop(&[window("five_hour", 99.5, now + 50 * 60)]), None);
        // The weekly window alone can stop too.
        assert_eq!(
            stop(&[
                window("five_hour", 10.0, now + 600),
                window("seven_day", 98.5, now + 86_400)
            ]),
            Some(now + 86_400)
        );
    }

    #[test]
    fn warm_jobs_halve_the_wait_with_a_cap() {
        let now = 0;
        // Reset in 4 h, cap 55 min: 55, 110, 165 min, then 165+min(37.5,55)=202.5 min (37.5 min
        // before reset), then 221.25 (18.75 min before), then 230.6 (9.4 min) stops.
        let times = warm_schedule(now, 4 * 3600, 55);
        assert_eq!(times, vec![3300, 6600, 9900, 12150, 13275]);
        assert!(times.iter().all(|at| 4 * 3600 - at > 600));
        // Reset in 70 min: first at 35 min (35 before reset), then 52.5 (17.5 before).
        assert_eq!(warm_schedule(now, 70 * 60, 55), vec![2100, 3150]);
        // Reset within 20 minutes: nothing.
        assert!(warm_schedule(now, 20 * 60, 55).is_empty());
    }

    #[test]
    fn settings_updates_are_validated() {
        let defaults = Settings::default();
        let updated = updated_settings(
            &defaults,
            &json!({"daily_limit": 3, "allow_zed_restart": true, "continue_text": "дальше"}),
        )
        .unwrap();
        assert_eq!(updated.daily_limit, 3);
        assert!(updated.allow_zed_restart);
        assert_eq!(updated.continue_text, "дальше");
        assert_eq!(updated.hold_percent, 95);
        assert!(updated_settings(&defaults, &json!({"daily_limit": 51})).is_none());
        assert!(updated_settings(&defaults, &json!({"hold_percent": 20})).is_none());
        assert!(updated_settings(&defaults, &json!({"hold_percent": 99})).is_none());
        let stop =
            updated_settings(&defaults, &json!({"stop_percent": 97, "enabled": false})).unwrap();
        assert_eq!(stop.stop_percent, 97);
        assert!(!stop.enabled);
        assert!(updated_settings(&defaults, &json!({"stop_percent": 90})).is_none());
        assert!(updated_settings(&defaults, &json!({"continue_text": "/compact"})).is_none());
        assert!(updated_settings(&defaults, &json!({"continue_text": "  "})).is_none());
        assert!(updated_settings(&defaults, &json!({"stall_minutes": "15"})).is_none());
        assert!(updated_settings(&defaults, &json!({"unknown": 1})).is_none());
        assert_eq!(
            updated_settings(&defaults, &json!({})),
            Some(defaults.clone())
        );
    }

    #[test]
    fn old_state_gets_default_autopilot_and_daily_counters_roll_over() {
        let state: AutopilotState = serde_json::from_value(json!({})).unwrap();
        assert_eq!(state.settings, Settings::default());
        assert!(state.settings.enabled);
        assert_eq!(state.settings.stop_percent, 98);
        // Older settings without the wave 3 §6 fields get their defaults.
        let old: AutopilotState =
            serde_json::from_value(json!({"settings": {"daily_limit": 2}})).unwrap();
        assert_eq!(old.settings.daily_limit, 2);
        assert!(old.settings.enabled);
        let mut state = state;
        // Every thread is on until switched off.
        assert!(state.auto_continue("d", "t"));
        assert!(state.active("d", "t"));
        state.flags_mut("d", "t", "2026-11-26").actions_today = 5;
        assert_eq!(state.flags_mut("d", "t", "2026-11-26").actions_today, 5);
        assert_eq!(state.flags_mut("d", "t", "2026-11-27").actions_today, 0);
        state.flags_mut("d", "t", "2026-11-27").auto_continue = false;
        assert!(!state.auto_continue("d", "t"));
        assert!(!state.active("d", "t"));
        state.settings.enabled = false;
        assert!(!state.active("d", "other"));
        let job = new_job("d", "t", "continue", 1, "x", "user", 0);
        assert!(job.request_id.starts_with("autopilot:"));
        for index in 0..60 {
            let mut entry = log_entry(
                "d",
                if index % 2 == 0 { "t" } else { "u" },
                "continued",
                "user",
                &format!("{index}"),
            );
            entry.at = index;
            state.push_log(entry);
        }
        assert_eq!(state.log.len(), MAX_LOG);
        assert_eq!(state.log[0].detail, "10");
        let recent = state.recent_history(&db::HistoryQuery {
            thread_id: Some("t".into()),
            before: Some(58),
            limit: 2,
            ..Default::default()
        });
        assert_eq!(recent["rows"][0]["detail"], "56");
        assert_eq!(recent["rows"][1]["detail"], "54");
    }

    #[test]
    fn explicit_off_records_outlive_default_ones() {
        let mut state = AutopilotState::default();
        state.flags_mut("d", "off", "2026-11-27").auto_continue = false;
        for index in 0..MAX_THREADS + 5 {
            state.flags_mut("d", &format!("t{index}"), "2026-11-27");
        }
        assert_eq!(state.threads.len(), MAX_THREADS);
        assert!(!state.auto_continue("d", "off"));
    }
}
