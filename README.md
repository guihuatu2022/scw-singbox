# sing-box VLESS+WS on Scaleway Serverless Containers

## 1. 构建 & 推送镜像

推送到 `main` 分支或打 `v*` tag 会自动触发 GitHub Actions，构建后推送到：

```
ghcr.io/<你的GitHub用户名>/<仓库名>:latest
```

首次推送后，去 GitHub 仓库的 Packages 页面，把这个包的可见性设为 **Public**
（否则 Scaleway 拉取私有镜像需要额外配置 registry 凭证，先用公开镜像最简单）。

## 2. 在 Scaleway 创建容器

**通过 Console：**
1. Serverless → Containers → Create namespace（选 Paris/Amsterdam/Warsaw 任一区域）
2. Deploy container / Create container 时，Registry 选 **External registry**（不是 Scaleway 自己的 Registry），Image 填 `ghcr.io/<你的用户名>/<仓库名>:latest`
3. **Port** 参数随便填一个数字，比如 `8080`
   （这个值会通过 `PORT` 环境变量传给容器，entrypoint.sh 会自动读取，不需要手动再设一遍 PORT）
4. Environment variables 里添加（这里填的是 **container 级**变量，只作用于这一个容器；如果以后同一个 namespace 下要部署多个容器并共享某些配置，可以把公共变量挪到 **namespace 级**，namespace 级变量会自动传给该命名空间下所有容器，container 级同名变量会覆盖它）：
   - `UUID` = 用 `uuidgen` 或 https://www.uuidgenerator.net 生成的一个 UUID（必填）
   - `WS_PATH` = 比如 `/my-secret-path`（不填默认是 `/ws`，建议改成不容易被猜到的路径）
   - `LOG_LEVEL` = `info`（可选）
5. Advanced options：
   - **min scale 设为 1**（重要：如果留 0，容器空闲后会被整个回收，正在用的 WS 长连接会被直接掐断，下一个客户端连进来还要等冷启动）
   - **Request timeout 调到平台允许的最大值**（同样是为了不打断长连接，具体上限以控制台里实际能选的范围为准）
6. Deploy，等状态变成 Ready

**通过 CLI（等价操作，方便写进部署脚本）：**

```bash
scw container namespace create name=singbox region=nl-ams

scw container container create \
  namespace-id=<namespace-id> \
  name=singbox-vless \
  registry-image=ghcr.io/<你的用户名>/<仓库名>:latest \
  port=8080 \
  min-scale=1 \
  max-scale=1 \
  environment-variables.UUID=<你的UUID> \
  environment-variables.WS_PATH=/my-secret-path \
  environment-variables.LOG_LEVEL=info

scw container container deploy <container-id>
```

## 3. 客户端节点信息

- 地址：Scaleway 分配的默认域名（形如 `xxxxxxx.functions.fnc.<region>.scw.cloud`），或你绑定的自定义域名
- 端口：**443**（Scaleway 边缘统一走 443/80 对外，TLS 由 Scaleway 用 Let's Encrypt 自动签发，不是你容器里配的端口）
- TLS：开启（wss）
- UUID：部署时设置的 `UUID`
- 传输方式：ws，path 填部署时设置的 `WS_PATH`

因为 TLS 在 Scaleway 边缘终止，容器内 sing-box 只处理明文 WS，所以 config 里没有 `tls` 字段——这是刻意的，不是漏配。

## 4. 本地调试

```bash
docker build --platform linux/amd64 -t singbox-test .
docker run --rm -e UUID=$(uuidgen) -e PORT=8080 -p 8080:8080 singbox-test
```

## 5. 为什么选择"从源码编译、不带 tag"

sing-box 的官方 release 二进制、以及几乎所有社区镜像（gzxhwq、bi4nbn、rookieterry 等），
都是打开了 `with_quic,with_gvisor,with_wireguard,with_utls,with_acme,with_clash_api,
with_tailscale,with_grpc,with_reality_server,with_ech` 这一整套可选特性编译的。
这些分别对应 QUIC 传输、TUN 模式、WireGuard 出站、uTLS 指纹伪装、ACME 自动签证书、
Clash 面板、Tailscale 集成、gRPC 传输、REALITY、ECH——**在 VLESS+WS 场景里一个都用不到**。

