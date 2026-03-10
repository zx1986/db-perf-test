#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
KUBECTL="kubectl --context $KUBE_CONTEXT -n $NAMESPACE"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying CDC Pipeline ==="
echo "Context: $KUBE_CONTEXT, Namespace: $NAMESPACE"

# Deploy all resources
$KUBECTL apply -f "$SCRIPT_DIR/mariadb.yaml"
$KUBECTL apply -f "$SCRIPT_DIR/kafka.yaml"
$KUBECTL apply -f "$SCRIPT_DIR/kafka-connect.yaml"

# Wait for MariaDB
echo ""
echo "Waiting for MariaDB..."
$KUBECTL rollout status deployment/cdc-mariadb --timeout=120s

# Wait for Kafka
echo "Waiting for Kafka..."
$KUBECTL rollout status deployment/cdc-kafka --timeout=120s

# Wait for Kafka Connect (takes longer due to plugin downloads)
echo "Waiting for Kafka Connect (downloading plugins, may take 2-3 min)..."
$KUBECTL rollout status deployment/cdc-kafka-connect --timeout=300s

# Wait for Connect REST API to be ready
echo "Waiting for Kafka Connect REST API..."
for i in $(seq 1 60); do
    if $KUBECTL exec deployment/cdc-kafka-connect -- curl -sf http://localhost:8083/connectors >/dev/null 2>&1; then
        echo "  Kafka Connect REST API is ready."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "ERROR: Kafka Connect REST API not ready after 5 min"
        exit 1
    fi
    sleep 5
done

# Create test table in MariaDB
echo ""
echo "Creating test table in MariaDB..."
$KUBECTL exec deployment/cdc-mariadb -- mariadb -udebezium -pdebezium testdb -e "
CREATE TABLE IF NOT EXISTS cdc_test (
  id INT PRIMARY KEY AUTO_INCREMENT,
  val INT NOT NULL DEFAULT 0
);
"

# Register Debezium source connector
echo "Registering Debezium source connector..."
$KUBECTL exec deployment/cdc-kafka-connect -- curl -sf -X POST \
    -H "Content-Type: application/json" \
    http://localhost:8083/connectors \
    -d '{
  "name": "source-mariadb",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "database.hostname": "cdc-mariadb",
    "database.port": "3306",
    "database.user": "debezium",
    "database.password": "debezium",
    "database.server.id": "1",
    "topic.prefix": "cdc",
    "database.include.list": "testdb",
    "table.include.list": "testdb.cdc_test",
    "schema.history.internal.kafka.bootstrap.servers": "cdc-kafka:9092",
    "schema.history.internal.kafka.topic": "_schema-history",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "true"
  }
}' | python3 -m json.tool 2>/dev/null || true

echo ""

# Register JDBC sink connector
echo "Registering JDBC sink connector..."
$KUBECTL exec deployment/cdc-kafka-connect -- curl -sf -X POST \
    -H "Content-Type: application/json" \
    http://localhost:8083/connectors \
    -d '{
  "name": "sink-yugabyte",
  "config": {
    "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
    "connection.url": "jdbc:postgresql://yb-tserver-service:5433/yugabyte",
    "connection.user": "yugabyte",
    "connection.password": "yugabyte",
    "topics": "cdc.testdb.cdc_test",
    "table.name.format": "cdc_test",
    "insert.mode": "upsert",
    "pk.mode": "record_key",
    "pk.fields": "id",
    "auto.create": "true",
    "auto.evolve": "true"
  }
}' | python3 -m json.tool 2>/dev/null || true

echo ""

# Show connector status
echo "=== Connector Status ==="
sleep 3
$KUBECTL exec deployment/cdc-kafka-connect -- \
    curl -sf http://localhost:8083/connectors/source-mariadb/status 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  source-mariadb: pending"
$KUBECTL exec deployment/cdc-kafka-connect -- \
    curl -sf http://localhost:8083/connectors/sink-yugabyte/status 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  sink-yugabyte: pending"

echo ""
echo "=== CDC Pipeline Deployed ==="
echo "Next: run 'cdc/run-test.sh' to test replication"
