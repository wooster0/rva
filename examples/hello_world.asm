@import "rv32i"

# Lowercases all characters of the given input. Ignores characters that are already lowercase or not a letter.
lowercase = {
    bytes = $$

    index = x1

    # None of these instructions end up in the emitted binary as long as this block is not inlined.
    add index, zero, zero
    loop:
    <x2> = bytes.@
    beq index, x2, :end
    bytes.<index> = (bytes.<index>) + 32
    @log [bytes.<index>]
    addi index, index, 1
    # Zero is an alias to register x0.
    jal zero, :loop
    end:
}

# Lowercase and print out the strings as assembly time.

@invoke lowercase "HELLO"
@invoke lowercase "WORLD"
