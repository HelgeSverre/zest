//! launchd control shared by the CLI and the native app's Index menu.
const std = @import("std");
const cli = @import("../core/cli.zig");
const runtime = @import("../core/runtime.zig");
const config = @import("../config/config.zig");
extern "c" fn getuid() c_uint;

pub const label = "dev.zest.indexer";
pub const request_filename = "reindex.request";
pub const State = enum { not_installed, stopped, running, waiting };

/// bootout can return while launchd is still terminating the job. Treat that
/// transition as pending, not as failure, before attempting a fresh bootstrap.
fn waitForStopped(ops: anytype) !void {
    for (0..120) |_| {
        switch (try ops.state()) {
            .stopped, .not_installed => return,
            .running, .waiting => try ops.pause(),
        }
    }
    return error.DaemonDidNotStop;
}

pub fn checkTermination(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.LaunchctlFailed,
        else => return error.LaunchctlTerminated,
    }
}

fn xml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidPlistString;
    var codepoints = std.unicode.Utf8View.initUnchecked(input).iterator();
    while (codepoints.nextCodepoint()) |cp| {
        if (cp == 0xfffe or cp == 0xffff) return error.InvalidPlistString;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |ch| {
        const escaped: []const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => {
                if (ch < 0x20 and ch != '\t' and ch != '\n' and ch != '\r') return error.InvalidPlistString;
                try out.append(allocator, ch);
                continue;
            },
        };
        try out.appendSlice(allocator, escaped);
    }
    return out.toOwnedSlice(allocator);
}

pub fn generatePlist(allocator: std.mem.Allocator, binary_path: []const u8, log_path: []const u8, home_path: []const u8, job_label: []const u8) ![]u8 {
    const binary = try xml(allocator, binary_path);
    defer allocator.free(binary);
    const log = try xml(allocator, log_path);
    defer allocator.free(log);
    const home = try xml(allocator, home_path);
    defer allocator.free(home);
    const escaped_label = try xml(allocator, job_label);
    defer allocator.free(escaped_label);
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\<key>Label</key><string>{s}</string>
        \\<key>ProgramArguments</key><array><string>{s}</string></array>
        \\<key>RunAtLoad</key><true/>
        \\<key>KeepAlive</key><true/>
        \\<key>ProcessType</key><string>Background</string>
        \\<key>LowPriorityIO</key><true/>
        \\<key>StandardErrorPath</key><string>{s}</string>
        \\<key>EnvironmentVariables</key><dict><key>HOME</key><string>{s}</string></dict>
        \\</dict></plist>
        \\
    , .{ escaped_label, binary, log, home });
}

