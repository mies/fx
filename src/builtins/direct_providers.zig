//! Direct OpenAI-compatible model providers (z.ai coding plan, OpenCode Go).
//!
//! The Vercel AI Gateway remains the default provider; a direct provider is
//! opted into per process with `FX_PROVIDER=zai|opencode` plus that
//! provider's API key environment variable. Each direct provider ships a
//! complete `gateway_provider.Provider` with a compiled-in trusted chat URL,
//! an OpenAI chat/completions build/stream pair, and a synthetic model
//! catalog so model capabilities and the picker keep working offline.
//! Unsupported capability slots (OAuth, web search, generation usage
//! reconciliation, credits) are explicit stubs.
const std = @import("std");

const agent_stream_provider_contract = @import("../core/agent/stream_provider.zig");
const gateway_client = @import("../gateway/client.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const generation_usage_provider = @import("../core/session/generation_usage_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const openai_compat = @import("../gateway/openai_compat.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const provider_selection = @import("../core/config/provider_selection.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");

const Allocator = std.mem.Allocator;

const ModelDef = struct {
    id: []const u8,
    context_window: u32 = 0,
    max_tokens: u32 = 0,
};

const Definition = struct {
    kind: provider_selection.Kind,
    chat_url: []const u8,
    default_model: []const u8,
    models: []const ModelDef,
};

/// z.ai GLM Coding Plan endpoint. Only this base path draws from the
/// subscription quota; the general paas v4 endpoint bills per token.
const zai_definition = Definition{
    .kind = .zai,
    .chat_url = "https://api.z.ai/api/coding/paas/v4/chat/completions",
    .default_model = "glm-5.3",
    .models = &.{
        .{ .id = "glm-5.3", .context_window = 1_000_000, .max_tokens = 128_000 },
        .{ .id = "glm-5-turbo" },
        .{ .id = "glm-4.7" },
    },
};

/// OpenCode Go flat-subscription endpoint (open-weight models). Zen
/// pay-as-you-go keys use the same wire protocol without the /go segment.
const opencode_definition = Definition{
    .kind = .opencode,
    .chat_url = "https://opencode.ai/zen/go/v1/chat/completions",
    .default_model = "glm-5.3",
    .models = &.{
        .{ .id = "glm-5.3" },
        .{ .id = "kimi-k3" },
        .{ .id = "qwen3.8-max" },
        .{ .id = "deepseek-v4-pro" },
        .{ .id = "minimax-m3" },
        .{ .id = "gpt-5.6-luna" },
        .{ .id = "grok-4.5" },
    },
};

pub const EntryOverrides = struct {
    kind: provider_selection.Kind,
    provider: gateway_provider.Provider,
    default_model: []const u8,
    chat_url: []const u8,
};

/// Returns the composition-root overrides for the active provider, or null
/// when the process stays on the Vercel AI Gateway.
pub fn entryOverrides() ?EntryOverrides {
    return overridesFor(provider_selection.active());
}

/// Chat URL of the active direct provider, or null on the gateway.
pub fn activeChatUrl() ?[]const u8 {
    return if (entryOverrides()) |overrides| overrides.chat_url else null;
}

/// Default model of the active direct provider, or null on the gateway.
pub fn activeDefaultModel() ?[]const u8 {
    return if (entryOverrides()) |overrides| overrides.default_model else null;
}

/// Agent stream provider of the active direct provider, or null on the gateway.
pub fn activeAgentStreamProvider() ?agent_stream_provider_contract.Provider {
    return if (entryOverrides()) |overrides| overrides.provider.agent_stream else null;
}

/// Model catalog provider of the active direct provider, or null on the gateway.
pub fn activeModelCatalogProvider() ?model_catalog.Provider {
    return if (entryOverrides()) |overrides| overrides.provider.model_catalog else null;
}

/// Credits provider of the active direct provider (an empty-snapshot stub so
/// the gateway credits endpoint never sees a direct-provider key), or null
/// on the gateway.
pub fn activeCreditsProvider() ?gateway_provider.CreditsProvider {
    return if (entryOverrides()) |overrides| overrides.provider.credits else null;
}

pub fn overridesFor(kind: provider_selection.Kind) ?EntryOverrides {
    return switch (kind) {
        .gateway => null,
        .zai => .{
            .kind = .zai,
            .provider = zai_provider,
            .default_model = zai_definition.default_model,
            .chat_url = zai_definition.chat_url,
        },
        .opencode => .{
            .kind = .opencode,
            .provider = opencode_provider,
            .default_model = opencode_definition.default_model,
            .chat_url = opencode_definition.chat_url,
        },
    };
}

const zai_provider = gateway_provider.Provider{
    .agent_stream = .{
        .build_fn = buildAgentRequest,
        .stream_fn = streamAgentCompletion,
    },
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = .{ .resolve_fn = resolveZaiChatUrl },
    .cli_model_catalog = .{ .fetch_fn = fetchZaiCliModelCatalog },
    .credits = .{ .fetch_fn = fetchCredits },
    .generation_usage = generation_usage_provider.unavailable_provider,
    .web_search = unavailable_web_search_provider,
    .model_catalog = .{ .fetch_fn = fetchZaiModelCatalog },
};

const opencode_provider = gateway_provider.Provider{
    .agent_stream = .{
        .build_fn = buildAgentRequest,
        .stream_fn = streamAgentCompletion,
    },
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = .{ .resolve_fn = resolveOpencodeChatUrl },
    .cli_model_catalog = .{ .fetch_fn = fetchOpencodeCliModelCatalog },
    .credits = .{ .fetch_fn = fetchCredits },
    .generation_usage = generation_usage_provider.unavailable_provider,
    .web_search = unavailable_web_search_provider,
    .model_catalog = .{ .fetch_fn = fetchOpencodeModelCatalog },
};

fn buildAgentRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.BuildRequest,
) anyerror![]u8 {
    return openai_compat.buildChatCompletionsRequest(alloc, request);
}

fn streamAgentCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.Request,
) anyerror!agent_stream_provider_contract.Result {
    const result = gateway_client.streamOpenAiChatCompletion(
        alloc,
        .{
            .api_key = request.api_key,
            .team = null,
            .session_id = null,
            .model = request.model,
            .retry_count = request.retry_count,
            .chat_url = request.chat_url,
            .payload = request.payload,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.content_capture_limit,
            .delivery = request.delivery,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
            .provider_attempt_owner = switch (request.provider_attempt_owner) {
                .transport => .transport,
                .agent => .agent,
            },
        },
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.cancel_flag,
    ) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
        return err;
    };
    // Failure diagnostics stay unset: the gateway collector summarizes the
    // gateway request shape, which does not describe this wire format.
    return .{
        .status = result.status,
        .completion = result.completion,
        .err_body = result.err_body,
        .generation_origin = "",
        .reconcile_generation_usage = false,
        .retry_after_seconds = result.retry_after_seconds,
        .ownership = .owned,
    };
}

