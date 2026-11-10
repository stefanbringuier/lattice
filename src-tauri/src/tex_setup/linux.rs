//! Installing TeX on Linux: the pinned TinyTeX, unpacked as the signed-in
//! user into ~/.TinyTeX, where TinyTeX installs itself and where Lattice looks
//! for TeX first (`commands::tex_directories`), then the required packages
//! through an installer script run as that user. Nothing needs root, and TeX
//! lives outside the AppImage, so it stays when Lattice updates.

use super::common::{
    self, active_tex_live_year, check_tex_live_year, download, follow_installer,
    not_available_here, send_progress, InstallGuard, Progress, Workspace,
};
use super::installer::{
    dependency_install_error, install_error, tiny_tex_release, tiny_tex_script, TEX_DISTRIBUTION,
    TINY_TEX_YEAR,
};
use super::TexInstallMode;
use crate::commands;
use crate::util::{swap_in_dir, DirSwapError};
use std::fs;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// tlmgr and latexmk are Perl programs, and a minimal install of any
/// distribution, or a Fedora desktop, can be without Perl.
const PERL_MISSING: &str =
    "TeX Live's tools need Perl. Install perl with your distribution's package manager, then try again.";

pub fn install_tex(mode: TexInstallMode, on_progress: &Progress) -> Result<(), String> {
    let _install_guard = InstallGuard::acquire()?;
    let workspace = Workspace::create()?;
    if mode == TexInstallMode::ToolsOnly {
        return common::install_tools_only(&workspace, on_progress);
    }
    if !commands::available("perl") {
        return Err(PERL_MISSING.into());
    }

    let Some(tree) = commands::tinytex_root() else {
        return Err("Could not locate your home folder.".into());
    };
    let texbin = tree.join("bin").join(tex_live_platform());
    let tlmgr = texbin.join("tlmgr");
    let install_base = active_tex_live_year(&tlmgr).is_none_or(|year| year < TINY_TEX_YEAR);
    if install_base {
        check_tex_live_year(TINY_TEX_YEAR)?;
        let release = tiny_tex_release().ok_or_else(|| not_available_here(TEX_DISTRIBUTION))?;
        let archive = workspace.0.join("TinyTeX.tar.xz");
        send_progress(on_progress, "downloading", 0.01);
        let mut last_percent = 0;
        download(release, &archive, |downloaded, total| {
            let percent = (downloaded.saturating_mul(55) / total).min(55);
            if percent > last_percent {
                last_percent = percent;
                send_progress(on_progress, "downloading", percent as f64 / 100.0);
            }
        })?;
        send_progress(on_progress, "installing-base", 0.6);
        install_tiny_tex(&archive, &tree)?;
    }

    let root = installer_root("lattice-tinytex-root");
    run_installer(&tiny_tex_script(&texbin, &root), &root, on_progress, Install::TinyTex)?;
    common::finish_full_install(&workspace, on_progress)
}

pub fn install_dependency(missing_file: &str, on_progress: &Progress) -> Result<(), String> {
    let root = installer_root("lattice-tex-dependency-root");
    common::install_dependency(missing_file, on_progress, &root, |script| {
        run_installer(script, &root, on_progress, Install::Dependency(missing_file))
    })
}

/// TeX Live's name for this platform, which names the folder of its programs.
fn tex_live_platform() -> String {
    format!("{}-linux", std::env::consts::ARCH)
}

/// Where an installer script keeps its working folder, which the script
/// itself creates (and refuses to reuse).
fn installer_root(prefix: &str) -> PathBuf {
    std::env::temp_dir().join(format!("{prefix}-{}", uuid::Uuid::new_v4().simple()))
}

