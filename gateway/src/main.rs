use anyhow::{Context, Result, bail};
use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::{
        DefaultBodyLimit, Query, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use axum_server::tls_rustls::RustlsConfig;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::SinkExt;
use isahc::{
    HttpClient,
    config::{RedirectPolicy, VersionNegotiation},
    prelude::*,
};
use jwt_simple::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeSet, HashMap, HashSet},
    fs::{self, DirBuilder, OpenOptions, Permissions},
    io::Write,
    net::{IpAddr, SocketAddr},
    os::unix::fs::{DirBuilderExt, FileTypeExt, PermissionsExt},
    os::unix::net::UnixStream as StdUnixStream,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Mutex, Notify, Semaphore, broadcast},
    task::JoinSet,
};
use uuid::Uuid;

mod autopilot;
mod db;
mod limits;
mod unread;
mod zed_control;
use web_push::{
    ContentEncoding, IsahcWebPushClient, SubscriptionInfo, Urgency, VapidSignatureBuilder,
    WebPushClient, WebPushError, WebPushMessageBuilder,
};

/// Release tag set by .github/workflows/gateway-release.yml; the updater compares it.
const GATEWAY_BUILD: &str = match option_env!("ZEDLINK_GATEWAY_BUILD") {
    Some(build) => build,
    None => concat!(env!("CARGO_PKG_VERSION"), "-dev"),
};
const MAX_RPC: usize = 2 * 1024 * 1024;
const MAX_PROBE_RESPONSE: u64 = 4 * 1024 * 1024;
const PAIR_TTL: Duration = Duration::from_secs(300);
const MAX_DEVICES: usize = 32;
const MAX_WEBSOCKETS: usize = 64;
const EVENT_POLL: Duration = Duration::from_secs(1);
const NOTIFICATION_POLL: Duration = Duration::from_secs(2);
const MONITOR_MAX_BACKOFF: Duration = Duration::from_secs(60);
const PUSH_TIMEOUT: Duration = Duration::from_secs(12);
/// A turn that starts this long after the last phone `thread.send` was started on the desktop.
const PHONE_SEND_WINDOW: Duration = Duration::from_secs(30);
const MAX_REMOTE_THREADS: usize = 1024;
/// Bursts of client requests wait this long for a probe slot instead of failing at once.
const PROBE_SLOT_WAIT: Duration = Duration::from_secs(5);
/// The same failing method/code pair is logged at most once per window.
const FAILURE_LOG_WINDOW: Duration = Duration::from_secs(30);
const PUSH_PREVIEW_CHARS: usize = 120;

