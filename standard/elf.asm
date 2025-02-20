# When inlined at the start of a program, makes it an ELF executable.
$elf_executable_header_32_bit = {
    code_size = $$.0
    entry_point = $$.1
    virtual_address = 4 * 1024 # The second page.
    header_size = :end - :start # Size of the ELF header and program header below.
    entry_point = entry_point + (header_size + virtual_address)

    start:
    @byte 0x7f # Magic number.
    @bytes "ELF" # Magic number.
    @byte 1 # Bit size: 32-bit.
    @byte 1 # Endianness: little-endian.
    @byte 1 # ELF version.
    @byte 0 # ABI: System V.
    @byte 0 # ABI version.
    @bytes [0, 0, 0, 0, 0, 0, 0] # Unused.
    @half 2 # Object file type: executable.
    @half 0xf3 # Architecture: RISC-V.
    @word 1 # ELF version: 1.
    @word entry_point # Entry point address.
    @word 0x34 # Program header table offset.
    @word 0 # Start of section header table.
    @word 0 # Unused.
    @half 52 # Size of this header.
    @half 0x20 # Program header entry size.
    @half 1 # Program header entry count.
    @half 0x28 # Section header entry size (irrelevant as there are no section headers).
    @half 0 # Section header entry count.
    @half 0 # Index of section header entry that contains the section names (none).
    @word 1 # Type of segment: loadable segment.
    @word 0 # Offset of the segment in the file image.
    @word virtual_address # Virtual address of the segment in memory.
    @word virtual_address # Physical address of the segment in memory.
    @word header_size + code_size # Size of the segment in the file image.
    @word header_size + code_size # Size of the segment in memory.
    @word 0x1 # Segment flags: executable.
    @word 0 # No alignment.
    end:
}

# When inlined at the start of a program, makes it an ELF executable.
$elf_executable_header_64_bit = {
    code_size = $$.0
    entry_point = $$.1
    virtual_address = 4 * 1024 # The second page.
    header_size = ::end - ::start # Size of the ELF header and program header below.
    entry_point = entry_point + (header_size + virtual_address)

    start:
    @byte 0x7f # Magic number.
    @bytes "ELF" # Magic number.
    @byte 2 # Bit size: 64-bit.
    @byte 1 # Endianness: little-endian.
    @byte 1 # ELF version.
    @byte 0 # ABI: System V.
    @byte 0 # ABI version.
    @bytes [0, 0, 0, 0, 0, 0, 0] # Unused.
    @half 2 # Object file type: executable.
    @half 0xf3 # Architecture: RISC-V.
    @word 1 # ELF version: 1.
    @double entry_point # Entry point address.
    @double 0x40 # Program header table offset.
    @double 0 # Start of section header table.
    @word 0 # Unused.
    @half 64 # Size of this header.
    @half 0x38 # Program header entry size.
    @half 1 # Program header entry count.
    @half 0x40 # Section header entry size (irrelevant as there are no section headers).
    @half 0 # Section header entry count.
    @half 0 # Index of section header entry that contains the section names (none).
    @word 1 # Type of segment: loadable segment.
    @word 0x1 # Segment flags: executable.
    @double 0 # Offset of the segment in the file image.
    @double virtual_address # Virtual address of the segment in memory.
    @double virtual_address # Physical address of the segment in memory.
    @double header_size + code_size # Size of the segment in the file image.
    @double header_size + code_size # Size of the segment in memory.
    @double 0 # No alignment.
    end:
}
