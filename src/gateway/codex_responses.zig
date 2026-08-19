//! OpenAI Responses-API request construction for the Codex ChatGPT-subscription
//! backend (chatgpt.com/backend-api/codex/responses).
//!
//! EXPERIMENTAL / personal use. This is a different wire format from Phase 1's
//! chat/completions (openai_compat.zig): system prompts become top-level
//! `instructions`, history becomes typed `input[]` items, and `store:false` +
//! `include:["reasoning.encrypted_content"]` are mandatory. v1 does NOT replay
//! encrypted reasoning across turns (valid but the model re-reasons each turn),
//! and strips all client-fabricated item ids so server-side pairing validation
//! passes — it sends `call_id` only, never `id`.
const std = @import("std");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const BuildError = error{
    UnsupportedCodexRequest,
    InvalidSerializedTools,
    OutOfMemory,
};

/// Builds a streaming Codex Responses request body. Returned bytes owned by
/// `alloc`. Image, structured-output, and forced-vision shapes are rejected —
/// v1 covers text + tool calling.
pub fn buildResponsesRequest(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
) BuildError![]u8 {
    if (request.vision_mode == .required or
        request.verified_images != null or
        request.response_format != null)
    {
        return error.UnsupportedCodexRequest;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeBody(alloc, &out.writer, request) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSerializedTools => return error.InvalidSerializedTools,
    };
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const WriteError = error{ WriteFailed, OutOfMemory, InvalidSerializedTools };

fn writeBody(
    alloc: Allocator,
    w: *std.Io.Writer,
    request: agent_stream_provider.BuildRequest,
) WriteError!void {
    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, w);

    try writeInstructions(alloc, w, request.messages);

    try w.writeAll(",\"input\":[");
    var first = true;
    for (request.messages) |message| {
        if (message.role == .system) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try writeInputItem(w, message);
    }
    try w.writeAll("]");

    try writeTools(alloc, w, request);
    try writeReasoning(w, request.provider_options);

    try w.writeAll(
        ",\"tool_choice\":\"auto\",\"parallel_tool_calls\":true," ++
            "\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"]}",
    );
}

fn writeInstructions(
    alloc: Allocator,
    w: *std.Io.Writer,
    messages: []const types.ChatMessage,
) WriteError!void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (joined.items.len > 0) try joined.appendSlice(alloc, "\n\n");
        try joined.appendSlice(alloc, text);
    }
    if (joined.items.len == 0) return;
    try w.writeAll(",\"instructions\":");
    try std.json.Stringify.value(joined.items, .{}, w);
}

fn writeInputItem(w: *std.Io.Writer, message: types.ChatMessage) WriteError!void {
    switch (message.role) {
        .system => unreachable,
        .user => {
            try w.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try std.json.Stringify.value(message.content orelse "", .{}, w);
            try w.writeAll("}]}");
        },
        .assistant => {
            // Emit the assistant text (if any) as its own message item, then
            // each tool call as a function_call item (call_id only, no id).
            var wrote = false;
            if (message.content) |content| {
                if (content.len > 0) {
                    try w.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, w);
                    try w.writeAll("}]}");
                    wrote = true;
                }
            }
            for (message.tool_calls) |call| {
                if (wrote) try w.writeByte(',');
                wrote = true;
                try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
                try std.json.Stringify.value(call.id, .{}, w);
                try w.writeAll(",\"name\":");
                try std.json.Stringify.value(call.name, .{}, w);
                try w.writeAll(",\"arguments\":");
                try std.json.Stringify.value(call.arguments_json, .{}, w);
                try w.writeAll("}");
            }
            // An assistant turn with neither text nor tool calls still needs a
            // placeholder so the input array stays well-formed.
            if (!wrote) {
                try w.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"\"}]}");
            }
        },
        .tool => {
            try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, w);
            try w.writeAll(",\"output\":");
            try std.json.Stringify.value(message.content orelse "", .{}, w);
            try w.writeAll("}");
        },
    }
}

fn writeTools(
    alloc: Allocator,
    w: *std.Io.Writer,
    request: agent_stream_provider.BuildRequest,
) WriteError!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var wrote_any = false;
    try writeToolListJson(arena, w, request.serialized_tools, &wrote_any);
    for (request.selected_dynamic_tool_schemas) |schema| {
        try writeToolObjectJson(arena, w, schema, &wrote_any);
    }
    if (wrote_any) try w.writeByte(']');
}

