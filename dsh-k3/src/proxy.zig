//! 单线程 epoll 事件循环的 TCP 负载均衡/转发核心。
//!
//! 模型：所有 socket 非阻塞，注册进同一个 epoll；每个连接两个方向各一个
//! 定长缓冲，EPOLLIN 读到 EAGAIN，写不动时挂 EPOLLOUT。一侧读 EOF 后，
//! 把残余数据冲刷给对端再 shutdown(WR)（半关闭），两侧都结束才关闭整条
//! 连接。信号（SIGHUP/SIGUSR1/SIGTERM/SIGINT）走 signalfd 进同一个事件循环。
//!
//! 与 Go 参考实现的行为对应关系：
//!   - 接受连接后立即加权随机选后端并发起连接（非阻塞 connect，5 秒超时）；
//!   - 选不出后端（weightSum<=0）或拨号失败：直接关闭客户端连接并打日志；
//!   - 两侧 socket 都打开 TCP keepalive（60 秒）；
//!   - SIGHUP 重载配置，失败保留旧配置；SIGUSR1 打印运行状态；
//!     SIGTERM/SIGINT 退出事件循环。

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const addrz = @import("addr.zig");
const configz = @import("config.zig");
const selector = @import("selector.zig");
const Allocator = std.mem.Allocator;

pub const BUF_CAP = 32 * 1024;
const MAX_EVENTS = 128;
const CONNECT_TIMEOUT_MS = 5000;
const LISTEN_BACKLOG = 512;

const TAG_LISTENER: usize = 0;
const TAG_SIGNAL: usize = 2;
const TAG_WAKE: usize = 4;

/// 打日志到 stderr（单行，带前缀）。热路径上的格式化都在栈上完成。
pub fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "gopf: " ++ fmt ++ "\n", args) catch return;
    _ = linux.write(2, s.ptr, s.len);
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

fn seedNow() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @bitCast(@as(i64, ts.sec) *% 1_000_000_000 +% ts.nsec)) ^ @as(u64, @intCast(linux.getpid()));
}

/// 一个方向的转发缓冲：head..tail 为待写数据。
const Buf = struct {
    data: [BUF_CAP]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,

    fn len(self: *const Buf) usize {
        return self.tail - self.head;
    }
    fn empty(self: *const Buf) bool {
        return self.tail == self.head;
    }
    /// 是否还有空间可写入（必要时先压缩）。
    fn space(self: *const Buf) bool {
        return self.head > 0 or self.tail < self.data.len;
    }
    fn writable(self: *Buf) []u8 {
        if (self.tail == self.data.len and self.head > 0) {
            const n = self.tail - self.head;
            std.mem.copyForwards(u8, self.data[0..n], self.data[self.head..self.tail]);
            self.head = 0;
            self.tail = n;
        }
        return self.data[self.tail..];
    }
    fn readable(self: *const Buf) []const u8 {
        return self.data[self.head..self.tail];
    }
    fn commit(self: *Buf, n: usize) void {
        self.tail += n;
    }
    fn consume(self: *Buf, n: usize) void {
        self.head += n;
        if (self.head == self.tail) {
            self.head = 0;
            self.tail = 0;
        }
    }
};

pub const Conn = struct {
    client: i32 = -1,
    backend: i32 = -1,
    c2b: Buf = .{}, // 客户端 → 后端
    b2c: Buf = .{}, // 后端 → 客户端
    c_read_done: bool = false, // 客户端读侧已 EOF
    b_read_done: bool = false, // 后端读侧已 EOF
    c_wr_shut: bool = false, // 已对客户端 shutdown(WR)
    b_wr_shut: bool = false, // 已对后端 shutdown(WR)
    connecting: bool = false, // 后端 connect 尚未完成
    deadline_ms: i64 = 0, // connect 超时 deadline
    c_interest: u32 = 0, // 当前 client fd 在 epoll 里的事件位
    b_interest: u32 = 0, // 当前 backend fd 在 epoll 里的事件位
    next: ?*Conn = null, // 全局连接链表 / 空闲链表
    backend_text: [64]u8 = undefined,
    backend_text_len: usize = 0,

    fn backendText(self: *const Conn) []const u8 {
        return self.backend_text[0..self.backend_text_len];
    }
};

const IoResult = enum { ok, eof, hard };

