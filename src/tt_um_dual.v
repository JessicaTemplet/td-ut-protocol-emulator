module tt_um_dual (
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

    wire _225;
    wire _226;
    wire _222;
    wire _223;
    wire _219;
    wire _220;
    wire _216;
    wire _217;
    wire _213;
    wire _214;
    wire _210;
    wire _211;
    wire _207;
    wire _208;
    wire _105;
    wire _110;
    wire [2:0] _100;
    wire _101;
    wire _98;
    wire _102;
    wire _111;
    wire _1;
    reg _107;
    wire _119;
    wire [2:0] _113;
    wire _114;
    wire _112;
    wire _115;
    wire _120;
    wire _2;
    reg _118;
    wire _128;
    wire [2:0] _122;
    wire _123;
    wire _121;
    wire _124;
    wire _129;
    wire _3;
    reg _127;
    wire _137;
    wire [2:0] _131;
    wire _132;
    wire _130;
    wire _133;
    wire _138;
    wire _4;
    reg _136;
    wire _146;
    wire [2:0] _140;
    wire _141;
    wire _139;
    wire _142;
    wire _147;
    wire _5;
    reg _145;
    wire _155;
    wire [2:0] _149;
    wire _150;
    wire _148;
    wire _151;
    wire _156;
    wire _6;
    reg _154;
    wire _164;
    wire [2:0] _158;
    wire _159;
    wire _157;
    wire _160;
    wire _165;
    wire _7;
    reg _163;
    wire _173;
    wire [2:0] _167;
    wire _168;
    wire _166;
    wire _169;
    wire _174;
    wire _8;
    reg _172;
    wire [7:0] _203;
    wire _204;
    wire _205;
    wire [7:0] _227;
    wire [7:0] _175;
    wire [7:0] _228;
    wire [7:0] _305;
    wire _302;
    wire _301;
    wire _224;
    wire _303;
    wire _299;
    wire _298;
    wire _221;
    wire _300;
    wire _296;
    wire _295;
    wire _218;
    wire _297;
    wire _293;
    wire _292;
    wire _215;
    wire _294;
    wire _290;
    wire _289;
    wire _212;
    wire _291;
    wire _287;
    wire _286;
    wire _209;
    wire _288;
    wire _284;
    wire _283;
    wire _206;
    wire _285;
    wire _313;
    wire _310;
    wire _314;
    wire _316;
    wire _11;
    reg _279;
    wire _319;
    wire _317;
    wire _320;
    wire _321;
    wire _12;
    reg _276;
    wire _324;
    wire _322;
    wire _325;
    wire _326;
    wire _13;
    reg _273;
    wire _329;
    wire _327;
    wire _330;
    wire _331;
    wire _14;
    reg _270;
    wire _334;
    wire _332;
    wire _335;
    wire _336;
    wire _15;
    reg _267;
    wire _339;
    wire _337;
    wire _340;
    wire _341;
    wire _16;
    reg _264;
    wire _344;
    wire _342;
    wire _345;
    wire _346;
    wire _17;
    reg _261;
    wire _349;
    wire _347;
    wire _350;
    wire _351;
    wire _18;
    reg _258;
    wire [7:0] _280;
    wire _281;
    wire _354;
    wire _352;
    wire _355;
    wire _357;
    wire _19;
    reg _253;
    wire _360;
    wire _358;
    wire _361;
    wire _362;
    wire _20;
    reg _250;
    wire _365;
    wire _363;
    wire _366;
    wire _367;
    wire _21;
    reg _247;
    wire _370;
    wire _368;
    wire _371;
    wire _372;
    wire _22;
    reg _244;
    wire _375;
    wire _373;
    wire _376;
    wire _377;
    wire _23;
    reg _241;
    wire _380;
    wire _378;
    wire _381;
    wire _382;
    wire _24;
    reg _238;
    wire _385;
    wire _383;
    wire _386;
    wire _387;
    wire _25;
    reg _235;
    wire _390;
    wire [1:0] _96;
    wire _97;
    wire _388;
    wire _391;
    wire _392;
    wire _26;
    reg _232;
    wire [7:0] _254;
    wire _255;
    wire _399;
    wire _395;
    wire _393;
    wire _396;
    wire _400;
    wire _27;
    reg _200;
    wire _405;
    wire _403;
    wire _401;
    wire _404;
    wire _406;
    wire _28;
    reg _197;
    wire _411;
    wire _409;
    wire _407;
    wire _410;
    wire _412;
    wire _29;
    reg _194;
    wire _417;
    wire _415;
    wire _413;
    wire _416;
    wire _418;
    wire _30;
    reg _191;
    wire _423;
    wire _421;
    wire _419;
    wire _422;
    wire _424;
    wire _31;
    reg _188;
    wire _429;
    wire _427;
    wire _425;
    wire _428;
    wire _430;
    wire _32;
    reg _185;
    wire _435;
    wire _433;
    wire _431;
    wire _434;
    wire _436;
    wire _33;
    reg _182;
    wire _398;
    wire _755;
    wire _753;
    wire [8:0] _466;
    wire [7:0] _464;
    wire [7:0] _463;
    wire [7:0] _470;
    wire [7:0] _34;
    wire [7:0] _744;
    wire [8:0] _474;
    wire [8:0] _475;
    wire [8:0] _476;
    wire [8:0] _35;
    reg [8:0] _473;
    wire [8:0] _36;
    wire [8:0] _458;
    wire [8:0] _459;
    wire [9:0] _397;
    wire [8:0] _477;
    wire [8:0] _37;
    wire [8:0] _622;
    wire _612;
    wire _611;
    wire _610;
    wire _609;
    wire _608;
    wire _607;
    wire _606;
    wire _605;
    reg _613;
    wire _614;
    wire _615;
    wire [1:0] _603;
    wire _604;
    wire _616;
    wire _598;
    wire _597;
    wire _596;
    wire _595;
    wire _594;
    wire _593;
    wire _592;
    wire [15:0] _585;
    wire _177;
    wire _498;
    wire _499;
    wire [15:0] _528;
    wire [15:0] _38;
    reg [15:0] _503;
    wire [1:0] _529;
    wire _530;
    wire _531;
    wire [15:0] _535;
    wire [15:0] _39;
    reg [15:0] _534;
    wire _537;
    wire _538;
    wire [15:0] _542;
    wire [15:0] _40;
    reg [15:0] _541;
    wire [11:0] _544;
    wire [11:0] _550;
    wire [11:0] _551;
    wire [11:0] _546;
    wire _547;
    wire _548;
    wire _549;
    wire [11:0] _552;
    wire [11:0] _554;
    wire [11:0] _41;
    reg [11:0] _545;
    wire [11:0] _42;
    wire [15:0] _523;
    reg [15:0] _526;
    wire [6:0] _555;
    wire [7:0] _556;
    wire [7:0] _557;
    wire [7:0] _43;
    reg [7:0] _507;
    wire [6:0] _508;
    wire [7:0] _518;
    reg [7:0] _521;
    wire [15:0] _522;
    wire [15:0] _527;
    wire [1:0] _564;
    wire [1:0] _562;
    wire [1:0] _563;
    wire [1:0] _44;
    reg [1:0] _560;
    wire [1:0] _45;
    wire _565;
    wire _566;
    wire [15:0] _570;
    wire [15:0] _46;
    reg [15:0] _569;
    wire [1:0] _579;
    wire [1:0] _580;
    wire [1:0] _47;
    reg [1:0] _577;
    wire [1:0] _48;
    reg [15:0] _587;
    wire [15:0] _588;
    wire [15:0] _49;
    reg [15:0] _586;
    wire _591;
    wire [2:0] _311;
    reg _599;
    wire _600;
    wire _315;
    wire _601;
    wire _590;
    wire _602;
    wire _617;
    wire _50;
    wire [8:0] _623;
    wire [8:0] _624;
    wire [8:0] _51;
    reg [8:0] _620;
    wire [8:0] _52;
    wire _501;
    wire [2:0] _739;
    wire [2:0] _736;
    wire _730;
    wire _731;
    wire [2:0] _737;
    wire _573;
    wire _583;
    wire _53;
    wire _574;
    wire _728;
    wire _495;
    wire _488;
    reg _491;
    wire _721;
    wire _722;
    reg _719;
    wire _716;
    wire _720;
    wire _723;
    reg [2:0] _714;
    wire _715;
    wire _724;
    wire [9:0] _634;
    wire [9:0] _640;
    wire [9:0] _641;
    wire [9:0] _637;
    wire [9:0] _638;
    wire [9:0] _639;
    wire [9:0] _642;
    wire [9:0] _54;
    reg [9:0] _633;
    wire [9:0] _55;
    wire _635;
    wire [7:0] _649;
    wire [7:0] _56;
    reg [7:0] _648;
    wire [7:0] _57;
    wire [7:0] _653;
    wire [7:0] _654;
    wire [7:0] _655;
    wire [7:0] _58;
    reg [7:0] _652;
    wire [7:0] _59;
    wire _629;
    wire _631;
    wire _662;
    reg _627;
    wire _663;
    wire _60;
    reg _660;
    wire _61;
    wire _656;
    wire _657;
    wire _711;
    wire _725;
    wire _494;
    wire _62;
    wire _487;
    wire _109;
    wire _480;
    wire _479;
    wire _481;
    wire _706;
    wire _707;
    wire _708;
    wire _709;
    wire [7:0] _671;
    wire [7:0] _677;
    wire [7:0] _63;
    wire gnd;
    wire [7:0] _697;
    wire [8:0] _682;
    wire [8:0] _683;
    wire [8:0] _64;
    reg [8:0] _680;
    wire [8:0] _65;
    wire [8:0] _667;
    wire [8:0] _668;
    wire _104;
    wire [9:0] _108;
    wire [8:0] _684;
    wire [8:0] _66;
    wire [8:0] _694;
    wire _516;
    wire _515;
    wire _514;
    wire _513;
    wire _512;
    wire _511;
    wire _510;
    wire _509;
    wire [2:0] _99;
    reg _517;
    wire _687;
    wire _356;
    wire _688;
    wire _686;
    wire _689;
    wire _67;
    wire [8:0] _695;
    wire [8:0] _696;
    wire [8:0] _68;
    reg [8:0] _692;
    wire [8:0] _69;
    wire [8:0] _669;
    wire [8:0] _670;
    wire _664;
    wire _665;
    wire [7:0] _703;
    wire [7:0] _70;
    wire [15:0] _94;
    wire [1:0] _95;
    wire _705;
    wire _726;
    wire _727;
    wire _71;
    wire _482;
    wire _483;
    reg _486;
    wire _492;
    wire _496;
    wire _729;
    wire [2:0] _740;
    wire [2:0] _72;
    reg [2:0] _734;
    wire [2:0] _73;
    wire _572;
    wire _741;
    wire _582;
    wire _742;
    wire _743;
    wire _74;
    wire [8:0] _460;
    wire [8:0] _461;
    wire _455;
    wire _456;
    wire [7:0] _750;
    wire [7:0] _75;
    wire [15:0] _306;
    wire [1:0] _307;
    wire _309;
    wire _751;
    wire _754;
    wire _756;
    wire _76;
    reg _179;
    wire [7:0] _201;
    wire _202;
    wire _282;
    wire [7:0] _304;
    wire [7:0] _773;
    wire _757;
    wire _758;
    wire _759;
    wire _760;
    wire [7:0] _764;
    wire [7:0] _77;
    reg [7:0] _763;
    wire [7:0] _78;
    wire [7:0] _80;
    wire [15:0] _462;
    wire [7:0] _772;
    wire [7:0] _774;
    wire [7:0] _775;
    wire _644;
    wire _643;
    wire _645;
    wire _768;
    wire _81;
    reg _767;
    wire _82;
    wire _452;
    wire _450;
    reg _447;
    wire _448;
    wire _437;
    reg _441;
    reg _444;
    wire _449;
    wire _451;
    wire _453;
    wire _454;
    wire [7:0] _776;
    wire [7:0] _83;
    reg [7:0] _771;
    wire [7:0] _84;
    reg _789;
    wire _790;
    wire vdd;
    wire _86;
    wire _439;
    wire _88;
    wire [7:0] _90;
    wire _780;
    reg _783;
    reg _786;
    wire _791;
    wire _792;
    wire _91;
    reg _779;
    wire _92;
    wire [7:0] _793;
    assign _225 = _203[0:0];
    assign _226 = _224 | _225;
    assign _222 = _203[1:1];
    assign _223 = _221 | _222;
    assign _219 = _203[2:2];
    assign _220 = _218 | _219;
    assign _216 = _203[3:3];
    assign _217 = _215 | _216;
    assign _213 = _203[4:4];
    assign _214 = _212 | _213;
    assign _210 = _203[5:5];
    assign _211 = _209 | _210;
    assign _207 = _203[6:6];
    assign _208 = _206 | _207;
    assign _105 = 1'b0;
    assign _110 = ~ _109;
    assign _100 = 3'b000;
    assign _101 = _99 == _100;
    assign _98 = _92 & _97;
    assign _102 = _98 & _101;
    assign _111 = _102 ? _110 : _107;
    assign _1 = _111;
    always @(posedge _88) begin
        if (_104)
            _107 <= _105;
        else
            _107 <= _1;
    end
    assign _119 = ~ _109;
    assign _113 = 3'b001;
    assign _114 = _99 == _113;
    assign _112 = _92 & _97;
    assign _115 = _112 & _114;
    assign _120 = _115 ? _119 : _118;
    assign _2 = _120;
    always @(posedge _88) begin
        if (_104)
            _118 <= _105;
        else
            _118 <= _2;
    end
    assign _128 = ~ _109;
    assign _122 = 3'b010;
    assign _123 = _99 == _122;
    assign _121 = _92 & _97;
    assign _124 = _121 & _123;
    assign _129 = _124 ? _128 : _127;
    assign _3 = _129;
    always @(posedge _88) begin
        if (_104)
            _127 <= _105;
        else
            _127 <= _3;
    end
    assign _137 = ~ _109;
    assign _131 = 3'b011;
    assign _132 = _99 == _131;
    assign _130 = _92 & _97;
    assign _133 = _130 & _132;
    assign _138 = _133 ? _137 : _136;
    assign _4 = _138;
    always @(posedge _88) begin
        if (_104)
            _136 <= _105;
        else
            _136 <= _4;
    end
    assign _146 = ~ _109;
    assign _140 = 3'b100;
    assign _141 = _99 == _140;
    assign _139 = _92 & _97;
    assign _142 = _139 & _141;
    assign _147 = _142 ? _146 : _145;
    assign _5 = _147;
    always @(posedge _88) begin
        if (_104)
            _145 <= _105;
        else
            _145 <= _5;
    end
    assign _155 = ~ _109;
    assign _149 = 3'b101;
    assign _150 = _99 == _149;
    assign _148 = _92 & _97;
    assign _151 = _148 & _150;
    assign _156 = _151 ? _155 : _154;
    assign _6 = _156;
    always @(posedge _88) begin
        if (_104)
            _154 <= _105;
        else
            _154 <= _6;
    end
    assign _164 = ~ _109;
    assign _158 = 3'b110;
    assign _159 = _99 == _158;
    assign _157 = _92 & _97;
    assign _160 = _157 & _159;
    assign _165 = _160 ? _164 : _163;
    assign _7 = _165;
    always @(posedge _88) begin
        if (_104)
            _163 <= _105;
        else
            _163 <= _7;
    end
    assign _173 = ~ _109;
    assign _167 = 3'b111;
    assign _168 = _99 == _167;
    assign _166 = _92 & _97;
    assign _169 = _166 & _168;
    assign _174 = _169 ? _173 : _172;
    assign _8 = _174;
    always @(posedge _88) begin
        if (_104)
            _172 <= _105;
        else
            _172 <= _8;
    end
    assign _203 = { _172,
                    _163,
                    _154,
                    _145,
                    _136,
                    _127,
                    _118,
                    _107 };
    assign _204 = _203[7:7];
    assign _205 = _202 | _204;
    assign _227 = { _205,
                    _208,
                    _211,
                    _214,
                    _217,
                    _220,
                    _223,
                    _226 };
    assign _175 = 8'b00000000;
    assign _228 = _92 ? _227 : _175;
    assign _305 = _92 ? _304 : _175;
    assign _302 = _280[0:0];
    assign _301 = _254[0:0];
    assign _224 = _201[0:0];
    assign _303 = _224 ? _302 : _301;
    assign _299 = _280[1:1];
    assign _298 = _254[1:1];
    assign _221 = _201[1:1];
    assign _300 = _221 ? _299 : _298;
    assign _296 = _280[2:2];
    assign _295 = _254[2:2];
    assign _218 = _201[2:2];
    assign _297 = _218 ? _296 : _295;
    assign _293 = _280[3:3];
    assign _292 = _254[3:3];
    assign _215 = _201[3:3];
    assign _294 = _215 ? _293 : _292;
    assign _290 = _280[4:4];
    assign _289 = _254[4:4];
    assign _212 = _201[4:4];
    assign _291 = _212 ? _290 : _289;
    assign _287 = _280[5:5];
    assign _286 = _254[5:5];
    assign _209 = _201[5:5];
    assign _288 = _209 ? _287 : _286;
    assign _284 = _280[6:6];
    assign _283 = _254[6:6];
    assign _206 = _201[6:6];
    assign _285 = _206 ? _284 : _283;
    assign _313 = _311 == _100;
    assign _310 = _92 & _309;
    assign _314 = _310 & _313;
    assign _316 = _314 ? _315 : _279;
    assign _11 = _316;
    always @(posedge _88) begin
        if (_177)
            _279 <= _105;
        else
            _279 <= _11;
    end
    assign _319 = _311 == _113;
    assign _317 = _92 & _309;
    assign _320 = _317 & _319;
    assign _321 = _320 ? _315 : _276;
    assign _12 = _321;
    always @(posedge _88) begin
        if (_177)
            _276 <= _105;
        else
            _276 <= _12;
    end
    assign _324 = _311 == _122;
    assign _322 = _92 & _309;
    assign _325 = _322 & _324;
    assign _326 = _325 ? _315 : _273;
    assign _13 = _326;
    always @(posedge _88) begin
        if (_177)
            _273 <= _105;
        else
            _273 <= _13;
    end
    assign _329 = _311 == _131;
    assign _327 = _92 & _309;
    assign _330 = _327 & _329;
    assign _331 = _330 ? _315 : _270;
    assign _14 = _331;
    always @(posedge _88) begin
        if (_177)
            _270 <= _105;
        else
            _270 <= _14;
    end
    assign _334 = _311 == _140;
    assign _332 = _92 & _309;
    assign _335 = _332 & _334;
    assign _336 = _335 ? _315 : _267;
    assign _15 = _336;
    always @(posedge _88) begin
        if (_177)
            _267 <= _105;
        else
            _267 <= _15;
    end
    assign _339 = _311 == _149;
    assign _337 = _92 & _309;
    assign _340 = _337 & _339;
    assign _341 = _340 ? _315 : _264;
    assign _16 = _341;
    always @(posedge _88) begin
        if (_177)
            _264 <= _105;
        else
            _264 <= _16;
    end
    assign _344 = _311 == _158;
    assign _342 = _92 & _309;
    assign _345 = _342 & _344;
    assign _346 = _345 ? _315 : _261;
    assign _17 = _346;
    always @(posedge _88) begin
        if (_177)
            _261 <= _105;
        else
            _261 <= _17;
    end
    assign _349 = _311 == _167;
    assign _347 = _92 & _309;
    assign _350 = _347 & _349;
    assign _351 = _350 ? _315 : _258;
    assign _18 = _351;
    always @(posedge _88) begin
        if (_177)
            _258 <= _105;
        else
            _258 <= _18;
    end
    assign _280 = { _258,
                    _261,
                    _264,
                    _267,
                    _270,
                    _273,
                    _276,
                    _279 };
    assign _281 = _280[7:7];
    assign _354 = _99 == _100;
    assign _352 = _92 & _97;
    assign _355 = _352 & _354;
    assign _357 = _355 ? _356 : _253;
    assign _19 = _357;
    always @(posedge _88) begin
        if (_104)
            _253 <= _105;
        else
            _253 <= _19;
    end
    assign _360 = _99 == _113;
    assign _358 = _92 & _97;
    assign _361 = _358 & _360;
    assign _362 = _361 ? _356 : _250;
    assign _20 = _362;
    always @(posedge _88) begin
        if (_104)
            _250 <= _105;
        else
            _250 <= _20;
    end
    assign _365 = _99 == _122;
    assign _363 = _92 & _97;
    assign _366 = _363 & _365;
    assign _367 = _366 ? _356 : _247;
    assign _21 = _367;
    always @(posedge _88) begin
        if (_104)
            _247 <= _105;
        else
            _247 <= _21;
    end
    assign _370 = _99 == _131;
    assign _368 = _92 & _97;
    assign _371 = _368 & _370;
    assign _372 = _371 ? _356 : _244;
    assign _22 = _372;
    always @(posedge _88) begin
        if (_104)
            _244 <= _105;
        else
            _244 <= _22;
    end
    assign _375 = _99 == _140;
    assign _373 = _92 & _97;
    assign _376 = _373 & _375;
    assign _377 = _376 ? _356 : _241;
    assign _23 = _377;
    always @(posedge _88) begin
        if (_104)
            _241 <= _105;
        else
            _241 <= _23;
    end
    assign _380 = _99 == _149;
    assign _378 = _92 & _97;
    assign _381 = _378 & _380;
    assign _382 = _381 ? _356 : _238;
    assign _24 = _382;
    always @(posedge _88) begin
        if (_104)
            _238 <= _105;
        else
            _238 <= _24;
    end
    assign _385 = _99 == _158;
    assign _383 = _92 & _97;
    assign _386 = _383 & _385;
    assign _387 = _386 ? _356 : _235;
    assign _25 = _387;
    always @(posedge _88) begin
        if (_104)
            _235 <= _105;
        else
            _235 <= _25;
    end
    assign _390 = _99 == _167;
    assign _96 = 2'b01;
    assign _97 = _95 == _96;
    assign _388 = _92 & _97;
    assign _391 = _388 & _390;
    assign _392 = _391 ? _356 : _232;
    assign _26 = _392;
    always @(posedge _88) begin
        if (_104)
            _232 <= _105;
        else
            _232 <= _26;
    end
    assign _254 = { _232,
                    _235,
                    _238,
                    _241,
                    _244,
                    _247,
                    _250,
                    _253 };
    assign _255 = _254[7:7];
    assign _399 = ~ _398;
    assign _395 = _311 == _100;
    assign _393 = _92 & _309;
    assign _396 = _393 & _395;
    assign _400 = _396 ? _399 : _200;
    assign _27 = _400;
    always @(posedge _88) begin
        if (_177)
            _200 <= _105;
        else
            _200 <= _27;
    end
    assign _405 = ~ _398;
    assign _403 = _311 == _113;
    assign _401 = _92 & _309;
    assign _404 = _401 & _403;
    assign _406 = _404 ? _405 : _197;
    assign _28 = _406;
    always @(posedge _88) begin
        if (_177)
            _197 <= _105;
        else
            _197 <= _28;
    end
    assign _411 = ~ _398;
    assign _409 = _311 == _122;
    assign _407 = _92 & _309;
    assign _410 = _407 & _409;
    assign _412 = _410 ? _411 : _194;
    assign _29 = _412;
    always @(posedge _88) begin
        if (_177)
            _194 <= _105;
        else
            _194 <= _29;
    end
    assign _417 = ~ _398;
    assign _415 = _311 == _131;
    assign _413 = _92 & _309;
    assign _416 = _413 & _415;
    assign _418 = _416 ? _417 : _191;
    assign _30 = _418;
    always @(posedge _88) begin
        if (_177)
            _191 <= _105;
        else
            _191 <= _30;
    end
    assign _423 = ~ _398;
    assign _421 = _311 == _140;
    assign _419 = _92 & _309;
    assign _422 = _419 & _421;
    assign _424 = _422 ? _423 : _188;
    assign _31 = _424;
    always @(posedge _88) begin
        if (_177)
            _188 <= _105;
        else
            _188 <= _31;
    end
    assign _429 = ~ _398;
    assign _427 = _311 == _149;
    assign _425 = _92 & _309;
    assign _428 = _425 & _427;
    assign _430 = _428 ? _429 : _185;
    assign _32 = _430;
    always @(posedge _88) begin
        if (_177)
            _185 <= _105;
        else
            _185 <= _32;
    end
    assign _435 = ~ _398;
    assign _433 = _311 == _158;
    assign _431 = _92 & _309;
    assign _434 = _431 & _433;
    assign _436 = _434 ? _435 : _182;
    assign _33 = _436;
    always @(posedge _88) begin
        if (_177)
            _182 <= _105;
        else
            _182 <= _33;
    end
    assign _398 = _397[0:0];
    assign _755 = ~ _398;
    assign _753 = _311 == _167;
    assign _466 = 9'b000000000;
    assign _464 = 8'b11111111;
    assign _463 = _462[7:0];
    RM_IHPSG13_1P_512x8_c3_bm_bist
        mue1_instr_lo
        ( .A_CLK(_88),
          .A_MEN(vdd),
          .A_WEN(_456),
          .A_REN(vdd),
          .A_ADDR(_461),
          .A_DIN(_463),
          .A_BM(_464),
          .A_DLY(vdd),
          .A_BIST_CLK(_88),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_466),
          .A_BIST_DIN(_175),
          .A_BIST_BM(_175),
          .A_DOUT(_470[7:0]) );
    assign _34 = _470;
    assign _744 = _462[15:8];
    assign _474 = 9'b000000001;
    assign _475 = _473 + _474;
    assign _476 = _456 ? _475 : _473;
    assign _35 = _476;
    always @(posedge _88) begin
        if (_439)
            _473 <= _466;
        else
            _473 <= _35;
    end
    assign _36 = _473;
    assign _458 = _52 + _474;
    assign _459 = _50 ? _37 : _458;
    assign _397 = _306[9:0];
    assign _477 = _397[8:0];
    assign _37 = _477;
    assign _622 = _620 + _474;
    assign _612 = _90[7:7];
    assign _611 = _90[6:6];
    assign _610 = _90[5:5];
    assign _609 = _90[4:4];
    assign _608 = _90[3:3];
    assign _607 = _90[2:2];
    assign _606 = _90[1:1];
    assign _605 = _90[0:0];
    always @* begin
        case (_311)
        0:
            _613 <= _605;
        1:
            _613 <= _606;
        2:
            _613 <= _607;
        3:
            _613 <= _608;
        4:
            _613 <= _609;
        5:
            _613 <= _610;
        6:
            _613 <= _611;
        default:
            _613 <= _612;
        endcase
    end
    assign _614 = ~ _613;
    assign _615 = _315 ? _613 : _614;
    assign _603 = 2'b11;
    assign _604 = _307 == _603;
    assign _616 = _604 & _615;
    assign _598 = _586[7:7];
    assign _597 = _586[6:6];
    assign _596 = _586[5:5];
    assign _595 = _586[4:4];
    assign _594 = _586[3:3];
    assign _593 = _586[2:2];
    assign _592 = _586[1:1];
    assign _585 = 16'b0000000000000000;
    assign _177 = ~ _86;
    assign _498 = _45 == _603;
    assign _499 = _496 & _498;
    assign _528 = _499 ? _527 : _503;
    assign _38 = _528;
    always @(posedge _88) begin
        if (_501)
            _503 <= _585;
        else
            _503 <= _38;
    end
    assign _529 = 2'b10;
    assign _530 = _45 == _529;
    assign _531 = _496 & _530;
    assign _535 = _531 ? _527 : _534;
    assign _39 = _535;
    always @(posedge _88) begin
        if (_501)
            _534 <= _585;
        else
            _534 <= _39;
    end
    assign _537 = _45 == _96;
    assign _538 = _496 & _537;
    assign _542 = _538 ? _527 : _541;
    assign _40 = _542;
    always @(posedge _88) begin
        if (_501)
            _541 <= _585;
        else
            _541 <= _40;
    end
    assign _544 = 12'b000000000000;
    assign _550 = 12'b000000000001;
    assign _551 = _545 + _550;
    assign _546 = 12'b111111111111;
    assign _547 = _545 == _546;
    assign _548 = ~ _547;
    assign _549 = _92 & _548;
    assign _552 = _549 ? _551 : _545;
    assign _554 = _488 ? _544 : _552;
    assign _41 = _554;
    always @(posedge _88) begin
        if (_104)
            _545 <= _544;
        else
            _545 <= _41;
    end
    assign _42 = _545;
    assign _523 = { _99,
                    _517,
                    _42 };
    always @(posedge _88) begin
        if (_104)
            _526 <= _585;
        else
            _526 <= _523;
    end
    assign _555 = _507[6:0];
    assign _556 = { _555,
                    _517 };
    assign _557 = _482 ? _556 : _507;
    assign _43 = _557;
    always @(posedge _88) begin
        if (_104)
            _507 <= _175;
        else
            _507 <= _43;
    end
    assign _508 = _507[6:0];
    assign _518 = { _508,
                    _517 };
    always @(posedge _88) begin
        if (_104)
            _521 <= _175;
        else
            _521 <= _518;
    end
    assign _522 = { _175,
                    _521 };
    assign _527 = _491 ? _526 : _522;
    assign _564 = 2'b00;
    assign _562 = _560 + _96;
    assign _563 = _496 ? _562 : _560;
    assign _44 = _563;
    always @(posedge _88) begin
        if (_501)
            _560 <= _564;
        else
            _560 <= _44;
    end
    assign _45 = _560;
    assign _565 = _45 == _564;
    assign _566 = _496 & _565;
    assign _570 = _566 ? _527 : _569;
    assign _46 = _570;
    always @(posedge _88) begin
        if (_501)
            _569 <= _585;
        else
            _569 <= _46;
    end
    assign _579 = _577 + _96;
    assign _580 = _574 ? _579 : _577;
    assign _47 = _580;
    always @(posedge _88) begin
        if (_501)
            _577 <= _564;
        else
            _577 <= _47;
    end
    assign _48 = _577;
    always @* begin
        case (_48)
        0:
            _587 <= _569;
        1:
            _587 <= _541;
        2:
            _587 <= _534;
        default:
            _587 <= _503;
        endcase
    end
    assign _588 = _583 ? _587 : _586;
    assign _49 = _588;
    always @(posedge _88) begin
        if (_177)
            _586 <= _585;
        else
            _586 <= _49;
    end
    assign _591 = _586[0:0];
    assign _311 = _306[13:11];
    always @* begin
        case (_311)
        0:
            _599 <= _591;
        1:
            _599 <= _592;
        2:
            _599 <= _593;
        3:
            _599 <= _594;
        4:
            _599 <= _595;
        5:
            _599 <= _596;
        6:
            _599 <= _597;
        default:
            _599 <= _598;
        endcase
    end
    assign _600 = ~ _599;
    assign _315 = _306[10:10];
    assign _601 = _315 ? _599 : _600;
    assign _590 = _307 == _529;
    assign _602 = _590 & _601;
    assign _617 = _602 | _616;
    assign _50 = _617;
    assign _623 = _50 ? _37 : _622;
    assign _624 = _74 ? _623 : _620;
    assign _51 = _624;
    always @(posedge _88) begin
        if (_177)
            _620 <= _466;
        else
            _620 <= _51;
    end
    assign _52 = _620;
    assign _501 = ~ _86;
    assign _739 = _734 + _113;
    assign _736 = _734 - _113;
    assign _730 = ~ _496;
    assign _731 = _574 & _730;
    assign _737 = _731 ? _736 : _734;
    assign _573 = ~ _572;
    assign _583 = _74 & _582;
    assign _53 = _583;
    assign _574 = _53 & _573;
    assign _728 = ~ _574;
    assign _495 = ~ _494;
    assign _488 = _71 & _487;
    always @(posedge _88) begin
        if (_104)
            _491 <= _105;
        else
            _491 <= _488;
    end
    assign _721 = ~ _719;
    assign _722 = _517 & _721;
    always @(posedge _88) begin
        if (_104)
            _719 <= _105;
        else
            _719 <= _517;
    end
    assign _716 = ~ _517;
    assign _720 = _716 & _719;
    assign _723 = _356 ? _722 : _720;
    always @(posedge _88) begin
        if (_104)
            _714 <= _100;
        else
            _714 <= _99;
    end
    assign _715 = _99 == _714;
    assign _724 = _715 & _723;
    assign _634 = 10'b0000000000;
    assign _640 = 10'b0000000001;
    assign _641 = _108 - _640;
    assign _637 = _633 - _640;
    assign _638 = _635 ? _633 : _637;
    assign _639 = _629 ? _638 : _633;
    assign _642 = _627 ? _641 : _639;
    assign _54 = _642;
    always @(posedge _88) begin
        if (_631)
            _633 <= _634;
        else
            _633 <= _54;
    end
    assign _55 = _633;
    assign _635 = _55 == _634;
    assign _649 = _645 ? _80 : _648;
    assign _56 = _649;
    always @(posedge _88) begin
        if (_439)
            _648 <= _175;
        else
            _648 <= _56;
    end
    assign _57 = _648;
    assign _653 = 8'b00000001;
    assign _654 = _652 - _653;
    assign _655 = _629 ? _57 : _654;
    assign _58 = _655;
    always @(posedge _88) begin
        if (_631)
            _652 <= _175;
        else
            _652 <= _58;
    end
    assign _59 = _652;
    assign _629 = _59 == _175;
    assign _631 = ~ _86;
    assign _662 = _657 ? _105 : _660;
    always @(posedge _88) begin
        if (_104)
            _627 <= _105;
        else
            _627 <= _71;
    end
    assign _663 = _627 ? vdd : _662;
    assign _60 = _663;
    always @(posedge _88) begin
        if (_631)
            _660 <= _105;
        else
            _660 <= _60;
    end
    assign _61 = _660;
    assign _656 = _61 & _629;
    assign _657 = _656 & _635;
    assign _711 = _108 == _634;
    assign _725 = _711 ? _724 : _657;
    assign _494 = _73 == _140;
    assign _62 = _494;
    assign _487 = _479 & _356;
    assign _109 = _108[0:0];
    assign _480 = ~ _356;
    assign _479 = _95 == _529;
    assign _481 = _479 & _480;
    assign _706 = _481 & _109;
    assign _707 = _706 | _487;
    assign _708 = _707 & _62;
    assign _709 = ~ _708;
    assign _671 = _462[7:0];
    RM_IHPSG13_1P_512x8_c3_bm_bist
        mue0_instr_lo
        ( .A_CLK(_88),
          .A_MEN(vdd),
          .A_WEN(_665),
          .A_REN(vdd),
          .A_ADDR(_670),
          .A_DIN(_671),
          .A_BM(_464),
          .A_DLY(vdd),
          .A_BIST_CLK(_88),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_466),
          .A_BIST_DIN(_175),
          .A_BIST_BM(_175),
          .A_DOUT(_677[7:0]) );
    assign _63 = _677;
    assign gnd = 1'b0;
    assign _697 = _462[15:8];
    assign _682 = _680 + _474;
    assign _683 = _665 ? _682 : _680;
    assign _64 = _683;
    always @(posedge _88) begin
        if (_439)
            _680 <= _466;
        else
            _680 <= _64;
    end
    assign _65 = _680;
    assign _667 = _69 + _474;
    assign _668 = _67 ? _66 : _667;
    assign _104 = ~ _86;
    assign _108 = _94[9:0];
    assign _684 = _108[8:0];
    assign _66 = _684;
    assign _694 = _692 + _474;
    assign _516 = _90[7:7];
    assign _515 = _90[6:6];
    assign _514 = _90[5:5];
    assign _513 = _90[4:4];
    assign _512 = _90[3:3];
    assign _511 = _90[2:2];
    assign _510 = _90[1:1];
    assign _509 = _90[0:0];
    assign _99 = _94[13:11];
    always @* begin
        case (_99)
        0:
            _517 <= _509;
        1:
            _517 <= _510;
        2:
            _517 <= _511;
        3:
            _517 <= _512;
        4:
            _517 <= _513;
        5:
            _517 <= _514;
        6:
            _517 <= _515;
        default:
            _517 <= _516;
        endcase
    end
    assign _687 = ~ _517;
    assign _356 = _94[10:10];
    assign _688 = _356 ? _517 : _687;
    assign _686 = _95 == _603;
    assign _689 = _686 & _688;
    assign _67 = _689;
    assign _695 = _67 ? _66 : _694;
    assign _696 = _71 ? _695 : _692;
    assign _68 = _696;
    always @(posedge _88) begin
        if (_104)
            _692 <= _466;
        else
            _692 <= _68;
    end
    assign _69 = _692;
    assign _669 = _71 ? _668 : _69;
    assign _670 = _665 ? _65 : _669;
    assign _664 = ~ _455;
    assign _665 = _454 & _664;
    RM_IHPSG13_1P_512x8_c3_bm_bist
        mue0_instr_hi
        ( .A_CLK(_88),
          .A_MEN(vdd),
          .A_WEN(_665),
          .A_REN(vdd),
          .A_ADDR(_670),
          .A_DIN(_697),
          .A_BM(_464),
          .A_DLY(vdd),
          .A_BIST_CLK(_88),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_466),
          .A_BIST_DIN(_175),
          .A_BIST_BM(_175),
          .A_DOUT(_703[7:0]) );
    assign _70 = _703;
    assign _94 = { _70,
                   _63 };
    assign _95 = _94[15:14];
    assign _705 = _95 == _564;
    assign _726 = _705 ? _725 : _709;
    assign _727 = _92 & _726;
    assign _71 = _727;
    assign _482 = _71 & _481;
    assign _483 = _482 & _109;
    always @(posedge _88) begin
        if (_104)
            _486 <= _105;
        else
            _486 <= _483;
    end
    assign _492 = _486 | _491;
    assign _496 = _492 & _495;
    assign _729 = _496 & _728;
    assign _740 = _729 ? _739 : _737;
    assign _72 = _740;
    always @(posedge _88) begin
        if (_501)
            _734 <= _100;
        else
            _734 <= _72;
    end
    assign _73 = _734;
    assign _572 = _73 == _100;
    assign _741 = ~ _572;
    assign _582 = _307 == _564;
    assign _742 = _582 ? _741 : vdd;
    assign _743 = _92 & _742;
    assign _74 = _743;
    assign _460 = _74 ? _459 : _52;
    assign _461 = _456 ? _36 : _460;
    assign _455 = _90[3:3];
    assign _456 = _454 & _455;
    RM_IHPSG13_1P_512x8_c3_bm_bist
        mue1_instr_hi
        ( .A_CLK(_88),
          .A_MEN(vdd),
          .A_WEN(_456),
          .A_REN(vdd),
          .A_ADDR(_461),
          .A_DIN(_744),
          .A_BM(_464),
          .A_DLY(vdd),
          .A_BIST_CLK(_88),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_466),
          .A_BIST_DIN(_175),
          .A_BIST_BM(_175),
          .A_DOUT(_750[7:0]) );
    assign _75 = _750;
    assign _306 = { _75,
                    _34 };
    assign _307 = _306[15:14];
    assign _309 = _307 == _96;
    assign _751 = _92 & _309;
    assign _754 = _751 & _753;
    assign _756 = _754 ? _755 : _179;
    assign _76 = _756;
    always @(posedge _88) begin
        if (_177)
            _179 <= _105;
        else
            _179 <= _76;
    end
    assign _201 = { _179,
                    _182,
                    _185,
                    _188,
                    _191,
                    _194,
                    _197,
                    _200 };
    assign _202 = _201[7:7];
    assign _282 = _202 ? _281 : _255;
    assign _304 = { _282,
                    _285,
                    _288,
                    _291,
                    _294,
                    _297,
                    _300,
                    _303 };
    assign _773 = _462[7:0];
    assign _757 = ~ _450;
    assign _758 = _449 & _757;
    assign _759 = _758 & _452;
    assign _760 = _759 & _82;
    assign _764 = _760 ? _80 : _763;
    assign _77 = _764;
    always @(posedge _88) begin
        if (_439)
            _763 <= _175;
        else
            _763 <= _77;
    end
    assign _78 = _763;
    assign _80 = ui_in;
    assign _462 = { _80,
                    _78 };
    assign _772 = _462[15:8];
    assign _774 = _772 ^ _773;
    assign _775 = _771 ^ _774;
    assign _644 = ~ _82;
    assign _643 = _449 & _452;
    assign _645 = _643 & _644;
    assign _768 = _767 | _645;
    assign _81 = _768;
    always @(posedge _88) begin
        if (_439)
            _767 <= _105;
        else
            _767 <= _81;
    end
    assign _82 = _767;
    assign _452 = ~ _92;
    assign _450 = _90[1:1];
    always @(posedge _88) begin
        if (_439)
            _447 <= _105;
        else
            _447 <= _444;
    end
    assign _448 = ~ _447;
    assign _437 = _90[0:0];
    always @(posedge _88) begin
        if (_439)
            _441 <= _105;
        else
            _441 <= _437;
    end
    always @(posedge _88) begin
        if (_439)
            _444 <= _105;
        else
            _444 <= _441;
    end
    assign _449 = _444 & _448;
    assign _451 = _449 & _450;
    assign _453 = _451 & _452;
    assign _454 = _453 & _82;
    assign _776 = _454 ? _775 : _771;
    assign _83 = _776;
    always @(posedge _88) begin
        if (_439)
            _771 <= _175;
        else
            _771 <= _83;
    end
    assign _84 = _771;
    always @(posedge _88) begin
        if (_439)
            _789 <= _105;
        else
            _789 <= _786;
    end
    assign _790 = ~ _789;
    assign vdd = 1'b1;
    assign _86 = rst_n;
    assign _439 = ~ _86;
    assign _88 = clk;
    assign _90 = uio_in;
    assign _780 = _90[2:2];
    always @(posedge _88) begin
        if (_439)
            _783 <= _105;
        else
            _783 <= _780;
    end
    always @(posedge _88) begin
        if (_439)
            _786 <= _105;
        else
            _786 <= _783;
    end
    assign _791 = _786 & _790;
    assign _792 = _779 | _791;
    assign _91 = _792;
    always @(posedge _88) begin
        if (_439)
            _779 <= _105;
        else
            _779 <= _91;
    end
    assign _92 = _779;
    assign _793 = _92 ? _304 : _84;
    assign uo_out = _793;
    assign uio_out = _305;
    assign uio_oe = _228;

endmodule
