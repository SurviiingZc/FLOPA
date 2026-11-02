"""Native 1024-pixel paired generations using the unchanged frozen RTL shadow."""

import argparse
import contextlib
import hashlib
import json
import os
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as functional
from diffusers import AutoencoderKL, DPMSolverMultistepScheduler
from diffusers import PixArtSigmaPipeline, PixArtTransformer2DModel
from PIL import Image
from skimage.metrics import structural_similarity

from rtl_shadow_torch import quantize_half_away, shadow_attention


ROOT = Path("/10T/zhangcheng/flopa_evaluation_20261018")
MODEL = Path("/10T/zhangcheng/DiT_models/pixart_sigma_xl_2_1024_ms")
CASES = (
    ("cactus_s301", "A small cactus with a happy face in the Sahara desert.", 301),
    ("cactus_s302", "A small cactus with a happy face in the Sahara desert.", 302),
    ("cabin_s301", "A wooden cabin beside a lake at sunrise.", 301),
    ("train_s303", "A yellow train in a green valley.", 303),
)


def digest(path):
    answer = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(8 << 20), b""):
            answer.update(block)
    return answer.hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=4) + "\n")
    temporary.replace(path)


class Replacement:
    def __init__(self, transformer, frozen, output, query_chunk):
        self.transformer = transformer
        self.frozen = frozen
        self.output = output
        self.query_chunk = query_chunk
        self.current_layer = None
        self.current_step = -1
        self.forward_count = 0
        self.handles = []
        self.records = []
        self.original = functional.scaled_dot_product_attention

    def begin_step(self, module, args, kwargs):
        self.current_step = self.forward_count
        self.forward_count += 1
        print("QUALITY_STEP", self.current_step, flush=True)

    def enter(self, layer):
        def hook(module, args):
            assert self.current_layer is None
            self.current_layer = layer
        return hook

    def leave(self, module, args, result):
        self.current_layer = None

    def sdpa(self, query, key, value, *args, **kwargs):
        if self.current_layer is None:
            return self.original(query, key, value, *args, **kwargs)
        mask = args[0] if args else kwargs.get("attn_mask")
        dropout = args[1] if len(args) > 1 else kwargs.get("dropout_p", 0.0)
        causal = args[2] if len(args) > 2 else kwargs.get("is_causal", False)
        assert mask is None and not causal and dropout == 0.0
        assert kwargs.get("scale") is None and not kwargs.get("enable_gqa", False)
        assert query.shape == key.shape == value.shape == (2, 16, 4096, 72)
        scale = self.frozen["scales"][str(self.current_layer)]
        quantized = []
        clipping = {}
        for name, tensor in zip(("q", "k", "v"), (query, key, value)):
            codes, count = quantize_half_away(tensor.float(), scale[name])
            quantized.append(codes)
            clipping[name] = count
        codes, stats = shadow_attention(
            *quantized, scale["score"]["register"], scale["out"]["register"],
            query_chunk_size=self.query_chunk,
        )
        result = (codes.float() * scale["o"]).to(query.dtype)
        assert torch.isfinite(result).all()
        self.records.append({
            "layer": self.current_layer, "step": self.current_step,
            "shape": list(query.shape), "input_clipping": clipping,
            "statistics": stats,
        })
        return result

    @contextlib.contextmanager
    def installed(self):
        attentions = [m for name, m in self.transformer.named_modules()
                      if name.endswith(".attn1")]
        assert len(attentions) == 28
        self.handles.append(self.transformer.register_forward_pre_hook(
            self.begin_step, with_kwargs=True))
        for layer, module in enumerate(attentions):
            self.handles.append(module.register_forward_pre_hook(self.enter(layer)))
            self.handles.append(module.register_forward_hook(self.leave))
        functional.scaled_dot_product_attention = self.sdpa
        try:
            yield self
        finally:
            functional.scaled_dot_product_attention = self.original
            for handle in self.handles:
                handle.remove()