fn writeToolListJson(
    arena: Allocator,
    w: *std.Io.Writer,
    serialized: []const u8,
    wrote_any: *bool,
) WriteError!void {
    if (serialized.len == 0) return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, serialized, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSerializedTools,
    };
    if (parsed != .array) return error.InvalidSerializedTools;
    for (parsed.array.items) |entry| try writeToolValue(w, entry, wrote_any);
}

fn writeToolObjectJson(
    arena: Allocator,
    w: *std.Io.Writer,
    serialized: []const u8,
    wrote_any: *bool,
) WriteError!void {
    if (serialized.len == 0) return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, serialized, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSerializedTools,
    };
    try writeToolValue(w, parsed, wrote_any);
}

/// Translates a gateway function-tool entry
/// (`{type:"function",name,description,inputSchema}`) into a Responses flat
/// tool (`{type:"function",name,description,strict:false,parameters}`).
/// Non-function (provider-executed) entries are skipped.
fn writeToolValue(w: *std.Io.Writer, entry: std.json.Value, wrote_any: *bool) WriteError!void {
    if (entry != .object) return;
    const tool_type = entry.object.get("type") orelse return;
    if (tool_type != .string or !std.mem.eql(u8, tool_type.string, "function")) return;
    const name = entry.object.get("name") orelse return;
    if (name != .string) return;

    if (!wrote_any.*) {
        try w.writeAll(",\"tools\":[");
        wrote_any.* = true;
    } else {
        try w.writeByte(',');
    }
    try w.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name.string, .{}, w);
    if (entry.object.get("description")) |description| {
        if (description == .string) {
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(description.string, .{}, w);
        }
    }
    try w.writeAll(",\"strict\":false,\"parameters\":");
    if (entry.object.get("inputSchema")) |schema| {
        try std.json.Stringify.value(schema, .{}, w);
    } else {
        try w.writeAll("{\"type\":\"object\",\"properties\":{}}");
    }
    try w.writeAll("}");
}

fn writeReasoning(w: *std.Io.Writer, options: anytype) WriteError!void {
    const reasoning = options.reasoning orelse return;
    // Only a named effort maps to a Codex effort; `.auto` lets the backend
    // pick its per-model default.
    switch (reasoning) {
        .auto => return,
        .named => {},
    }
    const label = codexEffort(reasoning.label());
    try w.writeAll(",\"reasoning\":{\"effort\":");
    try std.json.Stringify.value(label, .{}, w);
    try w.writeAll(",\"summary\":\"auto\"}");
}

/// The ChatGPT backend rejects `minimal` for most models; normalize it to
/// `low`. Other values pass through.
fn codexEffort(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "minimal")) return "low";
    return label;
}

pub const default_base_url = "https://chatgpt.com/backend-api/codex/responses";
pub const originator = "codex_cli_rs";
pub const openai_beta = "responses=experimental";

// --- tests -----------------------------------------------------------------

fn testRequest(
    messages: []const types.ChatMessage,
    tools: []const u8,
) agent_stream_provider.BuildRequest {
    return .{
        .model = "gpt-5.2-codex",
        .serialized_tools = tools,
        .messages = messages,
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

test "responses body maps instructions, roles, tool calls, and results" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "be brief" },
        .{ .role = .system, .content = "stay safe" },
        .{ .role = .user, .content = "list \"files\"" },
        .{ .role = .assistant, .content = "checking", .tool_calls = &.{.{
            .id = "call_1",
            .name = "list_files",
            .arguments_json = "{\"path\":\".\"}",
        }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "a.txt" },
    };
    const body = try buildResponsesRequest(alloc, testRequest(&messages, ""));
    defer alloc.free(body);

    // Instructions concatenate both system messages.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"be brief\\n\\nstay safe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"input_text\",\"text\":\"list \\\"files\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"output_text\",\"text\":\"checking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"list_files\"") != null);
    // No client-fabricated item id is sent.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"call_1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"a.txt\"") != null);
    // Mandatory Responses constraints.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "responses body translates gateway tools and reasoning effort" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const tools =
        "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\"," ++
        "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}," ++
        "{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\"}]";
    var request = testRequest(&messages, tools);
    request.provider_options = .{ .reasoning = types.ReasoningEffort.literal("minimal") };
    const body = try buildResponsesRequest(alloc, request);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"strict\":false,\"parameters\":") != null);
    // Provider-executed tool is skipped.
    try std.testing.expect(std.mem.indexOf(u8, body, "perplexity") == null);
    // minimal normalizes to low.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"low\",\"summary\":\"auto\"}") != null);
}

test "responses body rejects vision and structured shapes" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    var vision = testRequest(&messages, "");
    vision.vision_mode = .required;
    try std.testing.expectError(error.UnsupportedCodexRequest, buildResponsesRequest(alloc, vision));
}
