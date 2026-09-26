# boss.lua 离线冒烟测试

`smoke.lua` 用桩函数替换 Eluna/核心 API，把 `release/80/lua_scripts/boss.lua` 加载进一个独立的 Lua 环境里跑一遍，不需要启动 worldserver。

> 多区部署请用 `tools/deploy-realm.ps1` 安装到各区（改写 §2 的 `BOSS_DB_NAME` / `BOSS_RUNTIME_KEY` / `BOSS_CONFIG_KEY` + 备份 + 语法检查），
> 它改写的就是本测试断言的那几行常量。

## 为什么需要

`boss.lua` 有 4000+ 行，纯语法检查（`luac -p`）发现不了下面这类**运行时**缺陷：

- 名字在 `local` 声明之前被引用 → 被解析成全局变量 → 运行时是 `nil`；
- 调用了引擎里不存在的 API（例如 `GetCreatureByGUID`，mod-ale 从来没有这个函数）；
- `.boss` 子命令的返回没有 `[AGMP_OK]`/`[AGMP_ERROR]` 标记 → AGMP 面板的严格标记校验会误判成功/失败；
- 覆盖全局 `print`（会连带影响之后加载的所有 Eluna 脚本）。

启动一次 worldserver 校验要几分钟且需要干净的库；这个脚本秒级返回。

引擎使用的 Lua 版本是 **5.2**（`mod-ale/CMakeLists.txt`: `LUA_VERSION "lua52"`），请用同版本解释器运行以保证语义一致。

## 用法

```powershell
# 建议在一个没有 lua_scripts 子目录的工作目录下运行：
#   这样脚本打不开日志文件，所有输出都回到 stdout
cd <acore-boss-smartai>\tools\boss-lua-smoke
& <lua.exe> smoke.lua "D:/AzerothCore/release/<realm>/lua_scripts/boss.lua"
# 退出码：0 = 全部通过，1 = 有断言失败，2 = 加载/运行期错误
```

`lua.exe` 取任意 Lua 5.1/5.2 解释器（本仓库用 Lua 5.2.4 验证）。

## 覆盖范围

| 断言组 | 内容 |
|---|---|
| 加载 | `EnsureBossSchema` / `LoadBossConfigFromDB` / `LoadBossRuntimeFromDB` / 事件注册全流程无运行期错误 |
| 回归 | 全局 `print` 未被覆盖；`RegisterBossEventsFor*`、`activeBossInfo`、`IsManagedBossEntry` 不泄漏为全局 |
| SQL | 主表与扩展表（`boss_activity_config_ext`）的引导写入；扩展表建表语句与写入列一致；配置表不再用 `REPLACE INTO`；启动时写入 runtime 引导行 |
| 配置 | 分组齐全（24 组，含 6 个奖池）且项数之和等于描述表总数；喊话/嘲讽/AI 节奏/阶段阈值/巡逻/小怪/援军/职业/受管模板/技能池随机/**6 个独立奖池**/定时启停**确实取自数据库**（桩数据用与默认值不同的值）；数据库快照缺列会直接判失败 |
| 命令 | `help` / `config reload` / `config show [分组]` / `preset list` / `preset <key>` / `preset random on\|off` / `preset pool <key,key>\|all` / `difficulty <key>` / `rebase` / `kill` / `clear` / `schedule` / `spawn` / `spawn force` / 未知子命令 的标记与语义 |
| 技能池随机 | 两个配置列（`skill_preset_random_enabled` / `skill_preset_pool_text`）进建表与引导写入；开启后连续 20 次生成**每次都落在池内**且会出现不同预设；关闭后固定用 GM 指定的那套；`preset random off` / `preset pool` 写回扩展表且 `.boss config show` 立即反映；`preset pool <非法 key>` 返回 `AGMP_ERROR` |
| 定时启停 | 三个配置列（`activity_schedule_enabled` / `_windows` / `_clear_on_close`）进建表、引导写入与 runtime 写入；用**可控时钟**（改写 `GetGameTime`）驱动每秒 tick：星期掩码不匹配不生成、进入时段补生成 + `schedule_open`、同一段内不重复生成（30 秒重试）、离开时段写 `schedule_close`、时段外 `.boss spawn` 被拒而 `spawn force` 放行 |
| 6 个独立奖池（配置） | 36 个奖池列（6 池 × 开关/概率/人数模式/人数/职业过滤/奖品）进建表与引导写入；模拟老库缺列时自动 `ALTER` 补列；旧奖励模型的 13 列必须被 `DROP COLUMN` 且主表建表语句里不再出现；`reward` 组只剩选人字段而 `class_reward_items_text` 保留；`.boss config show reward_pool_N` 显示的是数据库值 |
| 6 个独立奖池（实发） | 桩环境里放**假 Boss + 假玩家（战士/法师）**，临时改写 `env.type` 让 `IsUnitValid` 认账，驱动「受伤事件累贡献 → 死亡结算」整条 `OnBossDied`：池 1（全员）把职业专属物品发给对应职业、池 3（指定 2 人）只发给战士、关闭的池 4/5 一件不发、池 6 独立生效；`containers.reward_pools_mask` 位图逐位核对（战士=池1+3+6、法师=池1+2），并断言跨职业/不可用物品一次都没发出去 |
| 放行 | 非 boss 命令返回 `true`、不产生 boss 回复（不拦截其他 GM 指令） |
| 副作用 | `.boss clear` 写 `command_clear` 事件并把 runtime 复位为 `idle` |
| 事件 | `PLAYER_EVENT_ON_HEAL(42/65)` 与受管 entry（含 ext 表额外指定的档位 entry）的 6 个 creature 事件全部注册 |
| 多区绑定 | 把 §2 的 key（`BOSS_RUNTIME_KEY` / `BOSS_CONFIG_KEY`）改写后重新加载：事件写入必须带新的 key、启动日志必须报出新 key、runtime 语句必须用新 key，共用库名不变，老库自动补 `state_key` 列与索引；任何一处写死的 `'current'` 都会失败 |

