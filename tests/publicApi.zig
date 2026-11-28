const std = @import("std");
const airdb = @import("airdb");

comptime {
    _ = @import("usageExample.zig");
}

fn expectExactDecls(comptime T: type, comptime expected: []const []const u8) !void {
    inline for (comptime std.meta.declarations(T)) |declName| {
        comptime var found = false;
        inline for (expected) |name| {
            if (comptime std.mem.eql(u8, declName, name)) found = true;
        }
        if (!found) {
            std.debug.print("unexpected public decl: {s}\n", .{declName});
            return error.UnexpectedPublicDecl;
        }
    }
    inline for (expected) |name| {
        if (!@hasDecl(T, name)) {
            std.debug.print("missing public decl: {s}\n", .{name});
            return error.MissingPublicDecl;
        }
    }
}

test "package root exports exactly the application API" {
    try expectExactDecls(airdb, &.{
        "Database",      "ReadTransaction", "WriteTransaction", "Reference",
        "typeDirectory", "typeRouting",     "catalog",          "objects",
        "query",         "blob",            "collections",      "links",
        "bulk",          "migrations",      "maintenance",      "verification",
        "compaction",    "RootKind",
    });
}

test "public airdb module does not export internal" {
    try std.testing.expect(!@hasDecl(airdb, "internal"));
}
