"""Read the model-server result metadata for the paper checklist."""

import datetime
import hashlib
import json
from pathlib import Path


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
MODELS = {'pixart': (16, 72, 14, [512, 768, 1024, 1536, 2048]),
          'wan': (12, 128, 15, [256, 384, 512, 768, 1024])}
LENGTHS = [1024, 2304, 4096, 9216, 16384]


def load(path):
    return json.loads(path.read_text()) if path.exists() else {}


def collect():
    items = {}

    def record(key, done, path, status='待测'):
        items[key] = {'done': bool(done), 'status': '完成并核验' if done else status,
                      'evidence': str(path)}

    for model, (_, _, layer, pixels) in MODELS.items():
        points = [ROOT / model / f'evaluation_p{pixel}_seed301' for pixel in pixels]
        captures = [point / 'complete.json' for point in points]
        record(model + '_capture', all(load(path).get('status') == 'passed_capture'
                                       for path in captures), ROOT / model, '采集未齐')
        calibration = [ROOT / model / f'calibration_p{pixel}_seed{seed}/complete.json'
                       for pixel in (pixels[0], pixels[-1]) for seed in (1001, 1002)]
        record(model + '_calibration', all(load(path).get('status') == 'passed_capture'
                                          for path in calibration) and
               (ROOT / model / 'frozen_scales.json').exists(), ROOT / model)
        micro = ROOT / 'power_vectors' / f'{model}_n256_s301/replay_manifest.json'
        record(model + '_power_calibration', micro.exists(), micro)
        count = 28 if model == 'pixart' else 30
        for layer_n, pixel_index in [(1024, 0), (4096, 2)]:
            suffix = '' if layer_n == 1024 else f'_n{layer_n}'
            prefix = model + '_layerstep' + suffix
            layer_point = ROOT / model / f'layerstep_p{pixels[pixel_index]}_seed301'
            record(prefix + '_capture',
                   load(layer_point / 'complete.json').get('status') == 'passed_capture',
                   layer_point)
            exported = ROOT / model / f'layerstep{suffix}_export_complete.json'
            record(prefix + '_golden', load(exported).get('layers') == count,
                   exported, '全部层整数参考生成中')
            gpu_path = ROOT / 'baselines/layerstep_gpu' / f'{model}{suffix}.json'
            gpu_report = load(gpu_path)
            record(prefix + '_gpu', gpu_report.get('status') == 'pass_timing_only' and
                   gpu_report.get('layers') == count, gpu_path, '等待空闲GPU或排队')
            if gpu_report:
                items[prefix + '_gpu']['result'] = gpu_report
        for n, pixel, point in zip(LENGTHS, pixels, points):
            directory = ROOT / 'qualification' / model / point.name / (
                f'l{layer:02d}_s15/full')
            manifest = load(directory / 'replay_manifest.json')
            qualification_path = directory / 'qualification.json'
            qualification = load(qualification_path)
            digest = (hashlib.sha256(qualification_path.read_bytes()).hexdigest()
                      if qualification_path.exists() else None)
            ready = (bool(manifest) and manifest.get('qualification_sha256') == digest and
                     qualification.get('all_query_rows_checked') is True and
                     qualification.get('all_kv_rows_checked') is True)
            record(f'{model}_golden_{n}', ready, directory,
                   '整数参考生成中或排队；精度结果仅诊断')
            for device, folder in [('gpu', 'cuda')]:
                path = ROOT / 'baselines' / folder / f'{model}_p{pixel}.json'
                report = load(path)
                ready = (report.get('status') == 'pass_timing_only' and
                         bool(report.get('samples_ms')))
                note = '等待空闲 GPU 或排队'
                record(f'{model}_{device}_{n}', ready, path, note)
            path = ROOT / 'baselines/gpu_energy' / f'{model}_p{pixel}.json'
            energy = load(path)
            trials = energy.get('trials', [])
            ready = (energy.get('status') == 'pass_energy_only' and len(trials) == 3 and
                     all(trial.get('wall_s', 0) >= 10 and
                         trial.get('actual_sdpa_calls', 0) > 0 and
                         trial.get('energy_j', 0) > 0 for trial in trials))
            key = f'{model}_gpu_energy_{n}'
            record(key, ready, path, '等待空闲GPU或能量测量排队')
            if ready:
                items[key]['result'] = {
                    key: energy[key] for key in ('status', 'gpu_uuid', 'shape', 'dtype',
                        'backend', 'vector_sha256', 'median_gross_uj_per_sdpa',
                        'minimum_gross_uj_per_sdpa', 'maximum_gross_uj_per_sdpa', 'scope')
                }
                items[key]['result']['source'] = str(path)
                items[key]['result']['source_sha256'] = hashlib.sha256(
                    path.read_bytes()).hexdigest()
                items[key]['result']['trials'] = [
                    {field: trial[field] for field in ('energy_j', 'wall_s',
                        'actual_sdpa_calls', 'mean_board_w', 'gross_uj_per_sdpa',
                        'sustained_ms_per_sdpa')} for trial in trials]
    return {'updated_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'items': items}


if __name__ == '__main__':
    print(json.dumps(collect(), ensure_ascii=True))
