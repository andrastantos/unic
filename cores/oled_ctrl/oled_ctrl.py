from typing import *

from silicon import *
import inspect
from silicon.sil_enum import Enum

# This is a simple SPI controller with arbitrary number of bits.
# For now, it's very simple, only supporting writes, but it can easily
# be extended for both reads and writes
class SpiCtrl(Module):
    clk = ClkPort()
    rst = RstPort()

    spi_clk = Output(logic)
    spi_mosi = Output(logic)
    spi_miso = Input(logic)
    spi_ncs = Output(logic)

    clk_divider = Input(Unsigned(8))

    send = Input(logic)
    send_data = Input()
    rcv_data = Output()

    busy = Output(logic)

    def body(self) -> None:
        spi_fsm = FSM()

        prescaler = Wire(Unsigned(8))

        prescaler <<= Reg(Select(
            self.rst | (prescaler == self.clk_divider),
            increment(prescaler),
            0
        ))
        spi_prescaler_tick = Wire(logic)
        spi_tick = Wire(logic)
        spi_capture_tick = Wire(logic)
        spi_prescaler_tick <<= Reg(prescaler == 0) # register to avoid tick being active during reset

        data_length = self.send_data.get_num_bits()
        spi_dreg = Wire(self.send_data.get_net_type())
        spi_cd   = Wire(logic)
        spi_dcnt = Wire(Unsigned((data_length - 1).bit_length()))

        class SpiStates(Enum):
            idle = 0
            wait_clk = 1
            send_dat = 2

        # Clk polarity during IDLE is not relevant, rising edge captures send_data
        # We will implement clk low during IDLE, nCS and send_data changing on falling edge
        # We will capture rcv_data on rising edge
        spi_fsm.reset_value <<= SpiStates.idle
        spi_fsm.default_state <<= SpiStates.idle

        spi_fsm.add_transition(SpiStates.idle, self.send & ~spi_tick, SpiStates.wait_clk)
        spi_fsm.add_transition(SpiStates.idle, self.send &  spi_tick, SpiStates.send_dat)
        spi_fsm.add_transition(SpiStates.wait_clk, spi_tick, SpiStates.send_dat)
        spi_fsm.add_transition(SpiStates.send_dat, spi_tick & (spi_dcnt == data_length-1), SpiStates.idle)

        spi_tick <<= spi_prescaler_tick & (self.spi_clk | (spi_fsm.state != SpiStates.send_dat))
        spi_capture_tick <<= spi_prescaler_tick & ~(self.spi_clk | (spi_fsm.state != SpiStates.send_dat))

        spi_dcnt <<= Reg(SelectFirst(
            spi_fsm.state == SpiStates.idle,     0,
            spi_fsm.state == SpiStates.wait_clk, 0,
            spi_fsm.state == SpiStates.send_dat, increment(spi_dcnt),
        ), clock_en = spi_tick)
        spi_dreg_next = concat(spi_dreg[data_length-2:0], Reg(self.spi_miso, clock_en = spi_capture_tick))
        spi_dreg <<= Reg(Select(
            self.send,
            Select(
                spi_tick & (spi_fsm.state == SpiStates.send_dat),
                spi_dreg,
                spi_dreg_next
            ),
            self.send_data
        ))

        self.spi_ncs <<= SelectFirst(
            spi_fsm.state == SpiStates.idle,     1,
            spi_fsm.state == SpiStates.wait_clk, 1,
            spi_fsm.state == SpiStates.send_dat, 0,
        )

        self.busy <<= spi_fsm.state != SpiStates.idle

        spi_clk_delay = Wire(logic)
        spi_clk_delay <<= SelectFirst(
            spi_fsm.state == SpiStates.idle, 1,
            spi_fsm.state == SpiStates.wait_clk, 1,
            spi_fsm.state == SpiStates.send_dat,
                Reg(Select(
                    spi_prescaler_tick,
                    spi_clk_delay,
                    0
                ))
        )

        self.spi_clk <<= SelectFirst(
            spi_fsm.state == SpiStates.idle, 0,
            spi_fsm.state == SpiStates.wait_clk, 0,
            spi_fsm.state == SpiStates.send_dat,
                Reg(Select(
                    spi_prescaler_tick & ~spi_clk_delay,
                    self.spi_clk,
                    ~self.spi_clk
                ))
        )
        self.rcv_data <<= Reg(spi_dreg_next, clock_en = ((spi_fsm.state == SpiStates.send_dat) & (spi_fsm.next_state == SpiStates.idle)))

        self.spi_mosi <<= ~self.spi_ncs & spi_dreg[data_length-1]