pub const Proxy = struct {
    alloc: Allocator,
    cfg: *configz.Config,
    cfg_path: []u8,
    rng: std.Random.DefaultPrng,

    epfd: i32 = -1,
    listen_fd: i32 = -1,
    sig_fd: i32 = -1,
    wake_fd: i32 = -1,
    bound: addrz.Ip4 = .{ .octets = .{ 0, 0, 0, 0 }, .port = 0 },

    all_head: ?*Conn = null, // 所有活跃连接
    free_head: ?*Conn = null, // 空闲连接池（复用，稳态零分配）

    active: u32 = 0,
    total: u64 = 0,
    stop_flag: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator, listen_addr: addrz.Ip4, cfg: *configz.Config, cfg_path: []const u8) !Proxy {
        var self = Proxy{
            .alloc = alloc,
            .cfg = cfg,
            .cfg_path = try alloc.dupe(u8, cfg_path),
            .rng = std.Random.DefaultPrng.init(seedNow()),
        };
        errdefer alloc.free(self.cfg_path);

        // epoll 实例
        const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(ep_rc) != .SUCCESS) return error.EpollCreateFailed;
        self.epfd = @intCast(ep_rc);
        errdefer _ = linux.close(self.epfd);

        // 监听 socket
        const lfd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(lfd_rc) != .SUCCESS) return error.SocketFailed;
        self.listen_fd = @intCast(lfd_rc);
        errdefer _ = linux.close(self.listen_fd);

        setSockOptI32(self.listen_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
        var sa = listen_addr.sockaddrIn();
        if (linux.errno(linux.bind(self.listen_fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
            return error.BindFailed;
        if (linux.errno(linux.listen(self.listen_fd, LISTEN_BACKLOG)) != .SUCCESS)
            return error.ListenFailed;
        var bound_sa: linux.sockaddr.in = undefined;
        var bound_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getsockname(self.listen_fd, @ptrCast(&bound_sa), &bound_len)) == .SUCCESS)
            self.bound = addrz.Ip4.fromSockaddrIn(bound_sa);

        // signalfd：SIGHUP/SIGUSR1/SIGTERM/SIGINT（要求调用方已 sigprocmask 屏蔽）
        var mask = posix.sigemptyset();
        posix.sigaddset(&mask, .HUP);
        posix.sigaddset(&mask, .USR1);
        posix.sigaddset(&mask, .TERM);
        posix.sigaddset(&mask, .INT);
        self.sig_fd = posix.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC) catch return error.SignalFdFailed;
        errdefer _ = linux.close(self.sig_fd);

        // eventfd：跨线程请求停止（测试用）
        const wfd_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.errno(wfd_rc) != .SUCCESS) return error.EventFdFailed;
        self.wake_fd = @intCast(wfd_rc);
        errdefer _ = linux.close(self.wake_fd);

        try self.epollAddTag(self.listen_fd, TAG_LISTENER, linux.EPOLL.IN);
        try self.epollAddTag(self.sig_fd, TAG_SIGNAL, linux.EPOLL.IN);
        try self.epollAddTag(self.wake_fd, TAG_WAKE, linux.EPOLL.IN);
        return self;
    }

    pub fn deinit(self: *Proxy) void {
        var it = self.all_head;
        while (it) |c| {
            const next = c.next;
            if (c.client >= 0) _ = linux.close(c.client);
            if (c.backend >= 0) _ = linux.close(c.backend);
            self.alloc.destroy(c);
            it = next;
        }
        while (self.free_head) |c| {
            const next = c.next;
            self.alloc.destroy(c);
            self.free_head = next;
        }
        if (self.listen_fd >= 0) _ = linux.close(self.listen_fd);
        if (self.sig_fd >= 0) _ = linux.close(self.sig_fd);
        if (self.wake_fd >= 0) _ = linux.close(self.wake_fd);
        if (self.epfd >= 0) _ = linux.close(self.epfd);
        self.cfg.deinit();
        self.alloc.destroy(self.cfg);
        self.alloc.free(self.cfg_path);
    }

    /// 请求事件循环停止（可跨线程调用）。
    pub fn stop(self: *Proxy) void {
        self.stop_flag.store(true, .release);
        const val: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&val), 8);
    }

    /// 主事件循环：直到 stop() 被调用或收到 SIGTERM/SIGINT 才返回。
    pub fn run(self: *Proxy) void {
        var events: [MAX_EVENTS]linux.epoll_event = undefined;
        while (!self.stop_flag.load(.acquire)) {
            const rc = linux.epoll_wait(self.epfd, &events, MAX_EVENTS, 1000);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => continue,
            }
            for (events[0..rc]) |ev| self.dispatch(ev);
            self.scanTimeouts();
        }
    }

    // -----------------------------------------------------------------------
    // 事件分发
    // -----------------------------------------------------------------------

    fn dispatch(self: *Proxy, ev: linux.epoll_event) void {
        const d = ev.data.ptr;
        if (d < 8) {
            switch (d) {
                TAG_LISTENER => self.acceptAll(),
                TAG_SIGNAL => self.onSignal(),
                TAG_WAKE => self.onWake(),
                else => {},
            }
            return;
        }
        const conn: *Conn = @ptrFromInt(d & ~@as(usize, 1));
        self.onConn(conn, (d & 1) == 1, ev.events);
    }

    fn epollAddTag(self: *Proxy, fd: i32, tag: usize, events: u32) !void {
        var ev = linux.epoll_event{ .events = events, .data = .{ .ptr = tag } };
        if (linux.errno(linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS)
            return error.EpollCtlFailed;
    }

    fn epollAddConn(self: *Proxy, fd: i32, conn: *Conn, backend: bool, events: u32) void {
        var ev = linux.epoll_event{ .events = events, .data = .{ .ptr = @intFromPtr(conn) | @intFromBool(backend) } };
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
    }

    fn epollModConn(self: *Proxy, fd: i32, conn: *Conn, backend: bool, events: u32) void {
        var ev = linux.epoll_event{ .events = events, .data = .{ .ptr = @intFromPtr(conn) | @intFromBool(backend) } };
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev);
    }

    // -----------------------------------------------------------------------
    // 接受连接 + 选后端 + 发起连接
    // -----------------------------------------------------------------------

    fn acceptAll(self: *Proxy) void {
        while (true) {
            var peer: linux.sockaddr.in = undefined;
            var plen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.accept4(self.listen_fd, @ptrCast(&peer), &plen, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return,
                .INTR => continue,
                else => |e| {
                    logf("accept error: errno={s}", .{@tagName(e)});
                    return;
                },
            }
            const cfd: i32 = @intCast(rc);
            self.total += 1;
            self.active += 1;
            self.serveClient(cfd, &peer);
        }
    }

    fn serveClient(self: *Proxy, cfd: i32, peer: *const linux.sockaddr.in) void {
        var pbuf: [64]u8 = undefined;
        const peer_text = addrz.Ip4.fromSockaddrIn(peer.*).formatBuf(&pbuf);

        const idx = selector.choose(self.cfg, self.rng.random()) orelse {
            logf("accepted {s} but no available backend; closing", .{peer_text});
            _ = linux.close(cfd);
            self.active -|= 1;
            return;
        };
        const host = &self.cfg.hosts[idx];

        const bfd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(bfd_rc) != .SUCCESS) {
            logf("accepted {s} but socket() failed; closing", .{peer_text});
            _ = linux.close(cfd);
            self.active -|= 1;
            return;
        }
        const bfd: i32 = @intCast(bfd_rc);

        var sa = host.addr.sockaddrIn();
        const crc = linux.connect(bfd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
        var connecting = false;
        switch (linux.errno(crc)) {
            .SUCCESS => {},
            .INPROGRESS => connecting = true,
            else => |e| {
                logf("dial backend {s} for {s} failed: errno={s}", .{ host.text, peer_text, @tagName(e) });
                _ = linux.close(bfd);
                _ = linux.close(cfd);
                self.active -|= 1;
                return;
            },
        }

        setSockOptI32(cfd, linux.SOL.SOCKET, linux.SO.KEEPALIVE, 1);
        setSockOptI32(cfd, linux.IPPROTO.TCP, linux.TCP.KEEPIDLE, 60);
        setSockOptI32(bfd, linux.SOL.SOCKET, linux.SO.KEEPALIVE, 1);
        setSockOptI32(bfd, linux.IPPROTO.TCP, linux.TCP.KEEPIDLE, 60);
        setSockOptI32(cfd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
        setSockOptI32(bfd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);

        const conn = self.allocConn() orelse {
            logf("out of memory for connection from {s}; closing", .{peer_text});
            _ = linux.close(bfd);
            _ = linux.close(cfd);
            self.active -|= 1;
            return;
        };
        conn.* = .{
            .client = cfd,
            .backend = bfd,
            .connecting = connecting,
            .deadline_ms = nowMs() + CONNECT_TIMEOUT_MS,
        };
        const bt = host.text;
        const blen = @min(bt.len, conn.backend_text.len);
        @memcpy(conn.backend_text[0..blen], bt[0..blen]);
        conn.backend_text_len = blen;

        conn.c_interest = computeInterest(conn, false);
        conn.b_interest = computeInterest(conn, true);
        self.epollAddConn(conn.client, conn, false, conn.c_interest);
        self.epollAddConn(conn.backend, conn, true, conn.b_interest);

        conn.next = self.all_head;
        self.all_head = conn;

        logf("accepted {s} -> backend {s}", .{ peer_text, bt });
    }

    // -----------------------------------------------------------------------
    // 连接读写
    // -----------------------------------------------------------------------

    fn onConn(self: *Proxy, conn: *Conn, backend: bool, events: u32) void {
        const fd = if (backend) conn.backend else conn.client;
        if (fd < 0) return;

        // 非阻塞 connect 完成判定
        if (backend and conn.connecting) {
            if (events & (linux.EPOLL.OUT | linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
                var val: i32 = 0;
                var vlen: linux.socklen_t = @sizeOf(i32);
                _ = linux.getsockopt(conn.backend, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&val), &vlen);
                if (val != 0) {
                    logf("dial backend {s} failed: errno={d}", .{ conn.backendText(), val });
                    self.closeConn(conn);
                    return;
                }
                conn.connecting = false;
            }
        }

        // 读
        if (events & (linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
            switch (self.doRead(conn, backend)) {
                .ok => {},
                .eof => {
                    if (backend) conn.b_read_done = true else conn.c_read_done = true;
                },
                .hard => {
                    self.closeConn(conn);
                    return;
                },
            }
        }

        // 写
        if (events & linux.EPOLL.OUT != 0) {
            if (self.doWrite(conn, backend) == .hard) {
                self.closeConn(conn);
                return;
            }
        }

        self.settle(conn);
    }

    fn doRead(self: *Proxy, conn: *Conn, backend: bool) IoResult {
        _ = self;
        const fd = if (backend) conn.backend else conn.client;
        const buf = if (backend) &conn.b2c else &conn.c2b;
        while (true) {
            const w = buf.writable();
            if (w.len == 0) return .ok; // 缓冲满：等对端可写后再开 EPOLLIN
            const rc = linux.read(fd, w.ptr, w.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return .eof;
                    buf.commit(rc);
                },
                .AGAIN => return .ok,
                .INTR => continue,
                else => return .hard,
            }
        }
    }

    fn doWrite(self: *Proxy, conn: *Conn, backend: bool) IoResult {
        _ = self;
        const fd = if (backend) conn.backend else conn.client;
        const buf = if (backend) &conn.c2b else &conn.b2c;
        while (!buf.empty()) {
            const r = buf.readable();
            const rc = linux.sendto(fd, r.ptr, r.len, linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return .ok;
                    buf.consume(rc);
                },
                .AGAIN => return .ok,
                .INTR => continue,
                else => return .hard,
            }
        }
        return .ok;
    }

    /// 每次处理完事件后的状态收敛：EOF 传播半关闭、关闭完成的 fd、
    /// 按最新状态刷新 epoll 关注事件、整条连接结束则回收。
    fn settle(self: *Proxy, conn: *Conn) void {
        if (!conn.connecting) {
            if (conn.c_read_done and !conn.b_wr_shut and conn.c2b.empty()) {
                if (conn.backend >= 0) _ = linux.shutdown(conn.backend, linux.SHUT.WR);
                conn.b_wr_shut = true;
            }
            if (conn.b_read_done and !conn.c_wr_shut and conn.b2c.empty()) {
                if (conn.client >= 0) _ = linux.shutdown(conn.client, linux.SHUT.WR);
                conn.c_wr_shut = true;
            }
        }

        if (conn.client >= 0 and conn.c_read_done and conn.c_wr_shut) {
            _ = linux.close(conn.client);
            conn.client = -1;
            conn.c_interest = 0;
        }
        if (conn.backend >= 0 and conn.b_read_done and conn.b_wr_shut) {
            _ = linux.close(conn.backend);
            conn.backend = -1;
            conn.b_interest = 0;
        }
        if (conn.client < 0 and conn.backend < 0) {
            self.closeConn(conn);
            return;
        }

        self.refreshInterest(conn, false);
        self.refreshInterest(conn, true);
    }

    fn computeInterest(conn: *Conn, backend: bool) u32 {
        const fd = if (backend) conn.backend else conn.client;
        if (fd < 0) return 0;
        var ev: u32 = 0;
        const rd_done = if (backend) conn.b_read_done else conn.c_read_done;
        const wr_shut = if (backend) conn.b_wr_shut else conn.c_wr_shut;
        const in_buf = if (backend) &conn.b2c else &conn.c2b; // 从该 fd 读，填入此缓冲
        const out_buf = if (backend) &conn.c2b else &conn.b2c; // 写到该 fd 的数据
        if (backend and conn.connecting) {
            ev |= linux.EPOLL.OUT; // 等待 connect 完成
        } else {
            if (!rd_done and in_buf.space()) ev |= linux.EPOLL.IN | linux.EPOLL.RDHUP;
            if (!wr_shut and !out_buf.empty()) ev |= linux.EPOLL.OUT;
        }
        return ev;
    }

    fn refreshInterest(self: *Proxy, conn: *Conn, backend: bool) void {
        const fd = if (backend) conn.backend else conn.client;
        if (fd < 0) return;
        const want = computeInterest(conn, backend);
        const cur = if (backend) conn.b_interest else conn.c_interest;
        if (want == cur) return;
        self.epollModConn(fd, conn, backend, want);
        if (backend) conn.b_interest = want else conn.c_interest = want;
    }

    fn closeConn(self: *Proxy, conn: *Conn) void {
        if (conn.client >= 0) {
            _ = linux.close(conn.client);
            conn.client = -1;
        }
        if (conn.backend >= 0) {
            _ = linux.close(conn.backend);
            conn.backend = -1;
        }
        self.active -|= 1;
        var pp: *?*Conn = &self.all_head;
        while (pp.*) |c| {
            if (c == conn) {
                pp.* = c.next;
                break;
            }
            pp = &c.next;
        }
        conn.next = self.free_head;
        self.free_head = conn;
    }

    fn allocConn(self: *Proxy) ?*Conn {
        if (self.free_head) |c| {
            self.free_head = c.next;
            return c;
        }
        return self.alloc.create(Conn) catch null;
    }

    fn scanTimeouts(self: *Proxy) void {
        var it = self.all_head;
        if (it == null) return;
        const now = nowMs();
        while (it) |conn| {
            const next = conn.next;
            if (conn.connecting and conn.deadline_ms < now) {
                logf("dial backend {s} timed out after 5s", .{conn.backendText()});
                self.closeConn(conn);
            }
            it = next;
        }
    }

    // -----------------------------------------------------------------------
    // 信号处理（在事件循环线程内执行）
    // -----------------------------------------------------------------------

    fn onSignal(self: *Proxy) void {
        while (true) {
            var infos: [8]linux.signalfd_siginfo = undefined;
            const rc = linux.read(self.sig_fd, @ptrCast(&infos), @sizeOf(@TypeOf(infos)));
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return,
                .INTR => continue,
                else => return,
            }
            const n = rc / @sizeOf(linux.signalfd_siginfo);
            if (n == 0) return;
            for (infos[0..n]) |info| {
                if (info.signo == @intFromEnum(linux.SIG.HUP)) {
                    self.reload();
                } else if (info.signo == @intFromEnum(linux.SIG.USR1)) {
                    self.status();
                } else if (info.signo == @intFromEnum(linux.SIG.TERM) or info.signo == @intFromEnum(linux.SIG.INT)) {
                    logf("received signal {d}, shutting down", .{info.signo});
                    self.stop();
                }
            }
            if (n < infos.len) return;
        }
    }

    fn onWake(self: *Proxy) void {
        var buf: [8]u8 = undefined;
        _ = linux.read(self.wake_fd, &buf, 8);
    }

    /// SIGHUP：重新加载配置；失败保留旧配置并打日志。
    pub fn reload(self: *Proxy) void {
        logf("reloading config from {s}", .{self.cfg_path});
        const new_cfg = self.alloc.create(configz.Config) catch {
            logf("config reload failed: out of memory; keeping old config", .{});
            return;
        };
        new_cfg.* = configz.loadFile(self.alloc, self.cfg_path) catch |e| {
            self.alloc.destroy(new_cfg);
            logf("config reload failed: {s}; keeping old config", .{@errorName(e)});
            return;
        };
        const old = self.cfg;
        self.cfg = new_cfg;
        old.deinit();
        self.alloc.destroy(old);
        logf("config reloaded: {d} backend(s), weight_sum={d}", .{ self.cfg.hosts.len, self.cfg.weight_sum });
        for (self.cfg.hosts) |h| logf("  backend {s} weight={d}", .{ h.text, h.weight });
    }

    /// SIGUSR1：打印运行状态。
    pub fn status(self: *Proxy) void {
        logf("status: active_conns={d} total_conns={d} backends={d} weight_sum={d}", .{
            self.active, self.total, self.cfg.hosts.len, self.cfg.weight_sum,
        });
        for (self.cfg.hosts) |h| logf("  backend {s} weight={d}", .{ h.text, h.weight });
    }
};

