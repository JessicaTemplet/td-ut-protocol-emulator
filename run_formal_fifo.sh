#!/bin/bash
# Unbounded formal proof of shadow_fifo with SymbiYosys (PDR/IC3), plus cover
# traces to show the proof is not vacuous.
#   OSS_CAD=/path/to/oss-cad-suite ./run_formal_fifo.sh     (default D:\oss-cad-suite via WSL)
# OSS CAD Suite: https://github.com/YosysHQ/oss-cad-suite-build/releases
cd "$(dirname "$0")" || exit 1
OSS_CAD="${OSS_CAD:-/mnt/d/oss-cad-suite}"
[ -f "$OSS_CAD/environment" ] || { echo "OSS CAD Suite not found at $OSS_CAD (set OSS_CAD)"; exit 1; }
eval "$(opam env --switch=hardcaml-env)"
dune build ./test/gen_formal_fifo.exe || exit 1
./_build/default/test/gen_formal_fifo.exe > formal/shadow_fifo.v || exit 1
source "$OSS_CAD/environment"
cd formal || exit 1
rc=0
sby -f fifo.sby prove || rc=1
sby -f fifo.sby cover || rc=1
exit $rc
