//! Gateway history database (`<state>/zedlink.sqlite`): per-turn token usage, limit samples
//! and the autopilot log. Only numbers, ids and short codes are stored — never transcript text
//! or thread titles. All access runs on blocking threads, never on the async runtime.

use super::*;
use rusqlite::{Connection, params};

const RETENTION_DAYS: i64 = 400;

const MIGRATIONS: &[&str] = &[
    // 1
    "CREATE TABLE turn_usage(
        target TEXT NOT NULL, thread TEXT NOT NULL, turn_key TEXT NOT NULL,
        agent TEXT NOT NULL, at INTEGER NOT NULL,
        input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL,
        cache_write INTEGER NOT NULL, thought INTEGER NOT NULL,
        PRIMARY KEY(target, thread, turn_key)) WITHOUT ROWID;
     CREATE INDEX turn_usage_at ON turn_usage(at);
     CREATE TABLE limit_samples(
        agent TEXT NOT NULL, kind TEXT NOT NULL, at INTEGER NOT NULL,
        used_percent REAL NOT NULL, resets_at INTEGER);
     CREATE INDEX limit_samples_agent_at ON limit_samples(agent, at);
     CREATE TABLE autopilot_log(
        id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
        target TEXT NOT NULL, thread TEXT NOT NULL, action TEXT NOT NULL,
        reason TEXT NOT NULL, detail TEXT NOT NULL);
     CREATE INDEX autopilot_log_thread ON autopilot_log(target, thread, at);
     CREATE INDEX autopilot_log_at ON autopilot_log(at);",
];

pub(super) fn migrate(connection: &mut Connection) -> rusqlite::Result<()> {
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    for (index, migration) in MIGRATIONS.iter().enumerate() {
        let target = index as i64 + 1;
        if version >= target {
            continue;
        }
        let transaction = connection.transaction()?;
        transaction.execute_batch(migration)?;
        transaction.pragma_update(None, "user_version", target)?;
        transaction.commit()?;
    }
    Ok(())
}

pub(super) fn open(path: &Path) -> Result<Connection> {
    let mut connection = Connection::open(path)?;
    fs::set_permissions(path, Permissions::from_mode(0o600))?;
    connection.busy_timeout(Duration::from_secs(5))?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    migrate(&mut connection)?;
    Ok(connection)
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct TurnUsage {
    pub(super) input: u64,
    pub(super) output: u64,
    pub(super) cache_read: u64,
    pub(super) cache_write: u64,
    pub(super) thought: u64,
}

impl TurnUsage {
    /// The bridge's `usage` object on a `turn.stopped` event; absent fields count as 0.
    pub(super) fn from_event(usage: &Value) -> Option<Self> {
        if !usage.is_object() {
            return None;
        }
        let field = |name: &str| usage[name].as_u64().unwrap_or(0);
        Some(Self {
            input: field("input_tokens"),
            output: field("output_tokens"),
            cache_read: field("cache_read_tokens"),
            cache_write: field("cache_write_tokens"),
            thought: field("thought_tokens"),
        })
    }
}

#[derive(Clone, Debug)]
pub(super) struct LogRow {
    pub(super) at: i64,
    pub(super) target_id: String,
    pub(super) thread_id: String,
    pub(super) action: String,
    pub(super) reason: String,
    pub(super) detail: String,
}

fn sql_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

pub(super) fn insert_turn(
    connection: &Connection,
    target_id: &str,
    thread_id: &str,
    turn_key: &str,
    agent: &str,
    at: i64,
    usage: &TurnUsage,
) -> rusqlite::Result<bool> {
    let inserted = connection.execute(
        "INSERT OR IGNORE INTO turn_usage
            (target, thread, turn_key, agent, at, input, output, cache_read, cache_write, thought)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            target_id,
            thread_id,
            turn_key,
            agent,
            at,
            sql_i64(usage.input),
            sql_i64(usage.output),
            sql_i64(usage.cache_read),
            sql_i64(usage.cache_write),
            sql_i64(usage.thought),
        ],
    )?;
    Ok(inserted > 0)
}

pub(super) fn insert_limit_sample(
    connection: &Connection,
    agent: &str,
    kind: &str,
    at: i64,
    used_percent: f64,
    resets_at: Option<i64>,
) -> rusqlite::Result<()> {
    connection.execute(
        "INSERT INTO limit_samples (agent, kind, at, used_percent, resets_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![agent, kind, at, used_percent, resets_at],
    )?;
    Ok(())
}

