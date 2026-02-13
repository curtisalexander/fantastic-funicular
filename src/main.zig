const std = @import("std");

const version = "0.1.0";

// ─── Argument parsing ───────────────────────────────────────────────────────

const Command = enum {
    hash,
    fence,
    prompt,
    help,
    version,
};

const Args = struct {
    command: Command,
    // hash flags
    algorithm: HashAlgorithm = .xxhash,
    // fence flags
    fence_mode: FenceMode = .extract,
    fence_lang: ?[]const u8 = null,
    // prompt flags
    count_tokens: bool = false,
    // positional
    positionals: []const []const u8 = &.{},
};

const HashAlgorithm = enum { xxhash, sha256 };
const FenceMode = enum { extract, wrap };

fn parseArgs(allocator: std.mem.Allocator) !Args {
    const argv = try std.process.argsAlloc(allocator);

    if (argv.len < 2) {
        return .{ .command = .help };
    }

    const cmd_str = argv[1];

    const command: Command = if (std.mem.eql(u8, cmd_str, "hash"))
        .hash
    else if (std.mem.eql(u8, cmd_str, "fence"))
        .fence
    else if (std.mem.eql(u8, cmd_str, "prompt"))
        .prompt
    else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h"))
        .help
    else if (std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "-V"))
        .version
    else
        .help;

    var args = Args{ .command = command };
    var positionals: std.ArrayList([]const u8) = .empty;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--sha256")) {
            args.algorithm = .sha256;
        } else if (std.mem.eql(u8, arg, "--xxhash")) {
            args.algorithm = .xxhash;
        } else if (std.mem.eql(u8, arg, "--extract")) {
            args.fence_mode = .extract;
        } else if (std.mem.eql(u8, arg, "--wrap")) {
            args.fence_mode = .wrap;
        } else if (std.mem.eql(u8, arg, "--lang")) {
            i += 1;
            if (i < argv.len) {
                args.fence_lang = argv[i];
            }
        } else if (std.mem.eql(u8, arg, "--tokens") or std.mem.eql(u8, arg, "-t")) {
            args.count_tokens = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.command = .help;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positionals.append(allocator, arg);
        }
    }

    args.positionals = try positionals.toOwnedSlice(allocator);
    return args;
}

// ─── Commands ───────────────────────────────────────────────────────────────

/// Hash: content-addressable hashing of files or stdin.
/// Useful for caching LLM responses keyed by input content.
fn cmdHash(args: Args) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    if (args.positionals.len == 0) {
        // Read from stdin
        const stdin = std.fs.File.stdin();
        const content = try stdin.readToEndAlloc(std.heap.page_allocator, 1024 * 1024 * 256);
        try hashAndPrint(stdout, content, "-", args.algorithm);
    } else {
        for (args.positionals) |path| {
            const content = readFile(path) catch |err| {
                var stderr_buf: [256]u8 = undefined;
                var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
                const stderr = &stderr_w.interface;
                stderr.print("aipipe: {s}: {}\n", .{ path, err }) catch {};
                stderr.flush() catch {};
                continue;
            };
            try hashAndPrint(stdout, content, path, args.algorithm);
        }
    }
}

fn hashAndPrint(writer: *std.Io.Writer, content: []const u8, name: []const u8, algorithm: HashAlgorithm) !void {
    switch (algorithm) {
        .xxhash => {
            const hash = std.hash.XxHash64.hash(0, content);
            try writer.print("{x:0>16}  {s}\n", .{ hash, name });
        },
        .sha256 => {
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
            for (digest) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.print("  {s}\n", .{name});
        },
    }
}

fn readFile(path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024 * 256);
}

/// Fence: extract or wrap fenced code blocks in LLM output.
fn cmdFence(args: Args) !void {
    const stdin = std.fs.File.stdin();
    const content = try stdin.readToEndAlloc(std.heap.page_allocator, 1024 * 1024 * 256);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    switch (args.fence_mode) {
        .extract => try extractFences(stdout, content, args.fence_lang),
        .wrap => try wrapFence(stdout, content, args.fence_lang),
    }
}

fn extractFences(writer: *std.Io.Writer, content: []const u8, lang_filter: ?[]const u8) !void {
    var in_fence = false;
    var fence_lang: []const u8 = "";
    var block_count: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (!in_fence) {
            if (std.mem.startsWith(u8, trimmed, "```")) {
                in_fence = true;
                fence_lang = std.mem.trimRight(u8, trimmed[3..], " \t\r");

                // Apply language filter
                if (lang_filter) |filter| {
                    if (!std.mem.eql(u8, fence_lang, filter)) {
                        // Skip this block — read until closing fence
                        while (lines.next()) |skip_line| {
                            const skip_trimmed = std.mem.trimLeft(u8, skip_line, " \t");
                            if (std.mem.startsWith(u8, skip_trimmed, "```")) break;
                        }
                        in_fence = false;
                        continue;
                    }
                }

                if (block_count > 0) {
                    try writer.writeAll("\n");
                }
                block_count += 1;
            }
        } else {
            if (std.mem.startsWith(u8, trimmed, "```")) {
                in_fence = false;
            } else {
                try writer.writeAll(line);
                try writer.writeAll("\n");
            }
        }
    }
}

