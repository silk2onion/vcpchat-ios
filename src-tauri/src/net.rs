use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tokio::sync::mpsc;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;
use url::Url;

const MAX_HTTP_BODY: usize = 2_000_000;
const DEVICE_HEADER_LIMIT: usize = 8_000;

pub struct NetState {
    client: reqwest::Client,
    streams: Mutex<HashMap<String, CancellationToken>>,
    sockets: Mutex<HashMap<String, CancellationToken>>,
}

impl NetState {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(20))
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
    {
        let mut guard = state.streams.lock().map_err(|_| "内部锁失败".to_string())?;
        if let Some(previous) = guard.insert(request.request_id.clone(), token.clone()) {
            previous.cancel();
        }
    }
    let client = state.client.clone();
    let request_id = request.request_id.clone();
    tauri::async_runtime::spawn(async move {
        let kind = match run_stream(&client, &app, &request, token.clone()).await {
            Ok(()) => "done",
            Err(message) if token.is_cancelled() => {
                let _ = message;
                "cancelled"
            }
            Err(message) => {
                let _ = emit_stream(&app, &request_id, "error", &message);
                return;
            }
        };
        let _ = emit_stream(&app, &request_id, kind, "");
    });
    Ok(())
}

async fn run_stream(client: &reqwest::Client, app: &AppHandle, request: &StartStream, token: CancellationToken) -> Result<(), String> {
    let response = client
        .post(&request.url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {}", request.api_key))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .header(reqwest::header::ACCEPT, "text/event-stream, application/json")
        .body(request.body.clone())
        .send()
        .await
        .map_err(|error| format!("无法连接服务器: {error}"))?;
    if response.status().is_redirection() {
        return Err("服务器要求重定向，已拒绝以免密钥离开原主机".into());
    }
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("HTTP {status}：{}", clip(&body, 500)));
    }
    let mut stream = response.bytes_stream();
    loop {
        let next = tokio::select! {
            _ = token.cancelled() => return Err("cancelled".into()),
            item = stream.next() => item,
        };
        match next {
            Some(Ok(bytes)) => {
                let text = String::from_utf8_lossy(&bytes);
                emit_stream(app, &request.request_id, "chunk", &text)?;
            }
            Some(Err(error)) => return Err(format!("流中断: {error}")),
            None => return Ok(()),
        }
    }
}

pub fn cancel_stream(state: &NetState, request_id: &str) -> Result<(), String> {
    let guard = state.streams.lock().map_err(|_| "内部锁失败".to_string())?;
    if let Some(token) = guard.get(request_id) {
        token.cancel();
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

pub async fn socket_connect(app: AppHandle, state: &NetState, channel: String, url: String) -> Result<(), String> {
    if channel != "log" && channel != "info" {
        return Err("未知通道".into());
    }
    validate_ws_url(&url)?;
    let token = CancellationToken::new();
    {
        let mut guard = state.sockets.lock().map_err(|_| "内部锁失败".to_string())?;
        if let Some(previous) = guard.insert(channel.clone(), token.clone()) {
            previous.cancel();
        }
    }
    tauri::async_runtime::spawn(async move {
        run_socket(app, channel, url, token).await;
    });
    Ok(())
}

pub fn socket_disconnect(state: &NetState, channel: &str) -> Result<(), String> {
    let guard = state.sockets.lock().map_err(|_| "内部锁失败".to_string())?;
    if let Some(token) = guard.get(channel) {
        token.cancel();
    }
    Ok(())
}

async fn run_socket(app: AppHandle, channel: String, url: String, token: CancellationToken) {
    let mut delay = Duration::from_secs(1);
    loop {
        if token.is_cancelled() {
            break;
        }
        let _ = emit_socket(&app, &channel, "status", "连接中");
        match connect_async(&url).await {
            Ok((socket, _)) => {
                delay = Duration::from_secs(1);
                let _ = emit_socket(&app, &channel, "status", "已连接");
                if let Err(error) = pump_socket(&app, &channel, socket, &token).await {
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
) -> Result<(), String> {
    use futures_util::SinkExt;
    let (mut write, mut read) = socket.split();
    let (pong_tx, mut pong_rx) = mpsc::channel::<Message>(4);
    loop {
        tokio::select! {
            _ = token.cancelled() => return Ok(()),
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
                        let _ = emit_socket(app, channel, "message", text.as_str());
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

fn emit_stream(app: &AppHandle, request_id: &str, kind: &str, text: &str) -> Result<(), String> {
    app.emit(
        "vcp-stream",
        StreamEvent {
            request_id: request_id.to_string(),
            kind: kind.to_string(),
            text: text.to_string(),
        },
    )
    .map_err(|error| format!("事件发送失败: {error}"))
}

fn emit_socket(app: &AppHandle, channel: &str, kind: &str, text: &str) -> Result<(), String> {
    app.emit(
        "vcp-socket",
        SocketEvent {
            channel: channel.to_string(),
            kind: kind.to_string(),
            text: clip(text, 4000),
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
}
