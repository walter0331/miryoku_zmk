# Dongle display: brightness + idle — design decisions

Decided 2026-09-09. Vocabulary (unit / scanner-role / dongle-role) is in `SETUP.md`.

**Goal.** One Prospector unit in dongle-role: split central, its own screen, touch
brightness adjustment, and a screen that goes dark when Walter is not there.
Driver: "my eyes are not so good" (brightness) and "I don't want the screen on
when I'm sleeping" (idle).

**Status: gate PASSED and all six steps of §7 BUILT 2026-09-09, not yet
hardware-tested.** Code lives in the fork
`walter0331/prospector-zmk-module`, branch `walter/dongle-touch-brightness`
(`fbf04cb`). Measured cost for all six features on the Classic layout:
**+1428 B flash, +128 B RAM** — 67.94% / 85.06%, against a 5-8 KB estimate.
See §9 for what remains unverified. §6 ran on hardware:
`prospector_dongle` with shields `corne_dongle prospector_adapter` (Classic
layout) pairs with both halves and renders on screen. The design below stands.

## 1. Shape

| # | Decision | Why |
|---|---|---|
| Q1 | **One unit, dongle-role** — not two units, not scanner-role | Keeps the reason dongle mode exists: the monitor's USB hub follows the display input, so the keyboard follows the screen between Macs. Two units would deliver the screen but not that. |
| Q2 | **Fork a module** — `walter0331/prospector-zmk-module` from `carrefinho@feat/new-status-screens` | Touch and idle are module *code*; they cannot be expressed as config. Already tracking a non-default branch, so a fork just makes that explicit. |
| Q7 | Dongle is **always USB-connected** to the Mac | Makes USB suspend a usable "human is gone" signal, and makes remote wakeup work. |
| Q11 | **Mine first**, upstream opportunistically | Get it working; the pairing fix is worth a separate small PR regardless (see §5). |

## 2. Behaviour

| # | Decision | Why |
|---|---|---|
| Q3 | **Two triggers, two levels**: keyboard idle → 1%; Mac asleep → fully off | Keyboard-idle alone leaves the screen glowing at 1% all night, which is the thing being complained about. Mac-asleep is the signal that actually matches "when I'm sleeping". |
| Q4 | Idle state is **dim to 1%**, not blank | `display_blanking_on()` only sends ST7789 `DISP_OFF`; the backlight is not a `zmk,display-led`, so blanking alone leaves a *lit blank panel*. Dimming the PWM is the same amount of code and looks right. |
| Q5 | **Typing wakes it**; touch wakes it too | Both are free — see §4. |
| Q6 | Idle dims to a fixed 1%; waking **restores the user's saved level**; level **persists across reboot** | A brightness that resets on every reboot is not worth a slider. |
| Q8 | Dim after **5 minutes** (`ZMK_IDLE_TIMEOUT=300000`) | ZMK's 30 s default dims while you read a paragraph. Nothing else on a USB-powered dongle uses that timer — it can never deep-sleep (§4). |
| Q9/Q12 | **Brightness only. Direct swipe up/down = ±10%, transient bar overlay.** No settings screen, no layout switching. | See §3 — the settings screen is the one part that does *not* port, so building it buys no reuse and costs 29 KB of a 35 KB budget. |
| Q10 | Layout **Classic or Field**, chosen by looking at it | RAM does not decide this (§3). Legibility does, and nobody has seen it yet. |

## 3. The memory argument (this is what decided Q12)

Measured on real builds, `xiao_ble/nrf52840`, 788 KB FLASH / 256 KB RAM:

| layout | FLASH | RAM | free RAM |
|---|---|---|---|
| Operator | 441,880 — 54.8% | 226,440 — 86.4% | 35,704 B |
| Field    | 483,388 — 59.9% | 224,008 — 85.5% | 38,136 B |
| Classic  | 546,784 — 67.8% | 222,856 — 85.0% | 39,288 B |

Headless `dongle_bare` is 31.2% / 22.5%, so the display stack costs ~167 KB RAM.

- **RAM is the constraint; flash is not.** ~35-39 KB free vs ~259-356 KB free.
- **Layout choice moves RAM by at most 3.6 KB (1.4 points).** It is not a lever.
  An earlier claim that Operator was a meaningful RAM risk was overstated —
  Operator is in fact the *smallest* on flash.
- **A ported settings screen is not affordable.** t-ogura's touch UI runs
  `LV_Z_MEM_POOL_SIZE=49152`; carrefinho's Operator uses `20000`. That delta
  alone is 29 KB of the ~35 KB budget, before the driver, handler, indev and
  widgets.
