const std = @import("std");
const openai_compat = @import("openai_compat.zig");
const model_mod = @import("../model.zig");
const LanguageModel = model_mod.LanguageModel;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// The full Azure OpenAI endpoint URL.
    /// e.g. "https://my-resource.openai.azure.com/openai/deployments/my-deployment"
    base_url: []const u8,
    api_key: []const u8,
    api_version: []const u8 = "2025-01-01-preview",
};

pub const AzureProvider = struct {
    compat: openai_compat.CompatProvider,

    pub fn init(allocator: Allocator, opts: Options) AzureProvider {
        return .{
            .compat = openai_compat.CompatProvider.init(allocator, .{
                .base_url = opts.base_url,
                .api_key = opts.api_key,
                .auth_header = "api-key",
                .auth_prefix = "",
                .completions_path = "/chat/completions",
                .provider_name = "azure",
            }),
        };
    }

    pub fn deinit(self: *AzureProvider) void {
        self.compat.deinit();
    }

    pub fn languageModel(self: *AzureProvider, model_id: []const u8) !LanguageModel {
        return self.compat.languageModel(model_id);
    }
};

/// Convenience init matching the design doc API.
pub fn init(allocator: Allocator, opts: Options) AzureProvider {
    return AzureProvider.init(allocator, opts);
}
