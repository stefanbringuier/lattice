#!/usr/bin/env bash
# Turn the AppImage `tauri build` makes into the one Lattice ships, in place:
#
#   bash scripts/appimage/finish.sh path/to/Lattice.AppImage
#
# Runs on the Debian or Ubuntu machine that built the image (x86_64 or
# aarch64) and needs curl, sha256sum, objdump (binutils), and mksquashfs and
# unsquashfs (squashfs-tools). It fails rather than ship an image that breaks one of the
# checks below, and prints what the image holds.
set -euo pipefail

appimage="$(realpath "${1:?usage: finish.sh path/to/Lattice.AppImage}")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arch="$(uname -m)"

# uruntime replaces the stock AppImage runtime because it falls back to
# extracting itself when FUSE is missing (containers, minimal installs, no
# fusermount) instead of refusing to start. Pinned by release and SHA-256.
runtime_version=v0.8.1
case "$arch" in
  x86_64) runtime_sha256=2153e68d63f570c7ebe3d1f38df0fa16814f34d839c5cce2ee42667e327708e8 ;;
  aarch64) runtime_sha256=5644d0584ebcb950924c2c549e597ac6a08bc42e07e6fac2d111fff96d39a152 ;;
  *) echo "No pinned AppImage runtime for $arch." >&2; exit 1 ;;
esac
runtime_url="https://github.com/VHSgunzo/uruntime/releases/download/$runtime_version/uruntime-appimage-squashfs-$arch"

fail() { echo "finish.sh: $1" >&2; exit 1; }
command -v objdump >/dev/null || fail "needs objdump (binutils)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The runtime the image came with is replaced below and never run here, as it
# may not read the image's compression. An AppImage is that runtime's ELF
# followed by the squashfs image, which starts after the ELF's section headers.
[[ "$(head -c 4 "$appimage" | od -An -c | tr -d ' ')" == '177ELF' ]] || fail "$appimage is not an AppImage"
read -r section_headers < <(od -An -t u8 -j 40 -N 8 "$appimage")
read -r header_size header_count < <(od -An -t u2 -j 58 -N 4 "$appimage")
appdir="$work/squashfs-root"
unsquashfs -q -n -no-xattrs -o "$((section_headers + header_size * header_count))" \
  -d "$appdir" "$appimage" >/dev/null || fail "could not unpack the image in $appimage"
[[ -x "$appdir/AppRun" ]] || fail "no AppRun after extracting $appimage"

# The graphics stack must be the host's own: it has to match the machine's
# kernel driver and Mesa. Mesa links the host's libwayland-client and
# libwayland-server, and a copy bundled from the build distro is older; loaded
# first, it is the one Mesa gets, and WebKit aborts with "Could not create
# default EGL display". libwayland-cursor and libwayland-egl stay bundled:
# GTK needs them, Mesa does not, and Fedora installs them only with GTK.
# linuxdeploy already leaves out most of this list, which is enforced here.
host_only=(-name 'libwayland-client.so*' -o -name 'libwayland-server.so*' -o -name 'libEGL*.so*'
  -o -name 'libGL*.so*' -o -name 'libgbm.so*' -o -name 'libdrm*.so*' -o -name 'libvulkan.so*'
  -o -name 'libglapi.so*')
echo "--- removed, the host provides these ---"
find "$appdir" \( "${host_only[@]}" \) -print -delete

# The AppImage exclude list keeps FriBidi out because a bundled copy can break
# the host's Pango. Lattice bundles its own Pango, which needs FriBidi, and
# installs without a desktop (minimal Debian and Ubuntu) have none.
for soname in libfribidi.so.0; do
  source_lib="/usr/lib/$arch-linux-gnu/$soname"
  [[ -f "$source_lib" ]] || fail "$source_lib, which the image bundles, is not on the build machine"
  cp -L "$source_lib" "$appdir/usr/lib/$soname"
done

# WebKit's GL loader, libepoxy, opens libGLESv2.so.2 while running and aborts
# without it. Every Mesa or NVIDIA driver serves GLES, but Debian, Ubuntu and
# Fedora ship libglvnd's GLES front end in a package of its own (libgles2,
# libglvnd-gles), which a desktop without GNOME can lack. The image carries
# that front end in usr/lib/fallback, off every library path, and the AppRun
# hook adds it only where the host has none. It hands each call to the host's
# driver, as the host's own copy would.
gles="/usr/lib/$arch-linux-gnu/libGLESv2.so.2"
objdump -p "$gles" | grep -q 'NEEDED *libGLdispatch\.so\.0' \
  || fail "$gles is not libglvnd's GLES front end"
