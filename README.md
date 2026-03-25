# YugabyteDB Benchmark Infrastructure

Benchmark infrastructure for evaluating YugabyteDB performance using sysbench OLTP workloads.

## Architecture

```
┌─────────────────┐                ┌──────────────────┐
│    Sysbench     │───────────────▶│   YugabyteDB     │
│   (OLTP)        │   PostgreSQL   │   (YSQL:5433)    │
└─────────────────┘                └──────────────────┘
                                          │
                                   ┌──────▼──────┐
                                   │  Prometheus │
                                   └─────────────┘
```

**Components:**
- **Sysbench** - Database benchmark tool using YugabyteDB's fork with YB-specific optimizations
- **YugabyteDB** - Distributed PostgreSQL-compatible database (deployed as Helm subchart)
- **Prometheus** - Metrics collection for performance reports

## Environments

Three deployment environments are supported:

| Environment | Infra | Use Case |
|---|---|---|
| **minikube** | minikube (KVM2) | Local development, quick benchmarks |
| **AWS** | EKS (m6i.xlarge) | Production-scale benchmarks |
| **k3s-virsh** | libvirt VMs + k3s | Performance tuning lab with I/O simulation |

### k3s-virsh: Performance Tuning Lab

Uses libvirt/virsh-managed VMs with k3s for full control over infrastructure resources:

- **dm-delay** — inject per-I/O latency on tserver storage (inside VMs)
- **virsh blkdeviotune** — throttle disk throughput/IOPS (from host, requires `cache=none`)
- **virsh setvcpus / setmem** — adjust CPU/memory per VM

Topology: 1 control node (4 CPU / 8 GB) + 3 worker nodes (4 CPU / 8 GB), Ubuntu 24.04.

## Prerequisites

- kubectl
- Helm 3.x
- Kubernetes cluster (minikube, EKS, or k3s-virsh)
- Python 3 with Jinja2 (`pip install Jinja2`) for report generation
- For k3s-virsh: libvirt, virt-install, qemu-img, genisoimage

## Quick Start

### Minikube

```bash
./scripts/setup-minikube.sh
make deploy-minikube
make sysbench-prepare && make sysbench-run
make report
```

### AWS

```bash
make deploy-aws KUBE_CONTEXT=my-eks-cluster
make sysbench-prepare KUBE_CONTEXT=my-eks-cluster
make sysbench-run KUBE_CONTEXT=my-eks-cluster
```

### k3s-virsh (Performance Tuning Lab)

```bash
# Create VMs and install k3s
./scripts/setup-k3s-virsh.sh

# Setup storage (with optional disk latency)
DISK_DELAY_MS=50 ./scripts/setup-slow-disk.sh

# Deploy YugabyteDB
make deploy-k3s-virsh KUBE_CONTEXT=k3s-ygdb

# Run benchmark
make sysbench-prepare KUBE_CONTEXT=k3s-ygdb
make sysbench-run KUBE_CONTEXT=k3s-ygdb

# Optional: throttle disk throughput on running cluster
DISK_BW_MBPS=10 ./scripts/setup-slow-throughput.sh

# Cleanup
make clean KUBE_CONTEXT=k3s-ygdb
./scripts/teardown-k3s-virsh.sh
```

Reports are saved to `reports/<timestamp>/report.html`.

## Project Structure

```
.
├── charts/
│   └── yb-benchmark/              # Helm chart
│       ├── Chart.yaml             # YugabyteDB as optional dependency
│       ├── values-aws.yaml        # AWS production settings
│       ├── values-minikube.yaml   # Minikube dev settings
│       ├── values-k3s-virsh.yaml  # k3s-virsh tuning lab settings
│       └── templates/
│           ├── sysbench.yaml           # Sysbench deployment
│           ├── sysbench-configmap.yaml # Sysbench scripts (prepare/run/cleanup)
│           └── prometheus.yaml         # Prometheus stack
├── scripts/
│   ├── setup-minikube.sh          # Minikube cluster setup
│   ├── setup-k3s-virsh.sh        # VM creation + k3s install
│   ├── teardown-k3s-virsh.sh     # VM cleanup
│   ├── setup-slow-disk.sh        # dm-delay storage setup
│   ├── setup-slow-throughput.sh   # virsh blkdeviotune wrapper
│   └── report-generator/          # HTML report generation
├── .vms/                          # VM disks and cloud images (gitignored)
├── Makefile                       # Deployment and benchmark targets
└── README.md
```

