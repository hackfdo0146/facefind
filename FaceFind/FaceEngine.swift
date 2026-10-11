import Foundation
import Vision
import CoreVideo
import Accelerate

// MARK: - Face engine: detection + embedding + matching (all Vision work here)
//
// Apple never made VNGenerateFaceprintRequest (128-d) public on iOS — verified
// against the iOS 27 SDK (no header / tbd symbol / Swift-interface entry).
// This engine uses the public substitute verified in the same SDK:
//   detection:  VNDetectFaceRectanglesRequest     (legacy ObjC API — stable)
//   embedding:  VNGenerateImageFeaturePrintRequest
//               with regionOfInterest = the face box (crop per face); result
//               VNFeaturePrintObservation rides with a Float32 vector in .data
//   matching:   cosine similarity (vDSP) against SQLite-stored Float32 vectors
//
// The legacy ObjC path does detection + per-face-crop embed in a single handler
// pass shape. Everything runs on the caller's background queue; nothing here
// touches the main thread.

enum FaceEngine {

    struct DetectedFace {
        let box: CGRect              // normalized, Vision coordinates (bottom-left origin)
        let vector: [Float]          // embedding of the face crop
    }

    private static func floats(_ fp: VNFeaturePrintObservation) -> [Float] {
        guard let data = fp.data as Data?,
              data.count >= MemoryLayout<Float>.size
        else { return [] }
        return data.withUnsafeBytes {
            Array(UnsafeBufferPointer<Float>(start: $0.baseAddress!.assumingMemoryBound(to: Float.self),
                                             count: data.count / MemoryLayout<Float>.size))
        }
    }

    private static func embed(cropBox: CGRect,
                              pixelBuffer: CVPixelBuffer?,
                              cgImage: CGImage?,
                              orientation: CGImagePropertyOrientation) -> [Float] {
        let embed = VNGenerateImageFeaturePrintRequest()
        embed.regionOfInterest = cropBox
        let handler: VNImageRequestHandler
        if let pixelBuffer {
            handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        } else if let cgImage {
            handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        } else { return [] }
        guard (try? handler.perform([embed])) != nil,
              let fp = embed.results?.first as? VNFeaturePrintObservation
        else { return [] }
        return floats(fp)
    }

    // MARK: detect + embed every face in a live frame
    static func analyze(pixelBuffer: CVPixelBuffer,
                        orientation: CGImagePropertyOrientation) -> [DetectedFace] {
        let detect = VNDetectFaceRectanglesRequest()
        detect.revision = VNDetectFaceRectanglesRequestRevision2   // most stable public revision
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        guard (try? handler.perform([detect])) != nil,
              let faces = detect.results, !faces.isEmpty
        else { return [] }

        var out: [DetectedFace] = []
        for obs in faces {
            let vector = embed(cropBox: obs.boundingBox, pixelBuffer: pixelBuffer, cgImage: nil, orientation: orientation)
            guard !vector.isEmpty else { continue }
            out.append(DetectedFace(box: obs.boundingBox, vector: vector))
        }
        return out
    }

    // MARK: enrollment (photo/library path) — synchronous on caller's queue
    static func enroll(image: CGImage,
                       name: String,
                       db: FaceDatabase) -> String? {   // nil = ok, else error text
        let detect = VNDetectFaceRectanglesRequest()
        detect.revision = VNDetectFaceRectanglesRequestRevision2
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([detect])) != nil,
              let obs = detect.results?.first
        else { return "no face detected in that photo" }

        let vector = embed(cropBox: obs.boundingBox, pixelBuffer: nil, cgImage: image, orientation: .up)
        guard !vector.isEmpty else { return "could not compute faceprint" }
        guard db.insert(name: name, vector: vector) else { return "database write failed" }
        return nil
    }

    // MARK: cosine similarity of two vectors (vDSP — cheap even at scale)
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty, a.count > 1 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &na, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &nb, vDSP_Length(b.count))
        let denom = (na.squareRoot() * nb.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    struct Match {
        let name: String
        let similarity: Float
    }

    // MARK: best match of one vector across the whole database
    static func bestMatch(for vector: [Float], entries: [FaceDatabase.Entry]) -> Match? {
        var best: Match?
        for e in entries where e.vector.count == vector.count {
            let s = cosine(vector, e.vector)
            if s > (best?.similarity ?? -1) {
                best = Match(name: e.name, similarity: s)
            }
        }
        return best
    }
}