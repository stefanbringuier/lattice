#!/usr/bin/env bash
# Launch an AppImage in a throwaway distro container, through its AppRun as a
# user's desktop would, and fail if it cannot start, renders nothing, or breaks
# the host tools it runs as children. FUSE is not exercised: containers have
# none, so the image is extracted first.
#
#   bash smoke-appimage.sh /path/to/Lattice.AppImage [x11|wayland]
#
# Run as root it installs what it needs. SMOKE_OUT keeps the logs and screenshot.
set -euo pipefail

appimage="${1:-}"
backend="${2:-x11}"
if [[ ! -f "$appimage" ]]; then
  echo "usage: $0 /path/to/Lattice.AppImage [x11|wayland]" >&2
  exit 2
fi

# Besides the test's own tools, a container gets exactly the libraries
# scripts/appimage/finish.sh lets the image take from the host: the ones the
# AppImage exclude list counts on every desktop to have, and the graphics
# stack. Any other library the image lacks then fails here.
host_sonames=(libGL.so.1 libEGL.so.1 libgbm.so.1 libdrm.so.2 libwayland-client.so.0
  libwayland-server.so.0 libfontconfig.so.1 libfreetype.so.6 libharfbuzz.so.0 libX11.so.6
  libX11-xcb.so.1 libxcb.so.1 libasound.so.2 libusb-1.0.so.0 libICE.so.6 libSM.so.6
  libgmp.so.10 libgpg-error.so.0 libcom_err.so.2 libexpat.so.1 libuuid.so.1 libz.so.1)
install_deps() {
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      dbus fonts-dejavu-core git imagemagick perl xvfb \
      libegl1 libegl-mesa0 libgl1 libgl1-mesa-dri libgbm1 libdrm2 libwayland-client0 \
      libwayland-server0 libfontconfig1 libfreetype6 libharfbuzz0b libx11-6 libx11-xcb1 \
      libxcb1 libasound2t64 libusb-1.0-0 libice6 libsm6 libgmp10 libgpg-error0 libcom-err2 \
      libexpat1 libuuid1 zlib1g >/dev/null
  elif command -v dnf >/dev/null; then
    if grep -qi '^ID="\?centos' /etc/os-release; then
      # ImageMagick and Weston live in EPEL, which needs CRB on CentOS Stream.
      dnf install -y -q dnf-plugins-core epel-release >/dev/null
      dnf config-manager --set-enabled crb
    fi
    # RHEL 10 and CentOS Stream 10 ship no X server, so they run the Wayland test.
    local display_server=xorg-x11-server-Xvfb
    if [[ "$backend" == wayland ]]; then display_server=weston; fi
    # By soname, which holds across Fedora and CentOS package names.
    dnf install -y -q dbus-daemon dbus-tools dejavu-sans-fonts findutils git-core \
      ImageMagick mesa-dri-drivers mesa-libEGL mesa-libGL mesa-libgbm perl "$display_server" \
      "${host_sonames[@]/%/()(64bit)}" >/dev/null
  elif command -v pacman >/dev/null; then
    pacman -Syu --noconfirm --needed dbus findutils git imagemagick mesa perl \
      ttf-dejavu weston xorg-server-xvfb \
      alsa-lib e2fsprogs expat fontconfig freetype2 gmp harfbuzz libdrm libglvnd \
      libgpg-error libice libsm libusb libx11 libxcb util-linux-libs wayland >/dev/null
  fi
  dbus-uuidgen --ensure
}

# Re-enter under a session bus, as a desktop provides; WebKit and GTK expect one.
if [[ -z "${SMOKE_IN_SESSION:-}" ]]; then
  if ((EUID == 0)); then
    install_deps
  fi
  SMOKE_IN_SESSION=1 exec dbus-run-session -- bash "$0" "$@"
fi

