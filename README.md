# cat-bot

InstaBox 免费机器 7×24 保活看门狗（GitHub Actions 部署，无需任何常开设备）。

## 解决的三层问题

| # | 问题 | 原因 | 对策 |
| --- | --- | --- | --- |
| 1 | **GitHub cron 调度饥饿**（旧版 `*/9` 实测每 4~5 小时才跑一次） | GitHub 对高频 scheduled workflow 会延迟/丢弃 | **链式自我触发**：每轮 run 结束用 `GITHUB_TOKEN` dispatch 自己，间隔稳定约 4 分钟；schedule `*/30` 只做兜底点火 |
| 2 | **空闲 30 分钟自动挂起** | 账号级锁死 `fixedAutoSuspendSeconds=1800` | 每轮续租 activity lease（TTL 3600s，容忍调度抖动） |
| 3 | **连续运行 8 小时强制挂起 + 10 分钟冷却**（旧版完全没处理） | 跑满 480 分钟被平台挂起，`cooldownUntil` 前所有唤醒一律 `409 machine_cooldown` | 距上限 ≤30 分钟时**主动 `suspend → resume` 清零计时**，只停几十秒不吃冷却；已进冷却则按 `cooldownUntil` 等待后自动唤醒 |

另有业务层：**3x-ui 代理健康检查 + 自动恢复 + Issue 告警**（沿用旧版逻辑并修复 bug）。

## 目录结构

```
.github/workflows/keepalive.yml    # 看门狗主 workflow（链式调度）
.github/workflows/repo-keepalive.yml  # 每月空提交，防 60 天无活动禁用
scripts/keepalive.sh               # 核心：续租 / 8h 轮转 / 冷却自愈（多机、多 key）
scripts/proxy_check.sh             # 3x-ui 代理检查 / SSH 容器与端口恢复 / Issue 告警
tests/                             # mock API + 全路径集成测试
```

## 每轮流程（约 4 分钟一轮，链式驱动）

```
scripts/keepalive.sh（每台机器）
├─ state ≠ running → 冷却中？剩 ≤480s 本轮等冷却结束唤醒；否则 resume/start 自愈
└─ state = running
   ├─ 距 8h 上限 ≤30min → suspend（计时清零）→ 停 5–15s → resume → 续租
   └─ 距上限还远 → PUT lease（TTL 3600s）；409 → 自动唤醒再续

scripts/proxy_check.sh（业务层）
├─ WS 握手检查 vless-ws 代理 + HTTP 检查 3x-ui 面板
├─ 不可达 → 机器非 running 先唤醒 → SSH（有 key）重启容器/重发布端口
├─ 复检 → 仍不可达 → 开/更新 Issue；恢复 → 自动关闭 Issue
└─ 每 8 小时轮转后的那轮检查若发现端口失效，SSH 会自动重发布
```

结果写入 run 的 Summary（Markdown 表），核心失败 → run 显红 → GitHub 失败邮件。

## 配置

**Secrets（Settings → Secrets and variables → Actions）：**

| Secret | 必要性 | 说明 |
| --- | --- | --- |
| `INSTABOX_API_KEY` | ✅ 已配置 | `ibk_...`，instabox.sh 控制台 Profile → API keys |
| `INSTABOX_SSH_KEY` | ⚠️ 建议补配 | SSH 私钥全文，启用容器/端口级自愈（旧版从未生效，因为没配） |

> 补配 `INSTABOX_SSH_KEY`：instabox.sh 控制台机器页 → SSH 连接信息里有用户名
> （`ibssh_...`，已在 workflow 里保留默认值）；私钥是你在控制台添加公钥对应的
> 那把。配置后每轮轮转若导致端口发布失效，会自动 `docker restart 3x-ui` +
> `instabox-port publish 2053/8443` 重发布。

**Variables（可选，Settings → Secrets and variables → Actions → Variables）：**
`INSTABOX_MACHINE`（默认全部）、`INSTABOX_LEASE_TTL`（默认 3600）、
`INSTABOX_CYCLE`（默认 1=开轮转）、`INSTABOX_CYCLE_MARGIN`（默认 30）、
`INSTABOX_COOLDOWN_WAIT_MAX`（默认 480）、`INSTABOX_API_URL`、
`INSTABOX_SSH_USER` / `PROXY_HOST` / `PROXY_PATH` / `PANEL_HOST` / `PANEL_PATH`
（未配置时沿用旧版硬编码默认值）。

**手动操作（Actions → InstaBox Keepalive → Run workflow）：**
`keepalive`（续一轮链）、`status`（只看状态）、`release`（放租约恢复空闲休眠）、
`restart`（重启机器并走代理恢复流程）。

## 已知限制

- **每 ~7.5–8 小时一次计划内停机**（约 1 分钟）：suspend → resume 轮转是绕开
  「强制挂起 + 10 分钟冷却」的唯一路径，免费计划下无法做到字面零中断。
- **public 仓库专用**：链式调度每天约 1440 Actions 分钟（免费不限）；转 private
  会瞬间耗尽 2000 分钟/月额度，勿转。
- **cron 饥饿**：schedule 兜底也可能延迟数小时，但链式主通道不受影响；
  若发现长时间没有新 run，手动 dispatch 一次 keepalive 重燃即可。
- GitHub 偶发 API 限流会导致链式 dispatch 失败，下个 schedule 周期自动重燃。

## 本地测试

```sh
sh tests/run_tests.sh   # mock API 全路径：续租/8h 轮转/冷却/自愈/status/release/错误 key
```

## 致谢

- [jyucoeng/instabox-keepalive](https://github.com/jyucoeng/instabox-keepalive) — 8h 轮转与冷却处理原型
- [pingmike2/instabox-keepalive](https://github.com/pingmike2/instabox-keepalive) — lease 续租与多账号结构
- [InstaBox](https://instabox.sh) — 官方 lease / suspend / resume API

## 免责声明

仅用于管理你自己账号下的 InstaBox 机器。请遵守 InstaBox 服务条款，使用产生的一切后果由使用者自行承担。
