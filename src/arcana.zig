//! Arcana -- Zig LLM Agent SDK
//!
//! A Zig port of Charm's Fantasy. Multi-provider, multi-model, one API.
//!
//! Usage:
//!
//!   const arcana = @import("arcana");
//!
//!   var provider = arcana.providers.anthropic.init(allocator, .{ .api_key = key });
//!   defer provider.deinit();
//!
//!   var model = try provider.languageModel("claude-sonnet-4-6");
//!
//!   var agent = arcana.newAgent(model, .{
//!       .system_prompt = "You are helpful.",
//!       .tools = &.{my_tool},
//!   });
//!
//!   var result = try agent.generate(.{ .prompt = "Hello" });
//!   defer result.deinit();
//!
//!   const text = result.response.text();
//!

const std = @import("std");

// ── Core types ─────────────────────────────────────────────────────

pub const message = @import("message.zig");
pub const model = @import("model.zig");
pub const tool = @import("tool.zig");
pub const schema = @import("schema.zig");
pub const provider = @import("provider.zig");
pub const agent = @import("agent.zig");
pub const json = @import("json.zig");

// ── Provider implementations ───────────────────────────────────────

pub const providers = struct {
    pub const anthropic = @import("providers/anthropic.zig");
    pub const openai = @import("providers/openai.zig");
    pub const openrouter = @import("providers/openrouter.zig");
    pub const azure = @import("providers/azure.zig");
    pub const google = @import("providers/google.zig");
    pub const ollama = @import("providers/ollama.zig");
    pub const openai_compat = @import("providers/openai_compat.zig");
};

// ── Re-exports for ergonomic API ───────────────────────────────────

pub const Message = message.Message;
pub const Role = message.Role;
pub const ToolCallInfo = message.ToolCallInfo;

pub const LanguageModel = model.LanguageModel;
pub const Response = model.Response;
pub const Call = model.Call;
pub const Usage = model.Usage;
pub const FinishReason = model.FinishReason;
pub const ToolInfo = model.ToolInfo;

pub const AgentTool = tool.AgentTool;
pub const ToolOutput = tool.ToolOutput;
pub const ToolRunFn = tool.ToolRunFn;

pub const Agent = agent.Agent;
pub const AgentOptions = agent.AgentOptions;
pub const AgentResult = agent.AgentResult;
pub const GenerateCall = agent.GenerateCall;

pub const Provider = provider.Provider;

// ── Top-level convenience functions ────────────────────────────────

/// Create a typed tool from a struct type. Schema is generated at comptime.
/// The handler receives a parsed struct, not raw JSON.
pub fn newTool(
    comptime Input: type,
    name: []const u8,
    description: []const u8,
    comptime handler: *const fn (input: Input, output: *ToolOutput) anyerror!void,
) AgentTool {
    return tool.tool(Input, name, description, handler);
}

/// Create a tool with a raw JSON schema string (escape hatch).
pub const rawTool = tool.rawTool;

pub const newAgent = agent.newAgent;

// ── Tests ──────────────────────────────────────────────────────────

test {
    // Pull in all tests from sub-modules
    _ = message;
    _ = model;
    _ = tool;
    _ = schema;
    _ = agent;
    _ = json;
    // Provider modules are compile-checked but don't have unit tests
    // (they require network access)
    _ = providers.anthropic;
    _ = providers.openai;
    _ = providers.openrouter;
    _ = providers.azure;
    _ = providers.google;
    _ = providers.ollama;
    _ = providers.openai_compat;
}
