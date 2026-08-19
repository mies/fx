//! OpenAI Codex ChatGPT-subscription OAuth session.
//!
//! EXPERIMENTAL / PERSONAL USE. Codex subscription auth talks to OpenAI's
//! internal `chatgpt.com/backend-api/codex` endpoint by presenting the
//! official Codex client id. OpenAI does not document or sanction third-party
//! clients using it; this exists for a user's own ChatGPT subscription only.
//!
//! This module owns the session shape, its `~/.fx/codex-auth.json` storage
//! (0600, like `~/.fx/auth.json`), JWT-claim extraction (account id, plan,
//! expiry), refresh-token rotation against `auth.openai.com`, and importing an
//! existing session from the official Codex CLI (`~/.codex/auth.json`) or pi
//! (`~/.pi/agent/auth.json`).
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const oauth_transport = @import("oauth_transport.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

/// The public Codex CLI client id, reused by every third-party client.
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const token_endpoint = "https://auth.openai.com/oauth/token";
pub const file_name = "codex-auth.json";
const schema_version = 1;
const max_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 5 * 60 * 1000;
const auth_claim = "https://api.openai.com/auth";

pub const Error = error{
    CodexSessionInvalid,
    CodexSessionMissingAccount,
    CodexRefreshFailed,
    HomeNotSet,
    CodexSessionWriteFailed,
} || Allocator.Error;

pub const Session = struct {
    access_token: []u8,
    refresh_token: []u8,
    /// Absolute expiry in ms; derived from the access-token `exp` claim.
    expires_at_ms: i64,
    account_id: []u8,
    /// ChatGPT plan type for display (may be empty).
    plan_type: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.account_id);
        alloc.free(self.plan_type);
        self.* = undefined;
    }

    pub fn needsRefresh(self: Session, now_ms: i64) bool {
        return self.expires_at_ms -| expiry_skew_ms <= now_ms;
    }
};

/// Decodes a JWT payload (segment 1) as an owned JSON object. Caller calls
/// `.deinit()`. Errors if the token is not a well-formed three-segment JWT.
fn decodeJwtClaims(alloc: Allocator, token: []const u8) !std.json.Parsed(std.json.Value) {
    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next() orelse return error.CodexSessionInvalid;
    const payload_b64 = it.next() orelse return error.CodexSessionInvalid;
    if (payload_b64.len == 0) return error.CodexSessionInvalid;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return error.CodexSessionInvalid;
    const buf = try alloc.alloc(u8, decoded_len);
    defer alloc.free(buf);
    decoder.decode(buf, payload_b64) catch return error.CodexSessionInvalid;

    return std.json.parseFromSlice(std.json.Value, alloc, buf, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CodexSessionInvalid,
    };
}

const TokenFacts = struct {
    account_id: []u8,
    plan_type: []u8,
    expires_at_ms: i64,
};

/// Extracts account id (required), plan type, and expiry from an access-token
/// JWT. `fallback_account_id` is used when the claim is absent (e.g. some
/// import sources carry it as a separate field).
fn tokenFacts(alloc: Allocator, access_token: []const u8, fallback_account_id: ?[]const u8) !TokenFacts {
    var parsed = try decodeJwtClaims(alloc, access_token);
    defer parsed.deinit();
    if (parsed.value != .object) return error.CodexSessionInvalid;
    const root = parsed.value.object;

    var account: ?[]const u8 = fallback_account_id;
    var plan: []const u8 = "";
    if (root.get(auth_claim)) |auth_value| {
        if (auth_value == .object) {
            if (auth_value.object.get("chatgpt_account_id")) |v| {
                if (v == .string and v.string.len > 0) account = v.string;
            }
            if (auth_value.object.get("chatgpt_plan_type")) |v| {
                if (v == .string) plan = v.string;
            }
        }
    }
    const resolved_account = account orelse return error.CodexSessionMissingAccount;
    if (resolved_account.len == 0) return error.CodexSessionMissingAccount;

    var expires_at_ms: i64 = 0;
    if (root.get("exp")) |exp_value| {
        if (exp_value == .integer) expires_at_ms = exp_value.integer * 1000;
    }

    const account_owned = try alloc.dupe(u8, resolved_account);
    errdefer alloc.free(account_owned);
    const plan_owned = try alloc.dupe(u8, plan);
    return .{
        .account_id = account_owned,
        .plan_type = plan_owned,
        .expires_at_ms = expires_at_ms,
    };
}

