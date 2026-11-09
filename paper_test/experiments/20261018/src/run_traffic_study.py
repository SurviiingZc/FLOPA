"""Measure actual byte-macro accesses and replay real P columns through SRAM."""

import csv
import json
import re
import subprocess
import time
from pathlib import Path

from submit_replay import ROOT, sha, write


PROJECT = ROOT.parents[2]
STUDY = ROOT / 'traffic_study_20261021'


def run(command, cwd, log):
    with log.open('w') as handle:
        subprocess.run(command, cwd=str(cwd), stdout=handle,
                       stderr=subprocess.STDOUT, check=True)


def build():
    proof = json.loads((PROJECT / 'paper_test/provenance/formatting/rtl_equivalence.json').read_text())
    assert proof['source_commit'].startswith('fc9e921')
    for entry in proof['files']:
        if entry['path'].startswith('rtl/'):
            assert entry['verilog_tokens_strings_comments_equal'] is True
            assert sha(PROJECT / entry['path']) == entry['formatted_sha256'], entry['path']
    main = STUDY / 'build'
    replay = STUDY / 'reference_build'
    for folder in (main, replay):
        folder.mkdir(parents=True, exist_ok=True)
    base = ['vcs', '-full64', '-sverilog', '-timescale=1ns/1ps', '+define+ATTN_ASIC',
            '-f', 'filelists/asic_models.f']
    run(base + ['-f', 'filelists/rtl.f', str(ROOT / 'src/tb_paper_replay.sv'),
                str(ROOT / 'src/tb_traffic_monitors.sv'), '-top', 'tb_paper_replay',
                '-Mdir=' + str(main / 'csrc'), '-o', str(main / 'simv')],
        PROJECT / 'tb/sim', main / 'compile.log')
    run(base + [str(PROJECT / 'rtl/memory/asic_sram_256xwide.v'),
                str(ROOT / 'src/tb_p_buffer_trace.sv'), '-top', 'tb_p_buffer_trace',
                '-Mdir=' + str(replay / 'csrc'), '-o', str(replay / 'simv')],
        PROJECT / 'tb/sim', replay / 'compile.log')
    return main / 'simv', replay / 'simv'


def classify(path):
    for name in ('q', 'k', 'v'):
        if f'.u_tile_cache.u_{name}' in path:
            return name
    if '.u_fused_array.' in path:
        return 'o'
    if '.u_output_buffer.' in path:
        return 'output'
    raise AssertionError('Unclassified physical SRAM macro: ' + path)


