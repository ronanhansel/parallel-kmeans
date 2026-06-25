# Cluster Setup Guide — Ubuntu VMs on Windows hosts

This is the "set up any new machine fast" guide. Follow it once per physical
machine. It reproduces the SSH/MPI cluster from the assignment video, automated
where possible.

Target: **≥ 3 physical machines**, one Ubuntu VM each, on one shared LAN, talking
over passwordless SSH, running the same MPI program.

> **Hosts are Windows; nodes are Ubuntu.** The host OS does not matter to MPI —
> all MPI processes run *inside* the Ubuntu VMs. The only host-specific part is
> the VirtualBox network setting (the Bridged Adapter), covered below.

---

## 0. Topology and naming (agree on this as a team first)

| Role   | Hostname  | Example LAN IP   | Notes                         |
|--------|-----------|------------------|-------------------------------|
| master | `node0`   | `192.168.1.50`   | rank 0, launches `mpirun`     |
| slave  | `node1`   | `192.168.1.51`   |                               |
| slave  | `node2`   | `192.168.1.52`   |                               |
| slave  | `node3`   | `192.168.1.53`   | optional 4th machine          |

- One person broadcasts a WiFi hotspot (a phone is fine, as the assignment
  suggests). Every physical machine joins **that one network**.
- The IPs above are examples — you read the real ones in step 3.
- Use the **same Linux username** on every VM (e.g. `mpiuser`). It makes the
  hostfile and SSH config trivial. The rest of this guide assumes `mpiuser`.

---

## 1. Create the Ubuntu VM (per physical machine)

1. Install [VirtualBox](https://www.virtualbox.org/) on the Windows host.
2. Create a VM, install **Ubuntu Server 22.04 or 24.04** (Desktop is fine too,
   Server is lighter). Give it ≥ 2 vCPUs and ≥ 2 GB RAM.
3. **Network — the critical setting.** VM → Settings → Network → Adapter 1:
   - **Attached to: Bridged Adapter**
   - **Name:** pick the host's *active* WiFi/Ethernet adapter (the one connected
     to the shared hotspot).
   - This puts the VM directly on the LAN with its own IP, so the VMs can reach
     each other. NAT (the default) will **not** work — the VMs would be
     invisible to one another.
4. Boot the VM, create the `mpiuser` account during install.

> **Rule from the assignment:** at most **one VM per physical machine**. Don't
> run two nodes on one laptop.

---

## 2. Get the code onto every VM

On each VM:

```bash
sudo apt update
sudo apt install -y git
git clone <YOUR_REPO_URL> parallel-kmeans-mpi
cd parallel-kmeans-mpi
```

> If you cloned on Windows and copied the folder in, the shell scripts may have
> CRLF line endings and fail with `bad interpreter`. This repo ships a
> `.gitattributes` that forces LF on `*.sh`, so a fresh `git clone` inside the VM
> is always safe. Prefer cloning directly in the VM.

---

## 3. Run the bootstrap script (per VM)

```bash
# On node0 (master):
ROLE=master scripts/bootstrap_node.sh

# On node1, node2, ... (slaves):
ROLE=slave scripts/bootstrap_node.sh
```

This installs `openssh-server`, `make`, and the MPI toolchain (**OpenMPI** —
`libopenmpi-dev openmpi-bin`), prepares `~/.ssh` (mode 700), generates a
passphrase-less RSA key if missing, and prints the VM's **LAN IP** and its
**public key**. Write down each IP. (Every node must use the same MPI
implementation; preflight checks this.)

> **Why passphrase-less keys?** `mpirun` opens SSH sessions to the workers
> non-interactively; it cannot type a password. This is standard for an isolated
> lab cluster on a private hotspot. Do not reuse these keys outside the lab.

---

## 4. Exchange SSH keys (so every node can reach every node)

MPI's launcher SSHes from the master to each worker. The simplest robust setup
is **all-to-all** passwordless SSH. On **each** VM, append every *other* VM's
public key to `~/.ssh/authorized_keys`.

Easiest path — from the master, copy its key to every node (including itself):

```bash
# Run on node0. Repeat the IP list for your cluster.
for ip in 192.168.1.50 192.168.1.51 192.168.1.52 192.168.1.53; do
    ssh-copy-id mpiuser@$ip
done
```

If `ssh-copy-id` is unavailable, do it manually: copy the contents of
`~/.ssh/id_rsa.pub` (printed by the bootstrap script) and paste each one into
every other machine's `~/.ssh/authorized_keys`, then:

