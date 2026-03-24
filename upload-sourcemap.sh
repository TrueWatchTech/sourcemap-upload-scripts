#!/usr/bin/env bash

# Re-exec with bash when the script is launched via `sh`.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

ENDPOINT="${DF_OPENAPI_ENDPOINT:-}"
API_KEY="${DF_API_KEY:-${DF_OPEN_API_KEY:-}}"
APP_ID="${DF_APP_ID:-}"
VERSION="${DF_VERSION:-}"
ENVIRONMENT="${DF_ENV:-}"
FILE_PATH="${DF_SOURCEMAP_FILE:-}"
NEED_COVER="${DF_NEED_COVER:-false}"
CHUNK_SIZE_MB="${DF_CHUNK_SIZE_MB:-10}"
MERGE_PATH="${DF_MERGE_PATH:-}"
CANCEL_PATH="${DF_CANCEL_PATH:-}"

TMP_DIR=""
UPLOAD_ID=""
UPLOAD_STARTED="false"

DEFAULT_MERGE_PATHS=(
  "/api/v1/rum_sourcemap/part_merge"
  "/api/v1/rum_sourcemap/merge_file"
  "/api/v1/rum_sourcemap/merge_parts"
)

DEFAULT_CANCEL_PATHS=(
  "/api/v1/rum_sourcemap/upload_cancel"
  "/api/v1/rum_sourcemap/multipart_upload_cancel"
  "/api/v1/rum_sourcemap/cancel_upload"
)

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME \\
    --endpoint https://your-openapi-endpoint \\
    --api-key <df-api-key> \\
    --app-id <app-id> \\
    --file ./sourcemap.zip \\
    [--version 1.0.2] \\
    [--env daily] \\
    [--need-cover true|false] \\
    [--chunk-size-mb 10] \\
    [--merge-path /api/v1/rum_sourcemap/part_merge] \\
    [--cancel-path /api/v1/rum_sourcemap/upload_cancel]

Example:
  $SCRIPT_NAME \\
    --endpoint https://your-openapi-endpoint \\
    --api-key "\$DF_API_KEY" \\
    --app-id app_id_from_studio \\
    --version 1.0.2 \\
    --env daily \\
    --file ./sourcemap.zip \\
    --need-cover true

Notes:
  - The file must already be a valid sourcemap zip prepared for upload.
  - Multipart chunk size must be <= 10 MB.
  - Authentication uses the DF-API-KEY request header.
  - If the exact merge/cancel path differs in your deployment, override it
    with --merge-path and/or --cancel-path.
  - You may also provide values through environment variables:
    DF_OPENAPI_ENDPOINT, DF_API_KEY, DF_APP_ID, DF_VERSION,
    DF_ENV, DF_SOURCEMAP_FILE, DF_NEED_COVER, DF_CHUNK_SIZE_MB.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
}

normalize_bool() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    true|false)
      printf '%s' "$value"
      ;;
    *)
      fail "--need-cover must be true or false"
      ;;
  esac
}

cleanup() {
  # Only attempt cancellation after an upload session has been created.
  if [[ "$UPLOAD_STARTED" == "true" && -n "$UPLOAD_ID" ]]; then
    cancel_upload || true
  fi

  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

json_compact() {
  jq -c . <<<"$1"
}

extract_success() {
  jq -r 'if has("success") then .success else false end' <<<"$1"
}

extract_error_message() {
  jq -r '
    .message // .msg // .errorMessage // .error // .detail // .code // "unknown error"
  ' <<<"$1" 2>/dev/null || printf 'unknown error'
}

post_json() {
  local path="$1"
  local payload="$2"
  local response_file="$3"
  local status

  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X POST "${ENDPOINT}${path}" \
    -H "Content-Type: application/json" \
    -H "DF-API-KEY: ${API_KEY}" \
    --data "$payload")" || return 1

  printf '%s' "$status"
}

upload_part_request() {
  local chunk_path="$1"
  local chunk_index="$2"
  local response_file="$3"
  local status

  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X POST "${ENDPOINT}/api/v1/rum_sourcemap/upload_part" \
    -H "DF-API-KEY: ${API_KEY}" \
    -F "uploadId=${UPLOAD_ID}" \
    -F "chunkIndex=${chunk_index}" \
    -F "files=@${chunk_path}")" || return 1

  printf '%s' "$status"
}

