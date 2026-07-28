#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>
#include <stdint.h>

using tile_word = ap_uint<128>;
using tile_axis = ap_axiu<128, 0, 0, 0>;

extern "C" void dit_fa_tile_mover(
    const tile_word *input,
    uint32_t offset_words,
    uint32_t beat_count,
    hls::stream<tile_axis> &tile_stream)
{
#pragma HLS INTERFACE m_axi port=input offset=slave bundle=gmem \
    max_read_burst_length=64 num_read_outstanding=4
#pragma HLS INTERFACE s_axilite port=input bundle=control
#pragma HLS INTERFACE s_axilite port=offset_words bundle=control
#pragma HLS INTERFACE s_axilite port=beat_count bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control
#pragma HLS INTERFACE axis port=tile_stream

    for (uint32_t index = 0; index < beat_count; ++index) {
#pragma HLS PIPELINE II=1
        tile_axis word;

        word.data = input[offset_words + index];
        word.keep = -1;
        word.strb = -1;
        word.last = index + 1 == beat_count;
        tile_stream.write(word);
    }
}