## Makefile Targets

### Deployment

| Target | Description |
|--------|-------------|
| `make deploy-minikube` | Deploy with minikube-optimized settings |
| `make deploy-aws` | Deploy with AWS-optimized settings |
| `make deploy-k3s-virsh` | Deploy on k3s-virsh tuning lab |
| `make deploy-benchmarks` | Deploy benchmarks only (use existing YugabyteDB) |
| `make clean` | Delete all resources |

### Sysbench Operations

| Target | Description |
|--------|-------------|
| `make sysbench-prepare` | Create tables and load test data (params from values file) |
| `make sysbench-run` | Run benchmark (params from values file) |
| `make sysbench-cleanup` | Drop benchmark tables |
| `make sysbench-shell` | Open shell in sysbench container |
| `make report` | Generate HTML performance report |

### Utilities

| Target | Description |
|--------|-------------|
| `make status` | Show status of all components |
| `make ysql` | Connect to YugabyteDB YSQL shell |
| `make port-forward-prometheus` | Port forward Prometheus to localhost:9090 |

### k3s-virsh Infrastructure

| Target | Description |
|--------|-------------|
| `make setup-k3s-virsh` | Create VMs and install k3s cluster |
| `make teardown-k3s-virsh` | Destroy VMs and cleanup |
| `make setup-slow-disk` | Setup tserver storage with dm-delay (`DISK_DELAY_MS=50`) |
| `make setup-slow-throughput` | Throttle VM disk throughput (`DISK_BW_MBPS=10 DISK_IOPS=200`) |

## Configuration

All sysbench parameters are defined in Helm values files (single source of truth).

### Sysbench Settings

Parameters follow [YugabyteDB official benchmark docs](https://docs.yugabyte.com/stable/benchmark/sysbench-ysql/).

| Parameter | AWS Default | Minikube Default | Description |
|-----------|-------------|------------------|-------------|
| `sysbench.tables` | 20 | 2 | Number of tables |
| `sysbench.tableSize` | 5000000 | 1000 | Rows per table |
| `sysbench.threads` | 60 | 2 | Concurrent threads |
| `sysbench.time` | 1800 | 60 | Test duration (seconds) |
| `sysbench.warmupTime` | 300 | 10 | In-run warmup (seconds) |
| `sysbench.workload` | oltp_read_write | oltp_read_write | Workload type |

To customize, edit `charts/yb-benchmark/values-*.yaml` and redeploy.

### YugabyteDB-specific Flags

These flags are configured in `sysbench.*` per YugabyteDB docs:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sysbench.rangeSelects` | false | **CRITICAL**: Prevents 100x slowdown from cross-tablet scans |
| `sysbench.rangeKeyPartitioning` | false | Use hash partitioning |
| `sysbench.serialCacheSize` | 1000 | Serial column cache size |
| `sysbench.createSecondary` | true | Create secondary index |

### Available Workloads

- `oltp_read_write` - Mixed read/write transactions (default)
- `oltp_read_only` - Read-only transactions
- `oltp_write_only` - Write-only transactions

## Performance Reports

After `make sysbench-run`, generate a report with `make report`.

The report includes:
- CPU utilization per pod
- Memory usage over time
- Network I/O statistics
- Min/Avg/Max summary table
- Interactive Chart.js visualizations

## Helm Chart

The chart can be used standalone:

```bash
# AWS production
helm install yb-bench ./charts/yb-benchmark -n yugabyte-test --create-namespace \
  -f ./charts/yb-benchmark/values-aws.yaml

# Minikube development
helm install yb-bench ./charts/yb-benchmark -n yugabyte-test --create-namespace \
  -f ./charts/yb-benchmark/values-minikube.yaml

# Benchmarks only (existing YugabyteDB)
helm install yb-bench ./charts/yb-benchmark -n yugabyte-test \
  -f ./charts/yb-benchmark/values-minikube.yaml \
  --set yugabyte.enabled=false
```

## Troubleshooting

### Sysbench can't connect to YugabyteDB

Check that YugabyteDB is running:
```bash
make status
kubectl --context minikube get pods -n yugabyte-test
```

### View logs

```bash
make sysbench-logs
kubectl --context minikube logs -n yugabyte-test yb-tserver-0
```
