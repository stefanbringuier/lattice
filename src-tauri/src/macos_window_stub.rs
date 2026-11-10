//! The stand-ins for `macos_window.rs` off macOS: the same functions and
//! commands, so its callers and the page stay as they are. Window materials,
//! the colour sampler, the quarantine flag and AppKit's event monitors have no
//! counterpart here, and do nothing.

use std::sync::{Mutex, PoisonError};

static FOCUSED_WINDOW_LABEL: Mutex<Option<String>> = Mutex::new(None);

pub fn install_magnify_monitor(_app: tauri::AppHandle) {}

/// Only the AppKit copy-shortcut monitor reads this text, and Linux has none.
#[tauri::command]
pub fn set_pdf_copy_text(_window: tauri::WebviewWindow, _text: Option<String>) {}

pub fn clear_pdf_copy_text(window_label: &str) {
    set_window_focused(window_label, false);
}

pub fn focused_window_label() -> Option<String> {
    FOCUSED_WINDOW_LABEL.lock().unwrap_or_else(PoisonError::into_inner).clone()
}

pub fn set_window_focused(window_label: &str, is_focused: bool) {
    let mut focused = FOCUSED_WINDOW_LABEL.lock().unwrap_or_else(PoisonError::into_inner);
    if is_focused {
        *focused = Some(window_label.to_string());
    } else if focused.as_deref() == Some(window_label) {
        *focused = None;
    }
}

pub fn install_copy_shortcut_monitor(_app: tauri::AppHandle) {}

/// The page's theme (appearance, background, translucency). The window keeps
/// the background it was built with, so the payload is accepted and ignored.
#[derive(serde::Deserialize)]
pub struct WindowMaterial {}

impl WindowMaterial {
    pub fn at_launch() -> Self {
        Self {}
    }
}

/// What the window's backing became: always opaque, as there is no vibrancy.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WindowBacking {
    Opaque,
}

pub fn apply_window_material(
    _window: &tauri::WebviewWindow, _material: &WindowMaterial,
) -> WindowBacking {
    WindowBacking::Opaque
}

pub fn forget_window_material(_window_label: &str) {}

pub fn render_at_display_refresh_rate(_window: &tauri::WebviewWindow) {}

pub async fn sample_screen_color(_app: &tauri::AppHandle) -> Result<Option<String>, String> {
    Ok(None)
}

/// Import panel on Linux: files via rfd (folders in the same pick are not
/// offered until a native both-kinds dialog exists).
pub async fn choose_files_and_folders(
    _window: &tauri::Window, title: &str, _prompt: &str,
) -> Result<Option<Vec<String>>, String> {
    let files = rfd::AsyncFileDialog::new().set_title(title).pick_files().await;
    Ok(files.map(|handles| {
        handles.into_iter().map(|handle| handle.path().display().to_string()).collect()
    }))
}

pub fn clear_launch_quarantine() {}
