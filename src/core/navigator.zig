const std = @import("std");

/// Manages path navigation with back/forward/up history.
pub const Navigator = struct {
    current: []const u8,
    back_stack: std.ArrayList([]const u8) = .empty,
    forward_stack: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, initial_path: []const u8) !Navigator {
        return .{
            .current = try allocator.dupe(u8, initial_path),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Navigator) void {
        self.allocator.free(self.current);
        for (self.back_stack.items) |p| self.allocator.free(p);
        self.back_stack.deinit(self.allocator);
        for (self.forward_stack.items) |p| self.allocator.free(p);
        self.forward_stack.deinit(self.allocator);
    }

    pub fn navigate(self: *Navigator, path: []const u8) !void {
        const old = self.current;
        try self.back_stack.append(self.allocator, old);

        for (self.forward_stack.items) |p| self.allocator.free(p);
        self.forward_stack.clearRetainingCapacity();

        self.current = try self.allocator.dupe(u8, path);
    }

    pub fn goBack(self: *Navigator) !bool {
        if (self.back_stack.items.len == 0) return false;
        const old = self.current;
        try self.forward_stack.append(self.allocator, old);
        self.current = self.back_stack.pop().?;
        return true;
    }

    pub fn goForward(self: *Navigator) !bool {
        if (self.forward_stack.items.len == 0) return false;
        const old = self.current;
        try self.back_stack.append(self.allocator, old);
        self.current = self.forward_stack.pop().?;
        return true;
    }

    pub fn goUp(self: *Navigator) !bool {
        const parent = std.fs.path.dirname(self.current) orelse return false;
        if (std.mem.eql(u8, parent, self.current)) return false;
        try self.navigate(parent);
        return true;
    }

    pub fn canGoBack(self: Navigator) bool {
        return self.back_stack.items.len > 0;
    }

    pub fn canGoForward(self: Navigator) bool {
        return self.forward_stack.items.len > 0;
    }
};
