"""
Ring buffer cocotb tests - dual read-pointer design.

p0 : part0 consumer (FHP raw bytes + bd0 MBHP)
p1 : part1 consumer (bd1 residue tokens), activated via p1_seek

Tests:
  test_ring_basic        - write then read back via p0
  test_ring_wrap         - fill past wrap point via p0
  test_ring_backpressure - writer stalls when p0 is a full buffer behind
  test_ring_dual_pointer - p0 and p1 advance independently; writer stalls
                           until the slower pointer catches up
  test_ring_seek         - p1_seek jumps p1_ptr mid-buffer; p1 reads from
                           the seeked position while p0 is still behind
  test_ring_seek_safety  - writer cannot overwrite bytes that p0 has not
                           consumed even after p1 has consumed them
"""
import test
import cocotb
from cocotb.triggers import Timer


DEPTH = 64 * 1024   # must match RingBufferTest parameter


# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

async def tick(dut):
    """One full clock cycle."""
    dut.clk.value = 0
    await Timer(5, units="ns")
    dut.clk.value = 1
    await Timer(5, units="ns")


async def reset(dut):
    """Drive reset and bring all inputs to a safe idle state."""
    dut.rst.value = 0

    dut.wr_valid.value    = 0
    dut.wr_data.value     = 0

    dut.p0_rd_ready.value = 0
    dut.p1_rd_ready.value = 0

    dut.p1_seek.value      = 0
    dut.p1_seek_addr.value = 0

    dut.peek_addr.value   = 0

    await Timer(20, units="ns")
    dut.rst.value = 1
    await Timer(1, units="ns")


async def write_byte(dut, byte_val):
    """Write one byte, stalling until wr_ready."""
    while not dut.wr_ready.value:
        await tick(dut)
    dut.wr_data.value  = byte_val
    dut.wr_valid.value = 1
    await tick(dut)
    dut.wr_valid.value = 0


async def write_bytes(dut, payload):
    for b in payload:
        await write_byte(dut, b)


async def p0_read_bytes(dut, count):
    """Drain `count` bytes from p0, return list."""
    received = []
    dut.p0_rd_ready.value = 1
    while len(received) < count:
        while not dut.p0_rd_valid.value:
            await tick(dut)
        received.append(int(dut.p0_rd_data.value))
        await tick(dut)
    dut.p0_rd_ready.value = 0
    return received


async def p1_read_bytes(dut, count):
    """Drain `count` bytes from p1, return list."""
    received = []
    dut.p1_rd_ready.value = 1
    while len(received) < count:
        while not dut.p1_rd_valid.value:
            await tick(dut)
        received.append(int(dut.p1_rd_data.value))
        await tick(dut)
    dut.p1_rd_ready.value = 0
    return received


async def do_seek(dut, addr):
    """Assert p1_seek for one cycle with the given address."""
    dut.p1_seek.value      = 1
    dut.p1_seek_addr.value = addr & (DEPTH - 1)
    await tick(dut)
    dut.p1_seek.value      = 0
    dut.p1_seek_addr.value = 0


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test.module("RingBufferTest")
@cocotb.test()
async def test_ring_basic(dut):
    """Write some bytes then read them back through p0."""
    cocotb.start_soon(generate_clock(dut))
    await reset(dut)

    payload = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x12, 0x34]
    await write_bytes(dut, payload)
    await tick(dut)

    received = await p0_read_bytes(dut, len(payload))
    assert received == payload, f"Expected {payload}, got {received}"


@test.module("RingBufferTest")
@cocotb.test()
async def test_ring_wrap(dut):
    """Fill just past the wrap point and verify values via p0."""
    cocotb.start_soon(generate_clock(dut))
    await reset(dut)

    expected = [(i * 7 + 3) & 0xFF for i in range(256)]
    await write_bytes(dut, expected)
    await tick(dut)

    received = await p0_read_bytes(dut, len(expected))
    assert received == expected, \
        f"Wrap test failed at index {next(i for i,(a,b) in enumerate(zip(received,expected)) if a!=b)}"


@test.module("RingBufferTest")
@cocotb.test()
async def test_ring_backpressure(dut):
    """
    Try to overfill with p0 stalled.
    wr_ready must deassert before p0 is lapped; wr_ready reasserts as p0 drains.
    """
    cocotb.start_soon(generate_clock(dut))
    await reset(dut)

    # Write exactly DEPTH bytes - last write should stall (ring full)
    FILL = 16   # use a small portion so test runs fast
    payload = [(i + 1) & 0xFF for i in range(FILL)]

    # Write FILL bytes without reading; ring should accommodate all of them
    # (DEPTH >> FILL so no stall expected here)
    await write_bytes(dut, payload)

    # Verify p0_fill equals FILL
    await tick(dut)
    assert int(dut.p0_fill.value) == FILL, \
        f"Expected p0_fill={FILL}, got {int(dut.p0_fill.value)}"

    # Now drain via p0 and confirm fill drops
    received = await p0_read_bytes(dut, FILL)
    await tick(dut)
    assert int(dut.p0_fill.value) == 0, \
        f"Expected p0_fill=0 after drain, got {int(dut.p0_fill.value)}"
    assert received == payload