# This is a small FSM to control the setup and refresh of the OLED screen on UnIC.
# The screen is a CFAL12832 and is based on the SSD1306 controller.
# See https://www.crystalfontz.com/product/cfal12832c0091bw-small-oled-white-monochrome for
# details, including sample code on which this FSM is based on as well.

def load_png(file_name: str) -> Sequence[int]:
    import imageio.v3 as iio
    pixels = iio.imread(file_name, mode="L")
    assert pixels.shape == (32,128), "Image must be 128 x 32 pixels"
    array = []
    for page in range(4):
        array.append(0x000)  # lower column address; upper column address
        array.append(0x010)  # ...
        array.append(0x0b0 + page) # set page address
        for x in range(127,-1,-1):
            byte = 0;
            for y in range(8):
                bit = 1 if pixels[y+page*8, x] < 128 else 0
                byte |= bit << y
            array.append(byte | 0x100)
    return array

class OledCtrl(Module):
    clk = ClkPort()
    rst = RstPort()

    reset = Input(logic) # synchronous reset request
    refresh = Input(logic) # refreshes the screen content
    busy = Output(logic) # shows that the state-machine is busy

    spi_clk = Output(logic)
    spi_mosi = Output(logic)
    spi_ncs = Output(logic)
    lcd_nrst = Output(logic)

    clk_divider = Input(Unsigned(8))
    rst_divider = Input(Unsigned(8))

    def body(self) -> None:

        spi_ctrl = SpiCtrl()

        self.spi_clk <<= spi_ctrl.spi_clk
        self.spi_mosi <<= spi_ctrl.spi_mosi
        self.spi_ncs <<= spi_ctrl.spi_ncs

        spi_ctrl.clk_divider <<= self.clk_divider

        spi_busy = spi_ctrl.busy

        SSD1306B_DCDC_CONFIG_PREFIX_8D          = 0x08D
        SSD1306B_DCDC_CONFIG_7p5v_14            = 0x014
        SSD1306B_DCDC_CONFIG_6p0v_15            = 0x015
        SSD1306B_DCDC_CONFIG_8p5v_94            = 0x094
        SSD1306B_DCDC_CONFIG_9p0v_95            = 0x095
        SSD1306B_DISPLAY_OFF_YES_SLEEP_AE       = 0x0AE
        SSD1306B_DISPLAY_ON_NO_SLEEP_AF         = 0x0AF
        SSD1306B_CLOCK_DIVIDE_PREFIX_D5         = 0x0D5
        SSD1306B_MULTIPLEX_RATIO_PREFIX_A8      = 0x0A8
        SSD1306B_DISPLAY_OFFSET_PREFIX_D3       = 0x0D3
        SSD1306B_DISPLAY_START_LINE_40          = 0x040
        SSD1306B_SEG0_IS_COL_0_A0               = 0x0A0
        SSD1306B_SEG0_IS_COL_127_A1             = 0x0A1
        SSD1306B_SCAN_DIR_UP_C0                 = 0x0C0
        SSD1306B_SCAN_DIR_DOWN_C8               = 0x0C8
        SSD1306B_COM_CONFIG_PREFIX_DA           = 0x0DA
        SSD1306B_COM_CONFIG_SEQUENTIAL_LEFT_02  = 0x002
        SSD1306B_COM_CONFIG_ALTERNATE_LEFT_12   = 0x012
        SSD1306B_COM_CONFIG_SEQUENTIAL_RIGHT_22 = 0x022
        SSD1306B_COM_CONFIG_ALTERNATE_RIGHT_32  = 0x032
        SSD1306B_CONTRAST_PREFIX_81             = 0x081
        SSD1306B_PRECHARGE_PERIOD_PREFIX_D9     = 0x0D9
        SSD1306B_VCOMH_DESELECT_PREFIX_DB       = 0x0DB
        SSD1306B_VCOMH_DESELECT_0p65xVCC_00     = 0x000
        SSD1306B_VCOMH_DESELECT_0p71xVCC_10     = 0x010
        SSD1306B_VCOMH_DESELECT_0p77xVCC_20     = 0x020
        SSD1306B_VCOMH_DESELECT_0p83xVCC_30     = 0x030
        SSD1306B_ENTIRE_DISPLAY_FORCE_ON_A5     = 0x0A5
        SSD1306B_ENTIRE_DISPLAY_NORMAL_A4       = 0x0A4
        SSD1306B_INVERSION_NORMAL_A6            = 0x0A6
        SSD1306B_INVERSION_INVERTED_A7          = 0x0A7

        def display_row(row, *args):
            yield 0x000  # lower column address; upper column address
            yield 0x010  # ...
            yield 0x0b0 + row # set page address
            for d in args: yield d | 0x100

        def init_code_generator(content_width, content_depth):
            init_code = [
                SSD1306B_DISPLAY_OFF_YES_SLEEP_AE,               # Set the display to sleep mode for the rest of the init.
                SSD1306B_CLOCK_DIVIDE_PREFIX_D5,         0x080,  # Set the clock speed, nominal ~105FPS (177Hz measured); Low nibble is divide ratio; High level is oscillator frequency
                SSD1306B_MULTIPLEX_RATIO_PREFIX_A8,      0x01F,  # Set the multiplex ratio to 1/32; Default is 0x3F (1/64 Duty), we need 0x1F (1/32 Duty)
                SSD1306B_DISPLAY_OFFSET_PREFIX_D3,       0x000,  # Set the display offset to 0 (default)
                SSD1306B_DISPLAY_START_LINE_40,                  # Set the display RAM display start line to 0 (default); Bits 0-5 can be set to 0-63 with a bitwise or
                SSD1306B_DCDC_CONFIG_PREFIX_8D,                  # Enable DC/DC converter, 7.5v
                SSD1306B_DCDC_CONFIG_7p5v_14,                    # ...
                SSD1306B_SEG0_IS_COL_127_A1,                     # Map the columns correctly for our OLED glass layout
                SSD1306B_SCAN_DIR_UP_C0,                         # Set COM output scan correctly for our OLED glass layout
                SSD1306B_COM_CONFIG_PREFIX_DA,                   # Set COM pins correctly for our OLED glass layout
                SSD1306B_COM_CONFIG_SEQUENTIAL_LEFT_02,          # ...
                SSD1306B_CONTRAST_PREFIX_81,            0x0BF,   # Set Contrast Control / SEG Output Current / Iref; (magic # from factory)
                SSD1306B_PRECHARGE_PERIOD_PREFIX_D9,    0x0F1,   # Set precharge (low nibble) / discharge (high nibble) timing; precharge = 1 clock; discharge = 15 clocks
                SSD1306B_VCOMH_DESELECT_PREFIX_DB,               # Set VCOM Deselect Level
                SSD1306B_VCOMH_DESELECT_0p83xVCC_30,             # ...
                SSD1306B_ENTIRE_DISPLAY_NORMAL_A4,               # Make sure Entire Display On is disabled (default)
                SSD1306B_INVERSION_NORMAL_A6,                    # Make sure display is not inverted (default)
                SSD1306B_DISPLAY_ON_NO_SLEEP_AF,                 # Get out of sleep mode, into normal operation

                # Set up an image
                *load_png("logo.png")
                #*display_row(0,   0x00,0x00,0x00,0xC0,0xE0,0xF0,0xF8,0xFC,0x1E,0x0F,0x07,0x03,0x07,0xCF,0xE6,0xF0,0xF8,0xFC,0x1E,0x0F,0x07,0x03,0x07,0x0F,0xFE,0xFC,0xF8,0xF0,0xE0,0x00,0x00,0x00,0x00,0x00,0x40,0x40,0x7F,0x40,0x40,0x0E,0x15,0x15,0x15,0x08,0x00,0x1B,0x04,0x04,0x1B,0x00,0x10,0x3E,0x11,0x12,0x00,0x00,0xE0,0xF8,0xFC,0xFE,0x0E,0x03,0x03,0x01,0x01,0x01,0x03,0x03,0x0E,0xFE,0xFC,0xF8,0xE0,0x00,0x00,0x00,0x01,0x01,0xFF,0xFF,0xFF,0xFF,0x01,0x01,0x01,0x01,0x01,0x03,0x03,0x0F,0x38,0x00,0x00,0x00,0x01,0x01,0xFF,0xFF,0xFF,0xFF,0x01,0x01,0x81,0xF1,0x01,0x01,0x03,0x07,0x1C,0x00,0x00,0x00,0x01,0x01,0xFF,0xFF,0xFF,0xFF,0x01,0x01,0x01,0x03,0x03,0x0E,0xFE,0xFC,0xF8,0xE0,),
                #*display_row(1,   0xFE,0xFE,0xFE,0xFE,0xFE,0xFE,0xFE,0xFE,0xFE,0xFE,0xFE,0xFE,0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0xB6,0x00,0x00,0x00,0x1E,0x29,0x49,0x49,0x06,0x00,0x1B,0x04,0x04,0x1B,0x00,0x36,0x49,0x49,0x49,0x36,0x00,0x00,0x00,0x00,0x0F,0x3F,0x7F,0xFF,0xE0,0x80,0x80,0x00,0x00,0x00,0x80,0x80,0xE0,0xFF,0x7F,0x3F,0x0F,0x00,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF,0x01,0x01,0x03,0x1F,0x00,0x80,0xC0,0xF0,0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x80,0xC0,0xF0,0xFF,0x7F,0x3F,0x0F,),
                #*display_row(2,   0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x6D,0x00,0x0C,0x0C,0xFC,0xFC,0x0C,0x0C,0x00,0x60,0xE0,0xE0,0xE0,0x60,0x60,0x60,0x60,0x00,0xC0,0xF0,0x38,0x1C,0x0C,0x0C,0x0C,0x1C,0x38,0x30,0x00,0x01,0x01,0x01,0x01,0x0D,0x0D,0xFD,0xFC,0x0C,0x0C,0x00,0x00,0x0C,0x1C,0x3C,0x7D,0xED,0xCD,0x8D,0x0D,0x0D,0x0D,0x01,0xF0,0xF8,0x9C,0x0C,0x0C,0x0C,0x0C,0x0C,0x9C,0xF8,0xF1,0x01,0x0D,0x1D,0xB9,0xF1,0xE1,0xF1,0xB9,0x1D,0x0D,0x01,0x31,0x39,0x1C,0x0C,0x0C,0x0C,0x0D,0x0D,0x9D,0xF9,0x71,0x01,0x0D,0x1D,0x3D,0x7D,0xED,0xCC,0x8C,0x0C,0x0C,0x0C,),
                #*display_row(3,   0x00,0x00,0x00,0x03,0x07,0x0F,0x1F,0x3F,0x78,0xF0,0xE0,0xC0,0xE0,0xF3,0x67,0x0F,0x1F,0x3F,0x78,0xF0,0xE0,0xC0,0xE0,0xF0,0x7F,0x3F,0x1F,0x0F,0x07,0x00,0x00,0x00,0x00,0x00,0xC0,0xC0,0xFF,0xFF,0xC0,0xC0,0x00,0x38,0x78,0xE1,0xC3,0xC7,0xEE,0x7C,0x38,0x00,0x0F,0x3F,0x70,0xE0,0xC0,0xC0,0xC0,0xE0,0x70,0x30,0x00,0x00,0x00,0x00,0x00,0x30,0x70,0xFF,0xFF,0x00,0x00,0x00,0x00,0x38,0x78,0xE0,0xC0,0xC0,0xC1,0xC3,0xE7,0x7E,0x3C,0x00,0x00,0x3D,0x7F,0xE7,0xC3,0xC3,0xC3,0xE7,0x7F,0x3D,0x00,0x00,0x06,0x07,0x03,0x01,0x00,0x01,0x03,0x07,0x06,0x00,0x30,0x70,0xE0,0xC3,0xC3,0xC3,0xC3,0xC3,0xE7,0x7E,0x3C,0x00,0x38,0x78,0xE0,0xC0,0xC0,0xC1,0xC3,0xE7,0x7E,0x3C,),
            ]
            #init_code = [0x44, 0x55, 0x105]
            size = len(init_code) + 1
            yield size >> 9
            yield size & 511
            for code in init_code: yield code

        init_code_cfg = MemoryConfig(
            port_configs = (MemoryPortConfig(data_type=Unsigned(9)),),
            init_content = init_code_generator
        )

        init_code = Memory(init_code_cfg)


        rst_cnt = Wire(Unsigned(8))

        fsm = FSM()
        class States(Enum):
            idle = 0
            read_len_low = 1
            reset = 2
            reset_release = 3
            wait_on = 4
            read_cmd = 5
            read_last = 6
            done = 7

        init_len = Wire(Unsigned(10))
        init_cnt = Wire(Unsigned(10))

        fsm.reset_value <<= States.idle
        fsm.default_state <<= States.idle

        fsm.add_transition(States.idle, 1, States.read_len_low)
        fsm.add_transition(States.read_len_low, 1, States.reset)
        fsm.add_transition(States.reset, rst_cnt == self.rst_divider, States.reset_release)
        fsm.add_transition(States.reset_release, 1, States.wait_on)
        fsm.add_transition(States.wait_on, rst_cnt == self.rst_divider, States.read_cmd)
        fsm.add_transition(States.read_cmd, (init_cnt == init_len) & ~spi_busy, States.read_last)
        fsm.add_transition(States.read_last, ~spi_busy, States.done)
        fsm.add_transition(States.done, self.refresh, States.idle)

        last_state = Reg(fsm.state)

        rst_cnt <<= Reg(Select((fsm.state == States.read_len_low) | (fsm.state == States.reset_release), increment(rst_cnt), 0))
        self.lcd_nrst <<= ~(fsm.state == States.reset)

        init_code.addr <<= init_cnt

        init_len <<= Reg(
            concat(init_len[0], init_code.data_out),
            clock_en=(last_state == States.idle) | (last_state == States.read_len_low)
        )
        spi_send = Wire(logic)
        init_cnt <<= Reg(SelectOne(
            fsm.state == States.idle, 1,
            fsm.state == States.read_len_low, 2,
            fsm.state == States.reset, 2,
            fsm.state == States.reset_release, 2,
            fsm.state == States.wait_on, 2,
            fsm.state == States.read_cmd, Select(spi_send, init_cnt, increment(init_cnt)),
            fsm.state == States.read_last, 0,
            fsm.state == States.done, 0
        ))

        self.busy <<= fsm.state != States.done

        spi_send <<= ((last_state == States.read_cmd)) & ~spi_busy
        spi_ctrl.send <<= spi_send
        spi_ctrl.send_data <<= init_code.data_out
        spi_ctrl.spi_miso <<= 0

