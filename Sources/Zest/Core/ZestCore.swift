import Foundation
import CZestCore

/// Safe Swift veneer over the Zig C ABI. Owns the index mmap for the Core's
/// lifetime; the rest of the app never touches raw C.
final class ZestCore {
    private let handle: OpaquePointer
    private let mapBase: UnsafeMutableRawPointer
    private let mapSize: Int

    struct Row {
        let name: String
        let dirPath: String
        let size: UInt64
        let mtime: Int64
        let kind: UInt8
        let category: UInt8
    }

    init?(indexPath: String) {
        let fd = open(indexPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
        let size = Int(st.st_size)

        guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              base != MAP_FAILED else { return nil }

        guard let h = zest_open(base.assumingMemoryBound(to: UInt8.self), size) else {
            munmap(base, size)
            return nil
        }
        self.handle = h
        self.mapBase = base
        self.mapSize = size
    }

    deinit {
        zest_close(handle)
        munmap(mapBase, mapSize)
    }

    /// Total number of indexed entries (files + directories) — for the status bar.
    var totalCount: Int { Int(zest_count(handle)) }

    /// Synchronous (runs in Zig); callers dispatch off-main in later phases.
    func query(_ q: String, scope: String = "/", maxDepth: UInt32 = .max, maxResults: UInt32 = 100_000) -> [Row] {
        guard let qp = zest_query(handle, q, scope, maxDepth, maxResults) else { return [] }
        defer { zest_query_free(qp) }
        let n = zest_query_count(qp)
        var rows: [Row] = []
        rows.reserveCapacity(n)
        for i in 0..<n {
            let r = zest_query_row(qp, i)
            rows.append(Row(
                name: Self.str(r.name),
                dirPath: Self.str(r.dir_path),
                size: r.size, mtime: r.mtime, kind: r.kind, category: r.category
            ))
        }
        return rows
    }

    private static func str(_ s: ZestStr) -> String {
        guard let p = s.ptr, s.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: s.len), as: UTF8.self)
    }
}
