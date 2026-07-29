#include "llama.h"
#include "ggml.h"

#ifdef DIT_FA_ENABLE_PL
#include "pl_attention.hpp"
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr std::uint64_t kAttentionNodesPerPrefill = 30;
constexpr int kTileRows = 32;
constexpr int kMaximumSequenceLength = 1024;

using Clock = std::chrono::steady_clock;

struct Options {
    std::string model_path;
    std::string prompt_path;
    std::string output_path;
    std::string backend = "ps";
    std::string xclbin_path;
    int threads = 2;
    int warmups = 1;
    int repetitions = 5;
    int sequence_length = 64;
    double pl_clock_mhz = 170.0;
};

struct TopLogit {
    llama_token token;
    float value;
};

struct NodeTiming {
    double end_to_end_ms = 0.0;
    double core_ms = 0.0;
    double quantize_ms = 0.0;
    double input_sync_ms = 0.0;
    double setup_ms = 0.0;
    double hardware_wait_ms = 0.0;
    double output_sync_ms = 0.0;
    double dequantize_ms = 0.0;
};

struct RunTiming {
    double prefill_ms = 0.0;
    std::vector<NodeTiming> nodes;
};

struct BenchmarkResult {
    std::string backend;
    std::vector<RunTiming> runs;
    std::vector<TopLogit> top_logits;
};

struct PsProfileState {
    Clock::time_point node_start;
    std::vector<double> node_elapsed_ms;
    bool active = false;

    void reset()
    {
        node_elapsed_ms.clear();
        active = false;
    }
};

#ifdef DIT_FA_ENABLE_PL
struct PlCallbackState {
    PlAttention *attention = nullptr;
    std::string error;
};
#endif

std::string read_text(const std::string &path)
{
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("cannot open prompt: " + path);
    }
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

int parse_positive(const char *text, const char *name)
{
    const int value = std::stoi(text);
    if (value <= 0) {
        throw std::runtime_error(std::string(name) + " must be positive");
    }
    return value;
}

int parse_nonnegative(const char *text, const char *name)
{
    const int value = std::stoi(text);
    if (value < 0) {
        throw std::runtime_error(std::string(name) + " must be nonnegative");
    }
    return value;
}

double parse_positive_double(const char *text, const char *name)
{
    const double value = std::stod(text);
    if (!(value > 0.0) || !std::isfinite(value)) {
        throw std::runtime_error(std::string(name) + " must be positive");
    }
    return value;
}

Options parse_options(int argc, char **argv)
{
    Options options;

    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (index + 1 >= argc) {
            throw std::runtime_error("missing value for " + argument);
        }
        if (argument == "--model") {
            options.model_path = argv[++index];
        } else if (argument == "--prompt") {
            options.prompt_path = argv[++index];
        } else if (argument == "--output") {
            options.output_path = argv[++index];
        } else if (argument == "--backend") {
            options.backend = argv[++index];
        } else if (argument == "--xclbin") {
            options.xclbin_path = argv[++index];
        } else if (argument == "--threads") {
            options.threads = parse_positive(argv[++index], "threads");
        } else if (argument == "--warmups") {
            options.warmups = parse_nonnegative(argv[++index], "warmups");
        } else if (argument == "--repetitions") {
            options.repetitions = parse_positive(argv[++index], "repetitions");
        } else if (argument == "--sequence-length") {
            options.sequence_length = parse_positive(argv[++index], "sequence length");
        } else if (argument == "--pl-clock-mhz") {
            options.pl_clock_mhz = parse_positive_double(argv[++index], "PL clock");
        } else {
            throw std::runtime_error("unknown option: " + argument);
        }
    }

    if (options.model_path.empty() || options.prompt_path.empty()) {
        throw std::runtime_error("--model and --prompt are required");
    }
    if (options.backend != "ps" && options.backend != "pl"
        && options.backend != "compare") {
        throw std::runtime_error("--backend must be ps, pl, or compare");
    }
    if (options.backend != "ps" && options.xclbin_path.empty()) {
        throw std::runtime_error("--xclbin is required for PL and compare backends");
    }
    if (options.sequence_length > kMaximumSequenceLength
        || options.sequence_length % kTileRows != 0) {
        throw std::runtime_error(
            "--sequence-length must be a multiple of 32 in [32, 1024]");
    }
    return options;
}

