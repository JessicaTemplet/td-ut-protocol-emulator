#!/bin/bash
eval "$(opam env --switch=hardcaml-env)"
cd "$(dirname "$0")"
dune exec ./test/test_shadow_fifo.exe
