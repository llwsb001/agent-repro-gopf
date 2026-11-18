# gopf-zig

Go 版四层 TCP 负载均衡器 [gopf](../..) 的 Zig 0.17 复现。单线程 `epoll`
事件循环 + 全非阻塞 socket，加权随机选后端，双向转发并支持半关闭。

## 构建

```sh
zig build                          # Debug 版
zig build -Doptimize=ReleaseFast   # 优化版（性能测试用这个）
zig build test                     # 单元 + 集成测试，一条命令跑完
```

产物在 `zig-out/bin/gopf`。只依赖 Zig 标准库与 Linux 系统调用，无第三方依赖。

## 运行

```sh
./zig-out/bin/gopf -listen 127.0.0.1:12481 settings.conf
```

- `-listen`：监听地址，默认 `:1248`。支持 `":port"`（= 0.0.0.0）、IPv4
  字面量、`localhost`。
- 第一个位置参数：JSON 配置路径。

配置格式（键名大小写不敏感，兼容 Go encoding/json 的习惯）：

```json
{"hosts":[{"addr":"127.0.0.1:18091","weight":100}]}
```

信号：

| 信号 | 行为 |
| --- | --- |
| `SIGHUP` | 重载配置；失败保留旧配置并打日志 |
| `SIGUSR1` | 打印运行状态（活跃/累计连接数、后端与权重摘要） |
| `SIGTERM` / `SIGINT` | 退出 |

日志（接受连接、拨号失败、重载结果、状态）打到 stderr。

## 行为（与 Go 参考实现对齐）

- 接受连接后**立即**按加权随机选后端并发起连接；`weightSum<=0`（无可用
  后端）直接关闭客户端连接。
- 加权随机：`rand(0, weightSum)` 后按累计权重落点（`weight:0` 的后端
  永远不会被选中）。
- 非阻塞 `connect`，**5 秒拨号超时**；失败打日志并关闭客户端连接。
- 双向同时拷贝；一侧读 EOF 后先把残余数据冲刷给对端，再对**对端**做
  `shutdown(WR)` 半关闭；两侧都结束才关闭整条连接。
- 两侧 socket 都开 `SO_KEEPALIVE` + `TCP_KEEPIDLE=60`，另设
  `TCP_NODELAY` 避免 Nagle 影响小请求延迟。
- 配置校验：`addr` 必须能拆成 `host:port` 且可解析；`weight` 不得为负；
  任何非法项让整次加载失败（初次加载失败直接退出，重载失败保留旧配置）。

## 设计取舍

**线程模型：单线程 epoll 事件循环**（除主循环外只有测试才起额外线程）。
Go 版是「每连接 1 个 goroutine + 每方向 1 个拷贝 goroutine」，即每条连接
3 个调度实体；本实现把全部连接放进一个状态机，单线程驱动：

- 每条连接两个 32 KiB 定长缓冲（客户端→后端、后端→客户端），读直到
  `EAGAIN`，写不动才挂 `EPOLLOUT`，缓冲满就摘 `EPOLLIN`（背压）。
- 每次事件后 `settle()` 收敛状态：EOF → 冲刷 → 半关闭 → 双 fd 都完成才
  回收。epoll 事件只携带「连接指针 + 方向位」，是否读写完全由状态决定，
  fd 复用导致的陈旧事件不会造成错误。
- 信号走 `signalfd` 进同一个事件循环（启动时先 `sigprocmask` 屏蔽），
  另有 `eventfd` 供跨线程停机（集成测试用）。
- 连接的建立/关闭都在循环线程内完成，配置指针换载无锁（读写天然串行）。

**内存分配策略：稳态零分配。**

- 连接对象（含两块 32 KiB 缓冲，约 64 KiB）来自一个简单的空闲链表池：
  `accept` 时弹出、关闭时推回，池子只增不减，稳态下不再有
  malloc/free。
- 配置解析用一块独立 arena，`SIGHUP` 重载时整体构建新配置、原子换指针、
  再释放旧 arena；失败不触碰旧配置。
- 日志为栈上格式化 + 一次 `write(2)`。

**与 Go 版的主要差异**：Go 的 `io.Copy` 在 TCP→TCP 时走 `sendfile(2)`
零拷贝；本实现是用户态 32 KiB 缓冲拷贝，大包吞吐略低（约为直连的
85–90%，见 `bench.md`），换来半关闭语义的简单与可控。地址解析只支持
IPv4 字面量与 `localhost`（不做 DNS），且只支持 Linux（epoll/signalfd）。

## 目录结构

```
build.zig        # 构建脚本（zig build / zig build test / -Doptimize=ReleaseFast）
src/main.zig     # 入口：参数解析、信号屏蔽、启动
src/addr.zig     # IPv4 / host:port 解析与校验（单元测试）
src/config.zig   # JSON 配置解析与校验（单元测试）
src/selector.zig # 加权随机选择（单元测试：分布、0 权重、空集）
src/proxy.zig    # epoll 事件循环与转发状态机（集成测试：回显、半关闭、1MiB、SIGHUP 重载）
src/tests.zig    # 测试汇总入口
bench.md         # 性能测试方法与结果
```
