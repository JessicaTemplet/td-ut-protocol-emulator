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

## Repository layout

| Path | Contents |
|---|---|
| `lib/` | The Hardcaml RTL: engines, loader, FIFO, bit pipe, glitch filter, pin wiring (`tt_core.ml`). |
| `bin/main.ml` | Verilog generation: writes `src/tt_um_dual.v` (and the two fallback tops into `build/`, not committed). |
| `src/` | What LibreLane hardens: the generated top `tt_um_dual.v`, `config.json`, the SRAM blackbox stub, the Magic DRC abstract and the macro power scripts. |
| `test/` | The Cyclesim suites and the vector/formal generators. |
| `gl_test/` | The cocotb bench for the shipped Verilog and the gate-level netlist (CI's `gl_test` job). |
| `formal/` | SymbiYosys proof of the FIFO. |
| `tools/tdasm/` | The assembler and program loader. |
| `scripts/` | Regression, Verilog generation, cocotb, formal and partial-flow runners; `maglef/` regenerates the SRAM DRC abstract; `blackbox_macro_gds.py` checks our own logic's DRC with the macro interior removed. |
| `docs/` | `info.md` (the Tiny Tapeout datasheet page) and `design/` (architecture and rationale). |

## What is verified, and how

| Layer | What it proves | Command |
|---|---|---|
| 35 Cyclesim suites (`test/`) | ISA, timer, loader, FIFO backpressure, dual-engine relay, CAPTURE mode, SPI and I2C microcode, the bit pipe and glitch filter, USB low-speed receive and transmit, the profile table, bit-clock recovery, link-health reporting, 10 Mbit Ethernet receive, and the real `tt_um` pin wiring/arbitration. PDK-independent. | `scripts/run_regression.sh` (all) or `scripts/run_test.sh test_<name>` |
| Transmit path and profiles (`test_txpipe`, `test_dual_tx`, `test_usb_transaction`, `test_tt_um_dual_usb_tx`) | The transmit pipe bit for bit against independent USB and CAN reference encoders, and looped back through the receive pipe (600 random packets). On the dual-engine core, with the data chosen at run time by µE1: UART frames, SPI full duplex, USB low-speed ACK and DATA0 on differential D-/D+ at 1.5 Mbit/s (constant bit cell, correct EOP), `CFG_WR` retuning a profile at run time, open-drain output. A SETUP token (CRC5) and a DATA0 packet (CRC16) decoded in one run by switching profiles on the PID, with controls showing neither fixed profile can do both; a USB-to-UART bridge running two profiles at once. | `scripts/run_test.sh test_txpipe`, `scripts/run_test.sh test_dual_tx`, `scripts/run_test.sh test_usb_transaction` |
| Bit-clock recovery (`test_clock_recovery`, `test_usb_rx_recovery`, `test_tt_um_dual_usb_rec`) | A second-order digital PLL places one sample strobe mid-bit for every bit at integer and fractional periods, with sender offset and jitter, and rejects a mid-bit glitch; its measured lock boundary matches a model (7.0% predicted, 6.75% measured for 7-cell runs). The USB receive loop sampling from it receives packets from senders off by -2% to +2% with jitter, where the calibrated timed loop fails beyond 0.5% (the model's 0.52%). | `scripts/run_test.sh test_clock_recovery`, `scripts/run_test.sh test_usb_rx_recovery` |
| Link health (`test_link_health`) | The timing margin in the status word is exact for a displaced edge, never falls as offset or jitter grows, and warns (a µE1 branch on one status bit) at jitter levels where the CRC still passes. For all 80 single-bit errors in a USB data packet, the CRC syndrome µE1 reads matches an independent host model and is unique, so the host can locate the bit. | `scripts/run_test.sh test_link_health` |
| 10 Mbit Ethernet (`test_ethernet`, `test_tt_um_dual_eth`) | Manchester decoding in the clock recovery, a hunt for the start-of-frame delimiter and CRC-32 in the receive pipe, one µE0 instruction per frame. Frames byte for byte at 5 and 7 clocks a bit against independent references (CRC-32 check value, residue, Manchester encoder with jitter); a measured tolerance table (50 MHz: +-0.5 cycle / 10 ns of jitter, 70 MHz: +-0.75 cycle / 10.7 ns, 30 of 30 frames each); late lock, corruption, truncation, dribble bits, lost bytes. | `scripts/run_test.sh test_ethernet` |
| Mutation check (`scripts/run_tx_mutation_test.sh`) | 29 deliberate faults in the transmit pipe, profile table, TX FIFO, µE1's new instructions, the clock recovery, link health, the Manchester decoder, the hunt and the timer are injected one at a time into a scratch copy; the tests catch every one. Includes a wrong CRC polynomial in both directions, which loopback alone cannot see. | `scripts/run_tx_mutation_test.sh` |
| Bit pipe and USB receive (`test_bitpipe`, `test_glitch_filter`, `test_usb_rx`, `test_tt_um_dual_usb`) | NRZI decode, bit un-stuffing, CRC and byte assembly against an independent reference transmitter: the real USB SETUP token and GET_DESCRIPTOR CRC16, 300 random USB packets, 300 random CAN frames (same unit, different configuration), every single-bit line corruption rejected. A four-instruction loop on the dual-engine core receives USB low-speed packets, through the real pins with the configuration loaded over them; a glitch that corrupts a packet is absorbed by the filter; the same program keeps up down to 8 clock cycles per bit. Five deliberate hardware mutations are each caught. | `scripts/run_test.sh test_bitpipe`, `scripts/run_test.sh test_usb_rx` |
| FIFO bounded-exhaustive check (`test_shadow_fifo_exhaustive`) | Every one of the 4^10 push/pop sequences from reset, on the real RTL against a reference model: flags, data order, no loss/duplication, push-when-full and pop-when-empty ignored, plus drain and fill liveness from every reached state (a full FIFO always makes room, an empty one always accepts). The FIFO's control state saturates well inside the bound, so this is complete for this design. About 25 s. | `scripts/run_test.sh test_shadow_fifo_exhaustive` |
| FIFO unbounded formal proof (`formal/`, SymbiYosys + PDR) | The same properties proved for ALL reachable states and ALL input sequences (not just up to a bound) on the Hardcaml-generated RTL, against a reference queue: flag/level agreement, data order with no loss or duplication, dropped push-when-full and pop-when-empty, and pop-only / push-only liveness (a full FIFO always makes room, an empty one always accepts). Six cover statements confirm the proof is not vacuous. Needs [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) (`OSS_CAD=/path`, default `$HOME/oss-cad-suite`). About 30 s. | `scripts/run_formal_fifo.sh` |
| cocotb on the shipped Verilog (`gl_test/`) | The **exact** `tt_um_dual.v` that gets hardened, including the two-per-engine `RM_IHPSG13_1P_512x8` hard SRAM macros (byte-lane wiring, shared address port, write-through timing) using the vendor behavioral model. Loads and runs the SPI master, the open-drain I2C master, USB low-speed receive (good and corrupted packets, from a 1.5%-fast sender through the clock recovery, and a jittery one the timing margin flags while its CRC still passes), 10 Mbit Ethernet receive (good and corrupted frame) and USB low-speed transmit over the real pins. Cyclesim cannot see this path: it simulates a behavioral RAM. | `scripts/run_test.sh test_gl` |
| Same bench, gate level | The hardened netlist behaves like the RTL. | `scripts/run_gl_test.sh gates` after copying the netlist to `gl_test/gate_level_netlist.v` |
| Physical (LibreLane via `tt_tool.py`) | Synthesis, PDN, routing, LVS, Magic DRC, antenna, timing. | see below |
| TT precheck | KLayout `ihp-sg13cmos5l.drc` deck and the pin/boundary checks on the final GDS. | see below |
| Assembler (`tools/tdasm/`) | The SPI, I2C, USB receive (with and without clock recovery), USB transmit and Ethernet receive example sources assemble to exactly the prescale, config bytes and words in `gl_test/*_vectors.json`, `.profile` bytes land where the profile table expects them, and fourteen malformed sources are each refused with the right error. Needs the Axiom compiler, so it is not part of `run_regression.sh`. | `tools/tdasm/test.sh` |

`gl_test/{spi,i2c,usb,usb_tx,usb_rec,eth}_vectors.json` are generated from the Hardcaml microcode
(`scripts/run_gen_vectors.sh`); `scripts/run_regression.sh` fails if the committed
copies, or `src/tt_um_dual.v`, are stale.

## Reproduce

Prerequisites: WSL/Linux, opam (switch `hardcaml-env` with `hardcaml`,
`ppx_hardcaml`, `dune`), `iverilog`, Docker (LibreLane runs containerized),
Python 3.12/3.13 (or `uv`) for cocotb.

```bash
scripts/run_regression.sh    # Cyclesim suites, Verilog generation, cocotb on the Verilog
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
scripts/run_main.sh          # regenerates src/tt_um_dual.v
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
  abstract used only by Magic DRC (`scripts/maglef/`).

## Acknowledgements

* The assembler and program loader (`tools/tdasm`) is written in
  [Axiom](https://github.com/chrispaig3/Axiom), a language by Chris Paige
  ([@chrispaig3](https://github.com/chrispaig3)).
* The RTL is written in [Hardcaml](https://github.com/janestreet/hardcaml) by Jane Street.
* Hardened with the [Tiny Tapeout](https://tinytapeout.com) flow and LibreLane on IHP's open
  [`ihp-sg13cmos5l`](https://github.com/IHP-GmbH/IHP-Open-PDK) PDK.

To cite this project, use GitHub's "Cite this repository" button (from [`CITATION.cff`](CITATION.cff)).

## AI Usage Disclosure

Claude was used to varying degrees throughout this process, primarily for tests, documentation, extended debugging sessions, and to accelerate realignment with the correct target. The assembler and loader (`tools/tdasm`) was written by Claude, in Axiom, and verified against the hardware's own test vectors. The majority of the chip's code is human written, with AI verification and review to prevent compounding failures and facilitate a better outcome than solo execution could have produced.
