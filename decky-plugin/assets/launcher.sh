#!/usr/bin/env bash
# lichii-bc250 launcher: tunes the emulator for the BC-250 iGPU, then runs eden-cli.
# Usage: lichii-bc250 [-f] [-c <config.ini>] -g "<path to your game dump>"   (default config: game.ini)
#        lichii-bc250 --gui      the Lichii GUI (settings, controller mapping, game list)
# A controller mapped in the GUI is copied into the -c config before the game starts.
set -euo pipefail
CONTAINER="__CONTAINER__"
EDEN_EXEC="__EDEN_EXEC__"
GUI_EXEC="__GUI_EXEC__"
APP_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
INSTALL_MODE="__INSTALL_MODE__"   # native: run the package directly; anything else: in CONTAINER
unset LD_PRELOAD
# A newer release is out: the plugin leaves its tag in this file; say it once and drop it.
update_flag="${XDG_CONFIG_HOME:-$HOME/.config}/lichii-bc250/update-available"
if [ -s "$update_flag" ]; then
    printf 'Lichii BC-250 %s is available: update it in the Decky plugin (Updates).\n' "$(head -n 1 "$update_flag")" >&2
    rm -f "$update_flag"
fi
# The BC-250 iGPU (RADV) with UMA: cap the texture cache so it never tramples
# the 15 GB of system RAM the game and the compositor also live in. 1.5/2 GB (v6) left
# ~2 GB more RAM free in play than 3/3.5 GB, with fewer swap stalls and no texture reloads.
export EDEN_NX2_TC_EXPECTED_MIB=1536
export EDEN_NX2_TC_CRITICAL_MIB=2048
export EDEN_NX2_VSYNC_HZ=30       # the game starts its frames on a 30 Hz tick
export EDEN_NX2_SWAP_INTERVAL=2   # present every second vblank; the game asks for 30 fps
export EDEN_VI2_MAX_RESOLUTION_MODE=1  # report the handheld display mode
export EDEN_NX2_SPLIT=2          # split GPU thread: the back half runs on its own thread
export EDEN_NX2_FENCE_BATCH=1    # batch GPU fence syncpoints
export EDEN_NX2_FRAMES_AHEAD=2   # the game runs a frame ahead of the GPU threads: 13.6 -> 21.3 fps
export EDEN_NX2_PRELOAD_ALL_PIPELINES=0  # cached pipelines build on first sight (boots faster)
# Compile new shaders on 4 workers and 2 driver threads, and give back each worker's memory
# after large shaders: on a first visit to Hyrule Field the default (all threads) took 3.7 GB at
# once and froze the game for up to 13 s while the box swapped.
export EDEN_NX2_PIPELINE_WORKERS=4 EDEN_NX2_PIPELINE_DRIVER_THREADS=2 EDEN_NX2_IR_POOL_CAP_MIB=64
# Steam's shader pre-cache layer records every pipeline the emulator builds into
# ~/.local/share/Steam/steamapps/shadercache/<id>/fozpipelinesv6: it never stops growing (42 GB on
# the BC-250 in one day of play and tests, until the disk was full) and nothing ever uses it.
export DISABLE_VK_LAYER_VALVE_steam_fossilize_1=1
# Borderless Gaming registers its Vulkan effects layer (VK_LAYER_BGFX_effects) for every Vulkan
# program through ~/.local/share/vulkan/loader_settings.d; inside the emulator it aborts at start
# ("Failed to create the thread pool Gate thread"). Its own off switch; nothing on other systems.
export DISABLE_BGFX=1
if [ "${1:-}" = --gui ]; then
    shift
    if [ -z "$GUI_EXEC" ]; then
        echo "This install has no GUI (--build compiles eden-cli only); install a release package for it." >&2
        exit 1
    fi
    EDEN_EXEC="$GUI_EXEC"
else
    config="" prev=""
    for arg in "$@"; do
        [ "$prev" = -c ] && config="$arg"
        prev="$arg"
    done
    # No -c: the BC-250 settings in game.ini (every game; v18).
    if [ -z "$config" ] && [ -f "$APP_DIR/game.ini" ]; then
        config="$APP_DIR/game.ini"
        set -- -c "$config" "$@"
    fi
    if [ -n "$config" ] && [ -f "$APP_DIR/import_gui_controls.py" ] && command -v python3 >/dev/null; then
        python3 "$APP_DIR/import_gui_controls.py" "$config" || true
    fi
fi
# Area loads: when the game starts reading an area's files, the emulator asks the kernel to
# reclaim 1.5 GB of cold memory, so the area's textures don't wait for it (Castle Town entry
# 2.2-3.8 s -> 1.0-2.2 s). Inside the container it can't write its cgroup's memory.reclaim, so
# it leaves the amount in $XDG_RUNTIME_DIR/lichii-bc250-reclaim and this helper writes it to the
# container's scope. Ends when the game does.
reclaim_helper() {
    local request="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lichii-bc250-reclaim" amount pid cg
    rm -f "$request"
    sleep 20
    while pgrep -x eden-cli >/dev/null; do
        if [ -s "$request" ]; then
            amount=$(head -c 16 "$request"); rm -f "$request"
            pid=$(pgrep -x eden-cli | head -n 1)
            cg=$(cut -d: -f3 "/proc/$pid/cgroup" 2>/dev/null); cg=${cg%/container}
            [[ "$amount" =~ ^[0-9]+M$ ]] && [ -n "$cg" ] && echo "$amount" > "/sys/fs/cgroup$cg/memory.reclaim" 2>/dev/null || true
        fi
        sleep 0.25
    done
}
if [ "${EDEN_NX2_PRE_RECLAIM_MIB:-1}" != 0 ]; then
    reclaim_helper </dev/null >/dev/null 2>&1 &
fi
if [ "$INSTALL_MODE" = native ]; then
    exec "$EDEN_EXEC" "$@"
fi
exec distrobox enter "$CONTAINER" -- "$EDEN_EXEC" "$@"