validate_response_json() {
  local body_file="$1"
  jq -e . "$body_file" >/dev/null 2>&1 || fail "OpenAPI returned non-JSON response: $(cat "$body_file")"
}

ensure_http_success() {
  local status="$1"
  local body_file="$2"
  local action="$3"
  local body

  if [[ ! "$status" =~ ^2 ]]; then
    body="$(cat "$body_file")"
    if jq -e . "$body_file" >/dev/null 2>&1; then
      fail "$action failed with HTTP ${status}: $(json_compact "$body")"
    fi
    fail "$action failed with HTTP ${status}: ${body}"
  fi
}

ensure_api_success() {
  local body_file="$1"
  local action="$2"
  local body

  validate_response_json "$body_file"
  body="$(cat "$body_file")"

  if [[ "$(extract_success "$body")" != "true" ]]; then
    fail "$action failed: $(extract_error_message "$body") | response=$(json_compact "$body")"
  fi
}

cancel_upload() {
  local response_file
  local status
  local body
  local path
  local path_candidates=()

  if [[ -z "$UPLOAD_ID" ]]; then
    return 0
  fi

  if [[ -n "$CANCEL_PATH" ]]; then
    path_candidates=("$CANCEL_PATH")
  else
    path_candidates=("${DEFAULT_CANCEL_PATHS[@]}")
  fi

  body="$(jq -cn --arg uploadId "$UPLOAD_ID" '{uploadId: $uploadId}')"
  response_file="$TMP_DIR/cancel-response.json"

  # Some deployments expose different cancel paths, so try known candidates.
  for path in "${path_candidates[@]}"; do
    if status="$(post_json "$path" "$body" "$response_file" 2>/dev/null)"; then
      if [[ "$status" =~ ^2 ]] && jq -e '.success == true' "$response_file" >/dev/null 2>&1; then
        log "Cancelled multipart upload via ${path}"
        return 0
      fi
    fi
  done

  log "Best-effort cancel did not confirm success for uploadId=${UPLOAD_ID}"
  return 1
}

merge_upload() {
  local response_file="$TMP_DIR/merge-response.json"
  local body
  local status
  local path
  local path_candidates=()

  if [[ -n "$MERGE_PATH" ]]; then
    path_candidates=("$MERGE_PATH")
  else
    path_candidates=("${DEFAULT_MERGE_PATHS[@]}")
  fi

  body="$(jq -cn --arg uploadId "$UPLOAD_ID" '{uploadId: $uploadId}')"

  # Prefer the confirmed OpenAPI path, then fall back to legacy guesses.
  for path in "${path_candidates[@]}"; do
    status="$(post_json "$path" "$body" "$response_file")" || {
      log "Merge request failed to reach ${path}, trying next candidate if available"
      continue
    }

    if [[ "$status" == "404" ]]; then
      log "Merge endpoint ${path} returned HTTP 404, trying next candidate"
      continue
    fi

    ensure_http_success "$status" "$response_file" "merge request (${path})"
    ensure_api_success "$response_file" "merge request (${path})"
    log "Merge succeeded via ${path}"
    UPLOAD_STARTED="false"
    return 0
  done

  fail "Unable to merge uploaded parts. Re-run with --merge-path using the exact endpoint from your deployment docs if needed."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --endpoint)
        ENDPOINT="$2"
        shift 2
        ;;
      --api-key)
        API_KEY="$2"
        shift 2
        ;;
      --app-id)
        APP_ID="$2"
        shift 2
        ;;
      --version)
        VERSION="$2"
        shift 2
        ;;
      --env)
        ENVIRONMENT="$2"
        shift 2
        ;;
      --file)
        FILE_PATH="$2"
        shift 2
        ;;
      --need-cover)
        NEED_COVER="$(normalize_bool "$2")"
        shift 2
        ;;
      --chunk-size-mb)
        CHUNK_SIZE_MB="$2"
        shift 2
        ;;
      --merge-path)
        MERGE_PATH="$2"
        shift 2
        ;;
      --cancel-path)
        CANCEL_PATH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

