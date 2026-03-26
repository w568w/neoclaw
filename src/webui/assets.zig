const std = @import("std");
const http = std.http;
const build_options = @import("build_options");

pub const Asset = struct {
    content: []const u8,
    mime: []const u8,
};

pub const server_header = "neoclaw/" ++ build_options.version;

const file_map = std.StaticStringMap(Asset).initComptime(.{
    .{ "/", Asset{ .content = @embedFile("index.html"), .mime = "text/html; charset=utf-8" } },
    .{ "/index.html", Asset{ .content = @embedFile("index.html"), .mime = "text/html; charset=utf-8" } },
    .{ "/style.css", Asset{ .content = @embedFile("style.css"), .mime = "text/css; charset=utf-8" } },
    .{ "/app.js", Asset{ .content = @embedFile("app.js"), .mime = "application/javascript; charset=utf-8" } },
});

pub fn servePath(request: *http.Server.Request, path: []const u8) !void {
    if (file_map.get(path)) |asset| {
        try request.respond(asset.content, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = asset.mime },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "server", .value = server_header },
            },
        });
    } else {
        try request.respond("not found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
                .{ .name = "server", .value = server_header },
            },
        });
    }
}
