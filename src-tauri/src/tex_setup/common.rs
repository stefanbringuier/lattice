//! What installing TeX and the paper tools does the same way on macOS and
//! Linux: one install at a time, a private download folder, the managed uv,
//! the TeX Live package that provides a missing file, following an installer
//! script's progress, and verifying the result as the signed-in user, who is
//! the one Lattice runs its tools as.

use super::installer::{
    dependency_script, extract_uv_archive, installer_stage_progress, tex_live_package_for_file,
    tex_live_year, uv_release, valid_tex_dependency_name, REUSABLE_TEX_ENGINES, REUSABLE_TEX_TOOLS,
    SYSTEM, TEX_DISTRIBUTION,
};
use super::TexInstallProgress;
use crate::commands;
use crate::util::{swap_in_dir, DirSwapError};
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;
use tauri::ipc::Channel;

pub(super) use super::fetch::download;

pub(super) type Progress = Channel<TexInstallProgress>;

pub(super) fn send_progress(channel: &Progress, stage: &str, progress: f64) {
    let _ = channel.send(TexInstallProgress { stage: stage.to_string(), progress });
}

static INSTALL_RUNNING: AtomicBool = AtomicBool::new(false);

/// One install at a time across every window.
pub(super) struct InstallGuard;

impl InstallGuard {
    pub(super) fn acquire() -> Result<Self, String> {
        INSTALL_RUNNING
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| Self)
            .map_err(|_| "Required setup is already running in another Lattice window.".into())
    }
}

impl Drop for InstallGuard {
    fn drop(&mut self) {
        INSTALL_RUNNING.store(false, Ordering::Release);
    }
}

/// A private folder for downloads, removed when the install ends.
pub(super) struct Workspace(pub(super) PathBuf);

