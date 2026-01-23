interface TokensParserIf;
  logic placeholder;
  modport self(output placeholder);

  modport user(input placeholder);
endinterface

module TokensParser (
    input var logic clk,
    input var logic rst,

    BoolDecoderIf.user bd,

    TokensParserIf.self self
);
  // Parse the bit stream
endmodule
