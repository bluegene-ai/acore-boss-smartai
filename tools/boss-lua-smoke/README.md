# boss.lua 离线冒烟测试

`smoke.lua` 用桩函数替换 Eluna/核心 API，把 `release/80/lua_scripts/boss.lua` 加载进一个独立的 Lua 环境里跑一遍，不需要启动 worldserver。

> 多区部署请用 `tools/deploy-realm.ps1` 安装到各区（自动改写 §2 的本区库名常量 + 备份 + 语法检查），
> 它改写的就是本测试断言的那两行常量。

## 为什么需要

`boss.lua` 有 4000+ 行，纯语法检查（`luac -p`）发现不了下面这类**运行时**缺陷：

- 名字在 `local` 声明之前被引用 → 被解析成全局变量 → 运行时是 `nil`（历史上的 `IsManagedBossEntry`、`DEFAULT_SPAWN_POINTS`、`activeBossInfo` 就是这种）；
- 调用了引擎里不存在的 API（例如 `GetCreatureByGUID`，mod-ale 从来没有这个函数）；
- `.boss` 子命令的返回没有 `[AGMP_OK]`/`[AGMP_ERROR]` 标记 → AGMP 面板的严格标记校验会误判成功/失败；
- 覆盖全局 `print`（会连带影响之后加载的所有 Eluna 脚本）。

启动一次 worldserver 校验要几分钟，且需要干净的库；这个脚本秒级返回。

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
| 配置 | 分组齐全（16 组）且项数之和等于描述表总数；喊话/嘲讽/AI 节奏/阶段阈值/巡逻/小怪/援军/职业/受管模板**确实取自数据库**（桩数据用与默认值不同的值）；数据库快照缺列会直接判失败（描述表改动后测试不会静默失效） |
| 命令 | `help` / `config reload` / `config show [分组]` / `preset list` / `preset <key>` / `difficulty <key>` / `rebase` / `kill` / `clear` / `spawn` / 未知子命令 的标记与语义 |
| 放行 | 非 boss 命令返回 `true`、不产生 boss 回复（不拦截其他 GM 指令） |
| 副作用 | `.boss clear` 写 `command_clear` 事件并把 runtime 复位为 `idle` |
| 事件 | `PLAYER_EVENT_ON_HEAL(42/65)` 与受管 entry（含 ext 表额外指定的档位 entry）的 6 个 creature 事件全部注册 |
| 多区绑定 | 把 §2 的 key（`BOSS_RUNTIME_KEY` / `BOSS_CONFIG_KEY`）改写后重新加载：事件写入必须带新的 key、启动日志必须报出新 key、runtime 语句必须用新 key，共用库名不变，老库自动补 `state_key` 列与索引；任何一处写死的 `'current'` 都会失败 |

## 配置一致性（重构时用的一次性工具，不在本目录）

判断「配置落库重构」是否改变行为，用的是 `tmp` 里的一次性脚本：

1. `snapshot.lua <boss.lua> <out.txt> [nodb|live] [row.txt]`：用桩环境加载脚本，捕获
   - `bootstrap.*` 引导写入语句（列名/顺序/取值/转义）
   - `after-preset.*` 执行 `.boss preset ember_storm` 后的回写（= 从数据库解析出来的运行期配置）
2. 对重构前 / 后的 boss.lua 各跑一次再 diff：主表 35 列必须逐字段一致。
3. 把 `--dump-sql` 导出的语句替换库名后在 **scratch 库**（`CREATE DATABASE boss_verify`）里跑两遍，
   验证真实的 MySQL 8.0 语法与 `ON DUPLICATE KEY UPDATE` 路径，最后 `DROP DATABASE`。

## ⚠ 安全警告（2026-09-23 真实事故）

**不要把 `--dump-sql` 导出的 SQL 丢进「真实库 + `START TRANSACTION` / `ROLLBACK`」里校验。**

导出文件里含 `CREATE DATABASE` / `CREATE TABLE` 这类 DDL，而 MySQL 的 **DDL 会隐式提交**，
事务被提前结束，后面的 `REPLACE INTO` / `INSERT` 就真的落库了。当时这次误操作覆盖了线上
`ac_eluna.boss_activity_config` 的 `spawn_points_text`（14 个刷新点被替换成 1 个）、
`skill_preset`、`gold_min/max_copper`、`reward_mounts_text`、`ally_health_multiplier_scaled`，
并写入 5 条假事件；已用 `incident-2026_09_23_restore_live_config.sql` 逐列复原。

正确做法（二选一）：

1. 只用导出文件做**人工复核**（默认已过滤 DDL，只剩 INSERT/REPLACE/UPDATE/DELETE）；
2. 需要真跑语法校验时，建一个 **scratch 库**（`CREATE DATABASE boss_verify` + `CREATE TABLE ... LIKE`），
   把导出 SQL 里的 `ac_eluna` 替换成 `boss_verify` 再执行，最后 `DROP DATABASE boss_verify`。

## 说明

- 两张配置表的 SELECT 都返回一份**按列名给出**的快照：`boss_activity_config`（Boss 身份/属性/奖励）
  与 `boss_activity_config_ext`（喊话/嘲讽/节奏/巡逻/小怪/职业/受管模板）。
  ext 快照故意用与文件内默认值不同的值，用来断言「运行时确实以数据库为准」；
  快照缺少描述表里的任何一列都会直接判失败，所以描述表加了列而快照没跟上不会静默通过。
- runtime / events / contributors 的 SELECT 返回「无行」，走内存默认分支。
- 桩环境里没有 `GetCreatureByGUID`：一旦脚本再引用它，会立刻以运行期错误暴露出来。
- 本脚本不写任何文件（会刻意避开 `lua_scripts/lua_logs/`），也不连数据库。
