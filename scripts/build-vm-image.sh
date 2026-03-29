#!/bin/bash
set -euo pipefail

# Builds a pre-baked Ubuntu 24.04 VM image with k3s and dmsetup pre-installed.
# The resulting image can be used in air-gapped environments without internet access.
#
# Usage: ./scripts/build-vm-image.sh
# Output: .vms/ubuntu-24.04-k3s.img
#
# Prerequisites (on build machine):
#   - virsh, virt-install, qemu-img, genisoimage
#   - Internet access (to download k3s and Ubuntu cloud image)

K3S_VERSION="${K3S_VERSION:-v1.34.5+k3s1}"
DISK_SIZE="${DISK_SIZE:-20G}"
NETWORK="${NETWORK:-default}"
OS_VARIANT="${OS_VARIANT:-ubuntu24.04}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/.vms"
BASE_IMG="$VM_DIR/ubuntu-24.04-cloudimg.img"
BASE_IMG_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
OUTPUT_IMG="$VM_DIR/ubuntu-24.04-k3s.img"
BUILD_VM="img-builder"

SSH_KEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

echo "=== Building Pre-baked VM Image ==="
echo "k3s version: $K3S_VERSION"
echo "Output: $OUTPUT_IMG"
echo ""

# --- Prerequisites ---
for cmd in virsh virt-install qemu-img genisoimage; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required" >&2; exit 1; }
done

if [ -z "$SSH_KEY" ]; then
    echo "ERROR: No SSH public key found" >&2
    exit 1
fi

# --- Download base image ---
mkdir -p "$VM_DIR"
if [ ! -f "$BASE_IMG" ]; then
    echo "Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress -O "$BASE_IMG" "$BASE_IMG_URL"
fi

# --- Download k3s assets ---
K3S_DIR="$VM_DIR/k3s-assets"
mkdir -p "$K3S_DIR"

K3S_BIN="$K3S_DIR/k3s"
K3S_IMAGES="$K3S_DIR/k3s-airgap-images-amd64.tar.zst"
K3S_INSTALL="$K3S_DIR/install.sh"

K3S_VERSION_URL=$(echo "$K3S_VERSION" | sed 's/+/%2B/g')

if [ ! -f "$K3S_BIN" ]; then
    echo "Downloading k3s binary ($K3S_VERSION)..."
    wget -q --show-progress -O "$K3S_BIN" "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION_URL}/k3s"
    chmod +x "$K3S_BIN"
fi

if [ ! -f "$K3S_IMAGES" ]; then
    echo "Downloading k3s airgap images..."
    wget -q --show-progress -O "$K3S_IMAGES" "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION_URL}/k3s-airgap-images-amd64.tar.zst"
fi

if [ ! -f "$K3S_INSTALL" ]; then
    echo "Downloading k3s install script..."
    wget -q --show-progress -O "$K3S_INSTALL" "https://get.k3s.io"
    chmod +x "$K3S_INSTALL"
fi

echo ""

# --- Clean up old builder VM ---
if virsh dominfo "$BUILD_VM" &>/dev/null; then
    echo "Cleaning up old builder VM..."
    virsh destroy "$BUILD_VM" 2>/dev/null || true
    virsh undefine "$BUILD_VM" --remove-all-storage 2>/dev/null || true
fi

# --- Create builder VM ---
echo "Creating builder VM..."
qemu-img convert -f qcow2 -O raw "$BASE_IMG" "$VM_DIR/${BUILD_VM}.raw"
truncate -s "$DISK_SIZE" "$VM_DIR/${BUILD_VM}.raw"

mkdir -p "/tmp/cloud-init-${BUILD_VM}"
cat > "/tmp/cloud-init-${BUILD_VM}/user-data" << EOF
#cloud-config
hostname: ${BUILD_VM}
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_KEY}
packages:
  - dmsetup
  - zstd
package_update: true
EOF

cat > "/tmp/cloud-init-${BUILD_VM}/meta-data" << EOF
instance-id: ${BUILD_VM}
local-hostname: ${BUILD_VM}
EOF

genisoimage -output "$VM_DIR/${BUILD_VM}-cidata.iso" \
    -volid cidata -joliet -rock -input-charset utf-8 \
    "/tmp/cloud-init-${BUILD_VM}/user-data" "/tmp/cloud-init-${BUILD_VM}/meta-data" \
    >/dev/null 2>&1
rm -rf "/tmp/cloud-init-${BUILD_VM}"

virt-install \
    --name "$BUILD_VM" \
    --memory 4096 \
    --vcpus 2 \
    --disk "path=$VM_DIR/${BUILD_VM}.raw,format=raw,cache=none,io=native" \
    --disk "path=$VM_DIR/${BUILD_VM}-cidata.iso,device=cdrom" \
    --os-variant "$OS_VARIANT" \
    --network "network=$NETWORK" \
    --graphics none \
    --noautoconsole \
    --import \
    >/dev/null 2>&1

