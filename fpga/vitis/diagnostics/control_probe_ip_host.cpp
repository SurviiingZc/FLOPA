#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <thread>

#include "experimental/xrt_device.h"
#include "experimental/xrt_kernel.h"

#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

namespace {

constexpr std::uint32_t kControlOffset = 0x00;
constexpr std::uint32_t kGlobalInterruptOffset = 0x04;
constexpr std::uint32_t kInterruptEnableOffset = 0x08;
constexpr std::uint32_t kInterruptStatusOffset = 0x0c;
constexpr std::uint32_t kValueOffset = 0x10;
constexpr std::uint32_t kDoneMask = 0x02;
constexpr int kPollCount = 50;

void print_control(const char *stage, std::uint32_t control)
{
    std::cout << stage << ": control=0x" << std::hex << control << std::dec
              << " start=" << ((control & 0x01) != 0)
              << " done=" << ((control & 0x02) != 0)
              << " idle=" << ((control & 0x04) != 0)
              << " ready=" << ((control & 0x08) != 0) << '\n';
}

} // namespace

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
        std::cerr << "[stage] opening CU with exclusive access\n";
        auto ip = xrt::kernel(
            device,
            uuid,
            "control_probe:{control_probe_1}",
            xrt::kernel::cu_access_mode::exclusive);

        const auto initial = ip.read_register(kControlOffset);
        print_control("before setup", initial);
        std::cout << "before setup: value=0x" << std::hex
                  << ip.read_register(kValueOffset) << std::dec << '\n';

        ip.write_register(kGlobalInterruptOffset, 0);
        ip.write_register(kInterruptEnableOffset, 0);
        ip.write_register(kInterruptStatusOffset, 3);
        ip.write_register(kValueOffset, 0x12345678);
        ip.write_register(kControlOffset, 1);

        for (int poll = 0; poll < kPollCount; ++poll) {
            const auto control = ip.read_register(kControlOffset);
            if (poll == 0 || (poll + 1) % 10 == 0 || (control & kDoneMask) != 0) {
                print_control("after start", control);
            }
            if ((control & kDoneMask) != 0) {
                std::cout << "PASS: direct CU control completed\n";
                return EXIT_SUCCESS;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        std::cerr << "ERROR: direct CU control timed out after 5 seconds\n";
        return EXIT_FAILURE;
    } catch (const std::exception &error) {
        std::cerr << "ERROR: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
