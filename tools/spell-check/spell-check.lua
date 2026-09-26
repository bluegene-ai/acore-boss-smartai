#!/usr/bin/env lua52_interpreter
--[[----------------------------------------------------------------------------
  spell-check.lua - AzerothCore / Eluna 法术 ID 校验工具

  用途：扫描一个 Eluna 脚本里用到的所有法术 ID，逐个到客户端 DBC (Spell.dbc)
        里校验存在性，并可选地反查 world 库（哪些 creature 使用了该法术）。

  用法：
    lua52_interpreter.exe spell-check.lua [选项] [脚本路径]

    脚本路径       要审计的 Lua 脚本，默认
                   C:\pureland\Release\lua_scripts\acore-boss-smartai\boss.lua
    -dbc <路径>    Spell.dbc 路径，默认 C:\pureland\data\dbc\Spell.dbc
    -db            额外做数据库反查（需要 mysql.exe 与本机 worldserver.conf）
    -v             详细输出（打印提取到的每个原始条目）

  退出码：
    0  所有提取到的法术 ID 都在 DBC 里存在
    1  有法术 ID 在 DBC 里不存在（硬错误）
    2  工具自身错误（文件读不到 / DBC 头非法 / 提取不到任何 ID 等）

  依赖：
    - Lua 5.2（没有 string.unpack，本工具用 string.byte 手工解小端 uint32）
    - 可选：C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe

  口径与已知局限详见同目录 README.md。
  本工具只读，不会修改被审计的脚本。
----------------------------------------------------------------------------]]

local DEFAULT_SCRIPT = [[C:\pureland\Release\lua_scripts\acore-boss-smartai\boss.lua]]
local DEFAULT_DBC    = [[C:\pureland\data\dbc\Spell.dbc]]
local MYSQL_EXE      = [[C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe]]
local WORLDSERVER_CONF = [[C:\pureland\Release\configs\worldserver.conf]]

-- Spell.dbc 字段下标（与 web\AcoreGMPanel\app\Support\GameNameResolver.php 的
-- DBC_SPECS['spell'] 完全一致：idField=0, nameField=136, maskField=152）
local SPELL_ID_FIELD   = 0
local SPELL_NAME_FIELD = 136
local SPELL_MASK_FIELD = 152

-- 客户端 16 个语种槽位的标准顺序（同 GameNameResolver::DBC_LOCALE_ORDER）
local DBC_LOCALE_ORDER = {
  'enUS', 'koKR', 'frFR', 'deDE', 'enCN', 'zhCN',
  'enTW', 'zhTW', 'esES', 'esMX', 'ruRU', 'ptPT',
  'ptBR', 'itIT', 'Unk', 'Unk2',
}

local t0 = os.clock()

local function elapsed()
  return string.format('%.2fs', os.clock() - t0)
end

local function die(msg)
  io.stderr:write('[spell-check] 工具错误: ' .. tostring(msg) .. '\n')
  os.exit(2)
end

--------------------------------------------------------------------------------
-- 参数解析
--------------------------------------------------------------------------------

local opts = {
  script = DEFAULT_SCRIPT,
  dbc = DEFAULT_DBC,
  db = false,
  verbose = false,
}

local args = { ... }
local i = 1
while i <= #args do
  local a = args[i]
  if a == '-db' then
    opts.db = true
  elseif a == '-v' or a == '--verbose' then
    opts.verbose = true
  elseif a == '-dbc' then
    i = i + 1
    if not args[i] then die('-dbc 需要一个路径参数') end
    opts.dbc = args[i]
  elseif a == '-h' or a == '--help' then
    io.write('用法: lua52_interpreter.exe spell-check.lua [-db] [-v] [-dbc <Spell.dbc>] [脚本路径]\n')
    os.exit(0)
  else
    opts.script = a
  end
  i = i + 1
end

--------------------------------------------------------------------------------
-- 工具函数
--------------------------------------------------------------------------------

