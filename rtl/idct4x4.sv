interface Idct4x4If;
  logic           coeff_ready;
  logic           coeff_valid;
  shortint signed coeff       [0:4-1][0:4-1];

  logic           block_ready;
  logic           block_valid;
  shortint signed block       [0:4-1][0:4-1];

  modport self(
      output coeff_ready,
      input coeff_valid,
      input coeff,

      input block_ready,
      output block_valid,
      output block
  );

  modport user(
      input coeff_ready,
      output coeff_valid,
      output coeff,

      output block_ready,
      input block_valid,
      input block
  );
endinterface

module Idct4x4 (
    input var logic clk,
    input var logic rst,

    Idct4x4If.self self
);
  logic signed [32-1:0] cospi8sqrt2minus1;
  always_comb cospi8sqrt2minus1 = 20091;
  logic signed [32-1:0] sinpi8sqrt2;
  always_comb sinpi8sqrt2 = 35468;

  typedef enum logic [4-1:0] {
    State_idle = 4'd1,
    State_calc_cols = 4'd2,
    State_calc_rows = 4'd4,
    State_out = 4'd8
  } State;

  State         state;
  logic [2-1:0] i;

  // TODO: this can be further optimized in terms of area
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      state      <= State_idle;
      self.block <= '{default: '{default: 0}};
      i          <= 0;
    end else begin
      case (state) inside
        default: state <= State_idle;
        State_idle: begin
          if (self.coeff_valid) begin
            state      <= State_calc_cols;
            i          <= 0;
            self.block <= self.coeff;
          end
        end
        State_calc_cols: begin
          int signed a1;
          int signed b1;
          int signed t1;
          int signed t2;
          int signed c1;
          int signed t3;
          int signed t4;
          int signed d1;
          i <= i + (1);
          if (i == 3) begin
            state <= State_calc_rows;
          end

          a1 = signed'(int'(self.block[0][i])) + signed'(int'(self.block[2][i]));
          b1 = signed'(int'(self.block[0][i])) - signed'(int'(self.block[2][i]));

          t1 = (signed'(int'(self.block[1][i])) * sinpi8sqrt2) >>> 16;
          t2 = signed'(int'(self.block[3][i])) + ((signed'(int'(self.block[3][i])) * cospi8sqrt2minus1) >>> 16);
          c1 = t1 - t2;

          t3 = signed'(int'(self.block[1][i])) + ((signed'(int'(self.block[1][i])) * cospi8sqrt2minus1) >>> 16);
          t4 = (signed'(int'(self.block[3][i])) * sinpi8sqrt2) >>> 16;
          d1 = t3 + t4;

          self.block[0][i] <= signed'(shortint'((a1 + d1)));
          self.block[1][i] <= signed'(shortint'((b1 + c1)));
          self.block[3][i] <= signed'(shortint'((a1 - d1)));
          self.block[2][i] <= signed'(shortint'((b1 - c1)));
        end
        State_calc_rows: begin
          int signed a1;
          int signed b1;
          int signed t1;
          int signed t2;
          int signed c1;
          int signed t3;
          int signed t4;
          int signed d1;
          i <= i + (1);
          if (i == 3) begin
            state <= State_out;
          end

          a1 = signed'(int'(self.block[i][0])) + signed'(int'(self.block[i][2]));
          b1 = signed'(int'(self.block[i][0])) - signed'(int'(self.block[i][2]));

          t1 = (signed'(int'(self.block[i][1])) * sinpi8sqrt2) >>> 16;
          t2 = signed'(int'(self.block[i][3])) + ((signed'(int'(self.block[i][3])) * cospi8sqrt2minus1) >>> 16);
          c1 = t1 - t2;

          t3 = signed'(int'(self.block[i][1])) + ((signed'(int'(self.block[i][1])) * cospi8sqrt2minus1) >>> 16);
          t4 = (signed'(int'(self.block[i][3])) * sinpi8sqrt2) >>> 16;
          d1 = t3 + t4;

          self.block[i][0] <= signed'(shortint'(((a1 + d1 + 4) >>> 3)));
          self.block[i][3] <= signed'(shortint'(((a1 - d1 + 4) >>> 3)));
          self.block[i][1] <= signed'(shortint'(((b1 + c1 + 4) >>> 3)));
          self.block[i][2] <= signed'(shortint'(((b1 - c1 + 4) >>> 3)));
        end

        State_out: begin
          if (self.block_ready) begin
            state <= State_idle;
          end
        end
      endcase
    end
  end

  always_comb begin
    self.block_valid = 1'b0;
    self.coeff_ready = 1'b0;

    case (state) inside
      default: begin
      end
      State_idle: begin
        self.coeff_ready = 1'b1;
      end
      State_out: begin
        self.block_valid = 1'b1;
      end
    endcase
  end

endmodule

