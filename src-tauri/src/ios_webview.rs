//! CSS owns safe-area padding. UIKit must not inset the entire web document as well.

use objc2::{msg_send, rc::Retained, runtime::AnyObject};
use objc2_ui_kit::{UIScrollView, UIScrollViewContentInsetAdjustmentBehavior};
use tauri::Manager;

pub fn configure(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let window = app.get_webview_window("main").ok_or("Missing main webview")?;
    window.with_webview(|platform| {
        // Tauri runs this closure on the main thread and keeps the WKWebView alive.
        let webview = unsafe { &*platform.inner().cast::<AnyObject>() };
        let scroll: Retained<UIScrollView> = unsafe { msg_send![webview, scrollView] };
        scroll.setContentInsetAdjustmentBehavior(UIScrollViewContentInsetAdjustmentBehavior::Never);
    })?;
    Ok(())
}
