#!/bin/bash
# Wait for an uploaded build to appear in App Store Connect.
set -euo pipefail
asc="${1:?App Store Connect CLI path required}"
: "${BUILD_NUMBER:?Build number required}"
: "${MARKETING_VERSION:?Marketing version required}"
: "${RUNNER_TEMP:?Temporary directory required}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'build_number must contain only digits' >&2; exit 1; }
max_attempts="${IOS_BUILD_STATUS_MAX_ATTEMPTS:-8}"
retry_seconds="${IOS_BUILD_STATUS_RETRY_SECONDS:-15}"
[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || { echo 'IOS_BUILD_STATUS_MAX_ATTEMPTS must be a positive integer' >&2; exit 1; }
[[ "$retry_seconds" =~ ^[1-9][0-9]*$ ]] || { echo 'IOS_BUILD_STATUS_RETRY_SECONDS must be a positive integer' >&2; exit 1; }
for ((attempt = 1; attempt <= max_attempts; attempt++)); do
  if "$asc" builds info --app com.whetstone.rai.ios --build-number "$BUILD_NUMBER" \
      --version "$MARKETING_VERSION" --platform IOS --output json \
      > "$RUNNER_TEMP/build.json" 2> "$RUNNER_TEMP/build-query-error.txt"; then
    exit 0
  fi
  # A successful upload can precede Apple's build listing by several minutes.
  if ! grep -q 'no build found for app' "$RUNNER_TEMP/build-query-error.txt"; then
    cat "$RUNNER_TEMP/build-query-error.txt" >&2
    exit 1
  fi
  if [ "$attempt" -eq "$max_attempts" ]; then
    echo "Build $BUILD_NUMBER is not listed after $((max_attempts * retry_seconds)) seconds." >&2
    exit 2
  fi
  echo "Build $BUILD_NUMBER is not listed yet. Retrying in ${retry_seconds} seconds ($attempt/$max_attempts)." >&2
  sleep "$retry_seconds"
done
