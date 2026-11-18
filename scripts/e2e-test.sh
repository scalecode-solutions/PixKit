#!/usr/bin/env bash
# The end-to-end UI test (PixLabEndToEndUITests) against a THROWAWAY local
# mvPix: it writes (a space, uploads, a delete). Never :6102, never production.
#
#   BASE=http://localhost:6103 DB=<its postgres container> scripts/e2e-test.sh <user-uuid> <friend-uuid>   (test accounts)
# The simulator needs media first: xcrun simctl addmedia <sim> photo.jpg big.mov
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/e2e-test.sh <user-uuid> <friend-uuid>}
FRIEND=${2:?usage: scripts/e2e-test.sh <user-uuid> <friend-uuid>}
SERVER=${SERVER:-../mvPix}
BASE=${BASE:?BASE=http://localhost:<throwaway port>}
case "$BASE" in http://localhost:6102*|http://127.0.0.1:6102*) echo "refusing: :6102 is the shared stack"; exit 2;; esac
case "$BASE" in http://localhost:*|http://127.0.0.1:*) ;; *) echo "refusing: localhost only"; exit 2;; esac
SIM=${SIM:-PixLab27}
SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM"; exit 2; }
curl -fsS "$BASE/health" >/dev/null || { echo "no mvPix at $BASE"; exit 2; }
# The throwaway's database container: each run starts with no spaces, items or
# uploads there (the graph stays). Refused for the shared stack's pix-db.
DB=${DB:?DB=<the throwaway postgres container>}
[ "$DB" != "pix-db" ] || { echo "refusing: pix-db is the shared stack"; exit 2; }
docker exec "$DB" psql -U pix -d pix -qc "TRUNCATE uploads, items, blobs, spaces CASCADE" >/dev/null

# The clip recorder needs the microphone: grant it rather than meet a prompt.
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl privacy "$SIM_ID" grant microphone dev.scalecode.PixLab

KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")
BUNDLE=/tmp/pixlab-e2e-$SIM-$(date +%s).xcresult

set +o pipefail
TEST_RUNNER_PIX_E2E=1 TEST_RUNNER_PIX_DEV_TOKEN=$TOKEN TEST_RUNNER_PIX_DEV_USER=$USER_ID \
TEST_RUNNER_PIX_DEV_BASE=$BASE TEST_RUNNER_PIX_E2E_FRIEND=$FRIEND \
  xcodebuild test -project Demo/PixLab.xcodeproj -scheme PixLab \
    -destination "platform=iOS Simulator,id=$SIM_ID" -resultBundlePath "$BUNDLE" \
    -only-testing:PixLabUITests/PixLabEndToEndUITests 2>&1 \
  | tee /tmp/pixlab-e2e.log | grep -E "Test Case .*(passed|failed)|error:|TEST (SUCCEEDED|FAILED)"
status=${PIPESTATUS[0]}
echo "result bundle: $BUNDLE"
exit "$status"
