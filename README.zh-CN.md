# Acore Boss SmartAI Lua（中文说明）

AzerothCore 3.3.5a 的 Eluna 活动 Boss 脚本：带运行时持久化、配置热加载、事件追踪与贡献快照。

## 功能

- 智能战斗 AI、多套技能池预设与技能节奏档位。
- **可切换的强度档位**，由专用 `creature_template` 承载（见下）。
- 运行时数据落在 `ac_eluna`：`boss_activity_runtime`、`boss_activity_config`、`boss_activity_events`、`boss_activity_contributors`。
- 表结构由 Lua 自举与迁移（不需要 Web 端建表）。
- 活动 Boss 使用**专用模板**，不再复用副本 Boss，因此不会和核心 `SmartAI` 形成双 AI。
- 命令：

| 命令 | 作用 |
|---|---|
| `.boss` / `.boss spawn` | 在配置刷新点生成 Boss |
| `.boss kill` | 击杀当前活跃 Boss（走正常死亡与奖励流程） |
| `.boss clear`（别名 `.boss despawn`） | 直接移除活跃 Boss、不发奖励并复位运行时记录 |
| `.boss rebase` | 按模板重算基准血量再套用倍率（**仅脱战可用**） |
| `.boss config reload` | 从 `ac_eluna` 热加载配置（AGMP 保存后自动调用） |
| `.boss preset list` / `.boss preset <key>` | 查看 / 切换技能池预设 |
| `.boss difficulty list` / `.boss difficulty <key>` | 查看 / 切换技能节奏档位 |
| `.boss help` | 帮助 |

## 难度档位

原先复用 `entry 647`（死亡矿井「绿皮队长」，模板带 `AIName=SmartAI` 和两条 `smart_scripts`），现改为 4 个等级 83 的专用模板（无 `AIName`、无 `smart_scripts`、无掉落）：

| entry | 档位 | HealthModifier | DamageModifier | rank | 血量（倍率 1500 时） |
|---|---|---|---|---|---|
| 190090 | 入门（与旧档同级） | 0.21 | 1.0 | 1 | 4,392,675 |
| 190091 | 标准（5 人） | 0.60 | 2.0 | 1 | 12,550,500 |
| 190092 | 困难（10 人） | 1.45 | 4.0 | 3 | 30,330,376 |
| 190093 | 团本（25 人） | 3.60 | 7.0 | 3 | 75,302,998 |

- 血量公式：`creature_classlevelstats(level=83, class=1).basehp2(=13945) × HealthModifier × (boss_health_multiplier_scaled / 100)`。
- 档位存在 `boss_activity_config.boss_entry`；AGMP 以「难度档位」下拉框呈现，并显示当前倍率下的预估血量。
- 面板的「血量倍率」是全局旋钮，改它会让所有档位等比缩放。
- 建档 SQL：`sql/2026_09_23_activity_boss_tiers_190090_190093.sql`（部署步骤见 `sql/README.md`）。

## 2026-09 复核修复的缺陷

| 级别 | 问题 | 修复 |
|---|---|---|
| P1 | mod-ale/Eluna **没有** `GetCreatureByGUID()`，导致「从数据库恢复活跃 Boss」是死代码：Lua 重载后会把仍活着的 Boss 记录当僵尸清掉，随后 `.boss spawn` 会**再刷一个** | 改用 `GetMapById()` + `GetUnitGUID(low, entry)` + `Map:GetWorldObject()` |
| P1 | `IsManagedBossEntry`、`DEFAULT_SPAWN_POINTS`、`activeBossInfo` 在 `local` 声明之前被引用，被解析成全局 `nil`（其中 `activeBossInfo` 让热加载改名静默失效） | 文件顶部前置声明；并给全部档位 entry 注册事件 |
| P1 | `rebase`/`config reload` 以**当前上限**为基准 → 每次热加载血量再乘一次倍率（倍率 1500 时 4.4M → 66 亿，uint32 溢出），且无条件回满血 | 脱战时用 `Creature:UpdateEntry()` 按模板重算（它会清威胁表，故战斗中禁止）；战斗中改为按倍率反推、绝不叠加；只在首次生成或显式要求时回满血 |
| P1 | `Unit:SetLevel()` 只写等级字段、不重算生物属性，`bossLevel=83` 只是显示等级（属性仍来自 20 级模板） | 改用等级 83 模板 + `exp=2`，真正吃 WotLK 数值行 |
| P1 | 贡献统计进战清零、脱战丢弃 → 分段输出进不了快照与奖励 | 按 Boss guid 累积，只在击杀结算或 `.boss clear` 时释放 |
| P2 | 配置里的光环**只加不减**（从配置删掉的光环永远留在 Boss 身上） | 按 guid 记录已挂光环并做差量 `RemoveAura` |
| P2 | 覆盖了全局 `print`，之后加载的所有 Eluna 脚本都写进 `boss.log`、控制台看不到 | 改为文件级 `local print`（加载横幅仍走控制台） |
| P2 | 日志无轮转 | 5MB 轮转到 `boss.log.<时间戳>.bak` |
| P2 | 事件/贡献文本可能超列宽（严格模式下整条 INSERT 静默失败） | 按列宽做 UTF-8 安全截断 |
| P2 | 刷新点为空时 `math.random(0)` 报错 | 显式空表保护并记日志 |
| P2 | 纯信息子命令（`.boss help`、`preset list`、`difficulty list`）**没有** `[AGMP_OK]`/`[AGMP_ERROR]` 标记，严格调用方会判失败 | 这些回复的首行改走 `BossReply` |
| P3 | `bossRewardedGUIDs` 无限增长 | 死亡时清理 |

