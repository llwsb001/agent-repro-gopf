# gopf (Zig 0.17 重写版)

用 Zig 0.17 标准库与 Linux 系统调用重写的 gopf 四层 TCP 负载均衡器。行为对齐参考实现：加权随机选后端、双向转发与半关闭、配置文件校验、SIGHUP 重载、SIGUSR1 状态、SIGTERM/SIGINT 退出。

## 构建与测试

```bash
# Zig 0.17.0
/home/user/.local/bin/zig build test
/home/user/.local/bin/zig build -Doptimize=ReleaseFast
```

> 本仓库开发时的受限沙箱不允许写默认全局缓存，因此验证时曾把缓存指到项目内：
> `ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global ZIG_LOCAL_CACHE_DIR=$PWD/.zig-cache/local zig build test`。
> 在普通可写缓存的环境里直接执行上面的两条命令即可。

`zig build test` 一条命令跑完单元测试与真实 TCP 集成测试（共 13 个测试），覆盖：

- 配置解析与校验：合法配置、非法地址/端口、负权重、空 hosts、全零权重、坏 JSON；
- 加权随机选择：固定种子下 1:2 权重在 10 万次中的比例，权重 0 的后端永不命中；
- reload 语义：重载后选择集改变，非法配置重载失败时保留旧配置；
- 信号处理函数安装与标志分发；
- 集成：测试内启动 TCP 回显后端与代理，验证小包回显、半关闭后剩余数据仍完整送达、1 MiB 大包字节一致、拨号失败时客户端被关闭。

如想只跑某一组测试，可用 `zig build test -Dtest-filter=integration`（这是本实现附带的调试便利，不影响默认全量测试）。

## 运行

后端先按任务书保持在 `127.0.0.1:18091`。配置示例（本目录的 `settings.conf`）：

```json
{"hosts":[{"addr":"127.0.0.1:18091","weight":100}]}
```

启动：

```bash
./zig-out/bin/gopf -listen 127.0.0.1:12483 settings.conf
```

- `-listen` 默认 `:1248`；第一个位置参数是 JSON 配置路径。
- 本轮按调度要求实际使用 `127.0.0.1:12483` 监听（任务书中的 12481 在其他实例占用），程序本身不硬编码端口。
- `SIGHUP` 重新读取配置文件；失败只打印错误并继续使用旧配置。
- `SIGUSR1` 在日志中打印 active/total 连接数、累计转发字节数和当前 host 摘要。
- `SIGTERM` / `SIGINT` 停止事件循环、关闭所有连接后退出。

配置中每个 host 的 `addr` 必须能拆成 `host:port`（支持 `[IPv6]:port`），`weight` 必须是非负整数；任何一项非法都会让整次加载失败。空 `hosts` 或全零权重是合法配置，但此时没有可用后端，新连接会被直接关闭。

## 设计取舍

### 线程模型：单线程 epoll 数据面

监听 fd、后端连接 fd、客户端 fd 全部设为非阻塞，统一注册到一个 epoll 实例；一个事件循环线程负责 accept、非阻塞 connect（5 秒超时）、双向转发、半关闭和关闭。没有“每连接一个线程”，也没有“每方向一个 goroutine/线程”，连接数增长时线程数不变。

对比 Go 原版：Go 使用 goroutine + runtime netpoller，逻辑上每连接两个方向的 `io.Copy`，由 runtime 把可运行 goroutine 调度到多核。Zig 版把所有就绪事件批量取回，在单线程里推进状态机，省掉了每连接线程创建、futex/调度器唤醒和每连接一次 `poll` 的系统调用；代价是数据面只吃一个 CPU 核，超大并发下不如多 reactor/多线程扩展。小包短连接场景下这个取舍表现很好；如果要做多核扩展，可以按 `SO_REUSEPORT` 起多个事件循环。

### 半关闭与缓冲区

每个连接对应一个固定大小的状态对象，内含两个 32 KiB 缓冲区（client→backend、backend→client）。读方向收到 EOF 时立即对另一侧 `shutdown(SHUT_WR)`，对侧仍可继续把剩余数据送完；两个方向都结束后才关闭整对 fd。发送遇到 `EAGAIN` 时保留未发送数据，等待下一次 EPOLLOUT，避免忙等和丢弃数据。

### 内存分配

启动时一次性分配 1024 个连接槽（约 64 MiB，页面按需触碰）和空闲索引栈。每条新连接只是从空闲栈取一个槽，事件循环热路径上不做堆分配，也没有逐连接创建/销毁 buffer。连接槽用完后新连接会被拒绝并记日志。配置使用独立 arena，reload 时先完整解析新配置，再在自旋锁保护下原子替换，最后释放旧 arena；读路径只在选后端时短暂持锁，选中后把地址拷贝到栈上，因此旧配置可以安全释放。

### 加权随机

权重和由配置加载时累加并校验 i64 溢出。选择时生成 `[0, weight_sum)` 的均匀随机数，再按累计权重落点。每个连接用时间、连接序号和实例地址混合出的种子初始化 PRNG；测试则传入固定种子，因此 1:2 的统计行为和零权重排除都可重复验证。

### 日志

stdout/stderr 打日志：accept、后端拨号失败、reload 成功/失败、SIGUSR1 状态摘要。压测时日志重定向到文件，不影响功能；如果生产环境追求极限吞吐，可以把 accept 日志降到 debug 或异步批量写。

## 目录

- `build.zig` — 构建、测试、`-Dtest-filter` 调试入口；
- `src/main.zig` — CLI、信号安装、启动；
- `src/config.zig` — JSON 解析、校验、文件读取；
- `src/balancer.zig` — 加权随机；
- `src/store.zig` — 配置存储、原子 reload、自旋锁；
- `src/tcp.zig` — Linux socket/connect/listen/非阻塞读写封装；
- `src/proxy.zig` — epoll 事件循环、连接状态机、转发；
- `src/tests.zig` — 单元与集成测试；
- `settings.conf` — 指向本机 18091 后端的示例配置。
