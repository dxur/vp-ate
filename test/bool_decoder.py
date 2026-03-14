"""
VP8 BoolDecoder cocotb test suite.

Strategy
--------
A pure-Python reference implementation (matching the Rust source exactly) is
kept in sync with the DUT.  Every decoded bit produced by the DUT is compared
against the reference.  Several test scenarios exercise:

  1. Basic decoding with 50 % probability across a stream of known bytes.
  2. Decoding with varying probabilities (all-zeros, all-ones, alternating).
  3. A stream long enough to force multiple byte refills during renormalisation.
  4. Back-to-back requests with no idle gap between booleans.
  5. A stall test where mem_ready / mem_data_valid are deliberately delayed.

Inter-test isolation
--------------------
cocotb v2 runs all tests in a single simulation — time never resets.
Two pitfalls fixed here vs. the original:

  1. Clock: starting `Clock(...)` inside every test accumulates coroutines.
     By the Nth test there are N clocks firing simultaneously, producing
     double edges and corrupted timing.  Fix: start the clock once per test
     and explicitly cancel the task before returning.

  2. MemoryModel: `stop()` only set a flag; the coroutine could linger into
     the next test and race against the fresh model.  Fix: `MemoryModel.start()`
     returns the cocotb Task so callers can `task.cancel()` and await it before
     the next scenario begins.
"""

import cocotb
from cocotb.triggers import RisingEdge
from cocotb.clock import Clock
import test  # project-local harness module


# ---------------------------------------------------------------------------
# Python reference – mirrors the Rust BoolDecoder exactly
# ---------------------------------------------------------------------------
class BoolDecoderRef:
    def __init__(self, data: bytes):
        self._buf = data
        self._pos = 0
        self._value = 0
        self._range = 255
        self._bit_count = 0

        # Seed: two bytes, big-endian (matches Rust: value = (value<<8)|byte)
        for _ in range(2):
            self._value = ((self._value << 8) | self._read_byte()) & 0xFFFF_FFFF

    def _read_byte(self) -> int:
        if self._pos >= len(self._buf):
            return 0  # VP8 pads with zeros beyond end of partition
        b = self._buf[self._pos]
        self._pos += 1
        return b

    def read_bool(self, prob: int) -> int:
        split = 1 + (((self._range - 1) * prob) >> 8)
        split_shifted = split << 8

        if self._value >= split_shifted:
            bit = 1
            self._range -= split
            self._value -= split_shifted
        else:
            bit = 0
            self._range = split

        # Renormalise
        while self._range < 128:
            self._value <<= 1
            self._range <<= 1
            self._bit_count += 1
            if self._bit_count == 8:
                self._bit_count = 0
                self._value = (self._value | self._read_byte()) & 0xFFFF_FFFF

        return bit


# ---------------------------------------------------------------------------
# Memory model – feeds bytes to the DUT one at a time, honouring the
# valid/ready handshake on both the request and data channels.
# ---------------------------------------------------------------------------
class MemoryModel:
    def __init__(self, dut, data: bytes, req_latency: int = 1,
                 data_latency: int = 1):
        """
        req_latency  – cycles after mem_valid seen before mem_ready asserted
        data_latency – cycles after request accepted before mem_data_valid
        """
        self._dut = dut
        self._data = data
        self._pos = 0
        self._req_latency = req_latency
        self._data_latency = data_latency

    def start(self):
        """Launch the model coroutine and return the Task for cancellation."""
        return cocotb.start_soon(self._run())

    async def _run(self):
        dut = self._dut
        dut.mem_ready.value = 0
        dut.mem_data_valid.value = 0
        dut.mem_data.value = 0

        while True:
            await RisingEdge(dut.clk)

            if dut.mem_valid.value != 1:
                continue

            # Request phase: honour req_latency then assert mem_ready
            for _ in range(self._req_latency - 1):
                await RisingEdge(dut.clk)
            dut.mem_ready.value = 1
            await RisingEdge(dut.clk)
            dut.mem_ready.value = 0

            # Data phase: honour data_latency then present the byte
            for _ in range(self._data_latency - 1):
                await RisingEdge(dut.clk)

            byte = self._data[self._pos] if self._pos < len(self._data) else 0
            self._pos += 1
            dut.mem_data.value = byte
            dut.mem_data_valid.value = 1

            # Wait until DUT accepts (mem_data_ready high on a rising edge)
            while True:
                await RisingEdge(dut.clk)
                if dut.mem_data_ready.value == 1:
                    break
            dut.mem_data_valid.value = 0
            dut.mem_data.value = 0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
async def reset(dut, cycles: int = 3):
    """Hard reset the DUT and clear all input signals."""
    dut.rst.value = 0
    dut.self_valid.value = 0
    dut.self_prob.value = 128
    dut.self_data_ready.value = 0
    dut.mem_ready.value = 0
    dut.mem_data_valid.value = 0
    dut.mem_data.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)


