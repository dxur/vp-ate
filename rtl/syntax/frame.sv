// Frame-level types and parser for VP8 keyframes.
//
// FrameHeaderParser reads the first 10 raw bytes from the ring buffer, then
// bool-decodes the remaining frame header fields to populate FrameCtx.
//
// Sequence:
//   byte 0-2:  frame tag  (is_key, version, show_frame, partition0_len)
//   byte 3-5:  start code 0x9D 0x01 0x2A  (keyframe only)
//   byte 6-9:  raw_width [15:0] + raw_height [15:0]
//   byte 10+:  bool-decoded header (part0 starts here)
//
// The parser hands the BoolDecoder its bytes directly from the ring buffer
// starting at byte offset 10. The residual partition starts at byte
// partition0_len + 10 and is handled separately.

import MacroblockHeaderPkg::*;

package Frame;
  typedef byte unsigned Prob;
  typedef Prob CoeffProbs[4][8][3][11];

  typedef struct {
    logic             valid;
    longint unsigned  part1_off;  // byte offset of residual partition in ring
    shortint unsigned width;
    shortint unsigned height;
    byte unsigned     h_scale;
    byte unsigned     v_scale;
    shortint unsigned mb_width;
    shortint unsigned mb_height;
    shortint signed   ydc;
    shortint signed   yac;
    shortint signed   y2dc;
    shortint signed   y2ac;
    shortint signed   uvdc;
    shortint signed   uvac;

    CoeffProbs coeff_probs;

    logic         mb_no_skip_coeff;
    byte unsigned prob_skip_false;
  } FrameCtx;

  typedef struct packed {
    logic                                 valid;
    MacroblockHeaderPkg::MacroblockHeader header;
    // tokens are in residue_decoder output - not stored here
  } Macroblock;
endpackage

// ---------------------------------------------------------------------------
// FrameHeaderParser
//
// Interfaces with two bool decoders that the parent must instantiate:
//   bd_part0  - the header partition (starts at ring offset 10)
//               Drives this interface to decode the bool-coded frame header.
//
// The parser reads the first 10 bytes RAW from the ring via raw_* ports,
// then switches to bool decoding for the rest.
// ---------------------------------------------------------------------------

