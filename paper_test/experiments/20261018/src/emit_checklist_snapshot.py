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
    return {'updated_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'items': items}


if __name__ == '__main__':
    print(json.dumps(collect(), ensure_ascii=True))
