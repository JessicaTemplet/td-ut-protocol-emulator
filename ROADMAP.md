# Roadmap: TD-µT protocol emulator (Tiny Tapeout, IHP CMOS5L)

Status as of 2026-10-13. Deadline: **2027-01-18**. Target: `tt_um_dual`, 6x4 tiles, IHP `ihp-sg13cmos5l`.

This file began as the project's working log and was converted into a roadmap. The detailed session-by-session record
(every bug, dead end and measurement) is in this file's git history: `git log -p -- ROADMAP.md`.
Reasons behind the larger changes of direction are in `docs/design/design_rationale.txt`; the original architecture
is in `docs/design/design_blueprint.txt`.

## Where it stands

A reprogrammable dual-engine protocol emulator (µE0 physical layer, µE1 protocol layer, coupled by a 4-entry
backpressured FIFO, programs loaded byte-serially over the pins). It **clears the real Tiny Tapeout toolchain end to
end**: hardened with `tt_tool.py`, LVS / Magic DRC / route DRC / antenna / power-grid all clean, no timing
violations, TT precheck passes, and the gate-level netlist passes the same testbench as the RTL.

The part of the original pitch that goes beyond UART/SPI/I2C is built too: a generic hardware bit pipe (NRZI,
bit-stuffing, CRC), a glitch filter, and a USB low-speed receive demo (items 6 and 7 below). It is receive-only, and the
caveats are listed in `docs/design/design_rationale.txt`, Deviation 7.

## The original 10-item plan, and what happened to each

| # | Item | Status | Outcome |
|---|---|---|---|
| 1 | Verify the RAM macro assumption | **Done** | A 512x16 macro exists only as dual-port at 12 tiles (half the chip). Switched to two single-port 512x8 macros per engine. |
| 2 | RAM sharing + dual-engine load path on real pins | **Done** | Separate memory per engine; `dual_loader.ml` (adds `engine_sel`) and `tt_um_dual` wired onto the `tt_um` pins, with a documented per-pin arbitration policy. |
| 3 | Early synthesis pass | **Done, and it changed the project** | Found instruction RAM inferred as ~16,000 flip-flops (118,642 cells, ~5x over budget); fixed with the hard SRAM macro. Also uncovered the wrong-process problem (see below). Final: 1,926 standard cells + 4 macros. |
| 4 | SPI, then I2C microcode | **Done** | Both run in Cyclesim, through the real `tt_um_dual` pins, and on the shipped Verilog + hardened netlist in cocotb. I2C uses the open-drain pin path. |
| 5 | Formal verification of the FIFO | **Done for the FIFO** | SymbiYosys unbounded proof (PDR) of order/flags/drop semantics and pop-/push-liveness, with covers; plus a bounded-exhaustive check of all 4^10 sequences. System-level "no deadlock" across both engines is directed simulation on top of the proved FIFO contract. |
| 6 | Hardware NRZI / bit-stuffing / CRC, then glitch filter | **Done** | `lib/bitpipe.ml`: one configurable unit, one `PIPE_BIT` instruction per bit (USB low speed and CAN are two configurations); `lib/glitch_filter.ml`: N-consecutive-samples filter. Checked against an independent transmitter, real USB vectors (SETUP token, GET_DESCRIPTOR CRC16), 300 random USB packets, 300 random CAN frames, all single-bit corruptions. Windowed interval validation (the blueprint's second filter stage) is not built. |
| 7 | Demonstrate one high-speed protocol (USB low-speed or CAN) | **Done (USB low speed, receive)** | A four-instruction loop receives USB low-speed packets on the dual-engine core, through the real pins and in cocotb on the shipped Verilog. The same program keeps up down to 8 cycles per bit (6.25 Mbit/s at 50 MHz). No transmit path and no per-edge resync yet. |
| 8 | Final synthesis and gate-budget check | **Done, with the bit pipe** | Re-hardened with the bit pipe in: 3,704 standard cells + 4 macros against a ~24k budget (was 1,926 before it). LVS, Magic DRC, route DRC and antenna 0; setup WNS +6.3 ns, hold WNS +0.11 ns; 14 max-slew and 3 max-cap warnings (slow corner); TT precheck passes on the new GDS. |
| 9 | Freeze the tape-out target | **Done** | `tt_um_dual`. `tt_um_logic` and `tt_um_system` are still generated as tested fallbacks. |
| 10 | Submission packaging | **Mostly done** | `info.yaml`, docs, pinout, CI workflow, README exist. Remaining: push to GitHub, green CI, submit. |

## Verified so far

- 25 Cyclesim suites (ISA, timer, loader, FIFO, dual-engine relay, CAPTURE, SPI, I2C, bit pipe, glitch filter,
  USB low-speed receive, real-pin wiring)
- FIFO bounded-exhaustive check and SymbiYosys unbounded proof, each mutation-checked so they can fail
- cocotb on the shipped `tt_um_dual.v` with the vendor SRAM model (SPI, I2C, USB good and corrupted packet), and on the
  hardened gate-level netlist (4/4)
- Physical, with the bit pipe: LVS 0, Magic DRC 0, route DRC 0, antenna 0, setup WNS +6.3 ns, hold WNS +0.11 ns,
  14 max-slew and 3 max-cap warnings (slow corner)
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

### C. The differentiators (the original thesis)
- Done: hardware NRZI, bit-stuffing and CRC as one generic bit pipe; the N-sample glitch filter; USB low-speed receive
  simulated end to end and on the shipped Verilog; item 8 re-run with everything in.
- Not built: windowed interval validation (the glitch filter's second stage), a transmit path (needs the runtime-data
  output opcode in B), per-edge resync for a real 1.5%-tolerant USB link, CAN as a full program through the pins, and
  the mid-bit phase-tracking counter for Manchester / 10 Mbit Ethernet.

Sequencing: A first so a valid entry exists; then C (it is the novelty claim, and the gate budget has room for it);
B items as time allows. Each step in B and C ends with the full loop: regression, harden, precheck, gate-level bench.

## Reproducing

See `README.md`: prerequisites, `./run_regression.sh`, the hardening commands, and the pinned tool versions
(tt-support-tools branch `ihp-sg13cmos5l`, LibreLane 3.1.0.dev3, PDK via the pinned IHP-Open-PDK commit).
