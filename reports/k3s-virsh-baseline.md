# k3s-virsh Baseline Performance Results

Date: 2026-03-25

## Host Machine

- Intel i7-13620H (13th Gen), 16 cores, 62 GB RAM
- Disk: NVMe SSD

## Cluster Setup

- 4 VMs on libvirt/KVM, Ubuntu 24.04, k3s v1.34.5
- 1 control node (role=master): YB masters, sysbench, prometheus
- 3 worker nodes (role=db): 1 tserver each, RF=3
- Disk: cache=none, io=native (no dm-delay, no throughput throttle)
- YugabyteDB 2.23.1, sysbench oltp_read_write
- 10 tables × 100K rows, 24 threads, 120s test, 30s warmup

## Results

### Test 1: 4 shared vCPUs per VM (no CPU pinning)

| VM | vCPUs | Pinned | Memory |
|---|---|---|---|
| ygdb-control | 4 | no | 8 GB |
| ygdb-worker-1/2/3 | 4 | no | 8 GB |

| Metric | Value |
|---|---|
| TPS | 42.06 |
| QPS | 1437.50 |
| 95th latency | 746.32 ms |
| Avg container CPU (per tserver) | 172.9% |
| Avg VM CPU (workers) | 72% |
| Steal time | 14.1% |
| I/O wait | 9.1% |
| Write IOPS | 278 |
| Errors | 56 (0.46/s) |

### Test 2: 2 dedicated vCPUs per VM (CPU pinning)

| VM | vCPUs | Pinned to | Memory |
|---|---|---|---|
| ygdb-control | 2 | host CPUs 0-1 | 8 GB |
| ygdb-worker-1 | 2 | host CPUs 2-3 | 8 GB |
| ygdb-worker-2 | 2 | host CPUs 4-5 | 8 GB |
| ygdb-worker-3 | 2 | host CPUs 6-7 | 8 GB |

| Metric | Value |
|---|---|
| TPS | 44.41 |
| QPS | 1517.75 |
| 95th latency | 657.93 ms |
| Avg container CPU (per tserver) | 129.9% |
| Avg VM CPU (workers) | 80% |
| Steal time | 6.6% |
| I/O wait | 3.5% |
| Write IOPS | 310 |
| Errors | 62 (0.51/s) |

### Comparison

| Metric | 4 shared | 2 dedicated | Delta |
|---|---|---|---|
| TPS | 42.06 | 44.41 | +5.6% |
| QPS | 1437.50 | 1517.75 | +5.6% |
| 95th latency | 746 ms | 658 ms | -12% (better) |
| Steal time | 14.1% | 6.6% | -53% |
| I/O wait | 9.1% | 3.5% | -62% |

### Test 3: 2 dedicated vCPUs, consistency re-run (no delay)

Same config as Test 2, fresh deploy to verify result reproducibility.

| Metric | Value |
|---|---|
| TPS | 47.16 |
| QPS | 1608.59 |
| 95th latency | 601.29 ms |
| Avg container CPU (per tserver) | 121.3% |
| Avg VM CPU (workers) | 80% |
| Steal time | 6.1% |
| I/O wait | 3.4% |
| Write IOPS | 289 |
| Errors | 51 (0.42/s) |

### Test 4: 2 dedicated vCPUs, 2ms dm-delay

Same config as Test 2, with 2ms per-I/O latency injected via dm-delay on tserver storage.

| Metric | Value |
|---|---|
| TPS | 33.97 |
| QPS | 1158.24 |
| 95th latency | 893.56 ms |
| Avg container CPU (per tserver) | 67.1% |
| Avg VM CPU (workers) | 82% |
| Steal time | 5.2% |
| I/O wait | 5.8% |
| System CPU | 25.4% |
| Write IOPS | 632 |
| Errors | 39 (0.32/s) |

### Test 5: 2 dedicated vCPUs, 4ms dm-delay

| Metric | Value |
|---|---|
| TPS | 30.90 |
| QPS | 1053.79 |
| 95th latency | 1050.76 ms |
| Avg container CPU (per tserver) | 69.1% |
| Avg VM CPU (workers) | 83% |
| Steal time | 4.8% |
| I/O wait | 4.6% |
| System CPU | 29.8% |
| Write IOPS | 541 |
| Errors | 37 (0.31/s) |

