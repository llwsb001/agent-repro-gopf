# gopf-zig

用 **Zig 0.17.0** 复现的 [gopf](https://github.com/RaindyRoye/gopf)：一个 Go 写的四层（TCP）负载均衡器。
语义对齐参考实现（`main.go`，308 行）：加权**随机**选后端、双向转发 + 半关闭、5 秒拨号超时、60 秒 TCP keepalive、SIGHUP 热重载、SIGUSR1 状态、SIGTERM/SIGINT 退出。

## 编译与运行

```bash
zig build                            # Debug 版 → zig-out/bin/gopf
zig build -Doptimize=ReleaseFast     # 优化版（压测用这个）
zig build test                       # 单元测试 + 真实 TCP 集成测试，一条命令全跑

./zig-out/bin/gopf -listen 127.0.0.1:12481 settings.conf
# 默认监听 :1248；第一个位置参数是 JSON 配置路径
```

配置格式（键名大小写不敏感，兼容 Go `encoding/json` 的行为，`Hosts/Addr/Weight` 也能读）：

```json
{ "hosts": [ { "addr": "127.0.0.1:18091", "weight": 100 } ] }
```

信号：

```bash
kill -HUP  <pid>   # 重载配置；失败保留旧配置并打错误日志
kill -USR1 <pid>   # 打印 active/total 连接数 + 当前配置摘要
kill -TERM <pid>   # 退出（SIGINT 同）
```

日志（带时间戳）输出到 stderr：接受连接、拨号失败、重载结果等。

## 目录结构

```
build.zig            # zig build / zig build test
src/main.zig         # CLI、信号自管道、accept 循环
src/config.zig       # JSON 解析/校验、SplitHostPort、加权随机选择、可热重载的 Store（含单元测试）
src/proxy.zig        # 连接生命周期：选后端→拨号→keepalive→双向 pump
src/sys.zig          # 裸系统调用封装：非阻塞 connect+poll 超时拨号、listen、文件读写等
src/log.zig          # Go log 风格时间戳日志
src/integration.zig  # 真实 TCP 集成测试（回显服务/固定应答服务 + 代理实例）
settings.conf        # 示例配置
bench.md             # 性能数据与分析
```

## 设计取舍

### 线程模型：每连接 1 线程 + 单线程 poll 双向 pump

- Go 原版每连接 3 个 goroutine（handleConn + 两个方向的 io.Copy）。这里每连接只 spawn **1 个 OS 线程**（1 MiB 栈），线程内用 `poll(2)` 同时监视两端可读事件，一个循环完成双向拷贝——省掉一半执行实体与跨 goroutine 同步。
- 一侧读到 EOF/错误 → 对另一端 `shutdown(SHUT_WR)`（半关闭），让对向在途数据继续 drain；两个方向都结束才 close 两个 fd。与 Go 的 `CloseWrite/CloseRead + WaitGroup` 语义等价。
- 写方向是阻塞 `write` 循环：极端情况下对端接收窗口满会短暂阻塞本线程的另一方向转发，但 TCP 缓冲足以吸收常规请求/响应模式；这是用"每连接单线程"换简单性与低开销的自觉取舍（Go 的双 goroutine 模型同样受内核缓冲约束）。
- 主线程 accept 循环也是 `poll`：同时监听 listen fd 与**信号自管道**。信号处理函数只往非阻塞管道写一个字节（async-signal-safe），重载/状态/退出都在主循环里串行执行，避免在信号上下文里做解析/分配。
- `SIGPIPE` 设为忽略（Go 隐式如此），写已死连接得到 `EPIPE` 而不是进程被杀。

### 内存分配策略

- 热路径**零堆分配**：两个 32 KiB 拷贝缓冲直接在连接线程栈上；选后端只在锁内把地址字符串拷进栈上 300 B 缓冲，连接线程绝不引用配置内存。
- 配置用 `page_allocator` 解析（`std.json` 动态 Value），校验通过后只保留 `[]Host`（地址字符串 dup 一份）。
- 热重载：先完整解析+校验新配置，成功后在互斥锁内整体换入、锁外释放旧配置；失败则旧配置原封不动。锁是自旋+`yield` 的极简互斥（0.17 移除了 `std.Thread.Mutex`），临界区只有指针交换/地址拷贝，竞争极低。
- 随机数：全局一个 Xoshiro256（`std.Random.DefaultPrng`），时间戳^pid 播种，选择时短暂加锁；`uintLessThan` 无偏采样，等价 Go `rand.Intn(weightSum)`。

### 为什么大量裸系统调用

Zig 0.17 删掉了旧 `std.net`，新的 `std.Io` 网络尚未实现完整（带超时的 `connect` 会 panic），`std.fs`/`std.time` 的多数便捷函数也已 Io 化或移除。因此 socket/拨号/文件/时钟全部走 `std.os.linux` 裸系统调用 + `std.posix` 残留封装；**唯一链接 libc 的理由是 `getaddrinfo`**（DNS/服务名解析，自己写 DNS 客户端得不偿失）。拨号超时按任务要求自己实现：非阻塞 `connect` + `poll(POLLOUT, 5000ms)` + `getsockopt(SO_ERROR)`，成功后恢复阻塞模式。

### 语义对齐细节

- 加权随机：`rand[0, weightSum)` 落累计权重区间；`weightSum<=0` 直接关连接；weight=0 的后端永远不会被选中。
- 校验完全复刻 Go `net.SplitHostPort`（含 `[v6]:port`、空 host/空 port 合法、多冒号/缺括号非法）；任一非法条目使整次加载失败；weight 负数报错，缺省/null 视为 0，非整数报错。
- 两侧 TCP keepalive 60 s（`TCP_KEEPIDLE`/`TCP_KEEPINTVL` 都设 60，同 Go `SetKeepAlivePeriod`）；两侧 `TCP_NODELAY`（Go 默认行为）。
- 监听支持 `:port` 通配（IPv6 双栈，`V6ONLY=0`，同 Go `net.Listen("tcp")`）。

## 测试覆盖（`zig build test`，17 个用例）

- 配置：合法（小写/Go 大写键）、非法地址、负权重、空 hosts、全零权重、坏 JSON、错误类型、SplitHostPort 各形态。
- 加权选择：固定种子 10 万次，1:2 权重比例 ≈1/3:2/3（区间断言）；0 权重后端 0 次命中。
- 重载：`Store.reload` 后选择集改变；坏 JSON/负权重/文件缺失时保留旧配置。
- 集成（真实 TCP，测试内起回显/应答服务与代理实例，ephemeral 端口）：
  - 小包请求/响应，**客户端不半关闭**也能立即收到响应（HTTP 模式），同连接第二请求仍可用；
  - 客户端半关闭后剩余回显数据仍传完并正确收到 EOF；
  - 1 MiB+777 B 大包双向并发传输字节一致；
  - 无可用后端（weight 0）立即关连接；拨号失败关连接；
  - 重写配置文件 + reload 后，端到端路由从服务 A 切到服务 B，坏重载不影响路由。

## 性能

见 `bench.md`。ReleaseFast 下**验收方复核**小包中位 **13.0–13.4k rps / p50 ≈7.2 ms / p99 ≈13 ms**，约为同机 Go 原版（14.4k rps）的 **0.90–0.93×**；1 MiB 大包中位 **578 rps ≈ 606 MB/s**（Go 605 rps ≈ 634 MB/s）。实现方自测表见 `bench.md` 前半部分，两者口径差异已在文中说明。

## 踩过的坑（0.17 API 迁移）

1. `std.net` 没了、`std.Io` 超时 connect 会 panic → 全部裸 syscall 自实现。
2. 链接 libc 后 `std.posix.errno` 读的是 libc 线程局部 errno，而裸 syscall 返回 `-errno` → 必须用 `std.os.linux.errno` 解码，否则错误路径上 `@intCast` 直接 panic。
3. `std.Thread.Mutex`、`std.Thread.sleep`、`std.time.timestamp/nanoTimestamp`、`std.fmt.bufPrintZ`、`std.process.argsAlloc`、`posix.close/write`、`ArrayList.init` 在 0.17 全部移除或改签名 → 分别用自旋锁、`nanosleep`、`clock_gettime`、手写 copyZ、`main(init: std.process.Init.Minimal)` 取 argv、`linux.close/write`、`array_list.Managed` 替代。
4. glibc 2.35 下 `pthread_create` 对 256 KiB 栈返回 EINVAL（minstack 含静态 TLS）→ 线程栈统一 1 MiB。
5. `build.zig` 的 `linkLibC()`/`b.args` 移到 module 选项/移除。
