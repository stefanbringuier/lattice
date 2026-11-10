#!/bin/sh
# Install Lattice for the current user, or remove it, with no root and no
# package manager:
#
#   curl -fsSL https://github.com/leo1oel/lattice/releases/latest/download/install.sh | sh
#   curl -fsSL https://github.com/leo1oel/lattice/releases/latest/download/install.sh | sh -s -- --uninstall
#
# The AppImage goes to ~/.local/bin/lattice and Lattice joins the app menu;
# from then on the app updates itself. Running this again reinstalls the latest
# release. LATTICE_VERSION=v0.16.0 picks a release, LATTICE_REPO=owner/name a
# fork.
#
# Everything runs from main at the end, so a download cut short runs nothing.
set -eu

identifier=app.leo1oel.researchwriter
repo="${LATTICE_REPO:-leo1oel/lattice}"
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
app="$bin_dir/lattice"
desktop="$data_dir/applications/$identifier.desktop"
icons="$data_dir/icons/hicolor"

say() { printf '%s\n' "$*"; }
die() { printf 'lattice install: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

fetch() {
  if has curl; then curl -fsSL --retry 3 -o "$2" "$1" || die "could not download $1"
  elif has wget; then wget -q -O "$2" "$1" || die "could not download $1"
  else die "needs curl or wget"
  fi
}

sha256_of() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif has shasum; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "needs sha256sum or shasum to check the download"
  fi
}

refresh_menus() {
  if has update-desktop-database; then update-desktop-database -q "$data_dir/applications" 2>/dev/null || true; fi
  if has gtk-update-icon-cache; then gtk-update-icon-cache -q -t "$icons" 2>/dev/null || true; fi
}

check_system() {
  [ "$(id -u)" -ne 0 ] || die "run this as your own user, not as root"
  [ "$(uname -s)" = Linux ] || die "this installer is for Linux; the macOS app is at https://github.com/$repo/releases"
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "there is no Lattice build for $(uname -m), only x86_64 and aarch64" ;;
  esac
  # The AppImage is built on Ubuntu 24.04, so it needs that glibc or newer.
  glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | cut -d' ' -f2)" || glibc=""
  case "$glibc" in
    2.*)
      glibc_minor="${glibc#2.}"
      glibc_minor="${glibc_minor%%.*}"
      [ "$glibc_minor" -ge 39 ] \
        || die "needs glibc 2.39 or newer (Ubuntu 24.04, Debian 13, Fedora 40 or later); this system has $glibc"
      ;;
    *) die "needs a glibc-based Linux distribution" ;;
  esac
}

install_app() {
  check_system
  # LATTICE_BASE_URL (file:///dir works too) lets CI install a build it has
  # not published yet.
  if [ -n "${LATTICE_BASE_URL:-}" ]; then
    base="$LATTICE_BASE_URL"
  elif [ -n "${LATTICE_VERSION:-}" ]; then
    base="https://github.com/$repo/releases/download/$LATTICE_VERSION"
  else
    base="https://github.com/$repo/releases/latest/download"
  fi
  asset="Lattice-$arch.AppImage"

  mkdir -p "$bin_dir" "$data_dir/applications" "$icons"
  # Beside the target, so the final move replaces it in one step; a copy of
  # Lattice already running keeps its old file until it quits.
  tmp="$(mktemp -d "$bin_dir/.lattice-install.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 1' INT TERM

  say "Downloading $asset from $repo..."
  fetch "$base/$asset" "$tmp/$asset"
  fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"
  expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$tmp/SHA256SUMS")"
  [ -n "$expected" ] || die "the release lists no checksum for $asset"
  [ "$(sha256_of "$tmp/$asset")" = "$expected" ] || die "$asset failed its checksum, so nothing was installed"
  chmod 755 "$tmp/$asset"

  # The menu entry and icons come from the AppImage itself.
  menu=yes
  (cd "$tmp" \
    && "./$asset" --appimage-extract 'usr/share/applications/*' >/dev/null 2>&1 \
    && "./$asset" --appimage-extract 'usr/share/icons/*' >/dev/null 2>&1) || menu=no
  root="$tmp/squashfs-root"
  entry=""
  for candidate in "$root"/usr/share/applications/*.desktop; do
    if [ -f "$candidate" ]; then entry="$candidate"; break; fi
  done
  [ -n "$entry" ] || menu=no

  mv -f "$tmp/$asset" "$app"
  if [ "$menu" = yes ]; then
    sed -e "s#^Exec=.*#Exec=\"$app\"#" -e '/^TryExec=/d' "$entry" > "$desktop"
    if [ -d "$root/usr/share/icons/hicolor" ]; then cp -R "$root/usr/share/icons/hicolor/." "$icons/"; fi
    refresh_menus
    say "Installed Lattice to $app and added it to your app menu."
  else
    say "Installed Lattice to $app. The app menu entry could not be added; run $app to start it."
  fi
  case ":$PATH:" in
    *":$bin_dir:"*) say "Start it from the app menu or with: lattice" ;;
    *) say "$bin_dir is not on your PATH, so start it from the app menu or with: $app" ;;
  esac
  say "Lattice updates itself from now on."
}

uninstall() {
  icon=""
  if [ -f "$desktop" ]; then icon="$(sed -n 's/^Icon=//p' "$desktop" | head -n 1)"; fi
  rm -f "$app" "$desktop"
  if [ -n "$icon" ]; then rm -f "$icons"/*/apps/"$icon".png "$icons"/*/apps/"$icon".svg; fi
  refresh_menus
  say "Removed Lattice. Your projects and settings are kept."
}

main() {
  case "${1:-}" in
    "") install_app ;;
    --uninstall) uninstall ;;
    -h | --help) sed -n '2,13p' "$0" 2>/dev/null || say "usage: install.sh [--uninstall]" ;;
    *) die "unknown option $1 (the only option is --uninstall)" ;;
  esac
}

main "$@"
