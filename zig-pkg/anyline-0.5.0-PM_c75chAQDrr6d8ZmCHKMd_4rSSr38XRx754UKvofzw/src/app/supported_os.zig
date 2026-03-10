const builtin = @import("builtin");

const SupportedOs = enum {
    windows,
    linux,
    macos,
    freebsd,

    pub inline fn isBSD(self: SupportedOs) bool {
        return switch (self) {
            .macos, .freebsd => true,
            .windows, .linux => false,
        };
    }
};

pub const SUPPORTED_OS = switch (builtin.os.tag) {
    .windows => SupportedOs.windows,
    .linux => SupportedOs.linux,
    .macos => SupportedOs.macos,
    .freebsd => SupportedOs.freebsd,
    else => |tag| @compileError(@tagName(tag) ++ " is not a supported OS!"),
};

pub const NEW_LINE = switch (SUPPORTED_OS) {
    .linux, .macos, .freebsd => "\n",
    .windows => "\r\n",
};
pub const ENV_HOME_PATH = switch (SUPPORTED_OS) {
    .linux, .macos, .freebsd => "HOME",
    .windows => "USERPROFILE",
};
