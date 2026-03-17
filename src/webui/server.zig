const std = @import("std");
const http = std.http;
const Io = std.Io;
const net = Io.net;

const loop = @import("../loop.zig");
const protocol = @import("protocol.zig");
const assets = @import("assets.zig");

const Allocator = std.mem.Allocator;

pub const WebServer = struct {
    allocator: Allocator,
    io: Io,
    runtime: *loop.Runtime,
    port: u16,

    tcp_server: ?net.Server = null,
    accept_future: ?Io.Future(void) = null,
    conn_group: Io.Group = .init,

    pub fn init(allocator: Allocator, io: Io, runtime: *loop.Runtime, port: u16) WebServer {
        return .{
            .allocator = allocator,
            .io = io,
            .runtime = runtime,
            .port = port,
        };
    }

    pub fn start(self: *WebServer) !void {
        const address = try net.IpAddress.parse("0.0.0.0", self.port);
        self.tcp_server = try net.IpAddress.listen(address, self.io, .{ .reuse_address = true });
        self.accept_future = try self.io.concurrent(acceptLoop, .{self});
    }

    pub fn deinit(self: *WebServer) void {
        // Stop per-connection work first, then stop accepting new connections.
        self.conn_group.cancel(self.io);
        if (self.accept_future) |*f| _ = f.cancel(self.io);
        if (self.tcp_server) |*server| server.deinit(self.io);
    }

    fn acceptLoop(self: *WebServer) void {
        var server = self.tcp_server orelse return;
        while (true) {
            const stream = server.accept(self.io) catch |err| switch (err) {
                error.Canceled => return,
                else => continue,
            };

            self.conn_group.concurrent(self.io, handleConnection, .{ self, stream }) catch {
                stream.close(self.io);
                continue;
            };
        }
    }

    fn handleConnection(self: *WebServer, stream: net.Stream) void {
        defer stream.close(self.io);

        var read_buf: [1 << 14]u8 = undefined;
        var write_buf: [1 << 14]u8 = undefined;
        var net_reader = stream.reader(self.io, &read_buf);
        var net_writer = stream.writer(self.io, &write_buf);
        var server = http.Server.init(&net_reader.interface, &net_writer.interface);

        while (true) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => return,
            };

            if (routeRequest(self, &request))
                // WebSocket upgrade consumed the connection.
                return;
        }
    }

    /// Routes a single HTTP request. Returns `true` when the connection has been
    /// upgraded to WebSocket (no further HTTP requests should be read).
    fn routeRequest(self: *WebServer, request: *http.Server.Request) bool {
        const parsed = parseTarget(request.head.target) catch {
            request.respond("bad request", .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
            }) catch {};
            return false;
        };

        if (std.mem.eql(u8, parsed.path, "/ws")) {
            switch (request.upgradeRequested()) {
                .websocket => |key_opt| {
                    if (key_opt) |key| {
                        WsSession.run(self.allocator, self.io, self.runtime, request, key, parseFromParam(self.allocator, parsed.query));
                        return true;
                    }
                },
                else => {},
            }

            request.respond("WebSocket upgrade required", .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
            }) catch {};
            return false;
        }

        assets.servePath(request, parsed.path) catch {};
        return false;
    }
};

// -- URI parsing helpers --

const ParsedTarget = struct {
    path: []const u8,
    query: ?[]const u8,
};

fn parseTarget(raw_target: []const u8) error{InvalidTarget}!ParsedTarget {
    const uri = std.Uri.parseAfterScheme("", raw_target) catch return error.InvalidTarget;
    return .{
        .path = uriComponentSlice(uri.path),
        .query = if (uri.query) |q| uriComponentSlice(q) else null,
    };
}

fn parseFromParam(allocator: Allocator, query: ?[]const u8) loop.EventSeq {
    const encoded_val = getQueryParam(query, "from") orelse return 0;
    const buf = allocator.dupe(u8, encoded_val) catch return 0;
    defer allocator.free(buf);
    const decoded = std.Uri.percentDecodeInPlace(buf);
    return std.fmt.parseInt(loop.EventSeq, decoded, 10) catch 0;
}

fn getQueryParam(query: ?[]const u8, key: []const u8) ?[]const u8 {
    const q = query orelse return null;
    var parts = std.mem.splitScalar(u8, q, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        if (!std.mem.eql(u8, part[0..eq], key)) continue;
        if (eq == part.len) return "";
        return part[eq + 1 ..];
    }
    return null;
}

fn uriComponentSlice(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
}

// -- WebSocket session --

const WsSession = struct {
    ws: *http.Server.WebSocket,
    runtime: *loop.Runtime,
    allocator: Allocator,
    sub: loop.Subscription,
    pusher_future: ?Io.Future(void) = null,

    fn run(
        allocator: Allocator,
        io: Io,
        runtime: *loop.Runtime,
        request: *http.Server.Request,
        key: []const u8,
        from_seq: loop.EventSeq,
    ) void {
        var ws = request.respondWebSocket(.{ .key = key }) catch return;
        ws.flush() catch return;

        const sub_from: loop.SubscribeFrom = if (from_seq > 0) .{ .seq = from_seq } else .tail;
        var self: WsSession = .{
            .ws = &ws,
            .runtime = runtime,
            .allocator = allocator,
            .sub = runtime.event_log.subscribe(sub_from),
        };

        self.pusher_future = io.concurrent(pushEvents, .{&self}) catch return;
        defer {
            if (self.pusher_future) |*future| _ = future.cancel(io);
        }

        self.runCommandLoop();
    }

    fn runCommandLoop(self: *WsSession) void {
        while (true) {
            const msg = self.ws.readSmallMessage() catch return;
            if (msg.opcode != .text and msg.opcode != .binary) continue;

            var cmd = protocol.parseCommand(self.allocator, msg.data) catch continue;
            defer cmd.deinit(self.allocator);
            dispatchCommand(self.runtime, cmd);
        }
    }

    fn dispatchCommand(runtime: *loop.Runtime, cmd: protocol.Command) void {
        switch (cmd) {
            .query => |q| {
                _ = runtime.submitQuery(q.agent_id, q.text, .interactive) catch {};
            },
            .reply => |r| {
                _ = runtime.submitReply(r.agent_id, r.syscall_id, r.text) catch {};
            },
            .cancel => |c| {
                _ = runtime.cancelAgent(c.agent_id) catch {};
            },
        }
    }

    fn pushEvents(session: *WsSession) void {
        while (true) {
            const record_opt = session.runtime.event_log.recv(&session.sub) catch return;
            const record_const = record_opt orelse return;
            var record = record_const;
            defer record.deinit(session.allocator);

            const json = protocol.serializeEvent(session.allocator, record) catch continue;
            defer session.allocator.free(json);

            session.ws.writeMessage(json, .text) catch return;
        }
    }
};
