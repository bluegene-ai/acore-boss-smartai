-- ============================================================================
--  2026_09_24 — 活动 Boss 脚本私有配置表 ac_eluna.boss_activity_config_ext
-- ----------------------------------------------------------------------------
--  背景：喊话 / 战斗嘲讽 / 巡逻 / 小怪节奏 / 职业奖励 / 受管模板等原来写死在
--        boss.lua 里，现在全部落库。这些列不能放进 boss_activity_config：
--        AGMP 保存配置时用 REPLACE INTO 重写那张表，凡不在它列清单里的列都会被
--        重置为建表默认值，所以脚本私有配置单独一张表。
--
--  ⚠ 通常**不需要手工执行本文件**：boss.lua 每次加载都会执行等价的
--     CREATE TABLE IF NOT EXISTS（列由 §3 配置区的 BOSS_CONFIG_SCHEMA_EXT 生成），
--     首次加载还会用 INSERT IGNORE 写入默认值。
--     本文件用于：DBA 预建表 / 数据库账号无建表权限时由 DBA 代建 / 人工复核列定义。
--
--  列的**唯一来源**是 boss.lua §3 的 BOSS_CONFIG_SCHEMA_EXT：
--  想加配置项请改描述表（并同步本文件），不要只手改数据库。
-- ============================================================================

