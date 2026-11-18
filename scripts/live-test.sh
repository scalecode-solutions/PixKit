#!/usr/bin/env bash
# Runs PixKit's live transport tests against the LOCAL mvPix stack
# (../mvPix, docker compose up), as a TEST account. Never a real person's.
# The C1 tests only read; later ones write to a throwaway server (BASE=…).
#
#   scripts/live-test.sh <user-uuid>
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/live-test.sh <user-uuid> (a test account)}
SERVER=${SERVER:-../mvPix}
BASE=${BASE:-http://localhost:6102}
case "$BASE" in http://localhost:*|http://127.0.0.1:*) ;; *) echo "refusing: live tests are localhost only"; exit 2;; esac
SIM=${SIM:-PixLab27}
SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM"; exit 2; }
curl -fsS "$BASE/health" >/dev/null || { echo "mvPix isn't up at $BASE (cd $SERVER && docker compose up -d)"; exit 2; }

KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")

set +o pipefail
TEST_RUNNER_PIX_LIVE_BASE=$BASE TEST_RUNNER_PIX_LIVE_USER=$USER_ID TEST_RUNNER_PIX_LIVE_TOKEN=$TOKEN \
  xcodebuild test -scheme PixKit -destination "platform=iOS Simulator,id=$SIM_ID" \
    -only-testing:PixKitTests/LiveTransportTests 2>&1 | tee /tmp/pixkit-live.log | grep -E "✔|✘|error:|Test run|recorded an issue"
exit "${PIPESTATUS[0]}"
