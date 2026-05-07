ARG SLES="registry.suse.com/suse/sle15:15.7"
FROM ${SLES} AS k3s-tailscale

ARG ARCH
ARG K3S_VERSION="v1.34.6+k3s1"
ARG CNI_VERSION="v1.9.1"
# Update TAILSCALE_VERSION and the SHA256 sums below when bumping.
ARG TAILSCALE_VERSION="1.96.4"

RUN set -e -x \
 && zypper -n in \
    ca-certificates \
    curl \
    tar gzip \
    iptables \
    nftables \
    iproute2 \
    iputils \
    jq

# Install K3s
RUN set -e -x \
 && if [ "${ARCH?required}" != "amd64" ]; then \
        K3S_SUFFIX="-${ARCH}"; \
    fi \
 && K3S_BIN="k3s${K3S_SUFFIX}" \
 && case "${ARCH}" in \
      amd64) K3S_SHA256="7c81556ac1212213a07180f92eca57db8caef886e58bbad15e9dada10782c10d" ;; \
      arm)   K3S_SHA256="5a53717e45db133408cecc7dfe4f42f076e71333df0ca0a44b79ff1568a5ee36" ;; \
      arm64) K3S_SHA256="2695afc60eea47880ba71c9a01412693b2246c1c76623a352a727db566a6d8b5" ;; \
      *) echo "unsupported ARCH: ${ARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/rancher/k3s/releases/download/${K3S_VERSION}/${K3S_BIN}" -o /bin/k3s \
 && { printf '%s  %s\n' "${K3S_SHA256}" "/bin/k3s" | sha256sum -c - || { echo "ERROR: K3S checksum failed for ${ARCH}"; exit 1; }; } \
 && chmod +x /bin/k3s \
 && ln -s /bin/k3s /bin/kubectl \
 && ln -s /bin/k3s /bin/ctr \
 && k3s --version

# Install CNI plugins
RUN set -e -x \
 && mkdir -p /opt/cni/bin \
 && CNI_TGZ="cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz" \
 && case "${ARCH}" in \
      amd64) CNI_SHA256="b98f74a0f8522f0a83867178729c1aa70f2158f90c45a2ca8fa791db1c76b303" ;; \
      arm)   CNI_SHA256="21416880bea0541d78afaf106373d6dbb471edb92c0114fa263494fe4aec8d3b" ;; \
      arm64) CNI_SHA256="56171987d3947707c3563db2f4001bccaf50fd63468611b9f3cbecb1375ee7ec" ;; \
      *) echo "unsupported ARCH for CNI plugins: ${ARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/${CNI_TGZ}" -o "/tmp/${CNI_TGZ}" \
 && { printf '%s  %s\n' "${CNI_SHA256}" "/tmp/${CNI_TGZ}" | sha256sum -c - || { echo "ERROR: CNI plugins checksum failed for ${ARCH}"; exit 1; }; } \
 && tar -xzf "/tmp/${CNI_TGZ}" -C /opt/cni/bin \
 && rm -f "/tmp/${CNI_TGZ}"

# Install Tailscale static binaries.
# TODO: add per-arch SHA256 verification once a version is agreed upon (see K3s/CNI blocks above).
RUN set -e -x \
 && case "${ARCH}" in \
      amd64|arm|arm64) ;; \
      *) echo "unsupported ARCH for Tailscale: ${ARCH}" >&2; exit 1 ;; \
    esac \
 && TS_TGZ="tailscale_${TAILSCALE_VERSION}_${ARCH}.tgz" \
 && curl -fsSL "https://pkgs.tailscale.com/stable/${TS_TGZ}" -o "/tmp/${TS_TGZ}" \
 && tar -xzf "/tmp/${TS_TGZ}" -C /tmp \
 && install -m 0755 "/tmp/tailscale_${TAILSCALE_VERSION}_${ARCH}/tailscale"  /usr/local/bin/tailscale \
 && install -m 0755 "/tmp/tailscale_${TAILSCALE_VERSION}_${ARCH}/tailscaled" /usr/local/bin/tailscaled \
 && rm -rf "/tmp/tailscale_${TAILSCALE_VERSION}_${ARCH}" "/tmp/${TS_TGZ}" \
 && tailscale version

COPY scratch/*.tar /var/lib/rancher/k3s/agent/images/

COPY k3s-entrypoint.sh /usr/local/bin/k3s-entrypoint.sh
RUN chmod +x /usr/local/bin/k3s-entrypoint.sh

VOLUME /var/lib/cni
VOLUME /var/lib/kubelet
VOLUME /var/lib/rancher/k3s
VOLUME /var/log

ENTRYPOINT ["/usr/local/bin/k3s-entrypoint.sh"]
CMD ["server"]
