//! OpenAI Codex ChatGPT-subscription browser login (OAuth 2.0 + PKCE).
//!
//! EXPERIMENTAL / personal use. Mirrors the official Codex CLI flow: open
//! auth.openai.com/oauth/authorize in the browser, catch the redirect on a
//! loopback server at http://localhost:1455/auth/callback, and exchange the
//! code for a ChatGPT-subscription session. Reuses the same public Codex
//! client id every third-party client uses; fx is presenting itself as Codex.
const std = @import("std");
const builtin = @import("builtin");
const codex_session = @import("codex_session.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const mcp_auth = @import("../mcp/mcp_auth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const authorize_endpoint = "https://auth.openai.com/oauth/authorize";
pub const redirect_uri = "http://localhost:1455/auth/callback";
pub const callback_port: u16 = 1455;
const scope = "openid profile email offline_access";
const callback_timeout_seconds: u32 = 300;

pub const LoginError = error{
    CodexLoginUnsupported,
    CodexCallbackPortBusy,
    CodexBrowserOpenFailed,
    CodexCallbackInvalid,
    CodexStateMismatch,
    CodexTokenExchangeFailed,
} || codex_session.Error;

pub const Outcome = struct {
    /// The authorize URL, so callers can print it for manual open.
    authorize_url: []u8,

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        alloc.free(self.authorize_url);
        self.* = undefined;
    }
};

/// Runs the full browser login and persists the session on success. `notify`
/// receives the authorize URL before the browser opens (so a CLI can print
/// it). Returns the authenticated session (caller deinits).
pub fn run(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
    notify_ctx: ?*anyopaque,
    notify_url: ?*const fn (?*anyopaque, []const u8) void,
) LoginError!codex_session.Session {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.CodexLoginUnsupported;
    }

    // Seed a CSPRNG from the platform secure source for PKCE + state.
    var seed: [32]u8 = undefined;
    std.Io.randomSecure(io_mod.getIo(), &seed) catch return error.CodexLoginUnsupported;
    var csprng = std.Random.DefaultCsprng.init(seed);
    const random = csprng.random();

    var verifier_buf: [64]u8 = undefined;
    var challenge_buf: [43]u8 = undefined;
    const pkce = mcp_auth.generatePkce(&verifier_buf, &challenge_buf, random);

    var state_bytes: [24]u8 = undefined;
    random.bytes(&state_bytes);
    var state_buf: [32]u8 = undefined;
    const state = std.base64.url_safe_no_pad.Encoder.encode(&state_buf, &state_bytes);

    var address = std.Io.net.IpAddress.parse("127.0.0.1", callback_port) catch return error.CodexLoginUnsupported;
    var listener = address.listen(io_mod.getIo(), .{ .reuse_address = true }) catch return error.CodexCallbackPortBusy;
    defer listener.deinit(io_mod.getIo());

    const authorize_url = try buildAuthorizeUrl(alloc, pkce.challenge, state);
    defer alloc.free(authorize_url);

    if (notify_url) |cb| cb(notify_ctx, authorize_url);
    const opened = url_opener.open(alloc, authorize_url) catch false;
    // A failed browser open is not fatal: the URL was surfaced for manual use.
    _ = opened;

    const code = try awaitCallbackCode(alloc, &listener, state);
    defer secret.zeroAndFree(alloc, code);

    return exchangeCode(alloc, transport, code, pkce.verifier);
}

fn buildAuthorizeUrl(alloc: Allocator, challenge: []const u8, state: []const u8) LoginError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll(authorize_endpoint) catch return error.OutOfMemory;
    appendQuery(w, true, "response_type", "code") catch return error.OutOfMemory;
    appendQuery(w, false, "client_id", codex_session.client_id) catch return error.OutOfMemory;
    appendQuery(w, false, "redirect_uri", redirect_uri) catch return error.OutOfMemory;
    appendQuery(w, false, "scope", scope) catch return error.OutOfMemory;
    appendQuery(w, false, "code_challenge", challenge) catch return error.OutOfMemory;
    appendQuery(w, false, "code_challenge_method", "S256") catch return error.OutOfMemory;
    appendQuery(w, false, "state", state) catch return error.OutOfMemory;
    appendQuery(w, false, "id_token_add_organizations", "true") catch return error.OutOfMemory;
    appendQuery(w, false, "codex_cli_simplified_flow", "true") catch return error.OutOfMemory;
    appendQuery(w, false, "originator", "codex_cli_rs") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn awaitCallbackCode(
    alloc: Allocator,
    listener: *std.Io.net.Server,
    expected_state: []const u8,
) LoginError![]u8 {
    waitForCallback(listener.socket.handle) catch return error.CodexCallbackInvalid;

    var stream = listener.accept(io_mod.getIo()) catch return error.CodexCallbackInvalid;
    defer stream.close(io_mod.getIo());

    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var request_len: usize = 0;
    while (request_len < request_bytes.len) {
        request_bytes[request_len] = reader.interface.takeByte() catch return error.CodexCallbackInvalid;
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) break;
    }
    const line_end = std.mem.indexOf(u8, request_bytes[0..request_len], "\r\n") orelse
        return error.CodexCallbackInvalid;
    const request_line = request_bytes[0..line_end];
    if (!std.mem.startsWith(u8, request_line, "GET ")) return error.CodexCallbackInvalid;
    const target_end = std.mem.indexOfScalarPos(u8, request_line, 4, ' ') orelse
        return error.CodexCallbackInvalid;
    const target = request_line[4..target_end];
    if (!std.mem.startsWith(u8, target, "/auth/callback?")) return error.CodexCallbackInvalid;

    var response = mcp_auth.parseAuthorizationRedirect(alloc, target) catch return error.CodexCallbackInvalid;
    defer response.deinit(alloc);

    const state_ok = std.mem.eql(u8, response.state, expected_state);
    try writeCallbackPage(&stream, state_ok);
    if (!state_ok) return error.CodexStateMismatch;
    return alloc.dupe(u8, response.code) catch error.OutOfMemory;
}

