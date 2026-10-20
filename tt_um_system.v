module tt_um_system (
    ui_in,
    rst_n,
    clk,
    uio_in,
    ena,
    uo_out,
    uio_out,
    uio_oe
);

    input [7:0] ui_in;
    input rst_n;
    input clk;
    input [7:0] uio_in;
    input ena;
    output [7:0] uo_out;
    output [7:0] uio_out;
    output [7:0] uio_oe;

    wire _64;
    wire _69;
    wire [2:0] _59;
    wire _60;
    wire _57;
    wire _61;
    wire _70;
    wire _1;
    reg _66;
    wire _78;
    wire [2:0] _72;
    wire _73;
    wire _71;
    wire _74;
    wire _79;
    wire _2;
    reg _77;
    wire _87;
    wire [2:0] _81;
    wire _82;
    wire _80;
    wire _83;
    wire _88;
    wire _3;
    reg _86;
    wire _96;
    wire [2:0] _90;
    wire _91;
    wire _89;
    wire _92;
    wire _97;
    wire _4;
    reg _95;
    wire _105;
    wire [2:0] _99;
    wire _100;
    wire _98;
    wire _101;
    wire _106;
    wire _5;
    reg _104;
    wire _114;
    wire [2:0] _108;
    wire _109;
    wire _107;
    wire _110;
    wire _115;
    wire _6;
    reg _113;
    wire _123;
    wire [2:0] _117;
    wire _118;
    wire _116;
    wire _119;
    wire _124;
    wire _7;
    reg _122;
    wire _68;
    wire _132;
    wire [2:0] _126;
    wire _127;
    wire _125;
    wire _128;
    wire _133;
    wire _8;
    reg _131;
    wire [7:0] _135;
    wire [7:0] _134;
    wire [7:0] _136;
    wire [7:0] _163;
    wire _166;
    wire _164;
    wire _167;
    wire _169;
    wire _11;
    reg _161;
    wire _172;
    wire _170;
    wire _173;
    wire _174;
    wire _12;
    reg _158;
    wire _177;
    wire _175;
    wire _178;
    wire _179;
    wire _13;
    reg _155;
    wire _182;
    wire _180;
    wire _183;
    wire _184;
    wire _14;
    reg _152;
    wire _187;
    wire _185;
    wire _188;
    wire _189;
    wire _15;
    reg _149;
    wire _192;
    wire _190;
    wire _193;
    wire _194;
    wire _16;
    reg _146;
    wire _197;
    wire _195;
    wire _198;
    wire _199;
    wire _17;
    reg _143;
    wire _331;
    wire [1:0] _55;
    wire [8:0] _227;
    wire [7:0] _225;
    wire [7:0] _224;
    wire [7:0] _231;
    wire [7:0] _18;
    wire gnd;
    wire [7:0] _322;
    wire [8:0] _235;
    wire [8:0] _236;
    wire [8:0] _237;
    wire [8:0] _19;
    reg [8:0] _234;
    wire [8:0] _20;
    wire [8:0] _219;
    wire [8:0] _220;
    wire [8:0] _238;
    wire [8:0] _21;
    wire [8:0] _257;
    wire _250;
    wire _251;
    wire [1:0] _239;
    wire _240;
    wire _252;
    wire _22;
    wire [8:0] _258;
    wire [8:0] _259;
    wire [8:0] _23;
    reg [8:0] _255;
    wire [8:0] _24;
    wire _315;
    wire _316;
    reg _313;
    wire _248;
    wire _247;
    wire _246;
    wire _245;
    wire _244;
    wire _243;
    wire _242;
    wire _241;
    reg _249;
    wire _310;
    wire _314;
    wire _168;
    wire _317;
    reg [2:0] _308;
    wire [2:0] _58;
    wire _309;
    wire _318;
    wire _293;
    wire [9:0] _269;
    wire [9:0] _275;
    wire [9:0] _276;
    wire [9:0] _272;
    wire [9:0] _273;
    wire [9:0] _274;
    wire [9:0] _277;
    wire [9:0] _25;
    reg [9:0] _268;
    wire [9:0] _26;
    wire _270;
    wire [7:0] _284;
    wire [7:0] _27;
    reg [7:0] _283;
    wire [7:0] _28;
    wire [7:0] _288;
    wire [7:0] _289;
    wire [7:0] _290;
    wire [7:0] _29;
    reg [7:0] _287;
    wire [7:0] _30;
    wire _264;
    wire _266;
    wire _299;
    wire _63;
    reg _262;
    wire _300;
    wire _31;
    reg _297;
    wire _32;
    wire _291;
    wire _292;
    wire _294;
    wire [9:0] _67;
    wire _305;
    wire _319;
    wire _303;
    wire [1:0] _301;
    wire _302;
    wire _320;
    wire _321;
    wire _33;
    wire [8:0] _221;
    wire [8:0] _222;
    wire [7:0] _328;
    wire [7:0] _34;
    wire [15:0] _53;
    wire [1:0] _54;
    wire _56;
    wire _329;
    wire _332;
    wire _333;
    wire _35;
    reg _140;
    wire [7:0] _162;
    wire [7:0] _350;
    wire _334;
    wire _335;
    wire _336;
    wire _337;
    wire [7:0] _341;
    wire [7:0] _36;
    reg [7:0] _340;
    wire [7:0] _37;
    wire [7:0] _39;
    wire [15:0] _223;
    wire [7:0] _349;
    wire [7:0] _351;
    wire [7:0] _352;
    wire _279;
    wire _278;
    wire _280;
    wire _345;
    wire _40;
    reg _344;
    wire _41;
    wire _215;
    wire _213;
    reg _210;
    wire _211;
    wire _200;
    reg _204;
    reg _207;
    wire _212;
    wire _214;
    wire _216;
    wire _217;
    wire [7:0] _353;
    wire [7:0] _42;
    reg [7:0] _348;
    wire [7:0] _43;
    reg _366;
    wire _367;
    wire vdd;
    wire _45;
    wire _202;
    wire _47;
    wire [7:0] _49;
    wire _357;
    reg _360;
    reg _363;
    wire _368;
    wire _369;
    wire _50;
    reg _356;
    wire _51;
    wire [7:0] _370;
    assign _64 = 1'b0;
    assign _69 = ~ _68;
    assign _59 = 3'b000;
    assign _60 = _58 == _59;
    assign _57 = _51 & _56;
    assign _61 = _57 & _60;
    assign _70 = _61 ? _69 : _66;
    assign _1 = _70;
    always @(posedge _47) begin
        if (_63)
            _66 <= _64;
        else
            _66 <= _1;
    end
    assign _78 = ~ _68;
    assign _72 = 3'b001;
    assign _73 = _58 == _72;
    assign _71 = _51 & _56;
    assign _74 = _71 & _73;
    assign _79 = _74 ? _78 : _77;
    assign _2 = _79;
    always @(posedge _47) begin
        if (_63)
            _77 <= _64;
        else
            _77 <= _2;
    end
    assign _87 = ~ _68;
    assign _81 = 3'b010;
    assign _82 = _58 == _81;
    assign _80 = _51 & _56;
    assign _83 = _80 & _82;
    assign _88 = _83 ? _87 : _86;
    assign _3 = _88;
    always @(posedge _47) begin
        if (_63)
            _86 <= _64;
        else
            _86 <= _3;
    end
    assign _96 = ~ _68;
    assign _90 = 3'b011;
    assign _91 = _58 == _90;
    assign _89 = _51 & _56;
    assign _92 = _89 & _91;
    assign _97 = _92 ? _96 : _95;
    assign _4 = _97;
    always @(posedge _47) begin
        if (_63)
            _95 <= _64;
        else
            _95 <= _4;
    end
    assign _105 = ~ _68;
    assign _99 = 3'b100;
    assign _100 = _58 == _99;
    assign _98 = _51 & _56;
    assign _101 = _98 & _100;
    assign _106 = _101 ? _105 : _104;
    assign _5 = _106;
    always @(posedge _47) begin
        if (_63)
            _104 <= _64;
        else
            _104 <= _5;
    end
    assign _114 = ~ _68;
    assign _108 = 3'b101;
    assign _109 = _58 == _108;
    assign _107 = _51 & _56;
    assign _110 = _107 & _109;
    assign _115 = _110 ? _114 : _113;
    assign _6 = _115;
    always @(posedge _47) begin
        if (_63)
            _113 <= _64;
        else
            _113 <= _6;
    end
    assign _123 = ~ _68;
    assign _117 = 3'b110;
    assign _118 = _58 == _117;
    assign _116 = _51 & _56;
    assign _119 = _116 & _118;
    assign _124 = _119 ? _123 : _122;
    assign _7 = _124;
    always @(posedge _47) begin
        if (_63)
            _122 <= _64;
        else
            _122 <= _7;
    end
    assign _68 = _67[0:0];
    assign _132 = ~ _68;
    assign _126 = 3'b111;
    assign _127 = _58 == _126;
    assign _125 = _51 & _56;
    assign _128 = _125 & _127;
    assign _133 = _128 ? _132 : _131;
    assign _8 = _133;
    always @(posedge _47) begin
        if (_63)
            _131 <= _64;
        else
            _131 <= _8;
    end
    assign _135 = { _131,
                    _122,
                    _113,
                    _104,
                    _95,
                    _86,
                    _77,
                    _66 };
    assign _134 = 8'b00000000;
    assign _136 = _51 ? _135 : _134;
    assign _163 = _51 ? _162 : _134;
    assign _166 = _58 == _59;
    assign _164 = _51 & _56;
    assign _167 = _164 & _166;
    assign _169 = _167 ? _168 : _161;
    assign _11 = _169;
    always @(posedge _47) begin
        if (_63)
            _161 <= _64;
        else
            _161 <= _11;
    end
    assign _172 = _58 == _72;
    assign _170 = _51 & _56;
    assign _173 = _170 & _172;
    assign _174 = _173 ? _168 : _158;
    assign _12 = _174;
    always @(posedge _47) begin
        if (_63)
            _158 <= _64;
        else
            _158 <= _12;
    end
    assign _177 = _58 == _81;
    assign _175 = _51 & _56;
    assign _178 = _175 & _177;
    assign _179 = _178 ? _168 : _155;
    assign _13 = _179;
    always @(posedge _47) begin
        if (_63)
            _155 <= _64;
        else
            _155 <= _13;
    end
    assign _182 = _58 == _90;
    assign _180 = _51 & _56;
    assign _183 = _180 & _182;
    assign _184 = _183 ? _168 : _152;
    assign _14 = _184;
    always @(posedge _47) begin
        if (_63)
            _152 <= _64;
        else
            _152 <= _14;
    end
    assign _187 = _58 == _99;
    assign _185 = _51 & _56;
    assign _188 = _185 & _187;
    assign _189 = _188 ? _168 : _149;
    assign _15 = _189;
    always @(posedge _47) begin
        if (_63)
            _149 <= _64;
        else
            _149 <= _15;
    end
    assign _192 = _58 == _108;
    assign _190 = _51 & _56;
    assign _193 = _190 & _192;
    assign _194 = _193 ? _168 : _146;
    assign _16 = _194;
    always @(posedge _47) begin
        if (_63)
            _146 <= _64;
        else
            _146 <= _16;
    end
    assign _197 = _58 == _117;
    assign _195 = _51 & _56;
    assign _198 = _195 & _197;
    assign _199 = _198 ? _168 : _143;
    assign _17 = _199;
    always @(posedge _47) begin
        if (_63)
            _143 <= _64;
        else
            _143 <= _17;
    end
    assign _331 = _58 == _126;
    assign _55 = 2'b01;
    assign _227 = 9'b000000000;
    assign _225 = 8'b11111111;
    assign _224 = _223[7:0];
    RM_IHPSG13_1P_512x8_c3_bm_bist
        mue0_instr_lo
        ( .A_CLK(_47),
          .A_MEN(vdd),
          .A_WEN(_217),
          .A_REN(vdd),
          .A_ADDR(_222),
          .A_DIN(_224),
          .A_BM(_225),
          .A_DLY(vdd),
          .A_BIST_CLK(_47),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_227),
          .A_BIST_DIN(_134),
          .A_BIST_BM(_134),
          .A_DOUT(_231[7:0]) );
    assign _18 = _231;
    assign gnd = 1'b0;
    assign _322 = _223[15:8];
    assign _235 = 9'b000000001;
    assign _236 = _234 + _235;
    assign _237 = _217 ? _236 : _234;
    assign _19 = _237;
    always @(posedge _47) begin
        if (_202)
            _234 <= _227;
        else
            _234 <= _19;
    end
    assign _20 = _234;
    assign _219 = _24 + _235;
    assign _220 = _22 ? _21 : _219;
    assign _238 = _67[8:0];
    assign _21 = _238;
    assign _257 = _255 + _235;
    assign _250 = ~ _249;
    assign _251 = _168 ? _249 : _250;
    assign _239 = 2'b11;
    assign _240 = _54 == _239;
    assign _252 = _240 & _251;
    assign _22 = _252;
    assign _258 = _22 ? _21 : _257;
    assign _259 = _33 ? _258 : _255;
    assign _23 = _259;
    always @(posedge _47) begin
        if (_63)
            _255 <= _227;
        else
            _255 <= _23;
    end
    assign _24 = _255;
    assign _315 = ~ _313;
    assign _316 = _249 & _315;
    always @(posedge _47) begin
        if (_63)
            _313 <= _64;
        else
            _313 <= _249;
    end
    assign _248 = _49[7:7];
    assign _247 = _49[6:6];
    assign _246 = _49[5:5];
    assign _245 = _49[4:4];
    assign _244 = _49[3:3];
    assign _243 = _49[2:2];
    assign _242 = _49[1:1];
    assign _241 = _49[0:0];
    always @* begin
        case (_58)
        0:
            _249 <= _241;
        1:
            _249 <= _242;
        2:
            _249 <= _243;
        3:
            _249 <= _244;
        4:
            _249 <= _245;
        5:
            _249 <= _246;
        6:
            _249 <= _247;
        default:
            _249 <= _248;
        endcase
    end
    assign _310 = ~ _249;
    assign _314 = _310 & _313;
    assign _168 = _53[10:10];
    assign _317 = _168 ? _316 : _314;
    always @(posedge _47) begin
        if (_63)
            _308 <= _59;
        else
            _308 <= _58;
    end
    assign _58 = _53[13:11];
    assign _309 = _58 == _308;
    assign _318 = _309 & _317;
    assign _293 = ~ _262;
    assign _269 = 10'b0000000000;
    assign _275 = 10'b0000000001;
    assign _276 = _67 - _275;
    assign _272 = _268 - _275;
    assign _273 = _270 ? _268 : _272;
    assign _274 = _264 ? _273 : _268;
    assign _277 = _262 ? _276 : _274;
    assign _25 = _277;
    always @(posedge _47) begin
        if (_266)
            _268 <= _269;
        else
            _268 <= _25;
    end
    assign _26 = _268;
    assign _270 = _26 == _269;
    assign _284 = _280 ? _39 : _283;
    assign _27 = _284;
    always @(posedge _47) begin
        if (_202)
            _283 <= _134;
        else
            _283 <= _27;
    end
    assign _28 = _283;
    assign _288 = 8'b00000001;
    assign _289 = _287 - _288;
    assign _290 = _264 ? _28 : _289;
    assign _29 = _290;
    always @(posedge _47) begin
        if (_266)
            _287 <= _134;
        else
            _287 <= _29;
    end
    assign _30 = _287;
    assign _264 = _30 == _134;
    assign _266 = ~ _45;
    assign _299 = _294 ? _64 : _297;
    assign _63 = ~ _45;
    always @(posedge _47) begin
        if (_63)
            _262 <= _64;
        else
            _262 <= _33;
    end
    assign _300 = _262 ? vdd : _299;
    assign _31 = _300;
    always @(posedge _47) begin
        if (_266)
            _297 <= _64;
        else
            _297 <= _31;
    end
    assign _32 = _297;
    assign _291 = _32 & _264;
    assign _292 = _291 & _270;
    assign _294 = _292 & _293;
    assign _67 = _53[9:0];
    assign _305 = _67 == _269;
    assign _319 = _305 ? _318 : _294;
    assign _303 = 1'b1;
    assign _301 = 2'b00;
    assign _302 = _54 == _301;
    assign _320 = _302 ? _319 : _303;
    assign _321 = _51 & _320;
    assign _33 = _321;
    assign _221 = _33 ? _220 : _24;
    assign _222 = _217 ? _20 : _221;
    RM_IHPSG13_1P_512x8_c3_bm_bist
        mue0_instr_hi
        ( .A_CLK(_47),
          .A_MEN(vdd),
          .A_WEN(_217),
          .A_REN(vdd),
          .A_ADDR(_222),
          .A_DIN(_322),
          .A_BM(_225),
          .A_DLY(vdd),
          .A_BIST_CLK(_47),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_227),
          .A_BIST_DIN(_134),
          .A_BIST_BM(_134),
          .A_DOUT(_328[7:0]) );
    assign _34 = _328;
    assign _53 = { _34,
                   _18 };
    assign _54 = _53[15:14];
    assign _56 = _54 == _55;
    assign _329 = _51 & _56;
    assign _332 = _329 & _331;
    assign _333 = _332 ? _168 : _140;
    assign _35 = _333;
    always @(posedge _47) begin
        if (_63)
            _140 <= _64;
        else
            _140 <= _35;
    end
    assign _162 = { _140,
                    _143,
                    _146,
                    _149,
                    _152,
                    _155,
                    _158,
                    _161 };
    assign _350 = _223[7:0];
    assign _334 = ~ _213;
    assign _335 = _212 & _334;
    assign _336 = _335 & _215;
    assign _337 = _336 & _41;
    assign _341 = _337 ? _39 : _340;
    assign _36 = _341;
    always @(posedge _47) begin
        if (_202)
            _340 <= _134;
        else
            _340 <= _36;
    end
    assign _37 = _340;
    assign _39 = ui_in;
    assign _223 = { _39,
                    _37 };
    assign _349 = _223[15:8];
    assign _351 = _349 ^ _350;
    assign _352 = _348 ^ _351;
    assign _279 = ~ _41;
    assign _278 = _212 & _215;
    assign _280 = _278 & _279;
    assign _345 = _344 | _280;
    assign _40 = _345;
    always @(posedge _47) begin
        if (_202)
            _344 <= _64;
        else
            _344 <= _40;
    end
    assign _41 = _344;
    assign _215 = ~ _51;
    assign _213 = _49[1:1];
    always @(posedge _47) begin
        if (_202)
            _210 <= _64;
        else
            _210 <= _207;
    end
    assign _211 = ~ _210;
    assign _200 = _49[0:0];
    always @(posedge _47) begin
        if (_202)
            _204 <= _64;
        else
            _204 <= _200;
    end
    always @(posedge _47) begin
        if (_202)
            _207 <= _64;
        else
            _207 <= _204;
    end
    assign _212 = _207 & _211;
    assign _214 = _212 & _213;
    assign _216 = _214 & _215;
    assign _217 = _216 & _41;
    assign _353 = _217 ? _352 : _348;
    assign _42 = _353;
    always @(posedge _47) begin
        if (_202)
            _348 <= _134;
        else
            _348 <= _42;
    end
    assign _43 = _348;
    always @(posedge _47) begin
        if (_202)
            _366 <= _64;
        else
            _366 <= _363;
    end
    assign _367 = ~ _366;
    assign vdd = 1'b1;
    assign _45 = rst_n;
    assign _202 = ~ _45;
    assign _47 = clk;
    assign _49 = uio_in;
    assign _357 = _49[2:2];
    always @(posedge _47) begin
        if (_202)
            _360 <= _64;
        else
            _360 <= _357;
    end
    always @(posedge _47) begin
        if (_202)
            _363 <= _64;
        else
            _363 <= _360;
    end
    assign _368 = _363 & _367;
    assign _369 = _356 | _368;
    assign _50 = _369;
    always @(posedge _47) begin
        if (_202)
            _356 <= _64;
        else
            _356 <= _50;
    end
    assign _51 = _356;
    assign _370 = _51 ? _162 : _43;
    assign uo_out = _370;
    assign uio_out = _163;
    assign uio_oe = _136;

endmodule
