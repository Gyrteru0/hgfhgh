------------------------------------------------------------
-- bot_beastmaster.lua
-- Anti-AFK economy fix for the 1v1 mid SF lobby (`v4.0.0` `A19` Fix):
-- Previously Dire's `waitSpot` `(-994, 2700)` sat `1,495u` from `safeCamp` `(-994, 4195)` while
-- `GetNearbyNeutralCreeps(1400)` scanned only `1,400u` (`#creeps == 0` -> immediate walk back to
-- `waitSpot`, `0 XP` for `5:00`, triggering `+1,416g` `DOTA_ModifyGold_AbandonedRedistribute` in `0050`!).
-- Now every auxiliary bot walks into true `<= 420u` camp vision FIRST, confirms XP gain / creep death,
-- assists with `Wild Axes` if available, and parks cleanly outside aggro until the next 95s cycle.
------------------------------------------------------------

local safeCamp = {
    [TEAM_RADIANT] = Vector(244, -5567, 256),
    [TEAM_DIRE]    = Vector(-994, 4195, 256),
}

local fallbackCamp = {
    [TEAM_RADIANT] = Vector(-1750, -4250, 256),
    [TEAM_DIRE]    = Vector(1250, 3300, 256),
}

-- Wait spot: safely outside camp spawn box & aggro range (`~1,450u`)
local waitSpot = {
    [TEAM_RADIANT] = Vector(244, -4000, 256),
    [TEAM_DIRE]    = Vector(-994, 2700, 256),
}

local CYCLE        = 95    -- refresh well inside Valve's 300s (5-minute) XP inactivity window
local FARM_TIME    = 32    -- ample budget: ~4.5s walk in + ~4.5s kill + return
local CAMP_RADIUS  = 950   -- creeps belonging to the active camp
local VISION_RANGE = 400   -- MUST stand inside `<= 400u` of camp centre before declaring it empty!
local START_TIME   = 65    -- neutral camps first spawn at `DotaTime() == 60.0s`

-- Per-bot state (each bot runs its own script instance).
local S = {
    cycle        = -1,
    startCount   = nil,
    startXP      = 0,
    killed       = false,
    useFallback  = false,
    arrivedAt    = nil,
}

local function CurrentXP(bot)
    if bot.GetXP then
        local ok, v = pcall(bot.GetXP, bot)
        if ok and type(v) == "number" then return v end
    end
    return (bot:GetLevel() or 1) * 1000
end

-- Alive neutral creeps belonging to `camp` (strictly `<= 1600` C++ spatial cache limit).
local function CampCreeps(bot, camp)
    local list = bot:GetNearbyNeutralCreeps(1600) or {}
    local out = {}
    for _, c in pairs(list) do
        if c and c:IsAlive() and GetUnitToLocationDistance(c, camp) <= CAMP_RADIUS then
            table.insert(out, c)
        end
    end
    return out
end

-- All four bots hit the SAME creep so at least one dies quickly with minimal HP loss.
local function SharedTarget(bot, creeps, camp)
    if #creeps == 0 then return nil end

    local attacked = {}
    local allies = bot:GetNearbyHeroes(1600, false, BOT_MODE_NONE) or {}
    for _, h in pairs(allies) do
        if h and h ~= bot and h.GetAttackTarget then
            local ok, tgt = pcall(h.GetAttackTarget, h)
            if ok and tgt then attacked[tgt] = (attacked[tgt] or 0) + 1 end
        end
    end

    local best, bestScore = nil, math.huge
    for _, c in ipairs(creeps) do
        local hp = c:GetHealth() or 0
        local score = -(attacked[c] or 0) * 1000000
            + hp * 100
            + GetUnitToLocationDistance(c, camp)
        if score < bestScore then
            bestScore = score
            best = c
        end
    end
    return best
end

