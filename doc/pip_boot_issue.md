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
    