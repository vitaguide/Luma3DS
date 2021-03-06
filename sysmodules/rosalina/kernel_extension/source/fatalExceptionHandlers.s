@   This file is part of Luma3DS
@   Copyright (C) 2016-2017 Aurora Wright, TuxSH
@
@   This program is free software: you can redistribute it and/or modify
@   it under the terms of the GNU General Public License as published by
@   the Free Software Foundation, either version 3 of the License, or
@   (at your option) any later version.
@
@   This program is distributed in the hope that it will be useful,
@   but WITHOUT ANY WARRANTY; without even the implied warranty of
@   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
@   GNU General Public License for more details.
@
@   You should have received a copy of the GNU General Public License
@   along with this program.  If not, see <http://www.gnu.org/licenses/>.
@
@   Additional Terms 7.b and 7.c of GPLv3 apply to this file:
@       * Requiring preservation of specified reasonable legal notices or
@         author attributions in that material or in the Appropriate Legal
@         Notices displayed by works containing it.
@       * Prohibiting misrepresentation of the origin of that material,
@         or requiring that modified versions of such material be marked in
@         reasonable ways as different from the original version.

.macro TEST_IF_MODE_AND_ARM_INST_OR_JUMP lbl, mode
    cpsid aif
    mrs sp, spsr
    tst sp, #0x20
    bne \lbl
    and sp, #0x1f                @ get previous processor mode
    cmp sp, #\mode
    bne \lbl

    sub sp, lr, #4
    mcr p15, 0, sp, c7, c8, 0    @ VA to PA translation with privileged read permission check
    mrc p15, 0, sp, c7, c4, 0    @ read PA register
    tst sp, #1                   @ failure bit
    bne \lbl
.endm


