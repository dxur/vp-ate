// Ring buffer - power-of-2 depth, byte granularity.
//
// Stream in:  wr_valid / wr_ready / wr_data
// Byte out:   rd_valid / rd_ready / rd_data
//
// rd_addr_valid / rd_addr: random-access peek one byte (combinational,
//   does NOT advance the read pointer) - used so FrameHeaderParser can
//   read bytes at arbitrary offsets while still draining them later.
//
// fill_count: current number of bytes held (for backpressure decisions).

module RingBuffer #(
    parameter int unsigned DEPTH = 64 * 1024  // must be a power of 2
) (
    input var logic clk,
    input var logic rst,

    // Write side (stream in)
    input var  byte unsigned wr_data,
    input var  logic         wr_valid,
    output var logic         wr_ready,

    // Read side (sequential drain)
    output var byte unsigned rd_data,
    output var logic         rd_valid,
    input var  logic         rd_ready,

    // Random-access peek (combinational, does not move read pointer)
    input var  logic         [$clog2(DEPTH)-1:0] peek_addr,  // absolute byte offset in ring
    output var byte unsigned                      peek_data,

    // Occupancy
    output var logic [$clog2(DEPTH):0] fill_count
);
  localparam int unsigned ADDR_W = $clog2(DEPTH);

  byte unsigned mem[0:DEPTH-1];

  logic [ADDR_W-1:0] wr_ptr;
  logic [ADDR_W-1:0] rd_ptr;
  logic [ADDR_W  :0] count;  // extra bit to distinguish full vs empty

  always_comb fill_count = count[ADDR_W:0];
  always_comb wr_ready   = (count < DEPTH[ADDR_W:0]);
  always_comb rd_valid   = (count != 0);

  // Peek port - combinational read at arbitrary address
  always_comb peek_data  = mem[peek_addr];

  // Sequential drain output
  always_comb rd_data    = mem[rd_ptr];

  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      // Write
      if (wr_valid && wr_ready) begin
        mem[wr_ptr] <= wr_data;
        wr_ptr      <= wr_ptr + 1'b1;
        count       <= count + 1'b1;
      end
      // Read
      if (rd_valid && rd_ready) begin
        rd_ptr <= rd_ptr + 1'b1;
        if (!(wr_valid && wr_ready))  // avoid double-decrement when simultaneous
          count <= count - 1'b1;
      end
      // Simultaneous read + write: count stays the same
      if ((wr_valid && wr_ready) && (rd_valid && rd_ready))
        count <= count;
    end
  end

endmodule

// ---------------------------------------------------------------------------
// Wrapper for cocotb testing (flat ports, no interface)
// ---------------------------------------------------------------------------
module RingBufferTest #(
    parameter int unsigned DEPTH = 64 * 1024
) (
    input var logic clk,
    input var logic rst,

    input var  byte unsigned wr_data,
    input var  logic         wr_valid,
    output var logic         wr_ready,

    output var byte unsigned rd_data,
    output var logic         rd_valid,
    input var  logic         rd_ready,

    input var  logic         [$clog2(DEPTH)-1:0] peek_addr,
    output var byte unsigned                      peek_data,

    output var logic [$clog2(DEPTH):0] fill_count
);
  RingBuffer #(.DEPTH(DEPTH)) uut (.*);
endmodule
