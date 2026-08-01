# Rust 后端蓝绿部署

这套原生 Arch Linux 部署骨架将 `lmm-api-rs` 的进程升级与数据库迁移拆开，并且默认只接管内部探针。当前 Rust 后端尚未实现 Go 服务的业务路由，因此**不得把生产 API 全量切到 Rust**。

## 边界与不变量

- blue 固定监听 `127.0.0.1:3100`，green 固定监听 `127.0.0.1:3101`。
- artifact 安装到 `/opt/lmm-api-rs/releases/<revision>/`；slot 的 `current` 符号链接用同文件系统 `rename(2)` 原子替换。
- 部署程序与 nginx 资产固定安装到 `/usr/lib/lmm-api-rs/deploy/`，`/usr/local/sbin` 仅提供符号链接入口；transient unit 不依赖调用者当前目录。
- PostgreSQL migrator 是独立事务，绝不放在应用 `ExecStartPre`、应用启动或蓝绿切换脚本里。
- `/readyz` 必须验证 PostgreSQL 与 schema contract；Valkey 是可选加速层，故障时返回 HTTP 200 的 `degraded`，不能阻止实例接流。`/livez` 只证明进程存活。
- nginx upstream include 先写 `.next`，经 `mv -T` 原子替换，再执行 `nginx -t` 与 reload。失败时恢复审计目录保存的旧 include。
- nginx 不配置对非幂等请求的重试。当前 route ownership include 只提供三个仅 loopback 可访问的 GET/HEAD 内部探针。
- 每次事务用 `flock` 串行化，并在 `/var/log/lmm-api-rs/deployments/<UTC>-<revision>/` 保存不含连接串的 hash、探针结果、切换前配置与结果。
- 切换前 journal 写入 `PREPARED`（old/new/revision/旧 upstream hash 与备份路径），reload 成功后立即写 `COMMITTED`。若进程在窗口内被 SIGKILL，下次启动通过真实 nginx TLS build canary 判断运行中 worker：命中新 revision 就提交并停止旧 slot，否则先恢复旧 worker 与旧 upstream、再停止未接流的新 slot；恢复 journal 始终保留原 PREPARED artifact revision。
- 当前只接管短生命周期内部 GET/HEAD 探针，切换后直接向旧 slot 发送 SIGTERM，由 Rust 的 `LMM_DRAIN_TIMEOUT_SECONDS` 完成有界排空。未来接管业务流量前必须提供 Rust 自身的 HTTP、SSE 与 WebSocket 连接生命周期指标，不能用任意外部 shell 命令伪装精确 drain。

## 首次安装

先创建不可登录的系统用户：

```bash
sudo useradd --system --home-dir /var/lib/lmm-api-rs --shell /usr/bin/nologin lmm-api-rs
sudo deploy/nginx/install-nginx-split.sh install
sudo deploy/backend-rust/install-lmm-api-rs-blue-green.sh
sudo install-nginx-rust-routing
```

将 `common.env.example` 复制为 `/etc/lmm-api-rs/common.env`，填入真实 PostgreSQL/Valkey URL，并保持 `0600 root:root`。敏感值不得进入仓库、命令行、systemd unit 或审计日志。仓库管理的 `deploy/nginx/new-api.conf` 已在 TLS server 中 include `/etc/nginx/snippets/lmm-api-rs-probe-locations.conf`；upstream 文件位于 nginx `http` 上下文。`install-nginx-rust-routing` 不要求任何 Rust slot 已运行，它原子安装 port 9 禁用 upstream 与 loopback GET/HEAD ownership，执行 `nginx -t`/reload/is-active 后将状态记为 `none`；首次部署据此选择 blue。第二个文件写入、测试、reload 或存活检查中途失败都会恢复两个旧文件。installer 与 deployer 共用一个 `flock`。

`deploy.conf.example` 配置真实 TLS canary：`curl --resolve api.lmm.best:443:127.0.0.1` 保留生产 SNI/Host 并使用明确 CA bundle，确保请求穿过实际 TLS server、route ownership 和 active upstream。探针允许 GET/HEAD，但只允许 loopback 来源，不能暴露到公网。不要用 nginx 对 POST 做自动重试。

## 构建与自主升级

构建时注入不可伪造的 revision，并计算 artifact hash：

```bash
cd rust
LMM_BUILD_REVISION="$(git rev-parse HEAD)" cargo build --release --locked -p lmm-api-rs
sha256sum target/release/lmm-api-rs
```

