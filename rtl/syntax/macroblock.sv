// Macroblock header types and parser for VP8 keyframes.
//
// MacroblockHeaderParser decodes prediction mode syntax from the part0
// boolean-coded partition for a single macroblock. It is driven
// sequentially by the parent (one MB at a time).
//
// Inputs:
//   bd            - BoolDecoder interface (user modport)
//   frame_ctx     - fully-populated FrameCtx (valid must be 1)
//   left_header   - header of MB to the left  (left_valid = 0 on leftmost)
//   above_header  - header of MB above        (above_valid = 0 on top row)
//   x, y          - current macroblock column / row
//
// Outputs:
//   header        - decoded MacroblockHeader
//   valid         - pulses high for one cycle when header is ready
//
// Tree-walk helper:
//   All VP8 binary-tree reads are implemented as a shared mini-FSM that
//   issues one bd.read_bool per step and walks through the constant tree
//   arrays until it reaches a leaf (negative entry).

module MacroblockHeaderParser
  import MacroblockHeaderPkg::*;
  import Frame::*;
(
    input var logic clk,
    input var logic rst,

    BoolDecoderIf.user bd,

    input var Frame::FrameCtx                       frame_ctx,
    input var MacroblockHeaderPkg::MacroblockHeader left_header,
    input var logic                                 left_valid,
    input var MacroblockHeaderPkg::MacroblockHeader above_header,
    input var logic                                 above_valid,

    input var  byte unsigned                         x,
    input var  byte unsigned                         y,
    output var MacroblockHeaderPkg::MacroblockHeader header,
    output var logic                                 valid,
    input var  logic                                 ready
);

  // -------------------------------------------------------------------------
  // Helper: extract effective IntraBMode for a neighbour MB
  // -------------------------------------------------------------------------
  function automatic IntraBMode mb_to_bmode(
      input MacroblockHeaderPkg::MacroblockHeader h
  );
    case (h.intra_y_mode)
      IntraMBMode_DcPred: mb_to_bmode = IntraBMode_BDcPred;
      IntraMBMode_VPred:  mb_to_bmode = IntraBMode_BVePred;
      IntraMBMode_HPred:  mb_to_bmode = IntraBMode_BHePred;
      IntraMBMode_TmPred: mb_to_bmode = IntraBMode_BTmPred;
      default:            mb_to_bmode = IntraBMode_BDcPred;
    endcase
  endfunction

  // -------------------------------------------------------------------------
  // Tree-walk shared logic
  //
  // tree_data  - current signed byte being examined
  // tree_node  - signed index into whichever tree we're walking
  // -------------------------------------------------------------------------

  typedef enum logic [6-1:0] {
    S_Idle          = 6'd1,
    S_SkipCoeff     = 6'd2,    // read mb_skip_coeff
    S_WalkYMode     = 6'd4,    // tree-walk KF_YMODE_TREE
    S_StartBMode    = 6'd8,    // set up 4×4 BMode loop
    S_WalkBMode     = 6'd16,   // tree-walk BMODE_TREE for one sub-block
    S_WalkUVMode    = 6'd32,   // tree-walk UV_MODE_TREE
    S_Out           = 6'd33
  } State;

  State state;

  // Tree-walk state
  logic signed [7:0] tree_node;   // current node index (signed)
  logic              bd_req_pend; // waiting for bd to accept our request
  logic              bd_result;   // latched bd.data

  // BMode loop counters
  logic [1:0] bm_y;    // sub-row  (0-3)
  logic [1:0] bm_x;    // sub-col  (0-3)

  // Context modes for BMode
  IntraBMode ctx_a;    // mode from above sub-block
  IntraBMode ctx_l;    // mode from left sub-block

  // Tree selection (combinational)
  // Returns the signed byte at current node for whichever tree is active
  function automatic byte signed tree_byte(
      input State   s,
      input logic signed [7:0] node
  );
    case (s)
      S_WalkYMode:  tree_byte = KF_YMODE_TREE[node[2:0]];
      S_WalkBMode:  tree_byte = BMODE_TREE   [node[4:0]];
      S_WalkUVMode: tree_byte = UV_MODE_TREE [node[2:0]];
      default:      tree_byte = -1;
    endcase
  endfunction

  function automatic byte unsigned prob_for_node(
      input State                s,
      input logic signed [7:0]   node,
      input IntraBMode           above,
      input IntraBMode           left
  );
    case (s)
      S_WalkYMode:  prob_for_node = KF_YMODE_PROB[node[2:0] >> 1];
      S_WalkUVMode: prob_for_node = KF_UV_MODE_PROB[node[2:0] >> 1];
      S_WalkBMode:  prob_for_node = Tables::KF_BMODE_PROB[above][left][node[3:0] >> 1];
      default:      prob_for_node = 8'd128;
    endcase
  endfunction

  // -------------------------------------------------------------------------
  // Combinational output
  // -------------------------------------------------------------------------
  always_comb begin
    bd.valid      = 1'b0;
    bd.prob       = 8'd128;
    bd.data_ready = 1'b0;
    valid         = 1'b0;

    case (state)
      S_Idle: ;

      S_SkipCoeff: begin
        bd.prob       = frame_ctx.prob_skip_false;
        bd.data_ready = !bd_req_pend;
        if (!bd_req_pend) bd.valid = 1'b1;
      end

      S_WalkYMode, S_WalkBMode, S_WalkUVMode: begin
        bd.prob       = prob_for_node(state, tree_node, ctx_a, ctx_l);
        bd.data_ready = !bd_req_pend;
        if (!bd_req_pend && tree_byte(state, tree_node) >= 0)
          bd.valid = 1'b1;
      end

      S_StartBMode: ;

      S_Out: begin
        valid = 1'b1;
      end

      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // Sequential FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      state       <= S_Idle;
      header      <= '{default: 0};
      tree_node   <= '0;
      bd_req_pend <= 1'b0;
      bd_result   <= 1'b0;
      bm_y        <= '0;
      bm_x        <= '0;
      ctx_a       <= IntraBMode_BDcPred;
      ctx_l       <= IntraBMode_BDcPred;
    end else begin

      // Track bd request lifetime
      if (bd.valid && bd.ready)   bd_req_pend <= 1'b1;
      if (bd.data_valid && bd_req_pend) begin
        bd_result   <= bd.data;
        bd_req_pend <= 1'b0;
      end

      case (state)
        // ------------------------------------------------------------------
        S_Idle: begin
          if (frame_ctx.valid) begin
            header      <= '{default: 0};
            state       <= S_SkipCoeff;
            bd_req_pend <= 1'b0;
          end
        end

        // ------------------------------------------------------------------
        // mb_skip_coeff
        // ------------------------------------------------------------------
        S_SkipCoeff: begin
          if (bd.data_valid && bd_req_pend) begin
            header.mb_skip_coeff <= bd_result;
            // Start Y-mode tree walk
            state     <= S_WalkYMode;
            tree_node <= 8'sd0;
          end
        end

        // ------------------------------------------------------------------
        // Y-mode tree walk
        // ------------------------------------------------------------------
        S_WalkYMode: begin
          automatic byte signed cur;
          cur = tree_byte(S_WalkYMode, tree_node);

          if (cur < 0) begin
            // Leaf - extract mode
            header.intra_y_mode <= IntraMBMode'(-cur);
            if (IntraMBMode'(-cur) == IntraMBMode_BPred) begin
              state <= S_StartBMode;
            end else begin
              // Start UV-mode walk
              state     <= S_WalkUVMode;
              tree_node <= 8'sd0;
            end
          end else if (bd.data_valid && bd_req_pend) begin
            // Non-leaf: advance node by result (0->left, 1->right = node+1)
            tree_node <= signed'(8'(cur)) + signed'(8'(bd_result));
          end
        end

        // ------------------------------------------------------------------
        // Prepare BMode 4×4 loop
        // ------------------------------------------------------------------
        S_StartBMode: begin
          bm_y  <= '0;
          bm_x  <= '0;
          // ctx_a for (0,0): above MB's sub_modes[3][0] or mb_to_bmode
          ctx_a <= above_valid ?
                     (above_header.intra_y_mode == IntraMBMode_BPred ?
                       above_header.sub_modes[3][0] :
                       mb_to_bmode(above_header)) :
                     IntraBMode_BDcPred;
          ctx_l <= left_valid ?
                     (left_header.intra_y_mode == IntraMBMode_BPred ?
                       left_header.sub_modes[0][3] :
                       mb_to_bmode(left_header)) :
                     IntraBMode_BDcPred;
          state     <= S_WalkBMode;
          tree_node <= 8'sd0;
        end

        // ------------------------------------------------------------------
        // BMode tree walk - one sub-block at a time
        // ------------------------------------------------------------------
        S_WalkBMode: begin
          automatic byte signed cur;
          cur = tree_byte(S_WalkBMode, tree_node);

          if (cur < 0) begin
            // Leaf - store sub-mode
            header.sub_modes[bm_y][bm_x] <= IntraBMode'(-cur);

            // Advance loop counters
            if (bm_x == 3) begin
              bm_x <= '0;
              if (bm_y == 3) begin
                // All 16 sub-blocks done -> UV mode
                state     <= S_WalkUVMode;
                tree_node <= 8'sd0;
              end else begin
                bm_y <= bm_y + 1'b1;
                // Update ctx_a: row boundary -> fetch from above MB or this MB
                ctx_a <= (bm_y == 0) ?
                           (above_valid ?
                              (above_header.intra_y_mode == IntraMBMode_BPred ?
                                above_header.sub_modes[3][0] :
                                mb_to_bmode(above_header)) :
                              IntraBMode_BDcPred) :
                           header.sub_modes[bm_y][0];    // same col, prev row
                ctx_l <= left_valid ?
                           (left_header.intra_y_mode == IntraMBMode_BPred ?
                             left_header.sub_modes[bm_y+1][3] :
                             mb_to_bmode(left_header)) :
                           IntraBMode_BDcPred;
                tree_node <= 8'sd0;
              end
            end else begin
              // Same row, advance column
              bm_x <= bm_x + 1'b1;
              // ctx_a from same row, prev column's sub_mode (just written)
              ctx_a <= header.sub_modes[bm_y][bm_x];  // bm_x is current (pre-increment)
              ctx_l <= IntraBMode'(-cur);              // just-decoded mode is now left context
              tree_node <= 8'sd0;
            end
          end else if (bd.data_valid && bd_req_pend) begin
            tree_node <= signed'(8'(cur)) + signed'(8'(bd_result));
          end
        end

        // ------------------------------------------------------------------
        // UV-mode tree walk
        // ------------------------------------------------------------------
        S_WalkUVMode: begin
          automatic byte signed cur;
          cur = tree_byte(S_WalkUVMode, tree_node);

          if (cur < 0) begin
            header.intra_uv_mode <= IntraMBMode'(-cur);
            header.valid         <= 1'b1;
            state                <= S_Out;
          end else if (bd.data_valid && bd_req_pend) begin
            tree_node <= signed'(8'(cur)) + signed'(8'(bd_result));
          end
        end

        // ------------------------------------------------------------------
        // Output
        // ------------------------------------------------------------------
        S_Out: begin
          if (ready) begin
            header.valid <= 1'b0;
            state        <= S_Idle;
          end
        end

        default: state <= S_Idle;
      endcase
    end
  end

