# Acore Boss SmartAI Lua

AzerothCore 3.3.5a Eluna Boss activity script with runtime persistence, hot-reload config, event tracking, and contributor snapshots.

## Features

- Smart combat AI with multiple skill presets and difficulty modes.
- Runtime persistence in `ac_eluna`:
  - `boss_activity_runtime`
  - `boss_activity_config`
  - `boss_activity_events`
  - `boss_activity_contributors`
- Automatic schema bootstrap and migration in Lua (no Web-side table creation required).
- Supports in-game/console commands such as:
  - `.boss spawn`
  - `.boss config reload`
  - `.boss preset <preset>`
  - `.boss difficulty <difficulty>`
  - `.boss rebase`

## Requirements

- AzerothCore 3.3.5a with Eluna enabled.
- MySQL/MariaDB with `characters` DB accessible.
- Script placed in `lua_scripts` load path.

## Install

1. Copy `boss.lua` to your Eluna scripts folder.
2. Restart `worldserver` (or reload scripts if your environment supports it).
3. Verify server logs for schema bootstrap output.

## Standalone Mode (Without Web)

This script is designed to run independently.

- On load, Lua ensures database/table existence.
- Config defaults are inserted by Lua if missing.
- Runtime/event/contributor records are written by Lua only.

No AGMP/Web dependency is required for core functionality.

## Using With AGMP Web Management

This script is compatible with AGMP Boss module.

### Responsibility Split

- Lua owns schema creation/migration and runtime persistence.
- AGMP only reads/writes data and sends SOAP commands.
- If tables are missing, AGMP shows warnings instead of creating schema.

### Recommended AGMP Flow

1. Ensure `boss.lua` has been loaded at least once (creates schema).
2. Open AGMP Boss page.
3. Edit config in Web UI (including spawn points text).
4. Save config in AGMP.
5. AGMP calls `.boss config reload` via SOAP.

### Key AGMP Config Expectations

- AGMP points to `ac_eluna` as custom DB for Boss module.
- `boss_activity_config` contains a `spawn_points_text` column.
- SOAP account has permission to execute Boss commands.

## Security and Ops Notes

- Restrict command permissions to trusted GM/admin roles.
- Back up `ac_eluna` before major tuning changes.
- Keep the script and AGMP module versions aligned.

## License

MIT. See `LICENSE`.
