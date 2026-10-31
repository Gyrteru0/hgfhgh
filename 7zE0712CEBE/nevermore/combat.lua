--
-- SF vs SF combat model:
-- * enemy raze tracker (cast phase -> ready time, because GetCooldownTimeRemaining
-- does not work for enemy abilities);
-- * honest raze damage (base + stacks + 2 per soul, the talent via GetSpecialValueInt);
-- * the "race": absolute HP after the exchange, who kills whom, which enemy bands are dangerous;
-- * the chase rule (CanCatch): do not run after an enemy with equal speed.
--
-- Combat estimates use the current visible snapshot and bounded time windows.

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")

local K = {}

K.LABELS = { "near", "mid", "far" }
K.RAZE_NAMES = {
    near = "nevermore_shadowraze1",
    mid  = "nevermore_shadowraze2",
    far  = "nevermore_shadowraze3",
}

local RAZE_CD        = (C.RAZE and C.RAZE.COOLDOWN) or 9.0
local CAST_POINT     = (C.RAZE and C.RAZE.CAST_POINT) or 0.55
local HIT_RADIUS     = (C.RAZE and C.RAZE.HIT_RADIUS) or 250
local RAZE_MANA      = (C.RAZE and C.RAZE.MANA_COST) or 75

local function Center(label)
    if label == "near" then return C.RAZE.NEAR_CENTER end
    if label == "mid" then return C.RAZE.MID_CENTER end
    return C.RAZE.FAR_CENTER
end
K.Center = Center

-- Raze damage

function K.RazeRawDamage(ability, stacks, souls, owner)
    return U.GetRazeRawDamage(ability, stacks, souls, owner)
end

function K.RazeManaCost(unit)
    if unit and unit.GetAbilityByName then
        local ab = unit:GetAbilityByName("nevermore_shadowraze1")
        if ab and ab.GetLevel and ab:GetLevel() > 0 then return U.GetRazeManaCost(ab) end
    end
    return RAZE_MANA
end

-- Damage of N of my razes on a target (current stacks on the target, my souls, the target's magic resist).
function K.MyRazeDamage(bot, target, n, extraStacks)
    if n <= 0 or not U.CanQuery(target) then return 0 end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    local souls = S.GetSouls(bot)
    local stacks = (U.GetShadowrazeDebuff(target) or 0) + (extraStacks or 0)
    local total = 0
    for i = 1, n do
        local raw = K.RazeRawDamage(q, stacks + i - 1, souls, bot)
        total = total + target:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
    end
    return total
end

-- Damage of N enemy razes on me.
function K.EnemyRazeDamage(bot, enemy, n, stacksOverride)
    if n <= 0 or not U.CanQuery(enemy) then return 0 end
    local q = enemy:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    local souls = S.GetSouls(enemy)
    local stacks = stacksOverride or (U.GetShadowrazeDebuff(bot) or 0)
    local total = 0
    for i = 1, n do
        local raw = K.RazeRawDamage(q, stacks + i - 1, souls, enemy)
        total = total + bot:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
    end
    return total
end

-- Right-click damage after the target's armour.
function K.AttackDamageVs(attacker, target)
    if not attacker or not U.CanQuery(target) then return 0 end
    local raw = attacker:GetAttackDamage() or 0
    if raw <= 0 then return 0 end
    return target:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)
end

-- My razes: readiness + mana (counting mango/stick when allowConsumables)

function K.MyManaBudget(bot, allowConsumables)
    if allowConsumables then return U.GetPotentialManaForRaze(bot) end
    return bot:GetMana() or 0
end

-- How many of my razes are really available (cooldown ready and enough mana).
-- Returns count, readyIgnoringMana.
function K.MyReadyRazeCount(bot, allowConsumables)
    local ready = 0
    for i = 1, 3 do
        local ab = bot:GetAbilityByName(K.RAZE_NAMES[K.LABELS[i]])
        if ab and ab:GetLevel() > 0 and ab:IsCooldownReady() then
            ready = ready + 1
        end
    end
    local budget = math.floor(K.MyManaBudget(bot, allowConsumables) / K.RazeManaCost(bot))
    if budget < ready then return budget, ready end
    return ready, ready
end

function K.MyRazeReady(bot, label)
    local ab = bot:GetAbilityByName(K.RAZE_NAMES[label])
    return ab and ab:GetLevel() > 0 and ab:IsCooldownReady() or false
end

-- Enemy raze tracker

K._enemy = {
    key = nil,
    raze = {
        near = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
        mid  = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
        far  = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
    },
    phaseLabel = nil,
    phaseStart = -1,
    lastAnyCastAt = -1,
    prevMyStacks = 0,
    prevMyStacksTime = -1,
}

local function ResetEnemyTracker()
    local E = K._enemy
    for i = 1, 3 do
        local st = E.raze[K.LABELS[i]]
        st.inPhase = false
        st.phaseStart = -1
        st.readyAt = 0
        st.lastCastAt = -1
    end
    E.phaseLabel = nil
    E.phaseStart = -1
    E.lastAnyCastAt = -1
end

local function EnemyKey(enemy)
    local pid = enemy.GetPlayerID and enemy:GetPlayerID()
    if pid == nil or pid < 0 then return tostring(enemy) end
    return pid
end

