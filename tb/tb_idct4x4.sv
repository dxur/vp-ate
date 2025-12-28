`timescale 1ns / 1ps
`include "rtl/idct4x4.sv"

module tb_idct4x4;

  logic clk = 0;
  logic rst = 1;

  always #5 clk = ~clk;

  logic      coeff_ready;
  logic      coeff_valid;
  block4x4_t coeff;

  logic      block_ready;
  logic      block_valid;
  block4x4_t block;

  idct4x4 dut (
      .clk(clk),
      .rst(rst),

      .coeff_ready(coeff_ready),
      .coeff_valid(coeff_valid),
      .coeff(coeff),

      .block_ready(block_ready),
      .block_valid(block_valid),
      .block(block)
  );

  initial begin
    static string fifo_path = "/dev/shm/tb";

    // Remove existing FIFO if it exists
    $system({"rm -f ", fifo_path});

    // Create a new FIFO
    if ($system({"mkfifo ", fifo_path}) != 0) begin
      $display("Error: Failed to create FIFO");
      $finish;
    end else begin
      $display("FIFO created at %s", fifo_path);
    end
  end

  initial begin
    $dumpfile("idct4x4_tb.vcd");
    $dumpvars(0, tb_idct4x4);

    coeff_valid = 0;
    block_ready = 0;

    coeff[0] = 10;
    coeff[1] = -5;
    coeff[2] = 3;
    coeff[3] = 1;
    coeff[4] = 0;
    coeff[5] = 2;
    coeff[6] = 1;
    coeff[7] = -2;
    coeff[8] = 4;
    coeff[9] = -3;
    coeff[10] = 8;
    coeff[11] = 0;
    coeff[12] = 5;
    coeff[13] = 1;
    coeff[14] = -1;
    coeff[15] = 2;

    #20 rst = 0;

    repeat (2) @(posedge clk);
    coeff_valid <= 1;
    wait (coeff_ready == 1);
    @(posedge clk);
    coeff_valid <= 0;
    block_ready <= 1;

    wait (block_valid == 1);
    @(posedge clk);

    // ----------------------------------------
    // Display results
    // ----------------------------------------
    $display("---- IDCT Output ----");
    for (int i = 0; i < 16; i = i + 1) $display("block[%0d] = %0d", i, block[i]);

    $display("----------------------");

    @(posedge clk);
    $finish;
  end

endmodule
