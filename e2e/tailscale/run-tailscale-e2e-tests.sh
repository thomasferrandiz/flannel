#!/bin/bash

set -e -o pipefail

source $(dirname $0)/../version.sh
source $(dirname $0)/../e2e-functions.sh

FLANNEL_NET="${FLANNEL_NET:-10.42.0.0/16}"
export FLANNEL_IMAGE="quay.io/coreos/flannel:${TAG}-${ARCH}"

# ──────────────────────────────────────────────
# Suite lifecycle
# ──────────────────────────────────────────────

setup_suite() {
    rm -rf $(dirname $0)/scratch
    mkdir -p $(dirname $0)/scratch
    cp $(dirname $0)/../../dist/${FLANNEL_IMAGE_FILE}.docker \
       $(dirname $0)/scratch/${FLANNEL_IMAGE_FILE}.tar

    # Generate self-signed TLS cert for headscale DERP relay.
    # The k3s node image (Dockerfile) copies headscale-ca.pem into the system
    # trust store so tailscale can verify the DERP server's TLS cert.
    local CERTS_DIR
    CERTS_DIR="$(dirname $0)/certs"
    mkdir -p "${CERTS_DIR}"
    openssl req -x509 -newkey rsa:2048 \
        -keyout "${CERTS_DIR}/headscale-server-key.pem" \
        -out    "${CERTS_DIR}/headscale-server-cert.pem" \
        -days 1 -nodes -subj '/CN=headscale' \
        -addext 'subjectAltName=DNS:headscale' 2>/dev/null
    cp "${CERTS_DIR}/headscale-server-cert.pem" "${CERTS_DIR}/headscale-ca.pem"

    pushd $(dirname $0) > /dev/null

    # Build node image without cache to ensure the updated flannel binary is used
    docker compose build --no-cache || { popd > /dev/null; return 1; }

    # Start headscale alone and wait for it to be healthy
    docker compose up headscale --detach --wait --wait-timeout 60 \
        || { echo "ERROR: headscale did not become healthy in time"; popd > /dev/null; return 1; }

    # Create user and generate a reusable preauthkey for both nodes
    docker exec tailscale-e2e-headscale \
        headscale users create flannel-test 2>/dev/null || true

    export TS_AUTHKEY=$(docker exec tailscale-e2e-headscale \
        headscale preauthkeys create \
            --user 1 \
            --reusable \
            --expiration 1h \
            -o json \
        | jq -r '.key')

    echo "Generated Headscale preauthkey: ${TS_AUTHKEY}"
    popd > /dev/null
}

setup() {
    pushd $(dirname $0) > /dev/null
    # TS_AUTHKEY is exported from setup_suite; docker compose reads it for ${TS_AUTHKEY}
    docker compose up ts-leader ts-worker --detach --wait --wait-timeout 300 \
        || { echo "ERROR: K3s nodes did not become ready in time"; popd > /dev/null; return 1; }
    popd > /dev/null

    $(dirname $0)/get-kubeconfig.sh
}

teardown() {
    pushd $(dirname $0) > /dev/null
    docker compose down \
        --remove-orphans \
        --rmi all \
        --volumes
    popd > /dev/null
}

# ──────────────────────────────────────────────
# Flannel manifest helpers
# ──────────────────────────────────────────────

write-flannel-conf-tailscale() {
    cp ../../Documentation/kube-flannel.yml ./kube-flannel.yml

    yq -i 'select(.kind == "DaemonSet").spec.template.spec.containers[0].image |= strenv(FLANNEL_IMAGE)' \
        ./kube-flannel.yml
    yq -i 'select(.kind == "DaemonSet").spec.template.spec.initContainers[1].image |= strenv(FLANNEL_IMAGE)' \
        ./kube-flannel.yml

    export flannel_conf="{ \"Network\": \"${FLANNEL_NET}\", \"Backend\": { \"Type\": \"tailscale\" }, \"EnableNFTables\": true }"
    yq -i 'select(.metadata.name == "kube-flannel-cfg").data."net-conf.json" |= strenv(flannel_conf)' \
        ./kube-flannel.yml

    # The flannel container needs access to the tailscaled socket on the host.
    yq -i 'select(.kind == "DaemonSet").spec.template.spec.volumes +=
        [{"name": "tailscale-socket", "hostPath": {"path": "/run/tailscale"}}]' \
        ./kube-flannel.yml
    yq -i 'select(.kind == "DaemonSet").spec.template.spec.containers[0].volumeMounts +=
        [{"name": "tailscale-socket", "mountPath": "/var/run/tailscale"}]' \
        ./kube-flannel.yml

    # tailscaled needs NET_ADMIN; add it on top of the existing capabilities
    yq -i 'select(.kind == "DaemonSet").spec.template.spec.containers[0].securityContext.capabilities.add +=
        ["SYS_ADMIN"]' \
        ./kube-flannel.yml
}