## 配置一致性（重构时用的一次性工具，不在本目录）

判断配置落库重构是否改变行为用的是 `tmp` 里的一次性脚本：`snapshot.lua <boss.lua> <out.txt> [nodb|live] [row.txt]`
捕获 `bootstrap.*` 引导写入语句与 `after-preset.*` 回写，重构前后各跑一次再 diff（主表 35 列必须逐字段一致）。

## ⚠ 安全警告：DDL 导出不要放进事务里重放

**不要把 `--dump-sql` 导出的 SQL 丢进「真实库 + `START TRANSACTION` / `ROLLBACK`」里校验。**

导出文件含 `CREATE DATABASE` / `CREATE TABLE` 这类 DDL，而 MySQL 的 **DDL 会隐式提交**，事务被提前结束，
后面的 `REPLACE INTO` / `INSERT` 就真的落库了（一次误操作覆盖过线上 `ac_eluna.boss_activity_config` 的配置列）。

正确做法（二选一）：

1. 只用导出文件做**人工复核**（默认已过滤 DDL，只剩 INSERT/REPLACE/UPDATE/DELETE）；
2. 需要真跑语法校验时，建一个 **scratch 库**（`CREATE DATABASE boss_verify` + `CREATE TABLE ... LIKE`），
   把导出 SQL 里的 `ac_eluna` 替换成 `boss_verify` 再执行，最后 `DROP DATABASE boss_verify`。

## 说明

- 两张配置表的 SELECT 都返回一份**按列名给出**的快照：`boss_activity_config`（Boss 身份/属性/选人权重）
  与 `boss_activity_config_ext`（喊话/嘲讽/节奏/巡逻/小怪/职业/受管模板/技能池随机/**6 个奖池**/定时启停）。
  ext 快照故意用与文件内默认值不同的值，用来断言「运行时确实以数据库为准」；
  快照缺少描述表里的任何一列都会直接判失败。
- 奖池实发那一段会临时改动 ext 快照里的 6 个奖池与职业映射（再 `.boss config reload`），段末恢复桩函数；
  假对象是用「表 + 改写 `type()`」冒充 userdata 的，`AddItem` 的记录就是断言用的"玩家背包"。
- runtime / events / contributors 的 SELECT 返回「无行」，走内存默认分支。
- 桩环境里没有 `GetCreatureByGUID`：一旦脚本再引用它，会立刻以运行期错误暴露出来。
- 本脚本不写任何文件（会刻意避开 `lua_scripts/lua_logs/`），也不连数据库。
