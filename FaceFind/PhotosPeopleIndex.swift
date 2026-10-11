import Foundation
import Photos

// MARK: - Direct lookup into Apple Photos' OWN face index ("People & Pets")
//
// Apple does NOT expose the People & Pets index through public PhotoKit. The
// private classes do exist on-device (verified against iOS runtime headers):
//   PHFace      — face record: faceprintData, eye/mouth coords, person id
//   PHPerson    — named person: name, faceCount, keyFace
// with real fetchers: PHFace.fetchFacesGroupedByAssetLocalIdentifierForAssets:,
// PHPerson.fetchPersonsWithOptions:  (all verified in iOS-Runtime-Headers)
//
// SAFETY RULES (the bare-perform version crashed on device):
//   1. private fetchers can throw NSExceptions — Swift cannot catch ObjC
//      exceptions, so every private call goes through ObjCExceptionCatcher
//      (BridgingHeader.h → ObjCExceptionCatcher.m @try/@catch → nil on throw)
//   2. numeric returns come back as NSNumber/Int64 — bridge with NSNumber
//      first, never assume Int
//   3. huge ID arrays crash the fetcher — chunk to 200 asset IDs per call
//   4. every call is responds(to:) guarded; nil → empty result (UI shows the
//      fallback state), never a crash.

enum PhotosPeopleIndex {

    private static func catchBlocks(_ block: @escaping () -> AnyObject?) -> AnyObject? {
        // ObjC: +catchExceptionOfBlock:error: → Swift sees it as
        // catchException(ofBlock:error:)? The import collided with NSObject.perform's
        // own 'perform' family, so call through the typed shim method we add here.
        let wrapper = CatcherWrapper.shared
        return wrapper.catchBlock(block)
    }

    @objc final class CatcherWrapper: NSObject {
        static let shared = CatcherWrapper()
        // ObjC: id(^)(void) block → Swift imports as () -> Any (escaping);
        // wrap our AnyObject?-returning closure to match, cast the result back
        func catchBlock(_ block: @escaping () -> AnyObject?) -> AnyObject? {
            let wrapped: () -> AnyObject? = { block() }
            let out = ObjCExceptionCatcher.safeRun { wrapped() as Any }
            return out as? AnyObject
        }
    }

    // MARK: all NAMED people from Apple's People & Pets (name non-empty)
    static func namedPeople() -> [(id: String, name: String, faceCount: Int)] {
        guard let cls = NSClassFromString("PHPerson") as? NSObject.Type else { return [] }
        let fetchSel = NSSelectorFromString("fetchPersonsWithOptions:")
        guard cls.responds(to: fetchSel) else { return [] }

        guard let fetchResult = catchBlocks({ cls.perform(fetchSel, with: nil)?.takeUnretainedValue() }) as? NSObject
        else { return [] }

        let countSel = NSSelectorFromString("count")
        let objSel = NSSelectorFromString("objectAtIndex:")
        guard fetchResult.responds(to: countSel),
              let nsTotal = fetchResult.perform(countSel).takeUnretainedValue() as? NSNumber,
              nsTotal.intValue > 0
        else { return [] }

        var out: [(String, String, Int)] = []
        for i in 0..<nsTotal.intValue {
            guard let person = fetchResult.perform(objSel, with: i).takeUnretainedValue() as? NSObject
            else { continue }
            let nameSel = NSSelectorFromString("name")
            let idSel = NSSelectorFromString("localIdentifier")
            let fcSel = NSSelectorFromString("faceCount")
            guard person.responds(to: nameSel), person.responds(to: idSel) else { continue }
            let rawName = person.perform(nameSel).takeUnretainedValue() as? String ?? ""
            let name = rawName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }                 // named visages only
            let id = person.perform(idSel).takeUnretainedValue() as? String ?? ""
            guard !id.isEmpty else { continue }
            var fc = 0
            if person.responds(to: fcSel) {
                let v = person.perform(fcSel).takeUnretainedValue()
                fc = (v as? NSNumber)?.intValue ?? (v as? Int) ?? 0
            }
            out.append((id, name, fc))
        }
        return out
    }

    // MARK: ALL faces PhotoKit indexed, grouped per asset (any person state)
    // NOTE: the fetcher chokes on huge arrays — chunk to 200 IDs per call.
    static func rawFaceCountByAsset(assetIDs: [String]) -> [String: Int] {
        guard !assetIDs.isEmpty,
              let faceCls = NSClassFromString("PHFace") as? NSObject.Type,
              faceCls.responds(to: NSSelectorFromString("fetchFacesGroupedByAssetLocalIdentifierForAssets:options:"))
        else { return [:] }

        var merged: [String: Int] = [:]
        for chunk in assetIDs.chunked(into: 200) {
            guard let dict = catchBlocks({
                faceCls.perform(NSSelectorFromString("fetchFacesGroupedByAssetLocalIdentifierForAssets:options:"),
                                with: chunk, with: nil)?.takeUnretainedValue()
            }) as? [String: [AnyObject]]
            else { continue }
            for (k, v) in dict { merged[k] = v.count }
        }
        return merged
    }

    // MARK: asset → set of NAMED people appearing in it
    static func namedFacesByAsset(assetIDs: [String]) -> [String: Set<String>] {
        guard !assetIDs.isEmpty,
              let faceCls = NSClassFromString("PHFace") as? NSObject.Type,
              faceCls.responds(to: NSSelectorFromString("fetchFacesGroupedByAssetLocalIdentifierForAssets:options:"))
        else { return [:] }
        var personNames: [String: String] = [:]
        for p in namedPeople() { personNames[p.id] = p.name }
        if personNames.isEmpty { return [:] }                 // nobody named → nothing to map

        var out: [String: Set<String>] = [:]
        for chunk in assetIDs.chunked(into: 200) {
            guard let dict = catchBlocks({
                faceCls.perform(NSSelectorFromString("fetchFacesGroupedByAssetLocalIdentifierForAssets:options:"),
                                with: chunk, with: nil)?.takeUnretainedValue()
            }) as? [String: [AnyObject]]
            else { continue }
            for (assetID, faces) in dict {
                for face in faces {
                    let pidSel = NSSelectorFromString("personLocalIdentifier")
                    guard face.responds(to: pidSel) else { continue }
                    guard let pid = face.perform(pidSel).takeUnretainedValue() as? String,
                          let name = personNames[pid]
                    else { continue }
                    out[assetID, default: []].insert(name)
                }
            }
        }
        return out
    }

    // MARK: assets whose faces Apple indexed but that match NO named person
    // (photos containing at least one UNNAMED visage = genuine "new" faces)
    static func assetsWithUnknownFaces(assets: [PHAsset]) -> [PHAsset] {
        let ids = assets.map(\.localIdentifier)
        let raw = rawFaceCountByAsset(assetIDs: ids)
        let named = namedFacesByAsset(assetIDs: ids)
        var unknown: [PHAsset] = []
        for asset in assets {
            let id = asset.localIdentifier
            let anyFaces = raw[id] ?? 0
            let namedCount = named[id]?.count ?? 0
            if anyFaces > namedCount { unknown.append(asset) }
        }
        return unknown
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}