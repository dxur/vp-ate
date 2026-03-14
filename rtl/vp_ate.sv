// VpAte - top-level VP8 intra-only decoder (no segmentation).
//
// Dataflow:
//   stream bytes
//     -> RingBuffer (dual-pointer: p0=part0, p1=part1)
//     -> FrameHeaderParser  (p0 raw bytes + bd0 -> FrameCtx)
//     -> MacroblockHeaderParser (bd0/p0, per-MB -> MacroblockHeader)
//     -> ResidueDecoder     (bd1/p1, via TokenDecoder -> MbResiduals)
//     -> Predictor          (combinational, FrameBuffer edges -> MbPixels)
//     -> FrameBuffer        (write reconstructed MB)
//
// Ring buffer - dual independent read pointers:
//   p0  feeds FHP (raw bytes) then bd0 (MBHP bool-decode).
//       p0 drains contiguously from byte 0 of the frame.
//   p1  feeds bd1 (residue token bool-decode).
//       p1 is inactive until frame_ctx_done fires, at which point a one-shot
//       seek sets p1_ptr = frame_ctx.part1_off[RING_AW-1:0].
//   wr_ready is deasserted when either active pointer is a full buffer behind
//   the write pointer, so neither partition can overwrite the other.
//
// Ring drain mux for p0:
//   Phase 0 (!frame_ctx_done): FHP owns p0 (raw header bytes).
//   Phase 1 ( frame_ctx_done): bd0 owns p0 (MBHP bool-decode).
//   p0_rd_ready = frame_ctx_done ? bd0_mem_data_ready : fhp_raw_ready
//
// p1 seek:
//   Fires the cycle frame_ctx_done is first asserted.
//   seek_addr = frame_ctx.part1_off[RING_AW-1:0]
//   After that bd1 drains p1 independently of p0.
//
// MB position tracking:
//   mb_col/mb_row advance on mb_header_valid & mb_header_ready.
//   ResidueDecoder takes many cycles per MB; we latch (res_mb_col,
//   res_mb_row, res_mb_header) when ResidueDecoder accepts a header.
//   FrameBuffer write address and frame_done use the latched values.
//
// has_coeff context:
//   Packing: {y2_hc[0], y_hc[3:0], u_hc[1:0], v_hc[1:0]} = 9 bits
//   hc_top_arr[col] : per-column top context, updated after each res_valid
//   hc_left_reg     : left context, reset to 0 at start of each row

import MacroblockHeaderPkg::*;
import Frame::*;
import ResiduePkg::*;
import PredictorPkg::*;

