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

This installs `openssh-server`, `make`, and the MPI toolchain (`mpich`),
prepares `~/.ssh` (mode 700), generates a passphrase-less RSA key if missing,
and prints the VM's **LAN IP** and its **public key**. Write down each IP.

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

## 6. Build on every node

The binary must exist at the **same path** on every node. Easiest: build on each.

```bash
cd ~/parallel-kmeans-mpi && make
```

(`make` produces `bin/kmeans_mpi` and `bin/kmeans_seq`.)

> The cluster runs `mpich` (`sudo apt install mpich`). The bootstrap script
> installs it. If you prefer OpenMPI, install `libopenmpi-dev openmpi-bin`
> instead and rebuild — the source is implementation-agnostic.

---

## 7. The hostfile

Create `hosts.txt` in the repo root on the master. `slots` = cores you want to
use on that node (match physical cores per the assignment).

```
# hostname   slots=<cores on that VM>
node0 slots=4
node1 slots=4
node2 slots=4
```

Three 4-core VMs → 12 total ranks, which is the configuration the experiments
target.

---

## 8. Smoke test across the cluster

```bash
# Should print 12 lines naming the three hosts.
mpirun --hostfile hosts.txt -np 12 hostname

# Real run: generate a dataset, then cluster it across the LAN.
python3 scripts/gen_dataset.py --out data/smoke.bin --points 200000 --dim 16 --clusters 16
mpirun --hostfile hosts.txt -np 12 ./bin/kmeans_mpi data/smoke.bin 16 50 1e-9
```

If the dataset must exist on every node (it does — rank 0 reads it, but workers
need the binary and any input paths consistent), either keep the dataset on the
master only (rank 0 reads + scatters, which is how this program works — workers
get their rows over the wire, so **only the master needs the data file**), or
share `~/parallel-kmeans-mpi` over NFS for convenience.

> This program reads the dataset **only on rank 0** and distributes rows with
> `MPI_Scatterv`. So the data file needs to exist **only on the master**. The
> compiled binary, however, must exist at the same path on every node.

---

## 9. You're cluster-ready

Proceed to `docs/RUNBOOK.md` to run the graded experiments and produce the
report charts.

### Quick troubleshooting

| Symptom | Cause / fix |
|---|---|
| `mpirun` hangs | Passwordless SSH not working (step 5), or firewall. `sudo ufw disable` on the lab VMs. |
| `bad interpreter: /bin/bash^M` | CRLF line endings. `git clone` inside the VM, or run `sed -i 's/\r$//' scripts/*.sh`. |
| `mpirun: command not found` | MPI not installed / not on PATH. Re-run bootstrap. |
| VMs can't ping each other | Network not Bridged, or on different WiFi networks. Re-check step 1.3. |
| `There are not enough slots` | Asking for more ranks than `slots` in the hostfile. Raise slots or add `--oversubscribe`. |
| Different MPI on different nodes | Use the same MPI implementation everywhere (all `mpich` or all OpenMPI). |