fn setSockOptI32(fd: i32, level: i32, optname: u32, val: i32) void {
    _ = linux.setsockopt(fd, level, optname, std.mem.asBytes(&val), @sizeOf(i32));
}

// ---------------------------------------------------------------------------
// 集成测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sleepMs(ms: u32) void {
    const ts = linux.timespec{ .sec = ms / 1000, .nsec = @as(i64, ms % 1000) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}

fn blockTestSignals() void {
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, .HUP);
    posix.sigaddset(&mask, .USR1);
    posix.sigaddset(&mask, .TERM);
    posix.sigaddset(&mask, .INT);
    posix.sigprocmask(linux.SIG.BLOCK, &mask, null);
}

/// 测试用回显/横幅服务器：独立线程跑 accept 循环。
const TestServer = struct {
    fd: i32,
    port: u16,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    banner: []const u8 = "",

    fn start(banner: ?[]const u8) !*TestServer {
        const alloc = std.heap.page_allocator;
        const self = try alloc.create(TestServer);
        errdefer alloc.destroy(self);
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        self.* = .{ .fd = @intCast(rc), .port = 0 };
        setSockOptI32(self.fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
        var sa = (addrz.Ip4{ .octets = .{ 127, 0, 0, 1 }, .port = 0 }).sockaddrIn();
        if (linux.errno(linux.bind(self.fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
            return error.BindFailed;
        if (linux.errno(linux.listen(self.fd, 64)) != .SUCCESS) return error.ListenFailed;
        var got: linux.sockaddr.in = undefined;
        var glen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getsockname(self.fd, @ptrCast(&got), &glen)) != .SUCCESS)
            return error.GetSockNameFailed;
        self.port = std.mem.bigToNative(u16, got.port);
        if (banner) |b| self.banner = b;
        self.thread = try std.Thread.spawn(.{}, TestServer.loop, .{self});
        return self;
    }

    fn loop(self: *TestServer) void {
        var pfd = [1]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        while (!self.stop_flag.load(.acquire)) {
            pfd[0].revents = 0;
            const rc = linux.poll(&pfd, 1, 50);
            if (linux.errno(rc) != .SUCCESS or rc == 0) continue;
            const cfd_rc = linux.accept4(self.fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(cfd_rc) != .SUCCESS) continue;
            const cfd: i32 = @intCast(cfd_rc);
            if (self.banner.len > 0) {
                writeAll(cfd, self.banner) catch {};
                _ = linux.close(cfd);
                continue;
            }
            const t = std.Thread.spawn(.{}, TestServer.echoHandler, .{cfd}) catch {
                _ = linux.close(cfd);
                continue;
            };
            t.detach();
        }
        _ = linux.close(self.fd);
    }

    fn echoHandler(cfd: i32) void {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const rc = linux.read(cfd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    writeAll(cfd, buf[0..rc]) catch break;
                },
                .INTR => continue,
                else => break,
            }
        }
        _ = linux.close(cfd);
    }

    fn stop(self: *TestServer) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| t.join();
        std.heap.page_allocator.destroy(self);
    }
};

