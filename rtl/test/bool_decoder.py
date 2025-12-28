import cocotb
from cocotb.triggers import Timer, RisingEdge

async def generate_clock(dut):
    for _ in range(10):
        dut.clk.value = 0
        await Timer(1, units="ns")
        dut.clk.value = 1
        await Timer(1, units="ns")

@cocotb.test()
async def bool_decoder_test(dut):
    cocotb.start_soon(generate_clock(dut))
    dut.rst.value = 0;
    await Timer(5, units="ns")
    dut.rst.value = 1;
    await RisingEdge(dut.clk)
    await Timer(50, units="ns")
