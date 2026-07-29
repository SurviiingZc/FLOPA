#include "pl_attention.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "experimental/xrt_bo.h"
#include "experimental/xrt_device.h"
#include "experimental/xrt_ip.h"
#include "experimental/xrt_kernel.h"

namespace {

constexpr std::uint32_t kAttentionControl = 0x000;
constexpr std::uint32_t kAttentionStatus = 0x004;
constexpr std::uint32_t kAttentionError = 0x008;
constexpr std::uint32_t kAttentionQBaseLow = 0x010;
constexpr std::uint32_t kAttentionQBaseHigh = 0x014;
constexpr std::uint32_t kAttentionKBaseLow = 0x018;
constexpr std::uint32_t kAttentionKBaseHigh = 0x01c;
constexpr std::uint32_t kAttentionVBaseLow = 0x020;
constexpr std::uint32_t kAttentionVBaseHigh = 0x024;
constexpr std::uint32_t kAttentionOBaseLow = 0x028;
constexpr std::uint32_t kAttentionOBaseHigh = 0x02c;
constexpr std::uint32_t kAttentionQStride = 0x030;
constexpr std::uint32_t kAttentionKStride = 0x034;
constexpr std::uint32_t kAttentionVStride = 0x038;
constexpr std::uint32_t kAttentionOStride = 0x03c;
constexpr std::uint32_t kAttentionSeqQ = 0x040;
constexpr std::uint32_t kAttentionSeqKv = 0x044;
constexpr std::uint32_t kAttentionNumQHeads = 0x048;
constexpr std::uint32_t kAttentionNumKvHeads = 0x04c;
constexpr std::uint32_t kAttentionHeadDim = 0x050;
constexpr std::uint32_t kAttentionTileQ = 0x054;
constexpr std::uint32_t kAttentionTileK = 0x058;
constexpr std::uint32_t kAttentionMode = 0x05c;
constexpr std::uint32_t kAttentionScoreScale = 0x060;
constexpr std::uint32_t kAttentionValueScale = 0x064;
constexpr std::uint32_t kAttentionOutScale = 0x068;
constexpr std::uint32_t kAttentionMask = 0x06c;
constexpr std::uint32_t kAttentionPerfControl = 0x070;
constexpr std::uint32_t kAttentionPerfCyclesLow = 0x074;
constexpr std::uint32_t kAttentionPerfCyclesHigh = 0x078;

constexpr std::uint32_t kLoaderBase = 0x100;
constexpr std::uint32_t kLoaderControl = kLoaderBase + 0x000;
constexpr std::uint32_t kLoaderStatus = kLoaderBase + 0x004;
constexpr std::uint32_t kLoaderTiles = kLoaderBase + 0x018;

constexpr std::uint32_t kAttentionStart = 1U << 0;
constexpr std::uint32_t kAttentionSoftReset = 1U << 1;
constexpr std::uint32_t kAttentionClearDone = 1U << 2;
constexpr std::uint32_t kAttentionClearError = 1U << 3;
constexpr std::uint32_t kAttentionCausal = 1U << 5;
constexpr std::uint32_t kAttentionPrefill = 1U << 6;
constexpr std::uint32_t kAttentionDone = 1U << 1;
constexpr std::uint32_t kAttentionErrorStatus = 1U << 2;

constexpr std::uint32_t kLoaderStart = 1U << 0;
constexpr std::uint32_t kLoaderAbort = 1U << 1;
constexpr std::uint32_t kLoaderClearDone = 1U << 2;
constexpr std::uint32_t kLoaderClearError = 1U << 3;
constexpr std::uint32_t kLoaderError = 1U << 2;

constexpr std::uint32_t kHeadDim = 64;
constexpr std::uint32_t kQHeads = 9;
constexpr std::uint32_t kModelKvHeads = 3;
constexpr std::uint32_t kKvCopies = kQHeads / kModelKvHeads;
static_assert(kQHeads % kModelKvHeads == 0, "Q/KV head ratio must be integral");
constexpr std::uint32_t kTileRows = 32;
constexpr std::uint32_t kMaximumSequenceLength = 1024;
constexpr std::uint32_t kTileBytes = kTileRows * kHeadDim;
constexpr std::uint32_t kTimeoutMs = 5000;
constexpr std::uint32_t kInitialTiles = 3;

struct Geometry {
    explicit Geometry(std::uint32_t sequence_length)
        : seq(sequence_length)
    {
        if (seq == 0 || seq > kMaximumSequenceLength || seq % kTileRows != 0) {
            throw std::runtime_error(
                "PL sequence length must be a multiple of 32 in [32, 1024]");
        }
        tile_count = seq / kTileRows;
        const std::uint64_t schedule = static_cast<std::uint64_t>(kQHeads)
            * tile_count * (1 + 2 * tile_count);
        if (schedule > std::numeric_limits<std::uint16_t>::max()) {
            throw std::runtime_error("PL sequence length exceeds the loader tile counter");
        }

        tensor_bytes = seq * kHeadDim;
        q_offset = 0;
        k_offset = q_offset + kQHeads * tensor_bytes;
        v_offset = k_offset + kQHeads * tensor_bytes;
        o_offset = v_offset + kQHeads * tensor_bytes;
        output_bytes = kQHeads * tensor_bytes;
        buffer_bytes = o_offset + output_bytes;
        schedule_tiles = static_cast<std::uint32_t>(schedule);
    }

