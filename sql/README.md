# release/80 自定义 SQL

## 活动 Boss 脚本私有配置表（2026_09_24_activity_boss_config_ext.sql）

`boss.lua` 把原先写死在脚本里的喊话 / 战斗嘲讽 / 巡逻 / 小怪节奏 / 职业奖励 /
受管模板等配置搬进了 `ac_eluna.boss_activity_config_ext`（**不是** `boss_activity_config`：
AGMP 保存主表时用 `REPLACE INTO` 重写整行，会把它不认识的列重置为默认值）。

- 正常情况下**不需要手工执行这个文件**：`boss.lua` 每次加载都会
  `CREATE TABLE IF NOT EXISTS`（列由脚本 §3 配置区的 `BOSS_CONFIG_SCHEMA_EXT` 生成），
  首次加载还会用 `INSERT IGNORE` 写入默认值。
- 该文件用于 DBA 预建表 / 账号无建表权限时代建 / 人工复核列定义；
  已校验：其 DDL 与脚本生成的建表语句逐列一致（列名、类型、默认值、顺序）。
- 加配置项的正确做法：改 `boss.lua` §3 的描述表（并同步本文件与面板 `config/boss.php`），不要只手改数据库。
- AGMP 面板的「扩展配置」Tab 可以直接编辑这张表（二级 Tab 按分组归集），
  写入用 `INSERT ... ON DUPLICATE KEY UPDATE`（只改提交的列，不会像主表那样被 `REPLACE INTO` 重置）。
- 查看当前生效值：`.boss config show` / `.boss config show <分组>`
  （分组：identity basic ally yells taunts ai phase patrol minion skill respawn
  spawnpoints helper reward class tier）。

## 活动 Boss 难度档位（2026_09_23_activity_boss_tiers_190090_190093.sql）

新建 4 个**活动 Boss 专用模板**，供 AGMP 面板「Boss 活动管理 → 难度档位」切换。
取代原先复用死亡矿井 Boss「绿皮队长」(entry 647) 的做法——647 自带 `AIName=SmartAI`
与 2 条 `smart_scripts`，会和 Eluna 脚本形成双 AI，面板的技能预设管不到它们。

| entry | 档位 | HealthModifier | DamageModifier | rank | 实际血量（× 面板倍率） |
|---|---|---|---|---|---|
| 190090 | 入门 | 0.21 | 1.0 | 1 | 4,392,675（倍率 1500，与旧档同级） |
| 190091 | 标准 | 0.60 | 2.0 | 1 | 12,550,500 |
| 190092 | 困难 | 1.45 | 4.0 | 3 | 30,330,376 |
| 190093 | 团本 | 3.60 | 7.0 | 3 | 75,302,998 |

- 模板统一：等级 83 / `exp=2` / `AIName=''` / 无 `smart_scripts` / `lootid=0`（奖励由脚本发放）/ `CreatureImmunitiesId=-229`（Boss 级控制免疫）。
- 血量公式：`creature_classlevelstats(83, class=1).basehp2(=13945) × HealthModifier × (boss_health_multiplier_scaled/100)`。
- **面板的「血量倍率」是全局旋钮**：改它会让 4 个档位等比缩放。线上当前倍率 = 1500。
- 想改某一档的强度：`UPDATE creature_template SET HealthModifier=... , DamageModifier=... WHERE entry=19009x;` 然后 `.reload creature_template`。
  参考量级：真实 WotLK 团本 Boss 的 HealthModifier 165–1250、DamageModifier 35–139。

### 部署步骤（新环境）

1. 导入本 SQL：
   ```powershell
   & "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 43306 -u root -p `
       --default-character-set=utf8mb4 acore_world80 < .\2026_09_23_activity_boss_tiers_190090_190093.sql
   ```
   （SQL 末尾会把 `ac_eluna.boss_activity_config.boss_entry` 设为 190090；重复执行是幂等的。）
2. 让核心重新读取模板（游戏内 GM 或 AGMP 面板控制台通道）：
   ```
   .reload creature_template
   ```
3. 让 Eluna 重新加载脚本（本次 `boss.lua` 有改动）：
   ```
   .reload ale
   ```
   然后 `.boss config reload` 让脚本按新 entry 重新注册事件与技能池。
4. 切换档位：AGMP →「Boss 活动管理」→ 难度档位下拉框 → 保存
   （面板写入 `boss_entry` 后会自动执行 `.boss config reload`）。
   注意：**已在场的 Boss 会继续用旧模板**，重生或手动 `.boss clear` + `.boss spawn` 后生效。

### 常用 GM 命令（`boss.lua`）

| 命令 | 作用 |
|---|---|
| `.boss` / `.boss spawn` | 在配置刷新点生成 Boss |
| `.boss kill` | 击杀当前活跃 Boss（走正常死亡 + 奖励流程） |
| `.boss clear` | 直接移除活跃 Boss、不发奖励、复位运行时记录（面板「重置」按钮） |
| `.boss rebase` | 按模板重算基准血量再套用倍率（**需脱战**，战斗中会拒绝） |
| `.boss config reload` | 从 `ac_eluna` 热加载配置（面板保存后自动调用） |
| `.boss config show [分组]` | 查看当前生效的配置项（不带分组则列出 16 个分组） |
| `.boss preset list` / `.boss preset <key>` | 查看 / 切换技能池预设 |
| `.boss difficulty list` / `.boss difficulty <key>` | 查看 / 切换技能节奏档位 |
| `.boss help` | 帮助 |
