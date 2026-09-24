-- BOSS.lua
-- 功能：智能BOSS战斗系统
-- 特性：智能目标选择、技能连招、战术移动、环境感知、支持web管理
-- 作者：pureland.fun
--
-- ============================================================================
--  文件结构（按出现顺序；查找配置请直接跳到「配置区」）
-- ----------------------------------------------------------------------------
--   §1 日志系统                  boss.log 轮转 + 文件级 print 遮蔽
--   §2 常量                      本区绑定（库名 / state_key）+ 配置键
--   §3 配置区  ★                所有可调项的默认值（分组）+ 描述表 + 目标注册表
--   §4 数据库表结构自举          本区库（默认 ac_eluna）四张表 + 配置扩展表（列由描述表生成）
--   §5 内容库                    技能池预设 / 强度档位 / 打断法术（非配置项）
--   §6 序列化与 SQL 工具         clamp / 列表与键值文本 / 查询取值助手
--   §7 配置读写                  描述表驱动：LoadBossConfigFromDB / PersistBossConfigToDB
--   §8 运行期状态                内存态（活跃 Boss、AI 状态、贡献统计…）
--   §9 通用工具 / 贡献统计 / 喊话 / 目标选择 / 技能决策 / 战术移动 / 巡逻
--   §10 Boss 生成与管理 / 事件处理 / GM 命令 / 事件注册
--
--  ★ 配置不再散落在脚本各处：所有可调项都在 §3 登记，运行期以数据库为准。
--    表结构、列名、读写方式见 §3 描述表与 §4/§7。
-- ============================================================================
local basePrint = print

-- ========== 日志系统 ==========
-- 用「文件级 local print」遮蔽全局 print，绝不改写 _G.print：
-- 历史版本直接覆盖了全局 print，导致本文件之后加载的所有 Eluna 脚本
-- 的调试输出都被写进 boss.log，控制台反而看不到。
local BOSS_LOG_PATH = "lua_scripts/lua_logs/boss.log"
local BOSS_LOG_MAX_BYTES = 5 * 1024 * 1024

local function RotateBossLog()
    local probe = io.open(BOSS_LOG_PATH, "r")
    if not probe then
        return
    end

    local size = probe:seek("end") or 0
    probe:close()
    if size < BOSS_LOG_MAX_BYTES then
        return
    end

    os.rename(BOSS_LOG_PATH, BOSS_LOG_PATH .. "." .. os.date("%Y%m%d-%H%M%S") .. ".bak")
end

RotateBossLog()
local logFile = io.open(BOSS_LOG_PATH, "a")

local function WriteLog(message)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    if logFile then
        logFile:write("[" .. timestamp .. "] " .. message .. "\n")
        logFile:flush()
    else
        basePrint("[LOG] " .. message)
    end
end

local function BossLog(...)
    local args = {...}
    local message = ""
    for i, v in ipairs(args) do
        if i > 1 then message = message .. "\t" end
        message = message .. tostring(v)
    end
    WriteLog(message)
end

-- 本文件内的 print 全部走日志，不再影响其他脚本
local print = BossLog

basePrint(">>Script:BOSS SmartAI loading...OK")

-- ========== §2 常量（不属于可调配置，改动需随版本发布） ==========
-- 日志路径/轮转上限在 §1 里另有常量：日志先于数据库可用，不能落库。
--
-- ★ 多区部署（多个 realm 共用一套 auth）：「本区绑定」就在下面两行。
--   一台机器上每个区各跑一份 worldserver + 一份 boss.lua，各区的配置 / 运行态 / 事件 /
--   贡献必须落在**各自的库**里，否则两个区会互相覆盖活动配置（面板上表现为"改了没生效"
--   或"看到的是别的区的 Boss"）。所以同一个 boss.lua 部署到不同区时，只改这两行：
--
--     80 区（历史库名，保持不动）  BOSS_DB_NAME = "ac_eluna"
--     70 区                        BOSS_DB_NAME = "ac_eluna70"
--     删档测试区                    BOSS_DB_NAME = "ac_eluna_test"
--
--   BOSS_RUNTIME_KEY / BOSS_CONFIG_KEY 目前各区都用 "current"；只有当两个区**共用同一个库**
--   时才需要给其中一个区换 key（不推荐，事件/贡献表没有 state_key 列，会串在一起）。
--
--   面板侧必须与这里一致，否则面板读写的是别的区：
--     AGMP config/boss.php → server_overrides[<区服索引>].custom_db_name / .runtime_key
--   用 tools/deploy-realm.ps1 部署时会自动改写这两行并打印对应的面板配置片段。
--
--   启动时本脚本会把生效的绑定写进本区日志（lua_scripts/lua_logs/boss.log），
--   与面板页头显示的库名对照即可确认没有串区。
local BOSS_DB_NAME = "ac_eluna"                              -- 本区：配置与运行态所在库
local BOSS_RUNTIME_KEY = "current"                           -- boss_activity_runtime 的 state_key
local BOSS_CONFIG_KEY = "current"                            -- 配置表的 state_key
local BOSS_DECIMAL_SCALE = 100                               -- 小数落库缩放（倍率/体型 ×100 存 INT）
local BOSS_MAIN_TABLE = "boss_activity_config"               -- 与 AGMP 面板共享的配置表
local BOSS_EXT_TABLE = "boss_activity_config_ext"            -- 脚本私有配置表（面板用 upsert 只改提交的列，不会删行重置）
local BOSS_RUNTIME_TABLE = "boss_activity_runtime"           -- 运行态（活跃 Boss 指针/时间戳）
local BOSS_EVENT_TABLE = "boss_activity_events"              -- 事件流水
local BOSS_CONTRIBUTOR_TABLE = "boss_activity_contributors"  -- 贡献快照
local BOSS_SCHEMA_READY = false

-- 多区部署自检：把本区绑定写进本区日志。面板页头也会显示它读的是哪个库，
-- 两处对不上就说明部署时库名没改成该区的（§2 顶部）。
print(string.format("[BOSS] 本区绑定: db=%s configKey=%s runtimeKey=%s",
    BOSS_DB_NAME, BOSS_CONFIG_KEY, BOSS_RUNTIME_KEY))

-- 【前置声明】以下名字在文件后段才赋值。Lua 只在「声明之后」的代码里把它们当 local，
-- 放在前面使用的函数会解析成全局变量（运行期为 nil，静默失效）。
local BuildNearbyPlayerList
local InsertBossEvent
local SetActiveBoss
local ClearActiveBoss
local IsManagedBossEntry
local DEFAULT_SPAWN_POINTS
local activeBossInfo
local RegisterBossEventsForEntry
local RegisterBossEventsForCandidates
local BossSendMessage
local BossReply

local function BossNow()
    local success, gameTime = pcall(function() return GetGameTime() end)
    if success and gameTime ~= nil then
        local numericTime = tonumber(tostring(gameTime))
        if numericTime ~= nil then
            return numericTime
        end
    end

    return os.time()
end

-- ============================================================================
--  §3 配置区 ★ 本脚本唯一的配置文件
-- ----------------------------------------------------------------------------
--  下面「默认值」只在数据库里还没有这一行时使用（引导写入 INSERT IGNORE）；
--  一旦落库，之后每次加载都以数据库为准，改默认值不会影响已上线的服务器。
--
--  两张表（详见 §7 读写实现）：
--    ac_eluna.boss_activity_config      —— 与 AGMP 面板共享的列（面板「基础配置」Tab）
--    ac_eluna.boss_activity_config_ext  —— 脚本私有配置：喊话 / 嘲讽 / AI 节奏 /
--                                          阶段阈值 / 巡逻 / 小怪 / 援军模板 / 职业 / 受管模板
--                                          （面板「扩展配置」Tab，按二级 Tab 分组展示）
--  为什么要拆表：AGMP 保存主表时用 REPLACE INTO 整行重写，凡不在它列清单里的列都会被
--  重置为建表默认值；脚本私有配置放在 ext 表里，面板只能用 upsert 逐列改，删列/换列都
--  不会把脚本新增的配置清掉。
--
--  分组（descriptor.group，`.boss config show <group>` 可查看当前生效值）：
--    identity   Boss 身份      basic    基础属性       ally    友方援军
--    yells      喊话           taunts   战斗嘲讽       ai      AI 节奏
--    phase      战斗阶段       patrol   巡逻           minion  小怪与援军
--    skill      技能池         respawn  刷新间隔       spawnpoints 刷新点
--    helper     援军模板       reward   奖励           class   职业
--    tier       受管模板
--
--  改配置：① AGMP 面板（基础配置 + 扩展配置两个 Tab）② 直接改数据库（两张表）
--          ③ 改这里（只影响「数据库里还没有这一行」的全新部署）
--          改完执行 `.boss config reload` 热加载，或重启 worldserver。
-- ============================================================================

-- ---- [identity] Boss 身份：活动 Boss 的模板 entry 与显示名 ----
-- 这是默认项；启动时会以 ac_eluna.boss_activity_config 的 boss_entry/boss_name 覆盖。
-- 强度档位 = entry：190090 入门 / 190091 标准 / 190092 困难 / 190093 团本（见 [tier]）。
local BOSS_CANDIDATES = {
    {entry = 190090, name = "送财童子"},
}

-- ---- [basic] 基础属性 / 光环，[ally] 友方援军，[yells] 喊话，[taunts] 战斗嘲讽，
-- ---- [ai] AI 节奏，[patrol] 巡逻，[minion] 小怪，[skill] 技能池，[respawn] 刷新间隔 ----
-- 说明：Boss/小怪属性、喊话与嘲讽文案、巡逻与小怪 AI 节奏、技能池选择都能落库，
--       面板列与 ext 列的对应关系见下面的 BOSS_CONFIG_SCHEMA_* 描述表。
local BOSS_CONFIG = {
    -- ---- [basic] 基础属性 ----
    bossLevel = 83,                    -- Boss等级（影响基础属性）
    bossScale = 5,                     -- Boss体型缩放倍数（1为正常大小）
    bossHealthMultiplier = 20,        -- Boss血量倍率（基础血量×此值）
    
    -- ---- [basic] Boss 自带 BUFF ----
    -- 21562=真言术：韧  1126=野性印记  467=献祭光环  20217=王者祝福
    bossAuras = {21562, 1126, 467, 20217},
    
    -- ---- [ally] 友方援军（米尔豪斯） ----
    allyLevel = 20,                    -- 友方援军（米尔豪斯）等级
    allyHealthMultiplier = 1.5,        -- 友方援军血量倍率
    
    -- ---- [yells] 喊话（支持 {BOSS_NAME} 占位符） ----
    bossSpawnYell = " 让 {BOSS_NAME} 来打爆这个垃圾服务器！",  -- 生成时喊话
    bossEnterCombatYell = "可恶，竟敢对我动手！",              -- 进入战斗喊话
    allySpawnYell = "保卫净土的时候到了！援护勇士，击倒这恶徒！", -- 友方援军喊话
    bossRespawnYell = "{BOSS_NAME}再临！",                     -- 重生时喊话
    bossGMSpawnYell = "小虫子们，来战！",                      -- GM命令生成时喊话
    
    -- ---- [taunts] 战斗嘲讽 ----
    -- 支持占位符: {PLAYER_NAME}=玩家名, {CLASS}=职业名, {SPELL}=技能名
    combatTaunts = {
        -- 血量阶段喊话
        phase2Yells = {  -- 进入阶段2 (70%)
            "哈哈哈，热身结束了！",
            "你们就这点本事吗？太让我失望了！",
            "现在，游戏正式开始！",
            "不错嘛，值得我认真一点！",
        },
        phase3Yells = {  -- 进入阶段3 (20%)
            "你们激怒我了！准备受死吧！",
            "这是你们逼我的！毁灭吧！",
            "我的力量...正在觉醒！",
            "颤抖吧，凡人！感受真正的恐惧！",
        },
        criticalHpYells = {  -- 血量低于10%
            "不...不可能！",
            "该死...我不会输给你们这些蝼蚁！",
            "就算死，我也要拉个垫背的！",
        },
        
        -- 技能施放喊话
        skillCastYells = {
            ["烈焰喷涌"] = "烈焰吞噬一切！",
            ["闪电链"] = "电流串起你们！",
            ["闪电新星"] = "别站这么近，统统导电！",
            ["冰霜新星"] = "冻在原地！",
            ["战车冲撞"] = "撞翻你们！",
            ["熔化护甲"] = "你的护甲像纸一样！",
            ["音波尖啸"] = "奥能爆裂！",
            ["岩石碎片"] = "碎石会自己找上你们！",
            ["践踏"] = "站稳了，地面要塌了！",
            ["穿刺"] = "这一击，穿心！",
            ["穿刺顺劈"] = "近身就是找死！",
            ["骇人咆哮"] = "在恐惧里四散奔逃吧！",
            ["剧毒新星"] = "毒雾会淹没你们！",
            ["毒液箭"] = "这一箭，带毒！",
            ["灼烧吐息"] = "呼吸之间，尽是焦土！",
            ["烈焰余烬"] = "脚下的火，可不会等你！",
            ["陨星拳"] = "拳头落下时，别怪我没提醒！",
            ["冰冻之地"] = "脚下结冰了，快动！",
            ["白茫"] = "看不见路？那就死在风雪里！",
            ["剧毒废料"] = "废料漫开了，别往里踩！",
            ["死亡凋零"] = "死亡会从你们脚下蔓延！",
            ["暗影冲击"] = "黑暗正从天上砸下来！",
            ["冰焰"] = "冰与火的轨迹，会把你们切开！",
            ["软泥抛掷"] = "接住这团烂东西吧！",
            ["无面者印记"] = "被标记的人，离队友远一点！",
            ["骨刃分劈"] = "靠近我的人，全都一起受死！",
            ["恐惧尖啸"] = "尖叫会撕开你们的阵型！",
            ["冰霜箭雨"] = "寒霜会覆盖你们所有人！",
            ["无意义之触"] = "你的存在，连威胁都算不上！",
            ["灼烧烈焰"] = "烈焰会把你们的法术和护甲一起烧穿！",
            ["哨兵震爆"] = "法术还没读完？先吃下这一下！",
            ["黑暗奔涌"] = "黑暗在我体内暴涨，你们挡不住！",
            ["暗影陷阱"] = "别站那儿！",
            ["死亡符文"] = "别踩符文！",
            ["吞噬烈焰"] = "火舌舔地！",
            ["烈焰升腾"] = "连环轰炸，享受吧！",
            ["碎石轰击"] = "石屑乱飞！",
            ["冰霜炸弹"] = "碎冰穿心！",
            ["冰霜斩击"] = "灼烧你的灵魂！",
            ["灵魂风暴"] = "黑暗膨胀！",
            ["寒冰巨弹"] = "脚下留神！",
        },
        
        -- 切换目标嘲讽
        targetSwitchYells = {
            "{PLAYER_NAME}，下一个就是你了！",
            "{PLAYER_NAME}，你以为躲得掉吗？",
            "{CLASS}，让我看看你的本事！",
            "嘿，{PLAYER_NAME}，来陪我玩玩！",
            "换个人欺负一下，就你了{PLAYER_NAME}！",
        },
        
        -- 成功打断嘲讽
        interruptYells = {
            "读条被打断的感觉如何，{PLAYER_NAME}？",
            "想施法？门都没有！",
            "你的技能CD了，我的可没有！",
            "打断成功！这就是职业素养！",
        },
        
        -- 击杀玩家嘲讽
        killYells = {
            "{PLAYER_NAME}，太弱了！",
            "下一个！",
            "这就是挑战我的下场！",
            "{CLASS}也不过如此嘛！",
            "灵魂归我了，{PLAYER_NAME}！",
            "又解决一个，还有谁？",
        },
        
        -- 低血量玩家嘲讽（目标血量<30%）
        lowHpYells = {
            "{PLAYER_NAME}，你快不行了，放弃吧！",
            "血量这么低还敢站在我面前？",
            "{PLAYER_NAME}，需要我叫救护车吗？",
            "再补一刀就死了，真可怜！",
        },
        
        -- 击杀治疗职业特殊嘲讽
        healerKillYells = {
            "治疗死了，你们还能撑多久？",
            "没奶了，等死吧你们！",
            "第一个杀治疗，这是常识！",
        },
        
        -- 召唤援军喊话
        summonMinionYells = {
            "我的仆从们，上！",
            "以多欺少？不，这叫战术！",
            "小家伙们，陪他们玩玩！",
        },
        
        -- 连招喊话
        comboYells = {
            ["控制链"] = "别想跑！",
            ["反治疗链"] = "治疗？我专治各种治疗！",
            ["爆发链"] = "见识一下真正的力量！",
            ["追击链"] = "风筝我？做梦！",
            ["眩晕链"] = "动不了了吧？",
            ["减速爆发"] = "减速，然后毁灭！",
            ["雷岩合围"] = "雷霆和山岩，一起压垮你们！",
            ["重压处决"] = "跪下，然后去死！",
            ["恐惧清场"] = "跑吧，跑到尽头也是死！",
            ["灰烬逼走"] = "落脚点？我全给你们烧掉！",
            ["烈拳处决"] = "挨过这拳，再谈活命！",
            ["焚场风暴"] = "全场着火，看你们怎么躲！",
            ["冰雷点杀"] = "冻住你，再劈碎你！",
            ["白茫封场"] = "风雪一起落下，谁都别想稳站！",
            ["寒毒压溃"] = "又冷又毒，你们撑不住的！",
            ["毒刃收口"] = "挂上毒，再慢慢收割！",
            ["毒雾驱散"] = "散开？毒雾会替我追上你们！",
            ["猎杀终曲"] = "逃得再远，也只是最后一段路！",
            ["墓地封锁"] = "地上、天上、前面，全是死路！",
            ["腐蚀点杀"] = "标记已经落下，你逃不掉！",
            ["轰炸终曲"] = "最后这轮轰炸，把你们全部埋掉！",
            ["碎阵压锋"] = "先碎掉你们前排，再碾过去！",
            ["破法齐射"] = "法师们，抬头看看是谁在猎杀你们！",
            ["黑潮封咏"] = "黑潮已起，谁都别想完整读完一个法术！",
        },
        
        -- 战斗时间过长嘲讽
        longCombatYells = {
            "你们是在给我挠痒痒吗？",
            "战斗拖得越久，你们越没胜算！",
            "我的耐心是有限的！",
        },
    },
    
    -- ---- [taunts] 喊话冷却与触发概率 ----
    tauntCooldown = 8,
    
    -- 随机喊话概率（%）
    randomTauntChance = 15,
    
    -- ---- [respawn] 刷新间隔 ----
    respawnTimeMinutes = 10,            -- Boss重生间隔（分钟）
    
    -- ---- [minion] 小怪数量（进入战斗时召唤） ----
    minionCountMin = 1,                -- 进入战斗时召唤援军数量（最小）
    minionCountMax = 2,                -- 进入战斗时召唤援军数量（最大）
    
    -- ---- [ai] AI 决策节奏 ----
    aiUpdateInterval = 1500,           -- AI决策间隔（毫秒），值越小反应越快

    -- ---- [phase] 战斗阶段与触发阈值 ----
    -- 血量阶段：> phase2 为一阶段，(phase3, phase2] 为二阶段，<= phase3 为三阶段
    phase2HpThreshold = 70,            -- 进入二阶段的血量百分比
    phase3HpThreshold = 20,            -- 进入三阶段的血量百分比
    criticalHpThreshold = 10,          -- 触发「濒死嘲讽」的血量百分比
    lowHpTauntThreshold = 30,          -- 对低血量目标嘲讽的触发线（目标血量%）
    lowHpTauntCooldownMs = 20000,      -- 低血量目标嘲讽冷却（毫秒）
    longCombatTauntIntervalMs = 60000, -- 战斗时长累计多少毫秒做一次随机嘲讽
    targetReevalLoops = 3,             -- 每 N 次 AI 循环重新评估一次目标
    phase2SummonCountMin = 1,          -- 二阶段召唤小怪数量（最小）
    phase2SummonCountMax = 2,          -- 二阶段召唤小怪数量（最大）
    phase3SummonCount = 2,             -- 三阶段召唤小怪数量
    phase2SpellId = 1044,              -- 二阶段自身法术（1044=自由祝福，0=不施放）
    phase3SpellId = 8599,              -- 三阶段自身法术（8599=狂暴，0=不施放）

    -- ---- [patrol] 巡逻 ----
    patrolEnabled = true,              -- Boss 脱战时是否在刷新点附近巡逻
    patrolRadius = 50,                 -- 巡逻随机移动半径（码）
    patrolLeashRadius = 100,            -- 巡逻允许偏离刷新点的最大半径（码）
    patrolInterval = 9000,             -- 巡逻检查间隔（毫秒）

    -- ---- [minion] 小怪 AI ----
    minionAiEnabled = true,            -- 召唤小怪是否启用脚本智能行为
    minionAiInterval = 1800,           -- 小怪智能决策间隔（毫秒）
    minionTargetRange = 40,            -- 小怪搜索玩家范围（码）

    -- ---- [skill] 技能池选择 ----
    -- 可选: storm_siege / ember_storm / frost_whiteout / venom_pursuit / grave_bombard / spellbreak_bulwark
    skillPreset = "storm_siege",

    -- ---- [skill] 技能池强度档位 ----
    -- 可选: easy / standard / hard / raid
    skillDifficulty = "standard",
}

-- ---- [spawnpoints] 刷新点：Boss 重生时随机选取的坐标 ----
-- mapId: 地图ID（571=诺森德）；x/y/z: 坐标。
-- 落库列：boss_activity_config.spawn_points_text（每行 "mapId,x,y,z"）；
-- 该列为空/无有效行时回退到下面这份默认点。
local function CloneSpawnPoints(points)
    local cloned = {}
    if type(points) ~= "table" then
        return cloned
    end

    for _, point in ipairs(points) do
        if type(point) == "table" then
            table.insert(cloned, {
                mapId = tonumber(point.mapId) or 0,
                x = tonumber(point.x) or 0,
                y = tonumber(point.y) or 0,
                z = tonumber(point.z) or 0,
            })
        end
    end

    return cloned
end

local SPAWN_POINTS = {
    {mapId = 571, x = 4353.573, y = -4411.8877, z = 151.3909},   -- 灰熊丘陵月溪旅营地西南
    {mapId = 571, x = 1246.5499, y = -4311.5073, z = 144.944},   -- 嚎风峡湾乌堡西
    {mapId = 571, x = 8093.9595, y = 2827.9702, z = 553.28033},  -- 冰冠冰川哭泣采掘场
    {mapId = 571, x = 6689.081, y = 500.4722, z = 401.2109},     -- 冰冠冰川天灾城
    {mapId = 571, x = 2975.7952, y = 5373.769, z = 62.121082},   -- 北风苔原
    {mapId = 571, x = 6005.9688, y = 5612.9023, z = -71.26319},  -- 索拉查盆地生命守卫者之路
    {mapId = 571, x = 8355.781, y = -44.54596, z = 815.31604},   -- 风暴峭壁雪流平原
}

DEFAULT_SPAWN_POINTS = CloneSpawnPoints(SPAWN_POINTS)

-- ---- [helper] 援军模板 entry ----
-- HELPER_ENTRIES: Boss进入战斗时召唤的敌方援军（小怪）
local HELPER_ENTRIES = {16244, 15976, 16018, 16165}

-- ALLY_HELPER_ENTRY: 友方援军（帮助玩家攻击Boss）
-- 20977 = 米尔豪斯·法力风暴
local ALLY_HELPER_ENTRY = 20977

-- ---- [reward] 奖励 ----
-- 所有概率值为0-100的整数，表示百分比
local REWARD_PROBABILITIES = {
    classRewardChance = 60,    -- 职业专属装备奖励概率（%）
    formulaRewardChance = 10,  -- 公式奖励概率（%）
    mountRewardChance = 15,    -- 坐骑奖励概率（%）

    -- 【保底奖励配置】
    -- 所有参与战斗的玩家均可获得（不限制人数）
    guaranteedRewardEnabled = true,      -- 是否启用保底奖励
    guaranteedRewardNotify = true,       -- 是否发送获得通知

    -- 【随机奖励人数配置】
    maxRandomRewardPlayers = 3,          -- 最多多少名玩家可获得随机奖励（原奖励体系）
    participationRange = 80,             -- 统计战斗贡献时使用的有效范围（码）
    damageWeight = 100,                  -- 输出贡献权重
    healingWeight = 80,                  -- 治疗贡献权重
    threatWeight = 35,                   -- 承伤/仇恨存在感权重
    presenceWeight = 10,                 -- 在场活跃权重（仅作微调，不单独决定资格）
    killWeight = 3,                      -- 最后一击加权
    randomRewardMode = "weighted",      -- weighted=按贡献加权；random=均匀随机

    -- 验证函数：确保概率值在0-100范围内
    validate = function(self)
        local function clamp(value)
            return math.max(0, math.min(100, value))
        end
        self.classRewardChance = clamp(self.classRewardChance)
        self.formulaRewardChance = clamp(self.formulaRewardChance)
        self.mountRewardChance = clamp(self.mountRewardChance)
        self.damageWeight = math.max(0, self.damageWeight or 0)
        self.healingWeight = math.max(0, self.healingWeight or 0)
        self.threatWeight = math.max(0, self.threatWeight or 0)
        self.presenceWeight = math.max(0, self.presenceWeight or 0)
        self.killWeight = math.max(0, self.killWeight or 0)
        self.participationRange = math.max(20, self.participationRange or 80)
        if self.randomRewardMode ~= "random" then
            self.randomRewardMode = "weighted"
        end
        return self
    end
}
REWARD_PROBABILITIES:validate()

-- 【奖励物品池】
-- REWARD_ITEMS: 必掉的（100%概率给一个）
local REWARD_ITEMS = {38082, 41600, 51809, 34067}

-- REWARD_FORMULAS: 公式奖励（概率触发，见REWARD_PROBABILITIES.formulaRewardChance）
-- 45059=附魔公式  44491=附魔公式
local REWARD_FORMULAS = {45059, 44491}

-- REWARD_MOUNTS: 稀有坐骑（概率触发，见REWARD_PROBABILITIES.mountRewardChance）
local REWARD_MOUNTS = {32768,30480,13335,37719,49282,49290,19872,33977,33809,37828,43963,54068,33183,33189,35513,43964,19902,43963,46109,50250,49286,30609,54860,37012}

-- REWARD_GUARANTEED: 所有参与者的保底奖励配置
local REWARD_GUARANTEED = {
    itemId = 40753,
    count = 2,
}

-- REWARD_GOLD: 随机奖励获奖者的金币奖励配置（单位：铜）
local REWARD_GOLD = {
    minCopper = 30000,
    maxCopper = 50000,
}

-- ---- [class] 职业 ----
-- 【职业类型定义】用于AI目标选择策略
-- melee=近战（优先度低）  ranged=远程（优先度中）  healer=治疗（优先度高）
-- 第三阶段会优先攻击healer类型
local CLASS_TYPES = {
    [1] = "melee",    -- 战士
    [2] = "healer",   -- 圣骑士（可切换为近战，但AI视为治疗威胁）
    [3] = "ranged",   -- 猎人
    [4] = "melee",    -- 盗贼
    [5] = "healer",   -- 牧师
    [6] = "melee",    -- 死亡骑士
    [7] = "healer",   -- 萨满（可切换，AI视为治疗威胁）
    [8] = "ranged",   -- 法师
    [9] = "ranged",   -- 术士
    [11] = "healer",  -- 德鲁伊（可切换，AI视为治疗威胁）
}

