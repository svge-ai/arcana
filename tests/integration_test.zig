const std = @import("std");
const arcana = @import("arcana");

// ── Tool input types ────────────────────────────────────────

const WeatherInput = struct {
    city: []const u8,
};

fn getWeather(input: WeatherInput, output: *arcana.ToolOutput) !void {
    try output.writeText("72F and sunny in ");
    try output.writeText(input.city);
}

// ── Live tests ──────────────────────────────────────────────

test "live: simple generation" {
    const allocator = std.testing.allocator;
    const api_key = std.posix.getenv("ANTHROPIC_API_KEY") orelse return;

    var provider = arcana.providers.anthropic.init(allocator, .{ .api_key = api_key });
    defer provider.deinit();

    const model = try provider.languageModel("claude-sonnet-4-6");
    var agent_inst = arcana.newAgent(model, .{
        .system_prompt = "Respond in one sentence.",
        .allocator = allocator,
    });

    var result = try agent_inst.generate(.{ .prompt = "What is 2+2?" });
    defer {
        result.deinit();
        allocator.destroy(result);
    }

    try std.testing.expect(result.response.text().len > 0);
    try std.testing.expect(result.steps >= 1);
}

test "live: tool use with typed input" {
    const allocator = std.testing.allocator;
    const api_key = std.posix.getenv("ANTHROPIC_API_KEY") orelse return;

    var provider = arcana.providers.anthropic.init(allocator, .{ .api_key = api_key });
    defer provider.deinit();

    const model = try provider.languageModel("claude-sonnet-4-6");

    // Typed tool — schema generated from WeatherInput struct at comptime
    const weather = arcana.newTool(
        WeatherInput,
        "get_weather",
        "Get current weather for a city.",
        getWeather,
    );

    var agent_inst = arcana.newAgent(model, .{
        .system_prompt = "Use tools to answer questions. Be concise.",
        .tools = &.{weather},
        .allocator = allocator,
    });

    var result = try agent_inst.generate(.{ .prompt = "What's the weather in San Francisco?" });
    defer {
        result.deinit();
        allocator.destroy(result);
    }

    try std.testing.expect(result.steps >= 2);
    try std.testing.expect(result.response.text().len > 0);
}
