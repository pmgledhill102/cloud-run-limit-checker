#!/usr/bin/env bash
# wipe.sh -- Delete deployed Cloud Run services, checker job, and optionally the AR repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Delete all Cloud Run services matching the prefix, the checker job,
and optionally the Artifact Registry repo.

Options:
  --project NAME      GCP project              (default: cr-limit-tests)
  --region REGION     GCP region               (default: europe-west1)
  --prefix NAME       Service name prefix      (default: service)
  --repo-name NAME    Artifact Registry repo   (default: limit-checker)
  --batch-size N      Delete batch size         (default: 50)
  --delete-repo       Also delete the Artifact Registry repo
  --yes, -y           Skip confirmation prompt
  -h, --help          Show this help
EOF
}

parse_flags "$@"
ensure_project

# ── Discover services ─────────────────────────────────────────────────────────
info "Discovering services with prefix: ${PREFIX}-"

SERVICES=()
while IFS= read -r name; do
  [[ -n "$name" ]] && SERVICES+=("$name")
done < <(
  gcloud run services list \
    --region "$REGION" \
    --filter "metadata.name~^${PREFIX}-[0-9]+" \
    --format 'value(metadata.name)' \
    2>/dev/null
)

CHECKER_EXISTS=false
if gcloud run jobs describe checker \
     --region "$REGION" --format='value(name)' &>/dev/null; then
  CHECKER_EXISTS=true
fi

info "Found ${#SERVICES[@]} service(s) and checker job exists: ${CHECKER_EXISTS}"

if (( ${#SERVICES[@]} == 0 )) && [[ "$CHECKER_EXISTS" != "true" ]] && [[ "$DELETE_REPO" != "true" ]]; then
  ok "Nothing to delete"
  exit 0
fi

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ "$YES" != "true" ]]; then
  echo ""
  echo "This will delete:"
  if (( ${#SERVICES[@]} > 0 )); then
    echo "  - ${#SERVICES[@]} Cloud Run service(s) matching '${PREFIX}-*'"
  fi
  if [[ "$CHECKER_EXISTS" == "true" ]]; then
    echo "  - Checker Cloud Run Job"
  fi
  if [[ "$DELETE_REPO" == "true" ]]; then
    echo "  - Artifact Registry repo: ${REPO_NAME}"
  fi
  echo ""
  read -rp "Continue? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    info "Aborted"
    exit 0
  fi
fi

# ── Delete services in batches ────────────────────────────────────────────────
if (( ${#SERVICES[@]} > 0 )); then
  info "Deleting ${#SERVICES[@]} service(s) (batch size: ${BATCH_SIZE})"

  succeeded=0
  failed=0
  i=0
  total=${#SERVICES[@]}

  while (( i < total )); do
    batch_end=$(( i + BATCH_SIZE ))
    if (( batch_end > total )); then
      batch_end=$total
    fi

    info "Batch: deleting services ${i}..$(( batch_end - 1 ))"

    pids=()
    batch_names=()
    j=$i
    while (( j < batch_end )); do
      name="${SERVICES[$j]}"
      batch_names+=("$name")

      gcloud run services delete "$name" \
        --region "$REGION" \
        --quiet &

      pids+=($!)
      (( j++ ))
      sleep 1
    done

    k=0
    for pid in "${pids[@]}"; do
      if wait "$pid"; then
        ok "Deleted: ${batch_names[$k]}"
        (( succeeded++ ))
      else
        err "Failed to delete: ${batch_names[$k]}"
        (( failed++ ))
      fi
      (( k++ ))
    done

    i=$batch_end
  done

  info "Delete summary: ${succeeded} succeeded, ${failed} failed (${total} total)"
fi

# ── Delete checker job ────────────────────────────────────────────────────────
if [[ "$CHECKER_EXISTS" == "true" ]]; then
  info "Deleting checker job..."
  if gcloud run jobs delete checker \
       --region "$REGION" \
       --quiet; then
    ok "Checker job deleted"
  else
    err "Failed to delete checker job"
  fi
fi

# ── Optionally delete Artifact Registry repo ─────────────────────────────────
if [[ "$DELETE_REPO" == "true" ]]; then
  info "Deleting Artifact Registry repo: ${REPO_NAME}"
  if gcloud artifacts repositories delete "$REPO_NAME" \
       --location "$REGION" \
       --quiet; then
    ok "Artifact Registry repo deleted"
  else
    err "Failed to delete Artifact Registry repo"
  fi
fi

ok "Wipe complete"
