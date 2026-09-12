//! Shared command-line conventions for the Zig binaries (`zest-indexer`,
//! `zest-query`). Version data comes from `build_info`, which build.zig
//! generates from release.json. Only import this from binary roots (and the
//! test root); the C-ABI lib has no build_info.
//!
//! Usage text is a plain string literal per binary, in this shape:
//!
//!   Usage: NAME [COMMAND] [OPTIONS]
//!
//!   One-paragraph description.
//!
//!   Commands:      (omit if none)
//!     name         What it does
//!
//!   Options:
//!     -h, --help     Show this help
//!     -V, --version  Print version
//!
//!   Diagnostics:   (omit if none; dev/support-only commands)
//!
//!   Examples:
//!     NAME ...
const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const runtime = @import("runtime.zig");

pub inline fn versionString(comptime name: []const u8) []const u8 {
    return comptime name ++ " " ++ build_info.version ++ " (build " ++ build_info.build ++ ")";
}

/// Handles `-h/--help` and `-V/--version` anywhere in `args`. Returns true if
/// one was printed to stdout; the caller should then return from main.
pub fn handleCommon(args: []const []const u8, comptime name: []const u8, usage: []const u8) bool {
    for (args[1..]) |arg| {
        // Everything after `--` is data, not flags: a zest-query search term can
        // legitimately be the literal text "-h".
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printStdout(usage);
            return true;
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            printStdout(comptime versionString(name) ++ "\n");
            return true;
        }
    }
    return false;
}

/// Prints `NAME: error: MESSAGE` plus a pointer at --help, then exits 2.
pub fn fail(comptime name: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(name ++ ": error: " ++ fmt ++ "\nTry '" ++ name ++ " --help' for usage.\n", args);
    std.process.exit(2);
}

/// Normal command output to stdout. Silent under `zig build test`, where stdout
/// is the test-server protocol pipe and a stray write makes the build runner
/// report a passing run as a failed command.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(runtime.io, &buffer);
    writer.interface.print(fmt, args) catch {};
    writer.interface.flush() catch {};
}

fn printStdout(text: []const u8) void {
    info("{s}", .{text});
}

test "version string and common flag detection" {
    try std.testing.expectStringStartsWith(versionString("zest-x"), "zest-x ");
    try std.testing.expect(std.mem.indexOf(u8, versionString("zest-x"), "(build ") != null);
    try std.testing.expect(!handleCommon(&.{ "zest-x", "foo", "--bar" }, "zest-x", ""));
    try std.testing.expect(handleCommon(&.{ "zest-x", "foo", "-V" }, "zest-x", ""));
    try std.testing.expect(handleCommon(&.{ "zest-x", "--help" }, "zest-x", ""));
    // `--` ends flag parsing, so a search for the literal "-h" is not help.
    try std.testing.expect(!handleCommon(&.{ "zest-x", "--", "-h" }, "zest-x", ""));
    try std.testing.expect(handleCommon(&.{ "zest-x", "-h", "--", "-V" }, "zest-x", ""));
}
