"""Measure a resident sequence of all self-attention layers at one captured step."""

import json
import argparse
import time
from pathlib import Path

import torch
import torch.nn.functional as functional
from torch.nn.attention import SDPBackend, sdpa_kernel

from benchmark_sdpa import check_gpu_exclusive, samples
from capture_trajectories import MODELS, sha, wait_for_gpu, write_json


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
parser = argparse.ArgumentParser()
parser.add_argument('--n', type=int, choices=[1024, 4096], default=1024)
args = parser.parse_args()
torch.set_num_threads(4)
torch.set_grad_enabled(False)
torch.backends.cuda.matmul.allow_tf32 = False
for model, config in MODELS.items():
    count = 28 if model == 'pixart' else 30
    pixel = config['pixels'][0 if args.n == 1024 else 2]
    point = ROOT / model / f'layerstep_p{pixel}_seed301'
    name = f'{model}.json' if args.n == 1024 else f'{model}_n{args.n}.json'
    destination = ROOT / 'baselines/layerstep_gpu' / name
    if destination.exists():
        continue
    for _ in range(48 * 60 * 2):
        if (point / 'complete.json').exists():
            break
        time.sleep(30)
    else:
        raise RuntimeError('Layerstep capture incomplete: ' + model)
    wait_for_gpu(ROOT)
    lock = (ROOT / 'gpu_capture_timing.lock').open('w')
    import fcntl
    fcntl.flock(lock, fcntl.LOCK_EX)
    wait_for_gpu(ROOT)
    uuid = check_gpu_exclusive()
    sources = []
    vectors = []
    disagreements = []
    with sdpa_kernel(SDPBackend.FLASH_ATTENTION):
        for layer in range(count):
            source = point / f'l{layer:02d}_s15.pt'
            vector = torch.load(source, map_location='cpu', weights_only=True)
            tensors = [vector[name].to('cuda').contiguous() for name in ('q', 'k', 'v')]
            assert list(tensors[0].shape) == [1, config['heads'], args.n, config['dim']]
            answer = functional.scaled_dot_product_attention(*tensors)
            reference = vector['o'].to('cuda').float()
            relative = float((answer.float() - reference).norm() /
                             reference.norm().clamp_min(1e-12))
            assert relative <= 0.005, (model, layer, relative)
            sources.append({'layer': layer, 'file': str(source), 'sha256': sha(source)})
            vectors.append(tensors)
            disagreements.append(relative)

        def operation():
            for tensors in vectors:
                answer = functional.scaled_dot_product_attention(*tensors)
            return answer

        samples(operation, 'cuda', 20)
        measured = []
        for batch in range(3):
            check_gpu_exclusive()
            measured.append(samples(operation, 'cuda', 30))
        with torch.profiler.profile(activities=[torch.profiler.ProfilerActivity.CPU,
                                                torch.profiler.ProfilerActivity.CUDA]) as prof:
            operation()
        trace = {event.key: event.count for event in prof.key_averages()}
        assert trace.get('aten::_scaled_dot_product_flash_attention') == count
        check_gpu_exclusive()
    import numpy as np
    values = np.array(measured).reshape(-1)
    write_json(destination, {
        'status': 'pass_timing_only', 'model': model, 'n': args.n, 'layers': count,
        'step_index': 15, 'branch': 'conditional', 'batch': 1, 'heads': config['heads'],
        'd': config['dim'], 'gpu_uuid': uuid, 'dtype': 'FP16', 'backend': 'FLASH_ATTENTION',
        'warmup': 20, 'samples_ms': measured, 'median_ms': float(np.median(values)),
        'q25_ms': float(np.quantile(values, 0.25)), 'q75_ms': float(np.quantile(values, 0.75)),
        'maximum_capture_output_disagreement': max(disagreements),
        'sources': sources, 'actual_operator_trace': trace,
        'scope': 'resident serial sequence of all captured self-attention SDPA calls',
        'excluded': 'interlayer projections, cross-attention, MLP, scheduler, CFG partner',
        'full_denoiser_or_sampling_step_latency': False,
    })
    print('LAYERSTEP_GPU_COMPLETE', model, float(np.median(values)), flush=True)
    del vectors
    torch.cuda.empty_cache()
    fcntl.flock(lock, fcntl.LOCK_UN)
    lock.close()
