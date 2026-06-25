#!/usr/bin/env bash
# Pre-demo health check for the cluster. Run AFTER make_hostfile.sh + sync_nodes.sh
# and BEFORE the graded demo. Catches every failure mode we hit during setup:
#   1. passwordless SSH (mpirun launches workers non-interactively — a prompt = hang)
#   2. mixed MPI implementations across nodes (must all be the same; we use OpenMPI)
#   3. stale / missing binary (the "four P=1 lines" singleton bug)
#   4. wrong network interface auto-selected by OpenMPI (rank callbacks hang)
#
# Exits non-zero on the first hard failure with a specific fix hint.
#
# Usage:
#   scripts/preflight.sh
#   HOSTFILE=hosts.txt NODE_USER=mpi scripts/preflight.sh
#   MPI_IF=enp0s3 scripts/preflight.sh    # pin the interface if auto-select misfires
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOSTFILE="${HOSTFILE:-hostfile}"
NODE_USER="${NODE_USER:+${NODE_USER}@}"
REPO_DIR="${REPO_DIR:-parallel-kmeans-mpi}"
MPIRUN="${MPIRUN:-mpirun}"

[[ -f "$HOSTFILE" ]] || { echo "[preflight] FAIL: no hostfile '$HOSTFILE'." >&2; exit 1; }

mapfile -t HOSTS < <(grep -vE '^\s*(#|$)' "$HOSTFILE" | awk '{print $1}')
TOTAL="$(grep -vE '^\s*(#|$)' "$HOSTFILE" | sed -n 's/.*slots=\([0-9]*\).*/\1/p' | paste -sd+ - | bc)"
[[ "${TOTAL:-0}" -ge 1 ]] || { echo "[preflight] FAIL: could not total slots from '$HOSTFILE'." >&2; exit 1; }

# Interface pin, if requested, applied to both the TCP byte-transport and the
# out-of-band launcher channel (both must agree or rank wire-up hangs).
EXTRA=(--hostfile "$HOSTFILE")
if [[ -n "${MPI_IF:-}" ]]; then
    EXTRA+=(--mca btl_tcp_if_include "$MPI_IF" --mca oob_tcp_if_include "$MPI_IF")
fi

echo "[preflight] hostfile '$HOSTFILE': ${#HOSTS[@]} node(s), $TOTAL total slots"
if [[ ${#HOSTS[@]} -lt 3 ]]; then
    echo "[preflight] WARN: only ${#HOSTS[@]} node(s). The assignment requires >= 3 physical machines."
fi

# --- 1. passwordless SSH, every node ----------------------------------------
echo "[preflight] [1/5] passwordless SSH to each node"
for host in "${HOSTS[@]}"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "${NODE_USER}${host}" true 2>/dev/null; then
        echo "[preflight]   OK   $host"
    else
        echo "[preflight]   FAIL: '$host' needs a password or is unreachable." >&2
        echo "[preflight]   fix: ssh-copy-id ${NODE_USER}${host}  (and check it's on the LAN)." >&2
        exit 1
    fi
done

# --- 2. same MPI implementation + version on every node ---------------------
echo "[preflight] [2/5] MPI implementation consistent across nodes"
ref=""
for host in "${HOSTS[@]}"; do
    ver="$(ssh -o BatchMode=yes "${NODE_USER}${host}" 'mpirun --version 2>&1 | head -1' 2>/dev/null || true)"
    [[ -n "$ver" ]] || { echo "[preflight]   FAIL: no mpirun on '$host' (re-run bootstrap_node.sh)." >&2; exit 1; }
    printf "[preflight]   %-22s %s\n" "$host" "$ver"
    if [[ -z "$ref" ]]; then ref="$ver"
    elif [[ "$ver" != "$ref" ]]; then
        echo "[preflight]   FAIL: MPI differs across nodes — every node must use the SAME impl/version." >&2
        exit 1
    fi
done

# --- 3. binary present at the same path on every node -----------------------
echo "[preflight] [3/5] bin/kmeans_mpi present + same commit on every node"
ref_commit=""
for host in "${HOSTS[@]}"; do
    line="$(ssh -o BatchMode=yes "${NODE_USER}${host}" \
        "cd ~/$REPO_DIR 2>/dev/null && test -x bin/kmeans_mpi && git rev-parse --short HEAD" 2>/dev/null || true)"
    [[ -n "$line" ]] || {
        echo "[preflight]   FAIL: bin/kmeans_mpi missing on '$host' — run scripts/sync_nodes.sh." >&2; exit 1; }
    printf "[preflight]   %-22s commit=%s\n" "$host" "$line"
    if [[ -z "$ref_commit" ]]; then ref_commit="$line"
    elif [[ "$line" != "$ref_commit" ]]; then
        echo "[preflight]   WARN: '$host' is at $line, master at $ref_commit — re-run sync_nodes.sh." >&2
    fi
done

# --- 4. cluster hostname smoke test (proves SSH+TCP launch path) ------------
echo "[preflight] [4/5] mpirun hostname across the cluster (-np $TOTAL)"
HN="$("$MPIRUN" "${EXTRA[@]}" -np "$TOTAL" hostname 2>&1 || true)"
if [[ -z "$HN" ]]; then
    echo "[preflight]   FAIL: mpirun hostname produced no output (launch path broken)." >&2
    echo "[preflight]   hint: try MPI_IF=<iface> to pin the interface (see handoff 2b/2d)." >&2
    exit 1
fi
echo "$HN" | sort | uniq -c | sed 's/^/[preflight]   /'
mkdir -p results
echo "$HN" | sort | uniq -c > results/cluster_hostname.txt
echo "[preflight]   saved topology proof -> results/cluster_hostname.txt"

# --- 5. real run, must report a SINGLE P=<total> line (no singleton bug) ----
echo "[preflight] [5/5] tiny kmeans run, expect one 'P=$TOTAL' line"
[[ -f data/t.bin ]] || python3 scripts/gen_dataset.py --out data/t.bin --points 20000 --dim 16 --clusters 16 --seed 7 >/dev/null
RUN="$("$MPIRUN" "${EXTRA[@]}" -np "$TOTAL" ./bin/kmeans_mpi data/t.bin 16 50 1e-9 2>/dev/null || true)"
pcount="$(grep -c "P=$TOTAL " <<<"$RUN" || true)"
psingle="$(grep -c 'P=1 ' <<<"$RUN" || true)"
echo "$RUN" | sed 's/^/[preflight]   /'
if [[ "$pcount" -ge 1 ]]; then
    echo "[preflight]   OK: single P=$TOTAL run — ranks share one communicator."
elif [[ "$psingle" -ge 1 ]]; then
    echo "[preflight]   FAIL: saw P=1 lines (singleton bug). Binary linked vs a different MPI." >&2
    echo "[preflight]   fix: scripts/sync_nodes.sh (make clean && make on every node)." >&2
    exit 1
else
    echo "[preflight]   FAIL: no P= line — run did not complete." >&2; exit 1
fi

echo "[preflight] ALL CHECKS PASSED — cluster is demo-ready. Next: scripts/run_demo.sh"
