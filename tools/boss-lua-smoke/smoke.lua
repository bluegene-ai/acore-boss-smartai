-- ============================================================================
--  boss.lua 离线冒烟测试（不需要启动 worldserver）
--  ---------------------------------------------------------------------------
--  为什么需要它：boss.lua 只靠语法检查发现不了「前向引用被当成全局变量(nil)」
--  这类运行时缺陷；而启动 worldserver 校验一次要几分钟。本脚本用桩函数替换
--  Eluna/核心 API，再用自定义 _ENV 加载 boss.lua，捕获 RegisterPlayerEvent /
--  RegisterCreatureEvent 的回调，逐条驱动 .boss 命令并断言返回标记。
--
--  用法（在任意目录，建议在无 lua_scripts 子目录的工作目录下运行，
--  这样脚本打不开日志文件、所有输出都回到 stdout）：
--      lua.exe smoke.lua "D:\AzerothCore\release\<realm>\lua_scripts\boss.lua"
--
--  覆盖：配置加载(SQL 构造/两张配置表)、扩展表建表与写入列一致、
--        「数据库值覆盖脚本默认值」、运行时持久化、
--        help/config/config show/preset/difficulty/rebase/kill/clear/spawn/未知子命令、
--        非 boss 命令放行，以及「全局 print 未被覆盖」「不再泄漏全局函数」两项回归断言。
-- ============================================================================

local bossPath = arg and arg[1] or "lua_scripts/boss.lua"

-- ---------------------------------------------------------------- 记录与断言
local recorded = { sql = {}, events = {}, replies = {}, failures = {}, alters = {} }
local function fail(msg)
    table.insert(recorded.failures, msg)
    io.write("  [FAIL] " .. msg .. "\n")
end
local function ok(msg)
    io.write("  [ ok ] " .. msg .. "\n")
end
local function assertTrue(cond, msg)
    if cond then ok(msg) else fail(msg) end
end

-- ---------------------------------------------------------------- 核心桩函数
local originalPrint = print
local engineCallbacks = { creature = {}, player = {} }

local function mockQuery(values)
    return {
        GetUInt32 = function(_, i) return values[i + 1] end,
        GetInt32 = function(_, i) return values[i + 1] end,
        GetFloat = function(_, i) return values[i + 1] end,
        GetString = function(_, i) return tostring(values[i + 1] or "") end,
    }
end

-- 数据库快照（按列名给出，不依赖描述表顺序）：
--   main = ac_eluna.boss_activity_config（与 AGMP 面板共享）
--   ext  = ac_eluna.boss_activity_config_ext（脚本私有配置）
-- ext 故意用与文件内默认值不同的值：用来断言「运行时确实以数据库为准」。
local CONFIG_VALUES = {
    boss_entry = 190090, boss_name = "送财童子", boss_level = 83,
    boss_scale_scaled = 999, boss_health_multiplier_scaled = 150000, boss_auras_text = "467",
    ally_level = 50, ally_health_multiplier_scaled = 999, respawn_time_minutes = 10,
    minion_count_min = 1, minion_count_max = 2,
    skill_preset = "spellbreak_bulwark", skill_difficulty = "hard",
    guaranteed_reward_enabled = 1, guaranteed_reward_notify = 1, max_random_reward_players = 3,
    class_reward_chance = 60, formula_reward_chance = 10, mount_reward_chance = 15,
    random_reward_mode = "weighted", participation_range = 80,
    damage_weight = 100, healing_weight = 80, threat_weight = 35, presence_weight = 10, kill_weight = 3,
    guaranteed_item_id = 40753, guaranteed_item_count = 2, gold_min_copper = 30000, gold_max_copper = 50000,
    reward_items_text = "38082,41600,51809,34067", reward_formulas_text = "45059,44491",
    reward_mounts_text = "32768,30480",
    spawn_points_text = "571,4353.573,-4411.8877,151.3909",
}