    std::uint32_t seq;
    std::uint32_t tile_count = 0;
    std::uint32_t tensor_bytes = 0;
    std::uint32_t q_offset = 0;
    std::uint32_t k_offset = 0;
    std::uint32_t v_offset = 0;
    std::uint32_t o_offset = 0;
    std::uint32_t output_bytes = 0;
    std::uint32_t buffer_bytes = 0;
    std::uint32_t schedule_tiles = 0;
};

std::uint32_t packed_input_index(std::uint32_t row, std::uint32_t element)
{
    const std::uint32_t tile = row / kTileRows;
    const std::uint32_t local_row = row % kTileRows;
    return tile * kTileBytes + element * kTileRows + local_row;
}

std::uint64_t join_u64(std::uint32_t low, std::uint32_t high)
{
    return (static_cast<std::uint64_t>(high) << 32) | low;
}

float tensor_value(
    const ggml_tensor *tensor,
    std::int64_t element,
    std::int64_t row,
    std::int64_t head)
{
    const auto *address = static_cast<const char *>(tensor->data)
        + element * tensor->nb[0]
        + row * tensor->nb[1]
        + head * tensor->nb[2];
    if (tensor->type == GGML_TYPE_F32) {
        float value = 0.0F;
        std::memcpy(&value, address, sizeof(value));
        return value;
    }
    if (tensor->type == GGML_TYPE_F16) {
        ggml_fp16_t value = 0;
        std::memcpy(&value, address, sizeof(value));
        return ggml_fp16_to_fp32(value);
    }
    throw std::runtime_error("PL attention requires F32 or F16 Q/K/V tensors");
}

float quantize_expanded_heads(
    const ggml_tensor *tensor,
    std::uint32_t source_head_count,
    std::uint32_t copies_per_head,
    std::uint32_t sequence_length,
    std::uint32_t tensor_bytes,
    std::int8_t *output)
{
    float max_absolute = 0.0F;
    const bool dense_f32 = tensor->type == GGML_TYPE_F32
        && tensor->nb[0] == sizeof(float)
        && tensor->nb[1] == kHeadDim * sizeof(float)
        && tensor->nb[2] == sequence_length * kHeadDim * sizeof(float);
    const bool dense_f16 = tensor->type == GGML_TYPE_F16
        && tensor->nb[0] == sizeof(ggml_fp16_t)
        && tensor->nb[1] == kHeadDim * sizeof(ggml_fp16_t)
        && tensor->nb[2] == sequence_length * kHeadDim * sizeof(ggml_fp16_t);
    const auto *dense_f32_values = dense_f32
        ? static_cast<const float *>(tensor->data)
        : nullptr;
    const auto *dense_f16_values = dense_f16
        ? static_cast<const ggml_fp16_t *>(tensor->data)
        : nullptr;

    if (dense_f32) {
        const std::size_t value_count = static_cast<std::size_t>(source_head_count)
            * sequence_length * kHeadDim;
        for (std::size_t index = 0; index < value_count; ++index) {
            max_absolute = std::max(
                max_absolute,
                std::fabs(dense_f32_values[index]));
        }
    } else if (dense_f16) {
        const std::size_t value_count = static_cast<std::size_t>(source_head_count)
            * sequence_length * kHeadDim;
        for (std::size_t index = 0; index < value_count; ++index) {
            max_absolute = std::max(
                max_absolute,
                std::fabs(ggml_fp16_to_fp32(dense_f16_values[index])));
        }
    } else {
        for (std::uint32_t head = 0; head < source_head_count; ++head) {
            for (std::uint32_t row = 0; row < sequence_length; ++row) {
                for (std::uint32_t element = 0; element < kHeadDim; ++element) {
                    max_absolute = std::max(
                        max_absolute,
                        std::fabs(tensor_value(tensor, element, row, head)));
                }
            }
        }
    }

    const float scale = max_absolute == 0.0F ? 1.0F : max_absolute / 127.0F;
    const float inverse_scale = 1.0F / scale;
    for (std::uint32_t source_head = 0;
         source_head < source_head_count;
         ++source_head) {
        const std::uint32_t first_output_head = source_head * copies_per_head;
        const std::uint32_t head_offset = first_output_head * tensor_bytes;
        const float *dense_f32_head = dense_f32
            ? dense_f32_values + source_head * tensor_bytes
            : nullptr;
        const ggml_fp16_t *dense_f16_head = dense_f16
            ? dense_f16_values + source_head * tensor_bytes
            : nullptr;
        for (std::uint32_t row = 0; row < sequence_length; ++row) {
            for (std::uint32_t element = 0; element < kHeadDim; ++element) {
                float value = 0.0F;
                if (dense_f32) {
                    value = dense_f32_head[row * kHeadDim + element];
                } else if (dense_f16) {
                    value = ggml_fp16_to_fp32(
                        dense_f16_head[row * kHeadDim + element]);
                } else {
                    value = tensor_value(tensor, element, row, source_head);
                }
                const long rounded = std::lround(value * inverse_scale);
                const long clamped = std::max(-127L, std::min(127L, rounded));
                output[head_offset + packed_input_index(row, element)] =
                    static_cast<std::int8_t>(clamped);
            }
        }
        for (std::uint32_t copy = 1; copy < copies_per_head; ++copy) {
            std::memcpy(
                output + (first_output_head + copy) * tensor_bytes,
                output + head_offset,
                tensor_bytes);
        }
    }
    return scale;
}

std::uint32_t pack_scale(float factor)
{
    if (!(factor >= 0.0F) || !std::isfinite(factor)) {
        throw std::runtime_error("invalid attention score scale");
    }
    if (factor == 0.0F) {
        return 0;
    }

    std::uint32_t selected_shift = 0;
    std::uint32_t selected_mantissa = 0;
    for (std::uint32_t shift = 0; shift <= 63; ++shift) {
        const double scaled = std::ldexp(static_cast<double>(factor), shift);
        const long long mantissa = std::llround(scaled);
        if (mantissa > 32767) {
            break;
        }
        if (mantissa > 0) {
            selected_shift = shift;
            selected_mantissa = static_cast<std::uint32_t>(mantissa);
        }
    }
    if (selected_mantissa == 0) {
        throw std::runtime_error("attention score scale is below hardware precision");
    }
    return (selected_shift << 16) | selected_mantissa;
}

std::string tensor_layout(const char *name, const ggml_tensor *tensor)
{
    std::ostringstream output;
    output << name << " ne=[";
    for (int dimension = 0; dimension < GGML_MAX_DIMS; ++dimension) {
        output << (dimension == 0 ? "" : ",") << tensor->ne[dimension];
    }
    output << "] nb=[";
    for (int dimension = 0; dimension < GGML_MAX_DIMS; ++dimension) {
        output << (dimension == 0 ? "" : ",") << tensor->nb[dimension];
    }
    output << "] type=" << ggml_type_name(tensor->type);
    return output.str();
}

void check_tensor_contract(const ggml_tensor *node, std::uint32_t sequence_length)
{
    if (node->op != GGML_OP_FLASH_ATTN_EXT) {
        throw std::runtime_error("PL callback received a non-attention node");
    }
    const ggml_tensor *q = node->src[0];
    const ggml_tensor *k = node->src[1];
    const ggml_tensor *v = node->src[2];
    const ggml_tensor *mask = node->src[3];
    if (q == nullptr || k == nullptr || v == nullptr || mask == nullptr) {
        throw std::runtime_error("PL attention requires Q, K, V, and causal mask tensors");
    }
    if (q->ne[0] != kHeadDim || q->ne[1] != sequence_length || q->ne[2] != kQHeads
        || q->ne[3] != 1 || k->ne[0] != kHeadDim || k->ne[1] < sequence_length
        || k->ne[2] != kModelKvHeads || k->ne[3] != 1 || v->ne[0] != kHeadDim
        || v->ne[1] < sequence_length || v->ne[2] != kModelKvHeads || v->ne[3] != 1) {
        throw std::runtime_error(
            "PL attention tensor shape does not match the configured sequence: "
            + tensor_layout("Q", q) + "; " + tensor_layout("K", k) + "; "
            + tensor_layout("V", v) + "; " + tensor_layout("O", node));
    }
    if (node->type != GGML_TYPE_F32 || node->ne[0] != kHeadDim
        || node->ne[1] != kQHeads || node->ne[2] != sequence_length
        || node->ne[3] != 1) {
        throw std::runtime_error("PL attention output tensor layout is unsupported");
    }
}

} // namespace

