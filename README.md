# Parallel K-Means on an MPI Cluster

Data-parallel K-means clustering in C + MPI, with a complete experiment harness
that produces every figure the assignment report requires. Built to run on a
cluster of **≥3 Ubuntu machines** (one VM per physical host, bridged network),
and to develop/validate on a single laptop first.

> Course project: implement a non-trivial parallel algorithm on a real MPI
> cluster, prove it matches the sequential solution, and characterise its
> load balance and speedup. Deadline **24 June 2026**. See
> [`docs/REPORT_OUTLINE.md`](docs/REPORT_OUTLINE.md).

## What's here

```
src/kmeans_mpi.c     parallel K-means (the graded core): Scatterv -> Bcast
                     -> local assign -> Allreduce -> uniform convergence
src/kmeans_seq.c     sequential baseline (correctness reference + T1 for speedup)
src/common.h         dataset I/O, distance, deterministic seeding (shared)
Makefile             `make` builds both binaries (mpicc + cc)

scripts/gen_dataset.py        synthetic Gaussian blobs -> binary dataset
scripts/verify_correctness.sh parallel labels == sequential labels (PASS/FAIL)
scripts/run_size_sweep.sh     find N where wall time ~= 2-3 min on all cores
scripts/run_granularity.sh    per-rank compute/comm timing + 25% load verdict
scripts/run_scaling.sh        speedup ladder 1,2,4,8,... at data scale 2N
scripts/bootstrap_node.sh     one-shot Ubuntu cluster-node setup (SSH + OpenMPI)

plots/make_plots.py           CSVs -> all report figures (PNG)

docker/Dockerfile             x86-64 Ubuntu image mirroring the cluster toolchain
docker/run.sh                 build/shell/make/verify wrapper (handles --platform)

docs/CLUSTER_SETUP.md         set up any new machine fast (Windows host -> Ubuntu VM)
docs/WSL_SETUP.md             WSL2 Ubuntu cluster + Mac driver (staged, with networking)
docs/REMOTE_ACCESS.md         Tailscale mesh for teammates on different networks
docs/RUNBOOK.md               exact commands to reproduce every result + figure
docs/REPORT_OUTLINE.md        10-20 pg report scaffold mapped to each experiment
```

## Quickstart (single machine — develop & validate)

Prereqs: a C/MPI toolchain and Python with numpy + matplotlib.

- **macOS:** `brew install open-mpi`
- **Ubuntu:** `sudo apt install -y build-essential libopenmpi-dev openmpi-bin python3-numpy python3-matplotlib`

```bash
make                              # build bin/kmeans_mpi and bin/kmeans_seq
scripts/verify_correctness.sh     # proves parallel == sequential (PASS)

# quick speedup demo on local cores, then draw the curves
N=60000 scripts/run_scaling.sh
python3 plots/make_plots.py
open results/fig_speedup.png      # Linux: xdg-open
```

`verify_correctness.sh` should print `PASS: … bit-identical …`. That confirms the
build and the algorithm before you touch the cluster.

## Matching the cluster on a Mac (x86-64 Ubuntu in Docker)

The cluster nodes are **x86-64 Ubuntu**. An Apple-Silicon Mac is ARM, so binaries
built natively there won't match the cluster and some code compiles differently
(e.g. POSIX feature-test macros). To develop against an environment that's
byte-compatible with the cluster, use the bundled x86-64 Ubuntu image:

```bash
docker/run.sh build               # one time: build the x86-64 Ubuntu image
docker/run.sh verify              # build + correctness check inside Linux x86-64
docker/run.sh make                # just compile the Linux binaries
docker/run.sh shell               # interactive Ubuntu shell at /work
docker/run.sh run -- mpirun -np 4 ./bin/kmeans_mpi data/verify.bin 8 100 1e-8
```

The repo is bind-mounted, so host edits are live in the container. This is the
right place to confirm the **Linux build and correctness** before pushing.

> On Apple Silicon this image runs under emulation (QEMU). It's faithful for
> compilation and correctness but **not** for timing — the speedup/granularity
> numbers in the report must come from real x86 cluster hardware, not Docker.

## Running on the real cluster

1. On **every** node, follow [`docs/CLUSTER_SETUP.md`](docs/CLUSTER_SETUP.md) —
   it walks Windows users through VirtualBox + bridged networking and runs
   `scripts/bootstrap_node.sh` to install OpenMPI and wire up passwordless SSH.
2. Create a `hostfile` listing each node and its core count, e.g.:
   ```
   master slots=4
   slave1 slots=4
   slave2 slots=4
   ```
3. Clone this repo to the **same path** on every node (or share via NFS), then on
   the master:
   ```bash
   make
   # smoke test: every node prints its hostname
   mpirun --hostfile hostfile -np 12 hostname
   ```
4. Reproduce the experiments — full step-by-step in
   [`docs/RUNBOOK.md`](docs/RUNBOOK.md):
   ```bash
   HOSTFILE=hostfile P=12 scripts/run_size_sweep.sh   # pick N (~2-3 min)
   HOSTFILE=hostfile P=12 N=<chosen> scripts/run_granularity.sh
   HOSTFILE=hostfile MAXP=12 N=<chosen> scripts/run_scaling.sh
   python3 plots/make_plots.py
   ```

## Design at a glance

| Aspect | Choice |
|---|---|
| Parallelism level | Data parallelism |
| Decomposition | Data, 1D block-row over M points |
| Mapping | 1D block; `Scatterv` spreads the remainder (≤1 point imbalance) |
| Communication | Master–slave hybrid: `Scatterv` once, `Bcast` + `Allreduce` per iter, `Gatherv` once; blocking collectives |
| Topology | Tree (MPI collective binomial-tree reduction), O(log P) depth |
| Convergence | Every rank holds identical global centroids → uniform termination |

Full rationale for each choice is in [`docs/REPORT_OUTLINE.md`](docs/REPORT_OUTLINE.md) §3.

## Notes

- Shell scripts are forced to LF via `.gitattributes` so they run correctly
  inside the Linux VMs even when checked out on Windows hosts.
- Datasets and results are gitignored; regenerate them with the scripts above.
- The passwordless SSH keys created by `bootstrap_node.sh` are for an isolated
  lab cluster only — don't reuse that setup on machines exposed to the internet.
