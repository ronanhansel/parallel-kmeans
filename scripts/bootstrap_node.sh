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

echo "==> [1/5] Updating apt and installing packages"
sudo apt update
sudo apt install -y net-tools openssh-server openssh-client make gcc $MPI_PKG

echo "==> [2/5] Ensuring SSH server is running"
sudo systemctl enable --now ssh 2>/dev/null || sudo service ssh start || true

echo "==> [3/5] Preparing ~/.ssh (mode 700)"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

echo "==> [4/5] Generating passphrase-less RSA key (if absent)"
if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
    echo "    generated ~/.ssh/id_rsa"
else
    echo "    key already exists, leaving it untouched"
fi

echo "==> [5/5] Node identity (record these for the key-exchange step)"
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
