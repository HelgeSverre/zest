import CZestCore
import Foundation

/// Safe Swift veneer over the Zig C ABI. Owns the index mmap for the Core's
/// lifetime; the rest of the app never touches raw C.
final class ZestCore {
  private let handle: OpaquePointer
  private let mapBase: UnsafeMutableRawPointer
  private let mapSize: Int

  let fileIdentity: FileIdentity

  struct FileIdentity: Equatable {
    let inode: UInt64
    let size: Int64
    let mtime: Int64
  }

  /// Identity of the index file on disk right now, or nil if it's missing/empty.
  /// Compared against `fileIdentity` to detect daemon rebuilds (rename = new inode).
  static func currentIdentity(of path: String) -> FileIdentity? {
    var st = stat()
    guard stat(path, &st) == 0, st.st_size > 0 else { return nil }
    return FileIdentity(
      inode: UInt64(st.st_ino), size: Int64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec))
  }

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
    guard fd >= 0 else {
      return nil
    }
    defer {
      close(fd)
    }

    var st = stat()
    guard fstat(fd, &st) == 0, st.st_size > 0 else {
      return nil
    }
    let size = Int(st.st_size)

    guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
      base != MAP_FAILED
    else {
      return nil
    }

    guard let h = zest_open(base.assumingMemoryBound(to: UInt8.self), size) else {
      munmap(base, size)
      return nil
    }
    self.handle = h
    self.mapBase = base
    self.mapSize = size
    self.fileIdentity = FileIdentity(
      inode: UInt64(st.st_ino), size: Int64(st.st_size),
      mtime: Int64(st.st_mtimespec.tv_sec))
  }

  deinit {
    zest_close(handle)
    munmap(mapBase, mapSize)
  }

  /// Total number of indexed entries (files + directories) — for the status bar.
  var totalCount: Int {
    Int(zest_count(handle))
  }

  /// Synchronous (runs in Zig); callers dispatch off-main in later phases.
  func query(
    _ q: String, scope: String = "/", maxDepth: UInt32 = .max, maxResults: UInt32 = 100_000
  ) -> [Row] {
    guard let qp = zest_query(handle, q, scope, maxDepth, maxResults) else {
      return []
    }
    defer {
      zest_query_free(qp)
    }
    let n = zest_query_count(qp)
    var rows: [Row] = []
    rows.reserveCapacity(n)
    for i in 0..<n {
      let r = zest_query_row(qp, i)
      rows.append(
        Row(
          name: Self.str(r.name),
          dirPath: Self.str(r.dir_path),
          size: r.size, mtime: r.mtime, kind: r.kind, category: r.category
        ))
    }
    return rows
  }

  /// 9-element per-category counts for the given scope. Indexed 0-8 by
  /// `core.FileCategory` (matches `Category.all` on the Swift side).
  /// O(1) at `maxDepth == 1` (per-folder block read); O(D) for deeper scopes
  /// (subtree sum). Returns zeros if the scope is not in the index.
  func histogram(scope: String, maxDepth: UInt32) -> [Int] {
    let h = zest_histogram(handle, scope, maxDepth)
    return [
      Int(h.counts.0), Int(h.counts.1), Int(h.counts.2), Int(h.counts.3), Int(h.counts.4),
      Int(h.counts.5), Int(h.counts.6), Int(h.counts.7), Int(h.counts.8),
    ]
  }

  /// Top-N extensions for the (scope, category) pair. Returns `(name, count)`
  /// rows sorted by count descending, truncated to `max`. Empty if the scope
  /// is not in the index or the category has no entries. `cat` is a
  /// `FileCategory` enum value (0-8, matches `Category.all`).
  /// O(1) at `maxDepth == 1`; O(D) for deeper scopes (subtree merge).
  func extBreakdown(scope: String, maxDepth: UInt32, cat: UInt8, max: Int) -> [(
    name: String, count: Int
  )] {
    let cap = UInt32(min(max, 32))
    if cap == 0 { return [] }
    var out = [ZestExtCount](
      repeating: ZestExtCount(name: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), count: 0),
      count: Int(cap))
    let n = Int(zest_ext_breakdown(handle, scope, maxDepth, cat, cap, &out))
    var rows: [(name: String, count: Int)] = []
    rows.reserveCapacity(n)
    for i in 0..<n {
      let c = out[i]
      let name = withUnsafePointer(to: c.name) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 16) { p in
          String(cString: p)
        }
      }
      rows.append((name, Int(c.count)))
    }
    return rows
  }

  private static func str(_ s: ZestStr) -> String {
    guard let p = s.ptr, s.len > 0 else {
      return ""
    }
    return String(decoding: UnsafeBufferPointer(start: p, count: s.len), as: UTF8.self)
  }
}
