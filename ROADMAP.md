# Roadmap: TD-µT protocol emulator (Tiny Tapeout, IHP CMOS5L)

Status as of 2026-10-20. Deadline: **2027-01-18**. Target: `tt_um_dual`, 6x4 tiles, IHP `ihp-sg13cmos5l`.

The step-by-step record of the build (every bug, dead end and measurement) is the **Build log** section at the end
of this file. Reasons behind the larger changes of direction are in `docs/design/design_rationale.txt`; the original
architecture is in `docs/design/design_blueprint.txt`.

## Where it stands

A reprogrammable dual-engine protocol emulator (µE0 physical layer, µE1 protocol layer, coupled by a 4-entry
backpressured FIFO, programs loaded byte-serially over the pins). It **clears the real Tiny Tapeout toolchain end to
end**: hardened with `tt_tool.py`, LVS / Magic DRC / route DRC / antenna / power-grid all clean, no timing
violations, TT precheck passes, and the gate-level netlist passes the same testbench as the RTL.

The part of the original pitch that goes beyond UART/SPI/I2C is built too: a generic hardware bit pipe (NRZI,
bit-stuffing, CRC), a glitch filter, and a USB low-speed receive demo (items 6 and 7 below); caveats in
`docs/design/design_rationale.txt`, Deviation 7.

**In progress (not yet hardened):** the next features from `design_note_tx_clock_recovery.md`, built together so the
chip is re-hardened once. Done so far: a transmit path that mirrors the bit pipe, with data decided at run time by µE1,
a runtime profile table (separate receive and transmit profiles, switched and rewritten while running), and bit-clock
recovery (a second-order digital PLL the receive loop samples from), and link-health reporting (timing margin in the
status word, CRC syndrome, learned period), and 10 Mbit Ethernet receive (Manchester decoding, delimiter hunt and CRC-32
in hardware, one µE0 instruction per frame). Next: the harden, attempting 70 MHz (50 MHz fallback). See Deviations 8
to 11 and Build log sections 9 to 12. The last hardened numbers below are from before this work.

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
| 8 | Final synthesis and gate-budget check | **Done, with the bit pipe** | Re-hardened with the bit pipe in, then electrical-rule cleanup: 4,018 standard cells + 4 macros against a ~24k budget (1,926 before the bit pipe). LVS, Magic DRC, route DRC and antenna 0; setup WNS +7.3 ns, hold WNS +0.057 ns; 0 max-slew, max-cap and max-fanout at every corner; TT precheck passes on the new GDS. |
| 9 | Freeze the tape-out target | **Done** | `tt_um_dual`. `tt_um_logic` and `tt_um_system` are still generated as tested fallbacks. |
| 10 | Submission packaging | **Mostly done** | `info.yaml`, docs, pinout, CI workflow, README exist. Pushed to GitHub; CI green on `a7efa34` (gds, precheck, gl_test, viewer). Remaining: submit. |

## Verified so far

- 25 Cyclesim suites (ISA, timer, loader, FIFO, dual-engine relay, CAPTURE, SPI, I2C, bit pipe, glitch filter,
  USB low-speed receive, real-pin wiring)
- FIFO bounded-exhaustive check and SymbiYosys unbounded proof, each mutation-checked so they can fail
- cocotb on the shipped `tt_um_dual.v` with the vendor SRAM model (SPI, I2C, USB good and corrupted packet), and on the
  hardened gate-level netlist (4/4)
- Physical, with the bit pipe: LVS 0, Magic DRC 0, route DRC 0, antenna 0, setup WNS +7.3 ns, hold WNS +0.057 ns,
  0 max-slew, max-cap and max-fanout warnings at every corner
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
- ~~**Runtime-data output.**~~ Done (not yet hardened): `TX_PUSH`/`TX_ECHO` from µE1 and `EMIT_TX` on µE0, through the
  transmit pipe. See Build log section 9.
- **System-level formal proof** that the two engines cannot deadlock (currently directed simulation).

### C. The differentiators (the original thesis)
- Done: hardware NRZI, bit-stuffing and CRC as one generic bit pipe; the N-sample glitch filter; USB low-speed receive
  simulated end to end and on the shipped Verilog; item 8 re-run with everything in.
- Done since (not yet hardened): the transmit path, the runtime profile table, and USB transactions mixing CRC5 tokens
  and CRC16 data in one run.
