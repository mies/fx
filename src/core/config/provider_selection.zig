const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

/// Selects the active model provider for this process. The Vercel AI Gateway
/// remains the default; direct providers speak an OpenAI-compatible wire
/// protocol against a compiled-in trusted base URL and authenticate with a
/// per-provider API key environment variable.
pub const env_var = "FX_PROVIDER";

pub const Kind = enum {
    gateway,
    zai,
    opencode,
};

pub fn parse(text: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, text);
}

pub fn active() Kind {
    const raw = io_mod.getenv(env_var) orelse return .gateway;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return .gateway;
    return parse(trimmed) orelse {
        debug_trace.logf("config", "ignoring {s}: unknown provider value", .{env_var});
        return .gateway;
    };
}

/// Environment variable holding the API key for a direct provider.
/// The gateway resolves credentials through the auth runtime instead.
pub fn apiKeyEnvVar(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .gateway => null,
        .zai => "ZAI_API_KEY",
        .opencode => "OPENCODE_API_KEY",
    };
}

/// Guidance shown when a direct provider is selected but its key is absent.
pub fn missingKeyMessage(kind: Kind) []const u8 {
    return switch (kind) {
        .gateway => "Fx needs access to Vercel AI Gateway.",
        .zai => "FX_PROVIDER=zai is set but no Z.AI key was found. Set ZAI_API_KEY, add a \"zai\" entry to ~/.fx/provider-keys.json (valid JSON, chmod 600), or unset FX_PROVIDER to use the Vercel AI Gateway.",
        .opencode => "FX_PROVIDER=opencode is set but no OpenCode key was found. Set OPENCODE_API_KEY, add an \"opencode\" entry to ~/.fx/provider-keys.json (valid JSON, chmod 600), or unset FX_PROVIDER to use the Vercel AI Gateway.",
    };
}

pub fn label(kind: Kind) []const u8 {
    return switch (kind) {
        .gateway => "Vercel AI Gateway",
        .zai => "Z.AI",
        .opencode => "OpenCode",
    };
}

test "parse accepts exact provider names only" {
    try std.testing.expectEqual(@as(?Kind, .zai), parse("zai"));
    try std.testing.expectEqual(@as(?Kind, .opencode), parse("opencode"));
    try std.testing.expectEqual(@as(?Kind, .gateway), parse("gateway"));
    try std.testing.expectEqual(@as(?Kind, null), parse("z.ai"));
    try std.testing.expectEqual(@as(?Kind, null), parse("ZAI"));
    try std.testing.expectEqual(@as(?Kind, null), parse(""));
}

test "direct providers declare an api key environment variable" {
    try std.testing.expectEqual(@as(?[]const u8, null), apiKeyEnvVar(.gateway));
    try std.testing.expectEqualStrings("ZAI_API_KEY", apiKeyEnvVar(.zai).?);
    try std.testing.expectEqualStrings("OPENCODE_API_KEY", apiKeyEnvVar(.opencode).?);
}
