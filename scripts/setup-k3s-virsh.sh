#!/bin/bash
set -euo pipefail

# Configuration
KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-ygdb}"
VM_PREFIX="${VM_PREFIX:-ygdb}"
CONTROL_CPUS="${CONTROL_CPUS:-4}"
CONTROL_MEMORY="${CONTROL_MEMORY:-8192}"
WORKER_CPUS="${WORKER_CPUS:-4}"
WORKER_MEMORY="${WORKER_MEMORY:-8192}"
DISK_SIZE="${DISK_SIZE:-20G}"
WORKER_COUNT="${WORKER_COUNT:-3}"
NETWORK="${NETWORK:-default}"
OS_VARIANT="${OS_VARIANT:-ubuntu24.04}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/.vms"
CLOUD_IMG="$VM_DIR/ubuntu-24.04-cloudimg.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"

SSH_KEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

echo "=== YugabyteDB Performance Tuning Lab Setup (virsh + k3s) ==="
echo "VMs: 1 control ($CONTROL_CPUS CPU / ${CONTROL_MEMORY}MB) + $WORKER_COUNT workers ($WORKER_CPUS CPU / ${WORKER_MEMORY}MB)"
echo "Kube context: $KUBE_CONTEXT"
echo ""

# --- Prerequisites ---
echo "Checking prerequisites..."
for cmd in virsh virt-install qemu-img genisoimage kubectl helm; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required but not installed." >&2; exit 1; }
done

if [ -z "$SSH_KEY" ]; then
    echo "ERROR: No SSH public key found (~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)" >&2
    exit 1
fi

# --- Cloud image ---
mkdir -p "$VM_DIR"
if [ ! -f "$CLOUD_IMG" ]; then
    echo "Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress -O "$CLOUD_IMG" "$CLOUD_IMG_URL"
fi

# --- VM creation ---
create_vm() {
    local name="$1"
    local cpus="$2"
    local memory="$3"

    # Skip if already running
    if virsh domstate "$name" 2>/dev/null | grep -q "running"; then
        echo "  $name: already running, skipping"
        return 0
    fi

    # Clean up if exists but not running
    if virsh dominfo "$name" &>/dev/null; then
        echo "  $name: exists but not running, recreating..."
        virsh destroy "$name" 2>/dev/null || true
        virsh undefine "$name" --remove-all-storage 2>/dev/null || true
    fi

    echo "  $name: creating VM ($cpus CPU, ${memory}MB RAM, $DISK_SIZE disk)..."

    # Create disk from cloud image
    cp "$CLOUD_IMG" "$VM_DIR/${name}.qcow2"
    qemu-img resize "$VM_DIR/${name}.qcow2" "$DISK_SIZE" >/dev/null 2>&1

    # Generate cloud-init
    mkdir -p "/tmp/cloud-init-${name}"
    cat > "/tmp/cloud-init-${name}/user-data" << EOF
#cloud-config
hostname: ${name}
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_KEY}
packages:
  - dmsetup
package_update: true
EOF

    cat > "/tmp/cloud-init-${name}/meta-data" << EOF
instance-id: ${name}
local-hostname: ${name}
EOF

    genisoimage -output "$VM_DIR/${name}-cidata.iso" \
        -volid cidata -joliet -rock -input-charset utf-8 \
        "/tmp/cloud-init-${name}/user-data" "/tmp/cloud-init-${name}/meta-data" \
        >/dev/null 2>&1

    rm -rf "/tmp/cloud-init-${name}"

    # Create VM
    virt-install \
        --name "$name" \
        --memory "$memory" \
        --vcpus "$cpus" \
        --disk "path=$VM_DIR/${name}.qcow2,format=qcow2,cache=none,io=native" \
        --disk "path=$VM_DIR/${name}-cidata.iso,device=cdrom" \
        --os-variant "$OS_VARIANT" \
        --network "network=$NETWORK" \
        --graphics none \
        --noautoconsole \
        --import \
        >/dev/null 2>&1

    echo "  $name: VM created"
}

echo ""
echo "Creating VMs..."
create_vm "${VM_PREFIX}-control" "$CONTROL_CPUS" "$CONTROL_MEMORY"
for i in $(seq 1 "$WORKER_COUNT"); do
    create_vm "${VM_PREFIX}-worker-${i}" "$WORKER_CPUS" "$WORKER_MEMORY"
done

# --- Wait for IPs ---
get_vm_ip() {
    local name="$1"
    virsh domifaddr "$name" 2>/dev/null | grep ipv4 | awk '{print $4}' | cut -d/ -f1 || true
}

echo ""
echo "Waiting for VMs to get IP addresses..."
ALL_VMS="${VM_PREFIX}-control"
for i in $(seq 1 "$WORKER_COUNT"); do
    ALL_VMS="$ALL_VMS ${VM_PREFIX}-worker-${i}"
done

declare -A VM_IPS
for vm in $ALL_VMS; do
    for attempt in $(seq 1 30); do
        ip=$(get_vm_ip "$vm")
        if [ -n "$ip" ]; then
            VM_IPS[$vm]="$ip"
            echo "  $vm: $ip"
            break
        fi
        [ "$attempt" -eq 30 ] && { echo "ERROR: $vm did not get an IP after 30 attempts" >&2; exit 1; }
        sleep 2
    done
done

CONTROL_IP="${VM_IPS[${VM_PREFIX}-control]}"

