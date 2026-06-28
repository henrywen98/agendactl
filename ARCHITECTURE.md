# ekctl 架构规格 v2.1

> 状态：v2.1 · 已实测验证（2026-06-25，macOS 26.3 Tahoe / Apple Silicon）；v2.1 对外开源。
> 本文是**设计契约**。决策的完整演进与理由见 `docs/adr/`（ADR-0001..0012），领域语言见 `docs/glossary.md`。

## 变更史

- **v2.1（本次，对外开源）**：改名 **`macctl` → `ekctl`**（GitHub 撞名 + SEO，ADR-0012）；形态收为**单个 `ekctl` skill 内置预编译 universal2 二进制**（装即用，反转 v2.0 的两-skill 拆分，ADR-0012）；新增**可选 MCP 适配层 `mcp/`**（触达 Claude Desktop / Codex 等不能跑 shell 的 GUI agent，反转 ADR-0008 对外部分，ADR-0011）。目录 `bin/`、`lib/` 删除，`.pi/skills/` → `skills/ekctl/`。
- **v2.0**：经 `/grill-with-docs` 审讯，v1.0 的「接口优先 + JXA 逃生舱」被连续反转为「**CLI-only 薄壳 + 纯 EventKit**」。四次关键反转（详见 ADR）：
  - **CLI-only**：agent 只调 CLI、**永不写代码**；删除逃生舱 / 3 次降级 / `menu` / `--filter` DSL / 独立 `probe`（ADR-0001..0004）。
  - **底座换 EventKit**：实测 AppleScript 脚本字典 jank（`calendarIdentifier` 读不出、`whose` 查询 3–6s），改用 Apple 官方 EventKit——快 **10–40×**、id 稳、无桥接坑（ADR-0006/0007）。
  - **纯 EventKit + 去 Notes**：范围收缩到 Calendar + Reminders，正好 = EventKit 覆盖面，JXA 彻底退出（ADR-0008）。
  - **Swift 单文件 + 命名 `macctl` + 两个独立 skill**（ADR-0009/0010；命名与拆分均于 v2.1 被 ADR-0012 反转）。
- **v0.1–v1.0（历史）**：JXA Probe-Execute → 接口优先 + 逃生舱。已被 v2.0 取代，保留于 ADR 与 git 历史。

---

## 0. TL;DR

| 项 | 决定 |
|---|---|
| 底座 | **EventKit**（官方框架：`EKEventStore` / `EKCalendar` / `EKEvent` / `EKReminder`） |
| 目标 App | **Calendar、Reminders**（Notes 搁置——无公开框架，见 ADR-0008） |
| 调用模式 | **CLI-only**：agent 只调 `ekctl` 命令、传参，**永不写代码**；无逃生舱 |
| 入口 | **`skills/ekctl/scripts/ekctl`**（Swift；内置预编译 universal2 ad-hoc 签名二进制，旁附 `.swift` 源码 + `build.sh`，ADR-0012） |
| 命令 | calendar / reminders 各 CRUD + 容器列举；固定粗筛 flag，复合查询由 agent 在上下文内筛 |
| 是否用 MCP | CLI 直调不用；对外另附**可选** `mcp/` 薄适配层给不能跑 shell 的 GUI agent（ADR-0011） |
| Skill | 单个 `skills/ekctl/` 覆盖 calendar + reminders，内置二进制，CLI-only 工作流（ADR-0012） |

一句话：**agent 调 `ekctl reminders create --list 任务 --name ...`（只传参）；CLI 内部用 EventKit 处理授权、时区、稳定 id、校验；CLI 没覆盖的就告诉用户「做不了」或由维护者加命令。能力封顶在 CLI 覆盖面，但出错面与维护成本都降一个量级。**

---

## 1. 背景与目标

### 1.1 要解决的问题

