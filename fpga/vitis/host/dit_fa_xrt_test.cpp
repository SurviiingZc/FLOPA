#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>

#include <unistd.h>

#include "experimental/xrt_bo.h"
#include "experimental/xrt_device.h"
#include "experimental/xrt_ip.h"
#include "experimental/xrt_kernel.h"

namespace {

void log_stage(const char *message)
{
    std::cerr << "[stage] " << message << std::endl;
    ::sync();
}

constexpr std::uint32_t kAttentionControl = 0x000;
constexpr std::uint32_t kAttentionStatus = 0x004;
constexpr std::uint32_t kAttentionError = 0x008;
constexpr std::uint32_t kAttentionVersion = 0x00c;
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
constexpr std::uint32_t kAttentionPerfStallLow = 0x07c;
constexpr std::uint32_t kAttentionPerfStallHigh = 0x080;
constexpr std::uint32_t kAttentionPerfMacLow = 0x084;
constexpr std::uint32_t kAttentionPerfMacHigh = 0x088;
constexpr std::uint32_t kAttentionPerfTiles = 0x08c;

constexpr std::uint32_t kLoaderBase = 0x100;
constexpr std::uint32_t kLoaderControl = kLoaderBase + 0x000;
constexpr std::uint32_t kLoaderStatus = kLoaderBase + 0x004;
constexpr std::uint32_t kLoaderVersion = kLoaderBase + 0x014;
constexpr std::uint32_t kLoaderTiles = kLoaderBase + 0x018;

constexpr std::uint32_t kAttentionStart = 1U << 0;
constexpr std::uint32_t kAttentionSoftReset = 1U << 1;
constexpr std::uint32_t kAttentionClearDone = 1U << 2;
constexpr std::uint32_t kAttentionClearError = 1U << 3;
constexpr std::uint32_t kAttentionPrefill = 1U << 6;
constexpr std::uint32_t kAttentionDone = 1U << 1;
constexpr std::uint32_t kAttentionErrorStatus = 1U << 2;

constexpr std::uint32_t kLoaderStart = 1U << 0;
constexpr std::uint32_t kLoaderAbort = 1U << 1;
constexpr std::uint32_t kLoaderClearDone = 1U << 2;
constexpr std::uint32_t kLoaderClearError = 1U << 3;
constexpr std::uint32_t kLoaderError = 1U << 2;

constexpr std::uint32_t kSeq = 64;
constexpr std::uint32_t kHeadDim = 64;
constexpr std::uint32_t kTileRows = 32;
constexpr std::uint32_t kTensorBytes = kSeq * kHeadDim;
constexpr std::uint32_t kQOffset = 0;
constexpr std::uint32_t kKOffset = kQOffset + kTensorBytes;
constexpr std::uint32_t kVOffset = kKOffset + kTensorBytes;
constexpr std::uint32_t kOOffset = kVOffset + kTensorBytes;
constexpr std::uint32_t kBufferBytes = kOOffset + kTensorBytes;
constexpr std::uint32_t kInitialTiles = 3;
constexpr std::uint32_t kScheduleTiles = 10;
constexpr std::uint32_t kTimeoutMs = 5000;

std::uint64_t join_u64(std::uint32_t low, std::uint32_t high)
{
    return (static_cast<std::uint64_t>(high) << 32) | low;
}

void write_address(
    xrt::ip &accelerator,
    std::uint32_t low_register,
    std::uint32_t high_register,
    std::uint64_t address)
{
    accelerator.write_register(low_register, static_cast<std::uint32_t>(address));
    accelerator.write_register(
        high_register,
        static_cast<std::uint32_t>(address >> 32));
}

void reset_hardware(xrt::ip &accelerator)
{
    accelerator.write_register(
        kAttentionControl,
        kAttentionSoftReset | kAttentionClearDone | kAttentionClearError);
    accelerator.write_register(
        kLoaderControl,
        kLoaderAbort | kLoaderClearDone | kLoaderClearError);
}

void program_job(xrt::ip &accelerator, std::uint64_t buffer_address)
{
    write_address(
        accelerator,
        kAttentionQBaseLow,
        kAttentionQBaseHigh,
        buffer_address + kQOffset);
    write_address(
        accelerator,
        kAttentionKBaseLow,
        kAttentionKBaseHigh,
        buffer_address + kKOffset);
    write_address(
        accelerator,
        kAttentionVBaseLow,
        kAttentionVBaseHigh,
        buffer_address + kVOffset);
    write_address(
        accelerator,
        kAttentionOBaseLow,
        kAttentionOBaseHigh,
        buffer_address + kOOffset);

    accelerator.write_register(kAttentionQStride, kHeadDim);
    accelerator.write_register(kAttentionKStride, kHeadDim);
    accelerator.write_register(kAttentionVStride, kHeadDim);
    accelerator.write_register(kAttentionOStride, kHeadDim);
    accelerator.write_register(kAttentionSeqQ, kSeq);
    accelerator.write_register(kAttentionSeqKv, kSeq);
    accelerator.write_register(kAttentionNumQHeads, 1);
    accelerator.write_register(kAttentionNumKvHeads, 1);
    accelerator.write_register(kAttentionHeadDim, kHeadDim);
    accelerator.write_register(kAttentionTileQ, kTileRows);
    accelerator.write_register(kAttentionTileK, kTileRows);
    accelerator.write_register(kAttentionMode, 0x4);
    accelerator.write_register(kAttentionScoreScale, 1);
    accelerator.write_register(kAttentionValueScale, 0);
    accelerator.write_register(kAttentionOutScale, 0x000f0001);
    accelerator.write_register(kAttentionMask, 0);
    accelerator.write_register(kAttentionPerfControl, 1);
    accelerator.write_register(kAttentionPerfControl, 0);
}

void wait_for_attention(xrt::ip &accelerator, std::uint32_t mask)
{
    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::milliseconds(kTimeoutMs);

    while (std::chrono::steady_clock::now() < deadline) {
        const auto status = accelerator.read_register(kAttentionStatus);

        if ((status & kAttentionErrorStatus) != 0) {
            const auto error = accelerator.read_register(kAttentionError);
            throw std::runtime_error(
                "attention error, code=" + std::to_string(error));
        }
        if ((status & mask) != 0) {
            return;
        }
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    throw std::runtime_error("attention timeout");
}

void wait_for_loader_tiles(xrt::ip &accelerator, std::uint32_t tile_count)
{
    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::milliseconds(kTimeoutMs);

    while (std::chrono::steady_clock::now() < deadline) {
        const auto status = accelerator.read_register(kLoaderStatus);

        if ((status & kLoaderError) != 0) {
            throw std::runtime_error("tile loader reported an error");
        }
        if (accelerator.read_register(kLoaderTiles) >= tile_count) {
            return;
        }
    }
    throw std::runtime_error("tile loader timeout");
}

void run_workload(xrt::ip &accelerator, xrt::kernel &mover, xrt::bo &buffer)
{
    accelerator.write_register(
        kLoaderControl,
        kLoaderStart | kLoaderClearDone | kLoaderClearError);

    auto run = mover(
        buffer,
        kQOffset / 16,
        kKOffset / 16,
        kVOffset / 16,
        1,
        kSeq / kTileRows,
        kSeq / kTileRows);

    wait_for_loader_tiles(accelerator, kInitialTiles);

    accelerator.write_register(
        kAttentionControl,
        kAttentionStart | kAttentionPrefill);

    const auto state = run.wait(kTimeoutMs);
    if (state == ERT_CMD_STATE_TIMEOUT) {
        run.abort();
        accelerator.write_register(kLoaderControl, kLoaderAbort);
        throw std::runtime_error("tile mover timeout");
    }
    if (state != ERT_CMD_STATE_COMPLETED) {
        accelerator.write_register(kLoaderControl, kLoaderAbort);
        throw std::runtime_error(
            "tile mover failed, state=" + std::to_string(state));
    }

    wait_for_loader_tiles(accelerator, kScheduleTiles);

    wait_for_attention(accelerator, kAttentionDone);
}

std::size_t verify_output(const std::uint8_t *data)
{
    std::size_t mismatches = 0;

    for (std::size_t index = 0; index < kTensorBytes; ++index) {
        const auto actual = data[kOOffset + index];
        if (actual != 1) {
            if (mismatches < 8) {
                std::cerr << "Mismatch output[" << index << "]: expected 1, got "
                          << static_cast<unsigned int>(actual) << '\n';
            }
            ++mismatches;
        }
    }
    return mismatches;
}

void print_results(xrt::ip &accelerator)
{
    const auto cycles = join_u64(
        accelerator.read_register(kAttentionPerfCyclesLow),
        accelerator.read_register(kAttentionPerfCyclesHigh));
    const auto stalls = join_u64(
        accelerator.read_register(kAttentionPerfStallLow),
        accelerator.read_register(kAttentionPerfStallHigh));
    const auto macs = join_u64(
        accelerator.read_register(kAttentionPerfMacLow),
        accelerator.read_register(kAttentionPerfMacHigh));

    std::cout << std::hex << std::setfill('0');
    std::cout << "Attention version: 0x" << std::setw(8)
              << accelerator.read_register(kAttentionVersion) << '\n';
    std::cout << "Loader version:    0x" << std::setw(8)
              << accelerator.read_register(kLoaderVersion) << '\n';
    std::cout << "Final status:      0x" << std::setw(8)
              << accelerator.read_register(kAttentionStatus) << '\n';
    std::cout << "Error code:        0x" << std::setw(8)
              << accelerator.read_register(kAttentionError) << '\n';
    std::cout << std::dec << std::setfill(' ');
    std::cout << "Cycles: " << cycles << '\n';
    std::cout << "Stall cycles: " << stalls << '\n';
    std::cout << "MACs: " << macs << '\n';
    std::cout << "Completed tiles: "
              << accelerator.read_register(kAttentionPerfTiles) << '\n';
    std::cout << "Loaded tiles: "
              << accelerator.read_register(kLoaderTiles) << '\n';
}

} // namespace

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <dit_fa.xclbin>\n";
        return EXIT_FAILURE;
    }

    try {
        log_stage("opening device 0");
        auto device = xrt::device(0);
        log_stage("loading xclbin");
        const auto uuid = device.load_xclbin(argv[1]);
        log_stage("xclbin loaded");
        log_stage("opening kernel handles");
        auto accelerator = xrt::ip(device, uuid, "dit_fa:{dit_fa_1}");
        auto mover = xrt::kernel(
            device,
            uuid,
            "dit_fa_tile_mover:{dit_fa_tile_mover_1}");
        log_stage("allocating BO");
        auto buffer = xrt::bo(
            device,
            kBufferBytes,
            xrt::bo::flags::normal,
            0);
        auto *data = buffer.map<std::uint8_t *>();
        const auto buffer_address = buffer.address();

        if (buffer_address > std::numeric_limits<std::uint32_t>::max()
            || buffer_address + kBufferBytes - 1
                > std::numeric_limits<std::uint32_t>::max()) {
            throw std::runtime_error(
                "XRT BO is above 4 GiB, but the current RTL writeback address "
                "is 32-bit");
        }

        std::fill(data + kQOffset, data + kKOffset, 0);
        std::fill(data + kKOffset, data + kVOffset, 0);
        std::fill(data + kVOffset, data + kOOffset, 1);
        std::fill(data + kOOffset, data + kBufferBytes, 0xa5);
        log_stage("syncing input BO");
        buffer.sync(XCL_BO_SYNC_BO_TO_DEVICE, kBufferBytes, 0);

        std::cout << "BO device address: 0x" << std::hex << buffer_address
                  << std::dec << '\n';
        log_stage("programming registers");
        reset_hardware(accelerator);
        program_job(accelerator, buffer_address);
        log_stage("starting four-tile workload");
        run_workload(accelerator, mover, buffer);
        log_stage("workload completed; syncing output BO");
        buffer.sync(XCL_BO_SYNC_BO_FROM_DEVICE, kTensorBytes, kOOffset);

        const auto mismatches = verify_output(data);
        const auto completed_tiles =
            accelerator.read_register(kAttentionPerfTiles);
        print_results(accelerator);
        if (mismatches != 0 || completed_tiles != 4) {
            std::cerr << "FAIL: mismatches=" << mismatches
                      << ", completed_tiles=" << completed_tiles << '\n';
            return EXIT_FAILURE;
        }

        std::cout << "PASS: seq=64, head_dim=64, four tiles\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << "ERROR: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
