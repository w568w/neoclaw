const std = @import("std");
const schema = @import("../schema.zig");
const loop = @import("../loop.zig");

var fallback_nonce_counter: std.atomic.Value(u64) = .init(1);

pub const name = "code_run";
pub const description = "Run Python or Bash code snippet.";

pub const Params = struct {
    type: enum { python, bash } = .python,
    code: []const u8,
    timeout: u32 = 10,
    cwd: ?[]const u8 = null,
};

const Job = struct {
    io: std.Io,
    code_type: @FieldType(Params, "type"),
    code: []const u8,
    timeout: u32,
    cwd: ?[]const u8,
};

pub fn start(ctx: *schema.ToolContext, params: Params, allocator: std.mem.Allocator) !loop.ToolStartResult {
    const job = try allocator.create(Job);
    errdefer allocator.destroy(job);

    job.* = .{
        .io = ctx.io,
        .code_type = params.type,
        .code = try allocator.dupe(u8, params.code),
        .timeout = params.timeout,
        .cwd = if (params.cwd) |cwd| try allocator.dupe(u8, cwd) else null,
    };

    return .{ .wait = .{ .worker = .{
        .ptr = job,
        .runFn = runJob,
        .deinitFn = deinitJob,
    } } };
}

fn runJob(ptr: *anyopaque, allocator: std.mem.Allocator) ![]const u8 {
    const job: *Job = @ptrCast(@alignCast(ptr));

    const ext = switch (job.code_type) {
        .python => "py",
        .bash => "sh",
    };
    const nonce = try randomNonceHex(allocator);
    defer allocator.free(nonce);
    const temp_name = try std.fmt.allocPrint(allocator, ".neoclaw_tmp_{s}.{s}", .{ nonce, ext });
    defer allocator.free(temp_name);

    const base_dir = job.cwd orelse ".";
    const temp_path = try std.fs.path.resolve(allocator, &.{ base_dir, temp_name });
    defer allocator.free(temp_path);
    try std.Io.Dir.cwd().writeFile(job.io, .{ .sub_path = temp_path, .data = job.code, .flags = .{ .truncate = true } });
    defer std.Io.Dir.cwd().deleteFile(job.io, temp_path) catch {};

    const argv = switch (job.code_type) {
        .python => [_][]const u8{ "python3", temp_path },
        .bash => [_][]const u8{ "bash", temp_path },
    };

    const timeout = (std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromSeconds(@intCast(job.timeout)),
        .clock = .awake,
    } }).toDeadline(job.io);

    const result = try std.process.run(allocator, job.io, .{
        .argv = &argv,
        .cwd = if (job.cwd) |cwd| .{ .path = cwd } else .inherit,
        .timeout = timeout,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("exit={f}\n", .{std.json.fmt(result.term, .{})});
    if (result.stdout.len > 0) {
        try out.writer.writeAll("[stdout]\n");
        try out.writer.writeAll(result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try out.writer.writeAll("\n");
    }
    if (result.stderr.len > 0) {
        try out.writer.writeAll("[stderr]\n");
        try out.writer.writeAll(result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try out.writer.writeAll("\n");
    }

    return out.toOwnedSlice();
}

fn deinitJob(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const job: *Job = @ptrCast(@alignCast(ptr));
    allocator.free(job.code);
    if (job.cwd) |cwd| allocator.free(cwd);
    allocator.destroy(job);
}

fn randomNonceHex(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [8]u8 = undefined;
    try fillRandom(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

fn fillRandom(buf: []u8) !void {
    const seed = fallback_nonce_counter.fetchAdd(1, .monotonic);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
}
