@instruction lwu i [0b0000011, 0b110]
@instruction ld i [0b0000011, 0b011]

@instruction sd s [0b0100011, 0b011]

@instruction slli64 i [0b0010011, 0b001]
@instruction srli64 i [0b0010011, 0b101]
@instruction srai64 i [0b0010011, 0b101]

@instruction addiw i [0b0011011, 0b000]
@instruction slliw s [0b0011011, 0b001, 0b0000000]
@instruction srliw s [0b0011011, 0b101, 0b0000000]
@instruction sraiw s [0b0011011, 0b101, 0b0100000]

@instruction addw r [0b0111011, 0b000, 0b0000000]
@instruction subw r [0b0111011, 0b000, 0b0100000]
@instruction sllw r [0b0111011, 0b001, 0b0000000]
@instruction srlw r [0b0111011, 0b101, 0b0000000]
@instruction sraw r [0b0111011, 0b101, 0b0100000]
