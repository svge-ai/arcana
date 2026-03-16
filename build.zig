const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (for consumers to import)
    const arcana_mod = b.addModule("arcana", .{
        .root_source_file = b.path("src/arcana.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/arcana.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration test (live API calls — needs ANTHROPIC_API_KEY)
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    integration_tests.root_module.addImport("arcana", arcana_mod);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-live", "Run live integration tests (needs ANTHROPIC_API_KEY)");
    integration_step.dependOn(&run_integration_tests.step);
}
