# gopf (Zig 0.17) 性能测试

## 环境与方法

- 机器：4 vCPU / 8 GiB，Linux 5.10（与本机 Go 基线同一台）。
- 编译：`zig build -Doptimize=ReleaseFast`（Zig 0.17.0，native x86_64-linux-gnu，**不链接 libc**，全部直接走 `std.os.linux` 系统调用）。
- 被测进程：`./zig-out/bin/gopf -listen :12481 settings.conf`，配置单后端 `127.0.0.1:18091`、weight 100。
- 后端：`bench/backend -addr 127.0.0.1:18091`（396 字节响应；`/big` 返回 1 MiB）。
- 压测：`bench/load`，每连接一次请求（`Connection: close`）。
- 流程：先 `-conns 50 -reqs 2000` 预热，再连跑 3 次 `-conns 100 -reqs 10000` 取中位数；大包跑 `-path /big -conns 4 -reqs 100`。

## 小包结果（396 B 响应）

预热：`reqs=2000 conns=50 → 15,692 rps, p50=2.57ms, p99=8.52ms`

| 轮次 | rps | mean | p50 | p99 |
|---|---|---|---|---|
| 1 | 16,614 | 5.96 ms | 5.21 ms | 22.48 ms |
| 2 | 18,240 | 5.44 ms | 4.93 ms | 17.63 ms |
| 3 | 16,923 | 5.85 ms | 5.24 ms | 22.27 ms |
| **中位数** | **16,923** | 5.85 ms | **5.21 ms** | **22.27 ms** |

## 大包结果（1 MiB 响应，`-conns 4 -reqs 100`，3 次中位数）

- **718 rps**，p50 ≈ 5.0 ms，p99 ≈ 9.8 ms
- 吞吐 ≈ 718 × 1 MiB ≈ **718 MiB/s（≈ 753 MB/s 含响应头）**。此时瓶颈是 4 核 CPU 上的两轮用户态拷贝（client→proxy→backend 双向各一次）与每连接 ~40 次系统调用，远未到内存带宽。

## 与基线对照

| 指标 | zig-gopf (ReleaseFast) | Go 原版基线 | 直连后端 |
|---|---|---|---|
| rps | **16.9k** | 15.7k | 30.9k |
| p50 | **5.2 ms** | 6.0 ms | — |
| p99 | 22.3 ms | **13 ms** | — |
| 大包吞吐 | ~750 MB/s | — | — |

### 差距来源分析

**对比 Go 原版（rps 高约 8%，p50 略低）**

- 热路径**零堆分配**：连接转发的 64 KiB 缓冲在 worker 线程栈上，任务队列是 4096 槽静态环形数组；Go 每个连接要建 3 个 goroutine（handleConn + 2 个 io.Copy）及若干接口/结构体堆对象，15k conn/s 下 GC 压力可观。
- 每连接只有 **1 个线程跑一个 poll(2) 双工循环**，而 Go 是 3 个 goroutine + channel/调度器交互。
- 直接系统调用，无运行时/netpoller 抽象层开销。

**p99 反而更差（22 ms vs 13 ms）**

- 4 核已被压满时，我方自旋锁（日志锁、队列锁、配置锁）在竞争下空转烧 CPU；Go 的 netpoller 精确唤醒对应 goroutine、GOMAXPROCS=4 天然限制并发竞争，尾部延迟更稳。
- futex 唤醒 + 线程交接在满载核上引入调度尾部；这是用"预分配线程池"换"每连接 85 µs clone 开销"的代价（见下）。

**对比直连（30.9k rps → 16.9k，约 55%）**

- 四层代理天然翻倍套接字与系统调用：每条连接约 20+ 次 syscall（accept4、4×setsockopt、queue futex、socket、connect、SNDTIMEO 设置/复位、后端 4×setsockopt、poll/read/write 若干、2×close），数据多一轮内核↔用户态拷贝。55% 的直连速率属于该模型的正常区间。

### 一个关键教训

最初按 Go 语义直译为"每连接 spawn 2 线程"，实测只有 ~5.2k rps——本机裸 `clone` 线程创建约 **85 µs/个**（Zig 0.17 无 libc 线程实现，与栈大小无关），每连接 2 次创建就吃掉了全部预算。改为**预生成 worker 池**（基础 `max(32, 4×nCPU)`，队列积压时按需扩容至 4096，空闲自动回收）+ 单线程 poll 双工后达到上述数字。Go 能用 goroutine 平铺直叙，是因为 goroutine 不是 OS 线程；在 Zig 里复现的是其*语义*，调度载体换成了池化线程。
