const std = @import("std");
const schema_mod = @import("schema.zig");

/// Internal function signature — receives raw JSON, writes to ToolOutput.
pub const ToolRunFn = *const fn (input_json: []const u8, output: *ToolOutput) anyerror!void;

pub const ToolOutput = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,

    pub fn writeText(self: *ToolOutput, text_str: []const u8) !void {
        if (self.len + text_str.len > self.buf.len) {
            return error.ToolOutputOverflow;
        }
        @memcpy(self.buf[self.len..][0..text_str.len], text_str);
        self.len += text_str.len;
    }

    pub fn slice(self: *const ToolOutput) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    run_fn: ToolRunFn,
    parameters_json: []const u8,
};

/// Create a typed tool from a struct type and a handler function.
/// The JSON schema is generated at compile time from `Input`.
/// The handler receives a parsed `Input` struct, not raw JSON.
///
/// Usage:
///   const WeatherInput = struct {
///       city: []const u8,
///       units: ?[]const u8 = null,
///   };
///   const weather = arcana.tool(WeatherInput, "get_weather", "Get weather.", getWeather);
///
///   fn getWeather(input: WeatherInput, output: *arcana.ToolOutput) !void {
///       try output.writeText("72F in " ++ input.city);
///   }
pub fn tool(
    comptime Input: type,
    name: []const u8,
    description: []const u8,
    comptime handler: *const fn (input: Input, output: *ToolOutput) anyerror!void,
) AgentTool {
    // Generate JSON schema at compile time
    const json_schema = comptime schema_mod.generateJsonSchema(Input);

    // Create a wrapper that parses JSON → Input, then calls the typed handler.
    // handler is comptime-known, so the generated struct captures it without closures.
    const Wrapper = struct {
        fn run(input_json: []const u8, output: *ToolOutput) anyerror!void {
            const parsed = std.json.parseFromSlice(
                Input,
                std.heap.page_allocator,
                input_json,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch {
                return output.writeText("Error: failed to parse tool input");
            };
            defer parsed.deinit();

            return handler(parsed.value, output);
        }
    };

    return .{
        .name = name,
        .description = description,
        .run_fn = Wrapper.run,
        .parameters_json = json_schema,
    };
}

/// Create a tool with a raw JSON schema string (escape hatch for complex schemas).
pub fn rawTool(
    name: []const u8,
    description: []const u8,
    run_fn: ToolRunFn,
    parameters_json: []const u8,
) AgentTool {
    return .{
        .name = name,
        .description = description,
        .run_fn = run_fn,
        .parameters_json = parameters_json,
    };
}

// ── Tests ──────────────────────────────────────────────────

test "tool output write" {
    var output = ToolOutput{};
    try output.writeText("hello ");
    try output.writeText("world");
    try std.testing.expectEqualStrings("hello world", output.slice());
}

test "tool output overflow" {
    var output = ToolOutput{};
    output.len = 16380;
    try std.testing.expectError(error.ToolOutputOverflow, output.writeText("12345"));
}

test "typed tool — schema generation and execution" {
    const WeatherInput = struct {
        city: []const u8,
    };

    const handler = struct {
        fn getWeather(input: WeatherInput, output: *ToolOutput) !void {
            try output.writeText("72F in ");
            try output.writeText(input.city);
        }
    };

    const t = tool(WeatherInput, "get_weather", "Get weather for a city.", handler.getWeather);

    try std.testing.expectEqualStrings("get_weather", t.name);
    try std.testing.expectEqualStrings("Get weather for a city.", t.description);

    // Verify schema was generated
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        t.parameters_json,
        .{},
    );
    defer parsed.deinit();
    const props = parsed.value.object.get("properties").?.object;
    try std.testing.expect(props.get("city") != null);

    // Verify execution with JSON input
    var output = ToolOutput{};
    try t.run_fn("{\"city\":\"San Francisco\"}", &output);
    try std.testing.expectEqualStrings("72F in San Francisco", output.slice());
}

test "typed tool — optional fields with defaults" {
    const SearchInput = struct {
        query: []const u8,
        limit: ?i32 = null,
    };

    const handler = struct {
        fn doSearch(input: SearchInput, output: *ToolOutput) !void {
            try output.writeText("searching: ");
            try output.writeText(input.query);
            if (input.limit) |l| {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, " (limit {})", .{l}) catch "";
                try output.writeText(s);
            }
        }
    };

    const t = tool(SearchInput, "search", "Search things.", handler.doSearch);

    // Without optional field
    var out1 = ToolOutput{};
    try t.run_fn("{\"query\":\"hello\"}", &out1);
    try std.testing.expectEqualStrings("searching: hello", out1.slice());

    // With optional field
    var out2 = ToolOutput{};
    try t.run_fn("{\"query\":\"hello\",\"limit\":5}", &out2);
    try std.testing.expectEqualStrings("searching: hello (limit 5)", out2.slice());
}

test "rawTool — manual schema" {
    const dummy_fn: ToolRunFn = struct {
        fn run(_: []const u8, _: *ToolOutput) !void {}
    }.run;
    const t = rawTool("test", "desc", dummy_fn, "{\"type\":\"object\"}");
    try std.testing.expectEqualStrings("test", t.name);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", t.parameters_json);
}