pub(super) fn insert_log(connection: &Connection, row: &LogRow) -> rusqlite::Result<i64> {
    connection.execute(
        "INSERT INTO autopilot_log (at, target, thread, action, reason, detail)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            row.at,
            row.target_id,
            row.thread_id,
            row.action,
            row.reason,
            row.detail
        ],
    )?;
    Ok(connection.last_insert_rowid())
}

pub(super) fn prune(connection: &Connection, now: i64) -> rusqlite::Result<usize> {
    let cutoff = now - RETENTION_DAYS * 86_400;
    let mut removed = 0;
    for table in ["turn_usage", "limit_samples", "autopilot_log"] {
        removed += connection.execute(&format!("DELETE FROM {table} WHERE at < ?1"), [cutoff])?;
    }
    Ok(removed)
}

#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct HistoryQuery {
    pub(super) target_id: Option<String>,
    pub(super) thread_id: Option<String>,
    pub(super) before: Option<i64>,
    pub(super) before_id: Option<i64>,
    pub(super) limit: u32,
}

pub(super) fn history(connection: &Connection, query: &HistoryQuery) -> rusqlite::Result<Value> {
    let mut statement = connection.prepare(
        "SELECT id, at, target, thread, action, reason, detail FROM autopilot_log
         WHERE (?1 IS NULL OR target = ?1) AND (?2 IS NULL OR thread = ?2)
           AND (?3 IS NULL OR at < ?3) AND (?4 IS NULL OR id < ?4)
         ORDER BY at DESC, id DESC LIMIT ?5",
    )?;
    let rows = statement
        .query_map(
            params![
                query.target_id,
                query.thread_id,
                query.before,
                query.before_id,
                query.limit
            ],
            |row| {
                Ok(json!({
                    "id": row.get::<_, i64>(0)?,
                    "at": row.get::<_, i64>(1)?,
                    "target_id": row.get::<_, String>(2)?,
                    "thread_id": row.get::<_, String>(3)?,
                    "action": row.get::<_, String>(4)?,
                    "reason": row.get::<_, String>(5)?,
                    "detail": row.get::<_, String>(6)?,
                }))
            },
        )?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({ "rows": rows }))
}

fn token_fields(row: &rusqlite::Row<'_>, first: usize) -> rusqlite::Result<Value> {
    let get = |offset: usize| {
        row.get::<_, Option<i64>>(first + offset)
            .map(|v| v.unwrap_or(0))
    };
    let (input, output, cache_read, cache_write, thought) =
        (get(0)?, get(1)?, get(2)?, get(3)?, get(4)?);
    Ok(json!({
        "input_tokens": input,
        "output_tokens": output,
        "cache_read_tokens": cache_read,
        "cache_write_tokens": cache_write,
        "thought_tokens": thought,
        "total_tokens": input + output + cache_read + cache_write + thought,
    }))
}

fn merge_objects(mut base: Value, extra: Value) -> Value {
    if let (Some(base), Some(extra)) = (base.as_object_mut(), extra.as_object()) {
        for (key, value) in extra {
            base.insert(key.clone(), value.clone());
        }
    }
    base
}

const SUMS: &str = "SUM(input), SUM(output), SUM(cache_read), SUM(cache_write), SUM(thought)";

pub(super) fn thread_stats(
    connection: &Connection,
    target_id: &str,
    thread_id: &str,
) -> rusqlite::Result<Value> {
    connection.query_row(
        &format!(
            "SELECT COUNT(*), MIN(at), MAX(at), {SUMS} FROM turn_usage
             WHERE target = ?1 AND thread = ?2"
        ),
        params![target_id, thread_id],
        |row| {
            Ok(merge_objects(
                json!({
                    "target_id": target_id,
                    "thread_id": thread_id,
                    "turns": row.get::<_, i64>(0)?,
                    "first_at": row.get::<_, Option<i64>>(1)?,
                    "last_at": row.get::<_, Option<i64>>(2)?,
                }),
                token_fields(row, 3)?,
            ))
        },
    )
}

