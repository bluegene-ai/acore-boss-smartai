-- ============================================================================
--  2026_09_26 — 历史遗留技能名修正：把技能施放喊话的键改成 Spell.dbc 的 enCN 名称
-- ----------------------------------------------------------------------------
--  背景：boss.lua 的技能池条目的 `name` 早期是按中文习惯意译的，与客户端 Spell.dbc 的
--        官方中文名不一致（例：69055 官方是「军刀猛刺」而脚本写作「骨刃分劈」）。
--        本次把这 22 个法术的 name 全部改成 DBC 官方名，并同步：
--          · boss.lua 的 skillPools / openingSkills / skillCastYells
--          · 本脚本：`boss_activity_config_ext`.`taunt_skill_cast_yells_text`
--        必须一起改：技能施放喊话是 **以技能名为键** 查表的（boss.lua: `skillCastYells[skill.name]`），
--        而库里的值会**整体覆盖**脚本默认值 —— 只改脚本、不改库，线上这 22 个技能就会静默不喊话。
--
--  幂等：对每对 (旧名, 新名) 只在「旧名= 存在且 新名= 不存在」时才替换，可重复执行。
--        替换串带 `=`，所以像「白茫=」不会误伤「白茫封场=」这种同前缀的连招键。
--
--  用法（多区：库名与本区 key 由 tools/deploy-realm.ps1 自动改写；手工执行请自行替换）：
--    "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 43306 -u root -p \
--        --default-character-set=utf8mb4 ac_eluna < 2026_09_26_skill_yells_rename.sql
--  然后：`.reload ale`（脚本里的 name 变了，必须重载脚本，而不是 .boss config reload）
-- ============================================================================

DROP PROCEDURE IF EXISTS `boss_rename_skill_yell`;

DELIMITER $$

CREATE PROCEDURE `boss_rename_skill_yell`(IN p_old VARCHAR(64), IN p_new VARCHAR(64))
BEGIN
    DECLARE v_text TEXT;

    SELECT `taunt_skill_cast_yells_text` INTO v_text
      FROM `ac_eluna`.`boss_activity_config_ext`
     WHERE `state_key` = 'current'
     LIMIT 1;

    -- 键必须按「行首」锚定：只判 `旧名=` 会被子串骗到 —— 例如 `烈焰余烬=` 里就含有 `余烬=`，
    -- 于是「新名已存在」的守卫会误判成已完成而跳过（实测踩过这个坑）。
    IF v_text IS NULL THEN
        SELECT CONCAT('[skip] 扩展表没有 state_key=current 的行，未处理: ', p_old) AS note;
    ELSEIF (
            v_text LIKE CONCAT(p_old, '=%')
         OR v_text LIKE CONCAT('%', '\n', p_old, '=%')
        ) AND NOT (
            v_text LIKE CONCAT(p_new, '=%')
         OR v_text LIKE CONCAT('%', '\n', p_new, '=%')
        ) THEN
        -- 除首行外：按「换行 + 键名 + =」整段替换
        UPDATE `ac_eluna`.`boss_activity_config_ext`
           SET `taunt_skill_cast_yells_text` = REPLACE(`taunt_skill_cast_yells_text`,
                   CONCAT('\n', p_old, '='), CONCAT('\n', p_new, '='))
         WHERE `state_key` = 'current';

        -- 首行（没有前导换行）：只改行首那一段，不动值
        UPDATE `ac_eluna`.`boss_activity_config_ext`
           SET `taunt_skill_cast_yells_text` = CONCAT(p_new, SUBSTRING(`taunt_skill_cast_yells_text`, CHAR_LENGTH(p_old) + 1))
         WHERE `state_key` = 'current'
           AND LEFT(`taunt_skill_cast_yells_text`, CHAR_LENGTH(p_old) + 1) = CONCAT(p_old, '=');

        SELECT CONCAT('[ok] ', p_old, ' -> ', p_new) AS note;
    ELSE
        SELECT CONCAT('[skip] 无需处理: ', p_old, ' -> ', p_new) AS note;
    END IF;
END$$

DELIMITER ;

CALL `boss_rename_skill_yell`('冰焰',       '冷焰');
CALL `boss_rename_skill_yell`('冰冻之地',   '大地冰封');
CALL `boss_rename_skill_yell`('冰霜箭雨',   '寒冰箭雨');
CALL `boss_rename_skill_yell`('哨兵震爆',   '警戒冲击');
CALL `boss_rename_skill_yell`('白茫',       '霜至');
CALL `boss_rename_skill_yell`('剧毒新星',   '毒性新星');
CALL `boss_rename_skill_yell`('骨刃分劈',   '军刀猛刺');
CALL `boss_rename_skill_yell`('陨星拳',     '流星拳');
CALL `boss_rename_skill_yell`('烈焰余烬',   '余烬');
CALL `boss_rename_skill_yell`('无意义之触', '蔑视之触');
CALL `boss_rename_skill_yell`('剧毒废料',   '剧毒废渣');
CALL `boss_rename_skill_yell`('恐惧尖啸',   '惊骇尖啸');
CALL `boss_rename_skill_yell`('灼烧吐息',   '灼热吐息');
CALL `boss_rename_skill_yell`('无面者印记', '无面者的印记');
CALL `boss_rename_skill_yell`('骇人咆哮',   '恐惧咆哮');
CALL `boss_rename_skill_yell`('软泥抛掷',   '可延展黏液');
CALL `boss_rename_skill_yell`('穿刺顺劈',   '刺骨挥砍');
CALL `boss_rename_skill_yell`('黑暗奔涌',   '黑暗涌动');
CALL `boss_rename_skill_yell`('灼烧烈焰',   '灼热烈焰');
CALL `boss_rename_skill_yell`('暗影冲击',   '暗影撞击');
CALL `boss_rename_skill_yell`('毒液箭',     '毒箭');
CALL `boss_rename_skill_yell`('音波尖啸',   '音速尖啸');

DROP PROCEDURE IF EXISTS `boss_rename_skill_yell`;

-- --------------------------------------------------------------------------- 核对：应仍为 41 行（只改键名，不增删）
SELECT `state_key`,
       CHAR_LENGTH(`taunt_skill_cast_yells_text`) - CHAR_LENGTH(REPLACE(`taunt_skill_cast_yells_text`, '\n', '')) + 1 AS yell_lines
  FROM `ac_eluna`.`boss_activity_config_ext`
 WHERE `state_key` = 'current';
