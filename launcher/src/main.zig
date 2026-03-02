const std = @import("std");
const os = std.os;
const linux = std.os.linux;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const ArrayList = std.ArrayList;

const config = @import("config");
const husi_package_name = config.package_name;
const husi_config_dir_name = "husi";
const husi_exit_restart = 50;

const CAP_VERSION_3: u32 = 0x20080522;
const CAP_DAC_READ_SEARCH = 2;
const CAP_NET_BIND_SERVICE = 10;
const CAP_NET_ADMIN = 12;
const CAP_NET_RAW = 13;
const CAP_SETPCAP = 8;
const CAP_SYS_PTRACE = 19;

const PR_CAP_AMBIENT = 47;
const PR_CAP_AMBIENT_RAISE = 2;

const CapHeader = extern struct {
    version: u32,
    pid: c_int,
};

const CapData = extern struct {
    effective: u32,
    permitted: u32,
    inheritable: u32,
};

fn syscallErrno(rc: usize) linux.E {
    const signed: isize = @bitCast(rc);
    if (signed <= -4096 or signed >= 0) {
        return .SUCCESS;
    }
    return @enumFromInt(@as(usize, @intCast(-signed)));
}

fn capget(header: *CapHeader, data: *[2]CapData) !void {
    const rc = linux.syscall2(.capget, @intFromPtr(header), @intFromPtr(data));
    switch (syscallErrno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

fn capset(header: *const CapHeader, data: *const [2]CapData) !void {
    const rc = linux.syscall2(.capset, @intFromPtr(header), @intFromPtr(data));
    switch (syscallErrno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

fn setInheritableCaps(caps: []const c_int) !void {
    var header = CapHeader{
        .version = CAP_VERSION_3,
        .pid = 0,
    };
    var data = [2]CapData{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };

    try capget(&header, &data);

    for (caps) |cap| {
        const index: u32 = @intCast(@as(u32, @bitCast(cap)) / 32);
        const bit: u32 = @as(u32, 1) << @intCast(@as(u32, @bitCast(cap)) % 32);

        if (index >= 2) {
            std.debug.print("unsupported capability index: {d}\n", .{cap});
            return error.UnsupportedCap;
        }
        if ((data[index].permitted & bit) == 0) {
            std.debug.print("missing permitted capability: {d}\n", .{cap});
            return error.MissingPermittedCap;
        }
        data[index].inheritable |= bit;
    }

    try capset(&header, &data);
}

fn raiseAmbientCaps(caps: []const c_int) !void {
    for (caps) |cap| {
        const rc = linux.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, @intCast(cap), 0, 0);
        switch (syscallErrno(rc)) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn dropSetpcap() !void {
    var header = CapHeader{ .version = CAP_VERSION_3, .pid = 0 };
    var data = [2]CapData{ .{ .effective = 0, .permitted = 0, .inheritable = 0 }, .{ .effective = 0, .permitted = 0, .inheritable = 0 } };

    try capget(&header, &data);

    const index: u32 = @as(u32, CAP_SETPCAP) / 32;
    const bit: u32 = @as(u32, 1) << @intCast(@as(u32, CAP_SETPCAP) % 32);

    data[index].effective &= ~bit;
    data[index].permitted &= ~bit;
    data[index].inheritable &= ~bit;

    try capset(&header, &data);
}

fn readExePath(allocator: mem.Allocator) ![]u8 {
    var buf: [fs.max_path_bytes]u8 = undefined;
    const path = try fs.readLinkAbsolute("/proc/self/exe", &buf);
    return allocator.dupe(u8, path);
}

/// Returns the directory containing the executable (modifies path in-place by removing last component).
fn dirOfPath(path: []const u8) ?[]const u8 {
    const slash = mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return null;
    return path[0..slash];
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and std.ascii.isWhitespace(s[start])) start += 1;
    var end: usize = s.len;
    while (end > start and std.ascii.isWhitespace(s[end - 1])) end -= 1;
    return s[start..end];
}

fn readArgsFile(allocator: mem.Allocator, path: []const u8, list: *ArrayList([]u8)) !void {
    const file = try fs.openFileAbsolute(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var iter = mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = trimWhitespace(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }
}

fn fileExists(path: []const u8) bool {
    fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn ensureDirectoryRecursive(path: []const u8) !void {
    fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            // Create parent first
            const parent = dirOfPath(path) orelse return err;
            try ensureDirectoryRecursive(parent);
            fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => {},
                else => return err2,
            };
        },
        else => return err,
    };
}

fn copyFile(source: []const u8, target: []const u8) !void {
    const src = try fs.openFileAbsolute(source, .{});
    defer src.close();
    const dst = try fs.createFileAbsolute(target, .{});
    defer dst.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
}

fn touchFile(path: []const u8) !void {
    const file = try fs.createFileAbsolute(path, .{ .exclusive = false });
    file.close();
}

fn ensureUserConfigFile(config_path: []const u8, template_path: []const u8) !void {
    if (fileExists(config_path)) return;
    if (fileExists(template_path)) {
        try copyFile(template_path, config_path);
    } else {
        try touchFile(config_path);
    }
}

const RuntimePaths = struct {
    launcher_dir: []u8,
    app_root: []u8,
    jar_path: []u8,
};

fn resolveRuntimePaths(allocator: mem.Allocator) !RuntimePaths {
    const exe_path = try readExePath(allocator);
    defer allocator.free(exe_path);

    const launcher_dir_slice = dirOfPath(exe_path) orelse return error.BadExePath;
    const launcher_dir = try allocator.dupe(u8, launcher_dir_slice);
    errdefer allocator.free(launcher_dir);

    const app_root_slice = dirOfPath(launcher_dir_slice) orelse return error.BadExePath;
    const app_root = try allocator.dupe(u8, app_root_slice);
    errdefer allocator.free(app_root);

    const jar_path = try std.fmt.allocPrint(allocator, "{s}/app/{s}.jar", .{ app_root, husi_package_name });

    return RuntimePaths{
        .launcher_dir = launcher_dir,
        .app_root = app_root,
        .jar_path = jar_path,
    };
}

const UserConfigPaths = struct {
    java_opts_path: []u8,
    app_args_path: []u8,
};

fn resolveUserConfigPaths(allocator: mem.Allocator) !UserConfigPaths {
    var config_base_alloc: ?[]u8 = null;
    defer if (config_base_alloc) |p| allocator.free(p);

    const config_base = blk: {
        if (process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null) |xdg| {
            if (xdg.len > 0) {
                config_base_alloc = xdg;
                break :blk xdg;
            }
            allocator.free(xdg);
        }
        const home = try process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        const path = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        config_base_alloc = path;
        break :blk path;
    };

    const config_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_base, husi_config_dir_name });
    defer allocator.free(config_dir);

    try ensureDirectoryRecursive(config_dir);

    const java_opts_path = try std.fmt.allocPrint(allocator, "{s}/desktop-java-opts.conf", .{config_dir});
    errdefer allocator.free(java_opts_path);
    const app_args_path = try std.fmt.allocPrint(allocator, "{s}/desktop-app-args.conf", .{config_dir});

    return UserConfigPaths{
        .java_opts_path = java_opts_path,
        .app_args_path = app_args_path,
    };
}

fn selectJavaCommand(allocator: mem.Allocator) ![]const u8 {
    if (process.getEnvVarOwned(allocator, "JAVA_HOME") catch null) |java_home| {
        defer allocator.free(java_home);
        if (java_home.len > 0) {
            const bin = try std.fmt.allocPrint(allocator, "{s}/bin/java", .{java_home});
            fs.accessAbsolute(bin, .{}) catch {
                allocator.free(bin);
                // fall through
            };
            return bin; // caller owns
        }
    }
    if (process.getEnvVarOwned(allocator, "JAVA") catch null) |java_env| {
        if (java_env.len > 0) return java_env;
        allocator.free(java_env);
    }
    return allocator.dupe(u8, "java");
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ambient_caps = [_]c_int{
        CAP_NET_ADMIN,
        CAP_NET_RAW,
        CAP_NET_BIND_SERVICE,
        CAP_SYS_PTRACE,
        CAP_DAC_READ_SEARCH,
    };

    setInheritableCaps(&ambient_caps) catch |err| {
        std.debug.print("set_inheritable_caps failed: {}\n", .{err});
        return 1;
    };
    raiseAmbientCaps(&ambient_caps) catch |err| {
        std.debug.print("raise_ambient_caps failed: {}\n", .{err});
        return 1;
    };
    dropSetpcap() catch |err| {
        std.debug.print("drop_setpcap failed: {}\n", .{err});
        return 1;
    };

    const runtime = resolveRuntimePaths(allocator) catch |err| {
        std.debug.print("resolve_runtime_paths failed: {}\n", .{err});
        return 1;
    };
    defer {
        allocator.free(runtime.launcher_dir);
        allocator.free(runtime.app_root);
        allocator.free(runtime.jar_path);
    }

    const java_opts_template = try std.fmt.allocPrint(allocator, "{s}/desktop-java-opts.conf.template", .{runtime.launcher_dir});
    defer allocator.free(java_opts_template);
    const app_args_template = try std.fmt.allocPrint(allocator, "{s}/desktop-app-args.conf.template", .{runtime.launcher_dir});
    defer allocator.free(app_args_template);

    const user_config = resolveUserConfigPaths(allocator) catch |err| {
        std.debug.print("resolve_user_config_paths failed: {}\n", .{err});
        return 1;
    };
    defer {
        allocator.free(user_config.java_opts_path);
        allocator.free(user_config.app_args_path);
    }

    ensureUserConfigFile(user_config.java_opts_path, java_opts_template) catch |err| {
        std.debug.print("ensure java opts config failed: {}\n", .{err});
        return 1;
    };
    ensureUserConfigFile(user_config.app_args_path, app_args_template) catch |err| {
        std.debug.print("ensure app args config failed: {}\n", .{err});
        return 1;
    };

    var java_opts: ArrayList([]u8) = .empty;
    defer {
        for (java_opts.items) |s| allocator.free(s);
        java_opts.deinit(allocator);
    }
    var app_args: ArrayList([]u8) = .empty;
    defer {
        for (app_args.items) |s| allocator.free(s);
        app_args.deinit(allocator);
    }

    readArgsFile(allocator, user_config.java_opts_path, &java_opts) catch |err| {
        std.debug.print("read java opts file failed: {}\n", .{err});
        return 1;
    };
    readArgsFile(allocator, user_config.app_args_path, &app_args) catch |err| {
        std.debug.print("read app args file failed: {}\n", .{err});
        return 1;
    };

    const java_command = selectJavaCommand(allocator) catch "java";
    defer allocator.free(java_command);

    const proc_args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, proc_args);

    // java [java_opts...] -jar <jar> [app_args...] [passthrough args...]
    var child_argv: ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);

    try child_argv.append(allocator, java_command);
    for (java_opts.items) |opt| try child_argv.append(allocator, opt);
    try child_argv.append(allocator, "-jar");
    try child_argv.append(allocator, runtime.jar_path);
    for (app_args.items) |arg| try child_argv.append(allocator, arg);
    for (proc_args[1..]) |arg| try child_argv.append(allocator, arg);

    while (true) {
        var child = std.process.Child.init(child_argv.items, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        child.spawn() catch |err| {
            std.debug.print("spawn failed: {}\n", .{err});
            return 1;
        };

        const term = child.wait() catch |err| {
            std.debug.print("wait failed: {}\n", .{err});
            return 1;
        };

        switch (term) {
            .Exited => |code| {
                if (code == husi_exit_restart) continue;
                return code;
            },
            else => return 1,
        }
    }
}
