//! macOS publishes its proxy settings through SCDynamicStore, which `proxy.rs`
//! translates and watches. A Linux desktop's proxy is already in the variables
//! the login shell and Lattice's own environment hand the sidecar
//! (`environment`), so there is nothing to translate or watch.

use super::environment::SystemProxy;

pub(super) fn watch_system_proxy(_on_change: impl Fn() + Send + 'static) {}

pub(super) fn system_proxy() -> Option<SystemProxy> {
    None
}
