#!/bin/sh
# Build Corne firmware (and the Prospector scanner) in the ZMK docker image.
#
#   ./build.sh              # left + right + scanner
#   ./build.sh left         # one target: left | right | scanner | reset
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
# carrefinho's module is the only one with a dongle-mode display; its main
# branch targets ZMK v0.3/Zephyr 3.5, so ZMK main needs this branch.
CARREFINHO_BRANCH=feat/new-status-screens

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

[ -d "$ROOT/zmk" ] || git clone --depth 1 https://github.com/zmkfirmware/zmk.git "$ROOT/zmk"
[ -d "$ROOT/prospector-zmk-module" ] || git clone --depth 1 -b "$MODULE_TAG" \
  https://github.com/t-ogura/prospector-zmk-module.git "$ROOT/prospector-zmk-module"
[ -d "$ROOT/prospector-carrefinho" ] || git clone --depth 1 -b "$CARREFINHO_BRANCH" \
  https://github.com/carrefinho/prospector-zmk-module.git "$ROOT/prospector-carrefinho"
[ -d "$ROOT/zmk/zephyr" ] || docker run --rm -v "$ROOT:/w" -w /w/zmk "$IMAGE" \
  sh -c 'west init -l app && west update && west zephyr-export'

build() { # name board shield extra-args...
  name=$1 board=$2 shield=$3; shift 3
  docker run --rm -v "$ROOT:/w" -w /w/zmk/app "$IMAGE" \
    west build -p -b "$board" -d "build/$name" -- \
      -DSHIELD="$shield" -DZMK_CONFIG=/w/miryoku_zmk/config \
      -DZMK_EXTRA_MODULES=/w/prospector-zmk-module "$@"
  mkdir -p "$OUT"
  cp "$ROOT/zmk/app/build/$name/zephyr/zmk.uf2" "$OUT/$name.uf2"
  echo "  -> $OUT/$name.uf2"
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
    left)    build left  "$BOARD" "corne_left nice_view_adapter nice_view" $adv_args ;;
    # dongle setup: the Prospector is central, so both halves are peripherals
    # and no status advertisement is needed (the dongle drives its own screen)
    left_peripheral) build left_peripheral "$BOARD" \
               "corne_left nice_view_adapter nice_view" \
               -DCONFIG_ZMK_SPLIT_ROLE_CENTRAL=n ;;
    # The split pairing fix (latency 0 / supervision timeout 10s) lives in
    # config/corne_dongle.conf — merged for every corne_dongle build, so it
    # cannot be lost from the command line. See that file for why.
    # headless controller dongle — no display module; the tested fallback
    dongle_bare) build dongle_bare "$DONGLE_BOARD" "corne_dongle" ;;
    # no APDS9960 on this unit: the adapter shield selects it by default and
    # the driver then logs "sensor: device not ready", pinning the backlight
    # to 5%. Classic is the layout verified on hardware and shipped in
    # firmware/2026-09-09-dongle_stable_v1; swap the layout flag for
    # _FIELD / _OPERATOR to try the others (they differ by under 4 KB of RAM).
    dongle)  build dongle "$DONGLE_BOARD" "corne_dongle prospector_adapter" \
               -DZMK_EXTRA_MODULES=/w/prospector-carrefinho \
               -DCONFIG_PROSPECTOR_USE_AMBIENT_LIGHT_SENSOR=n \
               -DCONFIG_PROSPECTOR_FIXED_BRIGHTNESS=80 \
               -DCONFIG_PROSPECTOR_STATUS_SCREEN_CLASSIC=y ;;
    right)   build right "$BOARD" "corne_right nice_view_adapter nice_view" ;;
    # ponytail: scanner conf lives in walter0331/zmk-config-prospector
    scanner) build scanner "$DONGLE_BOARD" prospector_scanner \
               -DZMK_CONFIG=/w/zmk-config-prospector/config $scanner_args ;;
    # touch panel is fitted (CST816S) even though stock Prospector ignores it;
    # adds swipe between layouts and a runtime brightness slider
    scanner_touch) build scanner_touch "$DONGLE_BOARD" prospector_scanner \
               -DZMK_CONFIG=/w/zmk-config-prospector/config $scanner_args \
               -DEXTRA_CONF_FILE=/w/zmk-config-prospector/config/prospector_scanner_touch.conf ;;
    # flash to both halves to clear BLE bonds, then reflash the real firmware
    reset)   build reset "$BOARD" settings_reset ;;
    reset_dongle) build reset_dongle "$DONGLE_BOARD" settings_reset ;;
    *) echo "unknown target: $target" >&2; exit 1 ;;
  esac
done
