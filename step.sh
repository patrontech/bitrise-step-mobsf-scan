#!/usr/bin/env bash
#
# Scans an IPA or APK with MobSF, running in Docker, and writes the PDF report,
# the JSON report, and the scorecard into a fresh output directory.
#
# Findings never fail the step: the report is the deliverable. The step fails
# only when it cannot produce a valid report.
#
# Requires docker, curl, and jq (all preinstalled on Bitrise's Linux stacks).

set -euo pipefail

log() { printf '\e[34m[mobsf]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[mobsf] ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

# --- Inputs -------------------------------------------------------------------

target_path="${target_path:-}"
platform="${platform:-}"
report_prefix="${report_prefix:-MobSF}"
mobsf_image="${mobsf_image:-opensecurity/mobile-security-framework-mobsf:v4.5.3}"
output_dir="${output_dir:-}"
startup_timeout="${startup_timeout:-600}"
scan_timeout="${scan_timeout:-3600}"

[[ -n $target_path ]] || fail "target_path is required."
[[ -f $target_path ]] || fail "target_path '$target_path' does not exist or is not a file."
[[ $startup_timeout =~ ^[0-9]+$ ]] || fail "startup_timeout must be a whole number of seconds."
[[ $scan_timeout =~ ^[0-9]+$ ]] || fail "scan_timeout must be a whole number of seconds."

case "${target_path##*.}" in
  ipa) default_platform=iOS ;;
  apk | aab) default_platform=Android ;;
  *) fail "target_path must be an .ipa, .apk, or .aab, not '$(basename "$target_path")'." ;;
esac
platform="${platform:-$default_platform}"

for tool in docker curl jq; do
  command -v "$tool" > /dev/null || fail "'$tool' is not installed. This step needs a Linux stack with Docker."
done

if [[ -z $output_dir ]]; then
  output_dir="$(mktemp -d "${TMPDIR:-/tmp}/mobsf-report.XXXXXX")"
else
  mkdir -p "$output_dir"
  [[ -z "$(ls -A "$output_dir")" ]] || fail "output_dir '$output_dir' must be empty, so that only reports get deployed from it."
fi

# Exports a step output (when running under Bitrise) and prints it.
export_output() {
  if command -v envman > /dev/null; then
    envman add --key "$1" --value "$2"
  fi
  printf '  %-22s %s\n' "$1" "$2"
}

# Export the output directory now rather than at the end, so that a failed run
# can still deploy MobSF's container log from it.
log "Output directory:"
export_output MOBSF_OUTPUT_DIR "$output_dir"

# --- MobSF container ----------------------------------------------------------

# The container is local and lives only as long as this step, so a throwaway
# key is enough. Nothing needs to be stored as a secret.
api_key="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
container="mobsf-$$-$RANDOM"

cleanup() {
  local status=$?
  if docker container inspect "$container" > /dev/null 2>&1; then
    if [[ $status -ne 0 ]]; then
      docker logs "$container" > "$output_dir/mobsf-container.log" 2>&1 || true
      log "The last lines of MobSF's container log (all of it is in $output_dir/mobsf-container.log):"
      tail -n 60 "$output_dir/mobsf-container.log" >&2 || true
    fi
    docker rm -f "$container" > /dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

log "Pulling $mobsf_image…"
for attempt in 1 2 3 4; do
  if docker pull --quiet "$mobsf_image"; then
    break
  elif [[ $attempt -eq 4 ]]; then
    fail "Could not pull $mobsf_image."
  fi
  log "Pull failed (attempt $attempt). Retrying in $((attempt * 15))s…"
  sleep $((attempt * 15))
done

# Publish on a random port, so concurrent runs and anything else already
# listening on 8000 don't collide.
docker run --detach --name "$container" \
  --env MOBSF_API_KEY="$api_key" \
  --publish 8000 \
  "$mobsf_image" > /dev/null

# Where MobSF is reachable depends on where the Docker daemon runs. With a
# local daemon it's the published port on loopback. When the build itself runs
# in a container that shares the host's daemon, the published port is on the
# *host*, so try the container's bridge address too. Whichever answers first wins.
port="$(docker port "$container" 8000/tcp | head -n 1 | sed 's/.*://')"
bridge_ip="$(docker container inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$container" | awk '{print $1}')"
candidates=("http://127.0.0.1:$port")
[[ -n $bridge_ip ]] && candidates+=("http://$bridge_ip:8000")

