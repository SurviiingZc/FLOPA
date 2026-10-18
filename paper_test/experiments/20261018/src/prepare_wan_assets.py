"""Fetch and verify missing Wan conditioning assets, never transformer weights."""

import hashlib
import json
import os
import shutil
import time
from pathlib import Path

import requests


ROOT = Path('/10T/zhangcheng/DiT_models/wan2_1_t2v_1_3b_diffusers')
OUT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
BASE = 'https://modelscope.cn/api/v1/models/Wan-AI/Wan2.1-T2V-1.3B-Diffusers/repo'


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(8 << 20), b''):
            result.update(chunk)
    return result.hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    response = requests.get(BASE + '/files', params={
        'Revision': 'master', 'Root': '', 'Recursive': 'true',
    }, timeout=60)
    response.raise_for_status()
    selected = []
    for item in response.json()['Data']['Files']:
        name = item['Path']
        include = name.startswith(('text_encoder/', 'tokenizer/', 'scheduler/'))
        include |= name in ('model_index.json', 'vae/config.json')
        if item['Type'] == 'blob' and include:
            selected.append(item)
    assert any(x['Path'].startswith('text_encoder/') for x in selected)
    (OUT / 'wan_asset_manifest.json').write_text(json.dumps(selected, indent=2) + '\n')
    for item in selected:
        target = ROOT / item['Path']
        expected = item.get('Sha256')
        assert expected, item
        if target.exists() and target.stat().st_size == item['Size']:
            if digest(target) == expected:
                print('EXISTING_VERIFIED', item['Path'], flush=True)
                continue
        assert shutil.disk_usage(ROOT).free > item['Size'] + (20 << 30)
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_suffix(target.suffix + '.flopa_part')
        for attempt in range(3):
            try:
                download = requests.get(BASE, params={
                    'Revision': item['Revision'], 'FilePath': item['Path'],
                }, stream=True, timeout=(60, 180))
                download.raise_for_status()
                count = 0
                sha = hashlib.sha256()
                with temp.open('wb') as handle:
                    for chunk in download.iter_content(8 << 20):
                        handle.write(chunk)
                        sha.update(chunk)
                        count += len(chunk)
                        if count % (1 << 30) < len(chunk):
                            print('PROGRESS', item['Path'], count, flush=True)
                assert count == item['Size'], (count, item['Size'])
                assert sha.hexdigest() == expected, item['Path']
                os.replace(temp, target)
                print('VERIFIED', item['Path'], expected, flush=True)
                break
            except Exception as error:
                print('RETRY', attempt, repr(error), flush=True)
                if attempt == 2:
                    raise
                time.sleep(5)
    (OUT / 'wan_assets_complete.json').write_text(json.dumps({
        'status': 'verified', 'files': len(selected),
        'manifest_sha256': digest(OUT / 'wan_asset_manifest.json'),
    }, indent=2) + '\n')
    print('WAN_CONDITIONING_ASSETS_VERIFIED', flush=True)


if __name__ == '__main__':
    main()
