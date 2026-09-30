// Unbounded proof of shadow_fifo (the real Hardcaml-generated RTL) against a
// reference queue. Inputs are completely free (any push/pop/data/reset every
// cycle); the only assumption is that the first cycle is in reset, so the
// design and the model start from a known state.
//
// Spec (same as test/test_shadow_fifo_exhaustive.ml): push is ignored when
// full and pop is ignored when empty, both decided on the PRE-edge state.
// Properties:
//   P1 empty/full flags match the model's fill level at all times
//   P2 whenever not empty, pop_data is the oldest accepted un-popped item
//      (order, no loss, no duplication, dropped pushes never corrupt data)
//   P3 pop-liveness: 4 consecutive pop-only cycles always leave the FIFO empty
//   P4 push-liveness: 4 consecutive push-only cycles always leave it full
//      (a full FIFO always makes room; an empty one always accepts -- the FIFO
//      half of "never deadlocks")
// Plus covers, so the proof is not vacuous.
module fifo_props (
    input clk,
    input rst_n,
    input push,
    input [15:0] push_data,
    input pop
);
  wire [15:0] pop_data;
  wire empty, full;

  shadow_fifo dut (
      .clk(clk), .rst_n(rst_n), .push(push), .push_data(push_data),
      .pop(pop), .pop_data(pop_data), .empty(empty), .full(full)
  );

  reg init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  // ---- reference queue (shift-register style, q0 = oldest) ----
  reg [2:0] len;
  reg [15:0] q0, q1, q2, q3;
  wire do_pop = pop && len != 3'd0;
  wire do_push = push && len != 3'd4;

  reg [15:0] n0, n1, n2, n3;
  reg [2:0] nlen;
  always @* begin
    n0 = q0; n1 = q1; n2 = q2; n3 = q3; nlen = len;
    if (do_pop) begin
      n0 = q1; n1 = q2; n2 = q3; nlen = len - 3'd1;
    end
    if (do_push) begin
      case (nlen[1:0])
        2'd0: n0 = push_data;
        2'd1: n1 = push_data;
        2'd2: n2 = push_data;
        2'd3: n3 = push_data;
      endcase
      nlen = nlen + 3'd1;
    end
  end
  always @(posedge clk) begin
    if (!rst_n) begin
      len <= 3'd0;
    end else begin
      len <= nlen;
      q0 <= n0; q1 <= n1; q2 <= n2; q3 <= n3;
    end
  end

  // ---- streak counters for the liveness properties ----
  reg [2:0] pop_streak, push_streak;
  always @(posedge clk) begin
    if (!rst_n || !(pop && !push)) pop_streak <= 3'd0;
    else if (pop_streak != 3'd7) pop_streak <= pop_streak + 3'd1;
    if (!rst_n || !(push && !pop)) push_streak <= 3'd0;
    else if (push_streak != 3'd7) push_streak <= push_streak + 3'd1;
  end

  always @* begin
    if (!init) begin
      assert (empty == (len == 3'd0));                 // P1
      assert (full == (len == 3'd4));                  // P1
      assert (len <= 3'd4);
      if (len != 3'd0) assert (pop_data == q0);        // P2
      assert (pop_streak < 3'd4 || empty);             // P3
      assert (push_streak < 3'd4 || full);             // P4
    end
  end

  // non-vacuity: the interesting states are actually reachable
  always @* begin
    if (!init) begin
      cover (full);
      cover (len == 3'd2 && do_push && do_pop);        // steady-state streaming
      cover (full && push && !pop);                    // push dropped when full
      cover (empty && pop && !push);                   // pop dropped when empty
      cover (pop_streak == 3'd4 && empty);
      cover (push_streak == 3'd4 && full);
    end
  end
endmodule
