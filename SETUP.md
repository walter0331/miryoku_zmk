# Walter's Corne — setup and runbook

Typeractive Corne (nice!nano v2 × 2, nice!view × 2), Miryoku layout, QWERTY,
plus a Prospector scanner display. Built locally with docker; the GitHub
workflows in this fork are **not** used and would fail (see Gotchas).

## Rebuild from nothing

    git clone git@github-walter0331:walter0331/miryoku_zmk.git
    cd miryoku_zmk && git checkout corne-qwerty-tuning
    ./build.sh            # clones deps on first run, ~2GB, then builds

Outputs land in `../firmware/builds/<YYYY-MM-DD>/` — `left.uf2`, `right.uf2`,
`scanner.uf2`. That is the folder you drag from in Finder.
`./build.sh reset` builds the settings_reset image.

Older `out/` copies, if any survive, are stale — build.sh no longer writes there.

**Two kinds of folder under `../firmware/`, do not mix them:**

| | what | rule |
|---|---|---|
| `builds/<date>/` | whatever the last build emitted | disposable, overwritten freely |
| `<date>-<name>_v<n>/` | a curated set with `MANIFEST.md` + sha256 + source commit | **immutable** — adding a file makes the manifest lie |

## How the firmware is composed

There is no repo that merges everything. ZMK composes at build time:

| Input | Supplies | Passed as |
|---|---|---|
| `../zmk` (ZMK main, Zephyr 4.1) | OS, BLE stack, corne + nice_view shields | `-b`, `-DSHIELD` |
| `config/` (this repo) | keymap, Kconfig | `-DZMK_CONFIG` |
| `../prospector-zmk-module` v2.2.3 | status advertisement | `-DZMK_EXTRA_MODULES` |
| `../zmk-config-prospector` | scanner's own config | `-DZMK_CONFIG` (scanner only) |

`build.sh` is the only place that composition is written down.

**Dependencies are cloned by branch, not by commit** (`--depth 1` on `main` /
`v2.2.3` / `feat/new-status-screens`). So a build is reproducible *today* but
not pinned: when upstream moves, so does your firmware. Each
`firmware/<date>-*/MANIFEST.md` records the exact SHAs its images were built
from — to reproduce an old set, `git checkout <sha>` in `../zmk` and the module
clone before running `build.sh`. If a build ever needs to be permanently
reproducible, pin the SHAs in `build.sh` rather than relying on the manifest.

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
- **Two Prospector modules, two branches.** carrefinho's `main` targets ZMK v0.3
  / Zephyr 3.5, but its `feat/new-status-screens` branch builds against ZMK main
  — that is the one `build.sh` clones, and the only one with a dongle-role
  display. t-ogura's v2.2.3 (scanner-role, has touch) also builds against ZMK
  main. See the vocabulary table under Dongle mode.
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

#### "Prospector" means three things — say which

Most of the confusion in this project comes from one word covering a unit, two
modules and two roles. The roles are the part that matters:

| Term | Means |
|---|---|
| **the unit** | the hardware: XIAO nRF52840 + Waveshare 1.69" 240x280 ST7789 + CST816S touch. No APDS9960. |
| **scanner-role** | passive BLE observer. Shows another keyboard's *advertised* status. t-ogura's module. Has touch. |
| **dongle-role** | the split central. Runs the keymap, shows its own *live* state. carrefinho's module. No touch. |

**One unit cannot be both.** A radio cannot receive its own advertisements, so
scanner-role needs a keyboard advertising elsewhere. Choosing dongle-role means
the t-ogura touch build does not apply — its `PROSPECTOR_MODE_SCANNER` is a
standalone bool with no central counterpart on any of its 15 branches.

The two modules are not rivals: t-ogura's LICENSE reads "Copyright (c) 2024
carrefinho (Original Prospector Module)" — it is a fork. Both MIT, so code moves
between them freely.

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
- **`config/<shield>.conf` works, and is the right home for shield-only
  symbols.** `config/corne_dongle.conf` is merged for exactly the builds whose
  SHIELD list contains `corne_dongle`, so symbols that exist only under
  `ZMK_SPLIT_ROLE_CENTRAL` can live there without breaking the halves. This is
  where the split pairing fix lives. Do not confuse it with the shield's own
  `Kconfig.defconfig`: ZMK's `default` values are parsed first and win there, so
  `ZMK_SPLIT_BLE_PREF_LATENCY`/`_TIMEOUT` set in `Kconfig.defconfig` are
  silently ignored (`BT_MAX_CONN`/`BT_MAX_PAIRED` do take effect).
  To check what a build actually merged, read the `kconfig: files:` list in
  `../zmk/app/build/<target>/build_info.yml` — that is ground truth, not a guess.
- `ZMK_SPLIT_ROLE_CENTRAL` is per-setup for the same shield, so it is a
  per-target flag too, not `config/corne_left.conf`.
- Peripherals report already-transformed key positions (`corne_right.overlay`
  sets `col-offset = <6>`), so the dongle's matrix transform exists only to
  declare 42 positions for the keymap. No position offsets to invent.
