const model = @import("model.zig");

/// Provider is the interface that all providers implement.
/// In Zig we don't use dynamic dispatch for the provider itself --
/// each provider module exposes init/deinit/languageModel directly.
/// This type is a struct that can hold the common interface needed
/// at runtime when the provider needs to be passed generically.
pub const Provider = struct {
    name: []const u8,
    language_model_fn: *const fn (ctx: *anyopaque, model_id: []const u8) model.LanguageModel,
    ctx: *anyopaque,

    pub fn languageModel(self: Provider, model_id: []const u8) model.LanguageModel {
        return self.language_model_fn(self.ctx, model_id);
    }
};