bool ps_profile_callback(
    ggml_tensor *tensor,
    ggml_backend_sched_eval_profile_phase phase,
    void *user_data)
{
    if (tensor->op != GGML_OP_FLASH_ATTN_EXT) {
        return false;
    }

    auto *state = static_cast<PsProfileState *>(user_data);
    if (phase == GGML_BACKEND_SCHED_EVAL_PROFILE_QUERY) {
        return true;
    }
    if (phase == GGML_BACKEND_SCHED_EVAL_PROFILE_BEGIN) {
        state->node_start = Clock::now();
        state->active = true;
        return true;
    }
    if (!state->active) {
        return false;
    }
    const auto end = Clock::now();
    state->node_elapsed_ms.push_back(
        std::chrono::duration<double, std::milli>(end - state->node_start).count());
    state->active = false;
    return true;
}

#ifdef DIT_FA_ENABLE_PL
bool pl_eval_callback(ggml_tensor *tensor, bool ask, void *user_data)
{
    if (tensor->op != GGML_OP_FLASH_ATTN_EXT) {
        return false;
    }
    if (ask) {
        return true;
    }

    auto *state = static_cast<PlCallbackState *>(user_data);
    try {
        state->attention->execute(tensor);
        return true;
    } catch (const std::exception &error) {
        state->error = error.what();
        return false;
    }
}
#endif

std::vector<llama_token> tokenize(
    const llama_vocab *vocab,
    const std::string &prompt,
    std::size_t sequence_length)
{
    const int required = -llama_tokenize(
        vocab, prompt.data(), static_cast<int>(prompt.size()), nullptr, 0, true, true);
    if (required <= 0) {
        throw std::runtime_error("failed to size tokenized prompt");
    }

    std::vector<llama_token> tokens(static_cast<std::size_t>(required));
    const int count = llama_tokenize(
        vocab,
        prompt.data(),
        static_cast<int>(prompt.size()),
        tokens.data(),
        static_cast<int>(tokens.size()),
        true,
        true);
    if (count < static_cast<int>(sequence_length)) {
        throw std::runtime_error(
            "prompt contains " + std::to_string(count) + " tokens, fewer than requested "
            + std::to_string(sequence_length));
    }
    tokens.resize(sequence_length);
    return tokens;
}

std::uint64_t hash_tokens(const std::vector<llama_token> &tokens)
{
    std::uint64_t hash = 1469598103934665603ULL;
    for (const auto token : tokens) {
        std::uint32_t bits = 0;
        static_assert(sizeof(bits) == sizeof(token), "unexpected llama token size");
        std::memcpy(&bits, &token, sizeof(bits));
        for (unsigned int byte = 0; byte < sizeof(bits); ++byte) {
            hash ^= (bits >> (byte * 8)) & 0xffU;
            hash *= 1099511628211ULL;
        }
    }
    return hash;
}

std::vector<TopLogit> find_top_logits(const float *logits, int count)
{
    std::vector<TopLogit> top;
    top.reserve(5);
    for (int token = 0; token < count; ++token) {
        const TopLogit candidate{token, logits[token]};
        const auto position = std::lower_bound(
            top.begin(),
            top.end(),
            candidate,
            [](const TopLogit &left, const TopLogit &right) {
                return left.value > right.value;
            });
        if (position != top.end() || top.size() < 5) {
            top.insert(position, candidate);
            if (top.size() > 5) {
                top.pop_back();
            }
        }
    }
    return top;
}

double sum_attention(const RunTiming &run)
{
    return std::accumulate(
        run.nodes.begin(),
        run.nodes.end(),
        0.0,
        [](double total, const NodeTiming &node) {
            return total + node.end_to_end_ms;
        });
}

double sum_core(const RunTiming &run)
{
    return std::accumulate(
        run.nodes.begin(),
        run.nodes.end(),
        0.0,
        [](double total, const NodeTiming &node) {
            return total + node.core_ms;
        });
}

double sum_node_field(const RunTiming &run, double NodeTiming::*field)
{
    return std::accumulate(
        run.nodes.begin(),
        run.nodes.end(),
        0.0,
        [field](double total, const NodeTiming &node) {
            return total + node.*field;
        });
}