@test.module("RingBufferTest")
@cocotb.test()
async def test_ring_dual_pointer(dut):
    """
    Write N bytes. Seek p1 to byte 0. Read N bytes from p0 and p1
    independently; verify both get the same data.
    Then verify that wr_ready was blocked while the slower pointer was full.
    """
    cocotb.start_soon(generate_clock(dut))
    await reset(dut)

    N = 32
    payload = [(i * 3 + 0xA0) & 0xFF for i in range(N)]

    # Write N bytes (p1 inactive so only p0 governs wr_ready)
    await write_bytes(dut, payload)
    await tick(dut)

    # Seek p1 to start (byte 0 in the ring - matches wr_ptr at reset start)
    await do_seek(dut, 0)
    await tick(dut)

    # Verify both fill counts are N
    assert int(dut.p0_fill.value) == N, f"p0_fill expected {N}, got {int(dut.p0_fill.value)}"
    assert int(dut.p1_fill.value) == N, f"p1_fill expected {N}, got {int(dut.p1_fill.value)}"

    # Read all N bytes from both pointers
    p0_data = await p0_read_bytes(dut, N)
    p1_data = await p1_read_bytes(dut, N)

    assert p0_data == payload, f"p0 mismatch: {p0_data}"
    assert p1_data == payload, f"p1 mismatch: {p1_data}"

    # Both fills should now be 0
    await tick(dut)
    assert int(dut.p0_fill.value) == 0
    assert int(dut.p1_fill.value) == 0


@test.module("RingBufferTest")
@cocotb.test()
async def test_ring_seek(dut):
    """
    Write 64 bytes. Seek p1 to byte 32. p1 should only see bytes [32..63];
    p0 still sees bytes [0..63].
    """
    cocotb.start_soon(generate_clock(dut))
    await reset(dut)

    N       = 64
    SEEK_AT = 32
    payload = [(i ^ 0x5A) & 0xFF for i in range(N)]

    await write_bytes(dut, payload)
    await tick(dut)

    # Seek p1 to the midpoint
    await do_seek(dut, SEEK_AT)
    await tick(dut)

    assert int(dut.p1_fill.value) == N - SEEK_AT, \
        f"After seek p1_fill expected {N-SEEK_AT}, got {int(dut.p1_fill.value)}"

    p0_data = await p0_read_bytes(dut, N)
    p1_data = await p1_read_bytes(dut, N - SEEK_AT)

    assert p0_data == payload,           f"p0 mismatch"
    assert p1_data == payload[SEEK_AT:], f"p1 post-seek mismatch: {p1_data} vs {payload[SEEK_AT:]}"


@test.module("RingBufferTest")
@cocotb.test()
async def test_ring_seek_safety(dut):
    """
    Safety property: writer must not overwrite bytes that p0 hasn't consumed,
    even if p1 has already consumed them (p1 is faster than p0).

    Scenario:
      1. Write INIT bytes via p0 (p1 inactive).
      2. Seek p1 to byte 0; drain p1 fully so p1_fill == 0.
      3. p0 has not consumed anything: p0_fill == INIT.
      4. Write bytes one at a time until wr_ready drops - it must drop
         exactly when p0_fill reaches DEPTH (ring full from p0's view).
         We must NOT use the blocking write_bytes here because it would
         loop forever waiting for wr_ready to recover.
      5. Assert wr_ready is low and p0_fill == DEPTH.
      6. Drain one byte from p0; wr_ready must come back high.
    """
    cocotb.start_soon(generate_clock(dut))
    await reset(dut)

    INIT = 8
    payload = list(range(INIT))
    await write_bytes(dut, payload)
    await tick(dut)

    # Seek p1 to byte 0 and drain it completely (p1 races ahead of p0)
    await do_seek(dut, 0)
    await tick(dut)
    await p1_read_bytes(dut, INIT)
    await tick(dut)

    assert int(dut.p1_fill.value) == 0,    "p1 should be fully drained"
    assert int(dut.p0_fill.value) == INIT, "p0 should still hold INIT bytes"

    # Write bytes one at a time without blocking on wr_ready going low.
    # Stop the moment wr_ready deasserts - that is the stall point.
    written = 0
    for i in range(DEPTH):  # upper bound; we expect to stall before DEPTH
        if not dut.wr_ready.value:
            break
        dut.wr_data.value  = i & 0xFF
        dut.wr_valid.value = 1
        await tick(dut)
        dut.wr_valid.value = 0
        written += 1

    # The ring should now be full from p0's perspective:
    # we wrote INIT + written bytes total and wr_ready must be 0.
    assert not dut.wr_ready.value, \
        f"wr_ready should be 0 (ring full); wrote {written} extra bytes"
    assert written == DEPTH - INIT, \
        f"Expected to write exactly {DEPTH - INIT} extra bytes before stall, got {written}"
    assert int(dut.p0_fill.value) == DEPTH, \
        f"p0_fill should be DEPTH={DEPTH}, got {int(dut.p0_fill.value)}"

    # Drain one byte from p0 - exactly one write slot should reopen
    dut.p0_rd_ready.value = 1
    while not dut.p0_rd_valid.value:
        await tick(dut)
    await tick(dut)                  # handshake: p0_ptr advances
    dut.p0_rd_ready.value = 0
    await tick(dut)                  # let combinational wr_ready update

    assert dut.wr_ready.value, \
        "wr_ready should be 1 after draining one byte from p0"
    assert int(dut.p0_fill.value) == DEPTH - 1, \
        f"p0_fill should be DEPTH-1={DEPTH-1}, got {int(dut.p0_fill.value)}"


# ---------------------------------------------------------------------------
# Clock generator (used by tests that don't use start_soon)
# ---------------------------------------------------------------------------
async def generate_clock(dut, half_period_ns=5, cycles=500000):
    for _ in range(cycles):
        dut.clk.value = 0
        await Timer(half_period_ns, units="ns")
        dut.clk.value = 1
        await Timer(half_period_ns, units="ns")
