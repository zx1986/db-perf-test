#!/bin/bash
set -e

# Report generation script for Sysbench stress tests
# Reads timestamps from output files and generates HTML report from Prometheus metrics

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
KUBE_CONTEXT="${KUBE_CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-yugabyte-test}"
RELEASE_NAME="${RELEASE_NAME:-yb-bench}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/reports}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://${RELEASE_NAME}-prometheus:9090}"

# Read timestamps
START_FILE="${PROJECT_ROOT}/output/sysbench/RUN_START_TIME.txt"
END_FILE="${PROJECT_ROOT}/output/sysbench/RUN_END_TIME.txt"

if [[ ! -f "$START_FILE" ]]; then
    echo "Error: Start timestamp file not found: $START_FILE"
    echo "Run 'make sysbench-run' first to generate timestamp files."
    exit 1
fi

if [[ ! -f "$END_FILE" ]]; then
    echo "Error: End timestamp file not found: $END_FILE"
    echo "The benchmark may still be running or failed to complete."
    exit 1
fi

START_TIME=$(cat "$START_FILE")
END_TIME=$(cat "$END_FILE")

echo "=== Sysbench Report Generator ==="
format_date() {
    if [[ "$(uname)" == "Darwin" ]]; then
        date -r "$1" '+%Y-%m-%d %H:%M:%S'
    else
        date -d "@$1" '+%Y-%m-%d %H:%M:%S'
    fi
}

echo "Start time: $(format_date ${START_TIME})"
echo "End time: $(format_date ${END_TIME})"
echo "Duration: $(( (END_TIME - START_TIME) / 60 )) minutes"
echo ""

# Execute
echo "Generating report..."
REPORT_OUTPUT=$(python3 "${SCRIPT_DIR}/generate_report.py" \
    --start "$START_TIME" \
    --end "$END_TIME" \
    --kube-context "$KUBE_CONTEXT" \
    --namespace "$NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --prometheus-url "$PROMETHEUS_URL" \
    --output-dir "$OUTPUT_DIR" \
    --title "Sysbench Stress Test Report" \
    --pods "yb-tserver.*" "yb-master.*" "sysbench.*")

echo "$REPORT_OUTPUT"

# Extract report directory and run parser
REPORT_DIR=$(echo "$REPORT_OUTPUT" | grep "Report saved to:" | sed 's|Report saved to: ||' | xargs dirname)
if [[ -n "$REPORT_DIR" && -d "$REPORT_DIR" ]]; then
    echo ""
    echo "=== Running Report Parser ==="
    python3 "${PROJECT_ROOT}/scripts/report-parser.py" "$REPORT_DIR" | tee "${REPORT_DIR}/summary.txt"
    echo "Summary saved to: ${REPORT_DIR}/summary.txt"
fi

echo ""
echo "=== Report Generation Complete ==="