fn resolveZaiChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    _ = fallback;
    return zai_definition.chat_url;
}

fn resolveOpencodeChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    _ = fallback;
    return opencode_definition.chat_url;
}

fn fetchZaiModelCatalog(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    _ = raw;
    _ = input;
    return syntheticCatalog(alloc, zai_definition);
}

fn fetchOpencodeModelCatalog(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    _ = raw;
    _ = input;
    return syntheticCatalog(alloc, opencode_definition);
}

fn syntheticCatalog(
    alloc: Allocator,
    definition: Definition,
) Allocator.Error!model_catalog.ProviderResult {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    try entries.ensureTotalCapacity(alloc, definition.models.len);
    for (definition.models) |def| {
        const id = try alloc.dupe(u8, def.id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        entries.appendAssumeCapacity(.{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
            .context_window = def.context_window,
            .max_tokens = def.max_tokens,
        });
    }
    return .{ .catalog = entries };
}

fn fetchZaiCliModelCatalog(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    _ = raw;
    return cliCatalog(alloc, zai_definition, input);
}

fn fetchOpencodeCliModelCatalog(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    _ = raw;
    return cliCatalog(alloc, opencode_definition, input);
}

fn cliCatalog(
    alloc: Allocator,
    definition: Definition,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    var ids: std.ArrayList([]u8) = .empty;
    for (definition.models) |def| {
        const id = alloc.dupe(u8, def.id) catch {
            for (ids.items) |item| alloc.free(item);
            ids.deinit(alloc);
            return .{ .failure = .{
                .access = .init(input.access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
        };
        ids.append(alloc, id) catch {
            alloc.free(id);
            for (ids.items) |item| alloc.free(item);
            ids.deinit(alloc);
            return .{ .failure = .{
                .access = .init(input.access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
        };
    }
    return .{ .loaded = .{
        .ids = ids,
        .provenance = .{ .access = .init(input.access) },
    } };
}

fn fetchCredits(
    _: ?*anyopaque,
    _: Allocator,
    _: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return .{};
}

const unavailable_web_search_policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = &.{},
    .backend_policies = &.{},
};

const unavailable_web_search_provider = web_search_provider.Provider{
    .policy = unavailable_web_search_policy,
    .preferred_backends_fn = preferredWebSearchBackends,
    .execute_fn = executeWebSearch,
};

fn preferredWebSearchBackends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
    return null;
}

fn executeWebSearch(
    _: ?*anyopaque,
    _: Allocator,
    _: web_search_provider.Inputs,
    _: web_search_contract.ProviderRequest,
    _: ?web_search_contract.ProgressFn,
    _: ?*anyopaque,
) anyerror!web_search_contract.ProviderResponse {
    return error.WebSearchUnavailable;
}

test "overrides exist for every direct provider and not for the gateway" {
    try std.testing.expect(overridesFor(.gateway) == null);
    const zai = overridesFor(.zai).?;
    try std.testing.expectEqualStrings("glm-5.3", zai.default_model);
    try std.testing.expect(std.mem.startsWith(u8, zai.chat_url, "https://api.z.ai/api/coding/paas/v4"));
    const opencode = overridesFor(.opencode).?;
    try std.testing.expect(std.mem.startsWith(u8, opencode.chat_url, "https://opencode.ai/zen/go/v1"));
}

test "synthetic catalogs advertise tool use and language models" {
    const alloc = std.testing.allocator;
    const result = try syntheticCatalog(alloc, zai_definition);
    var entries = result.catalog;
    defer model_catalog.freeModelCatalog(alloc, &entries);
    try std.testing.expectEqual(zai_definition.models.len, entries.items.len);
    try std.testing.expectEqualStrings("glm-5.3", entries.items[0].id);
    try std.testing.expect(entries.items[0].has_tool_use);
    try std.testing.expectEqual(@as(u32, 1_000_000), entries.items[0].context_window);
}

test "chat url resolvers ignore the gateway fallback" {
    try std.testing.expectEqualStrings(
        zai_definition.chat_url,
        resolveZaiChatUrl(null, "https://ai-gateway.vercel.sh/v3/ai/language-model"),
    );
    try std.testing.expectEqualStrings(
        opencode_definition.chat_url,
        resolveOpencodeChatUrl(null, "https://ai-gateway.vercel.sh/v3/ai/language-model"),
    );
}
