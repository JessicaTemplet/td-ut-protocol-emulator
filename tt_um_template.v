module tt_um_template (
    uio_in,
    ui_in,
    rst_n,
    clk,
    ena,
    uo_out,
    uio_out,
    uio_oe
);

    input [7:0] uio_in;
    input [7:0] ui_in;
    input rst_n;
    input clk;
    input ena;
    output [7:0] uo_out;
    output [7:0] uio_out;
    output [7:0] uio_oe;

    wire [7:0] _18;
    wire _74;
    wire _65;
    wire [15:0] _30;
    wire [15:0] _59;
    wire [14:0] _57;
    wire [15:0] _58;
    wire [15:0] _60;
    wire [7:0] _4;
    wire [15:0] _52;
    wire [15:0] _54;
    wire [15:0] _49;
    wire [15:0] _50;
    wire [3:0] _33;
    wire [3:0] _38;
    wire [3:0] _40;
    wire [3:0] _41;
    wire [3:0] _42;
    wire [3:0] _44;
    wire [3:0] _5;
    reg [3:0] _39;
    wire [3:0] _6;
    wire _34;
    wire _35;
    wire _32;
    wire _36;
    wire [15:0] _55;
    wire [15:0] _61;
    wire [15:0] _7;
    reg [15:0] _47;
    wire [15:0] _8;
    wire _31;
    wire _62;
    wire _63;
    wire _68;
    wire _69;
    wire _9;
    reg _66;
    wire _10;
    wire _28;
    reg _26;
    wire [7:0] _12;
    wire _20;
    wire _21;
    wire _27;
    wire _29;
    wire _14;
    wire _23;
    wire _16;
    wire vdd;
    reg _73;
    wire [4:0] _70;
    wire [7:0] _75;
    assign _18 = 8'b00000000;
    assign _74 = _10 & _31;
    assign _65 = 1'b0;
    assign _30 = 16'b0000000000000000;
    assign _59 = 16'b0000000000000001;
    assign _57 = _52[15:1];
    assign _58 = { _65,
                   _57 };
    assign _60 = _58 - _59;
    assign _4 = uio_in;
    assign _52 = { _18,
                   _4 };
    assign _54 = _52 - _59;
    assign _49 = _47 - _59;
    assign _50 = _31 ? _47 : _49;
    assign _33 = 4'b1000;
    assign _38 = 4'b0000;
    assign _40 = 4'b0001;
    assign _41 = _39 + _40;
    assign _42 = _36 ? _41 : _39;
    assign _44 = _29 ? _38 : _42;
    assign _5 = _44;
    always @(posedge _16) begin
        if (_23)
            _39 <= _38;
        else
            _39 <= _5;
    end
    assign _6 = _39;
    assign _34 = _6 == _33;
    assign _35 = ~ _34;
    assign _32 = _10 & _31;
    assign _36 = _32 & _35;
    assign _55 = _36 ? _54 : _50;
    assign _61 = _29 ? _60 : _55;
    assign _7 = _61;
    always @(posedge _16) begin
        if (_23)
            _47 <= _30;
        else
            _47 <= _7;
    end
    assign _8 = _47;
    assign _31 = _8 == _30;
    assign _62 = _10 & _31;
    assign _63 = _62 & _34;
    assign _68 = _63 ? _65 : _66;
    assign _69 = _29 ? vdd : _68;
    assign _9 = _69;
    always @(posedge _16) begin
        if (_23)
            _66 <= _65;
        else
            _66 <= _9;
    end
    assign _10 = _66;
    assign _28 = ~ _10;
    always @(posedge _16) begin
        if (_23)
            _26 <= _65;
        else
            _26 <= _20;
    end
    assign _12 = ui_in;
    assign _20 = _12[0:0];
    assign _21 = ~ _20;
    assign _27 = _21 & _26;
    assign _29 = _27 & _28;
    assign _14 = rst_n;
    assign _23 = ~ _14;
    assign _16 = clk;
    assign vdd = 1'b1;
    always @(posedge _16) begin
        if (_23)
            _73 <= _65;
        else
            if (_29)
                _73 <= vdd;
    end
    assign _70 = 5'b00000;
    assign _75 = { _70,
                   _73,
                   _10,
                   _74 };
    assign uo_out = _75;
    assign uio_out = _18;
    assign uio_oe = _18;

endmodule