mkdir -p "$appdir/usr/lib/fallback"
cp -L "$gles" "$appdir/usr/lib/fallback/"

# Every library the image links must be in it, or be one the AppImage exclude
# list (AppImageCommunity/pkg2appimage, file excludelist) counts on every
# desktop to have: glibc, the C++ runtime, the base font and X11 libraries and
# the graphics stack, here with the libwayland-server Mesa links. Anything else
# is a library some distro leaves out, so the build names each one and stops.
host_provided=(
  'ld-linux*.so.*' libc.so.6 libm.so.6 libmvec.so.1 libdl.so.2 libpthread.so.0 librt.so.1
  libresolv.so.2 libutil.so.1 libanl.so.1 libthread_db.so.1 'libnss_*.so.2'
  libstdc++.so.6 libgcc_s.so.1 libz.so.1 libexpat.so.1 libuuid.so.1 libcom_err.so.2
  libgpg-error.so.0 libgmp.so.10 libusb-1.0.so.0 libICE.so.6 libSM.so.6 libasound.so.2
  libfontconfig.so.1 libfreetype.so.6 libharfbuzz.so.0
  libX11.so.6 libX11-xcb.so.1 libxcb.so.1 libxcb-dri2.so.0 libxcb-dri3.so.0
  libGL.so.1 libEGL.so.1 libGLX.so.0 libGLdispatch.so.0 libOpenGL.so.0 libGLESv2.so.2
  libgbm.so.1 libdrm.so.2 libglapi.so.0 libvulkan.so.1
  libwayland-client.so.0 libwayland-server.so.0
)
from_host() {
  local pattern
  for pattern in "${host_provided[@]}"; do
    # shellcheck disable=SC2053 # the pattern is meant to glob.
    [[ "$1" == $pattern ]] && return 0
  done
  return 1
}
# objdump names each file it reads ("path:     file format elf64-...") and
# rejects the scripts among the candidates, which is why it may exit non-zero.
links="$(find "$appdir" -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.node' -o -perm -u+x \) -print0 \
  | xargs -0 objdump -p 2>/dev/null \
  | awk '/ file format / { file = $0; sub(/:[[:space:]]+file format .*/, "", file); next }
         $1 == "NEEDED" || $1 == "SONAME" { print $1 "\t" $2 "\t" file }')" || true
[[ -n "$links" ]] || fail "objdump found no linked libraries in the image"
declare -A in_image=() host_needs=()
while IFS= read -r name; do in_image[$name]=1; done \
  < <(find "$appdir" \( -type f -o -type l \) -name '*.so*' -printf '%f\n')
while IFS=$'\t' read -r kind name _; do
  if [[ "$kind" == SONAME ]]; then in_image[$name]=1; fi
done <<< "$links"
missing=()
while IFS=$'\t' read -r kind name file; do
  [[ "$kind" == NEEDED && -z "${in_image[$name]:-}" ]] || continue
  if from_host "$name"; then
    host_needs[$name]=1
  else
    missing+=("$name, needed by ${file#"$appdir"/}")
  fi
