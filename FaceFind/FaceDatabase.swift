import Foundation
import SQLite3

// MARK: - SQLite storage for enrolled faces
//
// Schema:
//   CREATE TABLE IF NOT EXISTS faces (
//     id INTEGER PRIMARY KEY AUTOINCREMENT,
//     name TEXT NOT NULL,
//     embedding BLOB NOT NULL,     -- Float32 array, C floats
//     created_at REAL NOT NULL     -- unix epoch seconds
//   );
// One row per (person enrollment). A faceprint vector floats between rows; the
// match step scans ALL rows and keeps the best cosine similarity.

final class FaceDatabase {
    static let shared = FaceDatabase()

    private var db: OpaquePointer?

    private init() {
        db = Self.open()
        Self.createSchema(db)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: open / migrate
    private static func open() -> OpaquePointer? {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let path = docs + "/facefind.sqlite"
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    private static func createSchema(_ db: OpaquePointer?) {
        guard let db else { return }
        exec(db, "CREATE TABLE IF NOT EXISTS faces ("
                   + "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                   + "name TEXT NOT NULL, "
                   + "embedding BLOB NOT NULL, "
                   + "created_at REAL NOT NULL);")
        exec(db, "CREATE INDEX IF NOT EXISTS idx_faces_name ON faces(name);")
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: insert an enrollment (name + Float32 vector blob)
    func insert(name: String, vector: [Float]) -> Bool {
        guard let db, !vector.isEmpty else { return false }
        let sql = "INSERT INTO faces (name, embedding, created_at) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(blob.count), SQLITE_TRANSIENT) }
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: list distinct people
    func people() -> [(name: String, count: Int)] {
        guard let db else { return [] }
        let sql = "SELECT name, COUNT(*) FROM faces GROUP BY name ORDER BY name COLLATE NOCASE;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            out.append((name, count))
        }
        return out
    }

    // MARK: all enrolled vectors (the match space; hundreds of rows stay cheap)
    struct Entry {
        let id: Int32
        let name: String
        let vector: [Float]
    }

    func allEntries() -> [Entry] {
        guard let db else { return [] }
        let sql = "SELECT id, name, embedding FROM faces ORDER BY id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int(stmt, 0)
            let name = String(cString: sqlite3_column_text(stmt, 1))
            guard let bytes = sqlite3_column_blob(stmt, 2) else { continue }
            let byteCount = Int(sqlite3_column_bytes(stmt, 2))
            let count = byteCount / MemoryLayout<Float>.size
            let floats = Array(UnsafeBufferPointer<Float>(start: bytes.assumingMemoryBound(to: Float.self),
                                                          count: count))
            out.append(Entry(id: id, name: name, vector: floats))
        }
        return out
    }

    // MARK: delete one person (all their enrollments)
    func delete(name: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM faces WHERE name = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: wipe everything (Settings: "delete all faceprints")
    func wipeAll() {
        guard let db else { return }
        Self.exec(db, "DELETE FROM faces;")
    }

    var count: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM faces;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }
}