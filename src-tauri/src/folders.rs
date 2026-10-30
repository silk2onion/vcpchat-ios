use serde_json::{json, Value};
use tauri::Manager;

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple {
    use std::{
        collections::HashMap,
        ffi::{CStr, CString},
        os::raw::c_char,
        sync::{
            atomic::{AtomicU64, Ordering},
            Mutex, OnceLock,
        },
    };
    use tokio::sync::oneshot;
    type Answer = oneshot::Sender<Result<String, String>>;
    static PENDING: OnceLock<Mutex<HashMap<u64, Answer>>> = OnceLock::new();
    static NEXT: AtomicU64 = AtomicU64::new(1);
    extern "C" {
        fn vcp_folder_request(
            input: *const c_char,
            token: u64,
            callback: extern "C" fn(u64, *const c_char),
        );
    }
    extern "C" fn complete(token: u64, answer: *const c_char) {
        let result = if answer.is_null() {
            Err("原生文件操作没有返回结果".into())
        } else {
            unsafe { CStr::from_ptr(answer) }
                .to_str()
                .map(str::to_owned)
                .map_err(|_| "原生响应编码无效".into())
        };
        if let Some(sender) = PENDING.get().and_then(|p| p.lock().ok()?.remove(&token)) {
            let _ = sender.send(result);
        }
    }
    pub async fn request(text: String) -> Result<String, String> {
        let text = CString::new(text).map_err(|_| "请求含无效字符")?;
        let token = NEXT.fetch_add(1, Ordering::Relaxed);
        let (send, receive) = oneshot::channel();
        {
            let mut pending = PENDING
                .get_or_init(|| Mutex::new(HashMap::new()))
                .lock()
                .map_err(|_| "文件操作状态不可用")?;
            if pending.len() >= 32 {
                return Err("文件操作过多，请稍后再试".into());
            }
            pending.insert(token, send);
        }
        unsafe { vcp_folder_request(text.as_ptr(), token, complete) };
        receive.await.map_err(|_| "文件操作已结束".to_string())?
    }
}

async fn request(app: &tauri::AppHandle, mut value: Value) -> Result<Value, String> {
    if !value.is_object() {
        return Err("文件请求无效".into());
    }
    let root = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("Connected Folders");
    value["storage"] = json!(root.to_string_lossy());
    let text = serde_json::to_string(&value).map_err(|e| e.to_string())?;
    if text.len() > 30_000_000 {
        return Err("文件请求超过20MB内容上限".into());
    }
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        let raw = apple::request(text).await?;
        let result: Value = serde_json::from_str(&raw).map_err(|_| "原生文件响应无效")?;
        if result["ok"] == true {
            Ok(result["data"].clone())
        } else {
            Err(result["error"]
                .as_str()
                .unwrap_or("原生文件操作失败")
                .to_owned())
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        let _ = text;
        Err("连接文件夹目前支持 Mac 和 iOS".into())
    }
}

#[tauri::command]
pub async fn folder_request(app: tauri::AppHandle, mut request: Value) -> Result<Value, String> {
    request
        .as_object_mut()
        .ok_or("文件请求无效")?
        .insert("agent".into(), json!(false));
    self::request(&app, request).await
}
#[tauri::command]
pub async fn folder_tool(
    app: tauri::AppHandle,
    args: Value,
    request_id: String,
) -> Result<Value, String> {
    if request_id.is_empty() || request_id.len() > 160 {
        return Err("工具请求编号无效".into());
    }
    let value = json!({"action":"execute","folderId":args["folderId"],"operationId":format!("vcp:{request_id}"),"agent":true,"args":args});
    self::request(&app, value).await
}
