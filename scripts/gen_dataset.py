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
    python3 gen_dataset.py --M 200000 --dim 16 --K 8 --out data/train.bin
    python3 gen_dataset.py --M 200000 --dim 16 --K 8 --seed 42 --spread 1.5 \
            --out data/train.bin

The blobs are well separated by default (spread 1.0) so K-means converges to a
clear solution, which makes the correctness assertion meaningful.
"""
import argparse
import struct
import sys

import numpy as np


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

    rng = np.random.default_rng(args.seed)

    # True cluster centers, well spread across the box.
    centers = rng.uniform(-args.box, args.box, size=(args.K, args.dim))

    # Assign each point to a cluster as evenly as possible, then shuffle so the
    # rows are not pre-sorted by cluster (a sorted layout would make the 1D
    # block decomposition trivially load-balanced in a misleading way).
    labels = np.tile(np.arange(args.K), args.M // args.K + 1)[: args.M]
    rng.shuffle(labels)

    data = centers[labels] + rng.normal(0.0, args.spread, size=(args.M, args.dim))
    data = data.astype("<f8")            # little-endian float64
    labels = labels.astype("<i4")        # little-endian int32

    with open(args.out, "wb") as f:
        f.write(struct.pack("<3i", args.M, args.dim, args.K))
        f.write(data.tobytes())
        f.write(labels.tobytes())

    mb = (12 + data.nbytes + labels.nbytes) / 1e6
    print(f"wrote {args.out}: M={args.M} dim={args.dim} K={args.K} "
          f"({mb:.1f} MB, seed={args.seed}, spread={args.spread})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
