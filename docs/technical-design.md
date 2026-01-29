# Technical Design: Cloud Run Direct VPC Limit Checker

## Objective

Determine, through empirical testing, the maximum number of Cloud Run services
that can concurrently use Direct VPC egress into a single subnet within one GCP
project, and verify that each service has functional network connectivity to an
internal resource via that VPC path.

## Constraints and Assumptions

- The GCP project (`cr-limit-tests`) is created manually and is not managed by
  this tooling.
- No Terraform or IaC tooling -- infrastructure that is not Cloud Run services
  (VPC, subnet, firewall rules, Compute Engine VM) is created manually or via
  `gcloud` commands documented below.
- All Cloud Run services use the same container image to keep things simple.
- Each Cloud Run service is configured with `min-instances=1` and
  `max-instances=1` to ensure every service is actively running and consuming a
  Direct VPC egress slot.
- Cloud Run services are configured with the smallest available footprint
  (128Mi memory, 0.08 vCPU) to minimise cost.
- **All Cloud Run services use internal-only ingress** (`--ingress=internal`).
  They have no external IP address and no public URL. They are not reachable
  from outside the VPC.
- **The Compute Engine VM has no external IP address.** It is accessible only
  via its private IP within the VPC. Administrative access (SSH, SCP) uses
  Identity-Aware Proxy (IAP) tunnelling.
- All network communication between Cloud Run services and the target VM occurs
  exclusively over private IP addresses within the VPC.
- Go is used for all components to produce small container images and to use the
  Google Cloud Go SDK for programmatic deployment.

## Components

### 1. Cloud Run Service (`service/`)

A minimal Go HTTP server packaged into a distroless container image. Configured
with **internal-only ingress** -- no external IP address or public URL is
assigned. The service is reachable only from within the VPC.

**Behaviour:**
- Listens on the port specified by the `PORT` environment variable (Cloud Run
  sets this automatically).
- On receiving `GET /ping`, makes an HTTP GET request to the internal target
  service at the address provided by the `TARGET_URL` environment variable
  (e.g. `http://10.0.0.2:8080/log`). The request includes a query parameter
  `service=<SERVICE_NAME>`, where `SERVICE_NAME` is read from an environment
  variable set during deployment.
- Returns `200 OK` with the target's response body if the internal call
  succeeds.
- Returns `502` with error details if the internal call fails.
- Logs the result of the target call (success or failure) to stdout.

**Dockerfile:**
- Multi-stage build: compile with `golang:1.23-alpine`, copy binary into
  `gcr.io/distroless/static-debian12`.
- Final image will be a few MB.

**Environment variables:**
| Variable       | Description                                  |
|----------------|----------------------------------------------|
| `PORT`         | Listening port (set by Cloud Run)            |
| `TARGET_URL`   | Internal target service URL (e.g. `http://10.0.0.2:8080/log`) |
| `SERVICE_NAME` | Unique name of this service instance         |

### 2. Internal Target Service (`target/`)

A Go HTTP server that runs on a Compute Engine VM inside the VPC.

**Behaviour:**
- Listens on `0.0.0.0:8080`.
- On receiving `GET /log?service=<name>`, it logs a structured message to
  stdout containing the service name and timestamp. When the VM is configured
  with the Cloud Logging agent (or the app uses the Cloud Logging client
  library), these entries appear in Cloud Logging.
- Returns `200 OK` with a JSON body: `{"status":"ok","service":"<name>"}`.

**Deployment:**
- Compiled locally or via Cloud Build and copied to the VM.
- Run as a systemd service or simply in the foreground for testing.
- **The VM has no external IP address** (`--no-address`). It is reachable only
  via its private IP within the VPC.
- Administrative access (SSH, SCP to deploy the binary) uses IAP tunnelling:
  `gcloud compute ssh target-service --tunnel-through-iap`.
- A firewall rule must allow ingress on port 8080 from the subnet CIDR range.
- A firewall rule must allow IAP tunnelling (TCP from `35.235.240.0/20`) for
  SSH access.

### 3. Checker Job (`checker/`)

A Cloud Run Job written in Go. It runs inside the VPC (configured with Direct
VPC egress into the same subnet) and verifies that each deployed Cloud Run
service has working connectivity to the target VM.

**Behaviour:**
- Uses the Cloud Run Admin API to list all services in the project/region whose
  names match the configured prefix (e.g. `service-*`).
- For each service, calls `GET /ping` via the service's internal URL. Because
  the checker runs inside the VPC, it can reach the internal-only services.
- Each pinged service calls the target VM at its private IP, proving the Direct
  VPC egress path works end-to-end.
- Logs a structured line to stdout for each service: service name, HTTP status,
  response body, and pass/fail.
- After all services have been checked, logs a summary line: total checked,
  passed, failed.
- Exits with code 0 if all services passed, non-zero otherwise.

**Dockerfile:**
- Same multi-stage pattern as the service: compile with `golang:1.23-alpine`,
  copy binary into `gcr.io/distroless/static-debian12`.