让 AI agent 可靠地读写 macOS 自带应用的数据（日历、提醒），用于生活自动化：
- 「明天 9 点提醒我交报告」
- 「这周有什么会」
- 「把那个提醒的时间改到后天」
- 「今天有哪些待办没做完」

### 1.2 目标 App 与实测能力

| App | EventKit 实体 | 读 | 增 | 改 | 删 | 备注 |
|---|---|---|---|---|---|---|
| Reminders | `EKReminder` | ✅ | ✅ | ✅ | ✅ | 实测 7 lists / 393 reminders；fetch 411ms |
| Calendar | `EKEvent` | ✅ | ✅ | ✅ | ✅ | 实测 9–10 cals；硬删；save 强校验 start<end |
| ~~Notes~~ | — | — | — | — | — | **搁置**：无 EventKit / 公开框架，需 JXA 另立底座（ADR-0008） |

### 1.3 Goals

- **G1** agent 不依赖人工，直接读写两大 App 的核心数据。
- **G2** 省上下文：高频操作走命令（`--help` 按需查签名），agent 永不下到框架层。
- **G3** 可靠优先：用官方 EventKit，稳定 id + 毫秒级 `NSPredicate` 查询，绕开 AppleScript 脚本字典的桥接坑。
- **G4** 可安全验证：写操作走 CLI（带参数校验 + `end>start` 等业务校验），并有 `__probe__` 标记的黑盒回归测试。
- **G5** 可扩展：加 App = 加 `ekctl <app>` 子命令 + 一个 skill 目录（若该 App 无框架则单独引底座）。

### 1.4 Non-goals

- ❌ 不做跨 App 编排框架——联动流由 agent 当场用多次命令组合。
- ❌ 不做 GUI 自动化（点按钮、模拟键鼠）——那是 Accessibility API 的领域。
- ❌ 不做 iOS 端。
- ❌ 不自建 MCP server（pi 不支持，且无必要）。
- ❌ 不做持久化——状态都在原生 App 里，ekctl 是读写器不是存储层。
- ❌ 不给 agent 任意代码执行通道（无逃生舱，ADR-0002）。

---

## 2. 关键设计决策（详见 ADR）

| 决策 | 结论 | ADR |
|---|---|---|
| 抽象层厚度 | 薄壳：几个已验证的参数化命令，不做查询引擎 | [0001] |
| agent 契约 | **CLI-only**：只调命令、不碰代码；无逃生舱；能力封顶 = CLI 覆盖面 | [0002] |
| 查询 | 固定粗筛 flag（`--from/--to/--status/--due/--limit`）+ agent 上下文内精筛；不做 `--filter` DSL | [0003] |
| 容器发现 | `lists`/`calendars` 薄命令拿真实名 + id；无独立 probe | [0004] |
| 底座 | **EventKit**（非 AppleScript 脚本字典）——实测快 10–40×、id 稳、无桥接坑 | [0006][0007] |
| 范围 | Calendar + Reminders（Notes 搁置）→ 底座纯 EventKit | [0008] |
| 实现语言 | **Swift 单文件脚本**（`#!/usr/bin/swift`）——EventKit 原生授权 + 类型安全 | [0009] |
| 命名 / 打包 | 二进制 `ekctl`；calendar / reminders 拆两个独立 skill | [0010] |

> 为什么 CLI-only 删得动那么多东西：v1.0 的复杂度（3 次降级纪律、`menu`、JXA 陷阱手册、schema 教学）几乎全为「逃生舱」服务。一旦 agent 不再写代码（ADR-0002），这些全部失去依附。
> 为什么 EventKit 而非 JXA：v1.0 §2.1 否 EventKit 的唯一理由是「AI 生成 JXA 正确率高」；CLI-only 下 agent 不生成代码，该理由失效，EventKit 的稳定 id + 毫秒查询全面胜出（ADR-0007）。

---

## 3. 架构总览

### 3.1 分层