module Iwht4x4 (
    input var logic clk,
    input var logic rst,

    Idct4x4If.self self
);

  typedef enum logic [4-1:0] {
    State_idle = 4'd1,
    State_calc_cols = 4'd2,
    State_calc_rows = 4'd4,
    State_out = 4'd8
  } State;

  State         state;
  logic [2-1:0] i;

  // TODO: this can be further optimized in terms of area
  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      state      <= State_idle;
      self.block <= '{default: '{default: 0}};
      i          <= 0;
    end else begin
      case (state) inside
        default: state <= State_idle;
        State_idle: begin
          if (self.coeff_valid) begin
            state      <= State_calc_cols;
            i          <= 0;
            self.block <= self.coeff;
          end
        end
        State_calc_cols: begin
          int signed a1;
          int signed b1;
          int signed c1;
          int signed d1;
          i <= i + (1);
          if (i == 3) begin
            state <= State_calc_rows;
          end

          a1 = signed'(int'(self.block[0][i])) + signed'(int'(self.block[3][i]));
          b1 = signed'(int'(self.block[1][i])) + signed'(int'(self.block[2][i]));
          c1 = signed'(int'(self.block[1][i])) - signed'(int'(self.block[2][i]));
          d1 = signed'(int'(self.block[0][i])) - signed'(int'(self.block[3][i]));

          self.block[0][i] <= signed'(shortint'((a1 + b1)));
          self.block[1][i] <= signed'(shortint'((c1 + d1)));
          self.block[2][i] <= signed'(shortint'((a1 - b1)));
          self.block[3][i] <= signed'(shortint'((d1 - c1)));
        end
        State_calc_rows: begin
          int signed a1;
          int signed b1;
          int signed c1;
          int signed d1;
          int signed a2;
          int signed b2;
          int signed c2;
          int signed d2;
          i <= i + (1);
          if (i == 3) begin
            state <= State_out;
          end

          a1 = signed'(int'(self.block[i][0])) + signed'(int'(self.block[i][3]));
          b1 = signed'(int'(self.block[i][1])) + signed'(int'(self.block[i][2]));
          c1 = signed'(int'(self.block[i][1])) - signed'(int'(self.block[i][2]));
          d1 = signed'(int'(self.block[i][0])) - signed'(int'(self.block[i][3]));

          a2 = a1 + b1;
          b2 = c1 + d1;
          c2 = a1 - b1;
          d2 = d1 - c1;

          self.block[i][0] <= signed'(shortint'(((a2 + 3) >>> 3)));
          self.block[i][1] <= signed'(shortint'(((b2 + 3) >>> 3)));
          self.block[i][2] <= signed'(shortint'(((c2 + 3) >>> 3)));
          self.block[i][3] <= signed'(shortint'(((d2 + 3) >>> 3)));
        end

        State_out: begin
          if (self.block_ready) begin
            state <= State_idle;
          end
        end
      endcase
    end
  end

  always_comb begin
    self.block_valid = 1'b0;
    self.coeff_ready = 1'b0;

    case (state) inside
      default: begin
      end
      State_idle: begin
        self.coeff_ready = 1'b1;
      end
      State_out: begin
        self.block_valid = 1'b1;
      end
    endcase
  end

endmodule

module Idct4x4Test (
    input var logic clk,
    input var logic rst,

    input var logic dct_or_wht,

    output var logic           coeff_ready,
    input var  logic           coeff_valid,
    input var  shortint signed coeff      [0:4-1][0:4-1],

    input var  logic           block_ready,
    output var logic           block_valid,
    output var shortint signed block      [0:4-1][0:4-1]
);
  Idct4x4If bus[0:2-1] ();

  Idct4x4 dct (
      .clk (clk),
      .rst (rst),
      .self(bus[0])
  );

  Iwht4x4 wht (
      .clk (clk),
      .rst (rst),
      .self(bus[1])
  );

  always_comb begin
    bus[0].coeff_valid = 1'b0;
    bus[0].block_ready = 1'b0;
    bus[0].coeff       = '{default: '{default: 0}};

    bus[1].coeff_valid = 1'b0;
    bus[1].block_ready = 1'b0;
    bus[1].coeff       = '{default: '{default: 0}};

    coeff_ready        = 1'b0;
    block_valid        = 1'b0;
    block              = '{default: '{default: 0}};

    case (dct_or_wht) inside
      0: begin
        bus[0].coeff_valid = coeff_valid;
        bus[0].block_ready = block_ready;
        bus[0].coeff       = coeff;

        coeff_ready        = bus[0].coeff_ready;
        block_valid        = bus[0].block_valid;
        block              = bus[0].block;
      end
      1: begin
        bus[1].coeff_valid = coeff_valid;
        bus[1].block_ready = block_ready;
        bus[1].coeff       = coeff;

        coeff_ready        = bus[1].coeff_ready;
        block_valid        = bus[1].block_valid;
        block              = bus[1].block;
      end
    endcase
  end
endmodule
