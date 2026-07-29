#include <cstdint>

extern "C" void control_probe(std::uint32_t value)
{
#pragma HLS INTERFACE s_axilite port=value bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

    volatile std::uint32_t sink = value ^ 0x4354524c;
    (void)sink;
}
