import Macroblock::*;
import Frame::*;

module HeaderParser (
    input var logic clk,
    input var logic rst,

    BoolDecoderIf.user bd,

    input var Frame::FrameCtx    frame_ctx,
    input var Macroblock::Header left_header,
    input var logic              left_valid,
    input var Macroblock::Header above_header,
    input var logic              above_valid,

    input var  byte unsigned      x,
    input var  byte unsigned      y,
    output var Macroblock::Header header,
    output var logic              valid,
    input var  logic              ready
);

  // mb_to_bmode: convert a non-BPred MB mode to an equivalent IntraBMode
  function automatic Macroblock::IntraBMode mb_to_bmode(input Macroblock::Header h);
    case (h.intra_y_mode)
      IntraMBMode_DcPred: mb_to_bmode = IntraBMode_BDcPred;
      IntraMBMode_VPred:  mb_to_bmode = IntraBMode_BVePred;
      IntraMBMode_HPred:  mb_to_bmode = IntraBMode_BHePred;
      IntraMBMode_TmPred: mb_to_bmode = IntraBMode_BTmPred;
      default:            mb_to_bmode = IntraBMode_BDcPred;
    endcase
  endfunction

  typedef enum logic [6:0] {
    S_IDLE        = 7'd1,
    S_SKIP_COEFF  = 7'd2,
    S_WALK_YMODE  = 7'd4,
    S_SETUP_BMODE = 7'd8,   // compute ctx_a, ctx_l for current [bm_y][bm_x]
    S_WALK_BMODE  = 7'd16,
    S_WALK_UVMODE = 7'd32,
    S_OUT         = 7'd64
  } State;

  State                        state;

  // Tree walk
  logic signed           [7:0] tree_node;
  logic                        bd_req_pend;

  // BMode counters
  logic                  [1:0] bm_y;
  logic                  [1:0] bm_x;

  // BMode context for current sub-mode walk
  Macroblock::IntraBMode       ctx_a;
  Macroblock::IntraBMode       ctx_l;

  // prob_for_node lookup
  function automatic byte unsigned prob_for_node(input State s, input logic signed [7:0] node,
                                                 input Macroblock::IntraBMode above,
                                                 input Macroblock::IntraBMode left);

    logic [1:0] ymode_idx;
    logic [1:0] uvmode_idx;
    logic [3:0] bmode_idx;

    ymode_idx  = 2'(node[2:0] >> 1);
    uvmode_idx = 2'(node[2:0] >> 1);
    bmode_idx  = 4'(node[4:0] >> 1);

    case (s)
      S_WALK_YMODE:  prob_for_node = KF_YMODE_PROB[ymode_idx];
      S_WALK_UVMODE: prob_for_node = KF_UV_MODE_PROB[uvmode_idx];
      S_WALK_BMODE:  prob_for_node = Tables::KF_BMODE_PROB[above][left][bmode_idx];
      default:       prob_for_node = 8'd128;
    endcase
  endfunction

  always_comb begin
    bd.valid      = 1'b0;
    bd.prob       = 8'd128;
    bd.data_ready = 1'b0;
    valid         = 1'b0;

    case (state)
      S_IDLE: ;

      S_SKIP_COEFF: begin
        bd.prob       = frame_ctx.prob_skip_false;
        bd.data_ready = 1'b1;
        if (!bd_req_pend) bd.valid = 1'b1;
      end

      S_WALK_YMODE, S_WALK_BMODE, S_WALK_UVMODE: begin
        bd.prob       = prob_for_node(state, tree_node, ctx_a, ctx_l);
        bd.data_ready = 1'b1;
        if (!bd_req_pend) bd.valid = 1'b1;
      end

      S_SETUP_BMODE: ;

      S_OUT: valid = 1'b1;

      default: ;
    endcase
  end

  // FSM
  always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
      state       <= S_IDLE;
      header      <= '0;
      tree_node   <= '0;
      bd_req_pend <= 1'b0;
      bm_y        <= '0;
      bm_x        <= '0;
      ctx_a       <= IntraBMode_BDcPred;
      ctx_l       <= IntraBMode_BDcPred;
    end else begin

      // BD request tracking
      if (bd.valid && bd.ready) bd_req_pend <= 1'b1;
      if (bd.data_valid && bd_req_pend) bd_req_pend <= 1'b0;

      case (state)

        S_IDLE: begin
          if (frame_ctx.valid) begin
            header      <= '0;
            bd_req_pend <= 1'b0;
            state       <= S_SKIP_COEFF;
          end
        end

        // skip_coeff: 1 bit, prob = prob_skip_false
        S_SKIP_COEFF: begin
          if (bd.data_valid && bd_req_pend) begin
            header.mb_skip_coeff <= bd.data;
            tree_node            <= 8'sd0;
            state                <= S_WALK_YMODE;
          end
        end

        // ymode tree walk KF_YMODE_TREE / KF_YMODE_PROB
        S_WALK_YMODE: begin
          if (bd.data_valid && bd_req_pend) begin
            automatic byte signed child;
            child = KF_YMODE_TREE[tree_node[2:0]+{2'b0, bd.data}];
            if (child <= 0) begin
              header.intra_y_mode <= Macroblock::IntraMBMode'(-child);
              if (Macroblock::IntraMBMode'(-child) == IntraMBMode_BPred) begin
                // Start BPred sub-mode parse
                bm_y  <= 2'd0;
                bm_x  <= 2'd0;
                state <= S_SETUP_BMODE;
              end else begin
                tree_node <= 8'sd0;
                state     <= S_WALK_UVMODE;
              end
            end else begin
              tree_node <= child;
            end
          end
        end

        S_SETUP_BMODE: begin
          // ctx_a
          if (bm_y > 0) begin
            ctx_a <= header.sub_modes[bm_y-1][bm_x];
          end else begin
            // bm_y == 0: use above MB
            if (above_valid) begin
              if (above_header.intra_y_mode == IntraMBMode_BPred)
                ctx_a <= above_header.sub_modes[3][bm_x];
              else ctx_a <= mb_to_bmode(above_header);
            end else begin
              ctx_a <= IntraBMode_BDcPred;
            end
          end

          // ctx_l
          if (bm_x > 0) begin
            ctx_l <= header.sub_modes[bm_y][bm_x-1];
          end else begin
            // bm_x == 0: use left MB
            if (left_valid) begin
              if (left_header.intra_y_mode == IntraMBMode_BPred)
                ctx_l <= left_header.sub_modes[bm_y][3];
              else ctx_l <= mb_to_bmode(left_header);
            end else begin
              ctx_l <= IntraBMode_BDcPred;
            end
          end

          tree_node <= 8'sd0;
          state     <= S_WALK_BMODE;
        end

        // bmode tree walk BMODE_TREE / KF_BMODE_PROB[ctx_a][ctx_l]
        S_WALK_BMODE: begin
          if (bd.data_valid && bd_req_pend) begin
            automatic byte signed child;
            child = BMODE_TREE[tree_node[4:0]+{4'b0, bd.data}];
            if (child <= 0) begin
              // Leaf reached store decoded sub-mode
              header.sub_modes[bm_y][bm_x] <= Macroblock::IntraBMode'(-child);

              // Advance to next sub-mode or finish
              if (bm_x == 2'd3) begin
                bm_x <= 2'd0;
                if (bm_y == 2'd3) begin
                  // All 16 sub-modes done move to uvmode
                  tree_node <= 8'sd0;
                  state     <= S_WALK_UVMODE;
                end else begin
                  bm_y  <= bm_y + 2'd1;
                  state <= S_SETUP_BMODE;
                end
              end else begin
                bm_x  <= bm_x + 2'd1;
                state <= S_SETUP_BMODE;
              end
            end else begin
              tree_node <= child;
            end
          end
        end

        // uvmode tree walk UV_MODE_TREE / KF_UV_MODE_PROB
        S_WALK_UVMODE: begin
          if (bd.data_valid && bd_req_pend) begin
            automatic byte signed child;
            child = UV_MODE_TREE[tree_node[2:0]+{2'b0, bd.data}];
            if (child <= 0) begin
              header.intra_uv_mode <= Macroblock::IntraMBMode'(-child);
              header.valid         <= 1'b1;
              state                <= S_OUT;
            end else begin
              tree_node <= child;
            end
          end
        end

        S_OUT: begin
          if (ready) begin
            header.valid <= 1'b0;
            state        <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule


// Test wrapper
module MacroblockParserTest (
    input var logic clk,
    input var logic rst,

    input var  logic       bd_ready,
    input var  logic       bd_data_valid,
    input var  logic       bd_data,
    output var logic       bd_valid,
    output var logic [7:0] bd_prob,
    output var logic       bd_data_ready,

    input var logic        frame_ctx_valid,
    input var logic [63:0] frame_ctx_part1_off,
    input var logic [15:0] frame_ctx_width,
    input var logic [15:0] frame_ctx_height,
    input var logic [ 7:0] frame_ctx_h_scale,
    input var logic [ 7:0] frame_ctx_v_scale,
    input var logic [15:0] frame_ctx_mb_width,
    input var logic [15:0] frame_ctx_mb_height,
    input var logic [15:0] frame_ctx_ydc,
    input var logic [15:0] frame_ctx_yac,
    input var logic [15:0] frame_ctx_y2dc,
    input var logic [15:0] frame_ctx_y2ac,
    input var logic [15:0] frame_ctx_uvdc,
    input var logic [15:0] frame_ctx_uvac,
    input var logic        frame_ctx_mb_no_skip_coeff,
    input var logic [ 7:0] frame_ctx_prob_skip_false,

    input var logic [71:0] left_header,
    input var logic        left_valid,
    input var logic [71:0] above_header,
    input var logic        above_valid,

    input var byte unsigned x,
    input var byte unsigned y,
    input var logic         parser_ready,

    output var logic       header_valid,
    output var logic       header_mb_skip_coeff,
    output var logic [2:0] header_intra_y_mode,
    output var logic [2:0] header_intra_uv_mode,
    output var logic [3:0] header_sub_modes    [0:3][0:3],
    output var logic       valid,

    // Diagnostic
    output var logic [6:0] state_out
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

  // Reassemble frame_ctx
  Frame::FrameCtx frame_ctx;
  always_comb begin
    frame_ctx.valid            = frame_ctx_valid;
    frame_ctx.part1_off        = frame_ctx_part1_off;
    frame_ctx.width            = frame_ctx_width;
    frame_ctx.height           = frame_ctx_height;
    frame_ctx.h_scale          = frame_ctx_h_scale;
    frame_ctx.v_scale          = frame_ctx_v_scale;
    frame_ctx.mb_width         = frame_ctx_mb_width;
    frame_ctx.mb_height        = frame_ctx_mb_height;
    frame_ctx.ydc              = signed'(frame_ctx_ydc);
    frame_ctx.yac              = signed'(frame_ctx_yac);
    frame_ctx.y2dc             = signed'(frame_ctx_y2dc);
    frame_ctx.y2ac             = signed'(frame_ctx_y2ac);
    frame_ctx.uvdc             = signed'(frame_ctx_uvdc);
    frame_ctx.uvac             = signed'(frame_ctx_uvac);
    frame_ctx.mb_no_skip_coeff = frame_ctx_mb_no_skip_coeff;
    frame_ctx.prob_skip_false  = frame_ctx_prob_skip_false;
    frame_ctx.coeff_probs      = Tables::DEFAULT_COEFF_PROBS;
  end

  Macroblock::Header left_hdr_s;
  Macroblock::Header above_hdr_s;

  always_comb begin
    left_hdr_s.valid         = left_header[71];
    left_hdr_s.mb_skip_coeff = left_header[70];
    left_hdr_s.intra_y_mode  = Macroblock::IntraMBMode'(left_header[69:67]);
    left_hdr_s.intra_uv_mode = Macroblock::IntraMBMode'(left_header[66:64]);
    for (int iy = 0; iy < 4; iy++)
    for (int ix = 0; ix < 4; ix++)
    left_hdr_s.sub_modes[iy][ix] = Macroblock::IntraBMode'(left_header[63-(iy*4+ix)*4-:4]);

    above_hdr_s.valid         = above_header[71];
    above_hdr_s.mb_skip_coeff = above_header[70];
    above_hdr_s.intra_y_mode  = Macroblock::IntraMBMode'(above_header[69:67]);
    above_hdr_s.intra_uv_mode = Macroblock::IntraMBMode'(above_header[66:64]);
    for (int iy = 0; iy < 4; iy++)
    for (int ix = 0; ix < 4; ix++)
    above_hdr_s.sub_modes[iy][ix] = Macroblock::IntraBMode'(above_header[63-(iy*4+ix)*4-:4]);
  end

  Macroblock::Header header_s;

  HeaderParser parser (
      .clk         (clk),
      .rst         (rst),
      .bd          (bd),
      .frame_ctx   (frame_ctx),
      .left_header (left_hdr_s),
      .left_valid  (left_valid),
      .above_header(above_hdr_s),
      .above_valid (above_valid),
      .x           (x),
      .y           (y),
      .header      (header_s),
      .valid       (valid),
      .ready       (parser_ready)
  );

  always_comb begin
    header_valid         = header_s.valid;
    header_mb_skip_coeff = header_s.mb_skip_coeff;
    header_intra_y_mode  = 3'(header_s.intra_y_mode);
    header_intra_uv_mode = 3'(header_s.intra_uv_mode);
    for (int iy = 0; iy < 4; iy++)
    for (int ix = 0; ix < 4; ix++) header_sub_modes[iy][ix] = 4'(header_s.sub_modes[iy][ix]);
  end

  assign state_out = parser.state;

endmodule
