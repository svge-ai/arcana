const std = @import("std");
const openai_compat = @import("openai_compat.zig");
const model_mod = @import("../model.zig");
const LanguageModel = model_mod.LanguageModel;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    base_url: []const u8 = "http://localhost:11434/v1",
};

pub const OllamaProvider = struct {
    compat: openai_compat.CompatProvider,

    pub fn init(allocator: Allocator, opts: Options) OllamaProvider {
        return .{
            .compat = openai_compat.CompatProvider.init(allocator, .{
                .base_url = opts.base_url,
                .api_key = "",
                .auth_header = "Authorization",
                .auth_prefix = "",
                .completions_path = "/chat/completions",
                .provider_name = "ollama",
            }),
        };
    }

    pub fn deinit(self: *OllamaProvider) void {
        self.compat.deinit();
    }

    pub fn languageModel(self: *OllamaProvider, model_id: []const u8) !LanguageModel {
        return self.compat.languageModel(model_id);
    }
};

/// Convenience init matching the design doc API.
pub fn init(allocator: Allocator, opts: Options) OllamaProvider {
    return OllamaProvider.init(allocator, opts);
}
