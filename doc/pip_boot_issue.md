Debug session for boot issues with PIP.

The working hypothesis was: setup/hold time issues. This, I proved wrong.

Running memtest for a long time as well as a basic program made me realize that the problem is not during normal progam execution.
This combined with the fact that not only PIP but floppy operations in general were unreliable under CP/M made me wonder: could
it be that it's only floppy access that has an issue?

Looking again at signal integrity and setup/hold timing requirements of the uPD765 chip, I haven't found anything.

Then I realized: what if there's seomthing wrong about interrupt processing?

This led me down the path of looking into how interrupts are fired and handled.

As it turns out, natively CP/M is routing floppy interrupts to the NMI vector, while timer (vertical retrace, really) interrupts to the interrupt line.

This is nice as the two sources can be separated from one another.

Scoping them both resulted in the following realization:

We hang the floppy operation (not everything, video interrupts are still firing and getting handled) if a regular interrupt
occurs *while* we have the NMI line still low. In other words: if there is a normal interrupt arriving in the short time between
getting an NMI interrupt and handling it to the point where we can re-arm the interrupt mecahnism (i.e. NMI goes inactive), we hang.

Another interesting note is that IRQ and NMI lines go inactive pretty much simultenously in this case.

So, the new hypothesis is this: if an INT interrupts NMI processig, we're hosed. My guess is that the Z80 should disable interrupts
when it enters NMI processing, but maybe the T80 doesn't? In fact, this can be seen: the interrupt acknowledge cycle goes out
while the NMI line is held active.

The expected operation is not all that explicit in the datasheet, but it seems the T80 is clearly at fault here: it doesn't even seem to generate
the requsit interrupt response cycle for an NMI, which *is* described in the datasheet (page 14). Well, actually the datasheet is rather
confusing here. Maybe the T80 cycles are correct.

So, yeah: what should happen (https://raine.1emulation.com/archive/dev/z80-documented.pdf page 17) is that NMI should clear IFF1, while INT should
clear *both* IFF1 and IFF2. My guess is that NMI either doesn't clear IFF1 or if it does, the interrupt enable logic only looks at IFF2.

These flags are called 'IntE_FF1' and 'IntE_FF2' in the source and it appears they are properly set for NMI:

    if NMI_s = '1' and Prefix = "00" then
        NMI_s    <= '0';
        NMICycle <= '1';
        IntE_FF1 <= '0';
    elsif IntE_FF1 = '1' and INT_n='0' and Prefix = "00" and SetEI = '0' then
        IntCycle <= '1';
        IntE_FF1 <= '0';
        IntE_FF2 <= '0';
    elsif (Halt_FF = '1' and INT_n = '0' and Mode = 3) then
        Halt_FF <= '0';
    end if;

It also appears that IntE_FF1 is used as the interrupt enable signal:

        IntE <= IntE_FF1;

So, we'll need to simulate.

Huh... After simulating it, it very much seems like the T80 does the right thing.

It does disable interrupts, it does jump to the right address when an NMI strikes and it does *not*
jump to the interrupt handler while we're still working.

<<< irq_while_nmi_sim.jpg >>>

So, we need to look elsewhere. Can I rig up the LA to take a state-capture?

This is a real pain. I've (though tying NMI out on TXD) verified that the NMI signal reaches the FPGA and
that it is of the proper name. Yet, the LA doesn't want to trigger on it. I don't seem to be able to trigger
on PC becoming 0x0066 either. That's strange to say the least...

I couldn't trigger on PC becoming 0x0038 either, yet I could on IRQ firing and I verified that the capture
contained PC becoming 0x0038.


The internal LA is also crap, but at least I've figured out what it supposed to do with the triggers...


At any rate: it really really shouldn't happen that we take an interrupt 7-8 instructions into the NMI handler.

It's also curious that the hang only happens if the IRQ happens around the M1 cycle for the second IN instruction.

BTW: the first few instructions of the NMI helper are:

    0x0066 JP 0x1d32
    0x1d32 PUSH AF
    0x1d34 IN A,(0)   ; read FDC status register
    0x1d35 AND A,0x20 ; test for the 'EXE' bit
    0x1d37 JR Z,0x73  ; jump if EXE bit is cleared (we jump here most likely in the hanging case, not in the one I have a trace for)
    0x1d39 IN A,(1)
    ...

In the hanging case, 'JR' probably jumps, then executes something after which it executes a second 'IN' judging from the signals I can observe.

Now, the question: I have a single wire that I can observe externally on top of the pins of the CPU. I also have a scope with reasonable trigger capabilities, which can trigger on the hanging case with relative ease.

So I have a total of 4 wires to watch, one of which could be an internal signal brought out to a pin. What can I do with that?

The idea is this: I'll monitor IntE, which is the interrupt enable signal. There's no way an interrupt can get triggered unless IntE (which really is just IntE_FF1) is set.

So now, I have:

    1. IORQ_n on channel 1
    2. IntE on channel 4
    3. IRQ_n on channel 2
    4. NMI_n on channel 3

Picture '44' contains the capture for an error. Indeed, what can be seen is that for a very short time (500ns, or 2 clock cycles) IntE goes high. This of course is a problem since we have an active interrupt. However! Let's see what happens in the normal (non-hanging setup)?

The next image (46) shows this: really, not much: we shouldn't touch IFF1.

The time between the rising edge of the IORQ and the rising edge of IntE is 6.6us. That's 26.5 clock cycles. Given that we are in wait-state 3 out of 4 clocks though, this is only one or two instructions after the IN operation. (Which BTW, I'm not sure if it's an IN, just a guess). Could it be that we enable interrupts in the very next cycle?

IntE_FF1 is not altered in all that many places. Can we figure out where it gets set?

There's this spot:

                        if DIRSet = '1' then
                                IntE_FF2 <= DIR(211);
                                IntE_FF1 <= DIR(210);
                        else

DIRSet is an external signal, defaults to '0' and is not assigned to on the next level (T80a_dido). It's not that.

Then there's this code:

                    if TState = 2 then
                                                if SetEI = '1' then
                                                        IntE_FF1 <= '1';
                                                        IntE_FF2 <= '1';
                                                end if;
                                                if I_RETN = '1' then
                                                        IntE_FF1 <= IntE_FF2;
                                                end if;
                                        end if;

So it could be an EI or a RETN instruction. Well, no surprise there... And... that's it. No other place.

Now, there's another question though: do we normally set IFF1 this early into the NMI routine (provided we go down the jumpy path)?

I'll adjust the trigger to go on IFF1 being 1 while NMI is low...

You know, the behavior of IntE is very weird. See 48 for instance: we *know* that the NMI routine doesn't re-enable the interrupts before at least the first IN operation. Yet, in this instance, it does get re-enabled. What gives? In general IntE goes up and down very erratically, though that's not a scientific statement.

So, could it be that either SetEI or I_RETN get erroneously triggered? I'm thinking the following: could it be that the instruction word (that gets decoded into either of these signals I'm sure) is used even in wait-states, thus, if the wrong data is presented on the data-bus during a wait-state on the M1 cycle, this gets captured and decoded - and acted upon - incorrectly?

SetEI
..........

SetEI comes from T80_MCode. In there it gets set in MCycle 3 for instruction 11011001. The comment seems to indicate that this is RETI. Not sure how exactly as the instruction code for RETI is ED 4D, no D9 in there anywhere, but oh well... So, that's one place:

                when "11011001" =>
                        if Mode = 3 then
                                -- RETI
                                MCycles <= "100";
                                case to_integer(unsigned(MCycle)) is
                                when 1 =>
                                        Set_Addr_TO <= aSP;
                                when 2 =>
                                        IncDec_16 <= "0111";
                                        Set_Addr_To <= aSP;
                                        LDZ <= '1';
                                when 3 =>
                                        Jump <= '1';
                                        IncDec_16 <= "0111";
                                        --I_RETN <= '1';
                                        SetEI <= '1';
                                when others => null;
                                end case;
                        elsif Mode < 2 then
                                -- EXX
                                ExchangeRS <= '1';
                        end if;

We also have this:

                when "11111011" =>
                        -- EI
                        SetEI <= '1';

This checks out, it's the EI instruction. And that's it. Notice though that 'SetEI' is set unconditionally. So, maybe we trigger this incorrectly?

The 'when' seems to belong to:
    case IRB is

case statement. IRB is just IR under a different name and is an input PIN.

IR gets set (in T80.vhd) in two places meaningfully:

                                if MCycle  = "001" and TState(2) = '0' then
                                -- MCycle = 1 and TState = 1, 2, or 3

                                        if TState = 2 and Wait_n = '1' then

                        ...

                                                if IntCycle = '1' and IStatus = "01" then
                                                        IR <= "11111111";
                                                elsif Halt_FF = '1' or (IntCycle = '1' and IStatus = "10") or NMICycle = '1' then
                                                        IR <= "00000000";
                                                else
                                                        IR <= DInst;
                                                end if;

Here we guard it with wait being high, so it can't get accidentally assigned. The other place is this:

                                        if TState = 2 and Wait_n = '1' then
                                                if ISet = "01" and MCycle = "111" then
                                                        IR <= DInst;
                                                end if;

Again, guarded by Wait_n = '1'. So, it seems my hypothesis is wrong. At any rate, it seems we are quite cavalier with setting IFF1, so something must be going on. Let's see if SetEI randomly triggers...

Picture '49' already shows something interesting (this is not a hang). But it's next to impossible to get SetIE, in the same cycle as NMI goes low. Not impossible though, so maybe it's just luck?

OK, now we have the hang, but that's not what's showing on the scope (picture 50). Which is to say, that the last NMI that happened (the one that hung) *did not* have SetIE going high. Let's change the trigger and retry to make sure though...

Picture 51 shows another kind of hang now. This is strange as the interrupt *doesn't* get handled immediately after the second IN instruction (as evidenced by the missing short IORQ that corresponds to that). There's also no pulse (yet) on the SetEI line. Let's try again...

Another hang, another one with no immediate handling of interrupt (and missing SetIE).

Picture 52 finally zoomed out sufficiently to show the SetEI pulse. It happens on the *next* interrupt. Checking the waveforms (picture 54/55) shows that the interrupt is only handled after the SetEI pulse. So...

1. The handling of the interrupt might be a red herring.
2. The behavior appears to have *changed* now that I monitor SetEI.

Actually... (picture 56) we seem to handle the interrupt right in the middle of the NMI handler just as before. And there's no SetEI pulse to be seen!
So, it's *not* SetEI that gets triggered.

I_RETN
..........

Let's route this signal out for starters...

Ha!!! (Picture 57)

This - again - a different type of hang, but it clearly shows the pulse on I_RETN. In fact, the 6.0us delta between the rising edge of IORQ and the rising edge of I_RETN shows that this is the instruction (???) - or most likely the mis-decoded instruction - that triggers the problem.

Either that, or the following issue, especially in the context of this particular repro:

1. NMI fires
2. Handler gets invoked, for the sake of argument, let's say it contains the instruction sequence where after after the second 'IN' we simply store 'A' somewhere safe, then invoke RET_N.
3. If - at this point - IRQ is low, it immediately gets invoked. However - for whatever reason - this invocation gets bongled and the CPU gets confused.

Now, here's why it's very unlikely: in order for RET_N to actually be there in the instruction stream, the following sequence would need to be the minimum:

    0x0066 JP 0x1d32
    0x1d32 PUSH AF
    0x1d34 IN A,(0)   ; read FDC status register
    0x1d35 AND A,0x20 ; test for the 'EXE' bit
    0x1d37 JR Z,0x73  ; jump if EXE bit is cleared (we jump here most likely in the hanging case, not in the one I have a trace for)
    ...               ; jump occurs
    0x---- ????
    0x---- IN A,(1)   ; just guessing: we're reading the data register as it's available
    0x---- LD (xxxx), A ; store A somewhere safe
    0x---- POP AF
    0x---- RETN

That is 6 bytes to read, so - theoretically - it should fit, but tight, in 6us. If there's a better way to save 'A', it might work better.

Even better, if we don't actually read the data here, we don't have to save it anywhere either, so we can POP AF earlier.

So, can I disprove this theory? Not quite. It can still be the case.

I_RETN is also an output of the micro-code engine...

It's set (and only set) here:

                        when "01000101"|"01001101"|"01010101"|"01011101"|"01100101"|"01101101"|"01110101"|"01111101" =>
                                -- RETI/RETN
                                MCycles <= "011";
                                case to_integer(unsigned(MCycle)) is
                                when 1 =>
                                        Set_Addr_TO <= aSP;
                                when 2 =>
                                        IncDec_16 <= "0111";
                                        Set_Addr_To <= aSP;
                                        LDZ <= '1';
                                when 3 =>
                                        Jump <= '1';
                                        IncDec_16 <= "0111";
                                        LDW <= '1';
                                        I_RETN <= '1';
                                when others => null;
                                end case;

RETN is 0xED 0x45, so not sure how all these codes map to that. This is prefixed with the 'EB' group, so

The first is 0x45 (retn), the second is 0x4d (reti), but the next ones are not marked anything in the ISA. Could that be?

Very unlikely, actually. Even it it is, it would mean either an invalid instruction in there, or an improper decode.

Nope. Clearing out the other codes still triggered the problem.

Though (picture 58) shows yet another - slightly different behavior. Now, the interrupt handling doesn't happen until *much* later in the instruction stream.

Could it be that some NMI logic is level-sensitive?????

No, that's also not that likely as the interrupt *does* fire - even if not 100% certainty while NMI is still asserted.

There are two intriguing things. One: the hang always happens (or almost always happens) if the interrupt fires *during* the second IO. Now, why would that be the case? Could it be that the second I/O is the one enabling the interrupt?

The second thing - at it can be verified - is if the RETN instruction gets interrupted or there's one between that and the handing of the interrupt. This can be verified by probing M1 instead of IORQ. So let's do that!

Of course now the problem is that I don't see the handling of the interrupt as that would be visible on the IORQ. So, what I will do is to probe that instead of INT.

