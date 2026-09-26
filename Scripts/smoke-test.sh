#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGED_APP="$ROOT_DIR/dist/verify-extracted/EchoFlow.app"
BUILD_DIR="$ROOT_DIR/.build"
BUILD_BACKUP="$ROOT_DIR/.build-smoke-test-backup.$$"
SMOKE_PARENT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

if [[ ! -d "$PACKAGED_APP" ]]; then
    printf 'Extracted packaged app does not exist: %s\n' "$PACKAGED_APP" >&2
    exit 1
fi
test -x "$PACKAGED_APP/Contents/MacOS/EchoFlow"
test -s "$PACKAGED_APP/Contents/Resources/EchoFlow_EchoFlowCore.bundle/model-manifest.json"

mkdir -p "$SMOKE_PARENT"
SMOKE_DIR="$(mktemp -d "$SMOKE_PARENT/echoflow-smoke.XXXXXX")"
SMOKE_APP="$SMOKE_DIR/EchoFlow.app"

echo 'Copying the extracted release app to a clean temporary location.'
ditto "$PACKAGED_APP" "$SMOKE_APP"

cleanup() {
    status=$?
    trap - EXIT
    if [[ -d "$BUILD_BACKUP" ]]; then
        rm -rf "$BUILD_DIR"
        mv "$BUILD_BACKUP" "$BUILD_DIR"
    fi
    rm -rf "$SMOKE_DIR"
    exit "$status"
}
trap cleanup EXIT

if [[ -e "$BUILD_BACKUP" ]]; then
    printf 'Refusing to overwrite stale build backup: %s\n' "$BUILD_BACKUP" >&2
    exit 1
fi
if [[ -e "$BUILD_DIR" ]]; then
    mv "$BUILD_DIR" "$BUILD_BACKUP"
fi
if [[ -e "$BUILD_DIR" ]]; then
    printf 'Build directory is still present; refusing an unisolated launch test.\n' >&2
    exit 1
fi

printf 'Build directory is unavailable; launching extracted app from %s\n' "$SMOKE_APP"
open -n -g "$SMOKE_APP"

for _ in {1..10}; do
    if pgrep -x EchoFlow >/dev/null 2>&1; then
        sleep 3
        if pgrep -x EchoFlow >/dev/null 2>&1; then
            printf 'Clean-location launch smoke test passed; EchoFlow remained running.\n'
            exit 0
        fi
    fi
    sleep 1
done

printf 'EchoFlow did not remain running after launch without its SwiftPM build directory.\n' >&2
exit 1
