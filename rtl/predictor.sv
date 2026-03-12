// Predictor - computes intra-prediction and adds residuals for one MB.
//
// Supports all 5 macroblock-level modes (DC, V, H, TM, BPred) for luma
// and all 4 chroma modes (DC, V, H, TM). BPred walks the 4×4 sub-grid
// using the 10 directional B-modes.
//
// All computation is purely combinational; there is no clock. The parent
// calls this as a pure function once it has:
//   - header  (prediction modes)
//   - residuals (post-IDCT, from ResidueDecoder)
//   - edge pixels from the frame buffer
//
// Output: 16×16 luma pixels + 8×8 Cb + 8×8 Cr (byte values 0-255)

import MacroblockHeaderPkg::*;
import ResiduePkg::*;

package PredictorPkg;
  typedef byte unsigned Luma  [0:15][0:15];
  typedef byte unsigned Chroma[0:7][0:7];

  typedef struct packed {
    logic valid;
    Luma   y;
    Chroma cb;
    Chroma cr;
  } MbPixels;
endpackage

// ---------------------------------------------------------------------------
// Shared arithmetic helpers
// ---------------------------------------------------------------------------

// avg2(a,b)   = (a + b + 1) >> 1
// avg3(a,b,c) = (a + 2b + c + 2) >> 2
function automatic byte unsigned avg2(input byte unsigned a, b);
  avg2 = byte'(({1'b0,a} + {1'b0,b} + 9'd1) >> 1);
endfunction

function automatic byte unsigned avg3(input byte unsigned a, b, c);
  avg3 = byte'(({2'b0,a} + {2'b0,b} + {2'b0,b} + {2'b0,c} + 10'd2) >> 2);
endfunction

function automatic byte unsigned clamp8(input int signed v);
  clamp8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : byte'(v);
