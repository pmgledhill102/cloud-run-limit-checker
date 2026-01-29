# Cloud Run Limit Checker

A testing tool to empirically determine the limits of Google Cloud Run's
[Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc)
feature, specifically around the number of concurrent services that can operate
within a single VPC subnet.

Google's documentation does not clearly state the upper bounds for the number of
Cloud Run services that can simultaneously use Direct VPC egress into a single
subnet. This project deploys a configurable number of Cloud Run services into a
shared subnet and verifies that each one has working VPC connectivity to an
internal service.

## Overview

The project consists of four components:

1. **Cloud Run service** (Go) -- A minimal container image deployed N times with
   unique names (`service-001`, `service-002`, ...). Each instance is configured
   with **internal-only ingress** (no external IP or public URL), Direct VPC
   egress into a shared subnet, minimum resources (128Mi memory, 0.08 vCPU), and
   exactly one instance (min=1, max=1) to guarantee that every deployed service
   is actively consuming a slot in the subnet. Each service exposes a `/ping`
   endpoint that calls the internal target VM over its private IP to prove VPC
   connectivity.

2. **Internal target service** (Go on Compute Engine) -- A lightweight HTTP
   server running on a Compute Engine VM inside the same VPC. The VM has **no
   external IP address** -- it is reachable only via its private IP within the
   VPC. It receives requests from the Cloud Run services and logs the caller's
   identity to stdout. This proves that each Cloud Run service has functional
   network connectivity through the Direct VPC path.

3. **Checker job** (Go, Cloud Run Job) -- A Cloud Run Job configured with Direct
   VPC egress into the same subnet. When executed, it lists all deployed
   services matching the naming prefix, calls each one's `/ping` endpoint via
   its internal URL, and logs the per-service results (pass/fail) to stdout.
   Because it runs inside the VPC, it can reach the internal-only Cloud Run
   services directly.

4. **Deploy/wipe scripts** (Bash, runs locally) -- Two shell scripts that use
   `gcloud` commands to manage the full lifecycle. `deploy.sh` builds container
   images with Cloud Build, deploys N Cloud Run services in batches, creates the
   checker job, and executes it. `wipe.sh` discovers all deployed services by
   prefix, deletes them in batches, removes the checker job, and optionally
   cleans up the Artifact Registry repo.

## Network Architecture

```
+--------------------------------------------------------------+
|  Google Cloud Project: cr-limit-tests                        |
|                                                              |
|  +--------------------------------------------------------+  |
|  |  VPC Network (no external IPs)                         |  |
|  |                                                        |  |
|  |  +--------------------------------------------------+  |  |
|  |  |  Subnet (e.g. 10.0.0.0/20)                      |  |  |
|  |  |                                                  |  |  |
|  |  |  +------------------+                            |  |  |
|  |  |  | Compute Engine   |                            |  |  |
|  |  |  | (target-service) |                            |  |  |
|  |  |  | internal IP only |                            |  |  |
|  |  |  | 10.0.0.x:8080    |                            |  |  |
|  |  |  +--------^---------+                            |  |  |
|  |  |           |                                      |  |  |
|  |  |           | HTTP (private IP, no public access)  |  |  |
|  |  |           |                                      |  |  |
|  |  |  +--------+-------------------------------+      |  |  |
|  |  |  |  Cloud Run services                    |      |  |  |
|  |  |  |  (internal ingress + Direct VPC egress)|      |  |  |
|  |  |  |  No external IP / no public URL        |      |  |  |
|  |  |  |                                        |      |  |  |
|  |  |  |  service-001  service-002  ...         |      |  |  |
|  |  |  |  service-003  service-004  ...         |      |  |  |
|  |  |  |       ...      service-N               |      |  |  |
|  |  |  +--------^-------------------------------+      |  |  |
|  |  |           |                                      |  |  |
|  |  |           | HTTP (internal *.run.app URLs)       |  |  |
|  |  |           |                                      |  |  |
|  |  |  +--------+-------------------------------+      |  |  |
|  |  |  |  Checker (Cloud Run Job)               |      |  |  |
|  |  |  |  (Direct VPC egress)                   |      |  |  |
|  |  |  |                                        |      |  |  |
|  |  |  |  Calls /ping on each service           |      |  |  |
|  |  |  |  Logs pass/fail to stdout              |      |  |  |
|  |  |  +----------------------------------------+      |  |  |
|  |  |                                                  |  |  |
|  |  +--------------------------------------------------+  |  |
|  +--------------------------------------------------------+  |
+--------------------------------------------------------------+

Local machine
+------------------------------------------+
| deploy.sh / wipe.sh                     |
| (Bash scripts using gcloud CLI)         |
|                                          |
| - Builds images (Cloud Build)           |
| - Deploys N services (gcloud run)       |
| - Creates & executes checker job        |
| - Deletes services & job on wipe        |
+------------------------------------------+
```

## How It Works

1. **Prerequisites** -- The GCP project `cr-limit-tests` is manually created
   with the required APIs enabled (Cloud Run, Compute Engine, VPC). A VPC,
   subnet, and Compute Engine
   VM running the target service are set up before running the orchestrator.

2. **Deploy** -- `deploy.sh` builds container images via Cloud Build, then
   deploys N Cloud Run services in batches using `gcloud run deploy`. All
   services use the same container image but receive a unique name. Each is
   configured with internal-only ingress, Direct VPC egress pointing at the
   shared subnet, and min-instances=0, max-instances=1.

3. **Verify** -- `deploy.sh` creates (or updates) the checker Cloud Run Job
   and executes it with `--wait`. The checker runs inside the VPC, lists all
   deployed services matching the naming prefix, calls each one's `/ping`
   endpoint via its internal URL, and logs the result for each service to
   stdout. Each pinged service proves its VPC connectivity by calling the
   target VM over its private IP.

4. **Cleanup** -- `wipe.sh` discovers all services matching the prefix via
   `gcloud run services list --filter`, deletes them in batches, removes the
   checker job, and optionally deletes the Artifact Registry repo.

## Project Structure

```
cloud-run-limit-checker/
  README.md                  # This file
  docs/
    technical-design.md      # Detailed technical design document
  service/                   # Cloud Run service (Go)
    main.go
    Dockerfile
  checker/                   # Checker Cloud Run Job (Go)
    main.go
    Dockerfile
  target/                    # Internal Compute Engine target service (Go)
    main.go
  scripts/                   # Deploy and wipe bash scripts
    common.sh                # Shared defaults, flag parsing, helpers
    deploy.sh                # Build, deploy services, run checker
    wipe.sh                  # Delete services, job, and optionally repo
```

## Quick Start

```bash
# Deploy 10 services and run the checker
./scripts/deploy.sh --target-url http://10.0.0.x:8080/log

# Deploy more services, skip rebuilding images
./scripts/deploy.sh --target-url http://10.0.0.x:8080/log --count 50 --skip-build

# Delete everything
./scripts/wipe.sh --yes
```

See [docs/technical-design.md](docs/technical-design.md) for detailed setup
instructions, configuration options, and iteration plan.
