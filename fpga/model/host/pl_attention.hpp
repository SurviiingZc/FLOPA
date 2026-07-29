#pragma once

#include "ggml.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct PlAttentionStats {
    std::uint64_t attention_nodes = 0;
    std::uint64_t accelerator_cycles = 0;
    double elapsed_ms = 0.0;
    double quantize_ms = 0.0;
    double input_sync_ms = 0.0;
    double setup_ms = 0.0;
    double hardware_wait_ms = 0.0;
    double output_sync_ms = 0.0;
    double dequantize_ms = 0.0;
    std::vector<std::uint64_t> node_accelerator_cycles;
    std::vector<double> node_elapsed_ms;
    std::vector<double> node_quantize_ms;
    std::vector<double> node_input_sync_ms;
    std::vector<double> node_setup_ms;
    std::vector<double> node_hardware_wait_ms;
    std::vector<double> node_output_sync_ms;
    std::vector<double> node_dequantize_ms;
};

class PlAttention {
public:
    explicit PlAttention(const std::string &xclbin_path);
    ~PlAttention();

    PlAttention(const PlAttention &) = delete;
    PlAttention &operator=(const PlAttention &) = delete;

    void execute(ggml_tensor *node);
    const PlAttentionStats &stats() const;
    void reset_stats();

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