template <typename Getter>
double mean_value(const std::vector<RunTiming> &runs, Getter getter)
{
    const double total = std::accumulate(
        runs.begin(),
        runs.end(),
        0.0,
        [&getter](double sum, const RunTiming &run) {
            return sum + getter(run);
        });
    return total / static_cast<double>(runs.size());
}

template <typename Getter>
double best_value(const std::vector<RunTiming> &runs, Getter getter)
{
    return getter(*std::min_element(
        runs.begin(),
        runs.end(),
        [&getter](const RunTiming &left, const RunTiming &right) {
            return getter(left) < getter(right);
        }));
}

RunTiming make_ps_run(double prefill_ms, const PsProfileState &profile)
{
    RunTiming run;
    run.prefill_ms = prefill_ms;
    run.nodes.reserve(profile.node_elapsed_ms.size());
    for (const double elapsed_ms : profile.node_elapsed_ms) {
        NodeTiming node;
        node.end_to_end_ms = elapsed_ms;
        run.nodes.push_back(node);
    }
    return run;
}

#ifdef DIT_FA_ENABLE_PL
RunTiming make_pl_run(
    double prefill_ms,
    const PlAttentionStats &stats,
    double pl_clock_mhz)
{
    RunTiming run;
    run.prefill_ms = prefill_ms;
    run.nodes.reserve(stats.node_elapsed_ms.size());
    for (std::size_t index = 0; index < stats.node_elapsed_ms.size(); ++index) {
        NodeTiming node;
        node.end_to_end_ms = stats.node_elapsed_ms[index];
        node.core_ms = static_cast<double>(stats.node_accelerator_cycles[index])
            / (pl_clock_mhz * 1000.0);
        node.quantize_ms = stats.node_quantize_ms[index];
        node.input_sync_ms = stats.node_input_sync_ms[index];
        node.setup_ms = stats.node_setup_ms[index];
        node.hardware_wait_ms = stats.node_hardware_wait_ms[index];
        node.output_sync_ms = stats.node_output_sync_ms[index];
        node.dequantize_ms = stats.node_dequantize_ms[index];
        run.nodes.push_back(node);
    }
    return run;
}
#endif

BenchmarkResult benchmark_backend(
    const Options &options,
    llama_model *model,
    const std::vector<llama_token> &tokens,
    const std::string &backend,
    bool profile_ps)
{
    PsProfileState ps_profile;
#ifdef DIT_FA_ENABLE_PL
    std::unique_ptr<PlAttention> pl_attention;
    PlCallbackState pl_callback;
    if (backend == "pl") {
        pl_attention = std::make_unique<PlAttention>(
            options.xclbin_path,
            static_cast<std::uint32_t>(options.sequence_length));
        pl_callback.attention = pl_attention.get();
    }
#else
    if (backend == "pl") {
        throw std::runtime_error("this binary was built without PL/XRT support");
    }
#endif

    llama_context_params params = llama_context_default_params();
    params.n_ctx = options.sequence_length;
    params.n_batch = options.sequence_length;
    params.n_ubatch = options.sequence_length;
    params.n_threads = options.threads;
    params.n_threads_batch = options.threads;
    params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
    params.offload_kqv = false;
    params.no_perf = false;
    if (backend == "ps" && profile_ps) {
        params.cb_eval_profile = ps_profile_callback;
        params.cb_eval_profile_user_data = &ps_profile;
    }
#ifdef DIT_FA_ENABLE_PL
    if (backend == "pl") {
        params.cb_eval_override = pl_eval_callback;
        params.cb_eval_override_user_data = &pl_callback;
    }
#endif

    using ContextPtr = std::unique_ptr<llama_context, decltype(&llama_free)>;
    ContextPtr context(llama_init_from_model(model, params), llama_free);
    if (!context) {
        throw std::runtime_error("failed to create model context for " + backend);
    }

    BenchmarkResult result;
    result.backend = backend;
    result.runs.reserve(static_cast<std::size_t>(options.repetitions));
    const int total_runs = options.warmups + options.repetitions;
    for (int run_index = 0; run_index < total_runs; ++run_index) {
        const bool measured = run_index >= options.warmups;
        ps_profile.reset();
#ifdef DIT_FA_ENABLE_PL
        pl_callback.error.clear();
        if (pl_attention) {
            pl_attention->reset_stats();
        }
#endif
        llama_memory_clear(llama_get_memory(context.get()), true);
        llama_batch batch = llama_batch_get_one(
            const_cast<llama_token *>(tokens.data()),
            static_cast<int>(tokens.size()));
        const auto start = Clock::now();
        const int decode_status = llama_decode(context.get(), batch);
        const auto end = Clock::now();
#ifdef DIT_FA_ENABLE_PL
        if (!pl_callback.error.empty()) {
            throw std::runtime_error("PL attention failed: " + pl_callback.error);
        }
#endif
        if (decode_status != 0) {
            throw std::runtime_error(backend + " model prefill failed");
        }

        const std::size_t node_count = backend == "ps"
            ? ps_profile.node_elapsed_ms.size()
#ifdef DIT_FA_ENABLE_PL
            : pl_attention->stats().node_elapsed_ms.size();
#else
            : 0;
#endif
        if ((profile_ps || backend == "pl")
            && node_count != kAttentionNodesPerPrefill) {
            throw std::runtime_error(
                backend + " measured " + std::to_string(node_count)
                + " Attention nodes, expected "
                + std::to_string(kAttentionNodesPerPrefill));
        }
        if (!measured) {
            continue;
        }

        const double prefill_ms =
            std::chrono::duration<double, std::milli>(end - start).count();
        if (backend == "ps" && profile_ps) {
            result.runs.push_back(make_ps_run(prefill_ms, ps_profile));
        } else if (backend == "ps") {
            RunTiming run;
            run.prefill_ms = prefill_ms;
            result.runs.push_back(run);
        }
#ifdef DIT_FA_ENABLE_PL
        else {
            result.runs.push_back(
                make_pl_run(prefill_ms, pl_attention->stats(), options.pl_clock_mhz));
        }
#endif
    }

    const float *logits = llama_get_logits_ith(context.get(), -1);
    if (logits == nullptr) {
        throw std::runtime_error(backend + " model did not produce final-token logits");
    }
    result.top_logits = find_top_logits(logits, llama_vocab_n_tokens(
        llama_model_get_vocab(model)));
    return result;
}

