#!/usr/bin/env bash
# SOURCE_DIR and LOCKFILE select the source/dependency combination independently.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
runtime="${1:-2.6}"
repetitions="${2:-1000}"
case "$runtime" in
  2.5) image=ruby:2.5.9-buster; source_dir="$repo/tmp/flaky-ci/linux-source-b6a8126" ;;
  2.6) image=ruby:2.6.10-bullseye; source_dir="$repo/tmp/flaky-ci/linux-source-7062" ;;
  3.0) image=ruby:3.0.7-bullseye; source_dir="$repo/tmp/flaky-ci/linux-source-b6a8126" ;;
  *) image="ruby:$runtime"; source_dir="$repo" ;;
esac
source_dir=$(cd "${SOURCE_DIR:-$source_dir}" && pwd)
lockfile="${LOCKFILE:-$repo/tmp/flaky-ci/ci-locks/ruby-$runtime.lock}"
lockfile=$(cd "$(dirname "$lockfile")" && pwd)/$(basename "$lockfile")
test -f "$lockfile"
case "$(uname -m)" in
  arm64|aarch64) native_platform=linux/arm64 ;;
  x86_64) native_platform=linux/amd64 ;;
  *) printf 'Set PLATFORM explicitly for this architecture.\n' >&2; exit 2 ;;
esac
platform="${PLATFORM:-$native_platform}"
architecture="${platform##*/}"
options=()
if [ -n "${CPUS:-}" ]; then options+=(--cpus "$CPUS"); fi
printf 'source=%s\nlockfile=%s\nimage=%s\nplatform=%s\n' "$source_dir" "$lockfile" "${IMAGE:-$image}" "$platform"
exec docker run --rm --init --platform "$platform" "${options[@]}" \
  -v "$source_dir:/subject:ro" \
  -v "$repo/tmp/flaky-ci:/harness:ro" \
  -v "$lockfile:/snapshot.lock:ro" \
  -v "httpclient-flake-ruby-$runtime-$architecture:/usr/local/bundle" \
  -e "REPEAT=$repetitions" -e "LOAD_WORKERS=${LOAD_WORKERS:-0}" \
  -e "TEST_FILE=${TEST_FILE:-test/test_httpclient}" \
  -e "TEST_CLASS=${TEST_CLASS:-TestHTTPClient}" \
  -e "TEST_NAMES=${TEST_NAMES:-test_empty_proxy_env,test_eof_error_length,test_eof_error_rest}" \
  -e "NO_TIMING=${NO_TIMING:-1}" -e "TRACE_TIMEOUT_RAISES=${TRACE_TIMEOUT_RAISES:-0}" \
  -e "JOIN_SERVER_THREADS=${JOIN_SERVER_THREADS:-0}" \
  -e "DRAIN_DIGEST_BODY=${DRAIN_DIGEST_BODY:-0}" \
  "${IMAGE:-$image}" bash /harness/container-entrypoint.sh