-- 【职业专属奖励】按职业分类的装备奖励
-- 键=职业ID（1=战士, 2=圣骑, 3=猎人, 4=盗贼, 5=牧师, 6=DK, 7=萨满, 8=法师, 9=术士, 11=德鲁伊）
-- 值=装备ID数组，随机选择一个
local CLASS_REWARD_ITEMS = {
    [1] = {40611,40614,40617,40620,40623,40256,40371,39257,40431,40257,40372}, -- 战士
    [2] = {40622,40619,40616,40613,40610,40256,40371,39257,40431,40257,40372,40258,40382,39299}, -- 圣骑士
    [3] = {40611,40614,40617,40620,40623,40256,40371,39257,40431}, -- 猎人
    [4] = {40624,40621,40618,40615,40612,40256,40371,39257,40431}, -- 盗贼
    [5] = {40622,40619,40616,40613,40610,40255,40373,40432,40258,40382,39299}, -- 牧师
    [6] = {40624,40621,40618,40615,40612,40256,40371,39257,40431,40257,40372}, -- 死亡骑士
    [7] = {40611,40614,40617,40620,40623,40255,40373,40432,40256,40371,39257,40431,40258,40382,39299}, -- 萨满
    [8] = {40624,40621,40618,40615,40612,40255,40373,40432,39299}, -- 法师
    [9] = {40622,40619,40616,40613,40610,40255,40373,40432,39299}, -- 术士
    [11] = {40624,40621,40618,40615,40612,40255,40373,40432,40256,40371,39257,40431,40257,40372,40258,40382,39299}, -- 德鲁伊
}

-- ---- [tier] 受管模板 entry ----
-- 本模块自带强度档位模板：190090 入门 / 190091 标准 / 190092 困难 / 190093 团本。
-- 这些 entry 一律注册 creature 事件，保证面板切档后旧档位残留的 Boss 仍可被清理与结算。
local BOSS_TIER_ENTRIES = {190090, 190091, 190092, 190093}

-- ============================================================================
--  配置分组元数据（供 `.boss config show` 展示，与描述表的 group 字段一一对应）
-- ============================================================================
local BOSS_CONFIG_GROUPS = {
    identity = "Boss 身份",
    basic = "基础属性",
    ally = "友方援军",
    yells = "喊话",
    taunts = "战斗嘲讽",
    ai = "AI 节奏",
    phase = "战斗阶段",
    patrol = "巡逻",
    minion = "小怪与援军",
    skill = "技能池",
    respawn = "刷新间隔",
    spawnpoints = "刷新点",
    helper = "援军模板",
    reward = "奖励",
    class = "职业",
    tier = "受管模板",
}

local BOSS_CONFIG_GROUP_ORDER = {
    "identity", "basic", "ally", "yells", "taunts", "ai", "phase", "patrol", "minion",
    "skill", "respawn", "spawnpoints", "helper", "reward", "class", "tier",
}

-- ============================================================================
--  配置项 → 数据库列 描述表（配置与数据库之间唯一的映射来源）
-- ----------------------------------------------------------------------------
--  字段说明：
--    group  分组（BOSS_CONFIG_GROUPS 的键）
--    column 数据库列名
--    kind   取值类型，决定序列化/解析方式：
--             int           整数
--             bool          0/1 布尔
--             scaled        小数（库内 ×BOSS_DECIMAL_SCALE 存 INT）
--             text          文本，允许为空（空 = 关闭该喊话）
--             text_keep     文本，空字符串视为「未配置」→ 保留当前值
--             intlist       正整数列表 "1,2,3"
--             lines         多行文本 ↔ 字符串数组（一行一条）
--             keyedlines    多行 "键=值" ↔ 字符串映射
--             keyedword     同 keyedlines（值为短标识，如职业类型）
--             keyedintlist  多行 "键=1,2,3" ↔ 数组映射
--             spawnpoints   多行 "mapId,x,y,z" ↔ 坐标数组
--    target 运行期配置容器名（见下面的 CONFIG_TARGETS）
--    key    容器内的字段名；整表容器（列表类）留空
--    min/max 数值边界（int/scaled 用；与旧版手写 clamp 完全一致）
--    ddl    ext 表的列定义（主表列定义见 §4 的 CREATE TABLE，不能随意改）
--    keepDefaultWhenEmpty  列表/映射解析为空时保留文件内默认值
-- ============================================================================

-- 主表：与 AGMP 面板共享的列。列顺序必须与建表语句/旧版 INSERT 一致，
-- 面板读写在 AGMP 的 BossRepository.php：读取只 SELECT 自己认识的列，
-- 保存用 REPLACE INTO 整行重写——所以面板不认识的列不要加在主表上（放 ext 表）。
local BOSS_CONFIG_SCHEMA_MAIN = {
    -- identity
    { group = "identity", column = "boss_entry", kind = "int", min = 1, max = 2000000,
      target = "BOSS_CANDIDATES", key = "entry" },
    { group = "identity", column = "boss_name", kind = "text_keep",
      target = "BOSS_CANDIDATES", key = "name" },
    -- basic
    { group = "basic", column = "boss_level", kind = "int", min = 1, max = 255,
      target = "BOSS_CONFIG", key = "bossLevel" },
    { group = "basic", column = "boss_scale_scaled", kind = "scaled", min = 10, max = 5000,
      target = "BOSS_CONFIG", key = "bossScale" },
    { group = "basic", column = "boss_health_multiplier_scaled", kind = "scaled", min = 10, max = 200000,
      target = "BOSS_CONFIG", key = "bossHealthMultiplier" },
    { group = "basic", column = "boss_auras_text", kind = "intlist",
      target = "BOSS_CONFIG", key = "bossAuras" },
    -- ally
    { group = "ally", column = "ally_level", kind = "int", min = 1, max = 255,
      target = "BOSS_CONFIG", key = "allyLevel" },
    { group = "ally", column = "ally_health_multiplier_scaled", kind = "scaled", min = 10, max = 200000,
      target = "BOSS_CONFIG", key = "allyHealthMultiplier" },
    -- respawn
    { group = "respawn", column = "respawn_time_minutes", kind = "int", min = 1, max = 1440,
      target = "BOSS_CONFIG", key = "respawnTimeMinutes" },
    -- minion
    { group = "minion", column = "minion_count_min", kind = "int", min = 0, max = 20,
      target = "BOSS_CONFIG", key = "minionCountMin" },
    { group = "minion", column = "minion_count_max", kind = "int", min = 0, max = 20,
      target = "BOSS_CONFIG", key = "minionCountMax" },
    -- skill
    { group = "skill", column = "skill_preset", kind = "text_keep",
      target = "BOSS_CONFIG", key = "skillPreset" },
    { group = "skill", column = "skill_difficulty", kind = "text_keep",
      target = "BOSS_CONFIG", key = "skillDifficulty" },
    -- reward
    { group = "reward", column = "guaranteed_reward_enabled", kind = "bool",
      target = "REWARD_PROBABILITIES", key = "guaranteedRewardEnabled" },
    { group = "reward", column = "guaranteed_reward_notify", kind = "bool",
      target = "REWARD_PROBABILITIES", key = "guaranteedRewardNotify" },
    { group = "reward", column = "max_random_reward_players", kind = "int", min = 0, max = 100,
      target = "REWARD_PROBABILITIES", key = "maxRandomRewardPlayers" },
    { group = "reward", column = "class_reward_chance", kind = "int", min = 0, max = 100,
      target = "REWARD_PROBABILITIES", key = "classRewardChance" },
    { group = "reward", column = "formula_reward_chance", kind = "int", min = 0, max = 100,
      target = "REWARD_PROBABILITIES", key = "formulaRewardChance" },
    { group = "reward", column = "mount_reward_chance", kind = "int", min = 0, max = 100,
      target = "REWARD_PROBABILITIES", key = "mountRewardChance" },
    { group = "reward", column = "random_reward_mode", kind = "text_keep",
      target = "REWARD_PROBABILITIES", key = "randomRewardMode" },
    { group = "reward", column = "participation_range", kind = "int", min = 20, max = 500,
      target = "REWARD_PROBABILITIES", key = "participationRange" },
    { group = "reward", column = "damage_weight", kind = "int", min = 0, max = 10000,
      target = "REWARD_PROBABILITIES", key = "damageWeight" },
    { group = "reward", column = "healing_weight", kind = "int", min = 0, max = 10000,
      target = "REWARD_PROBABILITIES", key = "healingWeight" },
    { group = "reward", column = "threat_weight", kind = "int", min = 0, max = 10000,
      target = "REWARD_PROBABILITIES", key = "threatWeight" },
    { group = "reward", column = "presence_weight", kind = "int", min = 0, max = 10000,
      target = "REWARD_PROBABILITIES", key = "presenceWeight" },
    { group = "reward", column = "kill_weight", kind = "int", min = 0, max = 10000,
      target = "REWARD_PROBABILITIES", key = "killWeight" },
    { group = "reward", column = "guaranteed_item_id", kind = "int", min = 0, max = 2000000,
      target = "REWARD_GUARANTEED", key = "itemId" },
    { group = "reward", column = "guaranteed_item_count", kind = "int", min = 0, max = 10000,
      target = "REWARD_GUARANTEED", key = "count" },
    { group = "reward", column = "gold_min_copper", kind = "int", min = 0, max = 2000000000,
      target = "REWARD_GOLD", key = "minCopper" },
    { group = "reward", column = "gold_max_copper", kind = "int", min = 0, max = 2000000000,
      target = "REWARD_GOLD", key = "maxCopper" },
    { group = "reward", column = "reward_items_text", kind = "intlist",
      target = "REWARD_ITEMS" },
    { group = "reward", column = "reward_formulas_text", kind = "intlist",
      target = "REWARD_FORMULAS" },
    { group = "reward", column = "reward_mounts_text", kind = "intlist",
      target = "REWARD_MOUNTS" },
    -- spawnpoints
    { group = "spawnpoints", column = "spawn_points_text", kind = "spawnpoints",
      target = "SPAWN_POINTS" },
}

