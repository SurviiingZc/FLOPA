"""Bind short-test executables to a fixed source inventory and characterized SRAM models."""

import hashlib
import json
import shutil
import sys
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def snapshot(root):
    paths = []
    for folder in ("rtl", "tb/uvm"):
        paths.extend(
            path for path in (root / folder).rglob("*")
            if path.suffix in (".v", ".vh", ".sv", ".svh")
        )
    explicit = [
        "fpga/rtl/axis_tile_loader.v",
        "tb/sim/filelists/rtl.f",
        "tb/sim/filelists/uvm.f",
        "tb/sim/filelists/asic_models.f",
        "tb/module_tb/compute/tb_runtime_arithmetic.sv",
        "tb/sim/scripts/run_runtime_d_short.sh",
        "tb/sim/scripts/summarize_runtime_d.py",
        "tb/sim/scripts/runtime_d_manifest.py",
    ]
    paths.extend(root / path for path in explicit)
    files = [
        {"path": path.relative_to(root).as_posix(), "sha256": sha256(path)}
        for path in sorted(set(paths))
    ]
    source_text = "".join(f"{row['path']}\0{row['sha256']}\n" for row in files)
    external = []
    for line in (root / "tb/sim/filelists/asic_models.f").read_text().splitlines():
        line = line.strip()
        if line.startswith("/") and not line.startswith("//"):
            path = Path(line)
            external.append({"path": str(path), "sha256": sha256(path)})
    return {
        "source_sha256": hashlib.sha256(source_text.encode()).hexdigest(),
        "files": files,
        "sram_models": external,
        "vcs_path": shutil.which("vcs"),
    }


def module_report(output):
    log = output / "arithmetic_module.log"
    text = log.read_text(errors="replace")
    checks = {
        "signed_mult_pipe3": "[PASS] signed_mult_pipe3 exact_products=577",
        "online_normalizer": "[PASS] online_normalizer exact_vectors=81 lanes=8",
        "clock_gate": "[PASS] clock_gate idle_high_phase_test_enable",
    }
    failed = "Fatal:" in text or "Error:" in text
    rows = [
        {
            "test": name,
            "pass": marker in text and not failed,
            "log": str(log),
            "log_sha256": sha256(log),
        }
        for name, marker in checks.items()
    ]
    passed = all(row["pass"] for row in rows) and "[PASS] tb_runtime_arithmetic" in text
    report = {"pass": passed, "tests": rows}
    (output / "module_summary.json").write_text(json.dumps(report, indent=4) + "\n")
    return report["pass"]


def main():
    action, root_arg, output_arg = sys.argv[1:4]
    root = Path(root_arg).resolve()
    output = Path(output_arg).resolve()
    current = snapshot(root)
    if action == "before":
        (output / "compile_before.json").write_text(json.dumps(current, indent=4) + "\n")
    elif action == "after":
        before = json.loads((output / "compile_before.json").read_text())
        if before != current:
            raise SystemExit("source/model/tool inventory changed while compilation was running")
        current["compile_before_sha256"] = before["source_sha256"]
        current["compile_after_sha256"] = current["source_sha256"]
        for name in ("simv", "arithmetic_simv", "compile.log", "arithmetic_compile.log"):
            current[name.replace(".", "_") + "_sha256"] = sha256(output / name)
        (output / "compile_manifest.json").write_text(json.dumps(current, indent=4) + "\n")
    elif action == "check":
        saved = json.loads((output / "compile_manifest.json").read_text())
        if any(saved.get(key) != value for key, value in current.items()):
            raise SystemExit("SKIP_COMPILE rejected: source/model/tool inventory differs")
        for name in ("simv", "arithmetic_simv"):
            if saved[name + "_sha256"] != sha256(output / name):
                raise SystemExit(f"SKIP_COMPILE rejected: {name} executable hash differs")
    elif action == "module":
        if not module_report(output):
            raise SystemExit("focused arithmetic/clock module checks failed")
    else:
        raise SystemExit(f"unknown action {action}")


if __name__ == "__main__":
    main()
