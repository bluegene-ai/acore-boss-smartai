-- ============================================================================
--  2026_09_26 — 新增 4 个技能预设（奥术崩解 / 瘟疫蜂群 / 钢铁先锋 / 鲜血誓约）配套：
--                给这 4 套预设的 24 条连招补上喊话
-- ----------------------------------------------------------------------------
--  喊话存在 `boss_activity_config_ext`.`taunt_combo_yells_text`（keyedlines：每行 "连招名=喊话"），
--  而**库里的值会整体覆盖脚本文件里的 comboYells 默认值** —— 所以只更新 boss.lua 而不跑本脚本，
--  线上一旦抽到这 4 套预设，连招会触发但**不出声**（无报错，只是静默）。
--
--  幂等：逐条检查 "<连招名>=" 是否已存在，不存在才**追加到末尾**；
--        已有的键（含 GM 改过的文案与旧版 42 条）一律不动，可重复执行。
--        键名按**行首**锚定（`\n键名=` 或文首），避免子串误判（例如 `烈焰余烬=` 含 `余烬=`）。
--
--  用法（多区：库名与 state_key 由 tools/deploy-realm.ps1 改写；手工执行请自行替换）：
--    "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 43306 -u root -p \
--        --default-character-set=utf8mb4 ac_eluna < 2026_09_26_combo_yells_new_presets.sql
--  然后：`.boss config reload`（只改配置，不必重载脚本；若同时也更新了 boss.lua，请用 `.reload ale`）
-- ============================================================================

DROP PROCEDURE IF EXISTS `boss_add_combo_yell`;

DELIMITER $$

CREATE PROCEDURE `boss_add_combo_yell`(IN p_name VARCHAR(64), IN p_yell VARCHAR(255))
BEGIN
    DECLARE v_text TEXT;

    SELECT `taunt_combo_yells_text` INTO v_text
      FROM `ac_eluna`.`boss_activity_config_ext`
     WHERE `state_key` = 'current'
     LIMIT 1;

    IF v_text IS NULL THEN
        SELECT CONCAT('[skip] 扩展表没有 state_key=current 的行，未写入: ', p_name) AS note;
    ELSEIF v_text NOT LIKE CONCAT('%', '\n', p_name, '=%')
       AND v_text NOT LIKE CONCAT(p_name, '=%') THEN
        UPDATE `ac_eluna`.`boss_activity_config_ext`
           SET `taunt_combo_yells_text` = CONCAT(v_text, IF(v_text = '', '', '\n'), p_name, '=', p_yell)
         WHERE `state_key` = 'current';
    END IF;
END$$

DELIMITER ;

CALL `boss_add_combo_yell`('奥能爆流', '奥能灌满这片场地，撑住给我看！');
CALL `boss_add_combo_yell`('法术反噬', '你们的法术，我原样还回去！');
CALL `boss_add_combo_yell`('秘法灼印', '秘法印记已经落下，别想安然读完条！');
CALL `boss_add_combo_yell`('魔力倾泻', '魔力倾泻而下，站哪儿都一样！');
CALL `boss_add_combo_yell`('崩解回响', '崩解会在你们体内回响！');
CALL `boss_add_combo_yell`('奥术终焉', '奥术收束成型，你们的结局已定！');
CALL `boss_add_combo_yell`('疫病起巢', '疫病已经种下，慢慢发芽吧！');
CALL `boss_add_combo_yell`('虫群蔽日', '抬头看看，天上全是我的虫群！');
CALL `boss_add_combo_yell`('瘟疫蔓延', '瘟疫不挑人，一个都跑不掉！');
CALL `boss_add_combo_yell`('腐液围城', '腐液围起来，看你们往哪退！');
CALL `boss_add_combo_yell`('蛆群噬骨', '骨头也要啃干净！');
CALL `boss_add_combo_yell`('万疫终章', '万疫齐发，这里就是你们的坟场！');
CALL `boss_add_combo_yell`('火箭齐射', '火箭已上膛，抬头！');
CALL `boss_add_combo_yell`('地雷封锁', '脚下埋好了东西，走路小心点！');
CALL `boss_add_combo_yell`('钢甲碾压', '钢甲碾过去，没什么能挡！');
CALL `boss_add_combo_yell`('弹幕覆盖', '弹幕覆盖，谁露头打谁！');
CALL `boss_add_combo_yell`('过热超载', '锅炉过热了，全都烧起来！');
CALL `boss_add_combo_yell`('钢铁终响', '钢铁的终响，就是你们的丧钟！');
CALL `boss_add_combo_yell`('放血开场', '先放点血，热身一下！');
CALL `boss_add_combo_yell`('裂甲之约', '你们的甲，我一片片撕下来！');
CALL `boss_add_combo_yell`('血债累积', '血债一笔笔记着，迟早要还！');
CALL `boss_add_combo_yell`('生命汲取', '你们的生命，现在归我！');
CALL `boss_add_combo_yell`('血怒反噬', '越疼，我越强！');
CALL `boss_add_combo_yell`('血誓终局', '血誓已成，谁也别想活着离场！');

DROP PROCEDURE IF EXISTS `boss_add_combo_yell`;

-- --------------------------------------------------------------------------- 核对：应为 42（旧）+ 24（本次）= 66 行
SELECT `state_key`,
       CHAR_LENGTH(`taunt_combo_yells_text`) - CHAR_LENGTH(REPLACE(`taunt_combo_yells_text`, '\n', '')) + 1 AS yell_lines
  FROM `ac_eluna`.`boss_activity_config_ext`
 WHERE `state_key` = 'current';
