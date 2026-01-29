#!/usr/bin/env bash
# deploy.sh -- Build images, deploy Cloud Run services, and run the checker job.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Deploy the target VM, Cloud Run services, and run the checker job.

Options:
  --project NAME      GCP project              (default: cr-limit-tests)
  --region REGION     GCP region               (default: europe-west1)
  --zone ZONE         VM zone                  (default: europe-west1-b)
  --network NAME      VPC network              (default: limit-checker-vpc)
  --subnet NAME       Subnet                   (default: limit-checker-subnet)
  --prefix NAME       Service name prefix      (default: service)
  --count N           Number of services       (default: 10)
  --concurrency N     Checker concurrency      (default: 10)
  --batch-size N      Deploy batch size         (default: 50)
  --repo-name NAME    Artifact Registry repo   (default: limit-checker)
  --vm-name NAME      Target VM name           (default: target-service)
  --target-url URL    Override target URL (skips VM setup entirely)
  --skip-build        Skip image builds
  --skip-deploy       Skip service deployment
  --skip-check        Skip checker job execution
  --skip-vm           Skip VM create/deploy, just query existing VM IP
  -h, --help          Show this help
EOF
}

parse_flags "$@"
ensure_project

# ── Step 1: Ensure target VM ─────────────────────────────────────────────────
query_vm_ip() {
  gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" \
    --format='value(networkInterfaces[0].networkIP)'
}

ensure_target_vm() {
  if [[ -n "$TARGET_URL" ]]; then
    info "Using provided --target-url: ${TARGET_URL}"
    return
  fi

  if [[ "$SKIP_VM" == "true" ]]; then
    info "Querying existing VM IP (--skip-vm)"
    local ip
    ip=$(query_vm_ip)
    TARGET_URL="http://${ip}:8080/log"
    ok "Derived TARGET_URL=${TARGET_URL}"
    return
  fi

  info "Cross-compiling target binary"
  GOOS=linux GOARCH=amd64 go build -o "$ROOT_DIR/target/target-bin" "$ROOT_DIR/target/main.go"
  ok "Built target/target-bin"

  info "Ensuring VM: ${VM_NAME} (zone: ${ZONE})"
  if gcloud compute instances describe "$VM_NAME" \
       --zone="$ZONE" --format='value(name)' &>/dev/null; then
    ok "VM already exists"
  else
    gcloud compute instances create "$VM_NAME" \
      --zone="$ZONE" \
      --machine-type=e2-micro \
      --network="$NETWORK" \
      --subnet="$SUBNET" \
      --no-address \
      --tags=target-service \
      --quiet
    ok "Created VM: ${VM_NAME}"

    info "Waiting for VM to become reachable via IAP..."
    local attempt=0
    until gcloud compute ssh "$VM_NAME" \
            --zone="$ZONE" --tunnel-through-iap --quiet \
            --command='true' &>/dev/null; do
      (( attempt++ ))
      if (( attempt > 30 )); then
        err "VM did not become reachable via IAP after 30 attempts"
        exit 1
      fi
      sleep 5
    done
    ok "VM reachable via IAP"
  fi

  info "Copying target binary to VM via IAP"
  local attempt=0
  until gcloud compute scp "$ROOT_DIR/target/target-bin" "${VM_NAME}:~/target" \
          --zone="$ZONE" --tunnel-through-iap --quiet 2>/dev/null; do
    (( attempt++ ))
    if (( attempt > 12 )); then
      err "SCP failed after ${attempt} attempts"
      exit 1
    fi
    warn "SCP attempt ${attempt} failed, retrying in 10s..."
    sleep 10
  done
  ok "Binary copied"

  info "Starting target service on VM"
  gcloud compute ssh "$VM_NAME" \
    --zone="$ZONE" \
    --tunnel-through-iap \
    --quiet \
    --command='pkill -x target 2>/dev/null || true; sleep 1; setsid ./target > target.log 2>&1 < /dev/null & sleep 1; echo "target started"'
  ok "Target service started"

  local ip
  ip=$(query_vm_ip)
  TARGET_URL="http://${ip}:8080/log"
  ok "Derived TARGET_URL=${TARGET_URL}"
}

ensure_target_vm

# ── Step 2: Create Artifact Registry repo (idempotent) ────────────────────────
create_repo() {
  info "Ensuring Artifact Registry repo: ${REPO_NAME}"
  if gcloud artifacts repositories describe "$REPO_NAME" \
       --location="$REGION" --format='value(name)' &>/dev/null; then
    ok "Artifact Registry repo already exists"
  else
    gcloud artifacts repositories create "$REPO_NAME" \
      --repository-format=docker \
      --location="$REGION" \
      --quiet
    ok "Created Artifact Registry repo: ${REPO_NAME}"
  fi
}