fn writeAll(fd: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn dial(port: u16) !i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    var sa = (addrz.Ip4{ .octets = .{ 127, 0, 0, 1 }, .port = port }).sockaddrIn();
    if (linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
        return error.ConnectFailed;
    // 读超时，防止实现出 bug 时测试卡死
    const tv = linux.timeval{ .sec = 3, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    return fd;
}

/// 读到 EOF 为止，返回读到的字节（可能少于 buf.len）。
fn readToEof(fd: i32, buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.read(fd, buf.ptr + n, buf.len - n);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                n += rc;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock, // 读超时触发
            else => return error.ReadFailed,
        }
    }
    return n;
}

fn readN(fd: i32, buf: []u8) !void {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.read(fd, buf.ptr + n, buf.len - n);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.EndOfStream;
                n += rc;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.ReadFailed,
        }
    }
}

const Running = struct {
    proxy: *Proxy,
    thread: std.Thread,

    fn stop(self: *Running) void {
        self.proxy.stop();
        self.thread.join();
        self.proxy.deinit();
        std.heap.page_allocator.destroy(self.proxy);
    }
};

/// 起一个在 127.0.0.1:0 上监听的代理实例（独立线程跑事件循环）。
/// 注意：Proxy 必须在堆上，事件循环线程与测试主线程共享同一对象。
fn startProxy(cfg_json: []const u8, cfg_path: []const u8) !Running {
    const alloc = std.heap.page_allocator;
    const cfg = try alloc.create(configz.Config);
    cfg.* = try configz.parse(alloc, cfg_json);
    const p = try alloc.create(Proxy);
    p.* = try Proxy.init(alloc, .{ .octets = .{ 127, 0, 0, 1 }, .port = 0 }, cfg, cfg_path);
    errdefer {
        p.deinit();
        alloc.destroy(p);
    }
    const t = try std.Thread.spawn(.{}, Proxy.run, .{p});
    return .{ .proxy = p, .thread = t };
}

