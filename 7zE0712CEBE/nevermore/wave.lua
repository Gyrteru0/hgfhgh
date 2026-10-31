--
-- Wave management (report chapter 18), v2.
--
-- Pure wave-state computation plus a set of independent levers.  Every lever is switched on by a
-- flag, so each policy is measured in isolation on the same case set and the same engine:
--
--   WV.PUSH_POLICY  "always"    - the studied bot's own pushing (no gate at all)
--                   "free"      - push only when the wave can actually crash (creep parity + enemy
--                                 really gone) - a push started from a 1v4 wave only feeds denies
--                   "advantage" - push only with >= 2 creeps of advantage (or a nearly dead T1)
--                   "siege"     - push only into the siege window (waves 10/20/...), otherwise farm
--                   "never"     - never push (control arm: the price of pure farming)
--   WV.CLOSE        stand closer to my own wave when nothing can punish it (default 450 behind it
--                   means the back creeps die 600-700 away = outside the last-hit walk window)
--   WV.CLOSE_DIST   how far behind the wave to stand (190 = "close", 60 = "in the wave")
--   WV.TOWER_FARM   force FARM while the enemy wave is at my T1 (the tower kills those creeps;
--                   zoning through that window is what the autopsy counts as "tower stole it")
--   WV.DENY_SCORE   replacement for the deny score bonus in lasthit.lua (nil = the bot's own value)
--   WV.SHOVE        "off" | "free" | "aggressive" - raze the creep wave to crash it fast
--                   ("free" = only when the enemy cannot punish, "aggressive" = also to break his
--                   freeze when he is >700 away).  The studied bot never razes creeps at all.
--
-- Counter instrumentation: WV.stats is read by tools/run_cases.lua at the end of every game, so a
-- policy that silently never fires is visible in the results table instead of looking like noise.
--
local C = require("bots/nevermore/constants")

local WV = {}

WV.PUSH_POLICY = "free"
WV.CLOSE = true
WV.CLOSE_DIST = 175
WV.TOWER_FARM = true
WV.DENY_SCORE = nil
WV.SHOVE = "free"
WV.PULL = "free"
WV.SHOVE_CD = 8
WV.SHOVE_WORTH = true
WV.SHOVE_MANA = 155

WV.stats = { blocked = 0, shoves = 0, close = 0, towerfarm = 0, pulls = 0, leaks = 0 }

local EMPTY = {}

-- ------------------------------------------------------------------ geometry
local function axis(bot)
    local a, b
    if bot:GetTeam() == TEAM_RADIANT then
        a, b = C.POSITIONS.RADIANT_T1, C.POSITIONS.DIRE_T1
    else
        a, b = C.POSITIONS.DIRE_T1, C.POSITIONS.RADIANT_T1
    end
    local dx, dy = b.x - a.x, b.y - a.y
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 1 then l = 1 end
    return a, dx / l, dy / l, l
end

-- position along the lane: 0 = my T1, 1 = the enemy T1
local function lanePos(a, ux, uy, len, loc)
    return ((loc.x - a.x) * ux + (loc.y - a.y) * uy) / len
end
WV.lanePos = lanePos

local function teamCreeps(bot, enemies)
    -- Strictly clamp to Dota 2 C++ spatial cache limit (`<= 1600u`) and guard `CanBeSeen()`
    -- to guarantee ZERO `[Developer] querying nearby units > cached` / `cannot be seen` console warnings!
    local list = bot:GetNearbyLaneCreeps(1600, enemies and true or false)
    local out = {}
    for _, c in ipairs(list or EMPTY) do
        if c and (not c.CanBeSeen or c:CanBeSeen()) and c:IsAlive() then
            out[#out + 1] = c
        end
    end
    return out
end

-- The wave state the policies need.  Cached for 0.1 s: RealThink runs every tick but the wave
-- does not move meaningfully inside one tick.
local cache, cacheAt = nil, -1
function WV.State(bot, force)
    local now = GameTime()
    if cache and not force and now == cacheAt then return cache end
    local a, ux, uy, len = axis(bot)
    local st = { a = a, ux = ux, uy = uy, len = len }
    local eCreeps = teamCreeps(bot, true)
    local aCreeps = teamCreeps(bot, false)
    local eFront, aFront = nil, nil
    local eSiege, aSiege = 0, 0
    for _, c in ipairs(eCreeps) do
        local p = lanePos(a, ux, uy, len, c:GetLocation())
        if not eFront or p < eFront then eFront = p end
        if (c:GetUnitName() or ""):find("siege") then eSiege = eSiege + 1 end
    end
    for _, c in ipairs(aCreeps) do
        local p = lanePos(a, ux, uy, len, c:GetLocation())
        if not aFront or p > aFront then aFront = p end
        if (c:GetUnitName() or ""):find("siege") then aSiege = aSiege + 1 end
    end
    st.enemyFront, st.allyFront = eFront, aFront
    st.botPos = lanePos(a, ux, uy, len, bot:GetLocation())
    st.enemyCreeps, st.allyCreeps = eCreeps, aCreeps
    st.nEnemy, st.nAlly = #eCreeps, #aCreeps
    st.nSiegeEnemy, st.nSiegeAlly = eSiege, aSiege
    -- Wave timing (Liquipedia, `A20` Fix — use `DotaTime()`, NOT `GameTime()`, because `GameTime()`
    -- includes the 75–102s pre-horn strategy/pregame clock and shifted siege wave #11 by ~3.5 waves!):
    -- Wave 1 spawns at `DotaTime() == 0:00`, every 30 s, and wave #11 (`5:00`) carries the first siege creep.
    local hornClock = math.max(0.0, (type(DotaTime) == "function" and DotaTime()) or now)
    local idx = math.floor(hornClock / 30) + 1
    st.waveIndex = idx
    st.nextWaveIn = 30 - (hornClock % 30)
    local j = idx
    while not (j >= 11 and (j - 1) % 10 == 0) do j = j + 1 end
    st.nextSiegeWave = j
    st.siegeIn = (j - idx) * 30 + st.nextWaveIn
    st.siegeSoon = st.siegeIn <= 45
    st.isSiegeWave = (idx >= 11 and (idx - 1) % 10 == 0)
    cache, cacheAt = st, now
    return st
end

local function enemyT1Pct(s)
    local t1 = s and s.enemyT1 or nil
    if not t1 then return nil end
    local ok, hp = pcall(t1.GetHealth, t1)
    local ok2, mx = pcall(t1.GetMaxHealth, t1)
    if ok and ok2 and mx and mx > 0 then return hp / mx end
    return nil
end

-- ------------------------------------------------------------------ push policy
-- Returns true when the current push must be downgraded to FARM.  The intent machine is the right
-- place: blocking only ExecutePush leaves the bot standing (measured: +11 s of idle time).
local function blockNow(bot, s)
    local policy = WV.PUSH_POLICY
    if policy == "always" then return false end
    local st = WV.State(bot)
    local t1 = enemyT1Pct(s)
    if t1 and t1 <= 0.30 then return false end        -- finishing the tower is always allowed
    local block
    if policy == "never" then
        block = true
    elseif policy == "free" then
        -- When the enemy hero is DEAD (`s.enemyAlive == false`), immediately push & crash our wave into his T1!
        if s and s.enemyAlive == false then
            block = false
        else
            local absent = (s and s.enemyAbsentFor or 0) >= 5
            block = not (absent and st.nAlly >= st.nEnemy)
        end
    elseif policy == "advantage" then
        block = not (st.nAlly >= st.nEnemy + 2 or (s and s.enemyAbsentFor or 0) >= 8)
    elseif policy == "siege" then
        block = not (st.siegeSoon or (s and s.enemyAbsentFor or 0) >= 12)
    else
        block = false
    end
    return block
end

function WV.BlockPush(bot, s)
    return blockNow(bot, s)
end

-- Called from the intent hook on a real PUSH -> FARM transition (not once per tick).
function WV.NoteBlock()
    WV.stats.blocked = WV.stats.blocked + 1
end

-- ------------------------------------------------------------------ positioning
-- Stand closer to my wave when nothing can punish it.
function WV.WaveDist(bot, baseDist, mode)
    if not WV.CLOSE then return baseDist end
    -- "PASSIVE" call sites build a RETREAT safepoint: never pull those closer to the wave
    if mode == "PASSIVE" then return baseDist end
    local heroes = bot:GetNearbyHeroes(1000, true, BOT_MODE_NONE)
    if heroes and #heroes > 0 then return baseDist end
    if bot:GetHealth() / math.max(1, bot:GetMaxHealth()) < 0.30 then return baseDist end
    WV.stats.close = WV.stats.close + 1
    return WV.CLOSE_DIST
end

-- Is the enemy wave at my T1 right now (>= 2 enemy creeps within 750 of my tower)?
function WV.AtMyTower(bot)
    if not WV.TOWER_FARM then return false end
    local P = package.loaded["bots/nevermore/positioning"]
    local myT1 = (P and P.GetT1Tower and P.GetT1Tower(bot))
        or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
    local n = 0
    for _, c in ipairs(teamCreeps(bot, true)) do
        if GetUnitToLocationDistance(c, myT1) <= 750 then n = n + 1 end
    end
    if n >= 2 then WV.stats.towerfarm = WV.stats.towerfarm + 1 end
    return n >= 2
end

-- ------------------------------------------------------------------ raze shove
local lastShove = -100

-- Decide whether razing the wave is allowed right now.
-- Strictly restricted to confirmed DEAD enemy hero (`s.enemyAlive == false`) so we NEVER waste
-- Shadowraze on solo lane creeps while laning against a live hero (`S1`/`S2` 0-raze CS rule preserved!),
-- while immediately blasting enemy waves after a solo kill (`HUD 09:01` fix) to crash into enemy T1!
function WV.ShoveAllowed(bot, s, enemyHero, now)
    if WV.SHOVE == "off" then return false end
    if not (s and s.enemyAlive == false) then return false end
    now = now or GameTime()
    if now - lastShove < WV.SHOVE_CD then return false end
    if bot:GetMana() < WV.SHOVE_MANA then return false end
    if bot:GetHealth() / math.max(1, bot:GetMaxHealth()) < 0.40 then return false end
    local st = WV.State(bot)
    if st.nEnemy < 2 then return false end
    return true
end

-- Best creep to raze: the one with the most enemy creeps inside a raze circle, inside cast range.
function WV.FindShove(bot, s)
    local st = WV.State(bot)
    local best, bestScore = nil, 0
    for _, c in ipairs(st.enemyCreeps) do
        if c and (not c.CanBeSeen or c:CanBeSeen()) and c:IsAlive() then
            local d = GetUnitToLocationDistance(bot, c:GetLocation())
            if d <= 720 then
                local score = 1
                local cp = c:GetLocation()
                for _, o in ipairs(st.enemyCreeps) do
                    if o ~= c and o and (not o.CanBeSeen or o:CanBeSeen()) and o:IsAlive()
                        and (o:GetLocation() - cp):Length() <= 250 then
                        score = score + 1
                    end
                end
                if score > bestScore then bestScore, best = score, c end
            end
        end
    end
    if not best or bestScore < 2 then return nil end
    local d = GetUnitToLocationDistance(bot, best:GetLocation())
    local bands = {
        { name = "nevermore_shadowraze1", center = C.RAZE.NEAR_CENTER },
        { name = "nevermore_shadowraze2", center = C.RAZE.MID_CENTER },
        { name = "nevermore_shadowraze3", center = C.RAZE.FAR_CENTER },
    }
    local ab, err = nil, 1e9
    for _, b in ipairs(bands) do
        local e = math.abs(d - b.center)
        if e < err then ab, err = b.name, e end
    end
    if err > 260 then return nil end
    return best, ab
end

function WV.NoteShove(now)
    lastShove = now or GameTime()
    WV.stats.shoves = WV.stats.shoves + 1
end

-- ------------------------------------------------------------------ aggro pull
-- Real Dota: an attack ORDER on an enemy hero draws the aggro of his creeps within 500 of me for
-- 2.3 s, once per 3 s.  Issuing the order and stepping back on the next tick therefore drags the
-- enemy wave towards my tower without trading a single hit - the standard mid "pull to hold the
-- wave" trick.  The studied bot never uses it (it only ever attacks the hero to fight).
--
-- PULL "free"     - only when he cannot punish the 0.1 s of walking away (he is > 700 away)
--      "always"   - whenever the wave is on his side and about to crash
local pullNextAt, pullMoveAt = -100, nil
WV.pullNextAt = nil

function WV.PullTick(bot, s, enemyHero, now)
    now = now or GameTime()
    if WV.PULL == "off" then return false end
    -- phase 2: on the next tick step back so the dragged creeps follow me to my side
    -- (NEVER yank SF `300u` backward mid-kill / mid-push when enemy hero is low or we are pressing!)
    if pullMoveAt and now >= pullMoveAt then
        pullMoveAt = nil
        if enemyHero and enemyHero:IsAlive() and (not enemyHero.CanBeSeen or enemyHero:CanBeSeen())
            and (enemyHero:GetHealth() or 9999) <= 360 then
            return false
        end
        local myT1 = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
        local loc = bot:GetLocation()
        local dx, dy = myT1.x - loc.x, myT1.y - loc.y
        local l = math.sqrt(dx * dx + dy * dy)
        if l > 1 then
            local p = Vector(loc.x + dx / l * 300, loc.y + dy / l * 300, loc.z or 128)
            bot:Action_MoveToLocation(p)
            WV.stats.pulls = WV.stats.pulls + 1
            return true
        end
        return false
    end
    if now < pullNextAt then return false end
    if not enemyHero or (enemyHero.CanBeSeen and not enemyHero:CanBeSeen()) or not enemyHero:IsAlive() then return false end
    local st = WV.State(bot)
    if st.nEnemy < 2 then return false end
    if bot:GetHealth() / math.max(1, bot:GetMaxHealth()) < 0.45 then return false end
    -- the wave must be on his side (otherwise there is nothing to hold back)
    if (st.allyFront or 0) < 0.55 then return false end
    -- I must be standing next to his creeps for the aggro to catch them (`0.1s` cached `st.enemyCreeps` MUST re-check `CanBeSeen()`!)
    local near = 0
    for _, c in ipairs(st.enemyCreeps) do
        if c and (not c.CanBeSeen or c:CanBeSeen()) and c:IsAlive()
            and GetUnitToLocationDistance(bot, c:GetLocation()) <= 500 then
            near = near + 1
        end
    end
    if near < 2 then return false end
    -- never do it inside his tower radius (the tower would switch to me)
    local ht = s and s.enemyT1
    if ht and (not ht.CanBeSeen or ht:CanBeSeen()) and ht:IsAlive() then
        if GetUnitToLocationDistance(bot, ht:GetLocation()) <= 850 then return false end
    end
    local dHero = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if WV.PULL == "free" and dHero <= 700 then return false end
    if dHero > 1100 then return false end          -- no legal target for the aggro order
    bot:Action_AttackUnit(enemyHero, false)        -- aggro trigger only; cancelled by the step back
    pullMoveAt = now + 0.05
    pullNextAt = now + 3.2
    return true
end

-- ------------------------------------------------------------------ old interface (compat)
-- ExecutePush is still gated by AllowPush: it covers the "siege fallback" path that bypasses the
-- intent machine.  A block here never leaves the bot idle because the intent was already downgraded.
function WV.AllowPush(bot, s)
    if WV.PUSH_POLICY == "always" then return true end
    return not blockNow(bot, s)
end

return WV