impl Workspace {
    pub(super) fn create() -> Result<Self, String> {
        let path = std::env::temp_dir()
            .join(format!("lattice-tex-install-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir(&path).map_err(|error| {
            format!("Could not create the {TEX_DISTRIBUTION} installer folder: {error}")
        })?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).map_err(|error| {
            format!("Could not secure the {TEX_DISTRIBUTION} installer folder: {error}")
        })?;
        Ok(Self(path))
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Refuse to install a base TeX whose TeX Live year has ended: its tlmgr no
/// longer installs packages from the current repository.
pub(super) fn check_tex_live_year(year: i32) -> Result<(), String> {
    let current_year = chrono::Utc::now().format("%Y").to_string().parse::<i32>().unwrap_or(year);
    if current_year > year {
        return Err(format!(
            "This Lattice version includes {TEX_DISTRIBUTION} {year}. Update Lattice to install the current release."
        ));
    }
    Ok(())
}

/// Why Lattice cannot install `what` on this processor: it has no pinned
/// download for it.
pub(super) fn not_available_here(what: &str) -> String {
    format!(
        "Automatic {what} installation is not available for this processor ({}).",
        std::env::consts::ARCH
    )
}

/// Keep the TeX that already works and install only the paper tools.
pub(super) fn install_tools_only(
    workspace: &Workspace, on_progress: &Progress,
) -> Result<(), String> {
    verify_reusable_tex_as_current_user().map_err(|error| {
        format!(
            "Your LaTeX setup changed before the required tools install started. Recheck setup and try again.\n{error}"
        )
    })?;
    ensure_uv_installed(&workspace.0, on_progress, 0.05, 0.95)?;
    send_progress(on_progress, "verifying", 0.98);
    verify_reusable_tex_as_current_user()?;
    verify_uv_as_current_user()?;
    send_progress(on_progress, "complete", 1.0);
    Ok(())
}

/// The end of a full install, once TeX and its packages are in: the paper
/// tools, then every tool checked as the signed-in user.
pub(super) fn finish_full_install(
    workspace: &Workspace, on_progress: &Progress,
) -> Result<(), String> {
    ensure_uv_installed(&workspace.0, on_progress, 0.94, 0.97)?;
    send_progress(on_progress, "verifying", 0.98);
    verify_tex_install_as_current_user()?;
    verify_uv_as_current_user()?;
    send_progress(on_progress, "complete", 1.0);
    Ok(())
}

/// Install the TeX Live package that provides `missing_file` into the TeX in
/// use. `run_installer` runs the installer script, whose working folder is
/// `root`.
pub(super) fn install_dependency(
    missing_file: &str, on_progress: &Progress, root: &Path,
    run_installer: impl FnOnce(&str) -> Result<(), String>,
) -> Result<(), String> {
    if !valid_tex_dependency_name(missing_file) {
        return Err("Invalid missing TeX dependency name.".into());
    }
    let _install_guard = InstallGuard::acquire()?;
    let tlmgr = commands::resolve("tlmgr");
    if !tlmgr.is_file() {
        return Err("TeX Live's package manager is not installed.".into());
    }
    let kpsewhich = tlmgr
        .parent()
        .map(|parent| parent.join("kpsewhich"))
        .filter(|path| path.is_file())
        .ok_or_else(|| "kpsewhich was not found beside tlmgr.".to_string())?;
    if verify_tex_dependency(&kpsewhich, missing_file).is_ok() {
        send_progress(on_progress, "complete", 1.0);
        return Ok(());
    }

    send_progress(on_progress, "searching-packages", 0.02);
    let (package, repository) = find_tex_live_package(&tlmgr, missing_file)?;
    run_installer(&dependency_script(root, &tlmgr, &package, repository))?;
    send_progress(on_progress, "verifying-dependency", 0.95);
    verify_tex_dependency(&kpsewhich, missing_file)?;
    send_progress(on_progress, "complete", 1.0);
    Ok(())
}

/// Wait for the installer script `child` runs, relaying the stages it writes
/// to `<root>/status` as progress. `Some` holds its stderr when it failed.
pub(super) fn follow_installer(
    mut child: Child, root: &Path, name: &str, on_progress: &Progress,
) -> Result<Option<String>, String> {
    let status_path = root.join("status");
    let mut last_stage = String::new();
    let exit = loop {
        let status = fs::read_to_string(&status_path).unwrap_or_default();
        let status = status.trim();
        if status != last_stage {
            if let Some(progress) = installer_stage_progress(status) {
                let stage = status.split_whitespace().next().unwrap_or(status);
                send_progress(on_progress, stage, progress);
            }
            last_stage = status.to_string();
        }
        if let Some(exit) = child
            .try_wait()
            .map_err(|error| format!("Could not monitor the {name} installer: {error}"))?
        {
            break exit;
        }
        thread::sleep(Duration::from_millis(250));
    };

    let mut stderr = String::new();
    if let Some(mut pipe) = child.stderr.take() {
        let _ = pipe.read_to_string(&mut stderr);
    }
    Ok((!exit.success()).then_some(stderr))
}

/// Install the managed uv pair unless it already verifies, reporting
/// progress between `progress_start` and `progress_end`.
fn ensure_uv_installed(
    workspace: &Path, on_progress: &Progress, progress_start: f64, progress_end: f64,
) -> Result<(), String> {
    if verify_uv_as_current_user().is_ok() {
        return Ok(());
    }
    let Some((uv, archive_root)) = uv_release() else {
        return Err(not_available_here("uv"));
    };
    let archive = workspace.join("uv.tar.gz");
    send_progress(on_progress, "installing-tools", progress_start);
    let download_end = progress_start + (progress_end - progress_start) * 0.8;
    let mut last_step = 0;
    download(uv, &archive, |downloaded, total| {
        let fraction = (downloaded as f64 / total as f64).clamp(0.0, 1.0);
        let progress = progress_start + fraction * (download_end - progress_start);
        let step = (progress * 1_000.0) as u64;
        if step > last_step {
            last_step = step;
            send_progress(on_progress, "installing-tools", progress);
        }
    })?;
    send_progress(on_progress, "installing-tools", download_end);

    let destination = commands::managed_tools_dir()
        .ok_or_else(|| "Could not locate your macOS Application Support folder.".to_string())?;
    let parent = destination
        .parent()
        .ok_or_else(|| "The managed uv tools folder has no parent.".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    let parent_metadata = fs::symlink_metadata(parent)
        .map_err(|error| format!("Could not inspect {}: {error}", parent.display()))?;
    if !parent_metadata.is_dir() || parent_metadata.file_type().is_symlink() {
        return Err(format!(
            "Refusing to install uv into an invalid managed tools folder: {}",
            parent.display()
        ));
    }
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).map_err(|error| {
        format!("Could not secure the managed tools folder {}: {error}", parent.display())
    })?;

    let staging = parent.join(format!(
        ".uv-{}-lattice-install-{}",
        commands::MANAGED_UV_VERSION,
        uuid::Uuid::new_v4().simple()
    ));
    fs::create_dir(&staging)
        .map_err(|error| format!("Could not prepare the uv installer: {error}"))?;
    fs::set_permissions(&staging, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("Could not secure the uv installer: {error}"))?;
    let installed = extract_uv_archive(&archive, &staging, archive_root)
        .and_then(|()| {
            ["uv", "uvx"]
                .iter()
                .try_for_each(|name| commands::uv_tool_status_at(&staging.join(name), name))
        })
        .and_then(|()| activate_uv_pair(&staging, &destination));
    if installed.is_err() {
        let _ = fs::remove_dir_all(&staging);
    }
    installed?;
    log::info!(
        target: "lattice::tex-setup",
        "Installed managed uv {} in {}",
        commands::MANAGED_UV_VERSION,
        destination.display()
    );
    send_progress(on_progress, "installing-tools", progress_end);
    verify_uv_as_current_user()
}

/// Move the verified `staging` pair into place, keeping the previous pair
/// until the new one is in.
fn activate_uv_pair(staging: &Path, destination: &Path) -> Result<(), String> {
    let backup = format!("lattice-backup-{}", uuid::Uuid::new_v4().simple());
    swap_in_dir(staging, destination, &backup).map_err(|failure| match failure {
        DirSwapError::Inspect(error) => {
            format!("Could not inspect the existing managed uv tools: {error}")
        }
        DirSwapError::Backup(error) => format!("Could not prepare the managed uv update: {error}"),
        DirSwapError::Activate { error, restore: None } => {
            format!("Could not activate the managed uv update: {error}")
        }
        DirSwapError::Activate { error, restore: Some(restore_error) } => format!(
            "Could not activate the managed uv update ({error}) or restore the previous tools ({restore_error})."
        ),
        DirSwapError::RemoveBackup(error) => {
            format!("uv was updated, but its old managed copy could not be removed: {error}")
        }
    })
}

/// The first line a failed tool printed, stderr first.
fn command_failure_detail(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr)
        .lines()
        .chain(String::from_utf8_lossy(&output.stdout).lines())
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("No error detail was reported.")
        .to_string()
}