/// `utc_offset` (seconds east of UTC) decides which local day a turn belongs to.
pub(super) fn usage_stats(
    connection: &Connection,
    since: i64,
    utc_offset: i64,
    top: u32,
) -> rusqlite::Result<Value> {
    let mut statement = connection.prepare(&format!(
        "SELECT date(at + ?2, 'unixepoch') AS day, agent, COUNT(*), {SUMS} FROM turn_usage
         WHERE at >= ?1 GROUP BY day, agent ORDER BY day, agent"
    ))?;
    let days = statement
        .query_map(params![since, utc_offset], |row| {
            Ok(merge_objects(
                json!({
                    "day": row.get::<_, String>(0)?,
                    "agent": row.get::<_, String>(1)?,
                    "turns": row.get::<_, i64>(2)?,
                }),
                token_fields(row, 3)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut statement = connection.prepare(&format!(
        "SELECT agent, COUNT(*), {SUMS} FROM turn_usage WHERE at >= ?1
         GROUP BY agent ORDER BY agent"
    ))?;
    let totals = statement
        .query_map(params![since], |row| {
            Ok(merge_objects(
                json!({"agent": row.get::<_, String>(0)?, "turns": row.get::<_, i64>(1)?}),
                token_fields(row, 2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut statement = connection.prepare(&format!(
        "SELECT target, thread, MAX(agent), COUNT(*), MAX(at), {SUMS} FROM turn_usage
         WHERE at >= ?1 GROUP BY target, thread
         ORDER BY SUM(input) + SUM(output) + SUM(cache_read) + SUM(cache_write) + SUM(thought) DESC
         LIMIT ?2"
    ))?;
    let threads = statement
        .query_map(params![since, top], |row| {
            Ok(merge_objects(
                json!({
                    "target_id": row.get::<_, String>(0)?,
                    "thread_id": row.get::<_, String>(1)?,
                    "agent": row.get::<_, String>(2)?,
                    "turns": row.get::<_, i64>(3)?,
                    "last_at": row.get::<_, i64>(4)?,
                }),
                token_fields(row, 5)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({"since": since, "days": days, "totals": totals, "top_threads": threads}))
}

pub(super) fn limit_samples(
    connection: &Connection,
    agent: &str,
    since: i64,
) -> rusqlite::Result<Value> {
    let mut statement = connection.prepare(
        "SELECT kind, at, used_percent, resets_at FROM limit_samples
         WHERE agent = ?1 AND at >= ?2 ORDER BY at, kind LIMIT 20000",
    )?;
    let samples = statement
        .query_map(params![agent, since], |row| {
            Ok(json!({
                "kind": row.get::<_, String>(0)?,
                "at": row.get::<_, i64>(1)?,
                "used_percent": row.get::<_, f64>(2)?,
                "resets_at": row.get::<_, Option<i64>>(3)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({"agent": agent, "since": since, "samples": samples}))
}

#[cfg(test)]
pub(super) fn turn_exists(
    connection: &Connection,
    target_id: &str,
    thread_id: &str,
    turn_key: &str,
) -> rusqlite::Result<bool> {
    use rusqlite::OptionalExtension;
    connection
        .query_row(
            "SELECT 1 FROM turn_usage WHERE target = ?1 AND thread = ?2 AND turn_key = ?3",
            params![target_id, thread_id, turn_key],
            |_| Ok(()),
        )
        .optional()
        .map(|row| row.is_some())
}

/// The database handle shared by the gateway; `None` inside when it could not be opened (the
/// gateway keeps working without history).
#[derive(Clone)]
pub(super) struct Database(Option<Arc<std::sync::Mutex<Connection>>>);

impl Database {
    pub(super) fn open_in(directory: &Path) -> Self {
        match open(&directory.join("zedlink.sqlite")) {
            Ok(connection) => Self(Some(Arc::new(std::sync::Mutex::new(connection)))),
            Err(error) => {
                eprintln!("history database unavailable: {error:#}");
                Self(None)
            }
        }
    }

    #[cfg(test)]
    pub(super) fn in_memory() -> Self {
        let mut connection = Connection::open_in_memory().expect("in-memory sqlite");
        migrate(&mut connection).expect("migrations");
        Self(Some(Arc::new(std::sync::Mutex::new(connection))))
    }

    /// Runs `work` on a blocking thread; `None` when there is no database or it failed.
    pub(super) async fn run<R: Send + 'static>(
        &self,
        work: impl FnOnce(&Connection) -> rusqlite::Result<R> + Send + 'static,
    ) -> Option<R> {
        let connection = self.0.clone()?;
        let result = tokio::task::spawn_blocking(move || {
            let connection = connection
                .lock()
                .map_err(|_| "database lock poisoned".to_owned())?;
            work(&connection).map_err(|error| error.to_string())
        })
        .await;
        match result {
            Ok(Ok(value)) => Some(value),
            Ok(Err(error)) => {
                eprintln!("history database error: {error}");
                None
            }
            Err(error) => {
                eprintln!("history database task failed: {error}");
                None
            }
        }
    }
}

fn history_unavailable() -> (StatusCode, Result<Value, Value>) {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Err(json!({"code": "HISTORY_UNAVAILABLE"})),
    )
}

fn invalid_request() -> (StatusCode, Result<Value, Value>) {
    (
        StatusCode::BAD_REQUEST,
        Err(json!({"code": "INVALID_REQUEST"})),
    )
}

/// Start of the local day `days - 1` days before today.
fn local_days_start(days: i64) -> i64 {
    use chrono::{Days, Local, TimeZone};
    let today = Local::now().date_naive();
    today
        .checked_sub_days(Days::new(days.saturating_sub(1).max(0) as u64))
        .and_then(|day| day.and_hms_opt(0, 0, 0))
        .and_then(|midnight| Local.from_local_datetime(&midnight).earliest())
        .map_or_else(|| now_seconds() - days * 86_400, |start| start.timestamp())
}

impl Gateway {
    /// Live thread rows of a target (title and context are never stored).
    async fn live_threads(&self, target_id: &str) -> HashMap<String, Value> {
        let request = json!({
            "version": 1, "request_id": Uuid::new_v4().to_string(),
            "method": "thread.list", "params": {},
        });
        let Ok(response) = self.probe_native(Some(target_id), &request).await else {
            return HashMap::new();
        };
        response["result"]["threads"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|row| Some((row["thread_id"].as_str()?.to_owned(), row.clone())))
            .collect()
    }

    /// `stats.thread`, `stats.usage`, `stats.limits`.
    pub(super) async fn stats_rpc(
        &self,
        method: &str,
        target_id: Option<&str>,
        params: &Value,
    ) -> (StatusCode, Result<Value, Value>) {
        let number = |name: &str, default: i64, range: std::ops::RangeInclusive<i64>| match params
            .get(name)
            .filter(|value| !value.is_null())
        {
            None => Some(default),
            Some(value) => value.as_i64().filter(|value| range.contains(value)),
        };
        match method {
            "stats.thread" => {
                let Ok(target) = self.target(params["target_id"].as_str().or(target_id)) else {
                    return (
                        StatusCode::NOT_FOUND,
                        Err(json!({"code": "UNKNOWN_TARGET"})),
                    );
                };
                let Some(thread_id) = valid_thread_id(&params["thread_id"]) else {
                    return invalid_request();
                };
                let target_id = target.id.clone();
                let stats = {
                    let (target_id, thread_id) = (target_id.clone(), thread_id.to_owned());
                    self.0
                        .database
                        .run(move |connection| thread_stats(connection, &target_id, &thread_id))
                        .await
                };
                let Some(mut stats) = stats else {
                    return history_unavailable();
                };
                stats["context"] = self
                    .live_threads(&target_id)
                    .await
                    .get(thread_id)
                    .map_or(Value::Null, |row| row["context"].clone());
                (StatusCode::OK, Ok(stats))
            }
            "stats.usage" => {
                let (Some(days), Some(top)) =
                    (number("days", 30, 1..=90), number("top", 10, 1..=50))
                else {
                    return invalid_request();
                };
                let since = local_days_start(days);
                let offset = i64::from(chrono::Local::now().offset().local_minus_utc());
                let stats = self
                    .0
                    .database
                    .run(move |connection| usage_stats(connection, since, offset, top as u32))
                    .await;
                let Some(mut stats) = stats else {
                    return history_unavailable();
                };
                stats["days_requested"] = json!(days);
                let mut live = HashMap::<String, HashMap<String, Value>>::new();
                if let Some(threads) = stats["top_threads"].as_array_mut() {
                    for row in threads {
                        let Some(target_id) = row["target_id"].as_str().map(str::to_owned) else {
                            continue;
                        };
                        if self.target(Some(&target_id)).is_err() {
                            continue;
                        }
                        if !live.contains_key(&target_id) {
                            let rows = self.live_threads(&target_id).await;
                            live.insert(target_id.clone(), rows);
                        }
                        let title = row["thread_id"]
                            .as_str()
                            .and_then(|thread_id| live.get(&target_id)?.get(thread_id))
                            .map_or(Value::Null, |thread| thread["title"].clone());
                        row["title"] = title;
                    }
                }
                (StatusCode::OK, Ok(stats))
            }
            "stats.limits" => {
                let Some(agent) = params["agent"].as_str().filter(|agent| {
                    !agent.is_empty()
                        && agent.len() <= 32
                        && agent
                            .bytes()
                            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
                }) else {
                    return invalid_request();
                };
                let Some(hours) = number("hours", 24, 1..=168) else {
                    return invalid_request();
                };
                let since = now_seconds() - hours * 3600;
                let agent = agent.to_owned();
                match self
                    .0
                    .database
                    .run(move |connection| limit_samples(connection, &agent, since))
                    .await
                {
                    Some(samples) => (StatusCode::OK, Ok(samples)),
                    None => history_unavailable(),
                }
            }
            _ => (
                StatusCode::FORBIDDEN,
                Err(json!({"code": "UNSUPPORTED_CAPABILITY"})),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn memory() -> Connection {
        let mut connection = Connection::open_in_memory().unwrap();
        migrate(&mut connection).unwrap();
        connection
    }

    #[test]
    fn migrations_set_user_version_and_are_idempotent() {
        let mut connection = memory();
        let version: i64 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
        migrate(&mut connection).unwrap();
        let tables: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'
                 AND name IN ('turn_usage', 'limit_samples', 'autopilot_log')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tables, 3);
    }

    #[test]
    fn file_database_uses_wal_and_private_mode() -> Result<()> {
        let directory = std::env::temp_dir().join(format!("zlink-db-{}", Uuid::new_v4()));
        fs::create_dir_all(&directory)?;
        let path = directory.join("zedlink.sqlite");
        let connection = open(&path)?;
        let mode: String = connection.query_row("PRAGMA journal_mode", [], |row| row.get(0))?;
        assert_eq!(mode, "wal");
        assert_eq!(fs::metadata(&path)?.permissions().mode() & 0o777, 0o600);
        drop(connection);
        // Reopening an existing database runs no migration twice.
        drop(open(&path)?);
        fs::remove_dir_all(&directory)?;
        Ok(())
    }

    #[test]
    fn turns_are_recorded_once_and_aggregated() {
        let connection = memory();
        let usage = |input, output| TurnUsage {
            input,
            output,
            cache_read: 10,
            cache_write: 1,
            thought: 0,
        };
        let day = 86_400;
        assert!(
            insert_turn(
                &connection,
                "d",
                "t1",
                "e:5",
                "claude",
                day + 100,
                &usage(100, 20)
            )
            .unwrap()
        );
        assert!(
            !insert_turn(
                &connection,
                "d",
                "t1",
                "e:5",
                "claude",
                day + 100,
                &usage(100, 20)
            )
            .unwrap()
        );
        assert!(turn_exists(&connection, "d", "t1", "e:5").unwrap());
        insert_turn(
            &connection,
            "d",
            "t1",
            "e:9",
            "claude",
            day + 200,
            &usage(50, 5),
        )
        .unwrap();
        insert_turn(
            &connection,
            "d",
            "t2",
            "e:1",
            "codex",
            2 * day + 10,
            &usage(1000, 1),
        )
        .unwrap();
        // Outside the range.
        insert_turn(&connection, "d", "t3", "e:1", "codex", 10, &usage(5, 5)).unwrap();

        let thread = thread_stats(&connection, "d", "t1").unwrap();
        assert_eq!(thread["turns"], 2);
        assert_eq!(thread["input_tokens"], 150);
        assert_eq!(thread["output_tokens"], 25);
        assert_eq!(thread["cache_read_tokens"], 20);
        assert_eq!(thread["total_tokens"], 150 + 25 + 20 + 2);
        assert_eq!(thread["first_at"], day + 100);
        let empty = thread_stats(&connection, "d", "none").unwrap();
        assert_eq!(empty["turns"], 0);
        assert_eq!(empty["total_tokens"], 0);

        let stats = usage_stats(&connection, day, 0, 10).unwrap();
        assert_eq!(stats["days"].as_array().unwrap().len(), 2);
        assert_eq!(stats["days"][0]["day"], "1970-01-02");
        assert_eq!(stats["days"][0]["agent"], "claude");
        assert_eq!(stats["days"][0]["turns"], 2);
        assert_eq!(stats["days"][1]["agent"], "codex");
        assert_eq!(stats["totals"][1]["input_tokens"], 1000);
        assert_eq!(stats["top_threads"][0]["thread_id"], "t2");
        assert_eq!(stats["top_threads"][1]["thread_id"], "t1");
        // A local offset moves a turn to the previous day.
        let shifted = usage_stats(&connection, day, -200, 10).unwrap();
        assert_eq!(shifted["days"][0]["day"], "1970-01-01");
    }

    #[test]
    fn history_pages_newest_first_and_filters() {
        let connection = memory();
        for (index, thread) in ["t1", "t2", "t1", "t1"].iter().enumerate() {
            insert_log(
                &connection,
                &LogRow {
                    at: 100 + index as i64,
                    target_id: "d".into(),
                    thread_id: (*thread).into(),
                    action: "continued".into(),
                    reason: "rate_limit".into(),
                    detail: format!("{index}"),
                },
            )
            .unwrap();
        }
        let query = HistoryQuery {
            thread_id: Some("t1".into()),
            limit: 2,
            ..Default::default()
        };
        let page = history(&connection, &query).unwrap();
        let rows = page["rows"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["detail"], "3");
        assert_eq!(rows[1]["detail"], "2");
        let next = history(
            &connection,
            &HistoryQuery {
                before: rows[1]["at"].as_i64(),
                ..query
            },
        )
        .unwrap();
        assert_eq!(next["rows"].as_array().unwrap().len(), 1);
        assert_eq!(next["rows"][0]["detail"], "0");
        let all = history(
            &connection,
            &HistoryQuery {
                limit: 200,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(all["rows"].as_array().unwrap().len(), 4);
    }

    #[test]
    fn retention_drops_rows_older_than_400_days() {
        let connection = memory();
        let now = 1_000 * 86_400;
        insert_limit_sample(
            &connection,
            "claude",
            "five_hour",
            now - 401 * 86_400,
            5.0,
            None,
        )
        .unwrap();
        insert_limit_sample(
            &connection,
            "claude",
            "five_hour",
            now - 10,
            50.0,
            Some(now + 60),
        )
        .unwrap();
        insert_turn(
            &connection,
            "d",
            "t",
            "k",
            "claude",
            now - 500 * 86_400,
            &TurnUsage::default(),
        )
        .unwrap();
        assert_eq!(prune(&connection, now).unwrap(), 2);
        let samples = limit_samples(&connection, "claude", 0).unwrap();
        assert_eq!(samples["samples"].as_array().unwrap().len(), 1);
        assert_eq!(samples["samples"][0]["used_percent"], 50.0);
        assert_eq!(samples["samples"][0]["resets_at"], now + 60);
    }

    #[test]
    fn usage_objects_from_bridge_events() {
        assert_eq!(
            TurnUsage::from_event(&json!({"input_tokens": 5, "output_tokens": 2,
                "cache_read_tokens": 7, "thought_tokens": null})),
            Some(TurnUsage {
                input: 5,
                output: 2,
                cache_read: 7,
                cache_write: 0,
                thought: 0
            })
        );
        assert_eq!(TurnUsage::from_event(&Value::Null), None);
    }

    #[tokio::test]
    async fn database_runs_off_the_runtime() {
        let database = Database::in_memory();
        let id = database
            .run(|connection| {
                insert_log(
                    connection,
                    &LogRow {
                        at: 1,
                        target_id: "d".into(),
                        thread_id: "t".into(),
                        action: "continued".into(),
                        reason: "user".into(),
                        detail: String::new(),
                    },
                )
            })
            .await;
        assert_eq!(id, Some(1));
        assert!(Database(None).run(|_| Ok(())).await.is_none());
    }
}