**Environment variables:**
| Variable       | Description                                              |
|----------------|----------------------------------------------------------|
| `PREFIX`       | Service name prefix to match (e.g. `service`)            |
| `REGION`       | GCP region where services are deployed                   |
| `CONCURRENCY`  | Number of parallel `/ping` calls to make                 |

**Cloud Run Job configuration:**
- Direct VPC egress to the same subnet as the services.
- Task timeout set high enough to check all services (e.g. 30 minutes).
- 1 task, 0 retries (the orchestrator handles re-runs if needed).

### 4. Deployment Orchestrator (`orchestrator/`)

A Go CLI application that runs on the developer's local machine.

**Responsibilities:**

1. **Build and push the container image** -- Builds the Cloud Run service
   container and pushes it to Artifact Registry (or uses Cloud Build).
2. **Deploy Cloud Run services** -- Iterates from 1 to N, creating each service
   with the Cloud Run Admin API v2 via the Go SDK. The Admin API is a management
   plane API and works regardless of the service's ingress setting. Each service
   is configured with:
   - A unique name: `service-001`, `service-002`, ... `service-NNN`
   - The shared container image
   - **Internal-only ingress** (`ingress: INGRESS_TRAFFIC_INTERNAL_ONLY`)
   - Direct VPC egress to the specified subnet
   - `min-instances=1`, `max-instances=1`
   - 128Mi memory, 0.08 vCPU
   - Environment variables: `TARGET_URL` and `SERVICE_NAME`
3. **Execute checker job** -- After all services are deployed, the orchestrator
   creates (or updates) and executes the checker Cloud Run Job. The job runs
   inside the VPC, calls `/ping` on each service, and logs results to stdout.
4. **Poll and report** -- The orchestrator polls the job execution status until
   it completes, then reads the job's stdout logs from Cloud Logging via the
   Logging API. It prints a summary table showing deployment and connectivity
   status for each service, plus aggregate counts (deployed, passed, failed).
5. **Teardown** -- Provides a `--cleanup` flag that deletes all services and
   the checker job matching the naming pattern.

**CLI flags:**
| Flag              | Description                                      | Default            |
|-------------------|--------------------------------------------------|--------------------|
| `--region`        | GCP region                                       | (required)         |
| `--network`       | VPC network name                                 | (required)         |
| `--subnet`        | Subnet name                                      | (required)         |
| `--target-url`    | Internal IP + port of the target service         | (required)         |
| `--service-image` | Container image URI for the Cloud Run service    | (required)         |
| `--checker-image` | Container image URI for the checker job           | (required)         |
| `--count`         | Number of services to deploy                     | `10`               |
| `--prefix`        | Service name prefix                              | `service`          |
| `--concurrency`   | Number of parallel deploy operations             | `10`               |
| `--cleanup`       | Delete all services and checker job               | `false`            |
| `--verify-only`   | Skip deployment, only execute the checker job    | `false`            |

**Concurrency:**
Deployments are parallelised using a worker pool (bounded by `--concurrency`)
to avoid hitting API rate limits while still completing in a reasonable time.
Verification concurrency within the checker job is controlled by its own
`CONCURRENCY` environment variable.

## Manual Infrastructure Setup

The following resources must exist before the orchestrator is run. These are
created manually or via `gcloud` commands.

### 1. GCP Project

```bash
gcloud projects create cr-limit-tests --name="Cloud Run Limit Checker"
gcloud config set project cr-limit-tests
```

### 2. Enable APIs

```bash
gcloud services enable \
  run.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  logging.googleapis.com
```

### 3. VPC and Subnet

```bash
gcloud compute networks create limit-checker-vpc \
  --subnet-mode=custom

gcloud compute networks subnets create limit-checker-subnet \
  --network=limit-checker-vpc \
  --region=REGION \
  --range=10.0.0.0/20
```

A `/20` subnet provides 4,094 usable IPs. Each Cloud Run instance with Direct
VPC egress consumes at least one IP from the subnet, so this should support
several hundred to a few thousand services depending on internal allocation
behaviour. If testing hits this ceiling, the subnet can be expanded.

### 4. Firewall Rules

Allow Cloud Run services to reach the target on port 8080:

```bash
gcloud compute firewall-rules create allow-cloudrun-to-target \
  --network=limit-checker-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:8080 \
  --source-ranges=10.0.0.0/20 \
  --target-tags=target-service
```

Allow IAP tunnelling for SSH access to the VM (which has no external IP):

```bash
gcloud compute firewall-rules create allow-iap-ssh \
  --network=limit-checker-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20 \
  --target-tags=target-service
```

### 5. Compute Engine VM

```bash
gcloud compute instances create target-service \
  --zone=ZONE \
  --machine-type=e2-micro \
  --network=limit-checker-vpc \
  --subnet=limit-checker-subnet \
  --no-address \
  --tags=target-service \
  --metadata=startup-script='#! /bin/bash
    # The target binary would be deployed separately
    echo "VM ready"'
```

Note: The VM has no external IP address. All administrative access uses IAP
tunnelling:

