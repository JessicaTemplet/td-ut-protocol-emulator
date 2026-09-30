#!/bin/bash
eval "$(opam env --switch=hardcaml-env)"
cd "$(dirname "$0")"
dune exec ./test/test_i2c_master.exe
