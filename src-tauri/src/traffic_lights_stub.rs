//! The traffic lights are macOS's window buttons. Elsewhere the window
//! manager draws its own, so there is nothing to align.

pub fn install_traffic_light_alignment(_window: &tauri::WebviewWindow) {}

pub fn align_traffic_lights_to(
    _window: &tauri::WebviewWindow, _center_from_top: f64,
) -> Option<f64> {
    None
}