test "forward: small packet echo" {
    blockTestSignals();
    const echo = try TestServer.start(null);
    defer echo.stop();

    var cfg_buf: [128]u8 = undefined;
    const cfg_json = std.fmt.bufPrint(&cfg_buf, "{{\"hosts\":[{{\"addr\":\"127.0.0.1:{d}\",\"weight\":1}}]}}", .{echo.port}) catch unreachable;
    var r = try startProxy(cfg_json, "/tmp/gopf-itest-none.conf");
    defer r.stop();

    const c = try dial(r.proxy.bound.port);
    defer _ = linux.close(c);
    const msg = "hello gopf!";
    try writeAll(c, msg);
    var buf: [64]u8 = undefined;
    try readN(c, buf[0..msg.len]);
    try testing.expectEqualStrings(msg, buf[0..msg.len]);
}

test "forward: half-close still delivers remaining data" {
    blockTestSignals();
    const echo = try TestServer.start(null);
    defer echo.stop();

    var cfg_buf: [128]u8 = undefined;
    const cfg_json = std.fmt.bufPrint(&cfg_buf, "{{\"hosts\":[{{\"addr\":\"127.0.0.1:{d}\",\"weight\":1}}]}}", .{echo.port}) catch unreachable;
    var r = try startProxy(cfg_json, "/tmp/gopf-itest-none.conf");
    defer r.stop();

    const c = try dial(r.proxy.bound.port);
    defer _ = linux.close(c);
    const msg = "half-close me please";
    try writeAll(c, msg);
    // 半关闭：客户端不再写，但还要读完回声
    _ = linux.shutdown(c, linux.SHUT.WR);
    var buf: [128]u8 = undefined;
    const n = try readToEof(c, &buf);
    try testing.expectEqual(msg.len, n);
    try testing.expectEqualStrings(msg, buf[0..n]);
}

