"""Extract mapped synthesis and select its exact hash-bound validation evidence."""

import hashlib
import json
import re
from pathlib import Path


def fields(reports, name):
    return dict(line.split('=', 1) for line in (reports / name).read_text().splitlines()
                if '=' in line)


def match_number(pattern, text):
    found = re.search(pattern, text, re.M)
    assert found, pattern
    return float(found.group(1))


def select_validation_manifest(root, expected_sha256):
    """Select matching bytes by SHA256, preferring the live path over identical archives."""
    root = root.resolve()
    if not isinstance(expected_sha256, str) or not re.fullmatch(
        r'[0-9a-fA-F]{64}', expected_sha256
    ):
        raise ValueError('run_config requires a complete validation_manifest_sha256')
    expected_sha256 = expected_sha256.lower()
    candidates = [root / 'paper_test/validation_manifest.json']
    candidates.extend(sorted((root / 'paper_test/provenance').glob('validation_*.json')))
    matches = []
    for candidate in candidates:
        if not candidate.is_file():
            continue
        path = candidate.resolve()
        if root not in path.parents:
            raise ValueError('Validation candidate resolves outside the repository root')
        payload = path.read_bytes()
        if hashlib.sha256(payload).hexdigest() == expected_sha256:
            matches.append((candidate, payload))
    if not matches:
        raise ValueError('No validation manifest matches the synthesis SHA256')
    if any(payload != matches[0][1] for _, payload in matches):
        raise ValueError('Matching validation SHA256 candidates contain different bytes')
    path, payload = matches[0]
    validation = json.loads(payload)
    if validation.get('status') != 'pass':
        raise ValueError('The hash-bound validation manifest has not passed')
    return path, expected_sha256, validation


def main():
    root = Path(__file__).resolve().parents[1]
    reports = root / 'asic/dc/work/synth/tt/diffusion_runtime_d/attention_accel_top/reports'
    # Read synthesis provenance first. A newer passing live validation cannot
    # replace the archived validation file that actually authorized this run.
    config = fields(reports, 'run_config.rpt')
    validation_path, validation_sha256, validation = select_validation_manifest(
        root, config.get('validation_manifest_sha256'))
    timing_status = fields(reports, 'timing_status.rpt')
    assert config['FA_GIT_COMMIT'] == validation['git_commit']
    assert int(config['validated_max_d']) == 128
    assert validation['max_d'] == int(config['validated_max_d'])
    assert validation['tests'] and all(test['status'] == 'pass' for test in validation['tests'])
    assert int(config['sram_macro_count']) == validation['expected_sram_macros']
    assert int(config['rtl_icg_count']) == validation['expected_rtl_icgs']
    assert config['automatic_clock_gating'] == '0'
    area_text = (reports / 'area.rpt').read_text()
    power_text = (reports / 'power.rpt').read_text()
    timing_text = (reports / 'timing.rpt').read_text()
    min_text = (reports / 'timing_min.rpt').read_text()
    area = match_number(r'^Total cell area:\s+([\d.]+)', area_text)
    macro_area = match_number(r'^Macro/Black Box area:\s+([\d.]+)', area_text)
    slacks = re.findall(r'slack \([^)]*\)\s+(-?[\d.]+)', timing_text)
    min_slacks = re.findall(r'slack \([^)]*\)\s+(-?[\d.]+)', min_text)
    assert slacks and min_slacks
    total_power = re.findall(
        r'^Total\s+.*?([\d.eE+-]+)\s+mW\s*$', power_text, re.M
    )
    assert total_power
    result = {
        'git_commit': config['FA_GIT_COMMIT'], 'rtl_sha256': config['FA_RTL_HASH'],
        'validation_manifest': str(validation_path.relative_to(root)),
        'validation_manifest_sha256': validation_sha256,
        'validated_max_d': 128, 'clock_period_ns': float(config['clock_period_ns']),
        'target_clock_mhz': 1000 / float(config['clock_period_ns']),
        'area_library_um2': area, 'area_mm2': area / 1e6,
        'sram_area_mm2': macro_area / 1e6,
        'sram_macro_count': int(config['sram_macro_count']),
        'explicit_rtl_icgs': int(config['rtl_icg_count']),
        'dw_multipliers': int(config['linked_dw02_mult_count']),
        'worst_setup_slack_ns': min(map(float, slacks)),
        'worst_hold_slack_ns': min(map(float, min_slacks)),
        'timing_status': timing_status,
        'vectorless_reported_total_mw': float(total_power[-1]),
        'power_boundary': 'DC default vectorless estimate; no new gate-SAIF activity',
        'physical_boundary': 'mapped TT synthesis; no placement, routed RC or CTS signoff',
        'completed_functional_jobs': validation['completed_jobs'],
        'checked_output_bytes': validation['checked_bytes'],
        'report_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(reports.glob('*.rpt'))},
        'reports': str(reports.relative_to(root)),
    }
    destination = root / 'paper_test/synthesis_summary.json'
    destination.write_text(json.dumps(result, indent=4) + '\n')
    print(json.dumps({key: value for key, value in result.items()
        if key != 'report_sha256'}, indent=2))


if __name__ == '__main__':
    main()
