# Project Handoff — Parallel K-Means MPI Cluster

**Last updated:** 2026-06-21
**Read this first.** It lets any agent resume without re-deriving the context.

---

## 1. What this project is

Course assignment: implement a non-trivial **parallel algorithm on a real MPI
cluster** (≥3 machines), prove it matches the sequential solution, and produce
load-balance + speedup charts. **Deadline: 24 June 2026.** Team of 4.

Chosen problem: **Parallel K-Means** (data parallelism, 1D block-row
decomposition). The code is complete and correct. See `README.md` and
`docs/REPORT_OUTLINE.md`.

The repo (code, experiment scripts, plotting, docs) is **done and pushed**. The
remaining work is **standing up the cluster and collecting results on real
hardware**, then writing the report.

---

## 2. Hard-won facts — DO NOT relitigate these

These were settled through painful debugging. Trust them.

### 2a. The Mac is the DRIVER, never a compute node
- User's machine is an **Apple Silicon (ARM) Mac**. MPI cannot mix ARM and x86
  ranks in one job. Cluster nodes must all be **x86_64 Linux**.
- **Docker on Mac cannot be an MPI node either.** Docker Desktop containers sit
  behind a LinuxKit NAT (`172.17.x`); `--network host` does NOT work on Mac. The
  container's self-IP is unreachable from other machines, so MPI rank callbacks
  hang. Also it runs under QEMU emulation → timings are meaningless.
- **Conclusion:** Mac = code authority + launcher + plotting (matplotlib is
  installed). It SSHes into the master node and runs `mpirun`. This is normal HPC
  (login node ≠ compute node). The Mac's x86 Docker env (`docker/run.sh`) is for
  **local build/correctness testing only**, never timing, never cluster peer.

### 2b. WSL2 was abandoned for the cluster — use VirtualBox bridged VMs
We spent a long session trying WSL2 Ubuntu nodes. Two distinct, real bugs:
- **Mirrored networking mode** breaks loopback routing
  (`127.0.0.1 via 169.254.x dev loopback0`). MPICH's Hydra PMI barrier and
  OpenMPI's launcher both hang because their localhost back-channel is mangled.
- **NAT mode** isolates each WSL behind its Windows host → no rank-to-rank
  reachability → can't form a multi-node cluster. Also the WSL IP changes on
  reboot.
- WSL hostname (`LAPTOP-...`) resolved to **IPv6 link-local only**, and stray
  interfaces (a Radmin VPN `eth0 26.x/8`) confused MPI interface auto-selection.

**Decision (user, 2026-06-21):** abandon WSL, use **VirtualBox + Ubuntu Server
24.04 + Bridged Adapter** — this is also exactly what the professor's spec
requires ("bridged adapters over a shared LAN, 1 VM per physical machine").

### 2c. MPI implementation = OpenMPI
- During the WSL firefight we briefly switched the repo to MPICH (Hydra dodged
  the WSL launcher hang). **That has been reverted.** The WSL hangs do NOT exist
  on clean bridged Ubuntu VMs.
- Repo standardizes on **OpenMPI** (`libopenmpi-dev openmpi-bin`). README,
  Dockerfile, `bootstrap_node.sh`, and all docs assume OpenMPI. **Every node must
  use the same implementation — do not mix.**
- If a future WSL-only fallback is ever needed, `bootstrap_node.sh` accepts
  `MPI_PKG="mpich"`, but the cluster should be OpenMPI.

### 2d. The singleton bug to watch for
On a node, `mpirun -np 4 ./bin/kmeans_mpi ...` printing **four `P=1` lines**
instead of one `P=4` means the binary is linked against a *different* MPI runtime
than the `mpirun` launching it (stale binary after switching MPI impls). Fix:
`make clean && make`. A correct run prints a single `kmeans_mpi: P=4 ...` line.

---

## 3. Current repo state

