#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*"
}

enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_absolute_path() {
  case "$1" in
    /*) return 0 ;;
    *) log "ERROR: path must be absolute: $1"; exit 1 ;;
  esac
}

mount_if_needed() {
  local target="$1"
  local type="$2"

  mkdir -p "$target"
  if ! grep -qs " $target " /proc/mounts; then
    log "mounting $type at $target"
    mount -t "$type" "$type" "$target"
  fi
}

client_specs() {
  local clients="${PERMITTED:-*}"
  local options="$1"
  local spec=""
  local client

  clients="${clients//,/ }"
  set -f
  for client in $clients; do
    [ -n "$client" ] || continue
    spec+=" ${client}(${options})"
  done
  set +f

  if [ -z "$spec" ]; then
    spec=" *(${options})"
  fi

  printf '%s' "$spec"
}

write_export() {
  local directory="$1"
  local options="$2"

  require_absolute_path "$directory"
  mkdir -p "$directory"
  printf '%s%s\n' "$directory" "$(client_specs "$options")" >> /etc/exports
}

stop() {
  log "stopping NFS server"
  exportfs -uav >/dev/null 2>&1 || true
  rpc.nfsd 0 >/dev/null 2>&1 || true
  log "NFS server stopped"
}

trap 'stop; exit 0' SIGTERM SIGINT

SHARED_DIRECTORY="${SHARED_DIRECTORY:-/exports/share}"
NFS_THREADS="${NFS_THREADS:-16}"

if ! [[ "$NFS_THREADS" =~ ^[0-9]+$ ]] || [ "$NFS_THREADS" -lt 1 ]; then
  log "ERROR: NFS_THREADS must be a positive integer, got: $NFS_THREADS"
  exit 1
fi

access="rw"
if enabled "${READ_ONLY:-}"; then
  access="ro"
fi

sync_mode="async"
if enabled "${SYNC:-}"; then
  sync_mode="sync"
fi

export_options="${NFS_EXPORT_OPTIONS:-$access,fsid=0,$sync_mode,no_subtree_check,no_auth_nlm,insecure,no_root_squash,crossmnt}"
secondary_export_options="${NFS_EXPORT_OPTIONS_2:-$access,$sync_mode,no_subtree_check,no_auth_nlm,insecure,no_root_squash}"

mount_if_needed /proc/fs/nfsd nfsd
mount_if_needed /var/lib/nfs/rpc_pipefs rpc_pipefs

: > /etc/exports
write_export "$SHARED_DIRECTORY" "$export_options"
if [ -n "${SHARED_DIRECTORY_2:-}" ]; then
  write_export "$SHARED_DIRECTORY_2" "$secondary_export_options"
fi

log "configured exports:"
cat /etc/exports

# Make startup idempotent when a container runtime retries quickly.
exportfs -uav >/dev/null 2>&1 || true
rpc.nfsd 0 >/dev/null 2>&1 || true

log "exporting filesystems"
exportfs -rav

log "starting kernel nfsd with $NFS_THREADS threads (NFSv4.1/NFSv4.2 only, TCP only)"
rpc.nfsd \
  --no-udp \
  --no-nfs-version 3 \
  --nfs-version 4.1 \
  --nfs-version 4.2 \
  "$NFS_THREADS"

if ! /usr/local/bin/healthcheck.sh; then
  log "ERROR: NFS server failed initial healthcheck"
  stop
  exit 1
fi

log "startup successful"

while sleep 5; do
  if ! /usr/local/bin/healthcheck.sh >/dev/null 2>&1; then
    log "ERROR: NFS server became unhealthy"
    stop
    exit 1
  fi
done