endfunction

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------
module Predictor (
    // Macroblock header (mode selection)
    input var MacroblockHeaderPkg::MacroblockHeader header,

    // Residuals (already IDCT/IWHT transformed, 16-bit signed)
    input var ResiduePkg::MbResiduals residuals,

    // Edge pixels from frame buffer (all optional; 0 = unavailable)
    input var logic              top_valid,
    input var byte unsigned      top_y [0:15],     // row above luma
    input var byte unsigned      top_cb[0:7],
    input var byte unsigned      top_cr[0:7],

    input var logic              left_valid,
    input var byte unsigned      left_y [0:15],    // column to the left
    input var byte unsigned      left_cb[0:7],
    input var byte unsigned      left_cr[0:7],

    input var logic              topleft_valid,
    input var byte unsigned      topleft_y,
    input var byte unsigned      topleft_cb,
    input var byte unsigned      topleft_cr,

    input var logic              topright_valid,
    input var byte unsigned      topright_y[0:3], // 4 pixels top-right of current MB

    // Output reconstructed MB
    output var PredictorPkg::MbPixels pixels
);

  // -----------------------------------------------------------------------
  // MB-level DC prediction - N=16 for luma, N=8 for chroma
  // -----------------------------------------------------------------------
  function automatic byte unsigned dc_pred16(
      input logic         tv, lv,
      input byte unsigned T[0:15],
      input byte unsigned L[0:15]
  );
    int unsigned sum;
    int unsigned cnt;
    sum = 0; cnt = 0;
    if (tv) begin for (int i=0;i<16;i++) begin sum += T[i]; cnt++; end end
    if (lv) begin for (int i=0;i<16;i++) begin sum += L[i]; cnt++; end end
    case ({tv,lv})
      2'b00: dc_pred16 = 8'd128;
      2'b10: dc_pred16 = byte'((sum + 8)  >> 4);
      2'b01: dc_pred16 = byte'((sum + 8)  >> 4);
      2'b11: dc_pred16 = byte'((sum + 16) >> 5);
    endcase
  endfunction

  function automatic byte unsigned dc_pred8(
      input logic         tv, lv,
      input byte unsigned T[0:7],
      input byte unsigned L[0:7]
  );
    int unsigned sum;
    sum = 0;
    if (tv) begin for (int i=0;i<8;i++) sum += T[i]; end
    if (lv) begin for (int i=0;i<8;i++) sum += L[i]; end
    case ({tv,lv})
      2'b00: dc_pred8 = 8'd128;
      2'b10: dc_pred8 = byte'((sum + 4) >> 3);
      2'b01: dc_pred8 = byte'((sum + 4) >> 3);
      2'b11: dc_pred8 = byte'((sum + 8) >> 4);
    endcase
  endfunction

  // 4×4 DC (BDcPred: avg of top[4] + left[4], always has some)
  function automatic byte unsigned dc_pred4(
      input logic         tv, lv,
      input byte unsigned T[0:3],
      input byte unsigned L[0:3]
  );
    int unsigned sum;
    sum = 4;  // rounding
    if (tv) begin for (int i=0;i<4;i++) sum += T[i]; end
    if (lv) begin for (int i=0;i<4;i++) sum += L[i]; end
    dc_pred4 = byte'(sum >> 3);
  endfunction

  // -----------------------------------------------------------------------
  // Luma prediction - 16×16
  // -----------------------------------------------------------------------
  PredictorPkg::Luma pred_y;  // predicted before residual add

  always_comb begin
    // Default: gray
    pred_y = '{default: '{default: 8'd128}};

    case (header.intra_y_mode)
      IntraMBMode_DcPred: begin
        byte unsigned dc;
        dc = dc_pred16(top_valid, left_valid, top_y, left_y);
        for (int r=0; r<16; r++)
          for (int c=0; c<16; c++)
            pred_y[r][c] = dc;
      end

      IntraMBMode_VPred: begin
        byte unsigned row_val[0:15];
        if (top_valid)    row_val = top_y;
        else              row_val = '{default: 8'd127};
        for (int r=0; r<16; r++)
          for (int c=0; c<16; c++)
            pred_y[r][c] = row_val[c];
      end

      IntraMBMode_HPred: begin
        byte unsigned col_val[0:15];
        if (left_valid)   col_val = left_y;
        else              col_val = '{default: 8'd129};
        for (int r=0; r<16; r++)
          for (int c=0; c<16; c++)
            pred_y[r][c] = col_val[r];
      end

      IntraMBMode_TmPred: begin
        byte unsigned T[0:15], L[0:15];
        byte unsigned P;
        T = top_valid   ? top_y   : '{default: 8'd127};
        L = left_valid  ? left_y  : '{default: 8'd129};
        P = (top_valid && left_valid) ? topleft_y :
             top_valid  ? 8'd129 : 8'd127;
        for (int r=0; r<16; r++)
          for (int c=0; c<16; c++)
            pred_y[r][c] = clamp8(int'(L[r]) + int'(T[c]) - int'(P));
      end

      IntraMBMode_BPred: begin
        // Computed in the BPred sub-block section below
        pred_y = '{default: '{default: 8'd128}};
      end

      default: ;
    endcase
  end

  // -----------------------------------------------------------------------
  // BPred: 4×4 sub-block predictions (compile-time unrolled)
  // -----------------------------------------------------------------------
  // We compute a 16×16 block by iterating the 4×4 grid. For each sub-block
  // (brow, bcol) we derive local T/L/TL/TR from already-filled pred_b slots
  // or from the MB-level edge arrays.
  //
  // Because SV doesn't allow reading a signal we're currently assigning,
  // we use a separate "b pred block" that we fill row-by-row.

  PredictorPkg::Luma b_pred_block;

  always_comb begin
    b_pred_block = '{default: '{default: 8'd128}};

    if (header.intra_y_mode == IntraMBMode_BPred) begin

      for (int brow = 0; brow < 4; brow++) begin
        for (int bcol = 0; bcol < 4; bcol++) begin
          // Local edges for this 4×4 sub-block
          byte unsigned T4[0:3];
          byte unsigned L4[0:3];
          byte unsigned TL;
          byte unsigned TR4[0:3];
          logic         t_avail, l_avail, tl_avail, tr_avail;

          // Top edge
          if (brow == 0) begin
            t_avail = top_valid;
            for (int c=0;c<4;c++) T4[c] = top_y[bcol*4+c];
          end else begin
            t_avail = 1'b1;
            for (int c=0;c<4;c++) T4[c] = b_pred_block[(brow-1)*4+3][bcol*4+c];
          end

          // Left edge
          if (bcol == 0) begin
            l_avail = left_valid;
            for (int r=0;r<4;r++) L4[r] = left_y[brow*4+r];
          end else begin
            l_avail = 1'b1;
            for (int r=0;r<4;r++) L4[r] = b_pred_block[brow*4+r][(bcol-1)*4+3];
          end

          // Top-left
          if (brow == 0 && bcol == 0) begin
            tl_avail = topleft_valid;
            TL       = topleft_y;
          end else if (brow == 0) begin
            tl_avail = top_valid;
            TL       = top_y[bcol*4-1];
          end else if (bcol == 0) begin
            tl_avail = left_valid;
            TL       = left_y[brow*4-1];
          end else begin
            tl_avail = 1'b1;
            TL       = b_pred_block[(brow-1)*4+3][(bcol-1)*4+3];
          end

          // Top-right
          if (bcol == 3) begin
            tr_avail = topright_valid;
            TR4      = topright_y;
          end else if (brow == 0) begin
            tr_avail = top_valid;
            for (int c=0;c<4;c++) TR4[c] = top_y[(bcol+1)*4+c];
          end else begin
            tr_avail = 1'b1;
            for (int c=0;c<4;c++) TR4[c] = b_pred_block[(brow-1)*4+3][(bcol+1)*4+c];
          end

          // Defaults when unavailable
          if (!t_avail)  for (int c=0;c<4;c++) T4[c]  = 8'd127;
          if (!l_avail)  for (int r=0;r<4;r++) L4[r]  = 8'd129;
          if (!tl_avail) TL = 8'd127;
          if (!tr_avail) for (int c=0;c<4;c++) TR4[c] = T4[3];

          // Dispatch mode
          begin
            byte unsigned pred4[0:3][0:3];
            IntraBMode mode;
            mode = header.sub_modes[brow][bcol];

            pred4 = predict_4x4(mode, T4, L4, TL, TR4);

            for (int r=0;r<4;r++)
              for (int c=0;c<4;c++)
                b_pred_block[brow*4+r][bcol*4+c] = pred4[r][c];
          end
        end
      end
    end
  end

  // 4×4 prediction dispatch function
  function automatic byte unsigned [0:3][0:3] predict_4x4(
      input IntraBMode      mode,
      input byte unsigned   T[0:3],
      input byte unsigned   L[0:3],
      input byte unsigned   TL,
      input byte unsigned   TR[0:3]
  );
    byte unsigned out[0:3][0:3];
    byte unsigned a_ext[0:7];

    out = '{default: '{default: 8'd128}};

    case (mode)
      // BDcPred
      IntraBMode_BDcPred: begin
        byte unsigned dc;
        dc = byte'((int'(T[0])+int'(T[1])+int'(T[2])+int'(T[3])+
                    int'(L[0])+int'(L[1])+int'(L[2])+int'(L[3])+4) >> 3);
        for (int r=0;r<4;r++) for (int c=0;c<4;c++) out[r][c] = dc;
      end

      // BTmPred
      IntraBMode_BTmPred: begin
        for (int r=0;r<4;r++)
          for (int c=0;c<4;c++)
            out[r][c] = clamp8(int'(L[r]) + int'(T[c]) - int'(TL));
      end

      // BVePred: vertical with smoothed top
      IntraBMode_BVePred: begin
        byte unsigned row_v[0:3];
        row_v[0] = avg3(TL,    T[0], T[1]);
        row_v[1] = avg3(T[0],  T[1], T[2]);
        row_v[2] = avg3(T[1],  T[2], T[3]);
        row_v[3] = avg3(T[2],  T[3], TR[0]);
        for (int r=0;r<4;r++) for (int c=0;c<4;c++) out[r][c] = row_v[c];
      end

      // BHePred: horizontal with smoothed left
      IntraBMode_BHePred: begin
        byte unsigned col_v[0:3];
        col_v[0] = avg3(TL,   L[0], L[1]);
        col_v[1] = avg3(L[0], L[1], L[2]);
        col_v[2] = avg3(L[1], L[2], L[3]);
        col_v[3] = avg3(L[2], L[3], L[3]);
        for (int r=0;r<4;r++) for (int c=0;c<4;c++) out[r][c] = col_v[r];
      end

      // BLdPred: left-down diagonal
      IntraBMode_BLdPred: begin
        for (int i=0;i<7;i++) begin
          if (i<4) a_ext[i] = T[i]; else a_ext[i] = TR[i-4];
        end
        a_ext[7] = TR[3];
        out[0][0]=avg3(a_ext[0],a_ext[1],a_ext[2]);
        out[0][1]=avg3(a_ext[1],a_ext[2],a_ext[3]); out[1][0]=out[0][1];
        out[0][2]=avg3(a_ext[2],a_ext[3],a_ext[4]); out[1][1]=out[0][2]; out[2][0]=out[0][2];
        out[0][3]=avg3(a_ext[3],a_ext[4],a_ext[5]); out[1][2]=out[0][3]; out[2][1]=out[0][3]; out[3][0]=out[0][3];
        out[1][3]=avg3(a_ext[4],a_ext[5],a_ext[6]); out[2][2]=out[1][3]; out[3][1]=out[1][3];
        out[2][3]=avg3(a_ext[5],a_ext[6],a_ext[7]); out[3][2]=out[2][3];
        out[3][3]=avg3(a_ext[6],a_ext[7],a_ext[7]);
      end

      // BRdPred: right-down diagonal
      IntraBMode_BRdPred: begin
        byte unsigned e[0:8];
        e[0]=L[3]; e[1]=L[2]; e[2]=L[1]; e[3]=L[0]; e[4]=TL;
        e[5]=T[0]; e[6]=T[1]; e[7]=T[2]; e[8]=T[3];
        out[3][0]=avg3(e[0],e[1],e[2]); out[3][1]=avg3(e[1],e[2],e[3]);
        out[2][0]=out[3][1];            out[3][2]=avg3(e[2],e[3],e[4]);
        out[2][1]=out[3][2]; out[1][0]=out[3][2];
        out[3][3]=avg3(e[3],e[4],e[5]); out[2][2]=out[3][3]; out[1][1]=out[3][3]; out[0][0]=out[3][3];
        out[2][3]=avg3(e[4],e[5],e[6]); out[1][2]=out[2][3]; out[0][1]=out[2][3];
        out[1][3]=avg3(e[5],e[6],e[7]); out[0][2]=out[1][3];
        out[0][3]=avg3(e[6],e[7],e[8]);
      end

      // BVrPred
      IntraBMode_BVrPred: begin
        byte unsigned e[0:8];
        e[0]=L[3]; e[1]=L[2]; e[2]=L[1]; e[3]=L[0]; e[4]=TL;
        e[5]=T[0]; e[6]=T[1]; e[7]=T[2]; e[8]=T[3];
        out[3][0]=avg3(e[1],e[2],e[3]); out[2][0]=avg3(e[2],e[3],e[4]);
        out[3][1]=avg3(e[3],e[4],e[5]); out[1][0]=out[3][1];
        out[2][1]=avg2(e[4],e[5]);      out[0][0]=out[2][1];
        out[3][2]=avg3(e[4],e[5],e[6]); out[1][1]=out[3][2];
        out[2][2]=avg2(e[5],e[6]);      out[0][1]=out[2][2];
        out[3][3]=avg3(e[5],e[6],e[7]); out[1][2]=out[3][3];
        out[2][3]=avg2(e[6],e[7]);      out[0][2]=out[2][3];
        out[1][3]=avg3(e[6],e[7],e[8]);
        out[0][3]=avg2(e[7],e[8]);
      end

      // BVlPred
      IntraBMode_BVlPred: begin
        for (int i=0;i<4;i++) a_ext[i] = T[i];
        for (int i=0;i<4;i++) a_ext[4+i] = TR[i];
        out[0][0]=avg2(a_ext[0],a_ext[1]);
        out[1][0]=avg3(a_ext[0],a_ext[1],a_ext[2]);
        out[2][0]=avg2(a_ext[1],a_ext[2]); out[0][1]=out[2][0];
        out[1][1]=avg3(a_ext[1],a_ext[2],a_ext[3]); out[3][0]=out[1][1];
        out[2][1]=avg2(a_ext[2],a_ext[3]); out[0][2]=out[2][1];
        out[3][1]=avg3(a_ext[2],a_ext[3],a_ext[4]); out[1][2]=out[3][1];
        out[2][2]=avg2(a_ext[3],a_ext[4]); out[0][3]=out[2][2];
        out[3][2]=avg3(a_ext[3],a_ext[4],a_ext[5]); out[1][3]=out[3][2];
        out[2][3]=avg3(a_ext[4],a_ext[5],a_ext[6]);
        out[3][3]=avg3(a_ext[5],a_ext[6],a_ext[7]);
      end

      // BHdPred
      IntraBMode_BHdPred: begin
        byte unsigned e[0:8];
        e[0]=L[3]; e[1]=L[2]; e[2]=L[1]; e[3]=L[0]; e[4]=TL;
        e[5]=T[0]; e[6]=T[1]; e[7]=T[2]; e[8]=T[3];
        out[3][0]=avg2(e[0],e[1]);
        out[3][1]=avg3(e[0],e[1],e[2]);
        out[2][0]=avg2(e[1],e[2]); out[3][2]=out[2][0];
        out[2][1]=avg3(e[1],e[2],e[3]); out[3][3]=out[2][1];
        out[2][2]=avg2(e[2],e[3]); out[1][0]=out[2][2];
        out[2][3]=avg3(e[2],e[3],e[4]); out[1][1]=out[2][3];
        out[1][2]=avg2(e[3],e[4]); out[0][0]=out[1][2];
        out[1][3]=avg3(e[3],e[4],e[5]); out[0][1]=out[1][3];
        out[0][2]=avg3(e[4],e[5],e[6]);
        out[0][3]=avg3(e[5],e[6],e[7]);
      end

      // BHuPred
      IntraBMode_BHuPred: begin
        byte unsigned l[0:3];
        l = L;
        out[0][0]=avg2(l[0],l[1]);
        out[0][1]=avg3(l[0],l[1],l[2]);
        out[0][2]=avg2(l[1],l[2]); out[1][0]=out[0][2];
        out[0][3]=avg3(l[1],l[2],l[3]); out[1][1]=out[0][3];
        out[1][2]=avg2(l[2],l[3]); out[2][0]=out[1][2];
        out[1][3]=avg3(l[2],l[3],l[3]); out[2][1]=out[1][3];
        out[2][2]=l[3]; out[2][3]=l[3];
        out[3][0]=l[3]; out[3][1]=l[3]; out[3][2]=l[3]; out[3][3]=l[3];
      end

      default: ;
    endcase

    predict_4x4 = out;
  endfunction

  // -----------------------------------------------------------------------
  // Chroma prediction - 8×8
  // -----------------------------------------------------------------------
  PredictorPkg::Chroma pred_cb, pred_cr;

  always_comb begin
    pred_cb = '{default: '{default: 8'd128}};
    pred_cr = '{default: '{default: 8'd128}};

    byte unsigned dc_b, dc_r;
    dc_b = dc_pred8(top_valid, left_valid, top_cb, left_cb);
    dc_r = dc_pred8(top_valid, left_valid, top_cr, left_cr);

    case (header.intra_uv_mode)
      IntraMBMode_DcPred: begin
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) begin
          pred_cb[r][c] = dc_b;
          pred_cr[r][c] = dc_r;
        end
      end

      IntraMBMode_VPred: begin
        byte unsigned Tb[0:7], Tr[0:7];
        Tb = top_valid ? top_cb : '{default: 8'd127};
        Tr = top_valid ? top_cr : '{default: 8'd127};
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) begin
          pred_cb[r][c] = Tb[c];
          pred_cr[r][c] = Tr[c];
        end
      end

      IntraMBMode_HPred: begin
        byte unsigned Lb[0:7], Lr[0:7];
        Lb = left_valid ? left_cb : '{default: 8'd129};
        Lr = left_valid ? left_cr : '{default: 8'd129};
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) begin
          pred_cb[r][c] = Lb[r];
          pred_cr[r][c] = Lr[r];
        end
      end

      IntraMBMode_TmPred: begin
        byte unsigned Tb[0:7], Tr[0:7], Lb[0:7], Lr[0:7];
        byte unsigned Pb, Pr;
        Tb = top_valid  ? top_cb  : '{default: 8'd127};
        Tr = top_valid  ? top_cr  : '{default: 8'd127};
        Lb = left_valid ? left_cb : '{default: 8'd129};
        Lr = left_valid ? left_cr : '{default: 8'd129};
        Pb = topleft_valid ? topleft_cb : (top_valid ? 8'd129 : 8'd127);
        Pr = topleft_valid ? topleft_cr : (top_valid ? 8'd129 : 8'd127);
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) begin
          pred_cb[r][c] = clamp8(int'(Lb[r])+int'(Tb[c])-int'(Pb));
          pred_cr[r][c] = clamp8(int'(Lr[r])+int'(Tr[c])-int'(Pr));
        end
      end

      default: ;
    endcase
  end

  // -----------------------------------------------------------------------
  // Add residuals and clamp to [0, 255]
  // -----------------------------------------------------------------------
  always_comb begin
    pixels.valid = 1'b1;

    // Luma
    for (int r=0;r<16;r++) for (int c=0;c<16;c++) begin
      automatic int signed pred_val;
      automatic int signed res_val;
      if (header.intra_y_mode == IntraMBMode_BPred)
        pred_val = int'({1'b0, b_pred_block[r][c]});
      else
        pred_val = int'({1'b0, pred_y[r][c]});
      res_val  = int'(residuals.luma[r][c]);
      pixels.y[r][c] = clamp8(pred_val + res_val);
    end

    // Chroma Cb
    for (int r=0;r<8;r++) for (int c=0;c<8;c++)
      pixels.cb[r][c] = clamp8(int'({1'b0,pred_cb[r][c]}) + int'(residuals.chroma[0][r][c]));

    // Chroma Cr
    for (int r=0;r<8;r++) for (int c=0;c<8;c++)
      pixels.cr[r][c] = clamp8(int'({1'b0,pred_cr[r][c]}) + int'(residuals.chroma[1][r][c]));
  end

endmodule