done <<< "$links"
echo "--- libraries the host provides ---"
printf '%s\n' "${!host_needs[@]}" | sort
if ((${#missing[@]} > 0)); then
  printf '  %s\n' "${missing[@]}" | sort -u >&2
  fail "the image links the libraries above, which it does not bundle and not every desktop has"
fi

# The hook runs after linuxdeploy's GTK hook, which it amends.
grep -q '^this_dir=' "$appdir/AppRun" && grep -q '^exec ' "$appdir/AppRun" \
  || fail "AppRun is not the script linuxdeploy writes, so the Lattice hook cannot be added"
# The runtime sets APPDIR, but an image unpacked with --appimage-extract and
# started through its AppRun has none until the GTK hook supplies it, and the
# GStreamer hook runs first. Its plugin path would then be the host's
# /usr/lib/gstreamer-1.0 (Arch), whose plugins the image's GStreamer cannot load.
if ! grep -q '^export APPDIR=' "$appdir/AppRun"; then
  sed -i '/^this_dir=/a export APPDIR="${APPDIR:-$this_dir}"' "$appdir/AppRun"
fi
grep -q '^export APPDIR=' "$appdir/AppRun" || fail "could not set APPDIR in AppRun"
install -m 644 "$here/apprun-hook.sh" "$appdir/apprun-hooks/lattice.sh"
if ! grep -q 'apprun-hooks/"lattice.sh"' "$appdir/AppRun"; then
  sed -i '/^exec /i source "$this_dir"/apprun-hooks/"lattice.sh"' "$appdir/AppRun"
fi
[[ "$(grep -n 'apprun-hooks/' "$appdir/AppRun" | tail -n1)" == *'"lattice.sh"'* ]] \
  || fail "the Lattice hook is not the last one AppRun sources"
# The GTK hook forces X11 against a Wayland crash (tauri-apps/tauri#8541) that
# came from the bundled libwayland-client removed above. Forced, a Wayland
# desktop draws Lattice through XWayland: slower, and blurry on a scaled
# screen. The Lattice hook picks the session's backend instead.
gtk_hook="$appdir/apprun-hooks/linuxdeploy-plugin-gtk.sh"
[[ -f "$gtk_hook" ]] || fail "linuxdeploy's GTK hook is not in the image"
sed -i '/^export GDK_BACKEND=/d' "$gtk_hook"
if grep -q 'GDK_BACKEND' "$gtk_hook"; then fail "the GTK hook still sets GDK_BACKEND"; fi

for helper in WebKitWebProcess WebKitNetworkProcess gst-plugin-scanner; do
  [[ -n "$(find "$appdir" -name "$helper" -type f -print -quit)" ]] || fail "$helper is not bundled"
done
# Without appsink WebKit turns off all media, Lattice's interface sounds too
# (see media-plugins.sh).
[[ -f "$appdir/usr/lib/gstreamer-1.0/libgstapp.so" ]] \
  || fail "the GStreamer plugins are not bundled; is bundleMediaFramework on and GSTREAMER_PLUGINS_DIR set?"

cache="${XDG_CACHE_HOME:-$HOME/.cache}/lattice-appimage"
runtime="$cache/uruntime-$runtime_version-$arch"
if [[ ! -f "$runtime" ]] || ! echo "$runtime_sha256  $runtime" | sha256sum -c --status; then
  mkdir -p "$cache"
  curl -fsSL --retry 3 -o "$runtime.part" "$runtime_url"
  mv "$runtime.part" "$runtime"
fi
echo "$runtime_sha256  $runtime" | sha256sum -c --status || fail "$runtime_url failed its SHA-256 check"
cp "$runtime" "$work/runtime"
# Fall back to extracting whatever the image's size (the default stops at 350 MiB).
sed -i 's|URUNTIME_EXTRACT=[0-9]|URUNTIME_EXTRACT=2|' "$work/runtime"
grep -aq 'URUNTIME_EXTRACT=2' "$work/runtime" || fail "could not set the runtime's extract fallback"

mksquashfs "$appdir" "$work/image.squashfs" -root-owned -noappend -no-progress \
  -comp zstd -Xcompression-level 19 -b 1M >/dev/null
cat "$work/runtime" "$work/image.squashfs" > "$work/Lattice.AppImage"
chmod 755 "$work/Lattice.AppImage"

# The new runtime must find the image and give back every file in it.
[[ "$("$work/Lattice.AppImage" --appimage-offset)" == "$(stat -c %s "$work/runtime")" ]] \
  || fail "the runtime does not find the appended image"
mkdir "$work/check"
(cd "$work/check" && "$work/Lattice.AppImage" --appimage-extract >/dev/null)
extracted="$(find "$work/check" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ "$(cd "$appdir" && find . | sort)" == "$(cd "$extracted" && find . | sort)" ]] \
  || fail "the finished image does not extract to the same files"

echo "--- AppRun ---"
cat "$appdir/AppRun"
echo "--- GTK hook ---"
cat "$appdir"/apprun-hooks/linuxdeploy-plugin-gtk*.sh 2>/dev/null || true
echo "--- GIO modules ---"
find "$appdir" -path '*gio/modules*' -name '*.so' || true
echo "--- bundled libraries ---"
ls "$appdir/usr/lib"
mv "$work/Lattice.AppImage" "$appimage"
ls -lh "$appimage"
