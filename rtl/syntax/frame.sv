package Frame;
  typedef byte unsigned Prob;
  typedef Prob [4-1:0][8-1:0][3-1:0][11-1:0] CoeffProbs;
  typedef struct packed {
    logic             valid;
    longint unsigned  part1_off;
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
    logic                                 tokens;  // TODO
  } Macroblock;
endpackage

module FrameParser #(
    parameter int unsigned     SLOTES_COUNT = 64,
    parameter longint unsigned BUFFER_SIZE  = 100 * 1024
) (
    input var logic clk,
    input var logic rst,

    input var  logic         stream_data_valid,
    output var logic         stream_data_ready,
    input var  byte unsigned stream_data,

    output var Frame::FrameCtx   ctx,
    output var Frame::Macroblock macroblocks[0:SLOTES_COUNT-1]
);
  // the ring buffer, contains both part0 and part1
  byte unsigned    buffer      [0:BUFFER_SIZE-1];
  longint unsigned index;
  longint unsigned part0_index;
  longint unsigned part1_index;

  always_comb stream_data_ready = 1;

  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      index           <= 0;
      part0_index     <= 0;
      part1_index     <= 0;
      buffer          <= '{default: 0};
      ctx             <= '{default: 0};
      // Do this on the parsing loop
      ctx.coeff_probs <= Tables::DEFAULT_COEFF_PROBS;
      macroblocks     <= '{default: 0};
    end else begin
      if (stream_data_valid) begin
        buffer[index] <= stream_data;
        // Ring buffer behavior
        // NOTE: this implicitly assume that part1_off is valid at this
        // time and smaller than the `BufferSize`
        // TODO: stream_data_ready to 0 when the parser still parsing
        if (index == BUFFER_SIZE - 1) begin
          index <= ctx.part1_off;
        end else begin
          index <= index + (1);
        end
      end

      // First decode the framectx then decode macroblocks
    end
  end
endmodule

module FrameParserTest (
    input var logic clk,
    input var logic rst
);
  // TODO: impl the test
endmodule
