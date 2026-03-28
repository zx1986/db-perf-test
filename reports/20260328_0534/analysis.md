# Bottleneck Analysis: 4 vCPU Pinned Workers + WAL Tuning + Triggers

**Report:** 20260328_0534
**Config:** dm-delay=5ms, IOPS cap=80, 3 tservers (4 vCPU / 2 P-cores pinned), 24 threads
**Tuning:** `bytes_durable_wal_write_mb=4`, `interval_durable_wal_write_ms=5000`
**Workload:** oltp_read_write, write-heavy + trigger (cleanup_duplicate_k)

## Summary

| Metric | Value |
|--------|-------|
| TPS | 30.43 |
| QPS | 1,454.06 |
| p95 Latency | 1,235.62 ms |
| Errors/s | 2.29 |

## Progression: Effect of Doubling CPU

All runs: same dm-delay=5ms, IOPS=80, triggers active, WAL tuning (4MB/5s).

| Metric | 2 vCPU (1 P-core) | 4 vCPU (2 P-cores) | Change |
|--------|-------------------|-------------------|--------|
| **TPS** | 23.26 | **30.43** | **+31%** |
| QPS | 1,107 | 1,454 | +31% |
| p95 Latency | 1,506 ms | 1,236 ms | -18% |
| WAL sync rate | 6.4 ops/s | 7.4 ops/s | +16% |
| WAL sync latency | 69 ms | 78 ms | +13% |
| Disk Write IOPS | ~4 | ~28 | +7x |
| Node CPU total | 77-96% | **64-74%** | freed headroom |
| iowait | 1-6% | 4-5% | similar |
| **steal** | 3.3% | **11-12%** | **+3.5x** |

## Bottleneck: CPU Steal from Host Overcommit

### Evidence

#### 1. Node CPU has headroom but steal is high

Mid-run Prometheus measurements:

| Node | CPU total | iowait | steal |
|------|-----------|--------|-------|
| ygdb-worker-1 | 71.9% | 5.3% | **12.4%** |
| ygdb-worker-2 | 64.3% | 4.9% | **11.1%** |
| ygdb-worker-3 | 73.9% | 3.6% | **11.4%** |

Workers are only 64-74% busy inside the VM, but 11-12% of CPU time is being **stolen by the hypervisor**. This means the physical P-cores are overloaded.

#### 2. Why steal increased

With the previous 2-vCPU config (1 P-core per worker), each worker had exclusive access to its P-core. Now with 4 vCPUs (2 P-cores per worker):
- 3 workers x 2 P-cores = 6 P-cores = all 6 P-cores consumed by workers
- Control node (2 shared vCPUs) has no dedicated P-cores left
- Host OS processes also need CPU time
- The control node and host processes compete for P-core time, causing steal on workers

#### 3. Disk I/O is not the bottleneck

| tserver | Write IOPS | IOPS cap | WAL sync rate |
|---------|-----------|----------|---------------|
| yb-tserver-0 | 29.1 | 80 | 7.6/s |
| yb-tserver-2 | 27.2 | 80 | 7.2/s |

IOPS at ~28 out of 80 cap (35% utilization). iowait at 4-5% — not a constraint.

#### 4. WAL sync latency slightly increased

WAL sync went from 69ms to 78ms despite same dm-delay and lower IOPS pressure. The increase is likely from CPU steal — the sync thread gets preempted by the hypervisor, adding latency.

## Full Optimization Journey

| Run | CPU | dm-delay | IOPS | WAL tuning | Triggers | TPS | Bottleneck |
|-----|-----|----------|------|-----------|----------|-----|------------|
| Baseline | 2 vCPU | 5ms | 500 | default | no | 50.6 | CPU |
| + IOPS cap | 2 vCPU | 5ms | 80 | default | no | 34.8 | IOPS |
| + Triggers | 2 vCPU | 5ms | 80 | default | yes | 17.5 | IOPS (amplified) |
| + WAL 4MB/5s | 2 vCPU | 5ms | 80 | 4MB/5s | yes | 23.3 | CPU |
| + 4 vCPU | 4 vCPU | 5ms | 80 | 4MB/5s | yes | **30.4** | **CPU steal** |

## Next Steps

To push further, options are:
1. **Reduce control node CPU** to free P-cores (e.g., control on E-cores only)
2. **Use fewer workers with more CPU** (2 workers x 3 P-cores instead of 3 x 2)
3. **Accept the steal** and increase threads to fill the idle CPU gaps