OK: another thing: when the jump doesn't happen and we do read the data register, the NMI line goes inactive immediately. This doesn't happen when we do take the jump. Oh, and in those cases, the RETN is not even visible on the scope. So we stay quite a bit of time in the NMI handler, it seems.

OK, we have a repro...

Right, so the very *next* cycle, after the RETN, we get interrupted. Could that be the problem? This needs simulating...

The other thing we can try is to trigger on the similar behavior with the Z80. There we won't see the RETN getting executed, so let's first describe what we see:

    1. The NMI line is asserted for 183us.
    2. After the NMI, the first I/O occurs at 16.2us
    3. The second I/O occurs at 27.1us
    4. After the I/O we see one very long, one very short instructions.
    5. After these, we get the RETN
    6. After RETN, we get the interrupt handling
    7. The delta time between the NMI and the interrupt handling is 35.6us

The theory then is that this timing would not happen with the Z80. We should trigger on NMI being longer then 36us.

Man, it's hard to trigger on this thing...

OK, so I think I have a capture...

Yup, we do. The things that I'm seeing are:

    1. The NMI line is asserted
    2. After the NMI, the first I/O occurs at 14.8us
    3. The second I/O occurs at 27.6us
    4. The INT line gets asserted mid I/O
    5. After the I/O I see a very long, a very short and a very long instruction. Presumably, this is the RETN.
    6. At this point *NO* interrupt handling is going on. The interrupt handling is delayed to 119us after the NMI.
       At this point though still, both the NMI and IRQ lines are asserted. So, it's not like NMI simply masks IRQ
       handling.

On a second run, it's even further delayed. In this case though there's no I/O in between, which is to say, we can't possibly depend on a busy-wait loop of sorts.


So the jump target is 0x1daa. We don't have that in our single capture. Damn!

One would think that the RETN, even if it delays the enabling of the flags, it doesn't delay it by more than a clock cycle. So, is it possible that the RETN happens prematurely?

Let's move on with the assumption that RETN happens close to the interrupt handling. In that case (picture 61), it could not have been the instruction second-to-prior to the interrupt handling: that's a short instruction, and RETN (needing to restore the PC from the stack) takes long. So, it - just as in the T80 case - is the instruction right prior to the interrupt handling. In other words, we go from RETN straight to interrupt handling, no intervening instructions are executed.

OK, so next question: Why can't I capture the case where we immediately execute RETN? In all cases captured with a real Z80, the enablement of the interrupts happen much later.

THIS IS THE POINT WHERE I NEED A DECENT LOGIC ANALYZER!!!! EBAY IT IS.

So, a few ideas to try before the LA shows up:

1. Slowly probe all the data-bus signals (one by one) on the first and second I/O operation. Working theory is that the first I/O reads something incorrect in, that prematurely terminates the NMI handler, thus preventing the actual condition in the FDC to be cleared, thus preventing further progress. Do this on both Z80 and T80 and compare.
2. Test voltage levels on I/O operations, check that signal-integrity is good, setup/hold times as well as voltage levels are what they should be. Compare Levels measured on the bus to what is detected by the FPGA (through loop-back on the debug pin).
3. Get the f-ing GAO working by reducing the number of warnings during synthesis. Idea is that the trigger sequencer is busted, so maybe a single trigger condition will work (as evidenced by not being able to trigger even on reset anymore).


Now, the cleaned up LA doesn't work at all. As in, it doesn't even appear to recognize the device!


At least some clarity: the LA didn't work because - I think - I've lost permissions on the module rule file, so I needed re-run it as root.

So now it at least can communicate, but the trigger - sadly - still is elusive. But, strangely only on NMI. The INT line interrupt works just fine.

Oh the JOY, it triggered!!!!!

This capture (nmi1) is not a failing one, in fact it doesn't have an interrupt around the NMI at all, but captures a full NMI processing sequence. So, let's see what's going on!

1d32 f5
1d33 db 00  --> IN A, (0) - red back 0xf0
1d35 e6 20  --> AND 0x20
1d37 28 73  --> jump conditional - doesn't happen
1d39 db 01  --> IN A, (1) - not only reads data from FDC, but clears NMI source.

This matches the previous sequence, so there's that:

    0x0066 JP 0x1d32
    0x1d32 PUSH AF
    0x1d34 IN A,(0)   ; read FDC status register
    0x1d35 AND A,0x20 ; test for the 'EXE' bit
    0x1d37 JR Z,0x73  ; jump if EXE bit is cleared (we jump here most likely in the hanging case, not in the one I have a trace for)
    0x1d39 IN A,(1)

But, now I can check my understanding of the jump: the data read back has bit 0x20 set, and the jump didn't happen. So, my comment is correct: we jump if the bit is cleared.

So, let's try to capture the hang! The hang happened, but the trigger didn't. God damn this thing...
So maybe we can only trigger once?

Really don't seem to be able to getting reliable trigger on NMI. Not sure why as it clearly is happening.


So, apparently, the f-ing LA can trigger only the first one or two signals in the trigger unit list?!

With this capture (nmi_and_int_no_crash1) there's another interesting case. I don't see the initial processing of the NMI, but I do see when it gets de-asserted. It's also curious that the interrupt happens in sync with an OUT instruction, which is similar to the hanging case. Could this be?

So, just before the interrupt hit, we start execution from 0x0074. Before that the trace cuts off, so not sure...

We eventually jump to 0x1e31:

1e31 3e 03  LD A,3
1e33 d3 f8  OUT (f8), A  (data is 03) -> CONNECT FDC INTERRUPT TO INT, DISCONNECT FROM NMI!!!

OK, so we understand why the interrupt line goes active. It apparently doesn't get disconnected from NMI though. Not that it matters as that should be edge-driven. Still, interesting...

FINALLY!!! I THINK I HAVE A CAPTURE OF THE HANG!!!!!!!

So, we've read 0xD0 from the FDC, which means 0x20 is cleared, so we jump:

BTW: address hold time seems to be 0 in an M1 cycle. Is that kosher? Yes, it is.

1dac  3e 03  LD A,3
1dae  d3 f8  OUT (f8), A  (data is 03) -> CONNECT FDC INTERRUPT TO INT, DISCONNECT FROM NMI!!!

So, we do the same here, this explains the yanking of the IRQ.

1db0  f1     POP AF - we read back what we've pushed, from the right addresses it seems as well (0x2020 from 0xff20)
1db1  ed 45  RETN   - we return from the NMI handler.

OK, so, since we haven't read that data bit, the FDC still yanks on the - now - interrupt line, so we should immediately go into interrupt handling...

BTW: the NMI handler properly saved and restored the PC (107e), so now that the interrupt handler gets invoked, the same address gets pushed onto the stack. So, we go into the interrupt handler:

0038  c3 40 1e   JP 1e40
1e40  f3         DI
1e41  e5         PUSH hl           (pushed value: 23 dc)
1e42  f5         PUSH af           (pushed value: 20 20)
1e43  2a 61 00   LD hl, (0061)     (loaded value: 81 83)
1e46  e5         PUSH hl           (pushed value: 83 81)
1e47  d5         PUSH de           (pushed value: 43 00)
1e48  c5         PUSH bc           (pushed value: ff 00)
1e49  db f8      IN a,(f8)         read system status, returned value is 30

    The status bits are as follows:

        b6: 1 line flyback, read twice in succession indicates frame flyback.
        b5: FDC interrupt - this is set
        b4: indicates 32-line screen - this is set as well
        b3-0: 300Hz interrupt counter: stays at 1111 until reset by in a,(&F4) (see above).

    So, we have a 32-line screen and an FDC interrupt. And indeed, we have a 32-line screen (not a 25 line one). So, really it's just the FDC interrupt that's interesting here.

1e4b  4f         LD c,a            store A in C
1e4c  db f8      IN a,(f8)         read status again (see b6 above as to why). returned value is still 30
1e4e  a1         AND c
1e4f  e6 20      AND 20            test for FDC interrupt
1e51  28 08      JR Z,xxxxx        we won't jump here of course as the bit is set.
1e53  21 7a 00   LD hl,007a
1e56  cd 70 1f   CALL 1f70


    We seem to be restoring some context here from context pointer HL.
...

1f70  5e         LD e,(hl)         load from 0x7a, e=51
1f71  23         INC hl
1f72  56         LD d,(hl)         loaded value 10 so now DE=1051
1f73  23         INC hl
1f74  7e         LD a,(hl)         loaded value is 81
1f75  23         INC hl
1f76  32 61 00   LD (0061),a
1f79  D3 F1      OUT (f1),a        swapping memory banks. This selects extended bank 1 into address space 4000-7fff.
1f7b  7e         LD a,(hl)         loaded value is 83
1f7c  23         INC hl
1f7d  32 62 00   LD (0062),a
1f80  D3 F2      OUT (f2),a        swap extended bank 3 into address space 8000-bfff
1f82  EB         EX de,hl          swap DE and HL
1f83  E9         JP (hl)

    hl at this point contains 1051. This is what we've just loaded at the beginning of the context restore. So maybe this isn't really restoring a context, more like a long jump. to a certain page.

...