### Test 6: 1 slow node (4ms dm-delay on worker-3 only)

Same config as Test 2, but dm-delay applied to only 1 of 3 workers.
tserver-0 on worker-3 (slow), tserver-1/2 on worker-1/2 (normal).

| Metric | Value |
|---|---|
| TPS | 37.39 |
| QPS | 1275.91 |
| 95th latency | 909.80 ms |
| Thread fairness stddev | 31.58 (vs 18.9 normal) |
| Errors | 50 (0.41/s) |

### Full Comparison (2 dedicated vCPUs)

| Metric | No delay (run 1) | No delay (run 2) | 2ms all | 4ms all | 4ms 1-node |
|---|---|---|---|---|---|
| TPS | 44.41 | 47.16 | 33.97 | 30.90 | 37.39 |
| QPS | 1517.75 | 1608.59 | 1158.24 | 1053.79 | 1275.91 |
| 95th latency | 658 ms | 601 ms | 894 ms | 1051 ms | 910 ms |
| Container CPU | 129.9% | 121.3% | 67.1% | 69.1% | — |
| System CPU | 14.6% | 14.6% | 25.4% | 29.8% | — |

### Test 7: 200 IOPS throttle (virsh blkdeviotune, no dm-delay)

All 3 workers throttled to 200 total IOPS via `virsh blkdeviotune`.
Unlike dm-delay (per-I/O latency), this caps the total I/O operations per second,
affecting both reads and writes.

| Metric | Value |
|---|---|
| TPS | 20.50 |
| QPS | 697.83 |
| 95th latency | 2198.52 ms |
| Avg latency | 1175.11 ms |
| Actual write IOPS (per worker) | ~200 (hitting cap) |
| Errors | 26 (0.22/s) |

### Full Comparison (2 dedicated vCPUs)

| Metric | No delay (run 1) | No delay (run 2) | 2ms all | 4ms all | 4ms 1-node | 200 IOPS |
|---|---|---|---|---|---|---|
| TPS | 44.41 | 47.16 | 33.97 | 30.90 | 37.39 | 20.50 |
| QPS | 1517.75 | 1608.59 | 1158.24 | 1053.79 | 1275.91 | 697.83 |
| 95th latency | 658 ms | 601 ms | 894 ms | 1051 ms | 910 ms | 2199 ms |

Run-to-run variance (no delay): ~6% TPS, consistent infrastructure metrics.

## YugabyteDB Internal Metrics

Captured from tserver Prometheus endpoints (`/prometheus-metrics`) during benchmark runs.

### No delay (baseline)

| Metric | tserver-0 | tserver-1 | tserver-2 |
|---|---|---|---|
| WAL fsync (log_sync_latency) | 3.5 ms | 4.6 ms | 4.3 ms |
| WAL group commit | 0.13 ms | 0.13 ms | 0.13 ms |
| WAL append | 0.10 ms | 0.10 ms | 0.10 ms |
| Write RPC | 6.3 ms | 8.3 ms | 6.0 ms |
| Read RPC | 0.26 ms | 0.34 ms | 0.24 ms |
| Raft UpdateConsensus | 0.68 ms | 1.17 ms | 0.53 ms |

### 4ms dm-delay (all 3 nodes)

| Metric | tserver-0 | tserver-1 | tserver-2 |
|---|---|---|---|
| WAL fsync (log_sync_latency) | 32.0 ms | 32.6 ms | 31.8 ms |
| WAL group commit | 1.3 ms | 1.7 ms | 1.3 ms |
| Write RPC | 11.8 ms | 13.5 ms | 12.9 ms |
| Read RPC | 0.42 ms | 0.43 ms | 0.41 ms |
| Raft UpdateConsensus | 2.7 ms | 2.4 ms | 2.2 ms |

### 4ms dm-delay (1 slow node: tserver-0 on worker-3)

| Metric | tserver-0 (SLOW) | tserver-1 (normal) | tserver-2 (normal) |
|---|---|---|---|
| WAL fsync (log_sync_latency) | **32.0 ms** | 3.2 ms | 3.2 ms |
| WAL group commit | **1.7 ms** | 0.09 ms | 0.11 ms |
| Write RPC | **16.2 ms** | 4.3 ms | 4.2 ms |
| Read RPC | **0.59 ms** | 0.21 ms | 0.23 ms |
| Raft UpdateConsensus | **6.3 ms** | 0.5 ms | 0.6 ms |