test "forward: 1 MiB payload byte-identical" {
    blockTestSignals();
    const echo = try TestServer.start(null);
    defer echo.stop();

    var cfg_buf: [128]u8 = undefined;
    const cfg_json = std.fmt.bufPrint(&cfg_buf, "{{\"hosts\":[{{\"addr\":\"127.0.0.1:{d}\",\"weight\":1}}]}}", .{echo.port}) catch unreachable;
    var r = try startProxy(cfg_json, "/tmp/gopf-itest-none.conf");
    defer r.stop();

    const alloc = std.heap.page_allocator;
    const total = 1 << 20;
    const send_buf = try alloc.alloc(u8, total);
    defer alloc.free(send_buf);
    const recv_buf = try alloc.alloc(u8, total);
    defer alloc.free(recv_buf);
    var x: u32 = 0x12345678;
    for (send_buf, 0..) |*b, i| {
        x = x *% 1664525 +% 1013904223;
        b.* = @as(u8, @truncate(x >> 13)) ^ @as(u8, @truncate(i));
    }

    const c = try dial(r.proxy.bound.port);
    defer _ = linux.close(c);
    try writeAll(c, send_buf);
    _ = linux.shutdown(c, linux.SHUT.WR);
    const n = try readToEof(c, recv_buf);
    try testing.expectEqual(total, n);
    try testing.expectEqualSlices(u8, send_buf, recv_buf);
}

