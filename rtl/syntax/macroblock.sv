


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

  typedef enum logic [6-1:0] {
    State_Idle = 6'd1,
    State_ReadSkipCoeff = 6'd2,
    State_ReadYMode = 6'd4,
    State_ReadBMode = 6'd8,
    State_ReadUVMode = 6'd16,
    State_Out = 6'd32
  } State;

  State                                   state;
  logic                           [8-1:0] next_node;
  logic                           [3-1:0] sub_x;
  logic                           [3-1:0] sub_y;
  byte unsigned                           prob;

  MacroblockHeaderPkg::IntraBMode         ctx_a;
  MacroblockHeaderPkg::IntraBMode         ctx_l;

  always_comb begin
  end

  always_comb begin
  end

  always_ff @(posedge clk) begin
  end
endmodule

module MacroblockParserTest
  import MacroblockHeaderPkg::*;
  import Frame::*;
(
    input var logic clk,
    input var logic rst,

    input var logic bd_ready,
    input var logic bd_data_valid,
    input var logic bd_data,

    output var logic         bd_valid,
    output var logic [8-1:0] bd_prob,
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
