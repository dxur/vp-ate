import Macroblock::*;

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
    logic              valid;
    Macroblock::Header header;
  } Macroblock;
endpackage

module FrameHeaderParser (
    input var logic clk,
    input var logic rst,

    // sequential drain, bytes 0-9
    input var  byte unsigned raw_data,
    input var  logic         raw_valid,
    output var logic         raw_ready,

    // BoolDecoder interface for part0 header (bytes 10+)
    BoolDecoderIf.user bd,

    // Output
    output var Frame::FrameCtx ctx,
    output var logic           done  // pulses one cycle when ctx is valid
);

  // Quantizer table lookup helpers (clamp index to [0,127])
  function automatic shortint signed dc_quant(input int signed idx);
    automatic int c = (idx < 0) ? 0 : (idx > 127) ? 127 : idx;
    dc_quant = shortint'(Tables::DC_QUANT[c]);
  endfunction

  function automatic shortint signed ac_quant(input int signed idx);
    automatic int c = (idx < 0) ? 0 : (idx > 127) ? 127 : idx;
    ac_quant = shortint'(Tables::AC_QUANT[c]);
  endfunction

  typedef enum logic [5:0] {
    S_TAG0           = 6'd0,
    S_TAG1           = 6'd1,
    S_TAG2           = 6'd2,
    S_START0         = 6'd3,
    S_START1         = 6'd4,
    S_START2         = 6'd5,
    S_DIM0           = 6'd6,
    S_DIM1           = 6'd7,
    S_DIM2           = 6'd8,
    S_DIM3           = 6'd9,
    S_BD_CS          = 6'd10,  // color_space (1 bit)
    S_BD_CLAMP       = 6'd11,  // clamping (1 bit)
    S_BD_SEG         = 6'd12,  // segmentation_enabled (1 bit)
    S_BD_FTYPE       = 6'd13,  // filter_type (1 bit)
    S_BD_LFLEVEL     = 6'd14,  // loop_filter_level (6 bits)
    S_BD_SHARP       = 6'd15,  // sharpness_level (3 bits)
    S_BD_LFADJ       = 6'd16,  // loop_filter_adj_enable (1 bit)
    S_BD_LFDELTA_UPD = 6'd17,  // mode_ref_lf_delta_update (1 bit)
    S_BD_REFDELTA_F  = 6'd18,  // ref_frame_delta_update_flag, 4 iterations
    S_BD_REFDELTA_V  = 6'd19,  // ref delta: magnitude(6) + sign(1) = 7 bits
    S_BD_MODDELTA_F  = 6'd20,  // mb_mode_delta_update_flag, 4 iterations
    S_BD_MODDELTA_V  = 6'd21,  // mode delta: magnitude(6) + sign(1) = 7 bits
    S_BD_LOG2P       = 6'd22,  // log2_nbr_of_dct_partitions (2 bits)
    S_BD_YACQI       = 6'd23,  // yac_qi (7 bits)
    S_BD_QDELTA_F    = 6'd24,  // quant delta present flag, 5 iterations
    S_BD_QDELTA_V    = 6'd25,  // quant delta: magnitude(4) + sign(1) = 5 bits
    S_BD_REFENTROPY  = 6'd26,  // refresh_entropy_probs (1 bit)
    S_BD_COEFFPROB   = 6'd27,  // coeff_prob update loop [4][8][3][11]
    S_BD_NOSKIP      = 6'd28,  // mb_no_skip_coeff (1 bit)
    S_BD_PROBSKIP    = 6'd29,  // prob_skip_false (8 bits)
    S_DONE           = 6'd30
  } State;

  State state;

  // done pulse register
  logic done_r;
  assign done = done_r;

  // bd0 handshake
  logic               bd_req_pending;

  logic        [ 7:0] bit_acc;
  logic        [ 3:0] bit_cnt;

  logic        [18:0] partition0_len;
  logic        [ 7:0] raw_lo;  // low byte of width (DIM0/1) and height (DIM2/3)

  // Quantizer base index and deltas
  logic        [ 6:0] yac_qi;  // after YACQI for delta application
  logic        [ 2:0] qdelta_idx;  // 0=ydc 1=y2dc 2=y2ac 3=uvdc 4=uvac
  logic signed [ 4:0] qdeltas                                                          [0:4];

  // LF delta loop counter
  logic        [ 2:0] lf_delta_idx;

  // Coeff prob loop state
  logic        [ 1:0] cp_plane;
  logic        [ 2:0] cp_band;
  logic        [ 1:0] cp_ctx;
  logic        [ 3:0] cp_tok;
  logic               cp_reading_prob;  // 0 = update flag phase; 1 = 8-bit value phase

  always_comb begin
    bd.valid      = 1'b0;
    bd.prob       = 8'd128;  // default: direct bit read
    bd.data_ready = 1'b1;
    raw_ready     = 1'b0;

    case (state)
      S_TAG0, S_TAG1, S_TAG2, S_START0, S_START1, S_START2, S_DIM0, S_DIM1, S_DIM2, S_DIM3:
      raw_ready = 1'b1;

      S_BD_CS, S_BD_CLAMP, S_BD_SEG, S_BD_FTYPE,
      S_BD_LFADJ, S_BD_LFDELTA_UPD,
      S_BD_REFDELTA_F, S_BD_MODDELTA_F,
      S_BD_QDELTA_F,
      S_BD_REFENTROPY, S_BD_NOSKIP:
      if (!bd_req_pending) bd.valid = 1'b1;
      // bd.prob 128

      S_BD_LFLEVEL, S_BD_SHARP,
      S_BD_REFDELTA_V, S_BD_MODDELTA_V,
      S_BD_LOG2P, S_BD_YACQI,
      S_BD_QDELTA_V, S_BD_PROBSKIP:
      if (bit_cnt > 0 && !bd_req_pending) bd.valid = 1'b1;
      // bd.prob 128

      // Coeff prob loop
      S_BD_COEFFPROB: begin
        if (!bd_req_pending) bd.valid = 1'b1;
        bd.prob = cp_reading_prob
                  ? 8'd128
                  : Tables::COEFF_UPDATE_PROBS[cp_plane][cp_band][cp_ctx][cp_tok];
      end

      default: ;
    endcase
  end

  // FSM
  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      state           <= S_TAG0;
      done_r          <= 1'b0;
      ctx             <= '{default: '0};
      ctx.coeff_probs <= Tables::DEFAULT_COEFF_PROBS;

      bd_req_pending  <= 1'b0;
      bit_acc         <= '0;
      bit_cnt         <= '0;
      partition0_len  <= '0;
      raw_lo          <= '0;
      yac_qi          <= '0;
      qdelta_idx      <= '0;
      qdeltas         <= '{default: '0};
      lf_delta_idx    <= '0;
      cp_plane        <= '0;
      cp_band         <= '0;
      cp_ctx          <= '0;
      cp_tok          <= '0;
      cp_reading_prob <= 1'b0;

    end else begin

      // BD handshake bookkeeping.
      if (bd.data_valid && bd_req_pending) bd_req_pending <= 1'b0;
      else if (bd.valid && bd.ready) bd_req_pending <= 1'b1;

      case (state)
        // Byte 0: [7:5]=partition0_len[2:0], [4]=show_frame,
        //         [3:1]=version, [0]=~is_key
        S_TAG0:
        if (raw_valid) begin
          partition0_len      <= '0;
          partition0_len[2:0] <= raw_data[7:5];
          state               <= S_TAG1;
        end

        // Byte 1: partition0_len[10:3]
        S_TAG1:
        if (raw_valid) begin
          partition0_len[10:3] <= raw_data;
          state                <= S_TAG2;
        end

        // Byte 2: partition0_len[18:11]
        S_TAG2:
        if (raw_valid) begin
          partition0_len[18:11] <= raw_data;
          state                 <= S_START0;
        end

        S_START0: if (raw_valid) state <= S_START1;  // consume 0x9D
        S_START1: if (raw_valid) state <= S_START2;  // consume 0x01
        S_START2: if (raw_valid) state <= S_DIM0;  // consume 0x2A

        // Width low byte
        S_DIM0:
        if (raw_valid) begin
          raw_lo <= raw_data;
          state  <= S_DIM1;
        end

        // Width high nibble: [7:6]=h_scale, [5:0]=width[13:8]
        S_DIM1:
        if (raw_valid) begin
          ctx.h_scale  <= {6'b0, raw_data[7:6]};
          ctx.width    <= {2'b0, raw_data[5:0], raw_lo};
          ctx.mb_width <= shortint'(16'(
              {raw_data[5:0], raw_lo} + 14'd15) >> 4);
          state <= S_DIM2;
        end

        // Height low byte
        S_DIM2:
        if (raw_valid) begin
          raw_lo <= raw_data;
          state  <= S_DIM3;
        end

        // Height high nibble: [7:6]=v_scale, [5:0]=height[13:8]
        S_DIM3:
        if (raw_valid) begin
          ctx.v_scale   <= {6'b0, raw_data[7:6]};
          ctx.height    <= {2'b0, raw_data[5:0], raw_lo};
          ctx.mb_height <= shortint'(16'({raw_data[5:0], raw_lo} + 14'd15) >> 4);
          ctx.part1_off <= longint'(partition0_len) + 64'd10;
          state         <= S_BD_CS;
        end

        S_BD_CS: if (bd.data_valid && bd_req_pending) state <= S_BD_CLAMP;  // color_space: ignored

        S_BD_CLAMP: if (bd.data_valid && bd_req_pending) state <= S_BD_SEG;  // clamping: ignored

        S_BD_SEG:
        if (bd.data_valid && bd_req_pending)
          state <= S_BD_FTYPE;  // segmentation_enabled: i want to complete the project, ignored

        S_BD_FTYPE:
        if (bd.data_valid && bd_req_pending) begin
          // filter_type: consumed but not stored in ctx
          state   <= S_BD_LFLEVEL;
          bit_cnt <= 4'd6;
          bit_acc <= '0;
        end

        // loop_filter_level: 6 bits MSB first
        S_BD_LFLEVEL:
        if (bd.data_valid && bd_req_pending) begin
          bit_acc <= {bit_acc[6:0], bd.data};
          bit_cnt <= bit_cnt - 4'd1;
          if (bit_cnt == 4'd1) begin
            state   <= S_BD_SHARP;
            bit_cnt <= 4'd3;
            bit_acc <= '0;
          end
        end

        // sharpness_level: 3 bits MSB first
        S_BD_SHARP:
        if (bd.data_valid && bd_req_pending) begin
          bit_acc <= {bit_acc[6:0], bd.data};
          bit_cnt <= bit_cnt - 4'd1;
          if (bit_cnt == 4'd1) state <= S_BD_LFADJ;
        end

        // loop_filter_adj_enable: 1 bit
        S_BD_LFADJ:
        if (bd.data_valid && bd_req_pending) begin
          if (bd.data) begin
            // enabled read mode_ref_lf_delta_update flag next
            state <= S_BD_LFDELTA_UPD;
          end else begin
            // disabled skip all LF delta parsing
            state   <= S_BD_LOG2P;
            bit_cnt <= 4'd2;
            bit_acc <= '0;
          end
        end

        // mode_ref_lf_delta_update: 1 bit
        S_BD_LFDELTA_UPD:
        if (bd.data_valid && bd_req_pending) begin
          if (bd.data) begin
            lf_delta_idx <= 3'd0;
            state        <= S_BD_REFDELTA_F;
          end else begin
            // No delta updates
            state   <= S_BD_LOG2P;
            bit_cnt <= 4'd2;
            bit_acc <= '0;
          end
        end

        // ref_frame_delta_update_flag: 1 bit * 4
        S_BD_REFDELTA_F:
        if (bd.data_valid && bd_req_pending) begin
          if (bd.data) begin
            // Delta present: 6-bit magnitude + 1-bit sign
            state   <= S_BD_REFDELTA_V;
            bit_cnt <= 4'd7;
            bit_acc <= '0;
          end else begin
            // No delta for this ref; advance
            if (lf_delta_idx == 3'd3) begin
              lf_delta_idx <= 3'd0;
              state        <= S_BD_MODDELTA_F;
            end else lf_delta_idx <= lf_delta_idx + 3'd1;
          end
        end

        // ref delta value: 7 bits (magnitude 6 + sign 1), consumed not stored
        S_BD_REFDELTA_V:
        if (bd.data_valid && bd_req_pending) begin
          bit_acc <= {bit_acc[6:0], bd.data};
          bit_cnt <= bit_cnt - 4'd1;
          if (bit_cnt == 4'd1) begin
            if (lf_delta_idx == 3'd3) begin
              lf_delta_idx <= 3'd0;
              state        <= S_BD_MODDELTA_F;
            end else begin
              lf_delta_idx <= lf_delta_idx + 3'd1;
              state        <= S_BD_REFDELTA_F;
            end
          end
        end

        // mb_mode_delta_update_flag: 1 bit * 4
        S_BD_MODDELTA_F:
        if (bd.data_valid && bd_req_pending) begin
          if (bd.data) begin
            state   <= S_BD_MODDELTA_V;
            bit_cnt <= 4'd7;
            bit_acc <= '0;
          end else begin
            if (lf_delta_idx == 3'd3) begin
              state   <= S_BD_LOG2P;
              bit_cnt <= 4'd2;
              bit_acc <= '0;
            end else lf_delta_idx <= lf_delta_idx + 3'd1;
          end
        end

        // mode delta value: 7 bits (magnitude 6 + sign 1), consumed not stored
        S_BD_MODDELTA_V:
        if (bd.data_valid && bd_req_pending) begin
          bit_acc <= {bit_acc[6:0], bd.data};
          bit_cnt <= bit_cnt - 4'd1;
          if (bit_cnt == 4'd1) begin
            if (lf_delta_idx == 3'd3) begin
              state   <= S_BD_LOG2P;
              bit_cnt <= 4'd2;
              bit_acc <= '0;
            end else begin
              lf_delta_idx <= lf_delta_idx + 3'd1;
              state        <= S_BD_MODDELTA_F;
            end
          end
        end

        // log2_nbr_of_dct_partitions: 2 bits (value not stored in ctx)
        S_BD_LOG2P:
        if (bd.data_valid && bd_req_pending) begin
          bit_acc <= {bit_acc[6:0], bd.data};
          bit_cnt <= bit_cnt - 4'd1;
          if (bit_cnt == 4'd1) begin
            state   <= S_BD_YACQI;
            bit_cnt <= 4'd7;
            bit_acc <= '0;
          end
        end

        // yac_qi: 7 bits MSB first.
        S_BD_YACQI:
        if (bd.data_valid && bd_req_pending) begin
          bit_acc <= {bit_acc[6:0], bd.data};
          bit_cnt <= bit_cnt - 4'd1;
          if (bit_cnt == 4'd1) begin
            // {bit_acc[5:0], bd.data} = 7-bit yac_qi, MSB first.
            // bit_acc has had 6 shifts from 0 before this final bit arrives.
            yac_qi <= {bit_acc[5:0], bd.data};
            begin
              automatic int qi = int'({1'b0, bit_acc[5:0], bd.data});
              // Compute base quantizers; deltas will be added in QDELTA states.
              ctx.ydc  <= dc_quant(qi);
              ctx.yac  <= ac_quant(qi);
              ctx.y2dc <= shortint'(int'(dc_quant(qi)) * 2);
              ctx.y2ac <= shortint'((int'(ac_quant(qi)) * 155) / 100);
              ctx.uvdc <= dc_quant(qi);
              ctx.uvac <= ac_quant(qi);
            end
            qdelta_idx <= 3'd0;
            qdeltas    <= '{default: '0};
            state      <= S_BD_QDELTA_F;
          end
        end

        // Quantizer delta present flag: 1 bit * 5 fields.
        S_BD_QDELTA_F:
        if (bd.data_valid && bd_req_pending) begin
          if (bd.data) begin
            // Delta present: 4-bit magnitude + 1-bit sign
            state   <= S_BD_QDELTA_V;
            bit_cnt <= 4'd5;
            bit_acc <= '0;
          end else begin
            // No delta for this field; qdeltas[qdelta_idx] stays 0
            if (qdelta_idx == 3'd4) begin
              // All 5 flags done
              state <= S_BD_REFENTROPY;
              begin
                automatic int qi = int'({1'b0, yac_qi});
                ctx.ydc  <= dc_quant(qi + int'(qdeltas[0]));
                ctx.y2dc <= shortint'(int'(dc_quant(qi + int'(qdeltas[1]))) * 2);
                ctx.y2ac <= shortint'((int'(ac_quant(qi + int'(qdeltas[2]))) * 155) / 100);
                begin
                  automatic shortint uvdc_v = dc_quant(qi + int'(qdeltas[3]));
                  ctx.uvdc <= (uvdc_v < shortint'(8)) ? shortint'(8) : uvdc_v;
                end
                begin
                  automatic shortint uvac_v = ac_quant(qi + int'(qdeltas[4]));
                  ctx.uvac <= (uvac_v > shortint'(132)) ? shortint'(132) : uvac_v;
                end
                ctx.yac <= ac_quant(qi);  // yac base: no delta applied
              end
            end else qdelta_idx <= qdelta_idx + 3'd1;
          end
        end

        // Quantizer delta value: 4-bit magnitude MSB first, then 1-bit sign.
        S_BD_QDELTA_V:
        if (bd.data_valid && bd_req_pending) begin
          bit_acc <= {bit_acc[6:0], bd.data};
          bit_cnt <= bit_cnt - 4'd1;
          if (bit_cnt == 4'd1) begin
            //   bit_acc[3:0] = {mag[3], mag[2], mag[1], mag[0]}  (MSB first)
            //   bd.data      = sign
            begin
              automatic logic [3:0] mag = bit_acc[3:0];
              automatic logic       sgn = bd.data;
              qdeltas[qdelta_idx] <= sgn ? -(signed'({1'b0, mag})) : signed'({1'b0, mag});
            end

            if (qdelta_idx == 3'd4) begin
              // Last (5th) delta done apply all, then refresh_entropy
              state <= S_BD_REFENTROPY;
              begin
                automatic int qi = int'({1'b0, yac_qi});
                // Deltas 0-3 are already in qdeltas[]; delta 4 computed here.
                automatic logic [3:0] mag4 = bit_acc[3:0];
                automatic logic sgn4 = bd.data;
                automatic
                logic signed [4:0]
                d4 = sgn4 ? -(signed'({1'b0, mag4})) : signed'({1'b0, mag4});

                ctx.ydc  <= dc_quant(qi + int'(qdeltas[0]));
                ctx.y2dc <= shortint'(int'(dc_quant(qi + int'(qdeltas[1]))) * 2);
                ctx.y2ac <= shortint'((int'(ac_quant(qi + int'(qdeltas[2]))) * 155) / 100);
                begin
                  automatic shortint uvdc_v = dc_quant(qi + int'(qdeltas[3]));
                  ctx.uvdc <= (uvdc_v < shortint'(8)) ? shortint'(8) : uvdc_v;
                end
                begin
                  automatic shortint uvac_v = ac_quant(qi + int'(d4));
                  ctx.uvac <= (uvac_v > shortint'(132)) ? shortint'(132) : uvac_v;
                end
                ctx.yac <= ac_quant(qi);
              end
            end else begin
              qdelta_idx <= qdelta_idx + 3'd1;
              state      <= S_BD_QDELTA_F;
            end
          end
        end

        // refresh_entropy_probs: 1 bit (always 1 for keyframes; value ignored)
        S_BD_REFENTROPY:
        if (bd.data_valid && bd_req_pending) begin
          cp_plane        <= 2'd0;
          cp_band         <= 3'd0;
          cp_ctx          <= 2'd0;
          cp_tok          <= 4'd0;
          cp_reading_prob <= 1'b0;
          state           <= S_BD_COEFFPROB;
        end

        S_BD_COEFFPROB:
        if (bd.data_valid && bd_req_pending) begin

          if (!cp_reading_prob) begin
            // update flag arrived
            if (bd.data) begin
              // Flag=1: read 8-bit probability value next
              cp_reading_prob <= 1'b1;
              bit_cnt         <= 4'd8;
              bit_acc         <= '0;
            end else begin
              // Flag=0: keep default probability, advance indices
              if (cp_tok == 4'd10) begin
                cp_tok <= 4'd0;
                if (cp_ctx == 2'd2) begin
                  cp_ctx <= 2'd0;
                  if (cp_band == 3'd7) begin
                    cp_band <= 3'd0;
                    if (cp_plane == 2'd3) state <= S_BD_NOSKIP;  // loop complete
                    else cp_plane <= cp_plane + 2'd1;
                  end else cp_band <= cp_band + 3'd1;
                end else cp_ctx <= cp_ctx + 2'd1;
              end else cp_tok <= cp_tok + 4'd1;
            end

          end else begin
            // accumulating 8-bit probability, MSB first
            bit_acc <= {bit_acc[6:0], bd.data};
            bit_cnt <= bit_cnt - 4'd1;
            if (bit_cnt == 4'd1) begin
              // All 8 bits received: {bit_acc[6:0], bd.data}
              ctx.coeff_probs[cp_plane][cp_band][cp_ctx][cp_tok] <= {bit_acc[6:0], bd.data};
              cp_reading_prob <= 1'b0;
              // Advance
              if (cp_tok == 4'd10) begin
                cp_tok <= 4'd0;
                if (cp_ctx == 2'd2) begin
                  cp_ctx <= 2'd0;
                  if (cp_band == 3'd7) begin
                    cp_band <= 3'd0;
                    if (cp_plane == 2'd3) state <= S_BD_NOSKIP;
                    else cp_plane <= cp_plane + 2'd1;
                  end else cp_band <= cp_band + 3'd1;
                end else cp_ctx <= cp_ctx + 2'd1;
              end else cp_tok <= cp_tok + 4'd1;
            end
          end
        end

        // mb_no_skip_coeff: 1 bit
        S_BD_NOSKIP:
        if (bd.data_valid && bd_req_pending) begin
          ctx.mb_no_skip_coeff <= bd.data;
          if (bd.data) begin
            // prob_skip_false follows
            state   <= S_BD_PROBSKIP;
            bit_cnt <= 4'd8;
            bit_acc <= '0;
          end else begin
            ctx.prob_skip_false <= 8'd0;
            ctx.valid           <= 1'b1;
            done_r              <= 1'b1;
            state               <= S_DONE;
          end
        end

        // prob_skip_false: 8 bits MSB first
        S_BD_PROBSKIP:
        if (bd.data_valid && bd_req_pending) begin
          bit_acc <= {bit_acc[6:0], bd.data};
          bit_cnt <= bit_cnt - 4'd1;
          if (bit_cnt == 4'd1) begin
            ctx.prob_skip_false <= {bit_acc[6:0], bd.data};
            ctx.valid           <= 1'b1;
            done_r              <= 1'b1;
            state               <= S_DONE;
          end
        end

        S_DONE: done_r <= 1'b0;

        default: state <= S_TAG0;

      endcase
    end
  end

endmodule

module FrameParserTest (
    input var logic clk,
    input var logic rst,

    input var  byte unsigned raw_data,
    input var  logic         raw_valid,
    output var logic         raw_ready,

    output var logic       bd_valid,
    output var logic [7:0] bd_prob,
    input var  logic       bd_ready,
    input var  logic       bd_data_valid,
    output var logic       bd_data_ready,
    input var  logic       bd_data,

    output var logic        ctx_valid,
    output var logic [63:0] ctx_part1_off,
    output var logic [15:0] ctx_width,
    output var logic [15:0] ctx_height,
    output var logic [ 7:0] ctx_h_scale,
    output var logic [ 7:0] ctx_v_scale,
    output var logic [15:0] ctx_mb_width,
    output var logic [15:0] ctx_mb_height,
    output var logic [15:0] ctx_ydc,
    output var logic [15:0] ctx_yac,
    output var logic [15:0] ctx_y2dc,
    output var logic [15:0] ctx_y2ac,
    output var logic [15:0] ctx_uvdc,
    output var logic [15:0] ctx_uvac,
    output var logic        ctx_mb_no_skip_coeff,
    output var logic [ 7:0] ctx_prob_skip_false,

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

  always_comb begin
    ctx_valid            = ctx.valid;
    ctx_part1_off        = ctx.part1_off[63:0];
    ctx_width            = ctx.width;
    ctx_height           = ctx.height;
    ctx_h_scale          = ctx.h_scale;
    ctx_v_scale          = ctx.v_scale;
    ctx_mb_width         = ctx.mb_width;
    ctx_mb_height        = ctx.mb_height;
    ctx_ydc              = ctx.ydc;
    ctx_yac              = ctx.yac;
    ctx_y2dc             = ctx.y2dc;
    ctx_y2ac             = ctx.y2ac;
    ctx_uvdc             = ctx.uvdc;
    ctx_uvac             = ctx.uvac;
    ctx_mb_no_skip_coeff = ctx.mb_no_skip_coeff;
    ctx_prob_skip_false  = ctx.prob_skip_false;
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
