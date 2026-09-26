# spell-check — Eluna 法术 ID 校验工具

审计一个 Eluna 脚本里用到的所有法术 ID：到客户端 `Spell.dbc` 校验存在性（离线、不需要数据库），
可选地反查 world 库看哪些 `creature_template` 使用了该法术。

本工具**只读**：不修改被审计的脚本，不写数据库。

## 依赖

| 依赖 | 路径 | 是否必需 |
|---|---|---|
| Lua 解释器 | `C:\pureland\build\modules\mod-ale\src\lualib\lua\Release\lua52_interpreter.exe`（Lua 5.2.4） | 必需 |
| 客户端 DBC | `C:\pureland\data\dbc\Spell.dbc`（48,956,359 字节） | 必需 |
| `worldserver.conf` | `C:\pureland\Release\configs\worldserver.conf`（读 `WorldDatabaseInfo` 取连接串） | 仅 `-db` |
| mysql 客户端 | `C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe` | 仅 `-db` |

Lua 5.2 没有 `string.unpack`，工具用 `string.byte` 手工拼小端 uint32。
`-db` 反查通过 `io.popen` + `cmd /c` 调用 mysql；密码只经 `MYSQL_PWD` 环境变量传递，
不进命令行、不进报告（报告里回显的 SQL 也不含密码）。

## 用法

```
lua52_interpreter.exe spell-check.lua [选项] [脚本路径]
```

| 参数 | 说明 |
|---|---|
| `脚本路径` | 要审计的 Lua 脚本。默认 `C:\pureland\Release\lua_scripts\acore-boss-smartai\boss.lua` |
| `-db` | 额外做数据库反查：`creature_template_spell JOIN creature_template`，以及 `spell_script_names` |
| `-v` | 打印每一条提取到的原始条目（含文件行号） |
| `-dbc <路径>` | 换一个 Spell.dbc |
| `-h` | 帮助 |

示例（在工具所在目录执行）：

```powershell
# 纯离线存在性校验
& "C:\pureland\build\modules\mod-ale\src\lualib\lua\Release\lua52_interpreter.exe" `
  spell-check.lua "C:\pureland\Release\lua_scripts\acore-boss-smartai\boss.lua"