```bash
chmod 600 ~/.ssh/authorized_keys
```

Make the hostnames resolvable on every VM by adding them to `/etc/hosts`:

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
192.168.1.50  node0
192.168.1.51  node1
192.168.1.52  node2
192.168.1.53  node3
EOF
```

---

## 5. Verify passwordless SSH (do this before touching MPI)

From the master, every hop must work **without a password prompt**:

```bash
ssh node1 hostname
ssh node2 hostname
ssh node3 hostname
```

If any prompts for a password, fix step 4 before continuing. MPI will hang
otherwise.

---

## 6. Build the hostfile, sync, and run — one command from the master

From here on you only work on the **master** (node0). The repo ships four
orchestration scripts that make the whole pipeline repeatable; `run_demo.sh`
chains them in order and stops at the first failure with a fix hint.

```bash
cd ~/parallel-kmeans-mpi

# First run: probe each node's core count over SSH, build the hostfile, sync
# every node to the same commit + binary, run preflight checks, then the full
# experiment + plotting pipeline. NODE_USER is the shared Linux username.
NODES="node0 node1 node2" NODE_USER=mpiuser scripts/run_demo.sh
```

That single command performs, in order:

| Stage | Script | What it proves / produces |
|-------|--------|---------------------------|
| 0 | `make_hostfile.sh` | probes `nproc` per node → `hostfile` (first host = rank 0/master) |
| 1 | `sync_nodes.sh` | `git pull` + `make clean && make` on every node → same commit + fresh binary |
| 2 | `preflight.sh` | SSH, identical MPI impl, binary present, launch path, no `P=1` singleton bug |
| 3 | `verify_correctness.sh` | parallel == sequential **across the cluster** (PASS) |
| 4–6 | `run_size_sweep` / `run_granularity` / `run_scaling` | the three graded experiments |
| 7 | `make_plots.py` | all six report figures |

> **Only the master needs the dataset.** This program reads the `.bin` **only on
> rank 0** and distributes rows with `MPI_Scatterv`, so workers get their points
> over the wire. What every node *does* need is the compiled binary at the
> **same path** — `sync_nodes.sh` guarantees that (it rebuilds on each node), so
> there is no NFS to set up and no data to copy around.

> The cluster runs **OpenMPI** (`libopenmpi-dev openmpi-bin`), installed by the
> bootstrap script. Every node must use the **same** implementation — preflight
> fails loudly if they differ.

### Useful variants

```bash
# Fast cluster proof only — topology + correctness, skip the long experiments:
QUICK=1 NODE_USER=mpiuser scripts/run_demo.sh

# Re-run later reusing the existing hostfile (no NODES needed):
NODE_USER=mpiuser scripts/run_demo.sh

# Adding the 3rd/4th machine — rebuild the hostfile from the new node set:
FRESH=1 NODES="node0 node1 node2 node3" NODE_USER=mpiuser scripts/run_demo.sh

# Pin the network interface if OpenMPI auto-select grabs the wrong one:
MPI_IF=enp0s3 NODE_USER=mpiuser scripts/run_demo.sh
```

> If `~/parallel-kmeans-mpi` is not the repo path on a node, pass
> `REPO_DIR=<path-relative-to-home>`. If you'd rather drive each step by hand,
> the individual scripts take the same env vars — see [`docs/RUNBOOK.md`](RUNBOOK.md).

---

## 7. You're cluster-ready

`run_demo.sh` already produced every CSV and figure. To re-run or tune
individual experiments by hand, proceed to [`docs/RUNBOOK.md`](RUNBOOK.md).

### Quick troubleshooting

| Symptom | Cause / fix |
|---|---|
| `mpirun` hangs | Passwordless SSH not working (step 5), or firewall. `sudo ufw disable` on the lab VMs. |
| `bad interpreter: /bin/bash^M` | CRLF line endings. `git clone` inside the VM, or run `sed -i 's/\r$//' scripts/*.sh`. |
| `mpirun: command not found` | MPI not installed / not on PATH. Re-run bootstrap. |
| VMs can't ping each other | Network not Bridged, or on different WiFi networks. Re-check step 1.3. |
| `There are not enough slots` | Asking for more ranks than `slots` in the hostfile. Raise slots or add `--oversubscribe`. |
| Different MPI on different nodes | Use the same MPI implementation everywhere (all OpenMPI). `preflight.sh` catches this. |
| Four `P=1` lines instead of one `P=<total>` | Stale binary linked against a different MPI runtime. Re-run `scripts/sync_nodes.sh` (`make clean && make` on every node). |
