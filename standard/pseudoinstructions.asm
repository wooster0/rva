@import "rv32i"
@import "rv64i"

@pseudoinstruction la {
    auipc $$.0, ($$.1) | 0b00000000_00001111_11111111_11111111
    addi $$.0, $$.0, ($$.1) | 0b11111111_11110000_00000000_00000000
}
@pseudoinstruction nop {
    addi zero, zero, 0
}
@pseudoinstruction li {
    addi $$.0, zero, $$.1
}
@pseudoinstruction mv {
    addi $$.0, $$.1, 0
}
@pseudoinstruction sext_w {
    addiw $$.0, $$.1, 0
}

@pseudoinstruction beqz {
    beq $$.0, zero, $$.1
}
@pseudoinstruction bnez {
    bne $$.0, zero, $$.1
}
@pseudoinstruction blez {
    bge zero, $$.0, $$.1
}
@pseudoinstruction bgez {
    bge $$.0, zero, $$.1
}
@pseudoinstruction bltz {
    blt $$.0, zero, $$.1
}
@pseudoinstruction bgtz {
    blt zero, $$.0, $$.1
}

@pseudoinstruction seqz {
    sltiu $$.0, $$.1, 1
}
@pseudoinstruction snez {
    sltu $$.0, zero, $$.1
}
@pseudoinstruction sltz {
    slt $$.0, $$.1, zero
}
@pseudoinstruction sgtz {
    slt $$.0, zero, $$.1
}

@pseudoinstruction j {
    jal zero, $$.0
}
@pseudoinstruction jr {
    jalr zero, $$.0, 0
}
@pseudoinstruction ret {
    jalr zero, ra, 0
}
@pseudoinstruction call {
    auipc t1, ($$.0) | 0b00000000_00001111_11111111_11111111
    jalr ra, t1, ($$.0) | 0b11111111_11110000_00000000_00000000
}
@pseudoinstruction tail {
    auipc t1, ($$.0) | 0b00000000_00001111_11111111_11111111
    jalr zero, t1, ($$.0) | 0b11111111_11110000_00000000_00000000
}

@pseudoinstruction not {
    xori $$.0, $$.1, - 1
}
@pseudoinstruction neg {
    sub $$.0, zero, $$.1
}
@pseudoinstruction negw {
    subw $$.0, zero, $$.1
}

@pseudoinstruction slli {
    instruction_32_bit = { slli32 $$.0, $$.1, ($$.2) >> 6 }
    instruction_64_bit = { slli64 $$.0, $$.1, ($$.2) >> 7 }
    instruction = ?
    @invoke {
        <x1> = $bits
        <x2> = 32
        beq x1, x2, :use_32_bit
        <x2> = 64
        beq x1, x2, :use_64_bit
        ebreak;
        use_32_bit:
        instruction = instruction_32_bit
        jal x0, :end
        use_64_bit:
        instruction = instruction_64_bit
        jal x0, :end
        end:
    };
    @inline instruction $$
}
