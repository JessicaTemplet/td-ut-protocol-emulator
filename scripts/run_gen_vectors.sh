#!/bin/bash
# Regenerate gl_test/{spi,i2c,usb,usb_tx,usb_rec,eth,selftest}_vectors.json from the Hardcaml microcode definitions.
cd "$(dirname "$0")/.." || exit 1
eval "$(opam env --switch=hardcaml-env)"
dune build ./test/gen_vectors.exe || exit 1
./_build/default/test/gen_vectors.exe > gl_test/spi_vectors.json &&
./_build/default/test/gen_vectors.exe i2c > gl_test/i2c_vectors.json &&
./_build/default/test/gen_vectors.exe usb > gl_test/usb_vectors.json &&
./_build/default/test/gen_vectors.exe usb_tx > gl_test/usb_tx_vectors.json &&
./_build/default/test/gen_vectors.exe usb_rec > gl_test/usb_rec_vectors.json &&
./_build/default/test/gen_vectors.exe eth > gl_test/eth_vectors.json &&
./_build/default/test/gen_vectors.exe selftest > gl_test/selftest_vectors.json &&
echo "wrote gl_test/spi_vectors.json gl_test/i2c_vectors.json gl_test/usb_vectors.json gl_test/usb_tx_vectors.json gl_test/usb_rec_vectors.json gl_test/eth_vectors.json gl_test/selftest_vectors.json"
