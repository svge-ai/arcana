const std = @import("std");
const openai_compat = @import("openai_compat.zig");
const model_mod = @import("../model.zig");
const LanguageModel = model_mod.LanguageModel;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://generativelanguage.googleapis.com/v1beta",
    /// For Vertex AI, specify project and location.
    project: ?[]const u8 = null,
    location: ?[]const u8 = null,
};

pub const GoogleProvider = struct {
    compat: openai_compat.CompatProvider,

    pub fn init(allocator: Allocator, opts: Options) GoogleProvider {
        return .{
            .compat = openai_compat.CompatProvider.init(allocator, .{
                .base_url = opts.base_url,
                .api_key = opts.api_key,
                .auth_header = "x-goog-api-key",
                .auth_prefix = "",
                .completions_path = "/chat/completions",
                .provider_name = "google",
            }),
        };
    }

    pub fn deinit(self: *GoogleProvider) void {
        self.compat.deinit();
    }

    pub fn languageModel(self: *GoogleProvider, model_id: []const u8) !LanguageModel {
        return self.compat.languageModel(model_id);
    }
};

/// Convenience init matching the design doc API.
pub fn init(allocator: Allocator, opts: Options) GoogleProvider {
    return GoogleProvider.init(allocator, opts);
}
