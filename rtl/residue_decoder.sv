// ResidueDecoder - sequences TokenDecoder calls for all sub-blocks of one MB.
//
// Consumes one MacroblockHeader at a time and drives a shared TokenDecoder
// (connected to the part1 BoolDecoder) 25 times in the order:
//   Y2 (if !BPred),  Y[0..15],  U[0..3],  V[0..3]
//
// After all blocks are decoded and IDCT/IWHT applied, it outputs a packed
// MbResiduals struct containing the transformed 4×4 coefficient arrays.
//
// has_coeff_vec context:
//   - Index 0        : left context  (reset at MB start from left MB's final)
//   - Index [1..mbw] : top context   (updated per column)
//   Each entry is:  y2_hc | y_hc[4] | u_hc[2] | v_hc[2]
//
// The module does NOT hold the has_coeff_vec itself for all columns -
// that is the parent's responsibility. Instead the parent passes
// cur_left/cur_top and receives updated values.

package ResiduePkg;
  typedef struct {
    shortint signed luma  [0:15][0:15];  // 16 4×4 blocks -> 16×16 pixels
    shortint signed chroma[0:1][0:7][0:7]; // 2 planes × 8×8
  } MbResiduals;
endpackage

import MacroblockHeaderPkg::*;
import Frame::*;

