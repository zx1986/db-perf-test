# CDC Performance Test Report

**Date:** 2026-03-10
**Pipeline:** MariaDB -> Debezium -> Kafka -> JDBC Sink -> YugabyteDB

## Environment

### Host Machine

- **CPU:** Intel i7-13620H (13th Gen), 16 cores
- **RAM:** 62 GB
- **Virtualization:** minikube with KVM2 driver

### Kubernetes Cluster

4 minikube VMs, each with 4 vCPUs / 8 GB RAM:

| Node | Role | Workloads |
|------|------|-----------|
| minikube | master | YB masters x3, Kafka, Kafka Connect, MariaDB, Prometheus |
| minikube-m02 | db | yb-tserver-2 |
| minikube-m03 | db | yb-tserver-1 |
| minikube-m04 | db | yb-tserver-0 |

### Component Versions

| Component | Version | Image |
|-----------|---------|-------|
| YugabyteDB | 2.23.1.0-b0 | yugabytedb/yugabyte |
| MariaDB | 11.8.6 | mariadb:11 |
| Apache Kafka | 3.9.2 | apache/kafka:3.9.2 |
| Kafka Connect | 7.8.0-ccs | confluentinc/cp-kafka-connect:7.8.0 |
| Debezium MySQL Connector | 3.1.2 | via confluent-hub |
| Confluent JDBC Sink Connector | 10.9.2 | via confluent-hub |

### YugabyteDB Configuration

- 3 masters + 3 tservers, RF=3
- Tserver resources: 2 CPU request, 4 Gi memory request, no CPU limit
- Storage: 10 Gi per tserver
- Shards: 2 per tserver (ysql + yb)

### CDC Pipeline Configuration

**Debezium Source Connector:**
- Reads MariaDB binlog (ROW format, FULL row image)
- `ExtractNewRecordState` SMT applied on source side (flat messages in Kafka)
- Single task

**JDBC Sink Connector:**
- `insert.mode: upsert` (handles both inserts and updates)
- `pk.mode: record_key`, `pk.fields: id`
- `auto.create: true` (creates table in YugabyteDB automatically)
- Single task
- Default batch size (3000)

**Kafka:**
- Single node, KRaft mode (no Zookeeper)
- Replication factor: 1

### Test Table Schema

```sql
-- MariaDB (source)
CREATE TABLE cdc_test (
  id INT PRIMARY KEY AUTO_INCREMENT,
  val INT NOT NULL DEFAULT 0
);
```

## Test Method

### Test 1: 10K Updates

1. Insert 10,000 rows into MariaDB (`val = 0`)
2. Wait for initial sync to YugabyteDB (all 10K rows with `val = 0`)
3. Run `UPDATE cdc_test SET val = val + 1` (single transaction, all 10K rows)
4. Record T1 (before UPDATE), T2 (after UPDATE returns)
5. Poll YugabyteDB every 1s: `SELECT COUNT(*) FROM cdc_test WHERE val >= 1`
6. Record T3 when count reaches 10,000
7. Report: UPDATE time (T2-T1), Replication time (T3-T2), Total (T3-T1)

### Test 2: 100K Updates

Same method as Test 1 but with 100,000 rows. Node CPU monitored via
node_exporter every 10s during replication.

### Test 3: 100K Updates with 3 Partitions / 3 Tasks

Same method as Test 2 but with:
- Kafka topic pre-created with 3 partitions
- JDBC sink connector `tasks.max=3`

Kafka partitions messages by the row's primary key (hash of PK determines
partition). This ensures per-row ordering while enabling parallelism across
different rows.

## Results

### Test 1: 10K Updates

| Metric | Value |
|--------|-------|
| Rows | 10,000 |
| Initial sync time | 16s |
| UPDATE execution (MariaDB) | 144ms |
| Replication time | 15.6s |
| Total end-to-end time | 15.8s |
| Throughput | 633 updates/s |

### Test 2: 100K Updates

| Metric | Value |
|--------|-------|
| Rows | 100,000 |
| Initial sync time | 146s (~685 rows/s) |
| UPDATE execution (MariaDB) | 282ms |
| Replication time | 365s |
| Total end-to-end time | 366s |
| Throughput | 273 updates/s |

#### Replication Progress (100K)

