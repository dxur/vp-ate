// RingBuffer - power-of-2 depth, byte granularity, two independent read pointers.
//
// p0 - part0 consumer (FHP raw bytes, then bd0 MBHP bool-decode)
// p1 - part1 consumer (bd1 residue token bool-decode)
//
// Pointer representation:
//   All three pointers (wr_ptr, p0_ptr, p1_ptr) carry ADDR_W+1 bits.
//   The low ADDR_W bits index mem[].
//   The extra MSB tracks wrap parity - this is the standard technique to
//   distinguish "full" (fill == DEPTH) from "empty" (fill == 0) without a
//   separate count register.
//
//   fill_pN = wr_ptr - pN_ptr   (ADDR_W+1 bit unsigned subtract, wraps)
//   full_pN = (fill_pN == DEPTH)
//   empty_pN = (fill_pN == 0)
//
// p1 seek:
//   p1_seek_addr carries the low ADDR_W bits of the target ring address.
//   On seek we set p1_ptr[ADDR_W-1:0] = p1_seek_addr and compute the MSB
//   so that fill = wr_ptr - p1_ptr reflects bytes available from that point.
//   Specifically: p1_ptr = wr_ptr - (wr_ptr[ADDR_W-1:0] - p1_seek_addr)
//   which gives fill = wr_ptr[ADDR_W-1:0] - p1_seek_addr (unsigned, modulo DEPTH).

module RingBuffer #(
    parameter int unsigned DEPTH = 64 * 1024   // must be a power of 2
) (
    input var logic clk,
    input var logic rst,

    // ---------- write port ----------
    input var  byte unsigned wr_data,
    input var  logic         wr_valid,
    output var logic         wr_ready,

    // ---------- p0 read port (part0: FHP + bd0) ----------
    output var byte unsigned              p0_rd_data,
    output var logic                      p0_rd_valid,
    input  var logic                      p0_rd_ready,
    output var logic [$clog2(DEPTH):0]    p0_fill,

    // ---------- p1 read port (part1: bd1) ----------
    output var byte unsigned              p1_rd_data,
    output var logic                      p1_rd_valid,
    input  var logic                      p1_rd_ready,
    output var logic [$clog2(DEPTH):0]    p1_fill,

    // p1 seek: jump p1_ptr to p1_seek_addr (assert for one cycle)
    input  var logic                      p1_seek,
    input  var logic [$clog2(DEPTH)-1:0]  p1_seek_addr,

    // ---------- peek port (absolute ring addr, combinational) ----------
    input  var logic [$clog2(DEPTH)-1:0]  peek_addr,
    output var byte unsigned              peek_data
);

  localparam int unsigned ADDR_W = $clog2(DEPTH);

  // -------------------------------------------------------------------------
  // Storage
  // -------------------------------------------------------------------------
  byte unsigned mem [0:DEPTH-1];

  // ADDR_W+1 bit pointers: MSB = wrap parity, low bits = mem index
  logic [ADDR_W:0] wr_ptr;
  logic [ADDR_W:0] p0_ptr;
  logic [ADDR_W:0] p1_ptr;
  logic            p1_active;

  // -------------------------------------------------------------------------
  // Occupancy  (ADDR_W+1 bit unsigned subtract - correct across wrap)
  // -------------------------------------------------------------------------
  always_comb p0_fill = wr_ptr - p0_ptr;
  always_comb p1_fill = p1_active ? (wr_ptr - p1_ptr) : '0;

  // -------------------------------------------------------------------------
  // Write-ready: stop when the slowest active pointer is a full buffer behind
  // -------------------------------------------------------------------------
  always_comb begin
    wr_ready = (p0_fill < DEPTH[ADDR_W:0]);
    if (p1_active)
      wr_ready = wr_ready && (p1_fill < DEPTH[ADDR_W:0]);
  end

  // -------------------------------------------------------------------------
  // Read outputs (combinational - index mem with low ADDR_W bits only)
  // -------------------------------------------------------------------------
  always_comb p0_rd_data  = mem[p0_ptr[ADDR_W-1:0]];
  always_comb p0_rd_valid = (p0_fill != '0);

  always_comb p1_rd_data  = mem[p1_ptr[ADDR_W-1:0]];
  always_comb p1_rd_valid = p1_active && (p1_fill != '0);

  always_comb peek_data   = mem[peek_addr];

  // -------------------------------------------------------------------------
  // Sequential
  // -------------------------------------------------------------------------
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      wr_ptr    <= '0;
      p0_ptr    <= '0;
      p1_ptr    <= '0;
      p1_active <= 1'b0;
    end else begin

      // -- write --
      if (wr_valid && wr_ready) begin
        mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
        wr_ptr                  <= wr_ptr + 1'b1;
      end

      // -- p0 drain --
      if (p0_rd_valid && p0_rd_ready)
        p0_ptr <= p0_ptr + 1'b1;

      // -- p1 seek (priority over drain this cycle) --
      // Set p1_ptr such that fill = wr_ptr[ADDR_W-1:0] - p1_seek_addr.
      // Achieved by: p1_ptr = wr_ptr - fill_after_seek
      //   where fill_after_seek = ADDR_W'(wr_ptr[ADDR_W-1:0] - p1_seek_addr)
      if (p1_seek) begin
        p1_ptr    <= wr_ptr - {{1'b0}, (wr_ptr[ADDR_W-1:0] - p1_seek_addr)};
        p1_active <= 1'b1;
      end else if (p1_rd_valid && p1_rd_ready) begin
        p1_ptr <= p1_ptr + 1'b1;
      end

    end
  end

endmodule

// ---------------------------------------------------------------------------
// Test wrapper (flat ports for cocotb)
// ---------------------------------------------------------------------------
module RingBufferTest #(
    parameter int unsigned DEPTH = 64 * 1024
) (
    input var logic clk,
    input var logic rst,

    input var  byte unsigned              wr_data,
    input var  logic                      wr_valid,
    output var logic                      wr_ready,

    output var byte unsigned              p0_rd_data,
    output var logic                      p0_rd_valid,
    input  var logic                      p0_rd_ready,
    output var logic [$clog2(DEPTH):0]    p0_fill,

    output var byte unsigned              p1_rd_data,
    output var logic                      p1_rd_valid,
    input  var logic                      p1_rd_ready,
    output var logic [$clog2(DEPTH):0]    p1_fill,

    input  var logic                      p1_seek,
    input  var logic [$clog2(DEPTH)-1:0]  p1_seek_addr,

    input  var logic [$clog2(DEPTH)-1:0]  peek_addr,
    output var byte unsigned              peek_data
);
  RingBuffer #(.DEPTH(DEPTH)) uut (.*);
endmodule