CREATE TABLE IF NOT EXISTS `ac_eluna`.`boss_activity_config_ext` (
  `state_key` VARCHAR(32) NOT NULL,
  -- [yells] 喊话
  `boss_spawn_yell` VARCHAR(255) NOT NULL DEFAULT '',
  `boss_enter_combat_yell` VARCHAR(255) NOT NULL DEFAULT '',
  `ally_spawn_yell` VARCHAR(255) NOT NULL DEFAULT '',
  `boss_respawn_yell` VARCHAR(255) NOT NULL DEFAULT '',
  `boss_gm_spawn_yell` VARCHAR(255) NOT NULL DEFAULT '',
  -- [taunts] 战斗嘲讽（多行文本，一行一条；"键=值" 行表示按键索引，如 技能名=喊话）
  `taunt_cooldown_seconds` INT NOT NULL DEFAULT 8,
  `random_taunt_chance` INT NOT NULL DEFAULT 15,
  `taunt_phase2_yells_text` TEXT NULL,
  `taunt_phase3_yells_text` TEXT NULL,
  `taunt_critical_hp_yells_text` TEXT NULL,
  `taunt_skill_cast_yells_text` TEXT NULL,
  `taunt_target_switch_yells_text` TEXT NULL,
  `taunt_interrupt_yells_text` TEXT NULL,
  `taunt_kill_yells_text` TEXT NULL,
  `taunt_low_hp_yells_text` TEXT NULL,
  `taunt_healer_kill_yells_text` TEXT NULL,
  `taunt_summon_minion_yells_text` TEXT NULL,
  `taunt_combo_yells_text` TEXT NULL,
  `taunt_long_combat_yells_text` TEXT NULL,
  -- [ai] AI 决策节奏
  `ai_update_interval_ms` INT NOT NULL DEFAULT 1500,
  -- [phase] 战斗阶段与触发阈值
  `phase2_hp_threshold` INT NOT NULL DEFAULT 70,
  `phase3_hp_threshold` INT NOT NULL DEFAULT 20,
  `critical_hp_threshold` INT NOT NULL DEFAULT 10,
  `low_hp_taunt_threshold` INT NOT NULL DEFAULT 30,
  `low_hp_taunt_cooldown_ms` INT NOT NULL DEFAULT 20000,
  `long_combat_taunt_interval_ms` INT NOT NULL DEFAULT 60000,
  `target_reeval_loops` INT NOT NULL DEFAULT 3,
  `phase2_summon_count_min` INT NOT NULL DEFAULT 1,
  `phase2_summon_count_max` INT NOT NULL DEFAULT 2,
  `phase3_summon_count` INT NOT NULL DEFAULT 2,
  `phase2_spell_id` INT NOT NULL DEFAULT 1044,
  `phase3_spell_id` INT NOT NULL DEFAULT 8599,
  -- [patrol] 巡逻
  `patrol_enabled` TINYINT NOT NULL DEFAULT 1,
  `patrol_radius` INT NOT NULL DEFAULT 50,
  `patrol_leash_radius` INT NOT NULL DEFAULT 100,
  `patrol_interval_ms` INT NOT NULL DEFAULT 9000,
  -- [minion] 小怪 AI（数量列在主表 minion_count_min/max）
  `minion_ai_enabled` TINYINT NOT NULL DEFAULT 1,
  `minion_ai_interval_ms` INT NOT NULL DEFAULT 1800,
  `minion_target_range` INT NOT NULL DEFAULT 40,
  -- [helper] 援军模板 entry
  `helper_entries_text` VARCHAR(255) NOT NULL DEFAULT '',
  `ally_helper_entry` INT NOT NULL DEFAULT 20977,
  -- [class] 职业类型与职业奖励池
  `class_types_text` TEXT NULL,
  `class_reward_items_text` TEXT NULL,
  -- [tier] 受管模板 entry（面板切档后旧档位残留的 Boss 仍受管）
  `managed_tier_entries_text` VARCHAR(255) NOT NULL DEFAULT '',
  -- [skill_random] 技能池随机：每次生成/重生从池里随机抽一套预设（池为空 = 全部预设）
  `skill_preset_random_enabled` TINYINT NOT NULL DEFAULT 0,
  `skill_preset_pool_text` VARCHAR(255) NOT NULL DEFAULT '',
  `reward_pool_1_enabled` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_1_chance` INT NOT NULL DEFAULT 100,
  `reward_pool_1_winner_mode` VARCHAR(8) NOT NULL DEFAULT 'all',
  `reward_pool_1_winner_count` INT NOT NULL DEFAULT 1,
  `reward_pool_1_class_filter` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_1_items_text` TEXT NULL,
  `reward_pool_2_enabled` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_2_chance` INT NOT NULL DEFAULT 100,
  `reward_pool_2_winner_mode` VARCHAR(8) NOT NULL DEFAULT 'count',
  `reward_pool_2_winner_count` INT NOT NULL DEFAULT 3,
  `reward_pool_2_class_filter` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_2_items_text` TEXT NULL,
  `reward_pool_3_enabled` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_3_chance` INT NOT NULL DEFAULT 10,
  `reward_pool_3_winner_mode` VARCHAR(8) NOT NULL DEFAULT 'count',
  `reward_pool_3_winner_count` INT NOT NULL DEFAULT 3,
  `reward_pool_3_class_filter` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_3_items_text` TEXT NULL,
  `reward_pool_4_enabled` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_4_chance` INT NOT NULL DEFAULT 15,
  `reward_pool_4_winner_mode` VARCHAR(8) NOT NULL DEFAULT 'count',
  `reward_pool_4_winner_count` INT NOT NULL DEFAULT 1,
  `reward_pool_4_class_filter` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_4_items_text` TEXT NULL,
  `reward_pool_5_enabled` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_5_chance` INT NOT NULL DEFAULT 60,
  `reward_pool_5_winner_mode` VARCHAR(8) NOT NULL DEFAULT 'count',
  `reward_pool_5_winner_count` INT NOT NULL DEFAULT 3,
  `reward_pool_5_class_filter` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_5_items_text` TEXT NULL,
  `reward_pool_6_enabled` TINYINT NOT NULL DEFAULT 0,
  `reward_pool_6_chance` INT NOT NULL DEFAULT 0,
  `reward_pool_6_winner_mode` VARCHAR(8) NOT NULL DEFAULT 'count',
  `reward_pool_6_winner_count` INT NOT NULL DEFAULT 1,
  `reward_pool_6_class_filter` TINYINT NOT NULL DEFAULT 1,
  `reward_pool_6_items_text` TEXT NULL,
  -- [schedule] 定时启停：每天的时间段（这三列必须留在描述表末尾，面板按列序镜像）
  `activity_schedule_enabled` TINYINT NOT NULL DEFAULT 0,
  `activity_schedule_windows` VARCHAR(255) NOT NULL DEFAULT '',
  `activity_schedule_clear_on_close` TINYINT NOT NULL DEFAULT 1,
  `updated_at` INT NOT NULL DEFAULT 0,
  PRIMARY KEY (`state_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 默认值不在此处插入：boss.lua 首次加载时会用 INSERT IGNORE 把 §3 配置区的默认值
-- 写进 state_key='current' 这一行。需要人工预置时，先启动一次 worldserver 即可。