fn buildSession(
    alloc: Allocator,
    access_token: []const u8,
    refresh_token: []const u8,
    fallback_account_id: ?[]const u8,
    explicit_expiry_ms: ?i64,
) !Session {
    const facts = try tokenFacts(alloc, access_token, fallback_account_id);
    errdefer {
        alloc.free(facts.account_id);
        alloc.free(facts.plan_type);
    }
    const access_owned = try alloc.dupe(u8, access_token);
    errdefer secret.zeroAndFree(alloc, access_owned);
    const refresh_owned = try alloc.dupe(u8, refresh_token);
    errdefer secret.zeroAndFree(alloc, refresh_owned);
    return .{
        .access_token = access_owned,
        .refresh_token = refresh_owned,
        .expires_at_ms = explicit_expiry_ms orelse facts.expires_at_ms,
        .account_id = facts.account_id,
        .plan_type = facts.plan_type,
    };
}

/// Builds a session from freshly issued tokens (login / refresh). Derives the
/// account id, plan, and expiry from the access-token JWT. Owned by caller.
pub fn sessionFromTokens(
    alloc: Allocator,
    access_token: []const u8,
    refresh_token: []const u8,
) Error!Session {
    return buildSession(alloc, access_token, refresh_token, null, null);
}

/// Extracts the ChatGPT account id from an access-token JWT. Owned by caller.
pub fn accountId(alloc: Allocator, access_token: []const u8) Error![]u8 {
    const facts = try tokenFacts(alloc, access_token, null);
    alloc.free(facts.plan_type);
    return facts.account_id;
}

/// Resolves the account id for a live request: the access-token JWT claim
/// first, then the stored session's saved account id (import sources may keep
/// it only in the file, not the JWT). Owned by caller; null if unresolvable.
pub fn resolveAccountId(alloc: Allocator, access_token: []const u8) ?[]u8 {
    if (accountId(alloc, access_token)) |id| return id else |_| {}
    var session = (load(alloc) catch null) orelse return null;
    defer session.deinit(alloc);
    if (session.account_id.len == 0) return null;
    return alloc.dupe(u8, session.account_id) catch null;
}

// --- fx storage (~/.fx/codex-auth.json) ------------------------------------

pub fn load(alloc: Allocator) Error!?Session {
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch return null;
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir);
}

pub fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) Error!?Session {
    const maybe_bytes = readPrivateFile(alloc, fx_dir, file_name) catch return null;
    const bytes = maybe_bytes orelse return null;
    defer secret.zeroAndFree(alloc, bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    const access = stringField(root, "access_token") orelse return null;
    const refresh_tok = stringField(root, "refresh_token") orelse return null;
    const account = stringField(root, "account_id");
    var explicit_expiry: ?i64 = null;
    if (root.get("expires_at_ms")) |v| {
        if (v == .integer) explicit_expiry = v.integer;
    }
    return buildSession(alloc, access, refresh_tok, account, explicit_expiry) catch return null;
}

pub fn save(alloc: Allocator, session: Session) Error!void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var fx_dir = openOrCreateProfileDir(home) catch return error.CodexSessionWriteFailed;
    defer fx_dir.close();
    return saveToDir(alloc, &fx_dir, session);
}

