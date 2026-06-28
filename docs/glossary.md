# Glossary（领域语言表）

> `/grilling` 工作稿。随审讯推进修正。🔬 = 待审 / 存疑 / 定义不全。
> 来源：ARCHITECTURE.md v1.0 附录 A + 领域分析。本表是审讯的「靶子」，不是定论。

## 执行技术层

- **底座（Backend）** ✅ [ADR-0008] — **纯 EventKit**（Calendar + Reminders）。范围去掉 Notes 后正好 = EventKit 覆盖面，[ADR-0007] 的「底座分裂」坍缩，**JXA 彻底退出**。Notes 搁置（日后做需单独引入 JXA 底座）。
- **EventKit** — Apple 官方 Calendar/Reminders 框架（`EKEventStore`/`EKCalendar`/`EKEvent`/`EKReminder`）。实测：list 稳定 UUID 27ms 读出、`NSPredicate` 拉 393 条 411ms、`allowsContentModifications`=writable。绕开 §9 整套坑。授权：Reminders 已 fullAccess、Events 待从 writeOnly 升 full。从 osascript ObjC 桥即可调（数据 op 可用；auth 握手别扭）。
- **JXA** — JavaScript for Automation，`osascript -l JavaScript`。**Notes 底座**（[ADR-0007]）+ EventKit 的 ObjC 桥宿主。agent 不直接接触（[ADR-0002]），仅 CLI 实现者与 break-glass 用。其 -1708/-1728/-10000/whose 日期坑（§9）正是 Calendar/Reminders 弃用脚本字典的原因。
- **sdef** — Scripting Definition，AppleScript/JXA 字典 XML，位于 `<App>.app/Contents/Resources/*.sdef`。
- **TCC** — Transparency, Consent, and Control，macOS 隐私授权。按「控制端 → 被控 App」粒度授权。
- **whose** — JXA/AppleScript 过滤语法，等价 SQL WHERE。对 Date 不稳（§9.4）。

## 架构层（本轮审讯大幅反转，见 ADR-0001..0004）

- **单一入口（Single Entry）** — `skills/ekctl/scripts/ekctl` 一个 Swift 可执行（[ADR-0009]/[ADR-0010]）。子命令 = `calendar` / `reminders` 各自的薄 CRUD + 容器列举（`calendars` / `lists`）。`menu` / `probe` / `run` 均无（[ADR-0004]；纯 EventKit 下也无 JXA run，[ADR-0008]）。
- **薄壳（Thin Shell）** — `ekctl <app> <cmd>`，几个**已验证的参数化稳函数**，**不做查询引擎**。agent 只传参，底层是 EventKit（[ADR-0001]/[ADR-0007]）。取代 v1.0 的「厚抽象层」。
- **CLI-only 契约** — agent **永远只调 CLI、不碰 EventKit/JXA**。CLI 没覆盖的 → 告诉用户「做不了」或记为「待 Henry 加命令」。能力封顶 = CLI 覆盖面（[ADR-0002]）。
- ~~**break-glass / `apple run`**~~ — ❌ 纯 EventKit（[ADR-0008]）下无 JXA run 子命令，break-glass 概念一并消失。
- ~~**逃生舱（Escape Hatch）**~~ — ❌ 作废（[ADR-0002]）。v1.0 概念：接口 3 次不够时 agent 现场写 JXA。
- ~~**3 次降级规则（3-Strike Degradation）**~~ — ❌ 失效（[ADR-0002] 删逃生舱，降级协议无依附）。
- ~~**`--filter` 谓词（MongoDB 风格 DSL）**~~ — ❌ 删除（[ADR-0001]/[ADR-0003]）。复合查询改为「固定粗筛 flag（`--due/--status/--from/--to/--search/--limit`）+ agent 上下文内过滤」。回退方案：极简 `--filter`（$eq/$gte/$contains）。
- **退出码契约** — 0/1/2/3/4/124，AI 据码分支。容器重名 → 码 2 + 列候选（[ADR-0006]）。

## 领域实体（🔬 本轮审讯重点）

- **App（自动化目标）** — Reminders / Calendar / Notes。各有独立 sdef。
- **容器（Container）** 🔬 — 统称承载 item 的命名分组：Reminders=List、Calendar=Calendar、Notes=Folder（但 Notes 还有 Account 一层！）。是否伪抽象？跨 App 是否同构？
- **Account（账户）** 🔬 — 仅 Notes 有。Folder 挂在 Account 下。`--folder <name>` 在多账户重名时如何消歧？接口缺 `--account` 限定（仅 `list-folders` 有）。
- **条目（Item）** — 被操作的对象：reminder / event / note。
- **id / uid** ✅（[ADR-0007] 取代 [ADR-0006] 的 JXA 路径）— **EventKit 路径**：calendar = `calendarIdentifier`（稳定 UUID，27ms 读出）、event/reminder = `eventIdentifier`/`calendarItemIdentifier`（稳定），全部经 `NSPredicate` 定位，**不再用 name+whose**。〔历史：JXA 脚本字典下 calendar id 读不出（-1700）、只能 event uid + name——见 [ADR-0006]，已弃。〕Notes（JXA）的 id 作用域待克隆时验。
- **name** ✅（Calendar 已验，[ADR-0006]）— 人类可读标签，可变、**实测确有重名**（两个「Australian Holidays」）。容器（日历）用 name 定位 + 重名消歧。
- **Container name 解析** ✅（[ADR-0006]）— name→容器 多义时：退出码 2 + 列出候选（或 `--index` 消歧）。**不**静默取第一个。

## 生命周期 🔬

- **Reminder 状态机** — created → (updated) → completed / deleted。`complete` vs `update --complete` 语义重叠？幂等？可逆？
- **Note 软删** — created → (updated) → soft-deleted（移到「最近删除」）→ 30 天后 hard-deleted。🔬 restore（恢复）缺失——生命周期不完整。
- **Event** — created → (updated) → deleted。**硬删**（实测 delete 后 `whose` matches=0，[ADR-0006]）。save 时强校验 `start < end`。

## 测试支持

- **`--dry-run`** — 接口层：只校验参数 + 解析容器名，不执行。`apple run` 无。
- **`--tag <text>`** — 写操作注入 `<text>` 到 name/body 便于 `__jxa_probe__` 清理。

## 待审 / 可能缺失的领域概念 🔬

- **写操作未提供字段的语义** — `update <id> --name "x"` 不带 `--due`：保持不变？还是清空？未规定（建议「未提供 = 保持」，待写进 CLI 规格）。
- **只读日历** ✅（[ADR-0006] 修正）— Calendar **无 `writable` 属性**（§8.2 `.writable()` 是错的，sdef calendar 只有 name/title/color/description）。`create-event` 写只读日历的拒绝路径靠 **save 失败错误兜底**，不靠预判属性。
- **并发** — 两个 `apple` 进程并发 `create`：AppleEvent 是否串行化？未规定。
- **控制端身份（TCC 主体）** — 从 pi / 终端 / cron 调 `apple`，TCC 主体是否同一？影响是否需重新授权。未规定。
- **批量操作** — 无 `delete --filter` / `update --filter` 批量形式。是缺口还是有意？