module ResidueDecoder (
    input var logic clk,
    input var logic rst,

    // Input: decoded macroblock header
    input var MacroblockHeaderPkg::MacroblockHeader mb_header,
    input var logic                                 mb_valid,
    output var logic                                mb_ready,

    // Frame context (quantizer, coeff probs)
    input var Frame::FrameCtx frame_ctx,

    // has_coeff context from parent (one entry per MB column + left slot)
    // Packing: {y2_hc, y_hc[3:0], u_hc[1:0], v_hc[1:0]}  = 9 bits
    input var  logic [8:0] hc_left,         // left context on entry
    input var  logic [8:0] hc_top,          // top context for current column
    output var logic [8:0] hc_left_out,     // updated left context
    output var logic [8:0] hc_top_out,      // updated top context

    // TokenDecoder interface (shared)
    output var logic [1:0]     td_plane,
    output var logic [1:0]     td_complexity,
    output var logic           td_first_coeff,
    output var shortint signed td_dcq,
    output var shortint signed td_acq,
    output var logic           td_start,
    input var  logic           td_busy,
    input var  shortint signed td_coeffs[0:15],
    input var  logic           td_has_coeff,
    input var  logic           td_coeff_valid,

    // IDCT interface (shared - parent must mux if >1 MB in flight)
    output var logic              idct_coeff_valid,
    input var  logic              idct_coeff_ready,
    output var shortint signed    idct_coeff[0:3][0:3],
    input var  logic              wht_coeff_valid,  // tied to idct when wht selected externally
    output var logic              use_wht,           // 1=IWHT 0=IDCT

    input var  logic              idct_block_valid,
    output var logic              idct_block_ready,
    input var  shortint signed    idct_block[0:3][0:3],

    // Output
    output var ResiduePkg::MbResiduals residuals,
    output var logic                    res_valid,
    input var  logic                    res_ready
);

  // -------------------------------------------------------------------------
  // Block sequencing order
  //   seq 0     : Y2      (only when !BPred)
  //   seq 1-16  : Y[0..15]
  //   seq 17-20 : U[0..3]
  //   seq 21-24 : V[0..3]
  // -------------------------------------------------------------------------
  typedef enum logic [4:0] {
    S_IDLE          = 5'd0,
    S_START_BLOCK   = 5'd1,   // configure and start TokenDecoder
    S_WAIT_TOKEN    = 5'd2,   // wait for TokenDecoder to finish
    S_WAIT_IDCT     = 5'd4,   // push coeffs to IDCT, wait for result
    S_STORE_BLOCK   = 5'd8,   // store IDCT result into residuals
    S_STORE_Y2      = 5'd16,  // IWHT result: distribute DCs into luma blocks
    S_OUT           = 5'd17
  } State;

  State        state;
  logic [4:0]  seq;           // 0-24 (or 1-24 when !BPred)
  logic        has_y2;        // !BPred -> Y2 present

  // Y2 raw tokens (pre-IWHT)
  shortint signed y2_tokens[0:15];

  // Scratch: tokens ready to push to IDCT
  shortint signed cur_tokens[0:15];
  logic [1:0]    cur_plane;
  logic [1:0]    cur_complexity;
  logic          cur_first_coeff;
  shortint signed cur_dcq, cur_acq;

  // has_coeff left/top working copies (match packed layout)
  // [8:8]=y2, [7:4]=y_hc[3:0], [3:2]=u_hc[1:0], [1:0]=v_hc[1:0]
  logic [8:0]  hc_l;   // left context
  logic [8:0]  hc_t;   // top context for current column

  // IDCT push state
  logic [1:0]  idct_row;
  logic        idct_push_done;

  // -------------------------------------------------------------------------
  // Helpers: decode sequence index -> plane parameters
  // -------------------------------------------------------------------------
  function automatic void seq_params(
      input  logic [4:0]  s,
      input  logic        y2_present,
      output logic [1:0]  plane,
      output shortint signed dcq,
      output shortint signed acq,
      output logic        first_coeff,
      output logic [1:0]  blk_xy_y,  // sub-block row (Y only)
      output logic [1:0]  blk_xy_x   // sub-block col (Y only)
  );
    logic [4:0] tmp;

    blk_xy_y   = '0;
    blk_xy_x   = '0;
    first_coeff = 1'b0;
    if (s == 0 && y2_present) begin
      plane = 2'd1;  // Y2
      dcq   = frame_ctx.y2dc;
      acq   = frame_ctx.y2ac;
    end else if (s >= 1 && s <= 16) begin
      plane = y2_present ? 2'd0 : 2'd3;  // Y AC-only or Y with DC
      dcq   = frame_ctx.ydc;
      acq   = frame_ctx.yac;
      first_coeff = y2_present ? 1'b1 : 1'b0;
      tmp = s - 1;
      blk_xy_y = tmp[3:2];
      blk_xy_x = tmp[1:0];
    end else if (s >= 17 && s <= 20) begin
      plane = 2'd2;  // U
      dcq   = frame_ctx.uvdc;
      acq   = frame_ctx.uvac;
    end else begin
      plane = 2'd2;  // V
      dcq   = frame_ctx.uvdc;
      acq   = frame_ctx.uvac;
    end
  endfunction

  // -------------------------------------------------------------------------
  // Complexity lookup: extract relevant has_coeff bits from hc_t / hc_l
  // -------------------------------------------------------------------------
  function automatic logic [1:0] get_complexity(
      input logic [4:0] s,
      input logic       y2p,
      input logic [8:0] hl,
      input logic [8:0] ht
  );
    logic [4:0] tmp;
    logic [4:0] t;
    logic [1:0] bx, by;
    logic bx1;
    logic top_hc, left_hc;

    if (s == 0 && y2p) begin
      top_hc  = ht[8];
      left_hc = hl[8];

    end else if (s >= 1 && s <= 16) begin
      tmp = s - 1;
      by  = tmp[3:2];
      bx  = tmp[1:0];

      top_hc  = ht[4 + bx];
      left_hc = (bx == 0) ? hl[4 + by] : 1'b0;

    end else if (s >= 17 && s <= 20) begin
      t = s - 17;
      bx1 = t[0];

      top_hc  = ht[3 - (t >> 1)];
      left_hc = hl[3 - (t >> 1)];

    end else begin
      t = s - 21;

      top_hc  = ht[1 - (t >> 1)];
      left_hc = hl[1 - (t >> 1)];
    end

    get_complexity = {1'b0, top_hc} + {1'b0, left_hc};
  endfunction

  // -------------------------------------------------------------------------
  // Combinational outputs
  // -------------------------------------------------------------------------
  always_comb begin
    mb_ready         = (state == S_IDLE);
    td_start         = 1'b0;
    td_plane         = 2'd0;
    td_complexity    = 2'd0;
    td_first_coeff   = 1'b0;
    td_dcq           = frame_ctx.ydc;
    td_acq           = frame_ctx.yac;
    idct_coeff_valid = 1'b0;
    idct_block_ready = 1'b0;
    use_wht          = 1'b0;
    idct_coeff       = '{default: '{default: 0}};
    hc_left_out      = hc_l;
    hc_top_out       = hc_t;
    res_valid        = (state == S_OUT);

    case (state)
      S_START_BLOCK: begin
        logic [1:0] _p, _bxy, _bxx;
        shortint signed _dcq, _acq;
        logic _fc;
        seq_params(seq, has_y2, _p, _dcq, _acq, _fc, _bxy, _bxx);
        td_plane       = _p;
        td_dcq         = _dcq;
        td_acq         = _acq;
        td_first_coeff = _fc;
        td_complexity  = get_complexity(seq, has_y2, hc_l, hc_t);
        td_start       = 1'b1;
      end

      S_WAIT_IDCT: begin
        // Push 4×4 coefficient matrix to IDCT row-by-row
        idct_coeff_valid = !idct_push_done;
        use_wht          = (seq == 0 && has_y2);
        for (int c = 0; c < 4; c++)
          idct_coeff[idct_row][c] = cur_tokens[int'(idct_row)*4 + c];
      end

      S_STORE_BLOCK, S_STORE_Y2: begin
        idct_block_ready = 1'b1;
      end

      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // Sequential
  // -------------------------------------------------------------------------
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      state      <= S_IDLE;
      seq        <= 5'd0;
      has_y2     <= 1'b0;
      hc_l       <= 9'd0;
      hc_t       <= 9'd0;
      idct_row   <= 2'd0;
      idct_push_done <= 1'b0;
      residuals  <= '{default: 0};
      y2_tokens  <= '{default: 0};
    end else begin
      case (state)
        S_IDLE: begin
          if (mb_valid) begin
            has_y2 <= (mb_header.intra_y_mode != IntraMBMode_BPred);
            seq    <= (mb_header.intra_y_mode != IntraMBMode_BPred) ? 5'd0 : 5'd1;
            hc_l   <= hc_left;
            hc_t   <= hc_top;
            residuals <= '{default: 0};
            state  <= S_START_BLOCK;
          end
        end

        S_START_BLOCK: begin
          if (td_start && !td_busy) begin
            state <= S_WAIT_TOKEN;
          end
        end

        S_WAIT_TOKEN: begin
          if (td_coeff_valid) begin
            // Latch token results
            for (int i = 0; i < 16; i++) cur_tokens[i] <= td_coeffs[i];
            // Update has_coeff context
            // (simplified: update y2 bit if seq==0, y bits for seqs 1-16, etc.)
            // Full context tracking omitted here for brevity - add per-bit later
            idct_row       <= 2'd0;
            idct_push_done <= 1'b0;
            state          <= S_WAIT_IDCT;
          end
        end

        S_WAIT_IDCT: begin
          if (idct_coeff_ready && !idct_push_done) begin
            idct_row <= idct_row + 1'b1;
            if (idct_row == 3) idct_push_done <= 1'b1;
          end
          if (idct_push_done && idct_block_valid) begin
            if (seq == 0 && has_y2) begin
              // Store Y2 tokens for IWHT distribution
              for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                  y2_tokens[r*4+c] <= idct_block[r][c];
              state <= S_STORE_Y2;
            end else begin
              state <= S_STORE_BLOCK;
            end
          end
        end

        S_STORE_Y2: begin
          // Y2 IWHT result: idct_block contains transformed DCs
          // Distribute back to luma block DC positions
          for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++) begin
              // luma block index r*4+c, position [0][0] (the DC) in its 4×4
              // In our residuals layout: luma[block_row*4 .. +3][block_col*4 .. +3]
              residuals.luma[r*4][c*4] <= idct_block[r][c];
            end
          // Advance to Y blocks
          seq   <= 5'd1;
          state <= S_START_BLOCK;
        end

        S_STORE_BLOCK: begin
          // Store IDCT result
          if (seq >= 1 && seq <= 16) begin
            logic [3:0] bi;
            logic [1:0] brow, bcol;
            logic [4:0] t;
            t = s - 1;
            bi   = t[3:0];
            brow = bi[3:2];
            bcol = bi[1:0];
            for (int r = 0; r < 4; r++)
              for (int c = 0; c < 4; c++)
                residuals.luma[brow*4+r][bcol*4+c] <= idct_block[r][c];
          end else if (seq >= 17 && seq <= 20) begin
            // U blocks: 2×2 grid, seq 17-20 -> [0][0],[0][1],[1][0],[1][1]
            logic [1:0] bi;
            logic [4:0] t;
            t = s - 17;
            bi = t[1:0];
            for (int r = 0; r < 4; r++)
              for (int c = 0; c < 4; c++)
                residuals.chroma[0][bi[1]*4+r][bi[0]*4+c] <= idct_block[r][c];
          end else begin
            // V blocks: seq 21-24
            logic [1:0] bi;
            logic [4:0] t;
            t = s - 21;
            bi = t[1:0];
            for (int r = 0; r < 4; r++)
              for (int c = 0; c < 4; c++)
                residuals.chroma[1][bi[1]*4+r][bi[0]*4+c] <= idct_block[r][c];
          end

          // Advance
          if (seq == 24) begin
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
