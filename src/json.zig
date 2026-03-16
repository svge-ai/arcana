const std = @import("std");
const message_mod = @import("message.zig");
const model_mod = @import("model.zig");
const Message = message_mod.Message;
const Role = message_mod.Role;
const ToolCallInfo = message_mod.ToolCallInfo;
const ToolInfo = model_mod.ToolInfo;
const Call = model_mod.Call;
const Response = model_mod.Response;
const ToolCallResult = model_mod.ToolCallResult;
const FinishReason = model_mod.FinishReason;
const Usage = model_mod.Usage;
const Allocator = std.mem.Allocator;

/// Build the JSON request body for the OpenAI chat completions API.
pub fn buildRequestBody(
    allocator: Allocator,
    model_id: []const u8,
    call: Call,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"model\":\"");
    try writeJsonEscaped(writer, model_id);
    try writer.writeAll("\",\"messages\":[");

    for (call.messages, 0..) |msg, i| {
        if (i > 0) try writer.writeByte(',');
        try writeMessage(writer, msg);
    }
    try writer.writeByte(']');

    // Tools
    if (call.tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (call.tools, 0..) |tool_info, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
            try writeJsonEscaped(writer, tool_info.name);
            try writer.writeAll("\",\"description\":\"");
            try writeJsonEscaped(writer, tool_info.description);
            try writer.writeAll("\",\"parameters\":");
            try writer.writeAll(tool_info.input_schema);
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
        try writer.writeAll(",\"tool_choice\":\"auto\"");
    }

    // Temperature
    if (call.temperature) |temp| {
        try writer.writeAll(",\"temperature\":");
        try std.fmt.format(writer, "{d}", .{temp});
    }

    // Max tokens
    if (call.max_output_tokens) |max_tokens| {
        try writer.writeAll(",\"max_tokens\":");
        try std.fmt.format(writer, "{d}", .{max_tokens});
    }

    // Top P
    if (call.top_p) |top_p| {
        try writer.writeAll(",\"top_p\":");
        try std.fmt.format(writer, "{d}", .{top_p});
    }

    try writer.writeByte('}');

    return buf.toOwnedSlice(allocator);
}

fn writeMessage(writer: anytype, msg: Message) !void {
    try writer.writeAll("{\"role\":\"");
    try writer.writeAll(msg.role.toStr());
    try writer.writeByte('"');

    // Content
    try writer.writeAll(",\"content\":");
    if (msg.content.len > 0) {
        try writer.writeByte('"');
        try writeJsonEscaped(writer, msg.content);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }

    // Tool call ID (for tool result messages)
    if (msg.tool_call_id) |id| {
        try writer.writeAll(",\"tool_call_id\":\"");
        try writeJsonEscaped(writer, id);
        try writer.writeByte('"');
    }

    // Tool calls (for assistant messages that invoke tools)
    if (msg.tool_calls) |tool_calls| {
        try writer.writeAll(",\"tool_calls\":[");
        for (tool_calls, 0..) |tc, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":\"");
            try writeJsonEscaped(writer, tc.id);
            try writer.writeAll("\",\"type\":\"function\",\"function\":{\"name\":\"");
            try writeJsonEscaped(writer, tc.name);
            try writer.writeAll("\",\"arguments\":\"");
            try writeJsonEscaped(writer, tc.arguments);
            try writer.writeAll("\"}}");
        }
        try writer.writeByte(']');
    }

    try writer.writeByte('}');
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(writer, "\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Parse an OpenAI chat completion JSON response into a Response.
pub fn parseResponse(allocator: Allocator, body: []const u8) !*Response {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    // Check for API error
    if (root.object.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg_val| {
                if (msg_val == .string) {
                    const err_msg = try allocator.dupe(u8, msg_val.string);
                    const response = try allocator.create(Response);
                    response.* = .{
                        .text_buf = err_msg,
                        .finish_reason = .err,
                        .usage = .{},
                        .tool_calls = try allocator.alloc(ToolCallResult, 0),
                        .allocator = allocator,
                    };
                    return response;
                }
            }
        }
        return error.ApiError;
    }

    const choices = root.object.get("choices") orelse return error.InvalidJson;
    if (choices != .array or choices.array.items.len == 0) return error.InvalidJson;

    const choice = choices.array.items[0];
    if (choice != .object) return error.InvalidJson;

    // Parse finish reason
    const finish_reason = blk: {
        const fr = choice.object.get("finish_reason") orelse break :blk FinishReason.unknown;
        if (fr != .string) break :blk FinishReason.unknown;
        if (std.mem.eql(u8, fr.string, "stop")) break :blk FinishReason.stop;
        if (std.mem.eql(u8, fr.string, "length")) break :blk FinishReason.length;
        if (std.mem.eql(u8, fr.string, "tool_calls")) break :blk FinishReason.tool_calls;
        if (std.mem.eql(u8, fr.string, "content_filter")) break :blk FinishReason.content_filter;
        break :blk FinishReason.unknown;
    };

    // Parse message
    const msg = choice.object.get("message") orelse return error.InvalidJson;
    if (msg != .object) return error.InvalidJson;

    // Parse text content
    const text_content = blk: {
        const c = msg.object.get("content") orelse break :blk "";
        if (c == .string) break :blk c.string;
        break :blk "";
    };
    const text_buf = try allocator.dupe(u8, text_content);

    // Parse tool calls
    var tool_calls_list: std.ArrayList(ToolCallResult) = .empty;
    defer tool_calls_list.deinit(allocator);

    if (msg.object.get("tool_calls")) |tc_arr| {
        if (tc_arr == .array) {
            for (tc_arr.array.items) |tc_val| {
                if (tc_val != .object) continue;

                const id_val = tc_val.object.get("id") orelse continue;
                if (id_val != .string) continue;

                const func_val = tc_val.object.get("function") orelse continue;
                if (func_val != .object) continue;

                const name_val = func_val.object.get("name") orelse continue;
                if (name_val != .string) continue;

                const args_val = func_val.object.get("arguments") orelse continue;
                if (args_val != .string) continue;

                try tool_calls_list.append(allocator, .{
                    .id = try allocator.dupe(u8, id_val.string),
                    .name = try allocator.dupe(u8, name_val.string),
                    .arguments = try allocator.dupe(u8, args_val.string),
                });
            }
        }
    }

    // Parse usage
    const usage_val = root.object.get("usage");
    const usage = blk: {
        if (usage_val) |uv| {
            if (uv == .object) {
                const input = getI64(uv.object, "prompt_tokens");
                const output = getI64(uv.object, "completion_tokens");
                const total = getI64(uv.object, "total_tokens");
                break :blk Usage{
                    .input_tokens = input,
                    .output_tokens = output,
                    .total_tokens = if (total != 0) total else input + output,
                };
            }
        }
        break :blk Usage{};
    };

    const response = try allocator.create(Response);
    response.* = .{
        .text_buf = text_buf,
        .finish_reason = finish_reason,
        .usage = usage,
        .tool_calls = try tool_calls_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    return response;
}

fn getI64(obj: std.json.ObjectMap, key: []const u8) i64 {
    const val = obj.get(key) orelse return 0;
    return switch (val) {
        .integer => val.integer,
        .float => @intFromFloat(val.float),
        else => 0,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "build request body simple" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "gpt-4", .{
        .messages = &.{
            Message.system("You are helpful."),
            Message.user("Hello"),
        },
    });
    defer allocator.free(body);

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gpt-4", root.get("model").?.string);

    const msgs = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("system", msgs.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", msgs.items[1].object.get("role").?.string);
}

test "build request body with tools" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "gpt-4", .{
        .messages = &.{Message.user("Hello")},
        .tools = &.{.{
            .name = "get_weather",
            .description = "Get weather",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}",
        }},
    });
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const tools_arr = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools_arr.items.len);
}

test "parse response simple" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"id":"chatcmpl-123","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hello, world!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":10,"total_tokens":13}}
    ;

    var response = try parseResponse(allocator, json_str);
    defer {
        response.deinit();
        allocator.destroy(response);
    }

    try std.testing.expectEqualStrings("Hello, world!", response.text());
    try std.testing.expectEqual(FinishReason.stop, response.finish_reason);
    try std.testing.expectEqual(@as(i64, 3), response.usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 10), response.usage.output_tokens);
    try std.testing.expectEqual(@as(i64, 13), response.usage.total_tokens);
    try std.testing.expectEqual(@as(usize, 0), response.tool_calls.len);
}

test "parse response with tool calls" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"id":"chatcmpl-456","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
    ;

    var response = try parseResponse(allocator, json_str);
    defer {
        response.deinit();
        allocator.destroy(response);
    }

    try std.testing.expectEqual(FinishReason.tool_calls, response.finish_reason);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", response.tool_calls[0].id);
    try std.testing.expectEqualStrings("get_weather", response.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"city\":\"SF\"}", response.tool_calls[0].arguments);
}
