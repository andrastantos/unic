module dac_top (
    input logic clk27,

    inout logic [40:1] pin,

    inout logic lcd_rst_n,
    inout logic lcd_cs_n,
    inout logic psram_cs_n,
    inout logic spi_miso_io1,
    inout logic spi_mosi_io0,
    inout logic flash_cs_n,
    inout logic spi_clk,
    inout logic spi_io3,
    inout logic spi_io2,

    inout logic io1a,
    inout logic io1b,
    inout logic io2a,
    inout logic io2b,
    inout logic io3a,
    inout logic io3b,
    inout logic io4a,
    inout logic io4b,
    inout logic io5a,
    inout logic io5b,
    inout logic io6a,
    inout logic io6b

);
    logic clk;

    OSC osc_inst (
        .OSCOUT(clk)
    );

    defparam osc_inst.FREQ_DIV = 10;
    defparam osc_inst.DEVICE = "GW1NR-4D";

    assign pin[18] = clk27;
    assign pin[17] = clk;

    logic [24:0] counter;

    always @(posedge clk) begin
        counter <= counter + 1'b1;
    end

    assign pin[19] = counter[24];
    assign pin[20] = counter[23];

    assign pin[16] = pin[15];
    assign pin[14] = pin[13];
    assign pin[12] = 0;
    assign pin[11] = 1;
    assign pin[10] = 0;
    assign pin[9] = 1;

endmodule
