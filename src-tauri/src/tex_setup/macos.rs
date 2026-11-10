//! Installing TeX on macOS: the pinned BasicTeX package and the required
//! packages, through an installer script run as root behind the
//! administrator prompt.

use super::common::{
    self, active_tex_live_year, check_tex_live_year, download, follow_installer, send_progress,
    InstallGuard, Progress, Workspace,
};
use super::installer::{
    basic_tex_script, dependency_install_error, install_error, privileged_command, BASIC_TEX,
    BASIC_TEX_YEAR,
};
use super::TexInstallMode;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub fn install_tex(mode: TexInstallMode, on_progress: &Progress) -> Result<(), String> {
    let _install_guard = InstallGuard::acquire()?;
    let workspace = Workspace::create()?;
    if mode == TexInstallMode::ToolsOnly {
        return common::install_tools_only(&workspace, on_progress);
    }

    let package_path = workspace.0.join("BasicTeX.pkg");
    let root_path = privileged_root("lattice-basictex-root");
    let tlmgr = Path::new("/Library/TeX/texbin/tlmgr");
    let install_base = active_tex_live_year(tlmgr).is_none_or(|year| year < BASIC_TEX_YEAR);
    if install_base {
        check_tex_live_year(BASIC_TEX_YEAR)?;
        send_progress(on_progress, "downloading", 0.01);
        let mut last_percent = 0;
        download(&BASIC_TEX, &package_path, |downloaded, total| {
            let percent = (downloaded.saturating_mul(55) / total).min(55);
            if percent > last_percent {
                last_percent = percent;
                send_progress(on_progress, "downloading", percent as f64 / 100.0);
            }
        })?;
    }
    send_progress(on_progress, "downloading", 0.55);

    let script = basic_tex_script(&package_path, &root_path, install_base);
    run_privileged_installer(&script, &root_path, on_progress, Privileged::BasicTex)?;
    common::finish_full_install(&workspace, on_progress)
}

pub fn install_dependency(missing_file: &str, on_progress: &Progress) -> Result<(), String> {
    let root = privileged_root("lattice-tex-dependency-root");
    common::install_dependency(missing_file, on_progress, &root, |script| {
        run_privileged_installer(script, &root, on_progress, Privileged::Dependency(missing_file))
    })
}

/// Where a privileged script keeps its root-owned working folder, which the
/// script itself creates (and refuses to reuse).
fn privileged_root(prefix: &str) -> PathBuf {
    PathBuf::from("/private/var/tmp").join(format!("{prefix}-{}", uuid::Uuid::new_v4().simple()))
}

#[derive(Clone, Copy)]
enum Privileged<'a> {
    BasicTex,
    /// The package for this missing file.
    Dependency(&'a str),
}

/// Run `script` as root behind the administrator prompt, relaying the stages
/// it writes to `<root>/status` as progress.
fn run_privileged_installer(
    script: &str, root: &Path, on_progress: &Progress, install: Privileged<'_>,
) -> Result<(), String> {
    let (name, authorization_progress) = match install {
        Privileged::BasicTex => ("BasicTeX", 0.58),
        Privileged::Dependency(missing_file) => (missing_file, 0.2),
    };
    send_progress(on_progress, "authorizing", authorization_progress);
    let child = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "on run argv",
            "-e",
            "do shell script (item 1 of argv) with administrator privileges",
            "-e",
            "end run",
        ])
        .arg(privileged_command(script))
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Could not request permission to install {name}: {error}"))?;
    match follow_installer(child, root, name, on_progress)? {
        None => Ok(()),
        Some(stderr) => Err(match install {
            Privileged::BasicTex => install_error(&stderr),
            Privileged::Dependency(_) => dependency_install_error(&stderr),
        }),
    }
}
