#!/bin/bash
eval "$(opam env --switch=hardcaml-env)"
cd "$(dirname "$0")"
dune exec ./test/test_tt_um_dual_usb_tx.exe
