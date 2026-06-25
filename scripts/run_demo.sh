#!/usr/bin/env bash
# One-command, repeatable cluster demo. Run this on the MASTER (rank 0) after the
# nodes are up and passwordless SSH works. It chains the whole pipeline in order
# and stops at the first failure with a specific hint, so the live demo is a
# single deterministic command instead of a sequence to remember.
#
# Stages:
#   0. make_hostfile.sh   build the hostfile by probing nproc on each node
#                         (skipped if a hostfile already exists, unless FRESH=1)
#   1. sync_nodes.sh      git pull + make on every node -> same commit + binary
#   2. preflight.sh       SSH / MPI / binary / launch / singleton-bug checks
#   3. verify_correctness across the cluster (parallel == sequential, PASS)
#   4. run_size_sweep     runtime vs input size  -> results/size_sweep.csv
#   5. run_granularity    per-rank load balance  -> results/granularity.csv
#   6. run_scaling        speedup ladder at 2N   -> results/scaling.csv
#   7. make_plots.py      all six report figures -> results/fig_*.png
#
# Cluster membership lives in the hostfile (single source of truth). Add the 3rd
# or 4th machine by re-running with NODES set, or FRESH=1 to rebuild it.
#
# Usage:
#   # first time / when node set changes — probe nproc over SSH and build hostfile:
#   NODES="node0 node1 node2" NODE_USER=mpi scripts/run_demo.sh
#
#   # subsequent runs — reuse the existing hostfile:
#   NODE_USER=mpi scripts/run_demo.sh
#
#   # pin the interface if OpenMPI auto-select misfires (see handoff 2b):
#   MPI_IF=enp0s3 NODE_USER=mpi scripts/run_demo.sh
#
#   # skip the long experiments, just prove the cluster works (correctness only):
#   QUICK=1 NODE_USER=mpi scripts/run_demo.sh
#
# Env knobs (all optional):
#   NODES      space-separated hosts; required only to (re)build the hostfile
#   NODE_USER  SSH/login user shared by every node (e.g. mpi)
#   HOSTFILE   hostfile path (default: hostfile)
#   FRESH=1    rebuild the hostfile even if one exists
#   QUICK=1    stop after correctness (skip sweep/granularity/scaling/plots)
#   NO_SYNC=1  skip the git-pull+rebuild stage (nodes already in sync)
#   N          baseline size for granularity/scaling (default: auto from sweep)
#   MPI_IF     network interface to pin for mpirun
#   SIZES      override the size-sweep ladder
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOSTFILE="${HOSTFILE:-hostfile}"
export HOSTFILE
[[ -n "${NODE_USER:-}" ]] && export NODE_USER
[[ -n "${MPI_IF:-}" ]] && export MPI_IF

say() { printf '\n========== %s ==========\n' "$*"; }

# --- 0. hostfile ------------------------------------------------------------
if [[ -n "${FRESH:-}" || ! -f "$HOSTFILE" ]]; then
    [[ -n "${NODES:-}" ]] || {
        echo "[demo] No hostfile and NODES unset. First run needs e.g.:" >&2
        echo "       NODES=\"node0 node1 node2\" NODE_USER=mpi scripts/run_demo.sh" >&2
        exit 1; }
    say "0/7  build hostfile from: $NODES"
    # shellcheck disable=SC2086
    scripts/make_hostfile.sh $NODES
fi

NODE_COUNT="$(grep -cvE '^\s*(#|$)' "$HOSTFILE")"
TOTAL="$(grep -vE '^\s*(#|$)' "$HOSTFILE" | sed -n 's/.*slots=\([0-9]*\).*/\1/p' | paste -sd+ - | bc)"
echo "[demo] cluster: $NODE_COUNT node(s), $TOTAL total slots (hostfile: $HOSTFILE)"
[[ "$NODE_COUNT" -ge 3 ]] || echo "[demo] WARN: assignment requires >= 3 physical machines (have $NODE_COUNT)."

# --- 1. sync code + binary to every node ------------------------------------
if [[ -z "${NO_SYNC:-}" ]]; then
    say "1/7  sync nodes (git pull + make on each)"
    scripts/sync_nodes.sh
else
    say "1/7  sync skipped (NO_SYNC=1)"
fi

# --- 2. preflight health check ----------------------------------------------
say "2/7  preflight checks"
scripts/preflight.sh

# --- 3. correctness across the cluster --------------------------------------
say "3/7  correctness: parallel == sequential (across the cluster)"
scripts/verify_correctness.sh

if [[ -n "${QUICK:-}" ]]; then
    say "QUICK mode: cluster proven (topology + correctness). Stopping before experiments."
    echo "[demo] artifacts: results/cluster_hostname.txt, results/{seq,par}_labels.txt"
    exit 0
fi

# --- 4. size sweep ----------------------------------------------------------
say "4/7  size sweep (runtime vs input size)"
P="$TOTAL" scripts/run_size_sweep.sh

# Pick N: the largest swept size whose wall time is <= 180s, else the largest
# completed size. Reported numbers come from the cluster's own aggregate HW.
if [[ -z "${N:-}" ]]; then
    N="$(python3 - <<'PY'
import csv
rows=[r for r in csv.DictReader(open("results/size_sweep.csv")) if r.get("wall_s")]
def f(r):
    try: return float(r["wall_s"])
    except: return None
ok=[r for r in rows if f(r) is not None]
band=[r for r in ok if f(r)<=180.0]
pick=(band[-1] if band else (ok[-1] if ok else None))
print(pick["M"] if pick else "")
PY
)"
    [[ -n "$N" ]] || { echo "[demo] FAIL: size sweep produced no usable rows." >&2; exit 1; }
    echo "[demo] auto-selected N=$N from size_sweep.csv"
fi

# --- 5. granularity / load balance ------------------------------------------
say "5/7  granularity / load balance at N=$N"
N="$N" P="$TOTAL" scripts/run_granularity.sh

# --- 6. speedup ladder ------------------------------------------------------
say "6/7  speedup ladder 1,2,4,... up to $TOTAL at 2N"
N="$N" MAXP="$TOTAL" scripts/run_scaling.sh

# --- 7. figures -------------------------------------------------------------
# The graded CSVs (size_sweep/granularity/scaling) are already on disk from
# stages 4-6. Plotting needs matplotlib; if it's missing, don't crash the whole
# demo over a figure step — report it and let the user render later.
say "7/7  render figures"
if python3 -c 'import matplotlib' 2>/dev/null; then
    python3 plots/make_plots.py
else
    echo "[demo] WARN: matplotlib not installed — skipping figures." >&2
    echo "[demo]       CSVs are saved in results/. To draw the figures later:" >&2
    echo "[demo]         sudo apt-get install -y python3-matplotlib && python3 plots/make_plots.py" >&2
fi

say "DEMO COMPLETE"
cat <<EOF
[demo] cluster: $NODE_COUNT nodes / $TOTAL cores | operating size N=$N
[demo] evidence:
  results/cluster_hostname.txt   per-node rank topology (>=3 machines)
  results/{seq,par}_labels.txt   correctness PASS (parallel == sequential)
  results/size_sweep.csv         runtime vs size  -> results/fig_size_sweep.png
  results/granularity.csv        load balance     -> results/fig_granularity.png
  results/scaling.csv            speedup ladder    -> results/fig_speedup.png, fig_runtime.png
  results/fig_efficiency.png, results/fig_comm_fraction.png
[demo] next: fill docs/REPORT_OUTLINE.md from these CSVs/figures.
EOF
