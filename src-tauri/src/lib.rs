mod background;
mod net;
mod files;
mod folders;
#[cfg(target_os = "ios")]
mod ios_webview;

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
fn chat_stream_snapshot(state: State<'_, NetState>, request_id: String, from_seq: usize) -> Result<net::StreamSnapshot, String> {
    net::stream_snapshot(&state, &request_id, from_seq)
}

#[tauri::command]
fn release_chat_stream(state: State<'_, NetState>, request_id: String) -> Result<(), String> {
    net::release_stream(&state, &request_id)
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
async fn socket_send(state: State<'_, NetState>, channel: String, text: String) -> Result<(), String> {
    net::socket_send(&state, &channel, text).await
}

#[tauri::command]
async fn audio_request(state: State<'_, NetState>, url: String, headers: HashMap<String, String>, body: String) -> Result<tauri::ipc::Response, String> {
    let bytes = net::audio_request(&state, HttpCall { method: "POST".into(), url, headers, body: Some(body) }).await?;
    Ok(tauri::ipc::Response::new(bytes))
}

#[tauri::command]
fn socket_disconnect(state: State<'_, NetState>, channel: String) -> Result<(), String> {
    net::socket_disconnect(&state, &channel)
}

#[tauri::command]
async fn sync_http_request(state: State<'_, NetState>,method:String,url:String,headers:HashMap<String,String>,body:Option<String>) -> Result<net::HttpResult,String> {
    net::sync_http_request(&state, HttpCall{method,url,headers,body}).await
}
#[tauri::command]
async fn binary_request(state: State<'_, NetState>,url:String,headers:HashMap<String,String>,body:Option<Vec<u8>>) -> Result<tauri::ipc::Response,String> {
    Ok(tauri::ipc::Response::new(net::binary_request(&state,url,headers,body).await?))
}
#[tauri::command]
async fn export_file(app:tauri::AppHandle,name:String,bytes:Vec<u8>) -> Result<String,String> {
    tauri::async_runtime::spawn_blocking(move||files::export(&app,&name,&bytes)).await.map_err(|e|e.to_string())?
}
#[tauri::command]
fn show_exports(app:tauri::AppHandle) -> Result<String,String>{files::show(&app)}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(NetState::new())
        .setup(|_app| {
            #[cfg(target_os = "ios")]
            ios_webview::configure(_app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            start_chat_stream,
            cancel_chat_stream,
            chat_stream_snapshot,
            release_chat_stream,
            http_request,
            socket_connect,
            socket_send,
            audio_request,
            socket_disconnect,
            sync_http_request, binary_request, export_file, show_exports, folders::folder_request, folders::folder_tool
        ])
        .run(tauri::generate_context!())
        .expect("VCPChat 启动失败");
}
