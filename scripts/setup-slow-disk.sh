#!/bin/bash
set -euo pipefail

# Configuration
KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-ygdb}"
VM_PREFIX="${VM_PREFIX:-ygdb}"
WORKER_COUNT="${WORKER_COUNT:-3}"
DISK_DELAY_MS="${DISK_DELAY_MS:-0}"
DISK_SIZE_GB="${DISK_SIZE_GB:-10}"
MOUNT_PATH="/mnt/ygdb-data"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/.vms"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

# Load VM IPs
if [ ! -f "$VM_DIR/vm-ips.env" ]; then
    echo "ERROR: $VM_DIR/vm-ips.env not found. Run setup-k3s-virsh.sh first." >&2
    exit 1
fi
source "$VM_DIR/vm-ips.env"

echo "=== Setting up tserver storage ==="
if [ "$DISK_DELAY_MS" -gt 0 ]; then
    echo "Mode: dm-delay (${DISK_DELAY_MS}ms latency per I/O)"
else
    echo "Mode: normal (no artificial delay)"
fi
echo "Size: ${DISK_SIZE_GB}GB per worker"
echo ""

for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    ip_var="WORKER_${i}_IP"
    ip="${!ip_var}"

    echo "Setting up $vm ($ip)..."

    if [ "$DISK_DELAY_MS" -gt 0 ]; then
        # dm-delay mode
        ssh $SSH_OPTS "ubuntu@${ip}" bash << REMOTE_SCRIPT
set -euo pipefail

# Clean up any previous setup
if mountpoint -q ${MOUNT_PATH} 2>/dev/null; then
    sudo umount ${MOUNT_PATH}
fi
if [ -e /dev/mapper/slow-disk0 ]; then
    sudo dmsetup remove slow-disk0 2>/dev/null || true
fi
# Detach any existing loop devices for our backing file
for loop in \$(losetup -j /mnt/slow-disk-data/disk0.img 2>/dev/null | cut -d: -f1); do
    sudo losetup -d "\$loop" 2>/dev/null || true
done

# Create backing file
sudo mkdir -p /mnt/slow-disk-data
sudo truncate -s ${DISK_SIZE_GB}G /mnt/slow-disk-data/disk0.img

# Setup loop device
LOOP=\$(sudo losetup --find --show /mnt/slow-disk-data/disk0.img)
echo "  Loop device: \$LOOP"

# Get size in sectors
SECTORS=\$(sudo blockdev --getsz "\$LOOP")

# Load dm_delay and create delayed device
sudo modprobe dm_delay
echo "0 \$SECTORS delay \$LOOP 0 ${DISK_DELAY_MS}" | sudo dmsetup create slow-disk0
echo "  dm-delay device: /dev/mapper/slow-disk0 (${DISK_DELAY_MS}ms)"

# Format and mount
sudo mkfs.ext4 -q /dev/mapper/slow-disk0
sudo mkdir -p ${MOUNT_PATH}
sudo mount /dev/mapper/slow-disk0 ${MOUNT_PATH}
sudo chmod 777 ${MOUNT_PATH}

echo "  Mounted at ${MOUNT_PATH}"
REMOTE_SCRIPT
    else
        # Normal mode - just create a directory
        ssh $SSH_OPTS "ubuntu@${ip}" bash << REMOTE_SCRIPT
set -euo pipefail

# Clean up any previous dm-delay setup
if mountpoint -q ${MOUNT_PATH} 2>/dev/null; then
    sudo umount ${MOUNT_PATH}
fi
if [ -e /dev/mapper/slow-disk0 ]; then
    sudo dmsetup remove slow-disk0 2>/dev/null || true
fi
for loop in \$(losetup -j /mnt/slow-disk-data/disk0.img 2>/dev/null | cut -d: -f1); do
    sudo losetup -d "\$loop" 2>/dev/null || true
done

sudo mkdir -p ${MOUNT_PATH}
sudo chmod 777 ${MOUNT_PATH}
echo "  Directory ready at ${MOUNT_PATH}"
REMOTE_SCRIPT
    fi

    echo "  $vm: done"
done

# --- Kubernetes resources ---
echo ""
echo "Applying Kubernetes storage resources..."

# StorageClass
kubectl --context "$KUBE_CONTEXT" apply -f - << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF

# Static PVs - one per worker node
for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    kubectl --context "$KUBE_CONTEXT" apply -f - << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ygdb-data-${vm}
  labels:
    type: local
spec:
  capacity:
    storage: ${DISK_SIZE_GB}Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: ${MOUNT_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${vm}
EOF
    echo "  PV ygdb-data-${vm} created"
done

echo ""
echo "=== Storage Setup Complete ==="
kubectl --context "$KUBE_CONTEXT" get pv
