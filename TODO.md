Files created in e2e/tailscale/:

File	Purpose
headscale-config.yaml	Headscale control plane config — embedded DERP server enabled, SQLite DB, CGNAT prefix 100.64.0.0/10, no TLS
k3s-entrypoint.sh	Container boot script: starts tailscaled, authenticates via preauthkey, waits for Running state, then execs K3s
Dockerfile	Extends the SLES base (same as e2e/Dockerfile) with K3s + CNI + Tailscale static binaries
docker-compose.yml	Three services on a shared bridge: headscale, ts-leader (K3s server), ts-worker (K3s agent); nodes depend on headscale being healthy
get-kubeconfig.sh	Reads kubeconfig from tailscale-e2e-leader container
run-tailscale-e2e-tests.sh	bash_unit test suite: starts Headscale first, generates a reusable preauthkey, then brings up K3s nodes; test_tailscale verifies pod-to-pod ping and checks that Flannel installed routes via tailscale0
Makefile updated — new tailscale-e2e-test target: make tailscale-e2e-test.

Two things to action before the first run:

Tailscale SHA256: The Dockerfile downloads Tailscale 1.68.2 without hash verification. Add per-arch SHA256s once you pin the version (the TODO comment marks the spot).
kube-flannel.yml socket mount: The write-flannel-conf-tailscale function patches the DaemonSet to mount /run/tailscale from the host so the flannel pod can reach tailscaled. Verify this path matches where tailscaled.sock lands in your kernel version (/run/tailscale/tailscaled.sock vs /var/run/tailscale/tailscaled.sock — they're the same via symlink on most distros).