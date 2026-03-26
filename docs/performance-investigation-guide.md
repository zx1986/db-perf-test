# YugabyteDB Performance Investigation Guide

A practical guide for identifying performance bottlenecks in YugabyteDB, based on measured results from the k3s-virsh performance tuning lab.

## Key Diagnostic Tools

### 1. Tserver Prometheus Metrics (primary tool)

Each tserver exposes metrics on port 9000 at `/prometheus-metrics`. These are the most reliable source for bottleneck identification.

**WAL (Write-Ahead Log) metrics:**
```promql
# WAL fsync latency - time to sync WAL to disk (per tserver)
sum(rate(log_sync_latency_sum[1m])) by (instance)
  / sum(rate(log_sync_latency_count[1m])) by (instance)

# WAL group commit latency - batched append+sync
sum(rate(log_group_commit_latency_sum[1m])) by (instance)
  / sum(rate(log_group_commit_latency_count[1m])) by (instance)
```

**RPC latency metrics:**
```promql
# Write RPC latency (end-to-end write path)
sum(rate(handler_latency_yb_tserver_TabletServerService_Write_sum[1m])) by (instance)
  / sum(rate(handler_latency_yb_tserver_TabletServerService_Write_count[1m])) by (instance)

# Read RPC latency
sum(rate(handler_latency_yb_tserver_TabletServerService_Read_sum[1m])) by (instance)
  / sum(rate(handler_latency_yb_tserver_TabletServerService_Read_count[1m])) by (instance)

# Raft consensus replication latency
sum(rate(handler_latency_yb_consensus_ConsensusService_UpdateConsensus_sum[1m])) by (instance)
  / sum(rate(handler_latency_yb_consensus_ConsensusService_UpdateConsensus_count[1m])) by (instance)
```

**Throughput metrics:**
```promql
# Write operations per second per tserver
sum(rate(handler_latency_yb_tserver_TabletServerService_Write_count[1m])) by (instance)
```

### 2. Container/VM Metrics

```promql
# Container CPU usage per tserver (percentage of 1 core)
sum(rate(container_cpu_usage_seconds_total{container="yb-tserver"}[1m])) by (pod) * 100

# Node-level disk write IOPS
rate(node_disk_writes_completed_total[1m])
```

### 3. Tserver Web UI

- `/rpcz` — in-flight RPCs with elapsed time (real-time snapshot)
- `/tablets` — tablet leaders and their distribution
- `/operations` — in-flight tablet operations

### 4. pg_stat_activity (limited usefulness)

```sql
SELECT state, wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state != 'idle'
GROUP BY state, wait_event_type, wait_event
ORDER BY count(*) DESC;
```

**Limitation:** YugabyteDB replaces PostgreSQL's buffer manager with DocDB/RocksDB, so most queries show as `active` with no `wait_event_type` regardless of whether the bottleneck is CPU, disk, or Raft consensus. This tool is mainly useful for detecting lock waits, not I/O or CPU bottlenecks.

## Bottleneck Identification

### Quick Decision Tree

```
Is container CPU near the vCPU limit (e.g., ~190% on 2 vCPUs)?
  YES → CPU-bound (see CPU Bottleneck below)
  NO  → Check WAL fsync latency
        Is log_sync_latency > 10ms?
          YES → Disk I/O bound (see Disk Bottleneck below)
          NO  → Check Write RPC latency
                Is Write RPC latency high but WAL fsync low?
                  YES → Network or Raft consensus issue
                  NO  → Check thread count and lock contention
```

### CPU Bottleneck

**Symptoms (measured):**

| Metric | Normal (24 threads) | CPU-bound (72 threads) |
|---|---|---|
| Container CPU | 126% | 168% (near 200% limit) |
| VM CPU | 80% | 91-96% |
| TPS | 47.5 | 47.8 (flat despite 3x threads) |
| Write RPC latency | 6-8 ms | 20-30 ms (CPU queuing) |
| WAL fsync | 3.5-4.6 ms | 3.8-5.4 ms (unchanged) |
| 95th latency | 612 ms | 1771 ms (3x worse) |
| Errors/sec | 0.33 | 1.64 (5x more timeouts) |

**How to identify:**
1. Container CPU approaches the vCPU limit (200% on 2 vCPUs)
2. TPS plateaus — adding more threads doesn't increase throughput
3. Write RPC latency increases but WAL fsync stays constant
4. VM-level CPU is >90%
5. Latency and errors increase proportionally with thread count

**Key indicator:** WAL fsync latency is LOW but Write RPC latency is HIGH. The gap is CPU queuing time.

### Disk Latency Bottleneck (dm-delay style)

**Symptoms (measured with 4ms dm-delay):**

| Metric | No delay | 4ms dm-delay |
|---|---|---|
| Container CPU | 126% | 69% (idle, waiting on disk) |
| TPS | 47.5 | 30.9 (-35%) |
| WAL fsync | 3.5-4.6 ms | 31.8-32.6 ms (~8x amplification) |
| Write RPC | 6-8 ms | 11.8-13.5 ms |
| Read RPC | 0.24-0.34 ms | 0.41-0.43 ms (barely affected) |
| Raft consensus | 0.5-1.2 ms | 2.2-2.7 ms |
| System CPU | 14.6% | 29.8% (kernel I/O work) |

**How to identify:**
1. WAL fsync latency is HIGH (>10ms)
2. Container CPU is LOW despite available capacity
3. System CPU (kernel) is elevated — I/O scheduling overhead
4. Read RPCs are largely unaffected (served from block cache)
5. TPS drops even with low thread counts

**Key indicator:** Container CPU is LOW but WAL fsync is HIGH. The tserver has CPU to spare but is waiting on disk.

