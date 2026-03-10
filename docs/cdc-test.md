# CDC Performance Test

## Pipeline

MariaDB -> Debezium -> Kafka -> JDBC Sink -> YugabyteDB

## Prerequisites

Deploy YugabyteDB cluster first (see [README](../README.md)).

## Component Versions

| Component | Version | Image |
|-----------|---------|-------|
| MariaDB | 11.x | mariadb:11 |
| Apache Kafka | 3.9.2 | apache/kafka:3.9.2 (KRaft, no Zookeeper) |
| Kafka Connect | 7.8.0 | confluentinc/cp-kafka-connect:7.8.0 |
| Debezium MySQL Connector | 3.1.x | via confluent-hub (requires Java 17) |
| Confluent JDBC Sink Connector | 10.x | via confluent-hub |

## Architecture

All CDC components deploy on the master node to avoid occupying worker nodes
(which are dedicated to YugabyteDB tservers).

**Debezium Source Connector:**
- Reads MariaDB binlog (ROW format, FULL row image)
- `ExtractNewRecordState` SMT applied on source side (flattens Debezium envelope
  into simple key-value records, required for JDBC sink compatibility)
- Single task

**JDBC Sink Connector:**
- `insert.mode: upsert` (handles both inserts and updates)
- `pk.mode: record_key`, `pk.fields: id`
- `auto.create: true` (creates table in YugabyteDB automatically)
- Configurable `tasks.max` for parallelism

**Kafka:**
- Single node, KRaft mode (no Zookeeper)
- Replication factor: 1

## Deploy

```bash
make cdc-deploy
```

This deploys MariaDB, Kafka, Kafka Connect (with Debezium + JDBC sink plugins),
creates the test table, and registers both source and sink connectors.

See [cdc/deploy.sh](../cdc/deploy.sh) for details.

## Run Test

```bash
make cdc-test                    # default 10K rows
ROWS=100000 make cdc-test        # 100K rows
```

The test script:
1. Inserts N rows into MariaDB (`val = 0`)
2. Waits for initial sync to YugabyteDB
3. Runs `UPDATE cdc_test SET val = val + 1` on all rows
4. Polls YugabyteDB every 1s until all rows have `val >= 1`
5. Reports: UPDATE time, replication time, throughput

See [cdc/run-test.sh](../cdc/run-test.sh) for details.

## Check Status

```bash
make cdc-status
```

## Cleanup

```bash
make cdc-clean
```

## Tuning Parallelism

By default the pipeline uses 1 Kafka partition and 1 sink task. To increase
parallelism:

1. Pre-create the Kafka topic with more partitions before deploying connectors
2. Set `tasks.max` on the JDBC sink connector

**How partitioning preserves CDC ordering:**
- Debezium uses the row's primary key as the Kafka message key
- Kafka hashes the key: `partition = hash(PK) % num_partitions`
- Same PK always goes to the same partition, so per-row CRUD ordering is guaranteed
- Different PKs go to different partitions, processed by different sink tasks in parallel
- Maximum useful parallelism = number of partitions (extra tasks are idle)
