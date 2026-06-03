#!/usr/bin/env bash
# Delete local CI Docker images, keeping only the newest KEEP_COUNT per repository prefix.
# Targets: infinilm-ci/<platform>, infiniops-ci/<platform>
#
# Usage:
#   ./scripts/cleanup_ci_images.sh --platform nvidia
#   ./scripts/cleanup_ci_images.sh --platform metax --dry-run
#   ./scripts/cleanup_ci_images.sh --platform nvidia --count 5
#
# Scheduled via GitHub Actions: .github/workflows/cleanup_ci_images.yml
# Manual run: Actions -> "Cleanup CI Docker Images" -> "Run workflow"

set -euo pipefail

KEEP_COUNT=5
DRY_RUN=false
PLATFORM=""

usage() {
  cat <<'EOF'
Usage: cleanup_ci_images.sh --platform PLATFORM [OPTIONS]

Remove local CI Docker images, keeping only the newest N images per repository prefix.

Options:
  --platform P  Platform name, e.g. nvidia, metax, moore, cambricon, iluvatar, ascend (required)
  --count N     Keep the newest N images; delete older ones (default: 5)
  --dry-run     List images that would be deleted without removing them
  -h, --help    Show this help message
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="${2:?--platform requires a name}"
      shift 2
      ;;
    --count)
      KEEP_COUNT="${2:?--count requires a number}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${PLATFORM}" ]]; then
  echo "Error: --platform is required (e.g. nvidia, metax)" >&2
  usage >&2
  exit 1
fi

if ! [[ "${PLATFORM}" =~ ^[a-z0-9_-]+$ ]]; then
  echo "Error: invalid platform name: ${PLATFORM}" >&2
  exit 1
fi

IMAGE_PREFIXES=(
  "infinilm-ci/${PLATFORM}"
  "infiniops-ci/${PLATFORM}"
)

if ! [[ "$KEEP_COUNT" =~ ^[0-9]+$ ]] || [[ "$KEEP_COUNT" -lt 1 ]]; then
  echo "Error: --count must be a positive integer" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker not found in PATH" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Error: cannot connect to Docker daemon" >&2
  exit 1
fi

deleted=0
failed=0
kept=0

log "Platform: ${PLATFORM}; keep newest ${KEEP_COUNT} image(s) per prefix"
if $DRY_RUN; then
  log "Dry-run mode: no images will be removed"
fi

for prefix in "${IMAGE_PREFIXES[@]}"; do
  log "Scanning ${prefix}:*"

  tmpfile=$(mktemp)
  trap 'rm -f "${tmpfile}"' RETURN

  while IFS=$'\t' read -r image_id repository tag created_at; do
    [[ -z "${image_id}" ]] && continue
    [[ "${tag}" == "<none>" ]] && continue

    created_epoch=$(date -d "${created_at% UTC}" +%s 2>/dev/null) || {
      log "WARN: skip ${repository}:${tag} (cannot parse created time: ${created_at})"
      ((failed++)) || true
      continue
    }

    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${created_epoch}" "${image_id}" "${repository}" "${tag}" "${created_at}"
  done < <(
    docker images \
      --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.CreatedAt}}' \
      --filter "reference=${prefix}"
  ) >"${tmpfile}"

  total=$(wc -l <"${tmpfile}" | tr -d ' ')
  if [[ "${total}" -eq 0 ]]; then
    log "No images found for ${prefix}"
    rm -f "${tmpfile}"
    trap - RETURN
    continue
  fi

  rank=0
  while IFS=$'\t' read -r created_epoch image_id repository tag created_at; do
    ((rank++)) || true
    ref="${repository}:${tag}"

    if ((rank <= KEEP_COUNT)); then
      log "KEEP ${ref} (rank ${rank}/${total}, created ${created_at})"
      ((kept++)) || true
      continue
    fi

    if $DRY_RUN; then
      log "WOULD DELETE ${ref} (rank ${rank}/${total}, created ${created_at})"
      ((deleted++)) || true
      continue
    fi

    if docker rmi "${ref}" >/dev/null 2>&1; then
      log "Deleted ${ref} (rank ${rank}/${total}, created ${created_at})"
      ((deleted++)) || true
    else
      log "WARN: failed to delete ${ref} (image may be in use)"
      ((failed++)) || true
    fi
  done < <(sort -t$'\t' -k1,1nr "${tmpfile}")

  rm -f "${tmpfile}"
  trap - RETURN
done

log "Done. removed=${deleted} kept=${kept} failed=${failed}"
