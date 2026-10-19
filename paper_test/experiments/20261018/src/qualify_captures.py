"""Wait for independent calibration, then qualify captured native-shape SDPA jobs."""

import argparse
import fcntl
import json
import math
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as functional

from capture_trajectories import MODELS, sha, write_json
from fixed_point_shadow import encode_multiplier, shadow


def calibration(root, model):
    config = MODELS[model]
    required = [root / model / f'calibration_p{pixel}_seed{seed}' / 'complete.json'
                for pixel in (config['pixels'][0], config['pixels'][-1])
                for seed in (1001, 1002)]
    if not all(path.exists() for path in required):
        return None
    ranges = {}
    sources = {}
    for path in required:
        report = json.loads(path.read_text())
        sources[str(path.relative_to(root))] = sha(path)
        assert report['status'] == 'passed_capture'
        for layer, values in report['stats'].items():
            current = ranges.setdefault(layer, {})
            for tensor in ('q', 'k', 'v', 'o'):
                current[tensor] = max(current.get(tensor, 0), values[tensor + '_maxabs'])
    scales = {}
    for layer, values in ranges.items():
        factors = {name: max(value / 127, 1e-12) for name, value in values.items()}
        scales[layer] = {
            **factors,
            'score': encode_multiplier(256 * factors['q'] * factors['k'] /
                                       math.sqrt(config['dim'])),
            'out': encode_multiplier(factors['v'] / (32768 * factors['o'])),
        }
    frozen = root / model / 'frozen_scales.json'
    report = {'calibration_sources': sources, 'scales': scales,
              'limits': {'relative_l2_per_head': 0.05, 'cosine_per_head': 0.99,
                         'pv_overflow_events': 0},
              'policy': 'all heads share job-global scales; independent maxabs calibration'}
    if frozen.exists():
        assert json.loads(frozen.read_text()) == report, 'Frozen scales changed'
    else:
        write_json(frozen, report)
    return report


def metrics(answer, reference):
    first = answer.astype(np.float64).reshape(-1)
    second = reference.astype(np.float64).reshape(-1)
    delta = first - second
    return {
        'relative_l2': float(np.linalg.norm(delta) / max(np.linalg.norm(second), 1e-12)),
        'cosine': float(np.dot(first, second) /
                        max(np.linalg.norm(first) * np.linalg.norm(second), 1e-12)),
        'mae': float(np.mean(np.abs(delta))),
        'rmse': float(np.sqrt(np.mean(delta ** 2))),
    }