def sim_spi():
    class top(Module):
        clk = ClkPort()
        rst = RstPort()

        def body(self):
            spi_core = SpiCtrl()

            self.data = Wire(Unsigned(9))
            self.send = Wire(logic)

            spi_core.clk_divider <<= 4
            spi_core.send_data <<= self.data
            spi_core.send <<= self.send

            miso = Wire(logic)
            last_spi_clk = Reg(spi_core.spi_clk)
            miso <<= Reg(Select(
                self.rst,
                Select(
                    (last_spi_clk == 1) & (spi_core.spi_clk == 0),
                    miso,
                    ~miso
                )
            ))
            spi_core.spi_miso <<= miso

        def simulate(self) -> TSimEvent:
            def clk():
                yield 10
                self.clk <<= ~self.clk & self.clk
                yield 10
                self.clk <<= ~self.clk
                yield 0

            print("Simulation started")

            self.rst <<= 1
            self.clk <<= 1
            self.send <<= 0
            self.data <<= None

            yield 10
            for i in range(5):
                yield from clk()
            self.rst <<= 0

            for i in range(10):
                self.send <<= 1
                self.data <<= i*10 + (1 - (i & 1)) * 256
                yield from clk()
                self.send <<= 0
                self.data <<= None
                for j in range(13*9):
                    yield from clk()
            now = yield 10
            print(f"Done at {now}")

    Build.simulation(top, "spi_ctrl.vcd", add_unnamed_scopes=True)