#[derive(Clone)]
struct Gateway(Arc<Inner>);
struct Inner {
    directory: PathBuf,
    targets: Vec<ProbeTarget>,
    route_origins: Vec<String>,
    tls_identities: Vec<TlsIdentity>,
    persisted: Mutex<Persisted>,
    pairing: Mutex<Option<Pairing>>,
    pairing_updates: broadcast::Sender<PairingUpdate>,
    probe_limit: Arc<Semaphore>,
    websocket_limit: Arc<Semaphore>,
    shutdown: Arc<Notify>,
    push_client: IsahcWebPushClient,
    apns: Option<ApnsProvider>,
    /// When the phone last sent a message to a thread (`target:thread` key).
    phone_sends: Mutex<HashMap<String, Instant>>,
    failure_log: std::sync::Mutex<HashMap<String, Instant>>,
    /// Targets with a `zed.restart` in progress (no hung-Zed push meanwhile).
    zed_restarts: std::sync::Mutex<HashSet<String>>,
    database: db::Database,
    limit_samples: std::sync::Mutex<limits::SampleMemory>,
    autopilot_runtime: std::sync::Mutex<autopilot::Runtime>,
}
struct ApnsProvider {
    team_id: String,
    key_id: String,
    topic: String,
    key_pem: String,
    client: HttpClient,
}
#[derive(Clone)]
struct TlsIdentity {
    id: String,
    cert: PathBuf,
    key: PathBuf,
    config: RustlsConfig,
}
#[derive(Clone, Serialize, Deserialize)]
struct Persisted {
    gateway_id: Uuid,
    devices: Vec<Device>,
    #[serde(default)]
    vapid_private_key: String,
    #[serde(default)]
    push_subscriptions: Vec<PushSubscription>,
    #[serde(default)]
    apns_devices: Vec<ApnsDevice>,
    /// Threads (`target:thread`) whose latest user message came from the phone.
    /// Push notifications are sent only for these threads.
    #[serde(default)]
    remote_threads: BTreeSet<String>,
    /// Last subscription-limit windows per agent (`limits.list`).
    #[serde(default)]
    limits: std::collections::BTreeMap<String, limits::StoredAgent>,
    #[serde(default)]
    unread: unread::UnreadState,
    #[serde(default)]
    autopilot: autopilot::AutopilotState,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
struct ApnsDevice {
    device_id: Uuid,
    token: String,
    environment: String,
}
#[derive(Clone, Serialize, Deserialize)]
struct Device {
    id: Uuid,
    name: String,
    digest: String,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
struct PushSubscription {
    device_id: Uuid,
    subscription: SubscriptionInfo,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApnsRegistrationRequest {
    token: String,
    environment: String,
}
struct Pairing {
    id: Uuid,
    digest: [u8; 32],
    watch_digest: [u8; 32],
    kind: PairingKind,
    expires: Instant,
    attempts: u8,
}
#[derive(Clone, Serialize)]
struct PairingUpdate {
    pairing_id: Uuid,
    status: &'static str,
    attempts_remaining: u8,
}
#[derive(Clone, Copy)]
enum PairingKind {
    Hex,
    Decimal,
}
#[derive(Deserialize)]
struct PairRequest {
    code: String,
    device_name: String,
}
#[derive(Deserialize)]
struct EventQuery {
    thread_id: String,
    after_sequence: Option<u64>,
    target_id: Option<String>,
}
#[derive(Deserialize)]
struct PairingEventQuery {
    pairing_id: String,
}
#[derive(Deserialize)]
struct UnsubscribeRequest {
    endpoint: String,
}
#[derive(Deserialize)]
struct NotificationTestRequest {
    endpoint: String,
}

#[derive(Clone, Default)]
struct ThreadObservation {
    status: String,
    approvals: HashSet<String>,
    inputs: HashSet<String>,
    had_error: bool,
    last_sequence: u64,
    /// Since when a Generating thread has had no new event (autopilot stall detection).
    quiet_since: Option<Instant>,
    stall_handled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NotificationEvent {
    Approval,
    Input,
    Done,
    Error,
    Stopped(&'static str),
    /// The bridge accepts connections but stops answering (zed_control watchdog).
    ZedHung,
    /// Something the autopilot did or needs (always pushed, whoever drove the thread).
    Autopilot,
}

impl NotificationEvent {
    fn kind(self) -> &'static str {
        match self {
            Self::Approval => "approval",
            Self::Input => "input",
            Self::Done => "done",
            Self::Error => "error",
            Self::Stopped(_) => "stopped",
            Self::ZedHung => "zed_hung",
            Self::Autopilot => "autopilot",
        }
    }
}

fn thread_notification(
    previous: &ThreadObservation,
    current: &ThreadObservation,
    stop_reason: Option<&str>,
) -> Option<NotificationEvent> {
    if current
        .approvals
        .iter()
        .any(|id| !previous.approvals.contains(id))
    {
        Some(NotificationEvent::Approval)
    } else if current
        .inputs
        .iter()
        .any(|id| !previous.inputs.contains(id))
    {
        Some(NotificationEvent::Input)
    } else if let Some(reason) = stop_reason {
        Some(match reason {
            "completed" if current.had_error => NotificationEvent::Error,
            "completed" => NotificationEvent::Done,
            "error" => NotificationEvent::Error,
            "cancelled" => NotificationEvent::Stopped("отменено"),
            "max_turn_requests" => NotificationEvent::Stopped("лимит запросов"),
            "max_tokens" => NotificationEvent::Stopped("лимит длины ответа"),
            "refusal" => NotificationEvent::Stopped("модель отказалась"),
            _ => NotificationEvent::Stopped("причина в треде"),
        })
    } else if !previous.had_error && current.had_error {
        Some(NotificationEvent::Error)
    } else if previous.status == "Generating" && current.status == "Idle" {
        Some(NotificationEvent::Done)
    } else {
        None
    }
}

/// What the lock screen shows; built from the bridge's thread row and snapshot.
#[derive(Clone, Debug)]
struct PushMessage {
    title: String,
    subtitle: Option<String>,
    body: String,
    event: NotificationEvent,
    target_id: String,
    thread_id: String,
    instance_id: String,
    epoch: String,
    project_id: Option<String>,
    host_id: Option<String>,
}

fn truncate_chars(text: &str, limit: usize) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= limit {
        collapsed
    } else {
        let mut cut = collapsed.chars().take(limit).collect::<String>();
        cut.push('…');
        cut
    }
}

fn last_agent_reply(snapshot: &Value) -> Option<String> {
    snapshot["entries_meta"]
        .as_array()?
        .iter()
        .rev()
        .filter(|entry| entry["kind"] == "assistant")
        .find_map(|entry| {
            let text = entry["segments"]
                .as_array()?
                .iter()
                .filter(|segment| segment["kind"] == "assistant")
                .filter_map(|segment| segment["text"].as_str())
                .collect::<Vec<_>>()
                .join(" ");
            let text = truncate_chars(&text, PUSH_PREVIEW_CHARS);
            (!text.is_empty()).then_some(text)
        })
}

fn push_body(event: NotificationEvent, snapshot: &Value) -> String {
    match event {
        NotificationEvent::Approval => snapshot["pending_approvals"]
            .as_array()
            .and_then(|approvals| approvals.last())
            .and_then(|approval| {
                approval["tool_name"]
                    .as_str()
                    .or_else(|| approval["display"].as_str())
            })
            .map(|tool| format!("Нужно подтверждение: {}", truncate_chars(tool, 80)))
            .unwrap_or_else(|| "Нужно подтверждение".to_owned()),
        NotificationEvent::Input => "Ждёт ответа".to_owned(),
        NotificationEvent::Done => last_agent_reply(snapshot)
            .map(|reply| format!("Готово: {reply}"))
            .unwrap_or_else(|| "Готово".to_owned()),
        NotificationEvent::Error => snapshot["agent_error"]["message"]
            .as_str()
            .or_else(|| snapshot["agent_error"]["title"].as_str())
            .map(|message| format!("Ошибка: {}", truncate_chars(message, PUSH_PREVIEW_CHARS)))
            .unwrap_or_else(|| "Ошибка".to_owned()),
        NotificationEvent::Stopped(reason) => format!("Остановлено: {reason}"),
        NotificationEvent::ZedHung => "Zed не отвечает".to_owned(),
        NotificationEvent::Autopilot => "Автопилот".to_owned(),
    }
}

fn nonempty(value: &Value) -> Option<&str> {
    value
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

fn push_heading(row: &Value, snapshot: &Value) -> (String, Option<String>) {
    let title = nonempty(&snapshot["title"])
        .or_else(|| nonempty(&row["title"]))
        .map(|title| truncate_chars(title, 80))
        .unwrap_or_else(|| "ZLink".to_owned());
    let host = nonempty(&row["host_label"]);
    let workspace = nonempty(&row["workspace_label"]).or_else(|| nonempty(&row["project"]));
    let subtitle = [host, workspace]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" · ");
    (title, (!subtitle.is_empty()).then_some(subtitle))
}

/// `badge` is the device's unread total (`summary.unread`).
fn apns_payload(message: &PushMessage, gateway_id: &str, created: u64, badge: u64) -> Value {
    let mut alert = json!({"title": message.title, "body": message.body});
    if let Some(subtitle) = &message.subtitle {
        alert["subtitle"] = json!(subtitle);
    }
    if message.event == NotificationEvent::ZedHung {
        return json!({"aps": {"alert": alert, "sound": "default", "category": "ZEDLINK_ZED",
                "thread-id": format!("zed:{}", message.target_id), "badge": badge},
            "type": "zed_hung", "event": message.event.kind(),
            "gateway": gateway_id, "target": message.target_id, "created": created});
    }
    json!({"aps": {"alert": alert, "sound": "default", "category": "ZEDLINK_REVIEW",
            "thread-id": message.thread_id, "badge": badge},
        "type": "push", "event": message.event.kind(),
        "gateway": gateway_id, "target": message.target_id, "thread": message.thread_id,
        "instance": message.instance_id, "epoch": message.epoch, "created": created,
        "project_id": message.project_id, "host_id": message.host_id})
}

fn apns_collapse_id(message: &PushMessage) -> String {
    let subject = if message.thread_id.is_empty() {
        &message.target_id
    } else {
        &message.thread_id
    };
    let mut id = format!("{subject}:{}", message.event.kind());
    while id.len() > 64 {
        id.pop();
    }
    id
}

fn pending_approval_keys(snapshot: &Value) -> HashSet<String> {
    let mut keys = HashSet::new();
    let mut add = |rows: Option<&Vec<Value>>, child: &str| {
        for row in rows.into_iter().flatten() {
            if let Some(id) = row["approval_id"].as_str() {
                keys.insert(format!(
                    "{}:{child}:{}:{id}",
                    snapshot["epoch"], row["turn_id"]
                ));
            }
        }
    };
    add(snapshot["pending_approvals"].as_array(), "");
    for child in snapshot["subagents"].as_array().into_iter().flatten() {
        add(
            child["pending_approvals"].as_array(),
            child["session_id"].as_str().unwrap_or(""),
        );
    }
    keys
}

fn remote_thread_key(target_id: &str, thread_id: &str) -> String {
    format!("{target_id}:{thread_id}")
}

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

/// A thread id as the bridge issues them (bounded, no control characters).
fn valid_thread_id(value: &Value) -> Option<&str> {
    value
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 128 && !id.chars().any(char::is_control))
}

/// Bridge `turn.stopped` events in `(after, through]` that carry token usage.
fn turn_usages(events: &Value, after: u64, through: u64) -> Vec<(u64, db::TurnUsage)> {
    events
        .as_array()
        .into_iter()
        .flatten()
        .filter(|event| event["kind"] == "turn.stopped")
        .filter_map(|event| {
            let sequence = event["sequence"].as_u64()?;
            if sequence <= after || sequence > through {
                return None;
            }
            Some((sequence, db::TurnUsage::from_event(&event["usage"])?))
        })
        .collect()
}

fn subagents_running(snapshot: &Value) -> bool {
    snapshot["subagents"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|child| {
            !child["current_turn_id"].is_null()
                || child["status"].as_str().is_some_and(|status| {
                    let status = status.to_ascii_lowercase();
                    status.contains("progress") || status.contains("pending")
                })
        })
}

/// Statistics key of a thread's agent: `claude`, `codex`, else its bounded id.
fn usage_agent(thread: &Value) -> String {
    let id = thread["agent"]["id"].as_str().unwrap_or("");
    let name = thread["agent"]["name"].as_str().unwrap_or("");
    match limits::agent_key(id, name) {
        Some(agent) => agent.to_owned(),
        None if !id.is_empty() => id
            .chars()
            .filter(|character| !character.is_control())
            .take(64)
            .collect(),
        None => "unknown".to_owned(),
    }
}

/// Whether the bridge reported a user message typed in desktop Zed.
/// A later update may relabel the same entry as remote (its receipt arrived late).
fn has_local_user_message(events: &Value, through_sequence: u64) -> bool {
    let Some(events) = events.as_array() else {
        return false;
    };
    let user_events = events.iter().filter(|event| {
        event["entry_kind"] == "user"
            && event["sequence"]
                .as_u64()
                .is_some_and(|sequence| sequence <= through_sequence)
    });
    let remote_entries = user_events
        .clone()
        .filter(|event| event["origin"] == "remote")
        .map(|event| &event["entry_index"])
        .collect::<Vec<_>>();
    user_events
        .filter(|event| event["origin"] == "local")
        .any(|event| !remote_entries.contains(&&event["entry_index"]))
}

fn latest_stop_reason(events: &Value, through_sequence: u64) -> Option<&str> {
    events
        .as_array()?
        .iter()
        .rev()
        .find(|event| {
            event["kind"] == "turn.stopped"
                && event["sequence"]
                    .as_u64()
                    .is_some_and(|sequence| sequence <= through_sequence)
        })
        .and_then(|event| event["stop_reason"].as_str())
}

enum PushOutcome {
    Sent,
    Stale,
    Failed,
}

#[derive(Clone, Deserialize)]
struct TlsListenerConfig {
    id: String,
    bind: SocketAddr,
    cert: PathBuf,
    key: PathBuf,
    #[serde(default)]
    url: Option<String>,
}

#[derive(Deserialize)]
struct ListenerFile {
    version: u8,
    listeners: Vec<TlsListenerConfig>,
}

#[derive(Clone, Deserialize)]
struct ProbeTarget {
    id: String,
    label: String,
    probe: PathBuf,
    /// systemd --user unit that runs this Zed (`zed.start` / `zed.restart`); see zed_control.
    #[serde(default)]
    zed_unit: Option<String>,
}

#[derive(Deserialize)]
struct TargetFile {
    version: u8,
    targets: Vec<ProbeTarget>,
}

fn application(state: Gateway) -> Router {
    Router::new()
        .route("/", get(browser_page))
        .route("/app.js", get(browser_script))
        .route("/ui.js", get(browser_ui_bundle))
        .route("/style.css", get(browser_style))
        .route("/manifest.webmanifest", get(browser_manifest))
        .route("/service-worker.js", get(browser_service_worker))
        .route("/fonts/terminal-icons.woff2", get(browser_terminal_font))
        .route("/icons/icon-192.png", get(browser_icon_192))
        .route("/icons/icon-512.png", get(browser_icon_512))
        .route("/v1/gateway", get(info))
        .route("/v1/pair", post(pair))
        .route("/v1/pairing-events", get(pairing_events))
        .route("/v1/rpc", post(rpc))
        .route("/v1/events", get(events))
        .route("/v1/notifications/config", get(notification_config))
        .route("/v1/notifications/subscribe", post(notification_subscribe))
        .route("/v1/notifications/status", post(notification_status))
        .route(
            "/v1/notifications/unsubscribe",
            post(notification_unsubscribe),
        )
        .route("/v1/notifications/test", post(notification_test))
        .route(
            "/v1/notifications/apns",
            get(apns_status).post(apns_register).delete(apns_unregister),
        )
        .route("/v1/notifications/apns/test", post(apns_test))
        .layer(DefaultBodyLimit::max(MAX_RPC))
        .with_state(state)
}

fn validate_listener(listener: &TlsListenerConfig) -> Result<()> {
    if listener.id.trim().is_empty() || listener.id.len() > 64 {
        bail!("listener id must contain 1 to 64 characters");
    }
    if !private_ip(listener.bind.ip()) {
        bail!(
            "listener {} must bind a loopback or private address",
            listener.id
        );
    }
    if !listener.cert.is_absolute() || !listener.key.is_absolute() {
        bail!(
            "listener {} certificate and key paths must be absolute",
            listener.id
        );
    }
    if fs::metadata(&listener.key)?.permissions().mode() & 0o077 != 0 {
        bail!(
            "listener {} TLS private key must be mode 0600 or stricter",
            listener.id
        );
    }
    if let Some(origin) = &listener.url {
        let parsed = url::Url::parse(origin).context("invalid listener HTTPS origin")?;
        if parsed.scheme() != "https"
            || parsed.host_str().is_none()
            || parsed.username() != ""
            || parsed.password().is_some()
            || parsed.path() != "/"
            || parsed.query().is_some()
            || parsed.fragment().is_some()
        {
            bail!(
                "listener {} URL must be a trusted HTTPS origin",
                listener.id
            );
        }
    }
    Ok(())
}

async fn run_gateway(
    listeners: Vec<TlsListenerConfig>,
    targets: Vec<ProbeTarget>,
    directory: PathBuf,
) -> Result<()> {
    if listeners.is_empty() || listeners.len() > 16 {
        bail!("configure between 1 and 16 TLS listeners");
    }
    if !directory.is_absolute() {
        bail!("state path must be absolute");
    }
    let admin_socket = directory.join("admin.sock");
    if admin_socket.exists() && StdUnixStream::connect(&admin_socket).is_ok() {
        bail!("another ZedLink gateway already owns this state directory");
    }
    let mut addresses = HashSet::new();
    for listener in &listeners {
        validate_listener(listener)?;
        if !addresses.insert(listener.bind) {
            bail!("duplicate listener address: {}", listener.bind);
        }
    }

    let mut route_origins = listeners
        .iter()
        .filter_map(|listener| listener.url.clone())
        .collect::<Vec<_>>();
    route_origins.sort();
    route_origins.dedup();
    let mut servers_to_start = Vec::with_capacity(listeners.len());
    let mut tls_identities = Vec::with_capacity(listeners.len());
    for listener in listeners {
        let tls = RustlsConfig::from_pem_file(&listener.cert, &listener.key)
            .await
            .with_context(|| format!("load TLS identity for listener {}", listener.id))?;
        tls_identities.push(TlsIdentity {
            id: listener.id.clone(),
            cert: listener.cert.clone(),
            key: listener.key.clone(),
            config: tls.clone(),
        });
        servers_to_start.push((listener, tls));
    }
    let targets = zed_control::apply_unit_from_environment(targets)?;
    let state = Gateway::load(directory, targets, route_origins, tls_identities)?;
    let admin = state.clone();
    tokio::spawn(async move {
        if let Err(error) = admin.admin_server().await {
            eprintln!("admin socket stopped: {error:#}");
        }
    });
    let notifications = state.clone();
    tokio::spawn(async move { notifications.notification_monitor().await });
    let watchdog = state.clone();
    tokio::spawn(async move { watchdog.zed_watchdog().await });
    let limits = state.clone();
    tokio::spawn(async move { limits.limits_poller().await });
    let autopilot = state.clone();
    tokio::spawn(async move { autopilot.autopilot_runner().await });

    let mut servers = JoinSet::new();
    for (listener, tls) in servers_to_start {
        let app = application(state.clone());
        eprintln!(
            "ZedLink route {} listening on https://{}",
            listener.id, listener.bind
        );
        servers.spawn(async move {
            axum_server::bind_rustls(listener.bind, tls)
                .serve(app.into_make_service())
                .await
                .with_context(|| format!("listener {} stopped", listener.id))
        });
    }
    tokio::select! {
        result = servers.join_next() => match result {
            Some(result) => result.context("gateway listener task failed")??,
            None => bail!("no gateway listener started"),
        },
        _ = state.0.shutdown.notified() => return Ok(()),
    }
    bail!("gateway listener stopped unexpectedly")
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    match args.first().map(String::as_str) {
        Some("serve") if args.len() == 6 => {
            let address: SocketAddr = args[1].parse().context("invalid listen address")?;
            let probe = PathBuf::from(&args[4]);
            let directory = PathBuf::from(&args[5]);
            run_gateway(
                vec![TlsListenerConfig {
                    id: "primary".into(),
                    bind: address,
                    cert: PathBuf::from(&args[2]),
                    key: PathBuf::from(&args[3]),
                    url: None,
                }],
                vec![ProbeTarget {
                    id: "default".into(),
                    label: "This Zed".into(),
                    probe,
                    zed_unit: None,
                }],
                directory,
            )
            .await
        }
        Some("serve-routes") if args.len() == 4 => {
            let path = PathBuf::from(&args[1]);
            if !path.is_absolute() {
                bail!("listener configuration path must be absolute");
            }
            if fs::metadata(&path)?.permissions().mode() & 0o077 != 0 {
                bail!("listener configuration must be mode 0600 or stricter");
            }
            let config: ListenerFile = serde_json::from_slice(&fs::read(&path)?)
                .context("invalid listener configuration")?;
            if config.version != 1 {
                bail!("unsupported listener configuration version");
            }
            run_gateway(
                config.listeners,
                vec![ProbeTarget {
                    id: "default".into(),
                    label: "This Zed".into(),
                    probe: PathBuf::from(&args[2]),
                    zed_unit: None,
                }],
                PathBuf::from(&args[3]),
            )
            .await
        }
        Some("serve-targets") if args.len() == 4 => {
            let listeners_path = PathBuf::from(&args[1]);
            let targets_path = PathBuf::from(&args[2]);
            for path in [&listeners_path, &targets_path] {
                if !path.is_absolute() {
                    bail!("configuration paths must be absolute");
                }
                if fs::metadata(path)?.permissions().mode() & 0o077 != 0 {
                    bail!("configuration files must be mode 0600 or stricter");
                }
            }
            let listeners: ListenerFile = serde_json::from_slice(&fs::read(listeners_path)?)
                .context("invalid listener configuration")?;
            let targets: TargetFile = serde_json::from_slice(&fs::read(targets_path)?)
                .context("invalid target configuration")?;
            if listeners.version != 1 || targets.version != 1 {
                bail!("unsupported configuration version");
            }
            run_gateway(
                listeners.listeners,
                targets.targets,
                PathBuf::from(&args[3]),
            )
            .await
        }
        Some("version") if args.len() == 1 => {
            println!("{GATEWAY_BUILD}");
            Ok(())
        }
        Some("admin") if args.len() >= 3 => {
            let command = match args[2].as_str() {
                "pair-code" if args.len() == 3 => json!({"method":"pair-code"}),
                "pair-short-code" if args.len() == 3 => json!({"method":"pair-short-code"}),
                "devices" if args.len() == 3 => json!({"method":"devices"}),
                "reload-tls" if args.len() == 3 => json!({"method":"reload-tls"}),
                "shutdown" if args.len() == 3 => json!({"method":"shutdown"}),
                "revoke" if args.len() == 4 => json!({"method":"revoke","device_id":args[3]}),
                _ => bail!(
                    "admin STATE_DIR pair-code|pair-short-code|devices|reload-tls|shutdown|revoke DEVICE_ID"
                ),
            };
            let mut stream = UnixStream::connect(Path::new(&args[1]).join("admin.sock")).await?;
            stream
                .write_all(serde_json::to_string(&command)?.as_bytes())
                .await?;
            stream.write_all(b"\n").await?;
            let mut response = String::new();
            BufReader::new(stream).read_line(&mut response).await?;
            print!("{response}");
            Ok(())
        }
        _ => bail!(
            "serve PRIVATE_IP:PORT CERT_PEM KEY_PEM PROBE_SOCKET STATE_DIR | serve-routes LISTENERS_JSON PROBE_SOCKET STATE_DIR | serve-targets LISTENERS_JSON TARGETS_JSON STATE_DIR | admin STATE_DIR pair-code|pair-short-code|devices|reload-tls|shutdown|revoke DEVICE_ID"
        ),
    }
}
fn static_response(content_type: &'static str, body: &'static str) -> Response {
    let mut response = Response::new(Body::from(body));
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        HeaderName::from_static("x-frame-options"),
        HeaderValue::from_static("DENY"),
    );
    headers.insert(
        HeaderName::from_static("referrer-policy"),
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        HeaderName::from_static("content-security-policy"),
        HeaderValue::from_static(
            "default-src 'none'; script-src 'self'; worker-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
        ),
    );
    response
}
async fn browser_page() -> Response {
    static_response(
        "text/html; charset=utf-8",
        include_str!("../web/index.html"),
    )
}
async fn browser_script() -> Response {
    static_response(
        "text/javascript; charset=utf-8",
        include_str!("../web/app.js"),
    )
}
async fn browser_ui_bundle() -> Response {
    static_response(
        "text/javascript; charset=utf-8",
        include_str!("../web/ui.js"),
    )
}
async fn browser_style() -> Response {
    static_response("text/css; charset=utf-8", include_str!("../web/style.css"))
}
async fn browser_manifest() -> Response {
    static_response(
        "application/manifest+json; charset=utf-8",
        include_str!("../web/manifest.webmanifest"),
    )
}
async fn browser_service_worker() -> Response {
    static_response(
        "text/javascript; charset=utf-8",
        include_str!("../web/service-worker.js"),
    )
}
fn static_bytes(content_type: &'static str, body: &'static [u8]) -> Response {
    let mut response = Response::new(Body::from(body));
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    response
}
async fn browser_terminal_font() -> Response {
    static_bytes(
        "font/woff2",
        include_bytes!("../web/fonts/terminal-icons.woff2"),
    )
}

async fn browser_icon_192() -> Response {
    static_bytes("image/png", include_bytes!("../web/icons/icon-192.png"))
}
async fn browser_icon_512() -> Response {
    static_bytes("image/png", include_bytes!("../web/icons/icon-512.png"))
}
fn private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            ip.is_loopback()
                || ip.is_private()
                || (ip.octets()[0] == 100 && (64..=127).contains(&ip.octets()[1]))
        }
        // fc00::/7 unique local, 200::/7 Yggdrasil mesh (wave 3 §5).
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.segments()[0] & 0xfe00 == 0xfc00
                || ip.segments()[0] & 0xfe00 == 0x0200
        }
    }
}
fn digest(bytes: &[u8]) -> [u8; 32] {
    let mut hash = Sha256::new();
    hash.update(b"ZedLink gateway credential v1\0");
    hash.update(bytes);
    hash.finalize().into()
}
fn new_vapid_private_key() -> String {
    loop {
        let bytes: [u8; 32] = rand::random();
        let encoded = URL_SAFE_NO_PAD.encode(bytes);
        if VapidSignatureBuilder::from_base64_no_sub(&encoded).is_ok() {
            return encoded;
        }
    }
}

