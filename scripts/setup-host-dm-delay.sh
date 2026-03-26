#!/bin/bash
set -euo pipefail

# Creates dm-delay devices on the HOST via privileged Docker container,
# then attaches them to worker VMs as secondary disks.
# No sudo required - uses Docker --privileged for kernel operations.

VM_PREFIX="${VM_PREFIX:-ygdb}"
WORKER_COUNT="${WORKER_COUNT:-3}"
DISK_DELAY_MS="${DISK_DELAY_MS:-4}"
DISK_SIZE_GB="${DISK_SIZE_GB:-10}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-ygdb}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/.vms"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

echo "=== Host-level dm-delay Setup ==="
echo "Delay: ${DISK_DELAY_MS}ms per I/O"
echo "Disk size: ${DISK_SIZE_GB}GB per worker"
echo "Workers: ${WORKER_COUNT}"
echo ""

# Load VM IPs
if [ ! -f "$VM_DIR/vm-ips.env" ]; then
    echo "ERROR: $VM_DIR/vm-ips.env not found. Run setup-k3s-virsh.sh first." >&2
    exit 1
fi
source "$VM_DIR/vm-ips.env"

# Step 1: Create dm-delay devices on the host via Docker
echo "Creating dm-delay devices via Docker..."
for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    dm_name="slow-${vm}"
    raw_file="$VM_DIR/${vm}-data.raw"

    echo "  $vm: creating ${DISK_SIZE_GB}GB dm-delay device (${DISK_DELAY_MS}ms)..."

    # Create backing file on host
    truncate -s "${DISK_SIZE_GB}G" "$raw_file"

    # Use Docker to create loop + dm-delay device
    docker run --rm --privileged \
        -v "$VM_DIR:/vms" \
        -v /dev:/dev \
        -v /lib/modules:/lib/modules:ro \
        ubuntu:24.04 bash -c "
apt-get update -qq && apt-get install -y -qq dmsetup kmod e2fsprogs >/dev/null 2>&1
modprobe dm_delay

# Clean up if exists
dmsetup remove ${dm_name} 2>/dev/null || true
for loop in \$(losetup -j /vms/${vm}-data.raw 2>/dev/null | cut -d: -f1); do
    losetup -d \"\$loop\" 2>/dev/null || true
done

# Create loop + dm-delay
LOOP=\$(losetup --find --show /vms/${vm}-data.raw)
SECTORS=\$(blockdev --getsz \$LOOP)
echo \"0 \$SECTORS delay \$LOOP 0 ${DISK_DELAY_MS}\" | dmsetup create ${dm_name}
# Wait for device node to appear, then format
sleep 1
if [ -e /dev/mapper/${dm_name} ]; then
    mkfs.ext4 -q /dev/mapper/${dm_name}
    echo \"  Created /dev/mapper/${dm_name} (loop=\$LOOP)\"
else
    echo \"  WARNING: /dev/mapper/${dm_name} not visible in container, will format from host\"
fi
" 2>&1 | grep -v '^$'

    # Format from host if needed (dm device is always visible on host)
    if ! docker run --rm --privileged -v /dev:/dev ubuntu:24.04 bash -c \
        "apt-get update -qq && apt-get install -y -qq e2fsprogs >/dev/null 2>&1 && tune2fs -l /dev/mapper/${dm_name} >/dev/null 2>&1"; then
        echo "  Formatting /dev/mapper/${dm_name} from host..."
        docker run --rm --privileged -v /dev:/dev ubuntu:24.04 bash -c \
            "apt-get update -qq && apt-get install -y -qq e2fsprogs >/dev/null 2>&1 && mkfs.ext4 -q /dev/mapper/${dm_name}"
    fi

done

echo ""

# Step 2: Attach dm-delay devices to VMs
echo "Attaching devices to VMs..."
for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    dm_name="slow-${vm}"
    dm_path="/dev/mapper/${dm_name}"

    # Detach existing vdb if present
    virsh detach-disk "$vm" vdb --live 2>/dev/null || true

    # Attach dm-delay device as vdb with cache=none
    virsh attach-disk "$vm" "$dm_path" vdb \
        --driver qemu --subdriver raw --cache none \
        --live 2>&1

    echo "  $vm: attached $dm_path as /dev/vdb"
done

echo ""

# Step 3: Mount inside VMs and create PVs
echo "Mounting /dev/vdb inside VMs..."
for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    ip_var="WORKER_${i}_IP"
    ip="${!ip_var}"

    ssh $SSH_OPTS "ubuntu@${ip}" bash << 'REMOTE'
set -euo pipefail
# Unmount old data
if mountpoint -q /mnt/ygdb-data 2>/dev/null; then sudo umount /mnt/ygdb-data; fi
# Clean any old dm-delay inside VM
if [ -e /dev/mapper/slow-disk0 ]; then sudo dmsetup remove slow-disk0 2>/dev/null || true; fi
sudo rm -rf /mnt/slow-disk-data

sudo mkdir -p /mnt/ygdb-data
sudo mount /dev/vdb /mnt/ygdb-data
sudo chmod 777 /mnt/ygdb-data
echo "  Mounted /dev/vdb at /mnt/ygdb-data"
REMOTE

    echo "  $vm ($ip): mounted"
done

echo ""

# Step 4: Create Kubernetes storage resources
echo "Applying Kubernetes storage resources..."
kubectl --context "$KUBE_CONTEXT" apply -f - << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF

for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"
    kubectl --context "$KUBE_CONTEXT" apply -f - << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ygdb-data-${vm}
spec:
  capacity:
    storage: ${DISK_SIZE_GB}Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/ygdb-data
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [${vm}]
EOF
    echo "  PV ygdb-data-${vm} created"
done

echo ""
echo "=== Host dm-delay Setup Complete ==="
echo "Delay: ${DISK_DELAY_MS}ms per I/O (zero VM CPU overhead)"
kubectl --context "$KUBE_CONTEXT" get pv
