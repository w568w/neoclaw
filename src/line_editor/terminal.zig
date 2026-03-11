const std = @import("std");
const builtin = @import("builtin");

pub const Terminal = if (builtin.os.tag == .windows) WindowsTerminal else PosixTerminal;

const PosixTerminal = struct {
    const posix = std.posix;

    orig_termios: ?posix.termios = null,

    /// Enables raw mode on stdin. Returns true if raw mode was enabled,
    /// or error.NotATerminal if stdin is not a terminal.
    pub fn enableRawMode(self: *PosixTerminal) !bool {
        self.orig_termios = posix.tcgetattr(posix.STDIN_FILENO) catch |err| switch (err) {
            error.NotATerminal => return error.NotATerminal,
            else => return err,
        };
        var raw = self.orig_termios.?;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        return true;
    }

    pub fn disableRawMode(self: *PosixTerminal) void {
        if (self.orig_termios) |orig| {
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig) catch {};
            self.orig_termios = null;
        }
    }

    pub fn readByte(_: *PosixTerminal) !u8 {
        var buf: [1]u8 = undefined;
        while (true) {
            const rc = std.os.linux.read(posix.STDIN_FILENO, &buf, 1);
            const e = std.os.linux.errno(rc);
            if (e == .SUCCESS) {
                if (rc == 0) return error.EndOfStream;
                return buf[0];
            }
            if (e == .INTR) continue;
            return error.ReadFailed;
        }
    }

    pub fn writeAll(_: *PosixTerminal, data: []const u8) void {
        var written: usize = 0;
        while (written < data.len) {
            const rc = std.os.linux.write(
                posix.STDOUT_FILENO,
                data[written..].ptr,
                data.len - written,
            );
            const e = std.os.linux.errno(rc);
            if (e == .SUCCESS) {
                written += rc;
            } else if (e == .INTR) {
                continue;
            } else {
                return;
            }
        }
    }
};

const WindowsTerminal = struct {
    const windows = std.os.windows;
    const ntdll = windows.ntdll;
    const HANDLE = windows.HANDLE;
    const NTSTATUS = windows.NTSTATUS;

    const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
    const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;

    orig_input_mode: ?windows.DWORD = null,
    orig_output_mode: ?windows.DWORD = null,

    fn stdinHandle() HANDLE {
        return windows.peb().ProcessParameters.hStdInput;
    }

    fn stdoutHandle() HANDLE {
        return windows.peb().ProcessParameters.hStdOutput;
    }

    fn consoleHandle() HANDLE {
        return windows.peb().ProcessParameters.ConsoleHandle;
    }

    fn getConsoleMode(console: HANDLE, file: HANDLE) !windows.DWORD {
        var get_mode = windows.CONSOLE.USER_IO.GET_MODE;
        var request = get_mode.request(
            .{ .handle = file, .flags = .{ .nonblocking = false } },
            0,
            .{},
            0,
            .{},
        );
        var io_status: windows.IO_STATUS_BLOCK = undefined;
        const status = ntdll.NtDeviceIoControlFile(
            console,
            null,
            null,
            null,
            &io_status,
            windows.IOCTL.CONDRV.ISSUE_USER_IO,
            @ptrCast(&request),
            @sizeOf(@TypeOf(request)),
            null,
            0,
        );
        if (status != .SUCCESS) return error.NotATerminal;
        return get_mode.Data;
    }

    fn setConsoleMode(console: HANDLE, file: HANDLE, mode: windows.DWORD) !void {
        var set_mode = windows.CONSOLE.USER_IO.SET_MODE(mode);
        var request = set_mode.request(
            .{ .handle = file, .flags = .{ .nonblocking = false } },
            0,
            .{},
            0,
            .{},
        );
        var io_status: windows.IO_STATUS_BLOCK = undefined;
        const status = ntdll.NtDeviceIoControlFile(
            console,
            null,
            null,
            null,
            &io_status,
            windows.IOCTL.CONDRV.ISSUE_USER_IO,
            @ptrCast(&request),
            @sizeOf(@TypeOf(request)),
            null,
            0,
        );
        if (status != .SUCCESS) return error.SetModeFailed;
    }

    pub fn enableRawMode(self: *WindowsTerminal) !bool {
        const console = consoleHandle();
        const stdin = stdinHandle();
        const stdout = stdoutHandle();

        self.orig_input_mode = getConsoleMode(console, stdin) catch
            return error.NotATerminal;
        self.orig_output_mode = getConsoleMode(console, stdout) catch null;

        const raw_input = (self.orig_input_mode.? &
            ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) |
            ENABLE_VIRTUAL_TERMINAL_INPUT;
        setConsoleMode(console, stdin, raw_input) catch return error.NotATerminal;

        if (self.orig_output_mode) |out_mode| {
            setConsoleMode(console, stdout, out_mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) catch {};
        }

        return true;
    }

    pub fn disableRawMode(self: *WindowsTerminal) void {
        const console = consoleHandle();
        if (self.orig_input_mode) |mode| {
            setConsoleMode(console, stdinHandle(), mode) catch {};
            self.orig_input_mode = null;
        }
        if (self.orig_output_mode) |mode| {
            setConsoleMode(console, stdoutHandle(), mode) catch {};
            self.orig_output_mode = null;
        }
    }

    pub fn readByte(_: *WindowsTerminal) !u8 {
        var buf: [1]u8 = undefined;
        var io_status: windows.IO_STATUS_BLOCK = undefined;
        const status = ntdll.NtReadFile(
            stdinHandle(),
            null,
            null,
            null,
            &io_status,
            &buf,
            1,
            null,
            null,
        );
        if (status == .SUCCESS) {
            if (io_status.Information == 0) return error.EndOfStream;
            return buf[0];
        }
        return error.ReadFailed;
    }

    pub fn writeAll(_: *WindowsTerminal, data: []const u8) void {
        if (data.len == 0) return;
        var written: usize = 0;
        while (written < data.len) {
            var io_status: windows.IO_STATUS_BLOCK = undefined;
            const remaining = data.len - written;
            const chunk: windows.ULONG = @intCast(@min(remaining, std.math.maxInt(windows.ULONG)));
            const status = ntdll.NtWriteFile(
                stdoutHandle(),
                null,
                null,
                null,
                &io_status,
                @ptrCast(data[written..].ptr),
                chunk,
                null,
                null,
            );
            if (status != .SUCCESS) return;
            written += io_status.Information;
        }
    }
};
