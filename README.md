# rva

This is a general-purpose RISC-V assembler.

* Supports labels, directives, and other standard features
* Extensible: instructions and pseudoinstructions are not part of the assembler itself but are instead supplied using external standard files:
  Example from `standard/rv32i.asm`:
  ```
  @instruction beq b [0b1100011, 0b000]
  @instruction bne b [0b1100011, 0b001]
  @instruction blt b [0b1100011, 0b100]
  @instruction bge b [0b1100011, 0b101]
  @instruction bltu b [0b1100011, 0b110]
  @instruction bgeu b [0b1100011, 0b111]
  ```
  Example from `standard/pseudoinstructions.asm`:
  ```
  @pseudoinstruction nop {
      addi zero, zero, 0
  }
  @pseudoinstruction li {
      addi $$.0, zero, $$.1
  }
  ```
* Supports execution of instructions and code inside `@invoke` blocks at assembly time.
  All instructions part of RV32I, RV32M, RV64I, and RV64M are executable at assembly time.
  This for example lets you print out values before running the code, using the `@log` directive:
  ```
  @log (5 + 5) * 20
  ```
  A common problem assemblers have is that they have no easy way of letting you inspect constants or macros.
  RVA does not have macros; its answer to metaprogramming is assembly time.

For more documentation see `documentation.txt`, `examples/`, and `tests.zig`.

The internal pipeline works as follows:
1. main.zig: Take the source code.
2. Tokenizer: Pass it into a tokenizer without producing any tokens yet.
3. Parser.zig: Parse the tokens into commands. Tokens are produced on the go. Look-ahead of up to one token is supported.
   A command represents directives, instructions, pseudoinstructions, arithmetic, and operations on values.
4. Assembler.zig: This is where assembly time execution happens. Any code inside `@invoke` blocks is invoked and executed right there and then at assembly time.
   All the rest that is not invoked gets emitted to the final binary, as machine code.

Unfortunately assembly time execution has some limitations in regard to mutating memory at assembly time which means it has limited usefulness for
creating structures, tables, data, etc. at assembly time.
The assembler is nonetheless in a useable state.
