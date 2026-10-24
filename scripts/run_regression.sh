#!/bin/bash
# Full regression: every Cyclesim suite, Verilog generation, then the cocotb
# bench on the generated Verilog (hard SRAM macro path). Exits non-zero if
# any step fails.
#
# Each step's full output is kept in regress_logs/<step>.log (cleared at the
# start of every run). A passing step prints its last few lines; a failing one
# prints its last 30 and the path to the full log, so a failure can always be
# read back afterwards.
cd "$(dirname "$0")/.." || exit 1
eval "$(opam env --switch=hardcaml-env)"
LOGS=regress_logs
rm -rf "$LOGS" && mkdir -p "$LOGS"
fail=0

# run_step NAME LINES CMD...: run CMD with its output in $LOGS/NAME.log, show
# the last LINES lines on success, or the failure tail and the log path.
run_step() {
  local name=$1 lines=$2 log="$LOGS/$1.log"
  shift 2
  if "$@" > "$log" 2>&1; then
    [ "$lines" -gt 0 ] && tail -"$lines" "$log"
    return 0
  fi
  echo "FAILED: $name (full log: $log)"
  tail -30 "$log"
  fail=1
  return 1
}

# Every Cyclesim suite (test/test_*.ml), in dependency order: unit blocks
# first, then the engines, then whole-chip pin-level tests.
SUITES="test_main test_timer test_engine test_engine_branch test_engine_pinmux test_loader test_system test_tt_um_system test_shadow_fifo test_shadow_fifo_exhaustive test_bitpipe test_glitch_filter test_engine_push test_protocol_engine test_dual test_dual_loader test_tt_um_dual test_spi_master test_i2c_master test_capture test_dual_capture test_tt_um_dual_spi test_tt_um_dual_i2c test_usb_rx test_tt_um_dual_usb test_txpipe test_dual_tx test_usb_transaction test_tt_um_dual_usb_tx test_clock_recovery test_usb_rx_recovery test_tt_um_dual_usb_rec test_link_health test_ethernet test_tt_um_dual_eth test_halt_guard test_tt_um_dual_selftest"
for s in $SUITES; do
  echo "=== $s ==="
  run_step "$s" 8 dune exec "./test/$s.exe"
done
echo "=== run_tx_mutation_test (each injected TX/profile fault must be caught) ==="
run_step run_tx_mutation_test 3 scripts/run_tx_mutation_test.sh
echo "=== run_main (verilog gen; src/tt_um_dual.v must match the committed copy) ==="
cp src/tt_um_dual.v "$LOGS/tt_um_dual.v.before"
if run_step run_main 8 scripts/run_main.sh; then
  cmp -s src/tt_um_dual.v "$LOGS/tt_um_dual.v.before" \
    || { echo "FAILED: src/tt_um_dual.v was stale (now regenerated; commit it)"; fail=1; }
fi
echo "=== gen_vectors (cocotb vectors must match the committed copy) ==="
for v in spi i2c usb usb_tx usb_rec eth selftest; do cp "gl_test/${v}_vectors.json" "$LOGS/${v}_vectors.before"; done
# A failed generator leaves the committed files untouched, which would compare
# equal, so its exit status is checked before the comparison.
if run_step gen_vectors 0 scripts/run_gen_vectors.sh; then
  for v in spi i2c usb usb_tx usb_rec eth selftest; do
    cmp -s "gl_test/${v}_vectors.json" "$LOGS/${v}_vectors.before" \
      || { echo "FAILED: gl_test/${v}_vectors.json was stale (now regenerated; commit it)"; fail=1; }
  done
fi
echo "=== run_gl_test (cocotb on shipped Verilog + vendor SRAM model) ==="
run_step gl_test 6 scripts/run_gl_test.sh
echo "=== run_formal_fifo (SymbiYosys unbounded proof; needs OSS CAD Suite) ==="
if [ -f "${OSS_CAD:-$HOME/oss-cad-suite}/environment" ]; then
  run_step formal_fifo 0 scripts/run_formal_fifo.sh && grep "DONE" "$LOGS/formal_fifo.log"
else
  echo "SKIPPED: OSS CAD Suite not found (set OSS_CAD); see README"
fi
if [ "$fail" = 0 ]; then echo "REGRESSION: ALL PASS"; else echo "REGRESSION: FAILURES"; fi
exit $fail
