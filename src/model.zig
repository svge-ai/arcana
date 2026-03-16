const std = @import("std");
const message = @import("message.zig");
const Message = message.Message;
const Allocator = std.mem.Allocator;

pub const FinishReason = enum {
    stop,
    length,
    content_filter,
    tool_calls,
    err,
    other,
    unknown,
};

pub const Usage = struct {
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    total_tokens: i64 = 0,
    reasoning_tokens: i64 = 0,
    cache_creation_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,

    pub fn add(self: Usage, other: Usage) Usage {
        return .{
            .input_tokens = self.input_tokens + other.input_tokens,
            .output_tokens = self.output_tokens + other.output_tokens,
            .total_tokens = self.total_tokens + other.total_tokens,
            .reasoning_tokens = self.reasoning_tokens + other.reasoning_tokens,
            .cache_creation_tokens = self.cache_creation_tokens + other.cache_creation_tokens,
            .cache_read_tokens = self.cache_read_tokens + other.cache_read_tokens,
        };
    }
};

pub const ToolInfo = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8, // JSON string
};

pub const Call = struct {
    messages: []const Message = &.{},
    tools: []const ToolInfo = &.{},
    temperature: ?f64 = null,
    max_output_tokens: ?i64 = null,
    top_p: ?f64 = null,
};

pub const Response = struct {
    text_buf: []u8,
    finish_reason: FinishReason,
    usage: Usage,
    tool_calls: []ToolCallResult,
    allocator: Allocator,

    pub fn text(self: *const Response) []const u8 {
        return self.text_buf;
    }

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.text_buf);
        for (self.tool_calls) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            self.allocator.free(tc.arguments);
        }
        self.allocator.free(self.tool_calls);
    }
};

pub const ToolCallResult = struct {
    id: []u8,
    name: []u8,
    arguments: []u8,
};

/// LanguageModel is a virtual interface for calling language models.
/// Providers implement the generate_fn to perform HTTP calls.
pub const LanguageModel = struct {
    generate_fn: *const fn (ctx: *anyopaque, call: Call, allocator: Allocator) anyerror!*Response,
    ctx: *anyopaque,
    model_id: []const u8,
    provider_name: []const u8,

    pub fn generate(self: LanguageModel, call: Call, allocator: Allocator) !*Response {
        return self.generate_fn(self.ctx, call, allocator);
    }
};

test "usage add" {
    const a = Usage{ .input_tokens = 10, .output_tokens = 5, .total_tokens = 15 };
    const b = Usage{ .input_tokens = 3, .output_tokens = 10, .total_tokens = 13 };
    const sum = a.add(b);
    try std.testing.expectEqual(@as(i64, 13), sum.input_tokens);
    try std.testing.expectEqual(@as(i64, 15), sum.output_tokens);
    try std.testing.expectEqual(@as(i64, 28), sum.total_tokens);
}