```bash
# SSH into the VM
gcloud compute ssh target-service --zone=ZONE --tunnel-through-iap

# Copy the target binary to the VM
gcloud compute scp target/target target-service:~ --zone=ZONE --tunnel-through-iap
```

### 6. Artifact Registry Repository

```bash
gcloud artifacts repositories create limit-checker \
  --repository-format=docker \
  --location=REGION
```

### 7. Build and Push Container Images

```bash
# Cloud Run service image
cd service/
gcloud builds submit --tag REGION-docker.pkg.dev/cr-limit-tests/limit-checker/service:latest

# Checker job image
cd ../checker/
gcloud builds submit --tag REGION-docker.pkg.dev/cr-limit-tests/limit-checker/checker:latest
```

## Key GCP Quotas and Limits to Monitor

| Quota / Limit                              | Default         | Notes                                         |
|--------------------------------------------|-----------------|-----------------------------------------------|
| Cloud Run services per project per region  | 1,000           | Can be increased via quota request             |
| Direct VPC egress IPs per subnet           | Undocumented    | **This is what we are testing**                |
| Cloud Run API requests per minute          | Varies          | Orchestrator concurrency should respect this   |
| Compute Engine instances                   | Per-project     | Only 1 needed for the target                  |
| Subnet IP range                            | /20 = 4,094 IPs | Expandable if needed                          |

## Iteration Plan

The work can be broken into the following iterations. Each iteration produces a
working, testable increment.

### Iteration 1: Cloud Run Service and Container Image

**Goal:** A working Go service that exposes `/ping` and calls an internal target
URL.

**Tasks:**
- Write the Go HTTP server (`service/main.go`) with the `/ping` endpoint.
- Write the Dockerfile with multi-stage build.
- Test locally with a mock target.
- Verify the image builds and runs in Docker.

**Exit criteria:** Running the container locally and calling
`curl http://localhost:8080/ping` makes a request to the configured
`TARGET_URL` and returns the response.

### Iteration 2: Internal Target Service and Infrastructure

**Goal:** A Go service running on Compute Engine that logs incoming requests,
with the supporting VPC infrastructure in place.

**Tasks:**
- Write the Go HTTP server (`target/main.go`).
- Set up the GCP project, VPC, subnet, firewall rules, and VM manually.
- Deploy the target binary to the VM via IAP tunnel.
- Verify the target responds on its internal IP.

**Exit criteria:** `curl http://INTERNAL_IP:8080/log?service=test` from within
the VPC returns `{"status":"ok","service":"test"}` and the request appears in
Cloud Logging.

### Iteration 3: Checker Job

**Goal:** A Cloud Run Job that can call `/ping` on a set of Cloud Run services
and report results.

**Tasks:**
- Write the checker Go application (`checker/main.go`).
- Write the Dockerfile.
- Implement service listing via the Cloud Run Admin API.
- Implement concurrent `/ping` calls with pass/fail logging to stdout.
- Test locally against mock services.

**Exit criteria:** Running the checker locally (with mock data or against a small
set of deployed services) produces structured pass/fail output to stdout.

### Iteration 4: Orchestrator -- Deploy, Verify, and Cleanup

**Goal:** The orchestrator can deploy N Cloud Run services, execute the checker
job, read results, and clean up.

**Tasks:**
- Scaffold the Go CLI with flag parsing.
- Implement Cloud Run service deployment using the Go SDK (Cloud Run Admin
  API v2).
- Implement checker job creation and execution.
- Implement job polling and log reading from Cloud Logging.
- Implement the cleanup/deletion flow.
- Test with a small count (e.g. 5 services).

**Exit criteria:** Running the orchestrator deploys 5 Cloud Run services,
executes the checker job, and prints a summary showing all 5 passed the
connectivity check. `--cleanup` removes all services and the job.

### Iteration 5: Scale Testing

**Goal:** Run the test at progressively larger scales to find the limit.

**Tasks:**
- Deploy in batches: 50, 100, 200, 500, 1000 services.
- Record results at each scale: deployment errors, connectivity failures, any
  quota or API errors encountered.
- Adjust orchestrator concurrency and subnet sizing as needed.
- Document findings.

**Exit criteria:** A documented record of the maximum number of concurrent Cloud
Run services with Direct VPC egress that successfully operate in a single
subnet, including any errors or limits encountered along the way.

## Cost Considerations

- **Cloud Run:** With min-instances=1 at 0.08 vCPU and 128Mi memory, each idle
  service costs approximately $0.00000192/s for CPU + $0.00000250/s for memory.
  At scale this still adds up -- 500 services running for 1 hour would cost
  roughly $8. Services should be cleaned up promptly after testing.
- **Compute Engine:** A single `e2-micro` is in the free tier (1 per billing
  account per month) or costs approximately $6/month.
- **Artifact Registry / Cloud Build:** Negligible for a single small image.
- **Network egress:** All traffic is internal, so no egress charges apply.

The orchestrator's `--cleanup` flag is critical for cost control. Tests should
be run and cleaned up within the shortest window possible.
