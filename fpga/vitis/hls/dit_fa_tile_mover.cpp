#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>
#include <stdint.h>

using tile_word = ap_uint<128>;
using tile_axis = ap_axiu<128, 4, 0, 0>;

constexpr uint32_t kTileBeats = 128;
constexpr uint32_t kTilesPerHead = 10;
constexpr uint32_t kCacheQ = 0;
constexpr uint32_t kCacheK = 1;
constexpr uint32_t kCacheV = 2;

extern "C" void dit_fa_tile_mover(
    const tile_word *input,
    uint32_t q_offset_words,
    uint32_t k_offset_words,
    uint32_t v_offset_words,
    uint32_t q_head_count,
    hls::stream<tile_axis> &tile_stream)
{
#pragma HLS INTERFACE m_axi port=input offset=slave bundle=gmem \
    max_read_burst_length=128 num_read_outstanding=8
#pragma HLS INTERFACE s_axilite port=input bundle=control
#pragma HLS INTERFACE s_axilite port=q_offset_words bundle=control
#pragma HLS INTERFACE s_axilite port=k_offset_words bundle=control
#pragma HLS INTERFACE s_axilite port=v_offset_words bundle=control
#pragma HLS INTERFACE s_axilite port=q_head_count bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control
#pragma HLS INTERFACE axis port=tile_stream

    const ap_uint<2> kinds[kTilesPerHead] = {
        kCacheQ, kCacheK, kCacheV, kCacheK, kCacheV,
        kCacheQ, kCacheK, kCacheV, kCacheK, kCacheV,
    };
    const ap_uint<1> banks[kTilesPerHead] = {
        0, 0, 0, 1, 1, 1, 0, 0, 1, 1,
    };
    const ap_uint<1> tile_indices[kTilesPerHead] = {
        0, 0, 0, 1, 1, 1, 0, 0, 1, 1,
    };
    for (uint32_t head = 0; head < q_head_count; ++head) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=9
        const uint32_t q_head_offset = q_offset_words + head * 2 * kTileBeats;
        const uint32_t k_head_offset = k_offset_words + head * 2 * kTileBeats;
        const uint32_t v_head_offset = v_offset_words + head * 2 * kTileBeats;

        for (uint32_t tile = 0; tile < kTilesPerHead; ++tile) {
#pragma HLS LOOP_TRIPCOUNT min=10 max=10
            uint32_t tensor_offset = v_head_offset;

            if (kinds[tile] == kCacheQ) {
                tensor_offset = q_head_offset;
            } else if (kinds[tile] == kCacheK) {
                tensor_offset = k_head_offset;
            }
            const uint32_t tile_offset = tensor_offset
                + static_cast<uint32_t>(tile_indices[tile]) * kTileBeats;

            for (uint32_t beat = 0; beat < kTileBeats; ++beat) {
#pragma HLS PIPELINE II=1
                tile_axis word;

                word.data = input[tile_offset + beat];
                word.keep = -1;
                word.strb = -1;
                word.user = (head + 1 == q_head_count
                             && tile + 1 == kTilesPerHead ? 8 : 0)
                    | (static_cast<ap_uint<4>>(banks[tile]) << 2)
                    | kinds[tile];
                word.last = beat + 1 == kTileBeats;
                tile_stream.write(word);
            }
        }
    }
}