validate_args() {
  [[ -n "$ENDPOINT" ]] || fail "--endpoint is required"
  [[ -n "$API_KEY" ]] || fail "--api-key is required"
  [[ -n "$APP_ID" ]] || fail "--app-id is required"
  [[ -n "$FILE_PATH" ]] || fail "--file is required"

  ENDPOINT="${ENDPOINT%/}"

  [[ -f "$FILE_PATH" ]] || fail "File does not exist: $FILE_PATH"
  [[ "$FILE_PATH" == *.zip ]] || fail "--file must point to a .zip file"
  [[ "$CHUNK_SIZE_MB" =~ ^[0-9]+$ ]] || fail "--chunk-size-mb must be an integer"
  (( CHUNK_SIZE_MB >= 1 )) || fail "--chunk-size-mb must be at least 1"
  (( CHUNK_SIZE_MB <= 10 )) || fail "--chunk-size-mb must be <= 10"

  if [[ -n "$VERSION" && -z "$ENVIRONMENT" ]]; then
    log "Warning: --version is set without --env. The upload target may be less specific."
  fi

  if [[ -z "$VERSION" && -n "$ENVIRONMENT" ]]; then
    log "Warning: --env is set without --version. The upload target may be less specific."
  fi
}

check_dependencies() {
  require_command curl
  require_command jq
  require_command split
  require_command mktemp
  require_command wc
}

init_upload() {
  local init_payload
  local response_file="$TMP_DIR/init-response.json"
  local status

  # Keep optional fields out of the request body when the caller does not provide them.
  init_payload="$(jq -cn \
    --arg appId "$APP_ID" \
    --arg version "$VERSION" \
    --arg env "$ENVIRONMENT" \
    --argjson needCover "$NEED_COVER" \
    '
    {
      appId: $appId,
      version: (if $version == "" then null else $version end),
      env: (if $env == "" then null else $env end),
      needCover: $needCover
    }
    | with_entries(select(.value != null))
    '
  )"

  status="$(post_json "/api/v1/rum_sourcemap/multipart_upload_init" "$init_payload" "$response_file")" || {
    fail "Unable to reach multipart init endpoint"
  }

  ensure_http_success "$status" "$response_file" "multipart init"
  ensure_api_success "$response_file" "multipart init"

  UPLOAD_ID="$(jq -r '.content.uploadId // empty' "$response_file")"

  if [[ -z "$UPLOAD_ID" ]]; then
    fail "Init succeeded but uploadId is empty. This usually means the same sourcemap already exists and overwrite is disabled."
  fi

  UPLOAD_STARTED="true"
  log "Init succeeded, uploadId=${UPLOAD_ID}"
}

split_file() {
  local chunk_size_bytes=$((CHUNK_SIZE_MB * 1024 * 1024))

  split -b "$chunk_size_bytes" -d -a 6 "$FILE_PATH" "$TMP_DIR/chunk_"
}

upload_parts() {
  local chunks=("$TMP_DIR"/chunk_*)
  local total_parts="${#chunks[@]}"
  local index=0
  local response_file
  local status
  local chunk

  if [[ "$total_parts" -eq 1 && ! -e "${chunks[0]}" ]]; then
    fail "No chunk files were created"
  fi

  response_file="$TMP_DIR/upload-part-response.json"

  # Chunk indexes are zero-based to match the OpenAPI contract.
  for chunk in "${chunks[@]}"; do
    log "Uploading part $((index + 1))/${total_parts}"
    status="$(upload_part_request "$chunk" "$index" "$response_file")" || {
      fail "Failed to upload part ${index}"
    }

    ensure_http_success "$status" "$response_file" "upload part ${index}"
    ensure_api_success "$response_file" "upload part ${index}"
    index=$((index + 1))
  done
}

print_summary() {
  local file_size_bytes

  file_size_bytes="$(wc -c <"$FILE_PATH" | tr -d '[:space:]')"
  log "Upload complete"
  log "Summary: appId=${APP_ID} version=${VERSION:-<unset>} env=${ENVIRONMENT:-<unset>} file=${FILE_PATH} sizeBytes=${file_size_bytes}"
}

main() {
  parse_args "$@"
  NEED_COVER="$(normalize_bool "$NEED_COVER")"
  check_dependencies
  validate_args

  TMP_DIR="$(mktemp -d)"

  init_upload
  split_file
  upload_parts
  merge_upload
  print_summary
}

main "$@"