class PlAttention::Impl {
public:
    Impl(const std::string &xclbin_path, std::uint32_t sequence_length)
        : geometry_(sequence_length),
          device_(0),
          uuid_(device_.load_xclbin(xclbin_path)),
          accelerator_(device_, uuid_, "dit_fa:{dit_fa_1}"),
          mover_(device_, uuid_, "dit_fa_tile_mover:{dit_fa_tile_mover_1}"),
          mover_run_(mover_),
          buffer_(device_, geometry_.buffer_bytes, xrt::bo::flags::normal, 0),
          data_(buffer_.map<std::int8_t *>()),
          buffer_address_(buffer_.address())
    {
        if (buffer_address_ > std::numeric_limits<std::uint32_t>::max()
            || buffer_address_ + geometry_.buffer_bytes - 1
                > std::numeric_limits<std::uint32_t>::max()) {
            throw std::runtime_error("XRT BO is above the RTL 32-bit write address range");
        }
        program_static_job();
        mover_run_.set_arg(0, buffer_);
        mover_run_.set_arg(1, geometry_.q_offset / 16);
        mover_run_.set_arg(2, geometry_.k_offset / 16);
        mover_run_.set_arg(3, geometry_.v_offset / 16);
        mover_run_.set_arg(4, kQHeads);
        mover_run_.set_arg(5, geometry_.tile_count);
        mover_run_.set_arg(6, geometry_.tile_count);
    }

