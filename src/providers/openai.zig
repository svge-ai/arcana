const std = @import("std");
const openai_compat = @import("openai_compat.zig");
const model_mod = @import("../model.zig");
const LanguageModel = model_mod.LanguageModel;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://api.openai.com/v1",
    organization: ?[]const u8 = null,
    project: ?[]const u8 = null,
};

pub const OpenAIProvider = struct {
    compat: openai_compat.CompatProvider,

    pub fn init(allocator: Allocator, opts: Options) OpenAIProvider {
        // Build extra headers for org/project
        var extra_list: [2]openai_compat.ExtraHeader = undefined;
        var extra_count: usize = 0;

        if (opts.organization) |org| {
            extra_list[extra_count] = .{ .name = "OpenAI-Organization", .value = org };
            extra_count += 1;
        }
        if (opts.project) |proj| {
            extra_list[extra_count] = .{ .name = "OpenAI-Project", .value = proj };
            extra_count += 1;
        }

        return .{
            .compat = openai_compat.CompatProvider.init(allocator, .{
                .base_url = opts.base_url,
                .api_key = opts.api_key,
                .auth_header = "Authorization",
                .auth_prefix = "Bearer ",
                .extra_headers = extra_list[0..extra_count],
                .completions_path = "/chat/completions",
                .provider_name = "openai",
            }),
        };
    }

    pub fn deinit(self: *OpenAIProvider) void {
        self.compat.deinit();
    }

    pub fn languageModel(self: *OpenAIProvider, model_id: []const u8) !LanguageModel {
        return self.compat.languageModel(model_id);
    }
};

/// Convenience init matching the design doc API.
pub fn init(allocator: Allocator, opts: Options) OpenAIProvider {
    return OpenAIProvider.init(allocator, opts);
}
