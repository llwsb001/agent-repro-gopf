# gopf — Zig 版

Go 版 gopf（四层 TCP 负载均衡器）的 Zig 0.17 复现。只依赖 Zig 标准库与系统调用，无第三方依赖。

## 构建与运行

```sh
zig build                                  # 生成 zig-out/bin/gopf
zig build -Doptimize=ReleaseFast           # 优化版
zig build test                             # 单元 + 集成测试

# 运行（参数语义与 Go 版一致）
./zig-out/bin/gopf [-listen :1248] settings.conf
```

配置文件为 JSON：`{"hosts":[{"addr":"host:port","weight":100}]}`。
与 Go 的 `encoding/json` 一样，键名大小写不敏感（参考实现的 `Hosts`/`Addr`/`Weight` 写法也能解析），未知键（如 `traffic_url`）被忽略。

信号：`SIGHUP` 重新加载配置（失败保留旧配置并打日志）；`SIGUSR1` 打印状态（当前/累计连接数、后端摘要）；`SIGTERM`/`SIGINT` 退出。

## 行为对照（与 Go 版一致）

- 加权**随机**选后端：`r = rand(0, weightSum)`，按累计权重落点；`weightSum <= 0` 时直接关闭连接。
- 连接到达后立即选后端并拨号（超时 5 秒，非阻塞 connect + poll + SO_ERROR 实现）。
- 双向同时拷贝；任一方向读到 EOF/出错后对**另一侧**做 `shutdown(SHUT_WR)` 半关闭，两个方向都结束才关闭两端 fd。
- 两侧连接都开启 TCP keepalive（`SO_KEEPALIVE`，`TCP_KEEPIDLE = TCP_KEEPINTVL = 60s`，对应 Go 的 `SetKeepAlivePeriod(60s)`）。
- 配置校验：`addr` 必须能拆成 host:port（端口须为 0–65535 数字），`weight` 不得为负；任一项非法则整次加载失败。

## 设计取舍

**线程模型**：每连接一个 OS 线程 + 每条连接再起一个线程跑反方向拷贝（对应 Go 的 goroutine-per-connection + `forward` 里的两个 goroutine）。这是刻意为之的对照设计：Go 的 goroutine 是几千字节起步的用户态调度栈，而这里是每个方向一个内核线程（栈 256 KiB 虚拟内存）。代价是每连接 2 次 `clone`、约 512 KiB 虚拟地址空间、以及内核线程调度开销 —— 这正是与 Go 版性能差距的主要来源（见 bench.md）。好处是代码极简、无事件循环状态机。

**内存分配**：热路径（accept → 转发 → 关闭）**零堆分配**。配置在加载/重载时分配一次；选后端时在持锁期间把地址拷到线程栈上的 512 字节缓冲区，因此重载释放旧配置不存在 use-after-free。拷贝缓冲区（32 KiB）也在栈上。进程级 `SIGPIPE` 被忽略，写已关闭的对端只会得到 `EPIPE` 错误（与 Go 运行时一致）。

**配置共享**：`config.Store` 用一把 `std.Io.Mutex` 保护（临界区只有"选一个下标 + 拷一个字符串"，几纳秒，不需要读写锁）。重载时先在锁外完成整个 JSON 解析与校验，加锁换指针后立刻释放旧配置。

**拨号超时的实现说明**：Zig 0.17 的 `std.Io.Threaded` 对带超时的 `connect` 会直接 `@panic("TODO")`，所以 `dial.zig` 里用原始 `socket/connect/poll/getsockopt(SO_ERROR)/fcntl` 系统调用自己实现了 5 秒超时，建连成功后恢复阻塞模式。监听/接受/读写则走 `std.Io.net` 接口。

**优雅退出**：与 Go 版一致，`SIGTERM`/`SIGINT` 直接 `exit(0)`（不等待在途连接）。信号处理器只做 async-signal-safe 的原子标志设置，实际的重载/状态打印由一个 10ms 轮询的 watcher 线程完成。

## 代码结构

- `src/main.zig` — 入口、参数解析、信号处理、日志
- `src/config.zig` — 配置解析/校验、线程安全的配置持有者（热重载）
- `src/chooser.zig` — 加权随机选择（纯函数，便于测试）
- `src/dial.zig` — host:port 拆分、地址解析、带超时的拨号、keepalive
- `src/proxy.zig` — accept 循环、连接处理、双向转发（含集成测试）

## 测试

`zig build test` 一条命令跑完，包括：

- 配置解析/校验：合法配置、非法地址、负权重、空 hosts、全零权重、大小写键名
- 加权选择：固定种子下 1:2 权重 10 万次抽样的比例检查；权重 0 的后端永不被选中
- 转发集成：测试内回显服务器 + 真实代理，验证小包回显、半关闭后剩余数据完整传完、2 MiB 大包字节一致、重载后选择集改变、无可用后端时直接关闭连接
