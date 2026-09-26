-- ============================================================================
--  2026_09_26 — 连招扩充（每个预设 18 → 36 条）配套：给新增 18 条连招补上喊话
-- ----------------------------------------------------------------------------
--  背景：连招喊话存在 `boss_activity_config_ext`.`taunt_combo_yells_text`（扩展表列，
--        keyedlines 语义：每行 "连招名=喊话"）。**数据库里的值会整体替换脚本文件里的
--        `BOSS_CONFIG.combatTaunts.comboYells` 默认值**（boss.lua §3 描述表 keyedlines +
--        §7 的 setter 是整体赋值），所以只改 boss.lua 的默认文案，线上不会生效——
--        新增的 18 条连招在游戏里会「触发但不出声」。
--
--  本脚本做一件事（**幂等，可重复执行**）：
--    对 18 条新连招，逐条检查 `taunt_combo_yells_text` 里是否已有 "<连招名>=" 这个键；
--    没有就**追加到末尾**。已有的键（包括 GM 自己改过的文案、以及旧版 24 条连招喊话）
--    一律不动，所以重复执行不会重复追加，也不会覆盖人工调整。
--
--  用法（多区部署：库名与本区 key 会被 tools/deploy-realm.ps1 自动改写；手工执行时
--        请把下面的 `ac_eluna` 与 `'current'` 换成该区自己的库名与 state_key）：
--    "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 43306 -u root -p \
--        --default-character-set=utf8mb4 ac_eluna < 2026_09_26_combo_yells_expansion.sql
--  然后：游戏内 `.boss config reload`（不需要 .reload ale：这一步只改配置，不改脚本内容）
--
--  前置：扩展表里必须已有 state_key='current' 的行（boss.lua 加载时会 INSERT IGNORE 引导写入；
--        没有行时本脚本只会打印 [skip] 提示，不会擅自建行）。
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
    ELSEIF v_text NOT LIKE CONCAT('%', p_name, '=%') THEN
        UPDATE `ac_eluna`.`boss_activity_config_ext`
           SET `taunt_combo_yells_text` = CONCAT(v_text, IF(v_text = '', '', '\n'), p_name, '=', p_yell)
         WHERE `state_key` = 'current';
    END IF;
END$$

DELIMITER ;

-- --------------------------------------------------------------------------- 风暴攻城（storm_siege）
CALL `boss_add_combo_yell`('雷链锁阵', '雷链已经连上，谁先动谁先死！');
CALL `boss_add_combo_yell`('崩岩压顶', '山岩压顶，你们连站的地方都没有！');
CALL `boss_add_combo_yell`('风暴终判', '风暴收尾，你们的回合到此为止！');

-- --------------------------------------------------------------------------- 余烬风暴（ember_storm）
CALL `boss_add_combo_yell`('引燃起手', '先点火，剩下的慢慢算！');
CALL `boss_add_combo_yell`('熔渣回火', '踩过我的火，就得付代价！');
CALL `boss_add_combo_yell`('焚世终章', '整片场地都在烧，你们无处可退！');

-- --------------------------------------------------------------------------- 冰封压境（frost_whiteout）
CALL `boss_add_combo_yell`('寒径封路', '脚下已经结冰，跑起来给我看看！');
CALL `boss_add_combo_yell`('霜锁窒压', '风雪封住你们的视线，也封住退路！');
CALL `boss_add_combo_yell`('极寒终末', '最后一场雪，为你们而下！');

-- --------------------------------------------------------------------------- 毒猎追击（venom_pursuit）
CALL `boss_add_combo_yell`('毒牙起手', '毒已经进血了，慢慢体会！');
CALL `boss_add_combo_yell`('疫雾围猎', '毒雾围起来，谁也别想单独跑！');
CALL `boss_add_combo_yell`('绞毒收猎', '猎物跑累了，就该收网！');

-- --------------------------------------------------------------------------- 墓火轰炸（grave_bombard）
CALL `boss_add_combo_yell`('冥火点名', '被点到名字的，自己走进坟里！');
CALL `boss_add_combo_yell`('尸爆连环', '一个接一个，别急！');
CALL `boss_add_combo_yell`('墓穴终焉', '坟已经挖好，躺进去吧！');

-- --------------------------------------------------------------------------- 破法壁垒（spellbreak_bulwark）
CALL `boss_add_combo_yell`('碎甲起锋', '先碎你们的甲，再谈反抗！');
CALL `boss_add_combo_yell`('静默围杀', '念不出法术的感觉，好好享受！');
CALL `boss_add_combo_yell`('反咒终章', '你们的法术，一个都别想落地！');

DROP PROCEDURE IF EXISTS `boss_add_combo_yell`;

-- --------------------------------------------------------------------------- 核对：应为 24（旧）+ 18（本次）= 42 行
SELECT `state_key`,
       CHAR_LENGTH(`taunt_combo_yells_text`) - CHAR_LENGTH(REPLACE(`taunt_combo_yells_text`, '\n', '')) + 1 AS yell_lines
  FROM `ac_eluna`.`boss_activity_config_ext`
 WHERE `state_key` = 'current';
