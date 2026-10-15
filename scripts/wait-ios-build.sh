#!/bin/bash
# Wait for an uploaded build to appear in App Store Connect.
set -euo pipefail
asc="${1:?App Store Connect CLI path required}"
: "${BUILD_NUMBER:?Build number required}"
: "${MARKETING_VERSION:?Marketing version required}"
: "${RUNNER_TEMP:?Temporary directory required}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'build_number must contain only digits' >&2; exit 1; }
for attempt in {1..8}; do
  if "$asc" builds info --app com.whetstone.rai.ios --build-number "$BUILD_NUMBER" \
      --version "$MARKETING_VERSION" --platform IOS --output json \
      > "$RUNNER_TEMP/build.json" 2> "$RUNNER_TEMP/build-query-error.txt"; then
    exit 0
  fi
  # A successful upload can precede Apple's build listing by several minutes.
  if ! grep -q 'no build found for app' "$RUNNER_TEMP/build-query-error.txt" || [ "$attempt" -eq 8 ]; then
    cat "$RUNNER_TEMP/build-query-error.txt" >&2
    exit 1
  fi
  echo "Build $BUILD_NUMBER is not listed yet. Retrying in 15 seconds ($attempt/8)." >&2
  sleep 15
done
