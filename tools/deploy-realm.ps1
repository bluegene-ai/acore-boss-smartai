# ============================================================================
#  deploy-realm.ps1 — 把 boss.lua 部署到某个区（多区部署标准步骤）
# ----------------------------------------------------------------------------
#  多区（多个 realm 共用一套 auth）各区共用同一个库（默认 ac_eluna），靠 state_key 分租；
#  各区之间唯一的差别就是 boss.lua §2 的那一个 key（BOSS_RUNTIME_KEY + BOSS_CONFIG_KEY，两行必须相同）。
#
#    1. 从仓库取 boss.lua，改写 §2 的本区 key → 写入 <RealmRoot>\lua_scripts\boss.lua
#       （-DbName 只在给某个区单独一个库时才需要；默认 ac_eluna）
#    2. 写入前自动备份（boss.lua.<时间戳>.bak）
#    3. 可选：语法检查（-LuaExe）与导入难度档位 SQL（-ApplyTierSql <world 库>）；
#       导入前会把 SQL 里写死的库名**与本区 key** 一起改写，避免动到别的区
#    4. 打印 AGMP 面板 config/boss.php 需要同步的 server_overrides 片段
#
#  用法：
#    # 主区（从单区升级上来）：key 保持 current，不改库名
#    pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-a>
#    # 第二个区：必须给它自己的 key（不能是 current，否则与主区共用一份数据）
#    pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-b> -RuntimeKey <realm-b>
#    # 连难度档位模板一起导进该区的 world 库
#    pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-b> -RuntimeKey <realm-b> `
#        -ApplyTierSql <该区 world 库>
#
#  部署完：让该区 worldserver 重新加载 Eluna（.reload ale 或重启），并把面板
#          config/generated/boss.php 的 server_overrides 加上该区（脚本会打印片段）。
# ============================================================================

[CmdletBinding()]
param(
    # 该区的 worldserver 根目录（里面应有 lua_scripts\ 与 worldserver.exe），例如 D:\AzerothCore\release\<realm-b>
    [Parameter(Mandatory = $true)][string]$RealmRoot,

    # 数据库名；多区共用库时保持默认 ac_eluna 即可（只有想给该区单独一个库时才改）
    [string]$DbName = 'ac_eluna',

    [string]$RuntimeKey = 'current',

    # 源文件；默认取本仓库根目录的 boss.lua
    [string]$Source = '',

    # 可选：Lua 解释器路径，给了就对新文件做一次语法检查
    [string]$LuaExe = '',

    # 可选：把难度档位 SQL 导入这个 world 库（如 <该区 world 库>）
    [string]$ApplyTierSql = '',

    # 可选：MySQL 客户端与连接参数（仅在 -ApplyTierSql 时需要）
    [string]$MysqlExe = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 3306,
    [string]$DbUser = 'root',
    [string]$DbPassword = '',

    # 只打印将要发生的改动，不写文件
    [switch]$DryRun,

    # 不备份原文件（不推荐）
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

if ($Source -eq '') {
    $Source = Join-Path (Split-Path -Parent $PSScriptRoot) 'boss.lua'
}

function Write-Step([string]$text) { Write-Host "== $text" }
function Write-Detail([string]$text) { Write-Host "   $text" }

# ---------------------------------------------------------------------- 校验
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "找不到源文件 boss.lua: $Source"
}
if (-not (Test-Path -LiteralPath $RealmRoot -PathType Container)) {
    throw "找不到区服目录: $RealmRoot（应指向该区 worldserver.exe 所在目录）"
}

$luaDir = Join-Path $RealmRoot 'lua_scripts'
if (-not (Test-Path -LiteralPath $luaDir -PathType Container)) {
    throw "$RealmRoot 下没有 lua_scripts\ 目录；这不像一个已部署的 worldserver 目录。"
}

if ($DbName -notmatch '^[A-Za-z0-9_]+$') {
    throw "库名只允许字母/数字/下划线: $DbName"
}
if ($RuntimeKey -notmatch '^[A-Za-z0-9_]+$') {
    throw "state_key 只允许字母/数字/下划线: $RuntimeKey"
}

$target = Join-Path $luaDir 'boss.lua'
$sourceText = [System.IO.File]::ReadAllText($Source)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ------------------------------------------------------------------- 改写常量
Write-Step "改写 §2 本区绑定"

$dbPattern = '(local BOSS_DB_NAME\s*=\s*")[^"]*(")'
$keyPattern = '(local BOSS_RUNTIME_KEY\s*=\s*")[^"]*(")'
$configKeyPattern = '(local BOSS_CONFIG_KEY\s*=\s*")[^"]*(")'

