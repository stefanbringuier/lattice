#!/usr/bin/env bash
# Install an AppImage through scripts/appimage/install.sh as a user would, from
# a release laid out as GitHub serves it, then uninstall it. Run as root in a
# throwaway distro container:
#
#   bash test-install.sh /path/to/Lattice.AppImage /path/to/install.sh
set -euo pipefail

appimage="${1:?usage: test-install.sh /path/to/Lattice.AppImage /path/to/install.sh}"
installer="${2:?usage: test-install.sh /path/to/Lattice.AppImage /path/to/install.sh}"
arch="$(uname -m)"
user=tester
home="/home/$user"

if command -v apt-get >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null
elif command -v dnf >/dev/null; then
  # Container images can leave out runuser and useradd; desktops never do.
  dnf install -y -q shadow-utils util-linux >/dev/null
fi
command -v curl >/dev/null || { echo "install test: the image has no curl" >&2; exit 1; }

# The release assets, named as CI publishes them.
release="$(mktemp -d)"
cp "$appimage" "$release/Lattice-$arch.AppImage"
(cd "$release" && sha256sum "Lattice-$arch.AppImage" > SHA256SUMS)
chmod -R a+rX "$release"

useradd -m "$user"
as_user() { runuser -u "$user" -- env -i HOME="$home" PATH=/usr/local/bin:/usr/bin:/bin "$@"; }
fail() { echo "install test failed: $1" >&2; exit 1; }

as_user LATTICE_BASE_URL="file://$release" sh "$installer"
app="$home/.local/bin/lattice"
desktop="$home/.local/share/applications/app.leo1oel.researchwriter.desktop"
[[ -x "$app" ]] || fail "$app is missing"
[[ "$(sha256sum < "$app")" == "$(sha256sum < "$appimage")" ]] || fail "$app is not the release's AppImage"
[[ -f "$desktop" ]] || fail "no menu entry"
grep -qx "Exec=\"$app\"" "$desktop" || fail "the menu entry does not start $app: $(grep '^Exec=' "$desktop")"
icon="$(sed -n 's/^Icon=//p' "$desktop")"
compgen -G "$home/.local/share/icons/hicolor/*/apps/$icon.png" >/dev/null || fail "no $icon icon was installed"

# A checksum that does not match must leave nothing behind.
echo "0000000000000000000000000000000000000000000000000000000000000000  Lattice-$arch.AppImage" > "$release/SHA256SUMS"
as_user rm -f "$app"
if as_user LATTICE_BASE_URL="file://$release" sh "$installer" 2>/dev/null; then fail "a bad checksum was accepted"; fi
[[ ! -e "$app" ]] || fail "a bad checksum still installed $app"
compgen -G "$home/.local/bin/.lattice-install.*" >/dev/null && fail "a failed install left its download behind"

as_user sh "$installer" --uninstall
[[ ! -e "$desktop" ]] || fail "--uninstall left the menu entry"
compgen -G "$home/.local/share/icons/hicolor/*/apps/$icon.png" >/dev/null && fail "--uninstall left the icons"

echo "install ok: $(. /etc/os-release && echo "$PRETTY_NAME")"