- Remote: `https://github.com/ronanhansel/parallel-kmeans.git`, branch `main`.
- Last pushed commit: `eb4050c` (OpenMPI defaults, WSL/remote docs).
- Local working tree (as of this handoff): Dockerfile + bootstrap_node.sh
  reverted to OpenMPI; a stray `hostfile` (`vinh@172.20.10.2 slots=4`) exists from
  WSL testing — **delete or overwrite it** when building the real cluster hostfile.
- **Verified working:** correctness (parallel == sequential, bit-identical) and
  the full scaling→plot pipeline, both on the Mac's x86 Docker env. The algorithm
  is sound; only real-hardware data collection remains.

### Repo map
```
src/kmeans_mpi.c     parallel core (graded): Scatterv→Bcast→assign→Allreduce→converge
src/kmeans_seq.c     sequential baseline (correctness ref + T1 for speedup)
src/common.h         dataset I/O, distance, deterministic seeding
Makefile             `make` → bin/kmeans_mpi (mpicc) + bin/kmeans_seq (cc)
scripts/gen_dataset.py        Gaussian blobs → binary dataset (--points --dim --clusters --seed)
scripts/verify_correctness.sh parallel labels == sequential (PASS/FAIL)
scripts/run_size_sweep.sh     find N where wall time ≈ 2–3 min on all cores
scripts/run_granularity.sh    per-rank compute/comm timing + 25% load verdict
scripts/run_scaling.sh        speedup ladder 1,2,4,8,… at data scale 2N
scripts/bootstrap_node.sh     one-shot Ubuntu node setup (apt + SSH keys + OpenMPI)
plots/make_plots.py           CSVs → all report figures (PNG)
docker/run.sh                 x86 Docker dev env on Mac (build/verify only)
docs/CLUSTER_SETUP.md         VirtualBox + bridged networking walkthrough
docs/RUNBOOK.md               exact commands to reproduce every result/figure
docs/REPORT_OUTLINE.md        10–20 pg report scaffold mapped to experiments
docs/WSL_SETUP.md             (superseded for the cluster — kept for reference)
docs/REMOTE_ACCESS.md         Tailscale + SSH if team is not co-located
```

All scripts take `HOSTFILE=<file>` to span the cluster and read `P`/`N`/`MAXP`
from env. Datasets/results are gitignored (regenerate with the same `--seed`).

---

## 4. Where the user is RIGHT NOW

Installing **VirtualBox + Ubuntu Server 24.04** VMs on friends' Windows machines.
Each Windows host runs one bridged-adapter Ubuntu VM. Target: ≥3 nodes.

The setup steps given to the user (Phases 1–4): create VM (bridged adapter,
Promiscuous = Allow All, identical username e.g. `mpi`, install OpenSSH server);
`apt install build-essential libopenmpi-dev openmpi-bin git python3-numpy
python3-matplotlib net-tools`; clone repo to `~/parallel-kmeans`; `make`; per-node
smoke test `mpirun -np 4 ./bin/kmeans_mpi data/t.bin 16 50 1e-9` must show `P=4`.

The user's Mac SSH public key (to authorize on the master so the Mac can drive):
```
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDFdaC37lSOHfGfWjSyxxkepE4J7hG+BYg+GZFQme9oayqgL21Zs2yOVswGCSMefan+2uqn7vh8NmwHh/gLtp1BcoPCgxaqPc65VXxJA94tfIFRaM3Y8juwAf5ExKQeSS2H+p4HjwufPBoKUjJkznoS1rg+xGPy1mX8WuQW2qoT8NeZfVa7mbg3k01NyaJSH8WMhNpivj45+QBDq+WUPukJF/Xp5ODDMF/d66PQktrlS842b/5PCzfaQjf+PBUwYo38ST/B2T1xhSjU9mL9AFveiKgF0OIccrblJdxCbsDvEPWeKB4k68STgRRHH9MUxvZX6A9BLzLHLbJbg0nXmP3RV0mMAFN8i1ppDsr1cBScRs0ILFoOJkP7qcd6pyXklWkofgce5tCfi3NIVEXHol70bQId4jmelmxS2Bha+mGvc1a2l+TzEaB3K3d1uYh2iLYr9vpo1GKWDu9qKWyO9cArrNQIPC0E2n+wy/sipfnduIvZxwNDGHmIXQK0vgW3IEX2BnbNxllcRpzcCbaF6QcCTxqbqidMc0NJTMuPvzcAlUGoqZivi1hErypNomOtljvc5lBV9+WxDprDD7MV7V76M4/iejTNhbb8aKz36ULRVRfLa0k+Vjj0O8yLooSw4+dcYpS0/E43QBxPOaaIUtA2ccbvnieFVJDwbUoix1Ci5Q== ronan@Ronans-MacBook-Pro.local
```

