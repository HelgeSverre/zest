//! Capability check, not a query of macOS's private TCC permission database.
const std = @import("std");
const runtime = @import("../core/runtime.zig");
pub const Status = enum { verified, denied, unavailable };
const Attempt = enum { readable, missing, denied, unavailable };

pub fn verify(ops: anytype) Status {
    // These are normally FDA-protected folders that the indexer itself scans.
    // Try another only if one is absent. Never interpret absence as a grant.
    for ([_][]const u8{ "Library/Safari", "Library/Mail", "Library/Messages" }) |relative| {
        switch (ops.attempt(relative)) {
            .readable => return .verified,
            .denied => return .denied,
            .unavailable => return .unavailable,
            .missing => {},
        }
    }
    return .unavailable;
}

fn classify(err: anyerror) Attempt {
    return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        error.AccessDenied, error.PermissionDenied => .denied,
        else => .unavailable,
    };
}

pub fn probe(allocator: std.mem.Allocator) !Status {
    const home = try runtime.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const Ops = struct {
        allocator: std.mem.Allocator,
        home: []const u8,
        fn attempt(self: @This(), relative: []const u8) Attempt {
            const path = std.fs.path.join(self.allocator, &.{ self.home, relative }) catch return .unavailable;
            defer self.allocator.free(path);
            var dir = std.Io.Dir.openDirAbsolute(runtime.io, path, .{ .iterate = true }) catch |err| return classify(err);
            defer dir.close(runtime.io);
            // Exercise the same directory-read permission as scanning, without
            // recursion, file-content reads, or returning any filenames.
            var iterator = dir.iterate();
            _ = iterator.next(runtime.io) catch |err| return classify(err);
            return .readable;
        }
    };
    return verify(Ops{ .allocator = allocator, .home = home });
}

test "verification distinguishes readable denied missing and unknown" {
    const Fake = struct {
        outcomes: []const Attempt,
        calls: usize = 0,
        fn attempt(self: *@This(), _: []const u8) Attempt {
            const result = self.outcomes[self.calls];
            self.calls += 1;
            return result;
        }
    };
    var missing = Fake{ .outcomes = &.{ .missing, .missing, .missing } };
    try std.testing.expectEqual(Status.unavailable, verify(&missing));
    var success = Fake{ .outcomes = &.{ .missing, .readable } };
    try std.testing.expectEqual(Status.verified, verify(&success));
    var denied = Fake{ .outcomes = &.{.denied} };
    try std.testing.expectEqual(Status.denied, verify(&denied));
    try std.testing.expectEqual(@as(usize, 1), denied.calls);
    var unknown = Fake{ .outcomes = &.{.unavailable} };
    try std.testing.expectEqual(Status.unavailable, verify(&unknown));
}
