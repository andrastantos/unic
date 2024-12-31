module oled_top (
    input logic clk27,

    output logic lcd_rst_n,
    output logic lcd_cs_n,
    output logic psram_cs_n,
    output logic flash_cs_n,
    input  logic spi_miso_io1,
    output logic spi_mosi_io0,
    output logic spi_clk,
    output logic spi_io3,
    output logic spi_io2,

    inout logic [40:1] pin
);
    logic clk;

    OSC osc_inst (
        .OSCOUT(clk)
    );

    defparam osc_inst.FREQ_DIV = 10; // Sets clk to about 21MHz
    defparam osc_inst.DEVICE = "GW1NR-4D";


    logic busy;
    logic spi_ncs;
    logic spi_mosi;
    logic [7:0] clk_divider;
    logic [7:0] rst_divider;

    logic refresh;
    logic lcd_nrst;

    //logic [31:0] refresh_divider;
    //always @(posedge clk) begin
    //    if (refresh_divider == 10000000) begin
    //        refresh = 1'b1;
    //        refresh_divider = 0;
    //    end else begin
    //        refresh = 1'b0;
    //        refresh_divider = refresh_divider + 1'b1;
    //    end
    //end
    assign refresh = 1'b0;

    assign clk_divider = 20; // Roughly 1MHz SPI clk
    assign rst_divider = 100; // Roughly 5us of reset pulse

    OledCtrl oled_ctr (
        .clk(clk),
        .rst(1'b0),
        .reset(1'b0),
        .refresh(refresh),
        .busy(busy),
        .spi_clk(spi_clk),
        .spi_mosi(spi_mosi),
        .spi_ncs(spi_ncs),
        .lcd_nrst(lcd_nrst),
        .clk_divider(clk_divider),
        .rst_divider(rst_divider)
    );

    assign psram_cs_n = 1'b0;
    assign flash_cs_n = 1'b0;
    assign lcd_cs_n = spi_ncs;
    assign spi_mosi_io0 = spi_mosi;
    assign lcd_rst_n = lcd_nrst;

    assign pin[20] = busy;
    assign pin[19] = spi_clk;
    assign pin[18] = spi_ncs;
    assign pin[17] = spi_mosi;
    assign pin[16] = clk;
    assign pin[15] = refresh;
    assign pin[14] = lcd_nrst;
endmodule