def sim_oled_ctrl():
    class top(Module):
        clk = ClkPort()
        rst = RstPort()

        def body(self):
            oled_ctrl = OledCtrl()

            self.data = Wire(Unsigned(9))
            self.send = Wire(logic)
            self.refresh = Wire(logic)
            self.busy = Wire(logic)

            oled_ctrl.clk_divider <<= 4
            oled_ctrl.rst_divider <<= 10

            oled_ctrl.reset <<= 0
            oled_ctrl.refresh <<= self.refresh

            self.busy <<= oled_ctrl.busy

        def simulate(self) -> TSimEvent:
            def clk():
                yield 10
                self.clk <<= ~self.clk & self.clk
                yield 10
                self.clk <<= ~self.clk
                yield 0

            print("Simulation started")

            self.rst <<= 1
            self.clk <<= 1
            self.send <<= 0
            self.data <<= None
            self.refresh <<= 0

            yield 10
            for i in range(5):
                yield from clk()
            self.rst <<= 0

            for i in range(500000):
                yield from clk()
                if not self.busy: break
            now = yield 10
            for i in range(100):
                yield from clk()

            self.refresh <<= 1
            yield from clk()
            self.refresh <<= 0
            for i in range(5000):
                yield from clk()
            now = yield 10
            print(f"Done at {now}")

    Build.simulation(top, "oled_ctrl.vcd", add_unnamed_scopes=True)

def gen():
    netlist = Build.generate_rtl(OledCtrl, "oled_ctrl.sv")
    #top_level_name = netlist.get_module_class_name(netlist.top_level)
    #flow = QuartusFlow(target_dir="q_fetch", top_level=top_level_name, source_files=("fetch.sv",), clocks=(("clk", 10), ("top_clk", 100)), project_name="fetch")
    #flow.generate()
    #flow.run()

if __name__ == "__main__":
    gen()
    #sim_oled_ctrl()
