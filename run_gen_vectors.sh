#!/bin/bash
# Regenerate gl_test/{spi,i2c}_vectors.json from the Hardcaml microcode definitions.
cd "$(dirname "$0")" || exit 1
eval "$(opam env --switch=hardcaml-env)"
dune build ./test/gen_vectors.exe || exit 1
./_build/default/test/gen_vectors.exe > gl_test/spi_vectors.json &&
./_build/default/test/gen_vectors.exe i2c > gl_test/i2c_vectors.json &&
echo "wrote gl_test/spi_vectors.json gl_test/i2c_vectors.json"