install-flannel() {
    kubectl --kubeconfig="${HOME}/.kube/config" apply -f ./kube-flannel.yml
}

delete-flannel() {
    kubectl --kubeconfig="${HOME}/.kube/config" delete -f ./kube-flannel.yml
}

# ──────────────────────────────────────────────
# Kubernetes helpers
# ──────────────────────────────────────────────

create_test_pod() {
    local pod_name=$1
    local worker_node=$2
    cat <<EOF | kubectl --kubeconfig="${HOME}/.kube/config" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
spec:
  containers:
  - name: ${pod_name}
    image: wbitt/network-multitool:alpine-extra
  nodeName: ${worker_node}
EOF
}

get_pod_ip() {
    kubectl --kubeconfig="${HOME}/.kube/config" get pod "$1" --template '{{.status.podIP}}'
}

get_pod_cidr() {
    kubectl --kubeconfig="${HOME}/.kube/config" get node "$1" --template '{{.spec.podCIDR}}'
}

get_pod_logs() {
    kubectl --kubeconfig="${HOME}/.kube/config" logs "$1" -n kube-flannel
}

# ──────────────────────────────────────────────
# Test assertions
# ──────────────────────────────────────────────

pings() {
    create_test_pod multitool1 ts-worker
    create_test_pod multitool2 ts-leader

    echo "Waiting for test pods to be ready..."
    timeout --foreground 2m bash -c "e2e-wait-for-test-pods"
    retVal=$?
    if [ $retVal -ne 0 ]; then
        echo "Test pods not ready in time. Checking status..."
        kubectl --kubeconfig="${HOME}/.kube/config" get events --sort-by='.lastTimestamp' -A
        echo "Flannel pod log:"
        flannel_pod=$(e2e-get-flannel-pod ts-worker)
        get_pod_logs "$flannel_pod"
        exit $retVal
    fi

    local ip_1 ip_2
    ip_1=$(get_pod_ip multitool1)
    ip_2=$(get_pod_ip multitool2)
    echo "multitool1 IP: ${ip_1}, multitool2 IP: ${ip_2}"

    timeout --foreground 2m bash -c "e2e-wait-for-ping multitool1 ${ip_2}" || {
        echo "=== Ping wait timed out — collecting diagnostics ==="
        debug_connectivity
    }
    assert "kubectl --kubeconfig=\"${HOME}/.kube/config\" exec multitool1 -- ping -c 5 ${ip_2}"
    assert "kubectl --kubeconfig=\"${HOME}/.kube/config\" exec multitool2 -- ping -c 5 ${ip_1}"
}

