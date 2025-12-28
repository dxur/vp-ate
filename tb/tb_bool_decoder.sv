`timescale 1ns / 1ps

`include "rtl/fifo_if.svh"
`include "rtl/bool_decoder.sv"

module tb_bool_decoder;

  // Signals
  logic       clk;
  logic       rst;

  logic       mem_valid;
  logic       mem_ready;
  logic       mem_data_valid;
  logic       mem_data_ready;
  logic [7:0] mem_data;

  logic [7:0] bool_prob;
  logic       bool_valid;
  logic       bool_ready;

  logic       bool_data_valid;
  logic       bool_data_ready;
  logic       bool_data;

  // DUT
  bool_decoder dut (
      .clk(clk),
      .rst(rst),
      .mem_valid(mem_valid),
      .mem_ready(mem_ready),
      .mem_data_valid(mem_data_valid),
      .mem_data_ready(mem_data_ready),
      .mem_data(mem_data),
      .prob(bool_prob),
      .valid(bool_valid),
      .ready(bool_ready),
      .data_valid(bool_data_valid),
      .data_ready(bool_data_ready),
      .data(bool_data)
  );

  // Clock
  initial clk = 0;
  always #5 clk = ~clk;

  // Testbench Byte Source Model
  logic [7:0] byte_queue      [$];
  logic       request_pending;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      mem_ready       <= 0;
      mem_data_valid  <= 0;
      mem_data        <= '0;
      request_pending <= 0;

      // initialize the byte queue
      byte_queue = '{8'hAA, 8'h55, 8'hF0, 8'h0F, 8'h99, 8'h12, 8'hC3, 8'h3C};
    end else begin
      mem_ready <= 0;

      // Phase 1: DUT requests a byte
      if (mem_valid) begin
        mem_ready <= 1;
        request_pending <= 1;
      end

      // Phase 2: provide next byte
      if ((request_pending || mem_valid) && byte_queue.size() > 0) begin
        if (!mem_data_valid) begin
          mem_data       <= byte_queue[0];
          mem_data_valid <= 1;
        end
      end

      // Phase 3: DUT consumes the byte
      if (mem_data_valid && mem_data_ready) begin
        void'(byte_queue.pop_front());
        mem_data_valid  <= 0;
        request_pending <= 0;
      end
    end
  end

  // Task: Decode one bit
  task decode_bit(input [7:0] probability);
    begin
      wait (bool_ready);
      @(posedge clk);

      bool_valid      <= 1;
      bool_prob       <= probability;
      bool_data_ready <= 1;

      @(posedge clk);
      bool_valid <= 0;

      wait (bool_data_valid);
      @(posedge clk);  // capture result
    end
  endtask

  // Main TB
  initial begin
    $dumpfile("bool_decoder.vcd");
    $dumpvars(0, tb_bool_decoder);

    rst = 1;
    bool_valid = 0;
    bool_data_ready = 0;
    bool_prob = 0;

    repeat (10) @(posedge clk);
    rst = 0;
    $display("[%0t] Reset Released", $time);

    wait (dut.state_q == dut.ST_IDLE);
    $display("[%0t] DUT Initialized (Buffer Filled)", $time);
    repeat (5) @(posedge clk);

    $display("[%0t] Decoding with Prob 128", $time);
    decode_bit(8'd128);

    $display("[%0t] Decoding with Prob 200", $time);
    decode_bit(8'd200);

    $display("[%0t] Decoding with Prob 10", $time);
    decode_bit(8'd10);

    $display("[%0t] Starting Burst Decode...", $time);
    repeat (15) decode_bit(8'd128);

    $display("[%0t] Test Complete", $time);
    $finish;
  end

  // Monitor
  always @(posedge clk) begin
    if (bool_data_valid && bool_data_ready) begin
      $display("[%0t] RESULT: %b | Range: %h | Value: %h", $time, bool_data, dut.range_q,
               dut.value_q);
    end
  end

endmodule
