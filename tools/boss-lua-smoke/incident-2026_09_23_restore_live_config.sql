-- ============================================================================
--  事故恢复：把 ac_eluna.boss_activity_config / runtime 复原到 2026-09-23 10:53 之前的值
--
--  原因：离线冒烟测试的 SQL 导出被放到「真实库 + START TRANSACTION/ROLLBACK」里校验，
--        但导出文件开头是 CREATE DATABASE/CREATE TABLE（DDL 会隐式提交），
--        导致事务被提前提交，脚本产生的 REPLACE INTO 真的写进了线上配置行。
--        被覆盖的字段：skill_preset/skill_difficulty、spawn_points_text、gold_min/max_copper、
--        reward_mounts_text、ally_health_multiplier_scaled；另产生 5 条假事件。
--
--  本文件按事发前的真实快照逐列复原（含 entry=190090 的新模板切换），并删除假事件。
--  一次性脚本，执行后可删除。
-- ============================================================================

UPDATE `ac_eluna`.`boss_activity_config` SET
    `boss_entry`                   = 190090,
    `boss_name`                    = '送财童子',
    `boss_level`                   = 83,
    `boss_scale_scaled`            = 999,
    `boss_health_multiplier_scaled`= 150000,
    `boss_auras_text`              = '467',
    `ally_level`                   = 50,
    `ally_health_multiplier_scaled`= 150,
    `respawn_time_minutes`         = 10,
    `minion_count_min`             = 1,
    `minion_count_max`             = 2,
    `skill_preset`                 = 'spellbreak_bulwark',
    `skill_difficulty`             = 'hard',
    `guaranteed_reward_enabled`    = 1,
    `guaranteed_reward_notify`     = 1,
    `max_random_reward_players`    = 3,
    `class_reward_chance`          = 60,
    `formula_reward_chance`        = 10,
    `mount_reward_chance`          = 15,
    `random_reward_mode`           = 'weighted',
    `participation_range`          = 80,
    `damage_weight`                = 100,
    `healing_weight`               = 80,
    `threat_weight`                = 35,
    `presence_weight`              = 10,
    `kill_weight`                  = 3,
    `guaranteed_item_id`           = 40753,
    `guaranteed_item_count`        = 2,
    `gold_min_copper`              = 300000,
    `gold_max_copper`              = 500000,
    `reward_items_text`            = '38082,41600,51809,34067',
    `reward_formulas_text`         = '45059,44491',
    `reward_mounts_text`           = '32768,30480,13335,37719,49282,49290,19872,33977,33809,37828,43963,54068,33183,33189,35513,43964,19902,46109,50250,49286,30609,54860,37012',
    `spawn_points_text`            = '571,4108.1600,5316.8500,28.7593
571,2498.7046,5456.1700,30.2720
571,497.6390,-5948.4900,314.3950
571,2490.7300,-3397.3700,159.2470
571,3423.7700,-1844.4600,106.4220
571,3437.4482,-4624.3790,231.5270
571,6423.9100,-2310.5020,292.8711
571,5690.4170,-3342.3003,372.6648
571,4918.7983,5189.6710,92.8270
571,5807.1600,4588.0270,-137.2932
571,8281.1500,-1284.8900,982.1502
571,7880.0650,-3256.0356,850.8980
571,4186.9900,460.3520,57.3126
571,3581.9573,-1334.0110,109.1245',
    `updated_at`                   = 1777649201
WHERE `state_key` = 'current';

UPDATE `ac_eluna`.`boss_activity_runtime` SET
    `boss_guid`       = 0,
    `boss_entry`      = 0,
    `boss_name`       = '',
    `map_id`          = 0,
    `instance_id`     = 0,
    `home_x`          = 0,
    `home_y`          = 0,
    `home_z`          = 0,
    `phase`           = 0,
    `status`          = 'idle',
    `skill_preset`    = 'spellbreak_bulwark',
    `skill_difficulty`= 'hard',
    `respawn_at`      = 0,
    `last_spawn_at`   = 0,
    `last_engage_at`  = 0,
    `last_death_at`   = 0,
    `last_reset_at`   = 0,
    `updated_at`      = 1782617254
WHERE `state_key` = 'current';

-- 删除冒烟测试产生的 5 条假事件（id 139-143）
DELETE FROM `ac_eluna`.`boss_activity_events` WHERE `id` BETWEEN 139 AND 143;

-- 复原结果回读
SELECT `state_key`, `boss_entry`, `boss_name`, `skill_preset`, `skill_difficulty`,
       `spawn_points_text`, `gold_min_copper`, `gold_max_copper`, `ally_health_multiplier_scaled`,
       `reward_mounts_text`, `updated_at`
FROM `ac_eluna`.`boss_activity_config`\G

SELECT COUNT(*) AS events_count, MAX(`id`) AS max_event_id, MAX(`created_at`) AS last_event_at
FROM `ac_eluna`.`boss_activity_events`;
