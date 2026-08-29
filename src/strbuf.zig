//! Building strings across the boundary, in both directions.
//!
//! flecs has `ecs_strbuf_t` and about twenty `ecs_strbuf_append*` entry points. Zig has
//! `std.Io.Writer`. Twenty wrappers over the append functions would add no type
//! information to any of them, so what lives here is the adapter between the two shapes
//! instead: a `std.Io.Writer` that appends into an `ecs_strbuf_t`, and the two ways of
//! getting a filled `ecs_strbuf_t` back out. The append functions themselves are
//! reached through `zecs.c`, which is where they already are.
//!
//! ## Streaming, and why there is none
//!
//! The obvious thing to want from flecs's JSON, doc and script serializers is for their
//! output to land in a socket or a file without being assembled in memory first. flecs
//! does not offer that. `ecs_strbuf_t` is a growable byte buffer with 512 bytes of
//! inline storage and no flush seam: there is no callback to install, no partial drain,
//! and every `*_buf` serializer writes the entire document before it returns. What the
//! buffer has is an end, not a middle.
//!
//! So the honest shape is that flecs buffers the whole thing, after which either
//!
//! - `take` hands the buffer over as an `Owned` — no copy at all, and one `deinit` to
//!   remember, or
//! - `writeInto` copies it once into a writer the caller already has, and there is
//!   nothing left to own.
//!
//! Neither is streaming. A wrapper that accepted a `*std.Io.Writer` and implied
//! otherwise would only be hiding where the buffer went.
//!
//! ## The one trap in `ecs_strbuf_t`
//!
//! A buffer's first 512 bytes live in an array inside the struct, and `content` points
//! at that array until the string outgrows it. Copying the struct by value after
//! anything has been appended therefore leaves the copy pointing into the original. A
//! buffer must stay where it was first written to, so everything here takes
//! `*c.ecs_strbuf_t` and why `Builder` says not to move it.

const std = @import("std");
const c = @import("c/core.zig");
const types = @import("types.zig");

//=============================================================================
// Strings flecs allocated
//=============================================================================

/// Frees a string flecs returned.
///
/// flecs spells this `ecs_os_free`, which is a macro over a function pointer rather
/// than a symbol — so a caller holding the `?[*:0]u8` from `zecs.c.core.ecs_ptr_to_json` or
/// `zecs.c.core.ecs_id_str` has no exported function to call and no obvious way to find one.
/// This is that function; see `types.freeOsBlock` for the one place it is implemented.
///
/// The block goes back to whatever `zecs.setAllocator` installed, so a string that is
/// never freed shows up as a leak in the host's allocator rather than nowhere.
pub fn free(str: [*:0]u8) void {
    types.freeOsBlock(@ptrCast(str));
}

/// A string flecs allocated and the caller must free.
///
/// This exists because the alternative — returning `?[*:0]u8` and documenting that it
/// needs `ecs_os_free` — is a leak waiting to happen twice over: the length is a
/// `strlen` away, and the free is a macro the caller cannot call. `Owned` is one
/// pointer and one length with a `deinit`, so `defer` covers it.
///
/// An allocator-copied slice was the other candidate and was rejected. flecs already
/// allocates through the host's allocator, so copying would mean a second block from
/// the same allocator, an extra memcpy, and an allocator parameter on every serializer
/// — to arrive at a slice the host could free two ways instead of one.
pub const Owned = struct {
    /// The string, sentinel included, so it can be handed straight back to a C API.
    bytes: [:0]u8,

    pub fn deinit(self: Owned) void {
        free(self.bytes.ptr);
    }
};

//=============================================================================
// Reading a buffer flecs filled
//=============================================================================

/// The bytes written to `buf` so far, borrowed where they lie.
///
/// This is what makes `writeInto` free of a second allocation: flecs has already built
/// the document inside `buf`, and the caller's writer can take it from there. The slice
/// is invalidated by the next append, by `take`, and by `ecs_strbuf_reset`.
///
/// Empty for a buffer nothing has been appended to.
pub fn contents(buf: *const c.ecs_strbuf_t) []const u8 {
    const ptr = buf.content orelse return &.{};
    return ptr[0..@intCast(c.ecs_strbuf_written(buf))];
}

/// Detaches everything in `buf` as an owned string, leaving `buf` empty and reusable.
///
/// Null when nothing was appended. That is flecs's own answer — `ecs_strbuf_get`
/// returns NULL for an untouched buffer rather than an empty string — and flattening it
/// to `""` here would erase the difference between a serializer that wrote nothing and
/// one that wrote an empty document.
pub fn take(buf: *c.ecs_strbuf_t) ?Owned {
    // Read the length before detaching: `ecs_strbuf_get` appends the terminator and
    // then zeroes the buffer's bookkeeping, so afterwards the only way back to the
    // length would be a `strlen` over a string whose length flecs just knew.
    const len: usize = @intCast(c.ecs_strbuf_written(buf));
    const raw = c.ecs_strbuf_get(buf) orelse return null;
    return .{ .bytes = raw[0..len :0] };
}

/// Writes everything in `buf` to `out` and resets `buf`.
///
/// One copy, into memory the caller already owns, with nothing left over to free. The
/// buffer is reset even when the write fails, because the failure belongs to `out` and
/// the buffer's allocation is this function's to release either way.
pub fn writeInto(buf: *c.ecs_strbuf_t, out: *std.Io.Writer) std.Io.Writer.Error!void {
    defer c.ecs_strbuf_reset(buf);
    try out.writeAll(contents(buf));
}

