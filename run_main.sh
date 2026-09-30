#!/bin/bash
# Regenerate tt_um_template.v, tt_um_system.v and tt_um_dual.v (the shipped
# top-level Verilog) from the Hardcaml sources.
cd "$(dirname "$0")" || exit 1
eval "$(opam env --switch=hardcaml-env)"
dune exec ./src/main.exe