workdir="$(mktemp -d)"
cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
  if [[ -n "${SMOKE_OUT:-}" ]]; then
    cp "$workdir"/*.log "$workdir"/*.png "$SMOKE_OUT"/ 2>/dev/null || true
    # The container runs as root; leave results the host user can replace.
    chmod -R a+rwX "$SMOKE_OUT" 2>/dev/null || true
  fi
  # The app's helpers (WebKit, the portal) can still be writing as they exit,
  # which fails the delete; the container goes away with it regardless.
  rm -rf "$workdir" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  echo "smoke failed: $1" >&2
  if [[ -f "$workdir/app.log" ]]; then
    tail -n 40 "$workdir/app.log" >&2
  fi
  exit 1
}

cp "$appimage" "$workdir/app.AppImage"
chmod +x "$workdir/app.AppImage"
mkdir "$workdir/extract"
(cd "$workdir/extract" && ../app.AppImage --appimage-extract >/dev/null)
root="$(find "$workdir/extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -x "$root/AppRun" ]] || fail "no AppRun after extract"
inner="$(find "$root/usr/bin" -type f \( -name Lattice -o -name research-writer \) | head -n1)"
[[ -n "$inner" ]] || fail "app binary not found after extract"
inner="$(realpath "$inner")"
# A bundled graphics stack or libwayland breaks EGL on any host whose Mesa is
# newer than the build distro's. usr/lib/fallback holds the GLES front end the
# AppRun hook uses only on hosts without one.
bundled="$(find "$root" -not -path '*/usr/lib/fallback/*' \( -name 'libwayland-client.so*' \
  -o -name 'libwayland-server.so*' -o -name 'libEGL*.so*' -o -name 'libGL*.so*' -o -name 'libgbm.so*' \
  -o -name 'libdrm*.so*' \) -printf '%f ')"
[[ -z "$bundled" ]] || fail "the image bundles libraries the host must provide: $bundled"

# The loader stops at the first library it cannot find, so every ELF file in
# the image is checked here first, for libraries that are neither in the image
# nor on this system. The test fails on them after the launch has run too.
declare -A in_image=()
while IFS= read -r name; do in_image[$name]=1; done \
  < <(find "$root" \( -type f -o -type l \) -name '*.so*' -printf '%f\n')
lacking=""
while IFS= read -r -d '' file; do
  magic=""
  LC_ALL=C read -r -n 4 magic < "$file" || true
  [[ "$magic" == $'\x7fELF' ]] || continue
  while read -r name arrow what _; do
    [[ "$arrow" == "=>" && "$what" == not && -z "${in_image[$name]:-}" ]] || continue
    lacking+="  $name, needed by ${file#"$root"/}"$'\n'
  done < <(ldd "$file" 2>/dev/null || true)
done < <(find "$root" -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.node' -o -perm -u+x \) -print0)
if [[ -n "$lacking" ]]; then
  echo "libraries neither the image nor this system has:" >&2
  printf '%s' "$lacking" | sort -u >&2
fi

export HOME="$workdir/home" XDG_RUNTIME_DIR="$workdir/run" LIBGL_ALWAYS_SOFTWARE=1
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# A desktop sets the display variables and nothing else; choosing a GDK
# backend from them is AppRun's job, so neither branch sets GDK_BACKEND.
# The Wayland branch has no XWayland, the case the Lattice hook must handle.
if [[ "$backend" == wayland ]]; then
  weston --backend=headless --socket=smoke --idle-time=0 >"$workdir/compositor.log" 2>&1 &
  socket="$XDG_RUNTIME_DIR/smoke"
  export WAYLAND_DISPLAY=smoke
  unset DISPLAY
else
  Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp >"$workdir/compositor.log" 2>&1 &
  socket=/tmp/.X11-unix/X99
  export DISPLAY=:99
  unset WAYLAND_DISPLAY
fi
for _ in $(seq 100); do
  [[ -S "$socket" ]] && break
  sleep 0.1
done
[[ -S "$socket" ]] || fail "the $backend display did not start: $(cat "$workdir/compositor.log")"

(cd "$root" && exec ./AppRun) >"$workdir/app.log" 2>&1 &

app_pid() {
  local process
  for process in /proc/[0-9]*; do
    if [[ "$(readlink "$process/exe" 2>/dev/null)" == "$inner" ]]; then
      echo "${process##*/}"
      return 0
    fi
  done
  return 1
}

