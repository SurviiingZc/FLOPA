"""Capture true sampling-trajectory SDPA inputs without changing model arithmetic."""

import argparse
import contextlib
import hashlib
import json
import os
import platform
import subprocess
import time
from pathlib import Path

import torch


MODELS = {
    'pixart': {
        'root': '/10T/zhangcheng/DiT_models/pixart_sigma_xl_2_1024_ms',
        'heads': 16, 'dim': 72, 'layers': [0, 14, 27],
        'main_prompt': 'A small cactus with a happy face in the Sahara desert.',
        'calibration': ['A wooden cabin beside a lake at sunrise.',
                        'A yellow train in a green valley.'],
        'pixels': [512, 768, 1024, 1536, 2048], 'guidance': 4.5,
    },
    'wan': {
        'root': '/10T/zhangcheng/DiT_models/wan2_1_t2v_1_3b_diffusers',
        'heads': 12, 'dim': 128, 'layers': [0, 15, 29],
        'main_prompt': 'A red toy car moves slowly along a road in a sunlit park.',
        'calibration': ['A blue boat crosses a quiet lake.',
                        'A dog runs across a grassy field.'],
        'pixels': [256, 384, 512, 768, 1024], 'guidance': 5.0,
    },
}


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(8 << 20), b''):
            result.update(block)
    return result.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def prepare_embeddings(model_name, output):
    from transformers import AutoTokenizer, T5EncoderModel, T5Tokenizer, UMT5EncoderModel
    from diffusers import PixArtSigmaPipeline, WanPipeline

    config = MODELS[model_name]
    root = config['root']
    target = output / model_name / 'embeddings.pt'
    if target.exists():
        print('EMBEDDINGS_EXIST', str(target), sha(target), flush=True)
        return
    torch.set_num_threads(8)
    if model_name == 'pixart':
        tokenizer = T5Tokenizer.from_pretrained(root, subfolder='tokenizer',
                                               local_files_only=True)
        encoder = T5EncoderModel.from_pretrained(
            root, subfolder='text_encoder', torch_dtype=torch.float32,
            local_files_only=True,
        ).eval()
        pipe = PixArtSigmaPipeline(tokenizer, encoder, None, None, None)
    else:
        tokenizer = AutoTokenizer.from_pretrained(root, subfolder='tokenizer',
                                                 local_files_only=True)
        encoder = UMT5EncoderModel.from_pretrained(
            root, subfolder='text_encoder', torch_dtype=torch.float32,
            local_files_only=True,
        ).eval()
        pipe = WanPipeline(tokenizer, encoder, None, None)
    values = {}
    with torch.inference_mode():
        for prompt in [config['main_prompt'], *config['calibration']]:
            if model_name == 'pixart':
                result = pipe.encode_prompt(
                    prompt, device=torch.device('cpu'), clean_caption=False,
                    max_sequence_length=300, do_classifier_free_guidance=True,
                )
            else:
                result = pipe.encode_prompt(
                    prompt, negative_prompt='', device=torch.device('cpu'),
                    dtype=torch.float32, max_sequence_length=512,
                    do_classifier_free_guidance=True,
                )
            values[prompt] = [None if item is None else item.cpu() for item in result]
            print('ENCODED', model_name, prompt, flush=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    torch.save(values, target)
    write_json(target.with_suffix('.json'), {
        'model': model_name, 'encoder_dtype': 'float32', 'device': 'cpu',
        'prompts': list(values), 'sha256': sha(target),
        'source_sha256': sha(__file__),
    })


def wait_for_gpu(output, capture_limit_gib=None):
    """Wait only for this job; never alter other users' processes."""
    visible = os.environ.get('CUDA_VISIBLE_DEVICES', '0')
    assert visible in ('0', '1'), visible
    last_state = None
    for _ in range(48 * 60 * 2):
        raw = subprocess.check_output([
            'nvidia-smi', '-i', visible,
            '--query-gpu=uuid,memory.used,utilization.gpu,memory.total',
            '--format=csv,noheader,nounits',
        ], text=True).strip()
        uuid, memory, utilization, total = [item.strip() for item in raw.split(',')]
        idle = int(memory) < 2048 and int(utilization) <= 5
        shared_ok = (capture_limit_gib is not None and
                     int(total) - int(memory) > (capture_limit_gib + 8) * 1024)
        state = 'available' if idle else 'waiting_for_idle_gpu'
        if shared_ok and not idle:
            state = 'available_for_memory_capped_capture_only'
        if state != last_state:
            write_json(output / 'gpu_queue_state.json', {
                'state': state, 'gpu_uuid': uuid, 'memory_mib': int(memory),
                'utilization_percent': int(utilization), 'unix_time': time.time(),
            })
            print(state, raw, flush=True)
            last_state = state
        if idle or shared_ok:
            time.sleep(3)
            recheck = subprocess.check_output([
                'nvidia-smi', '-i', visible,
                '--query-gpu=memory.used,utilization.gpu,memory.total',
                '--format=csv,noheader,nounits',
            ], text=True).strip().split(',')
            idle_recheck = int(recheck[0]) < 2048 and int(recheck[1]) <= 5
            shared_recheck = (capture_limit_gib is not None and
                             int(recheck[2]) - int(recheck[0]) >
                             (capture_limit_gib + 8) * 1024)
            if idle_recheck or shared_recheck:
                return uuid
        time.sleep(30)
    raise RuntimeError('GPU not available within the 48-hour queue limit')


class Recorder:
    def __init__(self, model_name, transformer, task, destination):
        self.model_name = model_name
        self.config = MODELS[model_name]
        self.transformer = transformer
        self.task = task
        self.destination = destination
        self.current_layer = None
        self.current_step = -1
        self.current_branch = None
        self.current_timestep = None
        self.handles = []
        self.stats = {}
        self.saved = []
        self.forward_count = 0

    def transformer_pre(self, module, args, kwargs):
        count = self.forward_count
        self.current_step = count if self.model_name == 'pixart' else count // 2
        self.current_branch = ('combined_cfg' if self.model_name == 'pixart'
                               else ('cond' if count % 2 == 0 else 'uncond'))
        self.current_timestep = float(kwargs['timestep'].flatten()[0].item())
        self.forward_count += 1

    def module_pre(self, layer):
        def hook(module, args):
            assert self.current_layer is None
            self.current_layer = layer
        return hook

    def module_post(self, module, args, result):
        self.current_layer = None

    def process(self, q, k, v, answer, layout):
        if self.current_layer is None or self.current_branch == 'uncond':
            return
        if layout == 'BNHD':
            q, k, v, answer = [x.transpose(1, 2) for x in (q, k, v, answer)]
        # PixArt concatenates unconditioned then conditioned CFG branches.
        q, k, v, answer = [x[-1:].detach() for x in (q, k, v, answer)]
        expected_n = (self.task['pixels'] // 16) ** 2
        if self.model_name == 'wan':
            expected_n *= 4
        assert q.shape == (1, self.config['heads'], expected_n, self.config['dim'])
        tensors = {'q': q, 'k': k, 'v': v, 'o': answer}
        if self.task['role'] == 'calibration':
            layer = str(self.current_layer)
            record = self.stats.setdefault(layer, {'calls': 0})
            record['calls'] += 1
            for name, value in tensors.items():
                if not torch.isfinite(value).all().item():
                    raise RuntimeError(f'nonfinite {name} at layer {layer}')
                record[name + '_maxabs'] = max(record.get(name + '_maxabs', 0),
                                               float(value.abs().max().item()))
            return
        wanted = (self.current_step == 15 and
                  self.current_layer == self.config['layers'][1])
        if self.task.get('qualification', False):
            wanted |= (self.current_step in (0, 15, 29) and
                       self.current_layer in self.config['layers'])
        if not wanted:
            return
        name = f'l{self.current_layer:02d}_s{self.current_step:02d}.pt'
        metadata = {
            **self.task, 'model': self.model_name, 'shape': list(q.shape),
            'layer': self.current_layer, 'step': self.current_step,
            'timestep': self.current_timestep, 'branch': 'conditional',
            'capture': 'after QK norm/RoPE, immediately at SDPA boundary',
            'layout': 'BHND', 'mask': None, 'causal': False,
            'raw_frames': 13 if self.model_name == 'wan' else None,
        }
        payload = {key: value.cpu().contiguous() for key, value in tensors.items()}
        payload['metadata'] = metadata
        torch.save(payload, self.destination / name)
        digest = sha(self.destination / name)
        write_json(self.destination / name.replace('.pt', '.json'),
                   {**metadata, 'sha256': digest})
        self.saved.append({'file': name, 'sha256': digest})
        print('CAPTURED', self.model_name, expected_n, name, flush=True)

    @contextlib.contextmanager
    def install(self):
        import torch.nn.functional as functional
        import diffusers.models.transformers.transformer_wan as wan_module

        self.handles.append(self.transformer.register_forward_pre_hook(
            self.transformer_pre, with_kwargs=True))
        blocks = self.transformer.transformer_blocks
        for index, block in enumerate(blocks):
            attention = block.attn1
            self.handles.append(attention.register_forward_pre_hook(self.module_pre(index)))
            self.handles.append(attention.register_forward_hook(self.module_post))
        original_sdpa = functional.scaled_dot_product_attention
        original_wan = wan_module.dispatch_attention_fn

        def sdpa(q, k, v, *args, **kwargs):
            result = original_sdpa(q, k, v, *args, **kwargs)
            if self.model_name == 'pixart':
                self.process(q, k, v, result, 'BHND')
            return result

        def dispatch(q, k, v, *args, **kwargs):
            result = original_wan(q, k, v, *args, **kwargs)
            if self.model_name == 'wan':
                self.process(q, k, v, result, 'BNHD')
            return result

        functional.scaled_dot_product_attention = sdpa
        wan_module.dispatch_attention_fn = dispatch
        try:
            yield self
        finally:
            functional.scaled_dot_product_attention = original_sdpa
            wan_module.dispatch_attention_fn = original_wan
            for handle in self.handles:
                handle.remove()


def load_pipeline(model_name):
    from diffusers import DPMSolverMultistepScheduler, PixArtSigmaPipeline
    from diffusers import PixArtTransformer2DModel, WanPipeline, WanTransformer3DModel
    from diffusers import UniPCMultistepScheduler

    config = MODELS[model_name]
    root = config['root']
    if model_name == 'pixart':
        model = PixArtTransformer2DModel.from_pretrained(
            root, subfolder='transformer', torch_dtype=torch.float16,
            local_files_only=True,
        ).eval().cuda()
        scheduler = DPMSolverMultistepScheduler.from_pretrained(
            root, subfolder='scheduler', local_files_only=True,
        )
        pipe = PixArtSigmaPipeline(None, None, None, model, scheduler)
    else:
        model = WanTransformer3DModel.from_pretrained(
            root, subfolder='transformer', torch_dtype=torch.float16,
            local_files_only=True,
        ).eval().cuda()
        scheduler = UniPCMultistepScheduler.from_pretrained(
            root, subfolder='scheduler', local_files_only=True,
        )
        assert abs(float(scheduler.config.flow_shift) - 3.0) < 1e-6
        pipe = WanPipeline(None, None, None, scheduler, transformer=model)
    pipe.set_progress_bar_config(disable=True)
    return pipe, model


def tasks(config):
    # First obtain independent calibration and performance pilot at the short N.
    for pixels in (config['pixels'][0], config['pixels'][-1]):
        for index, seed in enumerate((1001, 1002)):
            yield {'role': 'calibration', 'pixels': pixels, 'seed': seed,
                   'prompt': config['calibration'][index]}
        if pixels == config['pixels'][0]:
            yield {'role': 'evaluation', 'pixels': pixels, 'seed': 301,
                   'prompt': config['main_prompt'], 'qualification': True}
    for pixels in config['pixels'][1:]:
        yield {'role': 'evaluation', 'pixels': pixels, 'seed': 301,
               'prompt': config['main_prompt'],
               'qualification': pixels == config['pixels'][-1]}
    for pixels in (config['pixels'][0], config['pixels'][-1]):
        for seed in (302, 303):
            yield {'role': 'evaluation', 'pixels': pixels, 'seed': seed,
                   'prompt': config['main_prompt'], 'qualification': True}


def capture(model_name, output, allow_shared_capture=False):
    config = MODELS[model_name]
    limit_gib = 8 if allow_shared_capture else None
    uuid = wait_for_gpu(output, capture_limit_gib=limit_gib)
    torch.set_num_threads(4)
    torch.set_grad_enabled(False)
    torch.backends.cuda.matmul.allow_tf32 = False
    memory_fraction = (8 * (1 << 30) / torch.cuda.get_device_properties(0).total_memory
                       if allow_shared_capture else 0.85)
    torch.cuda.set_per_process_memory_fraction(memory_fraction)
    pipe, model = load_pipeline(model_name)
    embeddings = torch.load(output / model_name / 'embeddings.pt',
                            map_location='cpu', weights_only=True)
    root = Path(config['root'])
    weights = {str(path.relative_to(root)): sha(path)
               for path in sorted((root / 'transformer').glob('*.safetensors'))}
    protocol = {
        'model': model_name, 'torch': torch.__version__, 'cuda': torch.version.cuda,
        'gpu_uuid': uuid, 'gpu': torch.cuda.get_device_name(), 'platform': platform.platform(),
        'script_sha256': sha(__file__), 'weights_sha256': weights,
        'embeddings_sha256': sha(output / model_name / 'embeddings.pt'),
        'transformer_config': dict(model.config), 'scheduler_config': dict(pipe.scheduler.config),
        'steps': 30, 'guidance_scale': config['guidance'], 'output': 'latent; no VAE decode',
        'precision': 'FP16 model; original pipeline scheduler arithmetic',
        'source': 'real 30-step conditioned denoising trajectory',
        'shared_gpu_capture_allowed': allow_shared_capture,
        'allocator_limit_gib': limit_gib,
        'capture_wall_time_is_not_a_latency_measurement': True,
    }
    write_json(output / model_name / 'protocol.json', protocol)
    for task in tasks(config):
        if (output / model_name / 'numerical_gate_failed.json').exists():
            print('STOPPED_AFTER_NUMERICAL_GATE_FAILURE', model_name, flush=True)
            return
        folder = output / model_name / (
            f"{task['role']}_p{task['pixels']}_seed{task['seed']}")
        if (folder / 'complete.json').exists():
            print('SKIP_COMPLETE', str(folder), flush=True)
            continue
        folder.mkdir(parents=True, exist_ok=True)
        values = [None if x is None else x.to(device='cuda', dtype=torch.float16)
                  for x in embeddings[task['prompt']]]
        negative_index = 2 if model_name == 'pixart' else 1
        arguments = {
            'negative_prompt': None,
            'prompt_embeds': values[0], 'negative_prompt_embeds': values[negative_index],
            'height': task['pixels'], 'width': task['pixels'],
            'num_inference_steps': 30, 'guidance_scale': config['guidance'],
            'generator': torch.Generator(device='cuda').manual_seed(task['seed']),
            'output_type': 'latent',
        }
        if model_name == 'pixart':
            arguments.update(prompt_attention_mask=values[1],
                             negative_prompt_attention_mask=values[3],
                             use_resolution_binning=False, clean_caption=False)
        else:
            arguments.update(num_frames=13, max_sequence_length=512)
        write_json(output / model_name / 'active_task.json', task)
        started = time.time()
        print('TASK_START', model_name, task, flush=True)
        with torch.inference_mode(), Recorder(model_name, model, task, folder).install() as rec:
            result = pipe(**arguments)
            latent = result.images if model_name == 'pixart' else result.frames
            assert torch.isfinite(latent).all().item(), 'Nonfinite sampled latent'
        assert rec.forward_count == (30 if model_name == 'pixart' else 60)
        if task['role'] == 'calibration':
            assert len(rec.stats) == (28 if model_name == 'pixart' else 30)
            assert all(x['calls'] == 30 for x in rec.stats.values())
        else:
            assert len(rec.saved) == (9 if task.get('qualification') else 1)
        timesteps = pipe.scheduler.timesteps.detach().cpu().tolist()
        write_json(folder / 'complete.json', {
            **task, 'status': 'passed_capture', 'forward_calls': rec.forward_count,
            'stats': rec.stats, 'vectors': rec.saved, 'timesteps': timesteps,
            'wall_seconds': time.time() - started,
            'sampled_latent_shape': list(latent.shape),
            'latent_maxabs': float(latent.abs().max().item()),
            'protocol_sha256': sha(output / model_name / 'protocol.json'),
        })
        print('TASK_COMPLETE', str(folder), time.time() - started, flush=True)
        del result, latent
        torch.cuda.empty_cache()
    write_json(output / model_name / 'capture_complete.json', {'status': 'passed_capture'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', choices=list(MODELS), required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--embeddings-only', action='store_true')
    parser.add_argument('--allow-shared-capture', action='store_true')
    args = parser.parse_args()
    if args.embeddings_only:
        prepare_embeddings(args.model, args.output)
    else:
        capture(args.model, args.output, args.allow_shared_capture)
