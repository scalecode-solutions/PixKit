#!/usr/bin/env bash
# Runs PixKit's live BYTES tests (uploads, downloads, cache) against a
# THROWAWAY local mvPix, never the dev stack on :6102 (they write) and never
# anything but localhost. Test accounts only, never a real person's:
# A and B are friends; the outsider is B's friend but not A's.
#
#   BASE=http://localhost:6122 SIM=<your sim> A=<id> B=<id> OUT=<id> scripts/live-bytes-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SERVER=${SERVER:-../mvPix}
BASE=${BASE:?set BASE to a throwaway mvPix (e.g. http://localhost:6122)}
case "$BASE" in http://localhost:*|http://127.0.0.1:*) ;; *) echo "refusing: live tests are localhost only"; exit 2;; esac
case "$BASE" in *:6102|*:6102/) echo "refusing: :6102 is the dev stack; these tests write. Use a throwaway server."; exit 2;; esac
A=${A:?set A, B and OUT to test account ids (A and B friends; OUT a friend of B, not of A)}
B=${B:?set B}
OUT=${OUT:?set OUT}
SIM=${SIM:?set SIM to your own simulator (not a shared PixLab sim)}
SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM"; exit 2; }
curl -fsS "$BASE/health" >/dev/null || { echo "no mvPix at $BASE"; exit 2; }

KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
mint() { (cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$1"); }

set +o pipefail
TEST_RUNNER_PIX_BYTES_BASE=$BASE \
TEST_RUNNER_PIX_BYTES_A=$A TEST_RUNNER_PIX_BYTES_A_TOKEN=$(mint "$A") \
TEST_RUNNER_PIX_BYTES_B=$B TEST_RUNNER_PIX_BYTES_B_TOKEN=$(mint "$B") \
TEST_RUNNER_PIX_BYTES_OUT=$OUT TEST_RUNNER_PIX_BYTES_OUT_TOKEN=$(mint "$OUT") \
  xcodebuild test -scheme PixKit -destination "platform=iOS Simulator,id=$SIM_ID" \
    -only-testing:PixKitTests/LiveBytesTests 2>&1 | tee /tmp/pixkit-live-bytes.log | grep -E "✔|✘|error:|Test run|recorded an issue|↳"
exit "${PIPESTATUS[0]}"
