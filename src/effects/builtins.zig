//! Built-in effects beyond I/O.

const reshift = @import("reshift");
const Effect = reshift.Effect;

/// Sleep for a given number of nanoseconds.
pub const Sleep = Effect("builtin.Sleep", u64, void);

/// Spawn a new concurrent fiber.
pub const Spawn = Effect("builtin.Spawn", SpawnRequest, SpawnResult);

pub const SpawnRequest = struct {
    entry: *const fn () callconv(.c) void,
};

pub const SpawnResult = struct {
    fiber_id: u64,
};

/// Join (wait for) a spawned fiber.
pub const Join = Effect("builtin.Join", u64, JoinResult);

pub const JoinResult = union(enum) {
    ok: void,
    err: anyerror,
};

/// Log a message.
pub const Log = Effect("builtin.Log", LogRequest, void);

pub const LogRequest = struct {
    level: LogLevel,
    message: []const u8,
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};