$dbMatches = [regex]::Matches($sourceText, $dbPattern)
$keyMatches = [regex]::Matches($sourceText, $keyPattern)
$configKeyMatches = [regex]::Matches($sourceText, $configKeyPattern)

if ($dbMatches.Count -ne 1) {
    throw "在 boss.lua 里匹配到 $($dbMatches.Count) 处 BOSS_DB_NAME 赋值（应为 1 处）；常量位置变了，请同步本脚本与 smoke.lua。"
}
if ($keyMatches.Count -ne 1) {
    throw "在 boss.lua 里匹配到 $($keyMatches.Count) 处 BOSS_RUNTIME_KEY 赋值（应为 1 处）；常量位置变了，请同步本脚本与 smoke.lua。"
}
if ($configKeyMatches.Count -ne 1) {
    throw "在 boss.lua 里匹配到 $($configKeyMatches.Count) 处 BOSS_CONFIG_KEY 赋值（应为 1 处）；常量位置变了，请同步本脚本与 smoke.lua。"
}

Write-Detail ("库名     : " + $dbMatches[0].Value.Trim() + "  →  local BOSS_DB_NAME = `"$DbName`"")
Write-Detail ("本区 key : " + $keyMatches[0].Value.Trim() + "  →  local BOSS_RUNTIME_KEY = `"$RuntimeKey`"")
Write-Detail ("配置 key : " + $configKeyMatches[0].Value.Trim() + "  →  local BOSS_CONFIG_KEY = `"$RuntimeKey`"")

if ($RuntimeKey -eq 'current' -and $DbName -eq 'ac_eluna') {
    Write-Host "   [注意] key 仍是 current：只有『主区』（从单区升级上来的那个区）可以这样。" -ForegroundColor Yellow
    Write-Host "          其它区必须各给一个不同的 -RuntimeKey，否则两个区共用同一份配置/运行态/事件。" -ForegroundColor Yellow
}

# 保留原有换行符（仓库里是 CRLF，原样带过去）
$newText = [regex]::Replace($sourceText, $dbPattern, ('${1}' + $DbName + '${2}'), 1)
$newText = [regex]::Replace($newText, $keyPattern, ('${1}' + $RuntimeKey + '${2}'), 1)
$newText = [regex]::Replace($newText, $configKeyPattern, ('${1}' + $RuntimeKey + '${2}'), 1)

$sourceBytes = [System.IO.File]::ReadAllBytes($Source)
$hasBom = ($sourceBytes.Length -ge 3 -and $sourceBytes[0] -eq 0xEF -and $sourceBytes[1] -eq 0xBB -and $sourceBytes[2] -eq 0xBF)
Write-Detail ("源文件: $Source ($($sourceBytes.Length) 字节, BOM: $(if ($hasBom) { '有' } else { '无' }))")
Write-Detail ("目标文件: $target")

# ------------------------------------------------------------------ 语法检查
if ($LuaExe -ne '') {
    Write-Step '语法检查（改写后的内容）'
    if (-not (Test-Path -LiteralPath $LuaExe -PathType Leaf)) {
        throw "找不到 Lua 解释器: $LuaExe"
    }

    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ('boss-realm-check-' + [guid]::NewGuid().ToString('N') + '.lua')
    try {
        [System.IO.File]::WriteAllText($probe, $newText, $utf8NoBom)
        $checkScript = "local f, err = loadfile([[$probe]]); if f then print('SYNTAX OK') else print('SYNTAX ERROR: '..tostring(err)) end"
        $checkOut = & $LuaExe -e $checkScript
        Write-Detail ([string]$checkOut)
        if ([string]$checkOut -notmatch 'SYNTAX OK') {
            throw '改写后的 boss.lua 语法检查失败，未写入目标文件。'
        }
    } finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
    }
} else {
    Write-Step '语法检查：跳过（未提供 -LuaExe）'
}

# ---------------------------------------------------------------------- 写入
if ($DryRun) {
    Write-Step 'DryRun：不写任何文件'
} else {
    Write-Step '写入目标文件'
    if ((Test-Path -LiteralPath $target) -and -not $NoBackup) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$target.$stamp.bak"
        Copy-Item -LiteralPath $target -Destination $backup -Force
        Write-Detail "已备份原文件: $backup"
    } elseif ($NoBackup) {
        Write-Detail '未备份（-NoBackup）'
    }

    [System.IO.File]::WriteAllText($target, $newText, $utf8NoBom)
    $written = [System.IO.File]::ReadAllBytes($target)
    Write-Detail "写入完成: $($written.Length) 字节（全库字形保持一致；Eluna 读该文件无需 BOM）"
}

# --------------------------------------------------------------- 难度档位 SQL
if ($ApplyTierSql -ne '') {
    $tierSql = Join-Path (Split-Path -Parent $PSScriptRoot) 'sql\2026_09_23_activity_boss_tiers_190090_190093.sql'
    Write-Step "导入难度档位模板 → $ApplyTierSql"
    if (-not (Test-Path -LiteralPath $tierSql -PathType Leaf)) {
        throw "找不到难度档位 SQL: $tierSql"
    }

    # 该文件的 creature_template 部分作用在默认库（= -ApplyTierSql），但末尾那次
    # `ac_eluna`.`boss_activity_config` 切换既写死了库名、也用 `state_key = 'current'`
    # 选中「主区」那一行 —— 多区共用库时两个都要改写，否则会去改主区的活动配置。
    $tierText = [System.IO.File]::ReadAllText($tierSql)
    $schemaHits = ([regex]::Matches($tierText, '`ac_eluna`')).Count
    $keyHits = ([regex]::Matches($tierText, "state_key`` = 'current'")).Count
    $tierForRealm = $tierText -replace '`ac_eluna`', ('`' + $DbName + '`')
    $tierForRealm = $tierForRealm -replace "state_key`` = 'current'", ("state_key`` = '" + $RuntimeKey + "'")
    Write-Detail "SQL 内写死的库名 ``ac_eluna``: $schemaHits 处 → ``$DbName``"
    Write-Detail "SQL 内写死的本区 key 'current': $keyHits 处 → '$RuntimeKey'"

    if ($DryRun) {
        Write-Detail "DryRun：将执行 mysql < 改写后的 SQL（库 $ApplyTierSql）"
    } else {
        if (-not (Test-Path -LiteralPath $MysqlExe -PathType Leaf)) {
            throw "找不到 mysql.exe: $MysqlExe（可用 -MysqlExe 指定）"
        }
        if ($DbPassword -eq '') {
            throw '导入 SQL 需要 -DbPassword（或用面板/手工导入），避免在命令行里留下空密码提示。'
        }

        $tmpSql = Join-Path ([System.IO.Path]::GetTempPath()) ('boss-realm-tiers-' + [guid]::NewGuid().ToString('N') + '.sql')
        try {
            [System.IO.File]::WriteAllText($tmpSql, $tierForRealm, $utf8NoBom)
            $mysqlArgs = @("--host=$DbHost", "--port=$DbPort", "--user=$DbUser", "--password=$DbPassword",
                           '--default-character-set=utf8mb4', $ApplyTierSql)
            Get-Content -LiteralPath $tmpSql -Raw | & $MysqlExe @mysqlArgs 2>&1 |
                ForEach-Object { if ($_ -notmatch 'Using a password') { Write-Detail ([string]$_) } }
            if ($LASTEXITCODE -ne 0) { throw "导入失败（mysql 退出码 $LASTEXITCODE）" }
        } finally {
            if (Test-Path -LiteralPath $tmpSql) { Remove-Item -LiteralPath $tmpSql -Force }
        }

        Write-Detail '导入完成；该区 worldserver 里执行 .reload creature_template 后生效。'
    }
}

# --------------------------------------------------------- 面板需要同步的片段
Write-Step 'AGMP 面板需要同步的配置（config/generated/boss.php → server_overrides）'
Write-Host @"
   <该区的 server 索引> => [
       'custom_db_name' => '$DbName',
       'runtime_key'   => '$RuntimeKey',   // 必须与该区 boss.lua §2 的 key 相同
   ],
"@
Write-Host ''
Write-Step '收尾'
Write-Detail '让该区 worldserver 重新加载 Eluna 脚本：游戏内 .reload ale（或重启该区）'
Write-Detail "确认绑定：该区 lua_scripts\lua_logs\boss.log 里应出现 [BOSS] 本区绑定: db=$DbName configKey=$RuntimeKey runtimeKey=$RuntimeKey"
Write-Detail '确认没串区：面板「Boss 活动管理」页头显示的 state_key 应与上面一致'
Write-Detail '★ 每个区的 key 必须不同：两个区用同一个 key 就是共用同一份配置/运行态/事件'
Write-Step '完成'
