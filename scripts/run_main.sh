#!/bin/bash
# Regenerate the shipped top, src/tt_um_dual.v, from the Hardcaml sources
# (plus the two fallback tops in build/, not committed). See bin/main.ml.
cd "$(dirname "$0")/.." || exit 1
eval "$(opam env --switch=hardcaml-env)"
dune exec ./bin/main.exe
