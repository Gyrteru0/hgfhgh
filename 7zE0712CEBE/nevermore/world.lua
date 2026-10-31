--
-- The per-tick world snapshot: collect the unit lists, the enemy, the towers and the enemy's presence
-- (alive / when last seen) once. The W.s table is reused (no per-tick allocations).

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local W = {}

-- Buffers for the filtered unit lists (reused every tick — zero per-tick GC allocations)
local ENEMY_CREEPS_BUF, ALLY_CREEPS_BUF, ENEMY_TOWERS_BUF, ALLY_TOWERS_BUF = {}, {}, {}, {}
local function FilterQueryable(list, buf)
    for i = #buf, 1, -1 do buf[i] = nil end
    if not list then return buf end
    local n = 0
    for _, u in pairs(list) do
        if U.CanQuery(u) then
            n = n + 1
            buf[n] = u
        end
    end
    return buf
end

W.s = {
    now = 0,
    bot = nil,
    enemy = nil, -- The visible enemy hero (queryable) or nil
    enemyAny = nil, -- The enemy handle even if not visible (may not be queryable)
    enemyVisible = false,
    enemyAlive = true,
    enemyLastSeen = -1, -- The GameTime when he was last seen
    enemyLastLoc = nil,
    enemyAbsentFor = 0, -- seconds unseen (0 if visible)
    enemyDist = 99999,
    enemyCreeps = nil,
    allyCreeps = nil,
    enemyTowers = nil,
    allyTowers = nil,
    enemyT1 = nil, -- The enemy T1 handle (if alive and accessible)
    enemyT1Alive = true,
    allyT1 = nil,
    myKills = 0,
    myDeaths = 0,
    enemyKills = 0,
    enemyDeaths = 0,
}

local EMPTY = {}

local function FindT1(towers)
    for _, t in pairs(towers or EMPTY) do
        if t and t:IsAlive() then
            local name = t:GetUnitName() or ""
            if name:find("tower1") then return t end
        end
    end
    return nil
end

local function SafeGetTower(team, idx)
    if type(GetTower) ~= "function" then return nil end
    local ok, t = pcall(GetTower, team, idx)
    if ok then return t end
    return nil
end

