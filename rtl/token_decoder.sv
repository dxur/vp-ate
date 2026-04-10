// The token decoder
//
// Decodes one 4x4 block from bit stream

import Macroblock::*;

module TokenDecoder (
    input var logic clk,
    input var logic rst,

    BoolDecoderIf.user bd,

    input var logic           [1:0] plane,
    input var logic           [1:0] complexity,
    input var logic                 first_coeff,
    input var shortint signed       dcq,
    input var shortint signed       acq,
    input var Frame::FrameCtx       frame_ctx,

    input var  logic start,
    output var logic busy,

    output var shortint signed coeffs     [0:15],
    output var logic           has_coeff,
    output var logic           coeff_valid
);

  // COEFF_BANDS[16]
  // const COEFF_BANDS: [usize; 16] = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7];
  function automatic logic [2:0] coeff_band(input logic [3:0] i);
    case (i)
      4'd0: coeff_band = 3'd0;
      4'd1: coeff_band = 3'd1;
      4'd2: coeff_band = 3'd2;
      4'd3: coeff_band = 3'd3;
      4'd4: coeff_band = 3'd6;
      4'd5: coeff_band = 3'd4;
      4'd6: coeff_band = 3'd5;
      4'd7: coeff_band = 3'd6;
      4'd8: coeff_band = 3'd6;
      4'd9: coeff_band = 3'd6;
      4'd10: coeff_band = 3'd6;
      4'd11: coeff_band = 3'd6;
      4'd12: coeff_band = 3'd6;
      4'd13: coeff_band = 3'd6;
      4'd14: coeff_band = 3'd6;
      4'd15: coeff_band = 3'd7;
      default: coeff_band = 3'd0;
    endcase
  endfunction

  // ZIGZAG[16]
  // const ZIGZAG: [u8; 16] = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
  function automatic logic [3:0] zigzag(input logic [3:0] i);
    case (i)
      4'd0: zigzag = 4'd0;
      4'd1: zigzag = 4'd1;
      4'd2: zigzag = 4'd4;
      4'd3: zigzag = 4'd8;
      4'd4: zigzag = 4'd5;
      4'd5: zigzag = 4'd2;
      4'd6: zigzag = 4'd3;
      4'd7: zigzag = 4'd6;
      4'd8: zigzag = 4'd9;
      4'd9: zigzag = 4'd12;
      4'd10: zigzag = 4'd13;
      4'd11: zigzag = 4'd10;
      4'd12: zigzag = 4'd7;
      4'd13: zigzag = 4'd11;
      4'd14: zigzag = 4'd14;
      4'd15: zigzag = 4'd15;
      default: zigzag = 4'd0;
    endcase
  endfunction

  // COEFF_TREE
  function automatic byte signed coeff_tree(input logic [4:0] idx);
    case (idx)
      5'd0: coeff_tree = -8'sd11;
      5'd1: coeff_tree = 8'sd2;
      5'd2: coeff_tree = -8'sd0;
      5'd3: coeff_tree = 8'sd4;
      5'd4: coeff_tree = -8'sd1;
      5'd5: coeff_tree = 8'sd6;
      5'd6: coeff_tree = 8'sd8;
      5'd7: coeff_tree = 8'sd12;
      5'd8: coeff_tree = -8'sd2;
      5'd9: coeff_tree = 8'sd10;
      5'd10: coeff_tree = -8'sd3;
      5'd11: coeff_tree = -8'sd4;
      5'd12: coeff_tree = 8'sd14;
      5'd13: coeff_tree = 8'sd16;
      5'd14: coeff_tree = -8'sd5;
      5'd15: coeff_tree = -8'sd6;
      5'd16: coeff_tree = 8'sd18;
      5'd17: coeff_tree = 8'sd20;
      5'd18: coeff_tree = -8'sd7;
      5'd19: coeff_tree = -8'sd8;
      5'd20: coeff_tree = -8'sd9;
      5'd21: coeff_tree = -8'sd10;
      default: coeff_tree = -8'sd11;
    endcase
  endfunction

  // COEFF_TREE_NOEOB
  function automatic byte signed coeff_tree_noeob(input logic [4:0] idx);
    case (idx)
      5'd0: coeff_tree_noeob = -8'sd0;
      5'd1: coeff_tree_noeob = 8'sd2;
      5'd2: coeff_tree_noeob = -8'sd1;
      5'd3: coeff_tree_noeob = 8'sd4;
      5'd4: coeff_tree_noeob = 8'sd6;
      5'd5: coeff_tree_noeob = 8'sd10;
      5'd6: coeff_tree_noeob = -8'sd2;
      5'd7: coeff_tree_noeob = 8'sd8;
      5'd8: coeff_tree_noeob = -8'sd3;
      5'd9: coeff_tree_noeob = -8'sd4;
      5'd10: coeff_tree_noeob = 8'sd12;
      5'd11: coeff_tree_noeob = 8'sd14;
      5'd12: coeff_tree_noeob = -8'sd5;
      5'd13: coeff_tree_noeob = -8'sd6;
      5'd14: coeff_tree_noeob = 8'sd16;
      5'd15: coeff_tree_noeob = 8'sd18;
      5'd16: coeff_tree_noeob = -8'sd7;
      5'd17: coeff_tree_noeob = -8'sd8;
      5'd18: coeff_tree_noeob = -8'sd9;
      5'd19: coeff_tree_noeob = -8'sd10;
      default: coeff_tree_noeob = -8'sd0;
    endcase
  endfunction

  // CATEGORY_BASE: [5, 7, 11, 19, 35, 67]
  function automatic logic [3:0] pcat_len(input logic [2:0] cat_idx);
    case (cat_idx)
      3'd0: pcat_len = 4'd1;
      3'd1: pcat_len = 4'd2;
      3'd2: pcat_len = 4'd3;
      3'd3: pcat_len = 4'd4;
      3'd4: pcat_len = 4'd5;
      3'd5: pcat_len = 4'd11;
      default: pcat_len = 4'd0;
    endcase
  endfunction

  function automatic shortint signed cat_base(input logic [2:0] cat_idx);
    case (cat_idx)
      3'd0: cat_base = 16'sd5;
      3'd1: cat_base = 16'sd7;
      3'd2: cat_base = 16'sd11;
      3'd3: cat_base = 16'sd19;
      3'd4: cat_base = 16'sd35;
      3'd5: cat_base = 16'sd67;
      default: cat_base = 16'sd0;
    endcase
  endfunction

  // PCAT probability lookup: pcat[cat_idx][bit_idx]
  function automatic byte unsigned pcat_prob(input logic [2:0] cat_idx, input logic [3:0] bit_idx);
    // PCAT1
    if (cat_idx == 3'd0) begin
      case (bit_idx)
        4'd0: pcat_prob = 8'd159;
        default: pcat_prob = 8'd128;
      endcase
      // PCAT2
    end else if (cat_idx == 3'd1) begin
      case (bit_idx)
        4'd0: pcat_prob = 8'd165;
        4'd1: pcat_prob = 8'd145;
        default: pcat_prob = 8'd128;
      endcase
      // PCAT3
    end else if (cat_idx == 3'd2) begin
      case (bit_idx)
        4'd0: pcat_prob = 8'd173;
        4'd1: pcat_prob = 8'd148;
        4'd2: pcat_prob = 8'd140;
        default: pcat_prob = 8'd128;
      endcase
      // PCAT4
    end else if (cat_idx == 3'd3) begin
      case (bit_idx)
        4'd0: pcat_prob = 8'd176;
        4'd1: pcat_prob = 8'd155;
        4'd2: pcat_prob = 8'd140;
        4'd3: pcat_prob = 8'd135;
        default: pcat_prob = 8'd128;
      endcase
      // PCAT5
    end else if (cat_idx == 3'd4) begin
      case (bit_idx)
        4'd0: pcat_prob = 8'd180;
        4'd1: pcat_prob = 8'd157;
        4'd2: pcat_prob = 8'd141;
        4'd3: pcat_prob = 8'd134;
        4'd4: pcat_prob = 8'd130;
        default: pcat_prob = 8'd128;
      endcase
      // PCAT6
    end else begin
      case (bit_idx)
        4'd0: pcat_prob = 8'd254;
        4'd1: pcat_prob = 8'd254;
        4'd2: pcat_prob = 8'd243;
        4'd3: pcat_prob = 8'd230;
        4'd4: pcat_prob = 8'd196;
        4'd5: pcat_prob = 8'd177;
        4'd6: pcat_prob = 8'd153;
        4'd7: pcat_prob = 8'd140;
        4'd8: pcat_prob = 8'd133;
        4'd9: pcat_prob = 8'd130;
        4'd10: pcat_prob = 8'd129;
        default: pcat_prob = 8'd128;
      endcase
    end
  endfunction

  // States
  typedef enum logic [3:0] {
    S_IDLE        = 4'd0,
    S_START       = 4'd1,  // latch inputs, init state
    S_COEFF_START = 4'd2,  // begin processing coeff i: compute band/ctx, start tree
    S_WALK_TOKEN  = 4'd3,  // tree walk for token (COEFF_TREE or COEFF_TREE_NOEOB)
    S_PCAT_BITS   = 4'd4,  // read extra bits for category tokens
    S_SIGN        = 4'd5,  // read sign bit
    S_NEXT_COEFF  = 4'd6,  // advance i, loop or finish
    S_DONE        = 4'd7   // assert coeff_valid for one cycle
  } State;

  State                  state;

  // Registered inputs (latched on start)
  logic           [ 1:0] r_plane;
  logic           [ 1:0] r_complexity;
  logic           [ 1:0] r_init_complexity;
  logic                  r_first_coeff;
  shortint signed        r_dcq;
  shortint signed        r_acq;

  // Working registers
  logic           [ 3:0] coeff_i;  // current coefficient index (0..15)
  logic           [ 3:0] r_zigzag;  // zigzag[coeff_i]
  logic           [ 2:0] r_band;  // coeff_band[coeff_i]
  logic                  r_skip;  // skip flag (true after Dct0 token seen)
  logic                  r_has_coeff;

  // Tree walk
  byte signed            tree_node;  // current tree node (signed)
  logic                  bd_req_pend;

  // Current token (decoded from tree walk)
  logic           [ 3:0] r_token;  // 0..11
  logic                  r_is_cat;  // token is DctCat1..6
  logic           [ 2:0] r_cat_idx;  // 0=Cat1..5=Cat6

  // Pcat extra bits
  logic           [ 3:0] r_pcat_len;  // number of extra bits to read
  logic           [ 3:0] r_pcat_bit;  // current bit index (counts down from pcat_len-1)
  logic           [10:0] r_pcat_accum;  // accumulated extra bits (MSB first, up to 11 bits)

  // Coefficient accumulator before dequant
  shortint signed        r_abs_val;  // absolute value of coefficient

  // Output register
  shortint signed        r_coeffs                                                           [0:15];

  // Probability selection
  // The node register holds the current tree position
  // For COEFF_TREE: prob index = node[4:1]  (node>>1), range 0..10
  // For COEFF_TREE_NOEOB: prob index = node[4:1] + 1 (because probs[1..])
  function automatic logic [3:0] prob_idx_for_node(input byte signed node, input logic skip);
    if (skip)
      // COEFF_TREE_NOEOB: prob = probs[1 + node>>1]
      prob_idx_for_node = 4'(node[4:1]) + 4'd1;
    else
      // COEFF_TREE: prob = probs[node>>1]
      prob_idx_for_node = 4'(node[4:1]);
  endfunction

  logic [7:0] cur_prob;
  always_comb begin
    automatic logic [1:0] pl;
    automatic logic [2:0] bd_val;
    automatic logic [1:0] cx;
    automatic logic [3:0] pidx;
    pl = r_plane;
    bd_val = r_band;
    cx = r_complexity[1:0];
    pidx = prob_idx_for_node(tree_node, r_skip);
    if (pidx < 4'd11) cur_prob = frame_ctx.coeff_probs[pl][bd_val][cx[1:0]][pidx[3:0]];
    else cur_prob = 8'd128;
  end

  always_comb begin
    bd.valid      = 1'b0;
    bd.prob       = 8'd128;
    bd.data_ready = 1'b0;
    busy          = 1'b1;
    coeff_valid   = 1'b0;

    for (int k = 0; k < 16; k++) coeffs[k] = r_coeffs[k];
    has_coeff = r_has_coeff;

    case (state)
      S_IDLE: begin
        busy = 1'b0;
      end

      S_DONE: begin
        coeff_valid = 1'b1;
        busy        = 1'b0;
      end

      S_WALK_TOKEN: begin
        bd.prob       = cur_prob;
        bd.data_ready = 1'b1;
        if (!bd_req_pend) bd.valid = 1'b1;
      end

      S_SIGN: begin
        bd.prob       = 8'd128;
        bd.data_ready = 1'b1;
        if (!bd_req_pend) bd.valid = 1'b1;
      end

      S_PCAT_BITS: begin
        bd.prob       = pcat_prob(r_cat_idx, r_pcat_bit);
        bd.data_ready = 1'b1;
        if (!bd_req_pend) bd.valid = 1'b1;
      end

      default: ;
    endcase
  end

  // FSM
  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      state         <= S_IDLE;
      bd_req_pend   <= 1'b0;
      r_plane       <= '0;
      r_complexity  <= '0;
      r_first_coeff <= '0;
      r_dcq         <= '0;
      r_acq         <= '0;
      r_has_coeff   <= 1'b0;
      r_skip        <= 1'b0;
      coeff_i       <= '0;
      tree_node     <= '0;
      r_token       <= '0;
      r_is_cat      <= 1'b0;
      r_cat_idx     <= '0;
      r_pcat_len    <= '0;
      r_pcat_bit    <= '0;
      r_pcat_accum  <= '0;
      r_abs_val     <= '0;
      r_band        <= '0;
      r_zigzag      <= '0;
      for (int k = 0; k < 16; k++) r_coeffs[k] <= '0;
    end else begin

      // BD handshake tracking
      if (bd.valid && bd.ready) bd_req_pend <= 1'b1;
      if (bd.data_valid && bd_req_pend) bd_req_pend <= 1'b0;

      case (state)

        S_IDLE: begin
          if (start) begin
            r_plane           <= plane;
            r_complexity      <= complexity;
            r_init_complexity <= complexity;
            r_first_coeff     <= first_coeff;
            r_dcq             <= dcq;
            r_acq             <= acq;
            r_skip            <= 1'b0;
            r_has_coeff       <= 1'b0;
            bd_req_pend       <= 1'b0;
            for (int k = 0; k < 16; k++) r_coeffs[k] <= '0;

            // Set coeff_i to first_coeff (0 or 1), Y2, Y modes?
            coeff_i <= {3'b0, first_coeff};
            state   <= S_START;
          end
        end

        // Latch inputs and initialise working state
        S_START: begin
          state <= S_COEFF_START;
        end

        // Begin processing coefficient at index coeff_i
        // Compute band, zigzag, start tree walk at node 0
        S_COEFF_START: begin
          r_band    <= coeff_band(coeff_i);
          r_zigzag  <= zigzag(coeff_i);
          tree_node <= 8'sd0;
          state     <= S_WALK_TOKEN;
        end

        // Tree walk for token.
        // - If r_skip: use COEFF_TREE_NOEOB
        // - Else:      use COEFF_TREE
        // Prob is selected combinationally via cur_prob.
        S_WALK_TOKEN: begin
          if (bd.data_valid && bd_req_pend) begin
            automatic byte signed child;

            if (r_skip) begin
              // COEFF_TREE_NOEOB: index = node + bit
              child = coeff_tree_noeob(5'(tree_node) + {4'b0, bd.data});
            end else begin
              // COEFF_TREE: index = node + bit
              child = coeff_tree(5'(tree_node) + {4'b0, bd.data});
            end

            if (child <= 8'sd0) begin
              // Leaf reached, child is the token value
              automatic logic [3:0] tok;
              tok = 4'(-child);
              r_token <= tok;

              // DctEob (token=11): break, go to done
              if (tok == 4'd11) begin
                state <= S_DONE;

                // Dct0 (token=0): skip=true, complexity=0, continue
              end else if (tok == 4'd0) begin
                r_skip       <= 1'b1;
                r_has_coeff  <= 1'b1;
                r_complexity <= 2'd0;
                // No sign bit or dequant just go to next coeff
                state        <= S_NEXT_COEFF;

                // Dct1..4: literal value
              end else if (tok <= 4'd4) begin
                r_abs_val <= shortint'(tok);  // value = token (1,2,3,4)
                r_is_cat  <= 1'b0;
                state     <= S_SIGN;

                // DctCat1..6 (token=5..10): read pcat extra bits
              end else begin
                automatic logic [2:0] cidx;
                cidx = tok[2:0] - 3'd5;  // 0=Cat1..5=Cat6
                r_cat_idx    <= cidx;
                r_pcat_len   <= pcat_len(cidx);
                r_pcat_bit   <= 4'd0;
                r_pcat_accum <= '0;
                r_is_cat     <= 1'b1;
                r_abs_val    <= cat_base(cidx);  // will add extra bits
                state        <= S_PCAT_BITS;
              end

            end else begin
              // Not a leaf continue walking
              tree_node <= child;
            end
          end
        end

        // Read extra bits for category tokens.
        // abs_value = CATEGORY_BASE[cat] + v
        // We accumulate MSB first into r_pcat_accum.
        S_PCAT_BITS: begin
          if (bd.data_valid && bd_req_pend) begin
            // Shift in bit MSB first
            r_pcat_accum <= {r_pcat_accum[9:0], bd.data};

            if (r_pcat_bit == r_pcat_len - 4'd1) begin
              // Last bit compute final abs value
              automatic logic [10:0] final_accum;
              final_accum = {r_pcat_accum[9:0], bd.data};
              r_abs_val <= cat_base(r_cat_idx) + shortint'(final_accum);
              state     <= S_SIGN;
            end else begin
              r_pcat_bit <= r_pcat_bit + 4'd1;
            end
          end
        end

        // Read sign bit (prob=128).
        // Rust: let sign = bd.read_bool(128)?; if sign != 0 { abs_value = -abs_value }
        // Then dequant: val * (dcq if zigzag==0 else acq)
        // Update complexity: 0 if abs==0, 1 if abs==1, 2 otherwise
        S_SIGN: begin
          if (bd.data_valid && bd_req_pend) begin
            automatic shortint signed       signed_val;
            automatic shortint signed       dequant_val;
            automatic shortint signed       q;
            automatic logic           [3:0] zz;

            signed_val = bd.data ? -r_abs_val : r_abs_val;

            zz = r_zigzag;
            q = (zz == 4'd0) ? r_dcq : r_acq;

            dequant_val = signed_val * q;

            // Store in raster-order position
            r_coeffs[zz] <= dequant_val;

            // Update has_coeff
            r_has_coeff <= 1'b1;

            // Update skip: non-zero token → skip=false (Rust: skip = false after sign)
            r_skip <= 1'b0;

            // Update complexity based on abs value of coefficient (before dequant)
            // abs_value here is r_abs_val (always >=1 since Dct0 was handled separately)
            if (r_abs_val == 16'sd1) r_complexity <= 2'd1;
            else r_complexity <= 2'd2;

            state <= S_NEXT_COEFF;
          end
        end

        // Advance coeff_i and loop or finish
        S_NEXT_COEFF: begin
          if (coeff_i == 4'd15) begin
            state <= S_DONE;
          end else begin
            coeff_i <= coeff_i + 4'd1;
            state   <= S_COEFF_START;
          end
        end

        S_DONE: begin
          // Hold for one cycle so consumer can latch coeff_valid
          state <= S_IDLE;
        end

        default: state <= S_IDLE;

      endcase
    end
  end

endmodule


// Test wrapper
module TokenDecoderTest
  import Macroblock::*;
(
    input var logic clk,
    input var logic rst,

    input var  logic       bd_ready,
    input var  logic       bd_data_valid,
    input var  logic       bd_data,
    output var logic       bd_valid,
    output var logic [7:0] bd_prob,
    output var logic       bd_data_ready,

    input var logic [8447:0] coeff_probs_flat,

    input var logic           [1:0] plane,
    input var logic           [1:0] complexity,
    input var logic                 first_coeff,
    input var shortint signed       dcq,
    input var shortint signed       acq,

    input var  logic start,
    output var logic busy,

    output var shortint signed coeffs     [0:15],
    output var logic           has_coeff,
    output var logic           coeff_valid
);
  BoolDecoderIf bd ();

  always_comb begin
    bd_valid      = bd.valid;
    bd_prob       = bd.prob;
    bd_data_ready = bd.data_ready;
    bd.ready      = bd_ready;
    bd.data_valid = bd_data_valid;
    bd.data       = bd_data;
  end

  Frame::FrameCtx frame_ctx;
  always_comb begin
    frame_ctx.valid            = 1'b1;
    frame_ctx.part1_off        = '0;
    frame_ctx.width            = '0;
    frame_ctx.height           = '0;
    frame_ctx.h_scale          = '0;
    frame_ctx.v_scale          = '0;
    frame_ctx.mb_width         = '0;
    frame_ctx.mb_height        = '0;
    frame_ctx.ydc              = '0;
    frame_ctx.yac              = '0;
    frame_ctx.y2dc             = '0;
    frame_ctx.y2ac             = '0;
    frame_ctx.uvdc             = '0;
    frame_ctx.uvac             = '0;
    frame_ctx.mb_no_skip_coeff = '0;
    frame_ctx.prob_skip_false  = '0;

    for (int pl = 0; pl < 4; pl++)
    for (int band = 0; band < 8; band++)
    for (int ctx = 0; ctx < 3; ctx++)
    for (int tok = 0; tok < 11; tok++) begin
      automatic int idx;
      idx = ((pl * 8 + band) * 3 + ctx) * 11 + tok;
      frame_ctx.coeff_probs[pl][band][ctx][tok] = coeff_probs_flat[8447-idx*8-:8];
    end
  end

  TokenDecoder uut (
      .clk        (clk),
      .rst        (rst),
      .bd         (bd),
      .plane      (plane),
      .complexity (complexity),
      .first_coeff(first_coeff),
      .dcq        (dcq),
      .acq        (acq),
      .frame_ctx  (frame_ctx),
      .start      (start),
      .busy       (busy),
      .coeffs     (coeffs),
      .has_coeff  (has_coeff),
      .coeff_valid(coeff_valid)
  );
endmodule
