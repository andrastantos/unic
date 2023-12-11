LS series:

https://www.ti.com/lit/an/sdya010/sdya010.pdf?ts=1683483376843&ref_url=https%253A%252F%252Fwww.ti.com%252Fproduct%252FCD54HC4046A

Rise and fall time in the 25ns range. LS logic really doesn’t have appreciable drive strength above 3.3V. Maybe 1mA, maybe even less. So, for all practical purposes the 330 series resistance is overkill. It can drive about 30mA in high and -150mA in low before reaching the input thresholds. This is a strong (LS240) buffer. A regular gate can only drive 20/-40mA.

The fact that no current is available above 3.3V hold true across all TTL families, the drive strength varies widely.

HC is a different matter: it can drive 40mA before it drops to 3.3V. An HC240 can do even 70mA. The AC11240 can do about 150mA! Presumably the HCT series has similar output stage, but different input. So, HCT is potentially problematic.

https://www.ti.com/lit/an/sdya009c/sdya009c.pdf?ts=1683501505168&ref_url=https%253A%252F%252Fwww.ti.com%252Fproduct%252FSN74LS08%253Futm_source%253Dgoogle%2526utm_medium%253Dcpc%2526utm_campaign%253Dasc-int-null-prodfolderdynamic-cpc-pf-google-wwe_int%2526utm_content%253Dprodfolddynamic%2526ds_k%253DDYNAMIC%2BSEARCH%2BADS%2526DCM%253Dyes%2526gclid%253DCj0KCQjwmN2iBhCrARIsAG_G2i4LApa48LKNLaCR-puGEIm1fgQCjyN-cw9Xz6QH1AnIXbXYdv-xNB8aArd9EALw_wcB%2526gclsrc%253Daw.ds

Is a really good resource for logic gate design. It has data on protection circuits (may not apply to FPGA pads) and on page 15 a list of rise and fall times, though it’s interesting that it lists it a symmetrical, which it clearly isn’t. At any rate, all TTL logic is listed as 15ns/V rise/fall. Page 21 lists output resistances. Page 23 lists output and input capacitances. They are in the 3-5pF range, double that for bus-drivers. Page 20 contains a discussion of bus-contention and arrives at the conclusion that a few (tens of) nanoseconds with less then 10% duty-cycle is clearly acceptable. This means no series resistors on the DRAM!

Now, here’s the problem: yes, there are very few computers out there, using HC or HCT logic gates. However, people switch over to 5V (TTL compatible) CMOS in their ASICs rather quickly. Those would have output stages similar to HC/HCT gates.

Let’s compare it with some real components.

Device      C_in     C_out    V_oh @ I_oh         V_ol @ I_ol         C_L        Source
=======   =======   ========  ================== ================== ==========  =========================
Z8400A      5pF       10pF       2.4V@0.25mA       0.4V@1.8mA         50pF       http://www.bitsavers.org/components/zilog/z80/03-0027-02_Z80_CPU_Product_Specification_Mar78.pdf
Z84C00      5pF       15pF       2.4V@1.6mA        0.4V@2mA                      https://www.zilog.com/docs/z80/ps0178.pdf
6502        10/15pF   12pF       2.4V@0.1mA        0.4V@1.6mA                    http://www.bitsavers.org/components/mosTechnology/_dataBooks/1982_MOS_Technology_Data_Catalog.pdf
65C02       10/15pF   12pF       2.4V@0.1mA        0.4V@1.6mA                    http://www.bitsavers.org/components/mosTechnology/_dataBooks/1982_MOS_Technology_Data_Catalog.pdf
80186       10pF      20pF       2.4V@0.4mA        0.45V@2.5mA        20-200pF   http://www.bitsavers.org/components/intel/80186/210451-002_iAPX186_Datasheet_Dec82.pdf
80386SX     10pF      12pF       2.4V@1mA          0.45V@4-5mA        75pF       http://www.bitsavers.org/components/intel/80386/240187-001_386SX_Advance_Information_May88.pdf
80386EX     10pF      10pF       2.45V@8mA         0.45V@8mA          50pF       http://www.bitsavers.org/components/intel/80386/272420-006_80386EX_Data_Sheet_May96.pdf

So, processors in general had rather weak drivers, except for the EX, but that's a different era.

For us, to mimic the 0.4 drop over ~2mA, we could afford a ~200 ohm source resistance.

FPGA        C_in     C_out    V_oh @ I_oh         V_ol @ I_ol         C_L        Source
=======   =======   ========  ================== ================== ==========  =========================
GW1NSR      8pF        8pF       2.9V@4-24mA       0.4V@4-24mA                   https://www.gowinsemi.com/upload/database_doc/1807/document/6458c3c763f36.pdf

This is actually rather typical for FPGAs: up to 24mA driver current. That's an equivalent source resistance of about 16 ohms.

Overall, I'm thinking of lowering the series resistor to about 100ohms. It will not hurt TTL devices for sure and even CMOS devices that are potentially connected to us would see no more than 13mA of current. That is, if they have a 0-ohm source resistance. Seeing that they probably have something on the order of 100 ohms as well, that lowers the current to around 6-7mA, which should be highly acceptable.

JTAG
====

If we want on-board JTAG, we have a few options:

- FTDI (large, expensive)
- BL702 (nice RiscV chip, used on the Tang Nano as an FTDI emulator: https://github.com/sipeed/RV-Debugger-BL702, but where to get it?)
- stm32f103cbx8 (has FTDI emulator: https://github.com/rgwan/open-ec/tree/master/src, available around here, small)

The CPU+FPGA combo is actually a rather potent one for this project: the CPU could be more than just a JTAG interface. It could do all sorts of fun stuff, such as implementing DSP algorithms, or even emulating protocols such as commodore or other floppy drives. We would only need to add some sort of FLASH device. An 8MB part can be had for $1 in single units. A 64MB one for $2. A 128MB for $3.