---

## 5. RESUME HERE — what to do when the user returns

The user will paste, per VM: hostname, `hostname -I` (bridged LAN IP), `nproc`,
and the `P=4` smoke-test output; plus which IP is the master and whether the Mac
shares the LAN.

Then:

1. **Reach the master** from the Mac: `ssh mpi@<master-ip> hostname`. (Same-LAN
   bridged VMs are directly reachable, like Vinh was under mirrored mode.)
2. **Exchange SSH keys** so every node logs into every other node passwordlessly
   in BOTH directions (MPI launches workers over SSH non-interactively). Use
   `bootstrap_node.sh` to generate keys; append each node's `~/.ssh/id_rsa.pub`
   into every other node's `~/.ssh/authorized_keys`. Verify `ssh <other> hostname`
   works with no prompt between every pair.
3. **Build the hostfile** (overwrite the stray one) at repo root, e.g.:
   ```
   <master-ip> slots=<cores>
   <node2-ip>  slots=<cores>
   <node3-ip>  slots=<cores>
   ```
4. **Cluster smoke test:** `mpirun --hostfile hostfile -np <total> hostname` →
   must print each node's hostname. Then a real run:
   `mpirun --hostfile hostfile -np <total> ./bin/kmeans_mpi data/t.bin 16 50 1e-9`
   → must show a single `P=<total>` line.
   - Repo must be at the **same path on every node** AND the dataset must exist on
     every node (regenerate with identical `--seed`, or share via NFS). The run
     scripts only generate data on the launching node — for multi-node runs,
     generate the dataset on each node first with the same args.
   - If OpenMPI picks a wrong interface, pin it:
     `--mca btl_tcp_if_include <iface> --mca oob_tcp_if_include <iface>`.
5. **Run the experiments** (full detail in `docs/RUNBOOK.md`):
   ```
   HOSTFILE=hostfile P=<total>  scripts/run_size_sweep.sh    # pick N (~2–3 min wall)
   HOSTFILE=hostfile P=<total>  N=<chosen> scripts/run_granularity.sh
   HOSTFILE=hostfile MAXP=<total> N=<chosen> scripts/run_scaling.sh
   python3 plots/make_plots.py
   ```
   Required outputs: correctness PASS; runtime-vs-size to fix N; per-rank
   compute+comm stacked bar (load balance, retune if idle spread >25%); runtime +
   speedup curves at 2N over P = 1,2,4,…,2×total_cores.
6. **Fill in the report** from `docs/REPORT_OUTLINE.md` (already mapped
   section-by-section to each experiment).

---

## 6. Open questions / decisions pending

- **Total node + core count** not yet known → sets the speedup ladder
  (1,2,4,…,2×cores). Ask when results come in.
- **Remote teammates?** If the 4 are NOT co-located, `docs/REMOTE_ACCESS.md`
  covers Tailscale (each node joins one tailnet; pin MPI to `tailscale0`). Works
  for dev/debug, but WAN latency distorts the Allreduce-heavy timing — do the
  FINAL graded measurements on a co-located bridged LAN. Confirm with professor if
  remote is acceptable.
- The user asked twice about making the Mac a node (Docker x86, then Tailscale).
  Both answered: Mac stays the driver. Don't reopen unless the user insists.