-- Call every tick (enemy may be nil / invisible).
function K.UpdateEnemyTracker(bot, enemy)
    local now = GameTime()
    local E = K._enemy

    if not U.CanQuery(enemy) then
        for i = 1, 3 do E.raze[K.LABELS[i]].inPhase = false end
        E.phaseLabel = nil
        if bot then
            local fogStacks, fogRem = U.GetShadowrazeDebuff(bot)
            fogStacks = fogStacks or 0
            fogRem = fogRem or 0
            local duration = U.GetRazeDuration(nil)
            if fogStacks == 1 and fogRem >= duration - 0.8 then
                local hitTime = now - math.max(0.0, duration - fogRem)
                if hitTime > (E.lastAnyCastAt or -100) + 0.55 then
                    local Wref = U._W
                    local snap = Wref and Wref.s
                    local lastLoc = snap and snap.enemyLastLoc
                    local recentLoc = lastLoc and (snap.enemyAbsentFor or 99) <= 1.0
                    local estDist = recentLoc and GetUnitToLocationDistance(bot, lastLoc) or 0
                    -- Only the far band can reach beyond 702u. Do not infer a band from stale fog coordinates.
                    if estDist > 702 then
                        local st = E.raze["far"]
                        st.lastCastAt = hitTime
                        st.readyAt = math.max(st.readyAt or 0, hitTime + RAZE_CD - 0.2)
                        E.lastAnyCastAt = hitTime
                    end
                end
            end
            E.prevMyStacks = fogStacks
            E.prevMyStacksTime = now
        end
        return
    end

    local key = EnemyKey(enemy)
    if E.key ~= key or E.selfBot ~= bot then
        ResetEnemyTracker()
        E.key = key
        E.selfBot = bot
        E.prevMyStacksTime = -1
    end

    local actAnim = enemy.GetAnimActivity and enemy:GetAnimActivity() or 0
    local curAb = enemy.GetCurrentActiveAbility and enemy:GetCurrentActiveAbility() or nil

    E.phaseLabel = nil
    for i = 1, 3 do
        local label = K.LABELS[i]
        local razeName = K.RAZE_NAMES[label]
        local st = E.raze[label]
        local ab = enemy:GetAbilityByName(razeName)
        local inPhase = false
        if ab and ab:GetLevel() > 0 and ab:IsInAbilityPhase() then
            inPhase = true
        elseif curAb and curAb.GetName and curAb:GetName() == razeName then
            inPhase = true
        elseif actAnim == (1509 + i) then -- 1510 = Q (near), 1511 = W (mid), 1512 = E (far)
            inPhase = true
        end

        if inPhase and not st.inPhase then
            st.phaseStart = now
        elseif st.inPhase and not inPhase then
            -- The phase ended: if it lasted almost the whole cast point - the raze was released and the cooldown started.
            local dur = now - st.phaseStart
            if dur >= CAST_POINT - 0.15 then
                st.lastCastAt = now
                st.readyAt = now + RAZE_CD - 0.05
                E.lastAnyCastAt = now
            end
        end
        st.inPhase = inPhase
        if inPhase then
            E.phaseLabel = label
            E.phaseStart = st.phaseStart
        end
    end

    -- Initial-sight debuff inference. Current KV duration is 6s, not the old 8s.
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0
    local eq = enemy.GetAbilityByName and enemy:GetAbilityByName(K.RAZE_NAMES.near)
    local duration = U.GetRazeDuration(eq)
    if myStacks == 1 and myRem >= duration - 0.8 then
        local hitTime = now - math.max(0.0, duration - myRem)
        if hitTime > (E.lastAnyCastAt or -100) + 0.55 then
            local dist = GetUnitToLocationDistance(enemy, bot:GetLocation())
            if dist > 702 then
                local st = E.raze["far"]
                st.lastCastAt = hitTime
                st.readyAt = math.max(st.readyAt or 0, hitTime + RAZE_CD - 0.15)
                E.lastAnyCastAt = hitTime
            end
        end
    end
    E.prevMyStacks = myStacks
    E.prevMyStacksTime = now
end

-- How many seconds until the enemy band is ready (0 = ready now / unknown = ready).
function K.EnemyRazeReadyIn(label)
    local st = K._enemy.raze[label]
    if not st then return 0 end
    local dt = st.readyAt - GameTime()
    if dt < 0 then return 0 end
    return dt
end

function K.EnemyRazeReady(label, horizon)
    return K.EnemyRazeReadyIn(label) <= (horizon or 0)
end

-- Is the enemy in a raze cast phase right now? -> label, elapsed, remaining
function K.EnemyPhase()
    local E = K._enemy
    if not E.phaseLabel then return nil, 0, 0 end
    local elapsed = GameTime() - E.phaseStart
    local remaining = CAST_POINT - elapsed
    if remaining < 0 then remaining = 0 end
    return E.phaseLabel, elapsed, remaining
end

-- The centre of the enemy raze circle for a given band (by his current facing).
function K.EnemyRazeCenter(enemy, label)
    local loc = enemy:GetLocation()
    local rad = math.rad(enemy:GetFacing() or 0)
    local d = Center(label)
    return Vector(loc.x + math.cos(rad) * d, loc.y + math.sin(rad) * d, loc.z)
end

function K.EnemyManaBudget(enemy, allowConsumables)
    if allowConsumables then return U.GetPotentialManaForRaze(enemy) end
    return enemy:GetMana() or 0
end

-- How many enemy razes become ready within horizon seconds (limited by mana).
-- Returns count, countIgnoringMana.
function K.EnemyReadyRazeCount(enemy, horizon, allowConsumables)
    if not U.CanQuery(enemy) then return 0, 0 end
    if not U.EnemyHasRaze(enemy) then return 0, 0 end
    local n = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        local ab = enemy.GetAbilityByName and enemy:GetAbilityByName(K.RAZE_NAMES[label])
        if ab and ab.GetLevel and ab:GetLevel() > 0 and K.EnemyRazeReadyIn(label) <= (horizon or 0) then n = n + 1 end
    end
    local budget = math.floor(K.EnemyManaBudget(enemy, allowConsumables) / K.RazeManaCost(enemy))
    if budget < n then return budget, n end
    return n, n
end

