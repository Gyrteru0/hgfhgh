-- v4.3.6-tempo: observable lead/deficit FSM + resource-cycling / XP-preserving comeback.
-- Derivation: auto-20261031-0123 post-AFK window (t6176..18958). The human equalized
-- level at 1:16, punished a 39.7s bot mana drought, converted one kill into +642 gold
-- +234 XP and 18s of free farm, then cycled mango/tango/faerie/salve/clarity to keep
-- dual-value razes online. This module ports the *decision policy*, not hidden info:
-- only visible enemy state, public scoreboard K/D, and own resources are used.

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local K = require("bots/nevermore/combat")
local S = require("bots/nevermore/souls")

local T = {}
T._state = {}
T.AHEAD, T.EVEN, T.BEHIND = "AHEAD", "EVEN", "BEHIND"

local CFG = C.TEMPO or {}
local ENTER = CFG.ENTER_SCORE or 4
local EXIT = CFG.EXIT_SCORE or 2
local DWELL = CFG.DWELL or 1.5

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function StateFor(bot)
    local pid = (bot.GetPlayerID and bot:GetPlayerID()) or -1
    local st = T._state[pid]
    if not st then
        st = { mode = T.EVEN, since = -1000, score = 0, pending = T.EVEN, pendingSince = -1000 }
        T._state[pid] = st
    end
    return st
end

-- Public/visible score. No enemy gold, networth, inventory-in-fog or XP reads.
function T.Score(bot, s)
    local enemy = s.enemy
    local myLevel = bot:GetLevel() or 1
    local enLevel = myLevel
    if enemy and U.CanQuery(enemy) then enLevel = enemy:GetLevel() or myLevel
    elseif s.enemyLastLevel then enLevel = s.enemyLastLevel end
    local levelDiff = myLevel - enLevel

    local soulDiff = 0
    if enemy and U.CanQuery(enemy) then soulDiff = S.GetSouls(bot) - S.GetSouls(enemy) end

    local killDiff = (s.myKills or 0) - (s.enemyKills or 0)
    local deathDiff = (s.enemyDeaths or 0) - (s.myDeaths or 0)

    local bootsDiff, bracerDiff = 0, 0
    if enemy and U.CanQuery(enemy) then
        bootsDiff = ((U.HasItem(bot, "item_boots") or U.HasItem(bot, "item_power_treads")) and 1 or 0)
            - ((U.HasItem(enemy, "item_boots") or U.HasItem(enemy, "item_power_treads")) and 1 or 0)
        bracerDiff = U.GetItemCount(bot, "item_bracer") - U.GetItemCount(enemy, "item_bracer")
    end

    local score = 3 * levelDiff + clamp(math.floor(soulDiff / 4), -3, 3)
        + 2 * killDiff + deathDiff + 2 * bootsDiff + bracerDiff
    return score, levelDiff, soulDiff
end

function T.Update(bot, s)
    local st = StateFor(bot)
    local now = s.now or GameTime()
    local score, levelDiff, soulDiff = T.Score(bot, s)
    st.score, st.levelDiff, st.soulDiff = score, levelDiff, soulDiff

    local want = T.EVEN
    if score >= ENTER then want = T.AHEAD
    elseif score <= -ENTER then want = T.BEHIND end
    -- Hysteresis: once AHEAD/BEHIND, require the score to cross EXIT toward even
    -- for DWELL seconds before leaving; opposite extreme switches after DWELL.
    if st.mode ~= T.EVEN and math.abs(score) <= EXIT then want = T.EVEN end
    if want ~= st.pending then
        st.pending, st.pendingSince = want, now
    end
    if want ~= st.mode and now - st.pendingSince >= DWELL then
        st.mode, st.since = want, now
        st.pending = want
    end

    local enemy = s.enemy
    st.myMana = K.MyManaBudget(bot, true)
    st.enemyMana = (enemy and U.CanQuery(enemy)) and K.EnemyManaBudget(enemy, true) or nil
    st.myHp = bot:GetHealth() or 0
    st.myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    st.dry = st.myMana < 75
    st.enemyDry = st.enemyMana ~= nil and st.enemyMana < 75
    st.levelDeficit = math.max(0, -levelDiff)
    st.soulDeficit = math.max(0, -soulDiff)

    -- Wave / aggro pressure from visible creeps only.
    local aggro, enemyNear, allyNear = 0, 0, 0
    local bLoc = bot:GetLocation()
    for _, c in pairs(s.enemyCreeps or {}) do
        if U.CanQuery(c) and c:IsAlive() then
            local d = GetUnitToLocationDistance(bot, c:GetLocation())
            if d <= 650 then enemyNear = enemyNear + 1 end
            if d <= 500 and ((c.GetAttackTarget and c:GetAttackTarget() == bot)
                or (bot.WasRecentlyDamagedByCreep and bot:WasRecentlyDamagedByCreep(0.85) and d <= 230)) then
                aggro = aggro + 1
            end
        end
    end
    for _, c in pairs(s.allyCreeps or {}) do
        if U.CanQuery(c) and c:IsAlive() and GetUnitToLocationDistance(bot, c:GetLocation()) <= 650 then
            allyNear = allyNear + 1
        end
    end
    st.aggroCount, st.enemyNear, st.allyNear = aggro, enemyNear, allyNear
    st.waveDelta = allyNear - enemyNear
    st.enemyDist = s.enemyDist or 99999
    return st
end

function T.Get(bot) return T._state[(bot.GetPlayerID and bot:GetPlayerID()) or -1] end