BenchmarkResult benchmark_ps(
    const Options &options,
    llama_model *model,
    const std::vector<llama_token> &tokens)
{
    auto baseline = benchmark_backend(options, model, tokens, "ps", false);
    auto profile = benchmark_backend(options, model, tokens, "ps", true);
    if (baseline.runs.size() != profile.runs.size()) {
        throw std::runtime_error("PS baseline/profile repetition mismatch");
    }
    for (std::size_t index = 0; index < baseline.runs.size(); ++index) {
        baseline.runs[index].nodes = std::move(profile.runs[index].nodes);
    }
    return baseline;
}

void write_top_logits(std::ostream &output, const std::vector<TopLogit> &top, int indent)
{
    const std::string spaces(static_cast<std::size_t>(indent), ' ');
    output << spaces << "\"top_logits\": [\n";
    for (std::size_t index = 0; index < top.size(); ++index) {
        output << spaces << "    {\"token\": " << top[index].token
               << ", \"value\": " << top[index].value << "}";
        output << (index + 1 == top.size() ? "\n" : ",\n");
    }
    output << spaces << "]\n";
}

void write_backend_result(
    std::ostream &output,
    const BenchmarkResult &result,
    int indent)
{
    const std::string spaces(static_cast<std::size_t>(indent), ' ');
    const bool is_pl = result.backend == "pl";
    const auto prefill = [](const RunTiming &run) { return run.prefill_ms; };
    output << spaces << "{\n";
    output << spaces << "    \"prefill_ms_best\": "
           << best_value(result.runs, prefill) << ",\n";
    output << spaces << "    \"prefill_ms_mean\": "
           << mean_value(result.runs, prefill) << ",\n";
    output << spaces << "    \"attention_end_to_end_ms_best\": "
           << best_value(result.runs, sum_attention) << ",\n";
    output << spaces << "    \"attention_end_to_end_ms_mean\": "
           << mean_value(result.runs, sum_attention) << ",\n";
    if (is_pl) {
        const auto quantize = [](const RunTiming &run) {
            return sum_node_field(run, &NodeTiming::quantize_ms);
        };
        const auto input_sync = [](const RunTiming &run) {
            return sum_node_field(run, &NodeTiming::input_sync_ms);
        };
        const auto setup = [](const RunTiming &run) {
            return sum_node_field(run, &NodeTiming::setup_ms);
        };
        const auto hardware_wait = [](const RunTiming &run) {
            return sum_node_field(run, &NodeTiming::hardware_wait_ms);
        };
        const auto output_sync = [](const RunTiming &run) {
            return sum_node_field(run, &NodeTiming::output_sync_ms);
        };
        const auto dequantize = [](const RunTiming &run) {
            return sum_node_field(run, &NodeTiming::dequantize_ms);
        };
        output << spaces << "    \"attention_core_ms_best\": "
               << best_value(result.runs, sum_core) << ",\n";
        output << spaces << "    \"attention_core_ms_mean\": "
               << mean_value(result.runs, sum_core) << ",\n";
        output << spaces << "    \"quantize_ms_mean\": "
               << mean_value(result.runs, quantize) << ",\n";
        output << spaces << "    \"input_sync_ms_mean\": "
               << mean_value(result.runs, input_sync) << ",\n";
        output << spaces << "    \"setup_ms_mean\": "
               << mean_value(result.runs, setup) << ",\n";
        output << spaces << "    \"hardware_wait_ms_mean\": "
               << mean_value(result.runs, hardware_wait) << ",\n";
        output << spaces << "    \"output_sync_ms_mean\": "
               << mean_value(result.runs, output_sync) << ",\n";
        output << spaces << "    \"dequantize_ms_mean\": "
               << mean_value(result.runs, dequantize) << ",\n";
    }
    output << spaces << "    \"runs\": [\n";
    for (std::size_t run_index = 0; run_index < result.runs.size(); ++run_index) {
        const auto &run = result.runs[run_index];
        output << spaces << "        {\n";
        output << spaces << "            \"prefill_ms\": " << run.prefill_ms << ",\n";
        output << spaces << "            \"attention_end_to_end_ms\": "
               << sum_attention(run) << ",\n";
        if (is_pl) {
            output << spaces << "            \"attention_core_ms\": "
                   << sum_core(run) << ",\n";
        }
        output << spaces << "            \"attention_nodes\": [\n";
        for (std::size_t node_index = 0; node_index < run.nodes.size(); ++node_index) {
            const auto &node = run.nodes[node_index];
            output << spaces << "                {\"layer\": " << node_index
                   << ", \"end_to_end_ms\": " << node.end_to_end_ms;
            if (is_pl) {
                output << ", \"core_ms\": " << node.core_ms
                       << ", \"quantize_ms\": " << node.quantize_ms
                       << ", \"input_sync_ms\": " << node.input_sync_ms
                       << ", \"setup_ms\": " << node.setup_ms
                       << ", \"hardware_wait_ms\": " << node.hardware_wait_ms
                       << ", \"output_sync_ms\": " << node.output_sync_ms
                       << ", \"dequantize_ms\": " << node.dequantize_ms;
            }
            output << "}";
            output << (node_index + 1 == run.nodes.size() ? "\n" : ",\n");
        }
        output << spaces << "            ]\n";
        output << spaces << "        }";
        output << (run_index + 1 == result.runs.size() ? "\n" : ",\n");
    }
    output << spaces << "    ],\n";
    write_top_logits(output, result.top_logits, indent + 4);
    output << spaces << "}";
}

