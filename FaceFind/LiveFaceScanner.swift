import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import UIKit

// MARK: - Live camera + face tracker
//
// AVCaptureVideoDataOutput streams continuously. Frame cadence: every 3rd frame
// goes to FaceEngine (analyze = detect + embed + match, on a serial background
// queue); results are CACHED between processed frames and re-displayed at 30fps.
// Tracking: a face is the same person if its bounding box overlaps (IoU ≥ 0.3)
// the previous frame's box. Confirmation needs `kConsistentHits` consecutive
// frames with similarity > kThreshold (temporal smoothing — kills glancing
// false positives). Each track keeps a rolling buffer of the last 10 similarity
// scores for the sparkline overlay.

final class LiveFaceScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    static let shared = LiveFaceScanner()

    // ---- tunables (Settings screen mutates these live) ----
    static var processEveryNthFrame = 3
    static var kThreshold: Float = 0.6        // cosine similarity bar (user spec)
    static var kConsistentHits = 4            // consecutive frames above bar (3-5 spec)
    static let iouGate: Float = 0.3           // same-face gate between frames
    static var historyLen = 10                // rolling similarity buffer

    // ---- published state (main thread) ----
    struct FaceView {
        let id: Int
        let rect: CGRect                      // in layer coords (UIKit orientation)
        let name: String?                     // nil until confirmed
        let similarity: Float                 // latest score
        let confirmed: Bool
        let history: [Float]                  // last ≤10 scores for sparkline
    }

    var onFaces: (([FaceView]) -> Void)?      // called on main queue every frame

    // ---- camera ----
    let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "facefind.session")   // ALL config + start/stop
    private let queue = DispatchQueue(label: "facefind.capture")          // sample-buffer DELIVERY ONLY
    private let workQueue = DispatchQueue(label: "facefind.vision", qos: .userInitiated) // Vision work
    private let ciContext = CIContext()

    // ---- tracking state (work queue only) ----
    private final class Track {
        let id: Int
        var box: CGRect
        var name: String?
        var lastSimilarity: Float = 0
        var history: [Float] = []
        var hits = 0                          // consecutive consistent hits
        var missCount = 0
        init(id: Int, box: CGRect) { self.id = id; self.box = box }
    }

    private var tracks: [Track] = []
    private var nextTrackID = 1
    private var frameCounter = 0
    private var busy = false                  // one Vision job at a time (frame-skip backstop)
    private var databaseEntries: [FaceDatabase.Entry] = []
    private var orientation: CGImagePropertyOrientation = .right

    // MARK: camera start/stop (sessionQueue ONLY — Apple AVCam pattern:
    // startRunning/stopRunning MUST NOT share a queue with frame delivery or
    // beginConfiguration can deadlock against an in-flight buffer callback —
    // that exact deadlock froze the screen on the previous switch build)
    func start() {
        sessionQueue.async { self._startSync() }
    }

    // position: .front (default, mirrored like a selfie) or .back
    static var preferredPosition: AVCaptureDevice.Position = .front

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let input = self.session.inputs.first as? AVCaptureDeviceInput {
                Self.preferredPosition = input.device.position == .front ? .back : .front
            } else {
                Self.preferredPosition = Self.preferredPosition == .front ? .back : .front
            }
            self._startSync()
        }
    }

    private func _startSync() {
        // idempotent fast-path: requested camera already built and running
        if session.isRunning,
           let current = session.inputs.first as? AVCaptureDeviceInput,
           current.device.position == Self.preferredPosition {
            return
        }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        // drop ALL existing video inputs (switch = remove + re-add clean)
        for input in session.inputs where input is AVCaptureDeviceInput {
            session.removeInput(input)
        }
        session.sessionPreset = .high
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: Self.preferredPosition)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { session.commitConfiguration(); return }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(videoOut)
        else { session.commitConfiguration(); return }
        session.addInput(input)
        let firstBuild = session.outputs.isEmpty
        if firstBuild {
            session.addOutput(videoOut)
            // delegate attach happens ONCE, on first build only; the delivery
            // queue is separate from this config queue (no deadlock path)
            videoOut.setSampleBufferDelegate(self, queue: queue)
        }
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true
        if let conn = videoOut.connection(with: .video) {
            // front camera is mirrored like a selfie; rear stays unmirrored
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (device.position == .front)
            orientation = conn.isVideoMirrored ? .leftMirrored : .right
        }
        session.commitConfiguration()
        // first build → load the enrollment snapshot (already on sessionQueue,
        // same serialization as reloadDatabase)
        if firstBuild { databaseEntries = FaceDatabase.shared.allEntries() }
        // ALWAYS (re)start: after a rebuild the pipeline must be running or the
        // preview layer gets no frames = black screen.
        session.startRunning()
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func reloadDatabase() {
        // snapshot swap on the config queue serializes with camera rebuilds;
        // workQueue reads `databaseEntries` (value-type array — safe read)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.databaseEntries = FaceDatabase.shared.allEntries()
        }
    }

    // MARK: frame delegate
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % Self.processEveryNthFrame == 0,      // every 3rd frame
              !busy,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            // between Vision passes: republish the last-known positions every few frames
            if frameCounter % Self.processEveryNthFrame == 0 { publishFromTracks() }
            return
        }
        busy = true
        let dbEntries = databaseEntries
        let ornt = orientation
        let thisCounter = frameCounter
        workQueue.async { [weak self] in
            let detected = FaceEngine.analyze(pixelBuffer: pixelBuffer, orientation: ornt)
            self?.integrate(detected: detected, at: thisCounter)
            self?.busy = false
        }
    }

    // MARK: match detected faces into tracks (work queue)
    private func integrate(detected: [FaceEngine.DetectedFace], at counter: Int) {
        for face in detected {
            // 1. nearest track by IoU
            var track: Track?
            var bestIoU: Float = 0
            for t in tracks where t.missCount < 4 {
                let iou = Self.iou(t.box, face.box)
                if iou > bestIoU { bestIoU = iou; track = t }
            }
            let isSame = bestIoU >= Self.iouGate
            if track == nil || !isSame {
                let t = Track(id: nextTrackID, box: face.box)
                nextTrackID += 1
                tracks.append(t)
                track = t
            }
            guard let t = track else { continue }
            t.box = blend(t.box, face.box)          // smooth jitter
            t.missCount = 0

            // 2. similarity (reuse DB snapshot; matches cost one vDSP pass per person)
            let match = FaceEngine.bestMatch(for: face.vector, entries: databaseEntries)
            let score = match?.similarity ?? 0
            t.lastSimilarity = score
            t.history.append(score)
            if t.history.count > Self.historyLen { t.history.removeFirst(t.history.count - Self.historyLen) }

            // 3. temporal smoothing: confirm after kConsistentHits above threshold
            if score >= Self.kThreshold {
                t.hits += 1
                if t.hits >= Self.kConsistentHits, t.name == nil || t.name != match?.name {
                    t.name = match?.name
                }
            } else {
                t.hits = 0
                t.name = nil                         // below bar: drop the label immediately
            }
        }

        // miss handling: tracks not seen this pass age out after 4 Vision passes
        let seenBoxes = detected.map(\.box)
        for t in tracks {
            let seen = seenBoxes.contains { Self.iou($0, t.box) >= Self.iouGate }
            if !seen { t.missCount += 1 }
        }
        tracks.removeAll { $0.missCount >= 4 }

        publishFromTracks(counter: counter)
    }

    // MARK: publish to UI (main)
    private func publishFromTracks(counter: Int = 0) {
        let views = tracks.map { t in
            FaceView(id: t.id,
                     rect: t.box,
                     name: t.name,
                     similarity: t.lastSimilarity,
                     confirmed: t.name != nil,
                     history: t.history)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onFaces?(views)
        }
    }

    // MARK: geometry helpers
    private func blend(_ old: CGRect, _ new: CGRect) -> CGRect {
        CGRect(x: old.minX * 0.6 + new.minX * 0.4,
               y: old.minY * 0.6 + new.minY * 0.4,
               width: old.width * 0.6 + new.width * 0.4,
               height: old.height * 0.6 + new.height * 0.4)
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let u = a.width * a.height + b.width * b.height - interArea
        return u > 0 ? Float(interArea / u) : 0
    }
}