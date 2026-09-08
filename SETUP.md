# Walter's Corne — setup and runbook

Typeractive Corne (nice!nano v2 × 2, nice!view × 2), Miryoku layout, QWERTY,
plus a Prospector scanner display. Built locally with docker; the GitHub
workflows in this fork are **not** used and would fail (see Gotchas).

## Rebuild from nothing

    git clone git@github-walter0331:walter0331/miryoku_zmk.git
    cd miryoku_zmk && git checkout corne-qwerty-tuning
    ./build.sh            # clones deps on first run, ~2GB, then builds

Outputs land in `out/`: `left.uf2`, `right.uf2`, `scanner.uf2`.
`./build.sh reset` builds the settings_reset image.

## How the firmware is composed

There is no repo that merges everything. ZMK composes at build time:

| Input | Supplies | Passed as |
|---|---|---|
| `../zmk` (ZMK main, Zephyr 4.1) | OS, BLE stack, corne + nice_view shields | `-b`, `-DSHIELD` |
| `config/` (this repo) | keymap, Kconfig | `-DZMK_CONFIG` |
| `../prospector-zmk-module` v2.2.3 | status advertisement | `-DZMK_EXTRA_MODULES` |
| `../zmk-config-prospector` | scanner's own config | `-DZMK_CONFIG` (scanner only) |

`build.sh` is the only place that composition is written down.

## Flashing

Double-tap reset on the half → `NICENANO` mounts → drag the `.uf2` on.
Drag in **Finder**; a terminal `cp` to a removable volume is blocked by macOS TCC.

- Keymap-only changes → left half alone (the central runs the keymap).
- Debounce / split RF / TX power → **both** halves.
- Never flash `left.uf2` onto the right half; they are not interchangeable.

Prospector: double-tap its reset → `XIAO-SENSE` mounts → drag `scanner.uf2`.

## Why each setting exists

Every line below was added to fix an observed symptom.

`config/corne.conf`

| Setting | Symptom it fixed |
|---|---|
| `ZMK_POINTING=y` | Mouse layer did nothing — mouse keys are compiled out by default |
| `BT_CTLR_TX_PWR_PLUS_8=y` | Split halves disconnecting; ZMK's documented fix, and the aluminium case attenuates |
| `SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING/PROXY` | See the right half's battery, to tell a flat battery from RF trouble |
| `KSCAN_DEBOUNCE_RELEASE_MS=25` | `n` firing several times per press (chatter). Default is ~5ms |
| `ZMK_STATUS_ADVERTISEMENT=y` + name | Broadcast status for the Prospector scanner |
| `ZMK_STATUS_ADV_CENTRAL_SIDE="LEFT"` | Default is `"RIGHT"`; ours is left, or the scanner swaps the battery readings |

`config/corne.keymap`

| Setting | Symptom it fixed |
|---|---|
| `u_mt` `flavor = "balanced"` | Shift+letter typed fast produced lowercase — `tap-preferred` waits out the full 200ms timer |
| `u_mt` `require-prior-idle-ms = 300` | Home-row mods firing mid-roll: `that` → `tkhat` |
| `u_lt` `tapping-term-ms = 280` | Thumb taps past 200ms became silent layer holds — the character is dropped entirely |
| `u_lt` `quick-tap-ms = 200` | Hold-to-repeat on Space/Backspace |

`miryoku/custom_config.h` — `MIRYOKU_ALPHAS_QWERTY` + `MIRYOKU_TAP_QWERTY`.
Extra layer is QWERTY by default, so it is now identical to Base.

## Gotchas

- **`nice_nano_v2` does not exist on ZMK main.** hardware-model-v2 renamed it;
  use `nice_nano/nrf52840/zmk` (revision defaults to 2.0.0). This is why the
  stock `build-example-*` workflows in this fork fail.
- **`carrefinho/prospector-zmk-module` targets ZMK v0.3 / Zephyr 3.5.** We use
  `t-ogura/…` v2.2.3, which supports ZMK main. Relevant if dongle mode is ever
  revisited.