-- Can an enemy band reach me from distance dist within horizon seconds.
-- Relative kinematics fix (`v3.9.0`): when unpinned, an enemy closes at RELATIVE speed `(enMS - myMS) * horizon`,
-- NEVER at full `enMS * horizon` (`345 * 2.5 = 862u` falsely treated `Shadowraze1 (200u)` as a `1,397u` spell!).
local function BandCanReach(bot, enemy, label, dist, horizon, pinned)
    local reach = Center(label) + HIT_RADIUS + 25
    if dist <= reach then return true end
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local closeAllowance
    if pinned then
        closeAllowance = enMS * math.min(horizon or 0, 0.65) + 60
    else
        closeAllowance = math.max(0, enMS - myMS) * (horizon or 0) + 95
    end
    return dist <= reach + closeAllowance
end

-- Projectile-aware incoming physical damage. Already-launched projectiles are counted once;
-- fresh swings are scheduled from windup/cooldown, not granted instantly at t=0.
-- opts: enemy, creeps, towers, includePotential, afterTime, unknownConservative.
function K.IncomingAttackDamage(target, horizon, opts)
    if not target then return 0 end
    opts = opts or {}
    horizon = horizon or 0
    local damage = 0
    local launched = {}
    if target.GetIncomingTrackingProjectiles then
        for _, pr in pairs(target:GetIncomingTrackingProjectiles() or {}) do
            if pr and pr.is_attack then
                local caster = pr.caster
                local impact = 0
                if caster and U.CanQuery(caster) then
                    local speed = U.GetProjectileSpeedOf(caster)
                    if pr.location and speed > 0 then
                        impact = U.CalcInFlightRemainingTicks(pr.location, target, speed) / 30.0
                    end
                    if impact <= horizon then
                        local rawLo, rawHi, rawAvg = U.SampleRawDamageRange(caster)
                        damage = damage + U.CalcExactIntDamage(caster, target, rawAvg)
                        launched[caster] = true
                    end
                elseif opts.unknownConservative ~= false then
                    return math.huge
                end
            end
        end
    end
    local attackers = {}
    if opts.enemy and U.CanQuery(opts.enemy) then attackers[#attackers+1] = opts.enemy end
    for _, c in pairs(opts.creeps or {}) do
        if U.CanQuery(c) and c:IsAlive() then
            local targeting = c.GetAttackTarget and c:GetAttackTarget() == target
            local potential = opts.includePotential and not targeting
                and GetUnitToLocationDistance(target, c:GetLocation()) <= 500
            if targeting or potential then attackers[#attackers+1] = c end
        end
    end
    for _, t in pairs(opts.towers or {}) do
        if U.CanQuery(t) and t:IsAlive() and t.GetAttackTarget and t:GetAttackTarget() == target then
            attackers[#attackers+1] = t
        end
    end
    for _, atk in ipairs(attackers) do
        if not launched[atk] or horizon >= 2.0 then
            local first = U.GetNextAttackImpactTime(atk, target)
            if opts.afterTime and first < opts.afterTime then first = opts.afterTime + first end
            if first <= horizon then
                local spa = math.max(0.45, atk:GetSecondsPerAttack() or 1.6)
                local hits = 1 + math.floor((horizon - first) / spa + 1e-6)
                damage = damage + K.AttackDamageVs(atk, target) * hits
            end
        end
    end
    return damage
end

-- Serialized raze schedule. Returns damage, count, lastCastEnd.
local function RazeSchedule(caster, target, dist, horizon, isEnemy, allowConsumables, pinned, stacksOverride)
    if not U.CanQuery(target) then return 0, 0, 0 end
    horizon = horizon or 0
    local cost = K.RazeManaCost(caster)
    local mana = isEnemy and K.EnemyManaBudget(caster, true) or K.MyManaBudget(caster, allowConsumables)
    local regen = math.max(0, caster.GetManaRegen and caster:GetManaRegen() or 0)
    local myMS = (not isEnemy) and (caster:GetCurrentMovementSpeed() or 305) or (target:GetCurrentMovementSpeed() or 305)
    local enMS = isEnemy and (caster:GetCurrentMovementSpeed() or 305) or (target:GetCurrentMovementSpeed() or 305)
    local phase, _, phaseRemaining = nil, 0, 0
    if isEnemy then phase, _, phaseRemaining = K.EnemyPhase() end
    local candidates = {}
    for i = 1, 3 do
        local label = K.LABELS[i]
        local ab = caster.GetAbilityByName and caster:GetAbilityByName(K.RAZE_NAMES[label])
        if ab and ab.GetLevel and ab:GetLevel() > 0 then
            local readyIn = 0
            if isEnemy then
                readyIn = K.EnemyRazeReadyIn(label)
            else
                local ok, cd = pcall(ab.GetCooldownTimeRemaining, ab)
                readyIn = (ok and type(cd) == "number") and cd or (ab:IsCooldownReady() and 0 or 999)
            end
            local cp = U.GetRazeCastPoint(ab)
            local reach = Center(label) + HIT_RADIUS
            local inner = math.max(0, Center(label) - HIT_RADIUS)
            local gap = math.max(0, dist - reach, inner - dist)
            local allowance
            if isEnemy then
                allowance = pinned and (enMS * math.min(horizon, 0.65)) or (math.max(0, enMS - myMS) * horizon)
            else
                allowance = math.max(0, myMS - enMS) * horizon
            end
            if gap <= allowance + 1e-6 then
                local t = readyIn + cp
                if isEnemy and phase == label then t = math.max(0, phaseRemaining or cp) end
                candidates[#candidates+1] = { t = t, cp = cp, label = label }
            end
        end
    end
    table.sort(candidates, function(a,b) return a.t < b.t end)
    local q = caster.GetAbilityByName and caster:GetAbilityByName(K.RAZE_NAMES.near)
    local souls = S.GetSouls(caster)
    local stacks = stacksOverride or (U.GetShadowrazeDebuff(target) or 0)
    local _, rem = U.GetShadowrazeDebuff(target)
    rem = rem or 0
    local n, dmg, lastEnd = 0, 0, 0
    for _, c in ipairs(candidates) do
        local start = math.max(c.t - c.cp, lastEnd)
        local finish = start + c.cp
        if finish <= horizon + 1e-6 and mana + regen * finish >= cost * (n + 1) then
            n = n + 1
            local stacksAt = (rem > finish) and (stacks + n - 1) or (n - 1)
            local raw = U.GetRazeRawDamage(q, stacksAt, souls, caster)
            dmg = dmg + target:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
            lastEnd = finish
        end
    end
    return dmg, n, lastEnd
end
K.RazeSchedule = RazeSchedule

-- The enemy burst on me from distance dist over horizon, with serialized casts and real attack timing.
function K.EnemyBurstVs(bot, enemy, dist, horizon, pinned, stacksOverride)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 2.5
    local dmg, n, lastEnd = RazeSchedule(enemy, bot, dist, horizon, true, true, pinned, stacksOverride)
    local incoming = K.IncomingAttackDamage(bot, horizon, { enemy = enemy, afterTime = lastEnd, unknownConservative = false })
    return dmg + incoming, n
end

-- My burst on the enemy from distance dist over horizon. Casts are serialized; attacks only fill free time.
function K.MyBurstVs(bot, enemy, dist, horizon, allowConsumables)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 2.5
    local dmg, n, lastEnd = RazeSchedule(bot, enemy, dist, horizon, false, allowConsumables, false, nil)
    local first = U.GetNextAttackImpactTime(bot, enemy)
    local attackStart = (n > 0) and lastEnd or 0
    local firstAfter = attackStart + first
    if firstAfter <= horizon then
        local spa = math.max(0.45, bot:GetSecondsPerAttack() or 1.6)
        local hits = 1 + math.floor((horizon - firstAfter) / spa + 1e-6)
        dmg = dmg + K.AttackDamageVs(bot, enemy) * hits
    end
    return dmg, n
end

-- Hunt burst assumes we can reach the mid band, but still serializes casts and attacks.
function K.MyHuntBurst(bot, enemy, horizon)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 4.0
    local dist = math.min(GetUnitToLocationDistance(bot, enemy:GetLocation()), C.RAZE.MID_CENTER + 150)
    local dmg, n, lastEnd = RazeSchedule(bot, enemy, dist, horizon, false, true, false, nil)
    local first = U.GetNextAttackImpactTime(bot, enemy)
    local firstAfter = lastEnd + first
    if firstAfter <= horizon then
        local spa = math.max(0.45, bot:GetSecondsPerAttack() or 1.6)
        local hits = math.min(2, 1 + math.floor((horizon - firstAfter) / spa + 1e-6))
        dmg = dmg + K.AttackDamageVs(bot, enemy) * hits
    end
    return dmg, n
end

-- Minimum safe distance to the enemy: outside all his bands that are ready within horizon.
-- 0 = no band is ready (or no mana) -> we can stand anywhere.
function K.EnemyMinSafeDistance(enemy, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local budget = math.floor(K.EnemyManaBudget(enemy, true) / K.RazeManaCost(enemy))
    if budget <= 0 then return 0 end
    local best = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            local r = Center(label) + HIT_RADIUS + 45
            if r > best then best = r end
        end
    end
    return best
end

-- "Hedge" distance: stand at the outer edge of his furthest READY band
-- (centre + 200 of the 250 radius): the cast animation (0.55 s) gives us time to leave the circle.
-- This is the compromise for a "zoned" SF: do not give up the whole wave but do not stand in the band centre.
function K.EnemyDodgeableDistance(enemy, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local budget = math.floor(K.EnemyManaBudget(enemy, true) / K.RazeManaCost(enemy))
    if budget <= 0 then return 0 end
    local best = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            local r = Center(label) + 200
            if r > best then best = r end
        end
    end
    return best
end

-- The enemy band that is ready within horizon and that I am standing in (or nil).
function K.EnemyReadyBandAt(enemy, dist, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return nil end
    if K.EnemyManaBudget(enemy, true) < K.RazeManaCost(enemy) then return nil end
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            if math.abs(dist - Center(label)) <= HIT_RADIUS + 30 then return label end
        end
    end
    return nil
end

-- How many razes a unit can pay for right now (mana + consumables, 75 per raze).
function K.MyRazeBudget(bot, allowConsumables)
    return math.floor((K.MyManaBudget(bot, allowConsumables) or 0) / K.RazeManaCost(bot))
end

function K.EnemyRazeBudget(enemy, allowConsumables)
    if not U.CanQuery(enemy) then return 0 end
    return math.floor((K.EnemyManaBudget(enemy, allowConsumables) or 0) / K.RazeManaCost(enemy))
end

-- Is it safe for me to stand/cast in band label.
-- At ~center(label) I am inside HIS label band, so only its copy is dangerous.
-- If his copy is on cooldown (or unlearned / no mana) he cannot answer. This is more precise
-- than the old rule "only the band he hit us with last is safe".
function K.BandSafeFromEnemy(enemy, label, marginSec)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return true end
    local ab = enemy:GetAbilityByName(K.RAZE_NAMES[label])
    if not ab or ab:GetLevel() == 0 then return true end
    if K.EnemyManaBudget(enemy, true) < K.RazeManaCost(enemy) then return true end
    return K.EnemyRazeReadyIn(label) > (marginSec or 0.0)
end

-- Preserve the confirmed 2:1 lead; waive ONLY when SF holds a clean, healthy, flat-ground lethal finish (`myHp >= 520`, `mana >= 75`).
function K.HasRazeStackLead(bot, enemy)
    if not U.CanQuery(enemy) or not (enemy.IsHero and enemy:IsHero()) then return false end
    local mine, myRemain = U.GetShadowrazeDebuff(bot)
    local theirs, theirRemain = U.GetShadowrazeDebuff(enemy)
    if not (mine == 1 and theirs >= 2 and myRemain > 0.35 and theirRemain > 0.35) then
        return false
    end
    local R = K._race
    if R and R.valid and not R.heCanKillSoon and not R.uphillPenalty
        and (bot:GetHealth() or 0) >= 520 and (bot:GetMana() or 0) >= 75 then
        local enEff = R.enEffHpNow or enemy:GetHealth() or 9999
        local razeKill = U.GetNRazeDamage(bot, enemy, 1) + (bot:GetAttackDamage() or 60) * 1.35
        if enEff <= razeKill then
            return false
        end
    end
    return true
end

-- Count every overlapping, learned, ready band, not just the nearest centre.
function K.EnemyBandsAcross(enemy, low, high, horizon)
    if not U.CanQuery(enemy) then return 0 end
    horizon = horizon or 0.7
    local mana = K.EnemyManaBudget(enemy, true)
        + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * horizon
    local n, outer = 0, 0
    for _, label in ipairs(K.LABELS) do
        local ab = enemy:GetAbilityByName(K.RAZE_NAMES[label])
        if ab and ab:GetLevel() > 0 and K.EnemyRazeReadyIn(label) <= horizon
            and high >= Center(label) - HIT_RADIUS - 30
            and low <= Center(label) + HIT_RADIUS + 30 then
            n = n + 1
            outer = math.max(outer, Center(label) + HIT_RADIUS + 30)
        end
    end
    local cost=K.RazeManaCost(enemy)
    return math.min(n, math.floor(mana / cost)), mana >= cost and outer or 0
end

function K.StackLeadStepSafe(bot, enemy, point)
    if not K.HasRazeStackLead(bot, enemy) then return true end
    local here, e = bot:GetLocation(), enemy:GetLocation()
    local step = point - here
    local length2 = step.x * step.x + step.y * step.y
    local t = 0
    if length2 > 1 then
        t = math.max(0, math.min(1, ((e.x-here.x)*step.x + (e.y-here.y)*step.y) / length2))
    end
    local nearest = U.DistanceBetweenLocations(here + step * t, e)
    local before, after = U.DistanceBetweenLocations(here, e), U.DistanceBetweenLocations(point, e)
    if after >= before and nearest >= before - 5 then return true end -- Always permit outward escape.
    local horizon = math.min(1.5, math.sqrt(length2) / math.max(1, bot:GetCurrentMovementSpeed()) + 0.7)
    return K.EnemyBandsAcross(enemy, nearest, math.max(before, after), horizon) == 0
end

-- A short mid/far raze exchange is not a sustained right-click duel. Reuse
-- the existing damage and mana model, but bound the exchange by cast/move time.
-- Returns safe opportunity, ready own razes, enemy razes, our damage, incoming.
function K.SpellTradeWindow(bot, enemy, snapshot)
    if not U.CanQuery(enemy) then return false, 0, 0, 0, 0 end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist < 350 or dist > 1050 then return false, 0, 0, 0, 0 end
    local ready, desired = 0, C.RAZE.FAR_CENTER
    for _, label in ipairs({"far", "mid"}) do
        if K.MyRazeReady(bot, label) then
            ready = ready + 1
            desired = math.min(desired, Center(label))
        end
    end
    -- Only mana already usable without spending this tick on an item.
    local count = math.min(ready, math.floor(bot:GetMana() / K.RazeManaCost(bot)))
    if count < 1 then return false, count, 0, 0, 0 end
    if count == 1 and K.MyRazeReady(bot, "far") then desired = C.RAZE.FAR_CENTER end
    local ms = math.max(1, bot:GetCurrentMovementSpeed() or 305)
    local reach = desired + HIT_RADIUS - 40
    if count >= 2 then desired = C.RAZE.MID_CENTER + 150; reach = desired end
    local approach = math.max(0, dist - reach) / ms
    local horizon = count * CAST_POINT + approach + 0.40
    if horizon > 3.0 or not K.CanCatch(bot, enemy, reach, horizon) then
        return false, count, 0, 0, 0
    end
    local enemyMana = K.EnemyManaBudget(enemy, true)
        + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * horizon
    local enemyReady = 0
    if U.EnemyHasRaze(enemy) then
        for _, label in ipairs(K.LABELS) do
            local ab = enemy:GetAbilityByName(K.RAZE_NAMES[label])
            if ab and ab:GetLevel() > 0 and K.EnemyRazeReadyIn(label) <= horizon then enemyReady = enemyReady + 1 end
        end
    end
    local enemyCount = math.min(enemyReady, math.floor(enemyMana / K.RazeManaCost(enemy)))
    if count <= enemyCount then return false, count, enemyCount, 0, 0 end
    local goal = enemy:GetLocation() + (bot:GetLocation() - enemy:GetLocation()):Normalized() * desired
    for _, tower in pairs((snapshot and snapshot.enemyTowers) or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 800
            or U.DistanceBetweenLocations(goal, tower:GetLocation()) < 800) then
            return false, count, enemyCount, 0, 0
        end
    end
    local incoming = K.EnemyRazeDamage(bot, enemy, enemyCount)
    local enemyRange = enemy:GetAttackRange() or 525
    -- No mana is NOT no danger: include right clicks if he can reach during casts.
    if math.min(dist, desired) <= enemyRange + (enemy:GetCurrentMovementSpeed() or 305) * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot)
            * math.ceil(horizon / math.max(0.6, enemy:GetSecondsPerAttack() or 1.6))
    end
    for _, creep in pairs((snapshot and snapshot.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then
            incoming = incoming + K.AttackDamageVs(creep, bot)
                * math.ceil(horizon / math.max(0.6, creep:GetSecondsPerAttack() or 1.0))
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then
                return false, count, enemyCount, 0, incoming
            end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    local damage = K.MyRazeDamage(bot, enemy, count)
    local reserve = math.max(60, K.AttackDamageVs(enemy, bot) * 0.75)
    local myStacks = U.GetShadowrazeDebuff(bot)
    local spentRanged = count >= 2 and myStacks == 0
        and K.EnemyRazeReadyIn("mid") > horizon + 0.2 and K.EnemyRazeReadyIn("far") > horizon + 0.2
    local favourable = bot:GetHealth() - incoming >= reserve
        and damage >= incoming + (spentRanged and 0 or 35)
    return favourable, count, enemyCount, damage, incoming, favourable and spentRanged
end

-- Finite cast schedule for one short reply, including regeneration and already flying attacks.
function K.ShortReplyIncoming(bot,enemy,horizon,s)
    if not U.CanQuery(enemy) then return 0 end
    local dist=GetUnitToLocationDistance(bot,enemy:GetLocation())
    local damage,n,lastEnd=RazeSchedule(enemy,bot,dist,horizon,true,true,false,nil)
    damage=damage+K.IncomingAttackDamage(bot,horizon,{
        enemy=enemy,
        creeps=(s and s.enemyCreeps) or {},
        includePotential=false,
        afterTime=lastEnd,
        unknownConservative=true,
    })
    return damage
end

function K.ManaCycleWindow(bot,enemy,s)
    if not U.CanQuery(enemy) or bot:GetMana()<150 or bot:IsSilenced() or bot:IsHexed()
        or (bot.IsDisarmed and bot:IsDisarmed()) then return false end
    local times={}
    local distance=GetUnitToLocationDistance(bot,enemy:GetLocation())
    for _,label in ipairs(K.LABELS) do
        local ab=bot:GetAbilityByName(K.RAZE_NAMES[label])
        if ab and ab:GetLevel()>0 then
            local cd=ab:GetCooldownTimeRemaining()
            if cd<=9 and math.abs(distance-Center(label))<=HIT_RADIUS-(C.RAZE.ROBUST_MARGIN or 30) then
                times[#times+1]=math.max(0,cd)
            end
        end
    end
    table.sort(times)
    local n=math.min(#times,math.floor(bot:GetMana()/K.RazeManaCost(bot)))
    if n<2 then return false end
    local horizon=0
    for i=1,n do horizon=math.max(horizon,times[i])+CAST_POINT end
    horizon=horizon+0.35
    if horizon>10.5 or K.EnemyManaBudget(enemy,true)+math.max(0,enemy:GetManaRegen() or 0)*horizon>=75 then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    if bot:GetHealth()-incoming<math.max(100,K.AttackDamageVs(enemy,bot)*1.25) then return false end
    local hits=math.max(0,math.floor((horizon-n*CAST_POINT)/math.max(0.6,bot:GetSecondsPerAttack())))
    -- Do not assume old stacks survive until the reloaded spells.
    local damage=n*K.MyRazeDamage(bot,enemy,1,-(U.GetShadowrazeDebuff(enemy) or 0))+K.AttackDamageVs(bot,enemy)*hits
    local enemyHP=enemy:GetHealth()+math.max(0,enemy:GetHealthRegen() or 0)*horizon+U.GetStickCharges(enemy)*15
    if U.HasItem(enemy,"item_faerie_fire") then enemyHP=enemyHP+85 end
    return bot:GetHealth()-incoming-(enemyHP-damage)>=60
end

-- A read-only recovery estimate for the shop. Do not call Race here: the shop
-- must not overwrite the live combat snapshot or reset the enemy cast tracker.
function K.NeedsRecoverySupport(bot, enemy)
    if not U.CanQuery(enemy) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist > 1600 then return false end
    local mine = K.MyBurstVs(bot, enemy, math.min(dist, 600), 2.5, true)
    local theirs = K.EnemyBurstVs(bot, enemy, math.min(dist, 600), 2.5, false)
    local deficit = (enemy:GetHealth() - mine) - (bot:GetHealth() - theirs)
    return deficit >= 220 and (theirs >= mine + 80 or enemy:GetHealth() >= bot:GetHealth() + 250)
end

-- The race: absolute HP, who kills whom.

K._race = {
    valid = false,
    dist = 0,
    myHp = 0, enHp = 0,
    myBurstNow = 0, myBurstSoon = 0, myRazesSoon = 0,
    enBurstNow = 0, enBurstSoon = 0, enRazesSoon = 0,
    canKillNow = false, canKillSoon = false,
    heCanKillNow = false, heCanKillSoon = false,
    edge = 0, -- (my HP after his burst) - (his HP after my burst)
    hpDiff = 0, -- my HP - his HP (absolute)
    minSafeDist = 0, -- the distance beyond which his ready bands cannot reach me
    enemyFaster = false,
    enemyBandHere = nil, -- the enemy's ready band that I am standing in
}

-- Tower damage on a hero over horizon seconds (if the hero is in its radius). T1: ~90 damage, BAT 0.9.
local function TowerDamageOn(tower, hero, horizon)
    if not tower or not U.CanQuery(hero) then return 0 end
    local okAlive, alive = pcall(tower.IsAlive, tower)
    if not okAlive or not alive then return 0 end
    local okLoc, tLoc = pcall(tower.GetLocation, tower)
    if not okLoc or not tLoc then return 0 end
    if GetUnitToLocationDistance(hero, tLoc) > 720 then return 0 end
    local raw = 90
    local okD, d = pcall(tower.GetAttackDamage, tower)
    if okD and type(d) == "number" and d > 0 then raw = d end
    local per = hero:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)
    return per * math.floor(horizon / 0.9)
end

-- s (optional) = the world snapshot W.s: towers + nearby creeps so creep aggro, enemy burst heals
-- (Faerie Fire +85, Stick/Wand +15*charges, regen) and Source 2 25% uphill miss factor count in Race.
function K.Race(bot, enemy, pinned, s)
    local R = K._race
    R.valid = false
    if not bot or not U.CanQuery(enemy) then return R end
    local bLoc, eLoc = bot:GetLocation(), enemy:GetLocation()
    local dist = GetUnitToLocationDistance(bot, eLoc)
    local myHp = bot:GetHealth() or 0
    local enHp = enemy:GetHealth() or 0

    -- Enemy instant burst survival items (Faerie Fire +85 HP, Stick/Wand +15 HP per charge) + active regen
    local enInstantHeal = (U.HasItem(enemy, "item_faerie_fire") and 85 or 0) + (U.GetStickCharges(enemy) * 15)
    local enRegen25 = math.max(0, (enemy.GetHealthRegen and enemy:GetHealthRegen() or 0)) * 2.5
    local enEffHpNow = enHp + enInstantHeal
    local enEffHpSoon = enHp + enInstantHeal + enRegen25

    -- Source 2 25% uphill miss factor (0.75x projectile hit expectation when attacking >= 90u uphill)
    local myHitFactor = (bLoc and eLoc and (eLoc.z or 0) - (bLoc.z or 0) >= 90) and 0.75 or 1.0
    local enHitFactor = (bLoc and eLoc and (bLoc.z or 0) - (eLoc.z or 0) >= 90) and 0.75 or 1.0

    local myNow = K.MyBurstVs(bot, enemy, dist, 0.3, true)
    local mySoon, myRazesSoon = K.MyBurstVs(bot, enemy, dist, 2.5, true)
    local enNow = K.EnemyBurstVs(bot, enemy, dist, 0.3, pinned)
    local enSoon, enRazesSoon = K.EnemyBurstVs(bot, enemy, dist, 2.5, pinned)

    -- Apply uphill miss expectation to physical attack portion of 2.5s burst
    if myHitFactor < 1.0 then
        local myRazePart = K.MyRazeDamage(bot, enemy, myRazesSoon or 0)
        mySoon = myRazePart + math.max(0, mySoon - myRazePart) * myHitFactor
    end

    -- Towers & symmetric creep aggro physics (`v3.9.0`):
    -- Unaggroed creeps fighting our wave do NOT hit us during normal CS/poke; ONLY actually aggroed creeps
    -- count unconditionally in `enSoon`, while close (`<= 500u`) wave creeps count symmetrically in hero trades!
    R.myTowerOnHim = 0
    R.hisTowerOnMe = 0
    local activeCreepDpsOnMe = 0
    local potentialCreepDpsOnMe = 0
    local activeCreepDpsOnHim = 0
    local potentialCreepDpsOnHim = 0
    if s then
        R.myTowerOnHim = TowerDamageOn(s.allyT1, enemy, 2.5)
        R.hisTowerOnMe = TowerDamageOn(s.enemyT1, bot, 2.5)
        if R.hisTowerOnMe == 0 and s.enemyT1Alive ~= false and s.enemyT1Loc
            and U.DistanceBetweenLocations(bLoc, s.enemyT1Loc) <= 845 and #(s.allyCreeps or {}) == 0 then
            R.hisTowerOnMe = bot:GetActualIncomingDamage(90, DAMAGE_TYPE_PHYSICAL) * 2
        end
        mySoon = mySoon + R.myTowerOnHim
        enSoon = enSoon + R.hisTowerOnMe
        for _, c in pairs(s.enemyCreeps or {}) do
            if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then
                local cDps = K.AttackDamageVs(c, bot) / math.max(0.75, c:GetSecondsPerAttack() or 1.0)
                activeCreepDpsOnMe = activeCreepDpsOnMe + cDps
                potentialCreepDpsOnMe = potentialCreepDpsOnMe + cDps
            end
        end
        for _, c in pairs(s.allyCreeps or {}) do
            if U.CanQuery(c) and c:IsAlive() then
                local cDps = K.AttackDamageVs(c, enemy) / math.max(0.75, c:GetSecondsPerAttack() or 1.0)
                if c:GetAttackTarget() == enemy then
                    activeCreepDpsOnHim = activeCreepDpsOnHim + cDps
                    potentialCreepDpsOnHim = potentialCreepDpsOnHim + cDps
                elseif GetUnitToLocationDistance(c, enemy:GetLocation()) <= 450 then
                    potentialCreepDpsOnHim = potentialCreepDpsOnHim + cDps * 0.45
                end
            end
        end
        enSoon = enSoon + activeCreepDpsOnMe * 2.2 + math.max(0, potentialCreepDpsOnMe - activeCreepDpsOnMe) * 0.75
        mySoon = mySoon + activeCreepDpsOnHim * 2.2 + math.max(0, potentialCreepDpsOnHim - activeCreepDpsOnHim) * 0.75
        enNow = enNow + activeCreepDpsOnMe * 0.4
        myNow = myNow + activeCreepDpsOnHim * 0.4
    end

    -- Prolonged right-click trade: symmetric DPS and time to kill each other (with uphill miss + symmetric creep aggro)
    local myAtk = K.AttackDamageVs(bot, enemy) * myHitFactor
    local enAtk = K.AttackDamageVs(enemy, bot) * enHitFactor
    local mySpa = bot:GetSecondsPerAttack() or 1.6
    local enSpa = enemy:GetSecondsPerAttack() or 1.6
    if mySpa <= 0 then mySpa = 1.6 end
    if enSpa <= 0 then enSpa = 1.6 end
    R.myDps = (myAtk / mySpa) + potentialCreepDpsOnHim
    R.enHeroDps = enAtk / enSpa
    R.creepDpsOnMe = potentialCreepDpsOnMe
    R.enDps = R.enHeroDps + potentialCreepDpsOnMe
    R.uphillPenalty = (myHitFactor < 1.0)
    R.ttkMe = (R.enDps > 0) and (myHp / R.enDps) or 999
    R.ttkHim = (R.myDps > 0) and (enEffHpSoon / R.myDps) or 999

    R.dist = dist
    R.myHp = myHp
    R.enHp = enHp
    R.enEffHpNow = enEffHpNow
    R.enEffHpSoon = enEffHpSoon
    R.myBurstNow = myNow
    R.myBurstSoon = mySoon
    R.myRazesSoon = myRazesSoon
    R.enBurstNow = enNow
    R.enBurstSoon = enSoon
    R.enRazesSoon = enRazesSoon
    R.canKillNow = (myNow > 0) and (myNow >= enEffHpNow)
    R.canKillSoon = (mySoon > 0) and (mySoon >= enEffHpSoon)
    R.heCanKillNow = (enNow > 0) and (enNow >= myHp)
    R.heCanKillSoon = (enSoon > 0) and (enSoon >= myHp)
    R.edge = (myHp - enSoon) - (enEffHpSoon - mySoon)
    R.hpDiff = myHp - enEffHpNow
    -- A 6 s trade projection: "soon" burst + auto attacks for the remaining time (effective EHP).
    local T = 6.0
    local myAfter = myHp - enSoon - R.enDps * (T - 2.5)
    local enAfter = enEffHpSoon - mySoon - R.myDps * (T - 2.5)
    R.edgeLong = myAfter - enAfter
    local cfgD = C.DEFENSE or {}
    R.weaker = (R.edgeLong < -(cfgD.WEAKER_EDGE or 120))
        or (R.ttkMe < R.ttkHim * 0.65 and R.edge < 0)
    R.weakerSustained = R.ttkMe < R.ttkHim * (cfgD.SUSTAINED_TTK_RATIO or 0.8)
    R.losingHard = R.heCanKillSoon or (R.edgeLong <= -180 and not R.canKillSoon)
        or (R.ttkMe < R.ttkHim * 0.62 and not R.canKillSoon)
    R.minSafeDist = K.EnemyMinSafeDistance(enemy, 2.5)
    R.oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
    R.twoRaze = K.EnemyRazeDamage(bot, enemy, 2)
    R.threeRaze = K.EnemyRazeDamage(bot, enemy, 3)
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    R.enemyFaster = enMS > myMS + 5
    R.heHasBootsLead = (enMS - myMS) >= 25
    R.myHpPct = myHp / math.max(1, bot:GetMaxHealth() or 1)
    R.enemyHpPct = enHp / math.max(1, enemy:GetMaxHealth() or 1)
    R.myPotMana = U.GetPotentialManaForRaze(bot)
    R.enPotMana = U.GetPotentialManaForRaze(enemy)
    R.bothDry = R.myPotMana < ((C.PARITY and C.PARITY.DRY_MANA) or 75)
        and R.enPotMana < ((C.PARITY and C.PARITY.DRY_MANA) or 75)
    R.levelDiff = (bot:GetLevel() or 1) - (enemy:GetLevel() or 1)
    R.enemyBandHere = K.EnemyReadyBandAt(enemy, dist, 1.0)
    R.spellWindow, R.windowMyRazes, R.windowEnemyRazes, R.windowDamage, R.windowIncoming, R.cooldownWindow = K.SpellTradeWindow(bot, enemy, s)
    R.valid = true

    -- v4.3.3 Equal-resource lane hold. This is NOT a licence to stand in lethal burst:
    -- it only stops the old absolute-HP fear from conceding a symmetric dry / equal-mana trade.
    local pcfg = C.PARITY or {}
    R.parityHold = pcfg.ENABLED ~= false
        and R.levelDiff >= 0
        and not R.heCanKillNow and not R.heCanKillSoon
        and not R.losingHard and not R.uphillPenalty
        and not R.heHasBootsLead
        and (R.hisTowerOnMe or 0) <= 0
        and myHp >= (pcfg.MIN_HP or 150)
        and dist <= (pcfg.MAX_DIST or 1000)
        and math.abs(R.myHpPct - R.enemyHpPct) <= (pcfg.HP_SHARE_TOL or 0.18)
        and (R.bothDry or (R.myPotMana >= 75 and R.enPotMana >= 75))
        and R.ttkMe >= R.ttkHim * (pcfg.TTK_RATIO or 0.88)
    return R
end

-- Chasing

-- Can the distance be closed to neededDist in a reasonable time.
-- An enemy with equal/greater speed running away from us - uncatchable.
function K.CanCatch(bot, enemy, neededDist, maxTime)
    if not U.CanQuery(enemy) then return false end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d <= neededDist + 60 then return true end
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local vx, vy = 0, 0
    if enemy.GetVelocity then
        local v = enemy:GetVelocity()
        if v then vx, vy = v.x or 0, v.y or 0 end
    end
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 40 then
        -- Standing still: we catch him if the distance is reasonable
        return (d - neededDist) / myMS <= (maxTime or 2.5)
    end
    local ax, ay = (enLoc.x - botLoc.x) / d, (enLoc.y - botLoc.y) / d
    local awaySpeed = vx * ax + vy * ay -- >0: running away from us
    if awaySpeed > 0.4 * speed then
        local closing = myMS - awaySpeed
        if closing <= 15 then return false end
        return (d - neededDist) / closing <= (maxTime or 2.5)
    end
    -- Walking toward us / sideways
    return (d - neededDist) / (myMS + math.max(0, -awaySpeed)) <= (maxTime or 2.5)
end

-- Is the enemy moving away from us (fleeing)?
function K.IsEnemyMovingAway(bot, enemy)
    if not U.CanQuery(enemy) or not enemy.GetVelocity then return false end
    local v = enemy:GetVelocity()
    if not v then return false end
    local speed = math.sqrt((v.x or 0) ^ 2 + (v.y or 0) ^ 2)
    if speed < 60 then return false end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d < 1 then return false end
    local ax, ay = (enLoc.x - botLoc.x) / d, (enLoc.y - botLoc.y) / d
    return (v.x * ax + v.y * ay) > 0.5 * speed
end

-- Hook for utils (utils cannot require combat because of the cycle)
U._K = K

return K
