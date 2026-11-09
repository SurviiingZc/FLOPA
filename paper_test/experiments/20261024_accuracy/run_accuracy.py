"""Recompute activation errors using the frozen arithmetic and captured Q/K/V."""

import argparse
import csv
import hashlib
import json
import os
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as functional

from rtl_shadow_torch import shadow_attention


LENGTHS = (1024, 2304, 4096, 9216)
STAGES = ("total_error", "input_quantization_error", "fixed_point_error")


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


def quantify(answer, reference):
    first = np.asarray(answer, dtype=np.float64).reshape(-1)
    second = np.asarray(reference, dtype=np.float64).reshape(-1)
    assert first.shape == second.shape
    finite = np.isfinite(first) & np.isfinite(second)
    if not finite.all():
        raise ValueError("Nonfinite activation values are not silently excluded")
    delta = first - second
    squared = float(np.dot(delta, delta))
    absolute = float(np.abs(delta).sum())
    reference_squared = float(np.dot(second, second))
    return {
        "count": int(delta.size),
        "sum_absolute_error": absolute,
        "sum_squared_error": squared,
        "reference_sum_squared": reference_squared,
        "mae": absolute / delta.size,
        "rmse": float(np.sqrt(squared / delta.size)),
        "relative_l2": float(np.sqrt(squared / max(reference_squared, 1e-30))),
        "nonfinite_count": 0,
    }


def aggregate(rows):
    result = {"vectors": len(rows), "all_queries_and_heads": True}
    for stage in STAGES:
        count = sum(row[stage]["count"] for row in rows)
        absolute = sum(row[stage]["sum_absolute_error"] for row in rows)
        squared = sum(row[stage]["sum_squared_error"] for row in rows)
        reference_squared = sum(row[stage]["reference_sum_squared"] for row in rows)
        result[stage] = {
            "count": count, "mae": absolute / count,
            "rmse": float(np.sqrt(squared / count)),
            "relative_l2": float(np.sqrt(squared / max(reference_squared, 1e-30))),
        }
    result["bit_exact_vectors"] = sum(row["shadow_matches_frozen_o_bin"] for row in rows)
    result["input_clipping"] = {
        name: sum(row["input_clipping"][name] for row in rows)
        for name in ("q", "k", "v")
    }
    result["worst_head_relative_l2"] = max(
        head["total_error"]["relative_l2"] for row in rows for head in row["per_head"]
    )
    return result


