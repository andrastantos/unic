`timescale 1ns/1ns

module top();

    logic clk27;
    logic n_rst;

    logic dac_1;
    logic dac_2;
    logic fast_clk;
    logic slow_clk;

    dac_top dut(.*);

    initial begin
        clk27 = 1;
    end

    always #10 clk27 = ~clk27;

    initial begin
        $display("Reset applied");
        n_rst = 0;
        #500 n_rst = 1;
        $display("Reset removed");
    end

    initial begin
    	$dumpfile("top.vcd");
    	$dumpvars(0,top);
        #(1000*100) $finish;
    end
endmodule


module rPLL (
    output logic       CLKOUT,
    output logic       LOCK,
    output logic       CLKOUTP,
    output logic       CLKOUTD,
    output logic       CLKOUTD3,
    input logic        RESET,
    input logic        RESET_P,
    input logic        CLKIN,
    input logic        CLKFB,
    input logic [5:0]  FBDSEL,
    input logic [5:0]  IDSEL,
    input logic [5:0]  ODSEL,
    input logic [3:0]  PSDA,
    input logic [3:0]  DUTYDA,
    input logic [3:0]  FDLY
);
    assign CLKOUT = CLKIN;
endmodule