# Roadmap: TD-µT protocol emulator (Tiny Tapeout, IHP CMOS5L)

Status as of 2026-09-30. Deadline: **2027-01-18**. Target: `tt_um_dual`, 6x4 tiles, IHP `ihp-sg13cmos5l`.

This roadmap is distilled from `docs/design/design_rationale.txt`, the full session-by-session log of how the project got here
(every bug, dead end and measurement). Reasons behind the larger changes of direction are in
`docs/design/design_rationale.txt`; the original architecture is in `docs/design/design_blueprint.txt`.

## Where it stands

A reprogrammable dual-engine protocol emulator (µE0 physical layer, µE1 protocol layer, coupled by a 4-entry
backpressured FIFO, programs loaded byte-serially over the pins). It **clears the real Tiny Tapeout toolchain end to
end**: hardened with `tt_tool.py`, LVS / Magic DRC / route DRC / antenna / power-grid all clean, no timing
violations, TT precheck passes, and the gate-level netlist passes the same testbench as the RTL.

What is **not** built yet is the part of the original pitch that goes beyond UART/SPI/I2C: the hardware
NRZI / bit-stuffing / CRC primitives, the glitch filter, and a high-speed protocol demonstration (items 6 and 7 below).

## The original 10-item plan, and what happened to each

| # | Item | Status | Outcome |
|---|---|---|---|
| 1 | Verify the RAM macro assumption | **Done** | A 512x16 macro exists only as dual-port at 12 tiles (half the chip). Switched to two single-port 512x8 macros per engine. |
| 2 | RAM sharing + dual-engine load path on real pins | **Done** | Separate memory per engine; `dual_loader.ml` (adds `engine_sel`) and `tt_um_dual` wired onto the `tt_um` pins, with a documented per-pin arbitration policy. |
| 3 | Early synthesis pass | **Done, and it changed the project** | Found instruction RAM inferred as ~16,000 flip-flops (118,642 cells, ~5x over budget); fixed with the hard SRAM macro. Also uncovered the wrong-process problem (see below). Final: 1,926 standard cells + 4 macros. |
| 4 | SPI, then I2C microcode | **Done** | Both run in Cyclesim, through the real `tt_um_dual` pins, and on the shipped Verilog + hardened netlist in cocotb. I2C uses the open-drain pin path. |
| 5 | Formal verification of the FIFO | **Done for the FIFO** | SymbiYosys unbounded proof (PDR) of order/flags/drop semantics and pop-/push-liveness, with covers; plus a bounded-exhaustive check of all 4^10 sequences. System-level "no deadlock" across both engines is directed simulation on top of the proved FIFO contract. |
| 6 | Hardware NRZI / bit-stuffing / CRC, then glitch filter | **Not started** | Only the timestamped edge-capture mode (`CAPTURE`) exists, which covers the autobaud / logic-analyzer idea. |
| 7 | Demonstrate one high-speed protocol (USB low-speed or CAN) | **Not started** | Depends on 6. The "dead-band gap" thesis is currently an argument, not a demonstration. |
| 8 | Final synthesis and gate-budget check | **Done for the current design** | 1,926 cells against a ~24k budget, so there is large headroom for item 6. Must be re-run if 6 is added. |
| 9 | Freeze the tape-out target | **Done** | `tt_um_dual`. `tt_um_logic` and `tt_um_system` are still generated as tested fallbacks. |
| 10 | Submission packaging | **Mostly done** | `info.yaml`, docs, pinout, CI workflow, README exist. Remaining: push to GitHub, green CI, submit. |

## Verified so far

- 21 Cyclesim suites (ISA, timer, loader, FIFO, dual-engine relay, CAPTURE, SPI, I2C, real-pin wiring)
- FIFO bounded-exhaustive check and SymbiYosys unbounded proof, each mutation-checked so they can fail
- cocotb on the shipped `tt_um_dual.v` with the vendor SRAM model (SPI and I2C), and on the hardened gate-level netlist
- Physical: LVS 0, Magic DRC 0, route DRC 0, antenna 0, power-grid 0, setup WNS +8.6 ns, hold WNS +0.11 ns,
  worst IR drop 0.074%, 10 max-slew (slow corner), 0 max-cap
- TT precheck (KLayout `ihp-sg13cmos5l` deck, pin, boundary, layer, cell-name checks): pass
- One command re-runs everything: `./run_regression.sh`

## Remaining work, in order

### A. Ship what exists (low risk, do first)
1. Push to a GitHub repo built from the CMOS5L Tiny Tapeout template; let the real CI run the `gds`, `precheck` and
   `gl_test` jobs (local runs used the same steps, but not their infrastructure).
2. Fix anything CI finds (most likely candidates: the gate-level simulator version, see README).
3. Submit through the competition's process.

### B. Hardening the design (optional, each invalidates the current layout and needs a full re-verify)
- **Hardware halt / program-overrun guard.** Instruction SRAM is not cleared, so a program that runs off its last word
  executes arbitrary bits. Today this is a documented software rule (end with a halt).
- **Runtime-data output.** `EMIT_STATE` sends a compile-time bit, so SPI MOSI is a fixed unrolled byte. A real driver
  needs either an output shift-register opcode or per-transfer reprogramming.
- **System-level formal proof** that the two engines cannot deadlock (currently directed simulation).

### C. The differentiators (the original thesis; largest remaining effort)
- Hardware NRZI, bit-stuffing and CRC as generic ALU-style primitives (configurable polynomial / run-length, off for UART/SPI/I2C).
- 3-sample glitch filter with windowed interval validation.
- One high-speed protocol program (USB low-speed or CAN) using those primitives, simulated end to end.
- Optionally the mid-bit phase-tracking counter for Manchester / 10 Mbit Ethernet.
- Re-run item 8 (synthesis, budget, precheck, gate-level) with everything in.

Sequencing: A first so a valid entry exists; then C (it is the novelty claim, and the gate budget has room for it);
B items as time allows. Each step in B and C ends with the full loop: regression, harden, precheck, gate-level bench.

## Reproducing

See `README.md`: prerequisites, `./run_regression.sh`, the hardening commands, and the pinned tool versions
(tt-support-tools branch `ihp-sg13cmos5l`, LibreLane 3.1.0.dev3, PDK via the pinned IHP-Open-PDK commit).