def select_reports(root):
    selected = []
    for path in sorted((root / "qualification").glob("*/*/*/full/qualification.json")):
        report = json.loads(path.read_text())
        metadata = report["metadata"]
        if metadata["model"] not in ("pixart", "wan"):
            continue
        n = int(report["heads"][0]["integer"]["query_rows"])
        role = metadata["role"]
        if role == "evaluation" and n in LENGTHS and metadata["step"] == 15:
            selected.append(("main", path, report))
        elif role == "layerstep" and n in (1024, 4096):
            selected.append(("all_layers", path, report))
    return selected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--query-chunk", type=int, default=512)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    reports_folder = args.output / "vectors"
    reports_folder.mkdir(exist_ok=True)
    torch.set_num_threads(8)
    torch.set_grad_enabled(False)
    if torch.cuda.is_available():
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.allow_tf32 = False
    module_path = Path(__file__).with_name("rtl_shadow_torch.py")
    source_hash = digest(module_path)
    selected = select_reports(args.capture_root)
    assert len(selected) == 124, "Expected eight main points and 116 layer vectors"
    results = []
    started = time.time()
    write_json(args.output / "accuracy_status.json", {
        "state": "running", "pid": os.getpid(), "total": len(selected),
        "completed": 0, "software_sha256": source_hash, "started_unix": started,
    })
    for group, report_path, previous in selected:
        metadata = previous["metadata"]
        model = metadata["model"]
        vector_folder = report_path.parents[2].name
        vector_stem = report_path.parent.parent.name
        vector_path = args.capture_root / model / vector_folder / (vector_stem + ".pt")
        key = model + "_" + vector_folder + "_" + vector_stem
        output_path = reports_folder / (key + ".json")
        if output_path.exists():
            row = json.loads(output_path.read_text())
            assert row["software_sha256"] == source_hash
            assert row["source_sha256"] == digest(vector_path)
            results.append(row)
            continue
        assert digest(vector_path) == previous["vector_sha256"]
        frozen_path = args.capture_root / model / "frozen_scales.json"
        assert digest(frozen_path) == previous["calibration_sha256"]
        frozen = json.loads(frozen_path.read_text())
        config = frozen["scales"][str(metadata["layer"])]
        assert config == previous["scales"]
        payload = torch.load(vector_path, map_location="cpu", weights_only=True)
        inputs = {}
        clipped = {}
        for name in ("q", "k", "v"):
            raw = payload[name].float() / config[name]
            rounded = torch.sign(raw) * torch.floor(torch.abs(raw) + 0.5)
            clipped[name] = int((rounded.abs() > 127).sum())
            inputs[name] = rounded.clamp(-127, 127).to(torch.int8)
            old_path = report_path.parent / (name + ".bin")
            assert hashlib.sha256(inputs[name].numpy().tobytes()).hexdigest() == digest(old_path)
        code, statistics = shadow_attention(
            *(inputs[name].to(args.device) for name in ("q", "k", "v")),
            config["score"]["register"], config["out"]["register"],
            query_chunk_size=args.query_chunk,
        )
        codes = code.cpu().numpy()
        reference_codes_path = report_path.parent / "o.bin"
        code_sha = hashlib.sha256(codes.tobytes()).hexdigest()
        matches = code_sha == digest(reference_codes_path)
        if not matches:
            raise RuntimeError("Torch arithmetic differs from frozen shadow: " + key)
        floating_heads = []
        quantized_heads = []
        for head in range(payload["q"].shape[1]):
            floating = [payload[name][:, head:head + 1].float()
                        for name in ("q", "k", "v")]
            dequantized = [inputs[name][:, head:head + 1].float() * config[name]
                           for name in ("q", "k", "v")]
            floating_heads.append(functional.scaled_dot_product_attention(*floating).numpy())
            quantized_heads.append(functional.scaled_dot_product_attention(*dequantized).numpy())
        reference = np.concatenate(floating_heads, axis=1)
        quantized_reference = np.concatenate(quantized_heads, axis=1)
        actual = codes.astype(np.float32) * config["o"]
        per_head = []
        for head in range(reference.shape[1]):
            per_head.append({
                "head": head,
                "total_error": quantify(actual[:, head], reference[:, head]),
                "input_quantization_error": quantify(
                    quantized_reference[:, head], reference[:, head]),
                "fixed_point_error": quantify(actual[:, head], quantized_reference[:, head]),
            })
        row = {
            "group": group, "model": model, "N": int(reference.shape[2]),
            "heads": int(reference.shape[1]), "d": int(reference.shape[3]),
            "layer": metadata["layer"], "step": metadata["step"],
            "seed": metadata["seed"], "branch": metadata["branch"],
            "source": str(vector_path), "source_sha256": digest(vector_path),
            "calibration_sha256": digest(frozen_path), "software_sha256": source_hash,
            "frozen_shadow_sha256": previous["shadow_sha256"],
            "shadow_matches_frozen_o_bin": matches, "output_sha256": code_sha,
            "input_clipping": clipped, "integer_statistics": statistics,
            "all_query_rows_checked": True, "all_kv_rows_checked": True,
            "total_error": quantify(actual, reference),
            "input_quantization_error": quantify(quantized_reference, reference),
            "fixed_point_error": quantify(actual, quantized_reference),
            "per_head": per_head,
            "reference": "CPU FP32 SDPA on original captured Q/K/V",
            "units": "dequantized model activation units; not integer-code LSBs",
            "torch": torch.__version__, "numpy": np.__version__,
        }
        write_json(output_path, row)
        results.append(row)
        write_json(args.output / "accuracy_status.json", {
            "state": "running", "pid": os.getpid(), "total": len(selected),
            "completed": len(results), "last": key, "started_unix": started,
        })
        print("ACCURACY", key, row["total_error"], flush=True)
    summary = {"state": "complete", "vectors": len(results), "groups": {},
               "software_sha256": source_hash, "elapsed_seconds": time.time() - started,
               "scope": "frozen original arithmetic; no numerical optimization"}
    for model in ("pixart", "wan"):
        for n in LENGTHS:
            rows = [r for r in results if r["group"] == "main"
                    and r["model"] == model and r["N"] == n]
            assert len(rows) == 1
            summary["groups"]["{}_main_n{}".format(model, n)] = aggregate(rows)
        for n in (1024, 4096):
            rows = [r for r in results if r["group"] == "all_layers"
                    and r["model"] == model and r["N"] == n]
            assert len(rows) == (28 if model == "pixart" else 30)
            summary["groups"]["{}_all_layers_n{}".format(model, n)] = aggregate(rows)
    write_json(args.output / "accuracy_summary.json", summary)
    with (args.output / "accuracy_summary.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["group", "vectors", "elements", "MAE", "RMSE", "relative_L2",
                         "input_quantization_MAE", "input_quantization_RMSE",
                         "fixed_point_MAE", "fixed_point_RMSE"])
        for name, values in summary["groups"].items():
            writer.writerow([
                name, values["vectors"], values["total_error"]["count"],
                values["total_error"]["mae"], values["total_error"]["rmse"],
                values["total_error"]["relative_l2"],
                values["input_quantization_error"]["mae"],
                values["input_quantization_error"]["rmse"],
                values["fixed_point_error"]["mae"], values["fixed_point_error"]["rmse"],
            ])
    write_json(args.output / "accuracy_status.json", {
        "state": "complete", "total": len(selected), "completed": len(results),
        "elapsed_seconds": time.time() - started,
    })
    print("ACCURACY_COMPLETE", len(results), flush=True)


if __name__ == "__main__":
    main()
