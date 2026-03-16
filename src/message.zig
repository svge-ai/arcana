const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toStr(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const ToolCallInfo = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallInfo = null,

    pub fn system(content: []const u8) Message {
        return .{
            .role = .system,
            .content = content,
        };
    }

    pub fn user(content: []const u8) Message {
        return .{
            .role = .user,
            .content = content,
        };
    }

    pub fn assistant(content: []const u8) Message {
        return .{
            .role = .assistant,
            .content = content,
        };
    }

    pub fn assistantWithToolCalls(content: []const u8, tool_calls: []const ToolCallInfo) Message {
        return .{
            .role = .assistant,
            .content = content,
            .tool_calls = tool_calls,
        };
    }

    pub fn toolResult(tool_call_id: []const u8, content: []const u8) Message {
        return .{
            .role = .tool,
            .content = content,
            .tool_call_id = tool_call_id,
        };
    }
};

test "message constructors" {
    const sys = Message.system("You are helpful.");
    try std.testing.expectEqual(Role.system, sys.role);
    try std.testing.expectEqualStrings("You are helpful.", sys.content);

    const usr = Message.user("Hello");
    try std.testing.expectEqual(Role.user, usr.role);

    const asst = Message.assistant("Hi there");
    try std.testing.expectEqual(Role.assistant, asst.role);

    const tool_res = Message.toolResult("call_123", "result");
    try std.testing.expectEqual(Role.tool, tool_res.role);
    try std.testing.expectEqualStrings("call_123", tool_res.tool_call_id.?);
}