-- XP-preserving anchor: behind the wave toward own fountain, still inside 1200 XP
-- range of the nearest enemy creep, outside enemy tower and uphill-miss traps.
function T.XPAnchor(bot, s)
    local P = package.loaded["bots/nevermore/positioning"]
    local LN = package.loaded["bots/nevermore/lane"]
    local fountain = U.GetFountain(bot)
    local best, bestD = nil, math.huge
    for _, c in pairs(s.enemyCreeps or {}) do
        if U.CanQuery(c) and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, fountain)
            if d < bestD then bestD, best = d, c end
        end
    end
    if not best then
        for _, c in pairs(s.allyCreeps or {}) do
            if U.CanQuery(c) and c:IsAlive() then
                local d = GetUnitToLocationDistance(c, fountain)
                if d < bestD then bestD, best = d, c end
            end
        end
    end
    if not best then return P and P.GetT1Close(bot, 380) or nil end
    local cLoc = best:GetLocation()
    local dir = (fountain - cLoc):Normalized()
    local anchor = cLoc + dir * 620
    -- Keep a safe gap from a visible enemy who still has raze mana.
    if s.enemy and U.CanQuery(s.enemy) and (T.Get(bot) or {}).enemyMana and (T.Get(bot).enemyMana >= 75) then
        local eLoc = s.enemy:GetLocation()
        local safe = K.EnemyMinSafeDistance(s.enemy, 0.8) + 80
        if GetUnitToLocationDistance(s.enemy, anchor) < safe then
            anchor = eLoc + (anchor - eLoc):Normalized() * safe
        end
    end
    -- Never anchor under enemy T1 without a shield.
    if s.enemyT1Alive and s.enemyT1Loc and GetUnitToLocationDistance(bot, s.enemyT1Loc) < 1400 then
        local tLoc = s.enemyT1Loc
        if U.DistanceBetweenLocations(anchor, tLoc) < 900 then
            anchor = tLoc + (fountain - tLoc):Normalized() * 900
        end
    end
    if P and P.AvoidUphillMiss then anchor = P.AvoidUphillMiss(bot, anchor, cLoc) end
    if LN and LN.TowerDangerAtLoc and s.enemyT1Loc
        and LN.TowerDangerAtLoc(bot, s.enemyT1Loc, s.enemyT1, s.allyCreeps, anchor) >= 2 then
        return nil
    end
    return anchor
end

local function LethalNow(bot, s, race)
    if race and race.valid and (race.canKillNow or race.canKillSoon) then return true end
    local e = s.enemy
    if e and U.CanQuery(e) and e:IsAlive() then
        if U.CanOneShotEnemyHero(bot, e) or U.CanQuickTurnKillWithRaze(bot, e) then return true end
    end
    return false
end

-- AHEAD lead protection: do not stand dry in a losing wave while the enemy can punish.
function T.ShouldProtectLead(bot, s, race)
    local st = T.Get(bot); if not st or st.mode ~= T.AHEAD then return false end
    if LethalNow(bot, s, race) then return false end
    if not st.dry then return false end
    if st.enemyDist > 900 then return false end
    return (st.enemyMana and st.enemyMana >= 75) or st.aggroCount >= 2 or st.waveDelta <= -2
end

-- BEHIND catch-up: XP/lh first, no hero-only coinflip while dry or level-down.
function T.ShouldCatchupFarm(bot, s, race)
    local st = T.Get(bot); if not st or st.mode ~= T.BEHIND then return false end
    if LethalNow(bot, s, race) then return false end
    if st.enemyDry and st.myMana >= 75 then return false end -- punish his drought instead
    if st.enemyDist > 1000 then return false end
    return st.dry or st.levelDeficit > 0 or st.soulDeficit >= 6 or st.myHp < st.myMaxHp * 0.45
end

-- Even-game dry spacing: the replay death had bot HP > enemy HP but 35 mana and 3
-- enemy creeps beating him; v4.3.5 required an HP deficit and missed it.
function T.ShouldDryWaveSpace(bot, s, race)
    local st = T.Get(bot); if not st then return false end
    if LethalNow(bot, s, race) then return false end
    if not st.dry or st.enemyDist > 850 then return false end
    return st.aggroCount >= 2 or (st.waveDelta <= -2 and st.enemyMana and st.enemyMana >= 75)
end

function T.ShouldUseClarity(bot, s)
    if bot:HasModifier("modifier_clarity_potion") then return false end
    local missing = (bot:GetMaxMana() or 0) - (bot:GetMana() or 0)
    if missing < (CFG.CLARITY_MISSING or 120) then return false end
    if bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(3.0) then return false end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(3.0) then return false end
    if s.enemyAlive == false then return true end
    if not s.enemy or not U.CanQuery(s.enemy) then return (s.enemyAbsentFor or 0) >= 4.5 end
    return GetUnitToLocationDistance(bot, s.enemy:GetLocation()) >= (CFG.CLARITY_SAFE_DIST or 1100)
end

function T.ShouldBuyClarity(bot, enemy)
    local missing = (bot:GetMaxMana() or 0) - (bot:GetMana() or 0)
    if missing < (CFG.CLARITY_BUY_MISSING or 150) then return false end
    if K.MyManaBudget(bot, true) >= 150 then return false end
    if bot:HasModifier("modifier_clarity_potion") then return false end
    if enemy and U.CanQuery(enemy) then
        if GetUnitToLocationDistance(bot, enemy:GetLocation()) < 1000
            and K.EnemyManaBudget(enemy, true) >= 75 then return false end
    end
    return true
end

return T