pub fn saveToDir(alloc: Allocator, fx_dir: *io_mod.VerifiedDir, session: Session) Error!void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll("{\"version\":") catch return error.CodexSessionWriteFailed;
    w.print("{d}", .{schema_version}) catch return error.CodexSessionWriteFailed;
    writeJsonStringField(w, ",\"access_token\":", session.access_token) catch return error.CodexSessionWriteFailed;
    writeJsonStringField(w, ",\"refresh_token\":", session.refresh_token) catch return error.CodexSessionWriteFailed;
    writeJsonStringField(w, ",\"account_id\":", session.account_id) catch return error.CodexSessionWriteFailed;
    writeJsonStringField(w, ",\"plan_type\":", session.plan_type) catch return error.CodexSessionWriteFailed;
    w.print(",\"expires_at_ms\":{d}}}", .{session.expires_at_ms}) catch return error.CodexSessionWriteFailed;

    io_mod.durableReplaceVerified(alloc, fx_dir, file_name, out.written()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CodexSessionWriteFailed,
    };
}

/// Removes the stored session file. Returns whether a file was deleted.
pub fn remove(alloc: Allocator) Error!bool {
    _ = alloc;
    const home = io_mod.getenv("HOME") orelse return false;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch return false;
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return false;
    defer fx_dir.close(io_mod.getIo());
    fx_dir.deleteFile(io_mod.getIo(), file_name) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    return true;
}

// --- refresh ---------------------------------------------------------------

/// Refreshes and persists the session, rotating the refresh token. Returns the
/// updated session (the input is deinit'd on success).
pub fn refresh(alloc: Allocator, transport: oauth_transport.Provider, session: *Session) Error!Session {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    appendForm(&body.writer, true, "client_id", client_id) catch return error.CodexRefreshFailed;
    appendForm(&body.writer, false, "grant_type", "refresh_token") catch return error.CodexRefreshFailed;
    appendForm(&body.writer, false, "refresh_token", session.refresh_token) catch return error.CodexRefreshFailed;

    var response = transport.execute(alloc, .{
        .method = .post_form,
        .url = token_endpoint,
        .payload = body.written(),
    }) catch return error.CodexRefreshFailed;
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        debug_trace.logf("codex", "refresh rejected", .{});
        return error.CodexRefreshFailed;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response.body, .{}) catch return error.CodexRefreshFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CodexRefreshFailed;
    const root = parsed.value.object;
    const new_access = stringField(root, "access_token") orelse return error.CodexRefreshFailed;
    // Refresh tokens rotate; fall back to the current one only if absent.
    const new_refresh = stringField(root, "refresh_token") orelse session.refresh_token;

    var refreshed = buildSession(alloc, new_access, new_refresh, session.account_id, null) catch return error.CodexRefreshFailed;
    errdefer refreshed.deinit(alloc);
    try save(alloc, refreshed);
    session.deinit(alloc);
    return refreshed;
}

/// Returns a valid session, refreshing and persisting it first if expired.
pub fn loadValid(alloc: Allocator, transport: oauth_transport.Provider) Error!?Session {
    var session = (try load(alloc)) orelse return null;
    if (!session.needsRefresh(io_mod.milliTimestamp())) return session;
    // refresh() consumes (deinits) `session` on success and returns without
    // error; on any failure it leaves `session` owned by us, so this errdefer
    // zeroes and frees the secret tokens rather than leaking them.
    errdefer session.deinit(alloc);
    return try refresh(alloc, transport, &session);
}

// --- import ----------------------------------------------------------------

pub const ImportSource = enum { codex_cli, pi };

pub fn importFrom(alloc: Allocator, source: ImportSource) Error!?Session {
    const home = io_mod.getenv("HOME") orelse return null;
    const rel = switch (source) {
        .codex_cli => ".codex/auth.json",
        .pi => ".pi/agent/auth.json",
    };
    const path = std.fs.path.join(alloc, &.{ home, rel }) catch return error.OutOfMemory;
    defer alloc.free(path);

    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{ .mode = .read_only }) catch return null;
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch return null;
    defer secret.zeroAndFree(alloc, bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    return switch (source) {
        .codex_cli => sessionFromCodexCli(alloc, parsed.value.object),
        .pi => sessionFromPi(alloc, parsed.value.object),
    };
}