# ── Step 3: Build images with Cloud Build ─────────────────────────────────────
build_images() {
  info "Building service image: ${SERVICE_IMAGE}"
  gcloud builds submit "$ROOT_DIR/service" \
    --tag "$SERVICE_IMAGE" \
    --quiet

  info "Building checker image: ${CHECKER_IMAGE}"
  gcloud builds submit "$ROOT_DIR/checker" \
    --tag "$CHECKER_IMAGE" \
    --quiet

  ok "Images built"
}

# ── Step 4: Deploy N services in batches ──────────────────────────────────────
deploy_services() {
  info "Deploying ${COUNT} services (batch size: ${BATCH_SIZE})"

  local succeeded=0
  local failed=0
  local total="$COUNT"
  local i=0

  while (( i < total )); do
    # Determine batch bounds
    local batch_end=$(( i + BATCH_SIZE ))
    if (( batch_end > total )); then
      batch_end=$total
    fi

    info "Batch: deploying services ${i}..$(( batch_end - 1 ))"

    # Launch batch in background
    local pids=()
    local names=()
    local j=$i
    while (( j < batch_end )); do
      local name
      name=$(service_name "$j")
      names+=("$name")

      gcloud run deploy "$name" \
        --image "$SERVICE_IMAGE" \
        --region "$REGION" \
        --platform managed \
        --ingress internal \
        --vpc-egress all-traffic \
        --network "$NETWORK" \
        --subnet "$SUBNET" \
        --min-instances 0 \
        --max-instances 1 \
        --cpu 1 \
        --memory 512Mi \
        --set-env-vars "TARGET_URL=${TARGET_URL},SERVICE_NAME=${name}" \
        --allow-unauthenticated \
        --no-cpu-throttling \
        --quiet &

      pids+=($!)
      (( j++ ))
      sleep 1
    done

    # Wait for batch
    local k=0
    for pid in "${pids[@]}"; do
      if wait "$pid"; then
        ok "Deployed: ${names[$k]}"
        (( succeeded++ ))
      else
        err "Failed: ${names[$k]}"
        (( failed++ ))
      fi
      (( k++ ))
    done

    i=$batch_end
  done

  info "Deploy summary: ${succeeded} succeeded, ${failed} failed (${total} total)"
  if (( failed > 0 )); then
    err "${failed} service(s) failed to deploy"
    return 1
  fi
}

# ── Step 5: Create / update checker Cloud Run Job ─────────────────────────────
ensure_checker_job() {
  info "Ensuring checker Cloud Run Job"

  if gcloud run jobs describe checker \
       --region "$REGION" --format='value(name)' &>/dev/null; then
    info "Checker job exists, updating..."
    gcloud run jobs update checker \
      --region "$REGION" \
      --image "$CHECKER_IMAGE" \
      --network "$NETWORK" \
      --subnet "$SUBNET" \
      --vpc-egress all-traffic \
      --set-env-vars "PROJECT_ID=${PROJECT},REGION=${REGION},PREFIX=${PREFIX},CONCURRENCY=${CONCURRENCY}" \
      --task-timeout 30m \
      --max-retries 0 \
      --cpu 1 \
      --memory 512Mi \
      --quiet
    ok "Checker job updated"
  else
    gcloud run jobs create checker \
      --region "$REGION" \
      --image "$CHECKER_IMAGE" \
      --network "$NETWORK" \
      --subnet "$SUBNET" \
      --vpc-egress all-traffic \
      --set-env-vars "PROJECT_ID=${PROJECT},REGION=${REGION},PREFIX=${PREFIX},CONCURRENCY=${CONCURRENCY}" \
      --task-timeout 30m \
      --max-retries 0 \
      --cpu 1 \
      --memory 512Mi \
      --quiet
    ok "Checker job created"
  fi
}

# ── Step 6: Execute checker job ───────────────────────────────────────────────
run_checker() {
  info "Executing checker job..."
  gcloud run jobs execute checker \
    --region "$REGION" \
    --wait \
    --quiet
  ok "Checker job completed"
}

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" != "true" ]]; then
  create_repo
  build_images
fi

if [[ "$SKIP_DEPLOY" != "true" ]]; then
  deploy_services
fi

if [[ "$SKIP_CHECK" != "true" ]]; then
  ensure_checker_job
  run_checker
fi

ok "Done"
