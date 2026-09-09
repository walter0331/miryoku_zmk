#!/bin/sh
# Build Corne firmware (and the Prospector scanner) in the ZMK docker image.
#
#   ./build.sh              # left + right + scanner
#   ./build.sh left         # one target: left | right | scanner | reset
#
# Output: firmware/builds/<date>/<target>_<label>_<date>_<rev>.uf2
#
# Everything is composed at build time from four inputs; there is no repo
# that merges them:
#
#   zmk/                    ZMK main + Zephyr 4.1, and the corne/nice_view shields
#   miryoku_zmk/config/     this repo: keymap + Kconfig            -DZMK_CONFIG
#   prospector-zmk-module/  status advertisement for the scanner   -DZMK_EXTRA_MODULES
#   docker image            arm toolchain, west, cmake
#
# Both dependencies are cloned next to this repo on first run.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=zmkfirmware/zmk-build-arm:stable
MODULE_TAG=v2.2.3
# The dongle-role display module. Our fork of carrefinho's, whose upstream
# feat/new-status-screens branch is the only one that builds against ZMK main
# (its own main targets ZMK v0.3/Zephyr 3.5). The fork adds runtime brightness,
# idle dimming and touch control — see docs/dongle-display-design.md. The
# directory keeps its original name so existing clones keep working.
DISPLAY_MODULE_REPO=git@github-walter0331:walter0331/prospector-zmk-module.git
DISPLAY_MODULE_BRANCH=walter/dongle-touch-brightness

# nice!nano v2 is "nice_nano/nrf52840/zmk" on ZMK main: hardware-model-v2
# renamed it, and the old "nice_nano_v2" no longer resolves. Revision
# defaults to 2.0.0, which is the v2.
BOARD=nice_nano/nrf52840/zmk
DONGLE_BOARD=xiao_ble/nrf52840/zmk

# Fresh builds go under kbrd/firmware/builds/<date>/ — that is what you drag
# from in Finder (a terminal cp to a removable volume is blocked by macOS TCC).
# Kept separate from the curated snapshot folders beside it
# (firmware/<date>-<name>_v<n>/), which carry a MANIFEST.md of sha256s and must
# stay exactly as manifested — never drop a build into one of those.
# Dated once here, so a build running past midnight does not split in two.
OUT="$ROOT/firmware/builds/$(date +%Y-%m-%d)"

# Every emitted .uf2 is named <target>_<label>_<date>_<rev>.uf2 — see
# ../CLAUDE.md. A bare "dongle.uf2" says which target ran, not which firmware
# you are holding, and the next run of the same target silently overwrites it
# with something different. The rev makes two builds of one target on one day
# distinguishable, which is exactly when a wrong Finder drag happens.
REV=$(git -C "$ROOT/miryoku_zmk" rev-parse --short HEAD 2>/dev/null || echo nogit)
git -C "$ROOT/miryoku_zmk" diff --quiet 2>/dev/null || REV="$REV-dirty"

[ -d "$ROOT/zmk" ] || git clone --depth 1 https://github.com/zmkfirmware/zmk.git "$ROOT/zmk"
[ -d "$ROOT/prospector-zmk-module" ] || git clone --depth 1 -b "$MODULE_TAG" \
  https://github.com/t-ogura/prospector-zmk-module.git "$ROOT/prospector-zmk-module"
[ -d "$ROOT/prospector-carrefinho" ] || git clone --depth 1 -b "$DISPLAY_MODULE_BRANCH" \
  "$DISPLAY_MODULE_REPO" "$ROOT/prospector-carrefinho"
[ -d "$ROOT/zmk/zephyr" ] || docker run --rm -v "$ROOT:/w" -w /w/zmk "$IMAGE" \
  sh -c 'west init -l app && west update && west zephyr-export'

# Cap compiler parallelism. Unset, ninja spawns one gcc per host CPU (12 here)
# inside the Docker VM, and the peak killed Docker Desktop twice mid-build on a
# machine already deep in swap. Four is roughly 2x the wall clock for a quarter
# of the peak memory. Raise it if the host has headroom.
JOBS=${JOBS:-4}

build() { # name label board shield extra-args...
  name=$1 label=$2 board=$3 shield=$4; shift 4
  docker run --rm -v "$ROOT:/w" -w /w/zmk/app \
    -e CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" "$IMAGE" \
    west build -p -b "$board" -d "build/$name" -- \
      -DSHIELD="$shield" -DZMK_CONFIG=/w/miryoku_zmk/config \
      -DZMK_EXTRA_MODULES=/w/prospector-zmk-module "$@"
  mkdir -p "$OUT"
  # The build DIRECTORY keeps the bare target name: SETUP.md points at
  # zmk/app/build/<target>/build_info.yml as the ground truth for what a build
  # actually merged, and incremental rebuilds key off it. Only the output file
  # gets the descriptive name.
  uf2="$OUT/${name}_${label}_$(date +%Y-%m-%d)_${REV}.uf2"
  cp "$ROOT/zmk/app/build/$name/zephyr/zmk.uf2" "$uf2"
  echo "  -> $uf2"
}

# The scanner's own settings are build-time only, so they live here rather
# than in a conf file: layout 2 is Operator, and the ambient light sensor is
# off because with none fitted the backlight pins to 5% and looks dead.
adv_args="-DCONFIG_ZMK_STATUS_ADVERTISEMENT=y \
 -DCONFIG_ZMK_STATUS_ADV_KEYBOARD_NAME=\"Walter Corne\" \
 -DCONFIG_ZMK_STATUS_ADV_CENTRAL_SIDE=\"LEFT\""

