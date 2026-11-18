# gopf — Zig 0.17 复刻版四层 TCP 负载均衡器

参考 Go 版 gopf 的语义用 Zig 0.17 重写：监听本地端口，按**加权随机**选择后端，
建立连接后双向转发，支持半关闭传播、配置热加载与信号控制。
只依赖 Zig 标准库与系统调用（链接 libc；支持 **Linux** 与 **macOS**，无第三方依赖）。

## 编译

```sh
zig build                          # Debug
zig build -Doptimize=ReleaseFast   # 优化版（性能测试用此级别）
zig build test                     # 单元测试 + 集成测试
```

产物：`zig-out/bin/gopf`。

## 运行

```sh
./zig-out/bin/gopf -listen :12481 settings.conf
# 等价形式：-listen=:12481 / --listen :12481；缺省 -listen :1248
```

第一个位置参数是 JSON 配置路径：

```json
{"hosts":[{"addr":"127.0.0.1:18091","weight":100}]}
```

字段名固定小写：`hosts` / `addr` / `weight`（`std.json` typed parse）。
`weight` 缺省为 0；为负、或 `addr` 不能拆成 `host:port`（要求数字端口）→ 整次加载失败；
`hosts` 为空或全零权重 → 加载成功但 `weight_sum<=0`，新连接立即关闭。

信号：

| 信号 | 行为 |
|---|---|
| `SIGHUP` | 重载配置文件；失败则保留旧配置并打印错误 |
| `SIGUSR1` | 打印状态：活跃/累计连接数、拨号失败数、worker 数、当前配置摘要 |
| `SIGTERM` / `SIGINT` | 退出 |

信号 handler 只置原子标志，由专用线程轮询处理（避免在 handler 里拿锁/分配；
Linux / macOS 通用）。`SIGPIPE` 被忽略；写侧尽量带 `MSG_NOSIGNAL`，macOS
另开 `SO_NOSIGPIPE`。

## 行为要点（与 Go 版对齐）

- **选后端**：每连接取 `[0, weight_sum)` 均匀随机数（无偏 `uintLessThan`），
  按累计权重落点；weight 0 的后端永不命中；`weight_sum<=0` → 直接关闭。
- **拨号超时 5s**：阻塞 `connect` + `SO_SNDTIMEO`，成功后立刻把发送超时复位为
  无限，避免影响转发阶段。
- **转发**：一侧 EOF/出错 → 对另一侧 `shutdown(WR)` 半关闭；两侧都结束才关闭
  整条连接。半关闭后剩余数据照常传完（有集成测试覆盖）。
- **TCP 选项**：两侧均 `TCP_NODELAY` + `SO_KEEPALIVE`；Linux 用
  `TCP_KEEPIDLE/KEEPINTVL=60s`，macOS 用 `TCP_KEEPALIVE=60`（空闲秒数）。
- **地址解析**：不做 DNS；支持 IPv4/IPv6 字面量（含 `[v6]:port`、`::` 压缩、
  内嵌 v4）、空 host、`localhost`。普通域名配置可加载，拨号时报
  `cannot resolve host name` 并计入 `dial_errors`。

## 设计取舍

### 线程模型：池化 worker + 每连接单线程 poll 双工

Go 原版是"每连接 3 个 goroutine"。Zig 里裸线程创建实测约 85 µs/个，
每连接 2 次创建会把吞吐钉死在 ~5k rps。因此：

- **主线程**只做 accept：成功后将 `(fd, peer)` 推入 4096 槽环形任务队列
  （Linux futex / Darwin ulock 信号量同步，满则阻塞 → 背压回落到内核 accept 队列）。
- **worker 池**预生成 `max(32, 4×nCPU)` 个线程；队列深度超过空闲 worker 时
  按需扩容（上限 4096），突发过后多余 worker 以原子 cmpxchg"认领退休"
  （先原子减计数再退出，杜绝把池子击穿到 base 以下的竞态）。
- 每个 worker 用**一个 `poll(2)` 循环**服务一条连接的两个方向。读写都采用
  非阻塞调用。一侧有待发送数据时暂停该方向的读取，等目标端可写后继续发送，
  反向仍能独立转发。

### 内存分配策略

- **转发热路径零堆分配**：每个方向各用 64 KiB 缓冲，均在 worker 栈上（栈 1 MiB）；
  任务队列是静态环形数组；日志用栈上 1 KiB 缓冲 + 一次 `write(2)`。
- **配置对象自带 arena**：一次加载的全部字符串/切片都在该 arena 内；
  配置带引用计数（自旋锁保护），`SIGHUP` 换配置时旧配置等最后一个在途
  连接释放后才销毁——读者持引用期间无需持锁，转发全程不碰配置锁。
- 堆分配只发生在：启动建 Proxy、读/解析配置文件（临时缓冲 + arena）。

### 代码结构

```
src/main.zig    CLI 参数、信号（signalfd）、启动流程
src/proxy.zig   accept 循环、worker 池、poll 双工转发、reload/status（+集成测试）
src/config.zig  JSON 解析与校验、加权随机选择（+单元测试）
src/sys.zig     可移植 socket 封装（libc）：listen/accept/connect/读写、
                keepalive、地址解析与格式化
src/log.zig     单行一次 write 的线程安全日志
```

## 测试

`zig build test` 覆盖以下行为。

- 配置：合法配置、拒绝大写键、非法地址（无端口/端口越界/非数字/未加
  方括号 IPv6 等）、负权重、空 hosts、全零权重、非整数 weight。
- 加权选择：固定种子 10 万次抽取，1:2 权重占比落在 1/3±1.7 个百分点内；
  weight 0 后端 10 万次零命中；单后端恒命中。
- 转发集成：进程内起回显 TCP 服务 → 客户端连代理：小包回显一致；
  客户端 `shutdown(WR)` 半关闭后剩余数据完整送达；1 MiB 负载逐字节一致。
- 双向转发在单侧写缓冲满时仍能送达反向数据。
- 重载：`loadConfigFile`（SIGHUP 实际调用的函数）——换配置后选择集随之改变；
  文件损坏时重载失败且旧配置保留。

[bench.md](bench.md) 记录初版 Linux 实现的性能数据。