fn verify_uv_as_current_user() -> Result<(), String> {
    for tool in ["uv", "uvx"] {
        commands::managed_uv_tool_status(tool).map_err(|error| {
            format!("Lattice's managed {tool} failed user-level verification.\n{error}")
        })?;
    }
    Ok(())
}

fn verify_tex_tool_as_current_user(tool: &str, version_arg: &str) -> Result<(), String> {
    let mut command = commands::command(tool);
    let resolved = command.get_program().to_string_lossy().into_owned();
    let output = command.arg(version_arg).output().map_err(|error| {
        format!(
            "Lattice could not run {tool} as your {SYSTEM} user.\nResolved tool: {resolved}\n{error}"
        )
    })?;
    if !output.status.success() {
        return Err(format!(
            "{tool} failed its user-level verification.\nResolved tool: {resolved}\n{}",
            command_failure_detail(&output)
        ));
    }
    Ok(())
}

fn verify_conference_fonts_as_current_user() -> Result<(), String> {
    for required_file in crate::doctor::CONFERENCE_FONT_FILES {
        let output = commands::command("kpsewhich").arg(required_file).output().map_err(|error| {
            format!(
                "{TEX_DISTRIBUTION} was installed, but Lattice could not look up required file {required_file}.\n{error}"
            )
        })?;
        let resolved = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !output.status.success() || resolved.is_empty() {
            return Err(format!(
                "{TEX_DISTRIBUTION} was installed, but required file {required_file} could not be found.\n{}",
                command_failure_detail(&output)
            ));
        }
        fs::File::open(&resolved).map_err(|error| {
            format!(
                "{TEX_DISTRIBUTION} was installed, but Lattice could not read required file {required_file}.\nResolved file: {resolved}\n{error}"
            )
        })?;
    }
    Ok(())
}