/// Imports whichever known source exists, preferring the official Codex CLI.
pub fn importAny(alloc: Allocator) Error!?Session {
    if (try importFrom(alloc, .codex_cli)) |session| return session;
    return try importFrom(alloc, .pi);
}

fn sessionFromCodexCli(alloc: Allocator, root: std.json.ObjectMap) Error!?Session {
    const tokens_value = root.get("tokens") orelse return null;
    if (tokens_value != .object) return null;
    const tokens = tokens_value.object;
    const access = stringField(tokens, "access_token") orelse return null;
    const refresh_token = stringField(tokens, "refresh_token") orelse return null;
    const account = stringField(tokens, "account_id");
    return buildSession(alloc, access, refresh_token, account, null) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn sessionFromPi(alloc: Allocator, root: std.json.ObjectMap) Error!?Session {
    const codex_value = root.get("openai-codex") orelse return null;
    if (codex_value != .object) return null;
    const codex = codex_value.object;
    const access = stringField(codex, "access") orelse return null;
    const refresh_token = stringField(codex, "refresh") orelse return null;
    const account = stringField(codex, "accountId");
    var explicit_expiry: ?i64 = null;
    if (codex.get("expires")) |v| {
        if (v == .integer) explicit_expiry = v.integer;
    }
    return buildSession(alloc, access, refresh_token, account, explicit_expiry) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

// --- helpers ---------------------------------------------------------------

fn stringField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = root.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

fn appendForm(w: *std.Io.Writer, first: bool, key: []const u8, value: []const u8) !void {
    if (!first) try w.writeAll("&");
    try w.writeAll(key);
    try w.writeAll("=");
    for (value) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (safe) {
            try w.writeByte(byte);
        } else {
            const hex = "0123456789ABCDEF";
            try w.writeByte('%');
            try w.writeByte(hex[byte >> 4]);
            try w.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn writeJsonStringField(w: *std.Io.Writer, prefix: []const u8, value: []const u8) !void {
    try w.writeAll(prefix);
    try std.json.Stringify.value(value, .{}, w);
}

fn readPrivateFile(alloc: Allocator, dir: *std.Io.Dir, name: []const u8) !?[]u8 {
    var file = dir.openFile(io_mod.getIo(), name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return null;
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("codex", "session file refused: insecure permissions", .{});
        return null;
    }
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

fn openOrCreateProfileDir(home: []const u8) !io_mod.VerifiedDir {
    var home_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true });
    defer home_dir.close(io_mod.getIo());
    return io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, profile_paths.root_dir_name);
}

// --- tests -----------------------------------------------------------------

// A minimal HS256-style JWT (unsigned payload is all we read). Payload:
// {"exp":2000000000,"https://api.openai.com/auth":{"chatgpt_account_id":"acc-123","chatgpt_plan_type":"plus"}}
fn makeTestJwt(alloc: Allocator, payload_json: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header = "eyJhbGciOiJub25lIn0"; // {"alg":"none"}
    const payload_buf = try alloc.alloc(u8, enc.calcSize(payload_json.len));
    defer alloc.free(payload_buf);
    const payload = enc.encode(payload_buf, payload_json);
    return std.fmt.allocPrint(alloc, "{s}.{s}.sig", .{ header, payload });
}

test "token facts extract account, plan, and expiry from access JWT" {
    const alloc = std.testing.allocator;
    const jwt = try makeTestJwt(alloc,
        \\{"exp":2000000000,"https://api.openai.com/auth":{"chatgpt_account_id":"acc-123","chatgpt_plan_type":"plus"}}
    );
    defer alloc.free(jwt);

    const facts = try tokenFacts(alloc, jwt, null);
    defer {
        alloc.free(facts.account_id);
        alloc.free(facts.plan_type);
    }
    try std.testing.expectEqualStrings("acc-123", facts.account_id);
    try std.testing.expectEqualStrings("plus", facts.plan_type);
    try std.testing.expectEqual(@as(i64, 2000000000 * 1000), facts.expires_at_ms);
}

test "token facts fall back to a supplied account id when the claim is absent" {
    const alloc = std.testing.allocator;
    const jwt = try makeTestJwt(alloc, "{\"exp\":1000}");
    defer alloc.free(jwt);

    const facts = try tokenFacts(alloc, jwt, "fallback-acc");
    defer {
        alloc.free(facts.account_id);
        alloc.free(facts.plan_type);
    }
    try std.testing.expectEqualStrings("fallback-acc", facts.account_id);
    try std.testing.expectEqualStrings("", facts.plan_type);

    try std.testing.expectError(error.CodexSessionMissingAccount, tokenFacts(alloc, jwt, null));
}

test "malformed tokens are rejected" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.CodexSessionInvalid, tokenFacts(alloc, "not-a-jwt", "x"));
    try std.testing.expectError(error.CodexSessionInvalid, tokenFacts(alloc, "only.two", "x"));
}