void write_result(
    std::ostream &output,
    const Options &options,
    std::uint64_t token_hash,
    const std::vector<BenchmarkResult> &results)
{
    output << std::fixed << std::setprecision(6);
    output << "{\n";
    output << "    \"sequence_length\": " << options.sequence_length << ",\n";
    output << "    \"threads\": " << options.threads << ",\n";
    output << "    \"warmups\": " << options.warmups << ",\n";
    output << "    \"repetitions\": " << options.repetitions << ",\n";
    output << "    \"pl_clock_mhz\": " << options.pl_clock_mhz << ",\n";
    output << "    \"token_hash_fnv1a64\": \"0x" << std::hex << token_hash
           << std::dec << "\",\n";
    output << "    \"backends\": {\n";
    for (std::size_t index = 0; index < results.size(); ++index) {
        output << "        \"" << results[index].backend << "\": ";
        write_backend_result(output, results[index], 8);
        output << (index + 1 == results.size() ? "\n" : ",\n");
    }
    output << "    }";
    if (results.size() == 2) {
        const auto &ps = results[0];
        const auto &pl = results[1];
        const auto prefill = [](const RunTiming &run) { return run.prefill_ms; };
        output << ",\n";
        output << "    \"comparison\": {\n";
        output << "        \"prefill_speedup\": "
               << mean_value(ps.runs, prefill) / mean_value(pl.runs, prefill) << ",\n";
        output << "        \"attention_end_to_end_speedup\": "
               << mean_value(ps.runs, sum_attention)
                    / mean_value(pl.runs, sum_attention) << ",\n";
        output << "        \"attention_core_speedup\": "
               << mean_value(ps.runs, sum_attention) / mean_value(pl.runs, sum_core) << "\n";
        output << "    }\n";
    } else {
        output << "\n";
    }
    output << "}\n";
}

