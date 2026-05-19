# VPS TCP 加速脚本

脚本文件：
`vps-tcp-accelerator.sh`

## 这不是传统一键模板

这份脚本不是“把一串流行参数全塞进去”，而是按 3 个原理来做：

1. 把出口瓶颈尽量收回 VPS 本机
   通过把出口速率整形成真实带宽的 96% 左右，让排队尽量发生在本机 qdisc，而不是上游不可控设备里。
2. 按带宽时延积估算缓冲
   不用固定大缓存，而是按 `带宽 x RTT` 算出更接近实际链路需要的发送/接收窗口上限。
3. 让 pacing 和浅队列接管稳态
   用 `fq` 做按流公平与 pacing，尽量让吞吐贴近瓶颈，同时不把 RTT 打爆。

## 它到底做了什么

### 1. 自适应算 BDP

输入：

- 真实上行带宽
- 基线 RTT

输出：

- 合理的 socket buffer 默认值
- 合理的 socket buffer 上限
- 合理的队列包数上限
- 合理的整形 burst

### 2. 启用更适合稳态的 TCP 特性

它会设置：

- `default_qdisc=fq`
- `tcp_congestion_control=bbr` 或回退到 `cubic`
- `tcp_ecn=1`
- `tcp_fastopen=3`
- `tcp_mtu_probing=1`
- `tcp_notsent_lowat=16384`

### 3. 在出口侧做浅队列整形

脚本会用：

- `htb` 作为总速率上限
- `fq` 作为子队列与 pacing 执行器

这一步是整份脚本最关键的地方。

## 适用边界

### 适合

- 只有单台 VPS
- 想在不改客户端的前提下，让 TCP 更稳、更接近极限
- 跨境、高 RTT、容易队列膨胀的场景

### 不适合

- 想单边脚本就突破物理带宽
- 远端链路丢包严重且瓶颈不在 VPS 出口
- 需要双端协同的深度传输重构

## 用法

### 先看状态

```bash
bash vps-tcp-accelerator.sh --mode status --uplink-mbit 1000
```

### 应用

```bash
sudo bash vps-tcp-accelerator.sh --uplink-mbit 1000 --rtt-ms 80
```

### 带持久化 sysctl 文件

```bash
sudo bash vps-tcp-accelerator.sh \
  --uplink-mbit 1000 \
  --rtt-ms 80 \
  --persist-sysctl /etc/sysctl.d/99-ufa-tcp.conf
```

### 回滚

```bash
sudo bash vps-tcp-accelerator.sh --mode restore --iface eth0
```

## 你需要自己给的关键参数

最重要的是两个：

1. `--uplink-mbit`
   不是套餐标称值，而是这台 VPS 到你主要用户路径上的真实可持续上行能力。
2. `--rtt-ms`
   不是偶尔最低 ping，而是更接近稳定空闲时延的基线值。

如果这两个值错得离谱，再聪明的脚本也会调偏。

## 和常见一键脚本的区别

常见一键脚本很多是在：

- 盲目加大发送接收缓存
- 只切 `bbr`
- 不控制本机出口队列

这份脚本的核心判断是：

**单边 VPS 想逼近极限，最重要的不是猛，而是把瓶颈放到自己能控制的地方。**

所以它优先做的是：

- 本机整形
- 浅队列
- pacing
- BDP 尺寸化

而不是一味把缓存和发送速度拉大。
