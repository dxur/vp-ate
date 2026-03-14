// TokenDecoder - decodes one 4×4 block of VP8 DCT coefficients.
//
// Protocol:
//   Caller presents plane/complexity/first_coeff/dcq/acq *before* asserting
//   start. The module pulls bits from bd (BoolDecoderIf.user) until done,
//   then asserts coeff_valid for one cycle. Caller must de-assert start
//   before asserting it again.
//
// Outputs:
//   coeffs[16]  - dequantized coefficients in raster order (signed 16-bit)
//   has_coeff   - 1 if any non-zero coefficient was produced

module TokenDecoder
  import MacroblockHeaderPkg::*;
(
    input var logic clk,
    input var logic rst,

    BoolDecoderIf.user bd,

    // Configuration (stable while start is asserted)
    input var logic [1:0]        plane,       // 0=Y_ac, 1=Y2, 2=UV, 3=Y_dc+ac
    input var logic [1:0]        complexity,  // neighbour context 0-2
    input var logic              first_coeff, // 0 normally, 1 when Y with Y2 present
    input var shortint signed    dcq,
    input var shortint signed    acq,
    input var Frame::FrameCtx    frame_ctx,

    input var  logic             start,
    output var logic             busy,

    output var shortint signed   coeffs[0:15],
    output var logic             has_coeff,
    output var logic             coeff_valid  // pulses 1 cycle
);

  // -------------------------------------------------------------------------
  // Constant local tables (mirrors Rust macroblock.rs)
  // -------------------------------------------------------------------------
  localparam byte unsigned COEFF_BANDS[0:15] = '{0,1,2,3,6,4,5,6,6,6,6,6,6,6,6,7};
  localparam byte unsigned ZIGZAG[0:15]      = '{0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15};

  // DCT coefficient tree (with EOB).
  // Leaf encoding: -(token + 1), so token=0 -> -1, token=11 (EOB) -> -12.
  // This avoids the zero-ambiguity: every leaf is strictly < 0.
  // Branch entries are positive node indices as usual.
  localparam byte signed CT[0:21] = '{
    -8'sd12,  8'sd2,        // node 0: EOB (token 11 -> -12)
    -8'sd1,   8'sd4,        // node 2: Dct0 (token  0 -> -1)
    -8'sd2,   8'sd6,        // node 4: Dct1 (token  1 -> -2)
     8'sd8,   8'sd12,       // node 6: branch
    -8'sd3,   8'sd10,       // node 8: Dct2 (token  2 -> -3)
    -8'sd4,   -8'sd5,       // node 10: Dct3 (-4), Dct4 (-5)
    -8'sd6,   8'sd14,       // node 12: DctCat1 (token 5 -> -6)
    -8'sd7,   8'sd16,       // node 14: DctCat2 (token 6 -> -7)
    -8'sd8,   8'sd18,       // node 16: DctCat3 (token 7 -> -8)
    -8'sd9,   8'sd20,       // node 18: DctCat4 (token 8 -> -9)
    -8'sd10,  -8'sd11       // node 20: DctCat5 (-10), DctCat6 (-11)
  };

  // COEFF_TREE_NOEOB: same tree without the first pair (no EOB branch).
  // Node indices are shifted down by 2 vs CT; same -(token+1) leaf encoding.
  // Prob index = (node >> 1) + 1  (to account for the removed first decision).
  localparam byte signed CTNOEOB[0:19] = '{
    -8'sd1,   8'sd2,        // node 0: Dct0 (token  0 -> -1)
    -8'sd2,   8'sd4,        // node 2: Dct1 (token  1 -> -2)
     8'sd6,   8'sd10,       // node 4: branch
    -8'sd3,   8'sd8,        // node 6: Dct2 (token  2 -> -3)
    -8'sd4,   -8'sd5,       // node 8: Dct3 (-4), Dct4 (-5)
    -8'sd6,   8'sd12,       // node 10: DctCat1 (token 5 -> -6)
    -8'sd7,   8'sd14,       // node 12: DctCat2 (token 6 -> -7)
    -8'sd8,   8'sd16,       // node 14: DctCat3 (token 7 -> -8)
    -8'sd9,   8'sd18,       // node 16: DctCat4 (token 8 -> -9)
    -8'sd10,  -8'sd11       // node 18: DctCat5 (-10), DctCat6 (-11)
  };

  // Category extra-bit probabilities (flattened, lookup by cat offset then bit)
  // PCAT1[1], PCAT2[2], PCAT3[3], PCAT4[4], PCAT5[5], PCAT6[11]
  localparam byte unsigned PCAT_PROB[0:25] = '{
    159,               // cat1 (1 bit)
    165, 145,          // cat2 (2 bits)
    173, 148, 140,     // cat3 (3 bits)
    176, 155, 140, 135, // cat4 (4 bits)
    180, 157, 141, 134, 130, // cat5 (5 bits)
    254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 // cat6 (11 bits)
  };
  localparam int unsigned PCAT_OFF[0:5]  = '{0, 1, 3, 6, 10, 15};
  localparam int unsigned PCAT_BITS[0:5] = '{1, 2, 3, 4,  5, 11};
  localparam int signed   CAT_BASE[0:5]  = '{5, 7, 11, 19, 35, 67};

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE    = 4'd1,
    S_COEFF   = 4'd2,   // tree-walk COEFF_TREE / COEFF_TREE_NOEOB
    S_EXTRA   = 4'd4,   // extra bits for category tokens
    S_SIGN    = 4'd8,   // read sign bit (prob=128)
    S_DONE    = 4'd0
  } State;

  State state;

  // Working registers
  logic [3:0]          coeff_idx;  // 0-15 current coefficient position
  logic signed [7:0]   tree_node;
  logic                use_noeob;  // after first non-zero we switch to NOEOB tree
  logic [1:0]          cur_complexity;
  logic                bd_req_pend;
  logic                bd_result;

  // Current token
  logic signed [3:0]   token;   // -1 undefined, else 0-11
  logic                got_token;

  // Category extra-bit accumulation
  logic [3:0]          cat;        // category index 0-5
  logic [3:0]          extra_left; // bits remaining
  logic signed [10:0]  extra_acc;  // accumulated extra value

  // Coefficient storage
  shortint signed      coeff_buf[0:15];
  logic                has_coeff_r;

  // BD lookup
  function automatic byte unsigned coeff_prob(
      input logic [1:0]  pl,
      input byte unsigned band,
      input logic [1:0]  ctx,
      input logic [3:0]  tok_idx,
      input logic        noeob
  );
    // prob array index: first coefficient uses full table including EOB
    // noeob: skip prob[0] (EOB), node indexing is already adjusted in CTNOEOB
    // We just return the raw probability for the given combo
    coeff_prob = frame_ctx.coeff_probs[pl][band][ctx][tok_idx[3:0]];
  endfunction

  // -------------------------------------------------------------------------
  // Combinational
  // -------------------------------------------------------------------------
  always_comb begin
    bd.valid      = 1'b0;
    bd.prob       = 8'd128;
    bd.data_ready = !bd_req_pend;
    busy          = (state != S_IDLE);
    coeff_valid   = (state == S_DONE);

    for (int i = 0; i < 16; i++) coeffs[i] = coeff_buf[i];
    has_coeff = has_coeff_r;

    case (state)
      S_COEFF: begin
        // Determine current tree byte and issue bd request
        if (!bd_req_pend) begin
          automatic byte signed tb;
          automatic byte unsigned band;
          automatic byte unsigned pb;
          band = COEFF_BANDS[coeff_idx];

          if (use_noeob) begin
            tb = CTNOEOB[tree_node[4:0]];
          end else begin
            tb = CT[tree_node[4:0]];
          end

          if (tb >= 0) begin
            // Non-leaf: issue bool decode.
            // CT:     prob index = node >> 1  (node 0->prob[0], node 2->prob[1], ...)
            // CTNOEOB: same tree but with the EOB pair (nodes 0-1) removed, so
            //          CTNOEOB node 0 corresponds to CT node 2 (prob[1]).
            //          Correct index = (node >> 1) + 1.
            if (use_noeob)
              pb = coeff_prob(plane, band, cur_complexity,
                              4'((tree_node[4:0] >> 1) + 5'd1), use_noeob);
            else
              pb = coeff_prob(plane, band, cur_complexity,
                              4'(tree_node[4:0] >> 1), use_noeob);
            bd.prob  = pb;
            bd.valid = 1'b1;
          end
        end
      end

      S_EXTRA: begin
        if (!bd_req_pend) begin
          bd.prob  = PCAT_PROB[PCAT_OFF[cat] + int'(PCAT_BITS[cat]) - 1 - int'(extra_left)];
          bd.valid = 1'b1;
        end
      end

      S_SIGN: begin
        if (!bd_req_pend) begin
          bd.prob  = 8'd128;
          bd.valid = 1'b1;
        end
      end

      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // Sequential
  // -------------------------------------------------------------------------
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      state           <= S_IDLE;
      coeff_idx       <= 4'd0;
      tree_node       <= 8'sd0;
      use_noeob       <= 1'b0;
      cur_complexity  <= 2'd0;
      bd_req_pend     <= 1'b0;
      bd_result       <= 1'b0;
      token           <= 4'sd0;
      got_token       <= 1'b0;
      cat             <= 4'd0;
      extra_left      <= 4'd0;
      extra_acc       <= 11'd0;
      has_coeff_r     <= 1'b0;
      for (int i = 0; i < 16; i++) coeff_buf[i] <= 16'sd0;
    end else begin

      // BD handshake
      if (bd.valid && bd.ready)   bd_req_pend <= 1'b1;
      if (bd.data_valid && bd_req_pend) begin
        bd_result   <= bd.data;
        bd_req_pend <= 1'b0;
      end

      case (state)
        // ----------------------------------------------------------------
        S_IDLE: begin
          if (start) begin
            for (int i = 0; i < 16; i++) coeff_buf[i] <= 16'sd0;
            has_coeff_r    <= 1'b0;
            coeff_idx      <= first_coeff ? 4'd1 : 4'd0;
            tree_node      <= 8'sd0;
            use_noeob      <= 1'b0;
            cur_complexity <= complexity;
            state          <= S_COEFF;
          end
        end

        // ----------------------------------------------------------------
        S_COEFF: begin
          automatic byte signed tb;
          if (use_noeob)
            tb = CTNOEOB[tree_node[4:0]];
          else
            tb = CT[tree_node[4:0]];

          if (tb < 0) begin
            // Leaf: tb = -(token+1), so token = (-tb) - 1
            token <= 4'((-tb) - 1);

            // DCT EOB (token 11)
            if (-tb == 11) begin
              state <= S_DONE;
            end
            // DCT0 (token 0) - skip this coeff
            else if (-tb == 0) begin
              use_noeob      <= 1'b1;
              has_coeff_r    <= 1'b1;
              // update complexity
              cur_complexity <= 2'd0;
              coeff_idx <= coeff_idx + 1'b1;
              if (coeff_idx == 15) begin
                state <= S_DONE;
              end else begin
                tree_node <= 8'sd0;
              end
            end
            // Literal tokens 1-4
            else if (-tb <= 4) begin
              has_coeff_r <= 1'b1;
              // go to sign
              state <= S_SIGN;
            end
            // Category tokens 5-10
            else if (-tb <= 10) begin
              has_coeff_r <= 1'b1;
              cat         <= 4'(-tb) - 4'd5;
              extra_left  <= 4'(PCAT_BITS[int'(-tb) - 5]);
              extra_acc   <= 11'd0;
              state       <= S_EXTRA;
            end

          end else if (bd.data_valid && bd_req_pend) begin
            // Advance tree node
            tree_node <= signed'(8'(tb)) + signed'({7'b0, bd_result});
          end
        end

        // ----------------------------------------------------------------
        S_EXTRA: begin
          if (bd.data_valid && bd_req_pend) begin
            extra_acc  <= (extra_acc << 1) | {10'd0, bd_result};
            extra_left <= extra_left - 1'b1;
            if (extra_left == 1) begin
              state <= S_SIGN;
            end
          end
        end

        // ----------------------------------------------------------------
        S_SIGN: begin
          if (bd.data_valid && bd_req_pend) begin
            // Compute final value
            automatic shortint signed abs_val;
            automatic logic [3:0]    tok;
            automatic shortint signed q;
            automatic logic [3:0]    zz;

            tok = token[3:0];
            if (tok <= 4) begin
              abs_val = shortint'(tok);
            end else begin
              abs_val = shortint'(CAT_BASE[int'(tok) - 5] + int'(extra_acc));
            end

            // Apply sign
            if (bd_result) abs_val = -abs_val;

            // Update complexity
            case (abs_val < 0 ? -abs_val : abs_val)
              0:       cur_complexity <= 2'd0;
              1:       cur_complexity <= 2'd1;
              default: cur_complexity <= 2'd2;
            endcase

            // Dequantize and zigzag
            zz = ZIGZAG[coeff_idx];
            q  = (zz == 0) ? dcq : acq;
            coeff_buf[zz] <= shortint'(int'(abs_val) * int'(q));

            // Advance
            use_noeob <= 1'b1;
            coeff_idx <= coeff_idx + 1'b1;
            if (coeff_idx == 15) begin
              state <= S_DONE;
            end else begin
              state     <= S_COEFF;
              tree_node <= 8'sd0;
            end
          end
        end

        // ----------------------------------------------------------------
        S_DONE: begin
          // Stay one cycle then auto-return to idle
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

