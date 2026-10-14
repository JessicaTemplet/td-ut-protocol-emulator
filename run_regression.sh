#!/bin/bash
# Full regression: every Cyclesim suite, Verilog generation, then the cocotb
# bench on the generated Verilog (hard SRAM macro path). Exits non-zero if
# any step fails.
#
# Each step's full output is kept in regress_logs/<step>.log (cleared at the
# start of every run). A passing step prints its last few lines; a failing one
# prints its last 30 and the path to the full log, so a failure can always be
# read back afterwards.
cd "$(dirname "$0")" || exit 1
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

for s in run_test run_timer_test run_engine_test run_engine_branch_test run_engine_pinmux_test run_loader_test run_system_test run_tt_um_system_test run_shadow_fifo_test run_shadow_fifo_exhaustive_test run_bitpipe_test run_glitch_filter_test run_engine_push_test run_protocol_engine_test run_dual_test run_dual_loader_test run_tt_um_dual_test run_spi_master_test run_i2c_master_test run_capture_test run_dual_capture_test run_tt_um_dual_spi_test run_tt_um_dual_i2c_test run_usb_rx_test run_tt_um_dual_usb_test; do
  echo "=== $s ==="
  run_step "$s" 8 ./"$s".sh
done
echo "=== run_main (verilog gen) ==="
run_step run_main 8 ./run_main.sh
echo "=== gen_vectors (cocotb vectors must match the committed copy) ==="
for v in spi i2c usb; do cp "gl_test/${v}_vectors.json" "$LOGS/${v}_vectors.before"; done
# A failed generator leaves the committed files untouched, which would compare
# equal, so its exit status is checked before the comparison.
if run_step gen_vectors 0 ./run_gen_vectors.sh; then
  for v in spi i2c usb; do
    cmp -s "gl_test/${v}_vectors.json" "$LOGS/${v}_vectors.before" \
      || { echo "FAILED: gl_test/${v}_vectors.json was stale (now regenerated; commit it)"; fail=1; }
  done
fi
echo "=== run_gl_test (cocotb on shipped Verilog + vendor SRAM model) ==="
run_step gl_test 6 ./run_gl_test.sh
echo "=== run_formal_fifo (SymbiYosys unbounded proof; needs OSS CAD Suite) ==="
if [ -f "${OSS_CAD:-$HOME/oss-cad-suite}/environment" ]; then
  run_step formal_fifo 0 ./run_formal_fifo.sh && grep "DONE" "$LOGS/formal_fifo.log"
else
  echo "SKIPPED: OSS CAD Suite not found (set OSS_CAD); see README"
fi
if [ "$fail" = 0 ]; then echo "REGRESSION: ALL PASS"; else echo "REGRESSION: FAILURES"; fi
exit $fail
