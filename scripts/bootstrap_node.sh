#!/usr/bin/env bash
# Bootstrap an Ubuntu VM into a cluster-ready MPI node.
#
# Reproduces the manual steps from the assignment video, automated:
#   - update apt, install net-tools, openssh-server/client, make, MPI toolchain
#   - prepare ~/.ssh with mode 700
#   - generate a passphrase-less RSA key if one does not exist
#   - print this node's LAN IP and public key for the key-exchange step
#
# Run on EVERY VM. Pass the role for clarity in the output:
#   ROLE=master scripts/bootstrap_node.sh
#   ROLE=slave  scripts/bootstrap_node.sh
#
# Passphrase-less keys are required because mpirun logs in to workers
# non-interactively. This is appropriate for an isolated lab cluster on a private
# network; do not reuse these keys elsewhere.
set -euo pipefail

ROLE="${ROLE:-node}"
# OpenMPI by default to match the Docker image and README. Every node in one
# cluster MUST use the SAME implementation — do not mix OpenMPI and MPICH.
# Set MPI_PKG="mpich" to switch the whole cluster to MPICH instead.
MPI_PKG="${MPI_PKG:-libopenmpi-dev openmpi-bin}"

echo "==> Bootstrapping this VM as: $ROLE"

if ! command -v apt >/dev/null 2>&1; then
    echo "This script targets Debian/Ubuntu (apt not found)." >&2
    exit 1
fi

echo "==> [1/6] Checking packages (install only what's missing)"
# python3-numpy + python3-matplotlib are needed on the master to generate
# datasets (gen_dataset.py) and render figures (make_plots.py). Installing them
# on every node is harmless and keeps any node usable as the launcher.
#
# Cold start installs missing packages; warm start is a no-op. We never run
# `apt update` or upgrade already-installed packages — only a missing package
# triggers a single `apt update` + install of just the gaps, so re-running this
# script on a provisioned node costs nothing.
REQUIRED_PKGS=(net-tools openssh-server openssh-client make gcc $MPI_PKG \
    python3 python3-numpy python3-matplotlib)

missing=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        missing+=("$pkg")
    fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "    all packages already installed, skipping apt"
else
    echo "    missing: ${missing[*]}"
    sudo apt update
    sudo apt install -y --no-upgrade "${missing[@]}"
fi

echo "==> [2/6] Ensuring SSH server is running"
sudo systemctl enable --now ssh 2>/dev/null || sudo service ssh start || true

echo "==> [3/6] Preparing ~/.ssh (mode 700)"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

echo "==> [4/6] Generating passphrase-less RSA key (if absent)"
if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
    echo "    generated ~/.ssh/id_rsa"
else
    echo "    key already exists, leaving it untouched"
fi

# For an isolated lab cluster on a private hotspot, VM IPs and host keys change
# across reboots/rebuilds, which makes SSH throw "Host key verification failed"
# and breaks mpirun's non-interactive worker launch. Relax host-key checking for
# the cluster's private subnet + node aliases so the launcher never gets stuck on
# a stale key. This block is idempotent (only added once).
echo "==> [5/6] Relaxing SSH host-key checks for the lab subnet (idempotent)"
SSH_CFG="$HOME/.ssh/config"
touch "$SSH_CFG"; chmod 600 "$SSH_CFG"
if ! grep -q '# >>> kmeans-cluster >>>' "$SSH_CFG"; then
    cat >> "$SSH_CFG" <<'CFG'

# >>> kmeans-cluster >>>
# Isolated lab cluster on a private LAN. Disable host-key prompts so mpirun can
# SSH to workers non-interactively even after VM rebuilds / DHCP IP churn.
# Do NOT use these settings on machines exposed to the internet.
Host 10.* 172.16.* 172.17.* 172.18.* 172.19.* 172.2*.* 172.3*.* 192.168.* node0 node1 node2 node3
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
# <<< kmeans-cluster <<<
CFG
    echo "    added kmeans-cluster block to ~/.ssh/config"
else
    echo "    kmeans-cluster block already present, leaving it"
fi

echo "==> [6/6] Node identity (record these for the key-exchange step)"
echo "----------------------------------------------------------------"
echo "Hostname : $(hostname)"
echo -n "LAN IP   : "
# Prefer the bridged interface address; fall back across tools.
if command -v ip >/dev/null 2>&1; then
    ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | paste -sd' ' -
elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig | awk '/inet /{print $2}' | grep -v '127.0.0.1' | paste -sd' ' -
else
    hostname -I
fi
echo "MPI      : $(command -v mpirun || echo 'NOT FOUND') ($(mpirun --version 2>/dev/null | head -1))"
echo "Public key (append to authorized_keys on every OTHER node):"
echo "----------------------------------------------------------------"
cat "$HOME/.ssh/id_rsa.pub"
echo "----------------------------------------------------------------"
echo "==> Done. Next: exchange keys (CLUSTER_SETUP.md step 4) and build with 'make'."