先执行不启动实例、不切换流量的计划。它会验证配置、hash 和生产路由禁用门；如果此前事务被强杀，也会以 nginx upstream 为权威原子修复 active state/journal：

```bash
sudo deploy-lmm-api-rs --artifact /absolute/path/lmm-api-rs \
  --sha256 <sha256> --revision <git-sha> --dry-run
```

正式事务必须交给 systemd manager，使 SSH/API 控制连接断开后仍能自主完成。入口会先把 artifact 复制并复核到 root-owned、绝对路径的 `/var/lib/lmm-api-rs/artifacts/`，transient unit 不依赖用户目录或原始构建路径：

```bash
sudo deploy-lmm-api-rs --artifact /absolute/path/lmm-api-rs \
  --sha256 <sha256> --revision <git-sha> --systemd-run
```

部署器安装 inactive slot、启动并检查 `/livez`、`/readyz` 和 revision、写 PREPARED journal、原子切换内部探针 upstream、reload nginx，再通过真实 TLS `/readyz` 与 `/build` 确认 nginx 选中了目标 revision。nginx reload 是异步的，旧 worker 可能在短窗口内继续响应；canary 因此在有限截止时间内重试，并且只有 readiness、revision 与 slot 同时匹配才算收敛。回滚严格按“启动旧 slot 并 direct-ready → 原子恢复旧 upstream → `nginx -t`/reload/is-active → TLS canary 验证旧 revision → 停止新 slot”执行；任一步失败会保留新 slot 并写 `NEEDS_ATTENTION`，绝不报告成功。旧 release 不在同一事务删除。

## 故障注入与验证

仓库测试覆盖错误 hash、immutable release、并发锁、意外生产路由启用、loopback GET/HEAD ownership、禁止 non-idempotent retry、installer 回滚，以及 reload 后 SIGKILL 的下次启动对账：

```bash
bash deploy/backend-rust/test-blue-green.sh
bash -n deploy/backend-rust/*.sh
shellcheck deploy/backend-rust/*.sh
```

staging 中可设置 `LMM_DEPLOY_FAIL_AT=install|ready|kill-before-reload|nginx-test|switch|kill-after-reload` 验证相应失败点；两个 kill 值会 SIGKILL 部署事务，只能在隔离演练环境使用。下次事务结合 PREPARED journal 与 TLS canary 对账并原子修复 active state/upstream。禁止在生产常态配置中保留故障变量。

## 生产启用门

目前不存在开启业务流量的配置选项；创建 `/etc/lmm-api-rs/production-routing.enabled` 反而会让部署器拒绝运行。只有在以下条件全部具备并经过独立评审后，才应新增生产 route ownership：

1. SQLite 数据完整迁移到 PostgreSQL，且有已验证的回滚/前滚策略。
2. Rust 与 Go 的路由、鉴权、配额、计费、流式响应和错误契约通过差分测试。
3. schema 使用 expand/contract，N 与 N-1 均兼容，后台任务具有单例租约。
4. WebSocket/SSE 具备明确的 drain/reconnect 行为，非幂等请求不会被代理重试。
5. staging 完成 readiness、safe GET canary、切换后故障注入和回滚演练。

## ArchDmit 内部探针演练记录

2026-08-01 在 ArchDmit 完成了不接管业务流量的原生 systemd 演练：

- 使用隔离的 `lmm_api_rs_rehearsal` PostgreSQL 数据库和专用 Valkey `127.0.0.1:6380`；生产 SQLite 仍是 Go 服务的权威数据库。
- 从 port 9 bootstrap 首次发布 blue，再以同一 artifact revision 切换到 green，TLS build canary 分别确认 slot 身份。
- 真实 nginx reload 首次 canary 命中了尚未退出的旧 worker 并返回 502。部署器现会在有界窗口内重试 readiness + revision + slot，确认新 worker 收敛后才提交。
- 在 reload 后对部署进程执行 SIGKILL，后续独立 systemd reconcile 依据真实 TLS worker 完成 PREPARED → COMMITTED，对账 journal 保留原 artifact revision，并停止旧 slot。
- `/api/status` 继续返回 200，`/v1/models` 继续由 Go 鉴权并返回 401；公网访问 Rust 内部探针返回 403。Go 服务在整场演练中 PID 未变化且 `NRestarts=0`。

这份记录只证明内部探针蓝绿事务和崩溃恢复可用，不代表 PostgreSQL 生产迁移、Rust 业务路由兼容或完整后端切换已经完成。
