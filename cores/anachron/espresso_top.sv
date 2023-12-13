
//`define USE_SYNCHRONIZER // Define this to enable the PLL and the re-synchronization of the DRAM signals.

module espresso_top (
    input logic clk,
    input logic rst,

    output logic [10:0] dram_addr,
    inout logic [7:0] dram_data,

    output logic dram_n_nren,

    output logic dram_n_cas_0,
    output logic dram_n_cas_1,
    output logic dram_n_ras_a,
    output logic dram_n_ras_b,

    input logic dram_n_wait,

    output logic dram_n_we,

    input logic [3:0] drq,
    output logic [3:0] dram_n_dack,
    output logic dram_tc,

    input logic n_int
);

    logic [7:0] core_dram_data_out;
    logic [10:0] core_dram_addr_out;
    logic core_dram_bus_en;
    logic core_dram_data_out_en;

    logic core_dram_n_nren;
    logic core_dram_n_cas_0;
    logic core_dram_n_cas_1;
    logic core_dram_n_ras_a;
    logic core_dram_n_ras_b;

    logic fast_dram_n_nren;
    logic fast_dram_n_cas_0;
    logic fast_dram_n_cas_1;
    logic fast_dram_n_ras_a;
    logic fast_dram_n_ras_b;

`ifdef USE_SYNCHRONIZER
    logic clk2;

	always @(negedge clk2) fast_dram_n_nren  <= core_dram_n_nren;
    always @(negedge clk2) fast_dram_n_cas_0 <= core_dram_n_cas_0;
    always @(negedge clk2) fast_dram_n_cas_1 <= core_dram_n_cas_1;
    always @(negedge clk2) fast_dram_n_ras_a <= core_dram_n_ras_a;
    always @(negedge clk2) fast_dram_n_ras_b <= core_dram_n_ras_b;
`else
    assign fast_dram_n_nren  = core_dram_n_nren;
    assign fast_dram_n_cas_0 = core_dram_n_cas_0;
    assign fast_dram_n_cas_1 = core_dram_n_cas_1;
    assign fast_dram_n_ras_a = core_dram_n_ras_a;
    assign fast_dram_n_ras_b = core_dram_n_ras_b;
`endif

    assign dram_addr = core_dram_bus_en ? core_dram_addr_out : 11'bz;
    assign dram_data = core_dram_bus_en & core_dram_data_out_en ? core_dram_data_out : 8'bz;
    assign dram_n_nren = core_dram_bus_en ? fast_dram_n_nren : 1'bz;
    assign dram_n_cas_0 = core_dram_bus_en ? fast_dram_n_cas_0 : 1'bz;
    assign dram_n_cas_1 = core_dram_bus_en ? fast_dram_n_cas_1 : 1'bz;
    assign dram_n_ras_a = core_dram_bus_en ? fast_dram_n_ras_a : 1'bz;
    assign dram_n_ras_b = core_dram_bus_en ? fast_dram_n_ras_b : 1'bz;

`ifdef USE_SYNCHRONIZER
    // A pll to quadruple the input clock
    rPLL rpll_inst (
        .CLKOUT(clk2),
        .RESET(1'b0),
        .RESET_P(1'b0),
        .CLKIN(clk),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );

    defparam rpll_inst.FCLKIN = "10";
    defparam rpll_inst.DYN_IDIV_SEL = "false";
    defparam rpll_inst.IDIV_SEL = 0;
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    defparam rpll_inst.FBDIV_SEL = 3;
    defparam rpll_inst.DYN_ODIV_SEL = "false";
    defparam rpll_inst.ODIV_SEL = 16;
    defparam rpll_inst.PSDA_SEL = "0000";
    defparam rpll_inst.DYN_DA_EN = "true";
    defparam rpll_inst.DUTYDA_SEL = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL = "internal";
    defparam rpll_inst.CLKOUT_BYPASS = "false";
    defparam rpll_inst.CLKOUTP_BYPASS = "false";
    defparam rpll_inst.CLKOUTD_BYPASS = "false";
    defparam rpll_inst.DYN_SDIV_SEL = 2;
    defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
    defparam rpll_inst.DEVICE = "GW1N-9C";
`endif

    BrewV1Top top (
        .clk(clk),
        .rst(rst),

        .dram_bus_en(core_dram_bus_en),

        .dram_addr(core_dram_addr_out),

        .dram_data_in(dram_data),
        .dram_data_out(core_dram_data_out),

        .dram_data_out_en(core_dram_data_out_en),

        .dram_n_nren(core_dram_n_nren),
        .dram_n_cas_0(core_dram_n_cas_0),
        .dram_n_cas_1(core_dram_n_cas_1),
        .dram_n_ras_a(core_dram_n_ras_a),
        .dram_n_ras_b(core_dram_n_ras_b),
        .dram_n_wait(dram_n_wait),
        .dram_n_we(dram_n_we),

        .dram_n_dack(dram_n_dack),
        .drq(drq),
        .dram_tc(dram_tc),

        .n_int(n_int)
    );
endmodule

