# Disk I/O Simulation Method Comparison

Date: 2026-03-26

## Purpose

Compare three approaches to simulating constrained disk I/O for YugabyteDB performance testing:
1. **Normal** — no throttling (baseline)
2. **dm-delay 1ms** — host-level per-I/O latency injection via device-mapper
3. **IOPS 200** — QEMU-level IOPS cap via `virsh blkdeviotune`

All VMs: Ubuntu 24.04, 2 vCPU, 4 GB RAM, 20 GB qcow2 disk (`cache=none, io=native`).

## Test Results

### Sequential Write (4k x 500, O_DIRECT)

| VM | Speed | Effective IOPS |
|---|---|---|
| Normal | 89.1 MB/s | ~22,275 |
| dm-delay 1ms | 4.1 MB/s | ~1,025 |
| IOPS 200 | 784 KB/s | ~196 |

### Sequential Read (4k x 500, O_DIRECT)

| VM | Speed | Effective IOPS |
|---|---|---|
| Normal | 14.1 MB/s | ~3,525 |
| dm-delay 1ms | 2.0 MB/s | ~500 |
| IOPS 200 | 418 KB/s | ~105 |

### Large Block Write (1M x 50, O_DIRECT)

| VM | Speed |
|---|---|
| Normal | 1.3 GB/s |
| dm-delay 1ms | 711 MB/s |
| IOPS 200 | 356 MB/s |

### iostat During 4k Write Stress

| Metric | Normal | dm-delay 1ms | IOPS 200 |
|---|---|---|---|
| Write IOPS (w/s) | 312 | 53 | 41 |
| Write BW (wkB/s) | 9,818 | 10,625 | 11,138 |
| Write merge (wrqm/s) | 37 | 45 | 47 |
| Avg write size (wareq-sz) | 31 KB | 200 KB | 269 KB |
| Write latency (w_await) | 0.23 ms | **9.07 ms** | **68.44 ms** |
| Read IOPS (r/s) | 103 | 126 | 134 |
| Read latency (r_await) | 0.40 ms | **1.18 ms** | **14.59 ms** |
| Disk utilization (%util) | 4.5% | 14.5% | **75.0%** |

## Analysis

### dm-delay 1ms
- Adds **constant latency** to every I/O operation at the host block layer.
- Write latency: 9ms (amplified from 1ms because ext4/qcow2 batches multiple dm-delay operations per write).
- Read latency: 1.18ms — close to the configured 1ms delay.
- **Large block writes mostly unaffected** (711 MB/s vs 1.3 GB/s) — fewer I/O operations for large blocks means less delay.
- Write IOPS dropped 6x (312 → 53) but write bandwidth stayed similar (~10 MB/s) — the system compensates by making each write larger (31 KB → 200 KB).
- Disk utilization low (14.5%) — the disk isn't saturated, just slow per operation.

### IOPS 200
- Caps **total I/O operations per second** at the QEMU hypervisor level.
- Write latency: 68ms — I/O requests queue behind the IOPS cap.
- Read latency: 14.6ms — **reads are affected too** (shared IOPS budget with writes).
- Write IOPS dropped to 41 (below the 200 cap because reads consume some of the budget).
- Write bandwidth similar (~11 MB/s) — compensated by larger writes (269 KB avg).
- Disk utilization 75% — approaching saturation of the IOPS budget.
- **Large block writes less affected** (356 MB/s) — each 1MB write = 1 IOPS regardless of size.

### Key Differences

| Characteristic | dm-delay | IOPS cap |
|---|---|---|
| What it simulates | Slow disk media (SSD aging, HDD, network storage) | Provisioned IOPS (cloud EBS, SAN) |
| Latency model | Constant per I/O | Queuing (variable, bursty) |
| Affects reads? | Yes (1.18ms vs 0.40ms baseline) | Yes, more severely (14.6ms vs 0.40ms) |
| Large block impact | Minimal (fewer I/Os) | Minimal (1 IOPS per large write) |
| VM CPU overhead | None (host-level) | None (QEMU-level) |
| Predictability | High (consistent latency) | Low (queuing causes variance) |
| Configuration | `dm-delay` on host (needs Docker --privileged) | `virsh blkdeviotune` (no privileges) |

### Combining Both

Both methods can be applied simultaneously for realistic simulation:
- dm-delay adds base latency per I/O (simulates physical media speed)
- IOPS cap limits total throughput (simulates provisioned capacity)

Example: dm-delay 1ms + IOPS 200 would simulate a cloud SSD volume with ~1ms base latency and 200 IOPS provisioned capacity.

## Methodology Notes

- dm-delay is created on the host via privileged Docker container, filesystem mounted via `nsenter`.
- The VM's qcow2 disk image sits on the dm-delay filesystem, so all VM I/O traverses the delay.
- Both read and write delays must be specified: `"0 $SECTORS delay $LOOP 0 $MS $LOOP 0 $MS"` (5-arg form only delays reads).
- IOPS throttle applied via `virsh blkdeviotune <vm> vda --total-iops-sec 200 --live`.
- All tests use `O_DIRECT` to bypass guest page cache.