    void execute(ggml_tensor *node)
    {
        check_tensor_contract(node, geometry_.seq);
        const auto start = std::chrono::steady_clock::now();
        float kq_scale = 0.0F;
        std::memcpy(&kq_scale, node->op_params, sizeof(kq_scale));

        const ggml_tensor *q = node->src[0];
        const ggml_tensor *k = node->src[1];
        const ggml_tensor *v = node->src[2];
        const auto quantize_start = std::chrono::steady_clock::now();
        const float q_scale = quantize_expanded_heads(
            q,
            kQHeads,
            1,
            geometry_.seq,
            geometry_.tensor_bytes,
            data_ + geometry_.q_offset);
        const float k_scale = quantize_expanded_heads(
            k,
            kModelKvHeads,
            kKvCopies,
            geometry_.seq,
            geometry_.tensor_bytes,
            data_ + geometry_.k_offset);
        const float v_scale = quantize_expanded_heads(
            v,
            kModelKvHeads,
            kKvCopies,
            geometry_.seq,
            geometry_.tensor_bytes,
            data_ + geometry_.v_offset);
        const auto quantize_end = std::chrono::steady_clock::now();

        const auto input_sync_start = quantize_end;
        buffer_.sync(XCL_BO_SYNC_BO_TO_DEVICE, geometry_.o_offset, 0);
        const auto input_sync_end = std::chrono::steady_clock::now();

        const auto setup_start = input_sync_end;
        reset_hardware();
        program_dynamic_job(pack_scale(q_scale * k_scale * kq_scale * 256.0F));
        const auto setup_end = std::chrono::steady_clock::now();

        const auto hardware_start = setup_end;
        run_workload();
        const auto node_cycles = join_u64(
            accelerator_.read_register(kAttentionPerfCyclesLow),
            accelerator_.read_register(kAttentionPerfCyclesHigh));
        const auto hardware_end = std::chrono::steady_clock::now();

        const auto output_sync_start = hardware_end;
        buffer_.sync(
            XCL_BO_SYNC_BO_FROM_DEVICE,
            geometry_.output_bytes,
            geometry_.o_offset);
        const auto output_sync_end = std::chrono::steady_clock::now();

        const auto dequantize_start = output_sync_end;
        write_output(node, v_scale);
        const auto end = std::chrono::steady_clock::now();

        const auto elapsed = [](const auto &begin, const auto &finish) {
            return std::chrono::duration<double, std::milli>(finish - begin).count();
        };
        const double quantize_ms = elapsed(quantize_start, quantize_end);
        const double input_sync_ms = elapsed(input_sync_start, input_sync_end);
        const double setup_ms = elapsed(setup_start, setup_end);
        const double hardware_wait_ms = elapsed(hardware_start, hardware_end);
        const double output_sync_ms = elapsed(output_sync_start, output_sync_end);
        const double dequantize_ms = elapsed(dequantize_start, end);
        const double elapsed_ms = elapsed(start, end);

        stats_.accelerator_cycles += node_cycles;
        ++stats_.attention_nodes;
        stats_.elapsed_ms += elapsed_ms;
        stats_.quantize_ms += quantize_ms;
        stats_.input_sync_ms += input_sync_ms;
        stats_.setup_ms += setup_ms;
        stats_.hardware_wait_ms += hardware_wait_ms;
        stats_.output_sync_ms += output_sync_ms;
        stats_.dequantize_ms += dequantize_ms;
        stats_.node_accelerator_cycles.push_back(node_cycles);
        stats_.node_elapsed_ms.push_back(elapsed_ms);
        stats_.node_quantize_ms.push_back(quantize_ms);
        stats_.node_input_sync_ms.push_back(input_sync_ms);
        stats_.node_setup_ms.push_back(setup_ms);
        stats_.node_hardware_wait_ms.push_back(hardware_wait_ms);
        stats_.node_output_sync_ms.push_back(output_sync_ms);
        stats_.node_dequantize_ms.push_back(dequantize_ms);
    }

