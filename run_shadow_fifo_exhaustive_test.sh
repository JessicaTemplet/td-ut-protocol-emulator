#!/bin/bash
eval "$(opam env --switch=hardcaml-env)"
cd "$(dirname "$0")"
dune build ./test/test_shadow_fifo_exhaustive.exe 2>&1 | head -40 && time dune exec ./test/test_shadow_fifo_exhaustive.exe
