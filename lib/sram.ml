open Hardcaml
open Signal

(* ============================================================
   Real IHP SG13 SRAM macro backing (same part in the sg13g2 and CMOS5L
   PDKs; CMOS5L symlinks sg13cmos5l_sram to sg13g2_sram) for the engines' 512x16
   instruction memory, replacing Hardcaml's Ram.create.

   Why this exists: a full LibreLane hardening pass against
   tt_um_dual synthesized BOTH engines' Ram.create instances as
   ~16,076 individual flip-flops (Yosys's generic memory_map pass has
   no rule telling it to use a hard macro), landing the design at
   118,642 total cells -- ~5x the 24-tile budget. See docs/design/design_rationale.txt,
   "THE FINDING", for the full synthesis-log evidence.

   Macro used: RM_IHPSG13_1P_512x8_c3_bm_bist (single-port, 512x8,
   confirmed present in the local PDK install under
   libs.ref/sg13g2_sram/{verilog,lef,lib,gds,cdl}/ -- no external fetch
   needed). Two instances (low/high byte) make one 512x16 word, same
   "two single-port 512x8 macros per engine instead of one shared
   dual-port 512x16" call design_rationale.txt's Deviations section
   already made on area grounds (a 512x16 part only exists as
   dual-port, 3x4 tiles -- half the whole chip budget for one RAM).
   LEF says each 512x8 instance is 236.8 x 110.38um against this PDK's
   202.08 x 154.98um 1x1 tile -- a 2x1-tile footprint, so two per
   engine costs ~4 tiles/engine, ~8 total, matching that section's
   estimate.

   Pin behavior, from the macro's own datasheet
   (libs.ref/sg13g2_sram/doc/RM_IHPSG13_1P_512x8_c3_bm_bist.txt):
   - Single physical address port (A_ADDR) serves both read and write
     -- this design's write/read split already never overlaps in time
     (writes only while run=0, reads only while run=1, per the
     Deviations section), so muxing one address bus between
     write_addr and read_addr below is safe, not a new constraint.
   - Operation table: MEN=1,REN=1,WEN=0 = Read; MEN=1,REN=1,WEN=1 =
     Write-Through (new data appears on A_DOUT the same operation) --
     tying A_REN high always and driving A_WEN with write_enable
     reproduces exactly the ~collision_mode:Write_before_read contract
     Ram.create had, no `run`-awareness needed at this level.
   - A_BM (bit mask) is documented "write enabled on bit [i] if
     BM[i]=1'b1" (confirmed in the vendor behavioral primitive,
     RM_IHPSG13_1P_core_behavioral_bm_bist.v) -- tied to all-1s since
     every write here is a full 8-bit write, no partial-word writes
     exist in this design.
   - A_DLY: datasheet marks this MANDATORY tied to 1.
   - BIST_* inputs: tied off (A_BIST_EN=0 disables BIST mode entirely,
     per the operation table's own "when BIST_EN=0, A_ADDR is used"
     row); tying the rest to 0 just avoids floating/X inputs, they're
     don't-cares whenever BIST_EN=0.
   ============================================================ *)

let byte_lane ~instance ~clk ~write_enable ~addr ~din =
  let outputs =
    Instantiation.create ()
      ~name:"RM_IHPSG13_1P_512x8_c3_bm_bist"
      ~instance
      ~inputs:
        [ "A_CLK", clk
        ; "A_MEN", vdd
        ; "A_WEN", write_enable
        ; "A_REN", vdd
        ; "A_ADDR", addr
        ; "A_DIN", din
        ; "A_BM", ones 8
        ; "A_DLY", vdd
        ; "A_BIST_CLK", clk
        ; "A_BIST_EN", gnd
        ; "A_BIST_MEN", gnd
        ; "A_BIST_WEN", gnd
        ; "A_BIST_REN", gnd
        ; "A_BIST_ADDR", zero 9
        ; "A_BIST_DIN", zero 8
        ; "A_BIST_BM", zero 8
        ]
      ~outputs:[ "A_DOUT", 8 ]
  in
  Base.Map.find_exn outputs "A_DOUT"

(* Drop-in replacement for the shape engine.ml/protocol_engine.ml's
   Ram.create call already had: one write port (write_addr/
   write_enable/write_data), one read port (read_addr), same 1-cycle
   registered-read latency (the macro is itself a synchronous SRAM),
   returned as a single 16-bit signal. `instance_prefix` keeps each
   engine's pair of macro instances distinctly named in the generated
   netlist (e.g. "mue0_instr"/"mue1_instr"). *)
let create_512x16 ~instance_prefix ~clk ~write_enable ~write_addr ~write_data ~read_addr =
  let addr = mux2 write_enable write_addr read_addr in
  let lo =
    byte_lane
      ~instance:(instance_prefix ^ "_lo")
      ~clk ~write_enable ~addr
      ~din:(select write_data 7 0)
  in
  let hi =
    byte_lane
      ~instance:(instance_prefix ^ "_hi")
      ~clk ~write_enable ~addr
      ~din:(select write_data 15 8)
  in
  concat_msb [ hi; lo ]
