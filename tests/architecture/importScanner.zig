//! Import scanner for the inward-dependency architecture test.
//!
//! Every function here works on paths and bytes only. None of them touch the
//! file system, so unit tests can feed in-memory fixtures.

const std = @import("std");
const RingTable = @import("ringTable.zig").RingTable;

const Allocator = std.mem.Allocator;
const Ring = RingTable.Ring;
const Entry = RingTable.Entry;
const AllowedImport = RingTable.AllowedImport;

/// Parse, resolve and classify helpers for Zig import sites.
pub const ImportScanner = struct {
    /// Builtin that names the import target.
    pub const Builtin = enum { import, embedFile };

    /// One production import site found in a source file.
    pub const Import = struct {
        /// Line of the builtin, counted from 1.
        line: u32,
        /// Raw text between the quotes, as a slice of the parsed bytes.
        argument: []const u8,
        /// Builtin that made the reference.
        builtin: Builtin,
    };

    /// Where an import argument points once it is resolved.
    pub const Resolution = union(enum) {
        /// A production file under src/. The caller owns the path.
        file: []u8,
        /// A file whose name ends in Tests.zig.
        testFile,
        /// A named module in the ignored list.
        ignoredModule,
        /// A relative path that leaves src/.
        escapesSource,
        /// A named module that is not in the ignored list.
        unknownModule,
    };

    /// Outcome of checking one production edge against the ring rule.
    pub const Verdict = enum {
        /// The edge points inward, or sideways inside a ring that allows it.
        allowed,
        /// The edge breaks the rule but its file pair is in the allowlist.
        allowlisted,
        /// The edge breaks the rule and is not in the allowlist.
        violation,
        /// One end of the edge has no ring in the table.
        unranked,
    };

    /// Returns true for a .zig file whose name does not end in Tests.zig.
    pub fn isProductionPath(path: []const u8) bool {
        return std.mem.endsWith(u8, path, ".zig") and !std.mem.endsWith(u8, path, "Tests.zig");
    }

    /// Collects every production import in one pass over `bytes`, skipping comments, strings and top-level test blocks.
    pub fn parse(allocator: Allocator, bytes: []const u8) Allocator.Error![]Import {
        var imports: std.ArrayList(Import) = .empty;
        errdefer imports.deinit(allocator);

        var index: usize = 0;
        var line: u32 = 1;
        var depth: usize = 0;
        // Depth at which the current test block opened. Imports are ignored until it closes.
        var testDepth: ?usize = null;
        // Set after a top-level test keyword, until its opening brace.
        var testPending = false;

        while (index < bytes.len) {
            const char = bytes[index];
            const next: u8 = if (index + 1 < bytes.len) bytes[index + 1] else 0;
            switch (char) {
                '\n' => {
                    line += 1;
                    index += 1;
                },
                '/' => {
                    if (next == '/') {
                        index = skipToLineEnd(bytes, index);
                    } else {
                        index += 1;
                    }
                },
                '\\' => {
                    // Outside a literal a backslash pair starts a multiline string line.
                    if (next == '\\') {
                        index = skipToLineEnd(bytes, index);
                    } else {
                        index += 1;
                    }
                },
                '"' => index = skipQuoted(bytes, index, '"'),
                '\'' => index = skipQuoted(bytes, index, '\''),
                '{' => {
                    if (testPending) {
                        testDepth = depth;
                        testPending = false;
                    }
                    depth += 1;
                    index += 1;
                },
                '}' => {
                    if (depth > 0) depth -= 1;
                    if (testDepth) |opened| {
                        if (depth == opened) testDepth = null;
                    }
                    index += 1;
                },
                '@' => {
                    index += 1;
                    if (next == '"') {
                        // A quoted identifier such as @"name".
                        index = skipQuoted(bytes, index, '"');
                        continue;
                    }
                    const wordEnd = identifierEnd(bytes, index);
                    const word = bytes[index..wordEnd];
                    index = wordEnd;
                    const builtin: Builtin = if (std.mem.eql(u8, word, "import"))
                        .import
                    else if (std.mem.eql(u8, word, "embedFile"))
                        .embedFile
                    else
                        continue;
                    const startLine = line;
                    var scanAt = skipSpace(bytes, index, &line);
                    if (scanAt >= bytes.len or bytes[scanAt] != '(') continue;
                    scanAt = skipSpace(bytes, scanAt + 1, &line);
                    if (scanAt >= bytes.len or bytes[scanAt] != '"') {
                        index = scanAt;
                        continue;
                    }
                    // An unterminated argument is not an import the compiler would accept.
                    const closing = closingQuote(bytes, scanAt, '"') orelse {
                        index = skipQuoted(bytes, scanAt, '"');
                        continue;
                    };
                    index = closing + 1;
                    if (testDepth == null) {
                        try imports.append(allocator, .{
                            .line = startLine,
                            .argument = bytes[scanAt + 1 .. closing],
                            .builtin = builtin,
                        });
                    }
                },
                else => {
                    if (isIdentifierStart(char)) {
                        const wordEnd = identifierEnd(bytes, index);
                        const word = bytes[index..wordEnd];
                        index = wordEnd;
                        if (depth == 0 and testDepth == null and std.mem.eql(u8, word, "test")) {
                            var lookahead = index;
                            while (lookahead < bytes.len and isSpace(bytes[lookahead])) lookahead += 1;
                            if (lookahead < bytes.len) {
                                const after = bytes[lookahead];
                                if (after == '"' or after == '{' or after == '@' or isIdentifierStart(after)) {
                                    testPending = true;
                                }
                            }
                        }
                    } else if (char >= '0' and char <= '9') {
                        // Skip a whole number so a digit run never starts a word.
                        index = identifierEnd(bytes, index);
                    } else {
                        index += 1;
                    }
                },
            }
        }
        return imports.toOwnedSlice(allocator);
    }

    /// Resolves an import argument against the importing file's path, which is relative to the repo root.
    pub fn resolve(
        allocator: Allocator,
        importerPath: []const u8,
        argument: []const u8,
        ignoredNames: []const []const u8,
    ) Allocator.Error!Resolution {
        const isFile = std.mem.endsWith(u8, argument, ".zig") or std.mem.endsWith(u8, argument, ".zon");
        if (!isFile) {
            for (ignoredNames) |name| {
                if (std.mem.eql(u8, name, argument)) return .ignoredModule;
            }
            return .unknownModule;
        }
        if (argument.len > 0 and (argument[0] == '/' or argument[0] == '\\')) return .escapesSource;
        if (std.mem.indexOfScalar(u8, argument, ':') != null) return .escapesSource;

        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        const importerDirectory = importerPath[0 .. lastSeparator(importerPath) orelse 0];
        const inputs = [_][]const u8{ importerDirectory, argument };
        for (inputs) |input| {
            var iterator = std.mem.tokenizeAny(u8, input, "/\\");
            while (iterator.next()) |part| {
                if (std.mem.eql(u8, part, ".")) continue;
                if (std.mem.eql(u8, part, "..")) {
                    if (parts.items.len == 0) return .escapesSource;
                    _ = parts.pop();
                    continue;
                }
                try parts.append(allocator, part);
            }
        }
        if (parts.items.len < 2 or !std.mem.eql(u8, parts.items[0], "src")) return .escapesSource;
        if (std.mem.endsWith(u8, parts.items[parts.items.len - 1], "Tests.zig")) return .testFile;
        return .{ .file = try std.mem.join(allocator, "/", parts.items) };
    }

    /// Returns the ring of `path`, or null when the table does not list it.
    pub fn ringOf(entries: []const Entry, path: []const u8) ?Ring {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.ring;
        }
        return null;
    }

    /// Returns true when the file pair is in the allowlist.
    pub fn isAllowlisted(allowed: []const AllowedImport, from: []const u8, to: []const u8) bool {
        for (allowed) |pair| {
            if (std.mem.eql(u8, pair.from, from) and std.mem.eql(u8, pair.to, to)) return true;
        }
        return false;
    }

    /// Checks a production edge from file `from` to file `to` against the ring rule.
    pub fn classify(
        entries: []const Entry,
        allowed: []const AllowedImport,
        from: []const u8,
        to: []const u8,
    ) Verdict {
        const fromRing = ringOf(entries, from) orelse return .unranked;
        const toRing = ringOf(entries, to) orelse return .unranked;
        const fromLevel = @backingInt(fromRing);
        const toLevel = @backingInt(toRing);
        if (toLevel < fromLevel) return .allowed;
        if (toLevel == fromLevel) {
            // Infrastructure files stay apart so each OS concern can be replaced alone.
            if (fromRing != .infrastructure) return .allowed;
            if (std.mem.eql(u8, from, to)) return .allowed;
        }
        return if (isAllowlisted(allowed, from, to)) .allowlisted else .violation;
    }

    fn skipToLineEnd(bytes: []const u8, start: usize) usize {
        return std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
    }

    /// Returns the index of the quote that closes the literal opened at `start`, or null if the line ends first.
    fn closingQuote(bytes: []const u8, start: usize, quote: u8) ?usize {
        var index = start + 1;
        while (index < bytes.len) {
            const char = bytes[index];
            if (char == '\n') return null;
            if (char == '\\') {
                // An escape never swallows the newline, so line counts stay right.
                if (index + 1 < bytes.len and bytes[index + 1] == '\n') return null;
                index += 2;
                continue;
            }
            if (char == quote) return index;
            index += 1;
        }
        return null;
    }

    /// Returns the index just past a literal. A literal cannot span lines, so an unterminated one stops at the newline.
    fn skipQuoted(bytes: []const u8, start: usize, quote: u8) usize {
        if (closingQuote(bytes, start, quote)) |closing| return closing + 1;
        return skipToLineEnd(bytes, start);
    }

    fn skipSpace(bytes: []const u8, start: usize, line: *u32) usize {
        var index = start;
        while (index < bytes.len and isSpace(bytes[index])) : (index += 1) {
            if (bytes[index] == '\n') line.* += 1;
        }
        return index;
    }

    fn identifierEnd(bytes: []const u8, start: usize) usize {
        var index = start;
        while (index < bytes.len and (isIdentifierStart(bytes[index]) or (bytes[index] >= '0' and bytes[index] <= '9'))) index += 1;
        return index;
    }

    fn isIdentifierStart(char: u8) bool {
        return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or char == '_';
    }

    fn isSpace(char: u8) bool {
        return char == ' ' or char == '\t' or char == '\r' or char == '\n';
    }

    fn lastSeparator(path: []const u8) ?usize {
        return std.mem.lastIndexOfAny(u8, path, "/\\");
    }
};
