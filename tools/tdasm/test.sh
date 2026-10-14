#!/bin/bash
# Builds tdasm and checks it two ways:
#  1. the three examples assemble to exactly the words, prescale and
#     config that the Hardcaml project's gen_vectors.ml produces (the
#     vectors cocotb replays against the shipped Verilog), and
#  2. every file in tests/bad is refused with the expected message.
#
#   ./test.sh [path-to-repo-root]     (default: the repo this folder is in)
#
# Needs the Axiom compiler: set AXIOM, or put `axiom` on PATH.
set -u
cd "$(dirname "$0")" || exit 1
HC=${1:-$(cd ../.. && pwd)}
AXIOM=${AXIOM:-axiom}
fail=0

"$AXIOM" --diagnostic-format=ai build --input tdasm.ax --output tdasm >/dev/null || { echo "FAIL build"; exit 1; }
out=$(mktemp -d)

# --- 1. golden vectors -------------------------------------------------
fields() {  # print prescale, cfg, phys, protocol of a vectors JSON, one per line
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in ("prescale","cfg","phys","protocol"): print(k, v.get(k, []))' "$1"
}
for pair in spi_master:spi i2c_master_read:i2c usb_rx:usb; do
  src=${pair%%:*}; gold=$HC/gl_test/${pair##*:}_vectors.json
  ./tdasm "examples/$src.tds" --quiet --json "$out/$src.json" --load "$out/$src.load" || { echo "FAIL $src: assembler error"; fail=1; continue; }
  if diff <(fields "$gold") <(fields "$out/$src.json") >/dev/null; then
    echo "ok   $src matches $(basename "$gold")"
  else
    echo "FAIL $src differs from $gold:"; diff <(fields "$gold") <(fields "$out/$src.json"); fail=1
  fi
done

# --- 2. refused sources ------------------------------------------------
expect() {  # file, substring the error must contain
  if ./tdasm "tests/bad/$1" --quiet 2>"$out/err"; then
    echo "FAIL $1 was accepted"; fail=1
  elif grep -qF -- "$2" "$out/err"; then
    echo "ok   $1 refused"
  else
    echo "FAIL $1: expected \"$2\", got:"; cat "$out/err"; fail=1
  fi
}
expect pin_range.tds          "pin 9 is out of range 0..7"
expect undefined_label.tds    "undefined label \`nowhere\`"
expect other_engine_label.tds "belongs to the other engine"
expect wrong_engine_op.tds    "unknown uE1 (.protocol) instruction \`shift\`"
expect missing_prescale.tds   "missing .prescale line"
expect cfg_too_long.tds       "more than 9 config bytes"
expect duplicate_label.tds    "label \`a\` defined twice"
expect timeout_range.tds      "timeout 1024 is out of range 0..1023"
expect too_many_operands.tds  "too many operands for \`emit\`"

rm -rf "$out"
if [ $fail = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
