#!/usr/bin/env python3
"""Draw the implemented FlashAttention tile pipeline at IEEE double-column width."""

from pathlib import Path
import xml.etree.ElementTree as ET

import matplotlib as mpl
from PIL import Image

mpl.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, Polygon, Rectangle


FIG_WIDTH_MM = 183.0
FIG_HEIGHT_MM = 100.0
FIG_W = FIG_WIDTH_MM / 25.4
FIG_H = FIG_HEIGHT_MM / 25.4

INK = "#202124"
MID = "#5F6368"
GRID = "#8A9096"
WHITE = "#FFFFFF"
MEMORY = "#4F6367"
MEMORY_FILL = "#EEF1F2"
QK = "#2455D6"
QK_FILL = "#DCE7FF"
MAX = "#C62828"
MAX_FILL = "#FCE8E6"
STATE = "#743AB2"
STATE_FILL = "#F1E8F8"
EXP = "#147D3F"
EXP_FILL = "#E7F4EA"
PV = "#A66A00"
PV_FILL = "#FFF0CC"


def arrow(ax, x0, y0, x1, y1, color=INK, lw=0.9, mutation=6.0,
          linestyle="-", connection="arc3,rad=0", zorder=9):
    patch = FancyArrowPatch(
        (x0, y0), (x1, y1), arrowstyle="-|>", mutation_scale=mutation,
        linewidth=lw, color=color, linestyle=linestyle,
        connectionstyle=connection, shrinkA=0, shrinkB=0, zorder=zorder,
    )
    ax.add_patch(patch)
    return patch


def poly_arrow(ax, points, color=INK, lw=0.9, mutation=6.0,
               linestyle="-", zorder=9):
    for p0, p1 in zip(points[:-2], points[1:-1]):
        ax.plot([p0[0], p1[0]], [p0[1], p1[1]], color=color,
                linewidth=lw, linestyle=linestyle, zorder=zorder)
    return arrow(ax, *points[-2], *points[-1], color=color, lw=lw,
                 mutation=mutation, linestyle=linestyle, zorder=zorder)


def duration(ax, x0, x1, y, text, color=INK, size=5.1):
    arrow = FancyArrowPatch(
        (x0, y), (x1, y), arrowstyle="<->", mutation_scale=5.5,
        linewidth=0.75, color=color, shrinkA=0, shrinkB=0, zorder=9,
    )
    ax.add_patch(arrow)
    ax.text((x0 + x1) / 2, y + 0.013, text, ha="center", va="bottom",
            fontsize=size, fontweight="bold", color=color, zorder=10)


def stage_bar(ax, y, x0, x1, label, fill, edge, height=0.044,
              lead=0.010, size=5.2, weight="normal", zorder=6):
    points = [
        (x0, y), (x1, y), (x1, y + height),
        (min(x0 + lead, x1), y + height),
    ]
    patch = Polygon(points, closed=True, facecolor=fill, edgecolor=edge,
                    linewidth=0.72, zorder=zorder)
    ax.add_patch(patch)
    ax.text(x0 + 0.008, y + height / 2, label, ha="left", va="center",
            fontsize=size, fontweight=weight, color=INK, zorder=zorder + 1)
    return patch


def row_label(ax, y, text, color=INK, style="italic"):
    ax.text(0.205, y + 0.022, text, ha="right", va="center",
            fontsize=5.5, fontweight="bold" if style == "bold" else "normal",
            fontstyle="italic" if style == "italic" else "normal",
            color=color, zorder=10)


def boundary(ax, x, y0, y1):
    ax.plot([x, x], [y0, y1], color=GRID, linewidth=0.65,
            linestyle=(0, (2.0, 2.4)), zorder=3)


def panel_header(ax, y, label, title):
    ax.text(0.018, y, label, ha="left", va="center", fontsize=7.0,
            fontweight="bold", color=INK)
    ax.text(0.048, y, title, ha="left", va="center", fontsize=6.4,
            fontweight="bold", color=INK)


