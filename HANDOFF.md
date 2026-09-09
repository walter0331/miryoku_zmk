# Handoff — Corne dongle mode, 2026-09-09

## State: dongle mode WORKS, with the screen

Verified 2026-09-09 on hardware: the `corne_dongle prospector_adapter` build
(Classic layout) pairs with both halves, types, and renders on the Prospector.
The headless evidence below is what got us here and is kept for the record.

## State: dongle mode WORKS (headless)

Verified on hardware from the dongle's own debug log: both halves connect,
key positions arrive from both, HID reports go to the host.

    peripheral_event_work_callback: Trigger key position state change of type 0
    position_state_changed_listener: 27 bubble / 13 bubble / 26 bubble
    zmk_endpoint_send_report: usage page 0x07

202 key events in 28 s, zero security failures, zero slot churn.

Working firmware: `firmware/2026-09-09-dongle_v1/prospector_dongle_FIX.uf2`
(headless — no display module, so the Prospector screen stays dark).
Halves: `corne_left_peripheral.uf2`, `corne_right.uf2`, both already flashed.

## Root cause (the whole point of this handoff)

**ZMK's default split connection parameters break FRESH split pairing.**

    CONFIG_ZMK_SPLIT_BLE_PREF_LATENCY=30    # peripheral may skip 30 conn events
    CONFIG_ZMK_SPLIT_BLE_PREF_TIMEOUT=400   # supervision timeout = 4.0 s

SMP progresses correctly — pairing req/rsp, public key, confirm (values MATCH),
`bt_smp_dhkey_ready`, `sc_smp_send_dhkey_check` — then 3.7 s of silence and
`smp_pairing_complete: got status 0x8` (0x08 = connection timeout), surfacing in
ZMK as `Security failed … err 9` and `Disconnected (reason 8)`. The central
applies its preferred parameters *while pairing is still in flight*; latency 30
lets the peripheral defer the DHKey reply, and the 4 s supervision timeout kills
the link mid-handshake.

Bonded pairs skip SMP entirely, which is why normal split keyboards never see
this. It only bites a brand-new central — i.e. always a new dongle.

The fix is these two values on the **dongle**:

    -DCONFIG_ZMK_SPLIT_BLE_PREF_LATENCY=0
    -DCONFIG_ZMK_SPLIT_BLE_PREF_TIMEOUT=1000

Wrong theories, for the record — all disproved by evidence, so don't revisit:
stale bonds (full `settings_reset` on all three devices changed nothing);
carrefinho's module (a build with *zero* module code failed identically);
my `corne_dongle` shield (compared against a known-good community dongle, and
it scanned, matched the split UUID and connected fine); `ZMK_SPLIT_ROLE_CENTRAL`
vs the `ZMK_SPLIT_BLE_ROLE_CENTRAL` alias (the latter merely `select`s the
former). `reason 0x08` was always a timeout, never a rejection — that was the
clue that mattered, and it took too long to read properly.

This also explains carrefinho issue #22 ("No pairing between dongle and
halves", multiple reporters, closed with no fix) — not their bug. Worth
reporting upstream to both ZMK and that issue.

## Where the fix lives — RESOLVED

`config/corne_dongle.conf`. Zephyr merges `config/<shield>.conf` for exactly the
builds whose SHIELD list contains that shield, so symbols that exist only under
`ZMK_SPLIT_ROLE_CENTRAL` are safe there. Verified, not assumed: the
`kconfig: files:` list in `../zmk/app/build/<target>/build_info.yml` names it,
and a rebuild with **no** CLI flags comes out `LATENCY=0 / TIMEOUT=1000`.

Two dead ends, for the record — do not retry:

1. **NOT** the shield's `Kconfig.defconfig` — ZMK's own `default 30`/`400` are
   parsed first and win. (`BT_MAX_CONN`/`BT_MAX_PAIRED` there *do* take effect.)
2. **NOT** `config/corne.conf` — merged for the halves too, where these symbols
   do not exist, and an undefined Kconfig symbol is a hard error.

## Remaining work

- [x] **Persist the pairing flags.** `config/corne_dongle.conf`. `build.sh` no
      longer duplicates them on the command line — one source, and the rebuild
      that removed them is what proved the conf works.
- [x] **Rebuild the clean headless dongle.** `out/dongle_bare.uf2` is no longer
      the broken 30/400 image. `out/dongle.uf2`, `out/dongle_classic.uf2` and
      `out/dongle_field.uf2` are also current; all four carry the fix.
- [x] **Flash and verify the screen build. PASSED 2026-09-09.** Classic layout
      flashed to the Prospector: pairs with both halves, typing reaches the Mac,
      screen renders. carrefinho's display module does **not** break pairing
      once `corne_dongle.conf` is applied — the last dongle-mode unknown is
      closed. Detail and method caveat in `docs/dongle-display-design.md` §6.
- [ ] Tag a stable set: `firmware/2026-09-09-dongle_stable_v1/` with dongle +
      both halves + both `settings_reset` images + `MANIFEST.md` (sha256,
      source commits), plus a git tag.
- [ ] Commit: `build.sh`, `config/corne_dongle.conf`, `SETUP.md`, `HANDOFF.md`,
      `docs/dongle-display-design.md`, the `corne_dongle` shield changes.
- [~] **Revert codex's instrumentation.** `../zmk/screenlog.0` deleted and the
      tree is clean. The stash is still there — `git stash drop` was refused by
      the permission classifier, so it needs a human:
      `git -C ../zmk stash drop 'stash@{0}'`. Saved first as
      `../codex-DONGLE-DIAG.patch` (16 lines in `peripheral.c`).
- [ ] Open hardware question, unrelated: the right half has had one dead switch
      (inner right thumb, replaced) and `n` chatter. The 25 ms release debounce
      is in `config/corne.conf`; unverified whether it fixed the chatter. See
      `../case-issue.md` for the aluminium-case ESD pattern.

## Touch and idle on the dongle — designed, not built

Superseded the old "touch is not available today" note. It is available: the
CST816S driver is Zephyr in-tree, t-ogura's ~400-line input layer has zero
scanner coupling and is MIT (their module is a fork of carrefinho's), and the
touch panel sits on a bus carrefinho already enables. What is *not* portable is
t-ogura's settings-screen UI.

Full decision record with evidence, measured RAM budgets, rejected alternatives
and the build order: **`docs/dongle-display-design.md`**.

## Rollback

`firmware/2026-09-08-stable_v1/` — left as central, Prospector as a passive
t-ogura scanner with working touch/swipe. Reverting needs `settings_reset` on all
three devices first, because a half bonded to a dongle will not accept a new
central until its keys are cleared.