# --- Wait for SSH ---
echo ""
echo "Waiting for SSH access..."
for vm in $ALL_VMS; do
    ip="${VM_IPS[$vm]}"
    for attempt in $(seq 1 30); do
        if ssh $SSH_OPTS "ubuntu@${ip}" "true" 2>/dev/null; then
            echo "  $vm ($ip): SSH OK"
            break
        fi
        [ "$attempt" -eq 30 ] && { echo "ERROR: SSH to $vm ($ip) failed after 30 attempts" >&2; exit 1; }
        sleep 5
    done
done

# --- Wait for cloud-init to finish ---
echo ""
echo "Waiting for cloud-init to complete..."
for vm in $ALL_VMS; do
    ip="${VM_IPS[$vm]}"
    ssh $SSH_OPTS "ubuntu@${ip}" "cloud-init status --wait" >/dev/null 2>&1
    echo "  $vm: cloud-init done"
done

# --- Install k3s server ---
echo ""
echo "Installing k3s server on ${VM_PREFIX}-control..."
ssh $SSH_OPTS "ubuntu@${CONTROL_IP}" "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable=traefik' sh -" >/dev/null 2>&1
echo "  k3s server installed"

# Get join token
K3S_TOKEN=$(ssh $SSH_OPTS "ubuntu@${CONTROL_IP}" "sudo cat /var/lib/rancher/k3s/server/node-token")
K3S_URL="https://${CONTROL_IP}:6443"

# --- Install k3s agents ---
echo ""
echo "Installing k3s agents on workers..."
for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    ip="${VM_IPS[$vm]}"
    echo "  $vm ($ip)..."
    ssh $SSH_OPTS "ubuntu@${ip}" \
        "curl -sfL https://get.k3s.io | K3S_URL='${K3S_URL}' K3S_TOKEN='${K3S_TOKEN}' sh -" \
        >/dev/null 2>&1
    echo "  $vm: k3s agent installed"
done

# --- Export kubeconfig ---
echo ""
echo "Configuring kubeconfig (context: $KUBE_CONTEXT)..."
KUBECONFIG_RAW=$(ssh $SSH_OPTS "ubuntu@${CONTROL_IP}" "sudo cat /etc/rancher/k3s/k3s.yaml")

# Write to a temp file and merge
TMPKUBE=$(mktemp)
echo "$KUBECONFIG_RAW" | sed \
    -e "s|server: https://127.0.0.1:6443|server: https://${CONTROL_IP}:6443|" \
    -e "s|name: default|name: ${KUBE_CONTEXT}|g" \
    -e "s|cluster: default|cluster: ${KUBE_CONTEXT}|g" \
    -e "s|user: default|user: ${KUBE_CONTEXT}|g" \
    -e "s|current-context: default|current-context: ${KUBE_CONTEXT}|" \
    > "$TMPKUBE"

# Merge into existing kubeconfig
if [ -f ~/.kube/config ]; then
    # Remove old context if it exists
    kubectl config delete-context "$KUBE_CONTEXT" 2>/dev/null || true
    kubectl config delete-cluster "$KUBE_CONTEXT" 2>/dev/null || true
    kubectl config delete-user "$KUBE_CONTEXT" 2>/dev/null || true

    KUBECONFIG=~/.kube/config:${TMPKUBE} kubectl config view --flatten > ~/.kube/config.merged
    mv ~/.kube/config.merged ~/.kube/config
    chmod 600 ~/.kube/config
else
    mkdir -p ~/.kube
    cp "$TMPKUBE" ~/.kube/config
    chmod 600 ~/.kube/config
fi
rm -f "$TMPKUBE"

# --- Wait for nodes ---
echo ""
echo "Waiting for all nodes to be Ready..."
for attempt in $(seq 1 30); do
    READY_COUNT=$(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
    EXPECTED=$((1 + WORKER_COUNT))
    if [ "$READY_COUNT" -eq "$EXPECTED" ]; then
        echo "  All $EXPECTED nodes are Ready"
        break
    fi
    [ "$attempt" -eq 30 ] && { echo "ERROR: Not all nodes became Ready" >&2; kubectl --context "$KUBE_CONTEXT" get nodes; exit 1; }
    sleep 5
done

# --- Label nodes ---
echo ""
echo "Labeling nodes..."
CONTROL_NODE=$(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers | grep -v '<none>' | head -1 | awk '{print $1}')
kubectl --context "$KUBE_CONTEXT" label node "$CONTROL_NODE" role=master --overwrite

for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    # k3s names nodes by hostname
    kubectl --context "$KUBE_CONTEXT" label node "$vm" role=db --overwrite
done

# --- Save VM IP mapping for other scripts ---
cat > "$VM_DIR/vm-ips.env" << EOF
# Auto-generated by setup-k3s-virsh.sh
CONTROL_IP=${CONTROL_IP}
EOF
for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    echo "WORKER_${i}_IP=${VM_IPS[$vm]}" >> "$VM_DIR/vm-ips.env"
done

echo ""
echo "=== Node Layout ==="
kubectl --context "$KUBE_CONTEXT" get nodes -o wide -L role
echo ""
echo "=== VM IPs ==="
cat "$VM_DIR/vm-ips.env"
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Setup storage:    ./scripts/setup-slow-disk.sh"
echo "  2. Deploy YB stack:  make deploy-k3s-virsh"
echo "  3. Check status:     make status KUBE_CONTEXT=$KUBE_CONTEXT"
echo "  4. Prepare tables:   make sysbench-prepare KUBE_CONTEXT=$KUBE_CONTEXT"
echo "  5. Run benchmark:    make sysbench-run KUBE_CONTEXT=$KUBE_CONTEXT"
