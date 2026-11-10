#!/usr/bin/env bash
# Pick the GStreamer plugins the AppImage carries, out of everything the build
# machine has installed, and print the directory that holds them:
#
#   export GSTREAMER_PLUGINS_DIR="$(bash scripts/appimage/media-plugins.sh)"
#
# WebKitGTK plays sound through GStreamer: Lattice's interface sounds are Web
# Audio, synthesized live, so only audio output is needed, no decoders. With
# bundleMediaFramework (src-tauri/tauri.linux.conf.json), linuxdeploy copies
# every plugin in GSTREAMER_PLUGINS_DIR and the libraries they link, so that
# directory holds only these. Needs the Debian or Ubuntu packages
# gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-alsa and
# gstreamer1.0-pulseaudio.
set -euo pipefail

source_dir="/usr/lib/$(uname -m)-linux-gnu/gstreamer-1.0"
plugins=(
  coreelements                 # queue, capsfilter: any pipeline
  app                          # appsink, which WebKit requires to start media at all
  typefindfunctions            # stream type detection WebKit's media setup runs
  audioconvert audioresample volume interleave  # Web Audio's output path
  autodetect                   # autoaudiosink, which picks one of the next two
  pulseaudio                   # the desktop's sound server (PulseAudio, or PipeWire's)
  alsa                         # the sound card directly, where no server runs
)

target="${TMPDIR:-/tmp}/lattice-gstreamer-plugins"
rm -rf "$target"
mkdir -p "$target"
for plugin in "${plugins[@]}"; do
  file="$source_dir/libgst$plugin.so"
  if [[ ! -f "$file" ]]; then
    echo "media-plugins.sh: $file is missing; install the GStreamer packages named above" >&2
    exit 1
  fi
  ln -s "$file" "$target/"
done
echo "$target"
