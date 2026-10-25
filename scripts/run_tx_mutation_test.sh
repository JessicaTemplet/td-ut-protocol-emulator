#!/bin/bash
# Mutation check for the transmit path, the profile table, the input
# synchronizer, the halt guard, the loopback self-test and the profile-switch
# alignment. Each entry
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
cd "$(dirname "$0")/.." || exit 1
eval "$(opam env --switch=hardcaml-env)"
# WSL wipes /tmp when it goes idle, so the scratch copy lives under ~
WORK=$(mktemp -d "$HOME/.tx-mutation.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

TESTS="test_txpipe test_dual_tx test_usb_transaction test_clock_recovery test_usb_rx_recovery test_link_health test_ethernet test_dual test_halt_guard test_tt_um_dual_selftest test_profile_switch"

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
  "TX profile pointer ignored#lib/profile_table.ml#; tx_cfg = reg spec (mux tx_id profiles)#; tx_cfg = reg spec (List.hd profiles)"
  "RX profile pointer ignored#lib/profile_table.ml#{ O.rx_cfg = reg spec (mux rx_id profiles)#{ O.rx_cfg = reg spec (List.hd profiles)"
  "PROFILE does not reload the RX CRC#lib/protocol_engine.ml#; rx_crc_init = Profile_table.after_select spec (do_profile &&: pbit 4)#; rx_crc_init = gnd"
  "CFG_WR writes nothing#lib/protocol_engine.ml#; cfg_we = advance &&: is_cfg_wr#; cfg_we = gnd"
  "timer expires on a load cycle (old bug)#lib/timer.ml#main_zero &&: (~:(inputs.load))#main_zero"
  "recovery: phase correction sign flipped#lib/clock_recovery.ml#let v_wrapped = mux2 accept (mux2 neg up down) stay in#let v_wrapped = mux2 accept (mux2 neg down up) stay in"
  "recovery: acceptance window ignored#lib/clock_recovery.ml#((c.rec_window ==:. 0) |: (mag <=: window))#vdd"
  "recovery: period learning sign flipped#lib/clock_recovery.ml#let next = cur +: fstep in#let next = cur -: fstep in"
  "recovery: strobe at the boundary, not mid-bit#lib/clock_recovery.ml#&&: (phw <: half) &&: (wraps_past half)#&&: (v_wrapped <: phw)"
  "PIPE_BIT sync does not wait for the strobe#lib/engine.ml#       |: (bit_sync &&: (~:(rec_.Clock_recovery.O.pending)))#"
  "margin keeps the last edge, not the worst#lib/clock_recovery.ml#let bigger = measured &&: (mag >: worst) in#let bigger = measured in"
  "margin scaled by 32, not 64#lib/clock_recovery.ml#(sll (uresize worst dw) 6)#(sll (uresize worst dw) 5)"
  "status word drops the margin#lib/bitpipe.ml#concat_msb [ vdd; nbytes; i.margin;#concat_msb [ vdd; nbytes; zero 5;"
  "PIPE_STATUS crc_lo reads the high half#lib/engine.ml#      ; select bp.Bitpipe.O.crc 15 0#      ; select bp.Bitpipe.O.crc 31 16"
  "Manchester: boundary edges accepted as mid-bit (P/2, not P/4)#lib/clock_recovery.ml#mux2 c.manchester (mag <: quarter)#mux2 c.manchester (mag <: half)"
  "Manchester: bit sampled at the mid-bit point, not a quarter cell later#lib/clock_recovery.ml#mux2 check line cur) in#mux2 (running &&: manch &&: (phw <: one_cycle) &&: (v_wrapped >=: one_cycle)) line cur) in"
  "Manchester: the frame ends at the first missing edge#lib/clock_recovery.ml#let ending = check &: (~:hit) &: missed in#let ending = check &: (~:hit) in"
  "Manchester: arming snaps on any edge#lib/clock_recovery.ml#let snap = armed &&: edge &&: ((~:manch) |: line) in#let snap = armed &&: edge in"
  "sync-word hunt never starts#lib/bitpipe.ml#mux2 i.ctrl_reset c.sync_en#mux2 i.ctrl_reset gnd"
  "octet CRC ignored (dribble bits fail)#lib/bitpipe.ml#let crc_ok = mux2 c.octet_crc crc_octet crc ==: c.residue in#let crc_ok = crc ==: c.residue in"
  "PIPE_BIT run does not wait for the frame end#lib/engine.ml#       |: (is_run &&: (~:(rec_.Clock_recovery.O.frame_end))))#)"
  "input synchronizer removed#lib/dual.ml#let pins_sync = reg sync_spec (reg sync_spec inputs.pins_in) in#let pins_sync = inputs.pins_in in"
  "halt guard never trips#lib/halt_guard.ml#  (loaded <>:. 0) &&: (uresize pc width >=: loaded)#  gnd"
  "halt guard ignores branches past the program (tracks the first write only)#lib/halt_guard.ml#mux2 (write_enable &&: (addr >=: cur)) (addr +:. 1) cur#mux2 (write_enable &&: (cur ==:. 0)) (addr +:. 1) cur"
  "loopback mask ignored (engines read the pad)#lib/tt_core.ml#  looped_pins <== ((inputs.uio_in &: (~:mask)) |: (own_level &: mask));#  looped_pins <== inputs.uio_in;"
  "masked pad still driven#lib/tt_core.ml#(combined_oe &: (~:mask))#combined_oe"
  "loopback mask never written#lib/profile_table.ml#mux2 (we &&: (addr ==:. loopback_index)) data cur#cur"
  "profile switch: controls act one cycle early (CRC reload on the old profile)#lib/profile_table.ml#let select_latency = 2#let select_latency = 1"
  "profile switch: no interlock (a pipe instruction runs before the switch lands)#lib/profile_table.ml#  go select_latency sel Signal.gnd#  ignore (go select_latency sel Signal.gnd); Signal.gnd"
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