VLESS 协议和 WS 传输是 sing-box 的核心内置能力，不依赖任何可选 tag，所以直接
`go install .../sing-box@version`（不加 `-tags`）编译出来的二进制体积更小、
需要加载的代码更少，对 128MB 内存这种极限环境更友好。

部署前建议本地验证一下编译产物确实没带多余 tag：
```bash
docker run --rm --entrypoint sing-box <你的镜像> version
```
输出里的 `Tags:` 一行应该是空的（或者只有极少几个），如果发现 WS 连不上，
最坏情况下可以退回加 `-tags with_v2ray_api` 重新编译，但正常情况不需要。

## 6. 128MB / 100mCPU 下的其他优化

- **`GOMAXPROCS=1`**：Go 运行时默认按宿主机核心数决定调度线程数，而不是按 cgroup
  配额。100mCPU（0.1 核）的情况下不设置这个值，Go 会白白消耗调度开销。已写进
  Dockerfile 默认值，不需要在部署时另外设置。
- **`GOMEMLIMIT=100MiB`**：给 GC 一个软上限，让它在触碰 128MB 硬限制之前就主动
  回收，避免被平台 OOM Kill——被杀掉比被限速严重得多，所有连接会瞬间全断。
- **`sniff: false`**：配置模板里已关闭协议嗅探，因为纯代理转发不需要基于目标做
  路由决策，省下这部分 CPU。
- **日志级别默认 `warn`**：减少不必要的日志 I/O，可以通过 `LOG_LEVEL` 环境变量
  临时调回 `info` 排查问题。

## 7. 连接数增多、单实例扛不住了怎么办

**核心思路：横向扩容，而不是死磕单实例的垂直性能。**

VLESS 的鉴权只是校验 UUID，配置也是无状态的——任何一个跑着同一份配置的
sing-box 实例都能独立处理任何客户端的连接，实例之间不需要共享状态、不需要
粘性会话（sticky session）。这意味着"多开几个实例分担流量"对你的场景是
完全可行、零成本的扩展方式，不像有会话状态的应用那样需要额外设计。

具体到两个平台：

- **Scaleway**：
  - 把 `max concurrent requests per instance`（并发请求数）调低一些，比如
    20～30，而不是默认的 80。因为 WS 长连接会一直占着"请求"名额，把这个值
    设低一点，能让平台在连接数还不算很多的时候就提前拉起第二个实例分担，
    而不是让一个 0.1 核的实例硬扛几十个并发连接
  - `maxScale` 调大一点（比如 3～5），允许多开几个实例
  - `minScale` 保持 1（前面已经提到，避免冷启动打断长连接）

- **Gcore**：同理，把 `scale-max` 调大，允许自动扩容出多个副本；
  `scale-min` 保持 1

- **认清硬件天花板**：100mCPU 这个量级，单实例大概能稳定撑住几十个并发连接
  的正常代理流量（数量级参考，不是精确值，实际取决于每个连接的吞吐量——
  转发 1080p 视频流和转发几个人聊微信的 CPU 消耗完全不是一个量级）。如果
  自动扩容后实例数量经常顶到 `maxScale` 上限，或者你从 Scaleway Cockpit /
  Gcore 的监控里看到 CPU 长期跑满，说明已经不是"调参能解决"的问题了，
  该考虑升配（哪怕只是从 100mCPU 提到 250mCPU）而不是继续在极限配置里抠细节。

- **个人使用场景的现实预期**：如果这两个节点主要是你自己和身边几个人用，
  大概率根本碰不到这个瓶颈，不用现在就过度设计扩缩容参数，知道旋钮在哪、
  真遇到卡顿时去调哪个值就够了。