fn verify_reusable_tex_as_current_user() -> Result<(), String> {
    for (tool, version_arg) in REUSABLE_TEX_TOOLS {
        verify_tex_tool_as_current_user(tool, version_arg)?;
    }
    if REUSABLE_TEX_ENGINES
        .into_iter()
        .all(|engine| verify_tex_tool_as_current_user(engine, "--version").is_err())
    {
        return Err(format!("No supported LaTeX engine could be run as your {SYSTEM} user."));
    }
    verify_conference_fonts_as_current_user()
}

fn verify_tex_install_as_current_user() -> Result<(), String> {
    for (tool, version_arg) in [
        ("latexmk", "-version"),
        ("pdflatex", "--version"),
        ("synctex", "help"),
        ("bibtex", "--version"),
        ("biber", "--version"),
        ("texcount", "-version"),
        ("kpsewhich", "--version"),
    ] {
        verify_tex_tool_as_current_user(tool, version_arg)?;
    }
    verify_conference_fonts_as_current_user()
}

/// The TeX Live release of the tree `tlmgr` belongs to, if it runs.
pub(super) fn active_tex_live_year(tlmgr: &Path) -> Option<i32> {
    let output = Command::new(tlmgr).arg("--version").output().ok()?;
    let version = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    tex_live_year(&version)
}

/// The package providing `missing_file`, and the fallback repository it was
/// found in (`None` for the one the user configured).
fn find_tex_live_package(
    tlmgr: &Path, missing_file: &str,
) -> Result<(String, Option<&'static str>), String> {
    const FALLBACK_REPOSITORIES: [&str; 2] = [
        "https://mirrors.tuna.tsinghua.edu.cn/CTAN/systems/texlive/tlnet",
        "https://mirrors.ustc.edu.cn/CTAN/systems/texlive/tlnet",
    ];
    let search_pattern = format!("/{}$", regex::escape(missing_file));
    let mut failures = Vec::new();
    for repository in std::iter::once(None).chain(FALLBACK_REPOSITORIES.map(Some)) {
        let mut command = Command::new(tlmgr);
        if let Some(repository) = repository {
            command.args(["--repository", repository]);
        }
        let output = command
            .args(["search", "--global", "--file", &search_pattern])
            .output()
            .map_err(|error| format!("Could not search the TeX Live repository: {error}"))?;
        if output.status.success() {
            let search_output = String::from_utf8_lossy(&output.stdout);
            return tex_live_package_for_file(&search_output, missing_file)
                .map(|package| (package, repository));
        }
        failures.push(command_failure_detail(&output));
    }
    failures.dedup();
    Err(format!("The TeX Live repository could not be searched.\n{}", failures.join("\n")))
}

fn verify_tex_dependency(kpsewhich: &Path, missing_file: &str) -> Result<(), String> {
    let output = Command::new(kpsewhich)
        .arg(missing_file)
        .output()
        .map_err(|error| format!("Could not verify {missing_file}: {error}"))?;
    let resolved = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !output.status.success() || resolved.is_empty() {
        return Err(format!(
            "The package installation finished, but {missing_file} is still unavailable.\n{}",
            command_failure_detail(&output)
        ));
    }
    fs::File::open(&resolved).map(drop).map_err(|error| {
        format!(
            "The package installation finished, but Lattice could not read {missing_file}.\nResolved file: {resolved}\n{error}"
        )
    })
}