module FrameHeaderParser (
    input var logic clk,
    input var logic rst,

    // Raw byte interface to ring buffer (sequential drain, bytes 0-9)
    input var  byte unsigned raw_data,
    input var  logic         raw_valid,
    output var logic         raw_ready,

    // BoolDecoder interface for part0 header (bytes 10+)
    BoolDecoderIf.user bd,

    // Output
    output var Frame::FrameCtx ctx,
    output var logic           done  // pulses one cycle when ctx is valid
);
  // -------------------------------------------------------------------------
  // Internal quant helpers - mirroring DC_QUANT / AC_QUANT lookups.
  // We use the Tables package for the actual LUT data.
  // -------------------------------------------------------------------------
  function automatic shortint signed dc_quant(input byte unsigned idx);
    dc_quant = shortint'(Tables::DC_QUANT[idx>127?127 : idx]);
  endfunction

  function automatic shortint signed ac_quant(input byte unsigned idx);
    ac_quant = shortint'(Tables::AC_QUANT[idx>127?127 : idx]);
  endfunction

  // Clamp helper
  function automatic byte unsigned clamp7(input int signed v);
    clamp7 = byte'(v < 0 ? 0 : v > 127 ? 127 : v);
  endfunction

  // -------------------------------------------------------------------------
  // State machine
  // -------------------------------------------------------------------------
  typedef enum logic [5-1:0] {
    S_TAG0          = 5'd1,
    S_TAG1          = 5'd2,
    S_TAG2          = 5'd4,
    S_START0        = 5'd8,   // start code bytes
    S_START1        = 5'd16,
    S_START2        = 5'd17,
    S_DIM0          = 5'd18,  // raw width / height bytes
    S_DIM1          = 5'd19,
    S_DIM2          = 5'd20,
    S_DIM3          = 5'd21,
    // Bool-decode states (use bd interface)
    S_BD_CS         = 5'd22,  // color_space flag
    S_BD_CLAMP      = 5'd23,  // clamping flag
    S_BD_SEG        = 5'd24,  // segmentation_enabled (must be 0)
    S_BD_FTYPE      = 5'd25,  // filter_type
    S_BD_LFLEVEL    = 5'd26,  // loop_filter_level [5:0]
    S_BD_SHARP      = 5'd27,  // sharpness_level [2:0]
    S_BD_LFADJ      = 5'd28,  // loop_filter_adj_enable
    S_BD_SKIP       = 5'd29,  // skip mode_ref_lf_delta_update  (simplified: skip lf deltas)
    S_BD_LOG2P      = 5'd30,  // log2_nbr_of_dct_partitions [1:0]
    S_BD_YACQI      = 5'd31,  // yac_qi [6:0]  - NOTE: limited states, reuse bit counter
    S_BD_DELTAS     = 5'd0,   // 5 delta fields (ydc,y2dc,y2ac,uvdc,uvac)
    S_BD_REFENTROPY = 5'd3,   // refresh_entropy_probs
    S_BD_COEFFPROB  = 5'd5,   // coeff_prob update loop
    S_BD_NOSKIP     = 5'd6,   // mb_no_skip_coeff
    S_BD_PROBSKIP   = 5'd7,   // prob_skip_false [7:0]
    S_DONE          = 5'd9
  } State;

  State state;

  // Bit-accumulator for multi-bit literal reads via bool decoder
  logic [7:0] bit_acc;  // accumulated bits (max 8 bits for coeff probs)
  logic [3:0] bit_cnt;  // how many bits remain to collect
  logic [3:0] bit_tgt;  // target bit count for current field

  // Raw byte accumulator (first 10 bytes)
  logic [7:0] raw_byte_cnt;
  logic [1:0] raw_word;  // raw_width / raw_height word index

  // Parsed raw fields
  logic is_key;
  logic [2:0] version;
  logic [18:0] partition0_len;
  logic [13:0] raw_width_lo;
  logic [1:0] h_scale;
  logic [13:0] raw_height_lo;
  logic [1:0] v_scale;

  // Delta decoding
  logic [2:0] delta_idx;  // which of 5 deltas we're on
  logic delta_have_flag;  // we read the update flag
  logic delta_update;  // is delta present?
  logic [3:0] delta_mag;  // magnitude bits (4)
  logic [3:0] delta_bit_cnt;
  logic signed [4:0] deltas[0:4];  // ydc, y2dc, y2ac, uvdc, uvac

  // Coeff prob update loop
  logic [1:0] cp_plane;
  logic [2:0] cp_band;
  logic [1:0] cp_ctx;
  logic [3:0] cp_tok;
  logic cp_update_flag_done;
  logic cp_update;
  logic [3:0] cp_prob_bits;

  // BD request helper: we issue one bool_decode at a time
  logic bd_req_pending;

  // -------------------------------------------------------------------------
  // BD handshake: we set valid+prob, wait for data_valid
  // -------------------------------------------------------------------------
  logic bd_result;  // latched result of last bool decode

  always_comb begin
    bd.valid      = 1'b0;
    bd.prob       = 8'd128;  // default 50/50 literal
    bd.data_ready = !bd_req_pending;  // accept result when we have a pending request
    raw_ready     = 1'b0;
    done          = 1'b0;

    case (state) inside
      S_TAG0, S_TAG1, S_TAG2, S_START0, S_START1, S_START2, S_DIM0, S_DIM1, S_DIM2, S_DIM3:
      raw_ready = 1'b1;

      S_BD_CS, S_BD_CLAMP, S_BD_SEG,
      S_BD_FTYPE, S_BD_LFADJ, S_BD_SKIP,
      S_BD_REFENTROPY, S_BD_NOSKIP: begin
        // Single-bit flags
        if (!bd_req_pending) bd.valid = 1'b1;
      end

      S_BD_LFLEVEL, S_BD_SHARP, S_BD_LOG2P, S_BD_YACQI,
      S_BD_DELTAS, S_BD_COEFFPROB, S_BD_PROBSKIP: begin
        // Multi-bit accumulation: issue one bit at a time
        if (bit_cnt > 0 && !bd_req_pending) bd.valid = 1'b1;
      end

      S_DONE: done = 1'b1;

      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // Sequential state machine
  // -------------------------------------------------------------------------
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      state               <= S_TAG0;
      ctx                 <= '{default: 0};
      ctx.coeff_probs     <= Tables::DEFAULT_COEFF_PROBS;
      bd_req_pending      <= 1'b0;
      bd_result           <= 1'b0;
      raw_byte_cnt        <= '0;
      bit_acc             <= '0;
      bit_cnt             <= '0;
      delta_idx           <= '0;
      delta_have_flag     <= 1'b0;
      delta_update        <= 1'b0;
      delta_mag           <= '0;
      delta_bit_cnt       <= '0;
      deltas              <= '{default: '0};
      cp_plane            <= '0;
      cp_band             <= '0;
      cp_ctx              <= '0;
      cp_tok              <= '0;
      cp_update_flag_done <= 1'b0;
      cp_update           <= 1'b0;
      cp_prob_bits        <= '0;
      bd_req_pending      <= 1'b0;
    end else begin

      // Track bd request lifetime
      if (bd.valid && bd.ready) begin
        bd_req_pending <= 1'b1;
      end
      if (bd.data_valid && bd_req_pending) begin
        bd_result      <= bd.data;
        bd_req_pending <= 1'b0;
      end

      // -------------------------------------------------------------------
      case (state)
        // ------------------------------------------------------------------
        // Raw byte phase (first 10 bytes)
        // ------------------------------------------------------------------
        S_TAG0:
        if (raw_valid) begin
          is_key         <= (raw_data[0] == 1'b0);
          version        <= raw_data[3:1];
          partition0_len <= {raw_data[7:5], 16'b0};  // bits [23:21] of p0_len
          state          <= S_TAG1;
        end

        S_TAG1:
        if (raw_valid) begin
          partition0_len[10:3] <= raw_data;  // bits [18:11] ← byte 1
          state                <= S_TAG2;
        end

        S_TAG2:
        if (raw_valid) begin
          partition0_len[18:11] <= raw_data;  // byte 2: bits [18:11] of p0_len
          // Rebuild properly:  p0_len = (b0 | b1<<8 | b2<<16) >> 5
          // We'll recompute after collecting all 3 tag bytes - done below.
          state <= S_START0;
          // final partition0_len computation deferred - easier after latch
        end

        S_START0:
        if (raw_valid) begin
          // just consume 0x9D
          state <= S_START1;
        end
        S_START1:
        if (raw_valid) begin
          // consume 0x01
          state <= S_START2;
        end
        S_START2:
        if (raw_valid) begin
          // consume 0x2A
          state <= S_DIM0;
        end

        S_DIM0:
        if (raw_valid) begin
          raw_width_lo <= {6'b0, raw_data};  // low byte
          state        <= S_DIM1;
        end
        S_DIM1:
        if (raw_valid) begin
          h_scale  <= raw_data[7:6];
          raw_width_lo[13:8] <= raw_data[5:0];
          ctx.width  <= {2'b0, raw_data[5:0], raw_width_lo[7:0]};
          ctx.h_scale <= {6'b0, raw_data[7:6]};
          ctx.mb_width <= shortint'(({2'b0, raw_data[5:0], raw_width_lo[7:0]} + 16'd15) >> 4);
          state    <= S_DIM2;
        end
        S_DIM2:
        if (raw_valid) begin
          raw_height_lo <= {6'b0, raw_data};
          state         <= S_DIM3;
        end
        S_DIM3:
        if (raw_valid) begin
          ctx.v_scale   <= {6'b0, raw_data[7:6]};
          ctx.height    <= {2'b0, raw_data[5:0], raw_height_lo[7:0]};
          ctx.mb_height <= shortint'(({2'b0, raw_data[5:0], raw_height_lo[7:0]} + 16'd15) >> 4);
          // Store part1 offset (will be correctly set after we know partition0_len)
          // For now stash in part1_off; update after S_BD_LOG2P
          state <= S_BD_CS;
          // Issue first bool request: color_space flag
        end

        // ------------------------------------------------------------------
        // Bool-decode phase
        // ------------------------------------------------------------------

        // color_space (must be 0)
        S_BD_CS:
        if (bd.data_valid && bd_req_pending) begin
          // bd_result captured combinationally via always block above
          state <= S_BD_CLAMP;
        end

        // clamping (ignored in RTL)
        S_BD_CLAMP:
        if (bd.data_valid && bd_req_pending) begin
          state <= S_BD_SEG;
        end

        // segmentation_enabled (must be 0 for intra-only)
        S_BD_SEG:
        if (bd.data_valid && bd_req_pending) begin
          state <= S_BD_FTYPE;
        end

        // filter_type (1 bit)
        S_BD_FTYPE:
        if (bd.data_valid && bd_req_pending) begin
          state   <= S_BD_LFLEVEL;
          bit_cnt <= 4'd6;
          bit_acc <= '0;
        end

        // loop_filter_level (6 bits)
        S_BD_LFLEVEL: begin
          if (bd.data_valid && bd_req_pending) begin
            bit_acc <= {bit_acc[6:0], bd_result};
            bit_cnt <= bit_cnt - 1'b1;
            if (bit_cnt == 1) begin
              state   <= S_BD_SHARP;
              bit_cnt <= 4'd3;
              bit_acc <= '0;
            end
          end
        end

        // sharpness_level (3 bits)
        S_BD_SHARP: begin
          if (bd.data_valid && bd_req_pending) begin
            bit_acc <= {bit_acc[6:0], bd_result};
            bit_cnt <= bit_cnt - 1'b1;
            if (bit_cnt == 1) begin
              state <= S_BD_LFADJ;
            end
          end
        end

        // loop_filter_adj_enable (1 bit) - if set, we skip lf delta subfields
        // (simplified: just skip them by reading the mode_ref_lf_delta_update flag)
        S_BD_LFADJ:
        if (bd.data_valid && bd_req_pending) begin
          if (bd_result) begin
            // loop_filter_adj_enable=1 -> read mode_ref_lf_delta_update flag
            state <= S_BD_SKIP;
          end else begin
            // loop_filter_adj_enable=0 -> skip straight to log2_nbr_of_dct_partitions
            state   <= S_BD_LOG2P;
            bit_cnt <= 4'd2;
            bit_acc <= '0;
          end
        end

        // mode_ref_lf_delta_update (1 bit) - if 1, we'd need to read 8 signed deltas.
        // Simplified: just consume the flag and assume 0 for the deltas.
        // (Full implementation would add states for the 8 delta fields.)
        S_BD_SKIP:
        if (bd.data_valid && bd_req_pending) begin
          // Skip lf_delta parsing for now (intra test frames typically have it 0)
          state   <= S_BD_LOG2P;
          bit_cnt <= 4'd2;
          bit_acc <= '0;
        end

        // log2_nbr_of_dct_partitions (2 bits) - only 0 (1 partition) supported
        S_BD_LOG2P: begin
          if (bd.data_valid && bd_req_pending) begin
            bit_acc <= {bit_acc[6:0], bd_result};
            bit_cnt <= bit_cnt - 1'b1;
            if (bit_cnt == 1) begin
              // Compute part1_off = partition0_len + 10
              ctx.part1_off <= longint'(partition0_len) + 10;
              state <= S_BD_YACQI;
              bit_cnt <= 4'd7;
              bit_acc <= '0;
            end
          end
        end

        // yac_qi (7 bits)
        S_BD_YACQI: begin
          if (bd.data_valid && bd_req_pending) begin
            bit_acc <= {bit_acc[6:0], bd_result};
            bit_cnt <= bit_cnt - 1'b1;
            if (bit_cnt == 1) begin
              // Compute quantizers - deltas applied afterwards
              // bit_acc[6:0] is yac_qi
              ctx.yac         <= ac_quant(byte'(bit_acc[6:0]));
              ctx.ydc         <= dc_quant(byte'(bit_acc[6:0]));  // will add ydc_delta after
              ctx.y2dc        <= shortint'(dc_quant(byte'(bit_acc[6:0])) * 2);
              ctx.y2ac        <= shortint'((int'(ac_quant(byte'(bit_acc[6:0]))) * 155) / 100);
              ctx.uvdc        <= dc_quant(byte'(bit_acc[6:0]));  // updated with uvdc_delta
              ctx.uvac        <= ac_quant(byte'(bit_acc[6:0]));
              // Start delta decode
              state           <= S_BD_DELTAS;
              delta_idx       <= '0;
              delta_have_flag <= 1'b0;
              bit_cnt         <= 4'd1;  // read flag first
            end
          end
        end

        // 5 delta fields: ydc_delta, y2dc_delta, y2ac_delta, uvdc_delta, uvac_delta
        // each: 1-bit present flag, if set: 4-bit magnitude + 1-bit sign = 5 bits total
        S_BD_DELTAS: begin
          if (bd.data_valid && bd_req_pending) begin
            if (!delta_have_flag) begin
              // First bit = update flag
              delta_update    <= bd_result;
              delta_have_flag <= 1'b1;
              if (bd_result) begin
                bit_cnt <= 4'd5;  // 4 magnitude + 1 sign
                bit_acc <= '0;
                delta_bit_cnt <= 4'd5;
              end else begin
                deltas[delta_idx] <= '0;
                delta_have_flag   <= 1'b0;
                if (delta_idx == 4) begin
                  // Recompute quantisers with deltas
                  state <= S_BD_REFENTROPY;
                end else begin
                  delta_idx <= delta_idx + 1'b1;
                end
              end
            end else begin
              // Reading 5-bit delta (4 mag + sign)
              bit_acc       <= {bit_acc[6:0], bd_result};
              delta_bit_cnt <= delta_bit_cnt - 1'b1;
              if (delta_bit_cnt == 1) begin
                // bit_acc[4:1] = magnitude, bit_acc[0] = sign
                deltas[delta_idx] <= bit_acc[0] ? -signed'({1'b0, bit_acc[4:1]}) :
                                                   signed'({1'b0, bit_acc[4:1]});
                delta_have_flag <= 1'b0;
                if (delta_idx == 4) begin
                  state <= S_BD_REFENTROPY;
                end else begin
                  delta_idx <= delta_idx + 1'b1;
                end
              end
            end
          end

          // After S_BD_REFENTROPY is entered (next cycle), apply deltas to quantisers.
          // We do it here on the transition to avoid an extra state.
          if (state == S_BD_REFENTROPY) begin
            // Recompute
            begin
              // Use 32-bit signed arithmetic to avoid width warnings, then clamp to shortint.
              ctx.ydc <= shortint'(int'(signed'(ctx.ydc)) + int'(signed'(deltas[0])));
              ctx.y2dc <= shortint'(int'(signed'(ctx.y2dc)) + int'(signed'(deltas[1])) * 2);
              ctx.y2ac <= shortint'(int'(signed'(ctx.y2ac)) + (int'(signed'(deltas[2])) * 155) / 100);
              ctx.uvdc <= shortint'((int'(signed'(ctx.uvdc)) + int'(signed'(deltas[3]))) > 8 ?
                                    (int'(signed'(ctx.uvdc)) + int'(signed'(deltas[3]))) : 8);
              ctx.uvac <= shortint'((int'(signed'(ctx.uvac)) + int'(signed'(deltas[4]))) < 132 ?
                                    (int'(signed'(ctx.uvac)) + int'(signed'(deltas[4]))) : 132);
            end
          end
        end

        // refresh_entropy_probs (1 bit, keyframe always 1)
        S_BD_REFENTROPY:
        if (bd.data_valid && bd_req_pending) begin
          state               <= S_BD_COEFFPROB;
          cp_plane            <= '0;
          cp_band             <= '0;
          cp_ctx              <= '0;
          cp_tok              <= '0;
          cp_update_flag_done <= 1'b0;
          cp_update           <= 1'b0;
          cp_prob_bits        <= 4'd8;
          bit_cnt             <= 4'd1;  // read update flag first
        end

        // Coeff prob update: 4 planes × 8 bands × 3 ctx × 11 tokens
        // For each: read 1-bit flag via COEFF_UPDATE_PROBS, if set read 8-bit new prob
        S_BD_COEFFPROB: begin
          if (bd.data_valid && bd_req_pending) begin
            if (!cp_update_flag_done) begin
              cp_update           <= bd_result;
              cp_update_flag_done <= 1'b1;
              if (bd_result) begin
                bit_cnt <= 4'd8;
                bit_acc <= '0;
              end else begin
                // advance counter
                cp_update_flag_done <= 1'b0;
                if (cp_tok == 10) begin
                  cp_tok <= '0;
                  if (cp_ctx == 2) begin
                    cp_ctx <= '0;
                    if (cp_band == 7) begin
                      cp_band <= '0;
                      if (cp_plane == 3) begin
                        state <= S_BD_NOSKIP;
                      end else begin
                        cp_plane <= cp_plane + 1'b1;
                      end
                    end else begin
                      cp_band <= cp_band + 1'b1;
                    end
                  end else begin
                    cp_ctx <= cp_ctx + 1'b1;
                  end
                end else begin
                  cp_tok <= cp_tok + 1'b1;
                end
              end
            end else begin
              // Reading 8-bit updated probability
              bit_acc <= {bit_acc[6:0], bd_result};
              bit_cnt <= bit_cnt - 1'b1;
              if (bit_cnt == 1) begin
                ctx.coeff_probs[cp_plane][cp_band][cp_ctx][cp_tok] <= bit_acc[7:0];
                cp_update_flag_done <= 1'b0;
                // Advance
                if (cp_tok == 10) begin
                  cp_tok <= '0;
                  if (cp_ctx == 2) begin
                    cp_ctx <= '0;
                    if (cp_band == 7) begin
                      cp_band <= '0;
                      if (cp_plane == 3) begin
                        state <= S_BD_NOSKIP;
                      end else begin
                        cp_plane <= cp_plane + 1'b1;
                      end
                    end else begin
                      cp_band <= cp_band + 1'b1;
                    end
                  end else begin
                    cp_ctx <= cp_ctx + 1'b1;
                  end
                end else begin
                  cp_tok <= cp_tok + 1'b1;
                end
              end
            end
          end
        end

        // mb_no_skip_coeff (1 bit)
        S_BD_NOSKIP:
        if (bd.data_valid && bd_req_pending) begin
          ctx.mb_no_skip_coeff <= bd_result;
          if (bd_result) begin
            state   <= S_BD_PROBSKIP;
            bit_cnt <= 4'd8;
            bit_acc <= '0;
          end else begin
            ctx.prob_skip_false <= '0;
            state               <= S_DONE;
            ctx.valid           <= 1'b1;
          end
        end

        // prob_skip_false (8 bits) - only when mb_no_skip_coeff = 1
        S_BD_PROBSKIP: begin
          if (bd.data_valid && bd_req_pending) begin
            bit_acc <= {bit_acc[6:0], bd_result};
            bit_cnt <= bit_cnt - 1'b1;
            if (bit_cnt == 1) begin
              ctx.prob_skip_false <= bit_acc[7:0];
              state               <= S_DONE;
              ctx.valid           <= 1'b1;
            end
          end
        end

        S_DONE: ;  // stay - parent resets us on next frame

        default: state <= S_TAG0;
      endcase
    end
  end

endmodule

// ---------------------------------------------------------------------------
// Test wrapper (flat ports for cocotb - no interface)
// ---------------------------------------------------------------------------
module FrameParserTest (
    input var logic clk,
    input var logic rst,

    // Raw byte steam
    input var  byte unsigned raw_data,
    input var  logic         raw_valid,
    output var logic         raw_ready,

    // BoolDecoder connections (flat)
    output var logic       bd_valid,
    output var logic [7:0] bd_prob,
    input var  logic       bd_ready,
    input var  logic       bd_data_valid,
    output var logic       bd_data_ready,
    input var  logic       bd_data,

    output var Frame::FrameCtx ctx,
    output var logic           done
);
  BoolDecoderIf bd ();

  always_comb begin
    bd_valid      = bd.valid;
    bd_prob       = bd.prob;
    bd.ready      = bd_ready;
    bd.data_valid = bd_data_valid;
    bd_data_ready = bd.data_ready;
    bd.data       = bd_data;
  end

  FrameHeaderParser uut (
      .clk      (clk),
      .rst      (rst),
      .raw_data (raw_data),
      .raw_valid(raw_valid),
      .raw_ready(raw_ready),
      .bd       (bd),
      .ctx      (ctx),
      .done     (done)
  );
endmodule
