import MacroblockHeaderPkg::*;

module VpAte #(
    parameter int unsigned BUFFER_SIZE = 64 * 1024,
    parameter int unsigned MB_SLOTS    = 16,
    parameter int unsigned TK_SLOT     = 32
) (
    input var  logic         clk,
    input var  logic         rst,
    input var  byte unsigned data,
    input var  logic         data_valid,
    output var logic         data_ready
    // frame buffer output ??
);
  byte unsigned     buffer       [0:BUFFER_SIZE-1];
  int unsigned      buffer_ptr;

  MacroblockHeader  mb_slots     [   0:MB_SLOTS-1];
  int unsigned      mb_slots_ptr;
  TokensPkg::Tokens tokens       [    0:TK_SLOT-1];
  int unsigned      tokens_ptr;

  always_ff @(posedge clk) begin
    if ((rst)) begin
      buffer_ptr <= 32'b0;
    end else begin
      if ((data_valid)) begin
        buffer[buffer_ptr] <= data;
        buffer_ptr         <= buffer_ptr + 1;
      end
    end
  end

  always_comb begin
    data_ready = 1'b1;
  end
endmodule

module VpAteTest (
    input var  logic         clk,
    input var  logic         rst,
    input var  byte unsigned data,
    input var  logic         data_valid,
    output var logic         data_ready
);
  VpAte decoder (
      .clk       (clk),
      .rst       (rst),
      .data      (data),
      .data_valid(data_valid),
      .data_ready(data_ready)
  );
endmodule
