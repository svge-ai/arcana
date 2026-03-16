const std = @import("std");
const openai_compat = @import("openai_compat.zig");
const model_mod = @import("../model.zig");
const LanguageModel = model_mod.LanguageModel;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://openrouter.ai/api/v1",
};

pub const OpenRouterProvider = struct {
    compat: openai_compat.CompatProvider,

    pub fn init(allocator: Allocator, opts: Options) OpenRouterProvider {
        return .{
            .compat = openai_compat.CompatProvider.init(allocator, .{
                .base_url = opts.base_url,
                .api_key = opts.api_key,
                .auth_header = "Authorization",
                .auth_prefix = "Bearer ",
                .completions_path = "/chat/completions",
                .provider_name = "openrouter",
            }),
        };
    }

    pub fn deinit(self: *OpenRouterProvider) void {
        self.compat.deinit();
    }

    pub fn languageModel(self: *OpenRouterProvider, model_id: []const u8) !LanguageModel {
        return self.compat.languageModel(model_id);
    }
};

/// Convenience init matching the design doc API.
pub fn init(allocator: Allocator, opts: Options) OpenRouterProvider {
    return OpenRouterProvider.init(allocator, opts);
}