async def wait_ready(dut, timeout: int = 500):
    """Wait until self_ready is asserted (DUT ready for a new request)."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.self_ready.value == 1:
            return
    raise TimeoutError("DUT never asserted self_ready")


async def decode_one(dut, prob: int, timeout: int = 500) -> int:
    """
    Issue one decode request and return the decoded bit.
    Assumes DUT is already in idle (self_ready=1).
    """
    dut.self_prob.value = prob
    dut.self_valid.value = 1
    dut.self_data_ready.value = 1

    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.self_data_valid.value == 1:
            bit = int(dut.self_data.value)
            dut.self_valid.value = 0
            await wait_ready(dut, timeout)
            return bit

    raise TimeoutError(f"DUT never produced data_valid for prob={prob}")


async def run_scenario(dut, data: bytes, probs, req_lat=1, data_lat=1,
                       label=""):
    """
    Full scenario: reset DUT, start a fresh memory model, decode len(probs)
    booleans comparing each against the Python reference, then cancel the
    memory model task so it cannot bleed state into the next test.
    """
    ref = BoolDecoderRef(data)
    mem = MemoryModel(dut, data, req_latency=req_lat, data_latency=data_lat)

    # Reset FIRST: while rst is low the DUT's combinational block still
    # asserts mem_valid (State_init, init<2). Starting the memory model
    # before reset lets it see those spurious requests and burn stream
    # bytes before the DUT has actually left reset, corrupting value init.
    await reset(dut)
    mem_task = mem.start()
    await wait_ready(dut)

    for i, prob in enumerate(probs):
        ref_bit = ref.read_bool(prob)
        dut_bit = await decode_one(dut, prob)
        assert dut_bit == ref_bit, (
            f"[{label}] bit {i}: prob={prob} → DUT={dut_bit} REF={ref_bit}"
        )

    # Cancel the memory model and wait for the task to finish so there is no
    # lingering coroutine when the next test's memory model starts.
    mem_task.cancel()
    try:
        await mem_task
    except Exception:
        pass

    # Drive memory outputs idle so the next test begins with clean signals.
    dut.mem_ready.value = 0
    dut.mem_data_valid.value = 0
    dut.mem_data.value = 0

    cocotb.log.info(f"[{label}] PASS – decoded {len(probs)} bits correctly")


# ---------------------------------------------------------------------------
# Test 1 – Basic 50/50 decode, minimal latency
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_basic_50pct(dut):
    """Decode 16 bits from a known byte stream at prob=128 (50/50)."""
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    data = bytes([0xAB, 0xCD, 0x00, 0x00, 0x00, 0x00])
    probs = [128] * 16

    await run_scenario(dut, data, probs, label="basic_50pct")
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 2 – Varying probabilities
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_varying_probs(dut):
    """
    Decode with a range of probabilities including extremes (1, 254)
    and mid-points to stress the split arithmetic.
    """
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    data = bytes([0x55, 0xAA, 0xFF, 0x00, 0x12, 0x34, 0x56, 0x78])
    probs = [1, 10, 50, 100, 128, 150, 200, 254,
             128, 64, 32, 192, 220, 5, 128, 128]

    await run_scenario(dut, data, probs, label="varying_probs")
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 3 – Long stream forcing many byte refills
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_long_stream(dut):
    """Decode 64 bits to force several renormalisation refill cycles."""
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    # Fixed seed — deterministic regardless of random module state.
    data = bytes([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x23, 0x45, 0x67,
                  0x89, 0xAB, 0xCD, 0xEF])
    probs = [128] * 64

    await run_scenario(dut, data, probs, label="long_stream")
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 4 – Alternating high/low probability
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_alternating_probs(dut):
    """Stress split calculation with alternating extreme probabilities."""
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    data = bytes([0x7F, 0x80, 0x01, 0xFE, 0x55, 0xAA, 0x00, 0xFF])
    probs = [254, 1] * 16  # 32 booleans, alternating

    await run_scenario(dut, data, probs, label="alternating_probs")
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 5 – Stalled memory (multi-cycle latency on request and data)
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_stalled_memory(dut):
    """
    Memory responds slowly (3-cycle request latency, 4-cycle data latency).
    The DUT must stall correctly and still produce correct bits.
    """
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    data = bytes([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
    probs = [128, 64, 192, 32, 224, 16, 240, 128,
             100, 200, 50, 150, 75, 175, 128, 128]

    await run_scenario(dut, data, probs,
                       req_lat=3, data_lat=4,
                       label="stalled_memory")
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 6 – Decode immediately after reset (no extra idle cycles)
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_decode_after_reset(dut):
    """Issue decode as soon as DUT becomes ready post-reset."""
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    data = bytes([0xC3, 0x3C, 0x00, 0x00])
    probs = [128, 128, 128, 128, 128, 128, 128, 128]

    await run_scenario(dut, data, probs, label="after_reset")
    clk_task.cancel()
