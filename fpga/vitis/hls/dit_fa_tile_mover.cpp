#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>
#include <stdint.h>

using tile_word = ap_uint<128>;
using tile_axis = ap_axiu<128, 4, 0, 0>;

constexpr uint32_t kTileBeats = 128;
constexpr uint32_t kCacheQ = 0;
constexpr uint32_t kCacheK = 1;
constexpr uint32_t kCacheV = 2;

void stream_tile(
    const tile_word *input,
    uint32_t tile_offset,
    ap_uint<2> kind,
    ap_uint<1> bank,
    bool job_last,
    hls::stream<tile_axis> &tile_stream)
{
#pragma HLS INLINE
    for (uint32_t beat = 0; beat < kTileBeats; ++beat) {
#pragma HLS PIPELINE II=1
        tile_axis word;

        word.data = input[tile_offset + beat];
        word.keep = -1;
        word.strb = -1;
        word.user = (job_last ? 8 : 0)
            | (static_cast<ap_uint<4>>(bank) << 2)
            | kind;
        word.last = beat + 1 == kTileBeats;
        tile_stream.write(word);
    }
}

extern "C" void dit_fa_tile_mover(
    const tile_word *input,
    uint32_t q_offset_words,
    uint32_t k_offset_words,
    uint32_t v_offset_words,
    uint32_t q_head_count,
    uint32_t q_tile_count,
    uint32_t kv_tile_count,
    hls::stream<tile_axis> &tile_stream)
{
#pragma HLS INTERFACE m_axi port=input offset=slave bundle=gmem \
    max_read_burst_length=128 num_read_outstanding=8
#pragma HLS INTERFACE s_axilite port=input bundle=control
#pragma HLS INTERFACE s_axilite port=q_offset_words bundle=control
#pragma HLS INTERFACE s_axilite port=k_offset_words bundle=control
#pragma HLS INTERFACE s_axilite port=v_offset_words bundle=control
#pragma HLS INTERFACE s_axilite port=q_head_count bundle=control
#pragma HLS INTERFACE s_axilite port=q_tile_count bundle=control
#pragma HLS INTERFACE s_axilite port=kv_tile_count bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control
#pragma HLS INTERFACE axis port=tile_stream

    for (uint32_t head = 0; head < q_head_count; ++head) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=9
        const uint32_t q_head_offset = q_offset_words
            + head * q_tile_count * kTileBeats;
        const uint32_t k_head_offset = k_offset_words
            + head * kv_tile_count * kTileBeats;
        const uint32_t v_head_offset = v_offset_words
            + head * kv_tile_count * kTileBeats;

        for (uint32_t q_tile = 0; q_tile < q_tile_count; ++q_tile) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=32
            const uint32_t global_q_tile = head * q_tile_count + q_tile;
            stream_tile(
                input,
                q_head_offset + q_tile * kTileBeats,
                kCacheQ,
                global_q_tile & 1,
                false,
                tile_stream);

            for (uint32_t kv_tile = 0; kv_tile < kv_tile_count; ++kv_tile) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=32
                const uint32_t global_kv_tile = global_q_tile * kv_tile_count
                    + kv_tile;
                const ap_uint<1> bank = global_kv_tile & 1;
                stream_tile(
                    input,
                    k_head_offset + kv_tile * kTileBeats,
                    kCacheK,
                    bank,
                    false,
                    tile_stream);
                const bool job_last = head + 1 == q_head_count
                    && q_tile + 1 == q_tile_count
                    && kv_tile + 1 == kv_tile_count;
                stream_tile(
                    input,
                    v_head_offset + kv_tile * kTileBeats,
                    kCacheV,
                    bank,
                    job_last,
                    tile_stream);
            }
        }
    }
}
