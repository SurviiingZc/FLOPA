"""All four prespecified paired cases, with identical display transforms.

Conclusion: the frozen fixed-point attention changes paired generation visibly.
Evidence: four full images per method; no case exclusion, crop or color adjustment.
Archetype: image plate. Python, Times New Roman, 183 mm wide, PNG/PDF export.
"""

import json
from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt
from PIL import Image


ROOT = Path(__file__).resolve().parent
mpl.rcParams.update({
    "font.family": "Times New Roman",
    "font.size": 9,
    "pdf.fonttype": 42,
    "svg.fonttype": "none",
})


def main():
    summary = json.loads((ROOT / "quality_native/quality_summary.json").read_text("utf-8"))
    fig, axes = plt.subplots(4, 2, figsize=(7.2047, 12.4409))
    fig.subplots_adjust(left=0.09, right=0.99, top=0.975, bottom=0.02,
                        wspace=0.015, hspace=0.12)
    for row, case in enumerate(summary["cases"]):
        for col, variant in enumerate(("fp16", "flopa")):
            path = ROOT / "quality_native" / case["case"] / f"{variant}.png"
            axes[row, col].imshow(Image.open(path))
            axes[row, col].set_axis_off()
        name = case["case"].split("_")[0].capitalize()
        axes[row, 0].text(
            -0.10, 0.5, f"{name}\nseed {case['seed']}",
            transform=axes[row, 0].transAxes, rotation=90,
            ha="center", va="center", fontsize=10,
        )
        metrics = case["image_metrics"]
        axes[row, 1].text(
            0.5, -0.015,
            f"PSNR {metrics['psnr_db']:.2f} dB     SSIM {metrics['ssim']:.3f}",
            transform=axes[row, 1].transAxes, ha="center", va="top",
        )
    axes[0, 0].set_title("FP16 self-attention", fontsize=12)
    axes[0, 1].set_title("FLOPA fixed-point self-attention", fontsize=12)
    fig.savefig(ROOT / "pixart_quality_native_comparison.png", dpi=300, facecolor="white")
    fig.savefig(ROOT / "pixart_quality_native_comparison.pdf", facecolor="white")
    fig.savefig(ROOT / "pixart_quality_native_comparison.svg", facecolor="white")
    plt.close(fig)


if __name__ == "__main__":
    main()
