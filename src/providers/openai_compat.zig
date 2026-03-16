const std = @import("std");
const json_mod = @import("../json.zig");
const model_mod = @import("../model.zig");
const LanguageModel = model_mod.LanguageModel;
const Call = model_mod.Call;
const Response = model_mod.Response;
const Allocator = std.mem.Allocator;

/// Extra header to send with every request.
pub const ExtraHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Configuration for an OpenAI-compatible provider.
pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8 = "",
    /// Auth header name. "Authorization" for Bearer, "x-api-key" for Anthropic, etc.
    auth_header: []const u8 = "Authorization",
    /// Auth value prefix. "Bearer " for most, "" for key-only.
    auth_prefix: []const u8 = "Bearer ",
    /// Extra headers (e.g. anthropic-version).
    extra_headers: []const ExtraHeader = &.{},
    /// Chat completions endpoint path.
    completions_path: []const u8 = "/chat/completions",
    /// Provider name for identification.
    provider_name: []const u8 = "openai-compat",
};

/// Holds the per-model context so the LanguageModel vtable can route
/// generate calls back to the right provider + model_id.
const ModelCtx = struct {
    provider: *CompatProvider,
    model_id_buf: []u8,
};

/// State for an OpenAI-compatible provider instance.
pub const CompatProvider = struct {
    allocator: Allocator,
    config: Config,
    http_client: std.http.Client,
    /// Track model contexts so we can free them on deinit.
    model_contexts: std.ArrayList(*ModelCtx),

    pub fn init(allocator: Allocator, config: Config) CompatProvider {
        return .{
            .allocator = allocator,
            .config = config,
            .http_client = std.http.Client{ .allocator = allocator },
            .model_contexts = .empty,
        };
    }

    pub fn deinit(self: *CompatProvider) void {
        for (self.model_contexts.items) |mctx| {
            self.allocator.free(mctx.model_id_buf);
            self.allocator.destroy(mctx);
        }
        self.model_contexts.deinit(self.allocator);
        self.http_client.deinit();
    }

    /// Create a LanguageModel for the given model ID.
    /// The returned LanguageModel borrows the provider; the provider must outlive it.
    pub fn languageModel(self: *CompatProvider, model_id: []const u8) !LanguageModel {
        const mctx = try self.allocator.create(ModelCtx);
        mctx.* = .{
            .provider = self,
            .model_id_buf = try self.allocator.dupe(u8, model_id),
        };
        try self.model_contexts.append(self.allocator, mctx);

        return .{
            .generate_fn = doGenerate,
            .ctx = @ptrCast(mctx),
            .model_id = mctx.model_id_buf,
            .provider_name = self.config.provider_name,
        };
    }

    fn doGenerate(ctx: *anyopaque, call: Call, allocator: Allocator) anyerror!*Response {
        const mctx: *ModelCtx = @ptrCast(@alignCast(ctx));
        return mctx.provider.httpGenerate(mctx.model_id_buf, call, allocator);
    }

    pub fn httpGenerate(self: *CompatProvider, model_id: []const u8, call: Call, allocator: Allocator) !*Response {
        // Build request body
        const request_body = try json_mod.buildRequestBody(allocator, model_id, call);
        defer allocator.free(request_body);

        // Build URL
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            self.config.base_url,
            self.config.completions_path,
        });
        defer allocator.free(url);

        // Build auth header value
        const auth_value = if (self.config.api_key.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.config.auth_prefix, self.config.api_key })
        else
            null;
        defer if (auth_value) |v| allocator.free(v);

        // Build extra headers
        const extra_count = self.config.extra_headers.len + (if (auth_value != null) @as(usize, 1) else 0);
        var extra_headers = try allocator.alloc(std.http.Header, extra_count);
        defer allocator.free(extra_headers);

        var idx: usize = 0;
        if (auth_value) |av| {
            extra_headers[idx] = .{ .name = self.config.auth_header, .value = av };
            idx += 1;
        }
        for (self.config.extra_headers) |eh| {
            extra_headers[idx] = .{ .name = eh.name, .value = eh.value };
            idx += 1;
        }

        // Perform HTTP request using fetch with std.Io.Writer.Allocating
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = request_body,
            .response_writer = &aw.writer,
            .extra_headers = extra_headers,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
        }) catch |err| {
            const err_text = try std.fmt.allocPrint(allocator, "HTTP request failed: {s}", .{@errorName(err)});
            const response = try allocator.create(Response);
            response.* = .{
                .text_buf = err_text,
                .finish_reason = .err,
                .usage = .{},
                .tool_calls = try allocator.alloc(model_mod.ToolCallResult, 0),
                .allocator = allocator,
            };
            return response;
        };

        const response_body = aw.toArrayList();
        defer allocator.free(response_body.allocatedSlice());

        const status_code = @intFromEnum(fetch_result.status);
        if (status_code < 200 or status_code >= 300) {
            const err_text = try std.fmt.allocPrint(
                allocator,
                "HTTP {d}: {s}",
                .{ status_code, response_body.items },
            );
            const response = try allocator.create(Response);
            response.* = .{
                .text_buf = err_text,
                .finish_reason = .err,
                .usage = .{},
                .tool_calls = try allocator.alloc(model_mod.ToolCallResult, 0),
                .allocator = allocator,
            };
            return response;
        }

        return json_mod.parseResponse(allocator, response_body.items);
    }
};
