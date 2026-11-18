#!/usr/bin/env bash
# Runs PixLab's UI tests against the LOCAL mvPix, signed in as a TEST account
# through the debug dev sign-in. Never a real person's account.
#
#   scripts/ui-test.sh <user-uuid>        SIM=PixLab26 for the smaller phone
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/ui-test.sh <user-uuid> (a test account)}
SERVER=${SERVER:-../mvPix}
BASE=http://localhost:6102   # the Lab's Local server
SIM=${SIM:-PixLab27}
SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM"; exit 2; }
curl -fsS "$BASE/health" >/dev/null || { echo "mvPix isn't up at $BASE (cd $SERVER && docker compose up -d)"; exit 2; }

KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")
BUNDLE=/tmp/pixlab-ui-$SIM-$(date +%s).xcresult

set +o pipefail
TEST_RUNNER_PIX_DEV_TOKEN=$TOKEN TEST_RUNNER_PIX_DEV_USER=$USER_ID \
  xcodebuild test -project Demo/PixLab.xcodeproj -scheme PixLab \
    -destination "platform=iOS Simulator,id=$SIM_ID" -resultBundlePath "$BUNDLE" 2>&1 \
  | tee /tmp/pixlab-ui.log | grep -E "Test Case .*(passed|failed)|error:|TEST (SUCCEEDED|FAILED)"
status=${PIPESTATUS[0]}
echo "result bundle: $BUNDLE"
exit "$status"
