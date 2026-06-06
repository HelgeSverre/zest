const std = @import("std");
const builtin = @import("builtin");

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

/// `objc_msgSend(target, sel, arg1, arg2, arg3, arg4) -> id`
pub fn msgSendWith4(comptime T1: type, comptime T2: type, comptime T3: type, comptime T4: type, target: id, sel_name: [:0]const u8, arg1: T1, arg2: T2, arg3: T3, arg4: T4) id {
    const func: *const fn (id, SEL, T1, T2, T3, T4) callconv(.c) id = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name), arg1, arg2, arg3, arg4);
}

/// `objc_msgSend(target, sel, arg1, arg2, arg3) -> void`
pub fn msgSendVoidWith3(comptime T1: type, comptime T2: type, comptime T3: type, target: id, sel_name: [:0]const u8, arg1: T1, arg2: T2, arg3: T3) void {
    const func: *const fn (id, SEL, T1, T2, T3) callconv(.c) void = @ptrCast(&c.objc_msgSend);
    func(target, sel(sel_name), arg1, arg2, arg3);
}

/// `objc_msgSend(target, sel, arg1) -> bool`
pub fn msgSendBoolWith1(comptime T1: type, target: id, sel_name: [:0]const u8, arg1: T1) bool {
    const func: *const fn (id, SEL, T1) callconv(.c) bool = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name), arg1);
}

/// `objc_msgSend(target, sel, arg1) -> i64`
pub fn msgSendI64With1(comptime T1: type, target: id, sel_name: [:0]const u8, arg1: T1) i64 {
    const func: *const fn (id, SEL, T1) callconv(.c) i64 = @ptrCast(&c.objc_msgSend);
    return func(target, sel(sel_name), arg1);
}

/// Cast `objc_msgSend` to any function pointer type for custom signatures.
pub fn msgSendFn(comptime T: type) T {
    return @ptrCast(&c.objc_msgSend);
}

/// Mirrors C `struct objc_super` ({ id receiver; Class super_class; }).
pub const objc_super = extern struct {
    receiver: id,
    super_class: Class,
};

/// `[super sel:arg1]` returning void. Call from inside an overridden method's
/// IMP, passing the superclass whose implementation should run.
pub fn msgSendSuperVoidWith1(comptime T1: type, self_obj: id, superclass: Class, sel_name: [:0]const u8, arg1: T1) void {
    var sup = objc_super{ .receiver = self_obj, .super_class = superclass };
    const func: *const fn (*objc_super, SEL, T1) callconv(.c) void = @ptrCast(&c.objc_msgSendSuper);
    func(&sup, sel(sel_name), arg1);
}

// ---------------------------------------------------------------------------
// CoreGraphics geometry types
// ---------------------------------------------------------------------------

pub const CGFloat = f64;
pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
pub const CGSize = extern struct { width: CGFloat, height: CGFloat };
pub const NSEdgeInsets = extern struct {
    top: CGFloat,
    left: CGFloat,
    bottom: CGFloat,
    right: CGFloat,
};
pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,

    pub fn make(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) CGRect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
    }
};

// ---------------------------------------------------------------------------
// Runtime class creation
// ---------------------------------------------------------------------------

/// Create a new ObjC class as a subclass of `superclass`.
/// Returns null if the class name is already registered.
pub fn allocateClassPair(superclass: ?Class, name: [:0]const u8) ?Class {
    return c.objc_allocateClassPair(superclass orelse null, name.ptr, 0);
}

/// Register a class that was created with `allocateClassPair`.
/// After this, the class can be instantiated.
pub fn registerClassPair(cls: Class) void {
    c.objc_registerClassPair(cls);
}

/// Add a method to a class.  `imp` must be a `callconv(.c)` function pointer.
/// `types` is the ObjC type encoding (e.g. "v@:@" for void(self, _cmd, id)).
pub fn addMethod(cls: Class, sel_name: [:0]const u8, imp: anytype, types: [:0]const u8) bool {
    return c.class_addMethod(cls, sel(sel_name), @ptrCast(&imp), types.ptr) != 0;
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
// GCD (Grand Central Dispatch) wrappers
// ---------------------------------------------------------------------------

const dispatch_c = @cImport({
    @cInclude("dispatch/dispatch.h");
});

pub const dispatch_queue_t = *anyopaque;
pub const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;

// libdispatch exports the main queue as the global symbol `_dispatch_main_q`.
// The C header types it as an opaque struct, which Zig 0.16's translate-c
// surfaces as an opaque type we cannot take the address of. Re-declare the
// symbol with a sized type so we can obtain its address; only the address
// matters, and the linker resolves it by name.
extern var _dispatch_main_q: usize;

/// Returns the main dispatch queue (runs on the AppKit main thread).
pub fn dispatch_get_main_queue() dispatch_queue_t {
    return @ptrCast(&_dispatch_main_q);
}

/// Schedule `work(context)` to run asynchronously on `queue`.
/// Uses the _f variant (C function pointer) since Zig cannot create ObjC blocks.
pub fn dispatch_async_f(queue: dispatch_queue_t, context: ?*anyopaque, work: dispatch_function_t) void {
    dispatch_c.dispatch_async_f(@ptrCast(queue), context, work);
}

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

test "CGRect make" {
    const r = CGRect.make(10, 20, 100, 200);
    try std.testing.expectEqual(@as(CGFloat, 10), r.origin.x);
    try std.testing.expectEqual(@as(CGFloat, 20), r.origin.y);
    try std.testing.expectEqual(@as(CGFloat, 100), r.size.width);
    try std.testing.expectEqual(@as(CGFloat, 200), r.size.height);
}

test "allocateClassPair and registerClassPair" {
    const NSObject = getClass("NSObject") orelse return error.SkipZigTest;
    const cls = allocateClassPair(NSObject, "ZestTestClass001") orelse return error.SkipZigTest;
    registerClassPair(cls);
    // Should now be findable
    const found = getClass("ZestTestClass001");
    try std.testing.expect(found != null);
}

test "addMethod and call it" {
    const NSObject = getClass("NSObject") orelse return error.SkipZigTest;
    const cls = allocateClassPair(NSObject, "ZestTestClass002") orelse return error.SkipZigTest;

    const impl = struct {
        fn testMethod(_self: id, _cmd: SEL) callconv(.c) i64 {
            _ = _self;
            _ = _cmd;
            return 42;
        }
    }.testMethod;

    const added = addMethod(cls, "testMethod", impl, "q@:");
    try std.testing.expect(added);
    registerClassPair(cls);

    const obj = init(alloc(cls));
    defer release(obj);
    const result = msgSendI64(obj, "testMethod");
    try std.testing.expectEqual(@as(i64, 42), result);
}
