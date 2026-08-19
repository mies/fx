//! OpenAI-compatible chat/completions request construction for direct
//! providers (z.ai coding plan, OpenCode Go). The Vercel AI Gateway keeps its
//! own wire format in core/gateway/gateway_json.zig; this module translates
//! the protocol-neutral BuildRequest into the OpenAI chat.completions shape.
const std = @import("std");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const BuildError = error{
    UnsupportedDirectProviderRequest,
    InvalidSerializedTools,
    OutOfMemory,
};

/// Builds an OpenAI chat/completions streaming request body. The returned
/// bytes are owned by `alloc`. Image, structured-output, and forced-vision
/// requests are rejected: direct providers advertise no vision or file-input
/// capability, so the agent runtime never routes those shapes here on the
/// happy path.
pub fn buildChatCompletionsRequest(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
) BuildError![]u8 {
    if (request.vision_mode == .required or
        request.verified_images != null or
        request.response_format != null)
    {
        return error.UnsupportedDirectProviderRequest;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;

    writeBody(alloc, writer, request) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSerializedTools => return error.InvalidSerializedTools,
    };
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

const WriteError = error{ WriteFailed, OutOfMemory, InvalidSerializedTools };

fn writeBody(
    alloc: Allocator,
    writer: *std.Io.Writer,
    request: agent_stream_provider.BuildRequest,
) WriteError!void {
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);

    try writer.writeAll(",\"messages\":[");
    var first = true;
    for (request.messages) |message| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writeMessage(writer, message);
    }
    try writer.writeAll("]");

    try writeTools(alloc, writer, request);

    if (request.max_output_tokens) |max_tokens| {
        try writer.print(",\"max_tokens\":{d}", .{max_tokens});
    }
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}}");
}

fn writeMessage(writer: *std.Io.Writer, message: types.ChatMessage) WriteError!void {
    switch (message.role) {
        .system => {
            try writer.writeAll("{\"role\":\"system\",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            try writer.writeByte('}');
        },
        .user => {
            try writer.writeAll("{\"role\":\"user\",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            try writer.writeByte('}');
        },
        .assistant => {
            try writer.writeAll("{\"role\":\"assistant\",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            if (message.tool_calls.len > 0) {
                try writer.writeAll(",\"tool_calls\":[");
                for (message.tool_calls, 0..) |call, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeAll("}}");
                }
                try writer.writeByte(']');
            }
            try writer.writeByte('}');
        },
        .tool => {
            try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            try writer.writeByte('}');
        },
    }
}

/// Translates the gateway-shaped tool advertisement
/// (`[{"type":"function","name":..,"description":..,"inputSchema":{..}}]`)
/// plus any selected dynamic MCP schemas into the OpenAI `tools` array.
/// Non-function entries (provider-executed tools) are skipped: direct
/// providers have no server-side tools.
fn writeTools(
    alloc: Allocator,
    writer: *std.Io.Writer,
    request: agent_stream_provider.BuildRequest,
) WriteError!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var wrote_any = false;
    try writeToolListJson(arena, writer, request.serialized_tools, &wrote_any);
    for (request.selected_dynamic_tool_schemas) |schema| {
        try writeToolObjectJson(arena, writer, schema, &wrote_any);
    }
    if (wrote_any) try writer.writeByte(']');

    if (wrote_any) {
        const choice = switch (request.tool_choice) {
            .auto => "auto",
            .none => "none",
        };
        try writer.print(",\"tool_choice\":\"{s}\"", .{choice});
    }
}

fn writeToolListJson(
    arena: Allocator,
    writer: *std.Io.Writer,
    serialized: []const u8,
    wrote_any: *bool,
) WriteError!void {
    if (serialized.len == 0) return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, serialized, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSerializedTools,
    };
    if (parsed != .array) return error.InvalidSerializedTools;
    for (parsed.array.items) |entry| {
        try writeToolValue(writer, entry, wrote_any);
    }
}

fn writeToolObjectJson(
    arena: Allocator,
    writer: *std.Io.Writer,
    serialized: []const u8,
    wrote_any: *bool,
) WriteError!void {
    if (serialized.len == 0) return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, serialized, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSerializedTools,
    };
    try writeToolValue(writer, parsed, wrote_any);
}