//=============================================================================
// Writing into a buffer flecs will read
//=============================================================================

/// `ecs_strbuf_appendstrn` takes its length as an `i32`, so a longer slice goes in
/// pieces. Its declared parameter type is sentinel-terminated because that is what the
/// header says; the C function copies exactly `n` bytes and never looks for a
/// terminator, which is what makes an ordinary Zig slice a legal argument.
fn appendSlice(buf: *c.ecs_strbuf_t, bytes: []const u8) void {
    const chunk_max = std.math.maxInt(i32);
    var rest = bytes;
    while (rest.len != 0) {
        const n = @min(rest.len, chunk_max);
        c.ecs_strbuf_appendstrn(buf, @ptrCast(rest.ptr), @intCast(n));
        rest = rest[n..];
    }
}

/// A `std.Io.Writer` that appends into an `ecs_strbuf_t`.
///
/// This is the direction that lets Zig build the string: `builder.interface.print(...)`
/// with Zig's formatting, then `toOwned` for the `[:0]u8` a C API wants, or `strbuf`
/// for the `ecs_strbuf_t*` a flecs serializer will append its own output to.
///
/// ```zig
/// var builder: zecs.strbuf.Builder = .init(&.{});
/// defer builder.deinit();
///
/// try builder.interface.print("Position.x == {d}", .{limit});
/// const expr = builder.toOwned().?;
/// defer expr.deinit();
/// ```
///
/// Do not move a `Builder` after writing to it. It contains the `ecs_strbuf_t`, which
/// points into itself, and `interface` is located by `@fieldParentPtr`, which needs the
/// struct to still be where the writer thinks it is.
pub const Builder = struct {
    buf: c.ecs_strbuf_t = .{},
    interface: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    /// `buffer` may be empty, and usually should be: the `ecs_strbuf_t` behind this is
    /// already a growable buffer with 512 bytes of inline storage, so a second layer of
    /// buffering in front of it buys nothing but a copy. It is a parameter because
    /// `std.Io.Writer`'s file-sending path asserts a non-empty one.
    pub fn init(buffer: []u8) Builder {
        return .{ .interface = .{ .vtable = &vtable, .buffer = buffer } };
    }

    /// Discards everything written and releases the buffer.
    pub fn deinit(self: *Builder) void {
        c.ecs_strbuf_reset(&self.buf);
        self.* = undefined;
    }

    /// The buffer to hand to flecs, with anything still sitting in the writer flushed
    /// into it first so that the two sources of bytes stay in the order they were
    /// written.
    pub fn strbuf(self: *Builder) *c.ecs_strbuf_t {
        self.flush();
        return &self.buf;
    }

    /// Everything written so far, borrowed. Invalidated by the next write.
    pub fn written(self: *Builder) []const u8 {
        return contents(self.strbuf());
    }

    /// Detaches the result, leaving the builder empty and reusable. Null when nothing
    /// was written — see `take`.
    pub fn toOwned(self: *Builder) ?Owned {
        return take(self.strbuf());
    }

    /// Appending to an `ecs_strbuf_t` cannot fail — flecs aborts on a failed
    /// allocation rather than reporting one — so the flush that every accessor here
    /// performs has no error to propagate.
    fn flush(self: *Builder) void {
        self.interface.flush() catch unreachable;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Builder = @alignCast(@fieldParentPtr("interface", w));
        std.debug.assert(data.len != 0);

        // Whatever is in the writer's own buffer was written before anything in `data`,
        // so it goes first, and the writer is told it is gone.
        appendSlice(&self.buf, w.buffer[0..w.end]);
        w.end = 0;

        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            appendSlice(&self.buf, bytes);
            count += bytes.len;
        }

        // The last slice stands for itself repeated `splat` times. That is how a writer
        // expresses a run of padding or a repeated separator without building it.
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            appendSlice(&self.buf, pattern);
            count += pattern.len;
        }

        // Bytes taken from the writer's buffer are excluded: they were already counted
        // as written when they were buffered.
        return count;
    }
};

//=============================================================================
// Tests
//=============================================================================

test {
    // Nothing in this module is addon-gated, and the behaviour suite does not run at
    // every addon set, so this is what keeps everything here compiled even in a build
    // where nothing calls it. `refAllDecls` does not recurse, hence the three calls.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Owned);
    std.testing.refAllDecls(Builder);
}

test "an untouched buffer holds nothing and detaches to nothing" {
    // No allocation happens on this path, so it is safe before flecs's OS API exists.
    var buf: c.ecs_strbuf_t = .{};
    try std.testing.expectEqualStrings("", contents(&buf));
    try std.testing.expect(take(&buf) == null);
}

test "the writer adapter appends what was printed, in order" {
    // Short enough to stay in the buffer's inline storage, so this too allocates
    // nothing and does not depend on which allocator flecs currently holds.
    var builder: Builder = .init(&.{});
    defer builder.deinit();

    try builder.interface.writeAll("terms:");
    try builder.interface.print(" {s}={d}", .{ "count", 3 });
    try builder.interface.splatByteAll('.', 3);

    try std.testing.expectEqualStrings("terms: count=3...", builder.written());
}
