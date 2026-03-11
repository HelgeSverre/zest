const std = @import("std");

const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Opaque Objective-C object pointer (nullable).
pub const id = ?*anyopaque;

/// Objective-C selector.
pub const SEL = c.SEL;

/// Objective-C class (same representation as id at the ABI level).
pub const Class = c.Class;

// ---------------------------------------------------------------------------
// Class / selector helpers
// ---------------------------------------------------------------------------

/// Look up an Objective-C class by name.  Returns `null` when the class is
/// not registered with the runtime (e.g. framework not loaded).
pub fn getClass(name: [:0]const u8) ?Class {
    return c.objc_getClass(name.ptr);
}

/// Register (or look up) a selector by name.
pub fn sel(name: [:0]const u8) SEL {
    return c.sel_registerName(name.ptr);
}

// ---------------------------------------------------------------------------
// Typed objc_msgSend wrappers
// ---------------------------------------------------------------------------

/// `objc_msgSend(target, sel) -> id`  — no extra arguments, returns object.
pub fn msgSend(target: id, sel_name: [:0]const u8) id {
    const func: *const fn (id, SEL) callconv(.c) id = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name));
}

/// `objc_msgSend(target, sel, arg1) -> id`
pub fn msgSendWith1(comptime T1: type, target: id, sel_name: [:0]const u8, arg1: T1) id {
    const func: *const fn (id, SEL, T1) callconv(.c) id = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name), arg1);
}

/// `objc_msgSend(target, sel, arg1, arg2) -> id`
pub fn msgSendWith2(comptime T1: type, comptime T2: type, target: id, sel_name: [:0]const u8, arg1: T1, arg2: T2) id {
    const func: *const fn (id, SEL, T1, T2) callconv(.c) id = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name), arg1, arg2);
}

/// `objc_msgSend(target, sel, arg1, arg2, arg3) -> id`
pub fn msgSendWith3(comptime T1: type, comptime T2: type, comptime T3: type, target: id, sel_name: [:0]const u8, arg1: T1, arg2: T2, arg3: T3) id {
    const func: *const fn (id, SEL, T1, T2, T3) callconv(.c) id = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name), arg1, arg2, arg3);
}

/// `objc_msgSend(target, sel) -> void`
pub fn msgSendVoid(target: id, sel_name: [:0]const u8) void {
    const func: *const fn (id, SEL) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    func(target, sel(sel_name));
}

/// `objc_msgSend(target, sel, arg1) -> void`
pub fn msgSendVoidWith1(comptime T1: type, target: id, sel_name: [:0]const u8, arg1: T1) void {
    const func: *const fn (id, SEL, T1) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    func(target, sel(sel_name), arg1);
}

/// `objc_msgSend(target, sel, arg1, arg2) -> void`
pub fn msgSendVoidWith2(comptime T1: type, comptime T2: type, target: id, sel_name: [:0]const u8, arg1: T1, arg2: T2) void {
    const func: *const fn (id, SEL, T1, T2) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    func(target, sel(sel_name), arg1, arg2);
}

/// `objc_msgSend(target, sel) -> f64`
pub fn msgSendF64(target: id, sel_name: [:0]const u8) f64 {
    const func: *const fn (id, SEL) callconv(.c) f64 = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name));
}

/// `objc_msgSend(target, sel) -> bool` (BOOL on ARM64 is actually `bool`).
pub fn msgSendBool(target: id, sel_name: [:0]const u8) bool {
    const func: *const fn (id, SEL) callconv(.c) bool = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name));
}

/// `objc_msgSend(target, sel) -> i64` (NSInteger on 64-bit).
pub fn msgSendI64(target: id, sel_name: [:0]const u8) i64 {
    const func: *const fn (id, SEL) callconv(.c) i64 = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name));
}

/// `objc_msgSend(target, sel) -> u64` (NSUInteger on 64-bit).
pub fn msgSendU64(target: id, sel_name: [:0]const u8) u64 {
    const func: *const fn (id, SEL) callconv(.c) u64 = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name));
}

// ---------------------------------------------------------------------------
// Convenience wrappers for common messages
// ---------------------------------------------------------------------------

/// `[cls alloc]`
pub fn alloc(cls: anytype) id {
    return msgSend(@as(id, @ptrCast(cls)), "alloc");
}

/// `[obj init]`
pub fn init(obj: id) id {
    return msgSend(obj, "init");
}

/// `[obj autorelease]`
pub fn autorelease(obj: id) id {
    return msgSend(obj, "autorelease");
}

/// `[obj retain]`
pub fn retain(obj: id) id {
    return msgSend(obj, "retain");
}

/// `[obj release]`
pub fn release(obj: id) void {
    msgSendVoid(obj, "release");
}

// ---------------------------------------------------------------------------
// NSString helpers
// ---------------------------------------------------------------------------

pub const NSString = struct {
    /// Create an `NSString` from a Zig slice.
    /// The returned object is autoreleased.
    pub fn fromSlice(slice: []const u8) id {
        const NSStringClass = getClass("NSString") orelse @panic("NSString class not found");
        // -[NSString initWithBytes:length:encoding:]
        // NSUTF8StringEncoding = 4
        const raw = alloc(NSStringClass);
        const func: *const fn (id, SEL, [*]const u8, u64, u64) callconv(.c) id = @ptrCast(&c.objc_msgSend);
        const obj = func(
            raw,
            sel("initWithBytes:length:encoding:"),
            slice.ptr,
            @as(u64, slice.len),
            @as(u64, 4), // NSUTF8StringEncoding
        );
        return autorelease(obj);
    }

    /// Extract a Zig-owned `[]const u8` from an `NSString`.
    /// Caller owns the returned memory and must free it with `allocator.free()`.
    pub fn toSlice(allocator: std.mem.Allocator, nsstring: id) ![]const u8 {
        // -[NSString UTF8String] returns a C string
        const func: *const fn (id, SEL) callconv(.c) ?[*:0]const u8 = @ptrCast(&c.objc_msgSend);
        const cstr = func(nsstring, sel("UTF8String")) orelse return error.NullString;
        const len = std.mem.len(cstr);
        const buf = try allocator.alloc(u8, len);
        @memcpy(buf, cstr[0..len]);
        return buf;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sel returns non-null" {
    const s = sel("init");
    try std.testing.expect(s != null);
}

test "getClass finds NSObject" {
    const cls = getClass("NSObject");
    try std.testing.expect(cls != null);
}

test "alloc and init NSObject" {
    const cls = getClass("NSObject") orelse return error.SkipZigTest;
    const obj = init(alloc(cls));
    try std.testing.expect(obj != null);
    release(obj);
}

test "NSString round-trip" {
    const input = "Hello from Zig!";
    const ns = NSString.fromSlice(input);
    try std.testing.expect(ns != null);

    const output = try NSString.toSlice(std.testing.allocator, ns);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(input, output);
}
