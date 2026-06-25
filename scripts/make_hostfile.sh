#!/usr/bin/env bash
# Build an OpenMPI hostfile by probing each node's core count over SSH.
#
# Node-count agnostic: pass any number of hosts; adding the 3rd (or 4th) machine
# later is just another argument. The FIRST host becomes rank 0 — the master
# that launches mpirun and holds the dataset (rank 0 reads it and Scatterv's the
# rows, so the data file only needs to live on the master).
#
# Usage:
#   scripts/make_hostfile.sh node0 node1 node2 [node3 ...]
#   NODE_USER=mpi scripts/make_hostfile.sh 192.168.1.50 192.168.1.51 192.168.1.52
#   SLOTS=4 scripts/make_hostfile.sh node0 node1 node2   # force slots, skip nproc probe
#   OUT=hosts.txt scripts/make_hostfile.sh node0 node1 node2
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ $# -ge 1 ]] || { echo "usage: $0 <host1> [host2 ...]" >&2; exit 1; }

OUT="${OUT:-hostfile}"
NODE_USER="${NODE_USER:+${NODE_USER}@}"   # optional user@ prefix for SSH

: > "$OUT.tmp"
total=0
for host in "$@"; do
    if [[ -n "${SLOTS:-}" ]]; then
        slots="$SLOTS"
    else
        slots="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${NODE_USER}${host}" nproc 2>/dev/null || true)"
        [[ "$slots" =~ ^[0-9]+$ ]] || {
            echo "[hostfile] FAIL: could not read nproc on '$host' over SSH." >&2
            echo "           Check passwordless SSH (ssh ${NODE_USER}${host} hostname)." >&2
            rm -f "$OUT.tmp"; exit 1; }
    fi
    echo "$host slots=$slots" >> "$OUT.tmp"
    total=$(( total + slots ))
    printf "[hostfile] %-22s slots=%s\n" "$host" "$slots"
done
mv "$OUT.tmp" "$OUT"
echo "[hostfile] wrote $OUT  (total slots = $total; first host = rank 0 / master)"