- **The reuse argument points at the simple option, not away from it.** The
  reusable asset is `touch_handler.c` + `swipe_gesture_event.*` (~400 lines,
  zero scanner coupling) and *both* options reuse it identically. The settings
  screen lives inside `custom_status_screen.c` — 3662 lines, 196
  scanner/advertisement/keyboard references — and would be rewritten, not ported.
- Budget to hold: stop adding at ~92% RAM. Items in §7 should cost ~5-8 KB.

## 4. Verified facts the design leans on

Checked in the local clones, not assumed:

- **Peripheral typing keeps the dongle awake.** `split/central.c:41-47` turns a
  peripheral key event into `zmk_position_state_changed`; `activity.c:110`
  subscribes and resets the timer. No custom plumbing needed.
- **The dongle can never deep-sleep.** `sys_poweroff()` is gated on
  `!is_usb_power_present()` (`activity.c:78`). Screen off ≠ keyboard dead.
- **Waking the Mac already works.** `CONFIG_USB_DEVICE_REMOTE_WAKEUP=y` in the
  built `.config`, and `usb_hid.c:188-190` calls `usb_wakeup_request()` when a
  report is sent while suspended. The first keypress is consumed by the wake.
- **Wake-on-touch is free.** `PROSPECTOR_TOUCH_ENABLED` selects `ZMK_POINTING`,
  and `activity.c:119-124` registers a *wildcard* `INPUT_CALLBACK_DEFINE(NULL, …)`.
- **Touch needs no new bus.** t-ogura's touch node is on physical P0.04/P0.05;
  on `xiao_ble` that is `i2c1` (`xiao_ble-pinctrl.dtsi:40-45`); carrefinho
  already enables `&i2c1` for the APDS9960 this unit does not have.
- **The CST816S driver is Zephyr in-tree** (`zephyr/drivers/input/input_cst816s.c`),
  not vendored by either module.
- **`SETTINGS`/`NVS`/`INPUT` are already `=y`** in the dongle build, so
  persistence is nearly free.
- **The modules share ancestry.** t-ogura's LICENSE credits "carrefinho
  (Original Prospector Module)". Both MIT.
- **Mac-sleep detection needs a small custom bit.** ZMK collapses
  `USB_DC_SUSPEND` into "still connected" (`usb.c:34-51`), so
  `ZMK_BACKLIGHT_AUTO_OFF_USB` will not see it. Read
  `zmk_usb_get_status() == USB_DC_SUSPEND` instead.

## 5. Rejected, with reasons — do not revisit

- **t-ogura's touch build on a dongle.** Scanner-only. All 15 remote branches
  searched for `PROSPECTOR_MODE_CENTRAL|MODE_DONGLE|CENTRAL_MODE` — zero hits,
  with control greps proving the search ran. `PROSPECTOR_MODE_SCANNER` is a
  standalone bool with no counterpart; its shield conf hard-sets `ZMK_SPLIT=n`.
- **Copying t-ogura's idle feature.** Five Kconfig symbols
  (`PROSPECTOR_SCANNER_IDLE_BRIGHTNESS_MS`, `…_PERCENT`,
  `PROSPECTOR_ADVERTISEMENT_FREQUENCY_DIM`, `…_THRESHOLD_MS`, `…_BRIGHTNESS`)
  are **dead in v2.2.3** — declared, zero C references. Their one working path
  triggers on "no advertisement for 8 minutes", a scanner concept.