1051  2A 38 28   LD hl,(2838)      HL=23dc
1054  7E         LD a,(hl)         A=0
1055  B7         OR a              test if a is 0, I guess?
1056  21 5E 28   LD hl,285e
1059  28 0D      JR z,1068         we are going to jump as a is 0
...
1068  DB 00      IN A,(0)          read FDC status, returned D0, that is: still not ready
106a  E6 30      AND 30            now we test for two conditions: EXE and FDC busy (Which is set)
106c  28 06      JR z,xxxx         we won't jump as one fo this is set.
106e  FE 30      CP 30             test if a is 30 (no it's not for us)
1070  C8         RET z             return, if zero (we won't)
1071  C3 EC 0F   JP 0fec
...
0fec  C5         PUSH bc           pushed values: ff 30
0fed  06 00      LD b,0
0fef  23         INC hl
0ff0  E5         PUSH hl           pushed values: 28 5f
0ff1  DB 00      IN a,(0)          still reading back status D0
0ff3  87         ADD a,a
0ff4  30 FB      JR nc,xxxx        this is a loop and we're NOT looping, until MSB (request for master) bit is set
0ff6  F2 04 10   JP p,1004         jump if the sign flag is set. I think it will not be set, but I'm not sure...
0ff9  DB 01      IN a,(1)          we finally read the data, even though we haven't waited for it to be ready!!!! We read back 46 if that makes a difference.

    Hmmm... At this point we see the NMI line staying low for a little longer even though we've read the data.
    Could this be the problem? Not sure, have to read up on the FDC. I really don't think the sign bit (p) would be set incorrectly, that would cause all sorts of havoc. Overall, I haven't seen any reason why this could should not work.


Disassembly
-----------

It's probably time to start looking into large-scale disassembly.

Searching for the hex sequence starting 1e4b in memory, it's  at 1ecb in j15acpm3.ems.

This suggests at 128-byte header at the front. The sequence starting at 1051 in memory
can be found in the same file at 10d1. Still, the same 128-byte offset.

Not much documentation on the file format. At any rate, this is good enough, I think.
I'll strip the header and disassemble the rest.

So, the disassembly has been done, but of course there are issues. For instance
the interrupt vector table is not there at the beginning.

That piece of code apparently (for RAM address 0x0038) is at offset 0x2518. That suggests an offset of 24e0 into the file for at least this section. For what
it's worth, that does look like a section of code that works as reset vector
and various interrupt vectors.

What it's worth, the EMS file (the beginning of it) does feel like an executable.

It starts by:

l0000h:
        ld sp,0c100h                Set up stack
        ld a,088h                   Set up page 8 in section 0xc000-0xffff
        out (0f3h),a

        ; Copy 0xc80 bytes from offset 54e0 to ed80 (which is in page 8)
        ld hl,l54e0h                ;0007        21 e0 54         ! . T
        ld de,0ed80h                ;000a        11 80 ed         . . .
        ld bc,00c80h                ;000d        01 80 0c         . . .
        ldir                        ;0010        ed b0         . .

        ; Copy 0x27c0 bytes from offset 2520 to c440 (which is in page 8)
        ld hl,l2520h                ;0012        21 20 25         !   %
        ld de,0c440h                ;0015        11 40 c4         . @ .
        ld bc,l27c0h                ;0018        01 c0 27         . . '
        ldir                        ;001b        ed b0         . .

        ; Zero 0x17f bytes from 0xec00
        ld hl,0ec00h                ;001d        21 00 ec         ! . .
        ld de,0ec01h                ;0020        11 01 ec         . . .
        ld bc,0017fh                ;0023        01 7f 01         .  .
        ld (hl),000h                ;0026        36 00         6 .
        ldir                        ;0028        ed b0         . .

        ; Copy 0x800 bytes from 4ce0 to b800
        ld hl,l4ce0h                ;002a        21 e0 4c         ! . L
        ld de,0b800h                ;002d        11 00 b8         . . .
        ld bc,l0800h                ;0030        01 00 08         . . .
        ldir                        ;0033        ed b0         . .

        ; Set page 7 in memory region 0xc000-0xffff
        ld a,087h                   ;0035        3e 87         > .
        out (0f3h),a                ;0037        d3 f3         . .

        ; This is where we're going to jump to with the RET instruction, which happens to be the target address of the copy
        ; Copy 90 bytes from 0x46 to 0xc100.
        ld de,0c100h                ;0039        11 00 c1         . . .
        push de                     ;003c        d5         .
        ld hl,l0046h                ;003d        21 46 00         ! F .
        ld bc,00090h                ;0040        01 90 00         . . .
        ldir                        ;0043        ed b0         . .
        ret                         ;0045        c9         .

                -------------------- THIS PIECE OF CODE EXECUTES AT LOCATION 0xC100
                This is the code that got copied over in the last ldir

        ; Copy 0x23e0 bytes from address 0x100 to 0x0080.
        ; This is the code that establishes the 128-byte offset for most of the code in here.
        ; It also deletes som crap, in the process, but leaves the first 128 bytes in place.
        ld hl,l0100h                ;0046        21 00 01         ! . .
        ld de,l0080h                ;0049        11 80 00         . . .
        ld bc,l23e0h                ;004c        01 e0 23         . . #
        ldir                        ;004f        ed b0         . .

        ; Copy 128 bytes from 24e0 to 0
        ; This is the piece of code that creates the reset vector and what not
        ; in the first 128 bytes of memory.
        ld hl,l24e0h                ;0051        21 e0 24         ! . $
        ld de,l0000h                ;0054        11 00 00         . . .
        ld bc,l0040h                ;0057        01 40 00         . @ .
        ldir                        ;005a        ed b0         . .


        ld hl,l6500h                ;005c        21 00 65         ! . e
        ld de,0fc00h                ;005f        11 00 fc         . . .
        ld a,006h                ;0062        3e 06         > .
        call 0c186h                ;0064        cd 86 c1         . . .

        ld hl,l6b00h                ;0067        21 00 6b         ! . k
        ld de,0f600h                ;006a        11 00 f6         . . .
        ld a,00ch                ;006d        3e 0c         > .
        call 0c186h                ;006f        cd 86 c1         . . .

        ld hl,l6a80h                ;0072        21 80 6a         ! . j
        ld de,l4e00h                ;0075        11 00 4e         . . N
        ld bc,03200h                ;0078        01 00 32         . . 2
        ldir                ;007b        ed b0         . .

        ld a,083h                ;007d        3e 83         > .
        out (0f2h),a                ;007f        d3 f2         . .

        ld hl,l5280h                ;0081        21 80 52         ! . R
        ld de,0ba00h                ;0084        11 00 ba         . . .
        ld a,008h                ;0087        3e 08         > .
        call 0c186h                ;0089        cd 86 c1         . . .

        ld hl,08080h                ;008c        21 80 80         ! . .
        ld de,l8c00h                ;008f        11 00 8c         . . .
        ld a,05ch                ;0092        3e 5c         > \
        call 0c186h                ;0094        cd 86 c1         . . .

        xor a                        ;0097        af         .
        ld hl,02460h                ;0098        21 60 24         ! ` $
        ld de,02461h                ;009b        11 61 24         . a $
        ld bc,l0525h                ;009e        01 25 05         . % .
        ld (hl),a                        ;00a1        77         w
        ldir                ;00a2        ed b0         . .

        ld hl,0bdf0h                ;00a4        21 f0 bd         ! . .
        ld de,0bdf1h                ;00a7        11 f1 bd         . . .
        ld bc,l01ffh                ;00aa        01 ff 01         . . .
        ld (hl),a                        ;00ad        77         w
        ldir                ;00ae        ed b0         . .

        ld hl,l0040h                ;00b0        21 40 00         ! @ .
        ld de,l0040h+1                ;00b3        11 41 00         . A .
        ld bc,l003dh+2                ;00b6        01 3f 00         . ? .
        ld (hl),a                        ;00b9        77         w
        ldir                ;00ba        ed b0         . .

        ld hl,0fea0h                ;00bc        21 a0 fe         ! . .
        ld de,0fea1h                ;00bf        11 a1 fe         . . .
        ld bc,l013fh                ;00c2        01 3f 01         . ? .
        ld (hl),a                        ;00c5        77         w
        ldir                ;00c6        ed b0         . .

        di                        ;00c8        f3         .
        jp 0fc00h                ;00c9        c3 00 fc         . . .




l00cch:
        dec h                        ;00cc        25         %
        ld bc,l007fh+1                ;00cd        01 80 00         . . .
l00d0h:
        ldir                ;00d0        ed b0         . .
        dec a                        ;00d2        3d         =
        jr nz,l00cch                ;00d3        20 f7           .
        ret                        ;00d5        c9         .

The routine that gets called here (c186) is the following:

sub_c186h:
        dec h                        ;c186        25         %
        ld bc,00080h                ;c187        01 80 00         . . .
        ldir                     ;c18a        ed b0         . .
        dec a                        ;c18c        3d         =
        jr nz,sub_c186h                ;c18d        20 f7           .
        ret                        ;c18f        c9         .

At any rate, I think I understand enough now to have the main pieces of the OS code that I care about disassembled.

So here's what the NMI handler looks like:

        ; What we do here (or at least attempt to) is this:
        ; The destination buffer address is stored in 0x0283c; the buffer length is in 0x0283a.
        ; We attempt to read 5 bytes of header info and store it at address: 0x02840-0x2844
        ; We follow this by a full block transfer from the FDC to the buffer.
        ; What I'm learning is this:
        ;   Each command has three phases.
        ;    1. The command phase is when the command is issued, not interesting for our purposes.
        ;    2. The execution phase is when the DMA occurs (which we don't use, so I'm not sure). During this phase the EXM bit is set
        ;       and presumably says that we're dealing with data transfers as opposed to...
        ;    3. The result phase, when up to 7 status bytes can be read from the DATA register.
        ; The interleaving of the code is to satisfy the minimum 12us interval between reading the status register after a data transfer
        ; !!!!!!!!!!!!!!!!!!!!!!!! A SUBTLE TIMING BUG CAN CAUSE VIOLATION OF THIS !!!!!!!!!!!!!!!!!!!!!!
        ; In non-DMA mode, every byte generates an interrupt; however the RQM bit can also be polled to check if data is available.
        ; Data read/writes in this case happen through tha data-register, albeit this is not clear from the datasheet.
        ; Another reason to generate interrupts is a change of a drive 'ready' bit, which would mean a disk-change, most likely.
        ; So, if we get an interrupt with the EXM but cleared, it means we triggered the polling feature, so we need to read ST0 from
        ; the data register. ST0 status register contains the following:
        ;  b7/6: interrupt code; here we're interested in 00 (normal termination) 01 (abnormal termination) and 11 (FDD status change)
        ;  b5: seek end
        ;  b4: equipment failure
        ;  b3: not ready (i.e. door open or something)
        ;  b2: head address (???)
        ;  b1/0: unit select
        ; Given all this, what's most likely going on here is this:
        ; 0. We issue a command, and route FDC interrupts to NMI
        ; 1. In NMI, we check if we're in EXC mode. If so, we're in the execution phase and deal with the inflowing data.
        ;    if not, we re-route the FDC to normal interrupt and bail (at which point the interrupt probably will trigger immediately)
        ; 2. In the interrupt handler, we check for ST0 (read from the data register) and test for various cases of failures.
        ;
        ; This still doesn't explain why we handle the first 5 bytes of a sector in a special way, but whatever...
        ;
        nmi_handler:
                push af                        ;1d32        f5         .
                in a,(000h)                ; READ FDC STATUS
                and 020h                ; check for EXM bit
                jr z,l1dach                ; jump if EXM bit is clear -> we jump here in the case of a hang (i.e. we skip all processing)
                in a,(001h)                ; READ FDC DATA
                ld (02840h),a                ; store it
                push bc
                push de
        l1d40h:
                in a,(000h)                ; READ FDC STATUS again
                add a,a
                jr nc,l1d40h                ; Wait until RQM bit is set
                and 040h                ; Test bit 020, which is EXM (after the addition it's shifted by 1)
                jr z,l1daah                ; Bail if not
                in a,(001h)                ; READ FDC DATA
                ld (02841h),a                ; store it
                push hl
                ld hl,(0283eh)
        l1d52h:
                in a,(000h)                ; READ FDC STATUS again
                add a,a
                jr nc,l1d52h                ; Wait until RQM bit is set
                and 040h                ; Test bit 020, which is EXM (after the addition it's shifted by 1)
                jr z,l1da0h                ; Bail if not and restore middle 2 memory pages
                in a,(001h)                ; READ FDC DATA
                ld (02842h),a                ; store it
                ld a,l                        ; change middle 2 stages of memory to ... something (page info comes from address 0x0283e)
                out (0f1h),a
                ld a,h
                out (0f2h),a
        l1d66h:
                in a,(000h)                ; READ FDC STATUS again
                add a,a
                jr nc,l1d66h                ; Wait until RQM bit is set
                and 040h                ; Test bit 020, which is EXM (after the addition it's shifted by 1)
                jr z,l1da0h                ; Bail if not and restore middle 2 memory pages
                in a,(001h)                ; READ FDC DATA
                ld (02843h),a                ; store it
                ld c,001h               ; This is the input port address (FDC data port) for the rest of the transfer
                ld de,(0283ah)          ; DE is the transfer size for the rest of the transfer
                ld b,e
        l1d7bh:
                in a,(000h)                ; READ FDC STATUS again
                add a,a
                jr nc,l1d7bh                ; Wait until RQM bit is set
                and 040h                ; Test bit 020, which is EXM (after the addition it's shifted by 1)
                jr z,l1da0h                ; Bail if not and restore middle 2 memory pages
                in a,(001h)                ; READ FDC DATA
                ld (02844h),a                ; store it
                ld hl,(0283ch)
        l1d8ch:
                ; All of these instructions include a single M1 cycle, thus a single refresh as well.
                ; So the actual number of clock cycles is (N-2)*4+2, because the 2 refresh cycles don't honor nWAIT.
                in a,(000h)         ; 11 cycles     38 cycles     READ FDC STATUS again
                add a,a             ;  4 cycles      6 cycles
                jr nc,l1d8ch        ; 12/7 cycles   42/22 cycles  Wait until RQM bit is set
                and 040h            ;  7 cycles     22 cycles     Test bit 020, which is EXM (after the addition it's shifted by 1)
                jr z,l1da0h         ; 12/7 cycles   42/22 cycles  Bail if not and restore middle 2 memory pages
                ini                 ; 16 cycles     58 cycles     Load data byte and store it in destination buffer
                jr nz,l1d8ch        ; 12/7 cycles   42/22 cycles  Keep looping if B is non-zero (B used to be E)
                dec d               ;  4 cycles
                jr nz,l1d8ch        ; 12/7 cycles   42/22 cycles  Keep looping if D is non-zero

                ld a,005h           ;  7 cycles    Set up some memory page stuff...
                out (0f8h),a

        l1da0h: ; Restore middle two pages of memory and return
                ld hl,(00061h)
                ld a,l
                out (0f1h),a
                ld a,h
                out (0f2h),a
                pop hl
        l1daah:
                pop de
                pop bc
        l1dach:
                ld a,003h                ; Switch FDC interrupt from NMI to INT
                out (0f8h),a
                pop af
                retn

The FDC interrupt handler appears to be at address 0x1051:


l1051h:
        ld hl,(02838h)                ;1051        2a 38 28         * 8 (
        ld a,(hl)                        ;1054        7e         ~
        or a                        ;1055        b7         .
        ld hl,0285eh                ;1056        21 5e 28         ! ^ (
        jr z,l1068h                ;1059        28 0d         ( .
        ld hl,0ffe0h                ;105b        21 e0 ff         ! . .
        call l1068h                ;105e        cd 68 10         . h .
        ret nc                        ;1061        d0         .
        ld hl,(02838h)                ;1062        2a 38 28         * 8 (
        jp l20eah                ;1065        c3 ea 20         . .
l1068h:
        in a,(000h)                ; Read FDC status register
        and 030h                ; Test for EXM and FDC busy
        jr z,l1074h                ; If both 0, (i.e. not busy and not in execute phase), jump
        cp 030h                 ; Return if both bits are set (i.e. we're in execute phase and busy)
        ret z
        jp l0fech                ; Continue execution
l1074h: ; we get here if FDC not in execute phase and not busy
        call sub_0fe7h
        and 020h
        ret z
        scf
        ret

; We get here if the FDC is not in execute phase but busy -> presumably needs attention
; What we do here is to read all the returned status information and store it in (HL)
; Return value is going to be ST0, I think.
l0fech:
        push bc
        ld b,000h
        inc hl
        push hl
l0ff1h:
        in a,(000h)                ; Read FDC status register
        add a,a
        jr nc,l0ff1h                ; Wait for RQM bit
        jp p,l1004h                ; Jump if the DIO bit is cleared, that is, if no need to read the data register
        in a,(001h)                ; Read data register. At this point, we assume that we're in the status phase, so it should be ST0
        ld (hl),a               ; Store status register value
        inc hl
        inc b
        ex (sp),hl
        ex (sp),hl
        ex (sp),hl
        ex (sp),hl
        jr l0ff1h                ; Keep on looping
l1004h:
        pop hl
        ld a,(hl)
        dec hl
        ld (hl),b
        pop bc
        ret

So, what do we get? The byte read back that the code thinks is ST0 is 0x46. What would that mean in terms of a status info? It would be an abnormal command termination on unit 2 (which is the same as unit 0 from our perspective). So, maybe it checks out?

Notice, how we get this status code in what is essentially the *NMI* handler. We've read the status register sufficient times to not be in violation of anything in this particular instance; we also consistently read the same value, so I guess we can trust it.

Now, if my theory of how the FDC code deals with interrupts is correct, the NMI handler invocation is important: it means that we got an error code instead of the data for a read. I.e. the read never even started.

That would mean, that we did something naughty during the command phase which then the FDC really balked at and refused to cooperate. Since this is not something that should happen, the FDC code is not set up to deal with it and just waits for the read (in this case) to complete, which of course it never does.

So, if I'm right, we need to track down the *command phase* and see what's going on there. Searching for 'out (001h),a' gets only 6 results:

        out (001h),a                ;1087        d3 01         . .

        out (001h),a                ;1dbc        d3 01         . .
        out (001h),a                ;1dd1        d3 01         . .
        out (001h),a                ;1de3        d3 01         . .
        out (001h),a                ;1df7        d3 01         . .
        out (001h),a                ;1e0c        d3 01         . .

All but the first one are in one cluster, so it's probably worth a closer look. Well, not really. That's just the NMI handler for a sector write. It's right next to the NMI handler we've looked at and has a very similar structure, even terminating in a RETN instruction. So that's going to be dealing with the execution phase, and thus not all that interesting. That leaves us with a single location (of course there can be several other sections of code in other files that do this too):

; This routine outputs the A to the FDC controller.
sub_107ch:
        push bc
        ld b,a
l107eh:
        in a,(000h)                ; Read FDC status
        add a,a
        jr nc,l107eh                ; Wait for RQM
        add a,a
        jr c,l108bh                ; if DIO is set (i.e. transfer TO the CPU) bail
        ld a,b
        out (001h),a                ; Output byte that we've received
        ex (sp),hl
        ex (sp),hl
l108bh:
        pop bc                        ;108b        c1         .
        ret                        ;108c        c9         .

OK, not terribly interesting, we'll need to see who calls this

sub_0f61h calls with command code 0xf, so that's SEEK
sub_0f57h calls with command code 0x7, so that's RECALIBRATE
l0bceh or thereabouts calls with command code 0x3, so that's SPECIFY (whatever that is)
sub_0fd9h calls with command code 0x4, so that's SENSE DRIVE STATUS
sub_0fe7h calls with command code 0x8, so that's SENSE INTERRUPT STATUS
sub_1042h does something funky.

sub_1025h issues a long command coming from (hl). So this is what we need.

This in turn gets called from two places:

l100ah:
        call sub_1ccbh                ;100a        cd cb 1c         . . .
        call sub_1025h                ;100d        cd 25 10         . % .
        jp l1c9ch                ;1010        c3 9c 1c         . . .
l1013h:
        call sub_1cb0h                ;1013        cd b0 1c         . . .
        call sub_1025h                ;1016        cd 25 10         . % .
        ld a,(02872h)                ;1019        3a 72 28         : r (
l101ch:
        dec a                        ;101c        3d         =
        inc bc                        ;101d        03         .
        inc bc                        ;101e        03         .
        inc bc                        ;101f        03         .
        jr nz,l101ch                ;1020        20 fa           .
        jp l1ca2h                ;1022        c3 a2 1c         . . .


Both of which appears to some sort of system calls:

l0080h:
        jp l0bc7h                ;00 0080        c3 c7 0b         . . .
        jp l0bceh                ;01 0083        c3 ce 0b         . . .
        jp l0c94h                ;02 0086        c3 94 0c         . . .
        jp l0ca2h                ;03 0089        c3 a2 0c         . . .
        jp l0cabh                ;04 008c        c3 ab 0c         . . .
        jp l0cb9h                ;05 008f        c3 b9 0c         . . .
        jp 00d3ch                ;06 0092        c3 3c 0d         . < .
        jp l0da6h                ;07 0095        c3 a6 0d         . . .
        jp l0fd0h                ;08 0098        c3 d0 0f         . . .
        jp l0ccbh                ;09 009b        c3 cb 0c         . . .
        jp l0e07h                ;0a 009e        c3 07 0e         . . .
        jp l0db9h                ;0b 00a1        c3 b9 0d         . . .
        jp l108dh                ;0c 00a4        c3 8d 10         . . .
        jp l10abh                ;0d 00a7        c3 ab 10         . . .
        jp l10c7h                ;0e 00aa        c3 c7 10         . . .
        jp l100ah                ;0f
        jp l1013h                ;10

This is not a BDOS table though, not sure. At any rate, this is getting less and less interesting.

What is more interesting is this: we appear to be doing something nasty to the poor FDC controller so it
occasionally gives up interpreting a command. This could be:

1. Incorrect write timing (i.e. setup/hold violations) in I/O writes
2. Signal integrity on wires (most likely data wires at this point) resulting in wrong command getting latched
3. Violation of the 12us timing interval between DATA and STATUS register accesses. If this is violated, we can overwrite a command in the sequence.

Now, #3 is not likely because it would result in a command not getting issued (and being incorrect as well) most likely. So we wouldn't advance to the execute phase with an error, the FDC would just be hanging around waiting for more command bytes to arrive.

To test this, we need a signal that toggles every time we access the FDC. This can easily be concocted up in the FPGA.

Picture 65 shows a typical read. The two data lines (green and blue) are not driven for a while but then get driven high. The delay is about 280ns, but some of it for sure gets eaten up by the ULA decoding the access. T_rd is 200ns per datasheet. Max.

Let's try to catch something when data is driven low.

That didn't take long. Picture 66 shows it. and 67 shows about 60ns hold time. Plenty.

OK, so data reads should not be problematic. How about writes? I need to modify my trigger logic a bit for that...

Picture 68 shows very clear logic levels and plenty of setup (and hold) time.

It also shows 600ns of pulse width, again, plenty.

Logic levels are also clean: ~0.2V low, 3.3V high.

So, we pretty much have ruled out #1 and #2. Well, actually, we should check what the signals on the FDC look like...

Pictures 60 and 70 shows the impact (and the delay through) the ULA. Since the delay is almost exactly 250ns, I'm inclined to think that it's a registered version of the signal. Then again, the rising edge is at the same place, so it's not exactly a registered version. This was RD, how about WR? It's the same though I don't have a scope capture (ran out of hands).

So, it must be #3 than. How can we capture *that*? I think what I'm looking for is this: two falling edges on the chip-select with less than 12us between them. Given the pulse is 0.6us, that would mean, I'll need to trigger on a 'high' section of less than 11.4us. Let's try that.

We have reads happening as close as 8 us from one another, but that's not an issue. So, how I can I catch status-after-data accesses? I think more complicated triggering will be needed.

FDC access log
................

I've created a counter and captured the following signals:

counter
PC
RD
WR
A0
D[7:0]

I've captured these one cycle after the falling edge of FDC_access (That is IORQ=0 & M1=1 & A7=0). The capture seems to work except for RD and WR for some reason. At any rate, what I see there is the beginnings of a successful sector read I think.

1. Issuance of the command with PC at 1089/1080 which - from above - is the routine for actually issuing a command. Good.
2. Here the writes to the data register and the read of the status register are separated as follows:

data-to-status: ~180 cycles
status-to-data: 40 cycles

This makes sense: we read status than write data if allowed. Then we return from the subroutine, muck around a little and come back eventually with the next piece of data to write. So, it would be pretty hard to violate data-to-status timing.

Then we go into the read portion inside the NMI handler at address 1d35 and onwards. Here the timing is as follows:

data-to-status: 60 cycles
status-to-data: 40 cycles (maybe reversed though!!)

So, depending on which way it is we either have 10 or 15us. Which makes a *huge* difference.

... And given that the timing of 40 cycles matches that of the transmit case, I bet that's what it is.
At any rate, I'll need to double-check and triple-check that.

Taking the trace for its word, I get:

60 cycles
64 cycles
60 cycles
58 cycles
48 cycles
34 cycles ??!!!!! This is at 1d97 v.s. 1d8e <-- this is the final loop and it's very consistently that much.

So, reads actually do violate the 12us timing, but that's not where we have issues, I think. Unless we have a cascade of failures that a previous read was incorrectly terminated, thus the next read never starts, thus we have a hang.

So, worth going through the timing of that loop around 1d97 with a fine-tooth comb and check timing.

Annotated the loop in question (reading data portion of sector into buffer) with clock cycles from datasheet and adjusting it for WAIT-states:

        l1d8ch:
                ; All of these instructions include a single M1 cycle, thus a single refresh as well.
                ; Taking wait-states into account is rather annoying, but one can say that every memory access (not I/O!) incurs 3 extra cycles.
                ; At least first guess.
                in a,(000h)         ; 11 cycles     17 cycles     READ FDC STATUS again
                add a,a             ;  4 cycles      7 cycles
                jr nc,l1d8ch        ; 12/7 cycles   42/22 cycles  Wait until RQM bit is set
                and 040h            ;  7 cycles     22 cycles     Test bit 020, which is EXM (after the addition it's shifted by 1)
                jr z,l1da0h         ; 12/7 cycles   42/22 cycles  Bail if not and restore middle 2 memory pages
                ini                 ; 16 cycles     58 cycles     Load data byte and store it in destination buffer
                jr nz,l1d8ch        ; 12/7 cycles   42/22 cycles  Keep looping if B is non-zero (B used to be E)
                dec d               ;  4 cycles
                jr nz,l1d8ch        ; 12/7 cycles   42/22 cycles  Keep looping if D is non-zero

Looking at an actual through this loop one can see 31 clock cycles of difference between rising edge of data read and falling edge of status read (data_read_loop_timing). This, with the extra 3 cycles for the actual I/O access rounds up to 34, matching that of the previous measurement, so, that is real, and clearly a violation of the datasheet, being only 7.75us. Which BTW also matches what I've seen on the scope before (see 'as low as 8us').

But what should it be?

We have the tail-end of INI (store the data), which is a memory store, so it should take 6 cycles. Then we have the M1 cycle for the JR instruction, which (with refresh) takes 7 cycles. Then of course we have to read the target address, that's another 5 cycles. Now, the execution phase starts. According to the datasheet (http://www.zilog.com/docs/z80/um0080.pdf, page 287) if a conditional branch is taken, it'll have 3 M cycles and and 12 T cycles. The first M cycle takes 4 T cycles, the second one takes 3. These both get extended by 3 each due to wait-states. The third M cycle takes 5 T cycles, but might not include any memory accesses, thus no dependence on wait-states. So, the JR should take 18 clock cycles total. After that, we start fetching the IN A instruction, which takes an M1 cycle (3+2+3 clocks) and an M2 cycle (3+3 clocks) including wait-states to complete. So overall we have:

6+7+6+5+7+6 cycles here. This adds up to 37 clocks. So we're off by maybe 3 clock cycles, but either way, even going with the datasheet, this should not be within 12us. But, is this enough to make a difference? Don't forget: it mostly works!!

Let's do cycle-by-cycle annotations (cycles_marked_on_in_loop.odg).

The store in the INI takes 5 active cycles, but since memory access start and end on half-cycle boundaries, that's a total of 6 cycles.
The subsequent M1 cycles only takes 3, because two extra wait-states are eaten up by the finishing of the previous M3 cycle and the setup of the M1. This is predictable, it will always happen this way. So, we only have 3 cycles here (instead of 2) plus the 2 refresh cycles, totalling 4 for M1.
For the next M-cycle, we fetch the target address offset, which should take 3 cycles normally, and it doesn't get extended at all: the enable just falls on the right cycle. Again, completely predictable, will happen every time. Now we enter the 6 (!!!) cycles of pondering about taking the jump and coming up with the target address. During this time we don't have memory accesses, thus we don't extend this at all. **** THIS IS SOMETHING TO CHECK. MAYBE THE Z80 DOES GENERATE A MEMORY CYCLE AND THUS GETS IMPACTED!! **** Let's go to the gate-level simulator and see what happens!
The gate-level simulator shows that no memory access is happening in M3 of the JR instruction. So we should be fine.
These 6 cycles actually match up with the gate-level sim, so I must have my cycle boundaries mixed up. At any rate, we enter a 5-cycle (+2 for refresh) M1 cycle. This is because we get the wait-states in the worst possible lineup, so we get penalized for 3 cycles. The next memory read (port address) hits the wait-state generator with perfect stride though so we don't get any problems and fly through in just 3 cycles. Then, in the next cycle we drop IORQ, starting the I/O read.

Overall, I don't see anything that a real Z80 would be doing differently.

So, where does it leave us? We do violate timing on the uPD765, but we should be doing exactly the same as the Z80. This should not be the cause for worry. We've also learned that the naive way of calculating execution cycles is wrong (and an over-estimate) as sometimes we get the right rhythm and don't incur the full 3-cycle penalty on every memory access.

Still it doesn't explain what's going wrong. Damn!

One option is to try the A-Z80 core instead (https://github.com/gdevic/A-Z80). This seems to be a gate-level re-implementation, maybe it fairs better?

Clock issues
------------

The clock is very marginal on the design: adding just a little bit of trace (such as a logic analyzer wire) breaks it. Looking into it, it turns out there's a ferrite bead in it (helpfully omitted on the schematic) that destroys signal quality (FCC issues I'm sure). Images of the clock: 71,72,73,74 with the ferrite in place, 75,76,77,78 with it shorted. The places: before ferrite, after ferrite, at first socket, at shadow tracer socket (CPU pin). First set doesn't boot, second set does.

A-Z80
-----

This thing is full of logical loops and tri-state wires that need to be re-synthesized into muxes. It just barely closes timing at 5MHz. In my first attempt it didn't even remotely boot. This isn't encouraging and I decided to not invest more time in it, instead concentrate on Shadow Tracer that's more generic and forward-looking of a solution.

Logic analyzer
--------------

Another slow-moving disaster: thi thing showed up with 16 out of it's 32 channels not working. This of course took me a better of a day to figure out as it simply was showing weird results. Eventually, I connected all 32 inputs together and drove a pulse to it to see what's going on.

<<< add picture >>>

Clearly 16 channels show bonkers data. What's interesting is that if I trigger on one of the failing channels, the *trigger* happens at the right spot. This strongly points to a an address bus connectivity problem on one of the DRAM chips. I still can't believe I have to debug test equipment I paid money for. At any rate, I'm pursuing a replacement through eBay and might take it to work and XRay it for fun.

Programmer
----------

Gah, things are not going well this weekend. This simple circuit should have taken a couple of hours to get working. Instead it took more than a day, total.

Issues found:

1. ESD diode kills USB communication
2. LDO unstable with just 3.3uF cap, or even the data-sheet suggested 22uF. It need that *and* a 2.2ohm series resistor
3. The FPC connector is a major PITA to hand-solder. All sorts of connectivity issues
4. Pull-up on TDO. Not sure if needed, but TDO is not always driven by the FPGA.
5. Missing bypass caps on the VIO side of the level shifters. Again, not sure if they are necessary (I'm running at 2.5MHz after all) but not nice for sure.

At any rate, it is finally working. This should give me access (provided the extra pins on the FPC connector are functional) access to a bunch more FPGA pins which I can hook up to the LA (at least the 16 working channels) and start hunting for differences.

Shadow Tracer
-------------

The ZIFF sockets have much wider pins than the default KiCAD holes for the DIP 40 socket. I managed to force them in place by destroying only one socket in the process, but what a pain.

Clock troubles
--------------

I have finally found out why the PCW was so unstable if I moved the Z80 further away from the board. Or even just hooked up an LA: the clock pin was driven through a very large ferrite bead (thanks FCC!). This created a shitty enough clock that things stopped working. Even with that shorted through things are a bit shaky, but at least workable.

Comparison
----------

The first thing to note is that that the T80 gets out of reset one cycle earlier than the Z80. This can easily be remedied. <<< T80_early_reset.png>>>.

It is also obvious just how much faster UnIC is in getting the control signals changed after a clock edge. The LA can't even see the setup time, where for Z80 it can see one-to-two 40MHz (25ns) pulses. Hopefully that's not the root of my problems, that would be a bad day!

After fixing a few additional issues around data matching (inverted logic is hard!), the first - what appears to be - true difference in behavior is observed: <<<t80_first_differnce.png>>>. This is early enough in the boot that we should be able to trace it to an instruction even with this very limited visibility. What appears to be happening though is that the T80 starts the M1 cycle too late (one cycle too late) and thus catching the WAIT train in the wrong phase.

There is an OUT that terminates the first phase of the boot. That OUT seems to be this one:

                ; Note, different contents again for address 0.
0000    D3      OUT     (0F8h),A        ; A is still 0.
0001    F8
                ; This is the "end bootstrap mode" sequence.
                ; Execution continues in the copied boot ROM, see
                ; below.

Then we have M1 RFSH RD RD. This corresponds to this instruction:

0002    01      LD      BC,83F3h
0003    F3
0004    83

After that, we have:

After that we have M1 RFSH M1 RFSH IOWR. The reason for the two M1 cycles must be that this is a prefix instruction:

0005    ED      OUT     (C),B
0006    41

This is followed by M1 RFSH M1 RFSH M1 RFSH M1 RFSH M1 RFSH RD (i.e. 5 instructions, the last one needing a second byte). That matches:

0007    0D      DEC     C
0008    78      LD      A,B
0009    05      DEC     B
000A    87      ADD     A,A
000B    20      JR      NZ,memmaplp
000C    F8

The first time, the jump should take, but apparently a taken jump takes one extra cycles on the T80 compared to the real thing. That's weird. What should the timing be?

It should be 12 cycles for branches taken, 7 for not taken. But that's without wait-states. The M1 cycle catches the right phase and doesn't incur any extra waits. Indeed all cycles are 0-wait-state, so it should take 12 cycles total. And it does. For the Z80. For the T80 however, it's 13. That'll take some tracking down, but at least the fact that no wait-states complicate the picture is a good thing. <<<t80_annotated_jr_timing_bug.png>>>

Created a small simulation environment to test the issue. The code is the following <<<sim/cbranch_timing_test.asm>>>. This shows an interesting problem: the jump taken is now **3** extra cycles instead of 6, as in real HW. This has probably something to do with the wait-states. Either way, 3 is just as incorrect as 6. So let's investigate (BTW: the timing of the jump not taken is correct)! So the reason for this was simply an incorrect generic setting: 'MODE' should be set to 0, which is traditional Z80, not 1, which is fast Z80. This was a simulation only problem, so that is not an issue. What *is* an issue is that in the real HW, the wait signal is apparently honored even though it shouldn't be. Let's try to re-create the problem. This will take some finessing to find the right phase of the wait signal. BTW: not sure if the Z80 did honor wait-states in this machine cycle. It doesn't generate a memory access signal, so one would think, no. We can probably test it in the visual Z80... Luckily I got it right the first try and in fact, I see the problem: now we have 6 cycles.

So, I've implemented a fix that ignores wait-states when NOREAD is set. This is the signal (rather mislabeled) that seems to be controlling whether an MCycle will generate a bus access. It fixed the timing of the jump instruction, but also affected the timing of several dozen other instructions: NOREAD was set in many many places.

Trying the change in real HW, I see a marked improvement: the timing now lines up at the spot where it didn't before. BTW: it's nice that the markers SHIFTED in SigRok between runs. Not sure why, the trigger should be repeatable. At any rate, SigRok is not the pinnacle of SW maturity.

The control signals seem to stay in sync all the way to the end of the trace, which is nice. There are 'data_match' triggers, not sure I should take them seriously. What might be more interesting is address mismatches: those would be indicative of divergent control flow and would start triggering like crazy if we get there.

Actually, I think I should take them seriously. Let's try to figure out where they start triggering. <<<z80_data_mismatch.png>>>. This start happening soon after the 5th OUT statement.


0012    D3      OUT     (0F8h),A        ; start drive motor(s)
0013    F8
0014    11      LD      DE,0732h        ; E = wait_for_disc loop variable
                                        ; D affects no. beeps on error
0015    32
0016    07
                ; Sit around for about 100 seconds, prodding the
                ; FDC every so often to see if there's a disc.
            wait_for_disc:
0017    06      LD      B,0C8h
0018    C8
0019    DC      CALL    C,delay
001A    B1
001B    00

The first mismatch is when we try to push our PC to the stack. That's bad, actually. That means that we've had divergent control flow prior to this point and we only kept in sync because we've force-fed the instruction-stream to the T80. So, indeed, we should look at address mismatches.

Hmm... The address mismatches start at the first branch (JR) instruction. The timing matches, which is to say that the branch goes the same way, yet the address doesn't match afterwards? That's weird. Hold on! Looking back at the sim, indeed, the branch doesn't happen. WTF?! So it turns out more fixes need to be sprinkled around: the wait-state was guarding several paths, all needing changes. With that, we're progressing a little further.

We get into the call, but the address mismatches start soon after...

            delay:
00B1    3E      LD      A,0B3h
00B2    B3
            delaylp:                    ; inner loop controlled by A
00B3    E3      EX      (SP),HL         ; beefy NOPs?
00B4    E3      EX      (SP),HL
00B5    E3      EX      (SP),HL
00B6    E3      EX      (SP),HL
00B7    3D      DEC     A
00B8    20      JR      NZ,delaylp
00B9    F9
00BA    10      DJNZ    delay
00BB    F5
00BC    C9      RET

OK, this is *highly* problematic here. So, this is the second instruction that is the issue: EX (SP),HL. What the Z80 is doing is two reads followed by two writes. The T80 does it one byte at a time. <<<z80_ex16_issue>>> Not sure if this is benign or not, but would be a very involved thing to fix. I've verified the operation in simulation as well. This is troubling, but not sure if it's important. Technically one could envision a case where it matters, but only if someone implemented some 16-bit peripheral that depends on atomic reads *both* from a HW and a SW perspective. This is extremely unlikely.

The problem though is that this behavioral difference throws all sorts of sand into the gears of shadowtracer. Maybe it wasn't all that hard. I have a prototype fix that seems to do the trick. Let's test beef up the test-case to be self-checking at least for correctness and then check for real HW.

Actually, as usual this was way more complicated as expected; there's a lot of dependency on special signals, in fact, I had to introduce a new control signal to MCode to handle all the intricacies. At any rate, the unit test seems to be passing now, so maybe it's time for an FPGA test?

Hmm... Things are not quite what they should be still: the first EX (SP),HL seems to work, but the next one reports an address mismatch. This seems to indicate some problem with SP getting corrupted?! But I don't see that in the simulator. Maybe if I add back wait-states? Is it possible that we double-touch SP? Oh! It's only the write part that mismatches, wanna bet that the bytes are written in reverse order?

Yup, that was it!

Setup issue on RQM bit from FDC
-------------------------------

Looking at the trace later in time, we do get address mismatches. It's difficult to say where they start to appear as the initial, synchronized trace looks perfect. One can try a longer trace or clean up the trigger signals and trigger on the actual mismatch comparators.

Unfortunately even the longest trace shows no signs of disagreement. I think I'll have to clean up the comparators as a next step!

In order to make forward progress, I'll have to leave the LA I'm using (I need to ship it back for the return anyway). It doesn't give me enough visibility. What I did do is to bring out the registered (clean) version of ctrl_match, which *does* trigger way into the boot. So it's time to fire up the integrated LA and try to make that work.

SOME GREAT PROGRESS!!! It is quite possible that the integrated LA (GAO) is useable as root. If that were the case, it would indeed be great news and I could keep my $200...

The repro is saved as 'missing_m1'.

The instruction stream seams to be:

0xf170  add a,a
0xf171  jr nc,d

oh... it's pretty obvious: we want to jump in the T80 case, but not in the real world. <<<divergent_branch.png>>> Hmm... So the control mismatch is explained, but not the root cause. For that, I'll need to fire up data bus comparison.

This is interesting: even after enabling data mismatch, we trigger at the same spot. Maybe data mismatch is not ... well, matching? It only tracks writes for sure. Let's look at a slightly wider context...

The previous instruction is an 'IN a,n'. That's great! So, let's seee....

0xf16e  in a, 0  --> reads hmmm... either 0x70 or 0xf0. Hard to say because the data changes on the rising edge.
0xf170  add a,a
0xf171  jr nc,d

OK, if this is true, it is very bad news: we might have a setup violation that goes one way in the T80 and the other in the Z80. For this, I'll need a scope. I can trigger on the mismatch and with enough history, I should be able to see the rising edge of IORQ (or RD) and the change of D7.

But, BUT, **BUT**! The integrated LA is rather reliably suddenly.

So, some more thinking: *if* the T80 reads 0x70, then the MSB is cleared. After the shift, C is cleared, and the jump should happen. At the same time, if the Z80 reads the later value (0xf0), it would set C and thus not jump. While on the LA I can't see the data-bit, I can see the IORQ mismatch. It's a good test for 400MHz capture... The difference is 40ns, in that the Z80 deasserts IORQ later.

So, after cranking up the sampling rate on the GAO as well to about 50MHz, we can see the problem <<<setup_violation.png>>>: the data changes between the rising edge of the internal (T80) IORQ and the external (Z80) one.

Of course the uPD765 doesn't know when IORQ will disappear, it's just that it's slow enough to respond to straddle the two signals.

T_RD is 200ns for the disc controller, which is way way lower than the 625ns (640 measured) low-pulse of the IORQ. Of course I would have to check what nCS for the controller looks like, that's going to be different/shorter.

The ULA delay I actually have already looked at along with the data lines. This is scope trace 70. Data is a bit harder to see, but it's clear that data is driven soon after nCS goes active. nCS itself is delayed by about a clock cycle, so, even arguing for worst-case, the data should be ready 450ns after the assertion of IORQ. GAO shows the difference to be 274-258=16 clock cycles. Each clock cycles is approximately 210/4=52.5MHz or 19ns, so the whole affair takes place in 304ns. Yeah, that's believable. Roughly at least. The IORQ in this case takes 640ns (2.5 clock cycles). That should give us 625-250-200 = 200ns setup time for data. As we will see later, the Z80 specifies 50ns, so timing is met.

What do we get then? We get that the 765 *asynchronously* changes the status output as the read is on-going. Most status bits gets their way onto the bus in about 300ns, but at some later time (any time really) the MSB might flip. Which side we happen to capture it is any ones guess. If that is true, that's really bad news for ShadowTracer though: this ambiguity can't be designed out of the system. Not easily at least.

The Z80 datasheet for it's part (https://www.zilog.com/docs/z80/ps0178.pdf page 22) specifies 25 28 (23) minimum 50ns data setup time and 85ns (85ns) (47.5ns measured) IORQ (and RD) hold times. Again, nothing alarming, everything is within spec.

OK, so this is a bit problematic, but maybe not terribly. We can attempt at this point to re-run the full T80 without shadow-tracer mode: both modified instructions (JR and EX (SP),HL) seem to be part of the write-command-to-FDC routine above. While the first should have improved timing and the second should not have affected it, still, there is some remote chance that the problem was mitigated.

We can also attempt to do this: reset shadow-tracer whenever we see an M1 cycle to 0x0100. This would involve forcing the PC to be that of the externally presented address thus resetting the program flow to the same location. On entry, we could make ZEXALL (if not done already) to clear out all registers. Looking at the source (https://github.com/agn453/ZEXALL/blob/main/zexall.mac) it appears that we initialize every register except for A and B. According to https://rvbelzen.tripod.com/cpm3-prg/cpm3prg2.htm CP/M system calls don't save/restore registers, thus there probably won't be any PUSH A/B in there. At least not before their content is blasted away. Flags, I'm sure get destroyed very quickly too.

So that's what we're going to do. If this works, we should be able to execute ZEXALL and (very slowly) scour the instruction set for any further mismatches.

DEC (HL) and INC (HL)
-----------------------

BTW: it seems that at least after a while we find our way back to the same execution stream (PC matches again), but there are still mismatches triggering GAO.

(z80_data_mismatch2.png)

Here the issue might be spurious: we're getting a half-cycle data-mismatch, which we're driving the data-bus, but not yet WR. By the time WR gets asserted, we're in sync. Well, maybe not: the datasheet says that we should be driving the proper data out when we assert MREQ.

This normally should be benign, except that the PCW doesn't take WR into consideration for address decoding. If it's not a RD (and it's not) than it's a write (RD gets asserted in sync with MREQ). So, of someone foolishly depends on the falling edge of MREQ for capturing the databus data, we might be doing things wrong here. So what is this instruction?

0x1384   35  dec (hl)

It is the write phase of this thing that presents the wrong data. BTW: this doesn't seem to matter at all even: all writes present this problem, though not all trigger the full wrath of 'match' getting asserted.

This is strange: the simulation shows proper behavior. That is, data is presented with the same edge as MREQ. In fact, this bears out in the FPGA trace as well for *most* writes. In fact we are - as usual - faster than the Z80 in setting up the data, thus the brief mismatch.

What's curious about this particular case though is that we underflow the value (go from 0 to 0xff). Let's try that in sim...

Cool! We have a repro!!! It's not the underflow, actually, even the second dec (hl) has this issue. It's an unfortunate value chosen so that the first attempt didn't show the issue. So, what gives?!

So, it turns out, I've already fixed this issue for other read-modify-write instructions, just missed INC/DEC (HL). It's an easy fix, we just need to introduce "Early_T_Res <= '1';" to cycles M2 and M3.

Great, that fix took hold and now we're idling (after OS boot) with no triggers and synchronized PC.

This sets the stage for a ZEXALL run!

ZEXALL
------

Started ZEXALL at 6:11pm. This will take a while. Hopefully...

So, not sure when (didn't pay attention) but the LA eventually triggered during ZEXALL. And now I'm rebooting for some random reason. Probably interaction between the FTDI chips.

At any rate, let's re-run! From what I can tell, this was a data mismatch as the control signals are identical.

In fact there was another mismatch (also a data one) during ZEXALL load. Let's investigate that while we're waiting on the other one to repro...

(data_mismatch_during_zexall_load.vcd)

Here we seem to write 0x44 into address 0xff48 instead of what we should (0x6c). No idea where this value is coming from; the instruction seems to be a PUSH AF.

It is the second write, so it's (probably) F. So we have a flags mismatch.

0x44 decodes to 10001000
0x6c decodes to 10101100

Bit 5 is not used, that's one difference. Bit 3 is also not used, that's the other difference. Not used at least in the documented way.

I'll let this one slide for now.

So let's keep on waiting for the repro...

We have our repro (first_zexall_mismatch.vcd). This is the same problem. The next trigger is the same problem as well.

The documentation says a lot about bit 5 and 3. What does the T80 do about them? (I think there was even a comment that they are not handled 100% correctly). Actually the documentation says it's 'almost 100%'. (The flags behavior is described here: http://www.z80.info/zip/z80-documented.pdf, chapter 4).

On this, it very much appears to me that the code meticulously implements chapter 4, but forgets about the default behavior: Flag_X and Flag_Y are normally just bit 3 and 5 of the result. Actually, that's probably not the case. Line t80.vhd:858 seems to be dealing with it:

						F(7 downto 1) <= F_Out(7 downto 1);

Yup, and the ALU seems to be doing the right thing. So then, why are these set incorrectly so often? I think I'll need a test-case for this! Something better than ZEXALL...

At any rate, since no (documented) Z80 code should depend on either of these bits, this is not an issue for disk-IO.

Mid-point review
................

So, where are we after all this?

1. We've changed the timing (improved actually) of conditional jumps in the taken case. This should not have an impact on disk-IO. If anything it should regress it further.
2. We've changed the order of of the memory operations in EX (HL),BC, but not the timing. This instruction *is* used as a delay loop component, but - since we haven't changed the timing - it should't have an impact.
3. We've fixed the data presented on the first cycle of writes for in-place INC (HL) and DEC (HL) instructions. This *could* have caused some issues, but why would they only impact disk-IO? Plus, if they do, that would be really sloppy system design: one would have to use the falling edge instead of the rising one to capture the write data. And since the memory controller (the only place that these instructions can target) needs to issue a /RAS and a /CAS cycle, it is next to impossible to screw this up.
4. We've seen a problem where the FDC controller changes its mind about the RQM flag mid-status-read. This can cause issues, in fact it does cause issues where the T80 and the Z80 disagree on the status bit. Technically it can also cause meta-stability, but I doubt that would be a problem. And an incorrect reading just results in an extra execution of a delay loop, so I don't see how this could be the root cause. And of course, there's almost nothing that can be done about it either.
5. We see the X and Y flags (both being undocumented) set incorrectly at least under some circumstances. It would be good to know under what, but - since we know that ZEXALL is passing on the T80 - it can't be all that well documented. All the failing cases I've seen so far have these flags SET on the real deal while CLEARED on the T80. Some targeted tests might get me closer, but that's a PITA to do as I would need to execute it under CP/M. Plus, this is almost certainly not the problem, it would be shocking if CP/M depended on undocumented flags behavior even as a bug.

Of all this, the most likely (maybe better to put it this way: least unlikely) culprit is #4. But that's the one I don't think I can fix. Well, maybe I can: I can re-read the register and repeat until I get two consistent readings, but that's ... yuck. (I can't under any circumstances *repeat* the read transaction. That's a big no-no. I can however insert extra wait-states and keep sampling the data-bus beyond what is defined by the system if the previous two readings disagree.) So, this is how it would work:

T1: as usual
T2: as usual
T3: stay here, until WAIT samples high, also sample DATA
T4: sample data again. If different, stay in T4 for one more cycle.

Now, there are two reasons why this is not good:

1. In T4 we release IORQ and RD in the second half of the cycle, when we sample the DATA. The comparison happens after, we can't really - easily - go back in time and undo the decision about the release
2. In our failure case, RQM changes after we've sampled it. The Z80 samples a little latter and sees the change. This double-sampling would not catch the problematic behavior.

Post-rising-edge sampling is not a valid solution either: the data hold time requirement by the DS is 0.

But, maybe I got lucky and these things have fixed the problem? I don't know that, actually.

Back to the flags problem
-------------------------

Flags are rather volatile, right? They are more or less set by every instruction. So, looking back in the trace, I should be able to identify the place where they got corrupted!!

1C41  ED B0          LDIR <--- we've gotten an interrupt here
0038  C3 A1 FD       JP FDA1
FDA1  ED 73 A3 FE    LD (FEA3), SP
FDA5  31 4A FF       LD SP, FF4A
FDA8  F5             PUSH AF <--- this has wrong X and Y flags

OK, now we're talking!!!! This is chapter 4.2, and one of the weird corner-cases of X,Y register handling. I'll copy it here:

        The LDI/LDIR/LDD/LDDR instructions affect the flags in a strange way. At every iteration, a byte
        is copied. Take that byte and add the value of register A to it. Call that value n. Now, the flags
        are:

        YF flag A copy of bit 1 of n. <-- bit 5 of F
        HF flag Always reset.
        XF flag A copy of bit 3 of n. <-- bit 3 of F
        PF flag Set if BC not 0.
        SF, ZF, CF flags These flags are unchanged

What does the T80 do? Well, nothing special! This is *bad*. And, most importantly, testable!!! But that's a thing for tomorrow. Well, turns out there *is* special handing for the X/Y flags for these instructions. The 'I_BT' signal is set, which has some special-casing. There are a couple of options:

1. The flags handing is botched still
2. The interrupt handing causes the flags to be set differently between the two implementations. (Such as flags are not updated in the T80 in time for the interrupt to pick them up.) Though that would be very bad if it were the case as the loop termination would be affected.
3. It's also possible that interrupt handling is done such that the iteration is one-off in the two implementations. Though, again, it's unlikely that it would effect only these instructions and interrupts are firing left right and center, normally without triggering differences.

The first test, A=2 and the byte is 0. This means that bit 1 of the sum should be 1 and bit 3 should be 0. The X and Y flags are set as they should be.

Similarly, for all other test, the bits seem to be set as they should be. That's good and bad, I guess. Can it be that the documentation is wrong about this?

Let's try to reconstruct the problem from the LA logs. After all, we have visibility into the data being copied and A as well (through the PUSH).

        A = 0x02
        F = 0x64 (T80) 0x4C (Z80)
        byte = 0

So, following the logic described above,

        n = 0x02 (0b00000010)
        n[1] = 1 --> Y should be set, so F[5] should be 1 (Z80 is 0)
        n[3] = 0 --> X should be clr, so F[3] should be 0 (Z80 is 1)

In both accounts the T80 is correct, the Z80 is incorrect. Which of course is preposterous, the Z80 cannot be wrong by definition. Oh! The bits are swapped!!! Could that be?! In another instance (second_zexall_mismatch.vcd):

        A = 0x0f
        F = 0x2C (T80) 0x04 (Z80)
        byte = 0x60

        n = 0x6f (0b01101111)

        n[1] = 1 --> X should be set, so F[5] should be 1 (Z80 is 0)
        n[3] = 1 --> Y should be set, so F[3] should be 1 (Z80 is 0)

In both accounts the T80 is correct, but the Z80 is not bit-swapped! So it's not that simple. In fact, if we look at 'n' here the only two bits that are 0 are bit 7 and 4. Those were both 0 in the previous case as well. So it appears the documentation is rather incorrect and something more complex is afoot.

I think I'll have to roll up my sleeves and get CPM-based test disk creation working. Let's start by making a ZEXALL disk from source....

Building cpmtools needs building libdsk. This can be downloaded from https://www.seasip.info/Unix/LibDsk/#download, but it doesn't work right out of the bat. One needs to modify two compress.c and drvlinux.c to include the following:

        #ifdef MAJOR_IN_MKDEV
        #include <mkdev.h>
        #endif

        #ifdef MAJOR_IN_SYSMACROS
        #include <sys/sysmacros.h>
        #endif

Dependencies seem to include lyx which is some sort of LaTex package.

OK, as usual, things took *way* longer then they should have, but I finally have a CP/M bootable disk image with my custom code on it. Yay! I can compile and execute CP/M applications.

OK, so what do we learn from this? We do get a fairly reliable triggering of the failure, but, interestingly it's always preceded by an interrupt. It's also usually one of the two repros above. Weird.

Let's try to disable interrupts in the test and see if we get anything!

OK, so even after disabling the interrupts, I get the same behavior. Also, just to be clear, the PC is *not* in my
test code. This seems to indicate that the difference is not in instruction behavior but in interrupt handling behavior.

That *sucks*.

But actually, this is a 3rd set of data:

(third_zexall_mismatch.vcd).

Here we see:

        A = 0x00
        F = 0x6D (Z80) 0x45 (T80)
        byte = 0x44

        n = 0x44 (0x01000100)
        n[1] = 0 F[5] is 0 for T80 1 for Z80
        n[3] = 0 F[3] is 0 for T80 1 for Z80

Let's try to make the test longer so I can safely trigger inside it!

Yeah, at this point, I'm 99.999% certain, this is interrupt behavior that's different, not actual
instruction behavior.

Which, BTW is interesting: interrupts DESTROY the X Y flags, thus they are not all that useful. But that's besides the point, to match the behavior, I'll need to figure out what is going on.

Is there any way to see what the previous set of flags should have been?

So, in this particular iteration:

        A = 0x01
        F = 0x04 (Z80) 0x2C (T80)
        data = 0x2E
        data -1 = 0x02
        data -2 = 0x2E

        n    = 0x2F (0b00101111) [1] = 1 [3] = 1 F[5] = 1 F[3] = 1
        n -1 = 0x03 (0b00000011) [1] = 1 [3] = 0 F[5] = 1 F[3] = 0
        n -2 = 0x2F (0b00101111) [1] = 1 [3] = 1 F[5] = 1 F[3] = 1

        NONE of these matches the Z80, which is F[5] = 0 F[3] = 0

So, it's not that the interrupt happens before updating the flags. The flags get overwritten during the interrupt process. There are of course several instructions between the interrupt and the PUSH AF, so there is a possibility that some of those alter the X Y flags (in the Z80) while don't touch them in the T80. So, here's what's happening:

        1C41  ED B0          LDIR <--- we've gotten an interrupt here
        0038  C3 A1 FD       JP FDA1
        FDA1  ED 73 A3 FE    LD (FEA3), SP
        FDA5  31 4A FF       LD SP, FF4A
        FDA8  F5             PUSH AF <--- this has wrong X and Y flags

The JP should not affect any of the flags according to documentation. The first load is missing from the instruction table, not no load is marked as altering any of the flags (as they shouldn't). Same goes for the second load. And then we get to the push, which of course already exposes the problem.

So, I really don't think that any of the instructions mock around with the flags, which leaves the interrupt handling itself. How can we gain visibility into this though? Maybe the visual Z80 can give us some clues?

At any rate, I haven't uncovered anything tragic, so let's try to build a CPU image!

And, as expected, the hang is still there with disk operations. I can try removing all superfluous logic, such as the OLED driver and see if that makes a difference...

Yeah, that didn't make a difference either. Of course, as I haven't changed anything that should have made a difference, so it's no surprise nothing did.

OK, so this leaves us with the one issue around the uPD765 mocking with the status bits mid-read. Could that be the problem? I said before that I could set up a trigger for that (in shadow-tracer mode) and look at the timing more carefully on the scope. Maybe it's time for that...

OK, so there's one more thing that I can do: mask out the existing triggers and try to run ZEXALL to completion.

But first, let's do the scope thingy...

OK, I have the repro going. What I want to do is this:

- Trigger on 'match' a.k.a. io5a (pin 9)
- Look at D7
- Look at CS on FDC (pin 4)
- Look at RD on FDC (pin 2)

As a second one, look at D7 and D6 (or some other data pin) to capture the delta. So let's set this up!

OK, I need new probes. But besides that, I've learned that the 'match' signal tirggers quite often.

But I don't quite get what's going on for the control lines. Let's double check!

So CS is on channel 3 and that's low for many many many cycles. But that's fine because that's just A7.

So, the theory goes that either WR or RD must be low on top of CS to select this chip.

Now, the mismatch doesn't seem to happen during a *read*! I don't see the write, but that's probably what I should be looking at instead of CS: the address hold time is greater than 0 just as the setup time, so the actual chip-select will be bounded by those signals. So...

Oh, hold on! The mismatch happens when the branch happens, there should be a read shortly before that. That's the signature I'm really looking for.

FDC RQM bit issue, looking at the scope, it is clar (00081) that the RQM signal changes mid-read, after about 400ns from the start of the read. It starts by clearly being driven 0 but then changes it's mind and gets driven high. I think that was what the LA told me as well... Maybe not, but I can't really find that note. At any rate, clear violation of the DS.

So I have symultaneous captures both on the LA and the scope (00087). This is very different though! What's going on here?

More control mismatches
-----------------------

So, the piece of code triggering here is this:

	di			;1f50	f3 	.
	ld hl,(026e0h)		;1f51	2a e0 26 	* . &
	ld a,h			;1f54	7c 	|
	or a			;1f55	b7 	.
	jr nz,l1f32h		;1f56	20 da 	  .
	ld (026e4h),a		;1f58	32 e4 26 	2 . &
	ld hl,(l23d0h)		;1f5b	2a d0 23 	* . #  <----------- CTRL mismatch
	ld a,h			;1f5e	7c 	|
	or a			;1f5f	b7 	.

So, neither core wants to take the jump at 0x1f56, they execute the store in sync (we can see that A is 0)

But the next instruction is something completely different. For the Z80 it seems it's something that stores
1F5B at location 2764.

Oh, I know what's going on: it's an NMI. IT IS AN NMI!!!!

So one thing: I need to capture NMI. But the T80 either didn't take the NMI at all or it didn't take it at the same time.
Which is bizare as we do know it takes the NMI just fine.

Let's try this with a few more signals captured!


OK, I can't seem to get to this mismatch, but there's another one with a trivial repro: every ENTER triggers one.

Mismatch on Enter
------------------

Oh, this is the interrupt during LDI, I'm sure. It has the same signature. So let's try to ignore this.

Trying to fix the flags problem
-------------------------------

While writing up what the Shadow Tracer article, I realized something: all captured examples have both X and Y flags negated compared to the T80. Could that be that the interrupt handling causes this?

Tried to flip the flags. It was rather simple to do for all instructions, but this is a non-starter: now I get many many many mismatches on all sorts of instructions.

So the next idea is that it only happens on 'repeated' instructions. Though I'm not sure why that would matter.

The second attempt - only inverting for LDI/LDIR/INDR etc. instructions seems to have 'fixed' the problem. At least masked it.

The next problem is another PUSH AF mismatch.

Another FLAGS mismatch
----------------------

Now the T80 pushes 0x80 while the Z80 pushes 0xA8. This is again a full inversion of both X and Y flags. But, this time around it's without an interrupt being fired. What is the previous instruction? (If it is an LDIR, I'm going to get rather angry!)

Weird, we're in this part of the code:

                        push hl
        0xfdcc 2a a7 fe   ld hl, (0xfea7)
        0xfdcf 22 b9 00   ld (0xb9), hl
        0xfdd2 ff         rst 0x38
        0x0038 c3 40 1e   jp 0x1e40
        0x1e40 f3         di
        0x1e41 e5         push hl
        0x1e42 f5         push af			;1e42	f5 	<-- fail here

(sw_int_flags_issue.vcd)

So, we are in the interrupt handler allright, except through a SW interrupt. Damn it! We don't see far enough back in time to know what went down here. I can at least try to figure out if the VHDL inverts the flags...

It doesn't.

How to fix that? Well, of course set 'btr_for_int' in case of a RST 0x38, but that's not that simple as BTR_r has long since been cleared. In fact, to handle this, one would need a completely different logic: set a bit when LDI/R etc sets the flags and reset it if any other instructions sets them. Since in this case there could be several instructions separating the LDI form the actual interrupt.

Hmm... Now that I tried to re-capture this thing, I got a flags mismatch in an actual HW interrupt. Grrr...

Back to HW interrupt flags
--------------------------

(flags_mismatch_on_xor_int)

OK, this is interesting. We get interrupted here:

	push hl			;115c	e5 	.
	push bc			;115d	c5 	.
	xor a			;115e	af 	.  <-- interrupted

Now, the interesting thing is that the push operations should not have altered the flags, but the XOR does!!
The mismatch itself is the usual F problem T80: 0x6c, Z80:0x44 Again, both flags are the inverse of what they should be. But... why???

I've traced it back all the way, so it seems that A was zeroed out before the XOR here (there's a bunch of calls and pushes and what not in between).

The XOR happens at 0xBB2D.

At any rate, that means that both X and Y should be set to 0, yet in the T80 they are set to 1. But WHY???

I think I'll have to trace the logic that controls the swapping more carefully. Something is amiss here.

OK, I was an idiot: I've triggered the inversion for every interrupt. Now however I still have the issue:

The inversion gets tirrgered, the data is 0x7b, A is 0, so X and Y should both be 1. After the inversion they should both be zero. Indeed, that's what the T80 is doing, yet the Z80 now keeps both bits set. Maddenning!

I think I will just disable data tests on push AF. Somehow...

OK, the way I've done this is to introduce three 'debug' signals: ignore addr/data/ctrl mismatch. These are generated by MCode and routed all the way out to the top to be used by ShadowTracer. A little hacky, but got the job done on the first try. So hopefully I will see something novell now...

For now, I will completely ignore control mismatches and see if I catch anything.

So we did catch something. No, not really. This is still just the ripple-effect of a control mismatch: the way we recover from the extra loop is that our PC is screwed up until the next absolute jump. This happens to be call, I believe to F1CB, so the pushed address is incorrect. Maybe I should ignore all pushes in calls? This is a rather blunt instrument, but should work. Of course I'm continously pokeing holes in shadow-tracer with these...

R register mismatch due to previous control flow mismatches
------------------------------------------------------------

This might finally be something unseen? The code in question is this:

sub_23dch:
	ld (00060h),hl		;23dc	22 60 00 	" ` .
	ld (00062h),de		;23df	ed 53 62 00 	. S b .
	in a,(0f8h)		;23e3	db f8 	. .
	and 010h		;23e5	e6 10 	. .
	ld a,006h		;23e7	3e 06 	> .
	jr nz,l23ech		;23e9	20 01 	  .
	dec a			;23eb	3d 	=
l23ech:
	ld (00065h),a		;23ec	32 65 00 	2 e .
	ld a,001h		;23ef	3e 01 	> .
	ld (02791h),a		;23f1	32 91 27 	2 . '
	ld hl,l0a08h+1		;23f4	21 09 0a 	! . .
	ld (0277fh),hl		;23f7	22 7f 27 	"  '
	ld a,r		;23fa	ed 5f 	. _
	ld (026e5h),a		;23fc	32 e5 26 	2 . &  <-- mismatch in A
	ld (l23d9h),a		;23ff	32 d9 23 	2 . #  <-- mismatch in A
	ld hl,04000h		;2402	21 00 40 	! . @
	ld d,090h		;2405	16 90 	. .

In other words we have a mismatch in the R register. That's, well, irrelevant. Not sure why the code cares... But how should we ignore this? One possibility is to override the R register from the outside every time we see a refersh. This is quite a bit of surgery though. Oh, the idea apparently is that the R register is somewhat random, so you can use it a source of a PRNG. That would explain why the code cares. Also, why I don't...

Before I do that, just out of curiousity: let's re-enable the ctrl mismatch and see if the refresh counters get out of sync or are always. Yeah, they do. So the reason they get out of sync is due to the control mismatch. In fact every ctrl mismatch increases the difference by 1. This even gets us a sense of how many such events are there.

At any rate, let's see if it's easy to sync up the R registers... The update happens in T80.vhd:556. We need to supply in the override and make it hapen.

OK, so I think the trick worked. Now RFSH is always on off, but that's because it *has* to be the previous value. Unless I'm willing to increment it too...

It's good enough for now, let's disable ctrl mismatches and see what I get...
	exx			;2044	d9 	.
	push hl			;2045	e5 	.
	push de			;2046	d5 	.
	push bc			;2047	c5 	.
	exx			;2048	d9 	.

Grrr!!!! It still hits. But why?! It seems that we didn't have a chance to write back R to the register-file (because, why not, it exists there as well). So, we seem to be outputting an outdated value. BTW: this would have been a real difference between the T80 and the Z80, albiet minor. So let's track it down in the simulator and fix it!

This is interesting... What I see here - in simulation - is that R gets incremented after the last M1 cycle (for the ld a,r instruction), and that is what gets loaded into a. In other words, in sim, R is one greater than what was presented on the bus. What does the real thing do?

Well, I haven't saved these captures, so I'll have to re-look at them in the real HW...

OK, the repro is saved in <r_reg_mismatch.vcd>. The Z80 saves 0x48, while the T80 saves 0x46. The Z80 R for the 'LD A,R' instruction was 0x47 for the Z80 and 0x46 for the T80. So, the original T80 behavior is correct, but somehow I messed it up while modifying the R behavior.

So, what I did, was that the *previous* refresh cycle loaded R from the bus (that was the 0x46 value). This is the one presented on the bus in the next refresh. Indeed the problem seems to be in the override: we load the presented R value a cycle later than the normal increment would otherwise happen. This means that not only we load an old (-1) value, but we load it after the increment would have occured. So, instead I'm incremented the presented R now by two in the load, that should fix this issue (note: incrementing only the bottom 7 bits as the refresh counter was only 7 bits long).

This was an ugly hack, but maybe it stuck. At least it seems I'm triggering on something different this time...

Alternate register mismatch?
-------------------------------

Oh, it's this:

	exx			;2044	d9 	.
	push hl			;2045	e5 	.
	push de			;2046	d5 	.
	push bc			;2047	c5 	.
	exx			;2048	d9 	.
	ex af,af'		;2049	08 	.
	push af			;204a	f5 	.

But this time, it's A that doesn't match. And it doesn't match by a large margin: The Z80 thinks it should be 0x83, while the T80s idea is 0xff. F is also different (0x50 in the Z80 world, and 0xff again in the T80 one). I'm wondering if this is an initial state mismatch?

However, this is strange: we're in essence saving the whole alternative register context. Yet, it's only A and F that are triggering. And 0xFF is suspicious. I wonder if this is the only error? I'll save this <alternate_af_mismatch.vcd> and put a hit counter in the RAO file.

Interrupt mismatch?
---------------------

This is now triggering on the second data mismatch (BTW: I'll have to inhibit ctrl mismatch in a different way such that they still show up in the capture)

This is saved as <interrupt_mismatch_core0.vcd>

Here, we get an interrupt (though it's not captured in the RAO file, another mistake I'll need to correct).

However the point at which the interrupt is handled is different in the Z80 and the T80. It seems that the interrupt occurs somewhere here:

	ld hl,02943h		;1400	21 43 29 	! C )
	ld a,(de)		;1403	1a 	.
	ld c,a			;1404	4f 	O
	ld a,(hl)		;1405	7e 	~
	ld (hl),c		;1406	71 	q

Both processors executes the first instruction (ld hl,xxx) to completion. After that though, the T80 goes into interrupt handling where the Z80 executes the next one (ld a,(de)). So, maybe the T80 looks for interrupts in a different spot in the FSM? That sounds unlikely. Anyway, let's add the actual interrupt line and re-run.

OK, we've lost the repro. Not all that suprising, being an interrupt-based problem.

NMI-related mismatch?
---------------------

This time we trigger on the trail-end of an NMI routine. But it *is* actually the same problem: even for NMI, the T80 is quicker to respond than the Z80 is. Quicker by one instruction on the macro scale. I think I'll clean up and check my changes in before attacking this. It's getting too convoluted, and this is a true mismatch that needs fixing.

So, let's think this through:

NMI *clearly* is asserted at the same moment (or is it??? It is async, thus could be on different sides of a clock edge for the two chips - nah, the NMI triggers at clock cycle 1913, the clock edge is at 1916. Given that the sampling clock is running at around 50MHz, this is 60ns delta. That must be sufficient setup time. - well, actually, for NMI, it seems it's not timed to a clock cycle and for interrupts the setup time is 80ns. Hmm??? At any rate, let's for the samek of argument, assume that's not it.)

> The datasheet says: the CPU samples the interrupt signal with the rising edge of the last clock cycle at the of any instruction. When an interrupt is accepted, a special M1 cycle is generated. ... NMI is sampled at the same time as INT but has higher priority.

So, that is: the last rising edge of the last M cycle. Well, maybe that comment was prescient. The NMI changes right around that clock edge. If it needs longer setup time by the Z80 for some reason, we could see this difference.

This is relatively easy to verify: we could trigger on NMI (or INT) instead and see if we get cases wehere the CTRL flow is identical.

This particular trace is saved as <nmi_mismatch.vcd>

That was quick; And yes, the NMI does not necessarily trigger a control flow mismatch. Probably in most cases it doesn't.

The way the Z80 responds to these signals is strange though: it executes the next M1 cycle, that is, it fetches the instruction code for the subsequent instruction, but *doesn't execute* it. Instead, it performs a store of PC (which then points to the just fetched address) on the stack and jumps to 0x66 in the NMI case or 0x38 in the interrupt case <nmi_match.vcd>

Now, another interesting observation is that the NMI mismatch happens in this code fragment:

	ei			;1f2f	fb 	.
	jr l1f50h		;1f30	18 1e 	. .

Is it possible that EI is special-cased in the Z80? Let's see if it's always that instruction that mismatches! Nah, that would have been too ieasy: the INT mismatch happens in this code context:

	ld hl,02943h		;1400	21 43 29 	! C )
	ld a,(de)		;1403	1a 	.
	ld c,a			;1404	4f 	O

Nothing interrupt related here. So that leaves us with another setup violation difference?! That would be sad.

This might need some drastic measures to fix. I'm thinking the following:

1. Measure falling edge rate on the NMI line
2. Measure true setup time in the failure case (we have a trigger for that on io5a).
3. Cut the NMI and INT lines (pin 17 and 16) and loop them through a 74HCT74 or similar to register it to the falling edge of CLK. We could even do the same with D7 potentially, but there we would have to be more careful about the capturing edge: M1 cycles need to capture on the falling edge, normal read/write on the rising one. BTW: the 74HCT74 has 20ns propagation delay and 12ns setup time requirements. That seems to be born out by the data. Either that or (grudingly) put together another FPGA board and use that? I can lift the FPGA off after-the-fact, I guess and with the diode-fix, the switcher probably would work (or I could just short and supply direct 5V to it instead of through the diode...)
4. I can try to engage the IDelay in the I/O cells and banahce the sampling location between the Z80 and the T80. Probably won't be perfect, but maybe good enough? At least it's something I can do remotely. Apparently the IODELAY primitive allows delay of inputs in ~30ps steps up to 127*30=3.8ns total delay. That's not a ... lot. Still, worth a shot? We can see that output signals differ by about 2-3 (50MHz) clock cycles. Now, that's not input and it's not really a well-time path inside the FPGA either. The DS for instance reports 100ns rise and fall times for M1, and that's for the CMOS version. 3 clock cycles would be 60ns. As a contrast the T80's internally reported fall-time is less than 20ns. I don't think <4ns will make any difference. Should we register with OLED_CLK though? That gives us 20ns resolution... 10, if I employ both edges. It's async though to the 4MHz, so may not be all that great. One can also add a PLL, get the 4MHz up to - say 80, and control on that level. Let's do that!

So, I've done #4 and - accident or not - I've got a very weird behavior: <int_timing_mismatch.vcd> In this case, the tries to handle an interrupt, while the Z80 seems to never get around doing so. The code to be interrupted in question is:

	ei			;1f2f	fb 	.
	jr l1f50h		;1f30	18 1e 	. . <-- interrupt hapens at the last cycle of this
        ...
l1f50h:
	di			;1f50	f3 	.

This makes it even more mysterious: why doesn't the Z80 get interrupted?! The T80 is happily chugging along with the interrupt request and gets terribly confued by the overbearing Z80 on the bus. What the DS says is EI and *the following instruction* is executed with interrupts disabled. Reproducing a very similar cicumstance, the T80 does precisely what it is supposed to. Not interrupting the 'JR', but the following instruction. But the Z80 seems to be losing the plot here!

This is bizare!!

BTW: there is an interesting discussion about NMI/INT behavior here: https://spectrumcomputing.co.uk/forums/viewtopic.php?t=7086 This is not directly applicable as it discusses the behavior of how far interrupts are delayed in the case of RETN/RETI instructions, which are not part of the insrtuction sequence here.

I've tested very similar code on https://floooh.github.io/visualz80remix/ and it seems it also worked there. I've tested the following memory content:

        0000: ED 56 FB 18 03 00 00 00
        0008: 3D 00 00 00 00 00 00 00
        0010: 00 00 00 00 00 00 00 00
        ...
        0038: 3D ED 4D

        IM 1
        EI
        JR 0008h
        NOP
        NOP
        NOP
        DEC A
        ...
        DEC A
        RETI

The JR finishes at around cycle 23. So, I've tested raising an interrupt in cycles 22/0 all the way to 24/1, all of which properly executed the interrupt handler.

So, even more bizare!!!


I've tested the interrupt timing (picture 86) and it is synchronous with the clock. It start falling just before the falling edge of the clock. Well, that is not true for all cases. In fact, that's not true for FDD-related interrupts. Those seem to be async.

The logic levels on the interrupt line however are very well defined. The falling edge seems to be less tha 10ns, but not sure how much of that is the probing.

There is quite a bit of noise on the high level. That seems to be due to the very weak current source capability beyond 3.3V from TTL: the noise bottoms out at about 3.6V. Not a concern either way. The low level is very well maintained. In other words, yes the IRQ is async, but there aren't signal integrity issues with it.

Let's get back to the IRQ issue. Do I manage to get another repro?

So, with the current settings, we still get NMI handling too early. OK, so now we're too late.

Unfortuantely (as expected) it's not possible to completely eliminate the timing mismatch with a simple 80MHz delay.

So, going back to the previous problem: let's try to capture the interrupt mismatch again.

OK, this is interesting. <int_timing_mismatch> I think I've captured the same problem again: the interrupt isn't firing on the Z80. However, by moving the trigger point to the front of the buffer, I think I see the point where the interrupt *does* trigger eventually on the Z80.

So, let's see what's going on: the first instruction we see is the 'retn' from the NMI handler in this case:

	retn		;1db1	ed 45 	. E

this takes us to here:

	di			;1f50	f3 	.                           <--- T80 things interrupt is here
	ld hl,(026e0h)		;1f51	2a e0 26 	* . &
	ld a,h			;1f54	7c 	|
	or a			;1f55	b7 	.
	jr nz,l1f32h		;1f56	20 da 	  .
	ld (026e4h),a		;1f58	32 e4 26 	2 . &
	ld hl,(l23d0h)		;1f5b	2a d0 23 	* . #
	ld a,h			;1f5e	7c 	|
	or a			;1f5f	b7 	.
	jr z,l1f2ah		;1f60	28 c8 	( .                         <--- This branch happens on the Z80

l1f2ah:
	ld a,080h		;1f2a	3e 80 	> .
	ld (026e4h),a		;1f2c	32 e4 26 	2 . &
	ei			;1f2f	fb 	.
	jr l1f50h		;1f30	18 1e 	. .

l1f50h:
	di			;1f50	f3 	.                           <--- Interrupt happens here on the Z80
	ld hl,(026e0h)		;1f51	2a e0 26 	* . &

So, this is the solution to the mystery, I think: we execute out of the tail-end of an NMI handler, where the Z80 thinks that interrupts are still disabled, while the T80 thinks they are enabled. Consequently, the T80 gets interrupted immediately where the Z80 gets to execute some stuff beforehand. Let's veryify that with the previous trace as well, oh, I've overwritten the file, giving it the same name. At any rate, this explanation makes sense. Except of course now the question is: why is there a mismatch in the thinking of the IFF bit states between the two?

The NMI handler should set IFF1 to 0. Then RETN should copy IFF2 into IFF1. EI and DI impact both flags. Interrupt acceptance is controlled by IFF1 alone.

New interrupt logic
-------------------

I've implemented the new interrupt synchronizer. It is just a 74HCT574 clocked through an inverter from CLK_N to capture interrupt (and NMI) on the falling edge of the clock puse. The Z80 captures these signals on the rising edge, so there should be plenty of setup time there to work with. Scope capture <image 90> shows the effect: the asynchronity of the interrupt that gets cleaned up nicely by this circuit.

So, can we still trigger on the interrupt issues? Hopefully not...

I captured something <ex_sp_hl_mismatch> that seems new. I saved it for later but continue looking for the usual pattern for now.

A new missing interrupt?
------------------------

<missing_interrupt2>

Hmmm... The missing Z80 interrupt situation still happens. This time around, the interrupt happens between executing 0x1d97 (which is a branch apparently) and 1d8c:

l1d8ch:
	in a,(000h)		;1d8c	db 00 	. .
	add a,a			;1d8e	87 	.
	jr nc,l1d8ch		;1d8f	30 fb 	0 .
	and 040h		;1d91	e6 40 	. @
	jr z,l1da0h		;1d93	28 0b 	( .
	ini		;1d95	ed a2 	. .
	jr nz,l1d8ch		;1d97	20 f3 	  .
	dec d			;1d99	15 	.

But hold on!! I've seen this code before!! This is part of the NMI handler. So we should NOT, under any circumstances take an interrupt here. Those should be disabled. Unless, the NMI wire is borken, but then neither the Z80 nor the T80 should work.

Let's undo the re-sampling of the interrupt wires inside the T80 though: that should not be needed anymore.

OK, so we're back to the old problem: we're getting an immediate interrupt after the RETN in the T80 while the Z80 is taking its sweet time.

<missing_interrupt3>

Actually, this is not all that same. This is actually another instance of the T80 taking an interrupt in the middle of the interrupt handler. BTW: this is happening while the NMI line is high. The interrupt line goes low for what reason though? (BTW: it's possible to re-enable interrupts in an NMI handler, but I don't think we ever do). For completeness, here's the entire NMI handler:

l1d32h:
	push af			;1d32	f5 	.
	in a,(000h)		;1d33	db 00 	. .
	and 020h		;1d35	e6 20 	.
	jr z,l1dach		;1d37	28 73 	( s
	in a,(001h)		;1d39	db 01 	. .
	ld (02840h),a		;1d3b	32 40 28 	2 @ (
	push bc			;1d3e	c5 	.
	push de			;1d3f	d5 	.
l1d40h:
	in a,(000h)		;1d40	db 00 	. .
	add a,a			;1d42	87 	.
	jr nc,l1d40h		;1d43	30 fb 	0 .
	and 040h		;1d45	e6 40 	. @
	jr z,l1daah		;1d47	28 61 	( a
	in a,(001h)		;1d49	db 01 	. .
	ld (02841h),a		;1d4b	32 41 28 	2 A (
	push hl			;1d4e	e5 	.
	ld hl,(0283eh)		;1d4f	2a 3e 28 	* > (
l1d52h:
	in a,(000h)		;1d52	db 00 	. .
	add a,a			;1d54	87 	.
	jr nc,l1d52h		;1d55	30 fb 	0 .
	and 040h		;1d57	e6 40 	. @
	jr z,l1da0h		;1d59	28 45 	( E
	in a,(001h)		;1d5b	db 01 	. .
	ld (02842h),a		;1d5d	32 42 28 	2 B (
	ld a,l			;1d60	7d 	}
	out (0f1h),a		;1d61	d3 f1 	. .
	ld a,h			;1d63	7c 	|
	out (0f2h),a		;1d64	d3 f2 	. .
l1d66h:
	in a,(000h)		;1d66	db 00 	. .
	add a,a			;1d68	87 	.
	jr nc,l1d66h		;1d69	30 fb 	0 .
	and 040h		;1d6b	e6 40 	. @
	jr z,l1da0h		;1d6d	28 31 	( 1
	in a,(001h)		;1d6f	db 01 	. .
	ld (02843h),a		;1d71	32 43 28 	2 C (
	ld c,001h		;1d74	0e 01 	. .
	ld de,(0283ah)		;1d76	ed 5b 3a 28 	. [ : (
	ld b,e			;1d7a	43 	C
l1d7bh:
	in a,(000h)		;1d7b	db 00 	. .
	add a,a			;1d7d	87 	.
	jr nc,l1d7bh		;1d7e	30 fb 	0 .
	and 040h		;1d80	e6 40 	. @
	jr z,l1da0h		;1d82	28 1c 	( .
	in a,(001h)		;1d84	db 01 	. .
	ld (02844h),a		;1d86	32 44 28 	2 D (
	ld hl,(0283ch)		;1d89	2a 3c 28 	* < (
l1d8ch:
	in a,(000h)		;1d8c	db 00 	. .
	add a,a			;1d8e	87 	.
	jr nc,l1d8ch		;1d8f	30 fb 	0 .
	and 040h		;1d91	e6 40 	. @
	jr z,l1da0h		;1d93	28 0b 	( .
	ini	        	;1d95	ed a2 	. .
	jr nz,l1d8ch		;1d97	20 f3 	  .
	dec d			;1d99	15 	.
	jr nz,l1d8ch		;1d9a	20 f0 	  .
	ld a,005h		;1d9c	3e 05 	> .
	out (0f8h),a		;1d9e	d3 f8 	. .
l1da0h:
	ld hl,(00061h)		;1da0	2a 61 00 	* a .
	ld a,l			;1da3	7d 	}
	out (0f1h),a		;1da4	d3 f1 	. .
	ld a,h			;1da6	7c 	|
	out (0f2h),a		;1da7	d3 f2 	. .
	pop hl			;1da9	e1 	.
l1daah:
	pop de			;1daa	d1 	.
	pop bc			;1dab	c1 	.
l1dach:
	ld a,003h		;1dac	3e 03 	> .
	out (0f8h),a		;1dae	d3 f8 	. .
	pop af			;1db0	f1 	.
	retn	        	;1db1	ed 45 	. E

There's no re-enabling of interrupts. This is ... weird!!! It's possible though that the strong-arming of the T80 results in this difference. Like, there's a long-gone mismatch that results in the IFF flags to mismatch?! I'm not sure I believe that theory. Especially, because we're in an f-ing NMI handler. Unless... Let's trigger on mismatch during an NMI processing. That's not easy as the NMI singal could go away, but worth a shot.

It hit: <mismatch_during_nmi>. OK, this is a smoking gun! We're hittin an NMI and immediately after, we're taking the interrupt handler. I must have borken something: The T80 can't be this dumb.

OK, I can't find anything. I'll have to sim this. The latest even remotely interrupt-related change was this:

	Auto_Wait <= '1' when (IntCycle = '1' or NMICycle = '1') and MCycle = "001" else '0';

And that wasn't me :). So... No idea.

Oh, OH, OH!!!! So, this is what seems to be going on:

The NMI hits right after the 'EI' instruction, in fact in it's shadow:

	ei			;1f2f	fb 	.
	jr l1f50h		;1f30	18 1e 	. .  <-- Should not get executed due to NMI.

So, the Z80 saves the address 0x1f30 on the stack and goes on to address 0x66. The T80 however gets terribly confused and issues an interrupt with address 0x66 (the NMI vector). In other words, the T80 has a serious priority inversion issue going on. This is *probably a real issue*!!!! I'll need to sim this. From the T80s perspective, it seems that INT and NMI hits in the same cycle -> INT gets higher priority. Or something similar...

OK, so things are not that simple: a trivial test with aligned interrupts and NMI don't fire. I'll have to try to repro the above more precisely.

This is very exciting! I have a repro. Finally, I have a repro!!!

Here's the code:


        aseg
        ;; Reset vector
        .org    0
        jp      init

        .org    0x08
        reti
        .org    0x10
        reti
        .org    0x18
        reti
        .org    0x20
        reti
        .org    0x28
        reti
        .org    0x30
        reti
        .org    0x38 ; interrupt vector for maskable interrupts
irq:
        ld      c,b
        reti

        .org    0x66 ; interrupt vector for non-maskable interrupts
nmi:
        dec     b
        retn

        .org    0x100
init:
        ld b,0
        ld a,0
        im 1    ; set interrupt mode 1
        ; Schedule interrupt and an NMI to the same clock cycle
        ld a,2
        out 0xfa
        ld a,11+128 <------------------------------------------------------------------
        out 0xfa

        ld  a,1
        ld  b,a
        ld  a, 255
        ei      ; enable interrupts
        jr  wait
        nop
        nop
        nop
wait:
        dec a
        jr nz,wait

        ld a,c   ; if the interrupt fired before the NMI, we should fail the test
        out 0xfb ; terminate
done:
        jp done


If the marked line is 10 or 11, we fail. If it's either 9 or 12, we pass the test. I can even see the same behavior: acknowleding the interrupt with 0x66 on the address bus.

So, the issues seems to have been that we updated the IFF1 flag *after* we've cleared it for the NMI, if the NMI happened to have hit an 'EI' instruction. Not sure what the behavior should be if a (new) NMI hits a RETN instruction. I will implement the same behavior: interrupts stay disabled.

The repro is saved as <nmi_during_ei_issue>. The corresponding sim test is <sim/concurrent_irq_nmi_test.asm>

THIS IS VERY EXCITING. it seems that now I only get one kind of mismatch, something that's not related to interrupt handling. Maybe I should try a full boot?