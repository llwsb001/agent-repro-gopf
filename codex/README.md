# gopf

Linux 和 macOS 上的 TCP 转发器。使用 Zig 0.17.1、标准库和系统 socket API，无第三方依赖。

```sh
zig build -Doptimize=ReleaseFast
zig build test
./zig-out/bin/gopf -listen 127.0.0.1:12481 -workers 4 settings.conf
```

`-listen` 默认是 `:1248`。`-workers` 设置事件循环的数量，默认取逻辑 CPU 数与 16 的较小值。配置中的 `hosts` 由 `addr` 和非负整数 `weight` 组成，按权重随机选择后端。空列表和全零权重会关闭新接入的连接。

- `SIGHUP` 加载新配置，失败时继续使用旧配置。已建立的连接继续使用原后端。
- `SIGUSR1` 打印活跃和累计连接数以及配置状态。
- `SIGTERM` / `SIGINT` 停止接入并关闭连接。

## 并发与容量

接入线程选后端，把每条连接分配给一个 worker。worker 用 Linux `epoll` 或 macOS `kqueue` 管多条连接。worker 拥有连接两端的 socket、未发送的数据和关闭状态。两端分别维护读取进度和积压数据，一端读完只关闭对端的写方向。

每个 worker 复用一块 16 KiB 读缓冲。只有非阻塞写未发完时，才保留该方向的剩余数据。每个方向积压最多 16 KiB。每个 worker 的积压预算按连接配额计算，超过预算的连接会被关闭。约 16,384 条连接的总配额分给各 worker。连接和接入队列满时会拒绝新连接。

一条已连到后端的连接占用两个 socket。测试 10,000 条在线连接时，给代理进程留出超过 20,000 个文件描述符，并给压测端和后端各自留出所需额度。

DNS 在初始加载和重载时解析，因此事件循环内只做非阻塞拨号。同一后端的 IP 会依次尝试。**TODO** 给拨号加统一的 5 秒截止时间。首版由操作系统决定单次未完成拨号的等待时间。

## 测试

`zig build test` 包含配置校验、固定种子权重抽样、两端分别先半关闭、单向写受阻时反方向仍然能传输，以及 1 MiB 数据逐字节比对。

同机压测、10,000 条连接的容量和传输测试，以及 Go 的 `splice` 排查见 [bench.md](bench.md)。
