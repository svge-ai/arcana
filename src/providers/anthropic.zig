const std = @import("std");
const openai_compat = @import("openai_compat.zig");
const model_mod = @import("../model.zig");
const LanguageModel = model_mod.LanguageModel;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://api.anthropic.com/v1",
};

pub const AnthropicProvider = struct {
    compat: openai_compat.CompatProvider,

    pub fn init(allocator: Allocator, opts: Options) AnthropicProvider {
        return .{
            .compat = openai_compat.CompatProvider.init(allocator, .{
                .base_url = opts.base_url,
                .api_key = opts.api_key,
                .auth_header = "x-api-key",
                .auth_prefix = "",
                .extra_headers = &.{
                    .{ .name = "anthropic-version", .value = "2023-06-01" },
                },
                .completions_path = "/chat/completions",
                .provider_name = "anthropic",
            }),
        };
    }

    pub fn deinit(self: *AnthropicProvider) void {
        self.compat.deinit();
    }

    pub fn languageModel(self: *AnthropicProvider, model_id: []const u8) !LanguageModel {
        return self.compat.languageModel(model_id);
    }
};

/// Convenience init matching the design doc API.
pub fn init(allocator: Allocator, opts: Options) AnthropicProvider {
    return AnthropicProvider.init(allocator, opts);
}