def measure(model, n, dim, executable, reference):
    name = f'{model}_n{n}'
    folder = STUDY / 'inputs' / name
    target = STUDY / 'runs' / name
    target.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((folder / 'replay_manifest.json').read_text())
    assert (manifest['heads'], manifest['nq'], manifest['nkv'], manifest['d']) == (1, n, n, dim)
    for filename, digest in manifest['files_sha256'].items():
        assert sha(folder / filename) == digest
    command = [str(executable), '+VECTOR_DIR=' + str(folder),
               '+RESULT=' + str(target / 'result.csv'), '+NQ=' + str(n), '+NKV=' + str(n),
               '+HEADS=1', '+DIM=' + str(dim), '+CLK_PERIOD_NS=1.6',
               '+SCORE_SCALE={:08x}'.format(manifest['score_scale']),
               '+OUT_SCALE={:08x}'.format(manifest['out_scale']),
               '+P_TRACE=' + str(target / 'probability.txt'), '+no_notifier', '+notimingcheck']
    run(command, target, target / 'rtl.log')
    text = (target / 'rtl.log').read_text(errors='replace')
    assert '[PASS] tb_paper_replay' in text and 'Fatal:' not in text
    assert sha(target / 'result.csv.observed.bin') == manifest['files_sha256']['o.bin']
    with (target / 'result.csv').open() as handle:
        result_row = next(csv.DictReader(handle))
    assert result_row['status'] == 'pass'
    macros = re.findall(r'^MEM_TRAFFIC,([^,]+),(\d+),(\d+)$', text, re.M)
    assert len(macros) == 480 and len({row[0] for row in macros}) == 480
    traffic = {name: {'read_bytes': 0, 'write_bytes': 0, 'macros': 0}
               for name in ('q', 'k', 'v', 'o', 'output')}
    for path, reads, writes in macros:
        value = traffic[classify(path)]
        value['read_bytes'] += int(reads)
        value['write_bytes'] += int(writes)
        value['macros'] += 1
    pe = re.findall(r'^PE_TRAFFIC,[^,]+,(\d+),(\d+),(\d+),(\d+)$', text, re.M)
    assert len(pe) == 1024
    totals = [sum(int(row[index]) for row in pe) for index in range(4)]
    tiles = ((n + 31) // 32) ** 2
    assert totals[0] == tiles * 1024
    assert totals[1] == n * n
    assert totals[3] == n * n * dim
    run([str(reference), '+P_TRACE=' + str(target / 'probability.txt'),
         '+no_notifier', '+notimingcheck'], target, target / 'reference.log')
    replay_text = (target / 'reference.log').read_text(errors='replace')
    assert '[PASS] tb_p_buffer_trace' in replay_text and 'Fatal:' not in replay_text
    replay = re.search(r'^BUFFER_REPLAY,(\d+),(\d+),(\d+),(\d+)$', replay_text, re.M)
    assert replay
    reference_tiles, words, read_bytes, write_bytes = map(int, replay.groups())
    assert reference_tiles == tiles and words == tiles * 32
    assert read_bytes == write_bytes == tiles * 2048
    return {
        'state': 'pass_measured_traffic', 'model': model, 'n': n, 'heads': 1, 'd': dim,
        'tiles': tiles, 'cycles': int(result_row['cycles']),
        'loader_bytes': int(result_row['loader_bytes']),
        'output_bytes': int(result_row['output_bytes']), 'macro_accesses': traffic,
        'flopa_sram_read_bytes': sum(value['read_bytes'] for value in traffic.values()),
        'flopa_sram_write_bytes': sum(value['write_bytes'] for value in traffic.values()),
        'flopa_p_sram_read_bytes': 0, 'flopa_p_sram_write_bytes': 0,
        'p_register_loads_physical': totals[0], 'p_register_loads_useful': totals[1],
        'p_pv_uses_physical': totals[2], 'p_pv_uses_useful': totals[3],
        'useful_p_reuse': totals[3] / totals[1],
        'p_buffer_trace_read_bytes': read_bytes,
        'p_buffer_trace_write_bytes': write_bytes,
        'p_buffer_words_checked': words,
        'reference_scope': 'traffic-only SRAM spill/reload of actual RTL P columns',
        'reference_is_full_accelerator_variant': False,
        'functional_byte_exact_pass': True, 'macro_count': 480,
        'pe_count': 1024, 'mask_tail_case': n % 32 != 0,
        'input_manifest': manifest,
        'source_sha256': {name: sha(target / name) for name in (
            'rtl.log', 'reference.log', 'probability.txt', 'result.csv',
            'result.csv.observed.bin')},
    }


def main():
    STUDY.mkdir(parents=True, exist_ok=True)
    report = {'state': 'building', 'started_unix': time.time(), 'results': {}}
    state = STUDY / 'status.json'
    write(state, report)
    try:
        executable, reference = build()
        report['executable_sha256'] = sha(executable)
        report['reference_executable_sha256'] = sha(reference)
        report['rtl_unchanged_from_synthesis_input'] = 'fc9e921 modulo whitespace normalization'
        for model, dim in [('pixart', 72), ('wan', 128)]:
            for n in (33, 64, 128, 256):
                name = f'{model}_n{n}'
                report.update(state='running', active=name)
                write(state, report)
                report['results'][name] = measure(model, n, dim, executable, reference)
                write(state, report)
                print('TRAFFIC_PASS', name, flush=True)
        report.update(state='pass_complete_study', active=None,
                      elapsed_seconds=time.time() - report['started_unix'])
        write(state, report)
        write(ROOT / 'results/traffic_study_20261021.json', report)
    except Exception as error:
        report.update(state='failed', error=repr(error))
        write(state, report)
        raise


if __name__ == '__main__':
    main()
