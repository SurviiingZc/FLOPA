"""Independently audit saved paired PixArt outputs without running generation."""

import collections
import datetime
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
from skimage.metrics import structural_similarity
import torch


ROOT = Path('/10T/zhangcheng/flopa_accuracy_20261024')
QUALITY = ROOT / 'quality'
ORIGINAL = Path('/10T/zhangcheng/flopa_evaluation_20261018')


def read(path):
    return json.loads(path.read_text())


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(4 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    summary_path = QUALITY / 'quality_summary.json'
    summary = read(summary_path)
    protocol = read(QUALITY / 'quality_protocol.json')
    assert summary['state'] == 'complete'
    assert summary['completed'] == summary['total'] == len(summary['cases']) == 4
    source = ROOT / 'run_pixart_quality.py'
    source_text = source.read_text()
    frozen = ORIGINAL / 'pixart/frozen_scales.json'
    original_baseline = read(ROOT / 'existing_accuracy_aggregate.json')
    assert sha(frozen) == protocol['calibration_sha256']
    assert sha(frozen) == original_baseline['calibration']['pixart']['sha256']
    assert sha(source) == protocol['script_sha256']
    assert sha(ROOT / 'rtl_shadow_torch.py') == protocol['shadow_source_sha256']
    assert sha(ORIGINAL / 'pixart/embeddings.pt') == protocol['embeddings_sha256']
    source_checks = {
        'only_attn1_modules_hooked': 'if name.endswith(".attn1")' in source_text,
        'outside_attn1_original_sdpa':
            'if self.current_layer is None:\n            return self.original(' in source_text,
        'post_hook_clears_current_layer':
            'def leave(self, module, args, result):\n        self.current_layer = None'
            in source_text,
        'shared_initial_clone_for_both_variants':
            '"latents": initial.clone()' in source_text,
        'fresh_same_scheduler_for_each_variant':
            'pipe.scheduler = DPMSolverMultistepScheduler.from_config(protocol["scheduler"])'
            in source_text,
        'read_original_layer_scales':
            'scale = self.frozen["scales"][str(self.current_layer)]' in source_text,
    }
    assert all(source_checks.values()), source_checks
    cases = []
    expected_pairs = collections.Counter(
        (step, layer) for step in range(30) for layer in range(28)
    )
    for recorded in summary['cases']:
        folder = QUALITY / recorded['case']
        result = read(folder / 'result.json')
        assert result == recorded
        calls_path = folder / 'attention_calls.json'
        calls = read(calls_path)
        assert len(calls) == 840 == result['self_attention_calls_replaced']
        assert collections.Counter(
            (call['step'], call['layer']) for call in calls
        ) == expected_pairs
        assert all(call['shape'] == [2, 16, 1024, 72] for call in calls)
        assert all(call['statistics']['full_query_coverage'] for call in calls)
        assert all(call['statistics']['all_kv_rows_checked'] for call in calls)
        assert all(call['statistics']['unity_bypass'] is False for call in calls)
        initial_path = folder / 'initial_latents.pt'
        assert sha(initial_path) == result['paired_initial_latents_sha256']
        initial = torch.load(initial_path, map_location='cpu', weights_only=True)
        expected = torch.randn(
            (1, 4, 64, 64), generator=torch.Generator('cpu').manual_seed(result['seed']),
            dtype=torch.float16,
        )
        assert torch.equal(initial, expected)
        images = {}
        image_hashes = {}
        latents = {}
        for variant in ('fp16', 'flopa'):
            image_path = folder / (variant + '.png')
            image_hashes[variant] = sha(image_path)
            assert image_hashes[variant] == result['output_sha256'][variant]
            images[variant] = np.asarray(Image.open(image_path), dtype=np.float64) / 255
            assert images[variant].shape == (512, 512, 3)
            latents[variant] = torch.load(
                folder / (variant + '_final_latents.pt'), map_location='cpu', weights_only=True
            ).float()
            assert torch.isfinite(latents[variant]).all()
        error = images['flopa'] - images['fp16']
        mse = float(np.mean(error ** 2))
        recomputed = {
            'pixel_mae_0_to_1': float(np.mean(np.abs(error))),
            'pixel_rmse_0_to_1': float(np.sqrt(mse)),
            'psnr_db': float(10 * np.log10(1 / mse)),
            'ssim': float(structural_similarity(
                images['flopa'], images['fp16'], channel_axis=-1, data_range=1,
                gaussian_weights=True, sigma=1.5, use_sample_covariance=False,
            )),
        }
        deltas = {key: recomputed[key] - result['image_metrics'][key]
                  for key in recomputed}
        assert all(abs(value) < 1e-12 for value in deltas.values()), deltas
        latent_error = latents['flopa'] - latents['fp16']
        latent_metrics = {
            'latent_mae': float(latent_error.abs().mean()),
            'latent_rmse': float(latent_error.square().mean().sqrt()),
        }
        assert all(abs(value - result[key]) < 1e-9 for key, value in latent_metrics.items())
        cases.append({
            'case': result['case'], 'seed': result['seed'], 'prompt': result['prompt'],
            'calls': len(calls), 'layers': 28, 'steps': 30,
            'shape_every_call': [2, 16, 1024, 72],
            'coverage_every_step_layer_exactly_once': True,
            'conditional_and_unconditional_replaced': True,
            'initial_latent_matches_seed': True,
            'initial_latent_sha256': sha(initial_path),
            'output_sha256': image_hashes,
            'calls_sha256': sha(calls_path),
            'result_sha256': sha(folder / 'result.json'),
            'recomputed_image_metrics': recomputed,
            'reported_minus_recomputed_absolute_max': max(abs(v) for v in deltas.values()),
            'recomputed_latent_metrics': latent_metrics,
            'input_clipping_counts': {
                name: sum(call['input_clipping'][name] for call in calls)
                for name in ('q', 'k', 'v')
            },
            'output_saturations': sum(
                call['statistics']['output_saturations'] for call in calls
            ),
            'row_sum_saturations': sum(
                call['statistics']['row_sum_saturations'] for call in calls
            ),
            'pv_overflow_events': None,
            'pv_overflow_note': 'Torch shadow does not record this counter; not zero.',
        })
    mean_ssim = float(np.mean([case['recomputed_image_metrics']['ssim'] for case in cases]))
    mean_psnr = float(np.mean([case['recomputed_image_metrics']['psnr_db'] for case in cases]))
    assert abs(mean_ssim - summary['mean_ssim']) < 1e-12
    assert abs(mean_psnr - summary['mean_psnr_db']) < 1e-12
    answer = {
        'state': 'pass_saved_artifact_audit',
        'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'scope': 'Read-only saved-output verification; no model run or optimization.',
        'summary_sha256': sha(summary_path),
        'protocol_sha256': sha(QUALITY / 'quality_protocol.json'),
        'quality_runner_sha256': sha(source),
        'frozen_scales_sha256': sha(frozen),
        'shadow_sha256': sha(ROOT / 'rtl_shadow_torch.py'),
        'audit_script_sha256': sha(Path(__file__)),
        'source_checks': source_checks,
        'source_check_limit': 'Cross-attention preservation verified from hook scope in source.',
        'initial_latent_check_limit':
            'One shared initializer is saved; both branches receive its clone in audited source.',
        'cases': cases,
        'mean_ssim': mean_ssim,
        'mean_psnr_db': mean_psnr,
        'ssim_range': [min(case['recomputed_image_metrics']['ssim'] for case in cases),
                       max(case['recomputed_image_metrics']['ssim'] for case in cases)],
        'psnr_db_range': [min(case['recomputed_image_metrics']['psnr_db'] for case in cases),
                          max(case['recomputed_image_metrics']['psnr_db'] for case in cases)],
        'near_lossless_supported': False,
        'conclusion': 'Substantial paired-image differences; results do not support near lossless.',
        'population_quality_claim': False,
        'sample_scope':
            'Four prespecified prompt/seed pairs at 512 pixels; two calibration prompts.',
    }
    destination = ROOT / 'audit_quality.json'
    destination.write_text(json.dumps(answer, ensure_ascii=False, indent=4) + '\n')
    print(json.dumps({'output': str(destination), 'mean_psnr_db': mean_psnr,
                      'mean_ssim': mean_ssim, 'near_lossless_supported': False}), flush=True)


if __name__ == '__main__':
    main()
