# PixKit

A shared photo space between two friends, as a Swift package: photos, videos
and audio clips that either person can add, view, save or remove (their own).
It talks to an mvPix server: Connect/protobuf for the metadata, plain HTTP for
the bytes (resumable uploads, Range downloads).

- iOS 26, Swift 6 strict concurrency.
- The host owns sign-in: it hands PixKit a `tokenProvider` and the user's id
  (`PixConfig`). PixKit never logs anyone in.
- No notifications of any kind.

## PixLab

`Demo/` is the harness app (`cd Demo && xcodegen generate`). It signs in
against mvServer with MvAuth, or, in Debug against a local stack, with
`PIX_DEV_TOKEN` + `PIX_DEV_USER` in the launch environment.

## Tests

- Units: `xcodebuild test -scheme PixKit -destination 'platform=iOS Simulator,name=<sim>' -skip-testing:PixKitTests/LiveTransportTests`
- Live (localhost only, a test account): `scripts/live-test.sh <user-uuid>`
- UI: `scripts/ui-test.sh <user-uuid>` (`SIM=` picks the simulator)
- End to end (writes; a throwaway local mvPix only): `BASE=http://localhost:<port> DB=<its postgres container> scripts/e2e-test.sh <user-uuid> <friend-uuid>`, after `xcrun simctl addmedia <sim>` with a photo and a video over 1080p
