import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

class BoolDecoderMock:
    def __init__(self, dut):
        self.dut = dut
        self.queue = [] # Queue of bits to serve
        self.dut.bd_ready.value = 0
        self.dut.bd_data_valid.value = 0
        self.dut.bd_data.value = 0

    def append_bit(self, bit):
        self.queue.append(bit)

    async def run(self):
        self.dut.bd_ready.value = 1
        while True:
            await RisingEdge(self.dut.clk)
            
            # Default
            self.dut.bd_data_valid.value = 0
            
            # Check for request
            if self.dut.bd_valid.value:
                # Need to serve a bit
                
                # Check if we have data ready to be accepted
                # Actually, the protocol I defined:
                # User asserts valid/prob/data_ready. 
                # Self (Mock) sees valid, processes, asserts data_valid/data.
                # Since User asserts data_ready, we can complete in one cycle if we want, 
                # or wait.
                
                # For simplicity, if valid is high, we serve 'data_valid' in the next cycle (or same cycle if combinational? No, synced)
                # Let's serve next cycle.
                
                if len(self.queue) == 0:
                   raise Exception("BoolDecoderMock: Request received but queue empty!")
                
                bit = self.queue.pop(0)
                self.dut.bd_data.value = bit
                self.dut.bd_data_valid.value = 1
                
                # We expect User to assert data_ready.
                if not self.dut.bd_data_ready.value:
                     # Wait for data_ready? 
                     pass
            
            # If we just served data, invalid it next cycle (default above handles it)

@cocotb.test()
async def test_macroblock_parser_dc_pred(dut):
    """Test standard DC Prediction flow"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    bd_mock = BoolDecoderMock(dut)
    cocotb.start_soon(bd_mock.run())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    # Setup inputs
    dut.frame_ctx_prob_skip_false.value = 128
    dut.frame_ctx_mb_no_skip_coeff.value = 0
    
    dut.left_valid.value = 0
    dut.above_valid.value = 0
    dut.x.value = 0
    dut.y.value = 0
    dut.parser_ready.value = 1 # Always ready to accept result

    # Sequence of bits:
    # 1. Skip Coeff: 0 (false)
    # 2. Intra Y Mode: 0 (DcPred) -> Tree: 0 -> Leaf DcPred
    # 3. Intra UV Mode: 0 (DcPred) -> Tree: 0 -> Leaf DcPred
    
    bd_mock.append_bit(0) # Skip Coeff
    bd_mock.append_bit(0) # Y Mode (bit 0 -> DcPred)
    bd_mock.append_bit(0) # UV Mode (bit 0 -> DcPred)

    # Wait for valid
    while not dut.valid.value:
        await RisingEdge(dut.clk)

    # Check result
    assert dut.header_mb_skip_coeff.value == 0
    # Check IntraYMode::DcPred (Enum value 0)
    assert dut.header_intra_y_mode.value == 0 
    assert dut.header_intra_uv_mode.value == 0
    
    print("Test DC Pred Passed")

@cocotb.test()
async def test_macroblock_parser_v_pred(dut):
    """Test V Prediction flow"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    
    # We rely on the DUT reset state or we reset it
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    
    bd_mock = BoolDecoderMock(dut)
    cocotb.start_soon(bd_mock.run())

    dut.parser_ready.value = 1 

    # Sequence:
    # 1. Skip Coeff: 0
    # 2. Y Mode: VPred (Value 1)
    #    Tree: Root(0) -> bit 1 -> Node 2
    #          Node 2  -> bit 0 -> Leaf VPred
    # 3. Y Mode: VPred (Value 1) (Same for UV for simplicity)
    #    Tree: Root(0) -> bit 1 -> Node 2
    #          Node 2  -> bit 0 -> Leaf VPred
    
    bd_mock.append_bit(0)
    bd_mock.append_bit(1)
    bd_mock.append_bit(0)
    
    bd_mock.append_bit(1)
    bd_mock.append_bit(0)

    while not dut.valid.value:
        await RisingEdge(dut.clk)

    assert dut.header_intra_y_mode.value == 1 # VPred
    assert dut.header_intra_uv_mode.value == 1
    
    print("Test V Pred Passed")