/// Unpack the TinyTeX `archive` and move it into place at `tree`, keeping a
/// TinyTeX already there until the new one is in. It is unpacked beside
/// `tree`, on the same disk, so moving it in is a rename, and in-process, so
/// the system needs neither tar nor xz.
fn install_tiny_tex(archive: &Path, tree: &Path) -> Result<(), String> {
    let id = uuid::Uuid::new_v4().simple();
    let staging = tree.with_file_name(format!(".TinyTeX-lattice-install-{id}"));
    fs::create_dir(&staging)
        .map_err(|error| format!("Could not prepare the TinyTeX install: {error}"))?;
    let installed = unpack_tiny_tex(archive, &staging)
        .and_then(|unpacked| activate_tiny_tex(&unpacked, tree, &format!("lattice-backup-{id}")));
    // Holds the unpacked tree after a failure, and nothing after a success.
    let _ = fs::remove_dir_all(&staging);
    installed
}

/// Unpack `archive` into the empty `staging` folder, and return the one TeX
/// Live tree it holds (TinyTeX's `.TinyTeX`).
fn unpack_tiny_tex(archive: &Path, staging: &Path) -> Result<PathBuf, String> {
    let file = fs::File::open(archive)
        .map_err(|error| format!("Could not read the TinyTeX archive: {error}"))?;
    let xz = liblzma::read::XzDecoder::new_multi_decoder(BufReader::new(file));
    tar::Archive::new(xz)
        .unpack(staging)
        .map_err(|error| format!("Could not unpack TinyTeX: {error}"))?;
    let trees: Vec<PathBuf> = fs::read_dir(staging)
        .map_err(|error| format!("Could not read the unpacked TinyTeX: {error}"))?
        .flatten()
        .map(|entry| entry.path())
        .collect();
    let platform = tex_live_platform();
    match trees.as_slice() {
        [tree] if tree.join("bin").join(&platform).join("tlmgr").is_file() => Ok(tree.clone()),
        _ => Err("The TinyTeX archive did not contain the expected TeX Live folder.".into()),
    }
}

/// Swap the `unpacked` tree in at `tree`, the previous one moved aside with
/// the `backup` extension until then.
fn activate_tiny_tex(unpacked: &Path, tree: &Path, backup: &str) -> Result<(), String> {
    let swapped = swap_in_dir(unpacked, tree, backup);
    if let Err(DirSwapError::RemoveBackup(error)) = &swapped {
        // The new TinyTeX is in place; only the old one is left over.
        log::warn!(
            target: "lattice::tex-setup",
            "Could not remove the previous TinyTeX at {}: {error}",
            tree.with_extension(backup).display()
        );
        return Ok(());
    }
    swapped.map_err(|failure| match failure {
        DirSwapError::Inspect(error) => format!("Could not inspect the old TinyTeX: {error}"),
        DirSwapError::Backup(error) => format!("Could not move the old TinyTeX aside: {error}"),
        DirSwapError::Activate { error, restore: None } => {
            format!("Could not move TinyTeX into place: {error}")
        }
        DirSwapError::Activate { error, restore: Some(restore_error) } => format!(
            "Could not move TinyTeX into place ({error}) or put the old one back ({restore_error})."
        ),
        DirSwapError::RemoveBackup(error) => format!("Could not remove the old TinyTeX: {error}"),
    })
}

#[derive(Clone, Copy)]
enum Install<'a> {
    TinyTex,
    /// The package for this missing file.
    Dependency(&'a str),
}

/// Run `script` with bash as the signed-in user, relaying the stages it
/// writes to `<root>/status` as progress.
fn run_installer(
    script: &str, root: &Path, on_progress: &Progress, install: Install<'_>,
) -> Result<(), String> {
    let name = match install {
        Install::TinyTex => TEX_DISTRIBUTION,
        Install::Dependency(missing_file) => missing_file,
    };
    let child = commands::with_child_path(Command::new("/bin/bash"))
        .arg("-c")
        .arg(script)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Could not start the {name} installer: {error}"))?;
    match follow_installer(child, root, name, on_progress)? {
        None => Ok(()),
        Some(stderr) => Err(match install {
            Install::TinyTex => install_error(&stderr),
            Install::Dependency(_) => dependency_install_error(&stderr),
        }),
    }
}
