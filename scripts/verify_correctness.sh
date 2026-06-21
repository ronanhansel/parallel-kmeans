#!/usr/bin/env bash
# Correctness proof: the parallel program must reproduce the sequential solution.
#
# We run the sequential baseline and the MPI program on the SAME dataset, K,
# iteration cap and epsilon, then compare the final cluster assignment.
#
# K-means cluster IDs are arbitrary labels, so two correct runs can assign the
# same partition under a different numbering. We therefore compare the partition
# up to a relabeling: we check that the mapping seq_label -> par_label is a
# consistent bijection across all points. Because both programs use identical
# deterministic seeding (first K points) and identical update order, the labels
# are in practice bit-identical, but the relabeling check keeps the proof robust.
#
# Usage:
#   scripts/verify_correctness.sh [dataset.bin] [K] [max_iters] [epsilon] [P]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DATA="${1:-data/verify.bin}"
K="${2:-8}"
ITERS="${3:-100}"
EPS="${4:-1e-8}"
P="${5:-4}"

MPIRUN="${MPIRUN:-mpirun}"

mkdir -p data results

if [[ ! -f "$DATA" ]]; then
    echo "[verify] generating small dataset -> $DATA"
    python3 scripts/gen_dataset.py --out "$DATA" --points 20000 --dim 4 --clusters "$K" --seed 1
fi

echo "[verify] building"
make --no-print-directory >/dev/null

echo "[verify] sequential run"
./bin/kmeans_seq "$DATA" "$K" "$ITERS" "$EPS" results/seq_labels.txt results/seq_centroids.txt

echo "[verify] parallel run (P=$P)"
"$MPIRUN" -np "$P" ./bin/kmeans_mpi "$DATA" "$K" "$ITERS" "$EPS" \
    results/par_labels.txt results/par_centroids.txt

echo "[verify] comparing partitions (up to relabeling)"
python3 - "$@" <<'PY'
import sys
seq = [l.strip() for l in open("results/seq_labels.txt")]
par = [l.strip() for l in open("results/par_labels.txt")]
if len(seq) != len(par):
    print(f"FAIL: length mismatch seq={len(seq)} par={len(par)}")
    sys.exit(1)

# Build a consistent relabeling seq->par; fail if it is not a bijection.
fwd, rev = {}, {}
for s, p in zip(seq, par):
    if s in fwd and fwd[s] != p:
        print(f"FAIL: seq label {s} maps to both {fwd[s]} and {p}")
        sys.exit(1)
    if p in rev and rev[p] != s:
        print(f"FAIL: par label {p} maps to both {rev[p]} and {s}")
        sys.exit(1)
    fwd[s] = p
    rev[p] = s

identical = sum(1 for s, p in zip(seq, par) if s == p)
print(f"PASS: {len(seq)} points, partitions identical up to relabeling "
      f"({identical}/{len(seq)} labels bit-identical, "
      f"{len(fwd)} clusters matched)")
PY
echo "[verify] done"
