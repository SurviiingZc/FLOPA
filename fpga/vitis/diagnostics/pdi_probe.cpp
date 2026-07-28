#include <cstdint>

extern "C" void pdi_probe(std::uint32_t *memory)
{
#pragma HLS INTERFACE m_axi port=memory offset=slave bundle=gmem
#pragma HLS INTERFACE s_axilite port=memory bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

    memory[0] = 0x5044494d;
}