    const PlAttentionStats &stats() const
    {
        return stats_;
    }

    void reset_stats()
    {
        stats_ = {};
    }

private:
    void write_address(
        std::uint32_t low_register,
        std::uint32_t high_register,
        std::uint64_t address)
    {
        accelerator_.write_register(low_register, static_cast<std::uint32_t>(address));
        accelerator_.write_register(
            high_register,
            static_cast<std::uint32_t>(address >> 32));
    }

    void reset_hardware()
    {
        accelerator_.write_register(
            kAttentionControl,
            kAttentionSoftReset | kAttentionClearDone | kAttentionClearError);
        accelerator_.write_register(
            kLoaderControl,
            kLoaderAbort | kLoaderClearDone | kLoaderClearError);
    }

    void program_static_job()
    {
        write_address(
            kAttentionQBaseLow,
            kAttentionQBaseHigh,
            buffer_address_ + geometry_.q_offset);
        write_address(
            kAttentionKBaseLow,
            kAttentionKBaseHigh,
            buffer_address_ + geometry_.k_offset);
        write_address(
            kAttentionVBaseLow,
            kAttentionVBaseHigh,
            buffer_address_ + geometry_.v_offset);
        write_address(
            kAttentionOBaseLow,
            kAttentionOBaseHigh,
            buffer_address_ + geometry_.o_offset);

        accelerator_.write_register(kAttentionQStride, kHeadDim);
        accelerator_.write_register(kAttentionKStride, kHeadDim);
        accelerator_.write_register(kAttentionVStride, kHeadDim);
        accelerator_.write_register(kAttentionOStride, kHeadDim);
        accelerator_.write_register(kAttentionSeqQ, geometry_.seq);
        accelerator_.write_register(kAttentionSeqKv, geometry_.seq);
        accelerator_.write_register(kAttentionNumQHeads, kQHeads);
        accelerator_.write_register(kAttentionNumKvHeads, kQHeads);
        accelerator_.write_register(kAttentionHeadDim, kHeadDim);
        accelerator_.write_register(kAttentionTileQ, kTileRows);
        accelerator_.write_register(kAttentionTileK, kTileRows);
        accelerator_.write_register(kAttentionMode, 0x6);
        accelerator_.write_register(kAttentionValueScale, 0);
        accelerator_.write_register(kAttentionOutScale, 0x000f0001);
        accelerator_.write_register(kAttentionMask, 0);
    }

    void program_dynamic_job(std::uint32_t score_scale)
    {
        accelerator_.write_register(kAttentionScoreScale, score_scale);
        accelerator_.write_register(kAttentionPerfControl, 1);
        accelerator_.write_register(kAttentionPerfControl, 0);
    }

