# FaceFind — on-device face recognition (SwiftUI + Vision + SQLite)

Face recognition that never leaves the iPhone. Enroll people from a photo
(library or camera), then recognize them in real time from the live camera.

## What runs where
- **Vision framework, on-device:**
  - Face detection: `VNDetectFaceRectanglesRequest` (revision 2)
  - Face embedding: `VNGenerateImageFeaturePrintRequest` with
    `regionOfInterest` = the detected face box (per-face crop) →
    `VNFeaturePrintObservation` whose `.data` is a Float32 vector.
  - NOTE: Apple's 128-d `VNGenerateFaceprintRequest` is NOT public API on iOS
    (verified against the iOS 27 SDK: no header, no exported symbol, no Swift
    interface). The featureprint-of-face-crop above is Apple's public
    equivalent and is what this app uses.
- **SQLite** (`facefind.sqlite` in the app sandbox Documents dir):
  `faces(id, name, embedding BLOB, created_at)` — one row per enrollment,
  embedding stored as raw Float32 bytes (BLOB), per the spec.
- **Matching:** cosine similarity via vDSP against every enrolled vector.
  Hundreds of enrollments stay cheap (single vDSP pass per row per frame).

## Live recognition details (per the spec)
- Frames stream via `AVCaptureVideoDataOutput`; **every 3rd frame** goes to
  Vision; the last-known results are reused/redrawn between passes.
- All detection + embedding + DB matching on a serial **background queue**
  (`facefind.vision`, userInitiated); the camera preview never blocks.
- **Tracking:** a detected face maps to the track with the highest IoU
  (≥ 0.3) of its bounding box; boxes are blended 60/40 between passes to
  reduce jitter; a track ages out after 4 unseen passes (misses).
- **Temporal smoothing:** a match is confirmed only after **4 consecutive
  consistent hits** with cosine similarity **> 0.60**; similarity below the
  bar drops the label immediately (glancing at strangers won't name them).
- **Confidence history:** each track keeps a rolling buffer of its last
  **10 similarity scores**, drawn as a small bar **sparkline** next to the
  face box (green bars = above threshold, orange = below).
- **Multiple faces** are tracked independently; **no face** → hint text;
  **low confidence** → amber box with live % instead of a name.

## Screens
1. **recognize** — live camera + overlay (boxes, names, sparklines).
2. **register** — library/camera photo → name → faceprint → SQLite.
3. **people** — enrolled people (#faceprints each), delete with
   double-confirm.

## Privacy
Everything (detection, embeddings, matching, storage) is on-device. No
network calls, no analytics, nouploads. Photos are read only to compute the
faceprint.

## Setup & build (from scratch)
1. Requirements: Xcode 27+ (iOS 26.5+ SDK), an iPhone with a camera, paid or
   free Apple Developer signing.
2. Open `FaceFind.xcodeproj`, set your Team (target
   FaceFind → Signing & Capabilities), bundle id is `com.fdohen.facefind`.
3. Build/run:
   ```
   xcodebuild -project FaceFind.xcodeproj -target FaceFind -configuration Debug \
     -sdk iphoneos -destination 'generic/platform=iOS' build
   xcrun devicectl device install app --device <UDID> build/Debug-iphoneos/FaceFind.app
   xcrun devicectl device process launch --device <UDID> com.fdohen.facefind
   ```
4. First launch → allow camera. Allow photo library when registering from
   your library.

## Usage
1. **register** tab → type a name → pick a photo (frontal, well-lit) →
   "save faceprint". Add several photos of the same person (2-3 angles) for
   robust matching — each is a row; best similarity wins.
2. **recognize** tab → point the camera at the person → after ~0.5 s the box
   turns green with their name; the sparkline shows how solid the match is.
3. Delete people in **people** (double-confirm, instantly affects matching).

## Files
- `FaceFind/ContentView.swift` — 3 tabs, overlay, sparkline, pickers
- `FaceFind/LiveFaceScanner.swift` — camera, frame skipping, tracking, smoothing
- `FaceFind/FaceEngine.swift` — Vision detection + embedding + cosine matching
- `FaceFind/FaceDatabase.swift` — SQLite (BLOB faceprints, prepared statements)
- `FaceFind/KeychainStore.swift` — not used by this app (kept pattern from TestShot)

## Tunables (top of LiveFaceScanner.swift)
`processEveryNthFrame = 3` · `kThreshold = 0.6` · `kConsistentHits = 4` ·
`iouGate = 0.3` · `historyLen = 10`