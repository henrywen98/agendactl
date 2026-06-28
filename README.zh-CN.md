# agendactl

[![CI](https://github.com/henrywen98/agendactl/actions/workflows/ci.yml/badge.svg)](https://github.com/henrywen98/agendactl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)

**一个装了即用的 agent skill,让任意 AI agent 读写 macOS 日历与提醒事项。** skill 内置一个单文件、可审计的 Swift CLI(底座是 Apple 官方 [EventKit](https://developer.apple.com/documentation/eventkit))——`git clone` 到 agent 的 skills 目录就能用。**不用 MCP、不起 server、无任意代码执行。**

> *"明天 9 点提醒我交报告"* · *"这周有什么会"* · *"把那条标记完成"*
> agent 只调 `agendactl <app> <cmd> --flag …` 传参——永不写代码、不碰 EventKit、没有逃生舱。

[English](./README.md) · [中文]

---

## 实战演示

```text
你    ▸ 这周有什么会?

agent ▸ agendactl calendar list-events --from 2026-06-29T00:00:00 --to 2026-07-06T00:00:00
      ← {"_iso":"2026-06-29","items":[
           {"summary":"Funda Sales & Engineer sync","calendar":"工作",
            "start":"2026-07-02T01:00:00Z","end":"2026-07-02T01:30:00Z"} ]}
      这周有一个会:
        • 周四 07-02,09:00–09:30 — Funda Sales & Engineer sync(工作)

你    ▸ 提醒我明天 9 点交报告

agent ▸ agendactl reminders create --list 任务 --name "交报告" --due 2026-06-30T09:00:00
      ← {"id":"…","name":"交报告","list":"任务","due":"2026-06-30T01:00:00.000Z"}
      已加到「任务」清单,明天 09:00 到期。
```

agent 读 SKILL.md,只传参调 `agendactl`,解析 JSON,再用自然语言回答——全程不写代码、不碰 EventKit。

## 它是什么

一个 [agent **Skill**](https://github.com/VoltAgent/awesome-agent-skills):一个带 `SKILL.md`(告诉 agent 何时、如何使用)的目录,外加 `scripts/` 里一个**预编译、已签名的 universal 二进制**。装上这个目录,任意支持 skill 的 agent——Claude Code / Codex / Cursor / Gemini CLI / pi——就能管你的日历和提醒。同一个二进制也是普通 CLI,你自己或 cron/脚本都能直接调。

## 为什么是 skill,而不是 MCP server?

Apple 日历/提醒的 MCP server(和少数 CLI)已经很多。`agendactl` 走另一种形态:

| | `agendactl`(skill + CLI) | 典型 Apple-app MCP server |
|---|---|---|
| 安装 | `git clone` 一个目录进 skills 夹 | 配 MCP server + 它的运行时 |
| 安装运行时 | **零**——内置签名 universal 二进制 | Node / Python / bun |
| 能跑 shell 的 agent(Claude Code/Cursor/pi/cron/脚本) | ✅ 直接用 | ❌ 需要 MCP host |
| 给 agent 的任意代码执行权 | ❌ 无,只传参,能力封顶 = CLI 覆盖面 | 视实现 |
| 可审计面 | 一个 Swift 文件(~350 行)从头读到尾 | server + 依赖 |
| 底座 | 原生 EventKit(稳定 id、毫秒级查询) | EventKit / AppleScript / JXA |

> 范围是刻意的:只服务能跑 shell 的 agent。跑不了 shell 的纯 GUI 客户端(如 Claude Desktop)有意不覆盖——那是 MCP server 的地盘,本项目不去抢。

这套设计不是拍脑袋——是把更早的「JXA + 逃生舱」架构在审讯下连续反转得到的。每一步反转的理由与实测见 [`docs/adr/`](./docs/adr/)。

## 安装

**要求:** macOS 14+(Sonoma 起),Apple Silicon 或 Intel。仓库已内置预编译 universal 二进制:`skills/agendactl/scripts/agendactl`。

**当 agent skill 用**(推荐)—— 把自包含的 skill 拷进 agent 的 skills 目录:
```bash
git clone https://github.com/henrywen98/agendactl.git
cp -R agendactl/skills/agendactl ~/.agents/skills/agendactl    # 共享 agent-skills 目录(pi / OpenCode 等)
# 或各 agent 自己的目录:~/.claude/skills/agendactl(Claude Code)· ~/.codex/skills/agendactl(Codex)
```
skill 内置了二进制,装上即可用——**无需配 PATH**。支持 skill 的 agent 会按 skill 自身目录解析 `scripts/agendactl`。(`git clone` 不打 quarantine 标记,二进制直接跑;若你从浏览器下的 ZIP,清一次:`xattr -dr com.apple.quarantine ~/.claude/skills/agendactl/scripts/agendactl`。)

**当普通 CLI 用**(自己的脚本 / cron)—— 放进 `PATH`:
```bash
ln -s "$(pwd)/agendactl/skills/agendactl/scripts/agendactl" /opt/homebrew/bin/agendactl
agendactl --help
```

**从源码重建**(可选,审计或刷新构建):
```bash
./skills/agendactl/scripts/build.sh        # 2× swiftc → lipo → codesign(universal2,ad-hoc 签名)
```

## 授权(一次性)

EventKit 受 macOS 隐私(TCC)管控。首次使用触发**日历**与**提醒事项**的系统授权框——在有登录 GUI 的会话里点一次「允许」(两者是独立授权桶)。未授权时退出码 `3` 并给提示。这一步任何碰这两个 app 的工具都绕不过,无法在纯 headless 下跳过。

## 用法

```bash
agendactl --help                 # 总览
agendactl reminders --help       # 提醒命令
agendactl calendar --help        # 日历命令

# 「明天 9 点提醒我交报告」
agendactl reminders create --list "任务" --name "交报告" --due "2026-06-29T09:00:00"

# 「这周有什么会」
agendactl calendar list-events --from "2026-06-29T00:00:00" --to "2026-07-06T00:00:00"

# 「把那条提醒改到后天」
agendactl reminders update <id> --due "2026-07-01T09:00:00"
```

**契约**(便于 agent 稳定解析):

- 成功 → 退出码 `0`,stdout 为 **JSON**。每个响应顶层带 `_at` / `_tz` / `_iso` / `_note` 元数据:list 响应把数组放在 `items` 下(`{…meta, "items": [...]}`),写响应把这些 meta 键叠加到结果字段上;失败 → 退出码非 0,stderr 首行 `agendactl: <原因>`。
- 退出码:`0` 成功 · `1` 用法/参数错 · `2` 未找到(含重名歧义) · `3` 未授权 · `4` 运行时错。
- 日期:输入 ISO 8601(无时区后缀 = 本地时区);输出 UTC ISO。每个响应带 `_at` / `_tz` / `_iso` / `_note` 元数据——用 `._iso` 取「今天」。
- 容器(日历/清单)按**名字**寻址;重名返回退出码 `2` + 候选,用 `--index <n>` 消歧。

## 命令

```
agendactl calendar
  calendars
  list-events  [--calendar <名>] [--from <iso>] [--to <iso>] [--limit <n>]
  create-event --calendar <名> --summary <文本> --start <iso> --end <iso>
               [--location <文本>] [--notes <文本>] [--all-day]
  update-event <id> [--summary] [--start] [--end] [--location] [--notes]
  delete-event <id>

agendactl reminders
  lists
  list     [--list <名>] [--status incomplete|completed|all] [--due today|<iso>] [--limit <n>]
  create   --list <名> --name <文本> [--notes <文本>] [--due <iso>] [--priority 0-9]
  update   <id> [--name] [--notes] [--due] [--priority] [--complete]
  complete <id>
  delete   <id>
```

## 工作原理

```
支持 skill 的 agent(Claude Code / Codex / Cursor / Gemini CLI / pi）
  └─ 读 skills/agendactl/SKILL.md，调：agendactl <app> <cmd> --flag …（只传参）
        │ 跑内置二进制
        ▼
  agendactl（Swift，EventKit）—— 参数校验、授权、时区、稳定 id、end>start
        ▼
  macOS 日历 / 提醒（EKEvent / EKReminder）← iCloud 同步
```

CLI 是单一事实源:校验、授权、时区、稳定 id、业务规则全在一个 Swift 文件里。

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** —— 设计契约(先读这个)
- **[docs/adr/](./docs/adr/)** —— 决策记录(ADR-0001..0012)
- **[docs/glossary.md](./docs/glossary.md)** —— 领域语言表

## 状态

- ✅ CLI 运行时(`skills/agendactl/scripts/agendactl`,EventKit,Calendar + Reminders CRUD)
- ✅ Agent skill(`skills/agendactl/SKILL.md`)
- ✅ 测试:smoke(无授权契约)+ round-trip(EventKit CRUD,`__probe__` 标记、幂等、自清理)
- 🔜 Notes(需引 JXA 底座) · Mail / Contacts · 定时自动化

```bash
./tests/smoke.sh        # 契约检查,不授权 / 不写数据
./tests/roundtrip.sh    # 完整 EventKit CRUD round-trip(需 TCC 授权;写入并清理 __probe__ 项)
```

## 许可

[MIT](./LICENSE)