def draw_qk_softmax(ax):
    panel_header(ax, 0.965, "a", "QK and online-softmax pipeline for one KV tile")
    ax.text(0.018, 0.930, "Dominant cycles:", ha="left", va="center",
            fontsize=5.2, fontstyle="italic", color=INK)
    ax.text(0.982, 0.965,
            "R=C=32, H=64; L_delta=2, L_SE=5+3=8, L_l=2; all pipelines II=1",
            ha="right", va="center", fontsize=5.0, color=MID)

    # Compressed parameterized time axis. Widths encode stage order, not scale.
    xs = [0.220, 0.405, 0.545, 0.602, 0.835, 0.950, 0.982]
    labels = ["H", "R+C-1", "L_SE=8 (alpha)",
              "C+L_delta+L_SE (overlap)", "R+L_l"]
    for idx, text in enumerate(labels):
        duration(ax, xs[idx], xs[idx + 1], 0.925, text)
    for x in xs:
        boundary(ax, x, 0.455, 0.913)

    ys = {
        "load": 0.850,
        "qk": 0.790,
        "max": 0.730,
        "alpha": 0.670,
        "delta": 0.610,
        "prob": 0.550,
        "sum": 0.490,
        "l": 0.430,
    }

    row_label(ax, ys["load"], "Activate Q + K/V")
    stage_bar(ax, ys["load"], 0.220, 0.300, "ping-pong bank", MEMORY_FILL,
              MEMORY, size=5.0)

    row_label(ax, ys["qk"], "S = Q K^T", QK)
    stage_bar(ax, ys["qk"], xs[0], xs[2],
              "H MAC issues + registered R x C wavefront", QK_FILL, QK,
              size=5.2, weight="bold")

    row_label(ax, ys["max"], "block_m = rowmax(S)", MAX)
    stage_bar(ax, ys["max"], xs[1] - 0.042, xs[2],
              "staggered max pass (overlaps QK tail)", MAX_FILL, MAX,
              size=5.0, weight="bold")

    row_label(ax, ys["alpha"], "alpha = exp(old_m - new_m)", STATE)
    stage_bar(ax, ys["alpha"], xs[2], xs[3],
              "parallel alpha exp", STATE_FILL, STATE, size=5.0)

    row_label(ax, ys["delta"], "N = S - new_m", STATE)
    stage_bar(ax, ys["delta"], xs[3], 0.770,
              "reverse m + PE SUB + 2-stage stripe gather", STATE_FILL, STATE,
              size=5.0, weight="bold")

    row_label(ax, ys["prob"], "P = exp2(scale x N)", EXP)
    stage_bar(ax, ys["prob"], 0.635, 0.802,
              "scale L=5 -> PWL L=3 -> tagged prob_q", EXP_FILL, EXP,
              size=5.0, weight="bold")

    row_label(ax, ys["sum"], "local_l = rowsum(P)", EXP)
    stage_bar(ax, ys["sum"], 0.670, xs[4],
              "first P -> reverse rowsum", EXP_FILL, EXP,
              size=5.0, weight="bold")

    row_label(ax, ys["l"], "new_l = old_l x alpha + local_l", EXP)
    stage_bar(ax, ys["l"], xs[4], xs[5],
              "32 issue + 2 drain", EXP_FILL, EXP, size=5.0)

    arrow(ax, xs[4], 0.414, xs[4] + 0.075, 0.414,
          color=PV, lw=1.0, mutation=6.0)
    ax.text(xs[4] + 0.037, 0.417, "PV starts",
            ha="center", va="bottom", fontsize=5.0, fontweight="bold",
            color=PV)