### 200 IOPS throttle (all 3 nodes)

| Metric | tserver-0 | tserver-1 | tserver-2 |
|---|---|---|---|
| WAL fsync (log_sync_latency) | 200.1 ms | 178.9 ms | 201.9 ms |
| WAL group commit | 17.2 ms | 15.7 ms | 16.8 ms |
| Write RPC | 31.6 ms | 30.5 ms | 30.5 ms |
| Read RPC | 1.63 ms | 0.91 ms | 1.07 ms |
| Raft UpdateConsensus | 15.2 ms | 13.8 ms | 15.0 ms |
| Actual write IOPS | 201 | 197 | 201 |

## Observations

### CPU pinning (Tests 1-3)
- 2 dedicated vCPUs outperformed 4 shared vCPUs despite having half the cores.
- Main factor: reduced steal time (14% → 7%) from CPU pinning eliminates scheduling jitter.
- Tservers use ~130% of 200% available CPU — moderately loaded, not fully saturated.
- Both no-delay configs are CPU-bound (low I/O wait, write IOPS similar).
- Run-to-run variance is ~6% for no-delay tests — acceptable for this environment.

### Disk latency impact (Tests 4-5)
- **2ms disk delay dropped TPS by ~26%** (avg 45.8 → 34.0), shifting the bottleneck from CPU to I/O.
- **4ms delay dropped TPS by ~33%** (avg 45.8 → 30.9), further degradation but diminishing impact per ms.
- Container CPU dropped from ~126% to ~68% with any delay — tservers become I/O-bound immediately.
- System CPU rose from 14.6% to 30% — kernel doing more I/O scheduling work under delay.
- WAL fsync latency amplified ~8x relative to dm-delay (4ms delay → 32ms fsync) because each fsync batches multiple I/O operations.
- Read RPCs barely affected (~0.3ms regardless of delay) — served from memory/block cache.

### Asymmetric slow node (Test 6)
- **1 slow node out of 3 caused a 21% TPS drop** — much more than the expected ~0% if majority-ack were the only factor.
- Root cause: the slow tserver is also a **tablet leader** for ~1/3 of tablets. As leader, it must sync its local WAL (32ms) before responding, regardless of follower speed.
- Write RPC on the slow node (16.2ms) was 4x slower than normal nodes (4.2ms).
- Raft UpdateConsensus on the slow node (6.3ms) was 12x slower than normal nodes (0.5ms) — followers receiving consensus from the slow leader wait for its disk.
- Thread fairness stddev nearly doubled (18.9 → 31.6), confirming uneven query distribution across fast vs slow tablets.
- Even reads were 2.5x slower on the slow node (0.59ms vs 0.21ms), suggesting some read path overhead from the slow disk (possibly WAL reads or compaction).

### IOPS throttle (Test 7)
- **200 IOPS throttle dropped TPS by 57%** (47.5 → 20.5), the most severe degradation of all tests.
- WAL fsync latency hit **200ms** — I/O requests queuing behind the IOPS cap, ~50x worse than baseline.
- Unlike dm-delay, **reads were also affected** (0.24ms → 1.6ms) because reads and writes share the same IOPS budget.
- Actual write IOPS on all workers hit exactly ~200, confirming the cap is the bottleneck.
- TPS variance was much higher (16-23 per interval) — bursty behavior as I/O queues drain and refill.
- 95th latency reached **2.2 seconds** — worst of all tests, due to I/O queuing cascading through Raft consensus.

### dm-delay vs IOPS throttle
- dm-delay adds **constant latency** per I/O — predictable, affects writes more than reads.
- IOPS throttle creates **queuing delay** — unpredictable, affects both reads and writes equally.
- At comparable TPS impact levels, IOPS throttle produces worse tail latency (2.2s vs 1.1s at 95th percentile) due to queuing amplification.
- IOPS throttle is more representative of cloud environments where IOPS are provisioned (e.g., AWS EBS gp3 baseline: 3000 IOPS).
