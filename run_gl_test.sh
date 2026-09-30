#!/bin/bash
# Run the cocotb bench on the shipped Verilog.
#   ./run_gl_test.sh          RTL (src/tt_um_dual.v + vendor SRAM model)
#   ./run_gl_test.sh gates    gate level; expects gl_test/gate_level_netlist.v
# Uses its own venv (.venv-cocotb, created on first run) so it never touches
# the LibreLane/hardening environment.
cd "$(dirname "$0")" || exit 1
export PATH="$HOME/.local/bin:$PATH"
if [ ! -x .venv-cocotb/bin/cocotb-config ]; then
  rm -rf .venv-cocotb
  # cocotb 2.0.1 supports Python <= 3.13; use uv to get a 3.12 if the system python is newer
  if command -v uv >/dev/null; then
    uv venv --python 3.12 .venv-cocotb || exit 1
    uv pip install -q --python .venv-cocotb/bin/python -r gl_test/requirements.txt || exit 1
  else
    PY="$(command -v python3.12 || command -v python3.13)"
    [ -n "$PY" ] || { echo "need python 3.12/3.13 or uv (pip install uv)"; exit 1; }
    "$PY" -m venv .venv-cocotb && .venv-cocotb/bin/pip install -q -r gl_test/requirements.txt || exit 1
  fi
fi
source .venv-cocotb/bin/activate
cp tt_um_dual.v src/tt_um_dual.v   # src/ copy is what LibreLane and this bench read
cd gl_test || exit 1
rm -rf sim_build results.xml
# Locally the gate-level model needs the stdcell patch (see gl_test/Makefile);
# set PATCH_STDCELL=no when using Tiny Tapeout's iverilog 13 fork.
if [ "$1" = "gates" ]; then make GATES=yes PATCH_STDCELL="${PATCH_STDCELL:-yes}"; else make; fi
test -f results.xml && ! grep -q "<failure\|<error" results.xml
