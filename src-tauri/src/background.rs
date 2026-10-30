//! While a reply is streaming, ask iOS for background execution time so leaving the app briefly
//! does not freeze the request. iOS grants roughly half a minute; after that the stream may be cut,
//! and the frontend keeps what arrived and offers to continue.

use std::sync::Mutex;
use tauri::AppHandle;

static ACTIVE: Mutex<usize> = Mutex::new(0);

pub fn stream_started(app: &AppHandle) {
    let Ok(mut active) = ACTIVE.lock() else {
        return;
    };
    *active += 1;
    if *active == 1 {
        platform::begin(app);
    }
}

pub fn stream_finished(app: &AppHandle) {
    let Ok(mut active) = ACTIVE.lock() else {
        return;
    };
    *active = active.saturating_sub(1);
    if *active == 0 {
        platform::end(app);
    }
}

#[cfg(target_os = "ios")]
mod platform {
    use block2::RcBlock;
    use objc2::MainThreadMarker;
    use objc2_ui_kit::{UIApplication, UIBackgroundTaskIdentifier, UIBackgroundTaskInvalid};
    use std::sync::Mutex;
    use tauri::AppHandle;

    static TASK: Mutex<Option<UIBackgroundTaskIdentifier>> = Mutex::new(None);

    fn end_on_main(mtm: MainThreadMarker) {
        let task = TASK.lock().ok().and_then(|mut task| task.take());
        if let Some(identifier) = task {
            UIApplication::sharedApplication(mtm).endBackgroundTask(identifier);
        }
    }

    pub fn begin(app: &AppHandle) {
        let _ = app.run_on_main_thread(|| {
            let Some(mtm) = MainThreadMarker::new() else {
                return;
            };
            let Ok(mut task) = TASK.lock() else { return };
            if task.is_some() {
                return;
            }
            // iOS kills the app if an expired task is not ended from the handler.
            let handler = RcBlock::new(|| {
                if let Some(mtm) = MainThreadMarker::new() {
                    end_on_main(mtm);
                }
            });
            let identifier = UIApplication::sharedApplication(mtm)
                .beginBackgroundTaskWithExpirationHandler(Some(&handler));
            if identifier != unsafe { UIBackgroundTaskInvalid } {
                *task = Some(identifier);
            }
        });
    }

    pub fn end(app: &AppHandle) {
        let _ = app.run_on_main_thread(|| {
            if let Some(mtm) = MainThreadMarker::new() {
                end_on_main(mtm);
            }
        });
    }
}

#[cfg(not(target_os = "ios"))]
mod platform {
    use tauri::AppHandle;

    pub fn begin(_app: &AppHandle) {}

    pub fn end(_app: &AppHandle) {}
}
