# Disk I/O Simulation Method Comparison

Date: 2026-03-26

## Purpose

Compare three approaches to simulating constrained disk I/O for YugabyteDB performance testing:
1. **Normal** — no throttling (baseline)
2. **dm-delay 1ms** — host-level per-I/O latency injection via device-mapper
3. **IOPS 200** — QEMU-level IOPS cap via `virsh blkdeviotune`

All VMs: Ubuntu 24.04, 2 vCPU, 4 GB RAM, 20 GB qcow2 disk (`cache=none, io=native`).

## Raw Performance (no throttling)

Measured inside a VM with no dm-delay or IOPS cap. This is the baseline that the throttled VMs are compared against.

| Test | Speed | Effective IOPS | Latency |
|---|---|---|---|
| 4k sequential write (O_DIRECT) | 89.1 MB/s | ~22,275 | 0.23 ms |
| 4k sequential read (O_DIRECT) | 14.1 MB/s | ~3,525 | 0.40 ms |
| 1M sequential write (O_DIRECT) | 1.3 GB/s | — | — |
| 4k write stress (iostat) | 312 IOPS / 9.8 MB/s | 312 | 0.23 ms |

The host machine uses NVMe SSD. VMs use qcow2 with `cache=none, io=native`.

## Throttled Performance

### Sequential Write (4k x 500, O_DIRECT)

| VM | Speed | Effective IOPS | vs Raw |
|---|---|---|---|
| Raw (no throttle) | 89.1 MB/s | ~22,275 | — |
| dm-delay 1ms | 4.1 MB/s | ~1,025 | **-95%** |
| IOPS 200 | 784 KB/s | ~196 | **-99%** |

### Sequential Read (4k x 500, O_DIRECT)

| VM | Speed | Effective IOPS | vs Raw |
|---|---|---|---|
| Raw (no throttle) | 14.1 MB/s | ~3,525 | — |
| dm-delay 1ms | 2.0 MB/s | ~500 | -86% |
| IOPS 200 | 418 KB/s | ~105 | -97% |

### Large Block Write (1M x 50, O_DIRECT)

| VM | Speed | vs Raw |
|---|---|---|
| Raw (no throttle) | 1.3 GB/s | — |
| dm-delay 1ms | 711 MB/s | -45% |
| IOPS 200 | 356 MB/s | -73% |

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

## Raw vs qcow2 Disk Format

qcow2 format adds a metadata layer (copy-on-write, thin provisioning) that amplifies I/O: a single guest write triggers multiple host I/Os for data + metadata updates. Raw format maps guest I/O 1:1 to host I/O.

**Raw format is recommended for performance testing.**

### Raw Format Results (dm-delay 1ms)

| Metric | qcow2 | raw | Impact |
|---|---|---|---|
| Write latency (w_await) | 9.07 ms | **1.28 ms** | qcow2 amplifies 7x |
| Read latency (r_await) | 1.18 ms | **0.74 ms** | qcow2 amplifies 1.6x |
| Write IOPS | 53 | **74** | raw 40% more |
| Write merge ratio | 45% | 47% | similar |

### Full Comparison (raw format)

#### Sequential Write (4k x 500, O_DIRECT)

| VM | Speed | Effective IOPS | vs Raw baseline |
|---|---|---|---|
| Raw (no throttle) | 43.4 MB/s | ~10,850 | — |
| Raw + dm-delay 1ms | 4.1 MB/s | ~1,025 | -91% |
| Raw + IOPS 200 | 834 KB/s | ~209 | -98% |

#### Sequential Read (4k x 500, O_DIRECT)

| VM | Speed | Effective IOPS | vs Raw baseline |
|---|---|---|---|
| Raw (no throttle) | 9.3 MB/s | ~2,325 | — |
| Raw + dm-delay 1ms | 2.0 MB/s | ~500 | -78% |
| Raw + IOPS 200 | 416 KB/s | ~104 | -96% |

#### Large Block Write (1M x 50, O_DIRECT)

| VM | Speed | vs Raw baseline |
|---|---|---|
| Raw (no throttle) | 1.9 GB/s | — |
| Raw + dm-delay 1ms | 599 MB/s | -68% |
| Raw + IOPS 200 | 356 MB/s | -81% |

#### iostat During 4k Write Stress (raw format)

| Metric | Raw baseline | dm-delay 1ms | IOPS 200 |
|---|---|---|---|
| Write IOPS (w/s) | 456 | 74 | 42 |
| Write BW (wkB/s) | 12,299 | 15,476 | 11,212 |
| Write latency (w_await) | **0.06 ms** | **1.28 ms** | **60.16 ms** |
| Read latency (r_await) | **0.12 ms** | **0.74 ms** | **15.30 ms** |
| Avg write size (wareq-sz) | 27 KB | 209 KB | 265 KB |
| Disk utilization (%util) | 2.8% | 15.8% | 76.7% |

### Summary Table

| Metric | qcow2 baseline | raw baseline | raw + 1ms delay | raw + 200 IOPS |
|---|---|---|---|---|
| 4k write speed | 89 MB/s | 43 MB/s | 4.1 MB/s | 834 KB/s |
| Write latency | 0.23 ms | 0.06 ms | 1.28 ms | 60 ms |
| Read latency | 0.40 ms | 0.12 ms | 0.74 ms | 15 ms |
| dm-delay amplification | 9x (1ms→9ms) | **1.3x (1ms→1.3ms)** | — | — |

**Key finding:** qcow2's raw 4k write speed (89 MB/s) appears faster than raw (43 MB/s) because qcow2 batches writes through its metadata layer, but this comes at the cost of unpredictable I/O amplification under throttling. Raw format gives predictable, linear latency scaling.

## Methodology Notes

- dm-delay is created on the host via privileged Docker container, filesystem mounted via `nsenter`.
- The VM's disk image sits on the dm-delay filesystem, so all VM I/O traverses the delay.
- Both read and write delays must be specified: `"0 $SECTORS delay $LOOP 0 $MS $LOOP 0 $MS"` (5-arg form only delays reads).
- IOPS throttle applied via `virsh blkdeviotune <vm> vda --total-iops-sec 200 --live`.
- All tests use `O_DIRECT` to bypass guest page cache.
- **Raw disk format recommended** for performance testing to avoid qcow2 I/O amplification.