/// Bundle id of the TestFlight build (.github/workflows/ios-testflight.yml); ZEDLINK_APNS_TOPIC overrides it.
const DEFAULT_APNS_TOPIC: &str = "cx.m42.zlink";

fn valid_apns_topic(topic: &str) -> bool {
    !topic.is_empty()
        && topic.len() <= 155
        && !topic.starts_with('.')
        && !topic.ends_with('.')
        && topic
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-')
}

fn valid_apns_token(token: &str) -> bool {
    (32..=512).contains(&token.len())
        && token.len().is_multiple_of(2)
        && token.bytes().all(|byte| byte.is_ascii_hexdigit())
}

impl ApnsProvider {
    fn from_environment() -> Result<Option<Self>> {
        let key_file = match std::env::var("ZEDLINK_APNS_KEY_FILE") {
            Ok(path) => PathBuf::from(path),
            Err(std::env::VarError::NotPresent) => return Ok(None),
            Err(_) => bail!("invalid APNs key path"),
        };
        let team_id = std::env::var("ZEDLINK_APNS_TEAM_ID").context("APNs team ID missing")?;
        let key_id = std::env::var("ZEDLINK_APNS_KEY_ID").context("APNs key ID missing")?;
        // The bundle id of the iOS app the device tokens belong to; the TestFlight build's by default.
        let topic = match std::env::var("ZEDLINK_APNS_TOPIC") {
            Ok(topic) => topic,
            Err(std::env::VarError::NotPresent) => DEFAULT_APNS_TOPIC.to_string(),
            Err(_) => bail!("invalid APNs topic"),
        };
        if !valid_apns_topic(&topic) {
            bail!("invalid APNs topic");
        }
        if ![&team_id, &key_id].iter().all(|id| {
            id.len() == 10
                && id
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        }) {
            bail!("invalid APNs team or key ID");
        }
        let metadata = fs::metadata(&key_file).context("APNs key file unavailable")?;
        if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 {
            bail!("APNs key file must be private");
        }
        let key_pem = fs::read_to_string(key_file).context("APNs key file unreadable")?;
        ES256KeyPair::from_pem(&key_pem).context("invalid APNs signing key")?;
        let client = HttpClient::builder()
            .timeout(PUSH_TIMEOUT)
            .redirect_policy(RedirectPolicy::None)
            .version_negotiation(VersionNegotiation::http2())
            .build()
            .context("APNs HTTP/2 client unavailable")?;
        Ok(Some(Self {
            team_id,
            key_id,
            topic,
            key_pem,
            client,
        }))
    }

    fn provider_token(&self) -> Result<String> {
        let key = ES256KeyPair::from_pem(&self.key_pem)?;
        let mut claims =
            Claims::create(jwt_simple::prelude::Duration::from_mins(50)).with_issuer(&self.team_id);
        claims.expires_at = None;
        claims.invalid_before = None;
        Ok(key.with_key_id(&self.key_id).sign(claims)?)
    }

    /// `message` is a thread notification; without one this is the device test push.
    async fn send(
        &self,
        registration: &ApnsDevice,
        test_body: &str,
        gateway_id: &str,
        message: Option<&PushMessage>,
        badge: u64,
    ) -> PushOutcome {
        if !valid_apns_token(&registration.token) {
            return PushOutcome::Failed;
        }
        let Ok(token) = self.provider_token() else {
            return PushOutcome::Failed;
        };
        let host = if registration.environment == "sandbox" {
            "api.sandbox.push.apple.com"
        } else {
            "api.push.apple.com"
        };
        let created = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs());
        let payload = match message {
            Some(message) => apns_payload(message, gateway_id, created, badge),
            None => json!({"aps": {"alert": {"title": "ZLink", "body": test_body},
                "sound": "default", "category": "ZEDLINK_REVIEW"},
                "gateway": gateway_id, "type": "push_test", "created": created}),
        };
        let mut request =
            isahc::Request::post(format!("https://{host}/3/device/{}", registration.token))
                .header("authorization", format!("bearer {token}"))
                .header("apns-topic", self.topic.as_str())
                .header("apns-push-type", "alert")
                .header("apns-expiration", "0")
                .header("content-type", "application/json");
        if let Some(message) = message {
            request = request.header("apns-collapse-id", apns_collapse_id(message));
        }
        let request = request.body(payload.to_string());
        let Ok(request) = request else {
            return PushOutcome::Failed;
        };
        match tokio::time::timeout(PUSH_TIMEOUT, self.client.send_async(request)).await {
            Ok(Ok(response)) if response.status().is_success() => PushOutcome::Sent,
            Ok(Ok(response)) if response.status().as_u16() == 410 => PushOutcome::Stale,
            _ => PushOutcome::Failed,
        }
    }
}