function Think()
    local bot = GetBot()
    if bot == nil or not bot:IsAlive() then return end
    local dtime = DotaTime()
    if dtime < START_TIME then
        local wait = waitSpot[GetTeam()]
        if wait and GetUnitToLocationDistance(bot, wait) > 160 then
            bot:Action_MoveToLocation(wait)
        end
        return
    end

    local team = GetTeam()
    local primary = safeCamp[team]
    local backup = fallbackCamp[team]
    local wait = waitSpot[team]
    if primary == nil or wait == nil then return end

    local elapsed = dtime - START_TIME
    local timeInCycle = elapsed % CYCLE
    local cycle = math.floor(elapsed / CYCLE)

    ------------------------------------------------
    -- WAIT PHASE: park outside spawn box & regen
    ------------------------------------------------
    if timeInCycle >= FARM_TIME then
        S.cycle = -1
        S.startCount = nil
        S.killed = false
        S.useFallback = false
        S.arrivedAt = nil
        if GetUnitToLocationDistance(bot, wait) > 120 then
            bot:Action_MoveToLocation(wait)
        end
        return
    end

    ------------------------------------------------
    -- FARM PHASE: ALWAYS acquire true camp vision FIRST (`A19` Fix!)
    ------------------------------------------------
    if S.cycle ~= cycle then
        S.cycle = cycle
        S.startCount = nil
        S.startXP = CurrentXP(bot)
        S.killed = false
        S.useFallback = false
        S.arrivedAt = nil
    end

    if CurrentXP(bot) > S.startXP then
        S.killed = true
    end

    if S.killed then
        if GetUnitToLocationDistance(bot, wait) > 120 then
            bot:Action_MoveToLocation(wait)
        end
        return
    end

    local camp = (S.useFallback and backup) and backup or primary
    local distToCamp = GetUnitToLocationDistance(bot, camp)
    local creeps = CampCreeps(bot, camp)

    -- If we already saw `S.startCount >= 1` creeps in this camp and `#creeps < S.startCount` (including `1 -> 0` when the
    -- last neutral creep dies!), our XP refresh is 100% complete — return straight to `wait`!
    if S.startCount ~= nil and #creeps < S.startCount then
        S.killed = true
        if GetUnitToLocationDistance(bot, wait) > 120 then
            bot:Action_MoveToLocation(wait)
        end
        return
    end

    -- Walk all the way inside camp vision BEFORE inspecting `#creeps == 0`!
    if #creeps == 0 and distToCamp > VISION_RANGE then
        S.arrivedAt = nil
        bot:Action_MoveToLocation(camp)
        return
    end

    if #creeps > 0 then
        if S.startCount == nil or #creeps > S.startCount then
            S.startCount = #creeps
        end

        local target = SharedTarget(bot, creeps, camp)
        if target then
            local axes = bot:GetAbilityByName("beastmaster_wild_axes")
            if axes and axes:IsFullyCastable() and (bot:GetMana() or 0) >= 80 then
                bot:Action_UseAbilityOnLocation(axes, target:GetLocation())
                return
            end
            if not (bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK and bot:GetAttackTarget() == target) then
                bot:Action_AttackUnit(target, true)
            end
            return
        end
    end

    -- Inside `<= 400u` of camp centre and `#creeps == 0`: hold briefly (`0.8s`) to rule out tree fog,
    -- then pivot to `fallbackCamp` once before returning to `waitSpot`!
    if S.arrivedAt == nil then
        S.arrivedAt = dtime
        bot:Action_AttackMove(camp)
        return
    end
    if dtime - S.arrivedAt < 0.8 then
        bot:Action_AttackMove(camp)
        return
    end
    if not S.useFallback and backup ~= nil then
        S.useFallback = true
        S.startCount = nil
        S.arrivedAt = nil
        bot:Action_MoveToLocation(backup)
        return
    end

    S.killed = true
    bot:Action_MoveToLocation(wait)
end

function AbilityLevelUpThink()
    local bot = GetBot()
    if bot == nil then return end
    if bot:GetAbilityPoints() < 1 then return end

    local axes = bot:GetAbilityByName("beastmaster_wild_axes")
    if axes ~= nil and axes:CanAbilityBeUpgraded() then
        bot:ActionImmediate_LevelAbility("beastmaster_wild_axes")
        return
    end

    local inner = bot:GetAbilityByName("beastmaster_inner_beast")
    if inner ~= nil and inner:CanAbilityBeUpgraded() then
        bot:ActionImmediate_LevelAbility("beastmaster_inner_beast")
    end
end
