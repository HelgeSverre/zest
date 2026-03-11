const std = @import("std");
const types = @import("types.zig");

pub const PinManager = struct {
    pins: std.ArrayList(types.Pin) = .empty,
    allocator: std.mem.Allocator,
    file_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, file_path: ?[]const u8) PinManager {
        return .{
            .allocator = allocator,
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *PinManager) void {
        for (self.pins.items) |pin| {
            self.allocator.free(pin.name);
            self.allocator.free(pin.path);
        }
        self.pins.deinit(self.allocator);
    }

    pub fn load(self: *PinManager) !void {
        for (self.pins.items) |pin| {
            self.allocator.free(pin.name);
            self.allocator.free(pin.path);
        }
        self.pins.clearRetainingCapacity();

        if (self.file_path) |fp| {
            if (self.loadFromFile(fp)) {
                return;
            } else |_| {}
        }
        try self.loadDefaults();
    }

    fn loadFromFile(self: *PinManager, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch return error.FileNotFound;
        defer file.close();

        const data = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return error.ReadFailed;
        defer self.allocator.free(data);

        try self.parseJson(data);
    }

    fn parseJson(self: *PinManager, data: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return error.InvalidJson;

        for (root.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const name_val = obj.get("name") orelse continue;
            const path_val = obj.get("path") orelse continue;
            if (name_val != .string or path_val != .string) continue;

            const is_default = if (obj.get("is_default")) |d| d == .bool and d.bool else false;

            try self.pins.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name_val.string),
                .path = try self.allocator.dupe(u8, path_val.string),
                .is_default = is_default,
            });
        }
    }

    pub fn loadDefaults(self: *PinManager) !void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return error.HomeNotFound;
        defer self.allocator.free(home);

        const defaults = [_]struct { name: []const u8, suffix: []const u8 }{
            .{ .name = "Home", .suffix = "" },
            .{ .name = "Desktop", .suffix = "/Desktop" },
            .{ .name = "Documents", .suffix = "/Documents" },
            .{ .name = "Downloads", .suffix = "/Downloads" },
        };

        for (defaults) |d| {
            const path = if (d.suffix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, d.suffix })
            else
                try self.allocator.dupe(u8, home);

            try self.pins.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, d.name),
                .path = path,
                .is_default = true,
            });
        }
    }

    pub fn loadFromString(self: *PinManager, data: []const u8) !void {
        for (self.pins.items) |pin| {
            self.allocator.free(pin.name);
            self.allocator.free(pin.path);
        }
        self.pins.clearRetainingCapacity();
        try self.parseJson(data);
    }

    pub fn save(self: *PinManager) !void {
        const fp = self.file_path orelse return error.NoFilePath;

        if (std.fs.path.dirname(fp)) |parent| {
            std.fs.makeDirAbsolute(parent) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeAll("[\n");
        for (self.pins.items, 0..) |pin, i| {
            try writer.print("  {{\"name\": \"{s}\", \"path\": \"{s}\", \"is_default\": {}}}", .{
                pin.name,
                pin.path,
                pin.is_default,
            });
            if (i < self.pins.items.len - 1) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("]\n");

        const file = try std.fs.createFileAbsolute(fp, .{});
        defer file.close();
        try file.writeAll(buf.items);
    }

    pub fn addPin(self: *PinManager, name: []const u8, path: []const u8) !void {
        for (self.pins.items) |pin| {
            if (std.mem.eql(u8, pin.path, path)) return;
        }
        try self.pins.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
            .is_default = false,
        });
    }

    pub fn removePin(self: *PinManager, path: []const u8) bool {
        for (self.pins.items, 0..) |pin, i| {
            if (std.mem.eql(u8, pin.path, path)) {
                self.allocator.free(pin.name);
                self.allocator.free(pin.path);
                _ = self.pins.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn getPins(self: PinManager) []const types.Pin {
        return self.pins.items;
    }
};

pub fn pinsToJson(allocator: std.mem.Allocator, pins: []const types.Pin) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("[\n");
    for (pins, 0..) |pin, i| {
        try writer.print("  {{\"name\": \"{s}\", \"path\": \"{s}\", \"is_default\": {}}}", .{
            pin.name,
            pin.path,
            pin.is_default,
        });
        if (i < pins.len - 1) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("]\n");
    return buf.toOwnedSlice(allocator);
}