```
能跑 shell 的 agent（Claude Code / Cursor / pi / 脚本 / cron）
  └─ 读 skills/ekctl/SKILL.md（触发即载），只调：ekctl <app> <cmd> --flag …（只传参，永不写码）
        │ bash
        │
不能跑 shell 的 GUI agent（Claude Desktop / Codex desktop）
  └─ MCP tools ─▶ mcp/（薄转发，零业务逻辑，ADR-0011）
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│  skills/ekctl/scripts/ekctl  —— Swift，CLI-only 薄壳        │
│  ├─ 参数解析 + 校验（缺必填 / end>start / 容器名 …）        │
│  ├─ EventKit 调用（授权、查询、CRUD）                       │
│  └─ 输出裸 JSON（stdout）/ 错误 `ekctl: …`（stderr）       │
└───────────────┬──────────────────────────────────────────┘
                │ EventKit（EKEventStore）
                ▼
   macOS Calendar / Reminders（EKEvent / EKReminder）← EventKit / iCloud 同步
```

### 3.2 目录结构

```
ekctl/                          # 项目根（GitHub repo 名 = ekctl）
├── README.md  / README.zh-CN.md  # 人读总览（英文主 + 中文副）
├── ARCHITECTURE.md              # 本文档（设计契约）
├── LICENSE                      # MIT
├── skills/
│   └── ekctl/                   # 自包含、装即用的 skill（覆盖 calendar + reminders）
│       ├── SKILL.md             # 单个 skill（description 路由防误触发）
│       └── scripts/
│           ├── ekctl            # 内置预编译 universal2 + ad-hoc 签名二进制（运行时）
│           ├── ekctl.swift      # 源码（SSOT，可审计 / 可重建）
│           └── build.sh         # 2×swiftc → lipo → codesign
├── mcp/                         # 可选 stdio MCP 适配层（Claude Desktop / Codex），ADR-0011
│   ├── index.mjs · package.json · README.md
├── tests/
│   └── roundtrip.sh             # 黑盒回归（CRUD round-trip，__probe__ 自清理）
├── docs/
│   ├── adr/                     # 决策记录 ADR-0001..0012 + README 索引
│   └── glossary.md              # 领域语言表
└── references/
    └── calendar.sdef.xml        # AppleScript 字典快照（历史参考，非当前底座）
```

> 注：v1.0 的 `lib/std.js`（JXA helper）与 `bin/`、`lib/` 目录已删——EventKit 逻辑全在 `skills/ekctl/scripts/ekctl` 内。

---

## 4. 统一契约

所有 `ekctl` 命令遵守以下契约，agent 据此稳定解析。

### 4.1 退出码

| 码 | 含义 | agent 应对 |
|---|---|---|
| `0` | 成功 | 读 stdout 的 JSON |
| `1` | 用法/参数错（缺必填、未知命令、`end<=start`） | 看 stderr 改参数；查 `ekctl <app> --help` |
| `2` | 未找到（容器名 / id 不存在；含重名歧义） | 看 stderr 的 `available:` 选对的；或先 `lists`/`calendars` |
| `3` | 未授权（EventKit TCC） | 引导用户在 系统设置→隐私与安全→日历/提醒事项 授权 |
| `4` | 运行时错（EventKit save/remove 失败等） | 读 stderr 原因 |

### 4.2 输出格式

- **成功**：退出码 0，stdout = 裸 JSON（对象或数组，无信封），stderr 空。
- **失败**：退出码非 0，stderr 首行 `ekctl: <message>`，可选 `hint:` / `available:` 行。
- 无信封是为让 tool-calling agent 直接解析 stdout，最省 token（Unix 惯例）。

### 4.3 标识与命名