- Done since (not yet hardened): per-edge resync for a real 1.5%-tolerant USB link (bit-clock recovery).
- Done since (not yet hardened): Manchester decoding and 10 Mbit Ethernet receive.
- Not built: windowed interval validation (the glitch filter's second stage), CAN as a full program through the pins,
  and Ethernet transmit.

Sequencing: A first so a valid entry exists; then C (it is the novelty claim, and the gate budget has room for it);
B items as time allows. Each step in B and C ends with the full loop: regression, harden, precheck, gate-level bench.

## Reproducing

See `README.md`: prerequisites, `./run_regression.sh`, the hardening commands, and the pinned tool versions
(tt-support-tools branch `ihp-sg13cmos5l`, LibreLane 3.1.0.dev3, PDK via the pinned IHP-Open-PDK commit).


---

# Build log

The working record of the build, oldest first, kept to build facts only: what was made, what broke, how each problem
was diagnosed, and what was measured. Tool paths are relative to the
project root or `~`.

## 1. Single-engine foundation (RTL and Cyclesim)

Method that held for the whole project: test every increment before building on it. Almost every bug below was caught
this way, cheaply, before it compounded.

| Module | What it is |
|---|---|
| `lib/tt_core.ml` | Hardwired UART RX core (`tt_um_logic`, the original proof of concept), plus the wrappers that put the programmable cores on real `tt_um` pins |
| `lib/timer.ml` | Prescaled wait timer |
| `lib/engine.ml` | The ISA: `WAIT_EDGE`, `EMIT_STATE`, `SHIFT_IO`, `BRANCH_COND`; 16-bit word `[15:14] opcode / [13:11] pin_sel / [10] mode / [9:0] payload` |
| `lib/loader.ml` | Byte-serial program loader (no address bus) |
| `lib/system.ml` | Loader + engine glue |

**Bugs found and fixed in the original core and engine**
1. `tt_core.ml`: the half-bit state left after one cycle instead of waiting for the counter, so the first UART sample
   fired at cycle 51 instead of ~75. Fixed by gating the transition on `counter == 0`.
2. `tt_core.ml`: reloading on `counter == 0` added a spurious dwell cycle each period (51-cycle spacing, not 50).
   Redesigned so the reload happens on the same cycle the counter expires. This became the pattern for `timer.ml`.
3. `tt_core.ml`: `falling` edge detection was not gated by "idle", so a legitimate mid-frame 1-to-0 transition was
   read as a new start bit. Fixed with `start_edge = falling && ~running`.
4. `engine.ml`: the same bug class at ISA level. Fixed-duration waits reused the edge-match condition, so a data
   transition advanced the PC early. Now `payload == 0` means edge-only wait and nonzero means timer-only wait, never both.
5. `engine.ml`, swapping the compile-time ROM for a real RAM: `load` (which arms the timer with the current
   instruction's payload) was a blind register one cycle after `advance`. Against a registered-read RAM it fired mid-bubble
   and armed the timer with the previous instruction's stale payload, so the first timed wait hung forever. A first fix
   (an explicit bubble-stall gate) worked but added two extra cycles of dispatch overhead, enough to walk the sample
   point into the wrong bit by the end of the frame (silent corruption, caught by the bit-comparison, not the spacing
   check). Real fix: feed the RAM read address with `next_pc` (the PC after this cycle's advance), so `instr` and `pc`
   stay in lockstep with zero bubble.

**Measured, not a bug:** the engine reproduces the hardwired UART RX functionally with a fixed +2 raw-cycle dispatch
overhead per `WAIT`-to-`SHIFT` pair. It vanishes once the prescaler is above ~2, so it only matters at full clock rate.
An assembler must compensate (`payload = desired_cycles - overhead`).

**Range problem and `timer.ml`:** the 10-bit payload cannot hold a 9600-baud bit period at 50 MHz (5208 cycles vs a
1023 maximum). A programmable prescaler, set once, makes the payload count scaled ticks; verified at 9600 baud
(prescale 5, payload 868) with zero drift.

**Loader protocol** (while `run=0`): `ui_in[7:0]` = data, `uio_in[0]` = strobe, `[1]` = byte_sel (0 low byte, 1 high
byte), `[2]` = go. The write address auto-increments from 0 on reset; the high-byte strobe commits the word. `go` latches
`run` until reset and everything after is ignored, so the pins are free for the program to reuse. Strobe and go pass
through a 2-FF synchronizer. A running 8-bit XOR checksum is exposed so the host can verify the load before `go`. The
first strobe after reset loads the prescale byte (costs no pins, makes the timing base programmable).

**EMIT_STATE / BRANCH_COND:** `EMIT_STATE` drives a held output register. `BRANCH_COND` branches on a pin *level*
(not an edge, since `WAIT_EDGE` owns edges). Fixed-count loops need no hardware counter, they are unrolled. No bugs on
this slice, credited to the zero-bubble fetch discipline being solid by then.

**Pin mux** (1-of-8 inputs, 8 sticky output registers): adding it reintroduced the false-edge bug class, because the
edge detector's previous-sample register still held the old pin's level for the first cycle after `pin_sel` changed.
Fixed with a `pin_sel_stable` guard (an edge counts only once `pin_sel` held for a full prior cycle). The guard test
was checked to have teeth: deleting the guard made it fail with a visibly wrong PC trace.

**Pins moved onto `uio` for true bidirectional I/O:** I2C's open-drain SDA/SCL needs a pin that can be released.
`EMIT_STATE` payload bit 0 became a release flag (0 drives, 1 tri-states; backward compatible). `uio_out`/`uio_oe`
carry the engine's outputs once `run=1` and are forced to 0 while loading, so the chip never contends with the host
on the loader pads. `uo_out` shows the checksum before run and mirrors `pins_out` after.

**`tt_um_system` missing `ena` port:** the first real `tt_tool.py --create-user-config` failed with "port 'ena'
missing". No Cyclesim test could catch it. Added `ena` to `Tt_core.I.t`, deliberately unused.

## 2. Dual-engine architecture

New modules, built bottom-up: `shadow_fifo.ml`, `protocol_engine.ml` (µE1), `dual.ml`, `dual_loader.ml`, and
`tt_um_dual` in `tt_core.ml`. The single-engine path stayed alongside as a tested fallback.

- **FIFO:** 4 entries, push/pop with simultaneous push+pop. Named `Shadow_fifo`, not `Fifo`, because Hardcaml ships a
  `Fifo` and `tt_core.ml`'s `open Hardcaml` silently shadowed a sibling module of that name.
- **µE0 producer half:** `SHIFT_IO` payload bit 0 is a push flag. A pushing `SHIFT_IO` stalls the fetch stage when
  the FIFO is full (the hardware form of backpressure); a non-pushing one never stalls, so mid-frame bit timing is
  never at backpressure's mercy. Bug: `byte_ready`/`byte_data` were first raw combinational reads of `instr`, which is
  one RAM-latency ahead of `pc`. Made them registered so they read pc-aligned like `pins_out`.
- **µE1 ISA** (separate from µE0's): `FIFO_POP` (stalls until non-empty), `EMIT_STATE`, `BRANCH_COND_WORD` (branch on
  a bit of the last popped word), `BRANCH_PIN` (raw pin bypass).
- **`dual.ml`:** the three-way circular dependency (µE0 needs FIFO `full`, the FIFO needs µE0 push and µE1 pop, µE1 needs
  FIFO data) is closed with wire forward references. `run` and `protocol_run` are separate inputs, which is load-bearing
  for testing: µE1 pops in 1 cycle and µE0 takes 8 to assemble a byte, so with lockstep enables the FIFO never fills.
- **`dual_loader.ml`:** adds `engine_sel` (0 = µE0, 1 = µE1) and two write ports and address counters; one checksum
  over both engines; one `run` latch driving both. Tested with interleaved phys/protocol words.
- **`tt_um_dual` pin arbitration** (one 8-bit `uio` bus, two engines each with their own `pins_out`/`pins_oe`):
  per pin, OR the output enables, and where both claim a pin the **protocol engine's value wins**. This is a documented
  assumption, not a proven scheme. Neither SPI nor I2C contends a pin, so it is only exercised by a synthetic test.
- `test_dual.ml` proves backpressure (5th push stalls and holds with the FIFO full) and that order is preserved
  once µE1 drains. Directed simulation only, which the formal work in section 6 later backed for the FIFO.

## 3. RAM macro: the findings that reshaped the project

**Macro assumption was wrong.** The blueprint budgeted one shared 512x16 macro (~6,000 gates). The catalog offers a
512x16 only as dual-port at 12 tiles (half the 24-tile chip). Load and run never overlap in this design, so
dual-port was never needed. Decision: two single-port 512x8 macros per engine (four total), separate memories per
engine, which is what `engine.ml` and `protocol_engine.ml` already did.

**First real synthesis (LibreLane) result: 118,642 cells vs a ~24,000 budget (~5x over).** 16,076 sequential cells,
within a few percent of 2 x 512 x 16 = 16,384, i.e. both instruction memories built as flip-flops. Yosys's log showed
`memory_map` creating individual registers for both RAMs; nothing told it to use a hard macro. The run took ~3 hours,
and 29,053 repair buffers, 16,097 hold buffers and 137,032 fill cells were fallout from the oversized design. Decision:
use the real SRAM macro, not the flip-flop fallback. The 118,642-cell run is kept as the "before" baseline.

**Macro integration** (`RM_IHPSG13_1P_512x8_c3_bm_bist`, already present in the installed PDK):
- Datasheet contract: one shared address port; `A_MEN=1, A_REN=1, A_WEN=0` is a read and `A_WEN=1` is write-through,
  so tying `A_REN` high and driving `A_WEN` with `write_enable` reproduces `Write_before_read`. `A_BM` all ones,
  `A_DLY` tied to 1 (mandatory), BIST pins tied off.
- LibreLane wants a real Verilog module instantiation plus `MACROS`, `EXTRA_VERILOG_MODELS` and `PDN_MACRO_CONNECTIONS`,
  not a synthesis mapping flag. `lib/sram.ml` instantiates two macros (low and high byte) with Hardcaml `Instantiation`.
- **Cyclesim cannot simulate the macro.** `Instantiation` is always scheduled as a combinational primitive, so
  the `next_pc` feedback through the macro reads as an unbroken zero-delay loop ("Combinational loop") and broke 12 of
  14 suites. Fix: every layer keeps `create` (behavioral `Ram.create`, what every test uses) and gains `create_asic`
  (`Sram.create_512x16`, used only by `src/main.ml` to generate the shipped Verilog). Both wrap one shared
  `create_generic`. This leaves a verification gap, closed later by the cocotb bench on the shipped Verilog (section 6).
- Yosys cannot parse the vendor model's SDF-style `$setuphold` timing checks. Fix: a hand-written `(* blackbox *)` stub
  with only the port list (`src/RM_IHPSG13_1P_512x8_c3_bm_bist_blackbox.v`), standard for synthesis.

## 4. Physical design on the (wrong) process, then retargeting

Worked on `ihp-sg13g2` first. Lessons that carried over:
- `FP_SIZING` defaults to `relative`, which ignores `DIE_AREA`. The floorplan DEF read 508.8 x 527.5 instead of
  1289.28 x 710.64 µm. Fix: `FP_SIZING: absolute`. The earlier belief that the die "shrinks later" was wrong, caused by
  reading the requested value in `config.json` instead of the step's DEF output.
- Default macro PDN template never reached the macro's Metal4 pins (PDN-0232, "grid does not contain any shapes"),
  fixed on sg13g2 with `add_pdn_connect -grid macro -layers "Metal4 ..."`.
- Macro x-offset had to be a multiple of the PDN stripe pitch or the macro's pin comb landed out of phase with the stripes.
- Tried `GRT_MACRO_EXTENSION: 2` (worse: overflow 17 to 217, reverted) and `DPL_CELL_PADDING=1` (byte-for-byte no effect
  at ~2.8% utilization).
- With the macro blackboxed, synthesis dropped to 1,328 cells (186 sequential) at 2.785% utilization, from 118,642.
- Magic DRC reported 1,115,481 errors, all transistor-level rules inside the vendor macro. `MAGIC_DRC_MAGLEFS` with a
  LEF-derived abstract fixed it, **but only once the file was named exactly like the macro** (a `_maglef` suffix made
  Magic name the cell differently so it never matched; the count stayed byte-identical until the log was read).
  KLayout has no equivalent knob, so a script (`blackbox_macro_gds.py`) cleared the macro cell in a copy of the GDS
  and re-ran the deck: zero violations. That copy is verification-only and never the submission GDS.

**The sg13g2 work was against the wrong target.** The competition's own announcement says IHP **CMOS5L**
(`ihp-sg13cmos5l`), a different tech path in Tiny Tapeout's tools, and other public entries use it. The RTL
(ISA, engines, FIFO, loaders, tests) is process-independent and carried over. The toolchain was rebuilt:
- tt-support-tools branch `ihp-sg13cmos5l`, LibreLane `3.1.0.dev3`, PDK from a pinned IHP-Open-PDK commit
  (not via ciel). The template's devcontainer still names sg13g2 and is stale; the workflows are authoritative.
- The same 512x8 macro exists under CMOS5L (the `sg13cmos5l_sram` directory is a symlink to `sg13g2_sram`).
- Metal stack is Metal1-4 plus TopMetal1 (no TopMetal2). Tile sizes are identical (6x4 = 1289.28 x 710.64 µm).
- Macro DRC control, KLayout deck on the standalone macro GDS: `ihp-sg13g2.drc` = 1,830 violations (811 Sdiod.d,
  811 Sdiod.e, 208 Cnt.c.digibnd); `ihp-sg13cmos5l.drc` = 0. The "precheck sees the macro interior" risk does not
  apply on CMOS5L.

**CMOS5L bring-up**
- First run (v5, killed): global-routing overflow 1,762 at 4.5% usage, 99% in the bottom ~250 µm band by the macros;
  detailed routing thrashed over 4 hours (3,065 to 422 violations in 54 iterations).
- `src/config.json` was rebased onto the CMOS5L template's own config (adds `PL_TARGET_DENSITY_PCT: 60`,
  `GRT_ALLOW_CONGESTION: 1`, `FP_PDN_VPITCH: 50`, etc.).
- Three PDN hypotheses failed (a Metal4-to-TopMetal1 bridge, `-grid_over_pg_pins`, and no macro grid). Failed runs
  after that died on a stale `runs/wokwi/` directory, so delete it before re-running.
- **Root cause**, found by reading the generated DEF rather than logs: pdngen cuts Metal4 stripes around macros, and in
  a CMOS5L tile the grid is Metal4-only (`RT_MAX_LAYER = Metal4`, `FP_PDN_MULTILAYER = 0`). That is the same layer as the
  macro's PG pins, with no layer above to drop a via from, so no pdngen setting can reach them. The PSM-0038 "unconnected
  shapes" were the macro's own 11.24 µm pin comb, not stripes.
- **Fix, part 1, floorplan:** in the macro LEF every signal pin is on the bottom edge and the top edge carries all
  three PG nets. All four macros now sit in one row, orientation FS, y=14, x = 10/280/580/880, power edge facing a
  channel above the core bottom, signal edge facing open logic. (The old 2x2 stack put signal pins ~6 µm from the die
  boundary, the real cause of v5's congestion.)
- **Fix, part 2, `src/pdn_macro_bridge.tcl`:** wraps `pdngen` to draw one Metal3 strap per net across the core in the
  channel, Metal4 stubs under each power-edge macro pin (160 = 4 x 40), and Via3 arrays at same-net crossings.
- **LVS caught a short PSM could not** (PSM checks nets separately): the first strap placement covered the other net's
  Metal3 landing pads of pdngen's rail-to-stripe via stacks. Straps are now centred on a rail of their own net, and a
  geometric VPWR x VGND overlap check over wires, vias and pins reports 0.
- **Result (`runs/full2`):** PSM 0 violations, GRT overflow 0 (was 1,762), detailed routing 0 violations in 5 min
  (was 422 after 4+ h), antenna clean, IR drop 0.01%, LVS "Circuits match uniquely", precheck KLayout deck 0.
- Magic's own GDS streamout adds a stray Via3 cut beside each bridge array (344 `V3.b`), absent from the KLayout
  streamout that ships. For `ihp-sg13cmos5l` the TT precheck does not run Magic DRC at all; the gate is the KLayout deck.
- **13 Magic DRC errors** (10 M2.f, 2 M3.f, 1 M2.d) on the macros' signal edge made LibreLane exit non-zero.
  Clearing `MAGIC_DRC_MAGLEFS` was tried and gave 120,951 errors (CMOS5L's SRAMID exemptions do not cover Magic's deck
  fully), so the abstract stays. The abstract's LEF-OBS-derived `obsm2`/`obsm3` were being read as >10 µm wide metal.
  Fix: regenerate the abstract under the CMOS5L tech and post-process it with `trim_maglef.py` (clip obsm2/obsm3 to start
  1.5 µm in from the signal edge, lengthen 68 Metal2 pin stubs to 0.6 µm). Magic DRC then reports 0, and only Magic reads this file.
- **`runs/full3`:** "Flow complete.", Magic 0, LVS 0, route DRC 0, antenna 0, setup WNS +8.35 ns, hold WNS +0.11 ns,
  0.95 mW; KLayout precheck deck on its GDS: 0 violations.
- `run_to.sh <tag>` re-runs the flow into `runs/<tag>` with the same container, PDK and merged config as
  `tt_tool.py --harden --ihp` (e.g. `--to OpenROAD.GeneratePDN` for ~2-minute PDN iterations).

## 5. Protocol microcode

Both programs run on `Dual` (isolating microcode correctness from pin arbitration), then through the real `tt_um_dual`
pins and loader, and later in cocotb on the shipped Verilog and the hardened netlist.

- **SPI master, mode 0, full duplex** (`test_spi_master.ml`): µE0 bit-bangs SCLK with `EMIT_STATE` and timed waits, drives
  MOSI and samples MISO via `SHIFT_IO`; µE1 pops the byte and branches on its MSB to drive a response pin. A software
  slave in the testbench checks both directions bit for bit. Test bug found: the slave rotated its shift register on the
  same cycle it saw SCLK rise, but µE0 samples one cycle later (everything is registered off the same decode). The
  rotation must happen on the opposite edge. That timing rule was applied from the start in the I2C test.
- **ISA limitation found:** `EMIT_STATE`'s level is a compile-time bit, so MOSI is a fixed unrolled byte. Runtime
  data needs a new output shift-register opcode or per-transfer reprogramming. Still open.
- **I2C master, open-drain read** (`test_i2c_master.ml`): START, 8-bit address, ACK check via a µE0 `BRANCH_COND`
  (NACK jumps to the STOP code, which is also the normal end path, with the target address asserted against the program
  length), 8 data bits via `SHIFT_IO`, master NACK, STOP. The open-drain bus is a real wired-AND in the testbench fed
  back into the engine. Tested with a slave that always ACKs and one that never does (the abort branch would otherwise
  be untested). The only failure was the test's own miscounted SCL-edge total (18 vs the correct 19).
- Both ported to the real pins (`test_tt_um_dual_spi.ml`, `test_tt_um_dual_i2c.ml`), passing first time.
- **CAPTURE mode** (`SHIFT_IO` with `mode=1`, a previously unused bit): pushes a 16-bit record
  `{pin_sel[15:13], level[12], elapsed[11:0]}` into the shared FIFO, with `elapsed` a free-running 12-bit counter that
  resets on each capture and saturates. It turns µE0 into a timestamped logic-analyzer channel with no new FIFO, and µE1
  needed no changes. `dual.ml` ORs `byte_ready`/`capture_ready` into one push port and muxes the data. Tested at engine
  level and through the real FIFO. No microcode yet runs it against an unknown waveform.

## 6. Verification and submission checks

- **Real `tt_tool` flow and TT precheck** (`--create-user-config`, `--harden`, `--create-tt-submission`, then
  `tt/precheck/precheck.py --tech ihp-sg13cmos5l`). The first attempt failed the precheck's **pin check**: every
  VPWR/VGND LEF port must reach within 10 µm of both die edges, but pdngen cut each Metal4 stripe around the macro row,
  leaving 40 segments starting at y = 124.86. LVS, Magic and KLayout were all clean; the rule only exists in the
  precheck. Fix: `PDN_OBSTRUCTIONS` blocks Metal4 stripes over each macro column above the macros, so only the six
  full-height stripe pairs in the gaps survive and feed the rails above. Result: precheck passes, Magic/LVS/route DRC/
  antenna/PSM all 0, setup WNS +8.6 ns, hold WNS +0.11 ns, worst IR drop 0.074%, 10 max-slew (slow corner), 0 max-cap,
  1,926 standard cells + 4 macros.
- **cocotb on the shipped Verilog** (`gl_test/`): runs `tt_um_dual.v` including the vendor SRAM model, since
  Cyclesim only simulates a behavioral RAM. SPI and I2C pass at RTL and on the hardened gate-level netlist, with the same
  simulated time (23,681 ns for SPI). Local notes: stock iverilog 12 never drives the vendor flops' `delayed_*` nets (from
  `$setuphold`), leaving every flop X, so `gl_test/patch_stdcell.py` ties them (`PATCH_STDCELL=no` with TT's iverilog 13
  fork, which CI uses). The std-cell UDP file must be in the source list; the template Makefile omits it. The gate-level
  bench takes the netlist from `tt_submission/tt_um_dual.v`, not the power-pin `.pnl.v`.
- **Finding:** instruction SRAM is not cleared, so a program that runs off its last word executes arbitrary bits (X in
  sim; Cyclesim's zero-filled RAM hides it). Convention: end programs with a halt (an edge-only wait on an idle pin).
  Not enforced in hardware, because that would change the RTL and invalidate the layout.
- **FIFO liveness, bounded-exhaustive:** all 4^10 = 1,048,576 push/pop sequences from reset on the real RTL against a
  reference model, checking flags, order, no loss or duplication, ignored push-when-full / pop-when-empty, and that a
  drain empties within 4 pops and a fill fills within 4 pushes. Complete for this design because control state saturates
  inside the bound. Mutation-checked (a wrong reference fails with 677k and 12.7M violations). ~25 s.
- **FIFO unbounded proof:** SymbiYosys with `abc pdr` (IC3) on the real generated `Shadow_fifo`, wrapped by
  `formal/fifo_props.sv` (free inputs, reference queue, flag/level/order/liveness assertions, 6 covers). Prove PASS and
  cover PASS (all 6 reached); a too-tight liveness bound and a wrong spec both fail with counterexamples. ~30 s. Only the
  FIFO is formally proved; the system-level no-deadlock argument remains directed simulation on top of the proved FIFO contract.
- **I2C added to the cocotb bench** at RTL and gate level.

## 7. Bit pipe, glitch filter and USB low-speed receive

- `lib/bitpipe.ml`: one configurable unit (NRZI, bit un-stuffing, CRC, byte assembly) used by one `PIPE_BIT` instruction
  per bit. USB low speed and CAN are two configurations.
- `lib/glitch_filter.ml`: N-consecutive-samples filter, integrated into µE0. µE1 branch now tests all 16 word bits.
- Checked against an independent transmitter, real USB vectors (a SETUP token and a GET_DESCRIPTOR CRC16), 300 random
  USB packets, 300 random CAN frames and every single-bit corruption.
- A four-instruction receive loop on the dual-engine core passes through the real pins and in cocotb on the shipped
  Verilog (good and corrupted packet), and keeps up down to 8 cycles per bit (6.25 Mbit/s at 50 MHz). Receive only; no
  transmit path and no per-edge resync. Windowed interval validation is not built. See `docs/design/design_rationale.txt`,
  Deviation 7.
- Re-harden with the bit pipe in: flow complete, LVS 0, Magic DRC 0, antenna 0, no setup/hold violations, new
  `tt_submission/` generated. Gate-level cocotb on the new netlist: SPI, I2C and USB good/corrupted all pass (4/4).
  Post-bit-pipe numbers: 3,704 standard cells + 4 macros (was 1,926), setup WNS +6.3 ns, hold WNS +0.11 ns, route DRC 0,
  14 max-slew warnings at the slow corner. TT precheck passes on the new GDS.
  Signoff STA also reports, with timing met at every corner:
  - Max-cap: 2 at the slow corner, 3 at typ and fast. All are SRAM macro data-out pins (`A_DOUT`) driving slightly
    more than their 0.064 pF limit; the worst is `mue1_instr_hi/A_DOUT[2]` at 0.074 pF (16% over).
  - Max-fanout: 31 at every corner (fanout does not depend on corner) against a limit of 8. 28 are clock-tree leaf
    buffers (`clkbuf_leaf_*`) driving 11 to 19 flops each; CTS groups sinks by its own clustering rules, and clock
    slew and skew are checked separately. The other 3 are resizer-inserted `fanout*` buffers driving 10.
  None of these block precheck. All three were cleared later (see "Electrical-rule cleanup" below).
- Full regression with the bit pipe in: all pass, including the formal FIFO proof. One earlier regression run reported
  the formal FIFO step as failed, with the FIFO, its generator and the proof files unchanged since the last pass; the
  same proof passed on every rerun, and the cause could not be recovered because each step's log overwrote the last.
  `run_regression.sh` now keeps every step's full log in `regress_logs/` and prints the tail of any failing step. The same
  change closed a silent pass: a failed vector generator left the committed vectors untouched, so the stale-vector
  check compared them against themselves and passed.
- Electrical-rule cleanup (`src/config.json`, comment `//0d`): all max-slew, max-cap and max-fanout warnings to 0 at
  every corner. Fanout: `MAX_FANOUT_CONSTRAINT` 10 → 8 (the stdcell libs' `default_max_fanout`) and
  `CTS_SINK_CLUSTERING_SIZE` 8. Slew/cap: the four macros sit in one row along the die bottom, so SRAM nets are long
  (µE1's write enable was 913 µm on one `buf_1`, most address/data nets 550–900 µm), and hold fixing puts weak
  `dlygate4sd3_1` cells in front of the address pins, each then driving ~300 µm. Took four runs, each fixing one layer:
  post-GRT design repair with wider margins cleared cap and fanout but left 18 slew; a 300 µm max wire length fixed
  the 913 µm net; a 50% post-GRT slew margin (global-route estimates under-call these routed slews by ~1.5–2×)
  cleared µE1, leaving 12 on µE0; a 200 µm max wire length cleared the rest. Final, via `tt_tool.py --harden`: 4,018
  standard cells + 4 macros (+314), setup WNS +7.34 ns, hold WNS +0.057 ns, 2.01 mW (+0.26), worst IR drop 2.1 mV (0.17%),
  LVS/Magic DRC/route DRC/antenna 0, TT precheck passes, gate-level cocotb 4/4.

## 8. Toolchain: `tdasm`

- `tools/tdasm/` is the assembler and program loader: one `.tds` source holds both engines' programs (labels,
  prescale, bit-pipe config), and it writes a listing, vectors JSON in `gl_test`'s format, and the byte-serial load
  script for a host with the expected load checksum. It is written in Axiom, pinned to 0.7.8.
- Checked against the hardware's own vectors: the SPI, I2C and USB example sources assemble to exactly the prescale,
  config bytes and words `test/gen_vectors.ml` produces, and nine malformed sources are each refused with the right
  error. Kept out of `run_regression.sh` so the chip's regression does not depend on a third-party compiler.
- Found while building it: three ISA changes are silent on a chip without the bit pipe (config bytes would load as
  program bytes, word bits 8-15 alias bits 0-7, `pipe_*` runs as CAPTURE), so the assembler targets this design only.

## 9. Transmit path and runtime profile table

Started from `design_note_tx_clock_recovery.md`; the reasons and alternatives are in `docs/design/design_rationale.txt`,
Deviation 8.

- `lib/profile_table.ml`: four 16-byte bit-pipe profiles (profile p byte k at config index 32p + k, so the original 9
  bytes are profile 0 unchanged), separate RX and TX pointers, a second write port for µE1's `CFG_WR`. The table lives in
  `Dual` and the loader only produces write strobes; its index is 7 bits.
- `lib/bitpipe.ml`: profile decoding, the run-length stuffing rule and the CRC step factored out so the transmit pipe uses
  the same code; CRC widened to 32 bits (bytes 9 to 15).
- `lib/txpipe.ml`: shift-out with auto-load, CRC over data then CRC append, stuff insertion, NRZI encode, and a `more` flag.
- µE0: `EMIT_TX` (with open-drain and differential forms), `PIPE_CTRL` gains `tx_reset`, `tx_crc`, `sel_rx`, `sel_tx` and a
  profile number in `pin_sel`, `BRANCH_COND` gains a flag form (payload bit 9). µE1: `TX_PUSH`, `TX_ECHO`, `CFG_WR`,
  `PROFILE`, all in the previously unused `mode = 1` half of `FIFO_POP`'s opcode.
- `out_reg`/`oe_reg` now latch on `advance` instead of `run`, because an `EMIT_TX` can stall and a stalled one must not
  latch; for `EMIT_STATE`, which never stalls, the two are the same.

**Bugs found**
1. **Timer, shipped since the RAM fetch fix:** a timed `WAIT` right after an instruction with payload 1 expired on its
   first cycle. Found because `test_dual_tx` checks that every USB bit cell is the same length: a `WAIT` after a
   `release_pin` no-op lasted 1 cycle. Consequence on the submitted design: the I2C master's SCL high phase was 2
   cycles, not 4. The I2C tests had a cycle budget sized from those short waits. Fixed in `timer.ml`, budgets resized
   (`half_period + 3` per half: the wait plus up to two pin instructions), and the I2C test now asserts the shortest SCL
   high phase.
2. **Test bytes that could not fail:** the mutation check's "TX profile pointer ignored" survived. The SPI and `CFG_WR`
   scenarios sent 0xA5 / 0x5A, which read the same MSB- and LSB-first. Replaced with 0xA6 / 0x3B; the mutant is caught.
3. Mutants that left a variable unused failed to build under dune's dev profile (warnings as errors) and were reported
   as errors, not results; mutants now build with `--profile release`.
4. Files rewritten from Windows through the `\\wsl.localhost` path lose their executable bit (`run_regression.sh` then
   "ran" silently as nothing). Restored with `chmod`; check `git diff --summary` for mode changes before committing.

**Verified** (details in Deviation 8): `test_txpipe` (reference encoders and loopback, 600 random packets),
`test_dual_tx` (UART, SPI full duplex, USB ACK and DATA0 at 33 cycles a bit, `CFG_WR`, open-drain, the timer
regression), `test_usb_transaction` (CRC5 token + CRC16 data in one run, controls, a USB-to-UART bridge),
`test_tt_um_dual_usb_tx` and cocotb's `usb_low_speed_transmit` through the real pins, `run_tx_mutation_test.sh` (13 of 13
caught), and `tdasm` (`usb_tx.tds` matches the vector, `.profile` placement, five new refusals). Full regression passes,
including every pre-existing suite unchanged. Not yet hardened.

## 10. Bit-clock recovery

Reasons and the measured gain choice are in `docs/design/design_rationale.txt`, Deviation 9.

- `lib/clock_recovery.ml`: 12.8 fixed-point phase and period, mid-bit strobe made sticky (`pending`, cleared by the
  sync `PIPE_BIT`), acceptance window, phase gain shift, and a period estimate (the second-order term) clamped to
  P +- P/16. `overrun` is BRANCH_COND flag 1. Profiles are now 24 bytes; bytes 16 to 21 configure the recovery.
- µE0: `PIPE_BIT` payload bit 0 waits for the strobe, bit 1 skips the sample (`pipe_sync`).

**Found while building it**
1. **Proportional-only loses lock.** The first version, as the design note proposed, failed the jitter-and-offset
   check: gain shift 1 at -2% rejected real edges once its phase error outgrew the window. Added the period estimate.
2. **Choosing the period gain by sweep, not by rule.** A guessed rule (freq shift = gain shift + 2) was unstable for
   snap correction at -1.5%; the sweep (`REC_SWEEP=1 ./run_clock_recovery_test.sh`) showed freq shift 4 is the one value
   that holds every offset for gain shifts 0 to 3.
3. **A rounding bias I overstated.** Arithmetic shifts round toward minus infinity; the shifts now round toward zero.
   I first wrote that the bias was a whole cycle per packet; measured in closed loop it is 0.02 cycle, and the comment
   says so.
4. **Arm on an idle line.** The tt_um and cocotb benches rejected a packet the Dual-level test accepted. Replaying the
   committed vector at Dual level passed, which ruled out an RTL/Cyclesim mismatch; the difference was the pins reading
   0 just after `go`, so the rise to idle J was taken as the first bit boundary. Programs now wait for idle J before
   arming, and the test shows the unwaited version failing.
5. Harness bugs, each caught by a check failing for the wrong reason: a strobe after the last bit indexed past the end
   of the bit table; shell escaping twice turned a scratch-directory variable into an empty string (nothing was
   written outside the scratch area; variables now only go through script files).

**Verified:** `test_clock_recovery` (unit, model boundary, control, glitch, overrun, unbiased period),
`test_usb_rx_recovery` (USB at -2% to +2% with jitter, the timed loop as control, the arming rule),
`test_tt_um_dual_usb_rec` and cocotb `usb_receive_with_clock_recovery` on the same committed vector, `tdasm`
(`usb_rx_rec.tds` matches the vector), mutation check 18 of 18. Not yet hardened.

## 11. Link-health reporting

Reasons are in `docs/design/design_rationale.txt`, Deviation 10.

- `clock_recovery.ml`: the worst edge error since arm, and a 6-cycle sequential divider turning it into 64ths of the bit
  period (`margin`, `margin_busy`).
- Status word bits [7:3] carry the margin; `PIPE_STATUS` waits while the divider is busy. `PIPE_STATUS` payload[1:0]
  selects the word: status, CRC low half, CRC high half, learned period (`pipe_crc_lo`, `pipe_crc_hi`, `pipe_period`).
- The recovery gl_test vector gained a DEGRADED flag (µE1 pin 4, from status bit 7) and a third line with +-7 cycles of
  jitter; `tdasm`'s `usb_rx_rec.tds` and the Cyclesim twin follow it.

All checks passed on the first run. **Verified:** `test_link_health` (exact margin, monotonic with offset and jitter,
80-of-80 syndromes located, learned period, the degraded flag ahead of CRC failure), the same flag through the pins
and in cocotb, mutation check 22 of 22, `tdasm` parity. Not yet hardened.

## 12. 10 Mbit Ethernet receive

Reasons, the six measured steps that shaped the decoder, and the tolerance table are in
`docs/design/design_rationale.txt`, Deviation 11.

- `clock_recovery.ml`: Manchester mode (P/4 classification, the level a quarter cell after the mid-bit point, two-miss
  frame end, one-slot delay, rising-edge arm). `bitpipe.ml`: sync-word hunt and octet CRC (profile bytes 22 and 23). `engine.ml`:
  `PIPE_BIT run` and the lost-byte flag.
- `test_ethernet` (with `ETH_SWEEP` and `ETH_BITERR` as measurement tools), `test_tt_um_dual_eth`, cocotb
  `ethernet_receive`, `tdasm` `eth_rx.tds`.
- Found along the way, besides the decoder steps: with the FIFO full, `PIPE_STATUS` waits forever, so a program checks
  the lost-byte flag first; and two more shell-quoting slips (variables in an inline `bash -c` expanded in the wrong
  shell), each failing loudly before touching anything.

**Measured:** 50 MHz, 30/30 frames at +-0.01% with +-0.5 cycle (10 ns) of jitter; 70 MHz, 30/30 with +-0.75 cycle
(10.7 ns). Not yet hardened.

## 13. Practical notes

- Dune quirk: `lib/tt_core.ml` shares its name with the library, which suppresses automatic submodule aliasing, so
  sibling modules need explicit `module X = X` lines in `tt_core.ml`.
- CI and LibreLane read `src/tt_um_dual.v`; `run_main.sh` regenerates `tt_um_dual.v` and copies it there.
- `tt_tool.py --harden` wipes `runs/wokwi/` itself; stale or forked run directories break `--overwrite` resumes.
- PyYAML must be built against libyaml (`pip install --force-reinstall --no-binary pyyaml pyyaml`) or LibreLane
  fails with `module 'yaml' has no attribute 'CBaseLoader'`.
- Magic and KLayout run inside the LibreLane Docker image the flow uses; mount the project and run the tool directly
  for one-off checks. Precheck must be run from `tt/precheck/` (it resolves its deck files relative to the working
  directory) with an absolute `--gds` path so it can find `info.yaml`.
- When a fix produces a byte-for-byte identical failure, first check from the tool's own log whether the fix engaged
  at all before concluding the approach is wrong (the Magic abstract filename, `DPL_CELL_PADDING`, the die-area report).
- When a tool reports a requested value, read the step's own output instead (the die area from the DEF, not `config.json`).
