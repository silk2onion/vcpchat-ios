use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;
use url::Url;

const MAX_HTTP_BODY: usize = 2_000_000;
const DEVICE_HEADER_LIMIT: usize = 8_000;
const MAX_STREAM_BYTES: usize = 8_000_000;
const STREAM_IDLE_LIMIT: Duration = Duration::from_secs(180);
const FINISHED_STREAM_TTL: Duration = Duration::from_secs(30 * 60);

/// Everything a stream has produced, kept in Rust so the WebView can switch topics, be suspended
/// or even reload and still replay the reply from any sequence number.
#[derive(Default)]
struct StreamLog {
    chunks: Vec<String>,
    bytes: usize,
    state: StreamState,
    error: String,
    finished_at: Option<Instant>,
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
enum StreamState {
    #[default]
    Running,
    Done,
    Error,
    Cancelled,
}

impl StreamState {
    fn as_str(self) -> &'static str {
        match self {
            StreamState::Running => "running",
            StreamState::Done => "done",
            StreamState::Error => "error",
            StreamState::Cancelled => "cancelled",
        }
    }
}

struct StreamEntry {
    token: CancellationToken,
    log: Arc<Mutex<StreamLog>>,
}

struct SocketWrite {
    text: String,
    receipt: oneshot::Sender<Result<(), String>>,
}

struct SocketEntry {
    token: CancellationToken,
    sender: Arc<Mutex<Option<mpsc::Sender<SocketWrite>>>>,
}

pub struct NetState {
    client: reqwest::Client,
    streams: Mutex<HashMap<String, StreamEntry>>,
    sockets: Mutex<HashMap<String, SocketEntry>>,
}

