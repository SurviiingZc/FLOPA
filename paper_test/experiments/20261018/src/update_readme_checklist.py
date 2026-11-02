"""Render verified result states into the managed README checklist."""

import csv
import datetime
import fcntl
import hashlib
import json
import re
from pathlib import Path


PROJECT = Path('/data/workspaces/zhangcheng/flash_attention')
PAPER = PROJECT / 'paper_test'
RUN = PAPER / 'experiments/20261018'
F2 = Path('/data/workspaces/zhangcheng/flopa_eval_f2')
BEGIN = '<!-- CURRENT_TEST_CHECKLIST_BEGIN -->'
END = '<!-- CURRENT_TEST_CHECKLIST_END -->'


def load(path):
    return json.loads(path.read_text()) if path.exists() else {}


def main():
    lock = (RUN / 'checklist_update.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX)
    external = load(RUN / 'checklist_model_snapshot.json')
    items = dict(external.get('items', {}))
    manual = load(RUN / 'checklist_manual.json')

    def add(key, done, path, status='待启动'):
        items[key] = {'done': bool(done), 'status': '完成并核验' if done else status,
                      'evidence': str(path)}

    def job(key, name, power=False):
        path = RUN / 'jobs' / name / 'status.json'
        report = load(path)
        done = report.get('state') == 'pass' and report.get('cycles', 0) > 0
        if power:
            done = (done and report.get('functional_byte_exact_pass') is True and
                    report.get('all_user_annotation_percent') == 100 and
                    report.get('annotation_conflicts') == 0 and
                    bool(report.get('activity_based_estimate')))
        state = report.get('state', '待启动')
        notes = {'running': 'RTL 回放运行中', 'gate_running': '门级 SAIF 仿真运行中',
                 'power_readback': 'SAIF 已生成，功耗回读中', 'failed': '失败，待处理'}
        add(key, done, path, notes.get(state, state))

    for model in ('pixart', 'wan'):
        for n in (1024, 2304, 4096, 9216, 16384):
            job(f'{model}_rtl_{n}', f'{model}_n{n}')
            job(f'{model}_native_energy_{n}', f'power_native_{model}_n{n}_s301', power=True)
        job(model + '_power', f'power_{model}_n256_s301', power=True)
    job('f2_power', 'power_f2_pixart_n256_s301', power=True)
    for seed in (302, 303):
        job(f'power_seed{seed}', f'power_pixart_n256_s{seed}', power=True)
    traffic_path = RUN / 'results/traffic_study_20261021.json'
    traffic = load(traffic_path)
    traffic_good = traffic.get('state') == 'pass_complete_study' and (
        len(traffic.get('results', {})) == 8)
    traffic_good = traffic_good and all(
        value.get('functional_byte_exact_pass') is True and
        value.get('macro_count') == 480 and value.get('pe_count') == 1024
        for value in traffic.get('results', {}).values())
    add('traffic_counters', traffic_good, traffic_path,
        'SRAM端口计数与P轨迹读回待核验')
    pilot = RUN / 'results/gate_pilot_d72_n32.json'
    audit = RUN / 'results/pilot_power_flow_audit.json'
    add('gate_pilot', load(pilot).get('status') == 'pass_gate_flow_pilot' and audit.exists(),
        audit)
    mapped = PROJECT / 'asic/dc/work/synth/tt/diffusion_runtime_d/attention_accel_top'
    add('f0_ppa', all((mapped / 'reports' / file).exists() for file in
                     ('area.rpt', 'qor.rpt', 'timing_status.rpt', 'run_config.rpt')),
        mapped / 'reports')
    smoke = F2 / 'paper_test/f2_validation/results'
    cases = ['d64_q3_kv5_h2', 'd72_q33_kv65_h2', 'd128_q31_kv32_h2', 'd72_q32_kv32_h1']
    good = True
    for case in cases:
        output = smoke / (case + '.csv.observed.bin')
        expected = RUN / 'replay_smoke' / case / 'o.bin'
        path = smoke / (case + '.csv')
        if not all(file.exists() for file in (output, expected, path)):
            good = False
            continue
        with path.open() as handle:
            row = next(csv.DictReader(handle))
        good = good and row.get('status') == 'pass' and (
            hashlib.sha256(output.read_bytes()).digest() ==
            hashlib.sha256(expected.read_bytes()).digest())
    add('f2_function', good, smoke)
    synth = F2 / 'asic/dc/work/synth/tt/evaluation_f2/attention_accel_top'
    timing = synth / 'reports/timing_status.rpt'
    good = ((synth / 'results/attention_accel_top.ddc').exists() and timing.exists() and
            'setup_violating_paths=0' in timing.read_text())
    add('f2_ppa', good, synth, '综合运行中或待检查')
    for n in (1024, 4096):
        for model, count in [('pixart', 28), ('wan', 30)]:
            suffix = '' if n == 1024 else f'_n{n}'
            path = RUN / 'results' / f'layerstep_{model}{suffix}.json'
            report = load(path)
            done = report.get('status') == 'pass_all_layers' and report.get('layers') == count
            complete = sum(load(folder / 'status.json').get('state') == 'pass'
                           for folder in (RUN / 'jobs').glob(f'{model}_n{n}_l*_s15'))
            add(model + '_layerstep' + suffix + '_rtl', done, path,
                f'已核验{complete}/{count}层；逐层回放运行中或排队')
    for key, entry in manual.items():
        if key in ('power_seed302', 'power_seed303', 'traffic_counters'):
            continue
        if entry.get('done') is True:
            assert entry.get('evidence'), 'Checked manual item needs evidence: ' + key
        items[key] = entry

    groups = []

    def group(title, rows):
        groups.append('### ' + title + '\n')
        for key, label in rows:
            entry = items.get(key, {})
            if entry.get('cancelled'):
                status = entry.get('status', 'cancelled by user')
                groups.append(f'- 已取消：{label}；{status}。 <!-- task:{key} -->')
                continue
            mark = 'x' if entry.get('done') else ' '
            status = entry.get('status', '待启动')
            groups.append(f'- [{mark}] {label}；{status}。 <!-- task:{key} -->')
        groups.append('')

    group('A. 数据与测试流程', [
        ('pixart_capture', 'PixArt 五个原生 N 的真实轨迹 Q/K/V'),
        ('wan_capture', 'Wan 五个原生 N 的真实轨迹 Q/K/V'),
        ('pixart_calibration', 'PixArt 独立校准与冻结 scale'),
        ('wan_calibration', 'Wan 独立校准与冻结 scale'),
        ('pixart_power_calibration', 'PixArt N256/H1 功耗微基准独立切片校准'),
        ('wan_power_calibration', 'Wan N256/H1 功耗微基准独立切片校准'),
        ('gate_pilot', 'N32 门级测试台、SAIF 窗口和功耗回读流程核验'),
    ])
    for model, title in [('pixart', 'PixArt-Sigma：H=16，d=72'),
                         ('wan', 'Wan2.1：H=12，d=128')]:
        group('B. 主图 — ' + title, [
            (f'{model}_{kind}_{n}', f'N={n:,}：{label}')
            for n in (1024, 2304, 4096, 9216, 16384)
            for kind, label in [('golden', '完整整数参考与误差诊断'),
                                ('gpu', 'GPU 完整多头 SDPA 正式计时'),
                                ('rtl', 'FLOPA 完整多头 RTL 周期与逐字节核对')]
        ])
    group('C. 主表 — PPA、活动功耗与匹配对照', [
        ('f0_ppa', 'F0 当前映射版本面积、SRAM、时钟与时序报告'),
        ('pixart_power', 'F0 PixArt N256/H1/d72/seed301 门级活动功耗、能量与吞吐'),
        ('wan_power', 'F0 Wan N256/H1/d128/seed301 辅助活动功耗'),
        ('power_seed302', 'd72 主功耗点 seed302：采集、回放与功耗回读'),
        ('power_seed303', 'd72 主功耗点 seed303：采集、回放与功耗回读'),
        ('f2_function', 'F2 关闭 PV/row-state 重叠后的 d64/72/128 与尾 tile 功能检查'),
        ('f2_ppa', 'F2 同库、同 PVT、同目标时钟综合与面积/时序核验'),
        ('f2_power', 'F2 相同 d72/N256 输入的门级功能、SAIF 与活动功耗'),
        ('f2_comparison', 'F0/F2 同条件周期、能量与面积对照汇总'),
        ('f1_design', 'F1 真正 P-buffer-fed PV 的匹配设计与 RTL 实现'),
        ('f1_function', 'F1 与 F0 相同输入、相同整数算术的功能核对'),
        ('f1_ppa', 'F1 同库、同 PVT、同目标时钟综合与面积/时序核验'),
        ('f1_power', 'F1 相同 d72/N256 输入的门级 SAIF 与活动功耗'),
        ('memory_comparison', 'F0/F1 实际 P 读写流量、存储宏/寄存器面积及功耗分量'),
    ])
    group('D. 补充验证与论文交付', [
        ('mcraft_function', 'DFoT-MCRAFT 原生 d64 真实 Q/K/V 功能与兼容性验证'),
        ('mcraft_power', 'MCRAFT N256/H1/d64 辅助活动功耗'),
        ('traffic_counters', '核验 loader、片上 P/O 访问计数与论文机制结论的对应关系'),
        ('workbook', '结果回填精简 Excel：主图原始数据、主表及对照数据'),
        ('figure', 'Python 绘制两模型 GPU/FLOPA 完整多头能量主图（mJ/次），Times New Roman'),
        ('table', '分别生成本设计PPA表与匹配消融表，数值与已核验结果一致'),
        ('paper', '正文 Callback、结果版本及四页正文/一页参考文献排版核验'),
    ])
    group('E. 指定时间步的全部层SDPA覆盖（N1024，步索引15，条件分支）', [
        (f'{model}_layerstep_{kind}', f'{title}：{label}')
        for model, title in [('pixart', 'PixArt全部28层'), ('wan', 'Wan全部30层')]
        for kind, label in [('capture', '真实Q/K/V采集'),
                            ('golden', '逐层独立校准与完整整数参考'),
                            ('gpu', '驻留SDPA序列的累计GPU计时'),
                            ('rtl', '所有层RTL通过并累加实际周期')]
    ])
    group('F. 正式跨层覆盖（N4096，步索引15，条件分支；N1024仅流程验证）', [
        (f'{model}_layerstep_n4096_{kind}', f'{title}：{label}')
        for model, title in [('pixart', 'PixArt全部28层'), ('wan', 'Wan全部30层')]
        for kind, label in [('capture', '真实Q/K/V采集'),
                            ('golden', '逐层冻结校准与完整整数参考'),
                            ('gpu', '驻留SDPA序列的累计GPU计时'),
                            ('rtl', '所有层RTL通过并累加实际周期')]
    ])
    group('G. 能量主比较（完整多头SDPA，延迟数据保留）', [
        (f'{model}_gpu_energy_{n}', f'{title} N={n:,}：GPU三窗口整卡能量/实际调用数')
        for model, title in [('pixart', 'PixArt'), ('wan', 'Wan')]
        for n in (1024, 2304, 4096, 9216, 16384)
    ] + [
        (f'{model}_native_energy_{n}', f'{title} N={n:,}：ASIC完整多头门级活动能量')
        for model, title in [('pixart', 'PixArt'), ('wan', 'Wan')]
        for n in (1024, 2304, 4096, 9216, 16384)
    ] + [
        ('clock_power_audit', 'ASIC clock-network分组、时钟负载及SAIF映射审查'),
        ('native_energy_method', '原形长N/全head ASIC活动能量方法与可行性核验'),
        ('native_energy', '主图原形完整多头ASIC能量；不由N256/H1功率外推'),
    ])
    group('H. 当前定点精度与配对生成质量', [
        ('accuracy_pixart_lengths', 'PixArt四个N点：完整多头输出MAE/RMSE与冻结算术核对'),
        ('accuracy_wan_lengths', 'Wan四个N点：完整多头输出MAE/RMSE与冻结算术核对'),
        ('accuracy_pixart_layers', 'PixArt N1024/N4096全部28层的元素加权MAE/RMSE'),
        ('accuracy_wan_layers', 'Wan N1024/N4096全部30层的元素加权MAE/RMSE'),
        ('quality_pixart_4pairs', 'PixArt四组30步FP16/定点闭环生成与配对PSNR/SSIM'),
    ])
    done = sum(line.startswith('- [x]') for line in groups)
    count = sum(line.startswith('- [') for line in groups)
    local_zone = datetime.timezone(datetime.timedelta(hours=8))
    now = datetime.datetime.now(local_zone).isoformat(timespec='seconds')
    body = [BEGIN, f'更新时间：{now}；已核验 **{done}/{count}** 项。', '',
            '勾选只表示本项通过所列检查；运行中、排队、失败及待复测均保持空框。', '',
            *groups, END]
    readme = PAPER / 'README.md'
    text = readme.read_text()
    assert text.count(BEGIN) == 1 and text.count(END) == 1
    text = re.sub(re.escape(BEGIN) + r'.*?' + re.escape(END),
                  lambda match: '\n'.join(body), text, flags=re.S)
    temporary = readme.with_suffix('.checklist.tmp')
    temporary.write_text(text, encoding='utf-8')
    temporary.replace(readme)
    write_path = RUN / 'checklist_state.json'
    write_path.write_text(json.dumps({'updated': now, 'completed': done, 'total': count,
                                     'items': items}, ensure_ascii=False, indent=4) + '\n',
                          encoding='utf-8')
    print(json.dumps({'checked': done, 'total': count, 'readme': str(readme)}))


if __name__ == '__main__':
    main()
