#include <cstdlib>
#include <iostream>
#include <stdexcept>

#include "experimental/xrt_device.h"
#include "experimental/xrt_kernel.h"

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <control_probe.xclbin>\n";
        return EXIT_FAILURE;
    }

    try {
        std::cerr << "[stage] opening device 0\n";
        auto device = xrt::device(0);
        std::cerr << "[stage] loading xclbin\n";
        const auto uuid = device.load_xclbin(argv[1]);
        std::cerr << "[stage] opening kernel\n";
        auto kernel = xrt::kernel(
            device,
            uuid,
            "control_probe:{control_probe_1}");
        auto run = kernel(0U);
        const auto state = run.wait(5000);

        if (state == ERT_CMD_STATE_TIMEOUT) {
            throw std::runtime_error("kernel timed out after 5 seconds");
        }
        if (state != ERT_CMD_STATE_COMPLETED) {
            throw std::runtime_error("kernel returned an unexpected state");
        }

        std::cout << "PASS: CU control and execution succeeded\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << "ERROR: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
