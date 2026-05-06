#!/bin/bash
# Starts tailscaled, authenticates to Headscale, then starts K3s.

set -e

mkdir -p /var/lib/tailscale /var/run/tailscale

tailscaled \
    --tun=tailscale0 \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    &
TAILSCALED_PID=$!

echo "Waiting for tailscaled socket..."
for i in $(seq 1 30); do
    if [ -S /var/run/tailscale/tailscaled.sock ]; then
        echo "tailscaled socket ready"
        break
    fi
    sleep 1
    if [ "$i" -eq 30 ]; then
        echo "ERROR: tailscaled socket not ready after 30 seconds" >&2
        exit 1
    fi
done

echo "Authenticating to Headscale..."
tailscale up \
    --login-server=https://headscale:8080 \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${HOSTNAME}" \
    --accept-routes \
    --accept-dns=false

echo "Waiting for Tailscale Running state..."
for i in $(seq 1 60); do
    STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)
    if [ "${STATE}" = "Running" ]; then
        echo "Tailscale is Running, IPv4: $(tailscale ip -4)"
        break
    fi
    echo "Current state: ${STATE:-unknown}, waiting..."
    sleep 2
    if [ "$i" -eq 60 ]; then
        echo "ERROR: Tailscale not Running after 120 seconds" >&2
        exit 1
    fi
done

echo 1 > /proc/sys/net/ipv4/ip_forward

cleanup() {
    kill "${TAILSCALED_PID}" 2>/dev/null || true
}
trap cleanup EXIT

exec k3s "$@"
