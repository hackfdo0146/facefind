import Foundation
import Photos
import Vision

// MARK: - Library scan: find NEW faces in the user's photo library
//
// iOS gives third-party apps NO public API to Apple Photos' face data:
// verified on the iOS 27 SDK — PHAsset/PHFetchOptions expose face counts or
// person labels nowhere (the People album's ML data stays inside Photos), and
// the smart-album "Faces" subtype exists only as a legacy synced-album
// constant. So "visages already recognized by iPhoto" cannot be read directly.
// Equivalent behavior that IS possible on-device:
//   1. fetch user library assets via PHAsset (full library access permission)
//   2. run VNDetectFaceRectanglesRequest on each image (same engine class the
//      rest of the app uses — same " visage detection")
//   3. embed per-face crops with VNGenerateImageFeaturePrintRequest
//   4. compare against the local SQLite enrollment database (cosine ≥ threshold)
//   5. assets whose faces MATCH a known person → skipped (they're "already
//      recognized"); faces that DON'T match anyone → NEW faces, listed with the
//      asset thumbnail, and can be enrolled into people by name right there.
//
// Performance: batch fetch (paged), a single background serial queue, processed
// assets tracked in UserDefaults so re-scans only look at NEW photos since the
// last scan (incremental). Photos that contain no faces are marked done too.

final class LibraryScanner {

    // MARK: persisted scan state (asset localIdentifier → known-processed)
    private static let processedKey = "facefind.scannedAssets"
    private static var processedCache: Set<String>? = nil

    private static var processed: Set<String> {
        get {
            if let c = processedCache { return c }
            let set = Set(UserDefaults.standard.stringArray(forKey: processedKey) ?? [])
            processedCache = set
            return set
        }
        set {
            processedCache = newValue
            UserDefaults.standard.set(Array(newValue), forKey: processedKey)
        }
    }

    static func processedCount() -> Int { processed.count }

    /// MARK: reset scan memory (forces full rescan)
    static func resetScan() {
        processed = []
    }

    /// MARK: mark one asset as already-handled (People & Pets pre-pass uses this
    /// so photos Apple already attributes to a named person are never re-scanned)
    static func markProcessed(assetID: String) {
        var p = processed
        p.insert(assetID)
        processed = p
    }

    struct NewFace {
        let assetID: String
        let faceIndex: Int       // which face within that asset
        let vector: [Float]
        var bestName: String?    // nil = truly unknown face
        var bestSimilarity: Float
    }

    struct ScanResult {
        let scanned: Int         // assets processed this run
        let newlyFound: [NewFace]// faces not matching any enrolled person
        let knownFaces: Int      // faces that matched an enrolled person (skipped)
        let noFaceAssets: Int    // photos with zero faces
        let remaining: Int       // estimated unscanned assets left
        let done: Bool           // scan finished the whole library
    }

    private static let workQueue = DispatchQueue(label: "facefind.libraryscan", qos: .utility)
    private static var scanning = false

    // MARK: paged scan — one call processes up to `budget` new assets, reports progress.
    // UI calls this repeatedly until result.done == true.
    static func scan(budget: Int,
                     threshold: Float,
                     progress: ((Int, Int) -> Void)?,           // (processedThisRun, estimatedTotalNew)
                     completion: @escaping (ScanResult) -> Void) {
        guard !scanning else {
            completion(ScanResult(scanned: 0, newlyFound: [], knownFaces: 0, noFaceAssets: 0, remaining: 0, done: true))
            return
        }
        scanning = true

        workQueue.async {
            // 1. all photo assets, ascending
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let fetch = PHAsset.fetchAssets(with: opts)
            let done = Self.processed
            var targets: [PHAsset] = []
            fetch.enumerateObjects { asset, _, _ in
                if !done.contains(asset.localIdentifier) { targets.append(asset) }
            }
            let totalNew = targets.count
            let slice = Array(targets.prefix(budget))

            var newlyFound: [NewFace] = []
            var knownFaces = 0
            var noFaceAssets = 0
            var processedIDs = done
            let dbEntries = FaceDatabase.shared.allEntries()

            for (idx, asset) in slice.enumerated() {
                progress?(idx + 1, totalNew)
                let faces = faces(in: asset, entries: dbEntries, threshold: threshold)
                if faces.isEmpty {
                    noFaceAssets += 1
                } else {
                    for f in faces {
                        if f.bestName != nil { knownFaces += 1 }
                        else { newlyFound.append(f) }
                    }
                }
                processedIDs.insert(asset.localIdentifier)
            }
            processed = processedIDs
            scanning = false

            let result = ScanResult(scanned: slice.count,
                                    newlyFound: newlyFound,
                                    knownFaces: knownFaces,
                                    noFaceAssets: noFaceAssets,
                                    remaining: max(0, totalNew - slice.count),
                                    done: totalNew - slice.count <= 0)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: detect + embed + match every face in ONE asset (background queue)
    static func faces(in asset: PHAsset,
                      entries: [FaceDatabase.Entry],
                      threshold: Float) -> [NewFace] {
        guard asset.mediaType == .image else { return [] }
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.version = .current
        var cg: CGImage?
        PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize,
                                              contentMode: .aspectFit, options: opts) { img, _ in
            if cg == nil { cg = img?.cgImage }
        }
        guard let image = cg else { return [] }

        let detect = VNDetectFaceRectanglesRequest()
        detect.revision = VNDetectFaceRectanglesRequestRevision2
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([detect])) != nil,
              let observations = detect.results, !observations.isEmpty
        else { return [] }

        return observations.enumerated().compactMap { idx, obs -> NewFace? in
            let embed = VNGenerateImageFeaturePrintRequest()
            embed.regionOfInterest = obs.boundingBox
            guard (try? handler.perform([embed])) != nil,
                  let fp = embed.results?.first as? VNFeaturePrintObservation,
                  let data = fp.data as Data?,
                  data.count >= MemoryLayout<Float>.size
            else { return nil }
            let v = data.withUnsafeBytes {
                Array(UnsafeBufferPointer<Float>(start: $0.baseAddress!.assumingMemoryBound(to: Float.self),
                                                 count: data.count / MemoryLayout<Float>.size))
            }
            var best: (String, Float)?
            for e in entries where e.vector.count == v.count {
                let s = FaceEngine.cosine(v, e.vector)
                if s > (best?.1 ?? -1) { best = (e.name, s) }
            }
            return NewFace(assetID: asset.localIdentifier,
                           faceIndex: idx,
                           vector: v,
                           bestName: (best?.1 ?? 0) >= threshold ? best?.0 : nil,
                           bestSimilarity: best?.1 ?? 0)
        }
    }

    // MARK: enroll a NEW face under a chosen name (from the scan results UI)
    @discardableResult
    static func enroll(face: NewFace, name: String) -> Bool {
        let ok = FaceDatabase.shared.insert(name: name, vector: face.vector)
        LiveFaceScanner.shared.reloadDatabase()
        return ok
    }
}