def draw_ws_pv(ax):
    panel_header(ax, 0.380, "b", "Probability-stationary WS-PV with persistent O banks")
    ax.text(0.018, 0.346, "Dominant cycles per KV tile:", ha="left",
            va="center", fontsize=5.2, fontstyle="italic", color=INK)

    x0, xfill, xgroup, xissue, xdrain, xend = 0.220, 0.285, 0.430, 0.610, 0.790, 0.980
    duration(ax, x0, xfill, 0.341, "fill=3", size=5.0)
    duration(ax, xfill, xissue, 0.341, "H=64 issue, II=1")
    duration(ax, xissue, xdrain, 0.341, "C+R-1 drain")
    duration(ax, xdrain, xend, 0.341, "last KV: grouped NORM + WB")
    for x in (x0, xfill, xgroup, xissue, xdrain, xend):
        boundary(ax, x, 0.085, 0.329)

    ax.text((xfill + xgroup) / 2, 0.309, "g0: d=0--31",
            ha="center", va="center", fontsize=5.2, fontweight="bold",
            color=PV)
    ax.text((xgroup + xissue) / 2, 0.309, "g1: features 32--63",
            ha="center", va="center", fontsize=5.2, fontweight="bold",
            color=PV)

    y_p, y_seed, y_v, y_mac, y_out = 0.260, 0.210, 0.160, 0.110, 0.060
    row_label(ax, y_p, "P held in prob_q", STATE, style="bold")
    stage_bar(ax, y_p, x0, xdrain,
              "stationary across all 64 features and array drain", STATE_FILL, STATE,
              size=5.1, weight="bold")

    row_label(ax, y_seed, "persistent O-bank seed", PV)
    stage_bar(ax, y_seed, x0, xissue,
              "sync O read + operand reg + pipe2 rescale: L_seed=3",
              PV_FILL, PV, size=5.0, weight="bold")

    row_label(ax, y_v, "V[:,d] + seed issue", QK)
    stage_bar(ax, y_v, x0, xissue,
              "V cache L=2 + one-cycle seed/tag alignment; 64 d at II=1", QK_FILL, QK,
              size=5.0, weight="bold")

    row_label(ax, y_mac, "sum = seed + P x V", PV)
    stage_bar(ax, y_mac, xfill, xdrain,
              "one continuous WS column wavefront", PV_FILL, PV,
              size=5.0, weight="bold")

    row_label(ax, y_out, "tagged O write / final output", PV)
    stage_bar(ax, y_out, x0 + 0.145, xdrain,
              "right edge writes O_new[row,d] directly to bank[d]", PV_FILL, PV,
              size=5.0, weight="bold")
    stage_bar(ax, y_out, xdrain, xend,
              "8x (32 + L7 + 8-row flush)", STATE_FILL, STATE,
              size=5.0, weight="bold")

    ax.text(0.220, 0.012,
            "No row/group preload: g0/g1 are physical O-bank groups only.  "
            "O rescale and V return fill once, then sustain one feature/cycle.",
            ha="left", va="bottom", fontsize=5.0, color=MID)


def validate_outputs(output_dir):
    stem = output_dir / "flash_attention_pipeline"
    expected_px = (int(FIG_W * 600), int(FIG_H * 600))
    for suffix in (".png", ".tiff"):
        with Image.open(stem.with_suffix(suffix)) as image:
            if image.size != expected_px:
                raise RuntimeError(f"{suffix} size {image.size} != {expected_px}")
            if image.getbbox() is None:
                raise RuntimeError(f"{suffix} render is blank")
    svg_path = stem.with_suffix(".svg")
    svg_text = svg_path.read_text(encoding="utf-8")
    svg_path.write_text("\n".join(line.rstrip() for line in svg_text.splitlines()) + "\n",
                        encoding="utf-8")
    root = ET.parse(svg_path).getroot()
    if not any(element.tag.endswith("text") for element in root.iter()):
        raise RuntimeError("SVG text is not editable")


def render(output_dir):
    mpl.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["Arial", "Helvetica", "Liberation Sans", "DejaVu Sans"],
        "font.size": 5.5,
        "svg.fonttype": "none",
        "pdf.fonttype": 42,
        "pdf.use14corefonts": False,
        "savefig.facecolor": WHITE,
    })
    fig = plt.figure(figsize=(FIG_W, FIG_H), facecolor=WHITE)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    draw_qk_softmax(ax)
    ax.plot([0.018, 0.982], [0.405, 0.405], color=INK, linewidth=0.75)
    draw_ws_pv(ax)

    output_dir.mkdir(parents=True, exist_ok=True)
    stem = output_dir / "flash_attention_pipeline"
    fig.savefig(stem.with_suffix(".svg"))
    fig.savefig(stem.with_suffix(".pdf"))
    fig.savefig(stem.with_suffix(".png"), dpi=600)
    fig.savefig(stem.with_suffix(".tiff"), dpi=600,
                pil_kwargs={"compression": "tiff_lzw"})
    plt.close(fig)
    validate_outputs(output_dir)


if __name__ == "__main__":
    render(Path(__file__).resolve().parent)
