"""Benchmark full-head resident SDPA on a captured trajectory tensor."""

import argparse
import json
import os
import statistics
import subprocess
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as functional
from torch.nn.attention import SDPBackend, sdpa_kernel

from capture_trajectories import sha, write_json


def cpu_affinity():
    allowed = os.sched_getaffinity(0)
    raw = subprocess.check_output(['lscpu', '-p=CPU,CORE,SOCKET'], text=True)
    seen, cores = set(), []
    for line in raw.splitlines():
        if line.startswith('#'):
            continue
        cpu, core, socket = map(int, line.split(','))
        if cpu in allowed and (socket, core) not in seen:
            seen.add((socket, core))
            cores.append((socket, core, cpu))
    return [item[2] for item in sorted(cores)]


def samples(function, device, count):
    result = []
    for _ in range(count):
        if device == 'cuda':
            first = torch.cuda.Event(enable_timing=True)
            last = torch.cuda.Event(enable_timing=True)
            first.record()
            answer = function()
            last.record()
            last.synchronize()
            result.append(first.elapsed_time(last))
        else:
            first = time.perf_counter_ns()
            answer = function()
            result.append((time.perf_counter_ns() - first) / 1e6)
        del answer
    return result


def check_gpu_exclusive():
    device = os.environ.get('CUDA_VISIBLE_DEVICES', '0')
    uuid = subprocess.check_output([
        'nvidia-smi', '-i', device, '--query-gpu=uuid', '--format=csv,noheader',
    ], text=True).strip()
    processes = subprocess.check_output([
        'nvidia-smi', '--query-compute-apps=gpu_uuid,pid,used_memory',
        '--format=csv,noheader,nounits',
    ], text=True)
    competing = []
    for line in processes.splitlines():
        gpu, pid, memory = [item.strip() for item in line.split(',')]
        if gpu == uuid and int(pid) != os.getpid() and int(memory) >= 1024:
            competing.append(line)
    if competing:
        raise RuntimeError('GPU timing rejected due to another compute job: ' + str(competing))
    return uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vector', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', choices=['cpu', 'cuda'], required=True)
    args = parser.parse_args()
    torch.set_grad_enabled(False)
    torch.set_num_interop_threads(1)
    torch.backends.cuda.matmul.allow_tf32 = False
    payload = torch.load(args.vector, map_location='cpu', weights_only=True)
    device = args.device
    n = payload['q'].shape[2]
    # Fix repeat reductions before seeing which platform wins.
    warmup = 20 if device == 'cuda' or n <= 4096 else 5
    repetitions = 30 if device == 'cuda' or n <= 4096 else 5
    dtype = torch.float32 if device == 'cpu' else torch.float16
    report = {'vector_sha256': sha(args.vector), 'metadata': payload['metadata'],
              'device': device, 'dtype': str(dtype), 'torch': torch.__version__,
              'warmup': warmup, 'batches': 3, 'repetitions_per_batch': repetitions,
              'scope': 'resident complete multihead SDPA; no projection/RoPE/conversion',
              'pilot': [], 'tf32': False}
    report['load_average_before'] = list(os.getloadavg())
    if device == 'cpu':
        cores = cpu_affinity()
        for threads in (1, 4, 8, 16, 20, 40):
            if threads > len(cores):
                continue
            os.sched_setaffinity(0, cores[:threads])
            torch.set_num_threads(threads)
            qkv = [payload[name].to(dtype=dtype).contiguous() for name in ('q', 'k', 'v')]
            function = lambda: functional.scaled_dot_product_attention(*qkv)
            samples(function, device, 2)
            trial = samples(function, device, 3)
            report['pilot'].append({'threads': threads, 'affinity': cores[:threads],
                                     'median_ms': statistics.median(trial)})
        best = min(report['pilot'], key=lambda item: item['median_ms'])
        os.sched_setaffinity(0, best['affinity'])
        torch.set_num_threads(best['threads'])
        report['cpu_configuration'] = best
        report['numa_policy'] = 'process affinity; allocator default; no explicit membind'
        qkv = [payload[name].to(dtype=dtype).contiguous() for name in ('q', 'k', 'v')]
        function = lambda: functional.scaled_dot_product_attention(*qkv)
        context = None
    else:
        report['gpu_uuid'] = check_gpu_exclusive()
        qkv = [payload[name].to(device=device, dtype=dtype).contiguous()
               for name in ('q', 'k', 'v')]
        # Dense math is a fallback only, to avoid materializing multi-GB HxNxN at long N.
        reference = functional.scaled_dot_product_attention(*qkv)
        for backend in (SDPBackend.FLASH_ATTENTION, SDPBackend.EFFICIENT_ATTENTION):
            try:
                with sdpa_kernel(backend):
                    function = lambda: functional.scaled_dot_product_attention(*qkv)
                    candidate = function()
                    relative = float((candidate.float() - reference.float()).norm() /
                                     reference.float().norm().clamp_min(1e-12))
                    if relative > 0.005:
                        raise RuntimeError('Backend numerical disagreement: ' + str(relative))
                    samples(function, device, 2)
                    trial = samples(function, device, 5)
                    report['pilot'].append({'backend': backend.name,
                        'median_ms': statistics.median(trial), 'relative_l2': relative})
            except RuntimeError as error:
                report['pilot'].append({'backend': backend.name, 'unavailable': str(error)})
        valid = [item for item in report['pilot'] if 'median_ms' in item]
        if not valid:
            raise RuntimeError('No memory-efficient validated GPU backend')
        best = min(valid, key=lambda item: item['median_ms'])
        report['gpu_backend'] = best
        backend = getattr(SDPBackend, best['backend'])
        context = sdpa_kernel(backend)
        context.__enter__()
        function = lambda: functional.scaled_dot_product_attention(*qkv)
    try:
        samples(function, device, warmup)
        all_samples = []
        for batch in range(3):
            if device == 'cuda':
                check_gpu_exclusive()
            all_samples.append(samples(function, device, repetitions))
        # Kernel trace is outside all timed repeats.
        activities = [torch.profiler.ProfilerActivity.CPU]
        if device == 'cuda':
            activities.append(torch.profiler.ProfilerActivity.CUDA)
        with torch.profiler.profile(activities=activities) as profile:
            result = function()
        report['actual_operator_trace'] = [event.key for event in profile.key_averages()]
        assert torch.isfinite(result).all().item()
        values = np.array(all_samples).reshape(-1)
        report.update(status='pass_timing_only', samples_ms=all_samples,
                      median_ms=float(np.median(values)),
                      q25_ms=float(np.quantile(values, 0.25)),
                      q75_ms=float(np.quantile(values, 0.75)))
        report['load_average_after'] = list(os.getloadavg())
        write_json(args.output, report)
        print(json.dumps({key: report[key] for key in ('status', 'device', 'median_ms')}))
    finally:
        if context is not None:
            context.__exit__(None, None, None)


if __name__ == '__main__':
    main()
