#!/usr/bin/env bash
# Weekly homelab update: OS packages, ZFS kernel module check, Docker images,
# then reboot if the update requires it.
#
# Run as root. Scheduled by scripts/homelab-update.cron.
# Log: /var/log/homelab-update.log
#
# Usage: update.sh [--no-reboot]

set -uo pipefail

STACKS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LOG=/var/log/homelab-update.log
REBOOT=1
[[ "${1:-}" == "--no-reboot" ]] && REBOOT=0

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
    echo "update.sh must run as root" >&2
    exit 1
fi

exec >>"$LOG" 2>&1

# Prevent overlapping runs
exec 9>/run/homelab-update.lock
flock -n 9 || { echo "[$(date '+%F %T')] another update is running, exiting"; exit 1; }

log() { echo "[$(date '+%F %T')] $*"; }
errors=0

log "===== Update started"

# --- 1. OS packages -----------------------------------------------------------
log "Updating OS packages"
if apt-get update -q &&
   apt-get full-upgrade -y -q \
       -o Dpkg::Options::=--force-confdef \
       -o Dpkg::Options::=--force-confold &&
   apt-get autoremove -y -q --purge; then
    log "OS packages updated"
else
    log "ERROR: apt upgrade failed"
    errors=$((errors + 1))
fi

# --- 2. ZFS module for the newest kernel --------------------------------------
# A kernel upgrade without a rebuilt ZFS module leaves the pool unable to
# import on the next boot. Verify the module exists before allowing a reboot.
latest_kernel=$(ls /lib/modules | sort -V | tail -n1)
zfs_ok=1
if ! find "/lib/modules/$latest_kernel" -name 'zfs.ko*' -print -quit | grep -q .; then
    log "ZFS module missing for kernel $latest_kernel, running dkms autoinstall"
    dkms autoinstall -k "$latest_kernel"
    if ! find "/lib/modules/$latest_kernel" -name 'zfs.ko*' -print -quit | grep -q .; then
        log "CRITICAL: ZFS module still missing for $latest_kernel, reboot blocked"
        zfs_ok=0
        errors=$((errors + 1))
    fi
fi
[[ $zfs_ok -eq 1 ]] && log "ZFS module present for kernel $latest_kernel"

# --- 3. Docker stacks ----------------------------------------------------------
# Pull everything first: recreating Pi-hole interrupts DNS, which would break
# pulls for stacks that come after it.
stacks=("$STACKS_DIR"/*/docker-compose.yml)
for compose in "${stacks[@]}"; do
    stack=$(basename "$(dirname "$compose")")
    log "Pulling images: $stack"
    if ! docker compose -f "$compose" pull -q; then
        log "ERROR: failed to pull images for $stack"
        errors=$((errors + 1))
    fi
done

for compose in "${stacks[@]}"; do
    stack=$(basename "$(dirname "$compose")")
    log "Restarting changed containers: $stack"
    if ! docker compose -f "$compose" up -d --remove-orphans; then
        log "ERROR: failed to bring up $stack"
        errors=$((errors + 1))
    fi
done

log "Pruning unused images"
docker image prune -f

# --- 4. Reboot if required -----------------------------------------------------
if [[ -f /var/run/reboot-required ]]; then
    if [[ $REBOOT -eq 0 ]]; then
        log "Reboot required but --no-reboot was given"
    elif [[ $zfs_ok -eq 0 ]]; then
        log "Reboot required but skipped: ZFS module not ready"
    else
        log "Reboot required, rebooting (errors: $errors)"
        systemctl reboot
        exit 0
    fi
fi

log "===== Update finished (errors: $errors)"
exit $((errors > 0))
