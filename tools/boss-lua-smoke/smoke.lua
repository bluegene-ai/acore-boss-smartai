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
--      lua.exe smoke.lua "E:\Server\release\80\lua_scripts\boss.lua"
--
--  覆盖：配置加载(SQL 构造)、运行时持久化、help/config/preset/difficulty/
--        rebase/kill/clear/spawn/未知子命令、非 boss 命令放行、
--        以及「全局 print 未被覆盖」「不再泄漏全局函数」两项回归断言。
-- ============================================================================

local bossPath = arg and arg[1] or "E:/Server/release/80/lua_scripts/boss.lua"

-- ---------------------------------------------------------------- 记录与断言
local recorded = { sql = {}, events = {}, replies = {}, failures = {} }
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

-- 线上真实配置的快照（boss_activity_config 的 34 列）
local CONFIG_ROW = {
    190090, "送财童子", 83, 999, 150000, "467", 50, 999, 10, 1, 2,
    "spellbreak_bulwark", "hard", 1, 1, 3, 60, 10, 15, "weighted", 80,
    100, 80, 35, 10, 3, 40753, 2, 30000, 50000,
    "38082,41600,51809,34067", "45059,44491", "32768,30480", "571,4353.573,-4411.8877,151.3909",
}

local env = setmetatable({}, { __index = _G })

env.CharDBQuery = function(sql)
    table.insert(recorded.sql, { kind = "query", sql = sql })
    if sql:find("information_schema") then
        return mockQuery({ 1 })
    end
    if sql:find("boss_activity_config") and sql:find("SELECT") then
        return mockQuery(CONFIG_ROW)
    end
    return nil -- runtime / 其它：模拟“没有行”
end

env.CharDBExecute = function(sql)
    table.insert(recorded.sql, { kind = "execute", sql = sql })
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
local configWrites = 0
for _, item in ipairs(recorded.sql) do
    if item.sql:find("boss_activity_config") and item.kind == "execute" then
        configWrites = configWrites + 1
        assertTrue(item.sql:find("190090", 1, true) ~= nil,
            "配置写入包含新模板 entry 190090")
        assertTrue(item.sql:find("`spawn_points_text`", 1, true) ~= nil,
            "配置写入包含 spawn_points_text 列")
    end
end
assertTrue(configWrites >= 1, "启动时会引导式写入 boss_activity_config（INSERT IGNORE）")

local runtimeWrites = 0
for _, item in ipairs(recorded.sql) do
    if item.sql:find("boss_activity_runtime") and item.kind == "execute" then
        runtimeWrites = runtimeWrites + 1
    end
end
assertTrue(runtimeWrites >= 1, "启动时写入了 boss_activity_runtime 引导行")

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