fn valid_subscription(subscription: &SubscriptionInfo) -> bool {
    let public_key = URL_SAFE_NO_PAD.decode(subscription.keys.p256dh.as_bytes());
    let auth = URL_SAFE_NO_PAD.decode(subscription.keys.auth.as_bytes());
    let trusted_endpoint = url::Url::parse(&subscription.endpoint)
        .ok()
        .filter(|endpoint| {
            endpoint.scheme() == "https"
                && endpoint.username().is_empty()
                && endpoint.password().is_none()
                && endpoint.port_or_known_default() == Some(443)
        })
        .and_then(|endpoint| endpoint.host_str().map(str::to_owned))
        .is_some_and(|host| {
            host == "fcm.googleapis.com"
                || host == "push.apple.com"
                || host.ends_with(".push.apple.com")
                || host == "push.services.mozilla.com"
                || host.ends_with(".push.services.mozilla.com")
        });
    trusted_endpoint
        && subscription.endpoint.len() <= 2048
        && !subscription.keys.p256dh.is_empty()
        && subscription.keys.p256dh.len() <= 256
        && !subscription.keys.auth.is_empty()
        && subscription.keys.auth.len() <= 256
        && matches!(public_key.as_deref(), Ok([4, ..]) if public_key.as_ref().is_ok_and(|key| key.len() == 65))
        && auth.as_ref().is_ok_and(|secret| secret.len() == 16)
}
fn save(directory: &Path, state: &Persisted) -> Result<()> {
    let temporary = directory.join(format!("state-{}.tmp", Uuid::new_v4()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    fs::set_permissions(&temporary, Permissions::from_mode(0o600))?;
    file.write_all(&serde_json::to_vec(state)?)?;
    file.sync_all()?;
    fs::rename(&temporary, directory.join("state.json"))?;
    fs::File::open(directory)?.sync_all()?;
    Ok(())
}
impl Gateway {
    fn load(
        directory: PathBuf,
        targets: Vec<ProbeTarget>,
        route_origins: Vec<String>,
        tls_identities: Vec<TlsIdentity>,
    ) -> Result<Self> {
        if targets.is_empty() || targets.len() > 16 {
            bail!("configure between 1 and 16 Zed targets");
        }
        let mut target_ids = HashSet::new();
        for target in &targets {
            if target.id.is_empty()
                || target.id.len() > 64
                || !target
                    .id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
                || target.label.trim().is_empty()
                || target.label.len() > 80
                || !target_ids.insert(target.id.clone())
                || !target.probe.is_absolute()
            {
                bail!("invalid or duplicate Zed target");
            }
            let probe_parent =
                fs::metadata(target.probe.parent().context("probe parent missing")?)?;
            if !probe_parent.is_dir() || probe_parent.permissions().mode() & 0o077 != 0 {
                bail!(
                    "native probes must be in private directories with private socket permissions"
                );
            }
            if target.probe.exists() {
                validate_probe_socket(&target.probe)?;
            }
        }
        if !directory.exists() {
            let mut builder = DirBuilder::new();
            builder.mode(0o700);
            builder.create(&directory)?;
        }
        let metadata = fs::metadata(&directory)?;
        if !metadata.is_dir() || metadata.permissions().mode() & 0o077 != 0 {
            bail!("state directory must be private");
        }
        let file = directory.join("state.json");
        let mut persisted: Persisted = if file.exists() {
            let metadata = fs::metadata(&file)?;
            if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 {
                bail!("state file must be private");
            }
            serde_json::from_slice(&fs::read(file)?)?
        } else {
            let initial = Persisted {
                gateway_id: Uuid::new_v4(),
                devices: vec![],
                vapid_private_key: new_vapid_private_key(),
                push_subscriptions: vec![],
                apns_devices: vec![],
                remote_threads: BTreeSet::new(),
                limits: Default::default(),
                unread: Default::default(),
                autopilot: Default::default(),
            };
            save(&directory, &initial)?;
            initial
        };
        if persisted.vapid_private_key.is_empty() {
            persisted.vapid_private_key = new_vapid_private_key();
            save(&directory, &persisted)?;
        }
        VapidSignatureBuilder::from_base64_no_sub(&persisted.vapid_private_key)
            .context("invalid saved Web Push key")?;
        let (pairing_updates, _) = broadcast::channel(16);
        let database = db::Database::open_in(&directory);
        Ok(Self(Arc::new(Inner {
            directory,
            targets,
            route_origins,
            tls_identities,
            persisted: Mutex::new(persisted),
            pairing: Mutex::new(None),
            pairing_updates,
            probe_limit: Arc::new(Semaphore::new(16)),
            websocket_limit: Arc::new(Semaphore::new(MAX_WEBSOCKETS)),
            shutdown: Arc::new(Notify::new()),
            push_client: IsahcWebPushClient::new().context("Web Push client unavailable")?,
            apns: ApnsProvider::from_environment()?,
            phone_sends: Mutex::new(HashMap::new()),
            failure_log: std::sync::Mutex::new(HashMap::new()),
            zed_restarts: std::sync::Mutex::new(HashSet::new()),
            database,
            limit_samples: std::sync::Mutex::new(HashMap::new()),
            autopilot_runtime: std::sync::Mutex::new(autopilot::Runtime::default()),
        })))
    }
    /// Applies `change` to a copy of the persisted state and saves it; the in-memory state
    /// changes only when the save succeeded.
    async fn mutate_persisted<R>(&self, change: impl FnOnce(&mut Persisted) -> R) -> R {
        self.change_persisted(|state| (true, change(state))).await
    }

    /// Like `mutate_persisted`, but saves only when `change` reports a change.
    async fn change_persisted<R>(&self, change: impl FnOnce(&mut Persisted) -> (bool, R)) -> R {
        let mut persisted = self.0.persisted.lock().await;
        let mut next = persisted.clone();
        let (changed, result) = change(&mut next);
        if changed {
            match save(&self.0.directory, &next) {
                Ok(()) => *persisted = next,
                Err(error) => eprintln!("state save failed: {error:#}"),
            }
        }
        result
    }

    async fn authorize(&self, headers: &HeaderMap) -> Option<Uuid> {
        let token = headers
            .get("authorization")?
            .to_str()
            .ok()?
            .strip_prefix("Bearer ")?;
        self.authorize_token(token).await
    }
    async fn authorize_token(&self, token: &str) -> Option<Uuid> {
        let bytes = hex::decode(token).ok()?;
        if bytes.len() != 32 {
            return None;
        }
        let hash = digest(&bytes);
        self.0
            .persisted
            .lock()
            .await
            .devices
            .iter()
            .find_map(|device| {
                let stored = hex::decode(&device.digest).ok()?;
                (stored.len() == 32 && bool::from(stored.ct_eq(&hash))).then_some(device.id)
            })
    }
    fn target(&self, target_id: Option<&str>) -> Result<&ProbeTarget> {
        match target_id {
            Some(id) => self
                .0
                .targets
                .iter()
                .find(|target| target.id == id)
                .context("unknown Zed target"),
            None => self.0.targets.first().context("no Zed target configured"),
        }
    }

    /// Logs failed native requests (method and error code only, never params) so a
    /// "Live but no data" phone can be diagnosed from the gateway journal.
    async fn probe(&self, target_id: Option<&str>, request: &Value) -> Result<Value> {
        let method = request["method"].as_str().unwrap_or("?");
        let result = self.probe_native(target_id, request).await;
        let failure = match &result {
            Ok(response) => response["error"]["code"]
                .as_str()
                .or_else(|| response["error"].as_str())
                .map(str::to_owned),
            Err(error) => Some(format!("{error:#}")),
        };
        if let Some(failure) = failure {
            self.log_failure(&format!(
                "probe {method} target={} failed: {failure}",
                target_id.unwrap_or("default")
            ));
        }
        result
    }

    fn log_failure(&self, line: &str) {
        let now = Instant::now();
        let Ok(mut log) = self.0.failure_log.lock() else {
            eprintln!("{line}");
            return;
        };
        if log.len() > 512 {
            log.retain(|_, logged| now.duration_since(*logged) < FAILURE_LOG_WINDOW);
        }
        if log
            .get(line)
            .is_some_and(|logged| now.duration_since(*logged) < FAILURE_LOG_WINDOW)
        {
            return;
        }
        log.insert(line.to_owned(), now);
        drop(log);
        eprintln!("{line}");
    }

    async fn probe_native(&self, target_id: Option<&str>, request: &Value) -> Result<Value> {
        let _permit =
            tokio::time::timeout(PROBE_SLOT_WAIT, self.0.probe_limit.clone().acquire_owned())
                .await
                .context("probe request limit reached")??;
        let encoded = serde_json::to_vec(request)?;
        if encoded.len() > MAX_RPC {
            bail!("oversized probe request");
        }
        let probe = self.target(target_id)?.probe.clone();
        validate_probe_socket(&probe)?;
        let mut stream =
            tokio::time::timeout(Duration::from_secs(3), UnixStream::connect(probe)).await??;
        stream.write_all(&encoded).await?;
        stream.write_all(b"\n").await?;
        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(6), async {
            BufReader::new(stream)
                .take(MAX_PROBE_RESPONSE + 1)
                .read_until(b'\n', &mut response)
                .await
        })
        .await??;
        if response.len() as u64 > MAX_PROBE_RESPONSE || !response.ends_with(b"\n") {
            bail!("invalid probe response");
        }
        let response: Value = serde_json::from_slice(&response)?;
        if response["version"] != 1
            || response["request_id"] != request["request_id"]
            || response.get("result").is_some() == response.get("error").is_some()
        {
            bail!("invalid probe response envelope");
        }
        Ok(response)
    }

    async fn instance_list(&self) -> Value {
        let mut targets = Vec::with_capacity(self.0.targets.len());
        for target in &self.0.targets {
            let request = json!({
                "version": 1,
                "request_id": Uuid::new_v4().to_string(),
                "method": "instance.info",
                "params": {},
            });
            let mut item = json!({
                "target_id": target.id,
                "label": target.label,
                "available": false,
            });
            if let Ok(response) = self.probe(Some(&target.id), &request).await
                && let Some(result) = response.get("result")
            {
                item["available"] = json!(true);
                for field in ["instance_id", "epoch", "capabilities", "project"] {
                    if let Some(value) = result.get(field) {
                        item[field] = value.clone();
                    }
                }
            }
            targets.push(item);
        }
        json!({
            "targets": targets,
            "default_target_id": self.0.targets.first().map(|target| target.id.as_str()),
        })
    }
    async fn admin_server(&self) -> Result<()> {
        let path = self.0.directory.join("admin.sock");
        if path.exists() {
            fs::remove_file(&path)?;
        }
        let listener = UnixListener::bind(&path)?;
        fs::set_permissions(&path, Permissions::from_mode(0o600))?;
        loop {
            let (stream, _) = listener.accept().await?;
            let state = self.clone();
            tokio::spawn(async move {
                if let Err(error) = state.admin_command(stream).await {
                    eprintln!("admin command failed: {error:#}");
                }
            });
        }
    }
    async fn admin_command(&self, stream: UnixStream) -> Result<()> {
        let mut reader = BufReader::new(stream);
        let mut request = Vec::new();
        (&mut reader)
            .take(1025)
            .read_until(b'\n', &mut request)
            .await?;
        if request.len() > 1024 || !request.ends_with(b"\n") {
            bail!("invalid admin request");
        }
        let request: Value = serde_json::from_slice(&request)?;
        let shutdown = request["method"].as_str() == Some("shutdown");
        let response = match request["method"].as_str() {
            Some("pair-code") => {
                let code: [u8; 32] = rand::random();
                let watch_token: [u8; 32] = rand::random();
                let id = Uuid::new_v4();
                let mut pairing = self.0.pairing.lock().await;
                if let Some(previous) = pairing.as_ref() {
                    drop(self.0.pairing_updates.send(PairingUpdate {
                        pairing_id: previous.id,
                        status: "replaced",
                        attempts_remaining: 0,
                    }));
                }
                *pairing = Some(Pairing {
                    id,
                    digest: digest(&code),
                    watch_digest: digest(&watch_token),
                    kind: PairingKind::Hex,
                    expires: Instant::now() + PAIR_TTL,
                    attempts: 0,
                });
                json!({"code":hex::encode(code),"pairing_id":id,
                    "watch_token":hex::encode(watch_token),"expires_seconds":PAIR_TTL.as_secs()})
            }
            Some("pair-short-code") => {
                let code = format!("{:010}", rand::random_range(0..10_000_000_000_u64));
                let watch_token: [u8; 32] = rand::random();
                let id = Uuid::new_v4();
                let mut pairing = self.0.pairing.lock().await;
                if let Some(previous) = pairing.as_ref() {
                    drop(self.0.pairing_updates.send(PairingUpdate {
                        pairing_id: previous.id,
                        status: "replaced",
                        attempts_remaining: 0,
                    }));
                }
                *pairing = Some(Pairing {
                    id,
                    digest: digest(code.as_bytes()),
                    watch_digest: digest(&watch_token),
                    kind: PairingKind::Decimal,
                    expires: Instant::now() + PAIR_TTL,
                    attempts: 0,
                });
                json!({"code":code,"pairing_id":id,
                    "watch_token":hex::encode(watch_token),"expires_seconds":PAIR_TTL.as_secs()})
            }
            Some("devices") => {
                let persisted = self.0.persisted.lock().await;
                json!({"gateway_id":persisted.gateway_id,
                    "devices":persisted.devices.iter().map(|device| json!({
                        "id":device.id,
                        "name":device.name,
                        "notifications":persisted.push_subscriptions.iter().any(|subscription| subscription.device_id == device.id)
                            || persisted.apns_devices.iter().any(|registration| registration.device_id == device.id)
                    })).collect::<Vec<_>>()})
            }
            Some("shutdown") => json!({"stopping":true}),
            Some("reload-tls") => {
                let mut replacements = Vec::with_capacity(self.0.tls_identities.len());
                for identity in &self.0.tls_identities {
                    let replacement = RustlsConfig::from_pem_file(&identity.cert, &identity.key)
                        .await
                        .with_context(|| {
                            format!("reload TLS identity for listener {}", identity.id)
                        })?;
                    replacements.push(replacement);
                }
                let mut listeners = Vec::with_capacity(replacements.len());
                for (identity, replacement) in self.0.tls_identities.iter().zip(replacements) {
                    identity.config.reload_from_config(replacement.get_inner());
                    listeners.push(identity.id.clone());
                }
                json!({"reloaded":true,"listeners":listeners})
            }
            Some("revoke") => {
                let id =
                    Uuid::parse_str(request["device_id"].as_str().context("device ID missing")?)?;
                let mut persisted = self.0.persisted.lock().await;
                let mut next = persisted.clone();
                let before = next.devices.len();
                next.devices.retain(|device| device.id != id);
                next.push_subscriptions
                    .retain(|subscription| subscription.device_id != id);
                next.apns_devices
                    .retain(|registration| registration.device_id != id);
                next.unread.forget_device(id);
                if next.devices.len() != before {
                    save(&self.0.directory, &next)?;
                    *persisted = next;
                }
                json!({"revoked":persisted.devices.len()!=before})
            }
            _ => json!({"error":"INVALID_REQUEST"}),
        };
        let mut stream = reader.into_inner();
        stream
            .write_all(serde_json::to_string(&response)?.as_bytes())
            .await?;
        stream.write_all(b"\n").await?;
        if shutdown {
            self.0.shutdown.notify_one();
        }
        Ok(())
    }

    fn vapid_public_key(&self, persisted: &Persisted) -> Result<String> {
        let builder = VapidSignatureBuilder::from_base64_no_sub(&persisted.vapid_private_key)?;
        Ok(URL_SAFE_NO_PAD.encode(builder.get_public_key()))
    }

    async fn send_push(
        &self,
        record: &PushSubscription,
        body: &str,
        message: Option<&PushMessage>,
    ) -> PushOutcome {
        let thread_id = message
            .map(|message| message.thread_id.as_str())
            .filter(|id| !id.is_empty());
        let target_id = message.map(|message| message.target_id.as_str());
        let approval = message.is_some_and(|message| message.event == NotificationEvent::Approval);
        let private_key = self.0.persisted.lock().await.vapid_private_key.clone();
        let signature = match VapidSignatureBuilder::from_base64(&private_key, &record.subscription)
            .and_then(|builder| builder.build())
        {
            Ok(signature) => signature,
            Err(_) => return PushOutcome::Failed,
        };
        let payload = json!({
            "title": message.map_or("ZLink", |message| message.title.as_str()),
            "subtitle": message.and_then(|message| message.subtitle.as_deref()),
            "body": message.map_or(body, |message| message.body.as_str()),
            "tag": thread_id.map_or_else(|| "zedlink-test".to_owned(), |id| format!("zedlink-thread-{id}")),
            "thread_id": thread_id,
            "target_id": target_id,
            "kind": if approval { "approval" } else { "status" },
        });
        let encoded = match serde_json::to_vec(&payload) {
            Ok(encoded) => encoded,
            Err(_) => return PushOutcome::Failed,
        };
        let mut builder = WebPushMessageBuilder::new(&record.subscription);
        builder.set_payload(ContentEncoding::Aes128Gcm, &encoded);
        builder.set_ttl(300);
        builder.set_urgency(if approval {
            Urgency::High
        } else {
            Urgency::Normal
        });
        builder.set_vapid_signature(signature);
        let message = match builder.build() {
            Ok(message) => message,
            Err(_) => return PushOutcome::Failed,
        };
        match tokio::time::timeout(PUSH_TIMEOUT, self.0.push_client.send(message)).await {
            Ok(Ok(())) => PushOutcome::Sent,
            Ok(Err(WebPushError::EndpointNotFound(_) | WebPushError::EndpointNotValid(_))) => {
                PushOutcome::Stale
            }
            _ => PushOutcome::Failed,
        }
    }

    /// Marks a thread as driven from the phone (`remote`) or from the desktop.
    async fn set_remote_thread(&self, target_id: &str, thread_id: &str, remote: bool) {
        let key = remote_thread_key(target_id, thread_id);
        if remote {
            let mut sends = self.0.phone_sends.lock().await;
            sends.retain(|_, sent| sent.elapsed() < PHONE_SEND_WINDOW);
            sends.insert(key.clone(), Instant::now());
        }
        let mut persisted = self.0.persisted.lock().await;
        if persisted.remote_threads.contains(&key) == remote {
            return;
        }
        let mut next = persisted.clone();
        if remote {
            while next.remote_threads.len() >= MAX_REMOTE_THREADS {
                next.remote_threads.pop_first();
            }
            next.remote_threads.insert(key);
        } else {
            next.remote_threads.remove(&key);
        }
        if save(&self.0.directory, &next).is_ok() {
            *persisted = next;
        }
    }

    async fn device_exists(&self, device_id: Uuid) -> bool {
        self.0
            .persisted
            .lock()
            .await
            .devices
            .iter()
            .any(|device| device.id == device_id)
    }

    async fn is_remote_thread(&self, target_id: &str, thread_id: &str) -> bool {
        self.0
            .persisted
            .lock()
            .await
            .remote_threads
            .contains(&remote_thread_key(target_id, thread_id))
    }

    async fn phone_sent_recently(&self, target_id: &str, thread_id: &str) -> bool {
        self.0
            .phone_sends
            .lock()
            .await
            .get(&remote_thread_key(target_id, thread_id))
            .is_some_and(|sent| sent.elapsed() < PHONE_SEND_WINDOW)
    }

    async fn notify_all(&self, message: &PushMessage) {
        let persisted = self.0.persisted.lock().await;
        let subscriptions = persisted.push_subscriptions.clone();
        let apns_devices = persisted
            .apns_devices
            .iter()
            .map(|registration| {
                (
                    registration.clone(),
                    persisted.unread.total(registration.device_id),
                )
            })
            .collect::<Vec<_>>();
        let gateway_id = persisted.gateway_id.to_string();
        drop(persisted);
        let mut stale = HashSet::new();
        for record in subscriptions {
            if matches!(
                self.send_push(&record, &message.body, Some(message)).await,
                PushOutcome::Stale
            ) {
                stale.insert(record.subscription.endpoint);
            }
        }
        if !stale.is_empty() {
            let mut persisted = self.0.persisted.lock().await;
            let mut next = persisted.clone();
            next.push_subscriptions
                .retain(|record| !stale.contains(&record.subscription.endpoint));
            if save(&self.0.directory, &next).is_ok() {
                *persisted = next;
            }
        }
        if let Some(provider) = &self.0.apns {
            let mut expired = HashSet::new();
            for (registration, badge) in apns_devices {
                if matches!(
                    provider
                        .send(
                            &registration,
                            &message.body,
                            &gateway_id,
                            Some(message),
                            badge
                        )
                        .await,
                    PushOutcome::Stale
                ) {
                    expired.insert(registration.token);
                }
            }
            if !expired.is_empty() {
                let mut persisted = self.0.persisted.lock().await;
                let mut next = persisted.clone();
                next.apns_devices
                    .retain(|registration| !expired.contains(&registration.token));
                if save(&self.0.directory, &next).is_ok() {
                    *persisted = next;
                }
            }
        }
    }

    /// Polls every exposed thread. Runs whether or not anyone subscribed to pushes: unread
    /// counters, per-turn usage and the autopilot depend on it; only pushes need subscribers.
    async fn notification_monitor(&self) {
        let mut prior = HashMap::<String, ThreadObservation>::new();
        // Targets whose bridge failed: polled again only after a growing pause, so a hung
        // Zed's socket backlog is not filled by this loop (the watchdog must still see it).
        let mut backoff = HashMap::<String, (Instant, Duration)>::new();
        let mut interval = tokio::time::interval(NOTIFICATION_POLL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let mut current = prior.clone();
            for target in &self.0.targets {
                if backoff
                    .get(&target.id)
                    .is_some_and(|(retry_at, _)| Instant::now() < *retry_at)
                {
                    continue;
                }
                let request = json!({
                    "version": 1,
                    "request_id": Uuid::new_v4().to_string(),
                    "method": "thread.list",
                    "params": {},
                });
                // A closed Zed is normal; `probe_native` keeps it out of the failure log.
                let Ok(response) = self.probe_native(Some(&target.id), &request).await else {
                    let pause = backoff
                        .get(&target.id)
                        .map_or(NOTIFICATION_POLL * 2, |(_, pause)| {
                            (*pause * 2).min(MONITOR_MAX_BACKOFF)
                        });
                    backoff.insert(target.id.clone(), (Instant::now() + pause, pause));
                    continue;
                };
                backoff.remove(&target.id);
                let Some(threads) = response["result"]["threads"].as_array() else {
                    continue;
                };
                let (Some(instance), Some(epoch)) = (
                    response["result"]["instance_id"].as_str(),
                    response["result"]["epoch"].as_str(),
                ) else {
                    continue;
                };
                current.retain(|key, _| !key.starts_with(&format!("{}:", target.id)));
                for thread in threads {
                    let Some(thread_id) = thread["thread_id"].as_str() else {
                        continue;
                    };
                    let key = format!("{}:{instance}:{epoch}:{thread_id}", target.id);
                    if let Some(observation) = self
                        .observe_thread(target, instance, epoch, thread, thread_id, prior.get(&key))
                        .await
                    {
                        current.insert(key, observation);
                    } else if let Some(previous) = prior.get(&key) {
                        current.insert(key, previous.clone());
                    }
                }
            }
            prior = current;
        }
    }

    /// One thread of one monitor pass; `None` when its snapshot was unavailable.
    async fn observe_thread(
        &self,
        target: &ProbeTarget,
        instance: &str,
        epoch: &str,
        thread: &Value,
        thread_id: &str,
        previous: Option<&ThreadObservation>,
    ) -> Option<ThreadObservation> {
        let snapshot_request = json!({
            "version": 1,
            "request_id": Uuid::new_v4().to_string(),
            "method": "thread.snapshot",
            // A short tail keeps the poll cheap and still holds the last reply.
            "params": {"thread_id": thread_id, "tail_entry_count": 8},
        });
        let snapshot = self.probe(Some(&target.id), &snapshot_request).await.ok()?;
        let snapshot = snapshot.get("result").filter(|result| {
            result["pending_approvals"].is_array()
                && result["instance_id"].as_str() == Some(instance)
                && result["epoch"].as_str() == Some(epoch)
        })?;
        let last_sequence = snapshot["last_sequence"].as_u64().unwrap_or(0);
        let inputs = self
            .probe(
                Some(&target.id),
                &json!({
                    "version": 1,
                    "request_id": Uuid::new_v4().to_string(),
                    "method": "thread.elicitations",
                    "params": {"thread_id": thread_id, "instance_id": instance, "epoch": epoch},
                }),
            )
            .await
            .ok()
            .and_then(|response| {
                response["result"]["elicitations"].as_array().map(|rows| {
                    rows.iter()
                        .take(128)
                        .filter(|row| row["status"] == "pending")
                        .filter_map(|row| row["elicitation_id"].as_str().map(str::to_owned))
                        .collect::<HashSet<_>>()
                })
            })
            .unwrap_or_else(|| {
                previous
                    .map(|previous| previous.inputs.clone())
                    .unwrap_or_default()
            });
        let mut observation = ThreadObservation {
            status: snapshot["status"].as_str().unwrap_or("Unknown").to_owned(),
            approvals: pending_approval_keys(snapshot),
            inputs,
            had_error: snapshot["had_error"].as_bool().unwrap_or(false),
            last_sequence,
            quiet_since: None,
            stall_handled: false,
        };
        let mut stop_reason = None;
        if let Some(previous) = previous {
            let events_request = json!({
                "version": 1,
                "request_id": Uuid::new_v4().to_string(),
                "method": "thread.events",
                "params": {"thread_id": thread_id, "after_sequence": previous.last_sequence},
            });
            let events = self
                .probe(Some(&target.id), &events_request)
                .await
                .ok()
                .filter(|events| {
                    events["result"]["instance_id"].as_str() == Some(instance)
                        && events["result"]["epoch"].as_str() == Some(epoch)
                });
            let events = events.as_ref().map(|events| &events["result"]["events"]);
            stop_reason = events
                .and_then(|events| latest_stop_reason(events, last_sequence))
                .map(str::to_owned);
            if let Some(events) = events {
                self.record_turn_usage(
                    &target.id,
                    thread_id,
                    epoch,
                    thread,
                    turn_usages(events, previous.last_sequence, last_sequence),
                )
                .await;
            }
            // A message typed in desktop Zed hands the thread back to the desktop.
            // Bridges without message origins fall back to: a turn that started
            // without a recent phone send was started on the desktop.
            let typed_on_desktop =
                events.is_some_and(|events| has_local_user_message(events, last_sequence));
            let desktop_turn_started = previous.status != "Generating"
                && observation.status == "Generating"
                && !self.phone_sent_recently(&target.id, thread_id).await;
            if desktop_turn_started || typed_on_desktop {
                self.set_remote_thread(&target.id, thread_id, false).await;
            }
            if typed_on_desktop {
                self.mark_thread_read_everywhere(&target.id, thread_id)
                    .await;
                self.autopilot_exempt_turns(&target.id, thread_id);
            }
        }
        let initial = ThreadObservation::default();
        let event = thread_notification(
            previous.unwrap_or(&initial),
            &observation,
            stop_reason.as_deref(),
        );
        if let Some(event) = event {
            // The first sight of a thread (gateway start, new Zed epoch) replays old state;
            // only changes count as new agent events.
            if previous.is_some() {
                self.record_thread_event(&target.id, thread_id).await;
            }
            if self.is_remote_thread(&target.id, thread_id).await {
                let (title, subtitle) = push_heading(thread, snapshot);
                let message = PushMessage {
                    title,
                    subtitle,
                    body: push_body(event, snapshot),
                    event,
                    target_id: target.id.clone(),
                    thread_id: thread_id.to_owned(),
                    instance_id: instance.to_owned(),
                    epoch: epoch.to_owned(),
                    project_id: nonempty(&thread["project_id"]).map(str::to_owned),
                    host_id: nonempty(&thread["host_id"]).map(str::to_owned),
                };
                self.notify_all(&message).await;
            }
            if previous.is_some() {
                self.autopilot_observe(
                    &target.id,
                    thread_id,
                    event,
                    stop_reason.as_deref(),
                    snapshot,
                )
                .await;
            }
        }
        if observation.status == "Generating" {
            // Waiting for the user or for a running subagent is not a stall.
            let waiting = !observation.approvals.is_empty()
                || !observation.inputs.is_empty()
                || subagents_running(snapshot);
            let unchanged = previous.filter(|previous| {
                !waiting
                    && previous.status == "Generating"
                    && previous.last_sequence == last_sequence
            });
            observation.quiet_since = Some(
                unchanged
                    .and_then(|previous| previous.quiet_since)
                    .unwrap_or_else(Instant::now),
            );
            observation.stall_handled = unchanged.is_some_and(|previous| previous.stall_handled);
            let stall_after = Duration::from_secs(
                u64::from(
                    self.0
                        .persisted
                        .lock()
                        .await
                        .autopilot
                        .settings
                        .stall_minutes,
                ) * 60,
            );
            if !observation.stall_handled
                && observation
                    .quiet_since
                    .is_some_and(|since| since.elapsed() >= stall_after)
            {
                observation.stall_handled = true;
                self.autopilot_stalled(&target.id, thread_id, snapshot)
                    .await;
            } else {
                self.autopilot_budget_stop(&target.id, thread_id, snapshot)
                    .await;
            }
        }
        Some(observation)
    }

    /// Stores each finished turn's token usage once (key: epoch and event sequence).
    async fn record_turn_usage(
        &self,
        target_id: &str,
        thread_id: &str,
        epoch: &str,
        thread: &Value,
        usages: Vec<(u64, db::TurnUsage)>,
    ) {
        if usages.is_empty() {
            return;
        }
        let (target_id, thread_id) = (target_id.to_owned(), thread_id.to_owned());
        let epoch = epoch.to_owned();
        let agent = usage_agent(thread);
        let at = now_seconds();
        self.0
            .database
            .run(move |connection| {
                for (sequence, usage) in &usages {
                    db::insert_turn(
                        connection,
                        &target_id,
                        &thread_id,
                        &format!("{epoch}:{sequence}"),
                        &agent,
                        at,
                        usage,
                    )?;
                }
                Ok(())
            })
            .await;
    }
}

fn validate_probe_socket(probe: &Path) -> Result<()> {
    let metadata = fs::metadata(probe).context("native probe socket unavailable")?;
    let parent = fs::metadata(probe.parent().context("probe parent missing")?)?;
    if !metadata.file_type().is_socket()
        || metadata.permissions().mode() & 0o077 != 0
        || !parent.is_dir()
        || parent.permissions().mode() & 0o077 != 0
    {
        bail!("native probe must be in a private directory with private socket permissions");
    }
    Ok(())
}
async fn info(State(state): State<Gateway>) -> Json<Value> {
    Json(json!({
        "version": 1,
        "build": GATEWAY_BUILD,
        "gateway_id": state.0.persisted.lock().await.gateway_id,
        "route_origins": state.0.route_origins,
    }))
}
async fn pair(State(state): State<Gateway>, Json(request): Json<PairRequest>) -> impl IntoResponse {
    if request.device_name.trim().is_empty() || request.device_name.len() > 64 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_REQUEST"})),
        );
    }
    let mut pairing = state.0.pairing.lock().await;
    let Some(active) = pairing.as_mut() else {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"error":"PAIRING_UNAVAILABLE"})),
        );
    };
    if Instant::now() >= active.expires || active.attempts >= 5 {
        drop(state.0.pairing_updates.send(PairingUpdate {
            pairing_id: active.id,
            status: "expired",
            attempts_remaining: 0,
        }));
        *pairing = None;
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"error":"PAIRING_EXPIRED"})),
        );
    }
    active.attempts += 1;
    let valid = match active.kind {
        PairingKind::Hex => {
            let decoded = hex::decode(&request.code).unwrap_or_default();
            decoded.len() == 32 && bool::from(active.digest.ct_eq(&digest(&decoded)))
        }
        PairingKind::Decimal => {
            request.code.len() == 10
                && request.code.bytes().all(|byte| byte.is_ascii_digit())
                && bool::from(active.digest.ct_eq(&digest(request.code.as_bytes())))
        }
    };
    if !valid {
        drop(state.0.pairing_updates.send(PairingUpdate {
            pairing_id: active.id,
            status: "attempt_failed",
            attempts_remaining: 5_u8.saturating_sub(active.attempts),
        }));
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"error":"PAIRING_INVALID"})),
        );
    }
    let mut persisted = state.0.persisted.lock().await;
    if persisted.devices.len() >= MAX_DEVICES {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({"error":"RATE_LIMITED"})),
        );
    }
    let token: [u8; 32] = rand::random();
    let id = Uuid::new_v4();
    let mut next = persisted.clone();
    next.devices.push(Device {
        id,
        name: request.device_name,
        digest: hex::encode(digest(&token)),
    });
    next.unread.start_device(id);
    if save(&state.0.directory, &next).is_err() {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error":"INTERNAL_ERROR"})),
        );
    }
    *persisted = next;
    drop(state.0.pairing_updates.send(PairingUpdate {
        pairing_id: active.id,
        status: "paired",
        attempts_remaining: 5_u8.saturating_sub(active.attempts),
    }));
    *pairing = None;
    (
        StatusCode::OK,
        Json(json!({"device_id":id,"token":hex::encode(token),"gateway_id":persisted.gateway_id})),
    )
}

