#!/usr/bin/env sh
set -eu

threads_file=/proc/fs/nfsd/threads

if [ ! -r "$threads_file" ]; then
  echo "nfsd control file is not readable: $threads_file" >&2
  exit 1
fi

threads="$(cat "$threads_file" 2>/dev/null || echo 0)"
case "$threads" in
  ''|*[!0-9]*)
    echo "invalid nfsd thread count: $threads" >&2
    exit 1
    ;;
esac

if [ "$threads" -lt 1 ]; then
  echo "nfsd has no active kernel threads" >&2
  exit 1
fi

if ! pidof rpc.mountd >/dev/null 2>&1; then
  echo "rpc.mountd is not running" >&2
  exit 1
fi

if ! pidof rpc.idmapd >/dev/null 2>&1; then
  echo "rpc.idmapd is not running" >&2
  exit 1
fi

if ! exportfs -s >/tmp/exportfs.out 2>/tmp/exportfs.err; then
  cat /tmp/exportfs.err >&2 || true
  exit 1
fi

if ! [ -s /tmp/exportfs.out ]; then
  echo "no active NFS exports" >&2
  exit 1
fi

exit 0