# 追加数据库反查
& "...\lua52_interpreter.exe" spell-check.lua -db "C:\...\boss.lua"
```

### 退出码

| 码 | 含义 |
|---|---|
| `0` | 所有提取到的法术 ID 都能在 DBC 里找到 |
| `1` | 至少一个法术 ID 在 DBC 里不存在（**硬错误**） |
| `2` | 工具自身错误：脚本读不到、DBC 魔数不是 WDBC、DBC 头与实际大小不符、表头找不到等 |

## 从脚本里提取法术 ID 的方式

**没有**用 `loadfile` 执行被审计脚本（那需要造一个能满足脚本全部 Eluna API 的环境，
且会真的跑起来产生副作用）。实际做法是「括号配平定位表区间 + 语法模式精确匹配」：

1. 逐字符扫描，跳过字符串与注释（`--` 行注释、`--[[ ]]` 块注释、单双引号字符串含转义），
   对 `{`/`}` 做配平，定位 `local SKILL_PRESET_LIBRARY = { ... }` 与
   `local INTERRUPT_SPELL_LIBRARY = { ... }` 的完整字节区间。
2. 在 `SKILL_PRESET_LIBRARY` 区间内枚举**顶层** `key = { ... }`（当前 10 个预设，数量不写死）；
   每个预设块内再定位 `skillPools` / `comboChains` / `openingSkills` 三个子表。
3. 分类提取：
   - `skillPools[N]`：区间内每条 `spellId = <数字>`，并向后取同一花括号内最近的 `name = "<x>"`
   - `openingSkills`：同上
   - `comboChains`：每条连招的 `skills = { {id, "target"}, ... }` 里的第一个元素
   - `INTERRUPT_SPELL_LIBRARY`：`spellId = <数字>`（该表实际字段名就是 `spellId`，不是 `id`；
     工具仍保留了 `id` 字段的兜底分支）
   - `BOSS_CONFIG.phase2SpellId` / `phase3SpellId`：配置表里的两个字面量
4. 每个条目都记录精确行号与调用点标签（`预设.子表[池号]` 或 `预设.comboChains["连招名"]`）。

每个 ID 的调用点按 `ID|调用点` 去重，因此 go 不会重复计数。

**误报/漏报风险（明确说明）：**

- 匹配的是**语法形态**而不是求值结果。若脚本改成 `spellId = SPELL_X`（变量/表达式）、
  `[1] = 64213` 这种位置式写法、或把法术表放到别的表名/variable 里，工具**会漏**。
- 反过来，若脚本里有别的数组也写成 `{<数字>, "..."}` 且正好落在连招块内，理论上可能**误报**；
  当前 boss.lua 的连招块内只有 skills 一个数字表，实测 54 条与人工计数一致。
- `name = "<x>"` 的关联范围是「同一条目到下一个 `spellId` 之前」，而不是严格的花括号配平；
  正常情况下每条目自成一个 `{...}`，实测无误。
- 报告头部的条目分布计数（skillPools/openingSkills/comboChains/INTERRUPT）可用于快速核对提取完整性。

## Spell.dbc 解析口径（与面板 `GameNameResolver.php` 对齐）

- WDBC 头 20 字节：`magic(4) + recordCount(u32) + fieldCount(u32) + recordSize(u32) + stringBlockSize(u32)`，
  之后是 `recordCount × recordSize` 字节记录区，再之后是字符串块。
- **ID = 字段 0，名称字段 = 136，语种掩码字段 = 152**（与 `DBC_SPECS['spell']` 一致）。
  名称字段的值是字符串块内的字节偏移（0-based，`offset <= 0` 视为空）。
- 语种槽位按 `GameNameResolver::DBC_LOCALE_ORDER` 的 16 槽顺序
  `enUS, koKR, frFR, deDE, enCN, zhCN, enTW, zhTW, esES, esMX, ruRU, ptPT, ptBR, itIT, Unk, Unk2`。
  掩码只能当候选集合，必须抽样验证（工具复刻了 `dbcLocaleOffset` 的
  「期望语种 → 同语系 → 掩码置位槽 → 全槽位抽样」策略，抽样阈值同样是「抽样里 ≥50% 记录有非空字符串」）。
- 头里推算的大小会与实际文件大小比对，不一致直接按退出码 2 报错（不猜测截断/多余字节）。

## 判定口径

| 结论 | 判定 |
|---|---|
| **硬错误** | DBC 里找不到该 ID → 退出码 1。`spell_dbc`（world 库里的覆盖表，本站仅 4493 行）**不作为**存在性依据 |
| 名称差异 | `boss.lua` 的 `name` 与 DBC 名称字符串不相等。因为本站 DBC 只在槽位 4(enCN) 有字符串（实际是简体中文），中文名可以直接和 DBC 名称比对；工具只标「不同」，不自动判错 |
| 无 creature 使用 | `creature_template_spell` 里没有该 Spell。**不是错误**，但说明它不是本服任何生物技能表的成员（WotLK 团本 Boss 技能多为硬编码脚本，本来就不在这张表里） |
| 有 spell_script_names | 该法术挂了核心脚本，行为依赖特定机制，改动前需额外注意 |

## 已知局限

- **只能校验存在性与名称**，不能校验法术效果、目标类型、冷却、是否可被 Boss 正确施放。
- DBC 只有名称，没有图标/描述/效果信息；要判断「这个 ID 是不是某个 Boss 的招牌技能」需要人工核对。
- `-db` 依赖 mysql 客户端与 `worldserver.conf`；这两者缺失时会打警告并跳过反查，**退出码不受影响**。
- `creature_template_spell` 的列名是 `CreatureID`（`spell` 列名是 `Spell`）。注意 MySQL 在 Linux 上
  列名大小写不敏感，但在 Windows 上敏感——写错大小写会静默返回空结果。
- 报告里的中文列宽按字节数补齐，终端下对齐会因东亚宽字符而略有偏差（不影响内容）。
- 49MB 文件是整体读入的（实测峰值约 100MB，解析耗时约 0.3s），没有做流式分块；
  在内存受限环境（<200MB 可用）下才需要改成流式。

## 实测

```
$ lua52_interpreter.exe spell-check.lua
  recordCount=49839  fieldCount=234  recordSize=936  stringBlockSize=2307035
  头推算大小 = 20 + 49839*936 + 2307035 = 48956359  -> 与实际文件大小一致
  解析 ID 数=49839（含重复 ID 行 0）; 名称字段=140=enCN槽位(slot 4); 抽样语种掩码=0xFF01FE
  解析出预设 : 6 个; 提取条目 153 条; 去重后法术 ID 37 个
DBC 解析耗时: 0.30s
-> 退出码 0
```