// ---------------------------------------------------------------------------
// Test wrapper
// ---------------------------------------------------------------------------
module TokenDecoderTest
  import MacroblockHeaderPkg::*;
(
    input var logic clk,
    input var logic rst,

    // BD flat
    input var  logic         bd_ready,
    input var  logic         bd_data_valid,
    input var  logic         bd_data,
    output var logic         bd_valid,
    output var logic [7:0]   bd_prob,
    output var logic         bd_data_ready,

    input var Frame::FrameCtx    frame_ctx,
    input var logic [1:0]        plane,
    input var logic [1:0]        complexity,
    input var logic              first_coeff,
    input var shortint signed    dcq,
    input var shortint signed    acq,

    input var  logic             start,
    output var logic             busy,

    output var shortint signed   coeffs[0:15],
    output var logic             has_coeff,
    output var logic             coeff_valid
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

  TokenDecoder uut (
      .clk       (clk),
      .rst       (rst),
      .bd        (bd),
      .plane     (plane),
      .complexity(complexity),
      .first_coeff(first_coeff),
      .dcq       (dcq),
      .acq       (acq),
      .frame_ctx (frame_ctx),
      .start     (start),
      .busy      (busy),
      .coeffs    (coeffs),
      .has_coeff (has_coeff),
      .coeff_valid(coeff_valid)
  );
endmodule