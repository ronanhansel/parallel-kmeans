#!/usr/bin/env bash
# Bring every node to the same code + binary before a cluster run.
#
# mpirun execs ./bin/kmeans_mpi at the SAME relative path on every host, so a
# stale binary on any slave silently breaks the run (classic symptom: four
# "P=1" lines instead of one "P=<total>" — the binary was linked against a
# different MPI runtime; see docs/RUNBOOK / handoff "singleton bug").
#
# This script SSHes into each host listed in the hostfile and runs, in the repo:
#     git pull --ff-only   (skip with NO_PULL=1)
#     make clean && make
# so all nodes end up at the same commit with a freshly linked binary.
#
# The hostfile is the single source of truth for cluster membership — add the
# 3rd/4th node there (via make_hostfile.sh) and it's picked up automatically.
#
# Usage:
#   scripts/sync_nodes.sh
#   HOSTFILE=hosts.txt NODE_USER=mpi scripts/sync_nodes.sh
#   REPO_DIR=parallel-kmeans-mpi scripts/sync_nodes.sh
#   NO_PULL=1 scripts/sync_nodes.sh        # just rebuild, don't git pull
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOSTFILE="${HOSTFILE:-hostfile}"
NODE_USER="${NODE_USER:+${NODE_USER}@}"
REPO_DIR="${REPO_DIR:-parallel-kmeans-mpi}"   # path on each node, relative to ~

[[ -f "$HOSTFILE" ]] || { echo "[sync] FAIL: no hostfile '$HOSTFILE' (run make_hostfile.sh first)." >&2; exit 1; }

# Extract host tokens (first field of each non-comment, non-blank line).
mapfile -t HOSTS < <(grep -vE '^\s*(#|$)' "$HOSTFILE" | awk '{print $1}')
[[ ${#HOSTS[@]} -ge 1 ]] || { echo "[sync] FAIL: no hosts in '$HOSTFILE'." >&2; exit 1; }

if [[ -n "${NO_PULL:-}" ]]; then
    BUILD='make clean >/dev/null && make'
else
    BUILD='git pull --ff-only && make clean >/dev/null && make'
fi

echo "[sync] hosts: ${HOSTS[*]}"
echo "[sync] repo on each node: ~/$REPO_DIR   ($( [[ -n "${NO_PULL:-}" ]] && echo 'rebuild only' || echo 'git pull + rebuild'))"

fail=0
for host in "${HOSTS[@]}"; do
    echo "[sync] ===== $host ====="
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "${NODE_USER}${host}" \
        "cd ~/$REPO_DIR && $BUILD" 2>&1 | sed "s/^/[sync:$host] /"; then
        # Confirm the binary is present and report its commit for an audit trail.
        commit="$(ssh -o BatchMode=yes "${NODE_USER}${host}" \
            "cd ~/$REPO_DIR && test -x bin/kmeans_mpi && git rev-parse --short HEAD" 2>/dev/null || true)"
        if [[ -n "$commit" ]]; then
            printf "[sync] OK   %-22s commit=%s\n" "$host" "$commit"
        else
            echo "[sync] FAIL: bin/kmeans_mpi missing on $host after build." >&2; fail=1
        fi
    else
        echo "[sync] FAIL: build failed on $host (see lines above)." >&2; fail=1
    fi
done

if (( fail )); then
    echo "[sync] one or more nodes failed — fix before running the demo." >&2
    exit 1
fi
echo "[sync] all nodes synced and built. Next: scripts/preflight.sh"