test "forward: no available backend closes connection" {
    blockTestSignals();
    var r = try startProxy("{\"hosts\":[{\"addr\":\"127.0.0.1:1\",\"weight\":0}]}", "/tmp/gopf-itest-none.conf");
    defer r.stop();

    const c = try dial(r.proxy.bound.port);
    defer _ = linux.close(c);
    var buf: [8]u8 = undefined;
    const n = try readToEof(c, &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "forward: backend dial failure closes connection" {
    blockTestSignals();
    // 127.0.0.1:1 没有人监听，connect 必被拒。
    const cfg_json = "{\"hosts\":[{\"addr\":\"127.0.0.1:1\",\"weight\":1}]}";
    var r = try startProxy(cfg_json, "/tmp/gopf-itest-none.conf");
    defer r.stop();

    const c = try dial(r.proxy.bound.port);
    defer _ = linux.close(c);
    var buf: [8]u8 = undefined;
    const n = try readToEof(c, &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "reload via SIGHUP changes backend selection; failed reload keeps old" {
    blockTestSignals();
    const srv_a = try TestServer.start("A");
    defer srv_a.stop();
    const srv_b = try TestServer.start("B");
    defer srv_b.stop();

    // 配置文件（真实落盘，供 SIGHUP 重载）
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/gopf-itest-{d}.conf", .{linux.getpid()}) catch unreachable;
    defer {
        var pbuf: [4096]u8 = undefined;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        _ = linux.unlinkat(linux.AT.FDCWD, pbuf[0..path.len :0].ptr, 0);
    }
    var cfg_buf: [160]u8 = undefined;
    const cfg_a = std.fmt.bufPrint(&cfg_buf, "{{\"hosts\":[{{\"addr\":\"127.0.0.1:{d}\",\"weight\":1}}]}}", .{srv_a.port}) catch unreachable;
    try configz.writeTestFile(path, cfg_a);

    const alloc = std.heap.page_allocator;
    const cfg = try alloc.create(configz.Config);
    cfg.* = try configz.loadFile(alloc, path);
    const p = try alloc.create(Proxy);
    p.* = try Proxy.init(alloc, .{ .octets = .{ 127, 0, 0, 1 }, .port = 0 }, cfg, path);
    var r = Running{ .proxy = p, .thread = try std.Thread.spawn(.{}, Proxy.run, .{p}) };
    defer r.stop();

    // 初始应命中 A
    {
        const c = try dial(r.proxy.bound.port);
        defer _ = linux.close(c);
        var b: [1]u8 = undefined;
        try readN(c, &b);
        try testing.expectEqual(@as(u8, 'A'), b[0]);
    }

    // 改成 B 并发 SIGHUP；在有限时间内应观察到新配置生效
    const cfg_b = std.fmt.bufPrint(&cfg_buf, "{{\"hosts\":[{{\"addr\":\"127.0.0.1:{d}\",\"weight\":1}}]}}", .{srv_b.port}) catch unreachable;
    try configz.writeTestFile(path, cfg_b);
    _ = linux.kill(linux.getpid(), .HUP);
    var saw_b = false;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        sleepMs(20);
        const c = dial(r.proxy.bound.port) catch continue;
        var b: [1]u8 = undefined;
        const got = readN(c, &b) catch {
            _ = linux.close(c);
            continue;
        };
        _ = linux.close(c);
        _ = got;
        if (b[0] == 'B') {
            saw_b = true;
            break;
        }
    }
    try testing.expect(saw_b);

    // 写一份非法配置再发 SIGHUP：重载应失败并保留旧配置（仍是 B）
    try configz.writeTestFile(path, "{not valid json");
    _ = linux.kill(linux.getpid(), .HUP);
    sleepMs(300);
    {
        const c = try dial(r.proxy.bound.port);
        defer _ = linux.close(c);
        var b: [1]u8 = undefined;
        try readN(c, &b);
        try testing.expectEqual(@as(u8, 'B'), b[0]);
    }
}