## 不启动服务器也能测

`tools/boss-lua-smoke/smoke.lua` 把 `boss.lua` 加载进桩化的 Eluna 环境（不需要 `worldserver`），断言 27 项不变量：加载流程、SQL 构造、命令标记、`.boss clear` 副作用、事件注册，以及上面两处回归（"未覆盖全局 print"、"未泄漏全局变量"）。用法见 `tools/boss-lua-smoke/README.md`。

```
lua smoke.lua /path/to/boss.lua          # 退出码 0 = 全部通过
```

## 依赖

- AzerothCore 3.3.5a + Eluna（在 AzerothCore 使用的 Eluna 分支 `mod-ale` 上验证）。
- MySQL/MariaDB，且能访问 `characters` 库。
- 脚本放在 `lua_scripts` 加载路径下。
- 脚本通过 `CharDBQuery`/`CharDBExecute` 访问 `ac_eluna` 库；库名是 `boss.lua` 顶部的 `BOSS_DB_NAME` 常量，若你的库名不同请修改。

## 安装

1. 把 `boss.lua` 放进 Eluna 脚本目录。
2. （可选）用 `sql/2026_09_23_activity_boss_tiers_190090_190093.sql` 建专用模板，然后 `.reload creature_template`。
3. 重启 `worldserver`（或 `.reload ale`）。
4. 检查服务器日志中的建表/自举输出。

## 独立运行（不接 Web）

- 加载时 Lua 自举数据库与表。
- 缺失的配置默认值由 Lua 写入。
- 运行时/事件/贡献记录只由 Lua 写。

核心功能不依赖 AGMP/Web。

## 配合 AGMP 面板

### 职责划分

- Lua 负责建表/迁移与运行时持久化。
- AGMP 只读写数据并发送 SOAP 命令（含难度档位选择、击杀/重置按钮）。
- 表缺失时 AGMP 只提示，不建表。
- 控制台/SOAP 回复带 `[AGMP_OK]` / `[AGMP_ERROR]` 标记；AGMP 把「没有标记」判为失败，避免"命令根本没到游戏"被当成成功。

### 推荐流程

1. 先让 `boss.lua` 至少加载一次（完成建表）。
2. 打开 AGMP 的 Boss 页面。
3. 在网页里改配置（刷新点、难度档位等）。
4. 保存。
5. AGMP 自动执行 `.boss config reload`。

### 关键约定

- AGMP 的 Boss 模块指向 `ac_eluna`。
- `boss_activity_config` 必须含 `spawn_points_text` 列。
- SOAP 账号需要有执行 Boss 命令的权限。

## 安全与运维

- 只给可信 GM/管理员开放这些命令。
- 大改数值前备份 `ac_eluna`。
- 脚本与 AGMP 模块版本保持同步。
- **不要**把含 `CREATE`/`ALTER` 的 SQL 导出放进「真实库 + `START TRANSACTION`/`ROLLBACK`」重放：MySQL 的 DDL 会隐式提交。请改用临时 scratch 库（见 `tools/boss-lua-smoke/README.md`）。

## 许可

MIT，见 `LICENSE`。
