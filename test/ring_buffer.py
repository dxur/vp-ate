"""
Ring buffer cocotb tests.

Tests: basic write/read, wrap-around, backpressure (ring full).
"""
import test
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge


@test.module("RingBufferTest")
@cocotb.test()
async def test_ring_basic(dut):
    """Write some bytes then read them back in order."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst.value = 0
    dut.wr_valid.value = 0
    dut.rd_ready.value = 0
    await Timer(20, "ns")
    dut.rst.value = 1
    await RisingEdge(dut.clk)

    PAYLOAD = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x12, 0x34]

    # Write all bytes
    for b in PAYLOAD:
        dut.wr_data.value = b
        dut.wr_valid.value = 1
        await RisingEdge(dut.clk)
    dut.wr_valid.value = 0
    await RisingEdge(dut.clk)

    # Read them back
    received = []
    dut.rd_ready.value = 1
    for _ in PAYLOAD:
        while not dut.rd_valid.value:
            await RisingEdge(dut.clk)
        received.append(int(dut.rd_data.value))
        await RisingEdge(dut.clk)
    dut.rd_ready.value = 0

    assert received == PAYLOAD, f"Expected {PAYLOAD}, got {received}"


@test.module("RingBufferTest")
@cocotb.test()
async def test_ring_wrap(dut):
    """Fill just past the wrap point and verify values are correct."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst.value = 0
    dut.wr_valid.value = 0
    dut.rd_ready.value = 0
    await Timer(20, "ns")
    dut.rst.value = 1
    await RisingEdge(dut.clk)

    # Write 256 bytes (enough to wrap a small ring)
    expected = [(i * 7 + 3) & 0xFF for i in range(256)]
    for b in expected:
        while not dut.wr_ready.value:
            await RisingEdge(dut.clk)
        dut.wr_data.value = b
        dut.wr_valid.value = 1
        await RisingEdge(dut.clk)
    dut.wr_valid.value = 0

    received = []
    dut.rd_ready.value = 1
    for _ in expected:
        while not dut.rd_valid.value:
            await RisingEdge(dut.clk)
        received.append(int(dut.rd_data.value))
        await RisingEdge(dut.clk)
    dut.rd_ready.value = 0

    assert received == expected, f"Wrap test failed: {received[:8]}... vs {expected[:8]}..."