void print_summary(const std::vector<BenchmarkResult> &results)
{
    const auto prefill = [](const RunTiming &run) { return run.prefill_ms; };
    std::cerr << std::fixed << std::setprecision(3);
    for (const auto &result : results) {
        std::cerr << (result.backend == "ps" ? "PS" : "PS+PL")
                  << ": prefill mean " << mean_value(result.runs, prefill)
                  << " ms, best " << best_value(result.runs, prefill)
                  << " ms, Attention end-to-end mean "
                  << mean_value(result.runs, sum_attention) << " ms";
        if (result.backend == "pl") {
            std::cerr << ", PL core mean " << mean_value(result.runs, sum_core) << " ms";
        }
        std::cerr << '\n';
        if (result.backend == "pl") {
            const auto phase_mean = [&result](double NodeTiming::*field) {
                return mean_value(
                    result.runs,
                    [field](const RunTiming &run) {
                        return sum_node_field(run, field);
                    });
            };
            std::cerr << "PS+PL phases: quantize "
                      << phase_mean(&NodeTiming::quantize_ms)
                      << " ms, input sync " << phase_mean(&NodeTiming::input_sync_ms)
                      << " ms, setup " << phase_mean(&NodeTiming::setup_ms)
                      << " ms, hardware wait "
                      << phase_mean(&NodeTiming::hardware_wait_ms)
                      << " ms, output sync " << phase_mean(&NodeTiming::output_sync_ms)
                      << " ms, dequantize " << phase_mean(&NodeTiming::dequantize_ms)
                      << " ms\n";
        }
    }
    if (results.size() == 2) {
        const auto ps_attention = mean_value(results[0].runs, sum_attention);
        const auto pl_attention = mean_value(results[1].runs, sum_attention);
        const auto pl_core = mean_value(results[1].runs, sum_core);
        std::cerr << "Speedup: prefill "
                  << mean_value(results[0].runs, prefill)
                        / mean_value(results[1].runs, prefill)
                  << "x, Attention end-to-end " << ps_attention / pl_attention
                  << "x, Attention core " << ps_attention / pl_core << "x\n";
    }
}

int run(const Options &options)
{
    llama_backend_init();
    using ModelPtr = std::unique_ptr<llama_model, decltype(&llama_model_free)>;
    ModelPtr model(
        llama_model_load_from_file(
            options.model_path.c_str(),
            llama_model_default_params()),
        llama_model_free);
    if (!model) {
        throw std::runtime_error("failed to load model");
    }

    const llama_vocab *vocab = llama_model_get_vocab(model.get());
    const auto tokens = tokenize(
        vocab,
        read_text(options.prompt_path),
        static_cast<std::size_t>(options.sequence_length));
    std::vector<BenchmarkResult> results;
    if (options.backend == "ps" || options.backend == "compare") {
        results.push_back(benchmark_ps(options, model.get(), tokens));
    }
    if (options.backend == "pl" || options.backend == "compare") {
        results.push_back(benchmark_backend(options, model.get(), tokens, "pl", false));
    }

    print_summary(results);
    if (options.output_path.empty()) {
        write_result(std::cout, options, hash_tokens(tokens), results);
    } else {
        std::ofstream output(options.output_path);
        if (!output) {
            throw std::runtime_error("cannot create result: " + options.output_path);
        }
        write_result(output, options, hash_tokens(tokens), results);
    }

    model.reset();
    llama_backend_free();
    return 0;
}

} // namespace

int main(int argc, char **argv)
{
    try {
        return run(parse_options(argc, argv));
    } catch (const std::exception &error) {
        std::cerr << "Error: " << error.what() << '\n';
        return 1;
    }
}