async fn pairing_events(
    State(state): State<Gateway>,
    headers: HeaderMap,
    Query(query): Query<PairingEventQuery>,
    upgrade: WebSocketUpgrade,
) -> Response {
    let Ok(pairing_id) = Uuid::parse_str(&query.pairing_id) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let watch_token = headers
        .get(header::SEC_WEBSOCKET_PROTOCOL)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| {
            value.split(',').map(str::trim).find_map(|protocol| {
                protocol
                    .strip_prefix("zedlink-pairing-token-")
                    .map(str::to_owned)
            })
        })
        .and_then(|token| hex::decode(token).ok());
    let Some(watch_token) = watch_token.filter(|token| token.len() == 32) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let watch_digest = digest(&watch_token);
    let receiver = state.0.pairing_updates.subscribe();
    let mut pairing = state.0.pairing.lock().await;
    let Some(active) = pairing.as_ref() else {
        return StatusCode::GONE.into_response();
    };
    if active.id != pairing_id || !bool::from(active.watch_digest.ct_eq(&watch_digest)) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if Instant::now() >= active.expires {
        drop(state.0.pairing_updates.send(PairingUpdate {
            pairing_id,
            status: "expired",
            attempts_remaining: 0,
        }));
        *pairing = None;
        return StatusCode::GONE.into_response();
    }
    drop(pairing);
    let Ok(permit) = state.0.websocket_limit.clone().try_acquire_owned() else {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    };
    upgrade
        .protocols(["zedlink-pairing-v1"])
        .on_upgrade(move |socket| pairing_event_stream(socket, state, pairing_id, receiver, permit))
        .into_response()
}