fn writeToolValue(
    writer: *std.Io.Writer,
    entry: std.json.Value,
    wrote_any: *bool,
) WriteError!void {
    if (entry != .object) return;
    const tool_type = entry.object.get("type") orelse return;
    if (tool_type != .string or !std.mem.eql(u8, tool_type.string, "function")) return;
    const name = entry.object.get("name") orelse return;
    if (name != .string) return;

    if (!wrote_any.*) {
        try writer.writeAll(",\"tools\":[");
        wrote_any.* = true;
    } else {
        try writer.writeByte(',');
    }
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (entry.object.get("description")) |description| {
        if (description == .string) {
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(description.string, .{}, writer);
        }
    }
    try writer.writeAll(",\"parameters\":");
    if (entry.object.get("inputSchema")) |schema| {
        try std.json.Stringify.value(schema, .{}, writer);
    } else {
        try writer.writeAll("{\"type\":\"object\",\"properties\":{}}");
    }
    try writer.writeAll("}}");
}

pub fn finishReasonFromOpenAi(raw: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length")) return .length;
    if (std.mem.eql(u8, raw, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, raw, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    return .other;
}

fn buildRequestForTest(
    messages: []const types.ChatMessage,
    serialized_tools: []const u8,
) agent_stream_provider.BuildRequest {
    return .{
        .model = "glm-5.3",
        .serialized_tools = serialized_tools,
        .messages = messages,
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

test "build maps roles, tool calls, and tool results to openai shapes" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "be brief" },
        .{ .role = .user, .content = "list \"files\"" },
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "call_1",
            .name = "list_files",
            .arguments_json = "{\"path\":\".\"}",
        }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "a.txt" },
        .{ .role = .assistant, .content = "done" },
    };
    const body = try buildChatCompletionsRequest(alloc, buildRequestForTest(&messages, ""));
    defer alloc.free(body);

    const expected =
        "{\"model\":\"glm-5.3\",\"messages\":[" ++
        "{\"role\":\"system\",\"content\":\"be brief\"}," ++
        "{\"role\":\"user\",\"content\":\"list \\\"files\\\"\"}," ++
        "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\"," ++
        "\"function\":{\"name\":\"list_files\",\"arguments\":\"{\\\"path\\\":\\\".\\\"}\"}}]}," ++
        "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"a.txt\"}," ++
        "{\"role\":\"assistant\",\"content\":\"done\"}]" ++
        ",\"stream\":true,\"stream_options\":{\"include_usage\":true}}";
    try std.testing.expectEqualStrings(expected, body);
}

test "build translates gateway tool advertisement into openai tools" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "hi" },
    };
    const tools =
        "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\"," ++
        "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}," ++
        "{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\"}]";
    var request = buildRequestForTest(&messages, tools);
    request.max_output_tokens = 900;
    const body = try buildChatCompletionsRequest(alloc, request);
    defer alloc.free(body);

    const expected =
        "{\"model\":\"glm-5.3\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]" ++
        ",\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read\"," ++
        "\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}}]" ++
        ",\"tool_choice\":\"auto\"" ++
        ",\"max_tokens\":900,\"stream\":true,\"stream_options\":{\"include_usage\":true}}";
    try std.testing.expectEqualStrings(expected, body);
}

test "build appends selected dynamic tool schemas" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const dynamic = [_][]const u8{
        "{\"type\":\"function\",\"name\":\"mcp_fs_read\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}",
    };
    var request = buildRequestForTest(&messages, "[]");
    request.selected_dynamic_tool_schemas = &dynamic;
    const body = try buildChatCompletionsRequest(alloc, request);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"mcp_fs_read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
}

test "build rejects vision and structured-output request shapes" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    var request = buildRequestForTest(&messages, "");
    request.vision_mode = .required;
    try std.testing.expectError(
        error.UnsupportedDirectProviderRequest,
        buildChatCompletionsRequest(alloc, request),
    );

    var structured = buildRequestForTest(&messages, "");
    structured.response_format = .{ .name = "n", .description = "d", .schema_json = "{}" };
    try std.testing.expectError(
        error.UnsupportedDirectProviderRequest,
        buildChatCompletionsRequest(alloc, structured),
    );
}

test "build rejects malformed serialized tools" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    try std.testing.expectError(
        error.InvalidSerializedTools,
        buildChatCompletionsRequest(alloc, buildRequestForTest(&messages, "{not json")),
    );
}

test "finish reason mapping covers openai vocabulary" {
    try std.testing.expectEqual(types.ProviderFinishReason.stop, finishReasonFromOpenAi("stop"));
    try std.testing.expectEqual(types.ProviderFinishReason.length, finishReasonFromOpenAi("length"));
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, finishReasonFromOpenAi("tool_calls"));
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, finishReasonFromOpenAi("function_call"));
    try std.testing.expectEqual(types.ProviderFinishReason.content_filter, finishReasonFromOpenAi("content_filter"));
    try std.testing.expectEqual(types.ProviderFinishReason.other, finishReasonFromOpenAi("mystery"));
}
