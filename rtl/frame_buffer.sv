module FrameBuffer #(
    parameter int unsigned MAX_WIDTH  = 1920,
    parameter int unsigned MAX_HEIGHT = 1080
) (
    input var logic clk,
    input var logic rst,

    input var logic [15:0] width,
    input var logic [15:0] height,

    input var  logic       wr_valid,
    output var logic       wr_ready,
    input var  logic [7:0] wr_mb_col,              // macroblock column index
    input var  logic [7:0] wr_mb_row,              // macroblock row index
    input var  logic [7:0] wr_y     [0:15][0:15],
    input var  logic [7:0] wr_cb    [ 0:7][ 0:7],
    input var  logic [7:0] wr_cr    [ 0:7][ 0:7],

    input var  logic [7:0] rd_mb_col,
    input var  logic [7:0] rd_mb_row,
    output var logic [7:0] rd_top_y         [0:15],
    output var logic [7:0] rd_top_cb        [ 0:7],
    output var logic [7:0] rd_top_cr        [ 0:7],
    output var logic [7:0] rd_left_y        [0:15],
    output var logic [7:0] rd_left_cb       [ 0:7],
    output var logic [7:0] rd_left_cr       [ 0:7],
    output var logic [7:0] rd_topleft_y,
    output var logic [7:0] rd_topleft_cb,
    output var logic [7:0] rd_topleft_cr,
    output var logic [7:0] rd_topright_y    [ 0:3],
    output var logic       rd_top_valid,
    output var logic       rd_left_valid,
    output var logic       rd_topleft_valid,
    output var logic       rd_topright_valid
);

  localparam int unsigned LUMA_SIZE = MAX_WIDTH * MAX_HEIGHT;
  localparam int unsigned CHROMA_SIZE = (MAX_WIDTH / 2) * (MAX_HEIGHT / 2);

  logic [7:0] luma_buf[  0:LUMA_SIZE-1];
  logic [7:0] cb_buf  [0:CHROMA_SIZE-1];
  logic [7:0] cr_buf  [0:CHROMA_SIZE-1];

  always_comb wr_ready = 1'b1;

  always_ff @(posedge clk) begin
    if (wr_valid) begin
      for (int r = 0; r < 16; r++) begin
        for (int c = 0; c < 16; c++) begin
          automatic int unsigned px_row, px_col, addr;
          px_row = int'(wr_mb_row) * 16 + r;
          px_col = int'(wr_mb_col) * 16 + c;
          addr   = px_row * int'(width) + px_col;
          if (addr < LUMA_SIZE) luma_buf[addr] <= wr_y[r][c];
        end
      end
      for (int r = 0; r < 8; r++) begin
        for (int c = 0; c < 8; c++) begin
          automatic int unsigned cr, cc, cw, addr;
          cr   = int'(wr_mb_row) * 8 + r;
          cc   = int'(wr_mb_col) * 8 + c;
          cw   = (int'(width) + 1) / 2;
          addr = cr * cw + cc;
          if (addr < CHROMA_SIZE) begin
            cb_buf[addr] <= wr_cb[r][c];
            cr_buf[addr] <= wr_cr[r][c];
          end
        end
      end
    end
  end

  always_comb begin
    rd_top_valid      = (rd_mb_row > 0);
    rd_left_valid     = (rd_mb_col > 0);
    rd_topleft_valid  = (rd_mb_row > 0 && rd_mb_col > 0);
    rd_topright_valid = (rd_mb_row > 0 && (int'(rd_mb_col) + 1) * 16 + 4 < int'(width));

    rd_top_y          = '{default: 8'd127};
    rd_top_cb         = '{default: 8'd127};
    rd_top_cr         = '{default: 8'd127};
    rd_left_y         = '{default: 8'd129};
    rd_left_cb        = '{default: 8'd129};
    rd_left_cr        = '{default: 8'd129};
    rd_topleft_y      = 8'd127;
    rd_topleft_cb     = 8'd127;
    rd_topleft_cr     = 8'd127;
    rd_topright_y     = '{default: 8'd127};

    if (rd_top_valid) begin
      automatic int unsigned top_row, left_col, cw;
      top_row  = (int'(rd_mb_row) - 1) * 16 + 15;
      left_col = int'(rd_mb_col) * 16;
      cw       = (int'(width) + 1) / 2;
      for (int c = 0; c < 16; c++) rd_top_y[c] = luma_buf[top_row*int'(width)+left_col+c];
      for (int c = 0; c < 8; c++) begin
        automatic int unsigned cr2, cc2, a;
        cr2 = (int'(rd_mb_row) - 1) * 8 + 7;
        cc2 = int'(rd_mb_col) * 8 + c;
        a = cr2 * cw + cc2;
        rd_top_cb[c] = cb_buf[a];
        rd_top_cr[c] = cr_buf[a];
      end
      if (rd_topright_valid) begin
        automatic int unsigned trb, trc;
        trb = top_row;
        trc = (int'(rd_mb_col) + 1) * 16;
        for (int c = 0; c < 4; c++) rd_topright_y[c] = luma_buf[trb*int'(width)+trc+c];
      end
    end

    if (rd_left_valid) begin
      automatic int unsigned mb_row_pix, left_col, cw;
      mb_row_pix = int'(rd_mb_row) * 16;
      left_col   = int'(rd_mb_col) * 16 - 1;
      cw         = (int'(width) + 1) / 2;
      for (int r = 0; r < 16; r++) rd_left_y[r] = luma_buf[(mb_row_pix+r)*int'(width)+left_col];
      for (int r = 0; r < 8; r++) begin
        automatic int unsigned cr2, cc2, a;
        cr2 = int'(rd_mb_row) * 8 + r;
        cc2 = int'(rd_mb_col) * 8 - 1;
        a = cr2 * cw + cc2;
        rd_left_cb[r] = cb_buf[a];
        rd_left_cr[r] = cr_buf[a];
      end
    end

    if (rd_topleft_valid) begin
      automatic int unsigned tl_row, tl_col, cw, tl_cb_row, tl_cb_col;
      tl_row        = (int'(rd_mb_row) - 1) * 16 + 15;
      tl_col        = int'(rd_mb_col) * 16 - 1;
      cw            = (int'(width) + 1) / 2;
      rd_topleft_y  = luma_buf[tl_row*int'(width)+tl_col];
      tl_cb_row     = (int'(rd_mb_row) - 1) * 8 + 7;
      tl_cb_col     = int'(rd_mb_col) * 8 - 1;
      rd_topleft_cb = cb_buf[tl_cb_row*cw+tl_cb_col];
      rd_topleft_cr = cr_buf[tl_cb_row*cw+tl_cb_col];
    end
  end

endmodule