echo "  Builder VM created"

# --- Wait for VM ---
echo "Waiting for IP..."
for attempt in $(seq 1 30); do
    BUILD_IP=$(virsh domifaddr "$BUILD_VM" 2>/dev/null | grep ipv4 | awk '{print $4}' | cut -d/ -f1 || true)
    if [ -n "$BUILD_IP" ]; then
        echo "  IP: $BUILD_IP"
        break
    fi
    [ "$attempt" -eq 30 ] && { echo "ERROR: VM did not get IP" >&2; exit 1; }
    sleep 2
done

echo "Waiting for SSH..."
for attempt in $(seq 1 30); do
    if ssh $SSH_OPTS "ubuntu@${BUILD_IP}" "true" 2>/dev/null; then
        echo "  SSH OK"
        break
    fi
    [ "$attempt" -eq 30 ] && { echo "ERROR: SSH failed" >&2; exit 1; }
    sleep 5
done

echo "Waiting for cloud-init..."
ssh $SSH_OPTS "ubuntu@${BUILD_IP}" "cloud-init status --wait" >/dev/null 2>&1
echo "  cloud-init done"

# --- Install k3s assets ---
echo ""
echo "Installing k3s assets into VM..."

# Copy k3s binary
scp $SSH_OPTS "$K3S_BIN" "ubuntu@${BUILD_IP}:/tmp/k3s"
ssh $SSH_OPTS "ubuntu@${BUILD_IP}" "sudo install -m 755 /tmp/k3s /usr/local/bin/k3s && rm /tmp/k3s"
echo "  k3s binary installed"

# Copy airgap images
scp $SSH_OPTS "$K3S_IMAGES" "ubuntu@${BUILD_IP}:/tmp/k3s-airgap-images-amd64.tar.zst"
ssh $SSH_OPTS "ubuntu@${BUILD_IP}" "sudo mkdir -p /var/lib/rancher/k3s/agent/images && sudo mv /tmp/k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/"
echo "  k3s airgap images installed"

# Copy install script
scp $SSH_OPTS "$K3S_INSTALL" "ubuntu@${BUILD_IP}:/tmp/install-k3s.sh"
ssh $SSH_OPTS "ubuntu@${BUILD_IP}" "sudo install -m 755 /tmp/install-k3s.sh /usr/local/bin/install-k3s.sh && rm /tmp/install-k3s.sh"
echo "  k3s install script installed"

# Verify
echo ""
echo "Verifying installation..."
ssh $SSH_OPTS "ubuntu@${BUILD_IP}" "k3s --version && dpkg -l dmsetup | tail -1 && ls -lh /var/lib/rancher/k3s/agent/images/"

# --- Clean up VM state ---
echo ""
echo "Cleaning up VM state for reuse..."
ssh $SSH_OPTS "ubuntu@${BUILD_IP}" "
    sudo cloud-init clean --logs --seed
    sudo rm -f /etc/ssh/ssh_host_*
    sudo rm -f /etc/machine-id && sudo touch /etc/machine-id
    sudo truncate -s 0 /var/log/syslog /var/log/auth.log /var/log/kern.log 2>/dev/null || true
    history -c
    sudo sync
"
echo "  Cleaned"

# --- Shutdown and export ---
echo ""
echo "Shutting down builder VM..."
ssh $SSH_OPTS "ubuntu@${BUILD_IP}" "sudo shutdown -h now" 2>/dev/null || true

# Wait for VM to fully stop
echo "  Waiting for VM to stop..."
for attempt in $(seq 1 30); do
    if virsh domstate "$BUILD_VM" 2>/dev/null | grep -q "shut off"; then
        echo "  VM stopped"
        break
    fi
    [ "$attempt" -eq 30 ] && { echo "  Force stopping..."; virsh destroy "$BUILD_VM" 2>/dev/null || true; sleep 2; }
    sleep 3
done

echo "Converting disk to output image..."
qemu-img convert -f raw -O qcow2 -c "$VM_DIR/${BUILD_VM}.raw" "$OUTPUT_IMG"
echo "  Output: $OUTPUT_IMG ($(du -h "$OUTPUT_IMG" | awk '{print $1}'))"

# --- Clean up builder VM ---
echo ""
echo "Cleaning up builder VM..."
virsh undefine "$BUILD_VM" --remove-all-storage >/dev/null 2>&1

echo ""
echo "=== Build Complete ==="
echo "Pre-baked image: $OUTPUT_IMG"
echo "Contents: Ubuntu 24.04 + k3s $K3S_VERSION + dmsetup"
echo ""
echo "To use: set VM_BASE_IMG=$OUTPUT_IMG before running setup-k3s-virsh.sh"
