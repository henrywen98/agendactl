# ekctl

**用任意 AI agent 读写 macOS 日历与提醒事项** —— 一个单文件、可审计的 Swift CLI,底座是 Apple 官方 [EventKit](https://developer.apple.com/documentation/eventkit),并以 agent skill 形态分发。**不依赖 MCP,无任意代码执行通道。**

> *"明天 9 点提醒我交报告"* · *"这周有什么会"* · *"把那条标记完成"*
> agent 只调 `ekctl <app> <cmd> --flag …` 传参——永不写代码、不碰 EventKit、没有逃生舱。

[English](./README.md) · [中文]

---

## 为什么再造一个日历/提醒工具?

Apple Reminders/Calendar 的 MCP server 已经很多。`ekctl` 反向下注:做一个**薄的、参数化的 CLI**,agent 用参数驱动;再给够不着 shell 的 GUI 客户端配一个*可选的* MCP 适配器。

| | `ekctl` | 典型 Apple-app MCP server |
|---|---|---|
| agent 接口 | 调 CLI 传 flag | 调 MCP tools |
| 不装 MCP client 能用吗 | ✅ 任何能跑 `bash` 的 agent(Claude Code / Cursor / pi / 脚本 / cron) | ❌ 需要 MCP host |
| 配 Claude Desktop / Codex 能用吗 | ✅ 走可选的 `mcp/` 适配器 | ✅ |
| 给 agent 的任意代码执行权 | ❌ 无,只传参,能力封顶 = CLI 覆盖面 | 视实现 |
| 可审计面 | 一个 Swift 文件(~350 行)从头读到尾 | server + 依赖 |
| 安装运行时 | 单个签名二进制(无需 Node/Python) | Node / Python / bun |
| 底座 | 原生 EventKit(稳定 id、毫秒级查询) | EventKit / AppleScript / JXA |

这套设计不是拍脑袋——是把更早的「JXA + 逃生舱」架构在审讯下连续反转得到的。每一步反转的理由与实测见 [`docs/adr/`](./docs/adr/)。

## 安装

**要求:** macOS 14+(Sonoma 起),Apple Silicon 或 Intel。仓库已内置预编译 universal 二进制:`skills/ekctl/scripts/ekctl`。

```bash
git clone https://github.com/henrywen98/ekctl.git
cd ekctl
```

`git clone` **不会**打 quarantine 标记,二进制可直接跑。(若你从浏览器下的 ZIP,清一次:`xattr -dr com.apple.quarantine skills/ekctl/scripts/ekctl`。)

按用法三选一:

**当 CLI 用**(Claude Code / Cursor / pi / 自己的脚本)—— 放进 `PATH`:
```bash
ln -s "$(pwd)/skills/ekctl/scripts/ekctl" /opt/homebrew/bin/ekctl
ekctl --help
```

**当 agent skill 用** —— 把自包含的 skill 拷进 agent 的 skills 目录:
```bash
cp -R skills/ekctl ~/.claude/skills/ekctl      # Claude Code;或 .pi/skills 等
```
skill 内置了二进制,装上 skill 即可用。

**当 MCP server 用**(Claude Desktop / Codex desktop)—— 见 [`mcp/`](./mcp/)。

**从源码重建**(可选,用于审计或刷新构建):
```bash
./skills/ekctl/scripts/build.sh        # 2× swiftc → lipo → codesign(universal2,ad-hoc 签名)
```

## 授权(一次性)

EventKit 受 macOS 隐私(TCC)管控。首次使用时 ekctl 触发**日历**与**提醒事项**的系统授权框——在有登录 GUI 的会话里点一次「允许」(日历与提醒是两个独立授权桶)。未授权时 ekctl 退出码 `3` 并给提示。这一步是任何碰这两个 app 的工具都绕不过的,无法在纯 headless 下跳过。

## 用法

```bash
ekctl --help                 # 总览
ekctl reminders --help       # 提醒命令
ekctl calendar --help        # 日历命令

# 「明天 9 点提醒我交报告」
ekctl reminders create --list "任务" --name "交报告" --due "2026-06-29T09:00:00"
# → {"id":"…","name":"交报告","list":"任务","due":"2026-06-29T01:00:00.000Z", …}

# 「这周有什么会」
ekctl calendar list-events --from "2026-06-29T00:00:00" --to "2026-07-06T00:00:00"

# 「把那条提醒改到后天」
ekctl reminders update <id> --due "2026-07-01T09:00:00"
```

**契约**(便于 agent 稳定解析):

- 成功 → 退出码 `0`,stdout 为**裸 JSON**(无信封);失败 → 退出码非 0,stderr 首行 `ekctl: <原因>`。
- 退出码:`0` 成功 · `1` 用法/参数错 · `2` 未找到(含重名歧义) · `3` 未授权 · `4` 运行时错。
- 日期:输入 ISO 8601(无时区后缀 = 本地时区);输出 UTC ISO。每个响应带 `_at` / `_tz` / `_iso` / `_note` 元数据——用 `._iso` 取「今天」。
- 容器(日历/清单)按**名字**寻址;重名返回退出码 `2` + 候选,用 `--index <n>` 消歧。

## 命令

```
ekctl calendar
  calendars
  list-events  [--calendar <名>] [--from <iso>] [--to <iso>] [--limit <n>]
  create-event --calendar <名> --summary <文本> --start <iso> --end <iso>
               [--location <文本>] [--notes <文本>] [--all-day]
  update-event <id> [--summary] [--start] [--end] [--location] [--notes]
  delete-event <id>

ekctl reminders
  lists
  list     [--list <名>] [--status incomplete|completed|all] [--due today|<iso>] [--limit <n>]
  create   --list <名> --name <文本> [--notes <文本>] [--due <iso>] [--priority 0-9]
  update   <id> [--name] [--notes] [--due] [--priority] [--complete]
  complete <id>
  delete   <id>
```

## 工作原理

```
AI agent  ──(bash: ekctl <app> <cmd> --flag …,只传参)──▶  ekctl(Swift,EventKit)  ──▶  macOS 日历 / 提醒
GUI agent ──(MCP tools)──▶  mcp/ 适配器  ──▶  ekctl  ──▶  …
```

CLI 是单一事实源:参数校验、授权、时区、稳定 id、业务规则(如 `end > start`)全在它内部。可选的 MCP 适配器只是薄转发,不加任何业务逻辑。

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** —— 设计契约(先读这个)
- **[docs/adr/](./docs/adr/)** —— 决策记录(ADR-0001..0012,v1→v2 的演进)
- **[docs/glossary.md](./docs/glossary.md)** —— 领域语言表

## 状态

- ✅ CLI 运行时(`skills/ekctl/scripts/ekctl`,EventKit,Calendar + Reminders CRUD)
- ✅ Agent skill(`skills/ekctl/SKILL.md`)
- ✅ 黑盒回归测试(`tests/roundtrip.sh`,`__probe__` 标记、幂等、自清理)
- 🔜 MCP 适配器(`mcp/`) · Notes(需引 JXA 底座) · Mail / Contacts · 定时自动化

测试会往第一个可写清单/日历写带 `__probe__` 标记的临时项再删掉:
```bash
./tests/roundtrip.sh
```

## 许可

[MIT](./LICENSE)
