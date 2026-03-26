const std = @import("std");
const http = std.http;
const Io = std.Io;
const net = Io.net;

const loop = @import("../loop.zig");
const protocol = @import("protocol.zig");
const assets = @import("assets.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.webui_server);
const ProbeResult = struct {
    reject: bool = false,
    prefix_len: usize = 0,
    prefix: [9]u8 = [_]u8{0} ** 9,
};

const ProbeReadResult = struct {
    prefix_len: usize = 0,
    err: ?anyerror = null,
};

pub const WebServer = struct {
    allocator: Allocator,
    io: Io,
    runtime: *loop.Runtime,
    port: u16,

    tcp_server_v4: ?net.Server = null,
    tcp_server_v6: ?net.Server = null,
    accept_future_v4: ?Io.Future(void) = null,
    accept_future_v6: ?Io.Future(void) = null,
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
        const address_v4 = try net.IpAddress.parse("0.0.0.0", self.port);
        self.tcp_server_v4 = try net.IpAddress.listen(&address_v4, self.io, .{ .reuse_address = true });
        errdefer {
            if (self.tcp_server_v4) |*server| {
                server.deinit(self.io);
                self.tcp_server_v4 = null;
            }
        }

        const address_v6 = try net.IpAddress.parse("::", self.port);
        self.tcp_server_v6 = net.IpAddress.listen(&address_v6, self.io, .{ .reuse_address = true }) catch null;
        errdefer {
            if (self.tcp_server_v6) |*server| {
                server.deinit(self.io);
                self.tcp_server_v6 = null;
            }
        }

        self.accept_future_v4 = try self.io.concurrent(acceptLoop, .{ self, .v4 });
        errdefer {
            if (self.accept_future_v4) |*f| {
                _ = f.cancel(self.io);
                self.accept_future_v4 = null;
            }
        }

        if (self.tcp_server_v6 != null) {
            self.accept_future_v6 = try self.io.concurrent(acceptLoop, .{ self, .v6 });
        }
    }

    pub fn deinit(self: *WebServer) void {
        // Stop per-connection work first, then stop accepting new connections.
        self.conn_group.cancel(self.io);
        if (self.accept_future_v4) |*f| _ = f.cancel(self.io);
        if (self.accept_future_v6) |*f| _ = f.cancel(self.io);
        if (self.tcp_server_v4) |*server| server.deinit(self.io);
        if (self.tcp_server_v6) |*server| server.deinit(self.io);
    }

    const ListenFamily = enum { v4, v6 };

    fn acceptLoop(self: *WebServer, family: ListenFamily) void {
        var server = switch (family) {
            .v4 => self.tcp_server_v4 orelse return,
            .v6 => self.tcp_server_v6 orelse return,
        };
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

        const probe = probeConnectionPrefix(self.io, stream);
        if (probe.reject) {
            stream.shutdown(self.io, .both) catch {};
            return;
        }

        var read_buf: [1 << 14]u8 = undefined;
        var write_buf: [1 << 14]u8 = undefined;
        var net_reader = stream.reader(self.io, &read_buf);
        if (probe.prefix_len != 0) {
            @memcpy(read_buf[0..probe.prefix_len], probe.prefix[0..probe.prefix_len]);
            net_reader.interface.end = probe.prefix_len;
        }
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

    fn probeConnectionPrefix(io: Io, stream: net.Stream) ProbeResult {
        var result: ProbeResult = .{};
        const read_result = readProbePrefix(io, stream, &result.prefix);
        result.prefix_len = read_result.prefix_len;
        if (read_result.err) |err| {
            if (err != error.Canceled) {
                var addr_buf: [96]u8 = undefined;
                const peer_addr = formatPeerAddress(&addr_buf, stream.socket.address);
                log.debug("probe read failed peer={s}: {s} ({d} bytes)", .{ peer_addr, @errorName(err), result.prefix_len });
            }
            return result;
        }
        if (result.prefix_len == 0) return result;

        result.reject = isLikelyTlsClientHello(result.prefix[0..result.prefix_len]);
        return result;
    }

    /// Routes a single HTTP request. Returns `true` when the connection has been
    /// upgraded to WebSocket (no further HTTP requests should be read).
    fn routeRequest(self: *WebServer, request: *http.Server.Request) bool {
        const parsed = parseTarget(request.head.target) catch {
            request.respond("bad request", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                    .{ .name = "server", .value = assets.server_header },
                },
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
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                    .{ .name = "server", .value = assets.server_header },
                },
            }) catch {};
            return false;
        }

        assets.servePath(request, parsed.path) catch {};
        return false;
    }
};

fn isLikelyTlsClientHello(data: []const u8) bool {
    if (data.len < 5) return false;
    if (data[0] != 0x16 or data[1] != 0x03 or data[2] > 0x04) return false;
    if (std.mem.readInt(u16, data[3..5], .big) == 0) return false;
    if (data.len >= 6 and data[5] != 0x01) return false;
    return true;
}

fn readProbePrefix(io: Io, stream: net.Stream, buf: []u8) ProbeReadResult {
    var total: usize = 0;
    while (total < buf.len) {
        var vec = [_][]u8{buf[total..]};
        const n = io.vtable.netRead(io.userdata, stream.socket.handle, vec[0..]) catch |err| {
            return .{ .prefix_len = total, .err = err };
        };
        if (n == 0) return .{ .prefix_len = total };

        total += n;

        if (total >= 1 and buf[0] != 0x16) return .{ .prefix_len = total };
        if (total >= 2 and buf[1] != 0x03) return .{ .prefix_len = total };
        if (total >= 3 and buf[2] > 0x04) return .{ .prefix_len = total };
        if (total >= 5) return .{ .prefix_len = total };
    }
    return .{ .prefix_len = total };
}

fn formatPeerAddress(buf: *[96]u8, addr: net.IpAddress) []const u8 {
    return switch (addr) {
        .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3], a.port }) catch "unknown",
        .ip6 => |a| std.fmt.bufPrint(buf, "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]:{d}", .{
            std.mem.readInt(u16, a.bytes[0..2], .big),
            std.mem.readInt(u16, a.bytes[2..4], .big),
            std.mem.readInt(u16, a.bytes[4..6], .big),
            std.mem.readInt(u16, a.bytes[6..8], .big),
            std.mem.readInt(u16, a.bytes[8..10], .big),
            std.mem.readInt(u16, a.bytes[10..12], .big),
            std.mem.readInt(u16, a.bytes[12..14], .big),
            std.mem.readInt(u16, a.bytes[14..16], .big),
            a.port,
        }) catch "unknown",
    };
}

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
                _ = runtime.submitQuery(q.agent_id, q.client_query_id, q.text, .interactive) catch {};
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
