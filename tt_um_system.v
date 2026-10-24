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

    wire _87;
    wire [2:0] _82;
    wire _83;
    wire _81;
    wire _84;
    wire _90;
    wire [2:0] _73;
    wire _74;
    wire _71;
    wire _75;
    wire _107;
    wire _1;
    reg _89;
    wire _114;
    wire _112;
    wire _115;
    wire _119;
    wire _110;
    wire _108;
    wire _111;
    wire _120;
    wire _2;
    reg _118;
    wire [2:0] _126;
    wire _127;
    wire _125;
    wire _128;
    wire _132;
    wire [2:0] _122;
    wire _123;
    wire _121;
    wire _124;
    wire _133;
    wire _3;
    reg _131;
    wire _140;
    wire _138;
    wire _141;
    wire _145;
    wire _136;
    wire _134;
    wire _137;
    wire _146;
    wire _4;
    reg _144;
    wire [2:0] _152;
    wire _153;
    wire _151;
    wire _154;
    wire _158;
    wire [2:0] _148;
    wire _149;
    wire _147;
    wire _150;
    wire _159;
    wire _5;
    reg _157;
    wire _166;
    wire _164;
    wire _167;
    wire _171;
    wire _162;
    wire _160;
    wire _163;
    wire _172;
    wire _6;
    reg _170;
    wire [2:0] _178;
    wire _179;
    wire _177;
    wire _180;
    wire _184;
    wire [2:0] _174;
    wire _175;
    wire _173;
    wire _176;
    wire _185;
    wire _7;
    reg _183;
    wire _104;
    wire _105;
    wire _91;
    wire _92;
    wire _106;
    wire _192;
    wire _190;
    wire _193;
    wire _197;
    wire _188;
    wire _186;
    wire _189;
    wire _198;
    wire _8;
    reg _196;
    wire [7:0] _200;
    wire [7:0] _199;
    wire [7:0] _201;
    wire [7:0] _228;
    wire _237;
    wire _235;
    wire _233;
    wire _236;
    wire _238;
    wire _231;
    wire _229;
    wire _232;
    wire _241;
    wire _11;
    reg _226;
    wire _250;
    wire _248;
    wire _246;
    wire _249;
    wire _251;
    wire _244;
    wire _242;
    wire _245;
    wire _252;
    wire _12;
    reg _223;
    wire _261;
    wire _259;
    wire _257;
    wire _260;
    wire _262;
    wire _255;
    wire _253;
    wire _256;
    wire _263;
    wire _13;
    reg _220;
    wire _272;
    wire _270;
    wire _268;
    wire _271;
    wire _273;
    wire _266;
    wire _264;
    wire _267;
    wire _274;
    wire _14;
    reg _217;
    wire _283;
    wire _281;
    wire _279;
    wire _282;
    wire _284;
    wire _277;
    wire _275;
    wire _278;
    wire _285;
    wire _15;
    reg _214;
    wire _294;
    wire _292;
    wire _290;
    wire _293;
    wire _295;
    wire _288;
    wire _286;
    wire _289;
    wire _296;
    wire _16;
    reg _211;
    wire _305;
    wire _303;
    wire _301;
    wire _304;
    wire _306;
    wire _299;
    wire _297;
    wire _300;
    wire _307;
    wire _17;
    reg _208;
    wire _240;
    wire [31:0] _332;
    wire [31:0] _337;
    wire [30:0] _334;
    wire [31:0] _336;
    wire [31:0] _338;
    wire [31:0] _339;
    wire [31:0] _341;
    wire [31:0] _18;
    reg [31:0] _333;
    wire [31:0] _19;
    wire _100;
    wire _102;
    wire [6:0] _348;
    wire [7:0] _349;
    wire [7:0] _350;
    wire [7:0] _20;
    reg [7:0] _346;
    wire [7:0] _21;
    wire [7:0] _98;
    wire _99;
    wire _103;
    wire _571;
    wire _569;
    wire _79;
    wire _80;
    wire _567;
    wire _570;
    wire _572;
    wire _565;
    wire _556;
    wire _557;
    reg _554;
    wire _551;
    wire _555;
    wire _558;
    reg [2:0] _549;
    wire _550;
    wire _559;
    wire _398;
    wire [9:0] _360;
    wire [9:0] _366;
    wire [9:0] _367;
    wire [9:0] _363;
    wire [9:0] _364;
    wire [9:0] _365;
    wire [9:0] _368;
    wire [9:0] _22;
    reg [9:0] _359;
    wire [9:0] _23;
    wire _361;
    wire [7:0] _389;
    wire [7:0] _24;
    reg [7:0] _388;
    wire [7:0] _25;
    wire [7:0] _393;
    wire [7:0] _394;
    wire [7:0] _395;
    wire [7:0] _26;
    reg [7:0] _392;
    wire [7:0] _27;
    wire _355;
    wire _357;
    wire _404;
    reg _353;
    wire _405;
    wire _28;
    reg _402;
    wire _29;
    wire _396;
    wire _397;
    wire _399;
    wire _546;
    wire _560;
    wire _424;
    wire _425;
    wire _426;
    wire _427;
    wire _30;
    reg _417;
    wire _541;
    wire _422;
    wire [1:0] _419;
    wire _420;
    wire _418;
    wire _421;
    wire _423;
    wire _542;
    wire _540;
    wire _543;
    wire _544;
    wire [1:0] _538;
    wire [8:0] _440;
    wire [7:0] _439;
    wire [7:0] _438;
    wire [7:0] _444;
    wire [7:0] _31;
    wire [7:0] _531;
    wire [8:0] _448;
    wire [8:0] _449;
    wire [8:0] _450;
    wire [8:0] _32;
    reg [8:0] _447;
    wire [8:0] _33;
    wire [8:0] _433;
    wire [8:0] _434;
    wire [8:0] _451;
    wire [8:0] _34;
    wire [8:0] _528;
    wire _415;
    wire _409;
    reg _412;
    wire _406;
    wire _407;
    wire _408;
    wire _413;
    wire _455;
    wire _35;
    reg _454;
    wire _456;
    wire _461;
    wire _462;
    wire _36;
    reg _459;
    wire _37;
    wire _517;
    wire [3:0] _513;
    wire [3:0] _468;
    wire [3:0] _466;
    wire _95;
    wire _94;
    wire _96;
    wire [3:0] _467;
    wire [3:0] _469;
    wire _342;
    wire _343;
    wire [3:0] _470;
    wire [3:0] _472;
    wire [3:0] _38;
    reg [3:0] _465;
    wire [3:0] _39;
    wire _514;
    wire _515;
    wire [5:0] _491;
    wire [5:0] _482;
    wire _331;
    wire [5:0] _485;
    wire [5:0] _486;
    wire [5:0] _488;
    wire [5:0] _490;
    wire [5:0] _40;
    reg [5:0] _483;
    wire [5:0] _41;
    wire _492;
    wire _77;
    wire _70;
    wire _78;
    wire _328;
    wire _329;
    wire _493;
    wire _497;
    wire _476;
    reg _479;
    wire _473;
    wire _474;
    wire _475;
    wire _480;
    wire _498;
    wire _86;
    wire _323;
    reg _326;
    wire gnd;
    wire _319;
    wire [1:0] _315;
    wire [1:0] _314;
    wire _316;
    wire [1:0] _311;
    wire _312;
    wire _313;
    wire _317;
    wire _318;
    wire _320;
    wire _309;
    wire _308;
    wire _310;
    wire _322;
    wire _327;
    wire _499;
    wire _42;
    reg _496;
    wire _43;
    wire _516;
    wire _518;
    reg _519;
    wire _511;
    wire _510;
    wire _509;
    wire _508;
    wire _507;
    wire _506;
    wire _505;
    wire _504;
    wire [2:0] _72;
    reg _512;
    wire [9:0] _76;
    wire _502;
    wire _503;
    wire _520;
    wire _521;
    wire _239;
    wire _522;
    wire _501;
    wire _523;
    wire _44;
    wire [8:0] _529;
    wire [8:0] _530;
    wire [8:0] _45;
    reg [8:0] _526;
    wire [8:0] _46;
    wire [8:0] _435;
    wire [8:0] _436;
    wire [7:0] _537;
    wire [7:0] _47;
    wire [15:0] _67;
    wire [1:0] _68;
    wire _539;
    wire _561;
    wire _562;
    wire _48;
    wire _563;
    wire _566;
    wire _573;
    wire _49;
    reg _205;
    wire [7:0] _227;
    wire [7:0] _590;
    wire _574;
    wire _575;
    wire _576;
    wire _577;
    wire [7:0] _581;
    wire [7:0] _50;
    reg [7:0] _580;
    wire [7:0] _51;
    wire [7:0] _53;
    wire [15:0] _437;
    wire [7:0] _589;
    wire [7:0] _591;
    wire [7:0] _592;
    wire _384;
    wire _383;
    wire _385;
    wire _585;
    wire _54;
    reg _584;
    wire _55;
    wire _382;
    wire _428;
    reg _379;
    wire _380;
    wire _369;
    reg _373;
    reg _376;
    wire _381;
    wire _429;
    wire _430;
    wire _431;
    wire [7:0] _593;
    wire [7:0] _56;
    reg [7:0] _588;
    wire [7:0] _57;
    reg _606;
    wire _607;
    wire vdd;
    wire _59;
    wire _371;
    wire _61;
    wire [7:0] _63;
    wire _597;
    reg _600;
    reg _603;
    wire _608;
    wire _609;
    wire _64;
    reg _596;
    wire _65;
    wire [7:0] _610;
    assign _87 = 1'b0;
    assign _82 = 3'b001;
    assign _83 = _72 == _82;
    assign _81 = _48 & _80;
    assign _84 = _81 & _83;
    assign _90 = _84 ? vdd : _89;
    assign _73 = 3'b000;
    assign _74 = _72 == _73;
    assign _71 = _48 & _70;
    assign _75 = _71 & _74;
    assign _107 = _75 ? _106 : _90;
    assign _1 = _107;
    always @(posedge _61) begin
        if (_86)
            _89 <= _87;
        else
            _89 <= _1;
    end
    assign _114 = _72 == _73;
    assign _112 = _48 & _80;
    assign _115 = _112 & _114;
    assign _119 = _115 ? vdd : _118;
    assign _110 = _72 == _82;
    assign _108 = _48 & _70;
    assign _111 = _108 & _110;
    assign _120 = _111 ? _106 : _119;
    assign _2 = _120;
    always @(posedge _61) begin
        if (_86)
            _118 <= _87;
        else
            _118 <= _2;
    end
    assign _126 = 3'b011;
    assign _127 = _72 == _126;
    assign _125 = _48 & _80;
    assign _128 = _125 & _127;
    assign _132 = _128 ? vdd : _131;
    assign _122 = 3'b010;
    assign _123 = _72 == _122;
    assign _121 = _48 & _70;
    assign _124 = _121 & _123;
    assign _133 = _124 ? _106 : _132;
    assign _3 = _133;
    always @(posedge _61) begin
        if (_86)
            _131 <= _87;
        else
            _131 <= _3;
    end
    assign _140 = _72 == _122;
    assign _138 = _48 & _80;
    assign _141 = _138 & _140;
    assign _145 = _141 ? vdd : _144;
    assign _136 = _72 == _126;
    assign _134 = _48 & _70;
    assign _137 = _134 & _136;
    assign _146 = _137 ? _106 : _145;
    assign _4 = _146;
    always @(posedge _61) begin
        if (_86)
            _144 <= _87;
        else
            _144 <= _4;
    end
    assign _152 = 3'b101;
    assign _153 = _72 == _152;
    assign _151 = _48 & _80;
    assign _154 = _151 & _153;
    assign _158 = _154 ? vdd : _157;
    assign _148 = 3'b100;
    assign _149 = _72 == _148;
    assign _147 = _48 & _70;
    assign _150 = _147 & _149;
    assign _159 = _150 ? _106 : _158;
    assign _5 = _159;
    always @(posedge _61) begin
        if (_86)
            _157 <= _87;
        else
            _157 <= _5;
    end
    assign _166 = _72 == _148;
    assign _164 = _48 & _80;
    assign _167 = _164 & _166;
    assign _171 = _167 ? vdd : _170;
    assign _162 = _72 == _152;
    assign _160 = _48 & _70;
    assign _163 = _160 & _162;
    assign _172 = _163 ? _106 : _171;
    assign _6 = _172;
    always @(posedge _61) begin
        if (_86)
            _170 <= _87;
        else
            _170 <= _6;
    end
    assign _178 = 3'b111;
    assign _179 = _72 == _178;
    assign _177 = _48 & _80;
    assign _180 = _177 & _179;
    assign _184 = _180 ? vdd : _183;
    assign _174 = 3'b110;
    assign _175 = _72 == _174;
    assign _173 = _48 & _70;
    assign _176 = _173 & _175;
    assign _185 = _176 ? _106 : _184;
    assign _7 = _185;
    always @(posedge _61) begin
        if (_86)
            _183 <= _87;
        else
            _183 <= _7;
    end
    assign _104 = _91 & _103;
    assign _105 = ~ _104;
    assign _91 = _76[0:0];
    assign _92 = ~ _91;
    assign _106 = _78 ? _105 : _92;
    assign _192 = _72 == _174;
    assign _190 = _48 & _80;
    assign _193 = _190 & _192;
    assign _197 = _193 ? vdd : _196;
    assign _188 = _72 == _178;
    assign _186 = _48 & _70;
    assign _189 = _186 & _188;
    assign _198 = _189 ? _106 : _197;
    assign _8 = _198;
    always @(posedge _61) begin
        if (_86)
            _196 <= _87;
        else
            _196 <= _8;
    end
    assign _200 = { _196,
                    _183,
                    _170,
                    _157,
                    _144,
                    _131,
                    _118,
                    _89 };
    assign _199 = 8'b00000000;
    assign _201 = _65 ? _200 : _199;
    assign _228 = _65 ? _227 : _199;
    assign _237 = ~ _103;
    assign _235 = _72 == _82;
    assign _233 = _48 & _80;
    assign _236 = _233 & _235;
    assign _238 = _236 ? _237 : _226;
    assign _231 = _72 == _73;
    assign _229 = _48 & _70;
    assign _232 = _229 & _231;
    assign _241 = _232 ? _240 : _238;
    assign _11 = _241;
    always @(posedge _61) begin
        if (_86)
            _226 <= _87;
        else
            _226 <= _11;
    end
    assign _250 = ~ _103;
    assign _248 = _72 == _73;
    assign _246 = _48 & _80;
    assign _249 = _246 & _248;
    assign _251 = _249 ? _250 : _223;
    assign _244 = _72 == _82;
    assign _242 = _48 & _70;
    assign _245 = _242 & _244;
    assign _252 = _245 ? _240 : _251;
    assign _12 = _252;
    always @(posedge _61) begin
        if (_86)
            _223 <= _87;
        else
            _223 <= _12;
    end
    assign _261 = ~ _103;
    assign _259 = _72 == _126;
    assign _257 = _48 & _80;
    assign _260 = _257 & _259;
    assign _262 = _260 ? _261 : _220;
    assign _255 = _72 == _122;
    assign _253 = _48 & _70;
    assign _256 = _253 & _255;
    assign _263 = _256 ? _240 : _262;
    assign _13 = _263;
    always @(posedge _61) begin
        if (_86)
            _220 <= _87;
        else
            _220 <= _13;
    end
    assign _272 = ~ _103;
    assign _270 = _72 == _122;
    assign _268 = _48 & _80;
    assign _271 = _268 & _270;
    assign _273 = _271 ? _272 : _217;
    assign _266 = _72 == _126;
    assign _264 = _48 & _70;
    assign _267 = _264 & _266;
    assign _274 = _267 ? _240 : _273;
    assign _14 = _274;
    always @(posedge _61) begin
        if (_86)
            _217 <= _87;
        else
            _217 <= _14;
    end
    assign _283 = ~ _103;
    assign _281 = _72 == _152;
    assign _279 = _48 & _80;
    assign _282 = _279 & _281;
    assign _284 = _282 ? _283 : _214;
    assign _277 = _72 == _148;
    assign _275 = _48 & _70;
    assign _278 = _275 & _277;
    assign _285 = _278 ? _240 : _284;
    assign _15 = _285;
    always @(posedge _61) begin
        if (_86)
            _214 <= _87;
        else
            _214 <= _15;
    end
    assign _294 = ~ _103;
    assign _292 = _72 == _148;
    assign _290 = _48 & _80;
    assign _293 = _290 & _292;
    assign _295 = _293 ? _294 : _211;
    assign _288 = _72 == _152;
    assign _286 = _48 & _70;
    assign _289 = _286 & _288;
    assign _296 = _289 ? _240 : _295;
    assign _16 = _296;
    always @(posedge _61) begin
        if (_86)
            _211 <= _87;
        else
            _211 <= _16;
    end
    assign _305 = ~ _103;
    assign _303 = _72 == _178;
    assign _301 = _48 & _80;
    assign _304 = _301 & _303;
    assign _306 = _304 ? _305 : _208;
    assign _299 = _72 == _174;
    assign _297 = _48 & _70;
    assign _300 = _297 & _299;
    assign _307 = _300 ? _240 : _306;
    assign _17 = _307;
    always @(posedge _61) begin
        if (_86)
            _208 <= _87;
        else
            _208 <= _17;
    end
    assign _240 = _78 ? _103 : _239;
    assign _332 = 32'b00000000000000000000000000000000;
    assign _337 = 32'b00000000000000000000000000000001;
    assign _334 = _19[30:0];
    assign _336 = { _334,
                    _87 };
    assign _338 = _336 & _337;
    assign _339 = _329 ? _338 : _333;
    assign _341 = _327 ? _332 : _339;
    assign _18 = _341;
    always @(posedge _61) begin
        if (_331)
            _333 <= _332;
        else
            _333 <= _18;
    end
    assign _19 = _333;
    assign _100 = _19[0:0];
    assign _102 = _100 ^ _87;
    assign _348 = _98[7:1];
    assign _349 = { _87,
                    _348 };
    assign _350 = _343 ? _349 : _346;
    assign _20 = _350;
    always @(posedge _61) begin
        if (_331)
            _346 <= _199;
        else
            _346 <= _20;
    end
    assign _21 = _346;
    assign _98 = _96 ? _199 : _21;
    assign _99 = _98[0:0];
    assign _103 = _43 ? _102 : _99;
    assign _571 = ~ _103;
    assign _569 = _72 == _174;
    assign _79 = _76[2:2];
    assign _80 = _78 & _79;
    assign _567 = _48 & _80;
    assign _570 = _567 & _569;
    assign _572 = _570 ? _571 : _205;
    assign _565 = _72 == _178;
    assign _556 = ~ _554;
    assign _557 = _512 & _556;
    always @(posedge _61) begin
        if (_86)
            _554 <= _87;
        else
            _554 <= _512;
    end
    assign _551 = ~ _512;
    assign _555 = _551 & _554;
    assign _558 = _239 ? _557 : _555;
    always @(posedge _61) begin
        if (_86)
            _549 <= _73;
        else
            _549 <= _72;
    end
    assign _550 = _72 == _549;
    assign _559 = _550 & _558;
    assign _398 = ~ _353;
    assign _360 = 10'b0000000000;
    assign _366 = 10'b0000000001;
    assign _367 = _76 - _366;
    assign _363 = _359 - _366;
    assign _364 = _361 ? _359 : _363;
    assign _365 = _355 ? _364 : _359;
    assign _368 = _353 ? _367 : _365;
    assign _22 = _368;
    always @(posedge _61) begin
        if (_357)
            _359 <= _360;
        else
            _359 <= _22;
    end
    assign _23 = _359;
    assign _361 = _23 == _360;
    assign _389 = _385 ? _53 : _388;
    assign _24 = _389;
    always @(posedge _61) begin
        if (_371)
            _388 <= _199;
        else
            _388 <= _24;
    end
    assign _25 = _388;
    assign _393 = 8'b00000001;
    assign _394 = _392 - _393;
    assign _395 = _355 ? _25 : _394;
    assign _26 = _395;
    always @(posedge _61) begin
        if (_357)
            _392 <= _199;
        else
            _392 <= _26;
    end
    assign _27 = _392;
    assign _355 = _27 == _199;
    assign _357 = ~ _59;
    assign _404 = _399 ? _87 : _402;
    always @(posedge _61) begin
        if (_86)
            _353 <= _87;
        else
            _353 <= _48;
    end
    assign _405 = _353 ? vdd : _404;
    assign _28 = _405;
    always @(posedge _61) begin
        if (_357)
            _402 <= _87;
        else
            _402 <= _28;
    end
    assign _29 = _402;
    assign _396 = _29 & _355;
    assign _397 = _396 & _361;
    assign _399 = _397 & _398;
    assign _546 = _76 == _360;
    assign _560 = _546 ? _559 : _399;
    assign _424 = _48 & _423;
    assign _425 = ~ _424;
    assign _426 = _417 & _425;
    assign _427 = _413 ? gnd : _426;
    assign _30 = _427;
    always @(posedge _61) begin
        if (_415)
            _417 <= _87;
        else
            _417 <= _30;
    end
    assign _541 = ~ _417;
    assign _422 = _76[0:0];
    assign _419 = 2'b01;
    assign _420 = _314 == _419;
    assign _418 = _312 & _239;
    assign _421 = _418 & _420;
    assign _423 = _421 & _422;
    assign _542 = _423 & _541;
    assign _540 = _78 & _96;
    assign _543 = _540 | _542;
    assign _544 = ~ _543;
    assign _538 = 2'b00;
    assign _440 = 9'b000000000;
    assign _439 = 8'b11111111;
    assign _438 = _437[7:0];
    RM_IHPSG13_1P_512x8_c3_bm_bist
        mue0_instr_lo
        ( .A_CLK(_61),
          .A_MEN(vdd),
          .A_WEN(_431),
          .A_REN(vdd),
          .A_ADDR(_436),
          .A_DIN(_438),
          .A_BM(_439),
          .A_DLY(vdd),
          .A_BIST_CLK(_61),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_440),
          .A_BIST_DIN(_199),
          .A_BIST_BM(_199),
          .A_DOUT(_444[7:0]) );
    assign _31 = _444;
    assign _531 = _437[15:8];
    assign _448 = 9'b000000001;
    assign _449 = _447 + _448;
    assign _450 = _431 ? _449 : _447;
    assign _32 = _450;
    always @(posedge _61) begin
        if (_371)
            _447 <= _440;
        else
            _447 <= _32;
    end
    assign _33 = _447;
    assign _433 = _46 + _448;
    assign _434 = _44 ? _34 : _433;
    assign _451 = _76[8:0];
    assign _34 = _451;
    assign _528 = _526 + _448;
    assign _415 = ~ _59;
    assign _409 = _407 & _310;
    always @(posedge _61) begin
        if (_86)
            _412 <= _87;
        else
            _412 <= _409;
    end
    assign _406 = _76[0:0];
    assign _407 = _318 & _406;
    assign _408 = _310 ? gnd : _407;
    assign _413 = _408 | _412;
    assign _455 = _413 ? gnd : _454;
    assign _35 = _455;
    always @(posedge _61) begin
        if (_415)
            _454 <= _87;
        else
            _454 <= _35;
    end
    assign _456 = _328 & _96;
    assign _461 = _456 ? _87 : _459;
    assign _462 = _327 ? gnd : _461;
    assign _36 = _462;
    always @(posedge _61) begin
        if (_331)
            _459 <= _87;
        else
            _459 <= _36;
    end
    assign _37 = _459;
    assign _517 = ~ _37;
    assign _513 = 4'b0000;
    assign _468 = 4'b0001;
    assign _466 = 4'b1000;
    assign _95 = ~ _43;
    assign _94 = _39 == _513;
    assign _96 = _94 & _95;
    assign _467 = _96 ? _466 : _39;
    assign _469 = _467 - _468;
    assign _342 = ~ _43;
    assign _343 = _328 & _342;
    assign _470 = _343 ? _469 : _465;
    assign _472 = _327 ? _513 : _470;
    assign _38 = _472;
    always @(posedge _61) begin
        if (_331)
            _465 <= _513;
        else
            _465 <= _38;
    end
    assign _39 = _465;
    assign _514 = _39 == _513;
    assign _515 = ~ _514;
    assign _491 = 6'b000001;
    assign _482 = 6'b000000;
    assign _331 = ~ _59;
    assign _485 = _483 - _491;
    assign _486 = _329 ? _485 : _483;
    assign _488 = _480 ? _491 : _486;
    assign _490 = _327 ? _482 : _488;
    assign _40 = _490;
    always @(posedge _61) begin
        if (_331)
            _483 <= _482;
        else
            _483 <= _40;
    end
    assign _41 = _483;
    assign _492 = _41 == _491;
    assign _77 = _76[1:1];
    assign _70 = _68 == _419;
    assign _78 = _70 & _77;
    assign _328 = _48 & _78;
    assign _329 = _328 & _43;
    assign _493 = _329 & _492;
    assign _497 = _493 ? gnd : _496;
    assign _476 = _474 & _310;
    always @(posedge _61) begin
        if (_86)
            _479 <= _87;
        else
            _479 <= _476;
    end
    assign _473 = _76[4:4];
    assign _474 = _318 & _473;
    assign _475 = _310 ? gnd : _474;
    assign _480 = _475 | _479;
    assign _498 = _480 ? vdd : _497;
    assign _86 = ~ _59;
    assign _323 = _320 & _310;
    always @(posedge _61) begin
        if (_86)
            _326 <= _87;
        else
            _326 <= _323;
    end
    assign gnd = 1'b0;
    assign _319 = _76[3:3];
    assign _315 = 2'b11;
    assign _314 = _76[9:8];
    assign _316 = _314 == _315;
    assign _311 = 2'b10;
    assign _312 = _68 == _311;
    assign _313 = _312 & _239;
    assign _317 = _313 & _316;
    assign _318 = _48 & _317;
    assign _320 = _318 & _319;
    assign _309 = _76[6:6];
    assign _308 = _76[5:5];
    assign _310 = _308 | _309;
    assign _322 = _310 ? gnd : _320;
    assign _327 = _322 | _326;
    assign _499 = _327 ? gnd : _498;
    assign _42 = _499;
    always @(posedge _61) begin
        if (_331)
            _496 <= _87;
        else
            _496 <= _42;
    end
    assign _43 = _496;
    assign _516 = _43 | _515;
    assign _518 = _516 | _517;
    always @* begin
        case (_72)
        0:
            _519 <= _518;
        1:
            _519 <= _454;
        2:
            _519 <= gnd;
        3:
            _519 <= gnd;
        4:
            _519 <= gnd;
        5:
            _519 <= gnd;
        6:
            _519 <= gnd;
        default:
            _519 <= gnd;
        endcase
    end
    assign _511 = _63[7:7];
    assign _510 = _63[6:6];
    assign _509 = _63[5:5];
    assign _508 = _63[4:4];
    assign _507 = _63[3:3];
    assign _506 = _63[2:2];
    assign _505 = _63[1:1];
    assign _504 = _63[0:0];
    assign _72 = _67[13:11];
    always @* begin
        case (_72)
        0:
            _512 <= _504;
        1:
            _512 <= _505;
        2:
            _512 <= _506;
        3:
            _512 <= _507;
        4:
            _512 <= _508;
        5:
            _512 <= _509;
        6:
            _512 <= _510;
        default:
            _512 <= _511;
        endcase
    end
    assign _76 = _67[9:0];
    assign _502 = _76[9:9];
    assign _503 = _501 & _502;
    assign _520 = _503 ? _519 : _512;
    assign _521 = ~ _520;
    assign _239 = _67[10:10];
    assign _522 = _239 ? _520 : _521;
    assign _501 = _68 == _315;
    assign _523 = _501 & _522;
    assign _44 = _523;
    assign _529 = _44 ? _34 : _528;
    assign _530 = _48 ? _529 : _526;
    assign _45 = _530;
    always @(posedge _61) begin
        if (_86)
            _526 <= _440;
        else
            _526 <= _45;
    end
    assign _46 = _526;
    assign _435 = _48 ? _434 : _46;
    assign _436 = _431 ? _33 : _435;
    RM_IHPSG13_1P_512x8_c3_bm_bist
        mue0_instr_hi
        ( .A_CLK(_61),
          .A_MEN(vdd),
          .A_WEN(_431),
          .A_REN(vdd),
          .A_ADDR(_436),
          .A_DIN(_531),
          .A_BM(_439),
          .A_DLY(vdd),
          .A_BIST_CLK(_61),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_440),
          .A_BIST_DIN(_199),
          .A_BIST_BM(_199),
          .A_DOUT(_537[7:0]) );
    assign _47 = _537;
    assign _67 = { _47,
                   _31 };
    assign _68 = _67[15:14];
    assign _539 = _68 == _538;
    assign _561 = _539 ? _560 : _544;
    assign _562 = _65 & _561;
    assign _48 = _562;
    assign _563 = _48 & _70;
    assign _566 = _563 & _565;
    assign _573 = _566 ? _240 : _572;
    assign _49 = _573;
    always @(posedge _61) begin
        if (_86)
            _205 <= _87;
        else
            _205 <= _49;
    end
    assign _227 = { _205,
                    _208,
                    _211,
                    _214,
                    _217,
                    _220,
                    _223,
                    _226 };
    assign _590 = _437[7:0];
    assign _574 = ~ _428;
    assign _575 = _381 & _574;
    assign _576 = _575 & _382;
    assign _577 = _576 & _55;
    assign _581 = _577 ? _53 : _580;
    assign _50 = _581;
    always @(posedge _61) begin
        if (_371)
            _580 <= _199;
        else
            _580 <= _50;
    end
    assign _51 = _580;
    assign _53 = ui_in;
    assign _437 = { _53,
                    _51 };
    assign _589 = _437[15:8];
    assign _591 = _589 ^ _590;
    assign _592 = _588 ^ _591;
    assign _384 = ~ _55;
    assign _383 = _381 & _382;
    assign _385 = _383 & _384;
    assign _585 = _584 | _385;
    assign _54 = _585;
    always @(posedge _61) begin
        if (_371)
            _584 <= _87;
        else
            _584 <= _54;
    end
    assign _55 = _584;
    assign _382 = ~ _65;
    assign _428 = _63[1:1];
    always @(posedge _61) begin
        if (_371)
            _379 <= _87;
        else
            _379 <= _376;
    end
    assign _380 = ~ _379;
    assign _369 = _63[0:0];
    always @(posedge _61) begin
        if (_371)
            _373 <= _87;
        else
            _373 <= _369;
    end
    always @(posedge _61) begin
        if (_371)
            _376 <= _87;
        else
            _376 <= _373;
    end
    assign _381 = _376 & _380;
    assign _429 = _381 & _428;
    assign _430 = _429 & _382;
    assign _431 = _430 & _55;
    assign _593 = _431 ? _592 : _588;
    assign _56 = _593;
    always @(posedge _61) begin
        if (_371)
            _588 <= _199;
        else
            _588 <= _56;
    end
    assign _57 = _588;
    always @(posedge _61) begin
        if (_371)
            _606 <= _87;
        else
            _606 <= _603;
    end
    assign _607 = ~ _606;
    assign vdd = 1'b1;
    assign _59 = rst_n;
    assign _371 = ~ _59;
    assign _61 = clk;
    assign _63 = uio_in;
    assign _597 = _63[2:2];
    always @(posedge _61) begin
        if (_371)
            _600 <= _87;
        else
            _600 <= _597;
    end
    always @(posedge _61) begin
        if (_371)
            _603 <= _87;
        else
            _603 <= _600;
    end
    assign _608 = _603 & _607;
    assign _609 = _596 | _608;
    assign _64 = _609;
    always @(posedge _61) begin
        if (_371)
            _596 <= _87;
        else
            _596 <= _64;
    end
    assign _65 = _596;
    assign _610 = _65 ? _227 : _57;
    assign uo_out = _610;
    assign uio_out = _228;
    assign uio_oe = _201;

endmodule
