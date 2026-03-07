interface BoolDecoderIf;
  logic         ready;
  logic         valid;
  logic [8-1:0] prob;
  logic         data_ready;
  logic         data_valid;
  logic         data;

  modport self(
      output ready,
      input valid,
      input prob,
      input data_ready,
      output data_valid,
      output data
  );

  modport user(
      input ready,
      output valid,
      output prob,
      output data_ready,
      input data_valid,
      input data
  );
endinterface

module BoolDecoder (
    input var logic clk,
    input var logic rst,

    input var  logic              mem_ready,
    output var logic              mem_valid,
    input var  logic              mem_data_valid,
    output var logic              mem_data_ready,
    input var  byte unsigned      mem_data,
               BoolDecoderIf.self self
);
  logic [32-1:0] value;
  logic [32-1:0] range;
  logic [ 4-1:0] bit_count;
  logic [ 2-1:0] init;

  typedef enum logic [5-1:0] {
    State_init = 5'd1,
    State_idle = 5'd2,
    State_check_range = 5'd4,
    State_wait_byte = 5'd8,
    State_compute_bool = 5'd16
  } State;
  State          state;

  logic [32-1:0] split;
  always_comb split = 1 + (((range - 1) * self.prob) >> 8);
  logic [32-1:0] split_shifted;
  always_comb split_shifted = split << 8;

  always_ff @(posedge clk, negedge rst) begin
    if (!rst) begin
      state     <= State_init;
      value     <= 0;
      range     <= 255;
      bit_count <= 0;
      init      <= 0;
    end else begin
      case (state) inside
        default: state <= State_init;
        State_init: begin
          range <= 255;
          if (init == 2) begin
            state <= State_idle;
          end else if (mem_data_valid) begin
            value[7:0] <= mem_data;
            init       <= init + 1;
          end
        end

        State_idle: begin
          if (self.valid) begin
            state <= State_check_range;
          end
        end

        State_check_range: begin
          if (range >= 128) begin
            state <= State_compute_bool;
          end else begin
            if (bit_count == 8) begin
              bit_count <= 0;
              if (mem_ready) begin
                state <= State_wait_byte;
              end
            end else begin
              value     <= value << 1;
              range     <= range << 1;
              bit_count <= bit_count + 1;
            end
          end
        end

        State_wait_byte: begin
          if (mem_data_valid) begin
            value[7:0] <= mem_data;
            state      <= State_check_range;
          end
        end

        State_compute_bool: begin
          if (self.data_ready) begin
            if (value >= split_shifted) begin
              range <= range - split;
              value <= value - split_shifted;
            end else begin
              range <= split;
            end
            state <= State_idle;
          end
        end
      endcase
    end
  end

  always_comb begin
    mem_valid       = 1'b0;
    mem_data_ready  = 1'b0;
    self.data_valid = 1'b0;
    self.ready      = 1'b0;
    self.data       = 0;

    case (state) inside
      default: begin
      end
      State_init: begin
        if (init != 2) begin
          mem_valid      = 1'b1;
          mem_data_ready = 1'b1;
        end
      end
      State_idle: begin
        self.ready = 1'b1;
      end
      State_check_range: begin
        if (range < 128 && bit_count == 8) begin
          mem_valid = 1'b1;
        end
      end
      State_wait_byte: begin
        mem_data_ready = 1'b1;
      end
      State_compute_bool: begin
        self.data_valid = 1'b1;
        if (value < split_shifted) begin
          self.data = 1;
        end
      end
    endcase
  end
endmodule

module BoolDecoderTest (
    input var  logic                 clk,
    input var  logic                 rst,
    input var  logic                 mem_ready,
    output var logic                 mem_valid,
    input var  logic                 mem_data_valid,
    output var logic                 mem_data_ready,
    input var  byte unsigned         mem_data,
    output var logic                 self_ready,
    input var  logic                 self_valid,
    input var  logic         [8-1:0] self_prob,
    input var  logic                 self_data_ready,
    output var logic                 self_data_valid,
    output var logic                 self_data
);
  BoolDecoderIf self ();
  always_comb begin
    self_ready      = self.ready;
    self.valid      = self_valid;
    self.prob       = self_prob;
    self.data_ready = self_data_ready;
    self_data_valid = self.data_valid;
    self_data       = self.data;
  end

  BoolDecoder uut (
      .clk(clk),
      .rst(rst),
      .mem_ready(mem_ready),
      .mem_valid(mem_valid),
      .mem_data_valid(mem_data_valid),
      .mem_data_ready(mem_data_ready),
      .mem_data(mem_data),
      .self(self)
  );
endmodule
