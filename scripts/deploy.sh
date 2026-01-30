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
      attempt=$((attempt + 1))
      if [ "$attempt" -gt 30 ]; then
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
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 12 ]; then
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

# Deploy a list of service names in batches, returning failed names in FAILED_NAMES.
FAILED_NAMES=()
deploy_batch_list() {
  local service_names=("$@")
  local total=${#service_names[@]}
  local i=0
  FAILED_NAMES=()

  while [ "$i" -lt "$total" ]; do
    local batch_end=$((i + BATCH_SIZE))
    if [ "$batch_end" -gt "$total" ]; then
      batch_end=$total
    fi

    info "Batch: deploying ${service_names[*]:$i:$((batch_end - i))}"

    local pids=()
    local batch_names=()
    local j=$i
    while [ "$j" -lt "$batch_end" ]; do
      local name="${service_names[$j]}"
      batch_names+=("$name")

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
        --cpu 0.08 \
        --memory 128Mi \
        --set-env-vars "TARGET_URL=${TARGET_URL},SERVICE_NAME=${name}" \
        --allow-unauthenticated \
        --quiet &

      pids+=($!)
      j=$((j + 1))
      sleep 1
    done

    local k=0
    for pid in "${pids[@]}"; do
      if wait "$pid"; then
        ok "Deployed: ${batch_names[$k]}"
      else
        err "Failed: ${batch_names[$k]}"
        FAILED_NAMES+=("${batch_names[$k]}")
      fi
      k=$((k + 1))
    done

    i=$batch_end
  done
}

deploy_services() {
  info "Deploying ${COUNT} services (batch size: ${BATCH_SIZE})"

  # Discover which services already exist
  info "Checking for existing services..."
  local existing=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && existing+=("$name")
  done < <(
    gcloud run services list \
      --region "$REGION" \
      --filter "metadata.name~^${PREFIX}-[0-9]+" \
      --format 'value(metadata.name)' \
      2>/dev/null
  )

  # Build list of services that need deploying
  local all_names=()
  local skipped=0
  local i=0
  while [ "$i" -lt "$COUNT" ]; do
    local name
    name=$(service_name "$i")
    local found=false
    for e in "${existing[@]+"${existing[@]}"}"; do
      if [[ "$e" == "$name" ]]; then
        found=true
        break
      fi
    done
    if [[ "$found" == "true" ]]; then
      skipped=$((skipped + 1))
    else
      all_names+=("$name")
    fi
    i=$((i + 1))
  done

  if [ "$skipped" -gt 0 ]; then
    ok "Skipping ${skipped} already-deployed service(s)"
  fi

  if [ "${#all_names[@]}" -eq 0 ]; then
    ok "All ${COUNT} services already deployed"
    return
  fi

  info "Deploying ${#all_names[@]} new service(s)"
  deploy_batch_list "${all_names[@]}"

  local max_retries=3
  local retry=0
  while [ "${#FAILED_NAMES[@]}" -gt 0 ] && [ "$retry" -lt "$max_retries" ]; do
    retry=$((retry + 1))
    local retry_list=("${FAILED_NAMES[@]}")
    warn "Retrying ${#retry_list[@]} failed service(s) (attempt ${retry}/${max_retries}) after 30s..."
    sleep 30
    deploy_batch_list "${retry_list[@]}"
  done

  local total_failed=${#FAILED_NAMES[@]}
  local total_ok=$((COUNT - total_failed))
  info "Deploy summary: ${total_ok} succeeded, ${total_failed} failed (${COUNT} total)"
  if [ "$total_failed" -gt 0 ]; then
    err "${total_failed} service(s) failed to deploy after ${max_retries} retries"
    return 1
  fi
}

# ── Step 5: Fix IAM bindings ──────────────────────────────────────────────────
fix_iam_bindings() {
  info "Checking IAM bindings on ${COUNT} service(s)..."

  local to_fix=()
  local i=0
  while [ "$i" -lt "$COUNT" ]; do
    local name
    name=$(service_name "$i")
    local policy
    policy=$(gcloud run services get-iam-policy "$name" \
      --region "$REGION" --format='value(bindings.members)' 2>/dev/null || true)
    if [[ "$policy" != *"allUsers"* ]]; then
      to_fix+=("$name")
    fi
    i=$((i + 1))
  done

  if [ "${#to_fix[@]}" -eq 0 ]; then
    ok "All services have correct IAM bindings"
    return
  fi

  warn "Fixing IAM bindings for ${#to_fix[@]} service(s)"
  local fixed=0
  local failed=0
  for name in "${to_fix[@]}"; do
    if gcloud run services add-iam-policy-binding "$name" \
         --region="$REGION" \
         --member=allUsers \
         --role=roles/run.invoker \
         --quiet &>/dev/null; then
      ok "Fixed IAM: ${name}"
      fixed=$((fixed + 1))
    else
      err "Failed to fix IAM: ${name}"
      failed=$((failed + 1))
    fi
    sleep 1
  done
  info "IAM fix summary: ${fixed} fixed, ${failed} failed"
}

# ── Step 6: Create / update checker Cloud Run Job ─────────────────────────────
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

# ── Step 7: Execute checker job ───────────────────────────────────────────────
run_checker() {
  info "Executing checker job..."
  nohup gcloud run jobs execute checker \
    --region "$REGION" \
    --quiet > /dev/null 2>&1 &
  ok "Checker job completed"
}

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" != "true" ]]; then
  create_repo
  build_images
fi

if [[ "$SKIP_DEPLOY" != "true" ]]; then
  deploy_services
  fix_iam_bindings
fi

if [[ "$SKIP_CHECK" != "true" ]]; then
  ensure_checker_job
  run_checker
  run_checker
fi

ok "Done"
