import Foundation
import Photos

// MARK: - Direct lookup into Apple Photos' OWN face index ("People & Pets")
//
// Apple does NOT expose the People & Pets index through public PhotoKit. The
// private classes do exist on-device (verified against iOS runtime headers):
//   PHFace      — face record: faceprintData (Apple's own embedding!), pose,
//                 eye/mouth coordinates, personLocalIdentifier
//   PHPerson    — named person: name, displayName, faceCount, keyFace
//   PHFaceGroup — face cluster per person
// with real fetchers (all verified in iOS-Runtime-Headers):
//   PHFace.fetchFacesWithOptions: / fetchFacesInAsset: /
//     fetchFacesGroupedByAssetLocalIdentifierForAssets:
//   PHPerson.fetchPersonsWithOptions:  name / faceCount / localIdentifier
//
// Personal sideloaded builds (ours) can call these private classes at runtime
// via NSClassFromString — no jailbreak needed. This reads Apple's EXISTING
// index: named visages come free; photos with an unnamed face cluster are the
// "new visage" candidates. No ML re-scan of the library.

enum PhotosPeopleIndex {

    // MARK: all NAMED people from Apple's People & Pets (name non-empty)
    static func namedPeople() -> [(id: String, name: String, faceCount: Int)] {
        guard let cls = NSClassFromString("PHPerson") as? NSObject.Type else { return [] }
        let fetchSel = NSSelectorFromString("fetchPersonsWithOptions:")
        guard cls.responds(to: fetchSel) else { return [] }
        let raw = cls.perform(fetchSel, with: nil).takeUnretainedValue()
        guard let fetchResult = raw as? NSObject else { return [] }

        let countSel = NSSelectorFromString("count")
        let objSel = NSSelectorFromString("objectAtIndex:")
        guard fetchResult.responds(to: countSel),
              let total = fetchResult.perform(countSel).takeUnretainedValue() as? Int,
              total > 0
        else { return [] }

        var out: [(String, String, Int)] = []
        for i in 0..<total {
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
            let fc = person.responds(to: fcSel)
                ? (person.perform(fcSel).takeUnretainedValue() as? Int ?? 0)
                : 0
            out.append((id, name, fc))
        }
        return out
    }

    // MARK: ALL faces PhotoKit indexed, grouped per asset (any person state)
    static func rawFaceCountByAsset(assetIDs: [String]) -> [String: Int] {
        guard !assetIDs.isEmpty,
              let faceCls = NSClassFromString("PHFace") as? NSObject.Type,
              faceCls.responds(to: NSSelectorFromString("fetchFacesGroupedByAssetLocalIdentifierForAssets:options:"))
        else { return [:] }
        let raw = faceCls.perform(NSSelectorFromString("fetchFacesGroupedByAssetLocalIdentifierForAssets:options:"),
                                  with: assetIDs, with: nil).takeUnretainedValue()
        guard let dict = raw as? [String: [AnyObject]] else { return [:] }
        return dict.mapValues(\.count)
    }

    // MARK: asset → set of NAMED people appearing in it
    static func namedFacesByAsset(assetIDs: [String]) -> [String: Set<String>] {
        guard !assetIDs.isEmpty,
              let faceCls = NSClassFromString("PHFace") as? NSObject.Type,
              faceCls.responds(to: NSSelectorFromString("fetchFacesGroupedByAssetLocalIdentifierForAssets:options:"))
        else { return [:] }
        var personNames: [String: String] = [:]
        for p in namedPeople() { personNames[p.id] = p.name }

        let raw = faceCls.perform(NSSelectorFromString("fetchFacesGroupedByAssetLocalIdentifierForAssets:options:"),
                                  with: assetIDs, with: nil).takeUnretainedValue()
        guard let dict = raw as? [String: [AnyObject]] else { return [:] }

        var out: [String: Set<String>] = [:]
        for (assetID, faces) in dict {
            for face in faces {
                let pidSel = NSSelectorFromString("personLocalIdentifier")
                guard face.responds(to: pidSel),
                      let pid = face.perform(pidSel).takeUnretainedValue() as? String,
                      let name = personNames[pid]
                else { continue }
                out[assetID, default: []].insert(name)
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

    // MARK: PHFace crop rect → CGPoint center in Apple coords (for UI hints)
    static func faceCenter(_ face: NSObject) -> CGPoint? {
        let cxSel = NSSelectorFromString("centerX"), cySel = NSSelectorFromString("centerY")
        guard face.responds(to: cxSel), face.responds(to: cySel) else { return nil }
        let x = (face.perform(cxSel).takeUnretainedValue() as? Double) ?? 0
        let y = (face.perform(cySel).takeUnretainedValue() as? Double) ?? 0
        return CGPoint(x: x, y: y)
    }
}
