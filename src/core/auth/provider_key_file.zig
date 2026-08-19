//! Plain-file storage for direct-provider API keys (FX_PROVIDER).
//!
//! `~/.fx/provider-keys.json` is a hand-editable JSON object mapping provider
//! id to key, e.g. `{"opencode":"...","zai":"..."}`. The file must be mode
//! 0600 like `~/.fx/api-key`; a group- or other-readable file is refused. The
//! provider's environment variable always wins over the file. Unreadable,
//! insecure, or malformed files are traced and treated as absent so startup
//! never hard-fails on a diagnosable local file; the missing-key guidance
//! names both sources.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const provider_selection = @import("../config/provider_selection.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const file_name = "provider-keys.json";
const max_file_bytes: usize = 16 * 1024;

/// Returns the stored key for `kind`, or null when HOME, the file, or the
/// entry is absent, or the file cannot be trusted (each cause traced).
/// Caller owns the returned bytes and should zero them before freeing.
pub fn load(alloc: Allocator, kind: provider_selection.Kind) Allocator.Error!?[]u8 {
    if (kind == .gateway) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("provider_key", "load failed step=open_home err={s}", .{@errorName(err)});
        return null;
    };
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("provider_key", "load failed step=open_profile err={s}", .{@errorName(err)});
            return null;
        },
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir, kind);
}

pub fn loadFromDir(
    alloc: Allocator,
    fx_dir: *std.Io.Dir,
    kind: provider_selection.Kind,
) Allocator.Error!?[]u8 {
    var file = fx_dir.openFile(io_mod.getIo(), file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("provider_key", "load failed step=open_file err={s}", .{@errorName(err)});
            return null;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        debug_trace.logf("provider_key", "load failed step=stat err={s}", .{@errorName(err)});
        return null;
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("provider_key", "load failed step=permissions err=ProviderKeyFileInsecure", .{});
        return null;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("provider_key", "load failed step=read err={s}", .{@errorName(err)});
            return null;
        },
    };
    defer secret.zeroAndFree(alloc, bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("provider_key", "load failed step=parse err=ProviderKeyFileInvalid", .{});
            return null;
        },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        debug_trace.logf("provider_key", "load failed step=shape err=ProviderKeyFileInvalid", .{});
        return null;
    }
    const entry = parsed.value.object.get(@tagName(kind)) orelse return null;
    if (entry != .string) {
        debug_trace.logf("provider_key", "load failed step=entry err=ProviderKeyFileInvalid", .{});
        return null;
    }
    const trimmed = std.mem.trim(u8, entry.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

fn writeTestKeyFile(tmp: *std.testing.TmpDir, contents: []const u8, mode: std.posix.mode_t) !void {
    tmp.dir.deleteFile(std.testing.io, file_name) catch {};
    var file = try tmp.dir.createFile(std.testing.io, file_name, .{
        .permissions = std.Io.File.Permissions.fromMode(mode),
    });
    try file.writeStreamingAll(std.testing.io, contents);
    file.close(std.testing.io);
}

test "provider key file resolves per-provider entries at mode 0600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestKeyFile(&tmp, "{\"opencode\":\"oc-key\\n\",\"zai\":\" z-key \"}", 0o600);

    const opencode_key = (try loadFromDir(std.testing.allocator, &tmp.dir, .opencode)) orelse
        return error.TestUnexpectedMissingKey;
    defer secret.zeroAndFree(std.testing.allocator, opencode_key);
    try std.testing.expectEqualStrings("oc-key", opencode_key);

    const zai_key = (try loadFromDir(std.testing.allocator, &tmp.dir, .zai)) orelse
        return error.TestUnexpectedMissingKey;
    defer secret.zeroAndFree(std.testing.allocator, zai_key);
    try std.testing.expectEqualStrings("z-key", zai_key);
}

test "provider key file treats absence, insecure modes, and bad shapes as missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect((try loadFromDir(std.testing.allocator, &tmp.dir, .zai)) == null);

    try writeTestKeyFile(&tmp, "{\"zai\":\"secret\"}", 0o644);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &tmp.dir, .zai)) == null);

    try writeTestKeyFile(&tmp, "not json", 0o600);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &tmp.dir, .zai)) == null);

    try writeTestKeyFile(&tmp, "[\"zai\"]", 0o600);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &tmp.dir, .zai)) == null);

    try writeTestKeyFile(&tmp, "{\"zai\":42}", 0o600);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &tmp.dir, .zai)) == null);

    try writeTestKeyFile(&tmp, "{\"zai\":\"  \"}", 0o600);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &tmp.dir, .zai)) == null);

    try writeTestKeyFile(&tmp, "{\"opencode\":\"other\"}", 0o600);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &tmp.dir, .zai)) == null);
}

test "provider key file never serves the gateway" {
    try std.testing.expect((try load(std.testing.allocator, .gateway)) == null);
}
