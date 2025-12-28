interface bus_if (
    input clk
);
  logic psel;
  modport dut(input psel);
endinterface

typedef struct packed {
  logic [7:0]  addr;
  logic [31:0] data;
  logic        valid;
} packet_t;

module my_module (
    input  packet_t in_packet,
    output packet_t out_packet
);

  always_comb begin
    if (in_packet.valid) begin
      out_packet.addr  = in_packet.addr + 1;
      out_packet.data  = in_packet.data * 2;
      out_packet.valid = 1;
    end else begin
      out_packet = '{default: '0};
    end
  end

endmodule

module test;
  int x;
  //task to add two integer numbers.
  task sum(input int a, b, output int c);
    c = a + b;
  endtask

  bus_if bus (clk);

  logic clk;
  always #5 clk = ~clk;

  initial begin
    @(posedge clk) x = 5;
    bus.psel = 0;

    $display("Start of initial block");
    fork
      // Process A
      begin
        #10;
        $display("Process A finished");
      end
      // Process B
      begin
        #5;
        $display("Process B finished");
      end
    join
    $display("End of initial block (after fork-join)");
  end
endmodule







