# boss.lua 离线冒烟测试

`smoke.lua` 用桩函数替换 Eluna/核心 API，把 `release/80/lua_scripts/boss.lua` 加载进一个独立的 Lua 环境里跑一遍，不需要启动 worldserver。

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
cd E:\Server\tools\boss-lua-smoke
& <lua.exe> smoke.lua "E:/Server/release/80/lua_scripts/boss.lua"
# 退出码：0 = 全部通过，1 = 有断言失败，2 = 加载/运行期错误
```

`lua.exe` 可以取 `E:\Server\.tmp-luacheck\lua.exe`（Lua 5.2.4），或任何 Lua 5.1/5.2 解释器。

## 覆盖范围

| 断言组 | 内容 |
|---|---|
| 加载 | `EnsureBossSchema` / `LoadBossConfigFromDB` / `LoadBossRuntimeFromDB` / 事件注册全流程无运行期错误 |
| 回归 | 全局 `print` 未被覆盖；`RegisterBossEventsFor*`、`activeBossInfo`、`IsManagedBossEntry` 不泄漏为全局 |
| SQL | 配置引导写入（`INSERT IGNORE`）含新模板 entry 与 `spawn_points_text`；启动时写入 runtime 引导行 |
| 命令 | `help` / `config reload` / `preset list` / `preset <key>` / `difficulty <key>` / `rebase` / `kill` / `clear` / `spawn` / 未知子命令 的标记与语义 |
| 放行 | 非 boss 命令返回 `true`、不产生 boss 回复（不拦截其他 GM 指令） |
| 副作用 | `.boss clear` 写 `command_clear` 事件并把 runtime 复位为 `idle` |
| 事件 | `PLAYER_EVENT_ON_HEAL(42/65)` 与 4 个档位 entry 的 6 个 creature 事件全部注册 |

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

- 桩函数返回「无行」的 `CharDBQuery`，所以运行时会走**内存默认配置**分支；`boss_activity_config` 的 SELECT 则返回一份线上真实配置快照（`boss_entry=190090`、倍率 1500 等），用于校验配置解析与 SQL 构造。
- 桩环境里没有 `GetCreatureByGUID`：一旦脚本再引用它，会立刻以运行期错误暴露出来。
- 本脚本不写任何文件（会刻意避开 `lua_scripts/lua_logs/`），也不连数据库。
