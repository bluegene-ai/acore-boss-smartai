# Acore Boss SmartAI Lua

AzerothCore 3.3.5a Eluna Boss activity script with runtime persistence, hot-reload config, event tracking, and contributor snapshots.

## Features

- Smart combat AI with multiple skill presets and difficulty modes.
- **Selectable power tiers** backed by dedicated `creature_template` entries (see [Difficulty tiers](#difficulty-tiers)).
- **All settings live in the database**: the script only ships defaults, the running config comes from `ac_eluna` (see [Where to change config](#where-to-change-config)).
- Runtime persistence in `ac_eluna`:
  - `boss_activity_runtime`
  - `boss_activity_config` (shared with the AGMP panel)
  - `boss_activity_config_ext` (script-private settings)
  - `boss_activity_events`
  - `boss_activity_contributors`
- Automatic schema bootstrap and migration in Lua (no Web-side table creation required).
- Dedicated boss templates: the activity boss no longer borrows a dungeon boss, so no core `SmartAI` scripts run on top of Eluna.
- In-game / console commands:

| Command | Effect |
|---|---|
| `.boss` / `.boss spawn` | Spawn the boss at a configured spawn point |
| `.boss kill` | Kill the active boss through the normal death + reward flow |
| `.boss clear` (alias `.boss despawn`) | Remove the active boss without rewards and reset the runtime row |
| `.boss rebase` | Recompute base health from the template and re-apply the multiplier (**out of combat only**) |
| `.boss config reload` | Hot reload config from `ac_eluna` (used by AGMP after saving) |
| `.boss config show [group]` | Print the effective config (no group = list the 16 groups) |
| `.boss preset list` / `.boss preset <key>` | List / switch the skill preset |
| `.boss difficulty list` / `.boss difficulty <key>` | List / switch the skill cadence tier |
| `.boss help` | Help |

## Where to change config

`boss.lua` keeps **shipped defaults** in one place (§3 "配置区" at the top of the file).
Once a row exists in the database those defaults are no longer used — bootstrap writes
happen with `INSERT IGNORE`. Precedence:

1. **AGMP panel** — the *Basic config* tab edits `boss_activity_config` (boss identity, stats, spawn points, skill preset, rewards); the *Extended config* tab edits `boss_activity_config_ext` (yells, taunts, AI cadence, phase thresholds, patrol, minions, helpers, classes, managed tiers), grouped into second-level tabs.
2. **Database** — `boss_activity_config` (panel-shared columns) and `boss_activity_config_ext` (script-private columns).
3. **Script §3 defaults** — only for a brand-new deployment without a config row.

After editing, run `.boss config reload` (the panel does this automatically) or restart worldserver.

### The two config tables

| Table | Contents | Written by |
|---|---|---|
| `boss_activity_config` | Boss identity, level/scale/health multiplier, auras, ally helper, spawn points, skill preset, rewards | AGMP panel (`REPLACE INTO`, whole row) + Lua |
| `boss_activity_config_ext` | Yells, combat taunts (12 text lists), AI cadence, phase thresholds, patrol, minion AI, helper entries, class types + class reward pools, managed tier entries | Lua (create/seed) + AGMP panel (`INSERT ... ON DUPLICATE KEY UPDATE`, submitted columns only) |

Why two tables: AGMP saves the main table with `REPLACE INTO`, which resets every column it
does not know about to the table default; script-private settings there would be wiped on each
panel save. The panel only upserts the ext table, so columns the script adds later survive.

### Adding a config item

1. Add the default value in §3 (or reuse an existing field).
2. Add one row to `BOSS_CONFIG_SCHEMA_MAIN` (panel-shared column: also update AGMP and the
   `CREATE TABLE`) or `BOSS_CONFIG_SCHEMA_EXT` (script-private) with
   `group / column / kind / target / key` (ext rows also need `ddl`).
3. The ext table DDL, the read path, the write path and `.boss config show` all follow
   automatically. To make it editable in the panel, add the column to AGMP's
   `config/boss.php` (`ext_fields`, with type/bounds) plus its zh_CN/en label —
   `php tools/verify_boss_ext_page.php` cross-checks the panel schema against this
   descriptor table column by column.

Value kinds (`kind`): `int`, `bool`, `scaled` (decimal ×100 stored as INT), `text`,
`text_keep`, `intlist`, `lines`, `keyedlines`, `keyedword`, `keyedintlist`, `spawnpoints`.

### What intentionally stays in the script

- Skill presets / difficulty coefficients / interrupt spell pool (§5 content library): these
  are combat *content* (spell ids, cooldowns, trigger conditions), released with the version;
  the selectable parts (which preset, which tier) are in the database.
- Display strings (class names), minion scatter distances and a few condition constants:
  logic constants rather than tunables.

## Difficulty tiers

Instead of reusing `entry 647` (Captain Greenskin from the Deadmines, whose template carries `AIName=SmartAI` plus two `smart_scripts` rows), the activity boss uses dedicated level-83 templates with no `AIName`, no `smart_scripts` and no loot:

| entry | tier | HealthModifier | DamageModifier | rank | health @ multiplier 1500 |
|---|---|---|---|---|---|
| 190090 | entry (live-equivalent) | 0.21 | 1.0 | 1 | 4,392,675 |
| 190091 | standard (5 players) | 0.60 | 2.0 | 1 | 12,550,500 |
| 190092 | hard (10 players) | 1.45 | 4.0 | 3 | 30,330,376 |
| 190093 | raid (25 players) | 3.60 | 7.0 | 3 | 75,302,998 |

- Health formula: `creature_classlevelstats(level=83, class=1).basehp2(=13945) × HealthModifier × (boss_health_multiplier_scaled / 100)`.
- The tier is stored in `boss_activity_config.boss_entry`; AGMP exposes it as a "difficulty tier" dropdown and shows the estimated health for the current multiplier.
- The panel's health multiplier is a global knob: changing it scales all tiers proportionally.
- SQL for the templates: `sql/2026_09_23_activity_boss_tiers_190090_190093.sql` (see `sql/README.md` for the deploy runbook).

## Defects fixed in the 2026-09 review

| Severity | Issue | Fix |
|---|---|---|
| P1 | `GetCreatureByGUID()` does not exist in mod-ale/Eluna, so the "recover the live boss from the DB" branch was dead code → after a Lua reload the DB row was wiped as stale while the boss was still alive, and the next `.boss spawn` created a **second** boss | Look the creature up with `GetMapById()` + `GetUnitGUID(low, entry)` + `Map:GetWorldObject()` |
| P1 | `IsManagedBossEntry`, `DEFAULT_SPAWN_POINTS` and `activeBossInfo` were referenced **before** their `local` declarations, so those references resolved to globals (`nil`) — `activeBossInfo` silently disabled renaming the live boss on config reload | Forward declare them at the top of the file (and register all tier entries, not just the configured one) |
| P1 | `rebase`/`config reload` used the **current** max health as the base → every reload multiplied health again (with multiplier 1500: 4.4M → 6.6B, overflowing `uint32`), and unconditionally healed the boss to full | Recompute the base from the template via `Creature:UpdateEntry()` while **out of combat** (it resets the threat table); in combat fall back to `current / multiplier` so it never compounds; heal only on first spawn or when explicitly requested |
| P1 | `Unit:SetLevel()` only writes `UNIT_FIELD_LEVEL` and does not recompute creature stats, so `bossLevel = 83` was cosmetic (stats came from the level-20 template) | Level-83 templates with real WotLK stat rows (`exp=2`) |
| P1 | Contribution stats were reset on every enter-combat and discarded on leave-combat, so damage dealt before a reset never reached the snapshot or the reward roll | Accumulate per boss guid; release only on death settlement or `.boss clear` |
| P2 | Config auras were only ever `AddAura`-ed — auras removed from the config were never removed from the boss | Track applied auras per guid and `RemoveAura` the difference |
| P2 | The script overwrote the **global** `print`, so every Eluna script loaded after it logged into `boss.log` instead of the console | Shadow `print` file-locally (`local print = BossLog`); the "loading OK" banner still goes to the console |
| P2 | No log rotation; unbounded log growth | 5 MB rotation to `boss.log.<timestamp>.bak` |
| P2 | Event/contributor text could exceed its column width (strict mode would silently drop the whole insert) | UTF-8-safe truncation at the column width |
| P2 | Empty `SPAWN_POINTS` would raise `math.random(0)` ("interval is empty") | Explicit guard with a log line |
| P2 | Info-only subcommands (`.boss help`, `preset list`, `difficulty list`) returned **no** `[AGMP_OK]`/`[AGMP_ERROR]` marker, so strict callers judged them as failures | First line of those replies goes through `BossReply` |
| P3 | `bossRewardedGUIDs` grew forever | Cleared on death |

## Testing without a server

`tools/boss-lua-smoke/smoke.lua` loads `boss.lua` into a stubbed Eluna environment (no `worldserver` needed) and asserts 63 invariants: load-time behaviour, SQL construction for both config tables, ext-table DDL/INSERT column consistency, command markers, `.boss config show` output, "database values actually win over script defaults", `.boss clear` side effects, event registration, and the two regressions above ("no global `print` override", "no leaked globals"). See `tools/boss-lua-smoke/README.md`.

```
lua smoke.lua /path/to/boss.lua          # exit 0 = all assertions pass
```

## Requirements

- AzerothCore 3.3.5a with Eluna enabled (tested against `mod-ale`, the Eluna fork used by AzerothCore).
- MySQL/MariaDB with the `characters` DB accessible.
- Script placed in the `lua_scripts` load path.
- The script talks to the `ac_eluna` schema through `CharDBQuery`/`CharDBExecute`; the name is the `BOSS_DB_NAME` constant at the top of `boss.lua` — change it if your database is named differently.

## Install

1. Copy `boss.lua` to your Eluna scripts folder.
2. (Optional) Create the dedicated templates with `sql/2026_09_23_activity_boss_tiers_190090_190093.sql`, then `.reload creature_template`.
3. Restart `worldserver` (or `.reload ale`).
4. Verify server logs for schema bootstrap output.

## Standalone Mode (Without Web)

This script is designed to run independently.

- On load, Lua ensures database/table existence.
- Config defaults are inserted by Lua if missing.
- Runtime/event/contributor records are written by Lua only.

No AGMP/Web dependency is required for core functionality.

## Using With AGMP Web Management

This script is compatible with the AGMP Boss module.

### Responsibility Split

- Lua owns schema creation/migration and runtime persistence.
- AGMP only reads/writes data and sends SOAP commands (including the difficulty tier selection and the kill/reset buttons).
- If tables are missing, AGMP shows warnings instead of creating schema.
- Console/SOAP replies carry an `[AGMP_OK]` / `[AGMP_ERROR]` marker; AGMP treats a reply without a marker as a failure, so a command that never reached the game is not reported as success.

### Recommended AGMP Flow

1. Ensure `boss.lua` has been loaded at least once (creates schema).
2. Open AGMP Boss page.
3. Edit config in Web UI (including spawn points text and difficulty tier).
4. Save config in AGMP.
5. AGMP calls `.boss config reload` via SOAP.

### Key AGMP Config Expectations

- AGMP points to `ac_eluna` as custom DB for Boss module.
- `boss_activity_config` contains a `spawn_points_text` column.
- The panel writes the main table with `REPLACE INTO` (fixed column list) and the ext table with
  `INSERT ... ON DUPLICATE KEY UPDATE` (submitted columns only) — add a main-table column only
  together with the panel code, an ext-table column is safe on its own.
- SOAP account has permission to execute Boss commands.
- `php tools/verify_boss_ext_page.php` cross-checks the panel's ext schema against `boss.lua`'s
  descriptor table and renders the page in both locales (81 checks).

## Security and Ops Notes

- Restrict command permissions to trusted GM/admin roles.
- Back up `ac_eluna` before major tuning changes.
- Keep the script and AGMP module versions aligned.
- Never replay a dumped SQL file containing `CREATE`/`ALTER` against a live database inside `START TRANSACTION`/`ROLLBACK`: MySQL DDL implicitly commits. Use a scratch schema instead (see `tools/boss-lua-smoke/README.md`).

## License

MIT. See `LICENSE`.