async fn send_pairing_event(socket: &mut WebSocket, event: Value) -> bool {
    tokio::time::timeout(
        Duration::from_secs(5),
        socket.send(Message::Text(event.to_string().into())),
    )
    .await
    .is_ok_and(|result| result.is_ok())
}

async fn pairing_event_stream(
    mut socket: WebSocket,
    state: Gateway,
    pairing_id: Uuid,
    mut receiver: broadcast::Receiver<PairingUpdate>,
    _permit: tokio::sync::OwnedSemaphorePermit,
) {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            update = receiver.recv() => {
                match update {
                    Ok(update) if update.pairing_id == pairing_id => {
                        let terminal = matches!(update.status, "paired" | "expired" | "replaced");
                        if !send_pairing_event(&mut socket, json!({
                            "pairing_id": update.pairing_id,
                            "status": update.status,
                            "attempts_remaining": update.attempts_remaining,
                        })).await || terminal {
                            break;
                        }
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            _ = interval.tick() => {
                let (status, expires_seconds, attempts_remaining) = {
                    let mut pairing = state.0.pairing.lock().await;
                    match pairing.as_ref() {
                        Some(active) if active.id == pairing_id && Instant::now() < active.expires => (
                            "active",
                            active.expires.saturating_duration_since(Instant::now()).as_secs(),
                            5_u8.saturating_sub(active.attempts),
                        ),
                        Some(active) if active.id == pairing_id => {
                            *pairing = None;
                            ("expired", 0, 0)
                        }
                        _ => ("replaced", 0, 0),
                    }
                };
                if status == "expired" {
                    drop(state.0.pairing_updates.send(PairingUpdate {
                        pairing_id,
                        status,
                        attempts_remaining,
                    }));
                }
                if !send_pairing_event(&mut socket, json!({
                    "pairing_id": pairing_id,
                    "status": status,
                    "expires_seconds": expires_seconds,
                    "attempts_remaining": attempts_remaining,
                })).await || status != "active" {
                    break;
                }
            }
        }
    }
    if let Err(error) = socket.close().await {
        eprintln!("pairing event stream close failed: {error}");
    }
}

async fn notification_config(
    State(state): State<Gateway>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    let persisted = state.0.persisted.lock().await;
    let public_key = match state.vapid_public_key(&persisted) {
        Ok(public_key) => public_key,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error":"INTERNAL_ERROR"})),
            );
        }
    };
    let enabled = persisted
        .push_subscriptions
        .iter()
        .any(|subscription| subscription.device_id == device_id);
    (
        StatusCode::OK,
        Json(json!({
            "version": 1,
            "supported": true,
            "enabled": enabled,
            "application_server_key": public_key,
        })),
    )
}

async fn notification_subscribe(
    State(state): State<Gateway>,
    headers: HeaderMap,
    Json(subscription): Json<SubscriptionInfo>,
) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    if !valid_subscription(&subscription) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_SUBSCRIPTION"})),
        );
    }
    let mut persisted = state.0.persisted.lock().await;
    let mut next = persisted.clone();
    next.push_subscriptions
        .retain(|record| record.subscription.endpoint != subscription.endpoint);
    next.push_subscriptions.push(PushSubscription {
        device_id,
        subscription,
    });
    if save(&state.0.directory, &next).is_err() {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error":"INTERNAL_ERROR"})),
        );
    }
    *persisted = next;
    (StatusCode::OK, Json(json!({"enabled":true})))
}

async fn notification_unsubscribe(
    State(state): State<Gateway>,
    headers: HeaderMap,
    Json(request): Json<UnsubscribeRequest>,
) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    if request.endpoint.is_empty() || request.endpoint.len() > 2048 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_REQUEST"})),
        );
    }
    let mut persisted = state.0.persisted.lock().await;
    let mut next = persisted.clone();
    next.push_subscriptions.retain(|record| {
        record.device_id != device_id || record.subscription.endpoint != request.endpoint
    });
    if save(&state.0.directory, &next).is_err() {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error":"INTERNAL_ERROR"})),
        );
    }
    *persisted = next;
    (StatusCode::OK, Json(json!({"enabled":false})))
}

async fn notification_status(
    State(state): State<Gateway>,
    headers: HeaderMap,
    Json(request): Json<UnsubscribeRequest>,
) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    if request.endpoint.is_empty() || request.endpoint.len() > 2048 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_REQUEST"})),
        );
    }
    let enabled = state
        .0
        .persisted
        .lock()
        .await
        .push_subscriptions
        .iter()
        .any(|record| {
            record.device_id == device_id && record.subscription.endpoint == request.endpoint
        });
    (StatusCode::OK, Json(json!({"enabled":enabled})))
}

async fn notification_test(
    State(state): State<Gateway>,
    headers: HeaderMap,
    Json(request): Json<NotificationTestRequest>,
) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    let subscription = state
        .0
        .persisted
        .lock()
        .await
        .push_subscriptions
        .iter()
        .find(|record| {
            record.device_id == device_id && record.subscription.endpoint == request.endpoint
        })
        .cloned();
    let Some(subscription) = subscription else {
        return (
            StatusCode::CONFLICT,
            Json(json!({"error":"NOTIFICATIONS_DISABLED"})),
        );
    };
    match state
        .send_push(
            &subscription,
            "Notifications are ready for this device.",
            None,
        )
        .await
    {
        PushOutcome::Sent => (StatusCode::OK, Json(json!({"delivered":true}))),
        PushOutcome::Stale => (
            StatusCode::GONE,
            Json(json!({"error":"SUBSCRIPTION_EXPIRED"})),
        ),
        PushOutcome::Failed => (
            StatusCode::BAD_GATEWAY,
            Json(json!({"error":"PUSH_DELIVERY_FAILED"})),
        ),
    }
}

async fn apns_status(State(state): State<Gateway>, headers: HeaderMap) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    let enabled = state
        .0
        .persisted
        .lock()
        .await
        .apns_devices
        .iter()
        .any(|record| record.device_id == device_id);
    (
        StatusCode::OK,
        Json(json!({"supported":state.0.apns.is_some(), "enabled":enabled})),
    )
}

async fn apns_register(
    State(state): State<Gateway>,
    headers: HeaderMap,
    Json(request): Json<ApnsRegistrationRequest>,
) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    if state.0.apns.is_none() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"APNS_NOT_CONFIGURED"})),
        );
    }
    if !valid_apns_token(&request.token)
        || !matches!(request.environment.as_str(), "sandbox" | "production")
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_REQUEST"})),
        );
    }
    let token = request.token.to_ascii_lowercase();
    let mut persisted = state.0.persisted.lock().await;
    let mut next = persisted.clone();
    next.apns_devices
        .retain(|record| record.device_id != device_id && record.token != token);
    next.apns_devices.push(ApnsDevice {
        device_id,
        token,
        environment: request.environment,
    });
    if save(&state.0.directory, &next).is_err() {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error":"INTERNAL_ERROR"})),
        );
    }
    *persisted = next;
    (StatusCode::OK, Json(json!({"enabled":true})))
}

async fn apns_unregister(State(state): State<Gateway>, headers: HeaderMap) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    let mut persisted = state.0.persisted.lock().await;
    let mut next = persisted.clone();
    next.apns_devices
        .retain(|record| record.device_id != device_id);
    if save(&state.0.directory, &next).is_err() {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error":"INTERNAL_ERROR"})),
        );
    }
    *persisted = next;
    (StatusCode::OK, Json(json!({"enabled":false})))
}

async fn apns_test(State(state): State<Gateway>, headers: HeaderMap) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    let Some(provider) = &state.0.apns else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"APNS_NOT_CONFIGURED"})),
        );
    };
    let registration = state
        .0
        .persisted
        .lock()
        .await
        .apns_devices
        .iter()
        .find(|record| record.device_id == device_id)
        .cloned();
    let Some(registration) = registration else {
        return (
            StatusCode::CONFLICT,
            Json(json!({"error":"NOTIFICATIONS_DISABLED"})),
        );
    };
    let gateway_id = state.0.persisted.lock().await.gateway_id.to_string();
    match provider
        .send(
            &registration,
            "Native push is ready for this device.",
            &gateway_id,
            None,
            0,
        )
        .await
    {
        PushOutcome::Sent => (StatusCode::OK, Json(json!({"delivered":true}))),
        PushOutcome::Stale => (
            StatusCode::GONE,
            Json(json!({"error":"SUBSCRIPTION_EXPIRED"})),
        ),
        PushOutcome::Failed => (
            StatusCode::BAD_GATEWAY,
            Json(json!({"error":"PUSH_FAILED"})),
        ),
    }
}

/// Methods the phone may forward to the native probe. Everything else is refused
/// before it reaches Zed.
fn allowed_rpc_method(method: &str) -> bool {
    matches!(
        method,
        "instance.list"
            | "session.resume"
            | "instance.info"
            | "thread.list"
            | "thread.create"
            | "thread.create.options"
            | "thread.rename"
            | "thread.unexpose"
            | "thread.snapshot"
            | "thread.history"
            | "thread.events"
            | "thread.commands"
            | "thread.settings"
            | "thread.settings.update"
            | "thread.elicitations"
            | "elicitation.respond"
            | "thread.queue"
            | "thread.queue.clear"
            | "thread.edit_review"
            | "thread.edit_review.respond"
            | "terminal.list"
            | "terminal.snapshot"
            | "clipboard.read"
            | "clipboard.write"
            | "terminal.input"
            | "terminal.create"
            | "terminal.resize"
            | "task.list"
            | "task.stop"
            | "task.catalog"
            | "task.run"
            | "debugger.catalog"
            | "debugger.launch"
            | "debugger.snapshot"
            | "debugger.control"
            | "thread.approvals"
            | "approval.respond"
            | "project.files"
            | "project.upload.begin"
            | "project.upload.chunk"
            | "project.upload.commit"
            | "project.upload.abort"
            | "zed.status"
            | "zed.start"
            | "zed.restart"
            | "project.directory"
            | "project.file"
            | "project.search"
            | "changes.snapshot"
            | "changes.diff"
            | "changes.stage"
            | "changes.unstage"
            | "thread.send"
            | "thread.cancel"
            | "subagent.cancel"
            | "thread.rewind_image"
            | "thread.rewind"
            | "request.status"
            | "workspace.list"
            | "workspace.open"
            | "thread.open"
            | "host.directory"
            | "host.add"
            | "limits.list"
            | "summary.unread"
            | "summary.mark_read"
            | "autopilot.status"
            | "autopilot.schedule"
            | "autopilot.cancel"
            | "autopilot.thread"
            | "autopilot.settings"
            | "autopilot.history"
            | "stats.thread"
            | "stats.usage"
            | "stats.limits"
    )
}

/// Methods the gateway answers itself (no bridge call is forwarded).
fn gateway_local_method(method: &str) -> bool {
    method == "limits.list"
        || method.starts_with("summary.")
        || method.starts_with("autopilot.")
        || method.starts_with("stats.")
}

/// Bounds for the workspace/host methods. The native side validates again; the
/// gateway only refuses shapes that can never be valid.
fn valid_workspace_params(method: &str, params: &Value) -> bool {
    let bounded = |value: &Value, max: usize| {
        value.as_str().is_some_and(|text| {
            !text.is_empty() && text.len() <= max && !text.chars().any(char::is_control)
        })
    };
    match method {
        "workspace.open" => {
            bounded(&params["host_id"], 256)
                && params["paths"].as_array().is_some_and(|paths| {
                    !paths.is_empty()
                        && paths.len() <= 32
                        && paths.iter().all(|path| bounded(path, 4096))
                })
        }
        "thread.open" => bounded(&params["thread_id"], 128),
        "host.directory" => bounded(&params["host_id"], 256) && bounded(&params["path"], 4096),
        // Zed parses this like its "Connect SSH Server" dialog; it never reaches a shell.
        "host.add" => {
            bounded(&params["command"], 512)
                && params["command"]
                    .as_str()
                    .is_some_and(|command| !command.trim().is_empty())
        }
        _ => true,
    }
}

