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

run_with_timeout() {
  local timeout_value="$1"
  shift

  timeout --preserve-status "$timeout_value" "$@"
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

permitted_clients() {
  local clients="${PERMITTED:-*}"
  local emitted=0
  local client

  clients="${clients//,/ }"
  set -f
  for client in $clients; do
    [ -n "$client" ] || continue
    printf '%s\n' "$client"
    emitted=1
  done
  set +f

  if [ "$emitted" -eq 0 ]; then
    printf '*\n'
  fi
}

client_specs() {
  local options="$1"
  local spec=""
  local client

  while IFS= read -r client; do
    spec+=" ${client}(${options})"
  done < <(permitted_clients)

  if [ -z "$spec" ]; then
    spec=" *(${options})"
  fi

  printf '%s' "$spec"
}

declare -a EXPORT_DIRECTORIES=()
declare -a EXPORT_OPTIONS=()

add_export() {
  local directory="$1"
  local options="$2"

  require_absolute_path "$directory"
  mkdir -p "$directory"
  printf '%s%s\n' "$directory" "$(client_specs "$options")" >> /etc/exports
  EXPORT_DIRECTORIES+=("$directory")
  EXPORT_OPTIONS+=("$options")
}

export_configured_exports() {
  local idx
  local directory
  local options
  local client

  for idx in "${!EXPORT_DIRECTORIES[@]}"; do
    directory="${EXPORT_DIRECTORIES[$idx]}"
    options="${EXPORT_OPTIONS[$idx]}"
    while IFS= read -r client; do
      log "exporting ${client}:${directory}"
      run_with_timeout "$NFS_EXPORTFS_TIMEOUT" exportfs -i -o "$options" "${client}:${directory}"
    done < <(permitted_clients)
  done
}

unexport_configured_exports() {
  local idx
  local directory
  local client

  for idx in "${!EXPORT_DIRECTORIES[@]}"; do
    directory="${EXPORT_DIRECTORIES[$idx]}"
    while IFS= read -r client; do
      log "unexporting ${client}:${directory}"
      run_with_timeout "$NFS_EXPORTFS_TIMEOUT" exportfs -u "${client}:${directory}" >/dev/null 2>&1 || true
    done < <(permitted_clients)
  done
}

stop() {
  log "stopping NFS server"
  unexport_configured_exports
  log "leaving kernel nfsd threads untouched; pod network namespace cleanup will drop listeners"
  pkill -TERM rpc.idmapd >/dev/null 2>&1 || true
  pkill -TERM rpc.mountd >/dev/null 2>&1 || true
  pkill -TERM rpcbind >/dev/null 2>&1 || true
  log "NFS server stopped"
}

trap 'stop; exit 0' SIGTERM SIGINT

SHARED_DIRECTORY="${SHARED_DIRECTORY:-/exports/share}"
NFS_THREADS="${NFS_THREADS:-16}"
NFS_EXPORTFS_TIMEOUT="${NFS_EXPORTFS_TIMEOUT:-15s}"

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
add_export "$SHARED_DIRECTORY" "$export_options"
if [ -n "${SHARED_DIRECTORY_2:-}" ]; then
  add_export "$SHARED_DIRECTORY_2" "$secondary_export_options"
fi

log "configured exports:"
cat /etc/exports

log "exporting filesystems"
export_configured_exports

log "starting rpcbind for local NFS RPC service registration"
rpcbind -w

log "starting rpc.idmapd for NFSv4 identity mapping"
rpc.idmapd

log "starting kernel nfsd with $NFS_THREADS threads (NFSv4.1/NFSv4.2 only, TCP only)"
rpc.nfsd \
  --no-udp \
  --no-nfs-version 3 \
  --nfs-version 4.1 \
  --nfs-version 4.2 \
  "$NFS_THREADS"

log "starting rpc.mountd for kernel export/auth cache upcalls"
rpc.mountd \
  --no-udp \
  --no-nfs-version 3 \
  --nfs-version 4.1 \
  --nfs-version 4.2

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
