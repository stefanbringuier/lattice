//! AppKit's `terminate:` (Dock ▸ Quit, logging out) exists only on macOS.
//! Elsewhere Lattice quits through its windows closing, which
//! `save_before_close` already holds until each page has saved.

use tauri::{AppHandle, Runtime};

pub fn install(_app: &AppHandle) {}

pub fn reply<R: Runtime>(_app: &AppHandle<R>, _proceed: bool) {}
