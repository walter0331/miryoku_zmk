# Hard-won facts — Corne + Prospector

Cross-repo notes for `~/work/kbrd`: things that cost real time to discover and
are not obvious from any README. Per-project docs live in
`miryoku_zmk/SETUP.md` (runbook) and `miryoku_zmk/docs/dongle-display-design.md`
(the dongle display design). This file is only for the traps.

Everything below was observed on hardware or read out of source. Where something
is inference rather than measurement, it says so.

---

## 1. This specific hardware

- **No APDS9960.** The beekeeb pre-soldered Prospector (XIAO nRF52840 +
  Waveshare 1.69" 240x280 ST7789 + CST816S) ships without the ambient light
  sensor. Firmware that enables it logs `APDS9960: Failed reading chip id` and,
  in carrefinho's module, never drives the backlight at all — the screen looks
  dead. `PROSPECTOR_USE_AMBIENT_LIGHT_SENSOR=n` is mandatory.
- **The touch panel works** and is on **`i2c1`** as far as `xiao_ble` is
  concerned: `i2c1` defaults to P0.04/P0.05 (D4/D5), which is where the panel is
  wired. t-ogura's shield remaps `i2c0` to those same physical pins; carrefinho
  enables `i2c1` already, so a `cst816s@15` node there needs no pinctrl of its
  own. IRQ D0 / RST D1, no collision with the display (D3/D7/D9) or the absent
  APDS9960 (D2).
- **Screen-vertical is touch X.** The panel is mounted rotated (logical display
  280x240 landscape). Measured over a real capture: during vertical swipes
  `INPUT_ABS_X` spans the full 0-239 while `ABS_Y` spans 167. **Raw X increases
  as the finger moves up the screen.**
- Right half has a history: one dead switch (inner right thumb, replaced) and
  `n` chatter, hence `KSCAN_DEBOUNCE_RELEASE_MS=25`. Aluminium case has a known
  ESD failure mode — see `case-issue.md`.

## 2. ZMK / Zephyr traps

### Split pairing

**ZMK's split defaults break FRESH pairing.** `ZMK_SPLIT_BLE_PREF_LATENCY=30`
and `_TIMEOUT=400` (4 s) let the peripheral defer its DHKey reply while the
supervision timeout tears the link down mid-handshake:
`smp_pairing_complete: got status 0x8`, surfacing as `Security failed err 9`.
Bonded pairs skip SMP, so only a brand-new central hits it — and a dongle is
always a brand-new central. Fix: `LATENCY=0`, `TIMEOUT=1000` on the dongle.
This also explains carrefinho issue #22, closed with no fix.

### Where Kconfig actually comes from

- `config/<shield>.conf` **is** merged, for exactly the builds whose SHIELD list
  contains that shield. This is the right home for symbols that only exist under
  `ZMK_SPLIT_ROLE_CENTRAL`.
- `config/corne.conf` is merged for **every** `corne*` shield including the
  halves, where such symbols do not exist — and an undefined Kconfig symbol is a
  hard error, not a warning.
- A shield's own `Kconfig.defconfig` **cannot** override a ZMK `default`: ZMK's
  is parsed first and wins. `BT_MAX_CONN`/`BT_MAX_PAIRED` there do take effect;
  `ZMK_SPLIT_BLE_PREF_*` silently do not.
- **Ground truth for "what did this build actually merge" is
  `zmk/app/build/<target>/build_info.yml`** — its `kconfig: files:` list. Read
  that instead of reasoning about merge rules.

### Activity, sleep, and the display

- A keypress on a BLE **peripheral** does reset the **central's** activity timer:
  `split/central.c:41-47` raises `zmk_position_state_changed`, and
  `activity.c:110` subscribes. No custom plumbing needed to wake a dongle screen
  on typing.
- **A USB-powered dongle can never deep-sleep.** `sys_poweroff()` is gated on
  `!is_usb_power_present()` (`activity.c:78`). Dimming or blanking the screen has
  zero effect on whether the keyboard responds.
- `CONFIG_ZMK_DISPLAY_BLANK_ON_IDLE` only sends the panel `DISP_OFF`. It touches
  the backlight solely via an optional `zmk,display-led` chosen node, and with
  `led_on`/`led_off` — binary, no dimming. On the Prospector the backlight is a
  raw `pwm-leds` node, so blanking alone leaves **a lit blank rectangle**.
- **`zmk_usb_get_conn_state()` collapses `USB_DC_SUSPEND` into "still
  connected"**, so `ZMK_BACKLIGHT_AUTO_OFF_USB` cannot see host sleep. Use the
  raw `zmk_usb_get_status() == USB_DC_SUSPEND` instead (`usb.c:34-51`).
- Waking the Mac already works: `CONFIG_USB_DEVICE_REMOTE_WAKEUP=y` and
  `usb_hid.c:188-190` calls `usb_wakeup_request()`. The first keypress after
  suspend is consumed by the wake.

### CST816S touch

- **`BTN_TOUCH=1` repeats on EVERY contact sample** while the finger is down —
  measured 1240 presses against 181 releases. Latch a swipe's start position on
  the not-touching -> touching **transition** only. Latching per-sample makes
  `start == current` at release and no swipe can ever exceed a threshold. This
  is the single bug that made swipes silently do nothing.
- **Zephyr's in-tree driver never emits `INPUT_KEY_UP`/`DOWN`.** It reports
  hardware gestures as `INPUT_EV_DEVICE`, and only when
  `CONFIG_INPUT_CST816S_EV_DEVICE=y`. Code ported from t-ogura that switches on
  `INPUT_KEY_*` is dead.
- X and Y arrive as **separate input events**; accumulate them, then act on
  `BTN_TOUCH`.
- **Backlight inversion lives in different layers in the two modules.**
  carrefinho inverts in devicetree (`nordic,invert` on `pwm1_default`, `&pwm1`);
  t-ogura inverts in C (`100 - brightness`, `&pwm0`). Porting a setter across
  double-inverts it. t-ogura's setter also clamps to a 1% floor, so it can never
  fully blank.

### Logging

- **Never set `CONFIG_LOG_MODE_IMMEDIATE` with a USB CDC console.** The first log
  write blocks on an endpoint USB has not configured yet; the device never
  enumerates and the keyboard is dead until reflashed. ZMK's `ZMK_USB_LOGGING`
  uses deferred mode deliberately.
- **Log at `SYS_INIT(APPLICATION)` and nobody will ever read it** — the USB
  backend is not attached yet, so the message is dropped. Report boot-time status
  from a delayed work item a few seconds in.
- **Per-event logging over USB CDC changes the behaviour it measures.** It backs
  up Zephyr's input queue until reports are discarded
  (`input_report: Timeout discarded. No blocking in syswq`). Touch feels worse on
  a logging build than on the real one. Use logs to find bugs, never to judge feel.

## 3. Build and toolchain

- **Cap ninja parallelism.** Unbounded, it spawns one gcc per host CPU inside the
  Docker VM; on this 18 GB machine (routinely deep in swap) that killed Docker
  Desktop mid-build twice, at different percentages. `JOBS=4` in `build.sh`.
  A build that dies at a random point is a memory problem, not a code problem.
- Board strings on ZMK main are `nice_nano/nrf52840/zmk` and
  `xiao_ble/nrf52840/zmk`. `nice_nano_v2` no longer resolves.
- Dependencies are cloned **by branch, not pinned**, so builds are reproducible
  today and drift when upstream moves. Each `firmware/<date>-*/MANIFEST.md`
  records the SHAs its images came from.
- A terminal `cp` to a mounted bootloader volume is blocked by macOS TCC. Drag in
  Finder.
- Keep **build output** (`firmware/builds/<date>/`) apart from **curated
  snapshots** (`firmware/<date>-<name>_v<n>/`, which carry a MANIFEST of
  sha256s). Dropping a file into a manifested folder makes the manifest lie.

## 4. Method — how the time was actually lost

Almost none of the lost time was spent on the bug. It went on **checks that
returned plausible answers to questions I had not asked.** Concrete instances
from one session:

- A 30-second serial capture returned 46 bytes and every grep for pairing
  evidence returned 0. Read as "pairing failed". Actually the build had **no
  logging compiled in** — a search that cannot hit is indistinguishable from a
  real absence.
- `grep -c "brightness"` returned 3901, apparently 3901 brightness changes.
  It was matching the **log module name** `prospector_brightness` on every debug
  line. The tell: it exactly equalled the count of a different pattern.
- A wait loop `until ! pgrep -f "[b]uild.sh"` matched **its own wrapper shell**,
  whose command line contained the string. It reported "still building" for
  minutes while nothing was building. `docker ps` showing no container was the
  contradiction that should have been checked immediately.
- A "is the new image built yet" check compared a file mtime against a 3-minute
  window and was satisfied by the **previous** build's output.
- Missed swipes were attributed to a 400 ms cooldown. They were dropped input
  reports caused by debug logging. Both were plausible; only one was measured.

Rules that fall out, in rough order of value:

1. **Separate "did the tool run" from "did it find anything".** A zero result
   and a broken query look identical.
2. **Before trusting a negative, name the mechanism that would have produced a
   hit** — and confirm that mechanism exists. "No log lines" requires logging to
   be compiled in.
3. **Cross-check a suspicious result against an independent signal.** Two counts
   coming out exactly equal, or a process that is "running" with no container.
4. **Verify a port's assumptions about its dependencies, not just its licence
   and its coupling.** t-ogura's handler was clean, MIT and scanner-free — and
   built on driver behaviour that does not exist in Zephyr's in-tree version.
5. **Instrumentation is code and gets the same scrutiny.** Three defects here
   were in the diagnostic, not the subject: no readiness check, a boot deadlock,
   and an observer effect. Two flash cycles went to broken instruments.
6. **When the same action fails twice, re-validate the premise** instead of
   retrying. Docker dying twice was a memory problem; no amount of rebuilding
   would have fixed it.
7. **Behaviour beats logs for pass/fail.** "Can you type, is the screen lit"
   settled in one message what two logging builds could not.
