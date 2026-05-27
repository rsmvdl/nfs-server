FROM alpine:3.22.0

# Metadata
LABEL org.opencontainers.image.title="NFS Server"
LABEL org.opencontainers.image.description="Small Kubernetes-oriented kernel NFSv4 server for one-PVC-per-server RWX volumes"
LABEL org.opencontainers.image.source="https://github.com/rsmvdl/nfs-server"
LABEL org.opencontainers.image.vendor="rsmvdl"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install required packages and clean up
RUN apk add --no-cache bash coreutils nfs-utils tini \
 && rm -rf /var/cache/apk/* /tmp/* /sbin/halt /sbin/poweroff /sbin/reboot \
 && mkdir -p /exports/share /proc/fs/nfsd /var/lib/nfs/rpc_pipefs /var/lib/nfs/v4recovery /run/rpcbind \
 && touch /etc/exports \
 && echo "rpc_pipefs /var/lib/nfs/rpc_pipefs rpc_pipefs defaults 0 0" >> /etc/fstab \
 && echo "nfsd /proc/fs/nfsd nfsd defaults 0 0" >> /etc/fstab

# Copy configuration and entrypoint
COPY nfsd.sh /usr/local/bin/nfsd.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/nfsd.sh /usr/local/bin/healthcheck.sh

# NFSv4 clients only need TCP/2049. NFSv3/rpcbind/mountd ports are intentionally
# not exposed because the RWX provisioner mounts with `vers=4.1`.
EXPOSE 2049/tcp

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/nfsd.sh"]
