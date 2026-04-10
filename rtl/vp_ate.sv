module SimpleFifo #(
    parameter int unsigned DEPTH = 64 * 1024 * 1024
) (
    input var logic clk,
    input var logic rst,

    input var  byte unsigned wr_data,
    input var  logic         wr_valid,
    output var logic         wr_ready,

    output var byte unsigned rd_data,
    output var logic         rd_valid,
    input var  logic         rd_ready,

    output var logic [$clog2(DEPTH):0] fill
);
  localparam int unsigned AW = $clog2(DEPTH);

  byte unsigned          mem    [0:DEPTH-1];
  logic         [AW-1:0] wr_ptr;
  logic         [AW-1:0] rd_ptr;
  logic         [  AW:0] count;

  assign fill     = count;
  assign wr_ready = (count < DEPTH[AW:0]);
  assign rd_valid = (count != '0);
  assign rd_data  = mem[rd_ptr];

  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      case ({
        wr_valid & wr_ready, rd_valid & rd_ready
      })
        2'b10: begin
          mem[wr_ptr] <= wr_data;
          wr_ptr      <= wr_ptr + 1'b1;
          count       <= count + 1'b1;
        end
        2'b01: begin
          rd_ptr <= rd_ptr + 1'b1;
          count  <= count - 1'b1;
        end
        2'b11: begin
          mem[wr_ptr] <= wr_data;
          wr_ptr      <= wr_ptr + 1'b1;
          rd_ptr      <= rd_ptr + 1'b1;
        end
        default: ;
      endcase
    end
  end
endmodule


import Macroblock::*;
import Frame::*;
import PredictorPkg::*;

module VpAte #(
    parameter int unsigned P0_FIFO_DEPTH = 64 * 1024 * 1024,
    parameter int unsigned P1_FIFO_DEPTH = 64 * 1024 * 1024,
    parameter int unsigned MAX_WIDTH     = 1280,
    parameter int unsigned MAX_HEIGHT    = 720
) (
    input var logic clk,
    input var logic rst,

    input var  byte unsigned p0_data,
    input var  logic         p0_valid,
    output var logic         p0_ready,

    input var  byte unsigned p1_data,
    input var  logic         p1_valid,
    output var logic         p1_ready,

    output var logic             frame_done,
    output var shortint unsigned frame_width,
    output var shortint unsigned frame_height
);

  localparam int unsigned MAX_MB_COLS = MAX_WIDTH / 16;
  localparam int unsigned MAX_MB_ROWS = MAX_HEIGHT / 16;

  // Sticky bit: set when mb_valid_r fires for the last MB.
  // Permanently blocks mb_header_ready so MBHP never handshakes again.
  logic                                   last_mb_accepted;

  // FIFOs
  byte unsigned                           p0_rd_data;
  logic                                   p0_rd_valid;
  logic                                   p0_rd_ready;
  logic         [$clog2(P0_FIFO_DEPTH):0] p0_fill;

  SimpleFifo #(
      .DEPTH(P0_FIFO_DEPTH)
  ) u_p0_fifo (
      .clk     (clk),
      .rst     (rst),
      .wr_data (p0_data),
      .wr_valid(p0_valid),
      .wr_ready(p0_ready),
      .rd_data (p0_rd_data),
      .rd_valid(p0_rd_valid),
      .rd_ready(p0_rd_ready),
      .fill    (p0_fill)
  );

  byte unsigned                           p1_rd_data;
  logic                                   p1_rd_valid;
  logic                                   p1_rd_ready;
  logic         [$clog2(P1_FIFO_DEPTH):0] p1_fill;

  SimpleFifo #(
      .DEPTH(P1_FIFO_DEPTH)
  ) u_p1_fifo (
      .clk     (clk),
      .rst     (rst),
      .wr_data (p1_data),
      .wr_valid(p1_valid),
      .wr_ready(p1_ready),
      .rd_data (p1_rd_data),
      .rd_valid(p1_rd_valid),
      .rd_ready(p1_rd_ready),
      .fill    (p1_fill)
  );

  // Frame Header Parser
  Frame::FrameCtx frame_ctx;
  logic           frame_ctx_done;
  logic           fhp_raw_ready;

  BoolDecoderIf fhp_bd ();
  BoolDecoderIf mbhp_bd ();

  FrameHeaderParser u_fhp (
      .clk      (clk),
      .rst      (rst),
      .raw_data (p0_rd_data),
      .raw_valid(p0_rd_valid),
      .raw_ready(fhp_raw_ready),
      .bd       (fhp_bd),
      .ctx      (frame_ctx),
      .done     (frame_ctx_done)
  );

  assign frame_width  = frame_ctx.width;
  assign frame_height = frame_ctx.height;

  // BD0 byte-stream handoff guard
  logic bd0_mem_data_ready;
  logic bd1_mem_data_ready;

  assign p0_rd_ready = fhp_raw_ready ? 1'b1 : bd0_mem_data_ready;
  assign p1_rd_ready = bd1_mem_data_ready;

  // BD0 user mux: FHP owns bd0 until frame_ctx.valid, then MBHP takes over
  BoolDecoderIf bd0 ();
  BoolDecoderIf bd1 ();

  always_comb begin
    if (!frame_ctx.valid) begin
      bd0.valid          = fhp_bd.valid;
      bd0.prob           = fhp_bd.prob;
      bd0.data_ready     = fhp_bd.data_ready;
      fhp_bd.ready       = bd0.ready;
      fhp_bd.data_valid  = bd0.data_valid;
      fhp_bd.data        = bd0.data;
      mbhp_bd.ready      = 1'b0;
      mbhp_bd.data_valid = 1'b0;
      mbhp_bd.data       = 1'b0;
    end else begin
      bd0.valid          = mbhp_bd.valid;
      bd0.prob           = mbhp_bd.prob;
      bd0.data_ready     = mbhp_bd.data_ready;
      mbhp_bd.ready      = bd0.ready;
      mbhp_bd.data_valid = bd0.data_valid;
      mbhp_bd.data       = bd0.data;
      fhp_bd.ready       = 1'b0;
      fhp_bd.data_valid  = 1'b0;
      fhp_bd.data        = 1'b0;
    end
  end

  // BoolDecoders
  BoolDecoder u_bd0 (
      .clk           (clk),
      .rst           (rst),
      .mem_ready     (p0_rd_valid & !fhp_raw_ready),
      .mem_valid     (),
      .mem_data_valid(p0_rd_valid & !fhp_raw_ready),
      .mem_data_ready(bd0_mem_data_ready),
      .mem_data      (p0_rd_data),
      .self          (bd0)
  );

  BoolDecoder u_bd1 (
      .clk           (clk),
      .rst           (rst),
      .mem_ready     (p1_rd_valid),
      .mem_valid     (),
      .mem_data_valid(p1_rd_valid),
      .mem_data_ready(bd1_mem_data_ready),
      .mem_data      (p1_rd_data),
      .self          (bd1)
  );

  // Macroblock Header Parser
  Macroblock::Header mb_header;
  logic              mb_header_valid;
  logic              mb_header_ready;

  Macroblock::Header left_hdr;
  Macroblock::Header above_hdr       [0:MAX_MB_COLS-1];
  logic              left_valid;
  logic              above_valid;
  byte unsigned      mb_col;
  byte unsigned      mb_row;

  HeaderParser u_mbhp (
      .clk         (clk),
      .rst         (rst),
      .bd          (mbhp_bd),
      .frame_ctx   (frame_ctx),
      .left_header (left_hdr),
      .left_valid  (left_valid),
      .above_header(above_hdr[7'(mb_col)]),
      .above_valid (above_valid),
      .x           (mb_col),
      .y           (mb_row),
      .header      (mb_header),
      .valid       (mb_header_valid),
      .ready       (mb_header_ready)
  );

  logic resdec_mb_ready;
  assign mb_header_ready = resdec_mb_ready && !last_mb_accepted;

  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      mb_col      <= '0;
      mb_row      <= '0;
      left_valid  <= 1'b0;
      above_valid <= 1'b0;
      left_hdr    <= '0;
      for (int i = 0; i < MAX_MB_COLS; i++) above_hdr[i] <= '0;
    end else if (mb_header_valid && mb_header_ready) begin
      above_hdr[7'(mb_col)] <= mb_header;
      left_hdr              <= mb_header;
      if (mb_col == byte'(frame_ctx.mb_width) - 1) begin
        mb_col      <= 8'd0;
        mb_row      <= mb_row + 1'b1;
        left_valid  <= 1'b0;
        above_valid <= 1'b1;
      end else begin
        mb_col      <= mb_col + 1'b1;
        left_valid  <= 1'b1;
        above_valid <= (mb_row > 0);
      end
    end
  end

  // has_coeff context
  logic         [8:0] hc_top_arr     [0:MAX_MB_COLS-1];
  logic         [8:0] hc_left_reg;
  logic         [8:0] hc_left_out;
  logic         [8:0] hc_top_out;
  logic         [8:0] hc_top_latched;

  byte unsigned       res_mb_col;
  byte unsigned       res_mb_row;

  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      hc_left_reg    <= 9'd0;
      hc_top_latched <= 9'd0;
      for (int i = 0; i < MAX_MB_COLS; i++) hc_top_arr[i] <= 9'd0;
      res_mb_col <= '0;
      res_mb_row <= '0;
    end else begin
      if (res_valid) begin
        hc_top_arr[7'(res_mb_col)] <= hc_top_out;
        hc_left_reg                <= hc_left_out;
      end
      if (mb_header_valid && resdec_mb_ready) begin
        res_mb_col     <= mb_col;
        res_mb_row     <= mb_row;
        hc_top_latched <= hc_top_arr[7'(mb_col)];
        if (mb_col == 8'd0) hc_left_reg <= 9'd0;
      end
    end
  end

  // Token Decoder
  logic           [1:0] td_plane;
  logic           [1:0] td_complexity;
  logic                 td_first_coeff;
  shortint signed       td_dcq;
  shortint signed       td_acq;
  logic                 td_start;
  logic                 td_busy;
  shortint signed       td_coeffs      [0:15];
  logic                 td_has_coeff;
  logic                 td_coeff_valid;

  TokenDecoder u_tokdec (
      .clk        (clk),
      .rst        (rst),
      .bd         (bd1),
      .plane      (td_plane),
      .complexity (td_complexity),
      .first_coeff(td_first_coeff),
      .dcq        (td_dcq),
      .acq        (td_acq),
      .frame_ctx  (frame_ctx),
      .start      (td_start),
      .busy       (td_busy),
      .coeffs     (td_coeffs),
      .has_coeff  (td_has_coeff),
      .coeff_valid(td_coeff_valid)
  );

  // IDCT / IWHT
  Idct4x4If idct_bus ();
  Idct4x4If wht_bus ();

  Idct4x4 u_idct (
      .clk (clk),
      .rst (rst),
      .self(idct_bus)
  );
  Iwht4x4 u_wht (
      .clk (clk),
      .rst (rst),
      .self(wht_bus)
  );

  logic           use_wht;
  logic           idct_coeff_valid;
  logic           idct_coeff_ready;
  shortint signed idct_coeff       [0:3][0:3];
  logic           idct_block_valid;
  logic           idct_block_ready;
  shortint signed idct_block       [0:3][0:3];

  always_comb begin
    idct_bus.coeff_valid = idct_coeff_valid & ~use_wht;
    idct_bus.coeff       = idct_coeff;
    idct_bus.block_ready = idct_block_ready & ~use_wht;
    wht_bus.coeff_valid  = idct_coeff_valid & use_wht;
    wht_bus.coeff        = idct_coeff;
    wht_bus.block_ready  = idct_block_ready & use_wht;
    idct_coeff_ready     = use_wht ? wht_bus.coeff_ready : idct_bus.coeff_ready;
    idct_block_valid     = use_wht ? wht_bus.block_valid : idct_bus.block_valid;
    idct_block           = use_wht ? wht_bus.block : idct_bus.block;
  end

  // Residue Decoder
  ResiduePkg::MbResiduals residuals;
  logic                   res_valid;

  Macroblock::Header      res_mb_header;
  // mb_valid_r: finally it works, that was a timing nightmare
  logic                   mb_valid_r;
  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      res_mb_header <= '0;
      mb_valid_r    <= 1'b0;
    end else begin
      mb_valid_r <= mb_header_valid && resdec_mb_ready;
      if (mb_header_valid && resdec_mb_ready) res_mb_header <= mb_header;
    end
  end

  // resdec_mb_ready must be low while mb_valid_r is pending so the
  // MBHP cannot push a second header before residue decoder has consumed the
  // first one.
  ResidueDecoder u_resdec (
      .clk             (clk),
      .rst             (rst),
      .mb_header       (res_mb_header),
      .mb_valid        (mb_valid_r),
      .mb_ready        (resdec_mb_ready),
      .frame_ctx       (frame_ctx),
      .hc_left         (hc_left_reg),
      .hc_top          (hc_top_latched),
      .hc_left_out     (hc_left_out),
      .hc_top_out      (hc_top_out),
      .td_plane        (td_plane),
      .td_complexity   (td_complexity),
      .td_first_coeff  (td_first_coeff),
      .td_dcq          (td_dcq),
      .td_acq          (td_acq),
      .td_start        (td_start),
      .td_busy         (td_busy),
      .td_coeffs       (td_coeffs),
      .td_has_coeff    (td_has_coeff),
      .td_coeff_valid  (td_coeff_valid),
      .idct_coeff_valid(idct_coeff_valid),
      .idct_coeff_ready(idct_coeff_ready),
      .idct_coeff      (idct_coeff),
      .use_wht         (use_wht),
      .idct_block_valid(idct_block_valid),
      .idct_block_ready(idct_block_ready),
      .idct_block      (idct_block),
      .residuals       (residuals),
      .res_valid       (res_valid),
      .res_ready       (1'b1)
  );

  // Frame Buffer + Predictor
  byte unsigned fb_top_y[0:15], fb_top_cb[0:7], fb_top_cr[0:7];
  byte unsigned fb_left_y[0:15], fb_left_cb[0:7], fb_left_cr[0:7];
  byte unsigned fb_tl_y, fb_tl_cb, fb_tl_cr;
  byte unsigned fb_tr_y[0:3];
  logic fb_top_v, fb_left_v, fb_tl_v, fb_tr_v;

  PredictorPkg::MbPixels mb_pixels;

  FrameBuffer #(
      .MAX_WIDTH (MAX_WIDTH),
      .MAX_HEIGHT(MAX_HEIGHT)
  ) u_fb (
      .clk              (clk),
      .rst              (rst),
      .width            (frame_ctx.width),
      .height           (frame_ctx.height),
      .wr_valid         (res_valid),
      .wr_ready         (  /* always 1 */),
      .wr_mb_col        (res_mb_col),
      .wr_mb_row        (res_mb_row),
      .wr_y             (mb_pixels.y),
      .wr_cb            (mb_pixels.cb),
      .wr_cr            (mb_pixels.cr),
      .rd_mb_col        (res_mb_col),
      .rd_mb_row        (res_mb_row),
      .rd_top_y         (fb_top_y),
      .rd_top_cb        (fb_top_cb),
      .rd_top_cr        (fb_top_cr),
      .rd_left_y        (fb_left_y),
      .rd_left_cb       (fb_left_cb),
      .rd_left_cr       (fb_left_cr),
      .rd_topleft_y     (fb_tl_y),
      .rd_topleft_cb    (fb_tl_cb),
      .rd_topleft_cr    (fb_tl_cr),
      .rd_topright_y    (fb_tr_y),
      .rd_top_valid     (fb_top_v),
      .rd_left_valid    (fb_left_v),
      .rd_topleft_valid (fb_tl_v),
      .rd_topright_valid(fb_tr_v)
  );

  Predictor u_pred (
      .header        (res_mb_header),
      .residuals     (residuals),
      .top_valid     (fb_top_v),
      .top_y         (fb_top_y),
      .top_cb        (fb_top_cb),
      .top_cr        (fb_top_cr),
      .left_valid    (fb_left_v),
      .left_y        (fb_left_y),
      .left_cb       (fb_left_cb),
      .left_cr       (fb_left_cr),
      .topleft_valid (fb_tl_v),
      .topleft_y     (fb_tl_y),
      .topleft_cb    (fb_tl_cb),
      .topleft_cr    (fb_tl_cr),
      .topright_valid(fb_tr_v),
      .topright_y    (fb_tr_y),
      .pixels        (mb_pixels)
  );

  // frame_done
  always_comb begin
    frame_done = res_valid
              && (res_mb_row == byte'(int'(frame_ctx.mb_height) - 1))
              && (res_mb_col == byte'(int'(frame_ctx.mb_width)  - 1));
  end

  // signal stop at frame boundery so mbh dont consume extra bits from bd0
  always_ff @(posedge clk or negedge rst) begin
    if (!rst) last_mb_accepted <= 1'b0;
    else if (mb_valid_r
             && (mb_row == byte'(int'(frame_ctx.mb_height) - 1))
             && (mb_col == byte'(int'(frame_ctx.mb_width)  - 1)))
      last_mb_accepted <= 1'b1;
  end

endmodule

// Test wrapper
module VpAteTest (
    input var logic clk,
    input var logic rst,

    // Partition streams
    input var  byte unsigned p0_data,
    input var  logic         p0_valid,
    output var logic         p0_ready,

    input var  byte unsigned p1_data,
    input var  logic         p1_valid,
    output var logic         p1_ready,

    // Frame outputs
    output var logic             frame_done,
    output var shortint unsigned frame_width,
    output var shortint unsigned frame_height,

    // Diagnostic
    output var logic [ 5:0] fhp_state,
    output var logic        fhp_valid,
    output var logic [ 5:0] bd0_state,
    output var logic [ 6:0] mbhp_state,
    output var logic [ 6:0] resdec_state,
    output var logic [ 4:0] resdec_seq,
    output var logic [ 5:0] bd1_state,
    output var logic [15:0] p0_fill_low,
    output var logic [15:0] p1_fill_low,
    output var logic        bd0_v,
    output var logic        bd0_r,
    output var logic        bd0_dv,
    output var logic        bd0_dr,
    output var logic        mbhp_pend,
    output var logic [ 7:0] res_mb_col_out,
    output var logic [ 7:0] res_mb_row_out,
    output var logic [ 3:0] idct_state,
    output var logic [ 3:0] wht_state,
    output var logic        idct_cv,
    output var logic        idct_cr,
    output var logic        idct_bv,
    output var logic        idct_br,
    output var logic        use_wht_out,

    // BDx stream
    output var logic       bd0_bit_valid,
    output var logic [7:0] bd0_bit_prob,
    output var logic       bd0_bit_value,

    output var logic       bd1_bit_valid,
    output var logic [7:0] bd1_bit_prob,
    output var logic       bd1_bit_value,

    output var logic res_valid_out,

    // snapshot for test bench
    output var logic [   7:0] snap_mb_col,
    output var logic [   7:0] snap_mb_row,
    output var logic [   2:0] snap_intra_y_mode,
    output var logic [   2:0] snap_intra_uv_mode,
    output var logic          snap_skip_coeff,
    output var logic [  63:0] snap_sub_modes_flat,
    output var logic [4095:0] snap_luma_flat,
    output var logic [2047:0] snap_chroma_flat,
    output var logic [2047:0] snap_y_pixels_flat,
    output var logic [ 511:0] snap_cb_pixels_flat,
    output var logic [ 511:0] snap_cr_pixels_flat,

    output var logic         snap_block_valid,
    output var logic [  4:0] snap_block_seq,
    output var logic         snap_block_has_coeff,
    output var logic [255:0] snap_block_coeffs_flat
);

  assign fhp_state          = decoder.u_fhp.state;
  assign fhp_valid          = decoder.frame_ctx.valid;
  assign bd0_state          = decoder.u_bd0.state;
  assign mbhp_state         = decoder.u_mbhp.state;
  assign resdec_state       = decoder.u_resdec.state;
  assign resdec_seq         = decoder.u_resdec.seq;
  assign bd1_state          = decoder.u_bd1.state;
  assign p0_fill_low        = decoder.p0_fill[15:0];
  assign p1_fill_low        = decoder.p1_fill[15:0];
  assign bd0_v              = decoder.bd0.valid;
  assign bd0_r              = decoder.bd0.ready;
  assign bd0_dv             = decoder.bd0.data_valid;
  assign bd0_dr             = decoder.bd0.data_ready;
  assign mbhp_pend          = decoder.u_mbhp.bd_req_pend;
  assign res_mb_col_out     = decoder.res_mb_col;
  assign res_mb_row_out     = decoder.res_mb_row;
  assign idct_state         = decoder.u_idct.state;
  assign wht_state          = decoder.u_wht.state;
  assign idct_cv            = decoder.idct_coeff_valid;
  assign idct_cr            = decoder.idct_coeff_ready;
  assign idct_bv            = decoder.idct_block_valid;
  assign idct_br            = decoder.idct_block_ready;
  assign use_wht_out        = decoder.use_wht;

  assign bd0_bit_valid      = decoder.bd0.data_valid & decoder.bd0.data_ready;
  assign bd0_bit_prob       = decoder.bd0.prob;
  assign bd0_bit_value      = decoder.bd0.data;

  assign bd1_bit_valid      = decoder.bd1.data_valid & decoder.bd1.data_ready;
  assign bd1_bit_prob       = decoder.bd1.prob;
  assign bd1_bit_value      = decoder.bd1.data;

  assign res_valid_out      = decoder.res_valid;

  assign snap_mb_col        = decoder.res_mb_col;
  assign snap_mb_row        = decoder.res_mb_row;
  assign snap_intra_y_mode  = 3'(decoder.res_mb_header.intra_y_mode);
  assign snap_intra_uv_mode = 3'(decoder.res_mb_header.intra_uv_mode);
  assign snap_skip_coeff    = decoder.res_mb_header.mb_skip_coeff;

  generate
    for (genvar gy = 0; gy < 4; gy++)
    for (genvar gx = 0; gx < 4; gx++)
      assign snap_sub_modes_flat[(gy*4+gx)*4+:4] = 4'(decoder.res_mb_header.sub_modes[gy][gx]);
  endgenerate

  generate
    for (genvar gr = 0; gr < 16; gr++)
    for (genvar gc = 0; gc < 16; gc++)
      assign snap_luma_flat[(gr*16+gc)*16+:16] = 16'(decoder.residuals.luma[gr][gc]);
  endgenerate

  generate
    for (genvar gp = 0; gp < 2; gp++)
    for (genvar gr = 0; gr < 8; gr++)
    for (genvar gc = 0; gc < 8; gc++)
      assign snap_chroma_flat[(gp*64+gr*8+gc)*16+:16] = 16'(decoder.residuals.chroma[gp][gr][gc]);
  endgenerate

  generate
    for (genvar gr = 0; gr < 16; gr++)
    for (genvar gc = 0; gc < 16; gc++)
      assign snap_y_pixels_flat[(gr*16+gc)*8+:8] = decoder.mb_pixels.y[gr][gc];
  endgenerate

  generate
    for (genvar gr = 0; gr < 8; gr++)
    for (genvar gc = 0; gc < 8; gc++) begin
      assign snap_cb_pixels_flat[(gr*8+gc)*8+:8] = decoder.mb_pixels.cb[gr][gc];
      assign snap_cr_pixels_flat[(gr*8+gc)*8+:8] = decoder.mb_pixels.cr[gr][gc];
    end
  endgenerate

  logic [4:0] snap_seq_r;
  logic       snap_valid_r;

  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      snap_seq_r   <= '0;
      snap_valid_r <= 1'b0;
    end else begin
      snap_valid_r <= decoder.u_resdec.td_coeff_valid;
      if (decoder.u_resdec.td_coeff_valid) snap_seq_r <= decoder.u_resdec.seq;
    end
  end

  assign snap_block_valid     = snap_valid_r;
  assign snap_block_seq       = snap_seq_r;
  assign snap_block_has_coeff = decoder.u_resdec.tok_hc;

  generate
    for (genvar gi = 0; gi < 16; gi++)
      assign snap_block_coeffs_flat[gi*16+:16] = 16'(decoder.u_resdec.tok_buf[gi]);
  endgenerate

  VpAte decoder (
      .clk         (clk),
      .rst         (rst),
      .p0_data     (p0_data),
      .p0_valid    (p0_valid),
      .p0_ready    (p0_ready),
      .p1_data     (p1_data),
      .p1_valid    (p1_valid),
      .p1_ready    (p1_ready),
      .frame_done  (frame_done),
      .frame_width (frame_width),
      .frame_height(frame_height)
  );

endmodule
