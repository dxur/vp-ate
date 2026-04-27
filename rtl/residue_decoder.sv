package ResiduePkg;
  typedef struct {
    logic signed [15:0] luma[16][16];
    logic signed [15:0] chroma[2][8][8];
  } MbResiduals;
endpackage

import Macroblock::*;
import Frame::*;

module ResidueDecoder (
    input var logic clk,
    input var logic rst,

    input var  Macroblock::Header mb_header,
    input var  logic              mb_valid,
    output var logic              mb_ready,

    input var Frame::FrameCtx frame_ctx,

    // has_coeff context (9 bits, {y2_hc[8], y_hc[7:4], u_hc[3:2], v_hc[1:0]})
    input var  logic [8:0] hc_left,
    input var  logic [8:0] hc_top,
    output var logic [8:0] hc_left_out,
    output var logic [8:0] hc_top_out,

    // TokenDecoder interface
    output logic        [ 1:0] td_plane,
    output logic        [ 1:0] td_complexity,
    output logic               td_first_coeff,
    output logic signed [15:0] td_dcq,
    output logic signed [15:0] td_acq,
    output logic               td_start,
    input  logic               td_busy,
    input  logic signed [15:0] td_coeffs     [0:15],
    input  logic               td_has_coeff,
    input  logic               td_coeff_valid,

    // IDCT/IWHT interface
    output logic               idct_coeff_valid,
    input  logic               idct_coeff_ready,
    output logic signed [15:0] idct_coeff      [0:3][0:3],
    output logic               use_wht,

    input  logic               idct_block_valid,
    output logic               idct_block_ready,
    input  logic signed [15:0] idct_block      [0:3][0:3],

    // Output
    output ResiduePkg::MbResiduals residuals,
    output logic                   res_valid,
    input  logic                   res_ready
);

  typedef enum logic [6:0] {
    S_IDLE        = 'd1,
    S_START_BLOCK = 'd2,
    S_WAIT_TOKEN  = 'd4,
    S_START_IDCT  = 'd8,
    S_WAIT_IDCT   = 'd16,
    S_ADVANCE     = 'd32,
    S_OUT         = 'd64
  } State;

  State               state;
  logic        [ 4:0] seq;  // 0=Y2, 1-16=Y, 17-20=U, 21-24=V
  logic               has_y2;
  logic               skip_coeff;  // mb_skip_coeff: all coeffs zero, no TD calls

  // Working copies of context
  logic        [ 8:0] hc_l;
  logic        [ 8:0] hc_t;

  // Token result latch
  logic signed [15:0] tok_buf                                                    [0:15];
  logic               tok_hc;  // has_coeff for this block

  // Y2 IWHT result (DCs for 16 luma blocks), held until all Y done
  logic signed [15:0] y2_dc                                                      [ 0:3] [0:3];

  // seq_plane: map seq to plane index (0=Y_ac,1=Y2,2=UV,3=Y_dc+ac)
  function automatic logic [1:0] seq_plane(input logic [4:0] s, input logic y2p);
    if (s == 0) return 2'd1;  // Y2
    else if (s <= 16) return y2p ? 2'd0 : 2'd3;  // Y AC-only or full
    else return 2'd2;  // U or V
  endfunction

  // seq_quant: map seq to (dcq, acq)
  function automatic void seq_quant(input logic [4:0] s, output logic signed [15:0] dcq,
                                    output logic signed [15:0] acq);
    if (s == 0) begin
      dcq = frame_ctx.y2dc;
      acq = frame_ctx.y2ac;
    end else if (s <= 16) begin
      dcq = frame_ctx.ydc;
      acq = frame_ctx.yac;
    end else begin
      dcq = frame_ctx.uvdc;
      acq = frame_ctx.uvac;
    end
  endfunction

  // first_coeff: 1 only for Y blocks when Y2 is present
  function automatic logic seq_first_coeff(input logic [4:0] s, input logic y2p);
    return (s >= 1 && s <= 16 && y2p) ? 1'b1 : 1'b0;
  endfunction

  // Complexity
  logic y_left[0:3];
  logic u_left[0:1];
  logic v_left[0:1];

  function automatic logic [1:0] complexity_for(
      input logic [4:0] s, input logic y2p, input logic [8:0] hl, input logic [8:0] ht,
      input logic yl[0:3], input logic ul[0:1], input logic vl[0:1]);

    logic top_hc, left_hc;
    logic [3:0] bi;
    logic [1:0] brow, bcol, t;
    logic urow, ucol, vrow, vcol;

    if (s == 0 && y2p) begin
      top_hc  = ht[8];
      left_hc = hl[8];

    end else if (s >= 1 && s <= 16) begin
      bi = 4'(s - 1);
      brow = bi[3:2];
      bcol = bi[1:0];
      top_hc = ht[4+bcol];
      left_hc = (bcol == 0) ? hl[4+brow] : yl[brow];

    end else if (s >= 17 && s <= 20) begin
      t    = 2'(s - 17);
      urow = t[1];
      ucol = t[0];
      top_hc  = ht[2+ucol];
      left_hc = (ucol == 0) ? hl[2+urow] : ul[urow];

    end else begin
      t    = 2'(s - 21);
      vrow = t[1];
      vcol = t[0];
      top_hc  = ht[4'(vcol)];
      left_hc = (vcol == 0) ? hl[4'(vrow)] : vl[vrow];
    end

    return {1'b0, top_hc} + {1'b0, left_hc};
  endfunction

  always_comb begin
    logic signed [15:0] _dcq, _acq;
    _dcq             = 16'sd0;
    _acq             = 16'sd0;

    mb_ready         = (state == S_IDLE);
    td_start         = 1'b0;
    td_plane         = 2'd0;
    td_complexity    = 2'd0;
    td_first_coeff   = 1'b0;
    td_dcq           = frame_ctx.ydc;
    td_acq           = frame_ctx.yac;
    idct_coeff_valid = 1'b0;
    idct_block_ready = 1'b0;
    use_wht          = (seq == 5'd0);
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) idct_coeff[r][c] = 16'sd0;
    hc_left_out = hc_l;
    hc_top_out  = hc_t;
    res_valid   = (state == S_OUT);

    case (state)
      S_START_BLOCK: begin
        seq_quant(seq, _dcq, _acq);
        td_plane       = seq_plane(seq, has_y2);
        td_dcq         = _dcq;
        td_acq         = _acq;
        td_first_coeff = seq_first_coeff(seq, has_y2);
        td_complexity  = complexity_for(seq, has_y2, hc_l, hc_t, y_left, u_left, v_left);
        td_start       = !skip_coeff && !td_busy;
      end

      S_START_IDCT: begin
        idct_coeff_valid = 1'b1;
        for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) idct_coeff[r][c] = tok_buf[r*4+c];
      end

      S_WAIT_IDCT: begin
        idct_block_ready = 1'b1;
      end

      default: ;
    endcase
  end

  // FSM
  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      state      <= S_IDLE;
      seq        <= 5'd0;
      has_y2     <= 1'b0;
      skip_coeff <= 1'b0;
      hc_l       <= 9'd0;
      hc_t       <= 9'd0;
      tok_hc     <= 1'b0;
      for (int i = 0; i < 16; i++) tok_buf[i] <= 16'sd0;
      for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) y2_dc[r][c] <= 16'sd0;
      for (int i = 0; i < 4; i++) y_left[i] <= 1'b0;
      for (int i = 0; i < 2; i++) u_left[i] <= 1'b0;
      for (int i = 0; i < 2; i++) v_left[i] <= 1'b0;
    end else begin
      case (state)

        S_IDLE: begin
          if (mb_valid) begin
            has_y2     <= (mb_header.intra_y_mode != IntraMBMode_BPred);
            skip_coeff <= mb_header.mb_skip_coeff;
            seq        <= (mb_header.intra_y_mode != IntraMBMode_BPred) ? 5'd0 : 5'd1;
            hc_l       <= hc_left;
            hc_t       <= hc_top;
            for (int i = 0; i < 4; i++) y_left[i] <= 1'b0;
            for (int i = 0; i < 2; i++) u_left[i] <= 1'b0;
            for (int i = 0; i < 2; i++) v_left[i] <= 1'b0;
            state <= S_START_BLOCK;
          end
        end

        S_START_BLOCK: begin
          if (skip_coeff) begin
            // mb_skip_coeff=1: all blocks have zero coefficients, no bitstream bits consumed.
            for (int i = 0; i < 16; i++) tok_buf[i] <= 16'sd0;
            tok_hc <= 1'b0;
            state  <= S_START_IDCT;  // still run IDCT
          end else if (!td_busy) begin
            state <= S_WAIT_TOKEN;
          end
        end

        S_WAIT_TOKEN: begin
          if (td_coeff_valid) begin
            for (int i = 0; i < 16; i++) tok_buf[i] <= td_coeffs[i];
            if (seq >= 1 && seq <= 16 && has_y2) begin
              logic [3:0] bi;
              logic [1:0] brow, bcol;
              bi   = 4'(seq - 1);
              brow = bi[3:2];
              bcol = bi[1:0];
              tok_buf[0] <= y2_dc[brow][bcol];
            end
            tok_hc <= td_has_coeff;
            state  <= S_START_IDCT;
          end
        end

        S_START_IDCT: begin
          if (idct_coeff_ready) state <= S_WAIT_IDCT;
        end

        S_WAIT_IDCT: begin
          if (idct_block_valid) begin

            logic [3:0] bi;
            logic [1:0] brow, bcol;
            logic [1:0] t;
            logic urow, ucol, vrow, vcol;
            logic [1:0] dbg_row, dbg_col;

            if (seq == 5'd0) begin
              for (int r = 0; r < 4; r++)
              for (int c = 0; c < 4; c++) y2_dc[r][c] <= idct_block[r][c];

              hc_t[8] <= tok_hc;
              hc_l[8] <= tok_hc;
              dbg_row = 0;
              dbg_col = 0;

            end else if (seq <= 5'd16) begin
              bi   = 4'(seq - 1);
              brow = bi[3:2];
              bcol = bi[1:0];

              for (int r = 0; r < 4; r++)
              for (int c = 0; c < 4; c++) residuals.luma[brow*4+r][bcol*4+c] <= idct_block[r][c];

              hc_t[4+bcol] <= tok_hc;
              y_left[brow] <= tok_hc;
              if (bcol == 3) hc_l[4+brow] <= tok_hc;

              dbg_row = brow;
              dbg_col = bcol;

            end else if (seq <= 5'd20) begin
              t    = 2'(seq - 17);
              urow = t[1];
              ucol = t[0];

              for (int r = 0; r < 4; r++)
              for (int c = 0; c < 4; c++)
              residuals.chroma[0][urow*4+r][ucol*4+c] <= idct_block[r][c];

              hc_t[2+ucol] <= tok_hc;
              u_left[urow] <= tok_hc;
              if (ucol == 1) hc_l[2+urow] <= tok_hc;

              dbg_row = {1'b0, urow};
              dbg_col = {1'b0, ucol};

            end else begin
              t    = 2'(seq - 21);
              vrow = t[1];
              vcol = t[0];

              for (int r = 0; r < 4; r++)
              for (int c = 0; c < 4; c++)
              residuals.chroma[1][vrow*4+r][vcol*4+c] <= idct_block[r][c];

              hc_t[{3'd0, vcol}] <= tok_hc;
              v_left[vrow] <= tok_hc;
              if (vcol == 1) hc_l[{3'd0, vrow}] <= tok_hc;

              dbg_row = {1'b0, vrow};
              dbg_col = {1'b0, vcol};
            end

            //   $display("DBG: SEQ=%0d MB(row=%0d,col=%0d) tok_hc=%b", seq, dbg_row, dbg_col, tok_hc);
            //   $display("DBG: HC_TOP=%0h HC_LEFT=%0h", hc_t, hc_l);
            //   $display("DBG: y_left=%b u_left=%b v_left=%b", y_left, u_left, v_left);

            state <= S_ADVANCE;
          end
        end

        S_ADVANCE: begin
          if (seq == 5'd24) begin
            state <= S_OUT;
          end else begin
            seq   <= seq + 1'b1;
            state <= S_START_BLOCK;
          end
        end

        S_OUT: begin
          if (res_ready) state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

module ResidueDecoderTest (
    input var logic clk,
    input var logic rst,

    input var logic [2:0] mb_intra_y_mode,  // IntraMBMode enum
    input var logic       mb_skip_coeff,

    input var  logic mb_valid,
    output var logic mb_ready,

    input var shortint signed ydc,
    input var shortint signed yac,
    input var shortint signed y2dc,
    input var shortint signed y2ac,
    input var shortint signed uvdc,
    input var shortint signed uvac,
    input var logic [8447:0] coeff_probs_flat,

    input var  logic [8:0] hc_left,
    input var  logic [8:0] hc_top,
    output var logic [8:0] hc_left_out,
    output var logic [8:0] hc_top_out,

    output var logic [  1:0] td_plane,
    output var logic [  1:0] td_complexity,
    output var logic         td_first_coeff,
    output var logic [ 15:0] td_dcq,
    output var logic [ 15:0] td_acq,
    output var logic         td_start,
    input var  logic         td_busy,
    input var  logic [255:0] td_coeffs_flat,
    input var  logic         td_has_coeff,
    input var  logic         td_coeff_valid,

    output var logic         idct_coeff_valid,
    input var  logic         idct_coeff_ready,
    output var logic [255:0] idct_coeff_flat,
    output var logic         use_wht,

    input var  logic         idct_block_valid,
    output var logic         idct_block_ready,
    input var  logic [255:0] idct_block_flat,

    output var logic [4095:0] luma_flat,
    output var logic [2047:0] chroma_flat,

    output var logic res_valid,
    input var  logic res_ready
);

  Macroblock::Header mb_header_s;
  always_comb begin
    mb_header_s               = '0;
    mb_header_s.intra_y_mode  = Macroblock::IntraMBMode'(mb_intra_y_mode);
    mb_header_s.mb_skip_coeff = mb_skip_coeff;
  end

  Frame::FrameCtx frame_ctx_s;
  always_comb begin
    frame_ctx_s.valid = 1'b1;
    frame_ctx_s.ydc   = ydc;
    frame_ctx_s.yac   = yac;
    frame_ctx_s.y2dc  = y2dc;
    frame_ctx_s.y2ac  = y2ac;
    frame_ctx_s.uvdc  = uvdc;
    frame_ctx_s.uvac  = uvac;
    for (int pl = 0; pl < 4; pl++)
    for (int band = 0; band < 8; band++)
    for (int ctx = 0; ctx < 3; ctx++)
    for (int tok = 0; tok < 11; tok++) begin
      automatic int idx;
      idx = ((pl * 8 + band) * 3 + ctx) * 11 + tok;
      frame_ctx_s.coeff_probs[pl][band][ctx][tok] = coeff_probs_flat[8447-idx*8-:8];
    end
  end

  shortint signed td_coeffs_s[0:15];
  always_comb begin
    for (int i = 0; i < 16; i++) td_coeffs_s[i] = shortint'(td_coeffs_flat[i*16+:16]);
  end

  shortint signed idct_block_s[0:3][0:3];
  always_comb begin
    for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) idct_block_s[r][c] = shortint'(idct_block_flat[(r*4+c)*16+:16]);
  end

  shortint signed idct_coeff_s[0:3][0:3];
  always_comb begin
    idct_coeff_flat = '0;
    for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) idct_coeff_flat[(r*4+c)*16+:16] = 16'(idct_coeff_s[r][c]);
  end

  shortint signed td_dcq_s, td_acq_s;
  always_comb begin
    td_dcq = 16'(td_dcq_s);
    td_acq = 16'(td_acq_s);
  end

  ResiduePkg::MbResiduals residuals_s;
  always_comb begin
    luma_flat   = '0;
    chroma_flat = '0;
    for (int r = 0; r < 16; r++)
    for (int c = 0; c < 16; c++) luma_flat[(r*16+c)*16+:16] = 16'(residuals_s.luma[r][c]);
    for (int p = 0; p < 2; p++)
    for (int r = 0; r < 8; r++)
    for (int c = 0; c < 8; c++) chroma_flat[(p*64+r*8+c)*16+:16] = 16'(residuals_s.chroma[p][r][c]);
  end

  ResidueDecoder uut (
      .clk             (clk),
      .rst             (rst),
      .mb_header       (mb_header_s),
      .mb_valid        (mb_valid),
      .mb_ready        (mb_ready),
      .frame_ctx       (frame_ctx_s),
      .hc_left         (hc_left),
      .hc_top          (hc_top),
      .hc_left_out     (hc_left_out),
      .hc_top_out      (hc_top_out),
      .td_plane        (td_plane),
      .td_complexity   (td_complexity),
      .td_first_coeff  (td_first_coeff),
      .td_dcq          (td_dcq_s),
      .td_acq          (td_acq_s),
      .td_start        (td_start),
      .td_busy         (td_busy),
      .td_coeffs       (td_coeffs_s),
      .td_has_coeff    (td_has_coeff),
      .td_coeff_valid  (td_coeff_valid),
      .idct_coeff_valid(idct_coeff_valid),
      .idct_coeff_ready(idct_coeff_ready),
      .idct_coeff      (idct_coeff_s),
      .use_wht         (use_wht),
      .idct_block_valid(idct_block_valid),
      .idct_block_ready(idct_block_ready),
      .idct_block      (idct_block_s),
      .residuals       (residuals_s),
      .res_valid       (res_valid),
      .res_ready       (res_ready)
  );

endmodule