- **id**：用 EventKit 稳定标识——event 用 `eventIdentifier`，reminder 用 `calendarItemIdentifier`。`update`/`complete`/`delete`/以这个 id 定位。
- **容器名**：calendar / list 用 `--calendar`/`--list` 传 name。重名 → 退出码 2 + `available:` 列候选；用 `--index <n>` 消歧（ADR-0006）。
- **日期**：输入 ISO 8601（`2026-06-26T09:00:00`，无时区后缀 = 本机时区；也接受 `2026-06-26`）；输出统一 UTC ISO（`.000Z`）。

### 4.4 查询（list 家族）

固定粗筛 flag，返回 JSON 后由 agent 在上下文内做复合/长尾过滤（ADR-0003）：
- calendar：`list-events [--calendar] [--from] [--to] [--limit]`
- reminders：`list [--list] [--status incomplete|completed|all] [--due today|<iso>] [--limit]`

复合查询（如「今天到期 + 高优先级 + 未完成」）= 粗筛 flag + agent 自己筛，不引入 `--filter` DSL。

---

## 5. 命令规格

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

ekctl --help / ekctl calendar --help / ekctl reminders --help
```

**示例**：
```bash
# 「明天 9 点提醒我交报告」
ekctl reminders create --list "任务" --name "交报告" --due "2026-06-26T09:00:00"
# → {"id":"...","name":"交报告","list":"任务","due":"2026-06-26T01:00:00.000Z"}

# 「把那个提醒改到后天」
ekctl reminders update <id> --due "2026-06-28T09:00:00"

# 「这周有什么会」
ekctl calendar list-events --from "2026-06-22T00:00:00" --to "2026-06-29T00:00:00"
```

**设计原则**：
- **参数而非代码**：agent 永远只传字符串/数字，不传代码片段。
- **校验前移**：缺必填、`end<=start`、容器名不存在、只读容器写入——都在 CLI 内挡掉（退出码 1/2）。
- **优先级**：reminders `--priority` 0=无、1–4=高、5=中、6–9=低（Apple 约定）。
- **扩命令 ≠ 改运行时**：加子命令只动 `skills/ekctl/scripts/ekctl` + 对应 SKILL.md。

---

## 6. Skill 结构

**单个 skill**（ADR-0012，反转 0010 的两-skill 拆分），同时覆盖 calendar + reminders，**内置预编译二进制**——装一个 skill 即全功能、二进制不重复。

```
skills/ekctl/
├── SKILL.md            # frontmatter（触发词 + calendar/reminders 路由）+ 命令索引 + 工作流
└── scripts/
    ├── ekctl           # 内置预编译 universal2 + ad-hoc 签名二进制
    ├── ekctl.swift     # 源码（SSOT）
    └── build.sh        # 可复现构建
```

**SKILL.md 要点**：
- `description` 列触发词与场景（决定何时自动加载），并在一份 description 内写清 **calendar（日程，有 start/end、无「完成」）vs reminders（待办，有 due、可完成）的路由**避免误触发——拆分的防混职责改由 description 承担。
- 工作流：**先 `lists`/`calendars` 拿真实容器名**（防「任务」vs「提醒」、「个人」vs「Personal」写错）→ 调命令 → 复合查询自己筛 → 写后复读确认。
- 明确 CLI-only：不提 EventKit/脚本，CLI 没覆盖的直说「暂不支持」。
- 交代二进制位置：`ekctl` 在 PATH，否则用**随 skill 内置**的 `scripts/ekctl`（防 agent 满盘 `find`）。

> 不能跑 shell 的 GUI agent（Claude Desktop / Codex）走 `mcp/` 适配层（ADR-0011），暴露与 CLI 同名的 tools，业务逻辑仍只在 CLI 内一处。

---

## 7. 数据模型（EventKit）

```swift
let store = EKEventStore()

// 容器（日历 / 提醒清单）—— EKCalendar，按实体类型取
store.calendars(for: .event)      // 日历
store.calendars(for: .reminder)   // 提醒清单
  // .title  .calendarIdentifier(稳定 UUID)  .allowsContentModifications(可写)