test "codex cli and pi import shapes both parse" {
    const alloc = std.testing.allocator;
    const jwt = try makeTestJwt(alloc,
        \\{"exp":2000000000,"https://api.openai.com/auth":{"chatgpt_account_id":"acc-9","chatgpt_plan_type":"pro"}}
    );
    defer alloc.free(jwt);

    const cli_json = try std.fmt.allocPrint(alloc,
        \\{{"OPENAI_API_KEY":null,"tokens":{{"access_token":"{s}","refresh_token":"rt-1","account_id":"acc-9","id_token":"x"}}}}
    , .{jwt});
    defer alloc.free(cli_json);
    var cli_parsed = try std.json.parseFromSlice(std.json.Value, alloc, cli_json, .{});
    defer cli_parsed.deinit();
    var cli_session = (try sessionFromCodexCli(alloc, cli_parsed.value.object)).?;
    defer cli_session.deinit(alloc);
    try std.testing.expectEqualStrings("acc-9", cli_session.account_id);
    try std.testing.expectEqualStrings("rt-1", cli_session.refresh_token);
    try std.testing.expectEqualStrings("pro", cli_session.plan_type);

    const pi_json = try std.fmt.allocPrint(alloc,
        \\{{"openai-codex":{{"type":"oauth","access":"{s}","refresh":"rt-2","accountId":"acc-9","expires":123456789}}}}
    , .{jwt});
    defer alloc.free(pi_json);
    var pi_parsed = try std.json.parseFromSlice(std.json.Value, alloc, pi_json, .{});
    defer pi_parsed.deinit();
    var pi_session = (try sessionFromPi(alloc, pi_parsed.value.object)).?;
    defer pi_session.deinit(alloc);
    try std.testing.expectEqualStrings("rt-2", pi_session.refresh_token);
    try std.testing.expectEqual(@as(i64, 123456789), pi_session.expires_at_ms);
}

test "session round-trips through the fx store at mode 0600" {
    const alloc = std.testing.allocator;
    const jwt = try makeTestJwt(alloc,
        \\{"exp":2000000000,"https://api.openai.com/auth":{"chatgpt_account_id":"acc-rt","chatgpt_plan_type":"plus"}}
    );
    defer alloc.free(jwt);
    var session = try buildSession(alloc, jwt, "refresh-secret", null, null);
    defer session.deinit(alloc);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer fx_dir.close();

    try saveToDir(alloc, &fx_dir, session);
    const stat = try tmp.dir.statFile(std.testing.io, file_name, .{});
    try std.testing.expect(stat.permissions.toMode() & 0o777 == 0o600);

    var loaded = (try loadFromDir(alloc, &fx_dir.dir)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("acc-rt", loaded.account_id);
    try std.testing.expectEqualStrings("refresh-secret", loaded.refresh_token);
    try std.testing.expectEqualStrings(session.access_token, loaded.access_token);
}
