#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
KUBECTL="kubectl --context $KUBE_CONTEXT -n $NAMESPACE"
ROWS="${1:-10000}"

mariadb_sql() {
    $KUBECTL exec deployment/cdc-mariadb -- mariadb -udebezium -pdebezium testdb -sNe "$1"
}

ysql() {
    $KUBECTL exec yb-tserver-0 -- /home/yugabyte/bin/ysqlsh -h yb-tserver-service -t -c "$1" 2>/dev/null | tr -d ' \n'
}

echo "=== CDC Replication Test: ${ROWS} Updates ==="
echo ""

# Step 1: Insert initial rows
echo "Step 1: Inserting $ROWS rows into MariaDB..."
mariadb_sql "TRUNCATE TABLE cdc_test;"
mariadb_sql "INSERT INTO cdc_test (val) SELECT 0 FROM seq_1_to_${ROWS};"
ROW_COUNT=$(mariadb_sql "SELECT COUNT(*) FROM cdc_test;")
echo "  MariaDB row count: $ROW_COUNT"

# Step 2: Wait for initial sync to YugabyteDB
echo ""
echo "Step 2: Waiting for initial sync to YugabyteDB..."
SYNC_START=$(date +%s)
while true; do
    COUNT=$(ysql "SELECT COUNT(*) FROM cdc_test WHERE val = 0;" || echo "0")
    ELAPSED=$(( $(date +%s) - SYNC_START ))
    echo "  [$ELAPSED s] Synced: $COUNT / $ROWS"
    if [ "$COUNT" -ge "$ROWS" ]; then
        break
    fi
    if [ "$ELAPSED" -gt 300 ]; then
        echo "ERROR: Initial sync timed out after 5 min"
        echo "Check connector status: kubectl --context $KUBE_CONTEXT -n $NAMESPACE exec deployment/cdc-kafka-connect -- curl -s http://localhost:8083/connectors/sink-yugabyte/status"
        exit 1
    fi
    sleep 2
done
echo "  Initial sync complete in ${ELAPSED}s"

# Step 3: Run UPDATE benchmark
echo ""
echo "Step 3: Running $ROWS updates in MariaDB..."
T1=$(date +%s%N)

mariadb_sql "UPDATE cdc_test SET val = val + 1;"

T2=$(date +%s%N)
UPDATE_MS=$(( (T2 - T1) / 1000000 ))
echo "  UPDATE executed in ${UPDATE_MS}ms"

# Step 4: Wait for updates to replicate
echo ""
echo "Step 4: Waiting for updates to replicate..."
while true; do
    COUNT=$(ysql "SELECT COUNT(*) FROM cdc_test WHERE val >= 1;" || echo "0")
    NOW=$(date +%s%N)
    ELAPSED_MS=$(( (NOW - T1) / 1000000 ))
    echo "  [${ELAPSED_MS}ms] Replicated: $COUNT / $ROWS"
    if [ "$COUNT" -ge "$ROWS" ]; then
        break
    fi
    if [ "$ELAPSED_MS" -gt 300000 ]; then
        echo "ERROR: Replication timed out after 5 min"
        exit 1
    fi
    sleep 1
done

T3=$(date +%s%N)
TOTAL_MS=$(( (T3 - T1) / 1000000 ))
REPL_MS=$(( (T3 - T2) / 1000000 ))

echo ""
echo "=== Results ==="
echo "Rows:             $ROWS"
echo "UPDATE time:      ${UPDATE_MS}ms"
echo "Replication time: ${REPL_MS}ms (from commit to last row in YugabyteDB)"
echo "Total time:       ${TOTAL_MS}ms (end-to-end)"
echo "Throughput:       $(( ROWS * 1000 / TOTAL_MS )) updates/s (end-to-end)"
