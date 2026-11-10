# Sourced by AppRun after linuxdeploy's GTK hook, so it amends what that hook
# set. Each block answers a way WebKitGTK fails when an AppImage built on one
# distro meets another machine's display server or graphics driver. A value
# the user already set is kept. AppRun runs under `set -e`, so every block is
# an if, which returns 0 when its test fails.

# GLib also loads GIO modules (gvfs, dconf) from the directory it was built
# with, which is where Debian and Ubuntu keep the host's own, built against
# the host's GLib. Where that GLib is newer they fail to load ("undefined
# symbol: g_variant_builder_init_static"), and where they load, two GLibs
# share one process. Only the image's own modules (TLS) are loaded.
if [ -z "${GIO_MODULE_DIR:-}" ] && [ -d "${GIO_EXTRA_MODULES:-}" ]; then
  export GIO_MODULE_DIR="$GIO_EXTRA_MODULES"
fi

# WebKit's GL loader opens libGLESv2.so.2 while running and aborts without it
# ("Couldn't open libGLESv2.so.2"). Debian, Ubuntu and Fedora ship libglvnd's
# GLES front end in a package of its own (libgles2, libglvnd-gles) that a
# desktop without GNOME can lack, so the image carries one in usr/lib/fallback.
# It is used only when the host has none, and drives the host's GPU driver.
case "$(uname -m)" in
  x86_64) lattice_ld_arch=x86-64 ;;
  aarch64) lattice_ld_arch=AArch64 ;;
  *) lattice_ld_arch="" ;;
esac
if [ -n "$lattice_ld_arch" ] && [ -d "${APPDIR:-}/usr/lib/fallback" ] \
  && ! PATH="$PATH:/usr/sbin:/sbin" ldconfig -p 2>/dev/null \
    | grep -q "libGLESv2\.so\.2 (libc6,$lattice_ld_arch"; then
  export LD_LIBRARY_PATH="$APPDIR/usr/lib/fallback${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
unset lattice_ld_arch

# GStreamer records what it found in its plugins in a registry it shares with
# the desktop's own GStreamer apps. The image's plugins sit at a new mount path
# on every start, so Lattice keeps a registry of its own instead of rewriting
# theirs each time.
if [ -n "${GST_PLUGIN_SYSTEM_PATH_1_0:-}" ] && [ -z "${GST_REGISTRY_1_0:-}" ]; then
  export GST_REGISTRY_1_0="${XDG_CACHE_HOME:-$HOME/.cache}/lattice/gstreamer-registry-$(uname -m).bin"
fi

# GTK draws on the session's own display server: Wayland where there is one,
# else X11. Through XWayland a Wayland desktop shows it slower, and blurry on
# a scaled screen. The blocks below follow this choice.
if [ -z "${GDK_BACKEND:-}" ]; then
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    export GDK_BACKEND=wayland
  else
    export GDK_BACKEND=x11
  fi
fi

# On Wayland GTK reads the desktop's font, text scaling and cursor settings
# from GSettings, which needs the dconf GIO module the image does not load
# (above). The settings portal serves the same values over D-Bus, as it does
# for Flatpak apps.
if [ "$GDK_BACKEND" = wayland ] && [ -z "${GTK_USE_PORTAL:-}" ]; then
  export GTK_USE_PORTAL=1
fi

# The session's GTK modules (canberra-gtk-module, appmenu, xapp) are built
# for the host's GTK, so the image's cannot load them, and says so on every
# start. Lattice uses none of them.
unset GTK_MODULES GTK3_MODULES

# With Mesa 25, EGL's default display can fail ("Could not create default EGL
# display: EGL_BAD_PARAMETER") unless the platform is named. On X11 it is X11.
if [ "${GDK_BACKEND:-}" = x11 ] && [ -z "${EGL_PLATFORM:-}" ]; then
  export EGL_PLATFORM=x11
fi

# NVIDIA's proprietary driver shows WebKit's DMA-BUF renderer as a blank or
# crashing window, and on Wayland its explicit sync stalls WebKit's frames.
if [ -e /proc/driver/nvidia ]; then
  export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
  if [ "${GDK_BACKEND:-}" = wayland ]; then
    export __NV_DISABLE_EXPLICIT_SYNC="${__NV_DISABLE_EXPLICIT_SYNC:-1}"
  fi
fi