endmodule

// ---------------------------------------------------------------------------
// Test wrapper (flat ports for cocotb)
// ---------------------------------------------------------------------------
module MacroblockParserTest
  import MacroblockHeaderPkg::*;
  import Frame::*;
(
    input var logic clk,
    input var logic rst,

    // BD flat ports
    input var  logic         bd_ready,
    input var  logic         bd_data_valid,
    input var  logic         bd_data,
    output var logic         bd_valid,
    output var logic [7:0]   bd_prob,
    output var logic         bd_data_ready,

    input var Frame::FrameCtx                       frame_ctx,
    input var MacroblockHeaderPkg::MacroblockHeader left_header,
    input var logic                                 left_valid,
    input var MacroblockHeaderPkg::MacroblockHeader above_header,
    input var logic                                 above_valid,
    input var byte unsigned                         x,
    input var byte unsigned                         y,
    input var logic                                 parser_ready,

    output var MacroblockHeaderPkg::MacroblockHeader header,
    output var logic                                 valid
);
  BoolDecoderIf bd ();

  always_comb begin
    bd_valid          = bd.valid;
    bd_prob           = bd.prob;
    bd.ready          = bd_ready;
    bd.data_valid     = bd_data_valid;
    bd_data_ready     = bd.data_ready;
    bd.data           = bd_data;
  end

  MacroblockHeaderParser parser (
      .clk         (clk),
      .rst         (rst),
      .bd          (bd),
      .frame_ctx   (frame_ctx),
      .left_header (left_header),
      .left_valid  (left_valid),
      .above_header(above_header),
      .above_valid (above_valid),
      .x           (x),
      .y           (y),
      .header      (header),
      .valid       (valid),
      .ready       (parser_ready)
  );
endmodule

`ifdef __veryl_test_test_macroblock_parser__
`ifdef __veryl_wavedump_test_macroblock_parser__
module __veryl_wavedump;
  initial begin
    $dumpfile("test_macroblock_parser.vcd");
    $dumpvars();
  end
endmodule
`endif

`endif
//# sourceMappingURL=macroblock.sv.map