fn writeCallbackPage(stream: *std.Io.net.Stream, ok: bool) LoginError!void {
    const body = if (ok)
        "fx is signed in to Codex. You can close this tab and return to the terminal."
    else
        "Sign-in failed: state mismatch. Close this tab and run `fx codex login` again.";
    var writer_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &writer_buffer);
    writer.interface.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    ) catch return error.CodexCallbackInvalid;
    writer.interface.flush() catch {};
}

fn exchangeCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    code: []const u8,
    verifier: []const u8,
) LoginError!codex_session.Session {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    const w = &body.writer;
    appendForm(w, true, "grant_type", "authorization_code") catch return error.OutOfMemory;
    appendForm(w, false, "code", code) catch return error.OutOfMemory;
    appendForm(w, false, "redirect_uri", redirect_uri) catch return error.OutOfMemory;
    appendForm(w, false, "client_id", codex_session.client_id) catch return error.OutOfMemory;
    appendForm(w, false, "code_verifier", verifier) catch return error.OutOfMemory;

    var response = transport.execute(alloc, .{
        .method = .post_form,
        .url = codex_session.token_endpoint,
        .payload = body.written(),
    }) catch return error.CodexTokenExchangeFailed;
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.CodexTokenExchangeFailed;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response.body, .{}) catch return error.CodexTokenExchangeFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CodexTokenExchangeFailed;
    const access = stringField(parsed.value.object, "access_token") orelse return error.CodexTokenExchangeFailed;
    const refresh = stringField(parsed.value.object, "refresh_token") orelse return error.CodexTokenExchangeFailed;

    var session = codex_session.sessionFromTokens(alloc, access, refresh) catch return error.CodexTokenExchangeFailed;
    errdefer session.deinit(alloc);
    try codex_session.save(alloc, session);
    return session;
}

fn waitForCallback(handle: std.posix.socket_t) !void {
    var remaining_ms: i64 = @as(i64, callback_timeout_seconds) * 1000;
    const wait_ms: i32 = 200;
    while (remaining_ms > 0) {
        var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&fds, wait_ms);
        if (ready > 0) {
            if ((fds[0].revents & std.posix.POLL.IN) == 0) return error.CodexCallbackInvalid;
            return;
        }
        remaining_ms -= wait_ms;
    }
    return error.CodexCallbackInvalid;
}

fn appendQuery(w: *std.Io.Writer, first: bool, key: []const u8, value: []const u8) !void {
    try w.writeByte(if (first) '?' else '&');
    try w.writeAll(key);
    try w.writeByte('=');
    try percentEncode(w, value);
}

fn appendForm(w: *std.Io.Writer, first: bool, key: []const u8, value: []const u8) !void {
    if (!first) try w.writeByte('&');
    try w.writeAll(key);
    try w.writeByte('=');
    try percentEncode(w, value);
}

fn percentEncode(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try w.writeByte(byte);
        } else {
            try w.writeByte('%');
            try w.writeByte(hex[byte >> 4]);
            try w.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn stringField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = root.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

test "authorize url carries pkce, state, and the codex flow params" {
    const alloc = std.testing.allocator;
    const url = try buildAuthorizeUrl(alloc, "chal-123", "state-xyz");
    defer alloc.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://auth.openai.com/oauth/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=app_EMoamEEZ73f0CkXaXp7hrann") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=chal-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=state-xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "codex_cli_simplified_flow=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "originator=codex_cli_rs") != null);
    // scope space is percent-encoded.
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=openid%20profile%20email%20offline_access") != null);
}