scanner_args="-DCONFIG_PROSPECTOR_DEFAULT_LAYOUT=2 \
 -DCONFIG_PROSPECTOR_USE_AMBIENT_LIGHT_SENSOR=n -DCONFIG_PROSPECTOR_FIXED_BRIGHTNESS=80"

for target in ${*:-left right scanner}; do
  case $target in
    # scanner setup: left is central and broadcasts status for the Prospector
    left)    build left  central-niceview "$BOARD" "corne_left nice_view_adapter nice_view" $adv_args ;;
    # dongle setup: the Prospector is central, so both halves are peripherals
    # and no status advertisement is needed (the dongle drives its own screen)
    left_peripheral) build left_peripheral peripheral-niceview "$BOARD" \
               "corne_left nice_view_adapter nice_view" \
               -DCONFIG_ZMK_SPLIT_ROLE_CENTRAL=n ;;
    # The split pairing fix (latency 0 / supervision timeout 10s) lives in
    # config/corne_dongle.conf — merged for every corne_dongle build, so it
    # cannot be lost from the command line. See that file for why.
    # headless controller dongle — no display module; the tested fallback
    dongle_bare) build dongle_bare headless-nodisplay "$DONGLE_BOARD" "corne_dongle" ;;
    # no APDS9960 on this unit: the adapter shield selects it by default and
    # the driver then logs "sensor: device not ready", pinning the backlight
    # to 5%. Classic is the layout verified on hardware and shipped in
    # firmware/2026-09-09-dongle_stable_v1; swap the layout flag for
    # _FIELD / _OPERATOR to try the others (they differ by under 4 KB of RAM).
    # FIXED_BRIGHTNESS is only the FIRST-BOOT value here: with
    # PROSPECTOR_RUNTIME_BRIGHTNESS a level saved by swiping is loaded from
    # settings and wins on every later boot.
    dongle)  build dongle classic-touch-50pct "$DONGLE_BOARD" "corne_dongle prospector_adapter" \
               -DZMK_EXTRA_MODULES=/w/prospector-carrefinho \
               -DCONFIG_PROSPECTOR_USE_AMBIENT_LIGHT_SENSOR=n \
               -DCONFIG_PROSPECTOR_FIXED_BRIGHTNESS=50 \
               -DCONFIG_PROSPECTOR_STATUS_SCREEN_CLASSIC=y \
               -DCONFIG_PROSPECTOR_RUNTIME_BRIGHTNESS=y \
               -DCONFIG_ZMK_IDLE_TIMEOUT=300000 \
               -DCONFIG_PROSPECTOR_TOUCH_BRIGHTNESS=y ;;
    right)   build right peripheral-niceview "$BOARD" "corne_right nice_view_adapter nice_view" ;;
    # ponytail: scanner conf lives in walter0331/zmk-config-prospector
    scanner) build scanner operator-fixed80 "$DONGLE_BOARD" prospector_scanner \
               -DZMK_CONFIG=/w/zmk-config-prospector/config $scanner_args ;;
    # touch panel is fitted (CST816S) even though stock Prospector ignores it;
    # adds swipe between layouts and a runtime brightness slider
    scanner_touch) build scanner_touch operator-swipe "$DONGLE_BOARD" prospector_scanner \
               -DZMK_CONFIG=/w/zmk-config-prospector/config $scanner_args \
               -DEXTRA_CONF_FILE=/w/zmk-config-prospector/config/prospector_scanner_touch.conf ;;
    # same as dongle plus USB logging, for diagnosing touch/brightness on
    # /dev/cu.usbmodem*. Not for daily use: logging costs flash and spams CDC.
    #
    # OBSERVER EFFECT: the per-event LOG_DBG in touch_brightness.c is slow over
    # USB CDC, which backs up Zephyr's input queue until it discards reports
    # ("input_report: Timeout discarded. No blocking in syswq"). Touch feels
    # worse on THIS target than on the real one, where CONFIG_LOG is off and
    # those calls compile away. Use it to find bugs, never to judge feel.
    #
    # Do NOT add CONFIG_LOG_MODE_IMMEDIATE here. With a USB CDC console it
    # deadlocks at boot: the first log write blocks on an endpoint USB has not
    # configured yet, so the dongle never enumerates and the keyboard is dead
    # until you reflash. ZMK_USB_LOGGING uses deferred mode for this reason.
    # Learned the hard way 2026-09-09.
    dongle_log) build dongle_log classic-touch-usblog "$DONGLE_BOARD" "corne_dongle prospector_adapter" \
               -DZMK_EXTRA_MODULES=/w/prospector-carrefinho \
               -DCONFIG_PROSPECTOR_USE_AMBIENT_LIGHT_SENSOR=n \
               -DCONFIG_PROSPECTOR_FIXED_BRIGHTNESS=50 \
               -DCONFIG_PROSPECTOR_STATUS_SCREEN_CLASSIC=y \
               -DCONFIG_PROSPECTOR_RUNTIME_BRIGHTNESS=y \
               -DCONFIG_ZMK_IDLE_TIMEOUT=300000 \
               -DCONFIG_PROSPECTOR_TOUCH_BRIGHTNESS=y \
               -DCONFIG_ZMK_USB_LOGGING=y -DCONFIG_INPUT_LOG_LEVEL_DBG=y ;;

    # flash to both halves to clear BLE bonds, then reflash the real firmware
    reset)   build reset clear-ble-bonds "$BOARD" settings_reset ;;
    reset_dongle) build reset_dongle clear-ble-bonds "$DONGLE_BOARD" settings_reset ;;
    *) echo "unknown target: $target" >&2; exit 1 ;;
  esac
done
