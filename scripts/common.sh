#!/usr/bin/env bash
# common.sh -- shared defaults, flag parsing, and helpers for deploy/wipe scripts.
# Source this file; do not execute it directly.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT="${PROJECT:-cr-limit-tests}"
REGION="${REGION:-europe-west1}"
NETWORK="${NETWORK:-limit-checker-vpc}"
SUBNET="${SUBNET:-limit-checker-subnet}"
PREFIX="${PREFIX:-service}"
COUNT="${COUNT:-10}"
CONCURRENCY="${CONCURRENCY:-10}"
BATCH_SIZE="${BATCH_SIZE:-50}"
TARGET_URL="${TARGET_URL:-}"
REPO_NAME="${REPO_NAME:-limit-checker}"

# Skip flags (deploy.sh only)
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_DEPLOY="${SKIP_DEPLOY:-false}"
SKIP_CHECK="${SKIP_CHECK:-false}"

# Wipe flags
DELETE_REPO="${DELETE_REPO:-false}"
YES="${YES:-false}"

# ── Derived variables (set after flag parsing) ────────────────────────────────
REGISTRY=""
SERVICE_IMAGE=""
CHECKER_IMAGE=""

_derive_vars() {
  REGISTRY="${REGION}-docker.pkg.dev/${PROJECT}/${REPO_NAME}"
  SERVICE_IMAGE="${REGISTRY}/service:latest"
  CHECKER_IMAGE="${REGISTRY}/checker:latest"
}

# ── Flag parsing ──────────────────────────────────────────────────────────────
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)    PROJECT="$2";     shift 2 ;;
      --region)     REGION="$2";      shift 2 ;;
      --network)    NETWORK="$2";     shift 2 ;;
      --subnet)     SUBNET="$2";      shift 2 ;;
      --prefix)     PREFIX="$2";      shift 2 ;;
      --count)      COUNT="$2";       shift 2 ;;
      --concurrency) CONCURRENCY="$2"; shift 2 ;;
      --batch-size) BATCH_SIZE="$2";  shift 2 ;;
      --target-url) TARGET_URL="$2";  shift 2 ;;
      --repo-name)  REPO_NAME="$2";   shift 2 ;;
      --skip-build) SKIP_BUILD=true;  shift ;;
      --skip-deploy) SKIP_DEPLOY=true; shift ;;
      --skip-check) SKIP_CHECK=true;  shift ;;
      --delete-repo) DELETE_REPO=true; shift ;;
      --yes|-y)     YES=true;         shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            err "Unknown flag: $1"; usage; exit 1 ;;
    esac
  done
  _derive_vars
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Colored output
info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# Generate a zero-padded service name: service-001, service-002, ...
service_name() {
  printf '%s-%03d' "$PREFIX" "$1"
}

# Ensure the gcloud project is set correctly.
ensure_project() {
  info "Using project: ${PROJECT}, region: ${REGION}"
  gcloud config set project "$PROJECT" --quiet 2>/dev/null
}