-- 扩展表：脚本私有配置。面板（「扩展配置」Tab）会 upsert 这些列，但列定义仍以本表为准：
-- 加配置 = 在默认值区加一个字段 + 在这里加一行（建表语句、补列、读写会自动跟着变），
-- 面板侧再加同样的列/文案即可编辑（见 AGMP config/boss.php 的 ext_fields）。
local BOSS_CONFIG_SCHEMA_EXT = {
    -- yells
    { group = "yells", column = "boss_spawn_yell", kind = "text", ddl = "VARCHAR(255) NOT NULL DEFAULT ''",
      target = "BOSS_CONFIG", key = "bossSpawnYell" },
    { group = "yells", column = "boss_enter_combat_yell", kind = "text", ddl = "VARCHAR(255) NOT NULL DEFAULT ''",
      target = "BOSS_CONFIG", key = "bossEnterCombatYell" },
    { group = "yells", column = "ally_spawn_yell", kind = "text", ddl = "VARCHAR(255) NOT NULL DEFAULT ''",
      target = "BOSS_CONFIG", key = "allySpawnYell" },
    { group = "yells", column = "boss_respawn_yell", kind = "text", ddl = "VARCHAR(255) NOT NULL DEFAULT ''",
      target = "BOSS_CONFIG", key = "bossRespawnYell" },
    { group = "yells", column = "boss_gm_spawn_yell", kind = "text", ddl = "VARCHAR(255) NOT NULL DEFAULT ''",
      target = "BOSS_CONFIG", key = "bossGMSpawnYell" },
    -- taunts
    { group = "taunts", column = "taunt_cooldown_seconds", kind = "int", min = 1, max = 3600,
      ddl = "INT NOT NULL DEFAULT 8", target = "BOSS_CONFIG", key = "tauntCooldown" },
    { group = "taunts", column = "random_taunt_chance", kind = "int", min = 0, max = 100,
      ddl = "INT NOT NULL DEFAULT 15", target = "BOSS_CONFIG", key = "randomTauntChance" },
    { group = "taunts", column = "taunt_phase2_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "phase2Yells" },
    { group = "taunts", column = "taunt_phase3_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "phase3Yells" },
    { group = "taunts", column = "taunt_critical_hp_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "criticalHpYells" },
    { group = "taunts", column = "taunt_skill_cast_yells_text", kind = "keyedlines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "skillCastYells" },
    { group = "taunts", column = "taunt_target_switch_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "targetSwitchYells" },
    { group = "taunts", column = "taunt_interrupt_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "interruptYells" },
    { group = "taunts", column = "taunt_kill_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "killYells" },
    { group = "taunts", column = "taunt_low_hp_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "lowHpYells" },
    { group = "taunts", column = "taunt_healer_kill_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "healerKillYells" },
    { group = "taunts", column = "taunt_summon_minion_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "summonMinionYells" },
    { group = "taunts", column = "taunt_combo_yells_text", kind = "keyedlines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "comboYells" },
    { group = "taunts", column = "taunt_long_combat_yells_text", kind = "lines", ddl = "TEXT NULL",
      target = "TAUNTS", key = "longCombatYells" },
    -- ai
    { group = "ai", column = "ai_update_interval_ms", kind = "int", min = 200, max = 60000,
      ddl = "INT NOT NULL DEFAULT 1500", target = "BOSS_CONFIG", key = "aiUpdateInterval" },
    -- phase
    { group = "phase", column = "phase2_hp_threshold", kind = "int", min = 1, max = 99,
      ddl = "INT NOT NULL DEFAULT 70", target = "BOSS_CONFIG", key = "phase2HpThreshold" },
    { group = "phase", column = "phase3_hp_threshold", kind = "int", min = 1, max = 99,
      ddl = "INT NOT NULL DEFAULT 20", target = "BOSS_CONFIG", key = "phase3HpThreshold" },
    { group = "phase", column = "critical_hp_threshold", kind = "int", min = 1, max = 99,
      ddl = "INT NOT NULL DEFAULT 10", target = "BOSS_CONFIG", key = "criticalHpThreshold" },
    { group = "phase", column = "low_hp_taunt_threshold", kind = "int", min = 1, max = 100,
      ddl = "INT NOT NULL DEFAULT 30", target = "BOSS_CONFIG", key = "lowHpTauntThreshold" },
    { group = "phase", column = "low_hp_taunt_cooldown_ms", kind = "int", min = 1000, max = 600000,
      ddl = "INT NOT NULL DEFAULT 20000", target = "BOSS_CONFIG", key = "lowHpTauntCooldownMs" },
    { group = "phase", column = "long_combat_taunt_interval_ms", kind = "int", min = 5000, max = 3600000,
      ddl = "INT NOT NULL DEFAULT 60000", target = "BOSS_CONFIG", key = "longCombatTauntIntervalMs" },
    { group = "phase", column = "target_reeval_loops", kind = "int", min = 1, max = 100,
      ddl = "INT NOT NULL DEFAULT 3", target = "BOSS_CONFIG", key = "targetReevalLoops" },
    { group = "phase", column = "phase2_summon_count_min", kind = "int", min = 0, max = 20,
      ddl = "INT NOT NULL DEFAULT 1", target = "BOSS_CONFIG", key = "phase2SummonCountMin" },
    { group = "phase", column = "phase2_summon_count_max", kind = "int", min = 0, max = 20,
      ddl = "INT NOT NULL DEFAULT 2", target = "BOSS_CONFIG", key = "phase2SummonCountMax" },
    { group = "phase", column = "phase3_summon_count", kind = "int", min = 0, max = 20,
      ddl = "INT NOT NULL DEFAULT 2", target = "BOSS_CONFIG", key = "phase3SummonCount" },
    { group = "phase", column = "phase2_spell_id", kind = "int", min = 0, max = 2000000,
      ddl = "INT NOT NULL DEFAULT 1044", target = "BOSS_CONFIG", key = "phase2SpellId" },
    { group = "phase", column = "phase3_spell_id", kind = "int", min = 0, max = 2000000,
      ddl = "INT NOT NULL DEFAULT 8599", target = "BOSS_CONFIG", key = "phase3SpellId" },
    -- patrol
    { group = "patrol", column = "patrol_enabled", kind = "bool",
      ddl = "TINYINT NOT NULL DEFAULT 1", target = "BOSS_CONFIG", key = "patrolEnabled" },
    { group = "patrol", column = "patrol_radius", kind = "int", min = 0, max = 1000,
      ddl = "INT NOT NULL DEFAULT 50", target = "BOSS_CONFIG", key = "patrolRadius" },
    { group = "patrol", column = "patrol_leash_radius", kind = "int", min = 0, max = 2000,
      ddl = "INT NOT NULL DEFAULT 100", target = "BOSS_CONFIG", key = "patrolLeashRadius" },
    { group = "patrol", column = "patrol_interval_ms", kind = "int", min = 500, max = 3600000,
      ddl = "INT NOT NULL DEFAULT 9000", target = "BOSS_CONFIG", key = "patrolInterval" },
    -- minion
    { group = "minion", column = "minion_ai_enabled", kind = "bool",
      ddl = "TINYINT NOT NULL DEFAULT 1", target = "BOSS_CONFIG", key = "minionAiEnabled" },
    { group = "minion", column = "minion_ai_interval_ms", kind = "int", min = 200, max = 60000,
      ddl = "INT NOT NULL DEFAULT 1800", target = "BOSS_CONFIG", key = "minionAiInterval" },
    { group = "minion", column = "minion_target_range", kind = "int", min = 1, max = 200,
      ddl = "INT NOT NULL DEFAULT 40", target = "BOSS_CONFIG", key = "minionTargetRange" },
    -- helper
    { group = "helper", column = "helper_entries_text", kind = "intlist", keepDefaultWhenEmpty = true,
      ddl = "VARCHAR(255) NOT NULL DEFAULT ''", target = "HELPER_ENTRIES" },
    { group = "helper", column = "ally_helper_entry", kind = "int", min = 1, max = 2000000,
      ddl = "INT NOT NULL DEFAULT 20977", target = "ALLY_HELPER_ENTRY" },
    -- class
    { group = "class", column = "class_types_text", kind = "keyedword", keepDefaultWhenEmpty = true,
      ddl = "TEXT NULL", target = "CLASS_TYPES" },
    { group = "class", column = "class_reward_items_text", kind = "keyedintlist", keepDefaultWhenEmpty = true,
      ddl = "TEXT NULL", target = "CLASS_REWARD_ITEMS" },
    -- tier
    { group = "tier", column = "managed_tier_entries_text", kind = "intlist", keepDefaultWhenEmpty = true,
      ddl = "VARCHAR(255) NOT NULL DEFAULT ''", target = "BOSS_TIER_ENTRIES" },
}

-- ============================================================================
--  配置目标注册表：描述表的 target/key 通过这里落到具体的 Lua 表/变量
--  （SPAWN_POINTS / REWARD_ITEMS 这类整表配置用 get/set 闭包整体替换）
-- ============================================================================
local CONFIG_TARGETS = {}

local function RegisterConfigTarget(name, getter, setter)
    CONFIG_TARGETS[name] = { get = getter, set = setter }
end

RegisterConfigTarget("BOSS_CANDIDATES",
    function(key) return BOSS_CANDIDATES[1] and BOSS_CANDIDATES[1][key] end,
    function(key, value)
        if not BOSS_CANDIDATES[1] then BOSS_CANDIDATES[1] = {} end
        BOSS_CANDIDATES[1][key] = value
    end)

RegisterConfigTarget("BOSS_CONFIG",
    function(key) return BOSS_CONFIG[key] end,
    function(key, value) BOSS_CONFIG[key] = value end)

RegisterConfigTarget("TAUNTS",
    function(key) return BOSS_CONFIG.combatTaunts[key] end,
    function(key, value) BOSS_CONFIG.combatTaunts[key] = value end)

RegisterConfigTarget("REWARD_PROBABILITIES",
    function(key) return REWARD_PROBABILITIES[key] end,
    function(key, value) REWARD_PROBABILITIES[key] = value end)

RegisterConfigTarget("REWARD_GUARANTEED",
    function(key) return REWARD_GUARANTEED[key] end,
    function(key, value) REWARD_GUARANTEED[key] = value end)

RegisterConfigTarget("REWARD_GOLD",
    function(key) return REWARD_GOLD[key] end,
    function(key, value) REWARD_GOLD[key] = value end)

RegisterConfigTarget("REWARD_ITEMS",
    function() return REWARD_ITEMS end,
    function(_, value) REWARD_ITEMS = value end)

RegisterConfigTarget("REWARD_FORMULAS",
    function() return REWARD_FORMULAS end,
    function(_, value) REWARD_FORMULAS = value end)

RegisterConfigTarget("REWARD_MOUNTS",
    function() return REWARD_MOUNTS end,
    function(_, value) REWARD_MOUNTS = value end)

RegisterConfigTarget("SPAWN_POINTS",
    function() return SPAWN_POINTS end,
    function(_, value) SPAWN_POINTS = value end)

RegisterConfigTarget("HELPER_ENTRIES",
    function() return HELPER_ENTRIES end,
    function(_, value) HELPER_ENTRIES = value end)

RegisterConfigTarget("ALLY_HELPER_ENTRY",
    function() return ALLY_HELPER_ENTRY end,
    function(_, value) ALLY_HELPER_ENTRY = value end)

RegisterConfigTarget("CLASS_TYPES",
    function() return CLASS_TYPES end,
    function(_, value) CLASS_TYPES = value end)

RegisterConfigTarget("CLASS_REWARD_ITEMS",
    function() return CLASS_REWARD_ITEMS end,
    function(_, value) CLASS_REWARD_ITEMS = value end)

RegisterConfigTarget("BOSS_TIER_ENTRIES",
    function() return BOSS_TIER_ENTRIES end,
    function(_, value) BOSS_TIER_ENTRIES = value end)

local function GetConfigTargetValue(descriptor)
    local target = CONFIG_TARGETS[descriptor.target]
    if not target then
        return nil
    end

    return target.get(descriptor.key)
end

local function SetConfigTargetValue(descriptor, value)
    local target = CONFIG_TARGETS[descriptor.target]
    if not target then
        return false
    end

    target.set(descriptor.key, value)
    return true
end

-- ============================================================================
--  配置区结束（§4 起为表结构自举与读写实现，正常调参不需要看下面）
-- ============================================================================

local function BossSchemaColumnExists(tableName, columnName)
    local query = CharDBQuery(
        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '"
            .. BOSS_DB_NAME
            .. "' AND TABLE_NAME = '"
            .. tableName
            .. "' AND COLUMN_NAME = '"
            .. columnName
            .. "';"
    )

    return query ~= nil and query:GetUInt32(0) > 0
end

local function EnsureBossSchemaColumn(tableName, columnName, columnDefinition)
    if BossSchemaColumnExists(tableName, columnName) then
        return
    end

    CharDBExecute(
        'ALTER TABLE `'
            .. BOSS_DB_NAME
            .. '`.`'
            .. tableName
            .. '` ADD COLUMN `'
            .. columnName
            .. '` '
            .. columnDefinition
            .. ';'
    )
end

-- ============================================================================
--  §4 数据库表结构自举（ac_eluna）
-- ----------------------------------------------------------------------------
--  主表/运行态/事件/贡献表的列是「对外契约」（AGMP 面板按列名读写），列定义写死；
--  配置扩展表的列由 BOSS_CONFIG_SCHEMA_EXT 生成，加配置项不需要改这里。
-- ============================================================================

-- 配置扩展表的建表语句：列完全来自描述表，避免「描述表加了字段、建表语句忘了加」。
local function BuildBossExtTableSql()
    local columns = {
        '`state_key` VARCHAR(32) NOT NULL',
    }

    for _, descriptor in ipairs(BOSS_CONFIG_SCHEMA_EXT) do
        columns[#columns + 1] = '`' .. descriptor.column .. '` ' .. (descriptor.ddl or 'TEXT NULL')
    end

    columns[#columns + 1] = '`updated_at` INT NOT NULL DEFAULT 0'
    columns[#columns + 1] = 'PRIMARY KEY (`state_key`)'

    return 'CREATE TABLE IF NOT EXISTS `' .. BOSS_DB_NAME .. '`.`' .. BOSS_EXT_TABLE .. '` ('
        .. table.concat(columns, ',')
        .. ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;'
end

-- 扩展表已存在、但描述表新增了列时必须补列：
-- CREATE TABLE IF NOT EXISTS 对已存在的表什么都不做，缺列会让引导写入整条失败
-- （表现为面板/脚本改完配置却始终不生效）。
-- 常见情况下（列齐全）只多一条 COUNT 查询；只有真缺列时才逐列 ALTER。
local function EnsureBossExtTableColumns()
    local columnNames = {}
    for _, descriptor in ipairs(BOSS_CONFIG_SCHEMA_EXT) do
        columnNames[#columnNames + 1] = "'" .. descriptor.column .. "'"
    end

    if #columnNames == 0 then
        return
    end

    local countQuery = CharDBQuery(
        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '"
            .. BOSS_DB_NAME
            .. "' AND TABLE_NAME = '"
            .. BOSS_EXT_TABLE
            .. "' AND COLUMN_NAME IN ("
            .. table.concat(columnNames, ",")
            .. ");"
    )

    if countQuery ~= nil and countQuery:GetUInt32(0) >= #BOSS_CONFIG_SCHEMA_EXT then
        return
    end

    for _, descriptor in ipairs(BOSS_CONFIG_SCHEMA_EXT) do
        EnsureBossSchemaColumn(BOSS_EXT_TABLE, descriptor.column, descriptor.ddl or 'TEXT NULL')
    end
end

local function EnsureBossSchema(force)
    if BOSS_SCHEMA_READY and not force then
        return true
    end

    CharDBQuery('CREATE DATABASE IF NOT EXISTS `' .. BOSS_DB_NAME .. '`;')
    CharDBQuery('CREATE TABLE IF NOT EXISTS `' .. BOSS_DB_NAME .. '`.`' .. BOSS_RUNTIME_TABLE .. '` ('
        .. '`state_key` VARCHAR(32) NOT NULL,'
        .. '`boss_guid` INT NOT NULL DEFAULT 0,'
        .. '`boss_entry` INT NOT NULL DEFAULT 0,'
        .. '`boss_name` VARCHAR(120) NOT NULL DEFAULT "",'
        .. '`map_id` INT NOT NULL DEFAULT 0,'
        .. '`instance_id` INT NOT NULL DEFAULT 0,'
        .. '`home_x` DOUBLE NOT NULL DEFAULT 0,'
        .. '`home_y` DOUBLE NOT NULL DEFAULT 0,'
        .. '`home_z` DOUBLE NOT NULL DEFAULT 0,'
        .. '`phase` INT NOT NULL DEFAULT 0,'
        .. '`status` VARCHAR(32) NOT NULL DEFAULT "idle",'
        .. '`skill_preset` VARCHAR(64) NOT NULL DEFAULT "",'
        .. '`skill_difficulty` VARCHAR(64) NOT NULL DEFAULT "",'
        .. '`respawn_at` INT NOT NULL DEFAULT 0,'
        .. '`last_spawn_at` INT NOT NULL DEFAULT 0,'
        .. '`last_engage_at` INT NOT NULL DEFAULT 0,'
        .. '`last_death_at` INT NOT NULL DEFAULT 0,'
        .. '`last_reset_at` INT NOT NULL DEFAULT 0,'
        .. '`updated_at` INT NOT NULL DEFAULT 0,'
        .. 'PRIMARY KEY (`state_key`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;')
    CharDBQuery('CREATE TABLE IF NOT EXISTS `' .. BOSS_DB_NAME .. '`.`' .. BOSS_EVENT_TABLE .. '` ('
        .. '`id` INT NOT NULL AUTO_INCREMENT,'
        .. '`boss_guid` INT NOT NULL DEFAULT 0,'
        .. '`boss_entry` INT NOT NULL DEFAULT 0,'
        .. '`boss_name` VARCHAR(120) NOT NULL DEFAULT "",'
        .. '`event_type` VARCHAR(32) NOT NULL DEFAULT "",'
        .. '`event_note` VARCHAR(255) NOT NULL DEFAULT "",'
        .. '`actor_name` VARCHAR(120) NOT NULL DEFAULT "",'
        .. '`actor_guid` INT NOT NULL DEFAULT 0,'
        .. '`payload_json` TEXT NULL,'
        .. '`created_at` INT NOT NULL DEFAULT 0,'
        .. 'PRIMARY KEY (`id`),'
        .. 'KEY `idx_created_at` (`created_at`),'
        .. 'KEY `idx_event_type` (`event_type`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;')
    CharDBQuery('CREATE TABLE IF NOT EXISTS `' .. BOSS_DB_NAME .. '`.`' .. BOSS_CONTRIBUTOR_TABLE .. '` ('
        .. '`id` INT NOT NULL AUTO_INCREMENT,'
        .. '`boss_guid` INT NOT NULL DEFAULT 0,'
        .. '`boss_entry` INT NOT NULL DEFAULT 0,'
        .. '`boss_name` VARCHAR(120) NOT NULL DEFAULT "",'
        .. '`player_guid` INT NOT NULL DEFAULT 0,'
        .. '`player_name` VARCHAR(120) NOT NULL DEFAULT "",'
        .. '`account_id` INT NOT NULL DEFAULT 0,'
        .. '`damage_done` BIGINT NOT NULL DEFAULT 0,'
        .. '`healing_done` BIGINT NOT NULL DEFAULT 0,'
        .. '`threat_samples` INT NOT NULL DEFAULT 0,'
        .. '`presence_samples` INT NOT NULL DEFAULT 0,'
        .. '`contribution_score` DOUBLE NOT NULL DEFAULT 0,'
        .. '`was_killer` TINYINT NOT NULL DEFAULT 0,'
        .. '`rewarded_random` TINYINT NOT NULL DEFAULT 0,'
        .. '`guaranteed_reward` TINYINT NOT NULL DEFAULT 0,'
        .. '`created_at` INT NOT NULL DEFAULT 0,'
        .. 'PRIMARY KEY (`id`),'
        .. 'KEY `idx_created_at` (`created_at`),'
        .. 'KEY `idx_player_guid` (`player_guid`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;')
    CharDBQuery('CREATE TABLE IF NOT EXISTS `' .. BOSS_DB_NAME .. '`.`' .. BOSS_MAIN_TABLE .. '` ('
        .. '`state_key` VARCHAR(32) NOT NULL,'
        .. '`boss_entry` INT NOT NULL DEFAULT 190090,'
        .. '`boss_name` VARCHAR(120) NOT NULL DEFAULT "",'
        .. '`boss_level` INT NOT NULL DEFAULT 83,'
        .. '`boss_scale_scaled` INT NOT NULL DEFAULT 500,'
        .. '`boss_health_multiplier_scaled` INT NOT NULL DEFAULT 2000,'
        .. '`boss_auras_text` TEXT NULL,'
        .. '`ally_level` INT NOT NULL DEFAULT 20,'
        .. '`ally_health_multiplier_scaled` INT NOT NULL DEFAULT 150,'
        .. '`respawn_time_minutes` INT NOT NULL DEFAULT 10,'
        .. '`minion_count_min` INT NOT NULL DEFAULT 1,'
        .. '`minion_count_max` INT NOT NULL DEFAULT 2,'
        .. '`skill_preset` VARCHAR(64) NOT NULL DEFAULT "storm_siege",'
        .. '`skill_difficulty` VARCHAR(64) NOT NULL DEFAULT "standard",'
        .. '`guaranteed_reward_enabled` TINYINT NOT NULL DEFAULT 1,'
        .. '`guaranteed_reward_notify` TINYINT NOT NULL DEFAULT 1,'
        .. '`max_random_reward_players` INT NOT NULL DEFAULT 3,'
        .. '`class_reward_chance` INT NOT NULL DEFAULT 60,'
        .. '`formula_reward_chance` INT NOT NULL DEFAULT 10,'
        .. '`mount_reward_chance` INT NOT NULL DEFAULT 15,'
        .. '`random_reward_mode` VARCHAR(16) NOT NULL DEFAULT "weighted",'
        .. '`participation_range` INT NOT NULL DEFAULT 80,'
        .. '`damage_weight` INT NOT NULL DEFAULT 100,'
        .. '`healing_weight` INT NOT NULL DEFAULT 80,'
        .. '`threat_weight` INT NOT NULL DEFAULT 35,'
        .. '`presence_weight` INT NOT NULL DEFAULT 10,'
        .. '`kill_weight` INT NOT NULL DEFAULT 3,'
        .. '`guaranteed_item_id` INT NOT NULL DEFAULT 40753,'
        .. '`guaranteed_item_count` INT NOT NULL DEFAULT 2,'
        .. '`gold_min_copper` INT NOT NULL DEFAULT 30000,'
        .. '`gold_max_copper` INT NOT NULL DEFAULT 50000,'
        .. '`reward_items_text` TEXT NULL,'
        .. '`reward_formulas_text` TEXT NULL,'
        .. '`reward_mounts_text` TEXT NULL,'
        .. '`spawn_points_text` TEXT NULL,'
        .. '`updated_at` INT NOT NULL DEFAULT 0,'
        .. 'PRIMARY KEY (`state_key`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;')

    -- 脚本私有配置表：列由 BOSS_CONFIG_SCHEMA_EXT 生成（新增配置项无需改这里），
    -- 已存在的表缺列时由 EnsureBossExtTableColumns 补齐
    CharDBQuery(BuildBossExtTableSql())
    EnsureBossExtTableColumns()

    EnsureBossSchemaColumn(
        BOSS_MAIN_TABLE,
        'spawn_points_text',
        'TEXT NULL AFTER `reward_mounts_text`'
    )

    EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'account_id', 'INT NOT NULL DEFAULT 0')
    EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'healing_done', 'BIGINT NOT NULL DEFAULT 0')
    EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'threat_samples', 'INT NOT NULL DEFAULT 0')
    EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'presence_samples', 'INT NOT NULL DEFAULT 0')
    EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'contribution_score', 'DOUBLE NOT NULL DEFAULT 0')
    EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'was_killer', 'TINYINT NOT NULL DEFAULT 0')
    EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'rewarded_random', 'TINYINT NOT NULL DEFAULT 0')
    EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'guaranteed_reward', 'TINYINT NOT NULL DEFAULT 0')

    BOSS_SCHEMA_READY = true
    return true
end

EnsureBossSchema(true)

-- ============================================================================
--  §5 内容库（非配置项）
-- ----------------------------------------------------------------------------
--  下面这些是「技能内容」而不是「可调配置」：
--    * 技能池预设 / 强度档位：每个技能由 spellId + 冷却 + 目标 + 条件构成，
--      改动等于改战斗设计，需要走版本发布与复核，不适合在数据库里改；
--    * 打断法术池：核心打断技能清单。
--  可调的部分（选哪套预设、哪个强度档位）已经落库：见 [skill] 的
--  boss_activity_config.skill_preset / skill_difficulty。
-- ============================================================================

-- ========== 技能池预设（基于 Northrend 脚本） ==========
-- 技能参数说明：
-- spellId: 技能ID（来自 Spell.dbc）
-- name: 技能名称（用于日志显示）
-- minCD/maxCD: 冷却时间范围（秒），在此范围内随机
-- target: "self"(自身) 或 "victim"(目标)
-- priority: 优先级(1-8)，越高越优先，同优先级随机选择
-- condition: 触发条件，见下方说明
-- 设计原则：仅选取 Northrend 副本脚本中已出现、且不依赖房间机关/载具/固定场景逻辑的法术

local SKILL_PRESET_ORDER = {
    "storm_siege",
    "ember_storm",
    "frost_whiteout",
    "venom_pursuit",
    "grave_bombard",
    "spellbreak_bulwark",
}

local SKILL_DIFFICULTY_ORDER = {
    "easy",
    "standard",
    "hard",
    "raid",
}

local SKILL_DIFFICULTY_LIBRARY = {
    easy = {
        displayName = "简单",
        cooldownMultiplier = 1.18,
        comboCooldownMultiplier = 1.10,
        comboChanceOffset = -8,
        summary = "整体节奏放缓，连招触发更少，适合单人试技能或小队熟悉机制。",
    },
    standard = {
        displayName = "标准",
        cooldownMultiplier = 1.00,
        comboCooldownMultiplier = 1.00,
        comboChanceOffset = 0,
        summary = "默认节奏，适合常规世界 Boss 轮换。",
    },
    hard = {
        displayName = "困难",
        cooldownMultiplier = 0.90,
        comboCooldownMultiplier = 0.92,
        comboChanceOffset = 6,
        summary = "技能衔接更快，连招更频繁，适合多名玩家参与。",
    },
    raid = {
        displayName = "团本级",
        cooldownMultiplier = 0.80,
        comboCooldownMultiplier = 0.85,
        comboChanceOffset = 12,
        summary = "高压覆盖和高频连招，按 10 人以上团本压力设计。",
    },
}

local SKILL_PRESET_LIBRARY = {
    -- 风暴攻城：偏中距离点名和群体震场，适合放在标准或困难档位作为通用模板。
    storm_siege = {
        displayName = "风暴攻城",
        summary = "雷电跳跃配合震荡与点名压制，强调分散站位和中场转火。",
        skillPools = {
            [1] = {
                {spellId = 64213, name = "闪电链", minCD = 10, maxCD = 15, target = "victim", priority = 7, condition = "grouped_targets"}, -- Emalon
                {spellId = 58678, name = "岩石碎片", minCD = 13, maxCD = 18, target = "victim", priority = 7, condition = "ranged_target"}, -- Archavon
                {spellId = 58663, name = "践踏", minCD = 18, maxCD = 24, target = "self", priority = 6, condition = "multi_melee"}, -- Archavon
                {spellId = 48878, name = "穿刺顺劈", minCD = 14, maxCD = 20, target = "victim", priority = 6, condition = "multi_melee"}, -- Dred
            },
            [2] = {
                {spellId = 64216, name = "闪电新星", minCD = 14, maxCD = 20, target = "self", priority = 8, condition = "multi_target"}, -- Emalon
                {spellId = 64422, name = "音波尖啸", minCD = 16, maxCD = 22, target = "self", priority = 7, condition = "caster_target"}, -- Auriaya
                {spellId = 58666, name = "穿刺", minCD = 12, maxCD = 18, target = "victim", priority = 7, condition = "low_hp_target"}, -- Archavon
                {spellId = 48849, name = "骇人咆哮", minCD = 20, maxCD = 28, target = "self", priority = 5, condition = "many_attackers"}, -- Dred
            },
            [3] = {
                {spellId = 64216, name = "闪电新星", minCD = 12, maxCD = 18, target = "self", priority = 8, condition = "multi_target"},
                {spellId = 58678, name = "岩石碎片", minCD = 10, maxCD = 16, target = "victim", priority = 7, condition = "grouped_targets"},
                {spellId = 58666, name = "穿刺", minCD = 10, maxCD = 15, target = "victim", priority = 7, condition = "healer_target"},
                {spellId = 64422, name = "音波尖啸", minCD = 14, maxCD = 20, target = "self", priority = 7, condition = "multi_target"},
            },
        },
        comboChains = {
            {name = "雷岩合围", skills = {{64213, "victim"}, {58678, "victim"}, {64216, "self"}}, cooldown = 28, triggerChance = 38, phase = {1, 2}},
            {name = "重压处决", skills = {{58663, "self"}, {58666, "victim"}, {64422, "self"}}, cooldown = 30, triggerChance = 35, phase = {2, 3}},
            {name = "恐惧清场", skills = {{48849, "self"}, {64216, "self"}, {58678, "victim"}}, cooldown = 34, triggerChance = 32, phase = {3}},
        },
        openingSkills = {
            {spellId = 64213, name = "闪电链", target = "victim"},
            {spellId = 58678, name = "岩石碎片", target = "victim"},
            {spellId = 58663, name = "践踏", target = "self"},
        },
    },

    -- 余烬风暴：通过吐息、火点名和拳击制造持续走位，适合野外平地或开阔地形。
    ember_storm = {
        displayName = "余烬风暴",
        summary = "火焰点名、持续场压和近战爆发并存，适合制造强走位与治疗压力。",
        skillPools = {
            [1] = {
                {spellId = 66681, name = "烈焰余烬", minCD = 9, maxCD = 14, target = "victim", priority = 7, condition = "ranged_target"}, -- Koralon
                {spellId = 69024, name = "剧毒废料", minCD = 11, maxCD = 16, target = "victim", priority = 6, condition = "grouped_targets"}, -- Krick/Ick
                {spellId = 64213, name = "闪电链", minCD = 13, maxCD = 18, target = "victim", priority = 6, condition = "grouped_targets"}, -- Emalon
                {spellId = 66725, name = "陨星拳", minCD = 18, maxCD = 24, target = "self", priority = 5, condition = "multi_melee"}, -- Koralon
            },
            [2] = {
                {spellId = 66665, name = "灼烧吐息", minCD = 12, maxCD = 18, target = "self", priority = 8, condition = "multi_target"}, -- Koralon
                {spellId = 64216, name = "闪电新星", minCD = 16, maxCD = 22, target = "self", priority = 7, condition = "multi_target"}, -- Emalon
                {spellId = 58663, name = "践踏", minCD = 18, maxCD = 24, target = "self", priority = 6, condition = "multi_melee"}, -- Archavon
                {spellId = 58666, name = "穿刺", minCD = 12, maxCD = 18, target = "victim", priority = 7, condition = "low_hp_target"}, -- Archavon
            },
            [3] = {
                {spellId = 66665, name = "灼烧吐息", minCD = 10, maxCD = 16, target = "self", priority = 8, condition = "multi_target"},
                {spellId = 66725, name = "陨星拳", minCD = 14, maxCD = 20, target = "self", priority = 7, condition = "multi_melee"},
                {spellId = 66681, name = "烈焰余烬", minCD = 8, maxCD = 12, target = "victim", priority = 7, condition = "healer_target"},
                {spellId = 69024, name = "剧毒废料", minCD = 10, maxCD = 15, target = "victim", priority = 7, condition = "grouped_targets"},
            },
        },
        comboChains = {
            {name = "灰烬逼走", skills = {{66681, "victim"}, {69024, "victim"}, {64216, "self"}}, cooldown = 26, triggerChance = 40, phase = {1, 2}},
            {name = "烈拳处决", skills = {{66725, "self"}, {58663, "self"}, {58666, "victim"}}, cooldown = 30, triggerChance = 34, phase = {2, 3}},
            {name = "焚场风暴", skills = {{66665, "self"}, {66681, "victim"}, {69024, "victim"}}, cooldown = 32, triggerChance = 38, phase = {3}},
        },
        openingSkills = {
            {spellId = 66681, name = "烈焰余烬", target = "victim"},
            {spellId = 69024, name = "剧毒废料", target = "victim"},
            {spellId = 66725, name = "陨星拳", target = "self"},
        },
    },

    -- 冰封压境：慢性减速和大范围白茫叠压，适合强化治疗与换位节奏。
    frost_whiteout = {
        displayName = "冰封压境",
        summary = "地面减速、全团白茫和法系压制叠加，后期会逼迫队伍持续换位。",
        skillPools = {
            [1] = {
                {spellId = 72090, name = "冰冻之地", minCD = 10, maxCD = 15, target = "victim", priority = 7, condition = "ranged_target"}, -- Toravon
                {spellId = 64213, name = "闪电链", minCD = 12, maxCD = 18, target = "victim", priority = 6, condition = "grouped_targets"}, -- Emalon
                {spellId = 54970, name = "毒液箭", minCD = 11, maxCD = 16, target = "victim", priority = 6, condition = "caster_target"}, -- Slad'ran
                {spellId = 58663, name = "践踏", minCD = 18, maxCD = 24, target = "self", priority = 5, condition = "multi_melee"}, -- Archavon
            },
            [2] = {
                {spellId = 72034, name = "白茫", minCD = 18, maxCD = 24, target = "self", priority = 8, condition = "multi_target"}, -- Toravon
                {spellId = 72090, name = "冰冻之地", minCD = 12, maxCD = 17, target = "victim", priority = 7, condition = "grouped_targets"},
                {spellId = 64422, name = "音波尖啸", minCD = 16, maxCD = 22, target = "self", priority = 6, condition = "caster_target"},
                {spellId = 55081, name = "剧毒新星", minCD = 18, maxCD = 24, target = "self", priority = 6, condition = "multi_target"}, -- Slad'ran
            },
            [3] = {
                {spellId = 72034, name = "白茫", minCD = 14, maxCD = 20, target = "self", priority = 8, condition = "multi_target"},
                {spellId = 72090, name = "冰冻之地", minCD = 10, maxCD = 14, target = "victim", priority = 8, condition = "healer_target"},
                {spellId = 55081, name = "剧毒新星", minCD = 14, maxCD = 20, target = "self", priority = 7, condition = "many_attackers"},
                {spellId = 58666, name = "穿刺", minCD = 10, maxCD = 16, target = "victim", priority = 7, condition = "low_hp_target"},
            },
        },
        comboChains = {
            {name = "冰雷点杀", skills = {{72090, "victim"}, {64213, "victim"}, {58666, "victim"}}, cooldown = 26, triggerChance = 36, phase = {1, 2}},
            {name = "白茫封场", skills = {{72034, "self"}, {55081, "self"}, {64422, "self"}}, cooldown = 32, triggerChance = 35, phase = {2, 3}},
            {name = "寒毒压溃", skills = {{72090, "victim"}, {72034, "self"}, {58663, "self"}}, cooldown = 30, triggerChance = 38, phase = {3}},
        },
        openingSkills = {
            {spellId = 72090, name = "冰冻之地", target = "victim"},
            {spellId = 54970, name = "毒液箭", target = "victim"},
            {spellId = 64213, name = "闪电链", target = "victim"},
        },
    },

    -- 毒猎追击：偏收割和连续压迫，适合近战多、需要频繁转火的对局。
    venom_pursuit = {
        displayName = "毒猎追击",
        summary = "以毒伤、恐惧和近战斩杀构成压迫链，适合打出频繁转火和收割节奏。",
        skillPools = {
            [1] = {
                {spellId = 54970, name = "毒液箭", minCD = 8, maxCD = 13, target = "victim", priority = 7, condition = "caster_target"}, -- Slad'ran
                {spellId = 48878, name = "穿刺顺劈", minCD = 12, maxCD = 17, target = "victim", priority = 6, condition = "multi_melee"}, -- Dred
                {spellId = 69024, name = "剧毒废料", minCD = 12, maxCD = 18, target = "victim", priority = 6, condition = "grouped_targets"}, -- Krick/Ick
                {spellId = 58678, name = "岩石碎片", minCD = 14, maxCD = 20, target = "victim", priority = 6, condition = "ranged_target"}, -- Archavon
            },
            [2] = {
                {spellId = 55081, name = "剧毒新星", minCD = 15, maxCD = 21, target = "self", priority = 8, condition = "multi_target"}, -- Slad'ran
                {spellId = 48849, name = "骇人咆哮", minCD = 18, maxCD = 24, target = "self", priority = 6, condition = "many_attackers"}, -- Dred
                {spellId = 64422, name = "音波尖啸", minCD = 16, maxCD = 22, target = "self", priority = 7, condition = "caster_target"}, -- Auriaya
                {spellId = 58666, name = "穿刺", minCD = 12, maxCD = 18, target = "victim", priority = 7, condition = "low_hp_target"}, -- Archavon
            },
            [3] = {
                {spellId = 55081, name = "剧毒新星", minCD = 13, maxCD = 18, target = "self", priority = 8, condition = "multi_target"},
                {spellId = 69024, name = "剧毒废料", minCD = 10, maxCD = 15, target = "victim", priority = 7, condition = "grouped_targets"},
                {spellId = 48849, name = "骇人咆哮", minCD = 16, maxCD = 24, target = "self", priority = 6, condition = "many_attackers"},
                {spellId = 58666, name = "穿刺", minCD = 10, maxCD = 15, target = "victim", priority = 8, condition = "healer_target"},
            },
        },
        comboChains = {
            {name = "毒刃收口", skills = {{54970, "victim"}, {48878, "victim"}, {58666, "victim"}}, cooldown = 24, triggerChance = 40, phase = {1, 2}},
            {name = "毒雾驱散", skills = {{69024, "victim"}, {55081, "self"}, {48849, "self"}}, cooldown = 30, triggerChance = 34, phase = {2, 3}},
            {name = "猎杀终曲", skills = {{64422, "self"}, {58666, "victim"}, {55081, "self"}}, cooldown = 28, triggerChance = 40, phase = {3}},
        },
        openingSkills = {
            {spellId = 54970, name = "毒液箭", target = "victim"},
            {spellId = 69024, name = "剧毒废料", target = "victim"},
            {spellId = 58678, name = "岩石碎片", target = "victim"},
        },
    },

    -- 墓火轰炸：选用 ICC 与 Ulduar 的纯战斗法术，主打点名爆发、投射物和地面覆盖。
    grave_bombard = {
        displayName = "墓火轰炸",
        summary = "死亡凋零、冰焰与暗影冲击持续封位，配合软泥抛掷和无面者印记打出点名爆发。",
        skillPools = {
            [1] = {
                {spellId = 71001, name = "死亡凋零", minCD = 11, maxCD = 16, target = "victim", priority = 7, condition = "grouped_targets"}, -- Lady Deathwhisper
                {spellId = 62660, name = "暗影冲击", minCD = 10, maxCD = 15, target = "victim", priority = 7, condition = "ranged_target"}, -- General Vezax
                {spellId = 69140, name = "冰焰", minCD = 14, maxCD = 20, target = "victim", priority = 6, condition = "ranged_target"}, -- Lord Marrowgar
                {spellId = 70852, name = "软泥抛掷", minCD = 15, maxCD = 20, target = "victim", priority = 6, condition = "caster_target"}, -- Professor Putricide
            },
            [2] = {
                {spellId = 71001, name = "死亡凋零", minCD = 10, maxCD = 15, target = "victim", priority = 8, condition = "grouped_targets"},
                {spellId = 63276, name = "无面者印记", minCD = 18, maxCD = 24, target = "victim", priority = 7, condition = "multi_target"}, -- General Vezax
                {spellId = 69140, name = "冰焰", minCD = 12, maxCD = 18, target = "victim", priority = 7, condition = "healer_target"},
                {spellId = 70852, name = "软泥抛掷", minCD = 13, maxCD = 18, target = "victim", priority = 7, condition = "grouped_targets"},
            },
            [3] = {
                {spellId = 71001, name = "死亡凋零", minCD = 9, maxCD = 13, target = "victim", priority = 8, condition = "grouped_targets"},
                {spellId = 62660, name = "暗影冲击", minCD = 9, maxCD = 13, target = "victim", priority = 8, condition = "healer_target"},
                {spellId = 63276, name = "无面者印记", minCD = 16, maxCD = 22, target = "victim", priority = 7, condition = "multi_target"},
                {spellId = 69140, name = "冰焰", minCD = 10, maxCD = 15, target = "victim", priority = 7, condition = "grouped_targets"},
            },
        },
        comboChains = {
            {name = "墓地封锁", skills = {{71001, "victim"}, {69140, "victim"}, {62660, "victim"}}, cooldown = 28, triggerChance = 38, phase = {1, 2}},
            {name = "腐蚀点杀", skills = {{63276, "victim"}, {70852, "victim"}, {62660, "victim"}}, cooldown = 30, triggerChance = 35, phase = {2, 3}},
            {name = "轰炸终曲", skills = {{71001, "victim"}, {70852, "victim"}, {69140, "victim"}}, cooldown = 26, triggerChance = 40, phase = {3}},
        },
        openingSkills = {
            {spellId = 71001, name = "死亡凋零", target = "victim"},
            {spellId = 62660, name = "暗影冲击", target = "victim"},
            {spellId = 69140, name = "冰焰", target = "victim"},
        },
    },

    -- 破法壁垒：前期压近战站位和坦线，后期叠加群体读条压制与法系惩罚。
    spellbreak_bulwark = {
        displayName = "破法壁垒",
        summary = "骨刃分劈、恐惧尖啸和灼烧烈焰压迫近战，冰霜箭雨、哨兵震爆与黑暗奔涌持续反制法系。",
        skillPools = {
            [1] = {
                {spellId = 69055, name = "骨刃分劈", minCD = 8, maxCD = 13, target = "victim", priority = 7, condition = "multi_melee"}, -- Marrowgar
                {spellId = 64386, name = "恐惧尖啸", minCD = 16, maxCD = 22, target = "self", priority = 6, condition = "many_attackers"}, -- Auriaya
                {spellId = 72905, name = "冰霜箭雨", minCD = 14, maxCD = 20, target = "self", priority = 6, condition = "grouped_targets"}, -- Lady Deathwhisper
                {spellId = 71204, name = "无意义之触", minCD = 12, maxCD = 18, target = "victim", priority = 6, condition = "multi_melee"}, -- Lady Deathwhisper
            },
            [2] = {
                {spellId = 62661, name = "灼烧烈焰", minCD = 14, maxCD = 20, target = "victim", priority = 8, condition = "multi_target"}, -- General Vezax
                {spellId = 64389, name = "哨兵震爆", minCD = 16, maxCD = 22, target = "self", priority = 7, condition = "caster_target"}, -- Auriaya
                {spellId = 72905, name = "冰霜箭雨", minCD = 13, maxCD = 19, target = "self", priority = 7, condition = "grouped_targets"},
                {spellId = 63276, name = "无面者印记", minCD = 18, maxCD = 24, target = "victim", priority = 6, condition = "healer_target"}, -- General Vezax
            },
            [3] = {
                {spellId = 62662, name = "黑暗奔涌", minCD = 18, maxCD = 26, target = "self", priority = 8, condition = "multi_melee"}, -- General Vezax
                {spellId = 62661, name = "灼烧烈焰", minCD = 12, maxCD = 18, target = "victim", priority = 8, condition = "multi_target"},
                {spellId = 64389, name = "哨兵震爆", minCD = 14, maxCD = 20, target = "self", priority = 7, condition = "caster_target"},
                {spellId = 72905, name = "冰霜箭雨", minCD = 12, maxCD = 18, target = "self", priority = 7, condition = "grouped_targets"},
            },
        },
        comboChains = {
            {name = "碎阵压锋", skills = {{69055, "victim"}, {64386, "self"}, {62661, "victim"}}, cooldown = 26, triggerChance = 36, phase = {1, 2}},
            {name = "破法齐射", skills = {{64389, "self"}, {72905, "self"}, {63276, "victim"}}, cooldown = 30, triggerChance = 38, phase = {2, 3}},
            {name = "黑潮封咏", skills = {{62662, "self"}, {62661, "victim"}, {72905, "self"}}, cooldown = 32, triggerChance = 40, phase = {3}},
        },
        openingSkills = {
            {spellId = 69055, name = "骨刃分劈", target = "victim"},
            {spellId = 72905, name = "冰霜箭雨", target = "self"},
            {spellId = 71204, name = "无意义之触", target = "victim"},
        },
    },
}

local SKILL_POOLS = {}

-- 专用打断法术池：优先尝试真正带打断效果的法术
local INTERRUPT_SPELL_LIBRARY = {
    {spellId = 57994, name = "风剪", maxRange = 25, cooldown = 8},
    {spellId = 2139, name = "法术反制", maxRange = 30, cooldown = 10},
    {spellId = 1766, name = "脚踢", maxRange = 8, cooldown = 10},
    {spellId = 6552, name = "拳击", maxRange = 8, cooldown = 10},
    {spellId = 47528, name = "心灵冰冻", maxRange = 8, cooldown = 8},
    {spellId = 72, name = "盾击", maxRange = 8, cooldown = 12},
    {spellId = 19647, name = "法术封锁", maxRange = 30, cooldown = 20},
}

local COMBO_CHAINS = {}
local OPENING_SKILLS = {}
local ACTIVE_SKILL_PRESET_KEY = nil
local ACTIVE_SKILL_PRESET = nil
local ACTIVE_SKILL_DIFFICULTY_KEY = nil
local ACTIVE_SKILL_DIFFICULTY = nil

-- ============================================================================
--  §6 序列化与 SQL 工具
-- ----------------------------------------------------------------------------
--  文本 ↔ 运行期结构的转换集中在这里，配置描述表的每种 kind 都对应下面一组函数：
--    intlist     "1,2,3"          ↔ 正整数数组        Parse/SerializePositiveIntegerList
--    lines       每行一条          ↔ 字符串数组        Parse/SerializeLineList
--    keyedlines  每行 "键=值"      ↔ 字符串映射        Parse/SerializeKeyedLines
--    keyedword   同 keyedlines     ↔ 短标识映射（职业类型）
--    keyedintlist 每行 "键=1,2,3"  ↔ 数组映射          Parse/SerializeKeyedIntegerLists
--    spawnpoints 每行 "map,x,y,z"  ↔ 坐标数组          Parse/SerializeSpawnPoints
-- ============================================================================

local function ClampNumber(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function ClampInteger(value, minValue, maxValue)
    local numericValue = math.floor((tonumber(value) or 0) + 0.5)
    if minValue ~= nil then
        numericValue = math.max(minValue, numericValue)
    end
    if maxValue ~= nil then
        numericValue = math.min(maxValue, numericValue)
    end
    return numericValue
end

local function RoundToScaledInteger(value)
    return math.floor((tonumber(value) or 0) * BOSS_DECIMAL_SCALE + 0.5)
end

local function ScaledIntegerToNumber(value, fallback)
    local numericValue = tonumber(value)
    if numericValue == nil then
        return fallback
    end

    return numericValue / BOSS_DECIMAL_SCALE
end

local function ParsePositiveIntegerList(text)
    local values = {}
    local seen = {}

    for token in string.gmatch(tostring(text or ""), "%d+") do
        local numericValue = tonumber(token)
        if numericValue and numericValue > 0 and not seen[numericValue] then
            seen[numericValue] = true
            table.insert(values, numericValue)
        end
    end

    return values
end

local function SerializePositiveIntegerList(values)
    local parts = {}
    if type(values) ~= "table" then
        return ""
    end

    for _, value in ipairs(values) do
        local numericValue = tonumber(value)
        if numericValue and numericValue > 0 then
            table.insert(parts, tostring(math.floor(numericValue)))
        end
    end

    return table.concat(parts, ",")
end

-- 多行文本 ↔ 字符串数组（喊话/嘲讽列表：一行一条）。
-- 空行不会变成空喊话；含 = 号的行对 lines 无影响，对 keyedlines 按第一个 = 切分。
local function ParseLineList(text)
    local lines = {}
    for line in string.gmatch(tostring(text or "") .. "\n", "([^\r\n]*)[\r\n]") do
        if line ~= "" then
            table.insert(lines, line)
        end
    end

    return lines
end

-- 单行文本（喊话原文可能带前导空格，不能 trim）
local function SanitizeSingleLine(value)
    local text = tostring(value or "")
    text = text:gsub("[\r\n]+", " ")
    return text
end

local function SerializeLineList(values)
    local lines = {}
    if type(values) ~= "table" then
        return ""
    end

    for _, value in ipairs(values) do
        local text = SanitizeSingleLine(value)
        if text ~= "" then
            table.insert(lines, text)
        end
    end

    return table.concat(lines, "\n")
end

local function ParseKeyedLines(text)
    local map = {}
    for _, line in ipairs(ParseLineList(text)) do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            key = key:gsub("^%s+", ""):gsub("%s+$", "")
            if key ~= "" and value ~= "" then
                map[key] = value
            end
        end
    end

    return map
end

-- 键排序后输出：同样的配置生成同样的文本，便于 DBA 肉眼比对与 diff
-- 注意：键要按「原值」回查 map（数值键 1 与字符串键 "1" 在 Lua 里不同），
-- 否则 map["1"] 取不到 map[1]，会写出 "1=" 这种空值。
local function SerializeKeyedLines(map)
    if type(map) ~= "table" then
        return ""
    end

    local keys = {}
    for key, value in pairs(map) do
        if type(value) == "string" and value ~= "" then
            table.insert(keys, key)
        end
    end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)

    local lines = {}
    for _, key in ipairs(keys) do
        lines[#lines + 1] = SanitizeSingleLine(key) .. "=" .. SanitizeSingleLine(map[key])
    end

    return table.concat(lines, "\n")
end

local function ParseKeyedIntegerLists(text)
    local map = {}
    for key, value in pairs(ParseKeyedLines(text)) do
        local numericKey = tonumber(key)
        if numericKey then
            local list = ParsePositiveIntegerList(value)
            if #list > 0 then
                map[numericKey] = list
            end
        end
    end

    return map
end

local function SerializeKeyedIntegerLists(map)
    if type(map) ~= "table" then
        return ""
    end

    local keys = {}
    for key, value in pairs(map) do
        local numericKey = tonumber(key)
        if numericKey and type(value) == "table" and SerializePositiveIntegerList(value) ~= "" then
            table.insert(keys, numericKey)
        end
    end
    table.sort(keys)

    local lines = {}
    for _, key in ipairs(keys) do
        lines[#lines + 1] = tostring(key) .. "=" .. SerializePositiveIntegerList(map[key])
    end

    return table.concat(lines, "\n")
end

local function SerializeSpawnPoints(points)
    local rows = {}
    if type(points) ~= "table" then
        return ""
    end

    for _, point in ipairs(points) do
        if type(point) == "table" then
            local mapId = ClampInteger(point.mapId or 0, 0, 2000000)
            local x = tonumber(point.x)
            local y = tonumber(point.y)
            local z = tonumber(point.z)
            if x ~= nil and y ~= nil and z ~= nil then
                table.insert(rows, string.format("%d,%.4f,%.4f,%.4f", mapId, x, y, z))
            end
        end
    end

    return table.concat(rows, "\n")
end

local function ParseSpawnPointsText(text, fallbackPoints)
    local parsed = {}
    local sourceText = tostring(text or "")

    for rawLine in string.gmatch(sourceText, "[^\r\n]+") do
        local numbers = {}
        for token in string.gmatch(rawLine, "[-+]?%d+%.?%d*") do
            table.insert(numbers, tonumber(token))
            if #numbers >= 4 then
                break
            end
        end

        if #numbers >= 4
            and numbers[1] ~= nil
            and numbers[2] ~= nil
            and numbers[3] ~= nil
            and numbers[4] ~= nil then
            table.insert(parsed, {
                mapId = ClampInteger(numbers[1], 0, 2000000),
                x = numbers[2],
                y = numbers[3],
                z = numbers[4],
            })
        end
    end

    if #parsed == 0 then
        -- 文本里没有有效坐标（例如面板把该列清空了）→ 回退到文件内的默认刷新点
        return CloneSpawnPoints(fallbackPoints or DEFAULT_SPAWN_POINTS)
    end

    return parsed
end

local function FindBossCandidateByEntry(entry)
    local targetEntry = tonumber(entry) or 0
    for _, bossCandidate in ipairs(BOSS_CANDIDATES) do
        if tonumber(bossCandidate.entry or 0) == targetEntry then
            return bossCandidate
        end
    end

    return nil
end

local function ResolveBossCandidateName(entry, fallbackName)
    local bossCandidate = FindBossCandidateByEntry(entry)
    if bossCandidate and tostring(bossCandidate.name or "") ~= "" then
        return tostring(bossCandidate.name)
    end

    local resolvedFallback = tostring(fallbackName or "")
    if resolvedFallback ~= "" then
        return resolvedFallback
    end

    if BOSS_CANDIDATES[1] and tostring(BOSS_CANDIDATES[1].name or "") ~= "" then
        return tostring(BOSS_CANDIDATES[1].name)
    end

    return "活动Boss"
end

local function DeepCopyTable(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, innerValue in pairs(value) do
        copy[key] = DeepCopyTable(innerValue)
    end
    return copy
end

local function ScaleCooldown(value, multiplier)
    return math.max(4, math.floor(value * multiplier + 0.5))
end

local function GetSkillPresetChoices()
    local choices = {}
    for _, presetKey in ipairs(SKILL_PRESET_ORDER) do
        local preset = SKILL_PRESET_LIBRARY[presetKey]
        if preset then
            table.insert(choices, presetKey .. "=" .. preset.displayName)
        end
    end
    return table.concat(choices, ", ")
end

local function GetSkillDifficultyChoices()
    local choices = {}
    for _, difficultyKey in ipairs(SKILL_DIFFICULTY_ORDER) do
        local difficulty = SKILL_DIFFICULTY_LIBRARY[difficultyKey]
        if difficulty then
            table.insert(choices, difficultyKey .. "=" .. difficulty.displayName)
        end
    end
    return table.concat(choices, ", ")
end

local function BuildScaledPreset(preset, difficulty)
    local scaledPreset = DeepCopyTable(preset)

    for _, phasePool in pairs(scaledPreset.skillPools or {}) do
        for _, skill in ipairs(phasePool) do
            skill.minCD = ScaleCooldown(skill.minCD, difficulty.cooldownMultiplier)
            skill.maxCD = math.max(skill.minCD, ScaleCooldown(skill.maxCD, difficulty.cooldownMultiplier))
        end
    end

    for _, combo in ipairs(scaledPreset.comboChains or {}) do
        combo.cooldown = ScaleCooldown(combo.cooldown, difficulty.comboCooldownMultiplier)
        combo.triggerChance = ClampNumber((combo.triggerChance or 30) + difficulty.comboChanceOffset, 10, 80)
    end

    return scaledPreset
end

local function ApplySkillConfig(presetKey, difficultyKey)
    local resolvedPresetKey = presetKey
    local preset = SKILL_PRESET_LIBRARY[resolvedPresetKey]

    if not preset then
        resolvedPresetKey = SKILL_PRESET_ORDER[1]
        preset = SKILL_PRESET_LIBRARY[resolvedPresetKey]
    end

    local resolvedDifficultyKey = difficultyKey
    local difficulty = SKILL_DIFFICULTY_LIBRARY[resolvedDifficultyKey]

    if not difficulty then
        resolvedDifficultyKey = SKILL_DIFFICULTY_ORDER[2]
        difficulty = SKILL_DIFFICULTY_LIBRARY[resolvedDifficultyKey]
    end

    if not preset or not difficulty then
        error("技能池预设或强度档位无效")
    end

    local scaledPreset = BuildScaledPreset(preset, difficulty)

    ACTIVE_SKILL_PRESET_KEY = resolvedPresetKey
    ACTIVE_SKILL_PRESET = preset
    ACTIVE_SKILL_DIFFICULTY_KEY = resolvedDifficultyKey
    ACTIVE_SKILL_DIFFICULTY = difficulty
    SKILL_POOLS = scaledPreset.skillPools or {}
    COMBO_CHAINS = scaledPreset.comboChains or {}
    OPENING_SKILLS = scaledPreset.openingSkills or {}

    print(" [配置]已加载技能池预设: " .. resolvedPresetKey .. " (" .. preset.displayName .. ")")
    print(" [配置]预设说明: " .. preset.summary)
    print(" [配置]当前强度档位: " .. resolvedDifficultyKey .. " (" .. difficulty.displayName .. ")")
    print(" [配置]档位说明: " .. difficulty.summary)

    return resolvedPresetKey, preset, resolvedDifficultyKey, difficulty
end

local function ApplySkillPreset(presetKey)
    return ApplySkillConfig(presetKey, ACTIVE_SKILL_DIFFICULTY_KEY or BOSS_CONFIG.skillDifficulty)
end

local function ApplySkillDifficulty(difficultyKey)
    return ApplySkillConfig(ACTIVE_SKILL_PRESET_KEY or BOSS_CONFIG.skillPreset, difficultyKey)
end

ApplySkillConfig(BOSS_CONFIG.skillPreset, BOSS_CONFIG.skillDifficulty)

local function GetCurrentSkillPresetLabel()
    if not ACTIVE_SKILL_PRESET then
        return "未加载"
    end

    return ACTIVE_SKILL_PRESET_KEY .. "(" .. ACTIVE_SKILL_PRESET.displayName .. ")"
end

local function GetCurrentSkillDifficultyLabel()
    if not ACTIVE_SKILL_DIFFICULTY then
        return "未加载"
    end

    return ACTIVE_SKILL_DIFFICULTY_KEY .. "(" .. ACTIVE_SKILL_DIFFICULTY.displayName .. ")"
end

local function GetQueryString(query, columnIndex, fallbackValue)
    local success, value = pcall(function() return query:GetString(columnIndex) end)
    if success and value ~= nil then
        local text = tostring(value)
        if text ~= "" then
            return text
        end
    end

    return fallbackValue
end

local function GetQueryRawString(query, columnIndex, fallbackValue)
    local success, value = pcall(function() return query:GetString(columnIndex) end)
    if success and value ~= nil then
        return tostring(value)
    end

    return fallbackValue
end

local function GetQueryInt(query, columnIndex, fallbackValue)
    local success, value = pcall(function() return query:GetInt32(columnIndex) end)
    if success and value ~= nil then
        local numericValue = tonumber(value)
        if numericValue ~= nil then
            return numericValue
        end
    end

    return fallbackValue
end

local function GetQueryUInt(query, columnIndex, fallbackValue)
    local success, value = pcall(function() return query:GetUInt32(columnIndex) end)
    if success and value ~= nil then
        local numericValue = tonumber(value)
        if numericValue ~= nil then
            return numericValue
        end
    end

    return fallbackValue
end

local function GetQueryFloat(query, columnIndex, fallbackValue)
    local success, value = pcall(function() return query:GetFloat(columnIndex) end)
    if success and value ~= nil then
        local numericValue = tonumber(value)
        if numericValue ~= nil then
            return numericValue
        end
    end

    local stringSuccess, stringValue = pcall(function() return query:GetString(columnIndex) end)
    if stringSuccess and stringValue ~= nil then
        local numericValue = tonumber(stringValue)
        if numericValue ~= nil then
            return numericValue
        end
    end

    return fallbackValue
end

-- 按 UTF-8 边界截断，避免把多字节汉字切成半个字
-- （MySQL 严格模式下，超长或被切断的字节会让整条 INSERT 失败并静默丢事件）
local function TruncateUtf8(text, maxBytes)
    local value = tostring(text or "")
    if maxBytes == nil or maxBytes <= 0 or #value <= maxBytes then
        return value
    end

    local cut = maxBytes
    while cut > 0 do
        local nextByte = string.byte(value, cut + 1)
        if nextByte == nil or nextByte < 128 or nextByte >= 192 then
            break
        end
        cut = cut - 1
    end

    return string.sub(value, 1, cut)
end

local function BossSqlEscape(value, maxBytes)
    local text = TruncateUtf8(value, maxBytes)
    text = text:gsub("\\", "\\\\")
    text = text:gsub("'", "\\'")
    text = text:gsub("\r", "\\r")
    text = text:gsub("\n", "\\n")
    return text
end

-- ============================================================================
--  §7 配置读写（描述表驱动）
-- ----------------------------------------------------------------------------
--  §3 的 BOSS_CONFIG_SCHEMA_MAIN / _EXT 是列与运行期字段之间唯一的映射来源：
--  这里不再手写列清单、占位符顺序与 clamp，加一个配置项只需要在 §3 加一行。
--  实现细节收在 do...end 里，只对外暴露 4 个函数，避免主 chunk 局部变量过多
--  （Lua 5.2 主 chunk 最多 200 个 local）。
-- ============================================================================
local LoadBossConfigFromDB, PersistBossConfigToDB, ShowBossConfigGroups, ShowBossConfigGroup
do
    -- ---------------------------------------------------------------- 取值与格式化
    -- 每条描述表项在 SQL 里的取值：既用于写库，也用于 `.boss config show` 展示
    local function ToSqlLiteral(descriptor, value)
        local kind = descriptor.kind

        if kind == "int" then
            return tostring(ClampInteger(value, descriptor.min, descriptor.max))
        end

        if kind == "bool" then
            return value and "1" or "0"
        end

        if kind == "scaled" then
            return tostring(ClampInteger(RoundToScaledInteger(value), descriptor.min, descriptor.max))
        end

        if kind == "intlist" then
            return "'" .. BossSqlEscape(SerializePositiveIntegerList(value)) .. "'"
        end

        if kind == "lines" then
            return "'" .. BossSqlEscape(SerializeLineList(value)) .. "'"
        end

        if kind == "keyedlines" or kind == "keyedword" then
            return "'" .. BossSqlEscape(SerializeKeyedLines(value)) .. "'"
        end

        if kind == "keyedintlist" then
            return "'" .. BossSqlEscape(SerializeKeyedIntegerLists(value)) .. "'"
        end

        if kind == "spawnpoints" then
            return "'" .. BossSqlEscape(SerializeSpawnPoints(value)) .. "'"
        end

        -- text / text_keep
        return "'" .. BossSqlEscape(value, 255) .. "'"
    end

    -- 该列在「列缺失/null」时的兜底文本（用于 GetQueryRawString 的 fallback）
    local function FallbackText(descriptor, currentValue)
        local kind = descriptor.kind

        if kind == "intlist" then
            return SerializePositiveIntegerList(currentValue)
        end

        if kind == "lines" then
            return SerializeLineList(currentValue)
        end

        if kind == "keyedlines" or kind == "keyedword" then
            return SerializeKeyedLines(currentValue)
        end

        if kind == "keyedintlist" then
            return SerializeKeyedIntegerLists(currentValue)
        end

        if kind == "spawnpoints" then
            -- 与旧版一致：该列为 NULL 时回退到「文件内的默认刷新点」
            return SerializeSpawnPoints(DEFAULT_SPAWN_POINTS)
        end

        return tostring(currentValue or "")
    end

    -- 把一列的值解析成运行期结构；解析不出有效内容时按 keepDefaultWhenEmpty 决定
    -- 是保留当前值（列表类）还是接受空值（喊话/嘲讽允许清空）。
    local function ParseColumnValue(descriptor, query, columnIndex, currentValue)
        local kind = descriptor.kind

        if kind == "int" then
            return ClampInteger(GetQueryUInt(query, columnIndex, currentValue or 0), descriptor.min, descriptor.max)
        end

        if kind == "scaled" then
            local scaled = GetQueryInt(query, columnIndex, RoundToScaledInteger(currentValue))
            return math.max(0.1, ScaledIntegerToNumber(scaled, currentValue))
        end

        if kind == "bool" then
            return GetQueryUInt(query, columnIndex, currentValue and 1 or 0) == 1
        end

        if kind == "text_keep" then
            -- 空字符串视为「未配置」，保留当前值（与旧版 GetQueryString 语义一致）
            return GetQueryString(query, columnIndex, currentValue)
        end

        local rawText = GetQueryRawString(query, columnIndex, FallbackText(descriptor, currentValue))

        if kind == "intlist" or kind == "spawnpoints" then
            local list
            if kind == "spawnpoints" then
                list = ParseSpawnPointsText(rawText, DEFAULT_SPAWN_POINTS)
            else
                list = ParsePositiveIntegerList(rawText)
            end
            if #list == 0 and descriptor.keepDefaultWhenEmpty then
                return currentValue
            end
            return list
        end

        local parsed
        if kind == "lines" then
            parsed = ParseLineList(rawText)
        elseif kind == "keyedlines" or kind == "keyedword" then
            parsed = ParseKeyedLines(rawText)
        elseif kind == "keyedintlist" then
            parsed = ParseKeyedIntegerLists(rawText)
        else
            return rawText
        end

        if next(parsed) == nil and descriptor.keepDefaultWhenEmpty then
            return currentValue
        end

        return parsed
    end

    -- ---------------------------------------------------------------- SQL 构造
    local function BuildBossSelectSql(tableName, descriptors)
        -- 不带 state_key：WHERE 已经限定了行，取值下标与描述表顺序一一对应
        local columns = {}
        for _, descriptor in ipairs(descriptors) do
            columns[#columns + 1] = '`' .. descriptor.column .. '`'
        end

        return string.format(
            "SELECT %s FROM `%s`.`%s` WHERE `state_key` = '%s' LIMIT 1;",
            table.concat(columns, ", "),
            BOSS_DB_NAME,
            tableName,
            BOSS_CONFIG_KEY
        )
    end

    local function BuildBossUpsertSql(tableName, descriptors, insertIgnore)
        local columns = { '`state_key`' }
        local values = { "'" .. BOSS_CONFIG_KEY .. "'" }
        local updates = {}

        for _, descriptor in ipairs(descriptors) do
            columns[#columns + 1] = '`' .. descriptor.column .. '`'
            values[#values + 1] = ToSqlLiteral(descriptor, GetConfigTargetValue(descriptor))
            updates[#updates + 1] = '`' .. descriptor.column .. '`=VALUES(`' .. descriptor.column .. '`)'
        end

        columns[#columns + 1] = '`updated_at`'
        values[#values + 1] = tostring(BossNow())
        updates[#updates + 1] = '`updated_at`=VALUES(`updated_at`)'

        local head = insertIgnore and "INSERT IGNORE INTO" or "INSERT INTO"
        local sql = string.format(
            "%s `%s`.`%s` (%s) VALUES (%s)",
            head,
            BOSS_DB_NAME,
            tableName,
            table.concat(columns, ", "),
            table.concat(values, ", ")
        )

        if not insertIgnore then
            -- 显式列出要更新的列：面板/其它工具写在同表上的列不会被顺手清掉
            sql = sql .. " ON DUPLICATE KEY UPDATE " .. table.concat(updates, ", ")
        end

        return sql .. ";"
    end

    local function ApplyBossConfigQuery(descriptors, query)
        for index, descriptor in ipairs(descriptors) do
            local currentValue = GetConfigTargetValue(descriptor)
            -- GetQuery*(query, columnIndex) 的下标从 0 开始
            local parsed = ParseColumnValue(descriptor, query, index - 1, currentValue)
            SetConfigTargetValue(descriptor, parsed)
        end
    end

    -- 列之间的约束与技能池应用（与旧版手写逻辑一致）
    local function FinalizeBossConfig()
        BOSS_CONFIG.minionCountMax = math.max(BOSS_CONFIG.minionCountMin, BOSS_CONFIG.minionCountMax)
        REWARD_GOLD.maxCopper = math.max(REWARD_GOLD.minCopper, REWARD_GOLD.maxCopper)

        REWARD_PROBABILITIES:validate()

        ApplySkillConfig(BOSS_CONFIG.skillPreset, BOSS_CONFIG.skillDifficulty)
        BOSS_CONFIG.skillPreset = ACTIVE_SKILL_PRESET_KEY or BOSS_CONFIG.skillPreset
        BOSS_CONFIG.skillDifficulty = ACTIVE_SKILL_DIFFICULTY_KEY or BOSS_CONFIG.skillDifficulty

        -- 运行期只保留配置里的那一个候选（BOSS_CANDIDATES 是 main 表 entry/name 的容器）
        local configuredEntry = tonumber(BOSS_CANDIDATES[1] and BOSS_CANDIDATES[1].entry or 0) or 0
        local configuredName = ResolveBossCandidateName(configuredEntry, BOSS_CANDIDATES[1] and BOSS_CANDIDATES[1].name)

        BOSS_CANDIDATES = {
            {entry = configuredEntry, name = configuredName},
        }

        if activeBossInfo and tonumber(activeBossInfo.entry or 0) == configuredEntry then
            activeBossInfo.name = configuredName
        end

        return configuredEntry, configuredName
    end

    -- ---------------------------------------------------------------- 展示（GM 命令）
    local function DescribeConfigValue(descriptor, value)
        local kind = descriptor.kind

        if kind == "bool" then
            return value and "true" or "false"
        end

        if kind == "scaled" then
            return string.format("%.2f", tonumber(value) or 0)
        end

        if kind == "int" then
            return tostring(math.floor(tonumber(value) or 0))
        end

        if kind == "intlist" then
            return SerializePositiveIntegerList(value)
        end

        if kind == "lines" then
            local list = type(value) == "table" and value or {}
            return string.format("%d 条：%s", #list, table.concat(list, " / "))
        end

        if kind == "keyedlines" or kind == "keyedword" then
            local text = SerializeKeyedLines(value)
            return text ~= "" and ("{" .. text:gsub("\n", "; ") .. "}") or "{}"
        end

        if kind == "keyedintlist" then
            local text = SerializeKeyedIntegerLists(value)
            return text ~= "" and ("{" .. text:gsub("\n", "; ") .. "}") or "{}"
        end

        if kind == "spawnpoints" then
            local points = type(value) == "table" and value or {}
            return string.format("%d 个刷新点", #points)
        end

        local text = tostring(value or "")
        return text ~= "" and text or "(空)"
    end

    local function FormatConfigLine(descriptor, value)
        local text = DescribeConfigValue(descriptor, value)
        if #text > 120 then
            text = TruncateUtf8(text, 108) .. "..."
        end

        return string.format("  %s (%s) = %s", descriptor.column, descriptor.key or "-", text)
    end

    -- ---------------------------------------------------------------- 对外接口
    ShowBossConfigGroups = function(player, chatHandler)
        BossReply(player, chatHandler, true, "Boss 配置分组（用法: .boss config show <group>）：")

        for _, groupKey in ipairs(BOSS_CONFIG_GROUP_ORDER) do
            local count = 0
            for _, descriptor in ipairs(BOSS_CONFIG_SCHEMA_MAIN) do
                if descriptor.group == groupKey then count = count + 1 end
            end
            for _, descriptor in ipairs(BOSS_CONFIG_SCHEMA_EXT) do
                if descriptor.group == groupKey then count = count + 1 end
            end

            if count > 0 then
                BossSendMessage(player, chatHandler, string.format(
                    "  %s = %s（%d 项）",
                    groupKey,
                    BOSS_CONFIG_GROUPS[groupKey] or groupKey,
                    count))
            end
        end

        BossSendMessage(player, chatHandler, "取值来源: " .. BOSS_DB_NAME .. "." .. BOSS_MAIN_TABLE .. " + " .. BOSS_EXT_TABLE
            .. "（面板可改主表；ext 表是脚本私有配置）")
    end

    ShowBossConfigGroup = function(player, chatHandler, groupKey)
        local descriptors = {}
        for _, descriptor in ipairs(BOSS_CONFIG_SCHEMA_MAIN) do
            if descriptor.group == groupKey then descriptors[#descriptors + 1] = descriptor end
        end
        for _, descriptor in ipairs(BOSS_CONFIG_SCHEMA_EXT) do
            if descriptor.group == groupKey then descriptors[#descriptors + 1] = descriptor end
        end

        if #descriptors == 0 then
            BossReply(player, chatHandler, false, "没有这个配置分组：" .. tostring(groupKey))
            ShowBossConfigGroups(player, chatHandler)
            return false
        end

        BossReply(player, chatHandler, true, string.format(
            "配置分组 %s（%s），共 %d 项：",
            groupKey,
            BOSS_CONFIG_GROUPS[groupKey] or groupKey,
            #descriptors))

        for _, descriptor in ipairs(descriptors) do
            BossSendMessage(player, chatHandler, FormatConfigLine(descriptor, GetConfigTargetValue(descriptor)))
        end

        return true
    end

    -- insertIgnore = true：引导写入，只在「数据库里还没有这一行」时补默认值
    -- insertIgnore = false：把当前运行期配置写回（切换技能池/档位时用）
    PersistBossConfigToDB = function(insertIgnore)
        EnsureBossSchema()
        REWARD_PROBABILITIES:validate()

        CharDBExecute(BuildBossUpsertSql(BOSS_MAIN_TABLE, BOSS_CONFIG_SCHEMA_MAIN, insertIgnore))
        CharDBExecute(BuildBossUpsertSql(BOSS_EXT_TABLE, BOSS_CONFIG_SCHEMA_EXT, insertIgnore))
    end

    LoadBossConfigFromDB = function()
        EnsureBossSchema()

        -- 1) 引导：缺行时把 §3 的默认值写进两张表（已有配置不会被覆盖）
        PersistBossConfigToDB(true)

        -- 2) 主表（与 AGMP 面板共享）读不到就保持内存配置，返回 false 让调用方提示失败
        local mainQuery = CharDBQuery(BuildBossSelectSql(BOSS_MAIN_TABLE, BOSS_CONFIG_SCHEMA_MAIN))
        if mainQuery == nil then
            print(" [配置]无法读取 " .. BOSS_MAIN_TABLE .. "，继续使用当前内存配置。")
            REWARD_PROBABILITIES:validate()
            ApplySkillConfig(BOSS_CONFIG.skillPreset, BOSS_CONFIG.skillDifficulty)
            return false
        end

        ApplyBossConfigQuery(BOSS_CONFIG_SCHEMA_MAIN, mainQuery)

        -- 3) 扩展表：读不到时保留文件内默认值（例如脚本刚升级、表还没建）
        local extQuery = CharDBQuery(BuildBossSelectSql(BOSS_EXT_TABLE, BOSS_CONFIG_SCHEMA_EXT))
        if extQuery ~= nil then
            ApplyBossConfigQuery(BOSS_CONFIG_SCHEMA_EXT, extQuery)
        else
            print(" [配置]未读取到 " .. BOSS_EXT_TABLE .. "，喊话/嘲讽/巡逻等使用文件内默认值。")
        end

        local configuredEntry, configuredName = FinalizeBossConfig()

        print(string.format(
            " [配置]已从 %s 载入配置: 主表 %d 项 + 扩展表 %d 项；Entry=%d, 名称=%s, 刷新点=%d, 技能池=%s, 强度=%s",
            BOSS_DB_NAME,
            #BOSS_CONFIG_SCHEMA_MAIN,
            #BOSS_CONFIG_SCHEMA_EXT,
            configuredEntry,
            configuredName,
            #SPAWN_POINTS,
            GetCurrentSkillPresetLabel(),
            GetCurrentSkillDifficultyLabel()))

        return true
    end
end

LoadBossConfigFromDB()

-- ========== 全局状态变量 ==========
local scriptSpawnedBossGUIDs = {}
local bossAllySpawned = {}
local bossAIStates = {}
local bossTraitsApplied = {}
local bossBaseMaxHealth = {}
local currentActiveBossGUID = nil
activeBossInfo = nil
local activeBossCreature = nil
local respawnTimerEventId = nil
local bossRewardedGUIDs = {}
local bossThreatSnapshots = {}
local bossMinionStates = {}
local bossContributionStats = {}
local bossRuntimeState = {
    status = "idle",
    phase = 0,
    respawnAt = 0,
    lastSpawnAt = 0,
    lastEngageAt = 0,
    lastDeathAt = 0,
    lastResetAt = 0,
}

-- ========== 工具函数 ==========

-- 基础验证函数（必须在其他工具函数之前定义）
local function IsUnitValid(unit)
    if not unit or type(unit) ~= "userdata" then return false end
    local success, result = pcall(function() return unit:IsInWorld() end)
    return success and (result == true)
end

local function SafeGetUnitName(unit)
    if not IsUnitValid(unit) then return "<无效对象>" end
    local success, result = pcall(function() return unit:GetName() end)
    if success then return result or "<未知对象>" else return "<失效对象>" end
end

local function SafeGetDistance(source, target)
    if not IsUnitValid(source) or not IsUnitValid(target) then return nil end
    local success, dist = pcall(function() return source:GetDistance(target) end)
    if success then return dist end
    return nil
end

local function SafeGetGuidLow(unit)
    if not IsUnitValid(unit) then return 0 end

    local success, guidLow = pcall(function() return unit:GetGUIDLow() end)
    if success and guidLow ~= nil then
        return tonumber(guidLow) or 0
    end

    return 0
end

-- 回复走「玩家广播 → chatHandler → 控制台」三级回退；前置声明的 local 在这里赋值
BossSendMessage = function(player, chatHandler, message)
    if player and player.SendBroadcastMessage then
        player:SendBroadcastMessage(message)
        return
    end

    if chatHandler and chatHandler.SendSysMessage then
        chatHandler:SendSysMessage(message)
        return
    end

    basePrint(message)
end

BossReply = function(player, chatHandler, success, message)
    local finalMessage = tostring(message or "")
    if player == nil then
        local marker = success and "[AGMP_OK] " or "[AGMP_ERROR] "
        BossSendMessage(player, chatHandler, marker .. finalMessage)
        return
    end

    BossSendMessage(player, chatHandler, finalMessage)
end

local function BuildCommandActor(player)
    if IsUnitValid(player) then
        return SafeGetUnitName(player), SafeGetGuidLow(player)
    end

    return "worldserver console", 0
end

local function BossJsonEscape(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')
    text = text:gsub("\r", "\\r")
    text = text:gsub("\n", "\\n")
    return text
end

local function BossJsonEncode(value)
    local valueType = type(value)
    if valueType == "nil" then
        return "null"
    end

    if valueType == "number" then
        return tostring(value)
    end

    if valueType == "boolean" then
        return value and "true" or "false"
    end

    if valueType == "string" then
        return '"' .. BossJsonEscape(value) .. '"'
    end

    if valueType == "table" then
        local maxIndex = 0
        local isArray = true
        for key, _ in pairs(value) do
            if type(key) ~= "number" then
                isArray = false
                break
            end
            if key > maxIndex then
                maxIndex = key
            end
        end

        local parts = {}
        if isArray then
            for index = 1, maxIndex do
                table.insert(parts, BossJsonEncode(value[index]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end

        for key, item in pairs(value) do
            table.insert(parts, BossJsonEncode(tostring(key)) .. ":" .. BossJsonEncode(item))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    return '"' .. BossJsonEscape(tostring(value)) .. '"'
end

local function ResolveBossContext(source)
    local context = {
        bossGuid = 0,
        bossEntry = 0,
        bossName = "",
        mapId = 0,
        instanceId = 0,
        homeX = 0,
        homeY = 0,
        homeZ = 0,
    }

    if type(source) == "table" and source.bossEntry ~= nil then
        return source
    end

    if IsUnitValid(source) then
        context.bossGuid = SafeGetGuidLow(source)
        context.bossEntry = tonumber(source:GetEntry() or 0) or 0
        context.bossName = ResolveBossCandidateName(context.bossEntry, tostring(source:GetName() or ""))
        context.mapId = tonumber(source:GetMapId() or 0) or 0
        context.instanceId = tonumber(source:GetInstanceId() or 0) or 0
        context.homeX = tonumber(source:GetX() or 0) or 0
        context.homeY = tonumber(source:GetY() or 0) or 0
        context.homeZ = tonumber(source:GetZ() or 0) or 0
    end

    if activeBossInfo then
        if context.bossGuid == 0 then context.bossGuid = tonumber(activeBossInfo.guid or 0) or 0 end
        if context.bossEntry == 0 then context.bossEntry = tonumber(activeBossInfo.entry or 0) or 0 end
        if context.bossName == "" then context.bossName = tostring(activeBossInfo.name or "") end
        if context.mapId == 0 then context.mapId = tonumber(activeBossInfo.mapId or 0) or 0 end
        if context.instanceId == 0 then context.instanceId = tonumber(activeBossInfo.instanceId or 0) or 0 end
        if activeBossInfo.homeX ~= nil then context.homeX = tonumber(activeBossInfo.homeX) or 0 end
        if activeBossInfo.homeY ~= nil then context.homeY = tonumber(activeBossInfo.homeY) or 0 end
        if activeBossInfo.homeZ ~= nil then context.homeZ = tonumber(activeBossInfo.homeZ) or 0 end
    end

    return context
end

local function PersistBossRuntime(source, overrides)
    EnsureBossSchema()
    local context = ResolveBossContext(source)
    overrides = overrides or {}

    if overrides.status ~= nil then bossRuntimeState.status = overrides.status end
    if overrides.phase ~= nil then bossRuntimeState.phase = overrides.phase end
    if overrides.respawn_at ~= nil then bossRuntimeState.respawnAt = overrides.respawn_at end
    if overrides.last_spawn_at ~= nil then bossRuntimeState.lastSpawnAt = overrides.last_spawn_at end
    if overrides.last_engage_at ~= nil then bossRuntimeState.lastEngageAt = overrides.last_engage_at end
    if overrides.last_death_at ~= nil then bossRuntimeState.lastDeathAt = overrides.last_death_at end
    if overrides.last_reset_at ~= nil then bossRuntimeState.lastResetAt = overrides.last_reset_at end

    local bossGuid = overrides.boss_guid
    if bossGuid == nil then bossGuid = context.bossGuid or 0 end

    local bossEntry = overrides.boss_entry
    if bossEntry == nil then bossEntry = context.bossEntry or 0 end

    local bossName = overrides.boss_name
    if bossName == nil then bossName = context.bossName or "" end

    local mapId = overrides.map_id
    if mapId == nil then mapId = context.mapId or 0 end

    local instanceId = overrides.instance_id
    if instanceId == nil then instanceId = context.instanceId or 0 end

    local homeX = overrides.home_x
    if homeX == nil then homeX = context.homeX or 0 end

    local homeY = overrides.home_y
    if homeY == nil then homeY = context.homeY or 0 end

    local homeZ = overrides.home_z
    if homeZ == nil then homeZ = context.homeZ or 0 end

    local skillPreset = overrides.skill_preset
    if skillPreset == nil then skillPreset = ACTIVE_SKILL_PRESET_KEY or BOSS_CONFIG.skillPreset or "" end

    local skillDifficulty = overrides.skill_difficulty
    if skillDifficulty == nil then skillDifficulty = ACTIVE_SKILL_DIFFICULTY_KEY or BOSS_CONFIG.skillDifficulty or "" end

    local sql = string.format(
        "REPLACE INTO `%s`.`boss_activity_runtime` ("
            .. "`state_key`, `boss_guid`, `boss_entry`, `boss_name`, `map_id`, `instance_id`, "
            .. "`home_x`, `home_y`, `home_z`, `phase`, `status`, `skill_preset`, `skill_difficulty`, "
            .. "`respawn_at`, `last_spawn_at`, `last_engage_at`, `last_death_at`, `last_reset_at`, `updated_at`) "
            .. "VALUES ('%s', %d, %d, '%s', %d, %d, %.3f, %.3f, %.3f, %d, '%s', '%s', '%s', %d, %d, %d, %d, %d, %d);",
        BOSS_DB_NAME,
        BOSS_RUNTIME_KEY,
        tonumber(bossGuid or 0) or 0,
        tonumber(bossEntry or 0) or 0,
        BossSqlEscape(bossName or "", 120),
        tonumber(mapId or 0) or 0,
        tonumber(instanceId or 0) or 0,
        tonumber(homeX or 0) or 0,
        tonumber(homeY or 0) or 0,
        tonumber(homeZ or 0) or 0,
        tonumber(bossRuntimeState.phase or 0) or 0,
        BossSqlEscape(bossRuntimeState.status or "idle", 32),
        BossSqlEscape(skillPreset or "", 64),
        BossSqlEscape(skillDifficulty or "", 64),
        tonumber(bossRuntimeState.respawnAt or 0) or 0,
        tonumber(bossRuntimeState.lastSpawnAt or 0) or 0,
        tonumber(bossRuntimeState.lastEngageAt or 0) or 0,
        tonumber(bossRuntimeState.lastDeathAt or 0) or 0,
        tonumber(bossRuntimeState.lastResetAt or 0) or 0,
        BossNow()
    )

    CharDBExecute(sql)
end

local function BossStatusIndicatesActive(status)
    local normalizedStatus = tostring(status or "")
    return normalizedStatus == "spawned" or normalizedStatus == "engaged"
end

-- mod-ale（Eluna）**没有** GetCreatureByGUID 这个全局函数：
-- 正确做法是用 GetUnitGUID(lowguid, entry) 拼出完整 ObjectGuid，
-- 再从地图取回对象（Map:GetWorldObject 内部走 Map::GetCreature，_objectsStore 里含召唤物）。
local function TryGetCreatureByGUID(guid, entry, mapId, instanceId)
    local numericGuid = tonumber(guid) or 0
    local numericEntry = tonumber(entry) or 0
    local numericMapId = tonumber(mapId) or 0
    local numericInstanceId = tonumber(instanceId) or 0
    if numericGuid <= 0 or numericEntry <= 0 or numericMapId <= 0 then
        return nil
    end

    local success, creature = pcall(function()
        local map = GetMapById(numericMapId, numericInstanceId)
        if not map then
            return nil
        end

        return map:GetWorldObject(GetUnitGUID(numericGuid, numericEntry))
    end)

    if success and IsUnitValid(creature) and IsManagedBossEntry(creature:GetEntry()) then
        return creature
    end

    return nil
end

local function LoadBossRuntimeFromDB()
    EnsureBossSchema()

    local query = CharDBQuery(string.format(
        "SELECT `boss_guid`, `boss_entry`, `boss_name`, `map_id`, `instance_id`, `home_x`, `home_y`, `home_z`, `phase`, `status`, `respawn_at`, `last_spawn_at`, `last_engage_at`, `last_death_at`, `last_reset_at` FROM `%s`.`boss_activity_runtime` WHERE `state_key`='%s' LIMIT 1;",
        BOSS_DB_NAME,
        BOSS_RUNTIME_KEY
    ))

    if not query then
        return false
    end

    local runtimeGuid = GetQueryUInt(query, 0, 0)
    local runtimeEntry = GetQueryUInt(query, 1, 0)
    local runtimeName = GetQueryString(query, 2, "")
    local runtimeMapId = GetQueryUInt(query, 3, 0)
    local runtimeInstanceId = GetQueryUInt(query, 4, 0)
    local runtimeHomeX = GetQueryFloat(query, 5, 0)
    local runtimeHomeY = GetQueryFloat(query, 6, 0)
    local runtimeHomeZ = GetQueryFloat(query, 7, 0)
    local runtimePhase = GetQueryUInt(query, 8, 0)
    local runtimeStatus = GetQueryString(query, 9, "idle")
    local runtimeRespawnAt = GetQueryUInt(query, 10, 0)
    local runtimeLastSpawnAt = GetQueryUInt(query, 11, 0)
    local runtimeLastEngageAt = GetQueryUInt(query, 12, 0)
    local runtimeLastDeathAt = GetQueryUInt(query, 13, 0)
    local runtimeLastResetAt = GetQueryUInt(query, 14, 0)

    bossRuntimeState.phase = runtimePhase
    bossRuntimeState.status = runtimeStatus
    bossRuntimeState.respawnAt = runtimeRespawnAt
    bossRuntimeState.lastSpawnAt = runtimeLastSpawnAt
    bossRuntimeState.lastEngageAt = runtimeLastEngageAt
    bossRuntimeState.lastDeathAt = runtimeLastDeathAt
    bossRuntimeState.lastResetAt = runtimeLastResetAt

    if runtimeGuid > 0 and runtimeEntry > 0 and BossStatusIndicatesActive(runtimeStatus) then
        currentActiveBossGUID = runtimeGuid
        activeBossCreature = nil
        activeBossInfo = {
            guid = runtimeGuid,
            entry = runtimeEntry,
            name = ResolveBossCandidateName(runtimeEntry, runtimeName),
            x = runtimeHomeX,
            y = runtimeHomeY,
            z = runtimeHomeZ,
            mapId = runtimeMapId,
            instanceId = runtimeInstanceId,
            homeX = runtimeHomeX,
            homeY = runtimeHomeY,
            homeZ = runtimeHomeZ,
            homeO = 0,
        }
    else
        ClearActiveBoss()
    end

    return true
end

    InsertBossEvent = function(source, eventType, eventNote, actorName, actorGuid, payload)
    EnsureBossSchema()
    local context = ResolveBossContext(source)
    local sql = string.format(
        "INSERT INTO `%s`.`boss_activity_events` ("
            .. "`boss_guid`, `boss_entry`, `boss_name`, `event_type`, `event_note`, `actor_name`, `actor_guid`, `payload_json`, `created_at`) "
            .. "VALUES (%d, %d, '%s', '%s', '%s', '%s', %d, '%s', %d);",
        BOSS_DB_NAME,
        tonumber(context.bossGuid or 0) or 0,
        tonumber(context.bossEntry or 0) or 0,
        BossSqlEscape(context.bossName or "", 120),
        BossSqlEscape(eventType or "", 32),
        BossSqlEscape(eventNote or "", 255),
        BossSqlEscape(actorName or "", 120),
        tonumber(actorGuid or 0) or 0,
        BossSqlEscape(BossJsonEncode(payload or {})),
        BossNow()
    )

    CharDBExecute(sql)
end

local function BuildSafeThreatList(unit, cachedThreatList)
    if not IsUnitValid(unit) then return {} end

    local rawThreatList = cachedThreatList
    if type(rawThreatList) ~= "table" then
        local success, threatList = pcall(function()
            if unit.GetThreatList then
                return unit:GetThreatList()
            end
            return unit:GetAITargets()
        end)

        if success then
            rawThreatList = threatList
        end
    end

    local threatList = {}
    if type(rawThreatList) == "table" then
        for _, threatUnit in ipairs(rawThreatList) do
            if IsUnitValid(threatUnit) then
                table.insert(threatList, threatUnit)
            end
        end
    end

    if #threatList == 0 then
        local successVictim, victim = pcall(function() return unit:GetVictim() end)
        if successVictim and IsUnitValid(victim) then
            table.insert(threatList, victim)
        end
    end

    return threatList
end

-- 受管 entry：当前配置的候选 + 本模块全部强度档位模板
-- （档位由面板切换，旧档位残留的 Boss 仍需被识别、清理与结算）
IsManagedBossEntry = function(entry)
    local numericEntry = tonumber(entry) or 0
    for _, bossCandidate in ipairs(BOSS_CANDIDATES) do
        if tonumber(bossCandidate.entry or 0) == numericEntry then
            return true
        end
    end

    for _, tierEntry in ipairs(BOSS_TIER_ENTRIES) do
        if tierEntry == numericEntry then
            return true
        end
    end

    return false
end

local function SafeGetPlayerByGUID(guid)
    if not guid then return nil end
    local success, player = pcall(function() return GetPlayerByGUID(guid) end)
    if success and player and IsUnitValid(player) then
        return player
    end
    return nil
end

local function ResolvePlayerContributor(unit)
    if not IsUnitValid(unit) then return nil end

    local successPlayer, isPlayer = pcall(function() return unit:IsPlayer() end)
    if successPlayer and isPlayer then
        return unit
    end

    local successOwner, owner = pcall(function() return unit:GetOwner() end)
    if successOwner and IsUnitValid(owner) then
        local ownerIsPlayer = false
        local successOwnerPlayer, ownerPlayerResult = pcall(function() return owner:IsPlayer() end)
        if successOwnerPlayer and ownerPlayerResult then
            ownerIsPlayer = true
        end
        if ownerIsPlayer then
            return owner
        end
    end

    local controllerGuid = nil
    local successController = pcall(function() controllerGuid = unit:GetControllerGUID() end)
    if successController and controllerGuid then
        return SafeGetPlayerByGUID(controllerGuid)
    end

    return nil
end

local function IsWithinActiveEncounterRange(unit, range)
    if not IsUnitValid(unit) or not activeBossInfo then return false end

    local successMap, mapId = pcall(function() return unit:GetMapId() end)
    if not successMap or mapId ~= activeBossInfo.mapId then
        return false
    end

    local dx = unit:GetX() - activeBossInfo.x
    local dy = unit:GetY() - activeBossInfo.y
    local distance = math.sqrt((dx * dx) + (dy * dy))
    return distance <= (range or REWARD_PROBABILITIES.participationRange)
end

local function EnsureContributionState(bossGuid)
    if not bossContributionStats[bossGuid] then
        bossContributionStats[bossGuid] = {
            players = {},
            totalDamage = 0,
            totalHealing = 0,
            totalThreatSamples = 0,
            totalPresenceSamples = 0,
        }
    end

    return bossContributionStats[bossGuid]
end

local function GetContributionIdentity(player)
    local guid = nil
    local guidLow = nil
    pcall(function() guid = player:GetGUID() end)
    pcall(function() guidLow = player:GetGUIDLow() end)
    return tostring(guidLow or guid or 0), guid, guidLow
end

local function GetOrCreateContributionRecord(bossGuid, player)
    if not IsUnitValid(player) then return nil, nil end

    local state = EnsureContributionState(bossGuid)
    local key, guid, guidLow = GetContributionIdentity(player)
    local accountId = 0
    pcall(function() accountId = tonumber(player:GetAccountId() or 0) or 0 end)
    local record = state.players[key]
    if not record then
        record = {
            key = key,
            guid = guid,
            guidLow = guidLow,
            accountId = accountId,
            name = SafeGetUnitName(player),
            damageDone = 0,
            healingDone = 0,
            threatSamples = 0,
            presenceSamples = 0,
            isKiller = false,
        }
        state.players[key] = record
    end

    record.guid = record.guid or guid
    record.guidLow = record.guidLow or guidLow
    if (record.accountId or 0) <= 0 and accountId > 0 then
        record.accountId = accountId
    end
    record.name = SafeGetUnitName(player)
    return state, record
end

local function AddContributionMetrics(bossGuid, player, metrics)
    local state, record = GetOrCreateContributionRecord(bossGuid, player)
    if not record then return end

    if metrics.damage and metrics.damage > 0 then
        record.damageDone = record.damageDone + metrics.damage
        state.totalDamage = state.totalDamage + metrics.damage
    end

    if metrics.healing and metrics.healing > 0 then
        record.healingDone = record.healingDone + metrics.healing
        state.totalHealing = state.totalHealing + metrics.healing
    end

    if metrics.threat and metrics.threat > 0 then
        record.threatSamples = record.threatSamples + metrics.threat
        state.totalThreatSamples = state.totalThreatSamples + metrics.threat
    end

    if metrics.presence and metrics.presence > 0 then
        record.presenceSamples = record.presenceSamples + metrics.presence
        state.totalPresenceSamples = state.totalPresenceSamples + metrics.presence
    end

    if metrics.isKiller then
        record.isKiller = true
    end
end

local function TrackEncounterPresence(creature, threatList)
    if not IsUnitValid(creature) then return end

    local bossGuid = creature:GetGUIDLow()
    for _, player in ipairs(BuildNearbyPlayerList(creature, REWARD_PROBABILITIES.participationRange)) do
        AddContributionMetrics(bossGuid, player, {presence = 1})
    end

    if threatList then
        for _, unit in ipairs(threatList) do
            local player = ResolvePlayerContributor(unit)
            if player then
                AddContributionMetrics(bossGuid, player, {threat = 1, presence = 1})
            end
        end
    end
end

local function ComputeContributionScore(record, state)
    local damageShare = state.totalDamage > 0 and (record.damageDone / state.totalDamage) or 0
    local healingShare = state.totalHealing > 0 and (record.healingDone / state.totalHealing) or 0
    local threatShare = state.totalThreatSamples > 0 and (record.threatSamples / state.totalThreatSamples) or 0
    local presenceShare = state.totalPresenceSamples > 0 and (record.presenceSamples / state.totalPresenceSamples) or 0

    local score = 0
    score = score + damageShare * REWARD_PROBABILITIES.damageWeight
    score = score + healingShare * REWARD_PROBABILITIES.healingWeight
    score = score + threatShare * REWARD_PROBABILITIES.threatWeight
    score = score + presenceShare * REWARD_PROBABILITIES.presenceWeight
    if record.isKiller then
        score = score + REWARD_PROBABILITIES.killWeight
    end

    return score
end

local function BuildContributorRewardPool(bossGuid, killer)
    local state = bossContributionStats[bossGuid]
    if not state then
        return {}, nil
    end

    local killerPlayer = ResolvePlayerContributor(killer)
    if killerPlayer then
        AddContributionMetrics(bossGuid, killerPlayer, {isKiller = true, presence = 1})
    end

    local contributors = {}
    for _, record in pairs(state.players) do
        local hasCoreContribution = record.damageDone > 0 or record.healingDone > 0 or record.threatSamples > 0 or record.isKiller
        if hasCoreContribution then
            local player = record.guid and SafeGetPlayerByGUID(record.guid) or nil
            if player then
                local score = ComputeContributionScore(record, state)
                table.insert(contributors, {
                    player = player,
                    score = score,
                    record = record,
                })
            end
        end
    end

    table.sort(contributors, function(a, b)
        if math.abs(a.score - b.score) < 0.0001 then
            return a.record.damageDone > b.record.damageDone
        end
        return a.score > b.score
    end)

    return contributors, state
end

local function InsertBossContributorSnapshot(source, record, score, rewardedRandom, guaranteedReward, createdAt)
    EnsureBossSchema()
    local context = ResolveBossContext(source)
    local sql = string.format(
        "INSERT INTO `%s`.`boss_activity_contributors` ("
            .. "`boss_guid`, `boss_entry`, `boss_name`, `player_guid`, `player_name`, `account_id`, `damage_done`, `healing_done`, "
            .. "`threat_samples`, `presence_samples`, `contribution_score`, `was_killer`, `rewarded_random`, `guaranteed_reward`, `created_at`) "
            .. "VALUES (%d, %d, '%s', %d, '%s', %d, %d, %d, %d, %d, %.6f, %d, %d, %d, %d);",
        BOSS_DB_NAME,
        tonumber(context.bossGuid or 0) or 0,
        tonumber(context.bossEntry or 0) or 0,
        BossSqlEscape(context.bossName or "", 120),
        tonumber(record.guidLow or 0) or 0,
        BossSqlEscape(record.name or "", 120),
        tonumber(record.accountId or 0) or 0,
        tonumber(record.damageDone or 0) or 0,
        tonumber(record.healingDone or 0) or 0,
        tonumber(record.threatSamples or 0) or 0,
        tonumber(record.presenceSamples or 0) or 0,
        tonumber(score or 0) or 0,
        record.isKiller and 1 or 0,
        rewardedRandom and 1 or 0,
        guaranteedReward and 1 or 0,
        tonumber(createdAt or BossNow()) or BossNow()
    )

    CharDBExecute(sql)
end

local function PersistBossContributorSnapshots(source, state, rewardedRandomKeys, guaranteedRewardKeys, createdAt)
    if not state or not state.players then return end

    for key, record in pairs(state.players) do
        local hasContribution = (record.damageDone or 0) > 0
            or (record.healingDone or 0) > 0
            or (record.threatSamples or 0) > 0
            or (record.presenceSamples or 0) > 0
            or record.isKiller

        if hasContribution then
            local score = ComputeContributionScore(record, state)
            InsertBossContributorSnapshot(
                source,
                record,
                score,
                rewardedRandomKeys and rewardedRandomKeys[key] == true,
                guaranteedRewardKeys and guaranteedRewardKeys[key] == true,
                createdAt
            )
        end
    end
end

local function SelectWeightedRewardWinners(contributors, rewardCount)
    local selected = {}
    local pool = {}
    for _, contributor in ipairs(contributors) do
        table.insert(pool, contributor)
    end

    while #selected < rewardCount and #pool > 0 do
        if REWARD_PROBABILITIES.randomRewardMode == "random" then
            local randomIndex = math.random(#pool)
            table.insert(selected, table.remove(pool, randomIndex))
        else
            local totalWeight = 0
            for _, contributor in ipairs(pool) do
                totalWeight = totalWeight + math.max(0.01, contributor.score)
            end

            local cursor = 0
            local threshold = math.random() * totalWeight
            local selectedIndex = #pool
            for index, contributor in ipairs(pool) do
                cursor = cursor + math.max(0.01, contributor.score)
                if threshold <= cursor then
                    selectedIndex = index
                    break
                end
            end

            table.insert(selected, table.remove(pool, selectedIndex))
        end
    end

    return selected
end

-- 获取玩家职业名
local function GetClassName(unit)
    local success, class = pcall(function() return unit:GetClass() end)
    if not success or not class then return "未知职业" end
    
    local classNames = {
        [1] = "战士",
        [2] = "圣骑士",
        [3] = "猎人",
        [4] = "盗贼",
        [5] = "牧师",
        [6] = "死亡骑士",
        [7] = "萨满",
        [8] = "法师",
        [9] = "术士",
        [11] = "德鲁伊",
    }
    return classNames[class] or "冒险者"
end

-- 喊话系统
local TauntSystem = {}

-- 发送随机喊话
function TauntSystem:SendRandomTaunt(creature, tauntList, placeholders)
    if not creature or not tauntList or #tauntList == 0 then return end
    
    placeholders = placeholders or {}
    local yell = tauntList[math.random(#tauntList)]
    
    -- 替换占位符
    for key, value in pairs(placeholders) do
        yell = string.gsub(yell, key, value)
    end
    
    creature:SendUnitYell(yell, 0)
end

-- 检查是否可以喊话（冷却）
function TauntSystem:CanTaunt(state)
    if not state.lastTauntTime then
        state.lastTauntTime = 0
        return true
    end
    local now = os.time()
    if now - state.lastTauntTime >= BOSS_CONFIG.tauntCooldown then
        state.lastTauntTime = now
        return true
    end
    return false
end

-- 尝试发送随机战斗嘲讽
function TauntSystem:TryRandomCombatTaunt(creature, state)
    if not self:CanTaunt(state) then return end
    if math.random(100) > BOSS_CONFIG.randomTauntChance then return end
    
    local taunts = BOSS_CONFIG.combatTaunts
    local allTaunts = {}
    
    -- 合并所有可能的嘲讽（只处理数组类型的列表）
    for key, list in pairs(taunts) do
        if type(list) == "table" and key ~= "skillCastYells" and key ~= "comboYells" then
            for _, taunt in ipairs(list) do
                if type(taunt) == "string" then
                    table.insert(allTaunts, taunt)
                end
            end
        end
    end
    
    if #allTaunts > 0 then
        self:SendRandomTaunt(creature, allTaunts)
    end
end

-- 发送援军召唤喊话
function TauntSystem:SendSummonTaunt(creature)
    local yells = BOSS_CONFIG.combatTaunts.summonMinionYells
    if yells and #yells > 0 then
        local yell = yells[math.random(#yells)]
        creature:SendUnitYell(yell, 0)
    end
end

-- ========== 智能目标选择系统 ==========
local TargetSelector = {}

-- 获取目标职业类型
function TargetSelector:GetClassType(unit)
    if not IsUnitValid(unit) then return "unknown" end
    local success, class = pcall(function() return unit:GetClass() end)
    if success and class then
        return CLASS_TYPES[class] or "unknown"
    end
    return "unknown"
end

-- 检查单位是否正在施法
function TargetSelector:IsCasting(unit)
    if not IsUnitValid(unit) then return false end
    local success, isCasting = pcall(function() return unit:IsCasting() end)
    return success and isCasting
end

-- 从威胁列表中查找正在施法的玩家
-- 返回: 正在施法的玩家列表，按威胁优先级排序
-- @param cachedThreatList: 可选，缓存的威胁列表，避免重复获取
function TargetSelector:FindCastingPlayers(creature, cachedThreatList)
    if not IsUnitValid(creature) then return {} end
    
    local threatList = BuildSafeThreatList(creature, cachedThreatList)
    if not threatList or #threatList == 0 then
        return {}
    end
    
    local castingPlayers = {}
    for _, unit in ipairs(threatList) do
        if IsUnitValid(unit) then
            local success, isPlayer = pcall(function() return unit:IsPlayer() end)
            if success and isPlayer then
                local dist = creature:GetDistance(unit)
                -- 只考虑距离内的施法玩家（打断技能通常有距离限制，约5-8码）
                if dist <= 10 then
                    local isCasting = self:IsCasting(unit)
                    if isCasting then
                        -- 计算施法威胁评分
                        local score = self:GetThreatScore(unit, creature)
                        -- 额外增加施法中的优先级（确保打断优先级）
                        score = score + 100
                        table.insert(castingPlayers, {
                            unit = unit, 
                            score = score, 
                            dist = dist,
                            classType = self:GetClassType(unit)
                        })
                    end
                end
            end
        end
    end
    
    -- 按评分排序
    table.sort(castingPlayers, function(a, b) return a.score > b.score end)
    return castingPlayers
end

-- 获取目标威胁评分
function TargetSelector:GetThreatScore(unit, creature)
    if not IsUnitValid(unit) or not IsUnitValid(creature) then return 0 end
    
    local score = 50  -- 基础分
    
    -- 距离因素（越近威胁越高）
    local success, dist = pcall(function() return creature:GetDistance(unit) end)
    if success and dist then
        if dist < 5 then
            score = score + 30
        elseif dist > 20 then
            score = score - 20
        end
    end
    
    -- 职业类型优先级
    local classType = self:GetClassType(unit)
    if classType == "healer" then
        score = score + 40  -- 优先攻击治疗
    elseif classType == "ranged" then
        score = score + 20  -- 其次攻击远程
    elseif classType == "melee" then
        score = score + 10
    end
    
    -- 血量因素（优先攻击低血量）
    local success, hpPct = pcall(function() return unit:GetHealthPct() end)
    if success and hpPct then
        if hpPct < 30 then
            score = score + 25  -- 斩杀线
        elseif hpPct < 50 then
            score = score + 15
        end
    end
    
    -- 是否正在施法（优先打断）- 基础评分增加
    if self:IsCasting(unit) then
        score = score + 50  -- 大幅提升施法目标的优先级
    end
    
    return score
end

-- 智能选择目标
-- @param cachedThreatList: 可选，缓存的威胁列表，避免重复获取
function TargetSelector:SelectSmartTarget(creature, options, cachedThreatList)
    if not IsUnitValid(creature) then return nil end
    
    options = options or {}
    local preferType = options.preferType or nil  -- "healer", "ranged", "melee"
    local maxDistance = options.maxDistance or 50
    local needLos = options.needLos ~= false
    
    local threatList = BuildSafeThreatList(creature, cachedThreatList)
    if not threatList or #threatList == 0 then
        local success, victim = pcall(function() return creature:GetVictim() end)
        return success and victim or nil
    end
    
    local candidates = {}
    for _, unit in ipairs(threatList) do
        if IsUnitValid(unit) then
            local success, isPlayer = pcall(function() return unit:IsPlayer() end)
            if success and isPlayer then
                local dist = creature:GetDistance(unit)
                if dist <= maxDistance then
                    local score = self:GetThreatScore(unit, creature)
                    
                    -- 根据偏好类型调整分数
                    if preferType then
                        local classType = self:GetClassType(unit)
                        if classType == preferType then
                            score = score + 50
                        end
                    end
                    
                    table.insert(candidates, {unit = unit, score = score, dist = dist})
                end
            end
        end
    end
    
    if #candidates == 0 then
        local success, victim = pcall(function() return creature:GetVictim() end)
        return success and victim or nil
    end
    
    -- 按分数排序
    table.sort(candidates, function(a, b) return a.score > b.score end)
    
    -- 前3名中随机选择（增加不确定性）
    local topCount = math.min(3, #candidates)
    local selected = candidates[math.random(topCount)]
    
    print(" [AI]智能目标选择: " .. SafeGetUnitName(selected.unit) .. 
          " 评分:" .. string.format("%.0f", selected.score) .. 
          " 距离:" .. string.format("%.1f", selected.dist))
    
    return selected.unit
end

-- ========== 技能决策系统 ==========
local SkillAI = {}

-- 检查技能条件
function SkillAI:CheckCondition(condition, creature, target)
    if condition == "none" then return true end
    if not IsUnitValid(creature) then return false end
    
    local threatList = BuildSafeThreatList(creature)
    local enemyCount = threatList and #threatList or 0
    local hpPct = creature:GetHealthPct()
    
    if condition == "multi_target" then
        return enemyCount >= 1
    elseif condition == "multi_melee" then
        -- 检查近身敌人数量
        local meleeCount = 0
        if threatList then
            for _, unit in ipairs(threatList) do
                if IsUnitValid(unit) then
                    local dist = creature:GetDistance(unit)
                    if dist and dist < 8 then
                        meleeCount = meleeCount + 1
                    end
                end
            end
        end
        return meleeCount >= 1
    elseif condition == "low_hp" then
        return hpPct < 50
    elseif condition == "critical_hp" then
        return hpPct < 20
    elseif condition == "ranged_target" and IsUnitValid(target) then
        -- 远程或治疗职业
        local classType = TargetSelector:GetClassType(target)
        return classType == "ranged" or classType == "healer"
    elseif condition == "healer_target" and IsUnitValid(target) then
        local classType = TargetSelector:GetClassType(target)
        return classType == "healer"
    elseif condition == "caster_target" and IsUnitValid(target) then
        local classType = TargetSelector:GetClassType(target)
        return classType == "ranged" or classType == "healer"
    elseif condition == "casting_target" and IsUnitValid(target) then
        local success, isCasting = pcall(function() return target:IsCasting() end)
        return success and isCasting
    elseif condition == "buffed_target" and IsUnitValid(target) then
        -- 检查目标是否有可驱散的重要BUFF（简化处理）
        return true
    elseif condition == "surrounded" then
        return enemyCount >= 3
    elseif condition == "many_attackers" then
        return enemyCount >= 4
    elseif condition == "distant_target" and IsUnitValid(target) then
        local dist = creature:GetDistance(target)
        return dist and dist > 12
    elseif condition == "low_hp_target" and IsUnitValid(target) then
        -- 目标血量低，适合斩杀
        local success, targetHp = pcall(function() return target:GetHealthPct() end)
        return success and targetHp and targetHp < 25
    elseif condition == "grouped_targets" then
        -- 检查玩家是否过于集中（8码内有其他玩家）
        if not threatList then return false end
        local groupedCount = 0
        for i, unit1 in ipairs(threatList) do
            if IsUnitValid(unit1) then
                local guid1 = nil
                pcall(function() guid1 = unit1:GetGUID() end)
                for j, unit2 in ipairs(threatList) do
                    if i ~= j and IsUnitValid(unit2) then
                        local dist = unit1:GetDistance(unit2)
                        if dist and dist < 8 then
                            groupedCount = groupedCount + 1
                        end
                    end
                end
            end
        end
        return groupedCount >= 2
    elseif condition == "kiting_target" and IsUnitValid(target) then
        -- 正在风筝（距离远且是远程职业）
        local classType = TargetSelector:GetClassType(target)
        local dist = creature:GetDistance(target)
        return (classType == "ranged" or classType == "healer") and dist and dist > 8
    end
    
    return true
end

-- 选择最佳技能
function SkillAI:SelectBestSkill(phase, creature, target)
    local skillPool = SKILL_POOLS[phase]
    if not skillPool then return nil end
    
    local validSkills = {}
    for _, skill in ipairs(skillPool) do
        if self:CheckCondition(skill.condition, creature, target) then
            table.insert(validSkills, skill)
        end
    end
    
    if #validSkills == 0 then
        -- 没有符合条件的技能，返回第一个
        return skillPool[1]
    end
    
    -- 检查目标是否正在施法
    local targetIsCasting = TargetSelector:IsCasting(target)
    
    -- 如果目标正在施法，优先选择打断技能
    if targetIsCasting then
        -- 查找打断技能（casting_target条件的技能）
        for _, skill in ipairs(validSkills) do
            if skill.condition == "casting_target" then
                print(" [AI]优先选择打断技能: " .. skill.name .. " (目标正在施法)")
                return skill
            end
        end
        -- 如果没有特定的casting_target技能，检查caster_target
        for _, skill in ipairs(validSkills) do
            if skill.condition == "caster_target" then
                print(" [AI]优先选择反制技能: " .. skill.name .. " (目标正在施法)")
                return skill
            end
        end
    end
    
    -- 按优先级排序
    table.sort(validSkills, function(a, b) return a.priority > b.priority end)
    
    -- 前2个中随机选择
    local topCount = math.min(2, #validSkills)
    return validSkills[math.random(topCount)]
end

-- 尝试施放打断技能
-- 返回: 是否成功施放打断技能
function SkillAI:TryInterruptCast(creature, target, state)
    -- 检查目标是否正在施法
    if not TargetSelector:IsCasting(target) then
        return false
    end
    
    -- 检查打断技能冷却
    state.interruptCD = state.interruptCD or 0
    if state.interruptCD > 0 then
        return false
    end
    
    for _, interruptSpell in ipairs(INTERRUPT_SPELL_LIBRARY) do
        local distance = SafeGetDistance(creature, target)
        if distance and distance <= interruptSpell.maxRange then
            print(" [AI]打断施法! 对 " .. SafeGetUnitName(target) .. " 使用 " .. interruptSpell.name)
            local castSuccess = pcall(function() creature:CastSpell(target, interruptSpell.spellId, true) end)
            if castSuccess then
                state.interruptCD = interruptSpell.cooldown

                -- 施放后若目标已不在施法，则判定为有效打断。
                if not TargetSelector:IsCasting(target) then
                    return true
                end

                print(" [AI]" .. interruptSpell.name .. " 未打断成功，尝试下一个打断法术")
            else
                print(" [AI]打断技能施放失败: " .. interruptSpell.name .. " -> " .. SafeGetUnitName(target))
            end
        end
    end

    return false
end

-- 施放技能的辅助函数，统一处理技能施放和喊话
function SkillAI:CastSkill(creature, target, skill, state)
    if not skill or not IsUnitValid(creature) then return false end

    local castTarget = target
    if skill.target == "self" then
        castTarget = creature
    elseif not IsUnitValid(castTarget) then
        local successVictim, victim = pcall(function() return creature:GetVictim() end)
        if successVictim and IsUnitValid(victim) then
            castTarget = victim
        else
            return false
        end
    end

    local castSuccess = pcall(function()
        creature:CastSpell(castTarget, skill.spellId, true)
    end)

    if not castSuccess then
        local skillName = skill.name or tostring(skill.spellId)
        print(" [AI]技能施放失败: " .. skillName .. " -> " .. SafeGetUnitName(castTarget))
        return false
    end
    
    -- 技能施放喊话
    local skillTaunt = BOSS_CONFIG.combatTaunts.skillCastYells[skill.name]
    if skillTaunt and TauntSystem:CanTaunt(state) then
        creature:SendUnitYell(skillTaunt, 0)
    end
    
    return true
end

-- 检查是否可以执行连招
function SkillAI:TryComboChain(creature, state, currentPhase)
    -- 确保comboCooldown存在
    state.comboCooldown = state.comboCooldown or 0
    
    if state.comboCooldown > 0 then
        return nil
    end
    
    -- 检查每个连招的冷却状态
    state.comboCooldowns = state.comboCooldowns or {}
    
    -- 筛选符合当前阶段的连招
    local validCombos = {}
    for _, combo in ipairs(COMBO_CHAINS) do
        -- 检查阶段限制
        local phaseValid = false
        if not combo.phase then
            phaseValid = true
        else
            for _, p in ipairs(combo.phase) do
                if p == currentPhase then
                    phaseValid = true
                    break
                end
            end
        end
        
        -- 检查冷却
        local cdValid = not state.comboCooldowns[combo.name] or state.comboCooldowns[combo.name] <= 0
        
        if phaseValid and cdValid then
            table.insert(validCombos, combo)
        end
    end
    
    if #validCombos == 0 then
        return nil
    end
    
    -- 随机选择一个连招
    local combo = validCombos[math.random(#validCombos)]
    local triggerChance = combo.triggerChance or 30
    
    -- 检查触发概率
    if math.random(100) <= triggerChance then
        state.comboCooldowns[combo.name] = combo.cooldown
        state.comboCooldown = 5  -- 全局连招冷却，防止连续连招
        return combo
    end
    
    return nil
end

-- ========== 战术移动系统 ==========
local TacticalAI = {}

-- 检查是否需要追击
function TacticalAI:ShouldChase(creature, target)
    if not IsUnitValid(creature) or not IsUnitValid(target) then return false end
    
    local dist = creature:GetDistance(target)
    local classType = TargetSelector:GetClassType(target)
    
    -- 远程目标且距离过远，需要追击
    if classType == "ranged" and dist > 10 then
        return true
    end
    
    -- 目标距离过远
    if dist > 20 then
        return true
    end
    
    return false
end

-- 执行战术移动
function TacticalAI:ExecuteMove(creature, target)
    if not IsUnitValid(creature) or not IsUnitValid(target) then return end
    
    local classType = TargetSelector:GetClassType(target)
    local dist = creature:GetDistance(target)
    
    if classType == "ranged" and dist > 10 then
        -- 追击远程目标
        print(" [AI]追击远程目标: " .. SafeGetUnitName(target))
        creature:MoveChase(target)
    elseif dist > 20 then
        -- 普通追击
        print(" [AI]追击目标: " .. SafeGetUnitName(target))
        creature:MoveChase(target)
    end
end

-- ========== 巡逻与小怪智能行为 ==========
local function TryMoveUnitHome(unit)
    if not IsUnitValid(unit) then return false end
    local success = pcall(function() unit:MoveHome() end)
    return success
end

local function TryMoveUnitRandom(unit, radius)
    if not IsUnitValid(unit) then return false end
    local success = pcall(function() unit:MoveRandom(radius) end)
    return success
end

local function RegisterBossPatrol(creature)
    if not BOSS_CONFIG.patrolEnabled or not IsUnitValid(creature) then return end

    local guid = creature:GetGUIDLow()
    local patrolCenter = activeBossInfo
    if currentActiveBossGUID ~= guid or not patrolCenter then
        return
    end

    creature:RegisterEvent(function(eventId, delay, calls, obj)
        if not IsUnitValid(obj) or not obj:IsAlive() then return end
        if obj:IsInCombat() then return end
        if currentActiveBossGUID ~= guid or not activeBossInfo then return end

        local centerX = activeBossInfo.x
        local centerY = activeBossInfo.y
        local centerZ = activeBossInfo.z
        local distanceFromCenter = math.sqrt(((obj:GetX() - centerX) ^ 2) + ((obj:GetY() - centerY) ^ 2))

        if distanceFromCenter > BOSS_CONFIG.patrolLeashRadius then
            if not TryMoveUnitHome(obj) then
                print(" [巡逻]Boss返回刷新点失败，GUID: " .. guid)
            end
            return
        end

        if not TryMoveUnitRandom(obj, BOSS_CONFIG.patrolRadius) then
            print(" [巡逻]Boss随机巡逻失败，GUID: " .. guid)
        end
    end, BOSS_CONFIG.patrolInterval, 0)
end

BuildNearbyPlayerList = function(unit, maxDistance)
    if not IsUnitValid(unit) then return {} end

    local players = {}
    local success, nearbyPlayers = pcall(function() return unit:GetPlayersInRange(maxDistance) end)
    if not success or not nearbyPlayers then
        return players
    end

    for _, player in ipairs(nearbyPlayers) do
        if IsUnitValid(player) then
            local successPlayer, isPlayer = pcall(function() return player:IsPlayer() end)
            if successPlayer and isPlayer then
                table.insert(players, player)
            end
        end
    end

    return players
end

local function SelectSmartMinionTarget(minion, preferredGuid)
    if not IsUnitValid(minion) then return nil end

    local candidates = {}
    local players = BuildNearbyPlayerList(minion, BOSS_CONFIG.minionTargetRange)
    for _, player in ipairs(players) do
        local score = TargetSelector:GetThreatScore(player, minion)
        local distance = SafeGetDistance(minion, player) or 99

        if preferredGuid then
            local successGuid, playerGuid = pcall(function() return player:GetGUID() end)
            if successGuid and playerGuid == preferredGuid then
                score = score + 20
            end
        end

        local classType = TargetSelector:GetClassType(player)
        if classType == "healer" then
            score = score + 25
        elseif classType == "ranged" then
            score = score + 10
        end

        local successHp, hpPct = pcall(function() return player:GetHealthPct() end)
        if successHp and hpPct and hpPct < 35 then
            score = score + 20
        end

        if distance > 20 then
            score = score - 10
        end

        table.insert(candidates, {unit = player, score = score, dist = distance})
    end

    if #candidates == 0 then
        local successVictim, victim = pcall(function() return minion:GetVictim() end)
        if successVictim and IsUnitValid(victim) then
            return victim
        end
        return nil
    end

    table.sort(candidates, function(a, b) return a.score > b.score end)
    local topCount = math.min(3, #candidates)
    return candidates[math.random(topCount)].unit
end

local function SmartMinionAI(event, delay, calls, minion)
    if not BOSS_CONFIG.minionAiEnabled or not IsUnitValid(minion) or not minion:IsAlive() then
        if minion and minion.GetGUIDLow then
            local successGuid, minionGuid = pcall(function() return minion:GetGUIDLow() end)
            if successGuid then
                bossMinionStates[minionGuid] = nil
            end
        end
        if minion and minion.RemoveEvents then
            minion:RemoveEvents()
        end
        return
    end

    local guid = minion:GetGUIDLow()
    local state = bossMinionStates[guid]
    if not state then
        return
    end

    local preferredGuid = state.preferredTargetGuid
    local target = SelectSmartMinionTarget(minion, preferredGuid)
    if not IsUnitValid(target) then
        return
    end

    local successVictim, currentVictim = pcall(function() return minion:GetVictim() end)
    local currentGuid = nil
    local targetGuid = nil
    pcall(function() currentGuid = currentVictim and currentVictim:GetGUID() end)
    pcall(function() targetGuid = target:GetGUID() end)

    if currentGuid ~= targetGuid then
        local switched = pcall(function() minion:AttackStart(target) end)
        if switched then
            state.preferredTargetGuid = targetGuid
            print(" [援军AI]小怪切换目标到: " .. SafeGetUnitName(target))
        end
    end

    local dist = SafeGetDistance(minion, target)
    if dist and dist > 8 then
        pcall(function() minion:MoveChase(target) end)
    end
end

local function RegisterMinionAI(minion, preferredTargetGuid)
    if not BOSS_CONFIG.minionAiEnabled or not IsUnitValid(minion) then return end

    local guid = minion:GetGUIDLow()
    bossMinionStates[guid] = {
        preferredTargetGuid = preferredTargetGuid,
    }

    minion:RegisterEvent(SmartMinionAI, BOSS_CONFIG.minionAiInterval, 0)
end

-- ========== 援军召唤 ==========
local function SummonMinions(creature, count, targetGuid)
    local c = count or 1
    for i = 1, c do
        local entry = HELPER_ENTRIES[math.random(#HELPER_ENTRIES)]
        local ang = math.random() * math.pi * 2
        local dist = math.random(3, 6)
        local x = creature:GetX() + math.cos(ang) * dist
        local y = creature:GetY() + math.sin(ang) * dist
        local z = creature:GetZ()
        local minion = creature:SpawnCreature(entry, x, y, z, creature:GetO(), 2, 60000)
        if minion then
            minion:SetFaction(creature:GetFaction())
            RegisterMinionAI(minion, targetGuid)
            if targetGuid then
                minion:RegisterEvent(function(e, d, r, obj)
                    -- 使用pcall安全获取目标
                    local success, targetUnit = pcall(function() return GetPlayerByGUID(targetGuid) end)
                    if success and targetUnit and IsUnitValid(targetUnit) then
                        obj:AttackStart(targetUnit)
                    else
                        -- 如果目标玩家无效，尝试攻击BOSS的当前目标
                        -- 注意：这里不直接使用creature，因为它可能已经失效
                        -- 小怪会自行选择目标或通过其他机制
                        print(" [援军]目标玩家无效，援军自行选择目标")
                    end
                end, 500, 1)
            end
        end
    end
end

-- ========== 智能Boss AI ==========
local function SmartBossAI(event, delay, calls, creature)
    if not creature or not creature:IsAlive() then return end
    local guid = creature:GetGUIDLow()
    if not scriptSpawnedBossGUIDs[guid] then
        creature:RemoveEvents()
        bossAIStates[guid] = nil
        return
    end
    
    local state = bossAIStates[guid]
    if not state then return end
    if not creature:IsInCombat() then return end

    if currentActiveBossGUID == guid and activeBossInfo then
        activeBossInfo.x = creature:GetX()
        activeBossInfo.y = creature:GetY()
        activeBossInfo.z = creature:GetZ()
        activeBossInfo.mapId = creature:GetMapId()
    end

    local dt = delay / 1000
    
    -- 更新连招冷却
    state.comboCooldowns = state.comboCooldowns or {}
    for name, cd in pairs(state.comboCooldowns) do
        state.comboCooldowns[name] = cd - dt
        if state.comboCooldowns[name] < 0 then state.comboCooldowns[name] = 0 end
    end
    
    -- 更新战斗时间
    state.combatTime = (state.combatTime or 0) + delay
    
    -- 获取并缓存威胁列表
    local currentThreatList = BuildSafeThreatList(creature)
    if currentThreatList and #currentThreatList > 0 then
        local enhancedSnapshot = {}
        for i, unit in ipairs(currentThreatList) do
            local unitInfo = {unit = unit, guid = nil, name = nil, isPlayer = false}
            if unit and type(unit) == "userdata" then
                local success, name = pcall(function() return unit:GetName() end)
                if success then unitInfo.name = name end
                local success2, isPlayer = pcall(function() return unit:IsPlayer() end)
                if success2 and isPlayer then
                    unitInfo.isPlayer = true
                    local success3, objGuid = pcall(function() return unit:GetGUID() end)
                    if success3 then unitInfo.guid = objGuid end
                end
            end
            table.insert(enhancedSnapshot, unitInfo)
        end
        bossThreatSnapshots[guid] = enhancedSnapshot
    end
    TrackEncounterPresence(creature, currentThreatList)
    
    -- 计算阶段（阈值可配：[phase] 组）
    local hp = creature:GetHealthPct()
    local prevPhase = state.phase
    if hp > BOSS_CONFIG.phase2HpThreshold then
        state.phase = 1
    elseif hp > BOSS_CONFIG.phase3HpThreshold then
        state.phase = 2
    else
        state.phase = 3
    end
    
    if prevPhase ~= state.phase then
        print(" [AI]阶段切换: " .. prevPhase .. " -> " .. state.phase .. ", 血量: " .. string.format("%.1f", hp) .. "%")
        PersistBossRuntime(creature, {
            status = "engaged",
            phase = state.phase,
        })
        InsertBossEvent(creature, "phase_change", "阶段从 " .. tostring(prevPhase) .. " 切换到 " .. tostring(state.phase) .. "。", "", 0, {
            from_phase = prevPhase,
            to_phase = state.phase,
            health_pct = hp,
        })
        -- 阶段切换触发特效（法术ID与数量都可配：[phase] 组）
        if state.phase == 2 and not state.phase2Triggered then
            print(" [AI]阶段2触发：施放自由祝福")
            if BOSS_CONFIG.phase2SpellId > 0 then
                creature:CastSpell(creature, BOSS_CONFIG.phase2SpellId, true)  -- 自由祝福
            end
            state.phase2Triggered = true
            local targetGuid = state.lastTargetGuid
            print(" [AI]阶段2召唤援军")
            SummonMinions(creature, math.random(BOSS_CONFIG.phase2SummonCountMin, BOSS_CONFIG.phase2SummonCountMax), targetGuid)
            -- 阶段2喊话 + 援军召唤喊话
            TauntSystem:SendRandomTaunt(creature, BOSS_CONFIG.combatTaunts.phase2Yells)
            TauntSystem:SendSummonTaunt(creature)
        elseif state.phase == 3 and not state.phase3Triggered then
            print(" [AI]阶段3触发：施放狂暴")
            if BOSS_CONFIG.phase3SpellId > 0 then
                creature:CastSpell(creature, BOSS_CONFIG.phase3SpellId, true)  -- 狂暴
            end
            state.phase3Triggered = true
            local targetGuid = state.lastTargetGuid
            print(" [AI]阶段3召唤援军")
            SummonMinions(creature, BOSS_CONFIG.phase3SummonCount, targetGuid)
            -- 阶段3喊话 + 援军召唤喊话
            TauntSystem:SendRandomTaunt(creature, BOSS_CONFIG.combatTaunts.phase3Yells)
            TauntSystem:SendSummonTaunt(creature)
        end
    end
    
    -- 极低血量嘲讽
    if hp < BOSS_CONFIG.criticalHpThreshold and not state.criticalHpYelled then
        state.criticalHpYelled = true
        TauntSystem:SendRandomTaunt(creature, BOSS_CONFIG.combatTaunts.criticalHpYells)
    end
    
    -- 战斗时间过长嘲讽（默认每 60 秒一次，可配）
    if state.combatTime % BOSS_CONFIG.longCombatTauntIntervalMs < delay then
        TauntSystem:TryRandomCombatTaunt(creature, state)
    end
    
    -- 更新打断技能冷却
    state.interruptCD = (state.interruptCD or 0) - (delay / 1000)
    
    -- 智能目标选择
    local target = nil
    local success, victim = pcall(function() return creature:GetVictim() end)
    if not success then victim = nil end
    
    -- ========== 打断优先级检查 ==========
    -- 首先检查是否有玩家正在施法需要打断
    local castingPlayers = TargetSelector:FindCastingPlayers(creature, currentThreatList)
    local shouldInterrupt = false
    local interruptTarget = nil
    
    if #castingPlayers > 0 and state.interruptCD <= 0 then
        -- 有玩家正在施法，且打断技能可用
        -- 检查当前目标是否正在施法
        if victim and TargetSelector:IsCasting(victim) then
            -- 当前目标正在施法，优先打断当前目标
            shouldInterrupt = true
            interruptTarget = victim
            print(" [AI]检测到当前目标正在施法，准备打断: " .. SafeGetUnitName(victim))
        else
            -- 当前目标没有施法，但其他玩家正在施法
            -- 考虑切换目标到正在施法的玩家（如果是治疗或高威胁目标）
            local topCaster = castingPlayers[1]
            if topCaster then
                -- 如果是治疗正在施法，或者当前目标距离太远，考虑切换
                if topCaster.classType == "healer" or (victim and creature:GetDistance(victim) > 10) then
                    shouldInterrupt = true
                    interruptTarget = topCaster.unit
                    target = topCaster.unit
                    print(" [AI]发现 " .. topCaster.classType .. " 正在施法，切换目标打断: " .. SafeGetUnitName(topCaster.unit))
                end
            end
        end
    end
    
    -- 如果没有设置打断目标，进行常规目标选择
    if not target then
        -- 每 N 次AI循环重新评估目标（N 可配）
        state.targetEvalCounter = (state.targetEvalCounter or 0) + 1
        if state.targetEvalCounter >= BOSS_CONFIG.targetReevalLoops or not IsUnitValid(victim) then
            state.targetEvalCounter = 0
            -- 根据当前情况选择目标类型
            local preferType = nil
            if state.phase == 3 then
                preferType = "healer"  -- 第三阶段优先攻击治疗
            end
            target = TargetSelector:SelectSmartTarget(creature, {preferType = preferType}, currentThreatList)
        else
            target = victim
        end
    end
    
    if not target or not IsUnitValid(target) then
        return
    end
    
    -- 保存目标GUID
    local success, targetGuid = pcall(function() return target:GetGUID() end)
    if success then
        state.lastTargetGuid = targetGuid
    end
    
    -- 检查是否需要切换目标
    local newTargetGuid = nil
    local currentVictimGuid = nil
    pcall(function() newTargetGuid = target:GetGUID() end)
    pcall(function() currentVictimGuid = victim and victim:GetGUID() end)
    if newTargetGuid ~= currentVictimGuid then
        local success = pcall(function() creature:AttackStart(target) end)
        if success then
            print(" [AI]切换目标到: " .. SafeGetUnitName(target))
            -- 切换目标嘲讽
            if TauntSystem:CanTaunt(state) then
                TauntSystem:SendRandomTaunt(creature, BOSS_CONFIG.combatTaunts.targetSwitchYells, {
                    ["{PLAYER_NAME}"] = SafeGetUnitName(target),
                    ["{CLASS}"] = GetClassName(target),
                })
            end
        end
    end
    
    -- 嘲讽低血量目标
    if IsUnitValid(target) then
        local success, hpPct = pcall(function() return target:GetHealthPct() end)
        if success and hpPct and hpPct < BOSS_CONFIG.lowHpTauntThreshold then
            if not state.lowHpTauntCooldown then state.lowHpTauntCooldown = 0 end
            state.lowHpTauntCooldown = state.lowHpTauntCooldown - delay
            if state.lowHpTauntCooldown <= 0 then
                state.lowHpTauntCooldown = BOSS_CONFIG.lowHpTauntCooldownMs
                TauntSystem:SendRandomTaunt(creature, BOSS_CONFIG.combatTaunts.lowHpYells, {
                    ["{PLAYER_NAME}"] = SafeGetUnitName(target),
                })
            end
        end
    end
    
    -- ========== 打断技能优先施放 ==========
    -- 如果检测到需要打断，优先尝试打断
    if shouldInterrupt and interruptTarget then
        if SkillAI:TryInterruptCast(creature, interruptTarget, state) then
            -- 打断成功嘲讽
            TauntSystem:SendRandomTaunt(creature, BOSS_CONFIG.combatTaunts.interruptYells, {
                ["{PLAYER_NAME}"] = SafeGetUnitName(interruptTarget),
            })
            return  -- 打断成功，本次AI循环结束
        end
    end
    
    -- 战术移动检查
    if TacticalAI:ShouldChase(creature, target) then
        TacticalAI:ExecuteMove(creature, target)
    end
    
    -- 开场技能
    if not state.openingDone then
        local openingSkill = OPENING_SKILLS[math.random(#OPENING_SKILLS)]
        SkillAI:CastSkill(creature, target, openingSkill, state)
        state.openingDone = true
        print(" [AI]使用开场技能: " .. openingSkill.name)
        return
    end
    
    -- 尝试执行连招
    local combo = SkillAI:TryComboChain(creature, state, state.phase)
    if combo then
        print(" [AI]执行连招: " .. combo.name)
        -- 连招喊话
        local comboYell = BOSS_CONFIG.combatTaunts.comboYells[combo.name]
        if comboYell then
            creature:SendUnitYell(comboYell, 0)
        end
        for _, skillInfo in ipairs(combo.skills) do
            local spellId, targetType = skillInfo[1], skillInfo[2]
            SkillAI:CastSkill(creature, target, {spellId = spellId, target = targetType}, state)
        end
        return
    end
    
    -- 技能冷却计时
    state.phase1CD = (state.phase1CD or 0) - dt
    state.phase2CD = (state.phase2CD or 0) - dt
    state.phase3CD = (state.phase3CD or 0) - dt
    
    -- 选择并施放技能
    local skillUsed = false
    
    -- 按优先级检查各阶段技能
    local phaseSkills = {
        {phase = 3, cdField = "phase3CD", name = "阶段3"},
        {phase = 2, cdField = "phase2CD", name = "阶段2"},
        {phase = 1, cdField = "phase1CD", name = "阶段1"},
    }
    
    for _, cfg in ipairs(phaseSkills) do
        if not skillUsed and state.phase >= cfg.phase and state[cfg.cdField] <= 0 then
            local skill = SkillAI:SelectBestSkill(cfg.phase, creature, target)
            if skill then
                print(" [AI]施放" .. cfg.name .. "技能: " .. skill.name)
                if SkillAI:CastSkill(creature, target, skill, state) then
                    state[cfg.cdField] = math.random(skill.minCD, skill.maxCD)
                    skillUsed = true
                end
            end
        end
    end
    
    -- 随机战斗嘲讽
    TauntSystem:TryRandomCombatTaunt(creature, state)
end

local function OnBossDamageTaken(event, creature, attacker, damage)
    if not creature or damage <= 0 then return end

    local guid = creature:GetGUIDLow()
    if not scriptSpawnedBossGUIDs[guid] then return end

    local contributor = ResolvePlayerContributor(attacker)
    if contributor then
        AddContributionMetrics(guid, contributor, {damage = damage})
    end
end

local function OnBossFightPlayerHeal(event, player, target, gain)
    if not currentActiveBossGUID or gain <= 0 then return end
    if not IsUnitValid(player) or not IsWithinActiveEncounterRange(player, REWARD_PROBABILITIES.participationRange) then
        return
    end

    local targetIsRelevant = false
    if IsUnitValid(target) then
        local successPlayer, isPlayer = pcall(function() return target:IsPlayer() end)
        if successPlayer and isPlayer then
            targetIsRelevant = IsWithinActiveEncounterRange(target, REWARD_PROBABILITIES.participationRange)
            if not targetIsRelevant then
                local state = bossContributionStats[currentActiveBossGUID]
                if state then
                    local targetKey = tostring(target:GetGUIDLow() or 0)
                    targetIsRelevant = state.players[targetKey] ~= nil
                end
            end
        end
    end

    if targetIsRelevant then
        AddContributionMetrics(currentActiveBossGUID, player, {healing = gain, presence = 1})
    end
end

-- ========== Boss管理函数 ==========
local function HasActiveBoss()
    if currentActiveBossGUID and IsUnitValid(activeBossCreature) then
        local activeEntry = tonumber(activeBossCreature:GetEntry() or 0) or 0
        if IsManagedBossEntry(activeEntry) then
            scriptSpawnedBossGUIDs[currentActiveBossGUID] = true
            return true
        end
    end

    local activeGuid = 0
    if currentActiveBossGUID then
        activeGuid = tonumber(currentActiveBossGUID) or 0
    elseif activeBossInfo then
        activeGuid = tonumber(activeBossInfo.guid or 0) or 0
    end

    if activeGuid > 0 and BossStatusIndicatesActive(bossRuntimeState.status) then
        local recoverEntry = activeBossInfo and tonumber(activeBossInfo.entry or 0) or 0
        local recoverMapId = activeBossInfo and tonumber(activeBossInfo.mapId or 0) or 0
        local recoverInstanceId = activeBossInfo and tonumber(activeBossInfo.instanceId or 0) or 0
        local recoveredBoss = TryGetCreatureByGUID(activeGuid, recoverEntry, recoverMapId, recoverInstanceId)
        if recoveredBoss then
            SetActiveBoss(recoveredBoss)
            scriptSpawnedBossGUIDs[activeGuid] = true
            return true
        end
    end

    if BossStatusIndicatesActive(bossRuntimeState.status) or activeGuid > 0 then
        local staleGuid = activeGuid
        ClearActiveBoss()
        PersistBossRuntime(nil, {
            boss_guid = 0,
            boss_entry = 0,
            boss_name = "",
            map_id = 0,
            instance_id = 0,
            home_x = 0,
            home_y = 0,
            home_z = 0,
            status = "idle",
            phase = 0,
            respawn_at = 0,
            last_spawn_at = 0,
            last_engage_at = 0,
            last_death_at = 0,
            last_reset_at = 0,
        })
        InsertBossEvent(nil, "runtime_cleared", "检测到僵尸 Boss 运行时记录，已自动清理。", "", 0, {
            stale_guid = staleGuid,
        })
    end

    return false
end

local function GetActiveBossInfo()
    return activeBossInfo
end

SetActiveBoss = function(creature)
    if creature then
        local guid = creature:GetGUIDLow()
        local entry = creature:GetEntry()
        currentActiveBossGUID = guid
        activeBossCreature = creature
        scriptSpawnedBossGUIDs[guid] = true
        activeBossInfo = {
            guid = guid,
            name = ResolveBossCandidateName(entry, creature:GetName()),
            x = creature:GetX(),
            y = creature:GetY(),
            z = creature:GetZ(),
            mapId = creature:GetMapId(),
            instanceId = creature:GetInstanceId(),
            entry = entry,
            homeX = creature:GetX(),
            homeY = creature:GetY(),
            homeZ = creature:GetZ(),
            homeO = creature:GetO(),
        }
    else
        currentActiveBossGUID = nil
        activeBossCreature = nil
        activeBossInfo = nil
    end
end

ClearActiveBoss = function()
    currentActiveBossGUID = nil
    activeBossCreature = nil
    activeBossInfo = nil
end

-- 记录每个Boss当前挂上的光环，用于配置热加载时做差量移除
local bossAppliedAuras = {}

local function CreatureIsInCombat(creature)
    if not IsUnitValid(creature) then
        return false
    end

    local success, inCombat = pcall(function() return creature:IsInCombat() end)
    return success and inCombat == true
end

-- 从「模板」重算基准血量。
-- 关键点：Unit:SetLevel 只写 UNIT_FIELD_LEVEL、不重算生物属性，历史版本拿
-- creature:GetMaxHealth() 当基准，导致每次 reload/rebase 都把血量再乘一次倍率（指数放大）。
-- 这里改用 Creature:UpdateEntry 让核心按模板重算属性；但它内部会 Initialize 威胁表，
-- 所以战斗中绝不调用，改为按当前倍率反推，保证血量不会被重复放大。
local function ResolveBossBaseMaxHealth(creature, guid)
    if not CreatureIsInCombat(creature) then
        local rebuilt = pcall(function() creature:UpdateEntry(creature:GetEntry()) end)
        if rebuilt then
            return creature:GetMaxHealth(), true
        end
    end

    local multiplier = tonumber(BOSS_CONFIG.bossHealthMultiplier) or 1
    if multiplier <= 0 then
        multiplier = 1
    end

    print(" [配置]Boss无法按模板重算属性（战斗中或调用失败），基准血量按当前上限反推，GUID: " .. tostring(guid))
    return math.max(1, math.floor(creature:GetMaxHealth() / multiplier + 0.5)), false
end

-- 为Boss应用特性
local function ApplyBossTraits(creature, opts)
    if not creature then return end
    opts = opts or {}

    local guid = creature:GetGUIDLow()
    local bossName = ResolveBossCandidateName(creature:GetEntry(), creature:GetName())
    local firstApply = not bossTraitsApplied[guid]
    local spawnX = opts.homeX or creature:GetX()
    local spawnY = opts.homeY or creature:GetY()
    local spawnZ = opts.homeZ or creature:GetZ()
    local spawnO = opts.homeO or creature:GetO()

    -- 1) 需要重基准时先从模板取基准血量（会顺带把等级恢复为模板等级）
    if not bossBaseMaxHealth[guid] or opts.forceRebase then
        bossBaseMaxHealth[guid] = (ResolveBossBaseMaxHealth(creature, guid))
    end

    -- 2) 再套用本模块的等级 / 体型 / 归位点设置
    creature:SetLevel(BOSS_CONFIG.bossLevel)
    creature:SetScale(BOSS_CONFIG.bossScale)

    pcall(function() creature:SetHomePosition(spawnX, spawnY, spawnZ, spawnO) end)

    if currentActiveBossGUID == guid and activeBossInfo then
        activeBossInfo.homeX = spawnX
        activeBossInfo.homeY = spawnY
        activeBossInfo.homeZ = spawnZ
        activeBossInfo.homeO = spawnO
    end

    -- 3) 血量 = 模板基准 × 倍率（同一 guid 只会以模板为基准计算一次）
    local targetMaxHealth = math.max(1, math.floor(bossBaseMaxHealth[guid] * BOSS_CONFIG.bossHealthMultiplier + 0.5))
    if creature:GetMaxHealth() ~= targetMaxHealth then
        creature:SetMaxHealth(targetMaxHealth)
    end

    -- 只在首次生成、或显式要求时回满血：战斗中保存面板配置不再顺带把 Boss 治满
    if firstApply or opts.heal == true then
        creature:SetHealth(creature:GetMaxHealth())
    elseif creature:GetHealth() > creature:GetMaxHealth() then
        creature:SetHealth(creature:GetMaxHealth())
    end

    -- 4) 光环差量：配置里删掉的光环必须真正移除，否则「热加载完全生效」是假的
    local previousAuras = bossAppliedAuras[guid] or {}
    local currentAuras = {}
    for _, auraId in ipairs(BOSS_CONFIG.bossAuras) do
        currentAuras[auraId] = true
        creature:AddAura(auraId, creature)
    end

    for auraId in pairs(previousAuras) do
        if not currentAuras[auraId] then
            pcall(function() creature:RemoveAura(auraId) end)
            print(" [配置]已移除Boss光环: " .. tostring(auraId))
        end
    end
    bossAppliedAuras[guid] = currentAuras

    if firstApply then
        local yellText = string.gsub(BOSS_CONFIG.bossSpawnYell, "{BOSS_NAME}", bossName)
        creature:SendUnitYell(yellText, 0)
    end

    bossTraitsApplied[guid] = true

    -- 仅首次生成时注册循环，避免脱战重进重复注册
    if firstApply and opts.registerAI ~= false then
        creature:RegisterEvent(SmartBossAI, BOSS_CONFIG.aiUpdateInterval, 0)
        RegisterBossPatrol(creature)
        print(" [调试信息] 智能AI已注册，GUID: " .. guid)
    end
end

-- ========== Boss生成函数 ==========
local function SpawnRandomBoss(instanceId)
    if HasActiveBoss() then return nil end

    -- 检查BOSS_CANDIDATES是否为空
    if not BOSS_CANDIDATES or #BOSS_CANDIDATES == 0 then
        print(" [错误] BOSS_CANDIDATES数组为空，无法生成Boss")
        return nil
    end

    if not SPAWN_POINTS or #SPAWN_POINTS == 0 then
        print(" [错误] SPAWN_POINTS数组为空，无法生成Boss（检查 boss_activity_config.spawn_points_text）")
        return nil
    end

    local bossCandidate = BOSS_CANDIDATES[math.random(#BOSS_CANDIDATES)]
    local entry = bossCandidate.entry
    local bossName = bossCandidate.name
    print(" [调试信息] 本轮已选择Boss: " .. bossName .. " (Entry: " .. entry .. ")")

    local spawnPoint = SPAWN_POINTS[math.random(#SPAWN_POINTS)]
    local boss = PerformIngameSpawn(1, entry, spawnPoint.mapId, instanceId, 
                                     spawnPoint.x, spawnPoint.y, spawnPoint.z, 0, false, 0, 1)

    if boss then
        local guid = boss:GetGUIDLow()
        print(" [调试信息] Boss生成成功，GUID: " .. guid)
        SetActiveBoss(boss)
        ApplyBossTraits(boss, {
            homeX = spawnPoint.x,
            homeY = spawnPoint.y,
            homeZ = spawnPoint.z,
            homeO = 0,
        })
        local respawnYellText = string.gsub(BOSS_CONFIG.bossRespawnYell, "{BOSS_NAME}", bossName)
        boss:SendUnitYell(respawnYellText, 0)
        local spawnTime = BossNow()
        PersistBossRuntime(boss, {
            status = "spawned",
            phase = 1,
            respawn_at = 0,
            last_spawn_at = spawnTime,
        })
        InsertBossEvent(boss, "spawn", "Boss 已在配置刷新点生成。", "", 0, {
            map_id = spawnPoint.mapId,
            instance_id = tonumber(instanceId or 0) or 0,
            skill_preset = ACTIVE_SKILL_PRESET_KEY or BOSS_CONFIG.skillPreset,
            skill_difficulty = ACTIVE_SKILL_DIFFICULTY_KEY or BOSS_CONFIG.skillDifficulty,
        })
        return boss
    else
        print(" [调试信息]Boss生成失败！")
    end
    return nil
end

local function CancelRespawnTimer()
    if respawnTimerEventId then
        RemoveEventById(respawnTimerEventId)
        respawnTimerEventId = nil
    end
end

local function ScheduleBossRespawn(instanceId, sourceContext)
    CancelRespawnTimer()
    local respawnMilliseconds = BOSS_CONFIG.respawnTimeMinutes * 60 * 1000
    local respawnAt = BossNow() + (BOSS_CONFIG.respawnTimeMinutes * 60)
    PersistBossRuntime(sourceContext, {
        boss_guid = 0,
        status = "cooldown",
        phase = 0,
        respawn_at = respawnAt,
    })
    InsertBossEvent(sourceContext, "respawn_scheduled", "Boss 重生已排程。", "", 0, {
        respawn_at = respawnAt,
        respawn_minutes = BOSS_CONFIG.respawnTimeMinutes,
        instance_id = tonumber(instanceId or 0) or 0,
    })
    respawnTimerEventId = CreateLuaEvent(function()
        SpawnRandomBoss(instanceId)
        respawnTimerEventId = nil
    end, respawnMilliseconds, 1)
    print(" [调试信息]Boss重生定时器已安排: " .. BOSS_CONFIG.respawnTimeMinutes .. " 分钟后")
end

-- ========== 事件处理 ==========
local function OnBossEnterCombat(event, creature, target)
    local guid = creature:GetGUIDLow()
    print(" [调试信息]Boss进入战斗，GUID: " .. guid)

    if not scriptSpawnedBossGUIDs[guid] then return end
    if bossAllySpawned[guid] then return end
    
    bossAllySpawned[guid] = true
    print(" [调试信息]初始化智能AI战斗状态")
    -- 只在本次生成的首次进战建立贡献表；脱战不再清空，
    -- 否则「打一段 → 被拉开/脱战 → 再进战 → 击杀」时前半段贡献不会进入快照与奖励结算。
    EnsureContributionState(guid)

    -- 确保脱战后重新进入能重新注册AI循环
    creature:RemoveEvents()

    -- 脱战重置后重新应用血量倍率/光环，但不重复注册AI事件
    ApplyBossTraits(creature, {registerAI = false})

    local targetGuid = nil
    local initialContributor = ResolvePlayerContributor(target)
    if initialContributor then
        targetGuid = initialContributor:GetGUID()
        AddContributionMetrics(guid, initialContributor, {threat = 1, presence = 1})
    end

    -- 友方援军
    local angle = math.random() * math.pi * 2
    local dist = math.random(4, 8)
    local ally = creature:SpawnCreature(ALLY_HELPER_ENTRY, 
        creature:GetX() + math.cos(angle) * dist,
        creature:GetY() + math.sin(angle) * dist,
        creature:GetZ(), creature:GetO(), 2, 60000)
    if ally then
        ally:SetLevel(BOSS_CONFIG.allyLevel)
        ally:SetMaxHealth(ally:GetMaxHealth() * BOSS_CONFIG.allyHealthMultiplier)
        ally:SetHealth(ally:GetMaxHealth())
        if target and target:IsPlayer() then
            ally:SetFaction(target:GetFaction())
        end
        ally:SendUnitYell(BOSS_CONFIG.allySpawnYell, 0)
        ally:AttackStart(creature)
    end
    
    creature:SendUnitYell(BOSS_CONFIG.bossEnterCombatYell, 0)

    -- Boss援军
    local minionCount = math.random(BOSS_CONFIG.minionCountMin, BOSS_CONFIG.minionCountMax)
    SummonMinions(creature, minionCount, targetGuid)
    
    -- 援军召唤喊话
    if BOSS_CONFIG.combatTaunts.summonMinionYells and #BOSS_CONFIG.combatTaunts.summonMinionYells > 0 then
        local yell = BOSS_CONFIG.combatTaunts.summonMinionYells[math.random(#BOSS_CONFIG.combatTaunts.summonMinionYells)]
        creature:SendUnitYell(yell, 0)
    end

    -- 初始化AI状态
    bossAIStates[guid] = {
        phase = 1,
        openingDone = false,
        phase2Triggered = false,
        phase3Triggered = false,
        phase1CD = 0,
        phase2CD = 0,
        phase3CD = 0,
        comboCooldown = 0,
        combatTime = 0,
        targetEvalCounter = 0,
        lastTargetGuid = targetGuid,
        interruptCD = 0,  -- 打断技能独立冷却
    }

    -- 重新注册智能AI循环
    creature:RegisterEvent(SmartBossAI, BOSS_CONFIG.aiUpdateInterval, 0)

    local actorName = ""
    local actorGuid = 0
    if initialContributor then
        actorName = SafeGetUnitName(initialContributor)
        actorGuid = SafeGetGuidLow(initialContributor)
    end
    local engageTime = BossNow()
    PersistBossRuntime(creature, {
        status = "engaged",
        phase = 1,
        respawn_at = 0,
        last_engage_at = engageTime,
    })
    InsertBossEvent(creature, "enter_combat", "Boss 进入战斗。", actorName, actorGuid, {
        target_name = actorName,
        target_guid = actorGuid,
    })
end

-- 奖励函数
local function PickClassItemFor(player)
    local class = player:GetClass()
    local pool = CLASS_REWARD_ITEMS[class]
    if pool and #pool > 0 then
        return pool[math.random(#pool)]
    end
    -- 检查REWARD_ITEMS是否为空
    if not REWARD_ITEMS or #REWARD_ITEMS == 0 then
        print(" [错误] REWARD_ITEMS数组为空")
        return nil
    end
    return REWARD_ITEMS[math.random(#REWARD_ITEMS)]
end

-- 发放物品奖励的辅助函数
local function GiveRewardItem(player, itemId, count, stepName, playerName)
    local success, result = pcall(function() return player:AddItem(itemId, count or 1) end)
    if success and result then
        print(string.format(" [奖励发放][%s] %s结果: ✓ 成功发放", playerName, stepName))
        return true
    else
        print(string.format(" [奖励发放][%s] %s结果: ✗ 发放失败，错误=%s", playerName, stepName, tostring(result)))
        return false
    end
end

-- 概率判定奖励的辅助函数
local function RollReward(player, chance, itemPool, stepNum, stepName, playerName)
    -- 检查itemPool是否为空
    if not itemPool or #itemPool == 0 then
        print(string.format(" [奖励发放][%s] 步骤%d: %s池为空，跳过", playerName, stepNum, stepName))
        return false
    end
    local roll = math.random(100)
    print(string.format(" [奖励发放][%s] 步骤%d: %s判定，随机数=%d，需要<=%d", playerName, stepNum, stepName, roll, chance))
    if roll <= chance then
        local itemId = itemPool[math.random(#itemPool)]
        print(string.format(" [奖励发放][%s] 步骤%d判定: ✓ 通过，选中物品ID=%d", playerName, stepNum, itemId))
        local success = GiveRewardItem(player, itemId, 1, "步骤" .. stepNum, playerName)
        return success
    else
        print(string.format(" [奖励发放][%s] 步骤%d判定: ✗ 未触发", playerName, stepNum))
        return false
    end
end

local function OnBossDied(event, creature, killer)
    local rewardedPlayers = {}
    
    if not creature or not creature:GetGUIDLow() then return end
    
    local guid = creature:GetGUIDLow()
    local bossName = ResolveBossCandidateName(creature:GetEntry(), creature:GetName())
    print(" [调试信息]Boss死亡，GUID: " .. guid .. ", 名称: " .. bossName)

    if bossRewardedGUIDs[guid] then
        print(" [调试信息]Boss已经被奖励过了，跳过")
        return
    end
    
    if not scriptSpawnedBossGUIDs[guid] then
        print(" [奖励发放]错误: Boss不在脚本生成列表中，GUID=" .. guid)
        return
    end
    
    bossRewardedGUIDs[guid] = true
    local deathTime = BossNow()
    local bossContext = ResolveBossContext(creature)
    local guaranteedRewardKeys = {}
    local randomRewardKeys = {}
    
    print(" [奖励发放]========== 开始奖励发放流程 ==========")
    print(" [奖励发放]Boss名称: " .. bossName)
    print(" [奖励发放]Boss GUID: " .. guid)
    
    local contributorPool, contributionState = BuildContributorRewardPool(guid, killer)
    local playersList = {}
    if #contributorPool > 0 then
        print(" [奖励发放]贡献池玩家数量: " .. #contributorPool)
        for index, entry in ipairs(contributorPool) do
            table.insert(playersList, entry.player)
            local record = entry.record
            print(string.format(
                " [奖励发放][贡献榜%02d] %s 分数=%.2f 输出=%d 治疗=%d 仇恨样本=%d 在场样本=%d%s",
                index,
                record.name,
                entry.score,
                record.damageDone,
                record.healingDone,
                record.threatSamples,
                record.presenceSamples,
                record.isKiller and " 最后一击" or ""))
        end
    else
        print(" [奖励发放]警告: 未建立有效贡献池，回退到仇恨快照逻辑")

        local playerSet = {}
        local threatSnapshot = bossThreatSnapshots[guid]
        if threatSnapshot then
            for _, snapshotEntry in ipairs(threatSnapshot) do
                if snapshotEntry.isPlayer and snapshotEntry.guid then
                    local player = SafeGetPlayerByGUID(snapshotEntry.guid)
                    if player then
                        local guidKey = tostring(snapshotEntry.guid)
                        if not playerSet[guidKey] then
                            playerSet[guidKey] = true
                            table.insert(playersList, player)
                        end
                    end
                end
            end
        end

        local killerPlayer = ResolvePlayerContributor(killer)
        if killerPlayer then
            local _, killerGuidObj = pcall(function() return killerPlayer:GetGUID() end)
            local killerGuid = tostring(killerGuidObj or killerPlayer:GetGUIDLow())
            if not playerSet[killerGuid] then
                playerSet[killerGuid] = true
                table.insert(playersList, killerPlayer)
            end
        end
    end

    print(" [奖励发放]符合条件的玩家总数: " .. #playersList)
    print(" [奖励发放]奖励概率配置: 职业奖励=" .. REWARD_PROBABILITIES.classRewardChance .. "%, 公式奖励=" .. REWARD_PROBABILITIES.formulaRewardChance .. "%, 坐骑奖励=" .. REWARD_PROBABILITIES.mountRewardChance .. "%")

    local deathKillerPlayer = ResolvePlayerContributor(killer)
    local deathActorName = deathKillerPlayer and SafeGetUnitName(deathKillerPlayer) or ""
    local deathActorGuid = deathKillerPlayer and SafeGetGuidLow(deathKillerPlayer) or 0
    InsertBossEvent(creature, "death", "Boss 已被击杀。", deathActorName, deathActorGuid, {
        eligible_players = #playersList,
        random_reward_limit = math.min(REWARD_PROBABILITIES.maxRandomRewardPlayers, #playersList),
    })
    
    -- ========== 保底奖励发放（所有参与者） ==========
    if REWARD_PROBABILITIES.guaranteedRewardEnabled then
        print(" [奖励发放]========== 开始发放保底奖励（所有参与者） ==========")
        local guaranteedItemId = REWARD_GUARANTEED.itemId
        local guaranteedCount = REWARD_GUARANTEED.count
        local guaranteedGiven = 0
        
        for _, player in ipairs(playersList) do
            local playerName = SafeGetUnitName(player)
            local success, result = pcall(function() 
                return player:AddItem(guaranteedItemId, guaranteedCount) 
            end)
            
            if success and result then
                guaranteedGiven = guaranteedGiven + 1
                local rewardKey = GetContributionIdentity(player)
                guaranteedRewardKeys[rewardKey] = true
                if REWARD_PROBABILITIES.guaranteedRewardNotify then
                    player:SendBroadcastMessage("你参与了『" .. bossName .. "』的战斗，获得保底奖励！")
                end
                print(" [奖励发放][保底]玩家 " .. playerName .. " 获得物品ID=" .. guaranteedItemId .. " x" .. guaranteedCount)
            else
                print(" [奖励发放][保底]玩家 " .. playerName .. " 发放失败（背包满或物品不存在），错误=" .. tostring(result))
            end
        end
        
        print(" [奖励发放]========== 保底奖励发放完成，共 " .. guaranteedGiven .. "/" .. #playersList .. " 名玩家获得 ==========")
    end
    
    -- ========== 随机奖励发放（限定人数） ==========
    local rewardCount = math.min(REWARD_PROBABILITIES.maxRandomRewardPlayers, #playersList)
    if rewardCount > 0 then
        print(" [奖励发放]========== 开始随机奖励抽取（最多 " .. rewardCount .. " 人） ==========")
        local selectedEntries = nil
        if #contributorPool > 0 then
            selectedEntries = SelectWeightedRewardWinners(contributorPool, rewardCount)
        else
            selectedEntries = {}
            local fallbackPool = {}
            for _, player in ipairs(playersList) do
                table.insert(fallbackPool, {player = player, score = 1, record = {name = SafeGetUnitName(player)}})
            end
            selectedEntries = SelectWeightedRewardWinners(fallbackPool, rewardCount)
        end
        
        for idx, selectedEntry in ipairs(selectedEntries) do
            local player = selectedEntry.player
            local playerName = SafeGetUnitName(player)
            local rewardKey = selectedEntry.record and selectedEntry.record.key or GetContributionIdentity(player)
            randomRewardKeys[rewardKey] = true
            if selectedEntry.record then
                print(string.format(" [奖励发放][抽奖] 玩家=%s 贡献分数=%.2f", playerName, selectedEntry.score or 0))
            end
            print(" [奖励发放]========== 开始为玩家 [" .. playerName .. "] 发放随机奖励 ==========")
            
            -- 1. 基础奖励（必掉，从REWARD_ITEMS中随机选一个）
            if not REWARD_ITEMS or #REWARD_ITEMS == 0 then
                print(" [奖励发放][" .. playerName .. "] 步骤1: REWARD_ITEMS为空，跳过")
            else
                local blue = REWARD_ITEMS[math.random(#REWARD_ITEMS)]
                print(" [奖励发放][" .. playerName .. "] 步骤1: 发放必掉奖励，物品ID=" .. blue)
                GiveRewardItem(player, blue, 1, "步骤1", playerName)
            end
            
            -- 2. 职业专属奖励（概率触发）
            local classItem = PickClassItemFor(player)
            RollReward(player, REWARD_PROBABILITIES.classRewardChance, {classItem}, 2, "职业奖励", playerName)
            
            -- 3. 稀有公式奖励（概率触发）
            RollReward(player, REWARD_PROBABILITIES.formulaRewardChance, REWARD_FORMULAS, 3, "公式奖励", playerName)
            
            -- 4. 坐骑奖励（概率触发）
            RollReward(player, REWARD_PROBABILITIES.mountRewardChance, REWARD_MOUNTS, 4, "坐骑奖励", playerName)
            
            -- 5. 金币奖励
            local gold = math.random(REWARD_GOLD.minCopper, REWARD_GOLD.maxCopper)
            local goldInGold = gold / 10000
            print(" [奖励发放][" .. playerName .. "] 步骤5: 发放金币，数量=" .. gold .. "铜（" .. string.format("%.1f", goldInGold) .. "金）")
            local success = pcall(function() player:ModifyMoney(gold) return true end)
            print(" [奖励发放][" .. playerName .. "] 步骤5结果: " .. (success and "✓ 金币发放成功" or "✗ 金币发放失败"))
            
            -- 发送通知
            player:SendBroadcastMessage("你击败了『" .. bossName .. "』，获得额外随机奖励！")
            table.insert(rewardedPlayers, playerName)
            print(" [奖励发放]========== 玩家 [" .. playerName .. "] 随机奖励发放完成 ==========")
        end

        if #rewardedPlayers > 0 then
            -- 去重玩家名称列表
            local uniqueNames = {}
            local nameSet = {}
            for _, name in ipairs(rewardedPlayers) do
                if not nameSet[name] then
                    nameSet[name] = true
                    table.insert(uniqueNames, name)
                end
            end
            
            local msg = "『" .. bossName .. "』被击败！获得额外随机奖励的玩家："
            for i, name in ipairs(uniqueNames) do
                if i > 1 then msg = msg .. "、" end
                msg = msg .. name
            end
            msg = msg .. "！所有参与者均获得保底奖励！"
            SendWorldMessage(msg)
            print(" [奖励发放]世界通告已发送: " .. msg)
            print(" [奖励发放]========== 随机奖励发放完成，共" .. #uniqueNames .. "名玩家获得 ==========")
        else
            print(" [奖励发放]========== 随机奖励无人获得 ==========")
        end
    else
        print(" [奖励发放]没有玩家符合奖励条件，跳过奖励发放")
        SendWorldMessage("『" .. bossName .. "』已被击败，但没有玩家获得奖励。")
        print(" [奖励发放]========== 奖励发放流程结束（无人获奖） ==========")
    end

    bossRuntimeState.lastDeathAt = deathTime
    PersistBossContributorSnapshots(
        bossContext,
        contributionState or bossContributionStats[guid],
        randomRewardKeys,
        guaranteedRewardKeys,
        deathTime
    )

    -- 清理
    if creature.RemoveEvents then creature:RemoveEvents() end
    bossAIStates[guid] = nil
    bossAllySpawned[guid] = nil
    bossTraitsApplied[guid] = nil
    bossBaseMaxHealth[guid] = nil
    bossAppliedAuras[guid] = nil
    bossRewardedGUIDs[guid] = nil
    if currentActiveBossGUID == guid then ClearActiveBoss() end
    scriptSpawnedBossGUIDs[guid] = nil
    bossThreatSnapshots[guid] = nil
    bossContributionStats[guid] = nil

    ScheduleBossRespawn(creature:GetInstanceId(), bossContext)
end

local function OnBossLeaveCombat(event, creature)
    local guid = creature:GetGUIDLow()
    creature:RemoveEvents()
    bossAIStates[guid] = nil
    bossAllySpawned[guid] = nil
    bossThreatSnapshots[guid] = nil
    -- 注意：不清理 bossContributionStats[guid]，贡献要跨「脱战 → 再进战」累积，
    -- 直到击杀结算（OnBossDied）或 GM 清理（.boss clear）时才释放。
    if scriptSpawnedBossGUIDs[guid] then
        local resetTime = BossNow()
        PersistBossRuntime(creature, {
            status = "spawned",
            phase = 1,
            last_reset_at = resetTime,
        })
        InsertBossEvent(creature, "leave_combat", "Boss 已脱离战斗。", "", 0, {})
    end
    RegisterBossPatrol(creature)
end

-- Boss击杀玩家嘲讽
local function OnBossKilledUnit(event, creature, victim)
    local guid = creature:GetGUIDLow()
    if not scriptSpawnedBossGUIDs[guid] then return end
    if not IsUnitValid(victim) then return end
    
    local victimName = SafeGetUnitName(victim)
    local victimClass = GetClassName(victim)
    
    -- 检查是否是治疗职业
    local isHealer = false
    local success, class = pcall(function() return victim:GetClass() end)
    if success and class then
        isHealer = (class == 2 or class == 5 or class == 7 or class == 11)  -- 骑牧萨德
    end
    
    -- 选择嘲讽列表
    local tauntList
    if isHealer then
        -- 混合治疗击杀嘲讽和普通击杀嘲讽
        tauntList = {}
        if BOSS_CONFIG.combatTaunts.killYells then
            for _, taunt in ipairs(BOSS_CONFIG.combatTaunts.killYells) do
                table.insert(tauntList, taunt)
            end
        end
        if BOSS_CONFIG.combatTaunts.healerKillYells then
            for _, taunt in ipairs(BOSS_CONFIG.combatTaunts.healerKillYells) do
                table.insert(tauntList, taunt)
            end
        end
    else
        tauntList = BOSS_CONFIG.combatTaunts.killYells
    end
    
    if tauntList and #tauntList > 0 then
        local yell = tauntList[math.random(#tauntList)]
        yell = string.gsub(yell, "{PLAYER_NAME}", victimName)
        yell = string.gsub(yell, "{CLASS}", victimClass)
        creature:SendUnitYell(yell, 0)
    end
end

local function OnBossSpawn(event, creature)
    local guid = creature:GetGUIDLow()
    if scriptSpawnedBossGUIDs[guid] then
        ApplyBossTraits(creature)
    end
end

-- GM命令
local function OnBossCommand(event, player, command, chatHandler)
    local parts = {}
    for part in string.gmatch(command, "%S+") do table.insert(parts, part) end

    -- 非 boss 命令交回核心处理，避免拦截其他 GM 指令
    if parts[1] ~= "boss" then return true end

    local authorized = player == nil
    if player and player.GetGMRank then authorized = player:GetGMRank() >= 1 end
    if not authorized and player and player.GetSecurity then authorized = player:GetSecurity() >= 1 end
    if not authorized and player and player.IsGM then authorized = player:IsGM() end

    if not authorized then
        BossReply(player, chatHandler, false, "你没有权限使用 .boss 命令。")
        return false
    end

    local actorName, actorGuid = BuildCommandActor(player)
    local action = parts[2]

    if action == "help" then
        -- 首行走 BossReply：控制台/SOAP 调用必须带回 [AGMP_OK] 标记，
        -- 否则面板的严格标记校验会把这几个「纯信息」子命令判成失败。
        BossReply(player, chatHandler, true, "Boss命令用法：")
        BossSendMessage(player, chatHandler, "1. .boss 或 .boss spawn 生成当前配置的Boss。")
        BossSendMessage(player, chatHandler, "2. .boss help 查看这份命令说明。")
        BossSendMessage(player, chatHandler, "3. .boss config reload 从 " .. BOSS_DB_NAME .. " 重新载入活动 Boss 配置。")
        BossSendMessage(player, chatHandler, "4. .boss config show [分组] 查看当前生效的配置项（不带分组则列出分组）。")
        BossSendMessage(player, chatHandler, "5. .boss preset list 查看所有技能池预设。")
        BossSendMessage(player, chatHandler, "6. .boss preset <key> 切换技能池预设。")
        BossSendMessage(player, chatHandler, "7. .boss difficulty list 查看所有技能强度档位。")
        BossSendMessage(player, chatHandler, "8. .boss difficulty <key> 切换技能强度档位。")
        BossSendMessage(player, chatHandler, "9. .boss rebase 按模板重算基准血量再套用倍率（需脱战）。")
        BossSendMessage(player, chatHandler, "10. .boss kill 击杀当前活跃Boss（走正常死亡与奖励流程）。")
        BossSendMessage(player, chatHandler, "11. .boss clear 直接移除当前活跃Boss并复位运行时记录（不发奖励）。")
        BossSendMessage(player, chatHandler, "当前Boss: " .. tostring(BOSS_CANDIDATES[1] and BOSS_CANDIDATES[1].name or "")
            .. " (Entry " .. tostring(BOSS_CANDIDATES[1] and BOSS_CANDIDATES[1].entry or 0) .. ")")
        BossSendMessage(player, chatHandler, "当前技能池: " .. GetCurrentSkillPresetLabel())
        BossSendMessage(player, chatHandler, "当前强度: " .. GetCurrentSkillDifficultyLabel())
        return false
    end

    if action == "config" then
        if parts[3] == "show" or parts[3] == "list" then
            -- 配置现在以数据库为准，这里让 GM 不必开数据库就能看到当前生效值
            if parts[4] and parts[4] ~= "" then
                ShowBossConfigGroup(player, chatHandler, parts[4])
            else
                ShowBossConfigGroups(player, chatHandler)
            end
            return false
        end

        if parts[3] ~= "reload" then
            BossReply(player, chatHandler, false, "用法: .boss config reload / .boss config show [分组]")
            return false
        end

        if not LoadBossConfigFromDB() then
            BossReply(player, chatHandler, false, "无法从 " .. BOSS_DB_NAME .. " 读取 Boss 配置。")
            return false
        end

        RegisterBossEventsForCandidates()

        local previousEntry = activeBossInfo and tonumber(activeBossInfo.entry or 0) or 0
        if IsUnitValid(activeBossCreature) and IsManagedBossEntry(activeBossCreature:GetEntry()) then
            -- 热加载只刷新技能池/光环等运行配置：
            -- 不在此处重算血量（重算需要 UpdateEntry，会清空威胁表，而且以当前上限为基准会造成倍率叠加）。
            -- 血量与强度档位（entry 对应的模板）在下次生成时生效。
            ApplyBossTraits(activeBossCreature, {registerAI = false})
        end

        PersistBossRuntime(activeBossCreature, {})
        InsertBossEvent(activeBossCreature, "command_config_reload", "Boss 配置已从数据库热加载。", actorName, actorGuid, {
            boss_entry = BOSS_CANDIDATES[1] and tonumber(BOSS_CANDIDATES[1].entry or 0) or 0,
            boss_name = BOSS_CANDIDATES[1] and tostring(BOSS_CANDIDATES[1].name or "") or "",
            skill_preset = ACTIVE_SKILL_PRESET_KEY or BOSS_CONFIG.skillPreset,
            skill_difficulty = ACTIVE_SKILL_DIFFICULTY_KEY or BOSS_CONFIG.skillDifficulty,
        })

        BossReply(player, chatHandler, true, "Boss 配置已从 " .. BOSS_DB_NAME .. " 热加载。")
        local configuredEntry = BOSS_CANDIDATES[1] and tonumber(BOSS_CANDIDATES[1].entry or 0) or 0
        if configuredEntry > 0 and previousEntry > 0 and configuredEntry ~= previousEntry then
            BossSendMessage(player, chatHandler, string.format(
                "提示：强度档位已从 entry %d 切换为 %d，当前活跃 Boss 仍使用旧模板，重生/重新生成后生效。",
                previousEntry, configuredEntry))
        end

        if player ~= nil and BOSS_CANDIDATES[1] then
            BossSendMessage(player, chatHandler, "当前 Boss: " .. ResolveBossCandidateName(BOSS_CANDIDATES[1].entry, BOSS_CANDIDATES[1].name) .. " (Entry " .. tostring(BOSS_CANDIDATES[1].entry) .. ")")
            BossSendMessage(player, chatHandler, "当前技能池: " .. GetCurrentSkillPresetLabel())
            BossSendMessage(player, chatHandler, "当前强度: " .. GetCurrentSkillDifficultyLabel())
        end
        return false
    end

    if action == "preset" then
        if not parts[3] or parts[3] == "list" then
            BossReply(player, chatHandler, true, "当前技能池预设: " .. GetCurrentSkillPresetLabel())
            BossSendMessage(player, chatHandler, "可选预设: " .. GetSkillPresetChoices())
            return false
        end

        if not SKILL_PRESET_LIBRARY[parts[3]] then
            BossReply(player, chatHandler, false, "技能池预设不存在：" .. tostring(parts[3]))
            return false
        end

        local resolvedKey, preset = ApplySkillPreset(parts[3])
        BOSS_CONFIG.skillPreset = resolvedKey
        PersistBossConfigToDB(false)
        PersistBossRuntime(activeBossCreature, {})
        InsertBossEvent(activeBossCreature, "command_preset", "技能预设已切换。", actorName, actorGuid, {
            preset = resolvedKey,
        })
        BossReply(player, chatHandler, true, "技能池已切换为 " .. resolvedKey .. "（" .. preset.displayName .. "）。")
        if player ~= nil then
            BossSendMessage(player, chatHandler, "说明: " .. preset.summary)
            BossSendMessage(player, chatHandler, "当前强度档位: " .. GetCurrentSkillDifficultyLabel())
        end
        return false
    end

    if action == "difficulty" then
        if not parts[3] or parts[3] == "list" then
            BossReply(player, chatHandler, true, "当前技能强度: " .. GetCurrentSkillDifficultyLabel())
            BossSendMessage(player, chatHandler, "可选强度: " .. GetSkillDifficultyChoices())
            return false
        end

        if not SKILL_DIFFICULTY_LIBRARY[parts[3]] then
            BossReply(player, chatHandler, false, "技能强度档位不存在：" .. tostring(parts[3]))
            return false
        end

        local _, _, resolvedDifficultyKey, difficulty = ApplySkillDifficulty(parts[3])
        BOSS_CONFIG.skillDifficulty = resolvedDifficultyKey
        PersistBossConfigToDB(false)
        PersistBossRuntime(activeBossCreature, {})
        InsertBossEvent(activeBossCreature, "command_difficulty", "技能强度已切换。", actorName, actorGuid, {
            difficulty = resolvedDifficultyKey,
        })
        BossReply(player, chatHandler, true, "技能强度已切换为 " .. resolvedDifficultyKey .. "（" .. difficulty.displayName .. "）。")
        if player ~= nil then
            BossSendMessage(player, chatHandler, "说明: " .. difficulty.summary)
            BossSendMessage(player, chatHandler, "当前技能池预设: " .. GetCurrentSkillPresetLabel())
        end
        return false
    end

    if action == "rebase" then
        local target = nil
        if player and player.GetSelectedUnit then
            target = player:GetSelectedUnit()
        end

        local validTarget = target and target.GetEntry and IsManagedBossEntry(target:GetEntry())
        if not validTarget and IsUnitValid(activeBossCreature) and IsManagedBossEntry(activeBossCreature:GetEntry()) then
            target = activeBossCreature
            validTarget = true
        end

        if not validTarget then
            BossReply(player, chatHandler, false, "当前没有可重基准的活跃 Boss。")
            return false
        end

        -- 重基准走 Creature:UpdateEntry：核心会 Initialize 威胁表，
        -- 战斗中执行等于把 Boss 打进脱战重置，因此战斗中直接拒绝。
        if CreatureIsInCombat(target) then
            BossReply(player, chatHandler, false, "Boss 正在战斗中，重基准会清空仇恨并重置战斗。请脱战后执行，或等它重生。")
            return false
        end

        ApplyBossTraits(target, {forceRebase = true, registerAI = false, heal = true})
        PersistBossRuntime(target, {})
        local resolvedGuid = SafeGetGuidLow(target)
        local resolvedBase = tonumber(bossBaseMaxHealth[resolvedGuid] or 0) or 0
        InsertBossEvent(target, "command_rebase", "已按模板重算 Boss 基准血量。", actorName, actorGuid, {
            health_multiplier = BOSS_CONFIG.bossHealthMultiplier,
            base_max_health = resolvedBase,
        })
        BossReply(player, chatHandler, true, string.format(
            "已按模板重算基准血量：基准=%d × 倍率=%s → 上限=%d。",
            resolvedBase,
            tostring(BOSS_CONFIG.bossHealthMultiplier),
            tonumber(target:GetMaxHealth() or 0) or 0))
        return false
    end

    if action == "kill" then
        -- 击杀当前活跃 Boss：走正常死亡流程（贡献结算、奖励发放、重生排程）
        local target = nil
        if IsUnitValid(activeBossCreature) and IsManagedBossEntry(activeBossCreature:GetEntry()) then
            target = activeBossCreature
        elseif activeBossInfo then
            target = TryGetCreatureByGUID(activeBossInfo.guid, activeBossInfo.entry, activeBossInfo.mapId, activeBossInfo.instanceId)
        end

        if not IsUnitValid(target) then
            BossReply(player, chatHandler, false, "当前没有可击杀的活跃 Boss。")
            return false
        end

        -- Unit:Kill 的参数是「被杀者」，调用者才是 killer，所以这里必须让 killer 去 Kill(target)
        local killerUnit = IsUnitValid(player) and player or target
        local killSuccess = pcall(function() killerUnit:Kill(target) end)
        if not killSuccess then
            BossReply(player, chatHandler, false, "击杀 Boss 失败（Kill 调用异常）。")
            return false
        end

        BossReply(player, chatHandler, true, "已击杀活跃 Boss（走正常死亡与奖励流程）。")
        return false
    end

    if action == "clear" or action == "despawn" then
        -- 清理活跃 Boss：直接移除、不发奖励、复位运行时记录（面板「重置」按钮）
        local target = nil
        if IsUnitValid(activeBossCreature) and IsManagedBossEntry(activeBossCreature:GetEntry()) then
            target = activeBossCreature
        elseif activeBossInfo then
            target = TryGetCreatureByGUID(activeBossInfo.guid, activeBossInfo.entry, activeBossInfo.mapId, activeBossInfo.instanceId)
        end

        local clearedGuid = activeBossInfo and tonumber(activeBossInfo.guid or 0) or 0
        local despawned = IsUnitValid(target)

        -- 先写事件（此时 activeBossInfo 还在，事件里能记下被清理的是哪个 Boss），再清理内存状态
        InsertBossEvent(nil, "command_clear", "GM 已清理活跃 Boss 并复位运行时记录。", actorName, actorGuid, {
            cleared_guid = clearedGuid,
            despawned = despawned and 1 or 0,
        })

        CancelRespawnTimer()

        if despawned then
            if target.RemoveEvents then
                target:RemoveEvents()
            end
            pcall(function() target:DespawnOrUnsummon(0) end)
        end

        bossAIStates[clearedGuid] = nil
        bossAllySpawned[clearedGuid] = nil
        bossTraitsApplied[clearedGuid] = nil
        bossBaseMaxHealth[clearedGuid] = nil
        bossAppliedAuras[clearedGuid] = nil
        bossRewardedGUIDs[clearedGuid] = nil
        bossThreatSnapshots[clearedGuid] = nil
        bossContributionStats[clearedGuid] = nil
        scriptSpawnedBossGUIDs[clearedGuid] = nil

        ClearActiveBoss()
        PersistBossRuntime(nil, {
            boss_guid = 0,
            boss_entry = 0,
            boss_name = "",
            map_id = 0,
            instance_id = 0,
            home_x = 0,
            home_y = 0,
            home_z = 0,
            status = "idle",
            phase = 0,
            respawn_at = 0,
            last_reset_at = BossNow(),
        })

        BossReply(player, chatHandler, true, string.format(
            "已清理活跃 Boss（GUID %d，%s）并复位运行时记录。",
            clearedGuid,
            despawned and "已从世界移除" or "世界中已不存在"))
        return false
    end

    if action ~= nil and action ~= "" and action ~= "spawn" then
        BossReply(player, chatHandler, false, "未知的 .boss 子命令（可用: spawn / help / config reload / config show / preset / difficulty / rebase / kill / clear）。")
        return false
    end

    if HasActiveBoss() then
        local bossInfo = GetActiveBossInfo()
        if bossInfo then
            BossReply(player, chatHandler, false, string.format(
                "当前已存在活跃的Boss：名称[%s] ID[%d] 坐标(%.1f, %.1f, %.1f)",
                bossInfo.name, bossInfo.entry, bossInfo.x, bossInfo.y, bossInfo.z))
        else
            BossReply(player, chatHandler, false, "当前已存在活跃的Boss。")
        end
        return false
    end

    CancelRespawnTimer()
    if not BOSS_CANDIDATES or #BOSS_CANDIDATES == 0 then
        BossReply(player, chatHandler, false, "错误：BOSS候选列表为空，无法生成。")
        return false
    end

    local boss = nil
    local bossName = nil
    if player == nil then
        boss = SpawnRandomBoss(0)
        if boss then
            bossName = SafeGetUnitName(boss)
            InsertBossEvent(boss, "command_spawn", "控制台命令生成 Boss。", actorName, actorGuid, {
                spawn_source = "console",
            })
        end
    else
        local bossCandidate = BOSS_CANDIDATES[math.random(#BOSS_CANDIDATES)]
        boss = PerformIngameSpawn(1, bossCandidate.entry, player:GetMapId(), player:GetInstanceId(), 
                                         player:GetX(), player:GetY(), player:GetZ(), player:GetO(), false, 0, 1)
        if boss then
            SetActiveBoss(boss)
            ApplyBossTraits(boss, {
                homeX = player:GetX(),
                homeY = player:GetY(),
                homeZ = player:GetZ(),
                homeO = player:GetO(),
            })
            boss:SendUnitYell(BOSS_CONFIG.bossGMSpawnYell, 0)
            bossName = bossCandidate.name
            PersistBossRuntime(boss, {
                status = "spawned",
                phase = 1,
                respawn_at = 0,
                last_spawn_at = BossNow(),
            })
            InsertBossEvent(boss, "command_spawn", "GM 命令在当前位置生成 Boss。", actorName, actorGuid, {
                spawn_source = "player",
                map_id = player:GetMapId(),
                instance_id = player:GetInstanceId(),
            })
        end
    end

    if boss then
        BossReply(player, chatHandler, true, "已生成BOSS『" .. tostring(bossName or SafeGetUnitName(boss)) .. "』。")
        if player ~= nil then
            BossSendMessage(player, chatHandler, "当前技能池预设: " .. GetCurrentSkillPresetLabel())
            BossSendMessage(player, chatHandler, "当前技能强度: " .. GetCurrentSkillDifficultyLabel())
        end
    else
        BossReply(player, chatHandler, false, "Boss 生成失败。")
    end

    return false
end

local registeredBossEntries = {}

RegisterBossEventsForEntry = function(entry)
    local numericEntry = tonumber(entry) or 0
    if numericEntry <= 0 or registeredBossEntries[numericEntry] then
        return
    end

    RegisterCreatureEvent(numericEntry, 1, OnBossEnterCombat)
    RegisterCreatureEvent(numericEntry, 2, OnBossLeaveCombat)
    RegisterCreatureEvent(numericEntry, 3, OnBossKilledUnit)
    RegisterCreatureEvent(numericEntry, 4, OnBossDied)
    RegisterCreatureEvent(numericEntry, 5, OnBossSpawn)
    RegisterCreatureEvent(numericEntry, 9, OnBossDamageTaken)

    registeredBossEntries[numericEntry] = true
end

-- 候选 entry + 全部强度档位模板都挂事件：
-- 面板切档后，旧档位残留的 Boss 依旧受管（可清理、可结算），无需重启服务器。
RegisterBossEventsForCandidates = function()
    for _, bossCandidate in ipairs(BOSS_CANDIDATES) do
        RegisterBossEventsForEntry(bossCandidate.entry)
    end

    for _, tierEntry in ipairs(BOSS_TIER_ENTRIES) do
        RegisterBossEventsForEntry(tierEntry)
    end
end

if not LoadBossRuntimeFromDB() then
    PersistBossRuntime(nil, {
        status = bossRuntimeState.status,
        phase = bossRuntimeState.phase,
    })
end

-- ========== 注册事件 ==========
RegisterBossEventsForCandidates()

RegisterPlayerEvent(42, OnBossCommand)
RegisterPlayerEvent(65, OnBossFightPlayerHeal)