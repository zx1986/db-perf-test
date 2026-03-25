.PHONY: help deploy-aws deploy-minikube deploy-k3s-virsh clean status ysql
.PHONY: sysbench-prepare sysbench-run sysbench-cleanup sysbench-shell sysbench-logs
.PHONY: report
.PHONY: range-query-test
.PHONY: cdc-deploy cdc-test cdc-status cdc-clean
.PHONY: setup-k3s-virsh teardown-k3s-virsh setup-slow-disk setup-slow-throughput

KUBE_CONTEXT ?= minikube
NAMESPACE ?= yugabyte-test
RELEASE_NAME ?= yb-bench
CHART_DIR := charts/yb-benchmark

# Slow disk simulation parameters
DISK_DELAY_MS ?= 0
DISK_BW_MBPS ?= 0
DISK_IOPS ?= 0

KUBECTL := kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE)
SYSBENCH_POD := deployment/$(RELEASE_NAME)-sysbench

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Deployment
deploy-aws: ## Deploy full stack with AWS-optimized settings
	@helm repo add yugabytedb https://charts.yugabyte.com 2>/dev/null || true
	@helm repo update yugabytedb
	@helm dependency build $(CHART_DIR)
	@helm upgrade --install $(RELEASE_NAME) $(CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--set fullnameOverride=$(RELEASE_NAME) \
		-f $(CHART_DIR)/values-aws.yaml \
		--wait --timeout 15m

deploy-minikube: ## Deploy full stack with minikube-optimized settings
	@helm repo add yugabytedb https://charts.yugabyte.com 2>/dev/null || true
	@helm repo update yugabytedb
	@helm dependency build $(CHART_DIR)
	@helm upgrade --install $(RELEASE_NAME) $(CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--set fullnameOverride=$(RELEASE_NAME) \
		-f $(CHART_DIR)/values-minikube.yaml \
		--wait --timeout 15m

deploy-k3s-virsh: ## Deploy full stack on k3s-virsh cluster
	@helm repo add yugabytedb https://charts.yugabyte.com 2>/dev/null || true
	@helm repo update yugabytedb
	@helm dependency build $(CHART_DIR)
	@helm upgrade --install $(RELEASE_NAME) $(CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--set fullnameOverride=$(RELEASE_NAME) \
		-f $(CHART_DIR)/values-k3s-virsh.yaml \
		--wait --timeout 15m

deploy-benchmarks: ## Deploy benchmarks only (use existing YugabyteDB)
	@helm upgrade --install $(RELEASE_NAME) $(CHART_DIR) \
		--kube-context $(KUBE_CONTEXT) \
		--namespace $(NAMESPACE) \
		--set yugabyte.enabled=false \
		--set fullnameOverride=$(RELEASE_NAME) \
		--wait --timeout 5m

# Sysbench operations - uses scripts from ConfigMap (parameters in values.yaml)
sysbench-prepare: ## Prepare sysbench tables
	$(KUBECTL) exec $(SYSBENCH_POD) -- /scripts/sysbench-prepare.sh

sysbench-run: ## Run sysbench benchmark
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) \
		./scripts/sysbench-run-with-timestamps.sh

sysbench-cleanup: ## Cleanup sysbench tables
	$(KUBECTL) exec $(SYSBENCH_POD) -- /scripts/sysbench-cleanup.sh

sysbench-shell: ## Open shell in sysbench container
	$(KUBECTL) exec -it $(SYSBENCH_POD) -- /bin/bash

sysbench-logs: ## Show sysbench container logs
	$(KUBECTL) logs -f $(SYSBENCH_POD)

# Report generation
report: ## Generate performance report from last benchmark run
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE_NAME=$(RELEASE_NAME) ./scripts/report-generator/report.sh

# Utilities
status: ## Show status of all components
	@echo "=== Pods ==="
	@$(KUBECTL) get pods -o wide
	@echo ""
	@echo "=== Services ==="
	@$(KUBECTL) get svc

ysql: ## Connect to YugabyteDB YSQL shell
	$(KUBECTL) exec -it yb-tserver-0 -- /home/yugabyte/bin/ysqlsh -h yb-tserver-service

port-forward-prometheus: ## Port forward Prometheus to localhost:9090
	$(KUBECTL) port-forward svc/$(RELEASE_NAME)-prometheus 9090:9090

# Range query test
range-query-test: ## Run PK range query performance test
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) ./scripts/range-query-test.sh

# CDC pipeline (MariaDB -> Debezium -> Kafka -> JDBC Sink -> YugabyteDB)
cdc-deploy: ## Deploy CDC pipeline and register connectors
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) ./cdc/deploy.sh

cdc-test: ## Run CDC replication test (10K updates)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) NAMESPACE=$(NAMESPACE) ./cdc/run-test.sh

cdc-status: ## Show CDC connector status
	@$(KUBECTL) exec deployment/cdc-kafka-connect -- curl -sf http://localhost:8083/connectors?expand=status 2>/dev/null | python3 -m json.tool || echo "Kafka Connect not ready"

cdc-clean: ## Delete CDC pipeline resources
	@$(KUBECTL) delete -f cdc/ --ignore-not-found

# k3s-virsh infrastructure
setup-k3s-virsh: ## Create VMs and install k3s cluster
	@./scripts/setup-k3s-virsh.sh

teardown-k3s-virsh: ## Destroy VMs and remove k3s cluster
	@./scripts/teardown-k3s-virsh.sh

setup-slow-disk: ## Setup tserver storage with optional dm-delay (DISK_DELAY_MS=50)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) DISK_DELAY_MS=$(DISK_DELAY_MS) ./scripts/setup-slow-disk.sh

setup-slow-throughput: ## Throttle VM disk throughput (DISK_BW_MBPS=10 DISK_IOPS=200)
	@DISK_BW_MBPS=$(DISK_BW_MBPS) DISK_IOPS=$(DISK_IOPS) ./scripts/setup-slow-throughput.sh

# Cleanup
clean: ## Delete all resources
	@echo "Uninstalling $(RELEASE_NAME)..."
	@helm --kube-context $(KUBE_CONTEXT) uninstall $(RELEASE_NAME) -n $(NAMESPACE) 2>/dev/null || true
	@echo "Deleting PVCs..."
	@$(KUBECTL) delete pvc -l app=yb-tserver 2>/dev/null || true
	@$(KUBECTL) delete pvc -l app=yb-master 2>/dev/null || true
	@echo "Deleting namespace..."
	@kubectl --context $(KUBE_CONTEXT) delete namespace $(NAMESPACE) --ignore-not-found
