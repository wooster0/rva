@instruction lui u [0b0110111]

@instruction auipc u [0b0010111]

@instruction jal j [0b1101111]

@instruction jalr i [0b1100111, 0b000]

@instruction beq b [0b1100011, 0b000]
@instruction bne b [0b1100011, 0b001]
@instruction blt b [0b1100011, 0b100]
@instruction bge b [0b1100011, 0b101]
@instruction bltu b [0b1100011, 0b110]
@instruction bgeu b [0b1100011, 0b111]

@instruction lb i [0b0000011, 0b000]
@instruction lh i [0b0000011, 0b001]
@instruction lw i [0b0000011, 0b010]
@instruction lbu i [0b0000011, 0b100]
@instruction lhu i [0b0000011, 0b101]

@instruction sb s [0b0100011, 0b000]
@instruction sh s [0b0100011, 0b001]
@instruction sw s [0b0100011, 0b010]

@instruction addi i [0b0010011, 0b000]
@instruction slti i [0b0010011, 0b010]
@instruction sltiu i [0b0010011, 0b011]
@instruction xori i [0b0010011, 0b100]
@instruction ori i [0b0010011, 0b110]
@instruction andi i [0b0010011, 0b111]
@instruction slli32 i [0b0010011, 0b001]
@instruction srli32 i [0b0010011, 0b101]
@instruction srai32 i [0b0010011, 0b101]

@instruction add r [0b0110011, 0b000, 0b0000000]
@instruction sub r [0b0110011, 0b000, 0b0100000]
@instruction sll r [0b0110011, 0b001, 0b0000000]
@instruction slt r [0b0110011, 0b010, 0b0000000]
@instruction sltu r [0b0110011, 0b011, 0b0000000]
@instruction xor r [0b0110011, 0b100, 0b0000000]
@instruction srl r [0b0110011, 0b101, 0b0000000]
@instruction sra r [0b0110011, 0b101, 0b0100000]
@instruction or r [0b0110011, 0b110, 0b0000000]
@instruction and r [0b0110011, 0b111, 0b0000000]

@instruction fence i [0b0001111, 0b000]
@instruction fence_tso x [0b0001111, 0b1000_0011_0011_00000_000_00000]
@instruction pause x [0b0001111, 0b0000_0001_0000_00000_000_00000]

@instruction ecall x [0b1110011, 0b000000000000_00000_000_00000]
@instruction ebreak x [0b1110011, 0b000000000001_00000_000_00000]
