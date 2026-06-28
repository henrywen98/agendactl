# ADR Log（架构决策记录）

> `/grilling` 期间产出的决策记录。每条 ADR 记一个「审讯中达成 / 反转 / 澄清」的决策。
> 编号从 0001 起，倒序无关，按达成时间递增。v1.0 ARCHITECTURE.md 本身是审讯前的基线决策集合（不逐一追溯为 ADR，只记录审讯后**变化 / 澄清 / 新增**的决策）。

## 格式

```
# ADR-NNNN: <标题>

- 状态：proposed | accepted | superseded by ADR-MMMM | rejected
- 日期：YYYY-MM-DD
- 上下文：<为什么要审这个点>
- 决策：<审讯后达成什么>
- 后果：<改了什么 / 代价 / 风险>
```

## 索引

| ADR | 标题 | 状态 |
|---|---|---|
| [0001](ADR-0001.md) | bin/apple 从「厚抽象层」降为「薄壳 + 透传」 | accepted |
| [0002](ADR-0002.md) | agent 契约 = CLI-only，删除面向 agent 的逃生舱 | accepted |
| [0003](ADR-0003.md) | 查询 = 固定粗筛 flag + agent 上下文内过滤 | accepted |
| [0004](ADR-0004.md) | 删独立 probe，拆为薄容器列举命令 | accepted |
| [0005](ADR-0005.md) | 首批先做 Calendar（非 reminders） | accepted |
| [0006](ADR-0006.md) | Calendar 定位策略：calendar 按 name + 重名消歧，event 按 uid（实测驱动） | accepted（EventKit 路径下部分被 0007 取代） |
| [0007](ADR-0007.md) | 底座改用 EventKit（Calendar+Reminders），Notes 留 JXA —— 实测推翻 §2.1 选型 | accepted（修订 0001；底座分裂被 0008 坍缩） |
| [0008](ADR-0008.md) | 范围收缩至 Calendar+Reminders（去掉 Notes）→ 底座统一为纯 EventKit | accepted（简化 0007） |
| [0009](ADR-0009.md) | CLI 形态 = Swift 单文件脚本（纯 EventKit） | accepted |
| [0010](ADR-0010.md) | 二进制命名 `macctl`；calendar / reminders 拆成两个独立 skill | superseded by ADR-0012 |
| [0011](ADR-0011.md) | 对外发布新增可选 MCP 适配层（反转 0008 对外部分） | accepted |
| [0012](ADR-0012.md) | 形态=单 `ekctl` skill 内置预编译二进制；改名 macctl→ekctl（反转 0010） | accepted（修订 0010） |

> 本轮审讯把 v1.0 的「接口优先 + 逃生舱」**反转**为「CLI-only 薄壳」：面向 agent 的厚机制（`--filter` DSL、`menu`、3 次降级、独立 probe、逃生舱）全部删除，复杂度移进由 Henry 维护、可黑盒测的 CLI 内部。
> 底座经实测**再反转两次**：① Calendar/Reminders 从 AppleScript 脚本字典（JXA）改为 **EventKit** 官方框架（快 10–40×、id 稳、无 §9 坑，[ADR-0007]）；② 去掉 Notes 后范围正好 = EventKit 覆盖面，底座坍缩为**纯 EventKit、JXA 彻底退出**（[ADR-0008]）。
> **净结果（已实现并实测全绿）**：scope = Calendar + Reminders；二进制 = `skills/ekctl/scripts/ekctl`（Swift 单文件，预编译 universal2 内置进 skill，[ADR-0009]/[ADR-0012]）；agent = CLI-only 调 `ekctl`，不能跑 shell 的 GUI agent 经可选 `mcp/` 适配层（[ADR-0011]）；底座 = 纯 EventKit；skill = 单个 `ekctl` skill 覆盖 calendar + reminders（[ADR-0012] 反转 0010 的拆分）。

<!-- 
审讯议题池（审完的转成 ADR 并从池里移除）：
已解决 / 失效：
- D1 id 作用域 → ADR-0006（Calendar：event 用全局唯一 uid；calendar 无可用 id，按 name）
- D3 name 重名消歧 → ADR-0006（实测真有重名，退出码 2 + 列候选 / --index）
- D7 只读日历写入拒绝路径 → ADR-0006（无 writable 属性，靠 create 失败错误兜底）
- D9 3 次降级规则可执行性 → 失效（ADR-0002 删除逃生舱与降级协议）
- D10 probe 与 list 输出一致性 → 失效（ADR-0004 删除独立 probe）
待审（剩余，多为 reminders/notes 克隆时再碰）：
- D2 Container 是否真同构（Notes Account 层）
- D4 complete vs update --complete 的语义边界
- D5 Note 软删后的 restore 生命周期
- D6 update 未提供字段的语义（保持 vs 清空）
- D8 并发与 AppleEvent 串行化
- D11 批量操作的有无边界
- D12 TCC 控制端身份跨调用上下文
-->