local EXT_VALUES = {
    boss_spawn_yell = "DB喊话-{BOSS_NAME}", boss_enter_combat_yell = "DB进战喊话",
    ally_spawn_yell = "DB友方喊话", boss_respawn_yell = "DB重生喊话", boss_gm_spawn_yell = "DB GM喊话",
    taunt_cooldown_seconds = 11, random_taunt_chance = 22,
    taunt_phase2_yells_text = "DB阶段2嘲讽",
    taunt_phase3_yells_text = "", taunt_critical_hp_yells_text = "",
    taunt_skill_cast_yells_text = "DB技能名=DB技能喊话",
    taunt_target_switch_yells_text = "DB换目标嘲讽", taunt_interrupt_yells_text = "DB打断嘲讽",
    taunt_kill_yells_text = "DB击杀嘲讽", taunt_low_hp_yells_text = "DB低血嘲讽",
    taunt_healer_kill_yells_text = "DB治疗击杀嘲讽", taunt_summon_minion_yells_text = "DB召唤嘲讽",
    taunt_combo_yells_text = "DB连招名=DB连招喊话", taunt_long_combat_yells_text = "DB久战嘲讽",
    ai_update_interval_ms = 2500,
    phase2_hp_threshold = 71, phase3_hp_threshold = 21, critical_hp_threshold = 9,
    low_hp_taunt_threshold = 31, low_hp_taunt_cooldown_ms = 21000,
    long_combat_taunt_interval_ms = 61000, target_reeval_loops = 4,
    phase2_summon_count_min = 3, phase2_summon_count_max = 4, phase3_summon_count = 5,
    phase2_spell_id = 1045, phase3_spell_id = 8600,
    patrol_enabled = 0, patrol_radius = 66, patrol_leash_radius = 77, patrol_interval_ms = 8000,
    minion_ai_enabled = 0, minion_ai_interval_ms = 2600, minion_target_range = 55,
    helper_entries_text = "11111,22222", ally_helper_entry = 20000,
    class_types_text = "1=melee\n2=healer", class_reward_items_text = "1=40611\n2=40622",
    managed_tier_entries_text = "190090,190091,190092,190093,190094",
}

-- 模拟「扩展表已存在、但脚本升级后描述表多了列」的线上状态：
-- 加载时必须先 ALTER 补列，否则引导写入会因 Unknown column 整条失败。
local PHASE_COLUMNS = {
    "phase2_hp_threshold", "phase3_hp_threshold", "critical_hp_threshold",
    "low_hp_taunt_threshold", "low_hp_taunt_cooldown_ms", "long_combat_taunt_interval_ms",
    "target_reeval_loops", "phase2_summon_count_min", "phase2_summon_count_max",
    "phase3_summon_count", "phase2_spell_id", "phase3_spell_id",
}

local mockExtColumns = { state_key = true, updated_at = true }
for column in pairs(EXT_VALUES) do mockExtColumns[column] = true end
for _, column in ipairs(PHASE_COLUMNS) do mockExtColumns[column] = nil end

local function mockInformationSchema(sql)
    -- 只有扩展表的列状态是「脚本升级后缺列」的模拟状态；其它表按列齐全处理
    if not sql:find("boss_activity_config_ext", 1, true) then
        return mockQuery({ 1 })
    end

    local inList = sql:match("COLUMN_NAME IN %((.-)%)")
    if inList then
        local present = 0
        for name in inList:gmatch("'([%w_]+)'") do
            if mockExtColumns[name] then present = present + 1 end
        end
        return mockQuery({ present })
    end

    local single = sql:match("COLUMN_NAME = '([%w_]+)'")
    if single then
        return mockQuery({ mockExtColumns[single] and 1 or 0 })
    end

    return mockQuery({ 1 })
end

