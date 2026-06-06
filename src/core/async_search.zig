const std = @import("std");
const types = @import("types.zig");
const filters_mod = @import("filters.zig");
const search_mod = @import("../index/search.zig");
const reader_mod = @import("../index/reader.zig");
const objc = @import("../ui/objc.zig");

// Forward-declare IndexSnapshot from app.zig
const app_mod = @import("../app.zig");
const IndexSnapshot = app_mod.IndexSnapshot;

/// Async search coordinator. Manages background search threads with
/// generation-based cancellation and GCD-based result delivery.
pub const AsyncSearch = struct {
    generation: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AsyncSearch {
        return .{
            .generation = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    /// Submit a new search to run on a background thread.
    /// Cancels any in-flight search by bumping the generation counter.
    /// Returns the results synchronously as fallback if thread spawn fails.
    pub fn submitSearch(
        self: *AsyncSearch,
        snapshot: *IndexSnapshot,
        query: []const u8,
        category: ?types.FileCategory,
        filter_criteria: []const filters_mod.FilterCriterion,
        scope: []const u8,
        max_depth: u32,
        max_results: u32,
    ) void {
        // Bump generation to cancel any in-flight search
        _ = self.generation.fetchAdd(1, .release);
        const my_gen = self.generation.load(.acquire);

        // Heap-allocate job context for the background thread
        const job = self.allocator.create(SearchJob) catch {
            // Fallback: run synchronously on main thread
            self.runSynchronousFallback(snapshot, query, category, filter_criteria, scope, max_depth, max_results);
            return;
        };

        // Dupe query so background thread owns it
        const query_dupe = self.allocator.dupe(u8, query) catch {
            self.allocator.destroy(job);
            self.runSynchronousFallback(snapshot, query, category, filter_criteria, scope, max_depth, max_results);
            return;
        };

        // Dupe filter criteria
        const filters_dupe = self.allocator.dupe(filters_mod.FilterCriterion, filter_criteria) catch {
            self.allocator.free(query_dupe);
            self.allocator.destroy(job);
            self.runSynchronousFallback(snapshot, query, category, filter_criteria, scope, max_depth, max_results);
            return;
        };

        // Dupe scope so background thread owns it (Navigator.current can be freed
        // out from under us when the user navigates while a search is in flight).
        const scope_dupe = self.allocator.dupe(u8, scope) catch {
            self.allocator.free(filters_dupe);
            self.allocator.free(query_dupe);
            self.allocator.destroy(job);
            self.runSynchronousFallback(snapshot, query, category, filter_criteria, scope, max_depth, max_results);
            return;
        };

        job.* = .{
            .async_search = self,
            .snapshot = snapshot.retain(),
            .query = query_dupe,
            .category = category,
            .filters = filters_dupe,
            .scope = scope_dupe,
            .max_depth = max_depth,
            .max_results = max_results,
            .generation = my_gen,
            .allocator = self.allocator,
        };

        // Spawn background thread (detached — will clean up after itself)
        const thread = std.Thread.spawn(.{}, searchWorker, .{job}) catch {
            // Failed to spawn thread — clean up and fall back to sync
            snapshot.release();
            self.allocator.free(scope_dupe);
            self.allocator.free(query_dupe);
            self.allocator.free(filters_dupe);
            self.allocator.destroy(job);
            self.runSynchronousFallback(snapshot, query, category, filter_criteria, scope, max_depth, max_results);
            return;
        };
        thread.detach();
    }

    /// Cancel any in-flight search by bumping the generation counter.
    pub fn cancel(self: *AsyncSearch) void {
        _ = self.generation.fetchAdd(1, .release);
    }

    fn runSynchronousFallback(
        self: *AsyncSearch,
        snapshot: *IndexSnapshot,
        query: []const u8,
        category: ?types.FileCategory,
        filter_criteria: []const filters_mod.FilterCriterion,
        scope: []const u8,
        max_depth: u32,
        max_results: u32,
    ) void {
        _ = self;
        const delegate = @import("../ui/delegate.zig");
        const s = delegate.state orelse return;

        const results = search_mod.search(s.allocator, &snapshot.reader, .{
            .query = query,
            .category = category,
            .filters = filter_criteria,
            .scope = scope,
            .max_depth = max_depth,
            .max_results = max_results,
        }) catch null;

        // Hand installRows its own snapshot ref; submitSearch's caller still owns
        // (and releases) the ref it passed in.
        installRows(s, results, snapshot.retain());
    }
};

const SearchJob = struct {
    async_search: *AsyncSearch,
    snapshot: *IndexSnapshot,
    query: []const u8,
    category: ?types.FileCategory,
    filters: []const filters_mod.FilterCriterion,
    scope: []const u8,
    max_depth: u32,
    max_results: u32,
    generation: u64,
    allocator: std.mem.Allocator,
};

const ResultDelivery = struct {
    results: ?[]search_mod.SearchResult,
    generation: u64,
    async_search: *AsyncSearch,
    allocator: std.mem.Allocator,
    // Retained ref to the snapshot `results` borrow into; transferred to
    // installRows on the current path, released on the stale/shutdown paths.
    snapshot: *IndexSnapshot,
};

fn searchWorker(job: *SearchJob) void {
    defer {
        job.snapshot.release();
        job.allocator.free(job.query);
        job.allocator.free(job.filters);
        job.allocator.free(job.scope);
        job.allocator.destroy(job);
    }

    const results = search_mod.searchCancellable(
        job.allocator,
        &job.snapshot.reader,
        .{
            .query = job.query,
            .category = job.category,
            .filters = job.filters,
            .scope = job.scope,
            .max_depth = job.max_depth,
            .max_results = job.max_results,
        },
        &job.async_search.generation,
        job.generation,
    ) catch |err| {
        if (err == error.SearchCancelled) return; // Superseded by newer search
        return; // Other errors — silently drop
    };

    // Deliver results to main thread via GCD
    const delivery = job.allocator.create(ResultDelivery) catch {
        job.allocator.free(results);
        return;
    };
    delivery.* = .{
        .results = results,
        .generation = job.generation,
        .async_search = job.async_search,
        .allocator = job.allocator,
        .snapshot = job.snapshot.retain(),
    };

    objc.dispatch_async_f(
        objc.dispatch_get_main_queue(),
        @ptrCast(delivery),
        deliverResults,
    );
}

fn deliverResults(ctx: ?*anyopaque) callconv(.c) void {
    const delivery: *ResultDelivery = @ptrCast(@alignCast(ctx));
    defer delivery.allocator.destroy(delivery);

    const delegate = @import("../ui/delegate.zig");
    const s = delegate.state orelse {
        // App shutting down — free results and the snapshot ref we carried.
        if (delivery.results) |r| delivery.allocator.free(r);
        delivery.snapshot.release();
        return;
    };

    // Check if this delivery is still current
    const current_gen = delivery.async_search.generation.load(.acquire);
    if (delivery.generation != current_gen) {
        // Stale results — a newer search has been submitted.
        if (delivery.results) |r| delivery.allocator.free(r);
        delivery.snapshot.release();
        return;
    }

    // Transfers the carried snapshot ref into AppState (held with `rows`).
    installRows(s, delivery.results, delivery.snapshot);
}

/// Replace the file list's rows with `results` (taking ownership), apply the
/// active sort order, and reload the table. Runs on the main thread.
///
/// `snapshot` is the index snapshot the result strings borrow into; ownership of
/// one retained ref transfers here and is held for exactly as long as `rows`,
/// so a concurrent index reload can never free the buffer under the table.
fn installRows(s: *@import("../ui/delegate.zig").AppState, results: ?[]search_mod.SearchResult, snapshot: ?*IndexSnapshot) void {
    if (s.rows) |old| s.allocator.free(old);
    if (s.rows_snapshot) |old| old.release();
    s.rows = results;
    s.rows_snapshot = snapshot;
    if (results) |rows| {
        if (s.sort) |srt| search_mod.sortResults(rows, srt.column, srt.ascending, s.folders_on_top);
    }
    @import("../ui/delegate.zig").updateEmptyState(s);
    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}
