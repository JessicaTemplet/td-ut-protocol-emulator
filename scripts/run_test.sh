#!/bin/bash
# Run one Cyclesim suite by name, e.g. `scripts/run_test.sh test_dual`
# (any test/test_*.ml). scripts/run_regression.sh runs all of them.
cd "$(dirname "$0")/.." || exit 1
[ -n "$1" ] || { echo "usage: scripts/run_test.sh <test_name>  (see test/test_*.ml)"; exit 1; }
eval "$(opam env --switch=hardcaml-env)"
dune exec "./test/$1.exe"