log "Waiting up to ${startup_timeout}s for MobSF to start (trying ${candidates[*]})…"
deadline=$((SECONDS + startup_timeout))
base_url=""
while [[ -z $base_url ]]; do
  for candidate in "${candidates[@]}"; do
    if curl --silent --fail --output /dev/null --max-time 5 \
      --header "Authorization: $api_key" "$candidate/api/v1/scans"; then
      base_url="$candidate/api/v1"
      break
    fi
  done
  [[ -n $base_url ]] && break
  if [[ "$(docker container inspect --format '{{.State.Running}}' "$container")" != true ]]; then
    fail "The MobSF container exited during startup."
  fi
  ((SECONDS < deadline)) || fail "MobSF did not start within ${startup_timeout}s."
  sleep 5
done
log "MobSF is up at ${base_url%/api/v1}."

# --- Scan ---------------------------------------------------------------------

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mobsf-work.XXXXXX")"

# POSTs to the MobSF API, writing the response body to $2 and failing on any
# non-2xx status. The remaining arguments go to curl.
api() {
  local endpoint=$1 out=$2 max_time=$3
  shift 3
  local status
  status="$(curl --silent --show-error --max-time "$max_time" \
    --header "Authorization: $api_key" \
    --output "$out" --write-out '%{http_code}' \
    "$@" "$base_url/$endpoint")" || fail "$endpoint: the request failed."
  if [[ $status != 2* ]]; then
    printf '%s\n' "$(head -c 2000 "$out")" >&2
    fail "$endpoint: HTTP $status."
  fi
}

log "Uploading $(basename "$target_path") ($(du -h "$target_path" | cut -f1))…"
api upload "$work_dir/upload.json" 1800 --form "file=@$target_path"
hash="$(jq -er '.hash' "$work_dir/upload.json")" || fail "upload: no hash in the response."

log "Scanning (hash $hash). This can take a while…"
started=$SECONDS
api scan "$work_dir/scan.json" "$scan_timeout" --data-urlencode "hash=$hash"
log "Scan finished in $((SECONDS - started))s."

api report_json "$work_dir/report.json" 600 --data-urlencode "hash=$hash"
api scorecard "$work_dir/scorecard.json" 600 --data-urlencode "hash=$hash"
api download_pdf "$work_dir/report.pdf" 1800 --data-urlencode "hash=$hash"

# --- Check and name the results -----------------------------------------------

[[ "$(head -c 5 "$work_dir/report.pdf")" == "%PDF-" ]] \
  || fail "download_pdf did not return a PDF. Its response began: $(head -c 300 "$work_dir/report.pdf")"
pdf_size="$(wc -c < "$work_dir/report.pdf" | tr -d ' ')"
((pdf_size > 10000)) || fail "The PDF report is only $pdf_size bytes, which is too small to be a real report."

# The scorecard normalizes iOS and Android to the same field names. The JSON
# report is the fallback for the build number, which only it carries.
app_name="$(jq -r '.app_name // empty' "$work_dir/scorecard.json")"
app_version="$(jq -r '.version_name // empty' "$work_dir/scorecard.json")"
app_build="$(jq -r '.version_code // .build // empty' "$work_dir/report.json")"
security_score="$(jq -r '.security_score // empty' "$work_dir/scorecard.json")"
mobsf_version="$(jq -r '.version // empty' "$work_dir/report.json")"
mobsf_version="${mobsf_version:-${mobsf_image##*:}}"

# Keep file names portable: anything outside [A-Za-z0-9._-] becomes '_'.
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
stem="$(sanitize "$report_prefix")-$(sanitize "$platform")-MobSF-$(date -u +%Y-%m)"
[[ -n $app_version ]] && stem+="-v$(sanitize "$app_version")"
[[ -n $app_build ]] && stem+="-b$(sanitize "$app_build")"

pdf_path="$output_dir/$stem.pdf"
json_path="$output_dir/$stem.json"
scorecard_path="$output_dir/$stem-scorecard.json"
mv "$work_dir/report.pdf" "$pdf_path"
mv "$work_dir/report.json" "$json_path"
mv "$work_dir/scorecard.json" "$scorecard_path"
rm -rf "$work_dir"

# --- Outputs ------------------------------------------------------------------

log "Done. Outputs:"
export_output MOBSF_PDF_PATH "$pdf_path"
export_output MOBSF_JSON_PATH "$json_path"
export_output MOBSF_SCORECARD_PATH "$scorecard_path"
export_output MOBSF_APP_NAME "$app_name"
export_output MOBSF_APP_VERSION "$app_version"
export_output MOBSF_APP_BUILD "$app_build"
export_output MOBSF_SECURITY_SCORE "$security_score"
export_output MOBSF_VERSION "$mobsf_version"