async fn rpc(State(state): State<Gateway>, headers: HeaderMap, body: Bytes) -> impl IntoResponse {
    let Some(device_id) = state.authorize(&headers).await else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"UNAUTHENTICATED"})),
        );
    };
    if body.len() > MAX_RPC {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(json!({"error":"PAYLOAD_TOO_LARGE"})),
        );
    }
    let mut request: Value = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error":"INVALID_REQUEST"})),
            );
        }
    };
    let Some(method) = request["method"].as_str().map(str::to_owned) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_REQUEST"})),
        );
    };
    if !allowed_rpc_method(&method) {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"error":"UNSUPPORTED_CAPABILITY"})),
        );
    }
    if !valid_workspace_params(&method, &request["params"]) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_REQUEST"})),
        );
    }
    let Some(original_request_id) = request["request_id"]
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 80)
        .map(str::to_owned)
    else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_REQUEST"})),
        );
    };
    let target_id = request
        .get("target_id")
        .and_then(Value::as_str)
        .map(str::to_owned);
    if target_id
        .as_ref()
        .is_some_and(|id| id.is_empty() || id.len() > 64)
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"INVALID_REQUEST"})),
        );
    }
    if let Some(object) = request.as_object_mut() {
        object.remove("target_id");
    }
    if method == "instance.list" {
        let result = state.instance_list().await;
        return (
            StatusCode::OK,
            Json(json!({"version":1,"request_id":original_request_id,"result":result})),
        );
    }
    if method.starts_with("zed.") || gateway_local_method(&method) {
        let params = &request["params"];
        let target = target_id.as_deref();
        let (status, body) = match method.split('.').next() {
            Some("zed") => state.zed_rpc(&method, target, params).await,
            Some("summary") => state.summary_rpc(&method, device_id, target, params).await,
            Some("autopilot") => state.autopilot_rpc(&method, target, params).await,
            Some("stats") => state.stats_rpc(&method, target, params).await,
            _ => (StatusCode::OK, Ok(state.limits_list().await)),
        };
        let body = match body {
            Ok(result) => json!({"version":1,"request_id":original_request_id,"result":result}),
            Err(error) => json!({"version":1,"request_id":original_request_id,"error":error}),
        };
        return (status, Json(body));
    }
    if method == "session.resume" {
        let Some(target_id) = target_id.as_deref() else {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error":"INVALID_REQUEST"})),
            );
        };
        let Ok(target) = state.target(Some(target_id)) else {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({"error":"UNKNOWN_TARGET"})),
            );
        };
        let params = &request["params"];
        let thread_id = params["thread_id"].as_str();
        let pending_id = params["pending_request_id"].as_str();
        if thread_id.is_some_and(|id| id.is_empty() || id.len() > 128)
            || pending_id.is_some_and(|id| id.is_empty() || id.len() > 80)
            || params
                .get("thread_id")
                .is_some_and(|value| !value.is_null() && !value.is_string())
            || params
                .get("pending_request_id")
                .is_some_and(|value| !value.is_null() && !value.is_string())
        {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error":"INVALID_REQUEST"})),
            );
        }
        let native_request = |method: &str, params: Value| {
            json!({
                "version": 1, "request_id": Uuid::new_v4().to_string(), "method": method, "params": params,
            })
        };
        let info_response = state
            .probe(Some(target_id), &native_request("instance.info", json!({})))
            .await;
        let Ok(info_response) = info_response else {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"error":"INSTANCE_UNAVAILABLE"})),
            );
        };
        let Some(info) = info_response.get("result") else {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"error":"INSTANCE_UNAVAILABLE"})),
            );
        };
        let list_response = state
            .probe(Some(target_id), &native_request("thread.list", json!({})))
            .await;
        let Ok(list_response) = list_response else {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"error":"INSTANCE_UNAVAILABLE"})),
            );
        };
        let Some(list) = list_response.get("result") else {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"error":"INSTANCE_UNAVAILABLE"})),
            );
        };
        if !info["instance_id"].is_string()
            || !info["epoch"].is_string()
            || !list["threads"].is_array()
            || info["instance_id"] != list["instance_id"]
            || info["epoch"] != list["epoch"]
        {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"error":"INSTANCE_UNAVAILABLE"})),
            );
        }
        let mut snapshot = Value::Null;
        if let Some(thread_id) = thread_id
            && list["threads"].as_array().is_some_and(|threads| {
                threads
                    .iter()
                    .any(|thread| thread["thread_id"] == thread_id)
            })
        {
            let tail_count = if params["instance_id"] == info["instance_id"]
                && params["epoch"] == info["epoch"]
            {
                16
            } else {
                64
            };
            let response = state
                .probe(
                    Some(target_id),
                    &native_request(
                        "thread.snapshot",
                        json!({
                            "thread_id": thread_id, "tail_entry_count": tail_count,
                        }),
                    ),
                )
                .await;
            let Ok(response) = response else {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    Json(json!({"error":"INSTANCE_UNAVAILABLE"})),
                );
            };
            if let Some(result) = response.get("result") {
                if result["instance_id"] != info["instance_id"]
                    || result["epoch"] != info["epoch"]
                    || result["thread_id"] != thread_id
                {
                    return (
                        StatusCode::SERVICE_UNAVAILABLE,
                        Json(json!({"error":"INSTANCE_UNAVAILABLE"})),
                    );
                }
                snapshot = result.clone();
            }
        }
        let mut pending_status = Value::Null;
        if let Some(pending_id) = pending_id {
            let response = state
                .probe(
                    Some(target_id),
                    &native_request(
                        "request.status",
                        json!({
                            "instance_id": info["instance_id"], "epoch": info["epoch"],
                            "original_request_id": format!("{device_id}:{pending_id}"),
                        }),
                    ),
                )
                .await;
            if let Ok(response) = response
                && let Some(result) = response.get("result")
            {
                pending_status = result.clone();
            }
        }
        let mut result = json!({
            "instance_id": info["instance_id"], "epoch": info["epoch"], "capabilities": info["capabilities"],
            "target": {"target_id": target_id, "label": target.label, "available": true},
            "threads": list["threads"], "snapshot": snapshot, "pending_status": pending_status,
        });
        // Leave room for the RPC envelope inside the client's 4 MiB response cap.
        let max_result_size = MAX_PROBE_RESPONSE as usize - 512;
        if serde_json::to_vec(&result).is_ok_and(|body| body.len() > max_result_size) {
            result["snapshot"] = Value::Null;
        }
        if serde_json::to_vec(&result).is_ok_and(|body| body.len() > max_result_size) {
            return (
                StatusCode::PAYLOAD_TOO_LARGE,
                Json(json!({"error":"RESPONSE_TOO_LARGE"})),
            );
        }
        return (
            StatusCode::OK,
            Json(json!({"version":1,"request_id":original_request_id,"result":result})),
        );
    }
    if method == "thread.send"
        && let Some(command) = request["params"]["text"]
            .as_str()
            .and_then(autopilot::parse_auto)
    {
        let (Ok(target), Some(thread_id)) = (
            state.target(target_id.as_deref()),
            valid_thread_id(&request["params"]["thread_id"]),
        ) else {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error":"INVALID_REQUEST"})),
            );
        };
        let target_id = target.id.clone();
        let body = match state
            .autopilot_command(&target_id, thread_id, command)
            .await
        {
            Ok(message) => json!({"version":1,"request_id":original_request_id,
                "result":{"intercepted":"autopilot","message":message}}),
            Err(code) => json!({"version":1,"request_id":original_request_id,
                "error":{"code":code}}),
        };
        return (StatusCode::OK, Json(body));
    }
    if matches!(
        method.as_str(),
        "thread.send"
            | "thread.create"
            | "thread.rewind_image"
            | "terminal.input"
            | "terminal.create"
            | "terminal.resize"
            | "task.stop"
            | "task.run"
            | "debugger.launch"
            | "debugger.control"
            | "changes.stage"
            | "changes.unstage"
    ) {
        request["request_id"] = json!(format!("{device_id}:{original_request_id}"));
    } else if method == "request.status" {
        let Some(original_send_id) = request["params"]["original_request_id"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 80)
            .map(str::to_owned)
        else {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error":"INVALID_REQUEST"})),
            );
        };
        request["params"]["original_request_id"] = json!(format!("{device_id}:{original_send_id}"));
    }
    match state.probe(target_id.as_deref(), &request).await {
        Ok(mut response) => {
            if method == "thread.send"
                && response.get("error").is_none_or(Value::is_null)
                && let (Ok(target), Some(thread_id)) = (
                    state.target(target_id.as_deref()),
                    request["params"]["thread_id"].as_str(),
                )
            {
                state.set_remote_thread(&target.id, thread_id, true).await;
                state.autopilot_exempt_turns(&target.id, thread_id);
            }
            response["request_id"] = json!(original_request_id);
            (StatusCode::OK, Json(response))
        }
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"INSTANCE_UNAVAILABLE"})),
        ),
    }
}
async fn events(
    State(state): State<Gateway>,
    headers: HeaderMap,
    Query(query): Query<EventQuery>,
    upgrade: WebSocketUpgrade,
) -> impl IntoResponse {
    let websocket_token = headers
        .get(header::SEC_WEBSOCKET_PROTOCOL)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| {
            value
                .split(',')
                .map(str::trim)
                .find_map(|protocol| protocol.strip_prefix("zedlink-token-").map(str::to_owned))
        });
    let device_id = if let Some(device_id) = state.authorize(&headers).await {
        Some(device_id)
    } else if let Some(token) = websocket_token.as_deref() {
        state.authorize_token(token).await
    } else {
        None
    };
    let Some(device_id) = device_id else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    if query.thread_id.is_empty() || query.thread_id.len() > 128 {
        return StatusCode::BAD_REQUEST.into_response();
    }
    if state.target(query.target_id.as_deref()).is_err() {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Ok(permit) = state.0.websocket_limit.clone().try_acquire_owned() else {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    };
    upgrade
        .protocols(["zedlink-v1"])
        .on_upgrade(move |socket| event_stream(socket, state, device_id, query, permit))
        .into_response()
}
async fn event_stream(
    mut socket: WebSocket,
    state: Gateway,
    device_id: Uuid,
    query: EventQuery,
    _permit: tokio::sync::OwnedSemaphorePermit,
) {
    let mut sequence = query.after_sequence.unwrap_or(0);
    let mut interval = tokio::time::interval(EVENT_POLL);
    let reason: String = 'stream: loop {
        tokio::select! {
            biased;
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Ping(payload))) => {
                    if !tokio::time::timeout(Duration::from_secs(5), socket.send(Message::Pong(payload)))
                        .await
                        .is_ok_and(|result| result.is_ok())
                    {
                        break 'stream "pong failed".into();
                    }
                    continue;
                }
                Some(Ok(Message::Close(_))) | None => break 'stream "client closed".into(),
                Some(Err(error)) => break 'stream format!("client error: {error}"),
                Some(Ok(_)) => continue,
            },
            _ = interval.tick() => {}
        }
        if !state.device_exists(device_id).await {
            break 'stream "device revoked".into();
        }
        let request = json!({"version":1,"request_id":Uuid::new_v4().to_string(),
            "method":"thread.events","params":{"thread_id":query.thread_id,"after_sequence":sequence}});
        // The native probe can take six seconds. Keep reading the socket while it
        // is pending so a client heartbeat is answered without waiting for Zed.
        let probe = state.probe(query.target_id.as_deref(), &request);
        tokio::pin!(probe);
        let response = loop {
            tokio::select! {
                incoming = socket.recv() => match incoming {
                    Some(Ok(Message::Ping(payload))) => {
                        if !tokio::time::timeout(Duration::from_secs(5), socket.send(Message::Pong(payload)))
                            .await.is_ok_and(|result| result.is_ok()) {
                            break 'stream "pong failed".into();
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break 'stream "client closed".into(),
                    Some(Err(error)) => break 'stream format!("client error: {error}"),
                    Some(Ok(_)) => {}
                },
                result = &mut probe => break result,
            }
        };
        let response = match response {
            Ok(response) => response,
            Err(_) => json!({"version":1,"error":{"code":"INSTANCE_UNAVAILABLE"}}),
        };
        // A device may be revoked while the native poll is in flight.
        if !state.device_exists(device_id).await {
            break 'stream "device revoked".into();
        }
        if let Some(next) = response["result"]["last_sequence"].as_u64() {
            sequence = next;
        }
        let error_code = response
            .get("error")
            .map(|error| error["code"].as_str().unwrap_or("UNKNOWN").to_owned());
        if tokio::time::timeout(
            Duration::from_secs(5),
            socket.send(Message::Text(response.to_string().into())),
        )
        .await
        .map_or(true, |result| result.is_err())
        {
            break 'stream "send to client failed".into();
        }
        if let Some(code) = error_code {
            break 'stream format!("bridge error {code}");
        }
    };
    let thread: String = query.thread_id.chars().take(8).collect();
    eprintln!(
        "event stream thread={thread} target={} after_sequence={sequence} closed: {reason}",
        query.target_id.as_deref().unwrap_or("default")
    );
    if let Err(error) = socket.close().await {
        // The phone usually drops the socket first; that is not a gateway failure.
        if !reason.starts_with("client") {
            eprintln!("event stream close failed: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_methods_are_allowed_and_bounded() {
        for method in [
            "workspace.list",
            "workspace.open",
            "thread.open",
            "host.directory",
            "host.add",
            "project.directory",
        ] {
            assert!(allowed_rpc_method(method), "{method}");
        }
        assert!(!allowed_rpc_method("host.shell"));
        assert!(!allowed_rpc_method("workspace.delete"));

        assert!(valid_workspace_params("workspace.list", &json!({})));
        assert!(valid_workspace_params(
            "workspace.open",
            &json!({"host_id": "ssh-1", "paths": ["/home/dev0/prj"]})
        ));
        assert!(!valid_workspace_params(
            "workspace.open",
            &json!({"host_id": "ssh-1", "paths": []})
        ));
        assert!(!valid_workspace_params(
            "workspace.open",
            &json!({"host_id": "ssh-1", "paths": "/tmp"})
        ));
        assert!(!valid_workspace_params(
            "workspace.open",
            &json!({"paths": ["/tmp"]})
        ));
        assert!(valid_workspace_params(
            "thread.open",
            &json!({"thread_id": "abc"})
        ));
        assert!(!valid_workspace_params(
            "thread.open",
            &json!({"thread_id": null})
        ));
        assert!(valid_workspace_params(
            "host.directory",
            &json!({"host_id": "local", "path": "~"})
        ));
        assert!(!valid_workspace_params(
            "host.directory",
            &json!({"host_id": "local", "path": "a\nb"})
        ));
        assert!(valid_workspace_params(
            "host.add",
            &json!({"command": "ssh dev0@hotbot2 -p 2222"})
        ));
        assert!(!valid_workspace_params(
            "host.add",
            &json!({"command": "   "})
        ));
        assert!(!valid_workspace_params(
            "host.add",
            &json!({"command": "ssh a\r\nb"})
        ));
        assert!(!valid_workspace_params(
            "host.add",
            &json!({"command": "x".repeat(600)})
        ));
    }

    #[test]
    fn creates_stable_vapid_key_pair() {
        let private_key = new_vapid_private_key();
        let first = VapidSignatureBuilder::from_base64_no_sub(&private_key).unwrap();
        let second = VapidSignatureBuilder::from_base64_no_sub(&private_key).unwrap();
        assert_eq!(first.get_public_key(), second.get_public_key());
        assert_eq!(first.get_public_key().len(), 65);
    }

    #[test]
    fn validates_web_push_subscription_shape() {
        let subscription = SubscriptionInfo::new(
            "https://fcm.googleapis.com/device".to_owned(),
            URL_SAFE_NO_PAD.encode([4_u8].into_iter().chain([7_u8; 64]).collect::<Vec<_>>()),
            URL_SAFE_NO_PAD.encode([9_u8; 16]),
        );
        assert!(valid_subscription(&subscription));

        let mut insecure = subscription.clone();
        insecure.endpoint = "http://push.example.test/device".into();
        assert!(!valid_subscription(&insecure));

        let mut private_endpoint = subscription.clone();
        private_endpoint.endpoint = "https://127.0.0.1/device".into();
        assert!(!valid_subscription(&private_endpoint));

        let mut malformed = subscription;
        malformed.keys.p256dh = URL_SAFE_NO_PAD.encode([4_u8; 32]);
        assert!(!valid_subscription(&malformed));
    }

    #[test]
    fn apns_topics_are_bundle_ids() {
        assert!(valid_apns_topic(DEFAULT_APNS_TOPIC));
        assert!(valid_apns_topic("dev.zedlink.app"));
        assert!(!valid_apns_topic(""));
        assert!(!valid_apns_topic(".cx.m42.zlink"));
        assert!(!valid_apns_topic("cx.m42.zlink\r\napns-priority: 10"));
        assert!(!valid_apns_topic("cx.m42/zlink"));
    }

    #[test]
    fn apns_tokens_are_bounded_and_provider_claims_are_scoped() -> Result<()> {
        assert!(valid_apns_token(&"ab".repeat(32)));
        assert!(!valid_apns_token("ab/../device"));
        assert!(!valid_apns_token(&"ab".repeat(257)));
        let provider = ApnsProvider {
            team_id: "ABCDEFGHIJ".into(),
            key_id: "KLMNOPQRST".into(),
            topic: DEFAULT_APNS_TOPIC.into(),
            key_pem: ES256KeyPair::generate().to_pem()?,
            client: HttpClient::new()?,
        };
        let signed = provider.provider_token()?;
        let parts = signed.split('.').collect::<Vec<_>>();
        assert_eq!(parts.len(), 3);
        let header: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0])?)?;
        let claims: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1])?)?;
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "KLMNOPQRST");
        assert_eq!(claims["iss"], "ABCDEFGHIJ");
        assert!(claims["iat"].is_number());
        assert!(claims.get("exp").is_none());
        Ok(())
    }

    #[test]
    fn loads_state_from_before_notifications() {
        let gateway_id = Uuid::new_v4();
        let state: Persisted = serde_json::from_value(json!({
            "gateway_id": gateway_id,
            "devices": [],
        }))
        .unwrap();
        assert_eq!(state.gateway_id, gateway_id);
        assert!(state.vapid_private_key.is_empty());
        assert!(state.push_subscriptions.is_empty());
        assert!(state.apns_devices.is_empty());
    }

    #[test]
    fn detects_replaced_and_child_approvals_without_count_changes() {
        let before = json!({"epoch":"a", "pending_approvals":[{"approval_id":"old","turn_id":1}]});
        let after = json!({"epoch":"a", "subagents":[{"session_id":"child","pending_approvals":[{"approval_id":"new","turn_id":2}]}]});
        let previous = ThreadObservation {
            approvals: pending_approval_keys(&before),
            ..Default::default()
        };
        let current = ThreadObservation {
            approvals: pending_approval_keys(&after),
            ..Default::default()
        };
        assert_eq!(previous.approvals.len(), current.approvals.len());
        assert_eq!(
            thread_notification(&previous, &current, None),
            Some(NotificationEvent::Approval)
        );
        assert_eq!(thread_notification(&current, &current, None), None);
        assert_eq!(
            thread_notification(&ThreadObservation::default(), &current, None),
            Some(NotificationEvent::Approval)
        );
    }

    #[test]
    fn chooses_failure_notification_before_generic_completion() {
        let generating = ThreadObservation {
            status: "Generating".into(),
            approvals: HashSet::new(),
            inputs: HashSet::new(),
            had_error: false,
            last_sequence: 1,
            ..Default::default()
        };
        let failed = ThreadObservation {
            status: "Idle".into(),
            approvals: HashSet::new(),
            inputs: HashSet::new(),
            had_error: true,
            last_sequence: 2,
            ..Default::default()
        };
        assert_eq!(
            thread_notification(&generating, &failed, Some("error")),
            Some(NotificationEvent::Error)
        );
        assert_eq!(thread_notification(&failed, &failed, None), None);
    }

    #[test]
    fn distinguishes_native_completion_cancellation_and_unknown_stop() {
        let running = ThreadObservation {
            status: "Generating".into(),
            last_sequence: 4,
            ..Default::default()
        };
        let idle = ThreadObservation {
            status: "Idle".into(),
            last_sequence: 5,
            ..Default::default()
        };
        assert_eq!(
            thread_notification(&running, &idle, Some("completed")),
            Some(NotificationEvent::Done)
        );
        assert_eq!(
            thread_notification(&running, &idle, Some("cancelled")),
            Some(NotificationEvent::Stopped("отменено"))
        );
        assert_eq!(
            thread_notification(&running, &idle, Some("max_turn_requests")),
            Some(NotificationEvent::Stopped("лимит запросов"))
        );
        assert_eq!(
            thread_notification(&running, &idle, None),
            Some(NotificationEvent::Done)
        );
        assert_eq!(thread_notification(&idle, &idle, None), None);
    }

    #[test]
    fn detects_new_input_without_repeating_existing_request() {
        let waiting = ThreadObservation {
            inputs: HashSet::from(["request-a".into()]),
            ..Default::default()
        };
        assert_eq!(
            thread_notification(&ThreadObservation::default(), &waiting, None),
            Some(NotificationEvent::Input)
        );
        assert_eq!(thread_notification(&waiting, &waiting, None), None);
    }

    #[test]
    fn stop_reason_is_bounded_by_authoritative_snapshot_sequence() {
        let events = json!([
            {"sequence": 4, "kind": "turn.stopped", "stop_reason": "completed"},
            {"sequence": 5, "kind": "status.changed"},
            {"sequence": 6, "kind": "turn.stopped", "stop_reason": "cancelled"},
        ]);
        assert_eq!(latest_stop_reason(&events, 5), Some("completed"));
        assert_eq!(latest_stop_reason(&events, 6), Some("cancelled"));
        assert_eq!(latest_stop_reason(&events, 3), None);
    }

    #[test]
    fn only_desktop_user_messages_release_remote_threads() {
        let events = json!([
            {"sequence": 2, "kind": "entry.added", "entry_kind": "user", "origin": "remote"},
            {"sequence": 3, "kind": "entry.added"},
            {"sequence": 5, "kind": "entry.added", "entry_kind": "user", "origin": "local", "entry_index": 7},
        ]);
        assert!(!has_local_user_message(&events, 4));
        assert!(has_local_user_message(&events, 5));
        assert!(!has_local_user_message(&json!([]), 9));
        let relabelled = json!([
            {"sequence": 1, "kind": "entry.added", "entry_kind": "user", "origin": "local", "entry_index": 3},
            {"sequence": 2, "kind": "entry.updated", "entry_kind": "user", "origin": "remote", "entry_index": 3},
        ]);
        assert!(!has_local_user_message(&relabelled, 2));
    }

    #[test]
    fn push_text_names_thread_project_and_reply() {
        let row = json!({"title": "Old title", "host_label": "hotbot2", "project": "dns",
            "workspace_label": "infra-dns"});
        let snapshot = json!({"title": "Настройки DNS", "entries_meta": [
            {"kind": "assistant", "segments": [{"kind": "assistant", "text": "старый ответ"}]},
            {"kind": "user"},
            {"kind": "assistant", "segments": [
                {"kind": "reasoning", "text": "думаю"},
                {"kind": "assistant", "text": "Записи   обновлены,\nTTL 300."}]},
            {"kind": "tool", "name": "edit"},
        ]});
        assert_eq!(
            push_heading(&row, &snapshot),
            (
                "Настройки DNS".to_owned(),
                Some("hotbot2 · infra-dns".to_owned())
            )
        );
        assert_eq!(
            push_body(NotificationEvent::Done, &snapshot),
            "Готово: Записи обновлены, TTL 300."
        );
        let long = "я".repeat(300);
        let reply = push_body(
            NotificationEvent::Done,
            &json!({"entries_meta": [{"kind": "assistant",
                "segments": [{"kind": "assistant", "text": long}]}]}),
        );
        assert_eq!(
            reply.chars().count(),
            "Готово: ".chars().count() + PUSH_PREVIEW_CHARS + 1
        );
        assert_eq!(
            push_body(
                NotificationEvent::Approval,
                &json!({"pending_approvals": [{"tool_name": "terminal"}]})
            ),
            "Нужно подтверждение: terminal"
        );
        assert_eq!(
            push_heading(&json!({}), &json!({})),
            ("ZLink".to_owned(), None)
        );
    }

    #[test]
    fn turn_usage_is_read_from_stopped_events_in_range() {
        let events = json!([
            {"sequence": 3, "kind": "turn.stopped", "usage": {"input_tokens": 9}},
            {"sequence": 4, "kind": "entry.updated"},
            {"sequence": 5, "kind": "turn.stopped", "stop_reason": "completed",
             "usage": {"input_tokens": 10, "output_tokens": 2, "cache_read_tokens": 100,
                       "cache_write_tokens": 5, "thought_tokens": 1}},
            // Old bridges send no usage.
            {"sequence": 6, "kind": "turn.stopped", "stop_reason": "completed"},
            {"sequence": 8, "kind": "turn.stopped", "usage": {"input_tokens": 1}},
        ]);
        let usages = turn_usages(&events, 3, 7);
        assert_eq!(usages.len(), 1);
        assert_eq!(usages[0].0, 5);
        assert_eq!(usages[0].1.cache_read, 100);
        assert_eq!(usages[0].1.thought, 1);
        assert_eq!(
            usage_agent(&json!({"agent": {"id": "claude-acp", "name": "Claude Agent"}})),
            "claude"
        );
        assert_eq!(
            usage_agent(&json!({"agent": {"id": "zed", "name": "Zed Agent"}})),
            "zed"
        );
        assert_eq!(usage_agent(&json!({})), "unknown");
    }

    #[test]
    fn listeners_may_bind_private_and_mesh_addresses_only() {
        for address in [
            "127.0.0.1",
            "10.1.2.3",
            "100.64.0.1",
            "::1",
            "fd7a:115c::1",
            "200::1",
            "201:abcd::1",
            "3ff:ffff::1",
        ] {
            assert!(private_ip(address.parse().unwrap()), "{address}");
        }
        for address in ["8.8.8.8", "2001:db8::1", "400::1", "1ff::1", "fe80::1"] {
            assert!(!private_ip(address.parse().unwrap()), "{address}");
        }
    }

    #[test]
    fn running_subagents_are_not_a_stall() {
        assert!(!subagents_running(&json!({"subagents": []})));
        assert!(subagents_running(
            &json!({"subagents": [{"current_turn_id": 3}]})
        ));
        assert!(subagents_running(
            &json!({"subagents": [{"current_turn_id": null, "status": "InProgress"}]})
        ));
        assert!(!subagents_running(
            &json!({"subagents": [{"current_turn_id": null, "status": "Completed"}]})
        ));
    }

    #[test]
    fn gateway_local_methods_are_allowed_and_not_forwarded() {
        for method in [
            "limits.list",
            "summary.unread",
            "summary.mark_read",
            "autopilot.status",
            "autopilot.schedule",
            "autopilot.cancel",
            "autopilot.thread",
            "autopilot.settings",
            "autopilot.history",
            "stats.thread",
            "stats.usage",
            "stats.limits",
        ] {
            assert!(allowed_rpc_method(method), "{method}");
            assert!(gateway_local_method(method), "{method}");
        }
        assert!(!allowed_rpc_method("autopilot.run"));
        assert!(!gateway_local_method("thread.send"));
        assert!(!gateway_local_method("agent.limits"));
    }

    #[test]
    fn state_from_wave_two_loads_with_wave_three_defaults() {
        let state: Persisted = serde_json::from_value(json!({
            "gateway_id": Uuid::new_v4(), "devices": [], "remote_threads": ["d:t"],
        }))
        .unwrap();
        assert!(state.limits.is_empty());
        assert!(state.unread.events.is_empty());
        assert!(state.autopilot.settings.enabled);
        assert!(state.autopilot.auto_continue("d", "t"));
    }

    #[test]
    fn apns_payload_carries_routing_for_tap() {
        let message = PushMessage {
            title: "T".into(),
            subtitle: Some("here · zed".into()),
            body: "Готово".into(),
            event: NotificationEvent::Done,
            target_id: "desktop".into(),
            thread_id: "t".repeat(80),
            instance_id: "i1".into(),
            epoch: "e1".into(),
            project_id: Some("p1".into()),
            host_id: None,
        };
        let payload = apns_payload(&message, "g1", 7, 3);
        assert_eq!(payload["type"], "push");
        assert_eq!(payload["aps"]["badge"], 3);
        assert_eq!(payload["instance"], "i1");
        assert_eq!(payload["epoch"], "e1");
        assert_eq!(payload["project_id"], "p1");
        assert_eq!(payload["aps"]["thread-id"], message.thread_id);
        assert_eq!(payload["aps"]["alert"]["subtitle"], "here · zed");
        assert_eq!(apns_collapse_id(&message).len(), 64);
    }
}
