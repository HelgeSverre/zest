//! Process-wide runtime handles for the Zig 0.16 `Io` interface.
//!
//! Zig 0.16 routes all filesystem and environment access through an `Io`
//! instance handed to `main` via `std.process.Init`. Rather than thread that
//! handle through every call site, we stash it here once at startup — the same
//! global-state pattern the UI layer already uses for `delegate.state`.
//!
//! Test builds default `io` to the test runner's instance so code under test
//! (clock/filesystem access) works without a `main`-style `init` call.
//! `environ_map` stays null in tests: no `$HOME` resolution happens under test
//! since all filesystem access there goes through `FakeFs`.

const std = @import("std");
const builtin = @import("builtin");

pub var io: std.Io = if (builtin.is_test) std.testing.io else undefined;
var environ_map: ?*std.process.Environ.Map = null;

/// Wire up the global handles from the process init struct. Call once at the
/// top of `main` before any filesystem or environment access.
pub fn init(process_init: std.process.Init) void {
    io = process_init.io;
    environ_map = process_init.environ_map;
}

/// Monotonic clock in nanoseconds. Replaces the removed
/// `std.time.nanoTimestamp` for elapsed-time measurements.
pub fn nowNanos() i128 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

/// Wall-clock time in whole seconds since the Unix epoch. Replaces the removed
/// `std.time.timestamp`.
pub fn unixTimestamp() i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

/// Replacement for the removed `std.process.getEnvVarOwned`. Returns an owned
/// copy of the environment variable, or `error.EnvironmentVariableNotFound`.
pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const map = environ_map orelse return error.EnvironmentVariableNotFound;
    const value = map.get(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}

/// Read an entire file at an absolute path into a caller-owned buffer.
/// `limit` caps the read (e.g. `.unlimited` or `.limited(1024 * 1024)`).
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: std.Io.Limit) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

/// Write `data` to an absolute path, creating or truncating the file.
pub fn writeFileAbsolute(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Create a directory at an absolute path, treating "already exists" as success.
pub fn ensureDir(path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}