-- This API exposes only visible teleport effects, not hidden cast destinations.
function W.ReadIncomingTeleports(bot, s)
    s.incomingEnemyTPs = {}
    if type(GetIncomingTeleports) ~= "function" then return end
    local ok, list = pcall(GetIncomingTeleports)
    if not ok or type(list) ~= "table" then return end
    local myPid = (bot and bot.GetPlayerID and bot:GetPlayerID()) or -999
    local allyIds = {}
    if myPid >= 0 then allyIds[myPid] = true end
    local enemyIds = {}
    if type(s.enemyPlayerId) == "number" and s.enemyPlayerId >= 0 then
        enemyIds[s.enemyPlayerId] = true
    end
    local known = s.enemyAny or s.enemy
    if known and known.GetPlayerID then
        local okId, pid = pcall(known.GetPlayerID, known)
        if okId and type(pid) == "number" and pid >= 0 then
            enemyIds[pid] = true
            s.enemyPlayerId = pid
        end
    end
    if type(GetTeamPlayers) == "function" then
        local allyTeam = bot:GetTeam()
        for _, id in pairs(GetTeamPlayers(allyTeam) or {}) do allyIds[id] = true end
        local enemyTeam = allyTeam == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT
        for _, id in pairs(GetTeamPlayers(enemyTeam) or {}) do enemyIds[id] = true end
    end
    for _, tp in pairs(list) do
        local pid = tp and tp.playerid
        local isEnemyTP = (pid ~= nil) and (enemyIds[pid] or (type(pid) == "number" and not allyIds[pid]))
        if isEnemyTP and tp.location and type(tp.location.x) == "number" and type(tp.location.y) == "number"
            and type(tp.time_remaining) == "number" and tp.time_remaining >= 0 and tp.time_remaining <= 15 then
            s.incomingEnemyTPs[#s.incomingEnemyTPs + 1] = tp
        end
    end
end

function W.Update(bot)
    local s = W.s
    local now = GameTime()
    if s.bot ~= bot or (s.now and s.now > 0 and now < s.now - 1.0) then
        s.enemyLastSeen = -1
        s.enemyLastLoc = nil
        s.enemyAbsentFor = 0
        s.enemyAlive = true
        s.enemyT1Alive = true
        s.enemyT1Loc = nil
        s.enemyT1LastHp = nil
    end
    s.now = now
    s.bot = bot

    -- The enemy: first from the global list (visibility/presence), then the nearby list.
    local enemy = nil
    local enemyAny = nil
    if type(GetUnitList) == "function" and UNIT_LIST_ENEMY_HEROES then
        local list = GetUnitList(UNIT_LIST_ENEMY_HEROES)
        for _, h in pairs(list or EMPTY) do
            if h then
                enemyAny = enemyAny or h
                if U.CanQuery(h) then
                    enemy = h
                    break
                end
            end
        end
    end
    if not enemy then
        local near = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
        for _, h in pairs(near or EMPTY) do
            if U.CanQuery(h) then
                enemy = h
                break
            end
        end
    end
    s.enemy = enemy
    s.enemyAny = enemyAny or enemy
    s.enemyVisible = enemy ~= nil
    if enemy then
        s.enemyLastSeen = now
        s.enemyLastLoc = enemy:GetLocation()
        s.enemyAbsentFor = 0
        s.enemyDist = GetUnitToLocationDistance(bot, s.enemyLastLoc)
        s.enemyAlive = enemy:IsAlive()
        if enemy.GetPlayerID then
            local okId, pid = pcall(enemy.GetPlayerID, enemy)
            if okId and type(pid) == "number" and pid >= 0 then s.enemyPlayerId = pid end
        end
        if enemy.GetLevel then
            local okLv, lv = pcall(enemy.GetLevel, enemy)
            if okLv and type(lv) == "number" and lv > 0 then s.enemyLastLevel = lv end
        end
        if enemy.GetMaxHealth then
            local okMh, mh = pcall(enemy.GetMaxHealth, enemy)
            if okMh and type(mh) == "number" and mh > 0 then s.enemyLastMaxHealth = mh end
        end
        if enemy.GetAttackDamage then
            local okAd, ad = pcall(enemy.GetAttackDamage, enemy)
            if okAd and type(ad) == "number" and ad > 0 then s.enemyLastAttackDmg = ad end
        end
    else
        if s.enemyLastSeen >= 0 then
            s.enemyAbsentFor = now - s.enemyLastSeen
        else
            s.enemyAbsentFor = (type(DotaTime) == "function" and math.max(0, DotaTime())) or now
        end
        s.enemyDist = 99999
        -- Is the invisible enemy alive: MUST query `GetTeamPlayers(enemyTeam)` + `IsHeroAlive(pid)` directly!
        -- CRITICAL FIX (`HUD 09:01` `auto-20261021-1810`): When the enemy hero dies in Source 2 C++,
        -- `GetUnitList(UNIT_LIST_ENEMY_HEROES)` returns `{}` so `s.enemyAny` is `nil`! Checking only `s.enemyAny`
        -- falsely left `s.enemyAlive == true` for all 28 seconds of the enemy's death timer!
        local alive = true
        if type(IsHeroAlive) == "function" then
            local checked = false
            local h = s.enemyAny
            if h and h.GetPlayerID then
                local ok, pid = pcall(h.GetPlayerID, h)
                if ok and pid and pid >= 0 then
                    local ok2, res = pcall(IsHeroAlive, pid)
                    if ok2 and res ~= nil then alive = res; checked = true end
                end
            end
            if not checked and type(GetTeamPlayers) == "function" then
                local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
                for _, pid in pairs(GetTeamPlayers(enemyTeam) or {}) do
                    local ok2, res = pcall(IsHeroAlive, pid)
                    if ok2 and res == false then alive = false; break end
                end
            end
        end
        s.enemyAlive = alive
    end

    -- Score
    if s.enemyAny and s.enemyAny.GetPlayerID and type(GetHeroKills) == "function" then
        local ok, pid = pcall(s.enemyAny.GetPlayerID, s.enemyAny)
        if ok and pid and pid >= 0 then
            local ok1, k = pcall(GetHeroKills, pid)
            local ok2, d = pcall(GetHeroDeaths, pid)
            if ok1 and k then s.enemyKills = k end
            if ok2 and d then s.enemyDeaths = d end
        end
    end
    if type(GetHeroKills) == "function" then
        local pid = bot:GetPlayerID()
        local ok1, k = pcall(GetHeroKills, pid)
        local ok2, d = pcall(GetHeroDeaths, pid)
        if ok1 and k then s.myKills = k end
        if ok2 and d then s.myDeaths = d end
    end

    -- Units
    -- GetNearbyLaneCreeps(..., true) may return enemy creeps in fog (the handle exists but
    -- cannot be queried): every GetHealth/GetLocation on such a creep logs "[Developer] ... cannot be
    -- seen" to the console and a last hit/push on it is an order into thin air. We filter via CanQuery into two
    -- reused tables (no per-tick allocations).
    s.enemyCreeps = FilterQueryable(bot:GetNearbyLaneCreeps(1600, true), ENEMY_CREEPS_BUF)
    s.allyCreeps = FilterQueryable(bot:GetNearbyLaneCreeps(1600, false), ALLY_CREEPS_BUF)
    -- CRITICAL C++ Engine Fix (`9056774541.dem` `tk=6340`): `bot:GetNearbyTowers(1600, true)` and `GetTower(...)`
    -- return handles to alive enemy towers standing on highground Fog of War (`CanBeSeen() == false`), where calling
    -- `:GetHealth()` / `:GetMaxHealth()` / `:GetAttackTarget()` spams C++ `[Developer] ... cannot be seen!` AND returns `-1`!
    -- Therefore:
    --   1. `s.enemyTowers` and `s.enemyT1` ONLY ever hold strictly `U.CanQuery(t)` (`CanBeSeen() == true`) towers!
    --   2. `s.enemyT1Alive` and `s.enemyT1Loc` preserve exact tower liveness & static mid T1 coordinates EVEN IN FULL FoW,
    --      so `HandleEnemyTowerSafety` evacuates immediately at `0.000s` when the last allied creep dies under highground T1!
    s.enemyTowers = FilterQueryable(bot:GetNearbyTowers(1600, true), ENEMY_TOWERS_BUF)
    s.allyTowers = FilterQueryable(bot:GetNearbyTowers(1600, false), ALLY_TOWERS_BUF)

    local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
    local staticEnemyT1Loc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    local rawT1 = nil
    if TOWER_MID_1 ~= nil then
        rawT1 = SafeGetTower(enemyTeam, TOWER_MID_1)
    end
    local visibleT1 = nil
    if rawT1 then
        local okAlive, alive = pcall(rawT1.IsAlive, rawT1)
        if okAlive and alive == false then
            s.enemyT1Alive = false
            s.enemyT1Loc = nil
        else
            s.enemyT1Alive = true
            if U.CanQuery(rawT1) then
                visibleT1 = rawT1
                local okLoc, loc = pcall(rawT1.GetLocation, rawT1)
                if okLoc and loc then s.enemyT1Loc = loc end
                local okHp, hp = pcall(rawT1.GetHealth, rawT1)
                if okHp and type(hp) == "number" and hp > 0 then s.enemyT1LastHp = hp end
            else
                -- Tower is alive in highground Fog of War (`CanBeSeen() == false`): keep exact cached/static coordinates!
                s.enemyT1Loc = s.enemyT1Loc or staticEnemyT1Loc
            end
        end
    else
        local nearT1 = FindT1(s.enemyTowers)
        if nearT1 and U.CanQuery(nearT1) then
            visibleT1 = nearT1
            s.enemyT1Alive = true
            s.enemyT1Loc = nearT1:GetLocation()
            local okHp, hp = pcall(nearT1.GetHealth, nearT1)
            if okHp and type(hp) == "number" and hp > 0 then s.enemyT1LastHp = hp end
        elseif TOWER_MID_1 ~= nil then
            -- `GetTower(enemyTeam, TOWER_MID_1)` returned `nil` -> enemy Mid T1 has been destroyed!
            s.enemyT1Alive = false
            s.enemyT1Loc = nil
        elseif s.enemyT1Alive ~= false then
            s.enemyT1Loc = s.enemyT1Loc or staticEnemyT1Loc
        end
    end
    s.enemyT1 = visibleT1
    s.allyT1 = FindT1(s.allyTowers)
    W.ReadIncomingTeleports(bot, s)
    if U.ObserveWorldTick then
        U.ObserveWorldTick(bot, s)
    end

    return s
end

-- The enemy is "absent": dead or unseen for longer than absentSec.
function W.EnemyAbsent(absentSec)
    local s = W.s
    if not s.enemyAlive then return true end
    if s.enemyVisible then return false end
    return s.enemyAbsentFor >= (absentSec or 5.0)
end

-- Hook for utils (utils cannot require world because of the cycle)
U._W = W

return W
