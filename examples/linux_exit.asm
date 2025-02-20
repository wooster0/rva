@import "rv32i"
@import "elf"

@inline $elf_executable_header_32_bit [::end, ::entry_point]

entry_point:
addi a7, zero, 94
addi a0, zero, 0
ecall;
end:
