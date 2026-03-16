const std = @import("std");
const message_mod = @import("message.zig");
const model_mod = @import("model.zig");
const tool_mod = @import("tool.zig");
const Message = message_mod.Message;
const ToolCallInfo = message_mod.ToolCallInfo;
const LanguageModel = model_mod.LanguageModel;
const Call = model_mod.Call;
const Response = model_mod.Response;
const Usage = model_mod.Usage;
const FinishReason = model_mod.FinishReason;
const ToolInfo = model_mod.ToolInfo;
const AgentTool = tool_mod.AgentTool;
const ToolOutput = tool_mod.ToolOutput;
const Allocator = std.mem.Allocator;

pub const AgentOptions = struct {
    system_prompt: []const u8 = "",
    tools: []const AgentTool = &.{},
    max_steps: usize = 10,
    temperature: ?f64 = null,
    allocator: Allocator = std.heap.page_allocator,
};

pub const GenerateCall = struct {
    prompt: []const u8 = "",
    messages: []const Message = &.{},
};

pub const AgentResult = struct {
    response: Response,
    total_usage: Usage,
    steps: usize,
    allocator: Allocator,

    // Owned memory that must be freed
    owned_tool_call_infos: [][]ToolCallInfo,
    owned_tool_call_strings: [][]u8,
    step_responses: []*Response,

    pub fn deinit(self: *AgentResult) void {
        // Free all intermediate step responses fully.
        // The last response's contents were copied into self.response,
        // so we only destroy the container for the last one.
        if (self.step_responses.len > 0) {
            // Free intermediate responses (all but last) fully
            for (self.step_responses[0 .. self.step_responses.len - 1]) |resp| {
                resp.deinit();
                self.allocator.destroy(resp);
            }
            // Free the last response container only (contents are in self.response)
            self.allocator.destroy(self.step_responses[self.step_responses.len - 1]);
        }
        self.allocator.free(self.step_responses);

        // Free owned strings used in tool call messages
        for (self.owned_tool_call_strings) |s| {
            self.allocator.free(s);
        }
        self.allocator.free(self.owned_tool_call_strings);

        for (self.owned_tool_call_infos) |infos| {
            self.allocator.free(infos);
        }
        self.allocator.free(self.owned_tool_call_infos);

        // Free the last response's contents (text_buf, tool_calls)
        self.response.deinit();
    }
};

pub const Agent = struct {
    model: LanguageModel,
    system_prompt: []const u8,
    tools: []const AgentTool,
    max_steps: usize,
    temperature: ?f64,
    allocator: Allocator,

    pub fn generate(self: *Agent, call: GenerateCall) !*AgentResult {
        const alloc = self.allocator;

        if (call.prompt.len == 0 and call.messages.len == 0) {
            return error.EmptyPrompt;
        }

        var total_usage = Usage{};
        var step_count: usize = 0;

        // Build tool info slice for calls
        var tool_infos = try alloc.alloc(ToolInfo, self.tools.len);
        defer alloc.free(tool_infos);
        for (self.tools, 0..) |t, i| {
            tool_infos[i] = .{
                .name = t.name,
                .description = t.description,
                .input_schema = t.parameters_json,
            };
        }

        // Accumulate messages across steps
        var all_messages: std.ArrayList(Message) = .empty;
        defer all_messages.deinit(alloc);

        // Owned memory tracking
        var owned_tool_call_infos: std.ArrayList([]ToolCallInfo) = .empty;
        defer owned_tool_call_infos.deinit(alloc);
        var owned_tool_call_strings: std.ArrayList([]u8) = .empty;
        defer owned_tool_call_strings.deinit(alloc);
        var step_responses: std.ArrayList(*Response) = .empty;
        defer step_responses.deinit(alloc);

        // Build initial messages
        if (self.system_prompt.len > 0) {
            try all_messages.append(alloc, Message.system(self.system_prompt));
        }
        if (call.prompt.len > 0) {
            try all_messages.append(alloc, Message.user(call.prompt));
        }
        for (call.messages) |msg| {
            try all_messages.append(alloc, msg);
        }

        // Step loop
        while (step_count < self.max_steps) {
            var model_call = Call{
                .messages = all_messages.items,
                .tools = tool_infos,
                .temperature = self.temperature,
            };

            // If no tools, don't send tool info
            if (self.tools.len == 0) {
                model_call.tools = &.{};
            }

            const response = try self.model.generate(model_call, alloc);
            try step_responses.append(alloc, response);

            total_usage = total_usage.add(response.usage);
            step_count += 1;

            // If no tool calls, or finish reason is not tool_calls, we're done
            if (response.tool_calls.len == 0 or response.finish_reason != .tool_calls) {
                break;
            }

            // Execute tool calls and add to conversation
            // First add the assistant's response with tool calls
            const tc_infos = try alloc.alloc(ToolCallInfo, response.tool_calls.len);
            for (response.tool_calls, 0..) |tc, i| {
                tc_infos[i] = .{
                    .id = tc.id,
                    .name = tc.name,
                    .arguments = tc.arguments,
                };
            }
            try owned_tool_call_infos.append(alloc, tc_infos);

            const asst_msg = Message.assistantWithToolCalls(
                response.text(),
                tc_infos,
            );
            try all_messages.append(alloc, asst_msg);

            // Execute each tool
            for (response.tool_calls) |tc| {
                const tool_opt = self.findTool(tc.name);
                if (tool_opt) |t| {
                    var output = ToolOutput{};
                    t.run_fn(tc.arguments, &output) catch {
                        // On error, send error as tool result
                        const err_result = Message.toolResult(tc.id, "Tool execution failed");
                        try all_messages.append(alloc, err_result);
                        continue;
                    };
                    // Dupe the output text since it lives in a stack buffer
                    const result_text = try alloc.dupe(u8, output.slice());
                    try owned_tool_call_strings.append(alloc, result_text);
                    const tool_msg = Message.toolResult(tc.id, result_text);
                    try all_messages.append(alloc, tool_msg);
                } else {
                    const err_msg = try std.fmt.allocPrint(alloc, "Tool not found: {s}", .{tc.name});
                    try owned_tool_call_strings.append(alloc, err_msg);
                    const tool_msg = Message.toolResult(tc.id, err_msg);
                    try all_messages.append(alloc, tool_msg);
                }
            }
        }

        const last_response = step_responses.items[step_responses.items.len - 1];

        const result = try alloc.create(AgentResult);
        result.* = .{
            .response = last_response.*,
            .total_usage = total_usage,
            .steps = step_count,
            .allocator = alloc,
            .owned_tool_call_infos = try owned_tool_call_infos.toOwnedSlice(alloc),
            .owned_tool_call_strings = try owned_tool_call_strings.toOwnedSlice(alloc),
            .step_responses = try step_responses.toOwnedSlice(alloc),
        };
        return result;
    }

    fn findTool(self: *const Agent, name: []const u8) ?AgentTool {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }
};

pub fn newAgent(model: LanguageModel, opts: AgentOptions) Agent {
    return .{
        .model = model,
        .system_prompt = opts.system_prompt,
        .tools = opts.tools,
        .max_steps = opts.max_steps,
        .temperature = opts.temperature,
        .allocator = opts.allocator,
    };
}

// ── Mock model for testing ─────────────────────────────────────────

const MockModel = struct {
    call_count: usize = 0,
    responses: []const MockResponse,

    const MockResponse = struct {
        text: []const u8,
        finish_reason: FinishReason,
        tool_calls: []const MockToolCall = &.{},
        usage: Usage = .{ .input_tokens = 3, .output_tokens = 10, .total_tokens = 13 },
    };

    const MockToolCall = struct {
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
    };

    fn generateFn(ctx: *anyopaque, _: Call, allocator: Allocator) anyerror!*Response {
        const self: *MockModel = @ptrCast(@alignCast(ctx));
        const idx = @min(self.call_count, self.responses.len - 1);
        const mock = self.responses[idx];
        self.call_count += 1;

        const text_buf = try allocator.dupe(u8, mock.text);

        var tool_calls = try allocator.alloc(model_mod.ToolCallResult, mock.tool_calls.len);
        for (mock.tool_calls, 0..) |tc, i| {
            tool_calls[i] = .{
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.name),
                .arguments = try allocator.dupe(u8, tc.arguments),
            };
        }

        const response = try allocator.create(Response);
        response.* = .{
            .text_buf = text_buf,
            .finish_reason = mock.finish_reason,
            .usage = mock.usage,
            .tool_calls = tool_calls,
            .allocator = allocator,
        };
        return response;
    }

    fn languageModel(self: *MockModel) LanguageModel {
        return .{
            .generate_fn = generateFn,
            .ctx = @ptrCast(self),
            .model_id = "mock-model",
            .provider_name = "mock",
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "simple generate" {
    const allocator = std.testing.allocator;
    var mock = MockModel{
        .responses = &.{
            .{ .text = "Hello, world!", .finish_reason = .stop },
        },
    };

    var agent_inst = newAgent(mock.languageModel(), .{
        .allocator = allocator,
    });

    var result = try agent_inst.generate(.{ .prompt = "Hello" });
    defer {
        result.deinit();
        allocator.destroy(result);
    }

    try std.testing.expectEqualStrings("Hello, world!", result.response.text());
    try std.testing.expectEqual(@as(usize, 1), result.steps);
    try std.testing.expectEqual(@as(i64, 3), result.total_usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 10), result.total_usage.output_tokens);
    try std.testing.expectEqual(@as(i64, 13), result.total_usage.total_tokens);
}

test "generate with system prompt" {
    const allocator = std.testing.allocator;
    var mock = MockModel{
        .responses = &.{
            .{ .text = "I'm helpful!", .finish_reason = .stop },
        },
    };

    var agent_inst = newAgent(mock.languageModel(), .{
        .system_prompt = "You are a helpful assistant.",
        .allocator = allocator,
    });

    var result = try agent_inst.generate(.{ .prompt = "Hello" });
    defer {
        result.deinit();
        allocator.destroy(result);
    }

    try std.testing.expectEqualStrings("I'm helpful!", result.response.text());
    try std.testing.expectEqual(@as(usize, 1), result.steps);
}

test "empty prompt error" {
    const allocator = std.testing.allocator;
    var mock = MockModel{
        .responses = &.{
            .{ .text = "", .finish_reason = .stop },
        },
    };
    var agent_inst = newAgent(mock.languageModel(), .{
        .allocator = allocator,
    });

    const result = agent_inst.generate(.{});
    try std.testing.expectError(error.EmptyPrompt, result);
}

test "tool use loop" {
    const allocator = std.testing.allocator;

    const tool_fn: tool_mod.ToolRunFn = struct {
        fn run(_: []const u8, output: *ToolOutput) !void {
            try output.writeText("72F and sunny");
        }
    }.run;

    const weather_tool = tool_mod.rawTool(
        "get_weather",
        "Get weather for a city",
        tool_fn,
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}",
    );

    var mock = MockModel{
        .responses = &.{
            .{
                .text = "",
                .finish_reason = .tool_calls,
                .tool_calls = &.{
                    .{ .id = "call_1", .name = "get_weather", .arguments = "{\"city\":\"SF\"}" },
                },
                .usage = .{ .input_tokens = 10, .output_tokens = 5, .total_tokens = 15 },
            },
            .{
                .text = "The weather in SF is 72F and sunny.",
                .finish_reason = .stop,
                .usage = .{ .input_tokens = 3, .output_tokens = 10, .total_tokens = 13 },
            },
        },
    };

    var agent_inst = newAgent(mock.languageModel(), .{
        .tools = &.{weather_tool},
        .allocator = allocator,
    });

    var result = try agent_inst.generate(.{ .prompt = "What's the weather in SF?" });
    defer {
        result.deinit();
        allocator.destroy(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.steps);
    try std.testing.expectEqualStrings("The weather in SF is 72F and sunny.", result.response.text());
    try std.testing.expectEqual(@as(i64, 13), result.total_usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 15), result.total_usage.output_tokens);
    try std.testing.expectEqual(@as(i64, 28), result.total_usage.total_tokens);
}

test "max steps enforcement" {
    const allocator = std.testing.allocator;

    const tool_fn: tool_mod.ToolRunFn = struct {
        fn run(_: []const u8, output: *ToolOutput) !void {
            try output.writeText("result");
        }
    }.run;

    const dummy_tool = tool_mod.rawTool("dummy", "dummy", tool_fn, "{}");

    // A mock that always returns tool calls
    var mock = MockModel{
        .responses = &.{
            .{
                .text = "",
                .finish_reason = .tool_calls,
                .tool_calls = &.{
                    .{ .id = "call_1", .name = "dummy", .arguments = "{}" },
                },
            },
        },
    };

    var agent_inst = newAgent(mock.languageModel(), .{
        .tools = &.{dummy_tool},
        .max_steps = 3,
        .allocator = allocator,
    });

    var result = try agent_inst.generate(.{ .prompt = "Loop forever" });
    defer {
        result.deinit();
        allocator.destroy(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.steps);
}

test "multiple tools" {
    const allocator = std.testing.allocator;

    const weather_fn: tool_mod.ToolRunFn = struct {
        fn run(_: []const u8, output: *ToolOutput) !void {
            try output.writeText("72F");
        }
    }.run;

    const time_fn: tool_mod.ToolRunFn = struct {
        fn run(_: []const u8, output: *ToolOutput) !void {
            try output.writeText("3:00 PM");
        }
    }.run;

    const weather_tool = tool_mod.rawTool("get_weather", "Get weather", weather_fn, "{}");
    const time_tool = tool_mod.rawTool("get_time", "Get time", time_fn, "{}");

    var mock = MockModel{
        .responses = &.{
            .{
                .text = "",
                .finish_reason = .tool_calls,
                .tool_calls = &.{
                    .{ .id = "call_1", .name = "get_weather", .arguments = "{}" },
                    .{ .id = "call_2", .name = "get_time", .arguments = "{}" },
                },
                .usage = .{ .input_tokens = 10, .output_tokens = 5, .total_tokens = 15 },
            },
            .{
                .text = "It's 72F and 3:00 PM.",
                .finish_reason = .stop,
                .usage = .{ .input_tokens = 3, .output_tokens = 10, .total_tokens = 13 },
            },
        },
    };

    var agent_inst = newAgent(mock.languageModel(), .{
        .tools = &.{ weather_tool, time_tool },
        .allocator = allocator,
    });

    var result = try agent_inst.generate(.{ .prompt = "Weather and time?" });
    defer {
        result.deinit();
        allocator.destroy(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.steps);
    try std.testing.expectEqualStrings("It's 72F and 3:00 PM.", result.response.text());
}
