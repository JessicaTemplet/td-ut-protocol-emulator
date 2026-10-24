#!/bin/bash
# Mutation check for the transmit path and the profile table. Each entry
# below injects one deliberate hardware fault into a scratch copy of the
# sources; the transmit and profile tests (test_txpipe, test_dual_tx,
# test_usb_transaction) must FAIL on every one. A mutation that survives is
# a fault the tests cannot see.
#
# "wrong CRC polynomial in BOTH directions" is the case loopback alone
# would miss: the shared profile decode corrupts encode and decode the same
# way, so only the independent reference encoders can catch it.
#
# Mutants build with --profile release: a mutation that leaves a variable
# unused would otherwise fail on the dev profile's warnings-as-errors.
#
# Deliberately not listed: clock_recovery.ml's shifts rounding toward
# minus infinity instead of zero. Its effect on the closed loop (a learned
# period 0.02 cycle low over 3000 bits) is below anything a test can
# separate from jitter, so it would only ever "survive".
set -u
cd "$(dirname "$0")" || exit 1
eval "$(opam env --switch=hardcaml-env)"
# WSL wipes /tmp when it goes idle, so the scratch copy lives under ~
WORK=$(mktemp -d "$HOME/.tx-mutation.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

TESTS="test_txpipe test_dual_tx test_usb_transaction test_clock_recovery test_usb_rx_recovery"

# name # file # text to find (must occur exactly once) # replacement
MUTATIONS=(
  "stuff bit never inserted#lib/txpipe.ml#  let need_byte = (bits_left#  let stuff_due = gnd in\n  let need_byte = (bits_left"
  "CRC never appended#lib/txpipe.ml#(mux2 i.ctrl_crc_append vdd#(mux2 i.ctrl_crc_append gnd"
  "NRZI polarity inverted#lib/txpipe.ml#(mux2 data prev (~:prev))#(mux2 data (~:prev) prev)"
  "CRC sent uncomplemented#lib/txpipe.ml# ^: c.crc_out_invert in# in"
  "MSB/LSB order swapped#lib/txpipe.ml#mux2 c.msb_first (select byte_src 7 7) (select byte_src 0 0)#mux2 c.msb_first (select byte_src 0 0) (select byte_src 7 7)"
  "wrong CRC polynomial in BOTH directions#lib/bitpipe.ml#poly = concat_msb [ word16 9; word16 3 ]#poly = concat_msb [ word16 9; word16 3 ] ^: of_int ~width:32 2"
  "TX FIFO pops twice (drops a byte)#lib/dual.ml#tx_pop <== engine_out.Engine.O.tx_fifo_pop;#tx_pop <== (engine_out.Engine.O.tx_fifo_pop |: reg (Reg_spec.create ~clock:inputs.clk ()) engine_out.Engine.O.tx_fifo_pop);"
  "differential pair not complemented#lib/engine.ml#(mux2 (pair_hit i) (~:(tx.Txpipe.O.line)) cur)#(mux2 (pair_hit i) tx.Txpipe.O.line cur)"
  "TX profile pointer ignored#lib/profile_table.ml#; tx_cfg = mux tx_id profiles#; tx_cfg = List.hd profiles"
  "RX profile pointer ignored#lib/profile_table.ml#{ O.rx_cfg = mux rx_id profiles#{ O.rx_cfg = List.hd profiles"
  "PROFILE does not reload the RX CRC#lib/protocol_engine.ml#; rx_crc_init = reg spec (do_profile &&: pbit 4)#; rx_crc_init = gnd"
  "CFG_WR writes nothing#lib/protocol_engine.ml#; cfg_we = advance &&: is_cfg_wr#; cfg_we = gnd"
  "timer expires on a load cycle (old bug)#lib/timer.ml#main_zero &&: (~:(inputs.load))#main_zero"
  "recovery: phase correction sign flipped#lib/clock_recovery.ml#let v = phw +: one_cycle -: corr in#let v = phw +: one_cycle +: corr in"
  "recovery: acceptance window ignored#lib/clock_recovery.ml#let within = (c.rec_window ==:. 0) |: (mag <=: window) in#let within = vdd in"
  "recovery: period learning sign flipped#lib/clock_recovery.ml#let next = cur +: fstep in#let next = cur -: fstep in"
  "recovery: strobe at the boundary, not mid-bit#lib/clock_recovery.ml#&&: (phw <: half) &&: (v_wrapped >=: half)#&&: (v >=: p)"
  "PIPE_BIT sync does not wait for the strobe#lib/engine.ml#       |: (bit_sync &&: (~:(rec_.Clock_recovery.O.pending))))#)"
)

caught=0
total=${#MUTATIONS[@]}
for m in "${MUTATIONS[@]}"; do
  IFS='#' read -r name file from to <<< "$m"
  rm -rf "$WORK/src" && mkdir -p "$WORK/src"
  cp -r lib test dune-project "$WORK/src/"
  if ! python3 - "$WORK/src/$file" "$from" "$to" <<'PY'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3].replace("\\n", "\n")
s = open(path).read()
if s.count(frm) != 1:
    sys.exit(f"pattern found {s.count(frm)} times")
open(path, "w").write(s.replace(frm, to))
PY
  then
    echo "  ERROR     $name: could not apply"
    continue
  fi
  targets=""
  for t in $TESTS; do targets="$targets ./test/$t.exe"; done
  # shellcheck disable=SC2086
  if ! (cd "$WORK/src" && dune build --profile release $targets >/dev/null 2>&1); then
    echo "  ERROR     $name: mutant does not build"
    continue
  fi
  survived=1
  for t in $TESTS; do
    if ! (cd "$WORK/src" && "./_build/default/test/$t.exe" >/dev/null 2>&1); then
      survived=0
      echo "  caught    $name  (by $t)"
      break
    fi
  done
  if [ "$survived" = 1 ]; then echo "  SURVIVED  $name"; else caught=$((caught + 1)); fi
done
echo "$caught of $total mutations caught"
[ "$caught" = "$total" ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
