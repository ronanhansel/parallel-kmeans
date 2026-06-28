#!/usr/bin/env python3
"""
Generate a synthetic Gaussian-blob dataset for the parallel K-means experiments.

The output is the little-endian binary format consumed by src/common.h:

    int32   M           number of points
    int32   dim         dimensionality
    int32   K           number of ground-truth clusters
    float64 data[M*dim] row-major coordinates
    int32   labels[M]   ground-truth cluster id per point

Coordinates are float64 so the C programs read bit-identical inputs and the
sequential-vs-parallel correctness comparison stays exact.

Usage:
    python3 gen_dataset.py --points 200000 --dim 16 --clusters 8 --out data/train.bin
    python3 gen_dataset.py --M 200000 --dim 16 --K 8 --seed 42 --spread 1.5 \
            --out data/train.bin

The blobs are well separated by default (spread 1.0) so K-means converges to a
clear solution, which makes the correctness assertion meaningful.

numpy is used when available (fast path for the multi-million-point experiment
datasets). If numpy is NOT installed the script transparently falls back to a
pure-stdlib generator so the cluster smoke tests and correctness checks still
run on a bare node — no extra packages required. The fallback is slower, so for
the large experiment sizes installing numpy is recommended
(`sudo apt install -y python3-numpy`).
"""
import argparse
import os
import struct
import sys

try:
    import numpy as np
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False


def _gen_numpy(M, dim, K, seed, spread, box):
    """Fast path: vectorised Gaussian blobs via numpy."""
    rng = np.random.default_rng(seed)
    centers = rng.uniform(-box, box, size=(K, dim))
    # Even cluster sizes, then shuffle so rows are not pre-sorted by cluster
    # (a sorted layout would make the 1D block decomposition trivially balanced
    # in a misleading way).
    labels = np.tile(np.arange(K), M // K + 1)[:M]
    rng.shuffle(labels)
    data = centers[labels] + rng.normal(0.0, spread, size=(M, dim))
    return data.astype("<f8").tobytes(), labels.astype("<i4").tobytes()


def _gen_stdlib(M, dim, K, seed, spread, box):
    """Fallback path: same construction with the standard library only.

    Produces the identical binary layout (different RNG, so different exact
    values than the numpy path, but a statistically equivalent dataset). Used
    when numpy is unavailable so a bare node can still run the smoke/correctness
    checks. Packs into array('d')/array('i') for speed without numpy.
    """
    import random
    from array import array

    rnd = random.Random(seed)
    centers = [[rnd.uniform(-box, box) for _ in range(dim)] for _ in range(K)]

    labels_list = [i % K for i in range(M)]
    rnd.shuffle(labels_list)

    data = array("d", bytes(8 * M * dim))   # zero-filled, then overwrite
    idx = 0
    gauss = rnd.gauss
    for i in range(M):
        c = centers[labels_list[i]]
        for d in range(dim):
            data[idx] = c[d] + gauss(0.0, spread)
            idx += 1

    labels = array("i", labels_list)

    # Force little-endian on big-endian hosts (no-op on x86/ARM little-endian).
    if sys.byteorder != "little":
        data.byteswap()
        labels.byteswap()

    return data.tobytes(), labels.tobytes()


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate Gaussian-blob dataset (binary).")
    # --points/--clusters are the canonical flags used by the run scripts;
    # --M/--K are kept as aliases for convenience on the command line.
    ap.add_argument("--points", "--M", dest="M", type=int, required=True,
                    help="number of points")
    ap.add_argument("--dim", type=int, default=16, help="dimensionality (default 16)")
    ap.add_argument("--clusters", "--K", dest="K", type=int, default=8,
                    help="number of clusters (default 8)")
    ap.add_argument("--seed", type=int, default=42, help="RNG seed (default 42)")
    ap.add_argument("--spread", type=float, default=1.0,
                    help="per-cluster std-dev; smaller = better separated (default 1.0)")
    ap.add_argument("--box", type=float, default=50.0,
                    help="centers are drawn uniformly in [-box, box] per axis")
    ap.add_argument("--out", required=True, help="output path (e.g. data/train.bin)")
    args = ap.parse_args()

    if args.K <= 0 or args.K > args.M:
        print(f"error: need 0 < K <= M (got K={args.K}, M={args.M})", file=sys.stderr)
        return 1

    if HAVE_NUMPY:
        data_bytes, label_bytes = _gen_numpy(
            args.M, args.dim, args.K, args.seed, args.spread, args.box)
        backend = "numpy"
    else:
        # Warn when the slow path meets a large dataset so the user can install
        # numpy instead of waiting (the experiment sizes are millions of points).
        if args.M * args.dim > 2_000_000:
            print(f"[gen] numpy not found; using the pure-Python fallback for "
                  f"M={args.M} dim={args.dim}. This is slow at this size — "
                  f"`sudo apt install -y python3-numpy` for the fast path.",
                  file=sys.stderr)
        data_bytes, label_bytes = _gen_stdlib(
            args.M, args.dim, args.K, args.seed, args.spread, args.box)
        backend = "stdlib"

    # Create the output directory if it doesn't exist yet. On a freshly synced
    # worker (or any node where the demo runs before data/ is created), the
    # parent dir may be absent — make it rather than crashing with ENOENT.
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.out, "wb") as f:
        f.write(struct.pack("<3i", args.M, args.dim, args.K))
        f.write(data_bytes)
        f.write(label_bytes)

    mb = (12 + len(data_bytes) + len(label_bytes)) / 1e6
    print(f"wrote {args.out}: M={args.M} dim={args.dim} K={args.K} "
          f"({mb:.1f} MB, seed={args.seed}, spread={args.spread}, backend={backend})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