def image_metrics(first, second):
    a = np.asarray(first, dtype=np.float64) / 255.0
    b = np.asarray(second, dtype=np.float64) / 255.0
    delta = a - b
    mse = float(np.mean(delta ** 2))
    return {
        "pixel_mae_0_to_1": float(np.mean(np.abs(delta))),
        "pixel_rmse_0_to_1": float(np.sqrt(mse)),
        "psnr_db": float(-10.0 * np.log10(mse)) if mse > 0 else None,
        "ssim": float(structural_similarity(
            a, b, data_range=1.0, channel_axis=-1, gaussian_weights=True,
            sigma=1.5, use_sample_covariance=False,
        )),
        "scope": "paired image fidelity; not dataset FID or text-alignment quality",
    }


def decode(pipe, latents):
    with torch.inference_mode():
        values = latents.float() / pipe.vae.config.scaling_factor
        image = pipe.vae.decode(values, return_dict=False)[0]
        assert torch.isfinite(image).all()
        return pipe.image_processor.postprocess(image, output_type="pil")[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--query-chunk", type=int, default=4096)
    parser.add_argument("--memory-limit-gib", type=float, default=10.0)
    parser.add_argument("--cases", nargs="+", choices=[c[0] for c in CASES], required=True)
    parser.add_argument("--worker", required=True)
    args = parser.parse_args()
    selected_cases = [case for case in CASES if case[0] in args.cases]
    assert len(selected_cases) == len(args.cases), "Repeated case names are not allowed"
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(8)
    torch.set_grad_enabled(False)
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    total = torch.cuda.get_device_properties(0).total_memory
    torch.cuda.set_per_process_memory_fraction(args.memory_limit_gib * (1 << 30) / total)
    frozen_path = ROOT / "pixart/frozen_scales.json"
    frozen = json.loads(frozen_path.read_text())
    embeddings_path = ROOT / "pixart/embeddings.pt"
    embeddings = torch.load(embeddings_path, map_location="cpu", weights_only=True)
    model = PixArtTransformer2DModel.from_pretrained(
        str(MODEL), subfolder="transformer", torch_dtype=torch.float16,
        local_files_only=True,
    ).eval().cuda()
    vae = AutoencoderKL.from_pretrained(
        str(MODEL), subfolder="vae", torch_dtype=torch.float32,
        local_files_only=True,
    ).eval().cuda()
    scheduler = DPMSolverMultistepScheduler.from_pretrained(
        str(MODEL), subfolder="scheduler", local_files_only=True)
    pipe = PixArtSigmaPipeline(None, None, vae, model, scheduler)
    pipe.set_progress_bar_config(disable=True)
    protocol = {
        "state": "running", "pid": os.getpid(), "cases": selected_cases,
        "worker": args.worker, "visible_device": os.environ.get("CUDA_VISIBLE_DEVICES"),
        "model": str(MODEL), "pixels": 1024, "N": 4096, "steps": 30,
        "guidance_scale": 4.5, "branches": "both unconditional and conditional",
        "replaced": "all 28 self-attention layers at all 30 denoising steps",
        "unchanged": "cross-attention, projections, scheduler, VAE and model weights",
        "reference": "original FP16 self-attention",
        "variant": "current frozen INT8/PWL/reciprocal arithmetic; dequantized to FP16",
        "calibration_sha256": digest(frozen_path),
        "embeddings_sha256": digest(embeddings_path),
        "shadow_source_sha256": digest(Path(__file__).with_name("rtl_shadow_torch.py")),
        "script_sha256": digest(__file__), "torch": torch.__version__,
        "gpu": torch.cuda.get_device_name(), "cuda": torch.version.cuda,
        "scheduler": dict(pipe.scheduler.config),
        "sampling": "prespecified subset of four prompt/seed pairs; no exclusions",
        "resolution_reason": "checkpoint-native 1024; forced 512 baseline was invalid",
        "query_chunk": args.query_chunk,
        "per_process_memory_limit_gib": args.memory_limit_gib,
        "unity_bypass": False,
        "calibration_prompts_reused_in_two_cases": True,
        "not_an_independent_dataset_quality_benchmark": True,
    }
    write_json(args.output / "quality_protocol.json", protocol)
    started = time.time()
    completed = []
    for case, prompt, seed in selected_cases:
        destination = args.output / case
        destination.mkdir(exist_ok=True)
        if (destination / "result.json").exists():
            completed.append(json.loads((destination / "result.json").read_text()))
            continue
        values = [None if v is None else v.to(device="cuda", dtype=torch.float16)
                  for v in embeddings[prompt]]
        initial = torch.randn(
            (1, 4, 128, 128), generator=torch.Generator("cpu").manual_seed(seed),
            dtype=torch.float16,
        ).cuda()
        torch.save(initial.cpu(), destination / "initial_latents.pt")
        results = {}
        for variant in ("fp16", "flopa"):
            print("QUALITY_CASE", case, variant, flush=True)
            pipe.scheduler = DPMSolverMultistepScheduler.from_config(protocol["scheduler"])
            arguments = {
                "negative_prompt": None,
                "prompt_embeds": values[0], "prompt_attention_mask": values[1],
                "negative_prompt_embeds": values[2],
                "negative_prompt_attention_mask": values[3],
                "height": 1024, "width": 1024, "num_inference_steps": 30,
                "guidance_scale": 4.5, "latents": initial.clone(),
                "use_resolution_binning": False, "output_type": "latent",
                "generator": torch.Generator("cpu").manual_seed(seed),
            }
            tick = time.time()
            replacement = Replacement(model, frozen, destination, args.query_chunk)
            with torch.inference_mode():
                if variant == "flopa":
                    with replacement.installed():
                        latent = pipe(**arguments).images
                    assert replacement.forward_count == 30
                    assert len(replacement.records) == 28 * 30
                    write_json(destination / "attention_calls.json", replacement.records)
                else:
                    latent = pipe(**arguments).images
            assert torch.isfinite(latent).all()
            torch.save(latent.cpu(), destination / (variant + "_final_latents.pt"))
            image = decode(pipe, latent)
            image.save(destination / (variant + ".png"))
            results[variant] = {
                "latent": latent.float().cpu(), "image": image,
                "wall_seconds_not_performance_measurement": time.time() - tick,
            }
        difference = results["flopa"]["latent"] - results["fp16"]["latent"]
        result = {
            "state": "complete", "case": case, "prompt": prompt, "seed": seed,
            "self_attention_calls_replaced": 840,
            "CFG_branches_replaced": 2, "pixels": 1024, "N": 4096,
            "paired_initial_latents_sha256": digest(destination / "initial_latents.pt"),
            "image_metrics": image_metrics(results["flopa"]["image"],
                                             results["fp16"]["image"]),
            "latent_mae": float(difference.abs().mean()),
            "latent_rmse": float(difference.square().mean().sqrt()),
            "wall_seconds": {v: results[v]["wall_seconds_not_performance_measurement"]
                             for v in results},
            "output_sha256": {v: digest(destination / (v + ".png")) for v in results},
        }
        write_json(destination / "result.json", result)
        completed.append(result)
        write_json(args.output / "quality_status.json", {
            "state": "running", "completed": len(completed), "total": len(selected_cases),
            "last": case, "elapsed_seconds": time.time() - started,
        })
        print("QUALITY_RESULT", case, result["image_metrics"], flush=True)
    summary = {
        "state": "complete", "completed": len(completed), "total": len(selected_cases),
        "cases": completed, "elapsed_seconds": time.time() - started,
        "mean_ssim": float(np.mean([r["image_metrics"]["ssim"] for r in completed])),
        "mean_psnr_db": float(np.mean([r["image_metrics"]["psnr_db"] for r in completed])),
        "scope": "paired image-fidelity diagnostics; not a population quality claim",
    }
    write_json(args.output / "quality_summary.json", summary)
    write_json(args.output / "quality_status.json", {
        "state": "complete", "completed": len(completed), "total": len(selected_cases),
        "elapsed_seconds": time.time() - started,
    })
    print("QUALITY_COMPLETE", flush=True)


if __name__ == "__main__":
    main()
