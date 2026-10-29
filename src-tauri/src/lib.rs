mod net;

use std::collections::HashMap;

use net::{HttpCall, NetState, StartStream};
use tauri::State;

#[tauri::command]
async fn start_chat_stream(
    app: tauri::AppHandle,
    state: State<'_, NetState>,
    request_id: String,
    url: String,
    api_key: String,
    body: String,
) -> Result<(), String> {
    net::spawn_stream(
        app,
        &state,
        StartStream {
            request_id,
            url,
            api_key,
            body,
        },
    )
    .await
}

#[tauri::command]
fn cancel_chat_stream(state: State<'_, NetState>, request_id: String) -> Result<(), String> {
    net::cancel_stream(&state, &request_id)
}

#[tauri::command]
async fn http_request(
    state: State<'_, NetState>,
    method: String,
    url: String,
    headers: HashMap<String, String>,
    body: Option<String>,
) -> Result<net::HttpResult, String> {
    net::http_request(
        &state,
        HttpCall {
            method,
            url,
            headers,
            body,
        },
    )
    .await
}

#[tauri::command]
async fn socket_connect(app: tauri::AppHandle, state: State<'_, NetState>, channel: String, url: String) -> Result<(), String> {
    net::socket_connect(app, &state, channel, url).await
}

#[tauri::command]
fn socket_disconnect(state: State<'_, NetState>, channel: String) -> Result<(), String> {
    net::socket_disconnect(&state, &channel)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(NetState::new())
        .invoke_handler(tauri::generate_handler![
            start_chat_stream,
            cancel_chat_stream,
            http_request,
            socket_connect,
            socket_disconnect
        ])
        .run(tauri::generate_context!())
        .expect("VCPChat 启动失败");
}