def qualify(path, frozen, output, sample_only=False, diagnostic_precision=False):
    vector = torch.load(path, map_location='cpu', weights_only=True)
    metadata = vector['metadata']
    config = frozen['scales'][str(metadata['layer'])]
    nq = vector['q'].shape[2]
    heads = vector['q'].shape[1]
    mode = 'sampled' if sample_only else 'full'
    directory = output / 'qualification' / metadata['model'] / path.parent.name / path.stem / mode
    report_path = directory / 'qualification.json'
    if report_path.exists():
        existing = json.loads(report_path.read_text())
        assert existing['vector_sha256'] == sha(path)
        if not diagnostic_precision or (directory / 'replay_manifest.json').exists():
            return existing
        original = directory / 'qualification_before_precision_deferral.json'
        if not original.exists():
            original.write_bytes(report_path.read_bytes())
    directory.mkdir(parents=True, exist_ok=True)
    quantized = {}
    clipping = {}
    for name in ('q', 'k', 'v'):
        raw = vector[name].float().numpy() / config[name]
        # Half-away-from-zero is the frozen software quantization rule.
        integers = np.sign(raw) * np.floor(np.abs(raw) + 0.5)
        clipping[name] = int((np.abs(integers) > 127).sum())
        quantized[name] = np.clip(integers, -127, 127).astype(np.int8)
    indices = (np.unique(np.linspace(0, nq - 1, 32, dtype=int))
               if sample_only else np.arange(nq))
    per_head = []
    integer_outputs = []
    for head in range(heads):
        cached_report = directory / f'head{head:02d}.json'
        cached_output = directory / f'head{head:02d}.output.bin'
        if cached_report.exists() and cached_output.exists():
            integer_output = np.fromfile(cached_output, dtype=np.int8)
            integer_output = integer_output.reshape(len(indices), vector['v'].shape[3])
            per_head.append(json.loads(cached_report.read_text()))
            integer_outputs.append(integer_output)
            continue
        original = [vector[name][:, head:head + 1].float() for name in ('q', 'k', 'v')]
        qkv_int = [quantized[name][0, head] for name in ('q', 'k', 'v')]
        integer_output, statistics = shadow(
            *qkv_int, config['score']['register'], config['out']['register'], indices,
        )
        # The CPU SDPA kernel computes a dense reference without a disk-sized NxN matrix.
        reference = functional.scaled_dot_product_attention(
            original[0][:, :, indices], original[1], original[2],
        )[0, 0].numpy()
        dequantized = [torch.from_numpy(tensor.astype(np.float32) * config[name])[None, None]
                       for name, tensor in zip(('q', 'k', 'v'), qkv_int)]
        quantized_reference = functional.scaled_dot_product_attention(
            dequantized[0][:, :, indices], dequantized[1], dequantized[2],
        )[0, 0].numpy()
        hardware_output = integer_output.astype(np.float32) * config['o']
        result = {
            'head': head, 'integer': statistics,
            'total_error': metrics(hardware_output, reference),
            'input_quantization_error': metrics(quantized_reference, reference),
            'fixed_point_error': metrics(hardware_output, quantized_reference),
        }
        result['passes'] = (statistics['pv_overflow_events'] == 0 and
                            statistics['row_sum_saturations'] == 0 and
                            result['total_error']['relative_l2'] <= 0.05 and
                            result['total_error']['cosine'] >= 0.99)
        per_head.append(result)
        integer_outputs.append(integer_output)
        integer_output.tofile(cached_output)
        write_json(directory / f'head{head:02d}.json', result)
        print('QUALIFIED_HEAD', str(path), head, result['passes'],
              result['total_error'], statistics['pv_overflow_events'], flush=True)
    passes = all(item['passes'] for item in per_head)
    report = {
        'status': ('pass_full_shadow' if not sample_only else 'pass_sampled_shadow')
                  if passes else 'failed_numerical_gate',
        'vector_sha256': sha(path), 'metadata': metadata, 'scales': config,
        'calibration_sha256': sha(output / metadata['model'] / 'frozen_scales.json'),
        'input_clipping_counts': clipping, 'heads': per_head,
        'query_indices': indices.tolist(), 'all_query_rows_checked': not sample_only,
        'all_kv_rows_checked': True,
        'precision_gate_is_diagnostic': diagnostic_precision,
        'accuracy_pass': passes,
        'arithmetic_scope': 'unchanged current RTL, including signed INT32 wrap',
        'shadow_sha256': sha(Path(__file__).with_name('fixed_point_shadow.py')),
    }
    write_json(report_path, report)
    if (passes or diagnostic_precision) and not sample_only:
        for name, tensor in quantized.items():
            tensor.tofile(directory / (name + '.bin'))
        np.stack(integer_outputs).tofile(directory / 'o.bin')
        write_json(directory / 'replay_manifest.json', {
            'heads': heads, 'nq': nq, 'nkv': quantized['k'].shape[2],
            'd': vector['q'].shape[3], 'score_scale': config['score']['register'],
            'out_scale': config['out']['register'],
            'qualification_sha256': sha(report_path),
            'precision_gate_is_diagnostic': diagnostic_precision,
            'accuracy_pass': passes,
            'arithmetic_scope': report['arithmetic_scope'],
            'shadow_sha256': report['shadow_sha256'],
            'files_sha256': {name: sha(directory / name)
                             for name in ('q.bin', 'k.bin', 'v.bin', 'o.bin')},
        })
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--diagnostic-precision', action='store_true')
    parser.add_argument('--model', choices=sorted(MODELS))
    args = parser.parse_args()
    suffix = '_' + args.model if args.model else ''
    lock_handle = (args.output / ('qualification' + suffix + '.lock')).open('w')
    fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    torch.set_num_threads(8)
    torch.set_grad_enabled(False)
    if args.diagnostic_precision:
        pending = {(model, pixel) for model, config in MODELS.items()
                   if args.model is None or args.model == model for pixel in config['pixels']}
        for _ in range(48 * 60 * 2):
            for model, pixel in sorted(pending):
                frozen = calibration(args.output, model)
                point = args.output / model / f'evaluation_p{pixel}_seed301'
                if frozen is None or not (point / 'complete.json').exists():
                    continue
                layer = MODELS[model]['layers'][1]
                report = qualify(point / f'l{layer:02d}_s15.pt', frozen, args.output,
                                 diagnostic_precision=True)
                print('EXPORTED_FUNCTIONAL_REPLAY', model, pixel,
                      'accuracy_pass=', report['accuracy_pass'], flush=True)
                pending.remove((model, pixel))
            if not pending:
                write_json(args.output / ('diagnostic_export' + suffix + '_complete.json'), {
                    'status': 'all_full_vectors_exported', 'precision_qualified': False,
                })
                return
            time.sleep(30)
        raise RuntimeError('Diagnostic replay export exceeded its 48-hour limit')
    remaining = set(MODELS)
    for _ in range(48 * 60 * 2):
        for model in sorted(remaining):
            frozen = calibration(args.output, model)
            if frozen is None:
                continue
            config = MODELS[model]
            short = args.output / model / (
                f"evaluation_p{config['pixels'][0]}_seed301")
            long = args.output / model / (
                f"evaluation_p{config['pixels'][-1]}_seed301")
            mid = config['layers'][1]
            if not (short / 'complete.json').exists():
                continue
            pilot = qualify(short / f'l{mid:02d}_s15.pt', frozen, args.output)
            if pilot['status'] == 'failed_numerical_gate':
                write_json(args.output / model / 'numerical_gate_failed.json', pilot)
                remaining.remove(model)
                continue
            if not (long / 'complete.json').exists():
                continue
            sampled = qualify(long / f'l{mid:02d}_s15.pt', frozen, args.output, True)
            if sampled['status'] == 'failed_numerical_gate':
                write_json(args.output / model / 'numerical_gate_failed.json', sampled)
                remaining.remove(model)
            else:
                write_json(args.output / model / 'long_sample_gate_passed.json', sampled)
                all_finished = True
                for pixels in config['pixels']:
                    point = args.output / model / f'evaluation_p{pixels}_seed301'
                    if not (point / 'complete.json').exists():
                        all_finished = False
                        continue
                    full = qualify(point / f'l{mid:02d}_s15.pt', frozen, args.output)
                    if full['status'] == 'failed_numerical_gate':
                        write_json(args.output / model / 'numerical_gate_failed.json', full)
                        remaining.remove(model)
                        all_finished = False
                        break
                if all_finished:
                    write_json(args.output / model / 'all_main_vectors_qualified.json',
                               {'status': 'pass_full_shadow'})
                    remaining.remove(model)
        if not remaining:
            return
        time.sleep(30)
    raise RuntimeError('Capture qualification queue reached its 48-hour limit')


if __name__ == '__main__':
    main()