-- 按 SELECT 里的列名组装一行数据；缺列直接判失败（描述表加了列而快照没跟上时立刻暴露）
local function rowFromSelect(sql, values)
    local columnsText = sql:match("SELECT%s+(.-)%s+FROM")
    if not columnsText then
        return nil
    end

    local row, missing = {}, {}
    for column in columnsText:gmatch("`([%w_]+)`") do
        local value = values[column]
        if value == nil then
            missing[#missing + 1] = column
        end
        row[#row + 1] = value
    end

    if #missing > 0 then
        fail("数据库快照缺少列: " .. table.concat(missing, ", "))
    end

    return mockQuery(row)
end

local env = setmetatable({}, { __index = _G })

env.CharDBQuery = function(sql)
    table.insert(recorded.sql, { kind = "query", sql = sql })
    if sql:find("information_schema") then
        return mockInformationSchema(sql)
    end
    if sql:find("boss_activity_config_ext", 1, true) and sql:find("SELECT", 1, true) then
        return rowFromSelect(sql, EXT_VALUES)
    end
    if sql:find("boss_activity_config", 1, true) and sql:find("SELECT", 1, true) then
        return rowFromSelect(sql, CONFIG_VALUES)
    end
    return nil -- runtime / 其它：模拟“没有行”
end

env.CharDBExecute = function(sql)
    table.insert(recorded.sql, { kind = "execute", sql = sql })

    -- 补列必须真的改变「表结构」，否则后面的查询/写入还是按缺列状态走
    local addedColumn = sql:match("ADD COLUMN `([%w_]+)`")
    if addedColumn then
        if mockExtColumns[addedColumn] then
            fail("重复补列: " .. addedColumn)
        end
        mockExtColumns[addedColumn] = true
        recorded.alters[#recorded.alters + 1] = addedColumn
    end
end

env.WorldDBQuery = env.CharDBQuery
env.WorldDBExecute = env.CharDBExecute

env.GetGameTime = function() return os.time() end
env.SendWorldMessage = function(msg) table.insert(recorded.replies, "[WORLD] " .. tostring(msg)) end
env.GetPlayersInWorld = function() return {} end
env.GetPlayerByGUID = function() return nil end
env.CreateLuaEvent = function() return 1 end
env.RemoveEventById = function() end
env.PerformIngameSpawn = function() return nil end
env.GetMapById = function() return nil end
env.GetUnitGUID = function(low, entry) return tostring(low) .. ":" .. tostring(entry) end
env.RegisterCreatureEvent = function(entry, ev, fn)
    engineCallbacks.creature[tostring(entry) .. "/" .. tostring(ev)] = fn
end
env.RegisterPlayerEvent = function(ev, fn)
    engineCallbacks.player[tostring(ev)] = fn
end
env.GetConfigValue = function() return 1 end

-- 快捷：模拟控制台(SOAP)执行一条 .boss 命令，返回本次产生的所有回复文本
local function runConsoleCommand(command)
    local handler = {
        messages = {},
        SendSysMessage = function(self, msg) table.insert(self.messages, tostring(msg)) end,
    }
    local fn = engineCallbacks.player["42"]
    if not fn then
        fail("PLAYER_EVENT_ON_COMMAND(42) 未注册")
        return {}
    end
    local returned = fn(42, nil, command, handler)
    recorded.lastReturn = returned
    return handler.messages
end

local function markersOf(messages)
    local text = table.concat(messages, " | ")
    local markers = {}
    for m in text:gmatch("%[AGMP_[A-Z]+%]") do table.insert(markers, m) end
    return table.concat(markers, ","), text
end

-- ------------------------------------------------------------------- 加载脚本
io.write("== 加载 " .. bossPath .. " ==\n")
local chunk, loadErr = loadfile(bossPath, "t", env)
if not chunk then
    io.write("LOAD ERROR: " .. tostring(loadErr) .. "\n")
    os.exit(2)
end

local runOk, runErr = pcall(chunk)
if not runOk then
    io.write("RUNTIME ERROR during load: " .. tostring(runErr) .. "\n")
    os.exit(2)
end
ok("脚本加载执行完成（EnsureBossSchema / LoadBossConfigFromDB / LoadBossRuntimeFromDB / 事件注册）")

-- --------------------------------------------------------------- 回归断言 1/2
assertTrue(print == originalPrint and rawget(env, "print") == nil,
    "全局 print 未被 boss.lua 覆盖（其它 Eluna 脚本不受影响）")
assertTrue(rawget(env, "RegisterBossEventsForEntry") == nil and rawget(env, "RegisterBossEventsForCandidates") == nil,
    "RegisterBossEventsFor* 不再泄漏为全局变量")
assertTrue(rawget(env, "activeBossInfo") == nil and rawget(env, "IsManagedBossEntry") == nil,
    "activeBossInfo / IsManagedBossEntry 仍为文件内 local")

-- ------------------------------------------------------ 配置读写 SQL 是否成形
-- 主表 = ac_eluna.boss_activity_config（与 AGMP 面板共享）
-- 扩展表 = ac_eluna.boss_activity_config_ext（脚本私有：喊话/嘲讽/巡逻/小怪/职业）
local mainConfigWrites, extConfigWrites = 0, 0
local extCreateSql, extInsertSql, mainInsertSql = nil, nil, nil

-- 精确区分两张表：扩展表名包含主表名，必须用「带反引号的完整表名」判断
local function isExtConfigSql(sql) return sql:find("`boss_activity_config_ext`", 1, true) ~= nil end
local function isMainConfigSql(sql)
    return sql:find("`boss_activity_config`", 1, true) ~= nil and not isExtConfigSql(sql)
end
local function isInsertSql(sql) return sql:find("INSERT", 1, true) ~= nil end

for _, item in ipairs(recorded.sql) do
    if item.kind == "query" and item.sql:find("CREATE TABLE IF NOT EXISTS", 1, true)
        and isExtConfigSql(item.sql) then
        extCreateSql = item.sql
    end
    if item.kind == "execute" and isExtConfigSql(item.sql) then
        extConfigWrites = extConfigWrites + 1
        if isInsertSql(item.sql) and extInsertSql == nil then
            extInsertSql = item.sql
        end
    end
    if item.kind == "execute" and isMainConfigSql(item.sql) then
        mainConfigWrites = mainConfigWrites + 1
        if isInsertSql(item.sql) and mainInsertSql == nil then
            mainInsertSql = item.sql
        end
    end
end

assertTrue(mainConfigWrites >= 1, "启动时会引导式写入 boss_activity_config")
assertTrue(extConfigWrites >= 1, "启动时会引导式写入 boss_activity_config_ext（脚本私有配置）")

if mainInsertSql then
    assertTrue(mainInsertSql:find("190090", 1, true) ~= nil, "主表配置写入包含新模板 entry 190090")
    assertTrue(mainInsertSql:find("`spawn_points_text`", 1, true) ~= nil, "主表配置写入包含 spawn_points_text 列")
    assertTrue(mainInsertSql:find("INSERT IGNORE INTO", 1, true) ~= nil, "引导写入用 INSERT IGNORE（不覆盖已有配置）")
end

-- REPLACE INTO 会删行重插：面板写在同表、但脚本不认识的列会被重置，所以脚本对
-- 两张配置表一律不用它（运行时表 boss_activity_runtime 用 REPLACE 是既有行为，不在检查范围）
local replaceConfigWrites = 0
for _, item in ipairs(recorded.sql) do
    if item.kind == "execute" and item.sql:find("REPLACE INTO", 1, true)
        and item.sql:find("boss_activity_config", 1, true) then
        replaceConfigWrites = replaceConfigWrites + 1
    end
end
assertTrue(replaceConfigWrites == 0, "配置表写入不再使用 REPLACE INTO（避免清掉面板列）")

-- 扩展表：建表语句与写入语句的列都必须和描述表一致（防止「描述表加了、DDL 忘了加」）
if extCreateSql and extInsertSql then
    local createColumns = {}
    local createBody = extCreateSql:match("%((.*)%) ENGINE") or ""
    for column in createBody:gmatch("`([%w_]+)`") do
        createColumns[column] = true
    end

    local insertColumnsText = extInsertSql:match("%((.-)%) VALUES") or ""
    local insertColumnCount, missingInCreate = 0, {}
    for column in insertColumnsText:gmatch("`([%w_]+)`") do
        insertColumnCount = insertColumnCount + 1
        if not createColumns[column] then
            missingInCreate[#missingInCreate + 1] = column
        end
    end

    assertTrue(insertColumnCount >= 32, "扩展表写入覆盖所有配置列（当前 " .. insertColumnCount .. " 列）")
    assertTrue(#missingInCreate == 0,
        "扩展表写入的每一列都在建表语句里" .. (#missingInCreate > 0 and ("（缺: " .. table.concat(missingInCreate, ",") .. "）") or ""))

    for _, column in ipairs({
        "boss_spawn_yell", "taunt_kill_yells_text", "taunt_combo_yells_text",
        "patrol_enabled", "minion_ai_interval_ms", "helper_entries_text",
        "class_reward_items_text", "managed_tier_entries_text",
    }) do
        assertTrue(createColumns[column] == true, "扩展表建表语句含列 " .. column)
    end
end

local runtimeWrites = 0
for _, item in ipairs(recorded.sql) do
    if item.sql:find("boss_activity_runtime") and item.kind == "execute" then
        runtimeWrites = runtimeWrites + 1
    end
end
assertTrue(runtimeWrites >= 1, "启动时写入了 boss_activity_runtime 引导行")

-- 扩展表迁移：桩状态里故意缺 12 个 [phase] 列，加载时必须先补列再写配置，
-- 否则线上遇到「脚本升级后描述表多了列」会整条写入失败（配置改了却不生效）
io.write("\n== 扩展表缺列迁移 ==\n")
assertTrue(#recorded.alters >= #PHASE_COLUMNS,
    string.format("自动补列 %d 个（缺 %d 个 [phase] 列）", #recorded.alters, #PHASE_COLUMNS))
local missingPhaseColumns = {}
for _, column in ipairs(PHASE_COLUMNS) do
    if not mockExtColumns[column] then missingPhaseColumns[#missingPhaseColumns + 1] = column end
end
assertTrue(#missingPhaseColumns == 0,
    "补列后扩展表列齐全" .. (#missingPhaseColumns > 0 and ("（缺: " .. table.concat(missingPhaseColumns, ",") .. "）") or ""))

local firstAlterIndex, firstExtInsertIndex = nil, nil
for index, item in ipairs(recorded.sql) do
    if item.kind == "execute" and item.sql:find("ADD COLUMN", 1, true) and firstAlterIndex == nil then
        firstAlterIndex = index
    end
    if item.kind == "execute" and isExtConfigSql(item.sql) and isInsertSql(item.sql)
        and firstExtInsertIndex == nil then
        firstExtInsertIndex = index
    end
end
assertTrue(firstAlterIndex ~= nil and firstExtInsertIndex ~= nil and firstAlterIndex < firstExtInsertIndex,
    "补列发生在扩展表写入之前（顺序：ALTER → INSERT）")

-- ------------------------------------------------------------ 命令驱动与断言
local cases = {
    { cmd = "boss help",              expect = "AGMP_OK",    name = ".boss help" },
    { cmd = "boss config reload",     expect = "AGMP_OK",    name = ".boss config reload" },
    { cmd = "boss preset list",       expect = "AGMP_OK",    name = ".boss preset list" },
    { cmd = "boss preset ember_storm",expect = "AGMP_OK",    name = ".boss preset <key>" },
    { cmd = "boss difficulty raid",   expect = "AGMP_OK",    name = ".boss difficulty <key>" },
    { cmd = "boss rebase",            expect = "AGMP_ERROR", name = ".boss rebase（无活跃 Boss）" },
    { cmd = "boss kill",              expect = "AGMP_ERROR", name = ".boss kill（无活跃 Boss）" },
    { cmd = "boss clear",             expect = "AGMP_OK",    name = ".boss clear（无活跃 Boss）" },
    { cmd = "boss spawn",             expect = "AGMP_ERROR", name = ".boss spawn（桩函数生成失败）" },
    { cmd = "boss nonsense",          expect = "AGMP_ERROR", name = ".boss 未知子命令" },
}

io.write("\n== 命令驱动 ==\n")
for _, case in ipairs(cases) do
    local messages = runConsoleCommand(case.cmd)
    local markers, text = markersOf(messages)
    io.write(string.format("  %-34s markers=%-12s %s\n", case.name, markers ~= "" and markers or "-",
        text:sub(1, 90)))
    assertTrue(markers:find(case.expect, 1, true) ~= nil,
        case.name .. " 返回 " .. case.expect .. "（面板可据此判定成功/失败）")
end

-- 配置展示 + 「运行时以数据库为准」：ext 表里的值必须真的生效，而不是被默认值盖掉
io.write("\n== .boss config show ==\n")
local groupMessages = runConsoleCommand("boss config show")
local groupText = table.concat(groupMessages, " | ")
assertTrue(#groupMessages > 0, ".boss config show 有输出")
local groupKeys = {
    "identity", "basic", "ally", "yells", "taunts", "ai", "phase", "patrol",
    "minion", "skill", "respawn", "spawnpoints", "helper", "reward", "class", "tier",
}
local missingGroups = {}
for _, group in ipairs(groupKeys) do
    if not groupText:find(group, 1, true) then missingGroups[#missingGroups + 1] = group end
end
assertTrue(#missingGroups == 0, "配置分组齐全（16 组）" ..
    (#missingGroups > 0 and ("（缺: " .. table.concat(missingGroups, ",") .. "）") or ""))

-- 各组声明的项数之和必须等于描述表总数（漏登记会立刻暴露）
local listedTotal = 0
for count in groupText:gmatch("（(%d+) 项）") do
    listedTotal = listedTotal + tonumber(count)
end
assertTrue(listedTotal >= 78, "分组项数之和覆盖全部配置项（当前 " .. listedTotal .. "）")

local function showGroup(group)
    return table.concat(runConsoleCommand("boss config show " .. group), " | ")
end

local yellsText = showGroup("yells")
assertTrue(yellsText:find("DB喊话-{BOSS_NAME}", 1, true) ~= nil,
    "喊话取自 boss_activity_config_ext（DB 值生效）")
assertTrue(yellsText:find("打爆这个垃圾服务器", 1, true) == nil,
    "喊话未回落到文件内默认值（说明 ext 表确实覆盖了默认配置）")

local tauntText = showGroup("taunts")
assertTrue(tauntText:find("DB击杀嘲讽", 1, true) ~= nil, "嘲讽列表取自 ext 表（多行文本解析正确）")
assertTrue(tauntText:find("DB技能名=DB技能喊话", 1, true) ~= nil, "键值型嘲讽（技能名=喊话）解析正确")
assertTrue(tauntText:find("11", 1, true) ~= nil and tauntText:find("22", 1, true) ~= nil,
    "嘲讽冷却/概率取自 ext 表")

local patrolText = showGroup("patrol")
assertTrue(patrolText:find("false", 1, true) ~= nil, "patrol_enabled=0 解析为 false")
assertTrue(patrolText:find("66", 1, true) ~= nil, "patrol_radius 取自 ext 表")

local helperText = showGroup("helper")
assertTrue(helperText:find("11111,22222", 1, true) ~= nil, "援军 entry 列表取自 ext 表")
assertTrue(helperText:find("20000", 1, true) ~= nil, "友方援军 entry 取自 ext 表")

local tierText = showGroup("tier")
assertTrue(tierText:find("190090,190091,190092,190093,190094", 1, true) ~= nil,
    "受管档位模板取自 ext 表")

local classText = showGroup("class")
assertTrue(classText:find("1=melee", 1, true) ~= nil,
    "职业类型映射（键值文本 1=melee）解析正确")
assertTrue(classText:find("1=40611", 1, true) ~= nil,
    "职业奖励池（键=物品列表）解析正确")

-- 战斗阶段阈值/阶段法术/召唤数量原先写死在 AI 里，现在必须来自配置
local phaseText = showGroup("phase")
assertTrue(phaseText:find("phase2_hp_threshold (phase2HpThreshold) = 71", 1, true) ~= nil,
    "阶段阈值 phase2HpThreshold 取自 ext 表")
assertTrue(phaseText:find("phase3_hp_threshold (phase3HpThreshold) = 21", 1, true) ~= nil,
    "阶段阈值 phase3HpThreshold 取自 ext 表")
assertTrue(phaseText:find("phase2_spell_id (phase2SpellId) = 1045", 1, true) ~= nil,
    "阶段法术 phase2SpellId 取自 ext 表")
assertTrue(phaseText:find("phase3_summon_count (phase3SummonCount) = 5", 1, true) ~= nil,
    "阶段召唤数量 phase3SummonCount 取自 ext 表")
assertTrue(phaseText:find("target_reeval_loops (targetReevalLoops) = 4", 1, true) ~= nil,
    "目标重评估间隔 targetReevalLoops 取自 ext 表")

local badGroupMessages = runConsoleCommand("boss config show nonsense")
local badMarkers = markersOf(badGroupMessages)
assertTrue(badMarkers:find("AGMP_ERROR", 1, true) ~= nil, "未知配置分组返回 AGMP_ERROR")

local badUsage = markersOf(runConsoleCommand("boss config oops"))
assertTrue(badUsage:find("AGMP_ERROR", 1, true) ~= nil, ".boss config <未知子命令> 返回 AGMP_ERROR")

-- 非 boss 命令必须放行（返回 true 表示交给核心继续处理）
io.write("\n== 非 boss 命令放行 ==\n")
local handler = { messages = {}, SendSysMessage = function(self, m) table.insert(self.messages, m) end }
local passthrough = engineCallbacks.player["42"](42, nil, "reload ale", handler)
assertTrue(passthrough == true, "非 boss 命令返回 true（不拦截其他 GM 指令）")
assertTrue(#handler.messages == 0, "非 boss 命令不产生 boss 回复")

-- clear 必须写 command_clear 事件并把运行时复位
io.write("\n== .boss clear 的副作用 ==\n")
runConsoleCommand("boss clear")
local hasClearEvent, hasRuntimeReset = false, false
for _, item in ipairs(recorded.sql) do
    if item.sql:find("boss_activity_events") and item.sql:find("command_clear", 1, true) then
        hasClearEvent = true
    end
    if item.sql:find("boss_activity_runtime") and item.sql:find("'idle'", 1, true) then
        hasRuntimeReset = true
    end
end
assertTrue(hasClearEvent, ".boss clear 写入 event_type='command_clear'")
assertTrue(hasRuntimeReset, ".boss clear 把 runtime 复位为 idle")

-- PLAYER_EVENT_ON_HEAL(65) 与 6 个 creature 事件是否注册齐全
io.write("\n== 事件注册 ==\n")
assertTrue(engineCallbacks.player["65"] ~= nil, "PLAYER_EVENT_ON_HEAL(65) 已注册")
for _, entry in ipairs({ "190090", "190091", "190092", "190093" }) do
    local complete = true
    for _, ev in ipairs({ "1", "2", "3", "4", "5", "9" }) do
        if not engineCallbacks.creature[entry .. "/" .. ev] then complete = false end
    end
    assertTrue(complete, "entry " .. entry .. " 的 creature 事件齐全(1/2/3/4/5/9)")
end
-- ext 表里的 managed_tier_entries_text 多带了一个 190094（文件内默认没有）：
-- 它也被注册事件，说明「受管模板」确实以数据库为准
assertTrue(engineCallbacks.creature["190094/1"] ~= nil,
    "受管模板 entry 由 ext 表驱动（190094 也注册了事件）")

-- ------------------------------------------------- 多区绑定（本区库名 / state_key）
-- boss.lua 的「多区支持」只有一句话：部署到不同区时只改 §2 的 key
-- （BOSS_RUNTIME_KEY / BOSS_CONFIG_KEY，两行必须相同），四张表都靠这个 state_key 分租。
-- 这里把常量改写后**重新加载一遍**，既核对 SQL 用的库名，也核对写入带的是本区 key。
-- 为什么必须动态重载而不是只看源码：真正的风险是"某处又写死了 ac_eluna / 'current'"，
-- 写死的值不会出现在源码里那两个常量上，只有跑起来才会在 SQL 里露出来。
io.write("\n== 多区绑定（共用库 + state_key 分租） ==\n")

local function isDbQualified(sql)
    return sql:find("`boss_activity", 1, true) ~= nil
        or sql:find("CREATE DATABASE", 1, true) ~= nil
end

-- 返回 (引用了库名的语句数, 其中库名不对的语句数)
local function auditBinding(sqlList, expectDb, label)
    local qualified, wrong = 0, 0
    local samples = {}
    for _, item in ipairs(sqlList) do
        if isDbQualified(item.sql) then
            qualified = qualified + 1
            local rest = item.sql:gsub("`" .. expectDb .. "`", "")
            if item.sql:find("`" .. expectDb .. "`", 1, true) == nil or rest:find("`ac_eluna", 1, true) ~= nil then
                wrong = wrong + 1
                samples[#samples + 1] = item.sql
            end
        end
    end

    assertTrue(qualified > 0, label .. "：存在引用本区库的语句（检查项没有空跑）")
    assertTrue(wrong == 0, label .. "：每条都指向 " .. expectDb .. "（不符 " .. wrong .. "/" .. qualified .. " 条）")
    for i = 1, math.min(#samples, 3) do
        io.write("        " .. samples[i]:sub(1, 160) .. "\n")
    end
end

-- 取 INSERT 语句的第一个字符串值 —— 事件/贡献表里它就是 state_key
local function firstInsertValue(sql)
    return sql:match("VALUES%s*%(%s*'([^']*)'")
end

auditBinding(recorded.sql, "ac_eluna", "默认部署(ac_eluna)")

-- 模拟把同一份 boss.lua 部署到第二个区：多区共用库，所以只改 §2 的 key（库名不变）
local sourceHandle = assert(io.open(bossPath, "r"))
local source = sourceHandle:read("*a")
sourceHandle:close()

local targetDb, targetRuntimeKey = "ac_eluna", "realm-b"
local rewritten, dbSubs = source:gsub('(local BOSS_DB_NAME%s*=%s*")[^"]*(")', "%1" .. targetDb .. "%2", 1)
local rewrittenKey, keySubs = rewritten:gsub('(local BOSS_RUNTIME_KEY%s*=%s*")[^"]*(")', "%1" .. targetRuntimeKey .. "%2", 1)
local rewrittenConfigKey, configKeySubs = rewrittenKey:gsub('(local BOSS_CONFIG_KEY%s*=%s*")[^"]*(")', "%1" .. targetRuntimeKey .. "%2", 1)
assertTrue(dbSubs == 1, "BOSS_DB_NAME 常量可被改写（deploy-realm 脚本依赖同一处）")
assertTrue(keySubs == 1, "BOSS_RUNTIME_KEY 常量可被改写")
assertTrue(configKeySubs == 1, "BOSS_CONFIG_KEY 常量可被改写（面板用同一个 key 读写四张表）")

local bindingLogs = {}
local childEnv = setmetatable({
    print = function(msg) table.insert(bindingLogs, tostring(msg)) end,
}, { __index = env })

local boundary = #recorded.sql
local childChunk, childErr = load(rewrittenConfigKey, "@" .. bossPath .. ":realm-rewrite", "t", childEnv)
if not childChunk then
    fail("改写后加载失败: " .. tostring(childErr))
else
    local childOk, childRunErr = pcall(childChunk)
    if not childOk then
        fail("改写后运行期错误: " .. tostring(childRunErr))
    end
end

-- 用子环境跑一条会写事件的命令（boss config reload → command_config_reload，无活跃 Boss 也会写），
-- 断言事件 INSERT 带的是**本区 key** 而不是默认的 current。注意命令串按核心的约定不带前导点
-- （AzerothCore 把 "." 去掉后才交给 handler，runConsoleCommand 传的是去掉点之后的字符串）。
-- 贡献表的写入在离线环境里跑不到（需要真的打死 Boss），所以它的列清单用源码静态检查兜底。
runConsoleCommand("boss config reload")
local childSql = {}
for i = boundary + 1, #recorded.sql do childSql[#childSql + 1] = recorded.sql[i] end
auditBinding(childSql, targetDb, "改为 key=" .. targetRuntimeKey .. " 的部署")

local eventInsertKey, eventInsertSeen = nil, false
for _, item in ipairs(childSql) do
    if item.sql:find("INSERT INTO", 1, true) and item.sql:find("boss_activity_events", 1, true) then
        eventInsertSeen = true
        eventInsertKey = firstInsertValue(item.sql)
    end
end
assertTrue(eventInsertSeen, "改写 key 后仍有事件写入语句（boss config reload → command_config_reload）")
assertTrue(eventInsertKey == targetRuntimeKey,
    "事件写入带的是本区 key（实际 " .. tostring(eventInsertKey) .. "，期望 " .. targetRuntimeKey .. "）")

assertTrue(source:find("`state_key`, `boss_guid`, `boss_entry`, `boss_name`, `event_type`", 1, true) ~= nil,
    "事件表 INSERT 的列清单含 state_key（结构回归）")
assertTrue(source:find("`state_key`, `boss_guid`, `boss_entry`, `boss_name`, `player_guid`", 1, true) ~= nil,
    "贡献表 INSERT 的列清单含 state_key（结构回归）")
assertTrue(source:find("EnsureBossSchemaColumn(BOSS_EVENT_TABLE, 'state_key'", 1, true) ~= nil
    and source:find("EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'state_key'", 1, true) ~= nil,
    "老库缺列时自动补 state_key（零迁移升级）")
assertTrue(source:find("EnsureBossSchemaIndex(BOSS_EVENT_TABLE, 'idx_state_key_id'", 1, true) ~= nil,
    "事件表自动补 (state_key, id) 索引")

-- 启动自检日志必须报出本区绑定：运维靠它确认没串区
local bindingLine = nil
for _, line in ipairs(bindingLogs) do
    if line:find("本区绑定", 1, true) then bindingLine = line end
end
assertTrue(bindingLine ~= nil, "启动时打印本区绑定日志")
if bindingLine then
    assertTrue(bindingLine:find(targetDb, 1, true) ~= nil
        and bindingLine:find(targetRuntimeKey, 1, true) ~= nil,
        "绑定日志内容与本区一致（库名 + state_key）")
end

-- state_key 也必须跟着走：runtime 的引导/查询语句里要用改写后的 key
local keySeen = false
for _, item in ipairs(childSql) do
    if item.sql:find("boss_activity_runtime", 1, true) and item.sql:find(targetRuntimeKey, 1, true) then
        keySeen = true
    end
end
assertTrue(keySeen, "runtime 语句使用本区 state_key（" .. targetRuntimeKey .. "）")

-- --------------------------------------------------------------------- 汇总
-- 可选：把本次运行生成的所有 SQL 落盘，便于人工复核语句是否符合预期。
--   lua.exe smoke.lua <boss.lua> --dump-sql <out.sql>
--   lua.exe smoke.lua <boss.lua> --dump-sql <out.sql> --include-ddl
--
-- ⚠⚠ 安全警告（2026-09-23 真的踩过）：
--   不要把导出的 SQL 直接丢进「真实库 + START TRANSACTION / ROLLBACK」里跑！
--   导出文件里含 CREATE DATABASE / CREATE TABLE 这类 DDL，而 MySQL 的 DDL 会**隐式提交**，
--   事务会被提前结束，后面的 UPDATE / REPLACE INTO 就真的落库了（当时覆盖了线上
--   boss_activity_config 的 spawn_points_text、skill_preset 等字段）。
--   要校验 DML 语法，请改用**一次性 scratch 库**：
--       CREATE DATABASE boss_verify;  -- 建同名结构（CREATE TABLE ... LIKE / INSERT ... SELECT）
--       把导出 SQL 里的 `ac_eluna` 替换成 `boss_verify` 后执行，最后 DROP DATABASE。
--   因此默认导出会**过滤掉 DDL**，只留 INSERT/REPLACE/UPDATE/DELETE（--include-ddl 可强制包含）。
local dumpIndex = nil
local includeDdl = false
for i = 1, #arg do
    if arg[i] == "--dump-sql" then dumpIndex = i end
    if arg[i] == "--include-ddl" then includeDdl = true end
end
if dumpIndex and arg[dumpIndex + 1] then
    local out = io.open(arg[dumpIndex + 1], "w")
    if out then
        local written, skipped = 0, 0
        for _, item in ipairs(recorded.sql) do
            local head = item.sql:gsub("^%s+", ""):upper()
            local isDdl = head:match("^CREATE") or head:match("^DROP") or head:match("^ALTER")
            if isDdl and not includeDdl then
                skipped = skipped + 1
            else
                out:write(item.sql:gsub(";%s*$", "") .. ";\n")
                written = written + 1
            end
        end
        out:close()
        io.write(string.format("  已导出 SQL: %s（%d 条；跳过 DDL %d 条）\n",
            arg[dumpIndex + 1], written, skipped))
    else
        fail("无法写入 SQL 导出文件: " .. tostring(arg[dumpIndex + 1]))
    end
end

io.write("\n== 汇总 ==\n")
io.write(string.format("  记录 SQL 语句: %d 条\n", #recorded.sql))
io.write(string.format("  注册 creature 事件: %d 个\n", (function()
    local n = 0
    for _ in pairs(engineCallbacks.creature) do n = n + 1 end
    return n
end)()))
if #recorded.failures == 0 then
    io.write("  RESULT: PASS\n")
    os.exit(0)
end
io.write(string.format("  RESULT: FAIL（%d 项）\n", #recorded.failures))
for _, f in ipairs(recorded.failures) do io.write("   - " .. f .. "\n") end
os.exit(1)
