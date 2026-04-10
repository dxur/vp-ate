module RingBuffer #(
    parameter int unsigned DEPTH = 64 * 1024
) (
    input var logic clk,
    input var logic rst,

    input var  byte unsigned wr_data,
    input var  logic         wr_valid,
    output var logic         wr_ready,

    output var byte unsigned                   p0_rd_data,
    output var logic                           p0_rd_valid,
    input var  logic                           p0_rd_ready,
    output var logic         [$clog2(DEPTH):0] p0_fill,

    output var byte unsigned                   p1_rd_data,
    output var logic                           p1_rd_valid,
    input var  logic                           p1_rd_ready,
    output var logic         [$clog2(DEPTH):0] p1_fill,

    input var logic                     p1_seek,
    input var logic [$clog2(DEPTH)-1:0] p1_seek_addr,

    input var  logic         [$clog2(DEPTH)-1:0] peek_addr,
    output var byte unsigned                     peek_data
);

  localparam int unsigned ADDR_W = $clog2(DEPTH);

  // Storage
  byte unsigned            mem       [0:DEPTH-1];

  logic         [ADDR_W:0] wr_ptr;
  logic         [ADDR_W:0] p0_ptr;
  logic         [ADDR_W:0] p1_ptr;
  logic                    p1_active;

  always_comb p0_fill = wr_ptr - p0_ptr;
  always_comb p1_fill = p1_active ? (wr_ptr - p1_ptr) : '0;

  always_comb begin
    wr_ready = (p0_fill < DEPTH[ADDR_W:0]);
    if (p1_active) wr_ready = wr_ready && (p1_fill < DEPTH[ADDR_W:0]);
  end

  always_comb p0_rd_data = mem[p0_ptr[ADDR_W-1:0]];
  always_comb p0_rd_valid = (p0_fill != '0);

  always_comb p1_rd_data = mem[p1_ptr[ADDR_W-1:0]];
  always_comb p1_rd_valid = p1_active && (p1_fill != '0);

  always_comb peek_data = mem[peek_addr];

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

      // p0 drain
      if (p0_rd_valid && p0_rd_ready) p0_ptr <= p0_ptr + 1'b1;

      // p1 seek
      if (p1_seek) begin
        p1_ptr    <= wr_ptr - {{1'b0}, (wr_ptr[ADDR_W-1:0] - p1_seek_addr)};
        p1_active <= 1'b1;
      end else if (p1_rd_valid && p1_rd_ready) begin
        p1_ptr <= p1_ptr + 1'b1;
      end

    end
  end

endmodule
