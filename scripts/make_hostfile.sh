#!/usr/bin/env bash
# Build an OpenMPI hostfile by probing each node's core count.
#
# Node-count agnostic: pass any number of hosts; adding the 3rd (or 4th) machine
# later is just another argument. The FIRST host becomes rank 0 — the master,
# which is wherever this script runs. mpirun launches the master's rank by fork
# (not SSH) and rank 0 reads the dataset and Scatterv's the rows, so the data
# file only needs to live on the master.
#
# The master is probed LOCALLY; only the other nodes are probed over SSH. So the
# master never needs passwordless SSH to itself.
#
# Usage:
#   scripts/make_hostfile.sh node0 node1 node2 [node3 ...]
#   NODE_USER=mpi scripts/make_hostfile.sh 192.168.1.50 192.168.1.51 192.168.1.52
#   SLOTS=4 scripts/make_hostfile.sh node0 node1 node2   # force slots, skip nproc probe
#   OUT=hosts.txt scripts/make_hostfile.sh node0 node1 node2
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/_cluster_lib.sh
source "$ROOT/scripts/_cluster_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: $0 <host1> [host2 ...]" >&2; exit 1; }

OUT="${OUT:-hostfile}"

: > "$OUT.tmp"
total=0
for host in "$@"; do
    if [[ -n "${SLOTS:-}" ]]; then
        slots="$SLOTS"
    else
        # Master probed locally, workers over SSH (run_on handles the split).
        slots="$(run_on "$host" nproc 2>/dev/null || true)"
        [[ "$slots" =~ ^[0-9]+$ ]] || {
            echo "[hostfile] FAIL: could not read nproc on '$host'." >&2
            if is_local "$host"; then
                echo "           (this is the master — 'nproc' failed locally?)" >&2
            else
                echo "           Check passwordless SSH: ssh ${SSH_USER}${host} hostname" >&2
            fi
            rm -f "$OUT.tmp"; exit 1; }
    fi
    echo "$host slots=$slots" >> "$OUT.tmp"
    total=$(( total + slots ))
    printf "[hostfile] %-22s slots=%s%s\n" "$host" "$slots" \
        "$(is_local "$host" && echo '  (master, rank 0, local)')"
done
mv "$OUT.tmp" "$OUT"
echo "[hostfile] wrote $OUT  (total slots = $total; first host = rank 0 / master)"
