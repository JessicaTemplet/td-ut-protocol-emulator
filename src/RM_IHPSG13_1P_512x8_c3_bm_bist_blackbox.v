// Synthesis-only blackbox stub for RM_IHPSG13_1P_512x8_c3_bm_bist.
//
// The vendor's own behavioral model (libs.ref/sg13g2_sram/verilog/
// RM_IHPSG13_1P_512x8_c3_bm_bist.v) has a `specify` block using SDF
// timing-check system tasks ($setuphold/$width with notifier
// arguments) that Yosys's Verilog-2005 frontend cannot parse
// ("syntax error, unexpected ','" at that file's line 140). That
// block is irrelevant here anyway -- for synthesis, Yosys only needs
// the module's port list so it can treat the macro as an opaque cell
// (the LEF/GDS/LIB views supply the physical footprint and timing).
// Port list copied verbatim from the vendor file's module declaration.
(* blackbox *)
module RM_IHPSG13_1P_512x8_c3_bm_bist (
    A_CLK,
    A_MEN,
    A_WEN,
    A_REN,
    A_ADDR,
    A_DIN,
    A_DLY,
    A_DOUT,
    A_BM,
    A_BIST_CLK,
    A_BIST_EN,
    A_BIST_MEN,
    A_BIST_WEN,
    A_BIST_REN,
    A_BIST_ADDR,
    A_BIST_DIN,
    A_BIST_BM
);

    input A_CLK;
    input A_MEN;
    input A_WEN;
    input A_REN;
    input [8:0] A_ADDR;
    input [7:0] A_DIN;
    input A_DLY;
    output [7:0] A_DOUT;
    input [7:0] A_BM;
    input A_BIST_CLK;
    input A_BIST_EN;
    input A_BIST_MEN;
    input A_BIST_WEN;
    input A_BIST_REN;
    input [8:0] A_BIST_ADDR;
    input [7:0] A_BIST_DIN;
    input [7:0] A_BIST_BM;

endmodule
