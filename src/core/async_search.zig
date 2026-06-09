const std = @import("std");
const types = @import("types.zig");
const filters_mod = @import("filters.zig");
const search_mod = @import("../index/search.zig");
const session_mod = @import("../index/session.zig");
const IndexSnapshot = session_mod.IndexSnapshot;
const dispatch = @import("dispatch.zig");

/// Callback the UI layer provides so AsyncSearch can deliver results
/// without importing the UI module.
pub const SearchDelivery = struct {
    /// Called on the main thread with results (or null on cancel/error).
    /// Takes ownership of `results` and one retained ref to `snapshot`.
    deliver: *const fn (ctx: *anyopaque, results: ?[]search_mod.SearchResult, snapshot: ?*IndexSnapshot) void,
    ctx: *anyopaque,
};

/// Async search coordinator. Manages background search threads with
/// generation-based cancellation and GCD-based result delivery.
pub const AsyncSearch = struct {
    generation: std.atomic.Value(u64),
    allocator: std.mem.Allocator,
    delivery: SearchDelivery,

    pub fn init(allocator: std.mem.Allocator, delivery: SearchDelivery) AsyncSearch {
        return .{
            .generation = std.atomic.Value(u64).init(0),
            .allocator = allocator,
            .delivery = delivery,
        };
    }

    /// Submit a new search to run on a background thread.
    /// Cancels any in-flight search by bumping the generation counter.
    /// Runs synchronously as fallback if thread spawn fails.
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
        // Single atomic: claim this submission's generation from the increment
        // itself. The old fetchAdd-then-load let two concurrent submitters read
        // the same post-increment value and collide on a generation.
        const my_gen = self.generation.fetchAdd(1, .acq_rel) + 1;

        const job = self.allocator.create(SearchJob) catch {
            self.runSynchronousFallback(snapshot, query, category, filter_criteria, scope, max_depth, max_results);
            return;
        };

        const query_dupe = self.allocator.dupe(u8, query) catch {
            self.allocator.destroy(job);
            self.runSynchronousFallback(snapshot, query, category, filter_criteria, scope, max_depth, max_results);
            return;
        };

        const filters_dupe = self.allocator.dupe(filters_mod.FilterCriterion, filter_criteria) catch {
            self.allocator.free(query_dupe);
            self.allocator.destroy(job);
            self.runSynchronousFallback(snapshot, query, category, filter_criteria, scope, max_depth, max_results);
            return;
        };

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

        const thread = std.Thread.spawn(.{}, searchWorker, .{job}) catch {
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
        const results = search_mod.search(self.allocator, &snapshot.reader, .{
            .query = query,
            .category = category,
            .filters = filter_criteria,
            .scope = scope,
            .max_depth = max_depth,
            .max_results = max_results,
        }) catch null;

        self.delivery.deliver(self.delivery.ctx, results, snapshot.retain());
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
        if (err == error.SearchCancelled) return;
        return;
    };

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

    dispatch.dispatch_async_f(
        dispatch.dispatch_get_main_queue(),
        @ptrCast(delivery),
        deliverResults,
    );
}

// Lifetime contract: this runs on the main queue and dereferences
// `delivery.async_search`, which is a field embedded in the UI's AppState. A
// block may still be queued when teardown happens, so AppState (and therefore
// this AsyncSearch) MUST outlive any in-flight delivery. Today that holds
// because the app is single-window and torn down only at process exit. If
// per-window teardown is ever added, drain outstanding deliveries (e.g. an
// atomic in-flight counter waited on in deinit) before freeing AppState.
fn deliverResults(ctx: ?*anyopaque) callconv(.c) void {
    const delivery: *ResultDelivery = @ptrCast(@alignCast(ctx));
    defer delivery.allocator.destroy(delivery);

    const current_gen = delivery.async_search.generation.load(.acquire);
    if (delivery.generation != current_gen) {
        if (delivery.results) |r| delivery.allocator.free(r);
        delivery.snapshot.release();
        return;
    }

    delivery.async_search.delivery.deliver(delivery.async_search.delivery.ctx, delivery.results, delivery.snapshot);
}
