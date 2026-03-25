#!/bin/bash
set -euo pipefail

# Configuration
VM_PREFIX="${VM_PREFIX:-ygdb}"
WORKER_COUNT="${WORKER_COUNT:-3}"
DISK_BW_MBPS="${DISK_BW_MBPS:-0}"
DISK_IOPS="${DISK_IOPS:-0}"
DISK_DEVICE="${DISK_DEVICE:-vda}"

echo "=== Disk Throughput/IOPS Throttling (virsh blkdeviotune) ==="

if [ "$DISK_BW_MBPS" -eq 0 ] && [ "$DISK_IOPS" -eq 0 ]; then
    echo "Mode: removing all throttles"
else
    [ "$DISK_BW_MBPS" -gt 0 ] && echo "Bandwidth: ${DISK_BW_MBPS} MB/s (read+write)"
    [ "$DISK_IOPS" -gt 0 ] && echo "IOPS: ${DISK_IOPS} (total)"
fi
echo ""

# Convert MB/s to bytes/sec
BW_BYTES=0
if [ "$DISK_BW_MBPS" -gt 0 ]; then
    BW_BYTES=$((DISK_BW_MBPS * 1048576))
fi

for i in $(seq 1 "$WORKER_COUNT"); do
    vm="${VM_PREFIX}-worker-${i}"

    if ! virsh domstate "$vm" 2>/dev/null | grep -q "running"; then
        echo "  $vm: not running, skipping"
        continue
    fi

    virsh blkdeviotune "$vm" "$DISK_DEVICE" \
        --read-bytes-sec "$BW_BYTES" \
        --write-bytes-sec "$BW_BYTES" \
        --total-iops-sec "$DISK_IOPS" \
        --live 2>&1

    echo "  $vm: throttle applied"

    # Show current settings
    virsh blkdeviotune "$vm" "$DISK_DEVICE" 2>&1 | grep -E 'bytes_sec|iops_sec' | head -6 | sed 's/^/    /'
    echo ""
done

echo "=== Throttle Configuration Complete ==="
