////////////////////////////////////////////////////////////////////////////////
// Type definitions
////////////////////////////////////////////////////////////////////////////////
`define States__idle 3'h0
`define States__read_len_low 3'h1
`define States__reset 3'h2
`define States__reset_release 3'h3
`define States__wait_on 3'h4
`define States__read_cmd 3'h5
`define States__read_last 3'h6
`define States__done 3'h7


`define SpiStates__idle 2'h0
`define SpiStates__wait_clk 2'h1
`define SpiStates__send_dat 2'h2





////////////////////////////////////////////////////////////////////////////////
// OledCtrl
////////////////////////////////////////////////////////////////////////////////
module OledCtrl (
	input logic clk,
	input logic rst,
	input logic reset,
	input logic refresh,
	output logic busy,
	output logic spi_clk,
	output logic spi_mosi,
	output logic spi_ncs,
	output logic lcd_nrst,
	input logic [7:0] clk_divider,
	input logic [7:0] rst_divider
);

	logic [2:0] last_state;
	logic [7:0] rst_cnt;
	logic [9:0] init_len;
	logic [9:0] init_cnt;
	logic spi_send;
	logic u70_output_port;
	logic spi_busy;
	logic [8:0] spi_ctrl_rcv_data;
	logic [8:0] spi_ctrl_send_data;
	logic [2:0] fsm_state;
	logic [2:0] fsm_next_state;

	always_ff @(posedge clk) rst_cnt <= rst ? 8'h0 : (fsm_state == `States__read_len_low | fsm_state == `States__reset_release) ? 1'h0 : 8'(rst_cnt + 1'h1 + 9'b0);
	assign lcd_nrst =  ~ (fsm_state == `States__reset);
	always_ff @(posedge clk) last_state <= rst ? 3'h0 : fsm_state;
	always_ff @(posedge clk) init_len <= rst ? 10'h0 : last_state == `States__idle | last_state == `States__read_len_low ? ({init_len[0], spi_ctrl_send_data}) : init_len;
	always_ff @(posedge clk) init_cnt <= rst ? 10'h0 : 
		(fsm_state == `States__idle ? 1'h1 : 10'b0) | 
		(fsm_state == `States__read_len_low ? 2'h2 : 10'b0) | 
		(fsm_state == `States__reset ? 2'h2 : 10'b0) | 
		(fsm_state == `States__reset_release ? 2'h2 : 10'b0) | 
		(fsm_state == `States__wait_on ? 2'h2 : 10'b0) | 
		(fsm_state == `States__read_cmd ? spi_send ? 10'(init_cnt + 1'h1 + 11'b0) : init_cnt : 10'b0) | 
		(fsm_state == `States__read_last ? 1'h0 : 10'b0) | 
		(fsm_state == `States__done ? 1'h0 : 10'b0) ;
	assign busy = fsm_state != `States__done;
	assign spi_send = last_state == `States__read_cmd &  ~ spi_busy;

	SpiCtrl spi_ctrl (
		.clk(clk),
		.rst(rst),
		.spi_clk(spi_clk),
		.spi_mosi(spi_mosi),
		.spi_miso(u70_output_port),
		.spi_ncs(spi_ncs),
		.clk_divider(clk_divider),
		.send(spi_send),
		.send_data(spi_ctrl_send_data),
		.rcv_data(spi_ctrl_rcv_data),
		.busy(spi_busy)
	);

	FSM_2 fsm (
		.clock_port(clk),
		.reset_port(rst),
		.reset_value(`States__idle),
		.state(fsm_state),
		.next_state(fsm_next_state),
		.default_state(`States__idle),
		.input_idle_to_read_len_low(1'h1),
		.input_read_len_low_to_reset(1'h1),
		.input_reset_to_reset_release(rst_cnt == rst_divider),
		.input_reset_release_to_wait_on(1'h1),
		.input_wait_on_to_read_cmd(rst_cnt == rst_divider),
		.input_read_cmd_to_read_last(init_cnt == init_len &  ~ spi_busy),
		.input_read_last_to_done( ~ spi_busy),
		.input_done_to_idle(refresh)
	);

	Memory init_code (
		.addr(init_cnt),
		.clk(clk),
		.data_out(spi_ctrl_send_data)
	);

	assign u70_output_port = 1'h0;
endmodule


////////////////////////////////////////////////////////////////////////////////
// Memory
////////////////////////////////////////////////////////////////////////////////
module Memory (
	input logic [9:0] addr,
	input logic clk,
	output logic [8:0] data_out
);

	logic [8:0] mem [0:1023];
	initial begin
		mem[0] <= 9'h1;
		mem[1] <= 9'h24;
		mem[2] <= 9'hae;
		mem[3] <= 9'hd5;
		mem[4] <= 9'h80;
		mem[5] <= 9'ha8;
		mem[6] <= 9'h1f;
		mem[7] <= 9'hd3;
		mem[8] <= 9'h0;
		mem[9] <= 9'h40;
		mem[10] <= 9'h8d;
		mem[11] <= 9'h14;
		mem[12] <= 9'ha1;
		mem[13] <= 9'hc0;
		mem[14] <= 9'hda;
		mem[15] <= 9'h2;
		mem[16] <= 9'h81;
		mem[17] <= 9'hbf;
		mem[18] <= 9'hd9;
		mem[19] <= 9'hf1;
		mem[20] <= 9'hdb;
		mem[21] <= 9'h30;
		mem[22] <= 9'ha4;
		mem[23] <= 9'ha6;
		mem[24] <= 9'haf;
		mem[25] <= 9'h0;
		mem[26] <= 9'h10;
		mem[27] <= 9'hb0;
		mem[28] <= 9'h1ff;
		mem[29] <= 9'h101;
		mem[30] <= 9'h101;
		mem[31] <= 9'h101;
		mem[32] <= 9'h101;
		mem[33] <= 9'h101;
		mem[34] <= 9'h101;
		mem[35] <= 9'h101;
		mem[36] <= 9'h101;
		mem[37] <= 9'h101;
		mem[38] <= 9'h101;
		mem[39] <= 9'h101;
		mem[40] <= 9'h101;
		mem[41] <= 9'h101;
		mem[42] <= 9'h101;
		mem[43] <= 9'h101;
		mem[44] <= 9'h101;
		mem[45] <= 9'h101;
		mem[46] <= 9'h101;
		mem[47] <= 9'h101;
		mem[48] <= 9'h101;
		mem[49] <= 9'h101;
		mem[50] <= 9'h101;
		mem[51] <= 9'h101;
		mem[52] <= 9'h101;
		mem[53] <= 9'h101;
		mem[54] <= 9'h101;
		mem[55] <= 9'h101;
		mem[56] <= 9'h101;
		mem[57] <= 9'h101;
		mem[58] <= 9'h101;
		mem[59] <= 9'h101;
		mem[60] <= 9'h101;
		mem[61] <= 9'h101;
		mem[62] <= 9'h101;
		mem[63] <= 9'h101;
		mem[64] <= 9'h101;
		mem[65] <= 9'h101;
		mem[66] <= 9'h101;
		mem[67] <= 9'h101;
		mem[68] <= 9'h101;
		mem[69] <= 9'h101;
		mem[70] <= 9'h101;
		mem[71] <= 9'h101;
		mem[72] <= 9'h101;
		mem[73] <= 9'h101;
		mem[74] <= 9'h101;
		mem[75] <= 9'h101;
		mem[76] <= 9'h101;
		mem[77] <= 9'h101;
		mem[78] <= 9'h101;
		mem[79] <= 9'h101;
		mem[80] <= 9'h101;
		mem[81] <= 9'h101;
		mem[82] <= 9'h101;
		mem[83] <= 9'h101;
		mem[84] <= 9'h101;
		mem[85] <= 9'h101;
		mem[86] <= 9'h101;
		mem[87] <= 9'h181;
		mem[88] <= 9'h1c1;
		mem[89] <= 9'h141;
		mem[90] <= 9'h161;
		mem[91] <= 9'h121;
		mem[92] <= 9'h121;
		mem[93] <= 9'h121;
		mem[94] <= 9'h121;
		mem[95] <= 9'h121;
		mem[96] <= 9'h111;
		mem[97] <= 9'h111;
		mem[98] <= 9'h131;
		mem[99] <= 9'h161;
		mem[100] <= 9'h1c1;
		mem[101] <= 9'h101;
		mem[102] <= 9'h101;
		mem[103] <= 9'h101;
		mem[104] <= 9'h101;
		mem[105] <= 9'h101;
		mem[106] <= 9'h101;
		mem[107] <= 9'h101;
		mem[108] <= 9'h101;
		mem[109] <= 9'h101;
		mem[110] <= 9'h101;
		mem[111] <= 9'h101;
		mem[112] <= 9'h101;
		mem[113] <= 9'h101;
		mem[114] <= 9'h101;
		mem[115] <= 9'h101;
		mem[116] <= 9'h101;
		mem[117] <= 9'h101;
		mem[118] <= 9'h101;
		mem[119] <= 9'h101;
		mem[120] <= 9'h101;
		mem[121] <= 9'h101;
		mem[122] <= 9'h101;
		mem[123] <= 9'h101;
		mem[124] <= 9'h101;
		mem[125] <= 9'h101;
		mem[126] <= 9'h101;
		mem[127] <= 9'h101;
		mem[128] <= 9'h101;
		mem[129] <= 9'h101;
		mem[130] <= 9'h101;
		mem[131] <= 9'h101;
		mem[132] <= 9'h101;
		mem[133] <= 9'h101;
		mem[134] <= 9'h101;
		mem[135] <= 9'h101;
		mem[136] <= 9'h101;
		mem[137] <= 9'h101;
		mem[138] <= 9'h101;
		mem[139] <= 9'h101;
		mem[140] <= 9'h101;
		mem[141] <= 9'h101;
		mem[142] <= 9'h101;
		mem[143] <= 9'h101;
		mem[144] <= 9'h101;
		mem[145] <= 9'h101;
		mem[146] <= 9'h101;
		mem[147] <= 9'h101;
		mem[148] <= 9'h101;
		mem[149] <= 9'h101;
		mem[150] <= 9'h101;
		mem[151] <= 9'h101;
		mem[152] <= 9'h101;
		mem[153] <= 9'h101;
		mem[154] <= 9'h101;
		mem[155] <= 9'h1ff;
		mem[156] <= 9'h0;
		mem[157] <= 9'h10;
		mem[158] <= 9'hb1;
		mem[159] <= 9'h1ff;
		mem[160] <= 9'h100;
		mem[161] <= 9'h100;
		mem[162] <= 9'h100;
		mem[163] <= 9'h100;
		mem[164] <= 9'h100;
		mem[165] <= 9'h100;
		mem[166] <= 9'h100;
		mem[167] <= 9'h100;
		mem[168] <= 9'h100;
		mem[169] <= 9'h100;
		mem[170] <= 9'h100;
		mem[171] <= 9'h100;
		mem[172] <= 9'h100;
		mem[173] <= 9'h100;
		mem[174] <= 9'h100;
		mem[175] <= 9'h100;
		mem[176] <= 9'h100;
		mem[177] <= 9'h168;
		mem[178] <= 9'h114;
		mem[179] <= 9'h114;
		mem[180] <= 9'h17c;
		mem[181] <= 9'h100;
		mem[182] <= 9'h178;
		mem[183] <= 9'h114;
		mem[184] <= 9'h114;
		mem[185] <= 9'h178;
		mem[186] <= 9'h100;
		mem[187] <= 9'h140;
		mem[188] <= 9'h140;
		mem[189] <= 9'h17c;
		mem[190] <= 9'h100;
		mem[191] <= 9'h13c;
		mem[192] <= 9'h140;
		mem[193] <= 9'h140;
		mem[194] <= 9'h13c;
		mem[195] <= 9'h100;
		mem[196] <= 9'h138;
		mem[197] <= 9'h144;
		mem[198] <= 9'h144;
		mem[199] <= 9'h17c;
		mem[200] <= 9'h100;
		mem[201] <= 9'h138;
		mem[202] <= 9'h144;
		mem[203] <= 9'h144;
		mem[204] <= 9'h138;
		mem[205] <= 9'h100;
		mem[206] <= 9'h17c;
		mem[207] <= 9'h108;
		mem[208] <= 9'h110;
		mem[209] <= 9'h108;
		mem[210] <= 9'h17c;
		mem[211] <= 9'h100;
		mem[212] <= 9'h100;
		mem[213] <= 9'h100;
		mem[214] <= 9'h100;
		mem[215] <= 9'h100;
		mem[216] <= 9'h100;
		mem[217] <= 9'h1ff;
		mem[218] <= 9'h1e1;
		mem[219] <= 9'h1e3;
		mem[220] <= 9'h1ce;
		mem[221] <= 9'h118;
		mem[222] <= 9'h130;
		mem[223] <= 9'h160;
		mem[224] <= 9'h1c0;
		mem[225] <= 9'h100;
		mem[226] <= 9'h100;
		mem[227] <= 9'h100;
		mem[228] <= 9'h100;
		mem[229] <= 9'h100;
		mem[230] <= 9'h100;
		mem[231] <= 9'h101;
		mem[232] <= 9'h103;
		mem[233] <= 9'h106;
		mem[234] <= 9'h10c;
		mem[235] <= 9'h118;
		mem[236] <= 9'h130;
		mem[237] <= 9'h1e0;
		mem[238] <= 9'h180;
		mem[239] <= 9'h100;
		mem[240] <= 9'h100;
		mem[241] <= 9'h100;
		mem[242] <= 9'h100;
		mem[243] <= 9'h100;
		mem[244] <= 9'h100;
		mem[245] <= 9'h100;
		mem[246] <= 9'h100;
		mem[247] <= 9'h100;
		mem[248] <= 9'h100;
		mem[249] <= 9'h100;
		mem[250] <= 9'h108;
		mem[251] <= 9'h10c;
		mem[252] <= 9'h10c;
		mem[253] <= 9'h10c;
		mem[254] <= 9'h10c;
		mem[255] <= 9'h1fc;
		mem[256] <= 9'h1fc;
		mem[257] <= 9'h1f8;
		mem[258] <= 9'h100;
		mem[259] <= 9'h1f8;
		mem[260] <= 9'h1fc;
		mem[261] <= 9'h1fc;
		mem[262] <= 9'h100;
		mem[263] <= 9'h180;
		mem[264] <= 9'h180;
		mem[265] <= 9'h1c0;
		mem[266] <= 9'h1c0;
		mem[267] <= 9'h1c0;
		mem[268] <= 9'h180;
		mem[269] <= 9'h1c0;
		mem[270] <= 9'h1c0;
		mem[271] <= 9'h100;
		mem[272] <= 9'h1f8;
		mem[273] <= 9'h1fc;
		mem[274] <= 9'h1fc;
		mem[275] <= 9'h100;
		mem[276] <= 9'h100;
		mem[277] <= 9'h100;
		mem[278] <= 9'h100;
		mem[279] <= 9'h1f8;
		mem[280] <= 9'h1fc;
		mem[281] <= 9'h1fc;
		mem[282] <= 9'h100;
		mem[283] <= 9'h100;
		mem[284] <= 9'h100;
		mem[285] <= 9'h100;
		mem[286] <= 9'h1ff;
		mem[287] <= 9'h0;
		mem[288] <= 9'h10;
		mem[289] <= 9'hb2;
		mem[290] <= 9'h1ff;
		mem[291] <= 9'h100;
		mem[292] <= 9'h100;
		mem[293] <= 9'h100;
		mem[294] <= 9'h100;
		mem[295] <= 9'h13e;
		mem[296] <= 9'h104;
		mem[297] <= 9'h108;
		mem[298] <= 9'h104;
		mem[299] <= 9'h13e;
		mem[300] <= 9'h100;
		mem[301] <= 9'h11c;
		mem[302] <= 9'h122;
		mem[303] <= 9'h122;
		mem[304] <= 9'h11c;
		mem[305] <= 9'h100;
		mem[306] <= 9'h122;
		mem[307] <= 9'h122;
		mem[308] <= 9'h11c;
		mem[309] <= 9'h100;
		mem[310] <= 9'h120;
		mem[311] <= 9'h100;
		mem[312] <= 9'h112;
		mem[313] <= 9'h12a;
		mem[314] <= 9'h12a;
		mem[315] <= 9'h124;
		mem[316] <= 9'h100;
		mem[317] <= 9'h102;
		mem[318] <= 9'h13e;
		mem[319] <= 9'h102;
		mem[320] <= 9'h100;
		mem[321] <= 9'h13e;
		mem[322] <= 9'h100;
		mem[323] <= 9'h11e;
		mem[324] <= 9'h120;
		mem[325] <= 9'h120;
		mem[326] <= 9'h11e;
		mem[327] <= 9'h100;
		mem[328] <= 9'h122;
		mem[329] <= 9'h122;
		mem[330] <= 9'h11c;
		mem[331] <= 9'h100;
		mem[332] <= 9'h134;
		mem[333] <= 9'h10a;
		mem[334] <= 9'h10a;
		mem[335] <= 9'h13e;
		mem[336] <= 9'h100;
		mem[337] <= 9'h13e;
		mem[338] <= 9'h100;
		mem[339] <= 9'h122;
		mem[340] <= 9'h122;
		mem[341] <= 9'h11c;
		mem[342] <= 9'h100;
		mem[343] <= 9'h100;
		mem[344] <= 9'h100;
		mem[345] <= 9'h100;
		mem[346] <= 9'h100;
		mem[347] <= 9'h100;
		mem[348] <= 9'h103;
		mem[349] <= 9'h107;
		mem[350] <= 9'h101;
		mem[351] <= 9'h13f;
		mem[352] <= 9'h17e;
		mem[353] <= 9'h13e;
		mem[354] <= 9'h1e4;
		mem[355] <= 9'h1e3;
		mem[356] <= 9'h1ee;
		mem[357] <= 9'h158;
		mem[358] <= 9'h130;
		mem[359] <= 9'h1e0;
		mem[360] <= 9'h140;
		mem[361] <= 9'h140;
		mem[362] <= 9'h15c;
		mem[363] <= 9'h164;
		mem[364] <= 9'h124;
		mem[365] <= 9'h124;
		mem[366] <= 9'h12c;
		mem[367] <= 9'h138;
		mem[368] <= 9'h130;
		mem[369] <= 9'h111;
		mem[370] <= 9'h113;
		mem[371] <= 9'h19e;
		mem[372] <= 9'h1f8;
		mem[373] <= 9'h100;
		mem[374] <= 9'h100;
		mem[375] <= 9'h100;
		mem[376] <= 9'h100;
		mem[377] <= 9'h100;
		mem[378] <= 9'h100;
		mem[379] <= 9'h100;
		mem[380] <= 9'h100;
		mem[381] <= 9'h108;
		mem[382] <= 9'h118;
		mem[383] <= 9'h118;
		mem[384] <= 9'h118;
		mem[385] <= 9'h118;
		mem[386] <= 9'h11b;
		mem[387] <= 9'h11f;
		mem[388] <= 9'h10f;
		mem[389] <= 9'h100;
		mem[390] <= 9'h11f;
		mem[391] <= 9'h11f;
		mem[392] <= 9'h11f;
		mem[393] <= 9'h100;
		mem[394] <= 9'h11f;
		mem[395] <= 9'h11f;
		mem[396] <= 9'h100;
		mem[397] <= 9'h100;
		mem[398] <= 9'h100;
		mem[399] <= 9'h11f;
		mem[400] <= 9'h11f;
		mem[401] <= 9'h11f;
		mem[402] <= 9'h100;
		mem[403] <= 9'h10f;
		mem[404] <= 9'h10f;
		mem[405] <= 9'h11f;
		mem[406] <= 9'h118;
		mem[407] <= 9'h118;
		mem[408] <= 9'h118;
		mem[409] <= 9'h118;
		mem[410] <= 9'h11b;
		mem[411] <= 9'h10f;
		mem[412] <= 9'h10f;
		mem[413] <= 9'h100;
		mem[414] <= 9'h100;
		mem[415] <= 9'h100;
		mem[416] <= 9'h100;
		mem[417] <= 9'h1ff;
		mem[418] <= 9'h0;
		mem[419] <= 9'h10;
		mem[420] <= 9'hb3;
		mem[421] <= 9'h1ff;
		mem[422] <= 9'h180;
		mem[423] <= 9'h180;
		mem[424] <= 9'h180;
		mem[425] <= 9'h180;
		mem[426] <= 9'h180;
		mem[427] <= 9'h180;
		mem[428] <= 9'h180;
		mem[429] <= 9'h180;
		mem[430] <= 9'h180;
		mem[431] <= 9'h180;
		mem[432] <= 9'h180;
		mem[433] <= 9'h180;
		mem[434] <= 9'h180;
		mem[435] <= 9'h180;
		mem[436] <= 9'h180;
		mem[437] <= 9'h180;
		mem[438] <= 9'h180;
		mem[439] <= 9'h180;
		mem[440] <= 9'h180;
		mem[441] <= 9'h180;
		mem[442] <= 9'h180;
		mem[443] <= 9'h180;
		mem[444] <= 9'h180;
		mem[445] <= 9'h180;
		mem[446] <= 9'h180;
		mem[447] <= 9'h180;
		mem[448] <= 9'h180;
		mem[449] <= 9'h180;
		mem[450] <= 9'h180;
		mem[451] <= 9'h180;
		mem[452] <= 9'h180;
		mem[453] <= 9'h180;
		mem[454] <= 9'h180;
		mem[455] <= 9'h180;
		mem[456] <= 9'h180;
		mem[457] <= 9'h180;
		mem[458] <= 9'h180;
		mem[459] <= 9'h180;
		mem[460] <= 9'h180;
		mem[461] <= 9'h180;
		mem[462] <= 9'h180;
		mem[463] <= 9'h180;
		mem[464] <= 9'h180;
		mem[465] <= 9'h180;
		mem[466] <= 9'h180;
		mem[467] <= 9'h180;
		mem[468] <= 9'h180;
		mem[469] <= 9'h180;
		mem[470] <= 9'h180;
		mem[471] <= 9'h180;
		mem[472] <= 9'h180;
		mem[473] <= 9'h180;
		mem[474] <= 9'h180;
		mem[475] <= 9'h180;
		mem[476] <= 9'h180;
		mem[477] <= 9'h180;
		mem[478] <= 9'h180;
		mem[479] <= 9'h180;
		mem[480] <= 9'h180;
		mem[481] <= 9'h180;
		mem[482] <= 9'h180;
		mem[483] <= 9'h180;
		mem[484] <= 9'h180;
		mem[485] <= 9'h183;
		mem[486] <= 9'h187;
		mem[487] <= 9'h181;
		mem[488] <= 9'h183;
		mem[489] <= 9'h182;
		mem[490] <= 9'h187;
		mem[491] <= 9'h184;
		mem[492] <= 9'h184;
		mem[493] <= 9'h184;
		mem[494] <= 9'h184;
		mem[495] <= 9'h186;
		mem[496] <= 9'h182;
		mem[497] <= 9'h182;
		mem[498] <= 9'h182;
		mem[499] <= 9'h182;
		mem[500] <= 9'h183;
		mem[501] <= 9'h181;
		mem[502] <= 9'h181;
		mem[503] <= 9'h180;
		mem[504] <= 9'h180;
		mem[505] <= 9'h180;
		mem[506] <= 9'h180;
		mem[507] <= 9'h180;
		mem[508] <= 9'h180;
		mem[509] <= 9'h180;
		mem[510] <= 9'h180;
		mem[511] <= 9'h180;
		mem[512] <= 9'h180;
		mem[513] <= 9'h180;
		mem[514] <= 9'h180;
		mem[515] <= 9'h180;
		mem[516] <= 9'h180;
		mem[517] <= 9'h180;
		mem[518] <= 9'h180;
		mem[519] <= 9'h180;
		mem[520] <= 9'h180;
		mem[521] <= 9'h180;
		mem[522] <= 9'h180;
		mem[523] <= 9'h180;
		mem[524] <= 9'h180;
		mem[525] <= 9'h180;
		mem[526] <= 9'h180;
		mem[527] <= 9'h180;
		mem[528] <= 9'h180;
		mem[529] <= 9'h180;
		mem[530] <= 9'h180;
		mem[531] <= 9'h180;
		mem[532] <= 9'h180;
		mem[533] <= 9'h180;
		mem[534] <= 9'h180;
		mem[535] <= 9'h180;
		mem[536] <= 9'h180;
		mem[537] <= 9'h180;
		mem[538] <= 9'h180;
		mem[539] <= 9'h180;
		mem[540] <= 9'h180;
		mem[541] <= 9'h180;
		mem[542] <= 9'h180;
		mem[543] <= 9'h180;
		mem[544] <= 9'h180;
		mem[545] <= 9'h180;
		mem[546] <= 9'h180;
		mem[547] <= 9'h180;
		mem[548] <= 9'h1ff;
	end

	logic [9:0] addr_reg;
	always @(posedge clk) begin
		addr_reg <= addr;
	end
	assign data_out = mem[addr_reg];

endmodule


////////////////////////////////////////////////////////////////////////////////
// SpiCtrl
////////////////////////////////////////////////////////////////////////////////
module SpiCtrl (
	input logic clk,
	input logic rst,
	output logic spi_clk,
	output logic spi_mosi,
	input logic spi_miso,
	output logic spi_ncs,
	input logic [7:0] clk_divider,
	input logic send,
	input logic [8:0] send_data,
	output logic [8:0] rcv_data,
	output logic busy
);

	logic [7:0] prescaler;
	logic spi_prescaler_tick;
	logic spi_tick;
	logic spi_capture_tick;
	logic [3:0] spi_dcnt;
	logic u41_output_port;
	logic [8:0] spi_dreg_next;
	logic [8:0] spi_dreg;
	logic u70_output_port;
	logic spi_clk_delay;
	logic u84_output_port;
	logic [1:0] spi_fsm_state;
	logic [1:0] spi_fsm_next_state;

	always_ff @(posedge clk) prescaler <= rst ? 8'h0 : (rst | prescaler == clk_divider) ? 1'h0 : 8'(prescaler + 1'h1 + 9'b0);
	always_ff @(posedge clk) spi_prescaler_tick <= rst ? 1'h0 : prescaler == 1'h0;
	assign spi_tick = spi_prescaler_tick & (spi_clk | spi_fsm_state != `SpiStates__send_dat);
	assign spi_capture_tick = spi_prescaler_tick &  ~ (spi_clk | spi_fsm_state != `SpiStates__send_dat);
	always_ff @(posedge clk) spi_dcnt <= rst ? 4'h0 : spi_tick ? spi_fsm_state == `SpiStates__idle ? 1'h0 : spi_fsm_state == `SpiStates__wait_clk ? 1'h0 : spi_fsm_state == `SpiStates__send_dat ? 4'(spi_dcnt + 1'h1 + 5'b0) : 4'hx : spi_dcnt;
	always_ff @(posedge clk) u41_output_port <= rst ? 1'h0 : spi_capture_tick ? spi_miso : u41_output_port;
	assign spi_dreg_next = {spi_dreg[7:0], u41_output_port};
	always_ff @(posedge clk) spi_dreg <= rst ? 9'h0 : send ? send_data : (spi_tick & spi_fsm_state == `SpiStates__send_dat) ? spi_dreg_next : spi_dreg;
	assign spi_ncs = spi_fsm_state == `SpiStates__idle ? 1'h1 : spi_fsm_state == `SpiStates__wait_clk ? 1'h1 : spi_fsm_state == `SpiStates__send_dat ? 1'h0 : 1'hx;
	assign busy = spi_fsm_state != `SpiStates__idle;
	always_ff @(posedge clk) u70_output_port <= rst ? 1'h0 : spi_prescaler_tick ? 1'h0 : spi_clk_delay;
	assign spi_clk_delay = spi_fsm_state == `SpiStates__idle ? 1'h1 : spi_fsm_state == `SpiStates__wait_clk ? 1'h1 : spi_fsm_state == `SpiStates__send_dat ? u70_output_port : 1'hx;
	always_ff @(posedge clk) u84_output_port <= rst ? 1'h0 : (spi_prescaler_tick &  ~ spi_clk_delay) ?  ~ spi_clk : spi_clk;
	assign spi_clk = spi_fsm_state == `SpiStates__idle ? 1'h0 : spi_fsm_state == `SpiStates__wait_clk ? 1'h0 : spi_fsm_state == `SpiStates__send_dat ? u84_output_port : 1'hx;
	always_ff @(posedge clk) rcv_data <= rst ? 9'h0 : spi_fsm_state == `SpiStates__send_dat & spi_fsm_next_state == `SpiStates__idle ? spi_dreg_next : rcv_data;
	assign spi_mosi =  ~ spi_ncs & spi_dreg[8];

	FSM spi_fsm (
		.clock_port(clk),
		.reset_port(rst),
		.reset_value(`SpiStates__idle),
		.state(spi_fsm_state),
		.next_state(spi_fsm_next_state),
		.default_state(`SpiStates__idle),
		.input_idle_to_wait_clk(send &  ~ spi_tick),
		.input_idle_to_send_dat(send & spi_tick),
		.input_wait_clk_to_send_dat(spi_tick),
		.input_send_dat_to_idle(spi_tick & spi_dcnt == 4'h8)
	);

endmodule


////////////////////////////////////////////////////////////////////////////////
// FSM_2
////////////////////////////////////////////////////////////////////////////////
module FSM_2 (
	input logic clock_port,
	input logic reset_port,
	input logic [2:0] reset_value,
	output logic [2:0] state,
	output logic [2:0] next_state,
	input logic [2:0] default_state,
	input logic input_idle_to_read_len_low,
	input logic input_read_len_low_to_reset,
	input logic input_reset_to_reset_release,
	input logic input_reset_release_to_wait_on,
	input logic input_wait_on_to_read_cmd,
	input logic input_read_cmd_to_read_last,
	input logic input_read_last_to_done,
	input logic input_done_to_idle
);

	logic [2:0] local_state;
	logic [2:0] local_next_state;

	always_ff @(posedge clock_port) local_state <= reset_port ? reset_value : local_next_state;
	initial local_state <= reset_value;

	FSMLogic_2 fsm_logic (
		.state(local_state),
		.next_state(local_next_state),
		.default_state(default_state),
		.input_idle_to_read_len_low(input_idle_to_read_len_low),
		.input_read_len_low_to_reset(input_read_len_low_to_reset),
		.input_reset_to_reset_release(input_reset_to_reset_release),
		.input_reset_release_to_wait_on(input_reset_release_to_wait_on),
		.input_wait_on_to_read_cmd(input_wait_on_to_read_cmd),
		.input_read_cmd_to_read_last(input_read_cmd_to_read_last),
		.input_read_last_to_done(input_read_last_to_done),
		.input_done_to_idle(input_done_to_idle)
	);

	assign state = local_state;
	assign next_state = local_next_state;
endmodule


////////////////////////////////////////////////////////////////////////////////
// FSM
////////////////////////////////////////////////////////////////////////////////
module FSM (
	input logic clock_port,
	input logic reset_port,
	input logic [1:0] reset_value,
	output logic [1:0] state,
	output logic [1:0] next_state,
	input logic [1:0] default_state,
	input logic input_idle_to_wait_clk,
	input logic input_idle_to_send_dat,
	input logic input_wait_clk_to_send_dat,
	input logic input_send_dat_to_idle
);

	logic [1:0] local_state;
	logic [1:0] local_next_state;

	always_ff @(posedge clock_port) local_state <= reset_port ? reset_value : local_next_state;
	initial local_state <= reset_value;

	FSMLogic fsm_logic (
		.state(local_state),
		.next_state(local_next_state),
		.default_state(default_state),
		.input_idle_to_wait_clk(input_idle_to_wait_clk),
		.input_idle_to_send_dat(input_idle_to_send_dat),
		.input_wait_clk_to_send_dat(input_wait_clk_to_send_dat),
		.input_send_dat_to_idle(input_send_dat_to_idle)
	);

	assign state = local_state;
	assign next_state = local_next_state;
endmodule


////////////////////////////////////////////////////////////////////////////////
// FSMLogic_2
////////////////////////////////////////////////////////////////////////////////
module FSMLogic_2 (
	input logic [2:0] state,
	output logic [2:0] next_state,
	input logic [2:0] default_state,
	input logic input_idle_to_read_len_low,
	input logic input_read_len_low_to_reset,
	input logic input_reset_to_reset_release,
	input logic input_reset_release_to_wait_on,
	input logic input_wait_on_to_read_cmd,
	input logic input_read_cmd_to_read_last,
	input logic input_read_last_to_done,
	input logic input_done_to_idle
);

	logic [2:0] state_idle_selector;
	logic [2:0] state_read_len_low_selector;
	logic [2:0] state_reset_selector;
	logic [2:0] state_reset_release_selector;
	logic [2:0] state_wait_on_selector;
	logic [2:0] state_read_cmd_selector;
	logic [2:0] state_read_last_selector;
	logic [2:0] state_done_selector;

	assign state_idle_selector = (input_idle_to_read_len_low ? `States__read_len_low : 3'b0) | (input_idle_to_read_len_low ? 3'b0 : `States__idle);
	assign state_read_len_low_selector = (input_read_len_low_to_reset ? `States__reset : 3'b0) | (input_read_len_low_to_reset ? 3'b0 : `States__read_len_low);
	assign state_reset_selector = (input_reset_to_reset_release ? `States__reset_release : 3'b0) | (input_reset_to_reset_release ? 3'b0 : `States__reset);
	assign state_reset_release_selector = (input_reset_release_to_wait_on ? `States__wait_on : 3'b0) | (input_reset_release_to_wait_on ? 3'b0 : `States__reset_release);
	assign state_wait_on_selector = (input_wait_on_to_read_cmd ? `States__read_cmd : 3'b0) | (input_wait_on_to_read_cmd ? 3'b0 : `States__wait_on);
	assign state_read_cmd_selector = (input_read_cmd_to_read_last ? `States__read_last : 3'b0) | (input_read_cmd_to_read_last ? 3'b0 : `States__read_cmd);
	assign state_read_last_selector = (input_read_last_to_done ? `States__done : 3'b0) | (input_read_last_to_done ? 3'b0 : `States__read_last);
	assign state_done_selector = (input_done_to_idle ? `States__idle : 3'b0) | (input_done_to_idle ? 3'b0 : `States__done);
	assign next_state = 
		(state == `States__idle ? state_idle_selector : 3'b0) | 
		(state == `States__read_len_low ? state_read_len_low_selector : 3'b0) | 
		(state == `States__reset ? state_reset_selector : 3'b0) | 
		(state == `States__reset_release ? state_reset_release_selector : 3'b0) | 
		(state == `States__wait_on ? state_wait_on_selector : 3'b0) | 
		(state == `States__read_cmd ? state_read_cmd_selector : 3'b0) | 
		(state == `States__read_last ? state_read_last_selector : 3'b0) | 
		(state == `States__done ? state_done_selector : 3'b0) | 
		(state == `States__idle | state == `States__read_len_low | state == `States__reset | state == `States__reset_release | state == `States__wait_on | state == `States__read_cmd | state == `States__read_last | state == `States__done ? 3'b0 : default_state);

endmodule


////////////////////////////////////////////////////////////////////////////////
// FSMLogic
////////////////////////////////////////////////////////////////////////////////
module FSMLogic (
	input logic [1:0] state,
	output logic [1:0] next_state,
	input logic [1:0] default_state,
	input logic input_idle_to_wait_clk,
	input logic input_idle_to_send_dat,
	input logic input_wait_clk_to_send_dat,
	input logic input_send_dat_to_idle
);

	logic [1:0] state_idle_selector;
	logic [1:0] state_wait_clk_selector;
	logic [1:0] state_send_dat_selector;

	assign state_idle_selector = (input_idle_to_wait_clk ? `SpiStates__wait_clk : 2'b0) | (input_idle_to_send_dat ? `SpiStates__send_dat : 2'b0) | (input_idle_to_wait_clk | input_idle_to_send_dat ? 2'b0 : `SpiStates__idle);
	assign state_wait_clk_selector = (input_wait_clk_to_send_dat ? `SpiStates__send_dat : 2'b0) | (input_wait_clk_to_send_dat ? 2'b0 : `SpiStates__wait_clk);
	assign state_send_dat_selector = (input_send_dat_to_idle ? `SpiStates__idle : 2'b0) | (input_send_dat_to_idle ? 2'b0 : `SpiStates__send_dat);
	assign next_state = (state == `SpiStates__idle ? state_idle_selector : 2'b0) | (state == `SpiStates__wait_clk ? state_wait_clk_selector : 2'b0) | (state == `SpiStates__send_dat ? state_send_dat_selector : 2'b0) | (state == `SpiStates__idle | state == `SpiStates__wait_clk | state == `SpiStates__send_dat ? 2'b0 : default_state);

endmodule


