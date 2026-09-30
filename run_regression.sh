#!/bin/bash
# Full regression: every Cyclesim suite, Verilog generation, then the cocotb
# bench on the generated Verilog (hard SRAM macro path). Exits non-zero if
# any step fails.
cd "$(dirname "$0")" || exit 1
eval "$(opam env --switch=hardcaml-env)"
fail=0
for s in run_test run_timer_test run_engine_test run_engine_branch_test run_engine_pinmux_test run_loader_test run_system_test run_tt_um_system_test run_shadow_fifo_test run_shadow_fifo_exhaustive_test run_engine_push_test run_protocol_engine_test run_dual_test run_dual_loader_test run_tt_um_dual_test run_spi_master_test run_i2c_master_test run_capture_test run_dual_capture_test run_tt_um_dual_spi_test run_tt_um_dual_i2c_test; do
  echo "=== $s ==="
  ./"$s".sh > /tmp/regress_step.log 2>&1 || { echo "FAILED: $s"; fail=1; }
  tail -8 /tmp/regress_step.log
done
echo "=== run_main (verilog gen) ==="
./run_main.sh > /tmp/regress_step.log 2>&1 || { echo "FAILED: run_main"; fail=1; }
tail -8 /tmp/regress_step.log
echo "=== gen_vectors (cocotb vectors must match the committed copy) ==="
cp gl_test/spi_vectors.json /tmp/spi_vectors.before
cp gl_test/i2c_vectors.json /tmp/i2c_vectors.before
./run_gen_vectors.sh > /dev/null 2>&1
cmp -s gl_test/spi_vectors.json /tmp/spi_vectors.before && cmp -s gl_test/i2c_vectors.json /tmp/i2c_vectors.before \
  || { echo "FAILED: gl_test/*_vectors.json was stale (now regenerated; commit them)"; fail=1; }
echo "=== run_gl_test (cocotb on shipped Verilog + vendor SRAM model) ==="
./run_gl_test.sh > /tmp/regress_step.log 2>&1 || { echo "FAILED: gl_test"; fail=1; }
tail -6 /tmp/regress_step.log
echo "=== run_formal_fifo (SymbiYosys unbounded proof; needs OSS CAD Suite) ==="
if [ -f "${OSS_CAD:-/mnt/d/oss-cad-suite}/environment" ]; then
  ./run_formal_fifo.sh > /tmp/regress_step.log 2>&1 || { echo "FAILED: formal fifo"; fail=1; }
  grep "DONE" /tmp/regress_step.log
else
  echo "SKIPPED: OSS CAD Suite not found (set OSS_CAD); see README"
fi
if [ "$fail" = 0 ]; then echo "REGRESSION: ALL PASS"; else echo "REGRESSION: FAILURES"; fi
exit $fail