.macro GEN_USUAL_HANDLER name, index, pos
    \name\()Handler:
        ldr sp, =exceptionStackTop
        ldr sp, [sp]
        sub sp, #0x100

        push {r0-r12, lr}
        mrs r0, spsr
        bl isExceptionFatal
        cmp r0, #0
        pop {r0-r12, lr}
        bne _exc_is_fatal_\name

        ldr sp, =originalHandlers
        ldr sp, [sp, #\pos]
        bx sp

        _exc_is_fatal_\name:
        push {r8, r9}
        mov r8, #\index
        b _commonHandler
.endm

.text
.arm
.balign 4

_die:
    cpsid aif
_die_loop:
    wfi
    b _die_loop

_commonHandler:
    cpsid aif

    push {r0}
    ldr r0, =_fatalExceptionOccured
    ldr r0, [r0]
    cmp r0, #0
    bne _die_loop
    pop {r0}

    ldr r9, =_regs
    stmia r9, {r0-r7}
    mov r1, r8
    pop {r8,r9}

    ldr r0, =_fatalExceptionOccured
    mov r4, #1

    _try_lock:
        ldrex r2, [r0]
        strex r3, r4, [r0]
        cmp r3, #0
        bne _try_lock

    push {r1, r12, lr}           @ attempt to hang the other cores
    adr r0, _die
    mov r1, #0xf
    mov r2, #1
    mov r3, #0
    bl executeFunctionOnCores
    pop {r1, r12, lr}

    mrs r2, spsr
    mrs r3, cpsr
    ldr r6, =_regs
    add r6, #0x20

    ands r4, r2, #0xf       @ get the mode that triggered the exception
    moveq r4, #0xf          @ usr => sys
    bic r5, r3, #0xf
    orr r5, r4
    msr cpsr_c, r5          @ change processor mode
    stmia r6!, {r8-lr}
    msr cpsr_c, r3          @ restore processor mode

    str lr, [r6], #4
    str r2, [r6], #4

    mov r0, r6

    mrc p15, 0, r4, c5, c0, 0    @ dfsr
    mrc p15, 0, r5, c5, c0, 1    @ ifsr
    mrc p15, 0, r6, c6, c0, 0    @ far
    fmrx r7, fpexc
    fmrx r8, fpinst
    fmrx r9, fpinst2
    bic r3, #(1<<31)
    fmxr fpexc, r3          @ clear the VFP11 exception flag (if it's set)

    stmia r0!, {r4-r9}

    mov r0, #0
    mcr p15, 0, r0, c7, c14, 0   @ Clean and Invalidate Entire Data Cache
    mcr p15, 0, r0, c7, c10, 4   @ Drain Synchronization Barrier

    ldr r0, =isN3DS
    ldr r0, [r0]
    cmp r0, #0
    beq _no_L2C
    ldr r0, =(0x17e10100 | 1 << 31)
    ldr r0, [r0]
    tst r0, #1                          @ is the L2C enabled?
    beq _no_L2C

    ldr r0, =0xffff
    ldr r2, =(0x17e10730 | 1 << 31)
    str r0, [r2, #0x4c]                @ invalidate by way

    _L2C_sync:
        ldr r0, [r2]                   @ L2C cache sync register
        tst r0, #1
        bne _L2C_sync

    _no_L2C:

    cps #0x1F
    ldr sp, =exceptionStackTop
    ldr sp, [sp]
    sub sp, #0x100

    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5   @ Drain Memory Barrier
    ldr r0, =_regs
    mrc p15, 0, r2, c0, c0, 5    @ CPU ID register
    bl fatalExceptionHandlersMain

    ldr r12, =mcuReboot
    ldr r12, [r12]
    bx r12

.global FIQHandler
.type   FIQHandler, %function
GEN_USUAL_HANDLER FIQ, 0, 28

.global undefinedInstructionHandler
.type   undefinedInstructionHandler, %function
undefinedInstructionHandler:
    TEST_IF_MODE_AND_ARM_INST_OR_JUMP _undefinedInstructionNormalHandler, 0x10

    ldr sp, [lr, #-4]   @ test if it's an VFP instruction that was aborted
    lsl sp, #4
    sub sp, #0xc0000000
    cmp sp, #0x30000000
    bcs _undefinedInstructionNormalHandler
    fmrx sp, fpexc
    tst sp, #0x40000000
    bne _undefinedInstructionNormalHandler

    @ FPU init
    sub lr, #4
    srsfd sp!, #0x13
    cps #0x13
    stmfd sp, {r0-r3, r11-lr}^
    sub sp, #0x20
    ldr r12, =initFPU
    ldr r12, [r12]
    blx r12
    ldmfd sp, {r0-r3, r11-lr}^
    add sp, #0x20
    rfefd sp!  @ retry aborted instruction

    GEN_USUAL_HANDLER _undefinedInstructionNormal, 1, 4

.global prefetchAbortHandler
.type   prefetchAbortHandler, %function
prefetchAbortHandler:
    TEST_IF_MODE_AND_ARM_INST_OR_JUMP _prefetchAbortNormalHandler, 0x13

    ldr sp, =(Break + 3*4 + 4)
    cmp lr, sp
    bne _prefetchAbortNormalHandler

    sub sp, r0, #0x110
    pop {r0-r7, r12, lr}
    pop {r8-r11}
    ldr lr, [sp, #8]!
    ldr sp, [sp, #4]
    msr spsr, sp
    addne lr, #2                        @ adjust address for later

    GEN_USUAL_HANDLER _prefetchAbortNormal, 2, 12

.global dataAbortHandler
.type   dataAbortHandler, %function
dataAbortHandler:
    ldr sp, =exceptionStackTop
    ldr sp, [sp]
    push {r0-r12, lr}
    mrs r0, spsr
    sub r1, lr, #8
    bl isDataAbortExceptionRangeControlled
    cmp r0, #0
    pop {r0-r12, lr}
    beq _dataAbortNormalHandler

    msr spsr_f, #(1 << 30)
    mov r12, #0
    subs pc, lr, #4

    GEN_USUAL_HANDLER _dataAbortNormal, 3, 16

.bss
.balign 4
_regs: .skip (4 * 23)
_fatalExceptionOccured: .word 0