# Verify that Flannel has installed routes via tailscale0 on both nodes.
check_tailscale_routes() {
    local worker_podcidr leader_podcidr leader_ts_ip worker_ts_ip

    worker_podcidr=$(get_pod_cidr ts-worker)
    leader_podcidr=$(get_pod_cidr ts-leader)
    leader_ts_ip=$(docker exec tailscale-e2e-leader tailscale ip -4 2>/dev/null | head -1)
    worker_ts_ip=$(docker exec tailscale-e2e-worker tailscale ip -4 2>/dev/null | head -1)

    echo "ts-leader pod CIDR: ${leader_podcidr}, Tailscale IP: ${leader_ts_ip}"
    echo "ts-worker pod CIDR: ${worker_podcidr}, Tailscale IP: ${worker_ts_ip}"

    # On the worker node: a route for the leader's pod CIDR must exist via the
    # leader's Tailscale IP on the tailscale0 interface.
    assert \
        "docker exec --privileged tailscale-e2e-worker \
            ip route show | grep -q '${leader_podcidr}'" \
        "Worker has no route for leader pod CIDR via tailscale0"
    assert \
        "docker exec --privileged tailscale-e2e-worker \
            ip route show | grep '${leader_podcidr}' | grep -q 'tailscale0'" \
        "Worker route for leader pod CIDR does not use tailscale0"

    # On the leader node: a route for the worker's pod CIDR must exist via the
    # worker's Tailscale IP on the tailscale0 interface.
    assert \
        "docker exec --privileged tailscale-e2e-leader \
            ip route show | grep -q '${worker_podcidr}'" \
        "Leader has no route for worker pod CIDR via tailscale0"
    assert \
        "docker exec --privileged tailscale-e2e-leader \
            ip route show | grep '${worker_podcidr}' | grep -q 'tailscale0'" \
        "Leader route for worker pod CIDR does not use tailscale0"
}