const Service = struct {
    allocator: std.mem.Allocator,
    home: []const u8,
    job_label: []const u8 = label,
    support: []const u8,
    plist: []const u8,
    domain: []const u8,
    target: []const u8,

    fn init(allocator: std.mem.Allocator) !Service {
        const home = try runtime.getEnvVarOwned(allocator, "HOME");
        const domain = try std.fmt.allocPrint(allocator, "gui/{d}", .{getuid()});
        return .{
            .allocator = allocator,
            .home = home,
            .support = try config.appSupportDir(allocator),
            .plist = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/{s}.plist", .{ home, label }),
            .domain = domain,
            .target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ domain, label }),
        };
    }

    fn launchctl(self: Service, args: []const []const u8) !std.process.RunResult {
        const argv = try self.allocator.alloc([]const u8, args.len + 1);
        argv[0] = "/bin/launchctl";
        @memcpy(argv[1..], args);
        return std.process.run(self.allocator, runtime.io, .{
            .argv = argv,
            .stdout_limit = .limited(128 * 1024),
            .stderr_limit = .limited(128 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
    }

    fn checked(self: Service, args: []const []const u8) !void {
        const result = try self.launchctl(args);
        checkTermination(result.term) catch |err| {
            runtime.warn("launchctl {s} failed: {s}\n", .{ args[0], result.stderr });
            return err;
        };
    }

    fn state(self: Service) !State {
        const result = try self.launchctl(&.{ "print", self.target });
        if (checkTermination(result.term)) |_| {
            return if (std.mem.indexOf(u8, result.stdout, "state = running") != null) .running else .waiting;
        } else |_| {
            // Only the documented missing-service diagnostic means stopped;
            // permission/domain/tool failures must not masquerade as absence.
            if (std.mem.indexOf(u8, result.stderr, "Could not find service") == null) {
                runtime.warn("Cannot determine daemon status: {s}\n", .{result.stderr});
                return error.DaemonStatusUnavailable;
            }
        }
        std.Io.Dir.accessAbsolute(runtime.io, self.plist, .{}) catch |err| switch (err) {
            error.FileNotFound => return .not_installed,
            else => return err,
        };
        return .stopped;
    }

    fn start(self: Service) !void {
        switch (try self.state()) {
            .running, .waiting => return,
            .not_installed => return error.DaemonNotInstalled,
            .stopped => {},
        }
        try self.checked(&.{ "enable", self.target });
        try self.checked(&.{ "bootstrap", self.domain, self.plist });
        switch (try self.state()) {
            .running, .waiting => {},
            else => return error.DaemonDidNotLoad,
        }
    }

    fn stop(self: Service) !void {
        switch (try self.state()) {
            .not_installed, .stopped => return,
            .running, .waiting => try self.checked(&.{ "bootout", self.target }),
        }
        try waitForStopped(self);
    }

    fn pause(_: Service) !void {
        try std.Io.sleep(runtime.io, .fromMilliseconds(250), .awake);
    }

    /// Stage only the executable. Do not create a LaunchAgents plist: merely
    /// logging in again must not start a scan before permission setup finishes.
    fn prepare(self: Service, override: ?[]const u8) ![]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const source = override orelse buf[0..try std.process.executablePath(runtime.io, &buf)];
        if (!std.fs.path.isAbsolute(source)) return error.BinaryPathMustBeAbsolute;
        // Keep the installed daemon independent of development build/clean.
        const bytes = try runtime.readFileAlloc(self.allocator, source, .limited(128 * 1024 * 1024));
        const binary = try std.fs.path.join(self.allocator, &.{ self.support, "bin", "zest-indexer" });
        // Setup completion installs from the exact executable the user just
        // authorized. Preserve it rather than replacing its inode/signature.
        if (std.mem.eql(u8, source, binary)) return binary;
        const existing = runtime.readFileAlloc(self.allocator, binary, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |installed| {
            defer self.allocator.free(installed);
            if (std.mem.eql(u8, bytes, installed)) return binary;
        }
        try runtime.ensureDir(std.fs.path.dirname(binary).?);
        // Preserve a running service if preparation fails. Restart only after
        // the new executable and plist are durably published.
        var atomic = try std.Io.Dir.cwd().createFileAtomic(runtime.io, binary, .{ .replace = true });
        defer atomic.deinit(runtime.io);
        try atomic.file.writeStreamingAll(runtime.io, bytes);
        try atomic.file.setPermissions(runtime.io, .fromMode(0o755));
        try atomic.file.sync(runtime.io);
        try atomic.replace(runtime.io);
        return binary;
    }

    fn install(self: Service, override: ?[]const u8) !void {
        const binary = try self.prepare(override);
        const log = try std.fs.path.join(self.allocator, &.{ self.support, "daemon.log" });
        const plist = try generatePlist(self.allocator, binary, log, self.home, self.job_label);
        try runtime.ensureDir(std.fs.path.dirname(self.plist).?);
        try runtime.writeFileAtomic(self.plist, plist);
        try self.stop();
        try self.start();
        cli.info("zest-indexer daemon installed and loaded.\nBinary: {s}\n", .{binary});
    }

    fn restart(self: Service) !void {
        try self.stop();
        try self.start();
    }
};

/// Control commands have bounded process lifetimes, so their strings/results
/// live in a command-local arena. The watch loop never uses this arena.
pub fn handle(gpa: std.mem.Allocator, args: []const []const u8) !bool {
    if (args.len < 2) return false;
    if (std.mem.eql(u8, args[1], "probe-access")) {
        if (args.len != 2) cli.fail("zest-indexer", "'probe-access' takes no arguments", .{});
        const access = @import("access.zig");
        const status = try access.probe(gpa);
        var buffer: [64]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(runtime.io, &buffer);
        try writer.interface.print("{s}\n", .{@tagName(status)});
        try writer.interface.flush();
        return true;
    }
    const command = std.meta.stringToEnum(enum { install, @"prepare-install", uninstall, status, start, stop, restart, reindex }, args[1]) orelse return false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const service = try Service.init(arena.allocator());
    if (command != .install and command != .@"prepare-install" and args.len != 2) cli.fail("zest-indexer", "'{s}' takes no arguments", .{args[1]});
    switch (command) {
        .install, .@"prepare-install" => {
            const override = if (args.len == 4 and std.mem.eql(u8, args[2], "--binary-path")) args[3] else if (args.len == 2) null else cli.fail("zest-indexer", "'{s}' accepts only --binary-path PATH", .{args[1]});
            if (command == .install) {
                try service.install(override);
            } else {
                var buffer: [4096]u8 = undefined;
                var writer = std.Io.File.stdout().writerStreaming(runtime.io, &buffer);
                try writer.interface.print("{s}\n", .{try service.prepare(override)});
                try writer.interface.flush();
            }
        },
        .uninstall => {
            try service.stop();
            std.Io.Dir.deleteFileAbsolute(runtime.io, service.plist) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            const binary = try std.fs.path.join(service.allocator, &.{ service.support, "bin", "zest-indexer" });
            std.Io.Dir.deleteFileAbsolute(runtime.io, binary) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            cli.info("zest-indexer daemon uninstalled.\n", .{});
        },
        .start => try service.start(),
        .stop => try service.stop(),
        .restart => try service.restart(),
        .status => {
            var buffer: [128]u8 = undefined;
            var writer = std.Io.File.stdout().writerStreaming(runtime.io, &buffer);
            try writer.interface.print("{s}\n", .{@tagName(try service.state())});
            try writer.interface.flush();
        },
        .reindex => {
            switch (try service.state()) {
                .running, .waiting => {},
                else => return error.DaemonNotRunning,
            }
            const path = try std.fs.path.join(service.allocator, &.{ service.support, request_filename });
            var token: [16]u8 = undefined;
            runtime.io.random(&token);
            try runtime.writeFileAtomic(path, &token);
            cli.info("Re-index requested.\n", .{});
        },
    }
    return true;
}

test "launchctl failures and signals propagate" {
    try checkTermination(.{ .exited = 0 });
    try std.testing.expectError(error.LaunchctlFailed, checkTermination(.{ .exited = 42 }));
    try std.testing.expectError(error.LaunchctlTerminated, checkTermination(.{ .signal = .TERM }));
}

test "stop waits through asynchronous unloading and times out if stuck" {
    const Fake = struct {
        polls: usize = 0,
        pauses: usize = 0,
        stuck: bool = false,
        fn state(self: *@This()) !State {
            self.polls += 1;
            if (self.stuck or self.polls == 1) return .running;
            if (self.polls == 2) return .waiting;
            return .stopped;
        }
        fn pause(self: *@This()) !void {
            self.pauses += 1;
        }
    };
    var normal = Fake{};
    try waitForStopped(&normal);
    try std.testing.expectEqual(@as(usize, 2), normal.pauses);
    var stuck = Fake{ .stuck = true };
    try std.testing.expectError(error.DaemonDidNotStop, waitForStopped(&stuck));
    try std.testing.expectEqual(@as(usize, 120), stuck.pauses);
}

test "plist escapes paths and rejects XML control bytes" {
    const allocator = std.testing.allocator;
    const plist = try generatePlist(allocator, "/A&B/<test>/\"' ø/indexer", "/A&B/log", "/home/me", label);
    defer allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "/A&amp;B/&lt;test&gt;/&quot;&apos; ø/indexer") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "/A&amp;B/log") != null);
    try std.testing.expectError(error.InvalidPlistString, generatePlist(allocator, "/bad\x01", "/log", "/home/me", label));
    try std.testing.expectError(error.InvalidPlistString, generatePlist(allocator, "/bad\xff", "/log", "/home/me", label));
    try std.testing.expectError(error.InvalidPlistString, generatePlist(allocator, "/bad\xef\xbf\xbe", "/log", "/home/me", label));
}

