# TD-µT: reprogrammable dual-engine protocol emulator (Tiny Tapeout, IHP CMOS5L)

Entry for Jane Street's open-source protocol emulator ASIC challenge
(Tiny Tapeout, **IHP `ihp-sg13cmos5l`**, 6x4 tiles). Two small microcode
engines (µE0 physical layer, µE1 protocol layer) coupled by a 4-entry FIFO
with hardware backpressure; UART/SPI/I2C are *programs* loaded over a
byte-serial pin protocol, not hardwired blocks. Written in
[Hardcaml](https://github.com/janestreet/hardcaml); the shipped Verilog is
generated. Architecture, design history and the plan are in the documents below.

## Documents

* [`ROADMAP.md`](ROADMAP.md): where the project stands, the original plan item by item, and what remains.
* [`docs/design/design_blueprint.txt`](docs/design/design_blueprint.txt): the original architecture, with as-built revision notes.
* [`docs/design/design_rationale.txt`](docs/design/design_rationale.txt): why it is built this way, and every major change of direction
  (wrong-process retarget, flip-flop RAM, macro power, verification).
* [`tools/tdasm/`](tools/tdasm/): the assembler and program loader, with the instruction set for both engines and example
  programs (SPI master, I2C master read, USB low-speed receive). It writes the load sequence for a host and vectors cocotb can
  replay. Written in [Axiom](https://github.com/chrispaig3/Axiom).
* The detailed build log (every bug and measurement) is the "Build log" section of `ROADMAP.md`.

## What is verified, and how

| Layer | What it proves | Command |
|---|---|---|
| 25 Cyclesim suites (`test/`) | ISA, timer, loader, FIFO backpressure, dual-engine relay, CAPTURE mode, SPI and I2C microcode, the bit pipe and glitch filter, USB low-speed receive, and the real `tt_um` pin wiring/arbitration. PDK-independent. | `./run_regression.sh` (all) or `./run_<name>_test.sh` |
| Bit pipe and USB receive (`test_bitpipe`, `test_glitch_filter`, `test_usb_rx`, `test_tt_um_dual_usb`) | NRZI decode, bit un-stuffing, CRC and byte assembly against an independent reference transmitter: the real USB SETUP token and GET_DESCRIPTOR CRC16, 300 random USB packets, 300 random CAN frames (same unit, different configuration), every single-bit line corruption rejected. A four-instruction loop on the dual-engine core receives USB low-speed packets, through the real pins with the configuration loaded over them; a glitch that corrupts a packet is absorbed by the filter; the same program keeps up down to 8 clock cycles per bit. Five deliberate hardware mutations are each caught. | `./run_bitpipe_test.sh`, `./run_usb_rx_test.sh` |
| FIFO bounded-exhaustive check (`test_shadow_fifo_exhaustive`) | Every one of the 4^10 push/pop sequences from reset, on the real RTL against a reference model: flags, data order, no loss/duplication, push-when-full and pop-when-empty ignored, plus drain and fill liveness from every reached state (a full FIFO always makes room, an empty one always accepts). The FIFO's control state saturates well inside the bound, so this is complete for this design. About 25 s. | `./run_shadow_fifo_exhaustive_test.sh` |
| FIFO unbounded formal proof (`formal/`, SymbiYosys + PDR) | The same properties proved for ALL reachable states and ALL input sequences (not just up to a bound) on the Hardcaml-generated RTL, against a reference queue: flag/level agreement, data order with no loss or duplication, dropped push-when-full and pop-when-empty, and pop-only / push-only liveness (a full FIFO always makes room, an empty one always accepts). Six cover statements confirm the proof is not vacuous. Needs [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) (`OSS_CAD=/path`, default `$HOME/oss-cad-suite`). About 30 s. | `./run_formal_fifo.sh` |
| cocotb on the shipped Verilog (`gl_test/`) | The **exact** `tt_um_dual.v` that gets hardened, including the two-per-engine `RM_IHPSG13_1P_512x8` hard SRAM macros (byte-lane wiring, shared address port, write-through timing) using the vendor behavioral model. Loads and runs the SPI master, the open-drain I2C master and USB low-speed receive (good and corrupted packets) over the real pins. Cyclesim cannot see this path: it simulates a behavioral RAM. | `./run_gl_test.sh` |
| Same bench, gate level | The hardened netlist behaves like the RTL. | `./run_gl_test.sh gates` after copying the netlist to `gl_test/gate_level_netlist.v` |
| Physical (LibreLane via `tt_tool.py`) | Synthesis, PDN, routing, LVS, Magic DRC, antenna, timing. | see below |
| TT precheck | KLayout `ihp-sg13cmos5l.drc` deck and the pin/boundary checks on the final GDS. | see below |
| Assembler (`tools/tdasm/`) | The SPI, I2C and USB example sources assemble to exactly the prescale, config bytes and words in `gl_test/*_vectors.json`, and nine malformed sources are each refused with the right error. Needs the Axiom compiler, so it is not part of `run_regression.sh`. | `tools/tdasm/test.sh` |

`gl_test/{spi,i2c,usb}_vectors.json` are generated from the Hardcaml microcode
(`./run_gen_vectors.sh`); `run_regression.sh` fails if the committed copies are
stale.

## Reproduce

Prerequisites: WSL/Linux, opam (switch `hardcaml-env` with `hardcaml`,
`ppx_hardcaml`, `dune`), `iverilog`, Docker (LibreLane runs containerized),
Python 3.12/3.13 (or `uv`) for cocotb.

```bash
./run_regression.sh          # Cyclesim suites, Verilog generation, cocotb on the Verilog
```

Hardening (about an hour) uses the same commands as the Tiny Tapeout CI
(`TinyTapeout/tt-gds-action@ihp-cmos5l`):

```bash
git clone -b ihp-sg13cmos5l https://github.com/TinyTapeout/tt-support-tools tt
python3 -m venv venv && source venv/bin/activate
pip install librelane==3.1.0.dev3 -r tt/requirements.txt
# PDK: NOT via ciel. Check out IHP-Open-PDK `dev` at the commit pinned in
# tt-gds-action's install_sg13cmos5l.sh into $PDK_ROOT/ihp-sg13cmos5l
export PDK_ROOT=$HOME/ttsetup/pdk_cmos5l PDK=ihp-sg13cmos5l LIBRELANE_TAG=3.1.0.dev3
./run_main.sh && cp tt_um_dual.v src/
python3 tt/tt_tool.py --create-user-config --ihp
python3 tt/tt_tool.py --harden --ihp
python3 tt/tt_tool.py --create-tt-submission --ihp
```

## Things worth knowing

* **Programs must not fall off the end.** Instruction SRAM is not cleared on
  reset, so past the last loaded word the engine fetches arbitrary bits
  (simulation shows X). Cyclesim's zero-filled RAM hides this. End every
  program with a halt: an edge-only `wait_edge ~payload:0` on a pin that never
  toggles (see the end of `spi_master_prog` in `test/gen_vectors.ml`).
* **Two engines, one pin bus.** Where µE0 and µE1 both drive a `uio` pin,
  µE1 wins (`tt_core.ml` header documents the policy).
* **Macro power connectivity is hand-drawn.** The SRAM's power pins sit on
  Metal4, the top layer of this tile's PDN, so `pdngen` cannot reach them.
  `src/pdn_macro_bridge.tcl` adds Metal3 straps and Via3 arrays; the macros
  are placed flipped in one row (`src/config.json`). `src/*.mag` is a trimmed
  abstract used only by Magic DRC (`trim_maglef.py`).

## AI Usage Disclosure

Claude was used to varying degrees throughout this process, primarily for tests, documentation, extended debugging sessions, and to accelerate realignment with the correct target. The assembler and loader (`tools/tdasm`) was written by Claude, in Axiom, and verified against the hardware's own test vectors. The majority of the chip's code is human written, with AI verification and review to prevent compounding failures and facilitate a better outcome than solo execution could have produced.
