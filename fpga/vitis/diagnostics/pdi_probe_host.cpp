#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>

#include "experimental/xrt_bo.h"
#include "experimental/xrt_device.h"
#include "experimental/xrt_kernel.h"

namespace {

constexpr std::uint32_t kExpectedValue = 0x5044494d;

} // namespace

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <pdi_probe.xclbin>\n";
        return EXIT_FAILURE;
    }

    try {
        std::cerr << "[stage] opening device 0\n";
        auto device = xrt::device(0);
        std::cerr << "[stage] loading xclbin\n";
        const auto uuid = device.load_xclbin(argv[1]);
        std::cerr << "[stage] opening kernel\n";
        auto kernel = xrt::kernel(device, uuid, "pdi_probe:{pdi_probe_1}");
        auto buffer = xrt::bo(
            device,
            sizeof(std::uint32_t),
            xrt::bo::flags::normal,
            0);
        auto *value = buffer.map<std::uint32_t *>();

        std::cout << "BO device address: 0x" << std::hex << buffer.address()
                  << std::dec << '\n';
        *value = 0;
        buffer.sync(XCL_BO_SYNC_BO_TO_DEVICE);
        std::cerr << "[stage] running kernel\n";
        auto run = kernel(buffer);
        const auto state = run.wait(5000);
        if (state == ERT_CMD_STATE_TIMEOUT) {
            run.abort();
            throw std::runtime_error("kernel timed out after 5 seconds");
        }
        if (state != ERT_CMD_STATE_COMPLETED) {
            throw std::runtime_error("kernel returned an unexpected state");
        }
        buffer.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

        std::cout << "Result: 0x" << std::hex << std::setw(8)
                  << std::setfill('0') << *value << '\n';
        if (*value != kExpectedValue) {
            std::cerr << "FAIL: unexpected probe value\n";
            return EXIT_FAILURE;
        }

        std::cout << "PASS: PDI load, CU execution, and DDR access succeeded\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << "ERROR: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