check_log() {
  local fatal='error while loading shared libraries|symbol lookup error|undefined symbol|GLIBC_[0-9]|not found \(required by|MESA-LOADER: failed|failed to load driver|Couldn.t open lib|GStreamer element [^ ]* not found|GStreamer-WARNING|No GSettings schemas|^Segmentation|Could not create default EGL display|EGL_BAD_|Error 71 \(Protocol error\)'
  if grep -Eiq "$fatal" "$1"; then
    fail "$2: $(grep -Ei -m5 "$fatal" "$1")"
  fi
}

pid=""
for _ in $(seq 40); do
  pid="$(app_pid || true)"
  [[ -n "$pid" ]] && break
  sleep 0.5
done
[[ -n "$pid" ]] || fail "the app never started"
# Hosts without libglvnd's GLES front end get the image's (see the AppRun hook).
gles=host
if tr '\0' '\n' <"/proc/$pid/environ" | grep -q '^LD_LIBRARY_PATH=.*/usr/lib/fallback'; then
  gles=image
fi
app_variable() { tr '\0' '\n' <"/proc/$pid/environ" | sed -n "s/^$1=//p"; }
# The image's GStreamer can load only the image's plugins; a host's are built
# for another GStreamer release.
gst_plugins="$(app_variable GST_PLUGIN_SYSTEM_PATH_1_0)"
[[ "$gst_plugins" == "$(realpath "$root")"/* ]] \
  || fail "GStreamer looks for plugins outside the image: '$gst_plugins'"

# X11 gets a screenshot, which must show more than a blank window's few colors.
colors=0
if [[ "$backend" == x11 ]]; then
  for _ in $(seq 24); do
    sleep 5
    kill -0 "$pid" 2>/dev/null || fail "the app exited during startup"
    import -window root "$workdir/screenshot.png"
    colors="$(identify -format '%k' "$workdir/screenshot.png")"
    ((colors >= 32)) && break
  done
  ((colors >= 32)) || fail "the window stayed blank ($colors colors on screen)"
else
  sleep 30
fi
kill -0 "$pid" 2>/dev/null || fail "the app exited during startup"
check_log "$workdir/app.log" "startup errors"
# WebKit starts GStreamer with its first page. Without appsink in the registry
# that writes, WebKit turns off all media, the interface sounds too.
registry="$(app_variable GST_REGISTRY_1_0)"
[[ -f "$registry" ]] && grep -aq appsink "$registry" \
  || fail "GStreamer did not register the image's media plugins (registry '${registry:-unset}')"

# Children inherit the app's environment. AppRun can add library paths to it
# that break the host's own tools (latexmk's perl, git, the terminal's shell).
mapfile -d '' -t app_env <"/proc/$pid/environ"
for tool in "git --version" "perl -v" "sh -c true"; do
  # shellcheck disable=SC2086 # the tool's words are meant to split.
  if ! env -i "${app_env[@]}" $tool >"$workdir/child.log" 2>&1; then
    fail "host '$tool' breaks in the app's environment: $(tail -n 3 "$workdir/child.log")"
  fi
  check_log "$workdir/child.log" "host '$tool' in the app's environment"
done

[[ -z "$lacking" ]] || fail "the image needs libraries that are neither bundled nor on this system (listed above)"
echo "smoke ok: $(. /etc/os-release && echo "$PRETTY_NAME"), $backend, GLES from the $gles, $colors colors on screen"