local function readFile(path)
  local f, err = io.open(path, 'rb')
  if not f then return nil, err end
  local data = f:read('*a')
  f:close()
  if not data then return nil, 'read failed' end
  return data
end

-- 小端 uint32（Lua 5.2 没有 string.unpack，手工拼）
local function u32le(s, pos)               -- pos 为 1-based 起始字节
  local b1, b2, b3, b4 = string.byte(s, pos, pos + 3)
  if not b4 then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function trim(s)
  return (string.gsub(s, '^%s+', ''):gsub('%s+$', ''))
end

local function shellquote(s)
  return '"' .. tostring(s) .. '"'
end

-- 安全执行 shell 命令并把 stdout 读回来（只用于可选的 -db 反查）
local function popen(cmd)
  local ok, pipe = pcall(io.popen, cmd, 'r')
  if not ok or not pipe then return nil, 'io.popen 不可用' end
  local out = pipe:read('*a')
  pipe:close()
  return out or ''
end

local function listRoles(t)
  local r = {}
  for k in pairs(t) do r[#r + 1] = k end
  table.sort(r)
  return table.concat(r, ',')
end

--------------------------------------------------------------------------------
-- 1. 解析 Spell.dbc
--------------------------------------------------------------------------------

-- 在字符串块里读一个以 \0 结尾的字符串
local function dbcString(strings, offset, strSize)
  if offset <= 0 or offset >= strSize then return nil end
  local stop = string.find(strings, '\0', offset + 1, true)   -- offset 是 0-based
  if not stop then return nil end
  local v = trim(string.sub(strings, offset + 1, stop - 1))
  if v == '' then return nil end
  return v
end

-- 探测 DBC 里实际填充的语种槽位（照搬 GameNameResolver::dbcLocaleOffset 的抽样策略，
-- 本站期望语种是 zhCN，因此优先顺序：zhCN -> zhTW -> 掩码位 -> 全槽位抽样）
local function detectLocaleSlot(recData, recSize, fieldCount, records, strings, strSize)
  if SPELL_MASK_FIELD >= fieldCount then return 0, 0 end

  local mask = 0
  local seen = 0
  for r = 0, records - 1 do
    local v = u32le(recData, r * recSize + SPELL_MASK_FIELD * 4 + 1)
    if v and v ~= 0 then mask = v; break end
    seen = seen + 1
    if seen >= 50 then break end
  end
  if mask == 0 then return 0, 0 end

  local function slotHasData(slot)
    local field = SPELL_NAME_FIELD + slot
    if field < 0 or field >= fieldCount then return false end
    local checked, hits = 0, 0
    for r = 0, records - 1 do
      checked = checked + 1
      local off = u32le(recData, r * recSize + field * 4 + 1)
      if off and dbcString(strings, off, strSize) then hits = hits + 1 end
      if checked >= 200 then break end
    end
    return checked > 0 and hits >= math.max(1, math.floor(checked * 0.5))
  end

  local candidates, added = {}, {}
  local function push(slot)
    if slot and slot >= 0 and slot <= 15 and not added[slot] then
      added[slot] = true
      candidates[#candidates + 1] = slot
    end
  end

  -- 期望语种 zhCN = slot 5, 同语系 zhTW = slot 7
  push(5); push(7)
  for slot = 0, 15 do
    if math.floor(mask / (2 ^ slot)) % 2 == 1 then push(slot) end
  end
  for slot = 0, 15 do push(slot) end

  for _, slot in ipairs(candidates) do
    if slotHasData(slot) then return slot, mask end
  end
  return 0, mask
end

local function loadDbc(path)
  local size = nil
  do
    local f = io.open(path, 'rb')
    if not f then return nil, 'Spell.dbc 打不开: ' .. path end
    size = f:seek('end')
    f:close()
  end

  local data, err = readFile(path)
  if not data then return nil, 'Spell.dbc 读取失败: ' .. tostring(err) end
  if #data ~= size then
    return nil, string.format('Spell.dbc 读取不完整: 期望 %d 字节, 实际 %d 字节', size, #data)
  end

  if string.sub(data, 1, 4) ~= 'WDBC' then
    return nil, 'Spell.dbc 魔数不是 WDBC'
  end

  local records    = u32le(data, 5)
  local fieldCount = u32le(data, 9)
  local recSize    = u32le(data, 13)
  local strSize    = u32le(data, 17)

  local expect = 20 + records * recSize + strSize
  local info = {
    file = path,
    size = #data,
    headerBytes = 20,
    records = records,
    fieldCount = fieldCount,
    recSize = recSize,
    strSize = strSize,
    expectSize = expect,
    sizeMatch = (expect == #data),
  }

  if records <= 0 or fieldCount <= 0 or recSize <= 0 or strSize <= 0 then
    return nil, 'Spell.dbc 头字段非法'
  end
  if recSize < fieldCount * 4 then
    return nil, string.format('Spell.dbc recordSize(%d) < fieldCount(%d)*4', recSize, fieldCount)
  end
  if not info.sizeMatch then
    return nil, string.format('Spell.dbc 头与实际大小不符: 头推算 %d, 实际 %d', expect, #data)
  end

  local recData = string.sub(data, 21, 20 + records * recSize)
  local strings = string.sub(data, 21 + records * recSize)
  data = nil
  collectgarbage('collect')
  info.heapAfterSliceKB = math.floor(collectgarbage('count'))

  local slot, mask = detectLocaleSlot(recData, recSize, fieldCount, records, strings, strSize)
  info.localeSlot = slot
  info.localeName = DBC_LOCALE_ORDER[slot + 1] or '?'
  info.sampleMask = mask

  local nameField = SPELL_NAME_FIELD + slot
  info.nameField = nameField

  local map = {}
  local idCollisions = 0
  for r = 0, records - 1 do
    local base = r * recSize + 1
    local id = u32le(recData, base + SPELL_ID_FIELD * 4)
    if id and id > 0 then
      local off = u32le(recData, base + nameField * 4)
      local name = off and dbcString(strings, off, strSize) or nil
      local m = 0
      if SPELL_MASK_FIELD < fieldCount then
        m = u32le(recData, base + SPELL_MASK_FIELD * 4) or 0
      end
      if map[id] then idCollisions = idCollisions + 1 end
      map[id] = { name = name, mask = m }
    end
  end
  info.idCollisions = idCollisions
  info.parsedIds = 0
  for _ in pairs(map) do info.parsedIds = info.parsedIds + 1 end

  return { map = map, info = info }
end

--------------------------------------------------------------------------------
-- 2. 从被审计脚本里提取法术 ID
--    做法：逐字符括号配平，先定位两张库表（SKILL_PRESET_LIBRARY /
--    INTERRUPT_SPELL_LIBRARY）的字节区间，再在区间内按语法模式精确匹配，
--    而不是全文正则硬啃。详见 README「提取方式」。
--------------------------------------------------------------------------------

-- 从 openIdx（'{' 位置）找到配对的 '}'，跳过字符串与注释
local function matchBrace(src, openIdx)
  local depth = 0
  local i = openIdx
  local n = #src
  while i <= n do
    local c = string.sub(src, i, i)
    if c == '-' and string.sub(src, i, i + 1) == '--' then
      if string.sub(src, i, i + 3) == '--[[' then
        local close = string.find(src, ']]', i + 4, true)
        if not close then return nil end
        i = close + 2
      else
        local nl = string.find(src, '\n', i, true)
        if not nl then return nil end
        i = nl + 1
      end
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = string.sub(src, j, j)
        if d == '\\' then j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      i = j + 1
    elseif c == '{' then
      depth = depth + 1
      i = i + 1
    elseif c == '}' then
      depth = depth - 1
      if depth == 0 then return i end
      i = i + 1
    else
      i = i + 1
    end
  end
  return nil
end

-- 定位 `local NAME = { ... }`，返回内容区间 (startContent, endContent)
local function tableExtent(src, name)
  local anchor = string.find(src, 'local%s+' .. name .. '%s*=%s*{')
  if not anchor then return nil end
  local openIdx = string.find(src, '{', anchor, true)
  local close = matchBrace(src, openIdx)
  if not close then return nil end
  return openIdx + 1, close - 1
end

-- 在 extent 内找一个顶层键 `KEY = { ... }`，返回内容区间
local function subsectionExtent(src, from, to, key)
  local anchor = string.find(src, '\n%s*' .. key .. '%s*=%s*{', from)
  if not anchor or anchor > to then return nil end
  local openIdx = string.find(src, '{', anchor, true)
  local close = matchBrace(src, openIdx)
  if not close or close > to then return nil end
  return openIdx + 1, close - 1
end

local function countLines(src, idx)
  local _, n = string.gsub(string.sub(src, 1, idx), '\n', '\n')
  return n + 1
end

local function extract(script, src)
  local findings = {}       -- 有序数组 {id=, name=, where=, line=}
  local seen = {}           -- "id|where" -> true，同一调用点只记一次

  -- at：条目在源文件里的起始字节（用来算行号，精确到条目而不是表头）
  local function add(id, name, where, at)
    id = tonumber(id)
    if not id or id <= 0 then return end
    local key = id .. '|' .. where
    if seen[key] then return end
    seen[key] = true
    local rec = { id = id, name = name, where = where, line = countLines(src, at or 1) }
    findings[#findings + 1] = rec
  end

  -- 从 region 里抽取 `spellId = N ... name = "X"` 形态的条目（skillPools / openingSkills /
  -- INTERRUPT_SPELL_LIBRARY 都是这个形态）。先匹配带 name 的，再补没有 name 的。
  local function scanSpellIdEntries(region, regionStart, where)
    local ranges = {}
    local p = 1
    while true do
      local s1, s2, sid = string.find(region, 'spellId%s*=%s*(%d+)', p)
      if not s1 then break end
      ranges[#ranges + 1] = { s = s1, e = s2, sid = sid }
      p = s2 + 1
    end
    for i, r in ipairs(ranges) do
      local stop = (ranges[i + 1] and ranges[i + 1].s - 1) or #region
      local chunk = string.sub(region, r.e + 1, stop)
      local nm = string.match(chunk, 'name%s*=%s*"([^"]*)"')
      add(r.sid, nm, where, regionStart + r.s - 1)
    end
    return #ranges
  end

  -- 2a. SKILL_PRESET_LIBRARY：先枚举顶层预设键，再在每个预设块里找子表
  local libS, libE = tableExtent(src, 'SKILL_PRESET_LIBRARY')
  if not libS then return nil, '在脚本里找不到 SKILL_PRESET_LIBRARY 表' end

  local presets = {}
  local pos = libS
  while true do
    local k1, k2, key = string.find(src, '%f[%a_]([%a_][%w_]*)%s*=%s*{', pos)
    if not k1 or k1 > libE then break end
    local openIdx = string.find(src, '{', k2, true)
    local close = matchBrace(src, openIdx)
    if not close or close > libE then break end
    presets[#presets + 1] = { key = key, s = openIdx + 1, e = close - 1, open = openIdx }
    pos = close + 1
    if #presets > 64 then break end
  end
  if #presets == 0 then return nil, 'SKILL_PRESET_LIBRARY 里没解析出任何预设' end

  local poolEntries, chainEntries, openingEntries = 0, 0, 0
  for _, pre in ipairs(presets) do
    local body = string.sub(src, pre.s, pre.e)
    local off = pre.s - 1     -- 把 body 内偏移换算回全文偏移

    -- skillPools = { [N] = { ... }, ... }
    local ps, pe = subsectionExtent(src, pre.s, pre.e, 'skillPools')
    if ps then
      local p = ps
      while true do
        local a1, a2, poolNo = string.find(src, '%[%s*(%d+)%s*%]%s*=%s*{', p)
        if not a1 or a1 > pe then break end
        local o = string.find(src, '{', a2, true)
        local c = matchBrace(src, o)
        if not c or c > pe then break end
        local region = string.sub(src, o + 1, c - 1)
        poolEntries = poolEntries + scanSpellIdEntries(region, o + 1,
          string.format('%s.skillPools[%s]', pre.key, poolNo))
        p = c + 1
      end
    end

    -- comboChains = { {name = "X", skills = {{id, "target"}, ...}, ...}, ... }
    local cs, ce = subsectionExtent(src, pre.s, pre.e, 'comboChains')
    if cs then
      local c = cs
      while true do
        local a1, a2, chainName = string.find(src, 'name%s*=%s*"([^"]*)"', c)
        if not a1 or a1 > ce then break end
        local sk = string.find(src, 'skills%s*=%s*{', a2)
        if not sk or sk > ce then break end
        local o = string.find(src, '{', sk, true)
        local cl = matchBrace(src, o)
        if not cl or cl > ce then break end
        local region = string.sub(src, o + 1, cl - 1)
        local where = string.format('%s.comboChains["%s"]', pre.key, chainName)
        local q = 1
        while true do
          local s1, s2, sid = string.find(region, '{%s*(%d+)%s*,', q)
          if not s1 then break end
          add(sid, nil, where, o + 1 + s1 - 1)
          chainEntries = chainEntries + 1
          q = s2 + 1
        end
        c = cl + 1
      end
    end

    -- openingSkills = { {spellId = N, name = "X", target = "..."}, ... }
    local os_, oe = subsectionExtent(src, pre.s, pre.e, 'openingSkills')
    if os_ then
      openingEntries = openingEntries + scanSpellIdEntries(
        string.sub(src, os_, oe), os_, string.format('%s.openingSkills', pre.key))
    end
  end

  -- 2b. INTERRUPT_SPELL_LIBRARY：先看实际字段名，再看兜底的 id 字段
  local is_, ie = tableExtent(src, 'INTERRUPT_SPELL_LIBRARY')
  local interruptEntries = 0
  if is_ then
    local region = string.sub(src, is_, ie)
    interruptEntries = scanSpellIdEntries(region, is_, 'INTERRUPT_SPELL_LIBRARY')
    if interruptEntries == 0 then
      -- 兜底：字段名不是 spellId 而是 id
      local p = 1
      while true do
        local s1, s2, sid = string.find(region, '%f[%a_]id%s*=%s*(%d+)', p)
        if not s1 then break end
        local chunk = string.sub(region, s2 + 1)
        local nm = string.match(chunk, 'name%s*=%s*"([^"]*)"')
        add(sid, nm, 'INTERRUPT_SPELL_LIBRARY', is_ + s1 - 1)
        interruptEntries = interruptEntries + 1
        p = s2 + 1
      end
    end
  end

  -- 2c. BOSS_CONFIG 里的字面量自身法术
  for _, key in ipairs({ 'phase2SpellId', 'phase3SpellId' }) do
    local at, _, val = string.find(src, '\n%s*' .. key .. '%s*=%s*(%d+)')
    if at and val then
      add(val, nil, 'BOSS_CONFIG.' .. key, at)
    end
  end

  return {
    findings = findings,
    presets = #presets,
    poolEntries = poolEntries,
    chainEntries = chainEntries,
    openingEntries = openingEntries,
    interruptEntries = interruptEntries,
    presetKeys = presets,
  }
end

--------------------------------------------------------------------------------
-- 3. 可选的数据库反查
--------------------------------------------------------------------------------

local function parseDbInfo()
  local f = io.open(WORLDSERVER_CONF, 'r')
  if not f then return nil, 'worldserver.conf 打不开' end
  local info
  for line in f:lines() do
    local s = string.match(line, '^%s*WorldDatabaseInfo%s*=%s*"([^"]*)"')
    if s then info = s; break end
  end
  f:close()
  if not info then return nil, 'worldserver.conf 里找不到 WorldDatabaseInfo' end
  local host, port, user, pass, db = string.match(info, '^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*)$')
  if not host then return nil, 'WorldDatabaseInfo 格式不是 host;port;user;password;dbname' end
  return { host = host, port = port, user = user, pass = pass, db = db }
end

-- 通过 SQL 文件 + MYSQL_PWD 环境变量调用 mysql.exe：
--   * 密码只进环境变量，不进命令行、不进报告（报告里回显的 SQL 也不含密码）
--   * SQL 从临时文件读，避免 Windows 命令行引号地狱
local function dbQuery(dbinfo, sql)
  local dir = [[C:\pureland\Release\lua_scripts\acore-boss-smartai\tools\spell-check]]
  local sqlFile = dir .. [[\_spellcheck_query.sql]]
  local f = io.open(sqlFile, 'wb')
  if not f then return nil, '写不了临时 SQL 文件: ' .. sqlFile end
  f:write(sql, '\n')
  f:close()

  local cmd = string.format(
    [[cmd /c "set "MYSQL_PWD=%s" && "%s" --no-defaults -h %s -P %s -u %s -D %s -N -B < "%s" 2>&1"]],
    dbinfo.pass, MYSQL_EXE, dbinfo.host, dbinfo.port, dbinfo.user, dbinfo.db, sqlFile)
  local out, err = popen(cmd)
  os.remove(sqlFile)
  if not out then return nil, err end
  return out
end

local function dbLookup(ids)
  local dbinfo, err = parseDbInfo()
  if not dbinfo then return nil, err end

  local list = table.concat(ids, ',')
  local usage = {}
  local sql = table.concat({
    'SELECT cts.Spell, ct.entry, ct.name',
    'FROM creature_template_spell cts',
    'JOIN creature_template ct ON ct.entry = cts.CreatureID',
    'WHERE cts.Spell IN (' .. list .. ')',
    'ORDER BY cts.Spell, ct.entry;',
  }, ' ')
  local out, perr = dbQuery(dbinfo, sql)
  if not out then return nil, perr end
  if string.find(out, 'ERROR') then return nil, trim(out) end
  for line in string.gmatch(out, '[^\r\n]+') do
    local id, entry, name = string.match(line, '^(%d+)\t(%d+)\t(.*)$')
    if id then
      id = tonumber(id)
      usage[id] = usage[id] or {}
      usage[id][#usage[id] + 1] = { entry = tonumber(entry), name = name }
    end
  end

  -- 顺手查 spell_script_names（表可能不存在，失败就当没有）
  local scripts = {}
  local sql2 = 'SELECT spell_id, ScriptName FROM spell_script_names WHERE spell_id IN ('
    .. list .. ') ORDER BY spell_id;'
  local out2 = dbQuery(dbinfo, sql2)
  if out2 and not string.find(out2, 'ERROR') and not string.find(out2, "doesn't exist") then
    for line in string.gmatch(out2, '[^\r\n]+') do
      local id, sn = string.match(line, '^(%d+)\t(.*)$')
      if id then
        id = tonumber(id)
        scripts[id] = scripts[id] or {}
        scripts[id][#scripts[id] + 1] = sn
      end
    end
  end

  return {
    usage = usage,
    scripts = scripts,
    info = dbinfo,
    sql = sql,
    sql2 = sql2,
    conn = string.format('%s:%s@%s', dbinfo.user, dbinfo.port, dbinfo.host),
  }
end

--------------------------------------------------------------------------------
-- 4. 主流程
--------------------------------------------------------------------------------

local src, rerr = readFile(opts.script)
if not src then die('读不到被审计脚本 ' .. opts.script .. ': ' .. tostring(rerr)) end

local ext, eerr = extract(opts.script, src)
if not ext then die(eerr) end

local dbc, derr = loadDbc(opts.dbc)
if not dbc then die(derr) end

local extById = {}
for _, f in ipairs(ext.findings) do
  extById[f.id] = extById[f.id] or {}
  table.insert(extById[f.id], f)
end
local ids = {}
for id in pairs(extById) do ids[#ids + 1] = id end
table.sort(ids)

local dbdata = nil
if opts.db then
  local res, berr = dbLookup(ids)
  if res then dbdata = res else io.stderr:write('[spell-check] -db 反查失败（跳过）: ' .. tostring(berr) .. '\n') end
end

--------------------------------------------------------------------------------
-- 5. 报告
--------------------------------------------------------------------------------

local function hr(ch)
  io.write(string.rep(ch or '-', 100) .. '\n')
end

io.write('================ Eluna 法术 ID 审计 ================\n')
io.write(string.format('被审计脚本 : %s (%d 字节, %d 行)\n', opts.script, #src, countLines(src, #src)))
io.write(string.format('Spell.dbc  : %s\n', dbc.info.file))
io.write(string.format('  magic=WDBC  headerBytes=%d  fileSize=%d\n', dbc.info.headerBytes, dbc.info.size))
io.write(string.format('  recordCount=%d  fieldCount=%d  recordSize=%d  stringBlockSize=%d\n',
  dbc.info.records, dbc.info.fieldCount, dbc.info.recSize, dbc.info.strSize))
io.write(string.format('  头推算大小 = 20 + %d*%d + %d = %d  -> %s\n',
  dbc.info.records, dbc.info.recSize, dbc.info.strSize, dbc.info.expectSize,
  dbc.info.sizeMatch and '与实际文件大小一致' or '★不一致★'))
io.write(string.format('  解析 ID 数=%d（含重复 ID 行 %d）; 名称字段=%d=%s槽位(slot %d); 抽样语种掩码=0x%X\n',
  dbc.info.parsedIds, dbc.info.idCollisions, dbc.info.nameField, dbc.info.localeName,
  dbc.info.localeSlot, dbc.info.sampleMask))
io.write(string.format('提取方式   : 括号配平定位表区间 + 语法模式精确匹配（顶层预设键枚举 -> skillPools/openingSkills/comboChains；另含 INTERRUPT_SPELL_LIBRARY 与 BOSS_CONFIG 字面量）\n'))
io.write(string.format('            条目分布: skillPools %d 条, openingSkills %d 条, comboChains %d 条, INTERRUPT_SPELL_LIBRARY %d 条\n',
  ext.poolEntries, ext.openingEntries, ext.chainEntries, ext.interruptEntries))
io.write(string.format('解析出预设 : %d 个 [%s]; 提取条目 %d 条; 去重后法术 ID %d 个\n',
  ext.presets, listRoles((function()
    local t = {}
    for _, p in ipairs(ext.presetKeys) do t[p.key] = true end
    return t
  end)()), #ext.findings, #ids))
io.write(string.format('DBC 解析耗时: %s\n', elapsed()))
if opts.verbose then
  io.write('\n---- 提取到的原始条目 ----\n')
  for _, f in ipairs(ext.findings) do
    io.write(string.format('  %-6d %-14s %s  (line %d)\n', f.id, f.name or '-', f.where, f.line))
  end
end

local missing = {}
io.write(string.format('\nDBC 语种槽位结论: 实际填充的槽位 = slot %d (%s)，抽样掩码 0x%X\n',
  dbc.info.localeSlot, dbc.info.localeName, dbc.info.sampleMask))
io.write('  （该项决定 DBC 名称来自哪个语种；本站客户端只在 slot 4/enCN 里有字符串，\n')
io.write('    所以 DBC 名称实际是中文，可与 boss.lua 的中文 name 直接比对。）\n')
io.write('\n---- 逐条明细（调用点） ----\n')
hr('=')
for _, id in ipairs(ids) do
  local rec = dbc.map[id]
  local list = extById[id]
  if not rec then missing[#missing + 1] = id end

  -- boss.lua 里声明的 name 去重
  local uniqName, nameOrder = {}, {}
  for _, f in ipairs(list) do
    if f.name and not uniqName[f.name] then
      uniqName[f.name] = true
      nameOrder[#nameOrder + 1] = f.name
    end
  end
  local scriptName = #nameOrder > 0 and table.concat(nameOrder, ' / ') or '(无)'
  local dbcName = rec and rec.name or nil

  io.write(string.format('[%d] %s  DBC=%s  boss.lua=%s  mask=%s\n',
    id,
    rec and '存在' or '★不存在★',
    dbcName or '(DBC 无此 ID)',
    scriptName,
    rec and string.format('0x%X', rec.mask) or '-'))
  for _, f in ipairs(list) do
    local flag = ''
    if f.name and dbcName and f.name ~= dbcName then
      flag = '   ← 名称与 DBC 不同'
    elseif f.name and not dbcName then
      flag = '   ← DBC 里查不到该 ID'
    end
    local dbn = (opts.db and dbdata) and (function()
      local u = dbdata.usage[id]
      if not u or #u == 0 then return '' end
      local parts = {}
      for _, e in ipairs(u) do parts[#parts + 1] = e.name end
      return '   [creature: ' .. table.concat(parts, ', ') .. ']'
    end)() or ''
    io.write(string.format('      %-46s line %-6d%-18s%s\n', f.where, f.line, f.name or '-', flag .. dbn))
  end
end
hr('=')

local MAX_CREATURES_SHOWN = 8

-- 把 creature 列表压成一行（超长时截断并给出总数）
local function creatureSummary(u)
  if not u or #u == 0 then return '(无任何 creature 使用)' end
  local parts = {}
  for i, e in ipairs(u) do
    if i > MAX_CREATURES_SHOWN then break end
    parts[#parts + 1] = string.format('%s(entry %d)', e.name, e.entry)
  end
  local s = table.concat(parts, ', ')
  if #u > MAX_CREATURES_SHOWN then
    s = s .. string.format(' ... 共 %d 个 creature', #u)
  end
  return s
end

if dbdata then
  io.write('\n---- 数据库反查 (creature_template_spell JOIN creature_template) ----\n')
  io.write('连接(无密码): ' .. dbdata.conn .. '\n')
  io.write('SQL: ' .. dbdata.sql .. '\n')
  local noUse = {}
  for _, id in ipairs(ids) do
    local u = dbdata.usage[id]
    if not u or #u == 0 then
      noUse[#noUse + 1] = id
    end
    io.write(string.format('  %-7d %s\n', id, creatureSummary(u)))
  end
  io.write('\n---- spell_script_names ----\n')
  io.write('SQL: ' .. dbdata.sql2 .. '\n')
  local anyScript = false
  for _, id in ipairs(ids) do
    local s = dbdata.scripts[id]
    if s then
      anyScript = true
      io.write(string.format('  %-7d %s\n', id, table.concat(s, ', ')))
    end
  end
  if not anyScript then io.write('  (所有 ID 都没有 spell_script_names 条目)\n') end
  io.write(string.format('\n无 creature 使用的 ID 共 %d 个: %s\n', #noUse, table.concat(noUse, ', ')))
  io.write(string.format('有 spell_script_names 的 ID 共 %d 个\n',
    (function() local n = 0 for _ in pairs(dbdata.scripts) do n = n + 1 end return n end)()))
end

io.write('\n================ 结论 ================\n')
if #missing == 0 then
  io.write(string.format('OK: %d 个法术 ID 全部能在 Spell.dbc 里找到。\n', #ids))
  io.write(string.format('总耗时 %s\n', elapsed()))
  os.exit(0)
else
  table.sort(missing)
  io.write(string.format('★硬错误: %d 个法术 ID 在 Spell.dbc 里不存在 -> %s\n', #missing, table.concat(missing, ', ')))
  io.write(string.format('总耗时 %s\n', elapsed()))
  os.exit(1)
end
