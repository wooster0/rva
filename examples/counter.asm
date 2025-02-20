@import "rv32i"

@invoke {
    times = x1
    <times> = 5
    index = x2
    <index> = 0
    loop:
    beq index, times, :end
    <index> = <index> + 1
    jal zero, :loop
    end:
    @log <index>
};
