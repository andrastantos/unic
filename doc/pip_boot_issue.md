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