test "macOS plist parser round-trips special executable and log paths" {
    const allocator = std.testing.allocator;
    const binary = "/A&B/<test>/\"' ø/indexer";
    const log = "/A&B/\"log\"";
    const plist = try generatePlist(allocator, binary, log, "/home/A&B", label);
    defer allocator.free(plist);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(runtime.io, .{ .sub_path = "test.plist", .data = plist });
    const path = try tmp.dir.realPathFileAlloc(runtime.io, "test.plist", allocator);
    defer allocator.free(path);
    for ([_][]const u8{ "ProgramArguments.0", "StandardErrorPath", "EnvironmentVariables.HOME" }, [_][]const u8{ binary, log, "/home/A&B" }) |key, expected| {
        const result = try std.process.run(allocator, runtime.io, .{ .argv = &.{ "/usr/bin/plutil", "-extract", key, "raw", "-o", "-", path } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try checkTermination(result.term);
        try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, result.stdout, "\n"));
    }
}

test "launchd install start stop and failed bootstrap with an isolated service" {
    // A GUI login domain is not always present on CI. Pure error/serialization
    // tests above still run there; never use the user's real service label.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const domain = try std.fmt.allocPrint(allocator, "gui/{d}", .{getuid()});
    const probe = try std.process.run(allocator, runtime.io, .{ .argv = &.{ "/bin/launchctl", "print", domain } });
    checkTermination(probe.term) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(runtime.io, "home & test");
    const home = try tmp.dir.realPathFileAlloc(runtime.io, "home & test", allocator);
    // One stable label: a crashed run leaves at most one stale job, and the
    // next run boots it out before starting instead of accumulating garbage.
    const job_label = "dev.zest.test";
    const service = Service{
        .allocator = allocator,
        .home = home,
        .job_label = job_label,
        .support = try std.fs.path.join(allocator, &.{ home, "Library/Application Support/zest" }),
        .plist = try std.fs.path.join(allocator, &.{ home, "Library/LaunchAgents/test.plist" }),
        .domain = domain,
        .target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ domain, job_label }),
    };
    defer service.stop() catch {};
    _ = service.launchctl(&.{ "bootout", service.target }) catch {};
    try waitForStopped(service);
    try std.testing.expectEqual(State.not_installed, try service.state());
    // A real long-running job whose TERM handler deliberately takes time.
    // This reproduces bootout returning before launchd removes the service.
    try tmp.dir.writeFile(runtime.io, .{
        .sub_path = "slow-helper",
        .data = "#!/bin/sh\ntrap 'sleep 2; exit 0' TERM\necho ready >&2\nwhile :; do sleep 0.1; done\n",
    });
    const slow_helper = try tmp.dir.realPathFileAlloc(runtime.io, "slow-helper", allocator);
    const prepared = try service.prepare(slow_helper);
    const prepared_stat = try std.Io.Dir.cwd().statFile(runtime.io, prepared, .{});
    _ = try service.prepare(slow_helper);
    const repeated_stat = try std.Io.Dir.cwd().statFile(runtime.io, prepared, .{});
    try std.testing.expectEqual(prepared_stat.inode, repeated_stat.inode);
    try std.testing.expectEqual(State.not_installed, try service.state());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(runtime.io, service.plist, .{}));
    // The real scan loop is separately exercised by scripts/test-daemon.mjs.
    try service.install(prepared);
    const installed_stat = try std.Io.Dir.cwd().statFile(runtime.io, prepared, .{});
    try std.testing.expectEqual(prepared_stat.inode, installed_stat.inode);
    const log_path = try std.fs.path.join(allocator, &.{ service.support, "daemon.log" });
    for (0..40) |_| {
        const log = runtime.readFileAlloc(allocator, log_path, .limited(4096)) catch "";
        if (std.mem.indexOf(u8, log, "ready") != null) break;
        try service.pause();
    } else return error.TestHelperDidNotStart;
    try std.testing.expect(switch (try service.state()) {
        .running, .waiting => true,
        else => false,
    });
    try service.stop();
    try std.testing.expectEqual(State.stopped, try service.state());
    try service.start();
    try service.stop();
    try runtime.writeFileAbsolute(service.plist, "not a plist");
    try std.testing.expectError(error.LaunchctlFailed, service.start());
    try std.testing.expectEqual(State.stopped, try service.state());
}