// 事件 —— EKEvent
//   .eventIdentifier  .title  .startDate  .endDate  .location  .notes  .isAllDay  .calendar
store.predicateForEvents(withStart:end:calendars:)  // 查询谓词
store.events(matching:)                              // 同步返回（毫秒级）
store.event(withIdentifier:)                         // 按 id 取
// 增/改：EKEvent(eventStore:) → 设属性 → store.save(_, span:.thisEvent, commit:true)
// 删：store.remove(_, span:.thisEvent, commit:true)（硬删）

// 提醒 —— EKReminder
//   .calendarItemIdentifier  .title  .notes  .dueDateComponents  .priority  .isCompleted  .calendar
store.predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)
store.predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)
store.predicateForReminders(in:)
store.fetchReminders(matching:completion:)           // 异步，CLI 内用 semaphore 同步化
store.calendarItem(withIdentifier:) as? EKReminder   // 按 id 取
// 增/改：EKReminder(eventStore:) → 设属性 → store.save(_, commit:true)；删：store.remove(_, commit:true)
```

> 业务校验在 CLI 内：Calendar 在 `save` 时强校验 `start < end`（违反报 `NSLocalizedDescription`），故 `create-event`/`update-event` 先验 `end>start`。

---

## 8. 授权（EventKit TCC）

- EventKit 走 macOS 的 TCC 授权，**Calendar 与 Reminders 各一个独立授权桶**（与 v1.0 的「自动化」桶不同）。
- 首次调用触发系统授权框（Swift `requestFullAccessToEvents` / `requestFullAccessToReminders`，macOS 14+），用 semaphore 同步等待。授权后 headless 可用。
- 实测：本机 Reminders 已 `fullAccess`；Calendar 可能处于 `writeOnly`（能写不能读），需一次性升级到完全访问（首次读触发弹框，点允许）。
- **不做绕过**：TCC 是用户安全边界。未授权返回退出码 3 + 引导提示。

---

## 9. 测试与验证

- **黑盒回归**：`tests/roundtrip.sh`——自动挑第一个可写容器，对 reminders 与 calendar 各跑 CRUD round-trip（create→update→complete/校验→delete→验归零），用 `__probe__` 标记 + 自清理，**幂等可重跑**。实测 8/8 通过。
- **触发 + 用法 eval**：用真实 prompt 跑 with-skill vs baseline 对照，验证两个 skill 触发对、选对、用对（全程 CLI-only、零误用）。
- **快照**：`references/calendar.sdef.xml` 留 AppleScript 字典快照，作历史参考（非当前底座）。

---

## 10. 路线图

| 阶段 | 产出 | 状态 |
|---|---|---|
| P0 审讯定架构 | ADR-0001..0010 + glossary | ✅ |
| P1 运行时 | `skills/ekctl/scripts/ekctl`（calendar + reminders，EventKit） | ✅ 实测全绿 |
| P2 skill | calendar / reminders 两个 SKILL.md | ✅ 过 eval |
| P3 测试 | `tests/roundtrip.sh` 黑盒回归 | ✅ |
| P4 扩展 | Notes（需引 JXA 底座）/ Mail / Contacts | 🔜 按需 |
| P5 自动化流 | launchd 定时触发 + 自然语言入口 | 🔜 |

---

## 附录：术语

- **EventKit** — Apple 官方 Calendar/Reminders 框架（`EKEventStore` 等）。本项目底座。
- **CLI-only** — agent 只调 `ekctl` 命令、不写代码；能力封顶 = CLI 覆盖面（ADR-0002）。
- **薄壳** — `ekctl <app> <cmd>`，参数化稳函数 + 校验，不做查询引擎（ADR-0001）。
- **TCC** — Transparency, Consent, and Control，macOS 隐私授权；EventKit 的 Calendar / Reminders 各一桶。
- **ADR** — Architecture Decision Record，见 `docs/adr/`，记录从 v1.0 到 v2.0 每次反转的理由与实测。