module VpAte #(
    parameter int unsigned BUFFER_SIZE = 64 * 1024,
    parameter int unsigned MB_SLOTS    = 16,
    parameter int unsigned MAX_WIDTH   = 1280,
    parameter int unsigned MAX_HEIGHT  = 720
) (
    input var  logic         clk,
    input var  logic         rst,

    // Input stream
    input var  byte unsigned data,
    input var  logic         data_valid,
    output var logic         data_ready,

    // Frame-done output
    output var logic             frame_done,
    output var shortint unsigned frame_width,
    output var shortint unsigned frame_height
);

  localparam int unsigned MAX_MB_COLS = MAX_WIDTH  / 16;
  localparam int unsigned MAX_MB_ROWS = MAX_HEIGHT / 16;
  localparam int unsigned RING_AW     = $clog2(BUFFER_SIZE);

  // -------------------------------------------------------------------------
  // Ring buffer  (dual read pointers)
  // -------------------------------------------------------------------------
  // p0 (part0: FHP raw + bd0 MBHP)
  byte unsigned      p0_rd_data;
  logic              p0_rd_valid;
  logic              p0_rd_ready;
  logic [RING_AW:0]  p0_fill;

  // p1 (part1: bd1 residue tokens)
  byte unsigned      p1_rd_data;
  logic              p1_rd_valid;
  logic              p1_rd_ready;
  logic [RING_AW:0]  p1_fill;

  // p1 seek - one-shot when frame_ctx_done first asserts
  logic              p1_seek;
  logic [RING_AW-1:0] p1_seek_addr;
  logic              p1_sought;    // sticky latch: prevents re-seek

  // peek (FHP uses this for raw random-access; tied off here)
  logic [RING_AW-1:0] ring_peek_addr;
  byte unsigned       ring_peek_data;
  assign ring_peek_addr = '0;

  logic ring_wr_ready;
  assign data_ready = ring_wr_ready;

  RingBuffer #(.DEPTH(BUFFER_SIZE)) u_ring (
      .clk          (clk),
      .rst          (rst),
      .wr_data      (data),
      .wr_valid     (data_valid),
      .wr_ready     (ring_wr_ready),
      .p0_rd_data   (p0_rd_data),
      .p0_rd_valid  (p0_rd_valid),
      .p0_rd_ready  (p0_rd_ready),
      .p0_fill      (p0_fill),
      .p1_rd_data   (p1_rd_data),
      .p1_rd_valid  (p1_rd_valid),
      .p1_rd_ready  (p1_rd_ready),
      .p1_fill      (p1_fill),
      .p1_seek      (p1_seek),
      .p1_seek_addr (p1_seek_addr),
      .peek_addr    (ring_peek_addr),
      .peek_data    (ring_peek_data)
  );

  // -------------------------------------------------------------------------
  // Frame Header Parser
  // -------------------------------------------------------------------------
  Frame::FrameCtx frame_ctx;
  logic           frame_ctx_done;

  // FHP drives p0 until done (raw header bytes + its own bool-decode bytes).
  logic fhp_raw_ready;

  FrameHeaderParser u_fhp (
      .clk       (clk),
      .rst       (rst),
      .raw_data  (p0_rd_data),
      .raw_valid (p0_rd_valid),
      .raw_ready (fhp_raw_ready),
      .bd        (bd0),
      .ctx       (frame_ctx),
      .done      (frame_ctx_done)
  );

  assign frame_width  = frame_ctx.width;
  assign frame_height = frame_ctx.height;

  // -------------------------------------------------------------------------
  // p1 seek: fires once the cycle frame_ctx_done first asserts.
  // seek_addr is the low RING_AW bits of frame_ctx.part1_off.
  // -------------------------------------------------------------------------
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) p1_sought <= 1'b0;
    else if (p1_seek) p1_sought <= 1'b1;
  end

  always_comb begin
    p1_seek      = frame_ctx_done && !p1_sought;
    p1_seek_addr = frame_ctx.part1_off[RING_AW-1:0];
  end

  // -------------------------------------------------------------------------
  // BoolDecoder - part0  (MBHP, drains p0 after FHP is done)
  // BoolDecoder - part1  (residue tokens, drains p1 independently)
  //
  // p0 drain mux:
  //   !frame_ctx_done -> FHP owns p0  (fhp_raw_ready drives p0_rd_ready)
  //    frame_ctx_done -> bd0 owns p0  (bd0_mem_data_ready drives p0_rd_ready)
  //
  // p1 drain:
  //   bd1_mem_data_ready drives p1_rd_ready directly; p1 is inactive
  //   (p1_rd_valid=0) until after the seek, so bd1 will simply stall.
  // -------------------------------------------------------------------------
  BoolDecoderIf bd0 ();
  BoolDecoderIf bd1 ();

  logic bd0_mem_data_ready;
  logic bd1_mem_data_ready;

  // p0 drain mux
  assign p0_rd_ready = frame_ctx_done ? bd0_mem_data_ready : fhp_raw_ready;

  // p1 drain - directly to bd1
  assign p1_rd_ready = bd1_mem_data_ready;

  BoolDecoder u_bd0 (
      .clk           (clk),
      .rst           (rst),
      .mem_ready     (p0_rd_valid & frame_ctx_done),
      .mem_valid     (/* unused - pull model */),
      .mem_data_valid(p0_rd_valid & frame_ctx_done),
      .mem_data_ready(bd0_mem_data_ready),
      .mem_data      (p0_rd_data),
      .self          (bd0)
  );

  BoolDecoder u_bd1 (
      .clk           (clk),
      .rst           (rst),
      .mem_ready     (p1_rd_valid),
      .mem_valid     (/* unused - pull model */),
      .mem_data_valid(p1_rd_valid),
      .mem_data_ready(bd1_mem_data_ready),
      .mem_data      (p1_rd_data),
      .self          (bd1)
  );

  // -------------------------------------------------------------------------
  // Macroblock Header Parser
  // -------------------------------------------------------------------------
  MacroblockHeaderPkg::MacroblockHeader mb_header;
  logic                                 mb_header_valid;
  logic                                 mb_header_ready;

  MacroblockHeaderPkg::MacroblockHeader left_hdr;
  MacroblockHeaderPkg::MacroblockHeader above_hdr [0:MAX_MB_COLS-1];
  logic                                 left_valid;
  logic                                 above_valid;
  byte unsigned                         mb_col;
  byte unsigned                         mb_row;

  MacroblockHeaderParser u_mbhp (
      .clk         (clk),
      .rst         (rst),
      .bd          (bd0),
      .frame_ctx   (frame_ctx),
      .left_header (left_hdr),
      .left_valid  (left_valid),
      .above_header(above_hdr[mb_col]),
      .above_valid (above_valid),
      .x           (mb_col),
      .y           (mb_row),
      .header      (mb_header),
      .valid       (mb_header_valid),
      .ready       (mb_header_ready)
  );

  // ResidueDecoder paces the header stream
  logic resdec_mb_ready;
  assign mb_header_ready = resdec_mb_ready;

  // MB position counter - advances on accepted header
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      mb_col      <= '0;
      mb_row      <= '0;
      left_valid  <= 1'b0;
      above_valid <= 1'b0;
      left_hdr    <= '{default: 0};
      for (int i = 0; i < MAX_MB_COLS; i++) above_hdr[i] <= '{default: 0};
    end else begin
      if (mb_header_valid && mb_header_ready) begin
        above_hdr[mb_col] <= mb_header;
        left_hdr          <= mb_header;
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
  end

  // -------------------------------------------------------------------------
  // has_coeff context arrays
  //   hc_top_arr[col] : top context for each MB column
  //   hc_left_reg     : left context, reset to 0 at start of each row
  // -------------------------------------------------------------------------
  logic [8:0] hc_top_arr [0:MAX_MB_COLS-1];
  logic [8:0] hc_left_reg;
  logic [8:0] hc_left_out;
  logic [8:0] hc_top_out;

  byte unsigned res_mb_col;
  byte unsigned res_mb_row;

  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      hc_left_reg <= 9'd0;
      for (int i = 0; i < MAX_MB_COLS; i++) hc_top_arr[i] <= 9'd0;
      res_mb_col  <= '0;
      res_mb_row  <= '0;
    end else begin
      if (mb_header_valid && resdec_mb_ready) begin
        res_mb_col  <= mb_col;
        res_mb_row  <= mb_row;
        hc_left_reg <= (mb_col == 8'd0) ? 9'd0 : hc_left_out;
      end
      if (res_valid) begin
        hc_top_arr[res_mb_col] <= hc_top_out;
        hc_left_reg            <= hc_left_out;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Token Decoder  (driven by ResidueDecoder, uses bd1/p1)
  // -------------------------------------------------------------------------
  logic [1:0]      td_plane;
  logic [1:0]      td_complexity;
  logic            td_first_coeff;
  shortint signed  td_dcq;
  shortint signed  td_acq;
  logic            td_start;
  logic            td_busy;
  shortint signed  td_coeffs [0:15];
  logic            td_has_coeff;
  logic            td_coeff_valid;

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

  // -------------------------------------------------------------------------
  // IDCT / IWHT  (use_wht from ResidueDecoder selects which fires)
  // -------------------------------------------------------------------------
  Idct4x4If idct_bus ();
  Idct4x4If wht_bus  ();

  Idct4x4 u_idct (.clk(clk), .rst(rst), .self(idct_bus));
  Iwht4x4 u_wht  (.clk(clk), .rst(rst), .self(wht_bus));

  logic            use_wht;
  logic            idct_coeff_valid;
  logic            idct_coeff_ready;
  shortint signed  idct_coeff [0:3][0:3];
  logic            idct_block_valid;
  logic            idct_block_ready;
  shortint signed  idct_block [0:3][0:3];

  always_comb begin
    idct_bus.coeff_valid = idct_coeff_valid & ~use_wht;
    idct_bus.coeff       = idct_coeff;
    idct_bus.block_ready = idct_block_ready & ~use_wht;

    wht_bus.coeff_valid  = idct_coeff_valid & use_wht;
    wht_bus.coeff        = idct_coeff;
    wht_bus.block_ready  = idct_block_ready & use_wht;

    idct_coeff_ready = use_wht ? wht_bus.coeff_ready  : idct_bus.coeff_ready;
    idct_block_valid = use_wht ? wht_bus.block_valid   : idct_bus.block_valid;
    idct_block       = use_wht ? wht_bus.block         : idct_bus.block;
  end

  // -------------------------------------------------------------------------
  // Residue Decoder
  // -------------------------------------------------------------------------
  ResiduePkg::MbResiduals residuals;
  logic                   res_valid;

  ResidueDecoder u_resdec (
      .clk             (clk),
      .rst             (rst),
      .mb_header       (mb_header),
      .mb_valid        (mb_header_valid),
      .mb_ready        (resdec_mb_ready),
      .frame_ctx       (frame_ctx),
      .hc_left         (hc_left_reg),
      .hc_top          (hc_top_arr[mb_col]),
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
      .wht_coeff_valid (wht_bus.block_valid),
      .use_wht         (use_wht),
      .idct_block_valid(idct_block_valid),
      .idct_block_ready(idct_block_ready),
      .idct_block      (idct_block),
      .residuals       (residuals),
      .res_valid       (res_valid),
      .res_ready       (1'b1)   // Predictor is combinational, always ready
  );

  // -------------------------------------------------------------------------
  // Frame Buffer + Predictor
  // -------------------------------------------------------------------------
  byte unsigned fb_top_y  [0:15], fb_top_cb  [0:7], fb_top_cr  [0:7];
  byte unsigned fb_left_y [0:15], fb_left_cb [0:7], fb_left_cr [0:7];
  byte unsigned fb_tl_y,          fb_tl_cb,          fb_tl_cr;
  byte unsigned fb_tr_y   [0:3];
  logic         fb_top_v, fb_left_v, fb_tl_v, fb_tr_v;

  PredictorPkg::MbPixels mb_pixels;

  // Latch the MB header at the time ResidueDecoder accepts it, so it stays
  // stable for all the cycles ResidueDecoder takes to finish.
  MacroblockHeaderPkg::MacroblockHeader res_mb_header;

  always_ff @(posedge clk, negedge rst) begin
    if (!rst) res_mb_header <= '{default: 0};
    else if (mb_header_valid && resdec_mb_ready)
      res_mb_header <= mb_header;
  end

  FrameBuffer #(.MAX_WIDTH(MAX_WIDTH), .MAX_HEIGHT(MAX_HEIGHT)) u_fb (
      .clk              (clk),
      .rst              (rst),
      .width            (frame_ctx.width),
      .height           (frame_ctx.height),
      .wr_valid         (res_valid),
      .wr_ready         (/* always 1 */),
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
      .top_valid     (fb_top_v),   .top_y (fb_top_y),   .top_cb (fb_top_cb),   .top_cr (fb_top_cr),
      .left_valid    (fb_left_v),  .left_y(fb_left_y),  .left_cb(fb_left_cb),  .left_cr(fb_left_cr),
      .topleft_valid (fb_tl_v),    .topleft_y(fb_tl_y), .topleft_cb(fb_tl_cb), .topleft_cr(fb_tl_cr),
      .topright_valid(fb_tr_v),    .topright_y(fb_tr_y),
      .pixels        (mb_pixels)
  );

  // -------------------------------------------------------------------------
  // frame_done - pulses when last MB residuals are ready
  // -------------------------------------------------------------------------
  always_comb begin
    frame_done = res_valid
              && (res_mb_row == byte'(frame_ctx.mb_height - 1))
              && (res_mb_col == byte'(frame_ctx.mb_width  - 1));
  end

endmodule

// ---------------------------------------------------------------------------
// Test wrapper (flat ports for cocotb)
// ---------------------------------------------------------------------------
module VpAteTest (
    input var  logic             clk,
    input var  logic             rst,
    input var  byte unsigned     data,
    input var  logic             data_valid,
    output var logic             data_ready,
    output var logic             frame_done,
    output var shortint unsigned frame_width,
    output var shortint unsigned frame_height
);
  VpAte decoder (
      .clk         (clk),
      .rst         (rst),
      .data        (data),
      .data_valid  (data_valid),
      .data_ready  (data_ready),
      .frame_done  (frame_done),
      .frame_width (frame_width),
      .frame_height(frame_height)
  );
endmodule
