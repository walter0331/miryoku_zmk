#!/bin/sh
# Flatten config/corne.keymap into a single self-contained .keymap file with
# readable keycode names, for host tools that parse a keymap FILE.
#
# WHY THIS EXISTS
#
# Our keymap is three #include lines of Miryoku macro headers and nothing else.
# Host-side parsers (lennyitb/KeymapOverlay, and anything like it) look for a
# `compatible = "zmk,keymap"` node in one file and only understand single-line
# object-like #defines. They throw on line one.
#
# The obvious fix -- point them at the build's zephyr/zephyr.dts.pre -- fails
# differently: that file has all ten layers and 42 real bindings, but every
# keycode is expanded to arithmetic, `&kp ((((0x07) << 16) | (0x14))))`, while
# the parsers resolve keycodes by NAME. You get correctly-positioned boxes with
# unreadable labels.
#
# So: run the preprocessor over the SAME headers, but with the dt-bindings
# headers replaced by empty stubs. Miryoku's own macros still expand and the
# ten layers still materialise, while Q stays Q and LGUI stays LGUI, because
# nothing defines them any more.
#
# The output is NOT buildable firmware -- it is a description of the keymap for
# a host tool to read. Never feed it back to ZMK.
#
# Usage:  ./tools/flatten-keymap.sh [output-path]
# Default output: firmware/builds/<date>/corne-flat.keymap

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/config/corne.keymap"
OUT=${1:-"$ROOT/../firmware/builds/$(date +%Y-%m-%d)/corne-flat.keymap"}

[ -f "$SRC" ] || { echo "no such keymap: $SRC" >&2; exit 1; }

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT

# Empty stubs for every <...> header Miryoku includes. Keeping the keycode
# names unexpanded is the entire point; behaviors.dtsi and mouse_keys.dtsi are
# stubbed too because a host parser wants the keymap node, not ZMK's behavior
# definitions.
mkdir -p "$STUB/dt-bindings/zmk" "$STUB/behaviors"
for h in keys bt outputs ext_power rgb pointing; do
    : > "$STUB/dt-bindings/zmk/$h.h"
done
: > "$STUB/behaviors.dtsi"
: > "$STUB/behaviors/mouse_keys.dtsi"

mkdir -p "$(dirname "$OUT")"

# -x assembler-with-cpp: devicetree is not C, and this is the mode Zephyr uses
# for the same job. -P drops the "# 33 file.h" line markers, which parsers that
# strip comments by hand will happily mistake for content.
cc -E -P -x assembler-with-cpp \
   -I "$STUB" \
   -I "$ROOT/config" \
   -I "$ROOT/miryoku" \
   "$SRC" > "$OUT.tmp"

# cpp leaves the whole keymap on a handful of very long lines. Break after each
# binding list and each node close so the result is diffable and human-readable.
sed -e 's/; */;\
/g' -e 's/> *}/>\
}/g' "$OUT.tmp" | sed '/^[[:space:]]*$/d' > "$OUT"
rm -f "$OUT.tmp"

layers=$(grep -c "bindings = <" "$OUT" || true)
echo "  -> $OUT"
echo "     $layers binding lists, $(wc -l < "$OUT" | tr -d ' ') lines"

# A keymap node the parser can find is the whole point; say so if it is missing.
grep -q 'compatible = "zmk,keymap"' "$OUT" || \
  echo "     WARNING: no zmk,keymap node in the output -- a parser will reject it" >&2
