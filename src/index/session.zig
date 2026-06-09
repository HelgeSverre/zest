const std = @import("std");
const types = @import("../core/types.zig");
const reader_mod = @import("reader.zig");
const search_mod = @import("search.zig");
const runtime = @import("../core/runtime.zig");
const config = @import("../config/config.zig");

/// Reference-counted index snapshot. Allows background search threads
/// to hold a reference while the main thread swaps in a new index.
pub const IndexSnapshot = struct {
    data: []const u8,
    reader: reader_mod.IndexReader,
    ref_count: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, data: []const u8) !*IndexSnapshot {
        const snap = try allocator.create(IndexSnapshot);
        // IndexReader.init can fail on a malformed index; without this the
        // snapshot struct leaks, once per failed load (every 5s poll).
        errdefer allocator.destroy(snap);
        snap.* = .{
            .data = data,
            .reader = try reader_mod.IndexReader.init(allocator, data),
            .ref_count = std.atomic.Value(u32).init(1),
            .allocator = allocator,
        };
        return snap;
    }

    pub fn retain(self: *IndexSnapshot) *IndexSnapshot {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *IndexSnapshot) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            var r = self.reader;
            r.deinit();
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }
};

/// Session-scoped index manager. Handles loading, snapshot lifecycle,
/// inode-based change detection, and search delegation.
pub const SessionIndex = struct {
    allocator: std.mem.Allocator,
    current_snapshot: ?*IndexSnapshot = null,
    inode: ?u64 = null,
    last_check: i128 = 0,

    pub fn init(allocator: std.mem.Allocator) SessionIndex {
        return .{
            .allocator = allocator,
            .current_snapshot = null,
            .inode = null,
            .last_check = 0,
        };
    }

    pub fn deinit(self: *SessionIndex) void {
        if (self.current_snapshot) |snap| snap.release();
        self.current_snapshot = null;
    }

    /// Load index data from a raw byte buffer. Takes ownership of `data`.
    pub fn load(self: *SessionIndex, data: []const u8) !void {
        const new_snap = try IndexSnapshot.create(self.allocator, data);
        if (self.current_snapshot) |old_snap| old_snap.release();
        self.current_snapshot = new_snap;
    }

    pub fn status(self: SessionIndex) types.IndexStatus {
        if (self.current_snapshot != null) return .ready;
        return .not_found;
    }

    /// Get the current index snapshot (retained — caller must release).
    pub fn snapshot(self: *SessionIndex) ?*IndexSnapshot {
        if (self.current_snapshot) |snap| return snap.retain();
        return null;
    }

    /// Search the current index. Returns an empty slice when no index is loaded.
    pub fn search(
        self: SessionIndex,
        allocator: std.mem.Allocator,
        opts: search_mod.SearchOptions,
    ) ![]search_mod.SearchResult {
        if (self.current_snapshot) |snap| {
            return search_mod.search(allocator, &snap.reader, opts);
        }
        return allocator.alloc(search_mod.SearchResult, 0);
    }

    /// Check if the index file has changed on disk and reload it if so.
    /// Only performs the stat check every 5 seconds to avoid excessive syscalls.
    /// Returns true only when a new index was actually loaded.
    pub fn checkForUpdate(self: *SessionIndex) bool {
        const check_interval_ns: i128 = 5 * std.time.ns_per_s;
        const now = runtime.nowNanos();
        if (now - self.last_check < check_interval_ns) return false;
        self.last_check = now;

        const idx_path = config.indexPath(self.allocator) catch return false;
        defer self.allocator.free(idx_path);

        const stat = std.Io.Dir.cwd().statFile(runtime.io, idx_path, .{}) catch return false;
        const current_inode = stat.inode;

        // If we already hold this exact index, there is nothing to do. When
        // `inode` is null we are seeing the file for the first time — which
        // includes the cold-start case where the index was built *after*
        // launch — so we fall through and load it. Returning false here would
        // wedge the reader on stale/empty results until the next restart.
        if (self.inode) |prev_inode| {
            if (current_inode == prev_inode) return false;
        }

        const data = runtime.readFileAlloc(self.allocator, idx_path, .unlimited) catch return false;
        self.load(data) catch {
            self.allocator.free(data);
            return false;
        };
        self.inode = current_inode;
        return true;
    }
};