- **No ambient light sensor.** The beekeeb pre-soldered Prospector (XIAO nRF52840
  + Waveshare 1.69" touch LCD, 240x280) ships without an APDS9960 — its case
  "does not support a proximity sensor". With the sensor enabled in firmware but
  absent in hardware the backlight pins to `ALS_MIN_BRIGHTNESS=5` and the screen
  looks dead. `build.sh` disables it and fixes brightness at 80%.
- The display **is** touch-capable (CST816S) and swipe works — verified on this
  unit, even though beekeeb say Prospector does not use touch. Build it with
  `./build.sh scanner_touch`: swipe between the four layouts, plus a settings
  screen with a runtime brightness slider (the only way to change brightness
  without a rebuild, since there is no light sensor). Fits with room to spare:
  FLASH 85.9%, RAM 86.7%.
- **Sticky `&to` layer keys** (`u_to_U_*`, double-tap) can strand you on a layer,
  and changing layers while a mod is held leaves that modifier latched — every
  key then arrives as ⌥key. Restarting the keyboard clears it.
- `U_BOOT` sits on `Q` (or `P` on Fun): a double-tap there enters the bootloader.
- Scanner shows max 7 layers; Miryoku defines 10.

## Bluetooth

Profiles: hold left outer thumb (Media) + tap `M` `,` `.` `/` for 0-3.
Add **Shift** (`F`) to clear that profile's bond and re-advertise — needed
whenever a host refuses to reconnect. Also "Forget" it on the host.
`settings_reset` on both halves is only for when the *halves* lose each other.

## Hardware history

- Inner right thumb switch died (Enter) — replaced.
- `n` chattered; debounce raised. Watch that half: the aluminium case has a known
  ESD failure mode (see `../case-issue.md`).

## Dongle mode (experiment, 2026-09-09)

The Prospector becomes the central and runs the keymap; both halves become
peripherals. Motivation: the monitor's USB hub follows the active display
input, so moving the screen between the two Macs moves the keyboard with it —
no BLE profile switching. It also equalises left/right latency, since today the
left half is local and the right arrives over BLE.

    ./build.sh dongle left_peripheral right reset reset_dongle

| Target | Board | Notes |
|---|---|---|
| `dongle` | `xiao_ble/nrf52840/zmk` | shields `corne_dongle prospector_adapter`, carrefinho module |
| `left_peripheral` | `nice_nano/nrf52840/zmk` | same shield as `left` plus `ZMK_SPLIT_ROLE_CENTRAL=n` |
| `right` | | unchanged — it was already a peripheral |

**Pairing is automatic.** Split bonds are not BLE profiles: the dongle scans for
peripherals advertising the split service and bonds to the first two it finds.
The procedure is `settings_reset` on all three (so the halves forget the old
left-as-central bond), then the real images, then power all three on together.
The five BLE profiles now belong to the dongle.

### What this costs

- No dongle, no keyboard — the halves cannot talk to a host on their own.
- The Prospector stops being a passive scanner. Dongle-mode display needs
  carrefinho's module, so the t-ogura touch/swipe scanner build does not apply.
- Fixes neither the hold-tap misfires (decided from press durations on whichever
  device is central) nor switch chatter (mechanical).

### Config-file traps found while building this

- `config/corne.conf` is merged for **every** `corne*` shield, the dongle
  included. Module-specific symbols there are fatal for builds without that
  module: undefined Kconfig symbols are a hard error, not a warning. The
  status-advertisement settings therefore live in `build.sh` as per-target
  flags, not in the conf.
- `ZMK_SPLIT_ROLE_CENTRAL` is per-setup for the same shield, so it is a
  per-target flag too, not `config/corne_left.conf`.
- Peripherals report already-transformed key positions (`corne_right.overlay`
  sets `col-offset = <6>`), so the dongle's matrix transform exists only to
  declare 42 positions for the keymap. No position offsets to invent.