- **Copying `set_pwm_brightness()` verbatim.** Two traps: it inverts in C
  (`100 - brightness`) while carrefinho inverts in devicetree (`nordic,invert`,
  `PWM_POLARITY_NORMAL`, `&pwm1` vs t-ogura's `&pwm0`) — double inversion; and
  it clamps to a 1% floor, so it cannot reach the "off" that Q3 requires.
- **Copying t-ogura's persistence as-is.** The save is deferred behind a dirty
  flag flushed only on screen transition (`display_settings.c:196-203`), so
  pulling power on the settings screen loses the setting.
- **Swipe between status layouts.** carrefinho selects layouts at *compile time*
  by Kconfig `choice` + `#include` (`custom_status_screen.c:3-12`,
  `CMakeLists.txt:20-36`). Only one is ever in the binary.
- **Fully blanking instead of dimming.** See Q4.

## 6. Verification gate — PASSED 2026-09-09

Everything above assumes carrefinho's display module **still pairs** once it is
in the build. That combination has never been powered on: the working firmware
(`prospector_dongle_FIX.uf2`) is headless. The module was cleared as the *cause*
of the original pairing failure, but not re-tested with the display running.

Flash `out/dongle_classic.uf2` (or `dongle_field.uf2`), then read
`/dev/cu.usbmodem1204` — the dongle's console — for ~25 s. Pass = all three:

    smp_pairing_complete: got status 0x0      (the bug was status 0x8)
    position state change                     (from both halves)
    zmk_endpoint_send_report                  (HID reaching the Mac)

Plus: the screen lights and shows something, on a unit with no APDS9960.

**If pairing fails, this design is void** and the answer becomes two units
(headless dongle + t-ogura scanner with working touch).

### Result — PASSED

Flashed `builds/2026-09-09/dongle_classic.uf2`. Dongle re-enumerated as
"Corne Dongle" / "ZMK Project" over USB; typing from **both** halves reaches the
Mac; the Prospector renders the Classic status screen. So carrefinho's display
module does not break split pairing once `corne_dongle.conf` is applied — the
last of the dongle-mode unknowns is closed.

**Method note, worth keeping.** The first verification attempt captured 46 bytes
— just `*** Booting Zephyr OS build … ***` — and every grep for
`smp_pairing_complete` / `position state change` / `zmk_endpoint_send_report`
returned 0. That was **not** a failure: `build.sh`'s `dongle` target compiles
*no* logging (`CONFIG_LOG` and `CONFIG_ZMK_USB_LOGGING` both unset), unlike the
`_FIX`/`_DEBUG` images. A search that cannot hit is indistinguishable from a
real absence. Verification came instead from behaviour — typing works, screen
renders — which was what the log lines were only ever a proxy for.
To get real log lines from a dongle build, add
`-DCONFIG_ZMK_USB_LOGGING=y` and read `/dev/cu.usbmodem*` (the port number
changes across a reflash; re-enumerate rather than reusing a stale handle).

## 7. Build order, once §6 passes

1. **Runtime brightness setter** — `led_set_brightness(disp_bl, 0, pct)`, 0-100,
   no inversion in C. Replaces carrefinho's boot-only `SYS_INIT`
   (`brightness.c:150`). *Prerequisite for everything below.*
2. **Persistence** — NVS, saved promptly.
3. **Touch** — `cst816s@15` on `&i2c1`; port `touch_handler.c` +
   `swipe_gesture_event.*`; drop `depends on PROSPECTOR_MODE_SCANNER`.
4. **Brightness UX** — swipe up/down ±10%, transient bar, fades.
5. **Idle dim** — `zmk_activity_state_changed`: IDLE → 1%, ACTIVE → saved level.
   `ZMK_IDLE_TIMEOUT=300000`.
6. **Mac-sleep off** — `zmk_usb_conn_state_changed` +
   `zmk_usb_get_status() == USB_DC_SUSPEND` → 0; resume restores.

## 9. Built, and what is still unverified

Everything in §7 is written, compiles clean, and is committed. **None of it has
run on hardware.** Flash `firmware/builds/2026-09-09/dongle_touch_brightness.uf2`
and check, in this order — it isolates failures fastest:

1. screen lit at 80% → the new owner replaced the stock `SYS_INIT` without both
   racing over the same PWM channel
2. swipe up/down → 10% per swipe
3. idle 5 min → 1%, then type → back to *your* level, not the build default
4. sleep the Mac → backlight fully off
5. set a level, unplug, replug → comes back at your level

**Most likely to be wrong: swipe direction (3 is a coin flip).** The panel is
mounted rotated and the axis mapping was derived from t-ogura's transform for a
*different* rotation. One subtraction in `touch_brightness.c` is marked as the
thing to flip.

**Second most likely: step 4.** A monitor's USB hub may keep the port powered
through host sleep and never deliver `USB_DC_SUSPEND`. If it never fires, fall
back to the two-stage timeout in §8.

## 8. Open risks

- **RAM at ~85%** before any of this. Upstream ZMK grows; this build is already
  tight. Re-measure every step.
- **USB suspend may never arrive.** A monitor hub can keep ports powered through
  host sleep. If `USB_DC_SUSPEND` does not fire, Q3 degrades to keyboard-idle
  only, and the two-stage timeout (dim at 5 min, off at ~30 min) is the fallback.
- **Touch is unproven in dongle-role.** It works on this unit in scanner-role,
  so the panel and pins are known good — but not with carrefinho's display stack.