debug_connectivity() {
    echo "--- tailscale status (leader) ---"
    docker exec tailscale-e2e-leader tailscale status 2>/dev/null || true
    echo "--- tailscale status (worker) ---"
    docker exec tailscale-e2e-worker tailscale status 2>/dev/null || true
    echo "--- tailscale AllowedIPs (leader) ---"
    docker exec tailscale-e2e-leader tailscale status --json 2>/dev/null \
        | jq '.Peer | to_entries[] | {host: .value.HostName, allowed: .value.AllowedIPs}' 2>/dev/null || true
    echo "--- tailscale AllowedIPs (worker) ---"
    docker exec tailscale-e2e-worker tailscale status --json 2>/dev/null \
        | jq '.Peer | to_entries[] | {host: .value.HostName, allowed: .value.AllowedIPs}' 2>/dev/null || true
    echo "--- tailscale derp-map (leader) ---"
    docker exec tailscale-e2e-leader tailscale debug derp-map 2>/dev/null || true
    echo "--- tailscale netcheck (leader) ---"
    docker exec tailscale-e2e-leader tailscale netcheck 2>/dev/null || true
    echo "--- tailscale ping leader→worker ---"
    docker exec tailscale-e2e-leader tailscale ping -c 3 100.64.0.2 2>/dev/null || true
    echo "--- tailscale ping worker→leader ---"
    docker exec tailscale-e2e-worker tailscale ping -c 3 100.64.0.1 2>/dev/null || true
    echo "--- ip route (leader) ---"
    docker exec tailscale-e2e-leader ip route show 2>/dev/null || true
    echo "--- ip route (worker) ---"
    docker exec tailscale-e2e-worker ip route show 2>/dev/null || true
    echo "--- flannel logs (leader) ---"
    local fp
    fp=$(kubectl --kubeconfig="${HOME}/.kube/config" get pods \
        --field-selector "spec.nodeName=ts-leader" -n kube-flannel \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
    [ -n "$fp" ] && kubectl --kubeconfig="${HOME}/.kube/config" logs "$fp" -n kube-flannel 2>/dev/null || true
    echo "--- flannel logs (worker) ---"
    fp=$(kubectl --kubeconfig="${HOME}/.kube/config" get pods \
        --field-selector "spec.nodeName=ts-worker" -n kube-flannel \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
    [ -n "$fp" ] && kubectl --kubeconfig="${HOME}/.kube/config" logs "$fp" -n kube-flannel 2>/dev/null || true
}

approve_headscale_routes() {
    echo "Waiting for Tailscale subnet routes to appear in Headscale..."

    # Phase 1: poll until at least one node has advertised routes (up to 150 s)
    local attempts=0 raw=""
    while [ "$attempts" -lt 30 ]; do
        raw=$(docker exec tailscale-e2e-headscale \
            headscale nodes list-routes -o json 2>/dev/null || true)
        local count
        count=$(echo "$raw" | jq '[.[] | select((.available_routes // []) | length > 0)] | length' 2>/dev/null || echo "0")
        if [ "${count:-0}" -gt 0 ]; then
            echo "Routes found ($count node(s) advertising)"
            break
        fi
        attempts=$((attempts + 1))
        if [ "$((attempts % 5))" -eq 0 ]; then
            echo "headscale nodes list-routes: ${raw:-<empty>}"
            local fp
            fp=$(kubectl --kubeconfig="${HOME}/.kube/config" get pods \
                --field-selector "spec.nodeName=ts-worker" -n kube-flannel \
                --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
            if [ -n "$fp" ]; then
                echo "Flannel logs (ts-worker):"
                kubectl --kubeconfig="${HOME}/.kube/config" logs "$fp" \
                    -n kube-flannel --tail=20 2>/dev/null || true
            fi
        fi
        echo "No routes yet (attempt $attempts/30)..."
        sleep 5
    done

    if [ "$attempts" -ge 30 ]; then
        echo "ERROR: no Tailscale subnet routes appeared after 150 s" >&2
        return 1
    fi

    # Phase 2: three approval passes spaced 10 s apart to catch all nodes.
    # We never test enabled_routes because headscale v0.28 doesn't update that
    # field in list-routes output after approve-routes is called.
    for pass in 1 2 3; do
        sleep 10
        raw=$(docker exec tailscale-e2e-headscale \
            headscale nodes list-routes -o json 2>/dev/null || true)
        echo "Approval pass $pass/3:"
        local found=0
        while IFS=$'\t' read -r node_id routes; do
            [ -z "$node_id" ] && continue
            echo "  node $node_id -> $routes"
            docker exec tailscale-e2e-headscale \
                headscale nodes approve-routes \
                    --identifier "$node_id" \
                    --routes "$routes" \
                    --force 2>&1 || true
            found=$((found + 1))
        done < <(echo "$raw" | jq -r \
            '.[] | select((.available_routes // []) | length > 0) |
             [(.id | tostring), ((.available_routes // []) | join(","))] | @tsv' \
            2>/dev/null)
        echo "  approved $found node(s)"
    done

    echo "Route approval complete; waiting for propagation..."
    sleep 15
    return 0
}

prepare_test() {
    write-flannel-conf-tailscale
    install-flannel

    echo "Waiting for nodes to be ready..."
    timeout --foreground 5m bash -c "e2e-wait-for-nodes"
    retVal=$?
    if [ $retVal -ne 0 ]; then
        echo "Nodes not ready in time. Checking status..."
        kubectl --kubeconfig="${HOME}/.kube/config" get events --sort-by='.lastTimestamp' -A
        echo "Flannel pod log:"
        flannel_pod=$(e2e-get-flannel-pod ts-worker)
        get_pod_logs "$flannel_pod"
        exit $retVal
    fi

    approve_headscale_routes

    echo "Forcing direct WireGuard session establishment..."
    for i in $(seq 1 24); do
        leader_out=$(docker exec tailscale-e2e-leader tailscale ping -c 1 --timeout 5s 100.64.0.2 2>/dev/null || true)
        worker_out=$(docker exec tailscale-e2e-worker tailscale ping -c 1 --timeout 5s 100.64.0.1 2>/dev/null || true)
        leader_ok=false
        worker_ok=false
        echo "$leader_out" | grep -q "pong" && ! echo "$leader_out" | grep -qi "derp\|relay" && leader_ok=true || true
        echo "$worker_out" | grep -q "pong" && ! echo "$worker_out" | grep -qi "derp\|relay" && worker_ok=true || true
        if $leader_ok && $worker_ok; then
            echo "Both nodes have direct connections (attempt $i)"
            echo "  leader→worker: ${leader_out}"
            echo "  worker→leader: ${worker_out}"
            break
        fi
        echo "Direct connection not ready (attempt $i/24)"
        echo "  leader→worker: ${leader_out:-<no output>}"
        echo "  worker→leader: ${worker_out:-<no output>}"
        sleep 5
    done

    echo "Waiting for services to be ready..."
    timeout --foreground 5m bash -c "e2e-wait-for-services"
}

# ──────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────

test_tailscale() {
    prepare_test
    pings
    check_tailscale_routes
    delete-flannel
}
