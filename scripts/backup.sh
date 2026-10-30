#!/usr/bin/env bash
# Nightly backup of application config and databases from /opt/docker, plus
# each stack's .env secrets. Keeps 7 daily and 4 weekly archives.
#
# Caches, logs, artwork and thumbnails are skipped: the apps rebuild them.
# Immich's database is exported with pg_dumpall and Pi-hole's settings with its
# Teleporter export, so neither needs to stop. Apps that use SQLite are stopped
# for the minute it takes to archive them, so their databases are consistent.
#
# Run as root. Scheduled by scripts/homelab-backup.cron.
# Log: /var/log/homelab-backup.log

set -uo pipefail

STACKS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DATA_DIR=/opt/docker
DEST=/storage/backups
LOG=/var/log/homelab-backup.log
KEEP_DAILY=7
KEEP_WEEKLY=4
WEEKLY_DAY=7    # day of week (date +%u) whose backup is also kept as weekly; 7 = Sunday

# Containers with SQLite databases, stopped while their data is archived
SQLITE_CONTAINERS=(plex radarr sonarr prowlarr seerr)

PLEX_DIR="opt/docker/plex/config/Library/Application Support/Plex Media Server"
EXCLUDES=(
    --exclude='opt/docker/immich/pgdata'        # exported with pg_dumpall instead
    --exclude='opt/docker/pihole'               # exported with Teleporter instead
    --exclude="$PLEX_DIR/Cache"
    --exclude="$PLEX_DIR/Codecs"
    --exclude="$PLEX_DIR/Crash Reports"
    --exclude="$PLEX_DIR/Diagnostics"
    --exclude="$PLEX_DIR/Logs"
    --exclude="$PLEX_DIR/Media"                 # video thumbnails, regenerated
    --exclude="$PLEX_DIR/Metadata"              # posters and artwork, re-downloaded
    --exclude="$PLEX_DIR/Plug-in Support/Caches"
    --exclude="$PLEX_DIR/Scanners/Credits"      # credit-detection model, re-downloaded
    --exclude="$PLEX_DIR/Updates"
    --exclude='*.db-20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]'  # Plex's own database copies
    --exclude='opt/docker/*/config/MediaCover'  # Radarr/Sonarr cover art
    --exclude='opt/docker/*/config/Backups'     # *arr built-in backups
    --exclude='opt/docker/*/config/logs'
    --exclude='opt/docker/*/config/logs.db*'
    --exclude='*.pid'
)

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [[ $EUID -ne 0 ]]; then
    echo "backup.sh must run as root" >&2
    exit 1
fi

exec >>"$LOG" 2>&1

exec 9>/run/homelab-backup.lock
flock -n 9 || { echo "[$(date '+%F %T')] another backup is running, exiting"; exit 1; }

log() { echo "[$(date '+%F %T')] $*"; }

log "===== Backup started"

# Never write backups onto the OS disk if the pool isn't mounted
if ! mountpoint -q /storage; then
    log "ERROR: /storage is not mounted, aborting"
    exit 1
fi

stamp=$(date +%F)
staging=$(mktemp -d)
archive="$DEST/daily/homelab-$stamp.tar.zst"
stopped=()

cleanup() {
    if ((${#stopped[@]})); then
        log "Starting containers: ${stopped[*]}"
        docker start "${stopped[@]}" >/dev/null || log "ERROR: failed to restart ${stopped[*]}"
        stopped=()
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

mkdir -p "$DEST/daily" "$DEST/weekly"
chmod 700 "$DEST"

# --- 1. Exports that don't need downtime ---------------------------------------
log "Exporting Immich database"
if ! docker exec immich-postgres sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' |
        zstd -q -o "$staging/immich-db.sql.zst"; then
    log "ERROR: Immich database export failed, aborting"
    exit 1
fi

log "Exporting Pi-hole settings"
if ! docker exec pihole sh -c 'd=$(mktemp -d) && cd "$d" && pihole-FTL --teleporter >/dev/null && cat ./*.zip; rc=$?; rm -rf "$d"; exit $rc' \
        >"$staging/pihole-teleporter.zip"; then
    log "ERROR: Pi-hole export failed, aborting"
    exit 1
fi

log "Copying .env files"
mkdir -p "$staging/env"
for env in "$STACKS_DIR"/*/.env "$STACKS_DIR"/*/*/.env; do
    [[ -f $env ]] || continue
    rel=${env#"$STACKS_DIR"/}
    install -Dm600 "$env" "$staging/env/$rel"
done

# --- 2. Archive, with SQLite apps stopped -------------------------------------
for c in "${SQLITE_CONTAINERS[@]}"; do
    if [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]]; then
        stopped+=("$c")
    fi
done
if ((${#stopped[@]})); then
    log "Stopping containers: ${stopped[*]}"
    docker stop "${stopped[@]}" >/dev/null
fi

log "Writing $archive"
tar --zstd -cf "$archive.part" "${EXCLUDES[@]}" \
    -C / "${DATA_DIR#/}" \
    -C "$staging" .
tar_rc=$?

cleanup
trap - EXIT

# tar exits 1 when a file changed while being read, which is harmless here
if ((tar_rc > 1)) || ! zstd -tq "$archive.part"; then
    log "ERROR: archive failed (tar exit $tar_rc), keeping previous backups"
    rm -f "$archive.part"
    exit 1
fi
mv "$archive.part" "$archive"
chmod 600 "$archive"
log "Archive written: $(du -h "$archive" | cut -f1)"

# --- 3. Weekly copy and rotation -----------------------------------------------
if [[ $(date +%u) == "$WEEKLY_DAY" ]]; then
    ln -f "$archive" "$DEST/weekly/"
    log "Kept as weekly backup"
fi

prune() {
    local dir=$1 keep=$2
    ls -1t "$dir"/homelab-*.tar.zst 2>/dev/null | tail -n +$((keep + 1)) | while read -r old; do
        log "Removing old backup $old"
        rm -f "$old"
    done
}
prune "$DEST/daily" "$KEEP_DAILY"
prune "$DEST/weekly" "$KEEP_WEEKLY"

log "===== Backup finished ($(du -sh "$DEST" | cut -f1) total in $DEST)"