**Note on WAL fsync amplification:** A 4ms per-I/O delay resulted in ~32ms WAL fsync because each fsync involves multiple I/O operations internally. Expect 6-10x amplification from raw disk latency to WAL fsync time.

### Disk IOPS Bottleneck (throughput cap)

**Symptoms (measured with 200 IOPS cap):**

| Metric | No limit | 200 IOPS cap |
|---|---|---|
| TPS | 47.5 | 20.5 (-57%) |
| WAL fsync | 3.5-4.6 ms | 178-202 ms (queuing) |
| Write RPC | 6-8 ms | 30-32 ms |
| Read RPC | 0.24-0.34 ms | 0.9-1.6 ms (affected!) |
| Raft consensus | 0.5-1.2 ms | 13-15 ms |
| Actual write IOPS | ~300 | ~200 (hitting cap) |
| 95th latency | 612 ms | 2199 ms |

**How to identify:**
1. WAL fsync latency is VERY HIGH (>100ms) with high variance
2. Both reads AND writes are slow (shared IOPS budget)
3. Actual disk IOPS from node_exporter match the provisioned limit
4. TPS is highly variable (bursty — queues drain then refill)
5. 95th latency is much worse than average (queuing tail)

**Key difference from latency bottleneck:** IOPS cap affects reads too, because reads and writes compete for the same I/O budget. dm-delay (latency) mainly affects writes since reads are served from cache.

### Asymmetric / Single Slow Node

**Symptoms (measured with 1 of 3 nodes at 4ms dm-delay):**

| Metric | Slow tserver-0 | Normal tserver-1 | Normal tserver-2 |
|---|---|---|---|
| WAL fsync | 32.0 ms | 3.2 ms | 3.2 ms |
| Write RPC | 16.2 ms | 4.3 ms | 4.2 ms |
| Raft consensus | 6.3 ms | 0.5 ms | 0.6 ms |
| Read RPC | 0.59 ms | 0.21 ms | 0.23 ms |

Overall TPS: 37.4 (vs 47.5 baseline = **-21% from one slow node**)

**How to identify:**
1. WAL fsync or Write RPC latency differs significantly across tservers
2. One tserver has metrics 5-10x worse than others
3. Thread fairness stddev is high (uneven query times)
4. TPS drop is larger than expected (~21% for 1/3 slow, not ~0%)

**Why one slow node affects the whole cluster:**
- The slow node is a **tablet leader** for ~1/3 of tablets
- As leader, it must sync its LOCAL WAL before responding — followers can't help
- Raft majority-ack doesn't help when the leader itself is slow
- All queries hitting those tablets experience the slow path

**How to observe in real-time:**
```promql
# Compare WAL fsync across tservers — outlier = slow node
sum(rate(log_sync_latency_sum[30s])) by (instance)
  / sum(rate(log_sync_latency_count[30s])) by (instance)

# Compare Write RPC latency — confirms user-facing impact
sum(rate(handler_latency_yb_tserver_TabletServerService_Write_sum[30s])) by (instance)
  / sum(rate(handler_latency_yb_tserver_TabletServerService_Write_count[30s])) by (instance)

# Write ops/sec per tserver — should be equal (not a routing issue)
sum(rate(handler_latency_yb_tserver_TabletServerService_Write_count[30s])) by (instance)
```

## Investigation Workflow

### Step 1: Establish baseline metrics

Before investigating, capture these baseline metrics under normal load:

```
Container CPU per tserver    → expected range for your hardware
WAL fsync latency            → depends on disk (NVMe: <5ms, SSD: 5-15ms, HDD: >15ms)
Write RPC latency            → typically 2-3x WAL fsync (includes Raft)
Read RPC latency             → typically <1ms (block cache hits)
```

### Step 2: Compare against baseline

When performance degrades, compare current metrics against baseline:

| Changed metric | Unchanged metric | Likely bottleneck |
|---|---|---|
| WAL fsync UP | Container CPU DOWN | Disk latency |
| WAL fsync UP, reads also slow | Container CPU DOWN | Disk IOPS cap |
| Write RPC UP | WAL fsync SAME | CPU saturation |
| One tserver different | Others normal | Single node issue |
| All metrics UP | VM steal time UP | Host CPU contention |

### Step 3: Drill down

- **Disk issue confirmed** → check `node_disk_io_time_seconds_total`, `node_disk_writes_completed_total` from node_exporter. Check host-level disk with `iostat`.
- **CPU issue confirmed** → check VM steal time, check if CPU limits/requests are too low, check for CPU pinning.
- **Single node issue** → check that specific node's disk health, network connectivity, check if it's running extra workloads. Consider moving tablet leaders away with `yb-admin`.
- **Raft consensus slow** → check network latency between nodes with `ping`. Check if follower nodes have disk issues (they need to sync WAL too for UpdateConsensus).

## Reference: Measured Baselines

All measured on k3s-virsh lab: 3 tservers, 2 dedicated vCPUs each, 8 GB RAM, RF=3, 24 sysbench threads.

| Scenario | TPS | WAL fsync | Write RPC | Container CPU |
|---|---|---|---|---|
| No bottleneck | 47.5 | 3.5-4.6 ms | 6-8 ms | 126% |
| CPU-bound (72 threads) | 47.8 | 3.8-5.4 ms | 20-30 ms | 168% |
| 2ms disk delay | 34.0 | ~32 ms | ~13 ms | 67% |
| 4ms disk delay | 30.9 | ~32 ms | ~13 ms | 69% |
| 200 IOPS cap | 20.5 | ~200 ms | ~31 ms | — |
| 1 slow node (4ms) | 37.4 | 32ms/3ms/3ms | 16ms/4ms/4ms | — |
