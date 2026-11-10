//! One-click TeX and required-tool install helpers.
//!
//! A full install puts a pinned TeX Live distribution in place (BasicTeX on
//! macOS, installed as root behind the administrator prompt; TinyTeX on
//! Linux, unpacked into the home folder), runs one script for the TeX Live
//! packages Lattice needs, installs the app-managed uv, and then verifies
//! everything as the signed-in user. The tools-only mode keeps a working TeX
//! and installs just uv. A dependency install finds the one TeX Live package
//! that provides a missing file.
//!
//! `installer` holds the pins, scripts and output parsers; `common` what both
//! platforms do alike; `macos` and `linux` the rest. Downloads stay in `fetch`.

use serde::{Deserialize, Serialize};

mod common;
mod fetch;
mod installer;
#[cfg(not(target_os = "macos"))]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

pub(crate) use fetch::download as download_pinned;
pub(crate) use installer::{create_private_file, PinnedDownload};
#[cfg(not(target_os = "macos"))]
pub use linux::{install_dependency, install_tex};
#[cfg(target_os = "macos")]
pub use macos::{install_dependency, install_tex};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TexInstallProgress {
    stage: String,
    progress: f64,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TexInstallMode {
    Full,
    ToolsOnly,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_modes_are_explicit_ipc_values() {
        let modes: Vec<TexInstallMode> = serde_json::from_str(r#"["toolsOnly", "full"]"#).unwrap();
        assert_eq!(modes, [TexInstallMode::ToolsOnly, TexInstallMode::Full]);
    }
}
