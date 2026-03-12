// VpAte - top-level VP8 intra decoder.
//
// Dataflow:
//   stream bytes
//     -> RingBuffer
//     -> FrameHeaderParser (raw bytes [0-9] + part0 BoolDecoder -> FrameCtx)
//     -> MacroblockHeaderParser (per-MB, part0 BoolDecoder -> MacroblockHeader)
//     -> [MB header ring - MB_SLOTS deep]
//     -> ResidueDecoder (part1 BoolDecoder -> MbResiduals, via TokenDecoder)
//     -> Predictor (combinational, FrameBuffer edges -> MbPixels)
//     -> FrameBuffer (write reconstructed MB)
//
// For now this is the structural integration skeleton. Backpressure and
// the full MB-slot ring are wired in simplified form.

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
    output var logic         frame_done,    // pulses when last MB is written
    output var shortint unsigned frame_width,
    output var shortint unsigned frame_height
);

  // -----------------------------------------------------------------------
  // Ring buffer
  // -----------------------------------------------------------------------
  logic                [$clog2(BUFFER_SIZE)-1:0] ring_peek_addr;
  byte unsigned                                  ring_peek_data;
  logic                [$clog2(BUFFER_SIZE):0]   ring_fill;
  logic                                          ring_rd_valid;
  logic                                          ring_rd_ready;
  byte unsigned                                  ring_rd_data;
  logic                                          ring_wr_ready;

  assign data_ready = ring_wr_ready;

  RingBuffer #(.DEPTH(BUFFER_SIZE)) u_ring (
      .clk        (clk),
      .rst        (rst),
      .wr_data    (data),
      .wr_valid   (data_valid),
      .wr_ready   (ring_wr_ready),
      .rd_data    (ring_rd_data),
      .rd_valid   (ring_rd_valid),
      .rd_ready   (ring_rd_ready),
      .peek_addr  (ring_peek_addr),
      .peek_data  (ring_peek_data),
      .fill_count (ring_fill)
  );
  assign ring_peek_addr = '0;  // unused at top level for now

  // -----------------------------------------------------------------------
  // BoolDecoder - part0 (header partition)
  // -----------------------------------------------------------------------
  BoolDecoderIf bd0 ();   // user modport drives FrameHeaderParser / MBHeaderParser
  BoolDecoderIf bd1 ();   // part1 (residual tokens) - second bool decoder

  // Part0 BoolDecoder: memdata comes from the ring buffer starting at byte 10
  logic bd0_mem_valid, bd0_mem_data_valid, bd0_mem_data_ready;
  byte unsigned bd0_mem_data;

  // Simplified: feed ring directly to bd0 (for test purposes)
  // In full implementation, ring_rd_ready is gated by the parser state
  assign bd0_mem_valid      = ring_rd_valid;
  assign ring_rd_ready      = bd0_mem_data_ready;
  assign bd0_mem_data       = ring_rd_data;
  assign bd0_mem_data_valid = ring_rd_valid;

  BoolDecoder u_bd0 (
      .clk           (clk),
      .rst           (rst),
      .mem_ready     (bd0_mem_valid),
      .mem_valid     (/* unused */),
      .mem_data_valid(bd0_mem_data_valid),
      .mem_data_ready(bd0_mem_data_ready),
      .mem_data      (bd0_mem_data),
      .self          (bd0)
  );

  // -----------------------------------------------------------------------
  // Frame Header Parser
  // -----------------------------------------------------------------------
  Frame::FrameCtx frame_ctx;
  logic           frame_ctx_done;

  // Raw bytes come from the ring before bd0 is initialised
  // (first 10 bytes bypass the bool decoder)
  // In this simplified wiring they share the same ring_rd port.
  // A production design would gate the ring drain mux.

  FrameHeaderParser u_fhp (
      .clk      (clk),
      .rst      (rst),
      .raw_data (ring_rd_data),
      .raw_valid(ring_rd_valid),
      .raw_ready(/* gated by fhp internally */),
      .bd       (bd0),
      .ctx      (frame_ctx),
      .done     (frame_ctx_done)
  );

  assign frame_width  = frame_ctx.width;
  assign frame_height = frame_ctx.height;

  // -----------------------------------------------------------------------
  // Macroblock Header Parser
  // -----------------------------------------------------------------------
  MacroblockHeaderPkg::MacroblockHeader mb_header;
  logic                                 mb_header_valid;

  // Simple MB ring (depth 1 for now - slot ring not yet implemented)
  MacroblockHeaderPkg::MacroblockHeader mb_ring[0:MB_SLOTS-1];
  logic [$clog2(MB_SLOTS)-1:0]          mb_ring_wr_ptr;
  logic [$clog2(MB_SLOTS)-1:0]          mb_ring_rd_ptr;

  MacroblockHeaderPkg::MacroblockHeader left_hdr;
  MacroblockHeaderPkg::MacroblockHeader above_hdr[0:MAX_WIDTH/16-1];
  logic                                 left_valid;
  logic                                 above_valid;
  byte unsigned                         mb_col, mb_row;

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
      .ready       (1'b1)  // always accept in simplified version
  );

  // Track MB position and store above/left context
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      mb_col     <= '0;
      mb_row     <= '0;
      left_valid <= 1'b0;
      above_valid <= 1'b0;
      left_hdr   <= '{default: 0};
      for (int i = 0; i < MAX_WIDTH/16; i++) above_hdr[i] <= '{default: 0};
    end else begin
      if (mb_header_valid) begin
        // Store contexts
        above_hdr[mb_col] <= mb_header;
        left_hdr          <= mb_header;
        // Advance position
        if (mb_col == shortint'(frame_ctx.mb_width) - 1) begin
          mb_col     <= 8'd0;
          mb_row     <= mb_row + 1'b1;
          left_valid <= 1'b0;
          above_valid <= (mb_row == 0) ? 1'b0 : 1'b1;
        end else begin
          mb_col     <= mb_col + 1'b1;
          left_valid <= 1'b1;
          above_valid <= (mb_row > 0);
        end
      end
    end
  end

  // -----------------------------------------------------------------------
  // Residue Decoder + Token Decoder + Transforms
  // (wired with shared IDCT)
  // -----------------------------------------------------------------------
  // Interfaces
  BoolDecoderIf bd1_iface ();
  Idct4x4If     idct_bus  ();
  Idct4x4If     wht_bus   ();

  TokenDecoder u_tokdec (
      .clk       (clk),
      .rst       (rst),
      .bd        (bd1_iface),
      .plane     (2'd0),
      .complexity(2'd0),
      .first_coeff(1'b0),
      .dcq       (frame_ctx.ydc),
      .acq       (frame_ctx.yac),
      .frame_ctx (frame_ctx),
      .start     (1'b0),   // driven by ResidueDecoder
      .busy      (),
      .coeffs    (),
      .has_coeff (),
      .coeff_valid()
  );

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

  // Residue decoder (uses first MB header from ring)
  ResiduePkg::MbResiduals residuals;
  logic                   res_valid;

  ResidueDecoder u_resdec (
      .clk          (clk),
      .rst          (rst),
      .mb_header    (mb_header),
      .mb_valid     (mb_header_valid),
      .mb_ready     (),
      .frame_ctx    (frame_ctx),
      .hc_left      (9'd0),
      .hc_top       (9'd0),
      .hc_left_out  (),
      .hc_top_out   (),
      .td_plane     (),
      .td_complexity(),
      .td_first_coeff(),
      .td_dcq       (),
      .td_acq       (),
      .td_start     (),
      .td_busy      (1'b0),
      .td_coeffs    ('{default: 16'sd0}),
      .td_has_coeff (1'b0),
      .td_coeff_valid(1'b0),
      .idct_coeff_valid(),
      .idct_coeff_ready(1'b1),
      .idct_coeff   (),
      .wht_coeff_valid(1'b0),
      .use_wht      (),
      .idct_block_valid(1'b0),
      .idct_block_ready(),
      .idct_block   ('{default: '{default: 16'sd0}}),
      .residuals    (residuals),
      .res_valid    (res_valid),
      .res_ready    (1'b1)
  );

  // -----------------------------------------------------------------------
  // Frame Buffer
  // -----------------------------------------------------------------------
  PredictorPkg::MbPixels mb_pixels;

  byte unsigned fb_top_y [0:15], fb_top_cb[0:7], fb_top_cr[0:7];
  byte unsigned fb_left_y[0:15], fb_left_cb[0:7], fb_left_cr[0:7];
  byte unsigned fb_tl_y, fb_tl_cb, fb_tl_cr;
  byte unsigned fb_tr_y[0:3];
  logic         fb_top_v, fb_left_v, fb_tl_v, fb_tr_v;

  FrameBuffer #(
      .MAX_WIDTH (MAX_WIDTH),
      .MAX_HEIGHT(MAX_HEIGHT)
  ) u_fb (
      .clk           (clk),
      .rst           (rst),
      .width         (frame_ctx.width),
      .height        (frame_ctx.height),
      .wr_valid      (res_valid),
      .wr_ready      (),
      .wr_mb_col     (mb_col),
      .wr_mb_row     (mb_row),
      .wr_y          (mb_pixels.y),
      .wr_cb         (mb_pixels.cb),
      .wr_cr         (mb_pixels.cr),
      .rd_mb_col     (mb_col),
      .rd_mb_row     (mb_row),
      .rd_top_y      (fb_top_y),
      .rd_top_cb     (fb_top_cb),
      .rd_top_cr     (fb_top_cr),
      .rd_left_y     (fb_left_y),
      .rd_left_cb    (fb_left_cb),
      .rd_left_cr    (fb_left_cr),
      .rd_topleft_y  (fb_tl_y),
      .rd_topleft_cb (fb_tl_cb),
      .rd_topleft_cr (fb_tl_cr),
      .rd_topright_y (fb_tr_y),
      .rd_top_valid  (fb_top_v),
      .rd_left_valid (fb_left_v),
      .rd_topleft_valid(fb_tl_v),
      .rd_topright_valid(fb_tr_v)
  );

  // -----------------------------------------------------------------------
  // Predictor (fully combinational)
  // -----------------------------------------------------------------------
  Predictor u_pred (
      .header         (mb_header),
      .residuals      (residuals),
      .top_valid      (fb_top_v),
      .top_y          (fb_top_y),
      .top_cb         (fb_top_cb),
      .top_cr         (fb_top_cr),
      .left_valid     (fb_left_v),
      .left_y         (fb_left_y),
      .left_cb        (fb_left_cb),
      .left_cr        (fb_left_cr),
      .topleft_valid  (fb_tl_v),
      .topleft_y      (fb_tl_y),
      .topleft_cb     (fb_tl_cb),
      .topleft_cr     (fb_tl_cr),
      .topright_valid (fb_tr_v),
      .topright_y     (fb_tr_y),
      .pixels         (mb_pixels)
  );

  // -----------------------------------------------------------------------
  // frame_done
  // -----------------------------------------------------------------------
  always_comb begin
    frame_done = res_valid &&
                 (mb_row == byte'(frame_ctx.mb_height - 1)) &&
                 (mb_col == byte'(frame_ctx.mb_width  - 1));
  end

endmodule

// ---------------------------------------------------------------------------
// Test wrapper (flat ports for cocotb)
// ---------------------------------------------------------------------------
module VpAteTest (
    input var  logic         clk,
    input var  logic         rst,
    input var  byte unsigned data,
    input var  logic         data_valid,
    output var logic         data_ready,
    output var logic         frame_done,
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
