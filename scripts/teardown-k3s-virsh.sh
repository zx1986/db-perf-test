#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-ygdb}"
VM_PREFIX="${VM_PREFIX:-ygdb}"
WORKER_COUNT="${WORKER_COUNT:-3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/.vms"

echo "=== Tearing down k3s-virsh cluster ==="

ALL_VMS="${VM_PREFIX}-control"
for i in $(seq 1 "$WORKER_COUNT"); do
    ALL_VMS="$ALL_VMS ${VM_PREFIX}-worker-${i}"
done

for vm in $ALL_VMS; do
    if virsh dominfo "$vm" &>/dev/null; then
        echo "  Destroying $vm..."
        virsh destroy "$vm" 2>/dev/null || true
        virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
        # Remove cidata ISO (not covered by --remove-all-storage for cdrom)
        rm -f "$VM_DIR/${vm}-cidata.iso"
        echo "  $vm: removed"
    else
        echo "  $vm: not found, skipping"
    fi
done

# Remove kubeconfig context
echo ""
echo "Cleaning kubeconfig context: $KUBE_CONTEXT"
kubectl config delete-context "$KUBE_CONTEXT" 2>/dev/null || true
kubectl config delete-cluster "$KUBE_CONTEXT" 2>/dev/null || true
kubectl config delete-user "$KUBE_CONTEXT" 2>/dev/null || true

# Clean up generated files (keep base cloud image)
rm -f "$VM_DIR/vm-ips.env"

echo ""
echo "=== Teardown Complete ==="
echo "Note: Base cloud image preserved at $VM_DIR/ubuntu-24.04-cloudimg.img"