fn wrapFence(writer: *std.Io.Writer, content: []const u8, lang: ?[]const u8) !void {
    try writer.writeAll("```");
    if (lang) |l| {
        try writer.writeAll(l);
    }
    try writer.writeAll("\n");
    try writer.writeAll(content);
    // Ensure trailing newline before closing fence
    if (content.len > 0 and content[content.len - 1] != '\n') {
        try writer.writeAll("\n");
    }
    try writer.writeAll("```\n");
}

/// Prompt: concatenate files into a prompt with headers and optional token counting.
fn cmdPrompt(args: Args) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    var total_tokens: usize = 0;

    if (args.positionals.len == 0) {
        // Read from stdin
        const stdin = std.fs.File.stdin();
        const content = try stdin.readToEndAlloc(std.heap.page_allocator, 1024 * 1024 * 256);
        try stdout.writeAll(content);
        if (args.count_tokens) {
            total_tokens = estimateTokens(content);
        }
    } else {
        for (args.positionals, 0..) |path, idx| {
            const content = readFile(path) catch |err| {
                var stderr_buf: [256]u8 = undefined;
                var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
                const stderr = &stderr_w.interface;
                stderr.print("aipipe: {s}: {}\n", .{ path, err }) catch {};
                stderr.flush() catch {};
                continue;
            };

            if (idx > 0) {
                try stdout.writeAll("\n");
            }

            // Write file header
            try stdout.writeAll("--- ");
            try stdout.writeAll(path);
            try stdout.writeAll(" ---\n");
            try stdout.writeAll(content);
            if (content.len > 0 and content[content.len - 1] != '\n') {
                try stdout.writeAll("\n");
            }

            if (args.count_tokens) {
                total_tokens += estimateTokens(content);
            }
        }
    }

    if (args.count_tokens) {
        var stderr_buf: [256]u8 = undefined;
        var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_w.interface;
        try stderr.print("~{d} tokens\n", .{total_tokens});
        try stderr.flush();
    }
}

/// Estimate token count using the ~4 chars per token heuristic.
fn estimateTokens(content: []const u8) usize {
    return (content.len + 3) / 4;
}

// ─── Help ───────────────────────────────────────────────────────────────────

fn printHelp() !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    try stdout.writeAll(
        \\aipipe - fast utilities for AI agent workflows
        \\
        \\USAGE:
        \\  aipipe <command> [options] [files...]
        \\
        \\COMMANDS:
        \\  hash      Content-addressable hashing of files or stdin
        \\  fence     Extract or wrap fenced code blocks
        \\  prompt    Concatenate files into a prompt with headers
        \\  help      Show this help message
        \\
        \\HASH OPTIONS:
        \\  --xxhash   Use xxHash64 (default, extremely fast)
        \\  --sha256   Use SHA-256
        \\
        \\FENCE OPTIONS:
        \\  --extract  Extract code from fenced blocks (default)
        \\  --wrap     Wrap stdin in a fenced code block
        \\  --lang <L> Filter by / set language tag
        \\
        \\PROMPT OPTIONS:
        \\  -t, --tokens  Print estimated token count to stderr
        \\
        \\EXAMPLES:
        \\  echo "hello" | aipipe hash
        \\  aipipe hash --sha256 file1.txt file2.txt
        \\  cat llm_output.md | aipipe fence --lang python
        \\  aipipe prompt -t src/*.zig
        \\  echo "x = 1" | aipipe fence --wrap --lang python
        \\
    );
}

fn printVersion() !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    try stdout.print("aipipe {s}\n", .{version});
}

// ─── Main ───────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);

    switch (args.command) {
        .hash => try cmdHash(args),
        .fence => try cmdFence(args),
        .prompt => try cmdPrompt(args),
        .help => try printHelp(),
        .version => try printVersion(),
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "estimateTokens" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("hi"));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("abcd"));
    try std.testing.expectEqual(@as(usize, 3), estimateTokens("hello world!"));
}

test "extractFences" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const input =
        \\Here is some code:
        \\```python
        \\print("hello")
        \\```
        \\And more text.
        \\```javascript
        \\console.log("hi")
        \\```
    ;

    // Extract all
    try extractFences(&aw.writer, input, null);
    try std.testing.expectEqualStrings("print(\"hello\")\n\nconsole.log(\"hi\")\n", aw.written());

    // Extract only python
    aw.clearRetainingCapacity();
    try extractFences(&aw.writer, input, "python");
    try std.testing.expectEqualStrings("print(\"hello\")\n", aw.written());
}

test "wrapFence" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try wrapFence(&aw.writer, "x = 1", "python");
    try std.testing.expectEqualStrings("```python\nx = 1\n```\n", aw.written());
}

test "hashAndPrint xxhash" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try hashAndPrint(&aw.writer, "hello\n", "test.txt", .xxhash);
    const result = aw.written();
    // Should be 16 hex chars + two spaces + filename + newline
    try std.testing.expect(result.len > 20);
    try std.testing.expect(std.mem.endsWith(u8, result, "  test.txt\n"));
}

test "hashAndPrint sha256" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try hashAndPrint(&aw.writer, "hello\n", "test.txt", .sha256);
    const result = aw.written();
    // SHA-256 = 64 hex chars + two spaces + filename + newline
    try std.testing.expect(result.len == 64 + 2 + 8 + 1);
    try std.testing.expect(std.mem.endsWith(u8, result, "  test.txt\n"));
}