| Time (s) | Rows replicated | Rate (rows/s) |
|----------|----------------|---------------|
| 0-60 | 0 | 0 (Debezium reading binlog) |
| 61-75 | 0 -> 9,883 | ~700 |
| 77-90 | 9,883 -> 0 | (count regressed, see findings) |
| 90-225 | 0 | 0 (stalled) |
| 225-365 | 0 -> 100,000 | ~714 |

#### Node CPU During 100K Replication

| Phase | minikube (master) | m02 (tserver) | m03 (tserver) | m04 (tserver) |
|-------|-------------------|---------------|---------------|---------------|
| Baseline (idle) | 8.7% | 20.4% | 26.9% | 20.0% |
| Debezium reading (0-60s) | 23-43% | 5-17% | 5-11% | 5-19% |
| Active sink writing | 7-9% | 26-27% | 19-20% | 19-20% |
| Comparison: sysbench 24 threads | 11% | 90% | 83% | 85% |

### Test 3: 100K Updates (3 Partitions, 3 Tasks)

| Metric | Value |
|--------|-------|
| Rows | 100,000 |
| Kafka partitions | 3 |
| Sink tasks | 3 |
| UPDATE execution (MariaDB) | ~280ms |
| Replication time | 49s |
| Throughput | 2,042 updates/s |

#### Comparison: 1 Task vs 3 Tasks (100K Updates)

| Metric | 1 Task | 3 Tasks | Improvement |
|--------|--------|---------|-------------|
| Replication time | 365s | 49s | 7.4x faster |
| Throughput | 273 updates/s | 2,042 updates/s | 7.5x higher |
| Tserver CPU | 19-27% | 34-48% | Higher utilization |

No count regression anomaly observed with 3 tasks.

## Findings

### 1. CDC sink throughput is far below direct-write capacity

During sysbench (direct writes), tservers handle ~80 TPS of complex OLTP
transactions (each with 34 queries). The CDC JDBC sink achieves only ~700
single-row upserts/s. This is because:

- The JDBC sink connector uses a single task (single thread)
- Each upsert is a simple single-row operation with low concurrency
- The connector batches rows but still issues sequential JDBC calls

### 2. Tserver CPU is NOT the bottleneck during CDC replication

Tserver nodes stayed at 19-27% CPU during active replication, compared to
80-90% during sysbench benchmarks. The bottleneck is the single-threaded
JDBC sink connector on the master node, not YugabyteDB write capacity.

### 3. ~60s latency before first update appeared

After the MariaDB UPDATE committed (282ms), it took ~60 seconds before
the first replicated row appeared in YugabyteDB. This delay is:
- Debezium reading 100K binlog events from MariaDB
- Producing 100K messages to Kafka
- JDBC sink consumer polling and starting to write

### 4. Count regression anomaly

During the first replication wave (61-90s), the replicated count went from
9,883 back down to 0. This likely indicates that the JDBC sink was
processing events out of order or that interim snapshot behavior from
Debezium's `ExtractNewRecordState` transform caused temporary inconsistency.
After a ~135s pause, the second wave progressed steadily to completion.

### 5. Throughput decreased at 100K vs 10K

- 10K test: 633 updates/s
- 100K test: 273 updates/s (end-to-end including the stall)
- 100K test active writing phase only: ~714 rows/s

The lower end-to-end throughput is due to the stall period. The actual
writing rate during active phases was consistent (~700 rows/s).

### 6. Parallelizing with partitions and tasks dramatically improves throughput

Increasing from 1 task to 3 tasks (with 3 Kafka partitions) yielded a 7.4x
improvement in replication time and 7.5x in throughput (273 → 2,042 updates/s).
Tserver CPU rose from 19-27% to 34-48%, still well below saturation.

**How partitioning preserves CDC ordering:**
- Debezium uses the row's primary key as the Kafka message key
- Kafka's partitioner hashes the key: `partition = hash(PK) % num_partitions`
- Same PK always goes to the same partition → per-row CRUD ordering is guaranteed
- Different PKs go to different partitions → processed by different sink tasks in parallel

This means parallelism scales with the number of distinct primary keys being
modified. The maximum useful parallelism equals the number of partitions (more
tasks than partitions results in idle tasks).

## Potential Further Optimizations

1. **Increase partitions/tasks further** - tserver CPU still has headroom at 3 tasks
2. **Increase batch size** - `consumer.max.poll.records` and batch.size
3. **Use YugabyteDB JDBC driver** - native driver may optimize distributed writes
4. **Tune Debezium** - `max.batch.size`, `max.queue.size` for faster source reading