    void wait_for_attention(std::uint32_t mask)
    {
        const auto deadline = std::chrono::steady_clock::now()
            + std::chrono::milliseconds(kTimeoutMs);
        while (std::chrono::steady_clock::now() < deadline) {
            const auto status = accelerator_.read_register(kAttentionStatus);
            if ((status & kAttentionErrorStatus) != 0) {
                const auto error = accelerator_.read_register(kAttentionError);
                throw std::runtime_error(
                    "attention error, code=" + std::to_string(error));
            }
            if ((status & mask) != 0) {
                return;
            }
            std::this_thread::sleep_for(std::chrono::microseconds(5));
        }
        throw std::runtime_error("attention timeout");
    }

    void wait_for_loader_tiles(std::uint32_t tile_count)
    {
        const auto deadline = std::chrono::steady_clock::now()
            + std::chrono::milliseconds(kTimeoutMs);
        while (std::chrono::steady_clock::now() < deadline) {
            const auto status = accelerator_.read_register(kLoaderStatus);
            if ((status & kLoaderError) != 0) {
                throw std::runtime_error("tile loader reported an error");
            }
            if (accelerator_.read_register(kLoaderTiles) >= tile_count) {
                return;
            }
        }
        throw std::runtime_error("tile loader progress timeout");
    }

    void run_workload()
    {
        accelerator_.write_register(kLoaderControl, kLoaderStart);
        mover_run_.start();
        wait_for_loader_tiles(kInitialTiles);

        accelerator_.write_register(
            kAttentionControl,
            kAttentionStart | kAttentionCausal | kAttentionPrefill);

        const auto mover_state = mover_run_.wait(kTimeoutMs);
        if (mover_state == ERT_CMD_STATE_TIMEOUT) {
            mover_run_.abort();
            accelerator_.write_register(kLoaderControl, kLoaderAbort);
            throw std::runtime_error("batched tile mover timeout");
        }
        if (mover_state != ERT_CMD_STATE_COMPLETED) {
            accelerator_.write_register(kLoaderControl, kLoaderAbort);
            throw std::runtime_error(
                "batched tile mover failed, state=" + std::to_string(mover_state));
        }
        wait_for_loader_tiles(geometry_.schedule_tiles);
        wait_for_attention(kAttentionDone);
    }

    void write_output(ggml_tensor *node, float scale)
    {
        const bool dense_f32 = node->type == GGML_TYPE_F32
            && node->nb[0] == sizeof(float)
            && node->nb[1] == kHeadDim * sizeof(float)
            && node->nb[2] == kQHeads * kHeadDim * sizeof(float);
        auto *dense_output = dense_f32 ? static_cast<float *>(node->data) : nullptr;

        for (std::uint32_t row = 0; row < geometry_.seq; ++row) {
            for (std::uint32_t head = 0; head < kQHeads; ++head) {
                const std::uint32_t head_offset = geometry_.o_offset
                    + head * geometry_.tensor_bytes;
                const auto *source = data_ + head_offset + row * kHeadDim;
                float *dense_destination = dense_f32
                    ? dense_output + (row * kQHeads + head) * kHeadDim
                    : nullptr;
                for (std::uint32_t element = 0; element < kHeadDim; ++element) {
                    const auto value = static_cast<float>(source[element]) * scale;
                    if (dense_f32) {
                        dense_destination[element] = value;
                        continue;
                    }
                    auto *address = static_cast<char *>(node->data)
                        + element * node->nb[0]
                        + head * node->nb[1]
                        + row * node->nb[2];
                    std::memcpy(address, &value, sizeof(value));
                }
            }
        }
    }

    Geometry geometry_;
    xrt::device device_;
    xrt::uuid uuid_;
    xrt::ip accelerator_;
    xrt::kernel mover_;
    xrt::run mover_run_;
    xrt::bo buffer_;
    std::int8_t *data_;
    std::uint64_t buffer_address_;
    PlAttentionStats stats_;
};

PlAttention::PlAttention(const std::string &xclbin_path, std::uint32_t sequence_length)
    : impl_(std::make_unique<Impl>(xclbin_path, sequence_length))
{
}

PlAttention::~PlAttention() = default;

void PlAttention::execute(ggml_tensor *node)
{
    impl_->execute(node);
}

const PlAttentionStats &PlAttention::stats() const
{
    return impl_->stats();
}

void PlAttention::reset_stats()
{
    impl_->reset_stats();
}
