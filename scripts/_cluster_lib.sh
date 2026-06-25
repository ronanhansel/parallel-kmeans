#!/usr/bin/env bash
# Shared helpers for the cluster orchestration scripts (make_hostfile, sync_nodes,
# preflight). Sourced, not executed.
#
# The key idea: the MASTER (rank 0) is whatever machine these scripts run on, and
# it must NOT SSH to itself. mpirun launches the local rank by fork, not SSH, and
# a master typically has no passwordless SSH to its own name. So every per-node
# action checks is_local() first and runs locally for the master, SSH otherwise.
#
# Callers set NODE_USER (bare username, no @) before sourcing; we normalise it.

# Bare login user (may be empty) and the user@ prefix for SSH.
CLUSTER_USER="${NODE_USER:-}"
SSH_USER="${CLUSTER_USER:+${CLUSTER_USER}@}"

# The master (rank 0). Callers set this to the FIRST host before using is_local.
# By the documented convention the first host IS the machine these scripts run
# on, so it is treated as local unconditionally — no name resolution, no SSH.
# This is the authoritative signal; the resolution checks below are only a
# fallback for hosts that aren't the designated master.
CLUSTER_MASTER="${CLUSTER_MASTER:-}"

# All names/addresses that refer to THIS machine: hostnames + every local IP.
_self_id="$( { hostname; hostname -s; hostname -f; hostname -I; } 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | sort -u )"

# _resolve <host> : print the IPv4 addresses <host> resolves to, one per line
# (empty if it can't be resolved). Tries getent (Linux) then a Python fallback
# so an /etc/hosts alias like 'node0' -> the master's LAN IP is detected.
_resolve() {
    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
    else
        python3 - "$1" 2>/dev/null <<'PY' || true
import socket, sys
try:
    print("\n".join(sorted({ai[4][0] for ai in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})))
except OSError:
    pass
PY
    fi
}

# is_local <host> : true if <host> names the machine we're running on. The
# designated master (CLUSTER_MASTER, the first host) is local by definition.
# Otherwise match by literal name/IP, then by resolving <host> to an IP and
# checking it against this machine's IPs — so an alias that points here is caught.
is_local() {
    [[ -n "$CLUSTER_MASTER" && "$1" == "$CLUSTER_MASTER" ]] && return 0
    case "$1" in
        localhost|127.0.0.1|"$(hostname)") return 0 ;;
    esac
    grep -qxF "$1" <<<"$_self_id" && return 0
    local ip
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && grep -qxF "$ip" <<<"$_self_id" && return 0
    done < <(_resolve "$1")
    return 1
}

# run_on <host> <command-string> : run the command on <host>. Local exec for the
# master (no SSH), passwordless SSH for every other node. Returns the command's
# own exit status so callers can branch on success/failure.
run_on() {
    local h="$1"; shift
    if is_local "$h"; then
        bash -c "$*"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER}${h}" "$*"
    fi
}

# hosts_from_hostfile <path> : print the host token (first field) of each real
# entry, one per line. Skips comments and blank lines.
hosts_from_hostfile() {
    grep -vE '^\s*(#|$)' "$1" | awk '{print $1}'
}

# total_slots_from_hostfile <path> : sum of every slots=N in the hostfile.
total_slots_from_hostfile() {
    grep -vE '^\s*(#|$)' "$1" | sed -n 's/.*slots=\([0-9]*\).*/\1/p' | paste -sd+ - | bc
}