impl NetState {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(20))
            .tcp_keepalive(Duration::from_secs(30))
            .user_agent("VCPChat-iOS/0.1")
            .build()
            .expect("HTTP client");
        Self {
            client,
            streams: Mutex::new(HashMap::new()),
            sockets: Mutex::new(HashMap::new()),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartStream {
    pub request_id: String,
    pub url: String,
    pub api_key: String,
    pub body: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HttpCall {
    pub method: String,
    pub url: String,
    pub headers: HashMap<String, String>,
    pub body: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HttpResult {
    pub status: u16,
    pub body: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StreamEvent {
    request_id: String,
    kind: String,
    text: String,
    /// For a chunk, its index; for a final event, the total number of chunks.
    seq: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamSnapshot {
    pub from_seq: usize,
    pub chunks: Vec<String>,
    pub state: String,
    pub error: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SocketEvent {
    channel: String,
    kind: String,
    text: String,
}

pub fn validate_http_url(raw: &str) -> Result<Url, String> {
    validate_url(raw, &["http", "https"])
}

pub fn validate_ws_url(raw: &str) -> Result<Url, String> {
    validate_url(raw, &["ws", "wss"])
}

fn validate_url(raw: &str, schemes: &[&str]) -> Result<Url, String> {
    if raw.chars().any(char::is_control) {
        return Err("URL 不能包含控制字符".into());
    }
    let url = Url::parse(raw).map_err(|_| "URL 格式无效".to_string())?;
    if !schemes.contains(&url.scheme()) {
        return Err("URL 协议不被允许".into());
    }
    if url.host_str().is_none() {
        return Err("URL 缺少主机名".into());
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("URL 不能包含用户名或密码".into());
    }
    Ok(url)
}

pub async fn spawn_stream(app: AppHandle, state: &NetState, request: StartStream) -> Result<(), String> {
    validate_http_url(&request.url)?;
    if request.body.len() > MAX_HTTP_BODY {
        return Err("请求体过大".into());
    }
    let token = CancellationToken::new();
    let log = Arc::new(Mutex::new(StreamLog::default()));
    {
        let mut guard = state.streams.lock().map_err(|_| "内部锁失败".to_string())?;
        forget_finished(&mut guard, Instant::now());
        let entry = StreamEntry {
            token: token.clone(),
            log: log.clone(),
        };
        if let Some(previous) = guard.insert(request.request_id.clone(), entry) {
            previous.token.cancel();
        }
    }
    let client = state.client.clone();
    crate::background::stream_started(&app);
    tauri::async_runtime::spawn(async move {
        let outcome = run_stream(&client, &app, &request, &log, token.clone()).await;
        let (final_state, message) = match outcome {
            Ok(()) => (StreamState::Done, String::new()),
            Err(_) if token.is_cancelled() => (StreamState::Cancelled, String::new()),
            Err(message) => (StreamState::Error, message),
        };
        let total = finish_log(&log, final_state, &message);
        emit_stream(&app, &request.request_id, final_state.as_str(), &message, total);
        crate::background::stream_finished(&app);
    });
    Ok(())
}

fn forget_finished(streams: &mut HashMap<String, StreamEntry>, now: Instant) {
    streams.retain(|_, entry| match entry.log.lock() {
        Ok(log) => log.finished_at.map(|at| now.duration_since(at) < FINISHED_STREAM_TTL).unwrap_or(true),
        Err(_) => false,
    });
}

fn finish_log(log: &Mutex<StreamLog>, state: StreamState, message: &str) -> usize {
    let Ok(mut log) = log.lock() else { return 0 };
    log.state = state;
    log.error = message.to_string();
    log.finished_at = Some(Instant::now());
    log.chunks.len()
}

fn append_chunk(log: &Mutex<StreamLog>, text: String) -> Result<usize, String> {
    let mut log = log.lock().map_err(|_| "内部锁失败".to_string())?;
    if log.bytes + text.len() > MAX_STREAM_BYTES {
        return Err("回复超过 8MB，已停止接收".into());
    }
    log.bytes += text.len();
    log.chunks.push(text);
    Ok(log.chunks.len() - 1)
}

async fn run_stream(
    client: &reqwest::Client,
    app: &AppHandle,
    request: &StartStream,
    log: &Mutex<StreamLog>,
    token: CancellationToken,
) -> Result<(), String> {
    let send = client
        .post(&request.url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {}", request.api_key))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .header(reqwest::header::ACCEPT, "text/event-stream, application/json")
        .body(request.body.clone())
        .send();
    let response = tokio::select! {
        _ = token.cancelled() => return Err("cancelled".into()),
        response = send => response.map_err(|error| format!("无法连接服务器: {error}"))?,
    };
    if response.status().is_redirection() {
        return Err("服务器要求重定向，已拒绝以免密钥离开原主机".into());
    }
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("HTTP {status}：{}", clip(&body, 500)));
    }
    let mut stream = response.bytes_stream();
    let mut decoder = Utf8Stream::default();
    loop {
        let next = tokio::select! {
            _ = token.cancelled() => return Err("cancelled".into()),
            item = tokio::time::timeout(STREAM_IDLE_LIMIT, stream.next()) => item,
        };
        let done = matches!(next, Ok(None));
        let text = match next {
            Err(_) => return Err(format!("流中断：{} 秒没有收到数据", STREAM_IDLE_LIMIT.as_secs())),
            Ok(Some(Ok(bytes))) => decoder.push(&bytes),
            Ok(Some(Err(error))) => return Err(format!("流中断: {error}")),
            Ok(None) => decoder.finish(),
        };
        if !text.is_empty() {
            let seq = append_chunk(log, text.clone())?;
            emit_stream(app, &request.request_id, "chunk", &text, seq);
        }
        if done {
            return Ok(());
        }
    }
}

/// Decodes UTF-8 across network chunks, holding back a character split between two reads.
#[derive(Default)]
struct Utf8Stream {
    pending: Vec<u8>,
}

impl Utf8Stream {
    fn push(&mut self, bytes: &[u8]) -> String {
        self.pending.extend_from_slice(bytes);
        let mut out = String::new();
        loop {
            match std::str::from_utf8(&self.pending) {
                Ok(text) => {
                    out.push_str(text);
                    self.pending.clear();
                    return out;
                }
                Err(error) => {
                    let valid = error.valid_up_to();
                    out.push_str(std::str::from_utf8(&self.pending[..valid]).unwrap_or_default());
                    match error.error_len() {
                        None => {
                            self.pending.drain(..valid);
                            return out;
                        }
                        Some(len) => {
                            out.push(char::REPLACEMENT_CHARACTER);
                            self.pending.drain(..valid + len);
                        }
                    }
                }
            }
        }
    }

    fn finish(&mut self) -> String {
        let rest = String::from_utf8_lossy(&self.pending).into_owned();
        self.pending.clear();
        rest
    }
}

pub fn cancel_stream(state: &NetState, request_id: &str) -> Result<(), String> {
    let guard = state.streams.lock().map_err(|_| "内部锁失败".to_string())?;
    if let Some(entry) = guard.get(request_id) {
        entry.token.cancel();
    }
    Ok(())
}

pub fn stream_snapshot(state: &NetState, request_id: &str, from_seq: usize) -> Result<StreamSnapshot, String> {
    let guard = state.streams.lock().map_err(|_| "内部锁失败".to_string())?;
    let Some(entry) = guard.get(request_id) else {
        return Ok(StreamSnapshot {
            from_seq,
            chunks: Vec::new(),
            state: "missing".into(),
            error: String::new(),
        });
    };
    let log = entry.log.lock().map_err(|_| "内部锁失败".to_string())?;
    Ok(StreamSnapshot {
        from_seq,
        chunks: log.chunks.iter().skip(from_seq).cloned().collect(),
        state: log.state.as_str().into(),
        error: log.error.clone(),
    })
}

/// Drops a finished stream's log once the frontend has saved the reply.
pub fn release_stream(state: &NetState, request_id: &str) -> Result<(), String> {
    let mut guard = state.streams.lock().map_err(|_| "内部锁失败".to_string())?;
    let finished = guard
        .get(request_id)
        .map(|entry| entry.log.lock().map(|log| log.state != StreamState::Running).unwrap_or(true))
        .unwrap_or(false);
    if finished {
        guard.remove(request_id);
    }
    Ok(())
}

pub async fn http_request(state: &NetState, call: HttpCall) -> Result<HttpResult, String> {
    validate_http_url(&call.url)?;
    let method = match call.method.to_ascii_uppercase().as_str() {
        "GET" => reqwest::Method::GET,
        "POST" => reqwest::Method::POST,
        _ => return Err("只允许 GET 和 POST".into()),
    };
    if call.body.as_ref().map(|body| body.len()).unwrap_or(0) > MAX_HTTP_BODY {
        return Err("请求体过大".into());
    }
    let mut builder = state.client.request(method, &call.url).timeout(Duration::from_secs(45));
    for (name, value) in &call.headers {
        if !allowed_header(name) || value.len() > DEVICE_HEADER_LIMIT {
            continue;
        }
        builder = builder.header(name, value);
    }
    if let Some(body) = call.body {
        builder = builder.body(body);
    }
    let response = builder.send().await.map_err(|error| format!("无法连接服务器: {error}"))?;
    if response.status().is_redirection() {
        return Err("服务器要求重定向，已拒绝".into());
    }
    let status = response.status().as_u16();
    let mut body = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| format!("读取响应失败: {error}"))?;
        if body.len() + chunk.len() > MAX_HTTP_BODY {
            return Err("响应超过 2MB".into());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(HttpResult {
        status,
        body: String::from_utf8_lossy(&body).into_owned(),
    })
}

fn allowed_header(name: &str) -> bool {
    matches!(name.to_ascii_lowercase().as_str(), "authorization" | "accept" | "content-type")
}

/// Audio and MiMo PCM/SSE are binary, unlike the existing text-only HTTP entry point.
pub async fn audio_request(state: &NetState, call: HttpCall) -> Result<Vec<u8>, String> {
    validate_http_url(&call.url)?;
    let body = call.body.unwrap_or_default();
    if body.len() > MAX_HTTP_BODY { return Err("语音请求过大".into()); }
    let mut builder = state.client.post(&call.url).timeout(Duration::from_secs(90));
    for (name, value) in &call.headers {
        if allowed_header(name) && value.len() <= DEVICE_HEADER_LIMIT {
            builder = builder.header(name, value);
        }
    }
    let response = builder.body(body).send().await.map_err(|e| format!("语音服务连接失败: {e}"))?;
    let status = response.status();
    let content_type = response.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("语音接收失败: {e}"))?;
        if bytes.len() + chunk.len() > 16_000_000 { return Err("语音响应超过 16MB，请分段朗读".into()); }
        bytes.extend_from_slice(&chunk);
    }
    if !status.is_success() {
        return Err(format!("语音 HTTP {}: {}", status.as_u16(), clip(&String::from_utf8_lossy(&bytes), 300)));
    }
    if !content_type.starts_with("audio/") && !content_type.contains("text/event-stream") {
        return Err(format!("语音服务未返回音频或 MiMo 音频流（{content_type}）"));
    }
    Ok(bytes)
}

pub async fn socket_connect(app: AppHandle, state: &NetState, channel: String, url: String) -> Result<(), String> {
    if channel != "log" && channel != "info" {
        return Err("未知通道".into());
    }
    validate_ws_url(&url)?;
    let token = CancellationToken::new();
    let sender = Arc::new(Mutex::new(None));
    {
        let mut guard = state.sockets.lock().map_err(|_| "内部锁失败".to_string())?;
        if let Some(previous) = guard.insert(channel.clone(), SocketEntry { token: token.clone(), sender: sender.clone() }) {
            previous.token.cancel();
        }
    }
    tauri::async_runtime::spawn(async move {
        run_socket(app, channel, url, token, sender).await;
    });
    Ok(())
}

pub fn socket_disconnect(state: &NetState, channel: &str) -> Result<(), String> {
    let mut guard = state.sockets.lock().map_err(|_| "内部锁失败".to_string())?;
    if let Some(entry) = guard.remove(channel) {
        entry.token.cancel();
    }
    Ok(())
}

pub async fn socket_send(state: &NetState, channel: &str, text: String) -> Result<(), String> {
    if channel != "log" || text.len() > 16_000 { return Err("审批消息无效".into()); }
    let payload: serde_json::Value = serde_json::from_str(&text).map_err(|_| "审批 JSON 无效")?;
    if payload["type"] != "tool_approval_response" || payload["data"]["requestId"].as_str().unwrap_or("").is_empty() || !payload["data"]["approved"].is_boolean() {
        return Err("审批缺少 requestId 或 approved".into());
    }
    let sender = {
        let guard = state.sockets.lock().map_err(|_| "内部锁失败")?;
        guard.get(channel).and_then(|entry| entry.sender.lock().ok()?.clone())
    }.ok_or("VCPLog 已断开，审批尚未发送")?;
    let (receipt, received) = oneshot::channel();
    sender.send(SocketWrite { text, receipt }).await.map_err(|_| "连接已断开，审批尚未发送")?;
    received.await.map_err(|_| "发送未完成，审批尚未确认".to_string())?
}

async fn run_socket(app: AppHandle, channel: String, url: String, token: CancellationToken, sender: Arc<Mutex<Option<mpsc::Sender<SocketWrite>>>>) {
    let mut delay = Duration::from_secs(1);
    loop {
        if token.is_cancelled() {
            break;
        }
        let _ = emit_socket(&app, &channel, "status", "连接中");
        match connect_async(&url).await {
            Ok((socket, _)) => {
                delay = Duration::from_secs(1);
                let (write_tx, write_rx) = mpsc::channel(8);
                if let Ok(mut slot) = sender.lock() { *slot = Some(write_tx); }
                let _ = emit_socket(&app, &channel, "status", "已连接");
                let outcome = pump_socket(&app, &channel, socket, &token, write_rx).await;
                if let Ok(mut slot) = sender.lock() { *slot = None; }
                if let Err(error) = outcome {
                    let _ = emit_socket(&app, &channel, "error", &error);
                }
            }
            Err(error) => {
                let _ = emit_socket(&app, &channel, "error", &format!("连接失败: {error}"));
            }
        }
        if token.is_cancelled() {
            break;
        }
        let _ = emit_socket(&app, &channel, "status", "已断开");
        tokio::select! {
            _ = token.cancelled() => break,
            _ = tokio::time::sleep(delay) => {}
        }
        delay = (delay * 2).min(Duration::from_secs(30));
    }
    let _ = emit_socket(&app, &channel, "status", "已断开");
}

async fn pump_socket(
    app: &AppHandle,
    channel: &str,
    socket: tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    token: &CancellationToken,
    mut outgoing: mpsc::Receiver<SocketWrite>,
) -> Result<(), String> {
    use futures_util::SinkExt;
    let (mut write, mut read) = socket.split();
    let (pong_tx, mut pong_rx) = mpsc::channel::<Message>(4);
    loop {
        tokio::select! {
            _ = token.cancelled() => return Ok(()),
            outgoing = outgoing.recv() => {
                if let Some(outgoing) = outgoing {
                    let result = write.send(Message::Text(outgoing.text.into())).await.map_err(|e| format!("审批发送失败: {e}"));
                    let _ = outgoing.receipt.send(result.clone());
                    result?;
                }
            }
            _ = tokio::time::sleep(Duration::from_secs(15)) => {
                write
                    .send(Message::Ping(Vec::new().into()))
                    .await
                    .map_err(|error| format!("心跳失败: {error}"))?;
            }
            outgoing = pong_rx.recv() => {
                if let Some(message) = outgoing {
                    write.send(message).await.map_err(|error| format!("发送失败: {error}"))?;
                }
            }
            incoming = read.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if text.len() <= MAX_HTTP_BODY {
                            let _ = emit_socket(app, channel, "message", text.as_str());
                        } else {
                            let _ = emit_socket(app, channel, "message", r#"{"type":"error","message":"单条日志超过 2MB，未载入"}"#);
                        }
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        let _ = pong_tx.try_send(Message::Pong(payload));
                    }
                    Some(Ok(Message::Close(_))) | None => return Ok(()),
                    Some(Ok(_)) => {}
                    Some(Err(error)) => return Err(format!("连接中断: {error}")),
                }
            }
        }
    }
}

/// Best effort: a suspended or reloading WebView misses events and catches up from the log.
fn emit_stream(app: &AppHandle, request_id: &str, kind: &str, text: &str, seq: usize) {
    let _ = app.emit(
        "vcp-stream",
        StreamEvent {
            request_id: request_id.to_string(),
            kind: kind.to_string(),
            text: text.to_string(),
            seq,
        },
    );
}

fn emit_socket(app: &AppHandle, channel: &str, kind: &str, text: &str) -> Result<(), String> {
    app.emit(
        "vcp-socket",
        SocketEvent {
            channel: channel.to_string(),
            kind: kind.to_string(),
            text: if kind == "message" { text.to_string() } else { clip(text, 4000) },
        },
    )
    .map_err(|error| format!("事件发送失败: {error}"))
}

fn clip(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_url_rejects_secrets_in_the_authority_and_other_schemes() {
        assert!(validate_http_url("http://127.0.0.1:6005/v1/chat/completions").is_ok());
        assert!(validate_http_url("http://user:secret@host").is_err());
        assert!(validate_http_url("file:///etc/passwd").is_err());
        assert!(validate_ws_url("ws://host:6005/VCPlog/VCP_Key=fixture").is_ok());
        assert!(validate_ws_url("http://host").is_err());
    }

    #[test]
    fn utf8_split_across_chunks_is_reassembled() {
        let bytes = "流式中文".as_bytes();
        let mut decoder = Utf8Stream::default();
        let mut text = decoder.push(&bytes[..4]);
        text += &decoder.push(&bytes[4..7]);
        text += &decoder.push(&bytes[7..]);
        text += &decoder.finish();
        assert_eq!(text, "流式中文");
        assert_eq!(Utf8Stream::default().push(&[0xff, b'a']), "\u{fffd}a");
    }

    #[test]
    fn the_log_replays_from_any_sequence_and_survives_until_released() {
        let state = NetState::new();
        let log = Arc::new(Mutex::new(StreamLog::default()));
        state.streams.lock().unwrap().insert(
            "r1".into(),
            StreamEntry {
                token: CancellationToken::new(),
                log: log.clone(),
            },
        );
        for part in ["a", "b", "c"] {
            append_chunk(&log, part.into()).unwrap();
        }
        let running = stream_snapshot(&state, "r1", 1).unwrap();
        assert_eq!((running.from_seq, running.chunks, running.state.as_str()), (1, vec!["b".to_string(), "c".to_string()], "running"));

        release_stream(&state, "r1").unwrap();
        assert_eq!(stream_snapshot(&state, "r1", 0).unwrap().state, "running");

        assert_eq!(finish_log(&log, StreamState::Error, "流中断"), 3);
        let failed = stream_snapshot(&state, "r1", 3).unwrap();
        assert_eq!((failed.chunks.len(), failed.state.as_str(), failed.error.as_str()), (0, "error", "流中断"));

        release_stream(&state, "r1").unwrap();
        assert_eq!(stream_snapshot(&state, "r1", 0).unwrap().state, "missing");
    }

    #[test]
    fn finished_logs_expire_and_running_ones_stay() {
        let mut streams = HashMap::new();
        let old = Arc::new(Mutex::new(StreamLog::default()));
        let now = Instant::now();
        old.lock().unwrap().finished_at = Some(now);
        streams.insert("old".to_string(), StreamEntry { token: CancellationToken::new(), log: old });
        streams.insert("live".to_string(), StreamEntry { token: CancellationToken::new(), log: Arc::new(Mutex::new(StreamLog::default())) });
        forget_finished(&mut streams, now + FINISHED_STREAM_TTL + Duration::from_secs(1));
        assert!(streams.contains_key("live"));
        assert!(!streams.contains_key("old"));
    }

    #[test]
    fn a_stream_log_stops_at_its_size_limit() {
        let log = Mutex::new(StreamLog::default());
        append_chunk(&log, "x".repeat(MAX_STREAM_BYTES)).unwrap();
        assert!(append_chunk(&log, "y".into()).is_err());
    }
}

// Foreground sync and file operations have their own byte budget. Ordinary chat HTTP stays at 2MB.
pub async fn sync_http_request(state: &NetState, call: HttpCall) -> Result<HttpResult, String> {
    validate_http_url(&call.url)?;
    let method = match call.method.as_str() { "GET" => reqwest::Method::GET, "POST" => reqwest::Method::POST, _ => return Err("同步只允许 GET/POST".into()) };
    const LIMIT: usize = 34 * 1024 * 1024;
    if call.body.as_ref().is_some_and(|b| b.len() > LIMIT) { return Err("同步请求超过34MiB".into()); }
    let mut request = state.client.request(method, &call.url).timeout(Duration::from_secs(90));
    for (name,value) in call.headers { if (allowed_header(&name) || name.eq_ignore_ascii_case("x-idempotency-key")) && value.len() <= DEVICE_HEADER_LIMIT { request=request.header(name,value); } }
    if let Some(body)=call.body { request=request.body(body); }
    let response=request.send().await.map_err(|e|format!("同步连接失败: {e}"))?;
    if response.status().is_redirection() { return Err("同步服务器要求重定向，已拒绝".into()); }
    let status=response.status().as_u16(); let mut stream=response.bytes_stream(); let mut bytes=Vec::new();
    while let Some(chunk)=stream.next().await { let chunk=chunk.map_err(|e|format!("同步消息流中断: {e}"))?; if bytes.len()+chunk.len()>LIMIT {return Err("同步响应超过34MiB，未保存".into());} bytes.extend_from_slice(&chunk); }
    let body=String::from_utf8(bytes).map_err(|_|"同步响应不是有效 UTF-8")?; Ok(HttpResult{status,body})
}
pub async fn binary_request(state: &NetState,url: String,headers: HashMap<String,String>,body:Option<Vec<u8>>) -> Result<Vec<u8>,String> {
    validate_http_url(&url)?;const LIMIT:usize=20_000_000;
    if body.as_ref().is_some_and(|b|b.len()>LIMIT){return Err("文件超过20MB".into());}
    let method=if body.is_some(){reqwest::Method::POST}else{reqwest::Method::GET};
    let mut request=state.client.request(method,&url).timeout(Duration::from_secs(90));
    for (name,value) in headers { if allowed_header(&name) && value.len()<=DEVICE_HEADER_LIMIT {request=request.header(name,value);} }
    if let Some(body)=body{request=request.body(body);}
    let response=request.send().await.map_err(|e|format!("文件连接失败: {e}"))?;
    if !response.status().is_success(){return Err(format!("文件 HTTP {}",response.status().as_u16()));}
    let mut bytes=Vec::new();let mut stream=response.bytes_stream();
    while let Some(chunk)=stream.next().await{let chunk=chunk.map_err(|e|format!("文件传输中断: {e}"))?;if bytes.len()+chunk.len()>LIMIT{return Err("文件响应超过20MB".into());}bytes.extend_from_slice(&chunk);}
    Ok(bytes)
}
