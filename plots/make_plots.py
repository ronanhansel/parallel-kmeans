#!/usr/bin/env python3
"""
Render every figure the report needs from the experiment CSVs in results/.

Figures produced (only those whose source CSV exists):

  results/fig_size_sweep.png   runtime vs input size (with / without comm)
                               -> read off N where wall time is ~120-180 s
  results/fig_granularity.png  per-rank stacked compute+comm bar chart
                               -> visual load-balance check at the baseline N
  results/fig_runtime.png      runtime vs process count (with / without comm)
  results/fig_speedup.png      speedup vs process count, against the ideal line

Usage:
    python3 plots/make_plots.py
    python3 plots/make_plots.py --results-dir results

Each figure is independent; missing CSVs are skipped with a note so you can
generate plots incrementally as experiments finish.
"""
import argparse
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")            # headless: works over SSH on the cluster
import matplotlib.pyplot as plt


def read_csv(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def plot_size_sweep(results_dir):
    path = os.path.join(results_dir, "size_sweep.csv")
    if not os.path.isfile(path):
        return f"skip size_sweep: {path} not found"
    rows = read_csv(path)
    rows = [r for r in rows if r.get("wall_s")]
    rows.sort(key=lambda r: int(r["M"]))
    M = [int(r["M"]) for r in rows]
    wall = [float(r["wall_s"]) for r in rows]
    comm = [float(r["comm_s"]) for r in rows]
    compute = [w - c for w, c in zip(wall, comm)]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(M, wall, "o-", label="total wall time (with comm)")
    ax.plot(M, compute, "s--", label="compute only (without comm)")
    ax.axhspan(120, 180, color="green", alpha=0.12, label="target 2-3 min band")
    ax.set_xlabel("input size M (points)")
    ax.set_ylabel("runtime (s)")
    ax.set_title("Runtime vs input size — choose N inside the 2-3 min band")
    ax.grid(True, alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_size_sweep.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out}"


def plot_granularity(results_dir):
    path = os.path.join(results_dir, "granularity.csv")
    if not os.path.isfile(path):
        return f"skip granularity: {path} not found"
    rows = read_csv(path)
    rows.sort(key=lambda r: int(r["rank"]))
    ranks = [int(r["rank"]) for r in rows]
    compute = [float(r["compute_s"]) for r in rows]
    comm = [float(r["comm_s"]) for r in rows]

    fig, ax = plt.subplots(figsize=(9, 5))
    ax.bar(ranks, compute, label="compute", color="#3b78b0")
    ax.bar(ranks, comm, bottom=compute, label="communication", color="#e08a1e")
    ax.set_xlabel("MPI rank")
    ax.set_ylabel("time (s)")
    ax.set_xticks(ranks)

    lo, hi = min(compute), max(compute)
    spread = (hi - lo) / hi * 100 if hi > 0 else 0.0
    verdict = "balanced (<=25%)" if spread <= 25 else "RETUNE (>25%)"
    ax.set_title(f"Per-rank compute + comm at baseline N "
                 f"(compute spread {spread:.1f}% — {verdict})")
    ax.grid(True, axis="y", alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_granularity.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out} (spread {spread:.1f}%)"


def _load_scaling(results_dir):
    path = os.path.join(results_dir, "scaling.csv")
    if not os.path.isfile(path):
        return None, f"{path} not found"
    rows = read_csv(path)
    rows.sort(key=lambda r: int(r["P"]))
    return rows, None


def plot_runtime(results_dir):
    rows, err = _load_scaling(results_dir)
    if rows is None:
        return f"skip runtime: {err}"
    P = [int(r["P"]) for r in rows]
    wall = [float(r["wall_s"]) for r in rows]
    comm = [float(r["comm_s"]) for r in rows]
    compute = [w - c for w, c in zip(wall, comm)]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(P, wall, "o-", label="total wall time (with comm)")
    ax.plot(P, compute, "s--", label="compute only (without comm)")
    ax.set_xscale("log", base=2)
    ax.set_xticks(P); ax.set_xticklabels([str(p) for p in P])
    ax.set_xlabel("number of processes P")
    ax.set_ylabel("runtime (s)")
    ax.set_title("Runtime vs process count at data scale 2N")
    ax.grid(True, alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_runtime.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out}"


def plot_speedup(results_dir):
    rows, err = _load_scaling(results_dir)
    if rows is None:
        return f"skip speedup: {err}"
    P = [int(r["P"]) for r in rows]
    sw = [float(r["speedup_wall"]) for r in rows]
    sc = [float(r["speedup_compute"]) for r in rows]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(P, P, "k:", label="ideal linear speedup")
    ax.plot(P, sw, "o-", label="measured speedup (with comm)")
    ax.plot(P, sc, "s--", label="measured speedup (compute only)")
    ax.set_xscale("log", base=2); ax.set_yscale("log", base=2)
    ax.set_xticks(P); ax.set_xticklabels([str(p) for p in P])
    ax.set_yticks(P); ax.set_yticklabels([str(p) for p in P])
    ax.set_xlabel("number of processes P")
    ax.set_ylabel("speedup S(P) = T(1) / T(P)")
    ax.set_title("Speedup vs process count at data scale 2N")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_speedup.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out}"


def main():
    ap = argparse.ArgumentParser(description="Render report figures from results CSVs.")
    ap.add_argument("--results-dir", default="results", help="directory holding the CSVs")
    args = ap.parse_args()

    if not os.path.isdir(args.results_dir):
        print(f"error: results dir '{args.results_dir}' does not exist", file=sys.stderr)
        return 1

    for fn in (plot_size_sweep, plot_granularity, plot_runtime, plot_speedup):
        print("[plots]", fn(args.results_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
