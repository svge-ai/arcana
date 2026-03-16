/// Comptime JSON schema generation from Zig struct types.
/// This is the Zig equivalent of Fantasy's runtime reflection for tool schemas.

const std = @import("std");

/// Generate a JSON Schema string from a Zig struct type at compile time.
/// Supports: []const u8 (string), bool, integers, floats, optionals, nested structs.
pub fn generateJsonSchema(comptime T: type) []const u8 {
    comptime {
        return generateObject(T);
    }
}

fn generateObject(comptime T: type) []const u8 {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("schema.generateJsonSchema requires a struct type, got " ++ @typeName(T));
    }
    const fields = info.@"struct".fields;

    var result: []const u8 = "{\"type\":\"object\",\"properties\":{";
    var required: []const u8 = "";
    var required_count: usize = 0;

    for (fields, 0..) |field, i| {
        if (i > 0) result = result ++ ",";
        result = result ++ "\"" ++ field.name ++ "\":";

        const is_optional = @typeInfo(field.type) == .optional;
        const actual_type = if (is_optional) @typeInfo(field.type).optional.child else field.type;
        result = result ++ typeToSchema(actual_type);

        // Non-optional fields without defaults are required
        if (!is_optional and field.defaultValue() == null) {
            if (required_count > 0) required = required ++ ",";
            required = required ++ "\"" ++ field.name ++ "\"";
            required_count += 1;
        }
    }

    result = result ++ "}";
    if (required_count > 0) {
        result = result ++ ",\"required\":[" ++ required ++ "]";
    }
    result = result ++ "}";
    return result;
}

fn typeToSchema(comptime T: type) []const u8 {
    const info = @typeInfo(T);

    // String types
    if (T == []const u8 or T == []u8) {
        return "{\"type\":\"string\"}";
    }

    // Sentinel-terminated strings
    if (info == .pointer and info.pointer.size == .Slice) {
        if (info.pointer.child == u8) {
            return "{\"type\":\"string\"}";
        }
    }

    // Boolean
    if (T == bool) {
        return "{\"type\":\"boolean\"}";
    }

    // Integers
    if (info == .int or info == .comptime_int) {
        return "{\"type\":\"integer\"}";
    }

    // Floats
    if (info == .float or info == .comptime_float) {
        return "{\"type\":\"number\"}";
    }

    // Enums → string with enum values
    if (info == .@"enum") {
        var result: []const u8 = "{\"type\":\"string\",\"enum\":[";
        for (info.@"enum".fields, 0..) |field, i| {
            if (i > 0) result = result ++ ",";
            result = result ++ "\"" ++ field.name ++ "\"";
        }
        result = result ++ "]}";
        return result;
    }

    // Optional — unwrap and recurse (the field itself handles required/optional)
    if (info == .optional) {
        return typeToSchema(info.optional.child);
    }

    // Nested struct → recurse
    if (info == .@"struct") {
        return generateObject(T);
    }

    @compileError("Unsupported type for JSON schema: " ++ @typeName(T));
}

// ── Tests ──────────────────────────────────────────────────

test "simple struct schema" {
    const Input = struct {
        city: []const u8,
        count: i32,
    };
    const schema = comptime generateJsonSchema(Input);
    // Parse to verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("object", obj.get("type").?.string);

    const props = obj.get("properties").?.object;
    try std.testing.expectEqualStrings("string", props.get("city").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("integer", props.get("count").?.object.get("type").?.string);

    const required = obj.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 2), required.items.len);
}

test "optional fields not required" {
    const Input = struct {
        name: []const u8,
        age: ?i32 = null,
    };
    const schema = comptime generateJsonSchema(Input);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const required = obj.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("name", required.items[0].string);
}

test "bool and float types" {
    const Input = struct {
        verbose: bool,
        temperature: f64,
    };
    const schema = comptime generateJsonSchema(Input);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    defer parsed.deinit();

    const props = parsed.value.object.get("properties").?.object;
    try std.testing.expectEqualStrings("boolean", props.get("verbose").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("number", props.get("temperature").?.object.get("type").?.string);
}

test "enum type becomes string enum" {
    const Units = enum { celsius, fahrenheit, kelvin };
    const Input = struct {
        city: []const u8,
        units: Units,
    };
    const schema = comptime generateJsonSchema(Input);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    defer parsed.deinit();

    const units_schema = parsed.value.object.get("properties").?.object.get("units").?.object;
    try std.testing.expectEqualStrings("string", units_schema.get("type").?.string);
    const enum_vals = units_schema.get("enum").?.array;
    try std.testing.expectEqual(@as(usize, 3), enum_vals.items.len);
}

test "nested struct" {
    const Address = struct {
        street: []const u8,
        zip: []const u8,
    };
    const Input = struct {
        name: []const u8,
        address: Address,
    };
    const schema = comptime generateJsonSchema(Input);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    defer parsed.deinit();

    const addr = parsed.value.object.get("properties").?.object.get("address").?.object;
    try std.testing.expectEqualStrings("object", addr.get("type").?.string);
    const addr_props = addr.get("properties").?.object;
    try std.testing.expectEqualStrings("string", addr_props.get("street").?.object.get("type").?.string);
}

test "default values not required" {
    const Input = struct {
        name: []const u8,
        limit: i32 = 10,
    };
    const schema = comptime generateJsonSchema(Input);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    defer parsed.deinit();

    const required = parsed.value.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("name", required.items[0].string);
}
