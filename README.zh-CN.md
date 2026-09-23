# Acore Boss SmartAI Lua（中文说明）

AzerothCore 3.3.5a 的 Eluna 活动 Boss 脚本：带运行时持久化、配置热加载、事件追踪与贡献快照。

## 功能

- 智能战斗 AI、多套技能池预设与技能节奏档位。
- **可切换的强度档位**，由专用 `creature_template` 承载（见下）。
- **配置全部落库**：脚本里只保留默认值，运行期以 `ac_eluna` 为准（见下「配置在哪里改」）。
- 运行时数据落在 `ac_eluna`：`boss_activity_runtime`、`boss_activity_config`、
  `boss_activity_config_ext`、`boss_activity_events`、`boss_activity_contributors`。
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
| `.boss config show [分组]` | 查看当前生效的配置项（不带分组则列出 16 个分组） |
| `.boss preset list` / `.boss preset <key>` | 查看 / 切换技能池预设 |
| `.boss difficulty list` / `.boss difficulty <key>` | 查看 / 切换技能节奏档位 |
| `.boss help` | 帮助 |

## 配置在哪里改

`boss.lua` 只在文件顶部 §3「配置区」保留**出厂默认值**；数据库里已有该行时，
默认值不生效（引导写入用 `INSERT IGNORE`）。改配置按优先级：

1. **AGMP 面板** —— 「基础配置」Tab 改主表 `boss_activity_config` 的列（Boss 身份/属性/刷新点/技能池/奖励）；
   「扩展配置」Tab 改 `boss_activity_config_ext`（喊话/嘲讽/AI 节奏/阶段阈值/巡逻/小怪/援军/职业/受管模板，
   内部再按二级 Tab 分组）。
2. **直接改数据库** —— `boss_activity_config`（面板共享列）与 `boss_activity_config_ext`（脚本私有列）都可以。
3. 改脚本 §3 的默认值 —— 只影响「数据库里还没有这一行」的全新部署。

改完执行 `.boss config reload`（面板保存会自动执行），或重启 worldserver。

### 两张配置表的分工

| 表 | 内容 | 谁写 |
|---|---|---|
| `boss_activity_config` | Boss 身份、等级/体型/血量倍率、光环、友方援军、刷新点、技能池、奖励 | AGMP 面板（`REPLACE INTO` 整行重写）+ Lua |
| `boss_activity_config_ext` | 喊话、战斗嘲讽（12 组文本）、AI 节奏、战斗阶段阈值、巡逻、小怪 AI、援军模板、职业类型与职业奖励池、受管模板 | Lua 建表/引导 + AGMP 面板（`INSERT ... ON DUPLICATE KEY UPDATE` 只改提交的列） |

为什么拆两张表：AGMP 保存主表时用 `REPLACE INTO` 重写整行，凡不在它列清单里的列
都会被重置为建表默认值，脚本私有配置放主表会被面板保存清掉，所以单独一张表；
面板对 ext 表只做 upsert，因此脚本后续新增的列不会被面板保存重置。

### 加一个配置项

1. 在 §3 配置区加默认值（或复用已有字段）；
2. 在 `BOSS_CONFIG_SCHEMA_MAIN`（面板共享列，需同时改 AGMP 与建表语句）或
   `BOSS_CONFIG_SCHEMA_EXT`（脚本私有列）里加一行：`group / column / kind / target / key`，ext 列还要给 `ddl`；
3. ext 表的建表语句、读、写、`.boss config show` 展示都会自动跟着变；如果要能在面板里编辑，
   再到 AGMP 的 `config/boss.php` 补 `ext_fields`（列名/类型/边界）+ 中英文语言的字段名，
   `php tools/verify_boss_ext_page.php` 会逐列比对脚本与面板是否一致。

配置项的取值类型（`kind`）：`int` / `bool` / `scaled`（小数 ×100 存 INT）/ `text` /
`text_keep` / `intlist` / `lines` / `keyedlines` / `keyedword` / `keyedintlist` / `spawnpoints`。

### 仍然写在脚本里的东西（不是配置项）

- 技能池预设 / 强度档位系数 / 打断法术池（§5 内容库）：属于「技能内容」，改动等于改战斗设计，随版本发布；
  可调的部分（选哪套预设、哪个档位）已经落库。
- 显示用文本（职业中文名等）、小怪召唤的散布半径、技能条件里的个别常量：属于逻辑常量，不是调参项。

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

`tools/boss-lua-smoke/smoke.lua` 把 `boss.lua` 加载进桩化的 Eluna 环境（不需要 `worldserver`），断言 63 项不变量：加载流程、两张配置表的 SQL 构造、扩展表建表/写入列一致性、命令标记、`.boss config show` 输出、「数据库值确实覆盖脚本默认值」、`.boss clear` 副作用、事件注册，以及上面两处回归（"未覆盖全局 print"、"未泄漏全局变量"）。用法见 `tools/boss-lua-smoke/README.md`。

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
- 面板对两张表用的写法不同：`boss_activity_config` 用 `REPLACE INTO` 整行重写（列清单写死在
  `BossRepository`），`boss_activity_config_ext` 用 `INSERT ... ON DUPLICATE KEY UPDATE` 只改提交的列。
  因此：给主表加列必须同步改面板，否则会被面板保存重置；给 ext 表加列则不会被面板影响。
- `boss_activity_config` 必须含 `spawn_points_text` 列。
- SOAP 账号需要有执行 Boss 命令的权限。
- 面板「扩展配置」Tab 的字段与脚本描述表由 `php tools/verify_boss_ext_page.php` 逐列比对（含中英文文案）。

## 安全与运维

- 只给可信 GM/管理员开放这些命令。
- 大改数值前备份 `ac_eluna`。
- 脚本与 AGMP 模块版本保持同步。
- **不要**把含 `CREATE`/`ALTER` 的 SQL 导出放进「真实库 + `START TRANSACTION`/`ROLLBACK`」重放：MySQL 的 DDL 会隐式提交。请改用临时 scratch 库（见 `tools/boss-lua-smoke/README.md`）。

## 许可

MIT，见 `LICENSE`。
