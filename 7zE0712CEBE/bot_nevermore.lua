
-- Nevermore Bot v4.3.5-supply — lane presence vs dry/out-of-reach rival, under-tower prep, free raze vs dry enemy, core-item gold reserve
local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")
local L = require("bots/nevermore/lasthit")
local P = require("bots/nevermore/positioning")
local K = require("bots/nevermore/combat")
local W = require("bots/nevermore/world")
local LN = require("bots/nevermore/lane")
local I = require("bots/nevermore/intent")
local WV = require("bots/nevermore/wave")
local T = require("bots/nevermore/tempo")

-- Simulation-only diagnostics: counts every gate of the free-pressure handlers. Outside the
-- simulator (no BOT_SIM_PROBE global) this compiles to a no-op, so the shipped bot pays nothing.
local function FDBG(k)
    if not _G.BOT_SIM_PROBE then return end
    local d = _G.__freeDbg
    if not d then d = {}; _G.__freeDbg = d end
    d[k] = (d[k] or 0) + 1
end

-- Load marker: if this line is missing from the console the file did not load
-- and the stock Valve bot plays instead (look for [VScript] errors).
print("[SF-BOT] bot_nevermore.lua loaded (v4.3.4-lane: lane-presence+under-tower-prep+free-raze-vs-dry+core-gold-reserve)")

U.DEBUG = false

-- All handlers live in the H table instead of being local functions: works around the
-- Lua 5.1 limit of 60 upvalues per function (otherwise the file does not compile in Dota).
local H = {}

local SAFE_DISTANCE = C.SAFE_DISTANCE or {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}


local State = {
    hunting                   = false, -- Hunting (see H.ComputeHunt)
    attackTarget              = nil,
    attackStartTime           = 0,
    deaggroTime               = 0,
    prepTarget                = nil,
    prepTargetTime            = 0,
    lhAttackTarget            = nil,
    defensive                 = false,
    defensiveSince            = 0,
    enemyAggroCount           = 0,
    tpOrderTime               = 0,
    flyingProjectiles         = {},
    firedThisAttack           = false,
    lastAggroTime             = 0,
    aggroPullTime             = 0,
    lastItemUseTime           = 0,
    lastHarassTime            = 0,
    needsTP                   = false,
    tpOrderTime               = -100,
    -- Commitment to "finish" or "run" (prevents fight<->flee flapping)
    commitKillUntil           = 0,
    fleeUntil                 = 0,
    -- Enemy is teleporting to its T1 (TP channel visible / respawned after death)
    enemyTPIncomingUntil      = 0,
    enemyWasAlive             = true,
    aimingRaze                = nil,
    aimingTarget              = nil,
    aimingLoc                 = nil,
    aimingStartTime           = 0,
    aimingValidationRadius    = nil,
    forcedRetreatLoc          = nil,
    forcedRetreatUntil        = 0,
    -- Commitment to walk out of the enemy T1 (point + deadline)
    towerEscapeLoc            = nil,
    towerEscapeUntil          = 0,
    nearChainUntil            = 0, -- Window for the follow-up raze chain after punishing an enemy that walked up to us
    lastMoveLoc               = nil,
    lastMoveTime              = 0,
    emergencyRetreat          = nil,
    emergencyRetreatStartTime = 0,
    emergencyTPQueued         = false,
    glyphUsedForDive          = false,
    glyphDiveTime             = 0,
    lastForceSalveTime        = 0,
    enemyT1ClosestCreepDist   = nil,
    enemyT1ClosestCreepTime   = 0,
    actionTaken               = false,
    holdPos = false,
    goingToFountain           = false,
    fountainReason            = nil,
    enemyReachedLevel2First   = false,
    heroAttackTarget          = nil,
    heroAttackTime            = 0,
    -- v4.3.3 one-shot delayed reply tokens (enemy action -> our answer after the sacred CS)
    heroReplyEnemy            = nil,
    heroReplyAttackTime       = -100,
    heroReplyRazeTime         = -100,
    heroReplyRazeHit          = -100,
    heroReplyAnsweredAttack   = false,
    heroReplyAnsweredRaze     = false,
    _lastSalveAutoBuyTime     = 0,
    -- Tango: sticky tree choice (fixes oscillating between trees)
    tangoTree                 = nil,
    tangoCastAt = 0,
    tangoFails = 0,
    tangoTreeLoc              = nil,
    tangoChosenAt             = 0,
    tangoBestDist             = math.huge,
    tangoBadTree              = nil,
    tangoBadTreeTime          = 0,
    -- Dodging the enemy raze
    dodgeLoc                  = nil,
    dodgeUntil                = 0,
    -- Intent and context
    intent                    = "FARM",
    lastIntentPrint           = 0,
    siegeWaitUntil            = 0,
}

-- Context for the intent FSM (reused, no per-tick allocation)
local IntentCtx = {
    enemy = false, race = nil, myHpPct = 1, myRazes = 0, healing = false,
    enemyDist = 99999, enemyDistToWave = 99999, enemyAbsent = false,
    enemyUnderHisTower = false, canCatch = true, underEnemyTower = false,
}

-- Hook for utils (glyph for a dive): "we are really committing" = aiming a raze / hit a hero <= 1 s ago
U._State = State -- Test hook: State access from the tooling
U._engagedCheck = function(bot, enemy)
    if State.aimingRaze then return true end
    if (GameTime() - (State.heroAttackTime or -10)) <= 1.0 then return true end
    return false
end

-- force=true: micro-steps (turning for a raze, dodging) must not be swallowed by deduplication.
function H.SmartMove(bot, loc, threshold, force, stackAbility)
    if not loc then return false end
    if State.actionTaken then return false end
    -- Smooth tangential obstacle & tower hull steering on real navigation moves (`> 55u`, never altering micro-turns!)
    if not force then
        loc = U.SteerAroundObstacles(bot, loc, W.s)
    end
    local enemy = H._enemyHeroNear
    if enemy and not State.forcedRetreatLoc and not State.survivalLoc and not State.towerEscapeLoc
        and not K.StackLeadStepSafe(bot, enemy, loc)
        and not H.StackLeadThirdRazeOK(bot, enemy, stackAbility, loc, W.s) then return false end
    threshold = threshold or 60
    local now = GameTime()
    local last = State.lastMoveLoc
    if force then
        if last and (now - State.lastMoveTime) < 0.1 and U.DistanceBetweenLocations(last, loc) <= 4 then
            State.actionTaken = true
            return true
        end
    elseif last and U.DistanceBetweenLocations(last, loc) <= threshold and (now - State.lastMoveTime) < 0.6 then
        -- A move order to this point was already issued recently: treat it as in progress (actionTaken),
        -- otherwise the next handler overrides it and everything
        -- reverses on the next tick - the classic oscillation between two points.
        State.actionTaken = true
        return true
    end
    State.lastMoveLoc = loc
    State.lastMoveTime = now
    bot:Action_MoveToLocation(loc)
    State.actionTaken = true
    return true
end

function H.ClearMoveCache()
    State.lastMoveLoc = nil
    State.lastMoveTime = 0
end

function H.ClearRazeState()
    State.shortCombatCast = nil
    State.aimingRaze = nil
    State.aimingTarget = nil
    State.aimingLoc = nil
    State.aimingStartTime = 0
    State.aimingValidationRadius = nil
    State.aimingFollowup = nil
end

function H.StartRazeCast(ability, target, loc, validationRadius, isCS)
    State.aimingFollowup = nil
    State.lastRazeOrderTime = GameTime()
    local isHeroTarget = target and target.IsHero and target:IsHero()
    if isHeroTarget and U.CanQuery(target) then
        local age = U.GetRecentEnemyRazeHitAge(target)
        if age <= C.RAZE.MIRROR_INSTANT_SEC then
            State.mirrorAnsweredEnemy = target
            State.mirrorAnsweredHit = GameTime() - age
        end
        local data = U.GetRazeAbilityData(ability)
        local chain = State.razeFollowup
        if chain and chain.enemy == target and GameTime() <= chain.untilTime then
            State.aimingFollowup = chain
            State.razeFollowup = nil -- The second cast consumes, never renews, this plan.
        elseif data and (data.label == "far" or data.label == "mid") then
            State.razeFollowup = {
                enemy = target, label = data.label == "far" and "mid" or "far",
                opened = GameTime(), untilTime = GameTime() + 2.5,
                stacks = U.GetShadowrazeDebuff(target),
            }
        end
    end
    State.aimingRaze = ability
    State.aimingTarget = target
    State.aimingLoc = loc
    State.aimingStartTime = GameTime()
    State.aimingValidationRadius = validationRadius or C.RAZE.HIT_RADIUS
    State.aimingIsCS = (isCS == true) or (target ~= nil and not isHeroTarget)
    State.actionTaken = true
end

function H.HandleActiveRazeValidation(bot)
    if not State.aimingRaze then return false end
    local now = GameTime()
    if bot:IsUsingAbility() or bot:IsChanneling() then
        local elapsed = now - State.aimingStartTime
        -- Do not cancel a completed cast just because the target moves during backswing.
        if elapsed >= C.RAZE.CAST_POINT and not State.aimingRaze:IsInAbilityPhase() then
            H.ClearRazeState()
            return false
        end
        local remaining = math.max(0, C.RAZE.CAST_POINT - elapsed)

        local data = U.GetRazeAbilityData(State.aimingRaze)
        if not data then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        -- Check whether live enemy hero still lands inside this exact coil (`<= 238u` of live center)
        -- Check whether live enemy hero (visible OR just stepped into river/highground FoW `<= 0.85s` ago while still alive!)
        -- lands inside this exact coil (`<= 244u` of live center), OR another enemy creep is killable inside this coil!
        local enemyNow = H._enemyHeroNear
        local enemyHitByCoil = false
        if enemyNow and U.CanQuery(enemyNow) and enemyNow:IsAlive() and (enemyNow:GetHealth() or 0) > 0 then
            local eNowLoc = enemyNow:GetLocation()
            local ePred = U.PredictPosition(enemyNow, remaining + (C.RAZE.LAND_LEAD or 0.08))
            if U.GetRazeHitErrorWithCurrentFacing(bot, ePred, data.center) <= (C.RAZE.HIT_RADIUS - 6)
                or U.GetRazeHitErrorWithCurrentFacing(bot, eNowLoc, data.center) <= (C.RAZE.HIT_RADIUS - 14) then
                enemyHitByCoil = true
            end
        elseif W.s and W.s.enemyAlive ~= false and (W.s.enemyAbsentFor or 99) <= 0.85 and W.s.enemyLastLoc then
            if U.GetRazeHitErrorWithCurrentFacing(bot, W.s.enemyLastLoc, data.center) <= (C.RAZE.HIT_RADIUS - 8) then
                enemyHitByCoil = true
            end
        end

        local otherKillableCreepInCoil = false
        if State.aimingIsCS and W.s and W.s.enemyCreeps then
            local rawBase = 30 + 60 * (State.aimingRaze:GetLevel() or 1)
            for _, oc in pairs(W.s.enemyCreeps) do
                if oc ~= State.aimingTarget and U.CanQuery(oc) and oc:IsAlive() and (oc:GetHealth() or 0) > 0 then
                    local magicDmg = math.floor(oc:GetActualIncomingDamage(rawBase, DAMAGE_TYPE_MAGICAL))
                    if (oc:GetHealth() or 9999) <= magicDmg
                        and U.GetRazeHitErrorWithCurrentFacing(bot, oc:GetLocation(), data.center) <= (C.RAZE.HIT_RADIUS - 8) then
                        otherKillableCreepInCoil = true
                        break
                    end
                end
            end
        end

        -- `9056774541.dem` `03:07.63` (`tk=12138 -> 12150`) Fix:
        --   1. When a river/staircase creep dies mid-cast, the enemy hero in the river drops into Highground Fog of War
        --      (`U.CanQuery(State.aimingTarget) == false` EVEN THOUGH `W.s.enemyAlive == true` and they are `118u` inside our coil!).
        --      NEVER S-cancel a hero Shadowraze when the hero just entered FoW while still alive inside the coil!
        --   2. NEVER S-cancel a Dual-Value CS coil when `enemyHitByCoil` OR `otherKillableCreepInCoil` holds!
        local aimingHeroRef = (State.aimingTarget ~= nil) and (not State.aimingIsCS)
        local tgtAlive = U.CanQuery(State.aimingTarget)
            and State.aimingTarget:IsAlive()
            and (State.aimingTarget:GetHealth() or 0) > 0
        if not tgtAlive then
            if enemyHitByCoil or otherKillableCreepInCoil
                or (aimingHeroRef and W.s and W.s.enemyAlive ~= false and (W.s.enemyAbsentFor or 99) <= 0.85) then
                return true
            end
            State.mirrorAnsweredHit = nil
            State.razeFollowup = State.aimingFollowup
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        local predicted = U.PredictPosition(State.aimingTarget, remaining + (C.RAZE.LAND_LEAD or 0.08))
        local error = U.GetRazeHitErrorWithCurrentFacing(bot, predicted, data.center)
        local limit = math.min(State.aimingValidationRadius or C.RAZE.HIT_RADIUS, C.RAZE.HIT_RADIUS) - 10

        -- For Dual-Value CS coils: NEVER abort if enemyHero is inside the coil (`enemyHitByCoil`)!
        if error > limit and not (State.aimingIsCS and (enemyHitByCoil or otherKillableCreepInCoil)) then
            State.mirrorAnsweredHit = nil -- A cancelled cast has not answered the hit.
            State.razeFollowup = State.aimingFollowup
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
        end
        return true
    end

    if now > State.aimingStartTime + 1.0 then
        H.ClearRazeState()
    end

    return false
end

function H.SafeClearActions(bot)
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    bot:Action_ClearActions(true)
    H.ClearMoveCache()
    return true
end

-- Power Treads (`v4.0.0` Combat `STR` Lock — fixes `0119` `tk=14981` `-220 HP` mid-duel Treads drop!):
-- * In ANY hero combat proximity (`enemyDist <= 1250u`) or below `78% HP`, LOCK Power Treads on `STR` (`+220 HP`)!
-- * NEVER drop `STR -> INT` mid-fight (`enemyDist <= 1150u` & `hpPct < 0.68`) when `bot:GetMana() >= 85` already covers the raze!
-- * Free-farm (`enemyDist > 1250u` & `hpPct >= 0.80`): stay on `AGI` (`+10` damage & `+10` attack speed).
function H.ManageTreads(bot, mode)
    if not U.HasItem(bot, "item_power_treads") then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.TREADS or {}
    local opts = nil
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = (bot:GetHealth() or 0) / maxHp
    local enemyDist = (W and W.s and W.s.enemy and U.CanQuery(W.s.enemy) and W.s.enemy:IsAlive())
        and (W.s.enemyDist or GetUnitToLocationDistance(bot, W.s.enemy:GetLocation()))
        or 9999
    if mode == "CAST" then
        -- Do NOT strip `-220` max/effective HP in close combat unless `INT` mana pool is strictly required to reach `75 MP`!
        if enemyDist <= 1150 and hpPct < 0.68 and (bot:GetMana() or 0) >= 85 then
            return U.UpdatePowerTreads(bot, "SURVIVE", { oneUseOnly = true })
        end
        opts = { oneUseOnly = true }
    elseif mode == nil then
        if hpPct < math.max(cfg.SURVIVE_HP_PCT or 0.30, 0.78)
            or enemyDist <= 1250
            or State.intent == I.RETREAT
            or State.emergencyRetreat then
            mode = "SURVIVE"
        elseif U.IsAttackingAction(bot) or hpPct >= 0.80 then
            mode = "FIGHT"
            opts = { hold = cfg.MODE_HOLD or 1.0 }
        else
            mode = "SURVIVE"
        end
    end
    return U.UpdatePowerTreads(bot, mode, opts)
end

function H.BeginForcedRetreat(bot, loc, duration)
    if not loc then return false end
    local now = GameTime()
    local bLoc = bot:GetLocation()
    -- Project short retreat targets cleanly AND steer around T1 tower hulls & creep walls (`v4.2.0` `Demo 1` `2:47` & `4:10` Fix!)
    local stepDist = U.DistanceBetweenLocations(bLoc, loc)
    if stepDist < 220 then
        local fnt = P.GetFountain(bot)
        local dir = (stepDist > 4) and (loc - bLoc):Normalized() or (fnt - bLoc):Normalized()
        loc = bLoc + dir * 240
    end
    local same = State.forcedRetreatLoc ~= nil
        and U.DistanceBetweenLocations(State.forcedRetreatLoc, loc) <= 120
        and now < (State.forcedRetreatUntil or 0)
    State.forcedRetreatLoc = loc
    State.forcedRetreatUntil = math.max(State.forcedRetreatUntil or 0, now + (duration or 0.65))
    State.fleeUntil = math.max(State.fleeUntil or 0, now + 1.2)
    State.actionTaken = true
    if not same then
        -- Switch Power Treads to STR on tick 1 WITHOUT poisoning `State.lastMoveLoc`!
        if H.ManageTreads(bot, "SURVIVE") then
            State.lastMoveLoc = nil
            State.lastMoveTime = 0
            return true
        end
        if bot:IsUsingAbility() then
            bot:Action_ClearActions(true)
        end
    end
    local movePt = U.SteerAroundObstacles(bot, loc, W.s)
    State.lastMoveLoc = movePt
    State.lastMoveTime = now
    bot:Action_MoveToLocation(movePt)
    return true
end

function H.TickForcedRetreat(bot, s)
    if not State.forcedRetreatLoc then return false end
    local now = GameTime()
    if now >= (State.forcedRetreatUntil or 0) then
        H.ClearForcedRetreat()
        return false
    end
    local bLoc = bot:GetLocation()
    local remDist = U.DistanceBetweenLocations(bLoc, State.forcedRetreatLoc)
    -- Zero-Stall Arrival Rule: NEVER stand idle at `forcedRetreatLoc` waiting for timer expiry!
    if remDist <= 65 then
        local enemy = s and s.enemy
        if enemy and U.CanQuery(enemy) and U.EnemyApproachSpeed(bot, enemy) > 45
            and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 860 then
            local fnt = P.GetFountain(bot)
            local ext = bLoc + (fnt - bLoc):Normalized() * 280
            State.forcedRetreatLoc = ext
            local movePt = U.SteerAroundObstacles(bot, ext, s or W.s)
            State.lastMoveLoc = movePt
            State.lastMoveTime = now
            bot:Action_MoveToLocation(movePt)
            State.actionTaken = true
            return true
        end
        H.ClearForcedRetreat()
        return false
    end
    return H.SmartMove(bot, State.forcedRetreatLoc, 60)
end

function H.ClearForcedRetreat()
    State.forcedRetreatLoc = nil
    State.forcedRetreatUntil = 0
end

-- Commitment to walk out of the enemy tower (see HandleEnemyTowerSafety)
function H.ClearTowerEscape()
    State.towerEscapeLoc = nil
    State.towerEscapeUntil = 0
end

-- Central level-deficit gate for hero pressure. Last hits and defensive razes are unaffected.
function H.LevelDeficitBlocksHeroAction(bot, enemy, projectedDamage, allowReactive)
    if not bot or not enemy or not enemy.IsHero or not enemy:IsHero() then return false end
    local deficit = (enemy:GetLevel() or 1) - (bot:GetLevel() or 1)
    if deficit <= 0 then return false end
    local cfg = C.LEVEL_DEFICIT or {}
    local enemyDry = (enemy:GetMana() or 0) < (cfg.DRY_MANA_THRESHOLD or 75)
    local hpLead = (bot:GetHealth() or 0) - (enemy:GetHealth() or 0)
    local creepsOnMe = 0
    for _, c in pairs(bot:GetNearbyLaneCreeps(230, true) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c.GetAttackTarget and c:GetAttackTarget() == bot then creepsOnMe = creepsOnMe + 1 end
    end
    local towerHelp = false
    for _, t in pairs(bot:GetNearbyTowers(900, false) or {}) do
        if U.CanQuery(t) and t:IsAlive() and t.GetAttackTarget and t:GetAttackTarget() == enemy then towerHelp = true end
    end
    local effHp = (enemy:GetHealth() or 0) + (U.HasItem(enemy, "item_faerie_fire") and 85 or 0) + U.GetStickCharges(enemy) * 15
    local lethal = projectedDamage and projectedDamage >= effHp
    -- Do not initiate casual pressure while behind, but allow a reactive raze after the enemy commits.
    -- This prevents the replay failure mode where the bot dies with full mana because every hero raze is gated.
    -- At -1 level a reactive reply is always allowed; at -2+ it is allowed when our tower is already helping.
    if allowReactive and (deficit == 1 or towerHelp) then return false end
    if deficit >= 2 then
        return not (lethal or (towerHelp and enemyDry and creepsOnMe <= (cfg.DRY_MAX_CREEPS_ON_ME or 1)))
    end
    return not (lethal or (enemyDry and hpLead >= (cfg.DRY_HP_LEAD or 120)
        and creepsOnMe <= (cfg.DRY_MAX_CREEPS_ON_ME or 1)))
end

function H.CastOrTurnRaze(bot, ability, actionType, aimLoc, target)
    if State.combatPolicyActive == true and target and target.IsHero and target:IsHero()
        and not State.heroCombatAllowed then return false end
    if not ability or (target and not U.CanQuery(target)) then return false end
    if target and State.towerChaseBlockedEnemy == target then return false end
    if target and target.IsHero and target:IsHero() then
        local reactive = false
        local stacks, remain = U.GetShadowrazeDebuff(bot)
        if (stacks and stacks > 0 and (remain or 0) > 0)
            or (K.EnemyPhase and K.EnemyPhase() ~= nil)
            or (bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(2.5)) then
            reactive = true
        end
        if H.LevelDeficitBlocksHeroAction(bot, target, K.MyRazeDamage(bot, target, 1), reactive) then return false end
    end
    if target and K.HasRazeStackLead(bot, target) then
        local distance = GetUnitToLocationDistance(bot, target:GetLocation())
        if K.EnemyBandsAcross(target, distance, distance, 0.7) > 0
            and not H.StackLeadThirdRazeOK(bot, target, ability, bot:GetLocation(), W.s) then return false end
    end
    if State.actionTaken then return false end
    -- Every path that decided "CAST" goes through the facing check (see H.RazeFacingOK); otherwise TURN
    if actionType == "CAST" and aimLoc and not H.RazeFacingOK(bot, aimLoc) then
        actionType = "TURN"
    end

    local data = U.GetRazeAbilityData(ability)
    if data and target and U.CanQuery(target) then
        local isHeroTarget = target.IsHero and target:IsHero()
        -- `v4.2.0` Strict Raw-Velocity Reach & Anti-Creep-Sliver Gate (`Demo 1` `0:44.47` `d=1050u` & `Demo 2` `0:47.67` `3 HP` Fix!)
        if isHeroTarget then
            if not U.WillRazeStrictlyCoverMovingTarget(bot, ability, target) then
                return false
            end
            if U.HeroRazeRuinsCreepCS(bot, ability, aimLoc, target, W.s) then
                return false
            end
        end
        -- Check the band against both the current and the predicted position (aimLoc): the raze lands
        -- 0.55 s later and an approaching enemy changes band in that time.
        local distNow = GetUnitToLocationDistance(bot, target:GetLocation())
        local errNow = math.abs(distNow - data.center)
        local errPred = errNow
        if aimLoc then
            errPred = math.abs(GetUnitToLocationDistance(bot, aimLoc) - data.center)
        end
        if math.min(errNow, errPred) > C.RAZE.STRICT_RADIUS + 25 then
            return false
        end
    end

    if actionType == "TURN" then
        -- Guard against an endless turn: turning 180 degrees takes ~0.1 s,
        -- so TURNing for over 0.45 s means something does not add up (target on the circle edge etc.);
        -- then TURN razes are blocked for 1 s and control goes back to the rest of the logic.
        local now = GameTime()
        if now < (State.razeTurnBlockUntil or 0) then return false end
        if (now - (State.lastTurnTick or -10)) > 0.25 then State.turnSince = now end
        State.lastTurnTick = now
        if (now - (State.turnSince or now)) > 0.45 then
            State.razeTurnBlockUntil = now + 1.0
            State.turnSince = now
            return false
        end
        local botLoc = bot:GetLocation()
        local turnLoc = aimLoc or (target and target:GetLocation()) or botLoc
        local dist = U.DistanceBetweenLocations(botLoc, turnLoc)
        local stepLoc = turnLoc
        -- Turn step 40 u (was 12): too short an order could be executed by the engine without
        -- turning the hero fully; 40 u = ~0.13 s of walking and the cast on the next tick stops it
        local step = (C.RAZE.TURN_STEP or 40)
        if dist > step + 10 then
            local dir = (turnLoc - botLoc):Normalized()
            stepLoc = botLoc + dir * step
        end
        return H.SmartMove(bot, stepLoc, 20, true, ability)
    elseif actionType == "CAST" then
        -- Every caller, including mirror/finish shortcuts, must cover the landing point.
        if data and target and U.CanQuery(target) then
            local landing = U.PredictPosition(target, C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08))
            if U.GetRazeHitErrorWithCurrentFacing(bot, landing, data.center) > C.RAZE.HIT_RADIUS - 10 then
                return false
            end
        end
        -- Before a raze switch Power Treads to intelligence (bigger mana pool -> more mana
        -- left after the cast). The order takes this tick, the cast follows on the next one.
        if H.ManageTreads(bot, "CAST") then
            State.actionTaken = true
            return true
        end
        bot:Action_UseAbility(ability)
        H.StartRazeCast(ability, target, aimLoc, C.RAZE.HIT_RADIUS)
        H.ClearMoveCache()
        return true
    end

    return false
end

-- Single facing check before the cast. An untargeted raze flies where the hero is LOOKING at
-- the start of the cast; "the circle covers the enemy at the current facing" (errFacing <= 220) allowed
-- a cast with an error of up to ~18 degrees on the far band - and any step by the enemy meant a miss
-- ("the bot turned slightly left/right and missed"). Now CAST only if the angle between
-- the look direction and the aim point <= MAX_ANGLE_TO_CAST; otherwise TURN (0.03-0.1 s).
function H.RazeFacingOK(bot, aimLoc)
    if not aimLoc then return true end
    local maxAng = (C.RAZE.MAX_ANGLE_TO_CAST or 6)
    return U.GetAngleDifference(bot, aimLoc) <= maxAng
end



function H.GetRazeAbilityByLabel(bot, label)
    if label == "near" then return bot:GetAbilityByName("nevermore_shadowraze1") end
    if label == "mid"  then return bot:GetAbilityByName("nevermore_shadowraze2") end
    if label == "far"  then return bot:GetAbilityByName("nevermore_shadowraze3") end
    return nil
end

-- Sort `{ "near", "mid", "far" }` in ascending order of `|predDist - center|` (`9055695956.dem` `tk=12868` `5:28` fix!):
-- At `dist = 663.9u`, `|663.9 - 700| = 36.1u` (`far` dead-center bullseye!) strictly beats `|663.9 - 450| = 213.9u`
-- (`mid` razor-edge that `S`-cancelled when enemy stepped `30u` back!). Reuses a static 3-slot array (zero GC churn).
local _CENTERED_ORDER = { "near", "mid", "far" }
function H.BestCenteredRazeOrder(bot, target)
    local d = 450
    if bot and target and U.CanQuery(target) then
        local pred = U.PredictPosition(target, C.RAZE.CAST_POINT or 0.55)
        d = GetUnitToLocationDistance(bot, pred or target:GetLocation())
    end
    local eNear = math.abs(d - 200)
    local eMid  = math.abs(d - 450)
    local eFar  = math.abs(d - 700)
    if eNear <= eMid and eNear <= eFar then
        _CENTERED_ORDER[1] = "near"
        if eMid <= eFar then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "mid", "far"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "far", "mid" end
    elseif eMid <= eNear and eMid <= eFar then
        _CENTERED_ORDER[1] = "mid"
        if eNear <= eFar then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "near", "far"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "far", "near" end
    else
        _CENTERED_ORDER[1] = "far"
        if eMid <= eNear then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "mid", "near"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "near", "mid" end
    end
    return _CENTERED_ORDER
end

-- Robust: CAST if at the current facing the circle covers the enemy both now and
-- after the cast time; TURN toward the aim point if it covers after turning; otherwise nil.
function H.GetRazeActionType(bot, ability, target)
    if not ability or not target or not U.CanQuery(target) then return nil, nil end
    local data = U.GetRazeAbilityData(ability)
    if not data then return nil, nil end
    local errAim, errFacing, aim = U.RobustRazeErrors(bot, target, data.center, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30)
    -- The cast threshold equals the candidate threshold. Different thresholds (CAST <= limit-15, TURN <= limit) created
    -- a dead zone: after turning, errFacing == errAim in (limit-15, limit] -> the cast never
    -- goed through while TURN was issued every tick (12 u step) -> the bot jittered in place forever.
    -- CAST = the circle covers AND the hero faces the aim point (angle <= MAX_ANGLE_TO_CAST);
    -- covers only after turning -> TURN
    if errFacing <= limit and H.RazeFacingOK(bot, aim) then return "CAST", aim end
    if errAim <= limit then return "TURN", aim end
    return nil, aim
end

function H.GetStickLikeItem(bot)
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and (not wand.GetCurrentCharges or wand:GetCurrentCharges() > 0) then return wand end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and (not stick.GetCurrentCharges or stick:GetCurrentCharges() > 0) then return stick end
    return nil
end

function H.GetPotentialCombatMana(bot)
    return U.GetPotentialManaForRaze(bot)
end

function H.TryUseBurstManaItem(bot, allowMango)
    local item = H.GetStickLikeItem(bot)
    if not item and allowMango then
        item = U.GetActiveItemByName(bot, "item_enchanted_mango")
    end
    if not item then return false end
    bot:Action_UseAbility(item)
    State.lastItemUseTime = GameTime()
    State.actionTaken = true
    return true
end

function H.IsInHeroAttackAnimation(bot)
    if not State.heroAttackTarget then return false end
    if not State.heroAttackTarget:IsAlive() then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local target = bot:GetAttackTarget()
    if target ~= State.heroAttackTarget then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local elapsed = GameTime() - State.heroAttackTime
    local bat = bot:GetSecondsPerAttack() or 1.7
    if elapsed < bat + 0.1 then
        return true
    end
    State.heroAttackTarget = nil
    State.heroAttackTime = 0
    return false
end

function H.IsSameAttackTarget(bot, target)
    return U.IsAttackingAction(bot) and bot:GetAttackTarget() == target
end

function H.IssueHeroAttack(bot, enemyHero, allowReactive)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.towerChaseBlockedEnemy == enemyHero then return false end
    local distance = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local myRange = (bot.GetAttackRange and bot:GetAttackRange()) or 500
    if H.LevelDeficitBlocksHeroAction(bot, enemyHero, K.AttackDamageVs(bot, enemyHero), allowReactive) then return false end
    -- Backswing Uphill Orb-Walk (`0.000s` DPS loss!):
    -- While right-click is cooling down in backswing (`remAtkCD > 0.16`), step uphill onto equal elevation (`z >= enemy`)
    -- inside attack range so subsequent attacks never suffer the `25%` Source 2 river-to-highground miss penalty!
    if type(GetHeightLevel) == "function" then
        local bLocNow, eLocNow = bot:GetLocation(), enemyHero:GetLocation()
        if GetHeightLevel(bLocNow) < GetHeightLevel(eLocNow) then
            local lastAtkT = (bot.GetLastAttackTime and bot:GetLastAttackTime()) or -100
            local spaNow = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.2
            local apNow = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.5
            local sinceAtk = GameTime() - lastAtkT
            local inBackswingWindow = (lastAtkT > 0) and (sinceAtk > 0.04) and ((spaNow - sinceAtk) > (apNow + 0.10))
            if inBackswingWindow then
                local hgOrb = P.AvoidUphillMiss(bot, bLocNow, eLocNow, myRange - 15)
                if hgOrb and GetHeightLevel(hgOrb) >= GetHeightLevel(eLocNow)
                    and U.DistanceBetweenLocations(bLocNow, hgOrb) > 10 then
                    H.SmartMove(bot, hgOrb, 15)
                    State.heroAttackTarget = enemyHero
                    State.heroAttackTime = GameTime()
                    return true
                end
                -- If own ramp is out of range, orb-walk directly up enemy's highground lip when winning all-in!
                if distance > 180 and ((bot:GetHealth() or 0) >= 120) then
                    H.SmartMove(bot, eLocNow, 25)
                    State.heroAttackTarget = enemyHero
                    State.heroAttackTime = GameTime()
                    return true
                end
            end
        end
    end
    if K.HasRazeStackLead(bot, enemyHero) and distance > myRange + 15 then
        if K.EnemyBandsAcross(enemyHero, distance, distance, 0.7) > 0 then return false end
        local stop = enemyHero:GetLocation() + (bot:GetLocation()-enemyHero:GetLocation()):Normalized()
            * math.min(distance, myRange)
        if not K.StackLeadStepSafe(bot, enemyHero, stop) then return false end
    end
    local sameTarget = H.IsSameAttackTarget(bot, enemyHero)
    if not sameTarget then
        bot:Action_AttackUnit(enemyHero, true)
        H.ClearMoveCache()
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.heroAttackTarget = enemyHero
        State.heroAttackTime = GameTime()
        State.firedThisAttack = false
    elseif State.attackTarget ~= enemyHero then
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    State.heroAttackTarget = enemyHero
    if not State.heroAttackTime or State.heroAttackTime <= 0 then State.heroAttackTime = GameTime() end
    return true
end

-- The attack animation detector uses the ANIMATION (GetAnimActivity/GetAnimCycle), not the order time:
-- the attack order is issued 0-1 s before the real swing (the hero is still walking/turning),
-- so an order-time lock expired before the actual swing and the next
-- handler (creep aggro drop, last hit, raze turn, positioning) cancelled the attack a fraction
-- of a second before the attack point. Called every tick before decisions are made.
function H.UpdateAttackActivity(bot)
    local now = GameTime()
    local act, cyc = nil, nil
    if bot.GetAnimActivity then
        local ok, a = pcall(bot.GetAnimActivity, bot)
        if ok and type(a) == "number" then act = a end
    end
    if act == nil then
        State.atkAnimAvailable = false
        State.atkAnimSince = nil
        return
    end
    if bot.GetAnimCycle then
        local ok, c = pcall(bot.GetAnimCycle, bot)
        if ok and type(c) == "number" then cyc = c end
    end
    State.atkAnimAvailable = true
    local A1 = _G.ACTIVITY_ATTACK or 1503
    local A2 = _G.ACTIVITY_ATTACK2 or 1504
    local A3 = _G.ACTIVITY_ATTACK_EVENT or 1505
    local isAtk = (act == A1 or act == A2 or act == A3)
    if isAtk then
        local restarted = cyc and State.atkAnimCycle and (cyc < State.atkAnimCycle - 0.05)
        if not State.atkAnimSince or restarted then State.atkAnimSince = now end
    else
        State.atkAnimSince = nil
    end
    State.atkAnimCycle = cyc
end

-- Is a right-click swing at the enemy hero in progress (attack point not reached yet)?
function H.IsHeroWindupNow(bot, enemyHero)
    if not enemyHero then return false end
    local okT, target = pcall(bot.GetAttackTarget, bot)
    if not okT or target ~= enemyHero then return false end
    if not U.IsAttackingAction(bot) then return false end
    -- Exact 30.000 Hz Source 2 `U._unitTrack[bot]` check: `rec.wasAnim` is `true` STRICTLY during real windup
    -- BEFORE projectile launch, and clears on the EXACT 0.033s tick `m_flLastAttackTime` updates so orb-walk
    -- chase & `Shadowraze3` execute with `0.000s` delay (`S33` + `03:30` 4x self-cancel fix)!
    local curTick = math.floor(GameTime() * 30.0 + 0.5)
    local rec = U._unitTrack and U._unitTrack[bot]
    return rec ~= nil and rec.wasAnim == true and rec.launchTick ~= nil and rec.launchTick >= curTick
end

-- "Let the attack land": while a swing at the hero is in progress, no non-emergency handler issues
-- orders (70-90 damage in 0.3-0.5 s beats all of them). Exceptions: his burst right now
-- is lethal, instant lethal coil is ready, the enemy tower is hitting us, emergency retreat.
function H.ShouldHoldForHeroWindup(bot, s, enemyHero, race)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not H.IsHeroWindupNow(bot, enemyHero) then return false end
    if State.emergencyRetreat then return false end
    if race and race.valid and race.heCanKillNow then return false end
    if U.CanQuickTurnKillWithRaze(bot, enemyHero) then return false end
    local t1 = s and s.enemyT1
    if t1 and U.CanQuery(t1) and t1.GetAttackTarget then
        local okT, tgt = pcall(t1.GetAttackTarget, t1)
        if okT and tgt == bot then return false end
    end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(0.5) then return false end
    return true
end

function H.IsHeroAttackWindupLocked(bot)
    local target = bot:GetAttackTarget()
    if not U.IsAttackingAction(bot) or not target or not target:IsAlive() then
        return false
    end
    if not (target.IsHero and target:IsHero()) then
        return false
    end
    if State.attackTarget ~= target then
        State.attackTarget = target
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    local elapsed = GameTime() - (State.attackStartTime or 0)
    local windup = U.GetExactWindupTicks(bot) / 30.0
    return elapsed < windup
end

-- "Shield" under the tower: a live (non-siege) allied creep inside the tower radius that is CLOSER to the
-- tower than refLoc (the bot by default), with the tower not currently hitting us. The old check
-- ("any creep within 760 of the tower") missed the case where the creeps walked off after the enemy
-- while the bot stayed the tower's closest target.
function H._hasTankCreepUnderTower(tower, allyCreeps, refLoc)
    if not tower or not tower:IsAlive() then return false end
    local bot = GetBot()
    local tgt = tower.GetAttackTarget and tower:GetAttackTarget()
    if bot and tgt == bot then return false end
    -- "Burn" after leaving the tower: it was hitting US just now - do not trust the shield
    -- (last hits/approaches only from outside its radius until the burn expires)
    if H.TowerBurnActive and H.TowerBurnActive() then return false end
    local ref = refLoc or (bot and bot:GetLocation())
    local count = LN.TowerShieldCount(tower, allyCreeps, ref)
    return count >= 1
end

-- A creep tank under the tower does not justify going in when the enemy hero is nearby and we are weaker
-- (he is at full HP, we are not): in that trade under the tower we simply die while wandering between points.
function H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc)
    if H._hasTankCreepUnderTower(tower, allyCreeps, targetLoc) then
        local eh = H._enemyHeroNear and H._enemyHeroNear
        if eh and U.CanQuery(eh) then
            local d = GetUnitToLocationDistance(eh, targetLoc)
            if d <= 900 then
                local myHp, enHp = bot:GetHealth(), eh:GetHealth()
                if myHp < enHp - 100 or (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.50 then
                    return false
                end
            end
        end
        return true
    end
    return false
end

function H.GetSafeApproach(bot, targetLoc, enemyTowers, allyCreeps)
    if W.s and W.s.enemy and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc then
        local tLoc = W.s.enemyT1Loc
        local needBlock = GameTime() < (State.noReenterEnemyT1Until or -1000) or U.DistanceBetweenLocations(targetLoc, tLoc) < 870
        if needBlock and U.DistanceBetweenLocations(targetLoc, tLoc) < 890
            and LN.TowerShieldCountLoc(tLoc, W.s.enemyT1, allyCreeps, targetLoc) < 1 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 890
        end
    end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 830 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 885
                end
            end
        end
    end
    return targetLoc
end

function H.GetSafeApproachLoose(bot, targetLoc, enemyTowers, allyCreeps)
    if W.s and W.s.enemy and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc then
        local tLoc = W.s.enemyT1Loc
        local needBlock = GameTime() < (State.noReenterEnemyT1Until or -1000) or U.DistanceBetweenLocations(targetLoc, tLoc) < 870
        if needBlock and U.DistanceBetweenLocations(targetLoc, tLoc) < 890
            and LN.TowerShieldCountLoc(tLoc, W.s.enemyT1, allyCreeps, targetLoc) < 1 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 890
        end
    end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 740 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 815
                end
            end
        end
    end
    return targetLoc
end

-- Single entry point for ANY approach toward the enemy hero:
-- 1) do not chase a fleeing enemy with equal/greater speed (pointless, we lose creeps);
-- 2) leash at his T1: do not enter the tower radius without a creep shield;
-- 3) the usual point correction relative to the tower.
-- Can we close to distance dAfter without entering our own "band fear" range?
function H.ApproachIntoBandOK(bot, enemyHero, dAfter)
    if State.intent == I.RETREAT then return false end
    local R = K._race
    local killing = (R and R.valid and R.canKillSoon) or State.hunting -- Hunting = finishing
    -- With a fresh stack on us, closing into the near band (< 470 = his right click + near
    -- raze with the stack bonus) is forbidden except to finish; with 2+ stacks we do not close at all.
    -- Previously only "band fear" was checked (it did not trigger without a stack when edge >= 0), so the mirror /
    -- stack finish walked a stacked bot right up to the enemy.
    if not killing then
        local st, rem = U.GetShadowrazeDebuff(bot)
        if (st or 0) >= 1 and (rem or 0) >= 1.0 then
            local nearFear = (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470
            if dAfter < nearFear then return false end
            if st >= 2 then return false end
        end
    end
    -- Single minimum distance (band fear + the "with a stack, stay out of his ready bands" rule)
    local fearMin = U.GetMinDistWithStack(bot, enemyHero)
    if fearMin <= 0 then return true end
    return dAfter >= fearMin - 20
end

function H.ApproachEnemyPoint(bot, enemyHero, loc, threshold, enemyTowers, allyCreeps, allowDive, stackAbility)
    if State.combatPolicyActive == true and enemyHero and not State.heroCombatAllowed then return false end
    if not loc then return false end
    if State.actionTaken then return false end
    if State.towerChaseBlockedEnemy == enemyHero and enemyHero then return false end
    local third = stackAbility and H.StackLeadThirdRazeOK(bot, enemyHero, stackAbility, loc, W.s)
    if enemyHero and not K.StackLeadStepSafe(bot, enemyHero, loc) and not third then return false end
    if allowDive and H.TowerBurnActive() then allowDive = false end -- No dives after leaving the T1
    if enemyHero and U.CanQuery(enemyHero) then
        local botLoc = bot:GetLocation()
        local enLoc = enemyHero:GetLocation()
        local dNow = U.DistanceBetweenLocations(botLoc, enLoc)
        local dAfter = U.DistanceBetweenLocations(loc, enLoc)
        if dAfter < dNow - 60 then
            -- Closing in: does it make sense?
            if not K.CanCatch(bot, enemyHero, dAfter, 2.0) then return false end
            -- Do not enter his READY band if our own fear triggers there too
            -- (ShouldRetreatFromEnemyRazeStack): otherwise we get an "approach - get scared - back off" loop.
            if not allowDive and not third and not H.ApproachIntoBandOK(bot, enemyHero, dAfter) then return false end
        end
        local t1 = W.s.enemyT1
        if t1 and not allowDive then
            local okLoc, tLoc = pcall(t1.GetLocation, t1)
            if okLoc and tLoc then
                local leash = (C.TOWER and C.TOWER.CHASE_LEASH) or 820
                if U.DistanceBetweenLocations(tLoc, loc) < leash and LN.TowerDanger(bot, t1, allyCreeps, loc) >= 2 then
                    return false
                end
                -- Do not chase the enemy BEHIND his T1. The leash above only checked the radius, so
                -- a point on the far side of the tower passed the check - and walking back would mean
                -- crossing its attack radius (hence the freezes under the tower).
                if LN.IsBeyondTower(bot, t1, loc) then return false end
            end
        end
    end
    loc = H.GetSafeApproachLoose(bot, loc, enemyTowers or {}, allyCreeps or {})
    if U.DistanceBetweenLocations(bot:GetLocation(), loc) <= (threshold or 35) then return false end
    return H.SmartMove(bot, loc, threshold or 35, false, stackAbility)
end

function H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    local enemy = H._enemyHeroNear
    if enemy and K.HasRazeStackLead(bot, enemy) then
        local walk = math.max(0, U.DistanceBetweenLocations(botLoc, targetLoc) - bot:GetAttackRange())
        local stop = botLoc + (targetLoc - botLoc):Normalized() * walk
        if not K.StackLeadStepSafe(bot, enemy, stop) then return false end
    end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 420 then return false end
                if GetUnitToLocationDistance(tower, botLoc) < 860 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToHarass(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            -- A right click on a hero inside the tower radius draws the tower onto us REGARDLESS of
            -- creeps (the tower aggros on hero attacks) - so we always stay outside its radius
            -- (+30 for the step toward the target). A creep shield only relaxes the requirement on the target position.
            if GetUnitToLocationDistance(tower, botLoc) < 790 then return false end
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 320 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local towerToEnemy = GetUnitToLocationDistance(tower, enemyHero:GetLocation())
            if towerToEnemy <= 850 then
                if H._hasTankCreepUnderTower(tower, allyCreeps) then
                    return true
                end
                if GetUnitToLocationDistance(bot, tower:GetLocation()) > 810 then
                    return true
                end
                return false
            end
        end
    end
    return true
end

function H.GetEnemyT1Tower(enemyTowers)
    for _, tower in pairs(enemyTowers or {}) do
        if tower and tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                return tower
            end
        end
    end
    return nil
end

-- Bot near its own T1 (within radius of the tower)
function H.IsNearOwnT1(bot, radius)
    local s = W.s
    local t1 = s and s.allyT1
    if not t1 then return false end
    local okL, tl = pcall(t1.GetLocation, t1)
    if not okL or not tl then return false end
    return GetUnitToLocationDistance(bot, tl) <= (radius or 400)
end

function H.IsBotUnderEnemyT1(bot, enemyTowers)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 then return false, nil end
    if GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880 then
        return true, t1
    end
    return false, t1
end

function H.HasRazeResource(bot)
    return H.GetPotentialCombatMana(bot) >= 75
end

function H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.TowerBurnActive() then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if bot:GetLevel() < 5 then return false end
    if not H.HasRazeResource(bot) then return false end
    local enemyCanPunish = U.EnemyCanUseRaze(enemyHero)
    local atkActual = enemyHero:GetActualIncomingDamage(bot:GetAttackDamage() or 0, DAMAGE_TYPE_PHYSICAL)
    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    local enemyVeryLow = enemyHero:GetHealth() <= (oneRaze + atkActual * 2.0) or enemyHero:GetHealth() <= (twoRaze + atkActual)
    if not enemyCanPunish then return true end
    if enemyVeryLow then return true end
    return false
end

function H.TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if not H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    U.UseGlyph(bot)
    State.actionTaken = true
    return true
end

function H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, mode)
    local safeLoc = P.GetLasthitPosition(bot, enemyCreeps or {}, allyCreeps or {}, nil, mode or "PASSIVE")
    local fountain = P.GetFountain(bot)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    local tLoc = (t1 and t1:IsAlive() and t1:GetLocation()) or (W.s and W.s.enemyT1Alive and W.s.enemyT1Loc) or nil
    if tLoc then
        local dir = (fountain - tLoc):Normalized()
        local extra = 150
        safeLoc = tLoc + dir * (865 + C.T1_SAFETY.RETREAT_BUFFER + extra)
    end
    return safeLoc
end

function H.HandleEnemyTowerSafety(bot, s, enemyHero)
    -- CRITICAL TWO-PART FIX (`9056568054.dem` `tk=14006` `837.5u` stall & `9056774541.dem` `tk=6338` `817.0u` FoW stall):
    --   1. Drive tower evacuation from `s.enemyT1Alive` + `s.enemyT1Loc` EVEN WHEN `s.enemyT1 == nil` in Highground FoW!
    --   2. True Dota 2 C++ T1 reach center-to-center = `700 + 144 + 24 = 868.0u` (NOT `720u`!), with full exit at `965u+`!
    local t1 = s and s.enemyT1 or nil
    if not (s and s.enemyT1Alive) then
        State.t1EnterTime = nil
        H.ClearTowerEscape()
        return false
    end
    local tLoc = (t1 and U.CanQuery(t1) and t1:GetLocation()) or (s and s.enemyT1Loc) or nil
    if not tLoc then return false end
    local cfg = C.TOWER or {}
    local escapeRad = math.max(cfg.ESCAPE_RADIUS or 965, 965)
    local d = GetUnitToLocationDistance(bot, tLoc)
    local now = GameTime()

    -- The tower is nearly down (visible & <= 3 hits) - finish it (breaking the T1 wins the game)
    if t1 and LN.IsTowerFinishable(bot, t1) then
        State.t1EnterTime = nil
        H.ClearTowerEscape()
        return false
    end

    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local towerBoltIncoming = false
    for _, p in pairs((bot.GetIncomingTrackingProjectiles and bot:GetIncomingTrackingProjectiles()) or {}) do
        if p and p.is_attack and p.caster and p.caster.IsTower then
            local okTw, isTw = pcall(p.caster.IsTower, p.caster)
            if okTw and isTw then towerBoltIncoming = true; break end
        end
    end

    local onMeEarly = towerBoltIncoming
    if not onMeEarly and t1 and U.CanQuery(t1) and t1.GetAttackTarget then
        local okTE, tgtE = pcall(t1.GetAttackTarget, t1)
        if okTE and tgtE == bot then onMeEarly = true end
    end
    if not onMeEarly and bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.25) then onMeEarly = true end

    if (State.towerEscapeUntil or 0) > now and State.towerEscapeLoc then
        if d > escapeRad and not towerBoltIncoming then
            H.ClearTowerEscape()
        elseif not onMeEarly and H.LaneEnemyAbsent(s) and LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation()) >= 1 then
            H.ClearTowerEscape()
            H.ClearForcedRetreat()
        else
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.2)
            H.SmartMove(bot, State.towerEscapeLoc, 60)
            State.actionTaken = true
            return true
        end
    elseif (State.towerEscapeUntil or 0) > 0 then
        H.ClearTowerEscape()
    end

    -- True C++ T1 reach center-to-center = `868.0u` (`700 + 144 + 24`): `885u` eliminates the entire `[720u..868u]` blind zone!
    -- Also pre-step out at `0.45s` before the last tanking creep dies (`shieldHpTotal <= 125`, `06:44.70` `0`-bolt siege exit!).
    local inRange = d <= 885
    if not inRange then State.t1EnterTime = nil end
    if d > escapeRad and not onMeEarly then return false end
    if State.actionTaken then return false end

    local onMe = onMeEarly
    local reason = nil
    if onMe then
        reason = "tower on me"
    elseif inRange then
        if not State.t1EnterTime then State.t1EnterTime = now end
        local shield = LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation())
        local shieldHpTotal = 0
        for _, ac in pairs(s.allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), tLoc) <= 780 then
                shieldHpTotal = shieldHpTotal + (ac:GetHealth() or 0)
            end
        end
        if shield == 0 or (shield == 1 and shieldHpTotal <= 125 and not H.LaneEnemyAbsent(s)) then
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.2)
            reason = "no shield"
        else
            local cur = bot:GetAttackTarget()
            local heroEngaged = State.aimingRaze and true or false
            if not heroEngaged and (not t1 or cur ~= t1) and (now - (State.heroAttackTime or -10)) <= 1.5 then heroEngaged = true end
            if not heroEngaged and cur and U.CanQuery(cur) and cur.IsHero and cur:IsHero() then heroEngaged = true end
            if heroEngaged and (now - State.t1EnterTime) > (cfg.DIVE_MAX_TIME or 1.0) then
                reason = "dive budget"
            end
        end
    end

    if not reason and inRange and enemyHero and U.CanQuery(enemyHero) and bot.WasRecentlyDamagedByHero then
        if bot:WasRecentlyDamagedByHero(enemyHero, 1.5) then
            local killing = U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero)
            local committed = GameTime() < (State.commitKillUntil or 0)
            local R = K._race
            local shieldHold = (not onMe) and LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation()) >= 1
                and (bot:GetHealth() or 0) >= 520 and (t1 ~= nil and bot:GetAttackTarget() == t1)
                and not (R and R.valid and R.heCanKillSoon)
            if not killing and not committed and not shieldHold then
                reason = "hero hits me under T1"
            end
        end
    end
    if not reason then return false end

    if reason ~= "no shield" and enemyHero and U.CanQuery(enemyHero) then
        local hp = bot:GetHealth()
        local maxHp = math.max(1, bot:GetMaxHealth())
        local tDmg = 100
        if t1 and U.CanQuery(t1) and t1.GetAttackDamage then
            local okD, v = pcall(t1.GetAttackDamage, t1)
            if okD and type(v) == "number" and v > 0 then tDmg = v end
        end
        local hpOk = hp >= maxHp * 0.40 and hp >= tDmg * 3
        local within = (now - (State.t1EnterTime or now)) <= (cfg.DIVE_MAX_TIME or 1.0)
        if hpOk and within then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if U.CanOneShotEnemyHero(bot, enemyHero) and dist <= bot:GetAttackRange() + 60 then
                return false
            end
            if not onMe and U.CanQuickTurnKillWithRaze(bot, enemyHero) then
                return false
            end
        end
    end

    local burn = cfg.BURN_SEC or 2.5
    if (now - (State.lastTowerEscapeAt or -100)) < (cfg.REPEAT_WINDOW or 10) then burn = cfg.BURN_REPEAT_SEC or 6.0 end
    State.lastTowerEscapeAt = now
    State.towerBurnUntil = now + burn
    State.t1EnterTime = nil
    local escape = LN.TowerEscapePointLoc(bot, tLoc)
    State.towerEscapeLoc = escape
    State.towerEscapeUntil = now + (cfg.ESCAPE_COMMIT_SEC or 3.0)
    H.BeginForcedRetreat(bot, escape, 0.9)
    if U.DEBUG then print(string.format("[SF-BOT] tower escape (%s) d=%.0f", reason, d)) end
    return true
end

-- The tower burn is active (we had to leave the T1 recently)
function H.TowerBurnActive()
    return GameTime() < (State.towerBurnUntil or 0)
end

-- A few of my hits are left on the enemy T1 - hit it no matter what:
-- in 1v1 breaking the T1 is a win. The HP threshold is held by LN.IsTowerFinishable (HP >= the number
-- of hits needed converted into its shots); a lethal hero finish still outranks the tower.
function H.HandleEnemyTowerFinish(bot, s, enemyHero)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local t1 = s.enemyT1
    if not t1 or not LN.IsTowerFinishable(bot, t1) then return false end
    local okL, tLoc = pcall(t1.GetLocation, t1)
    if not okL or not tLoc then return false end
    if GetUnitToLocationDistance(bot, tLoc) > ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then return false end
    if enemyHero and U.CanQuery(enemyHero) then
        if U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero) then
            return false
        end
    end
    if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= t1 then
        bot:Action_AttackUnit(t1, true)
        H.ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

function H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps)
    if not ability or not enemyHero or not U.CanQuery(enemyHero) then return false end
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 or not t1:IsAlive() then return false end
    if H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local enemyNearTower = GetUnitToLocationDistance(t1, enemyHero:GetLocation()) <= 900
    if not enemyNearTower then return false end
    local botUnderT1 = GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880
    local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, data.center)
    local setupUnderT1 = setupPos and U.DistanceBetweenLocations(setupPos, t1:GetLocation()) < 900
    if botUnderT1 or setupUnderT1 then
        return true
    end
    return false
end

function H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana()<75 or not U.IsRazeAbilityCastable(bot,H.GetRazeAbilityByLabel(bot,"mid")) then return false end
    if enemyHero:GetAttackTarget()==bot and GetUnitToLocationDistance(bot,enemyHero:GetLocation())<=bot:GetAttackRange() then return false end
    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not active or hitLabel ~= "mid" then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local minHold = C.RAZE.NEAR_CENTER + 110
    local maxHold = C.RAZE.FAR_CENTER - 110
    local desired = C.RAZE.MID_CENTER
    if dist >= minHold and dist <= maxHold then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    return H.SmartMove(bot, holdLoc, 35)
end

function H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil, nil, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return false, nil, nil, nil end
    local nearRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
    local atkRaw = bot:GetAttackDamage() or 0
    local atkActual = enemyHero:GetActualIncomingDamage(atkRaw, DAMAGE_TYPE_PHYSICAL)
    if atkActual <= 0 then return false, nil, nil, nil end
    local hpAfterRaze = enemyHero:GetHealth() - nearRazeDmg
    if hpAfterRaze <= 0 then return false, nearRazeDmg, atkActual, 0 end
    local attacksNeeded = math.ceil(hpAfterRaze / atkActual)
    if attacksNeeded >= 1 and attacksNeeded <= 2 then
        return true, nearRazeDmg, atkActual, attacksNeeded
    end
    return false, nearRazeDmg, atkActual, attacksNeeded
end

function H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not H.HasRazeResource(bot) then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        return false
    end
    local canFinish, _, _, attacksNeeded = H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not canFinish then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not canOneShot then return false end
    if not H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps) and not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist <= attackRange then
        H.IssueHeroAttack(bot, enemyHero)
        return true
    end
    if dist <= attackRange + 260 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 220)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.GetPotentialCombatMana(bot) < 150 then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    if not q or q:GetLevel() == 0 then return false end

    local stacks = U.GetShadowrazeDebuff(enemyHero)
    if stacks ~= 0 then return false end

    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    if twoRaze < enemyHero:GetHealth() then return false end
    if oneRaze >= enemyHero:GetHealth() then return false end

    local candidates = {
        { label = "mid",  ability = w, center = C.RAZE.MID_CENTER  },
        { label = "far",  ability = e, center = C.RAZE.FAR_CENTER  },
        { label = "near", ability = q, center = C.RAZE.NEAR_CENTER },
    }

    for _, c in ipairs(candidates) do
        if c.ability and U.IsRazeAbilityCastable(bot, c.ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, c.ability, enemyTowers, allyCreeps) then
            local actionType, aimLoc = H.GetRazeActionType(bot, c.ability, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, c.ability, actionType, aimLoc, enemyHero) then
                return true
            end
        end
    end

    local opener = nil
    if w and U.IsRazeAbilityCastable(bot, w) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, w, enemyTowers, allyCreeps) then
        opener = { ability = w, center = C.RAZE.MID_CENTER, label = "mid" }
    elseif e and U.IsRazeAbilityCastable(bot, e) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, e, enemyTowers, allyCreeps) then
        opener = { ability = e, center = C.RAZE.FAR_CENTER, label = "far" }
    elseif q and U.IsRazeAbilityCastable(bot, q) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        opener = { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" }
    end

    if opener then
        local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, opener.center)
        if setupPos then
            local currentDist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if math.abs(currentDist - opener.center) > 90 then
                if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps) then
                    return true
                end
            end
        end
    end

    return false
end

function H.TryRazeEnemy(bot, enemyHero, current_mode, enemyTowers, allyCreeps, isLethalChase, forceExtend)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end

    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, current_mode, isLethalChase or false, forceExtend or false)
    if ability then
        local data = U.GetRazeAbilityData(ability)
        local predDist = GetUnitToLocationDistance(bot, aimLoc or enemyHero:GetLocation())
        local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
        if data and data.label == "near" and predDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and data.label == "near" and underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and (data.label == "mid" or data.label == "far") and H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
            ability, actionType, aimLoc = nil, nil, nil
        end
    end

    if H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then return true end

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local followUp = stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2)
    if (forceExtend or (stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6) or isLethalChase or followUp) and bot:GetMana() >= 75 then
        local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
        -- Do not close in for a finishing raze into the NEAR band (200 from him) - that is his
        -- right-click range and his near raze; finish from mid/far or do not finish at all
        if setupPos and followUp and not isLethalChase and not forceExtend then
            local pred = U.PredictPosition(enemyHero, 0.35) or enemyHero:GetLocation()
            if U.DistanceBetweenLocations(setupPos, pred) <= C.RAZE.NEAR_CENTER + 10 then setupPos = nil end
        end
        if setupPos then
            -- Approaching his T1 for a raze is allowed while the tower is busy with a creep (a raze gives no aggro)
            -- and his burst cannot kill us; not below 50% HP.
            local allowDive = isLethalChase
            if not allowDive and (followUp or forceExtend) then
                local R = K._race
                local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
                if hpPct >= 0.5 and not (R and R.valid and R.heCanKillSoon) and H.TowerLockedOnCreep(W.s.enemyT1) then
                    allowDive = true
                end
            end
            -- If the safe boundary (tower) cuts off most of the approach, the raze position is
            -- unreachable: do not stamp at the boundary, give the tick to siege/last hits (not for finishing).
            local reachable = true
            if not isLethalChase then
                local clamped = H.GetSafeApproachLoose(bot, setupPos, enemyTowers or {}, allyCreeps or {})
                if clamped and U.DistanceBetweenLocations(clamped, setupPos) > 200 then reachable = false end
            end
            if reachable and H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps, allowDive) then
                return true
            end
        end
    end

    return false
end

function H.StackLeadThirdRazeOK(bot, enemy, ability, point, snapshot)
    if not ability or not K.HasRazeStackLead(bot, enemy) then return false end
    if State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then return false end
    local stacks, remain = U.GetShadowrazeDebuff(enemy)
    if stacks ~= 2 or not U.IsRazeAbilityCastable(bot, ability) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data or data.label == "near" then return false end
    local race = K._race
    if not race or not race.valid or race.heCanKillSoon then return false end
    local horizon = U.DistanceBetweenLocations(bot:GetLocation(), point) / math.max(1, bot:GetCurrentMovementSpeed())
        + C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08) + 0.1
    if horizon > 1.25 or remain <= horizon + 0.1 then return false end
    local predicted = U.PredictPosition(enemy, horizon)
    local d = U.DistanceBetweenLocations(point, enemy:GetLocation())
    local dp = U.DistanceBetweenLocations(point, predicted)
    if math.max(math.abs(d-data.center), math.abs(dp-data.center)) > C.RAZE.HIT_RADIUS - 40 then return false end
    local before = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local beforePred = GetUnitToLocationDistance(bot, predicted)
    local replies = K.EnemyBandsAcross(enemy, math.min(d, dp, before, beforePred), math.max(d, dp, before, beforePred), horizon)
    if replies > 1 then return false end -- Do not turn 2:1 into a possible 3:3.
    local snap = snapshot or {}
    for _, tower in pairs(snap.enemyTowers or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 900
            or U.DistanceBetweenLocations(point, tower:GetLocation()) < 900) then return false end
    end
    local incoming = K.EnemyRazeDamage(bot, enemy, replies)
    incoming = incoming + K.IncomingAttackDamage(bot, horizon, {
        enemy = enemy,
        creeps = snap.enemyCreeps or {},
        includePotential = true,
        unknownConservative = true,
    })
    if incoming == math.huge then return false end
    -- Account for enemy instant heals + post-cast retreat damage when walking into enemy range:
    -- NEVER step forward at low HP against a healthy higher-stat SF unless the 3rd raze is lethal.
    local enEffHp = (enemy:GetHealth() or 0) + (U.HasItem(enemy, "item_faerie_fire") and 85 or 0) + U.GetStickCharges(enemy) * 15
    local myThirdRaze = K.MyRazeDamage(bot, enemy, 1)
    local lethalFinish = (enEffHp - myThirdRaze) <= K.AttackDamageVs(bot, enemy) * 1.15
    if lethalFinish then
        return bot:GetHealth() - incoming >= math.max(95, K.AttackDamageVs(enemy, bot) * 1.1)
    end
    local retreatGap = math.max(0, (enemy:GetAttackRange() + 90) - d)
    local retreatTime = math.min(2.2, retreatGap / math.max(1, bot:GetCurrentMovementSpeed()))
    local postDisengageIncoming = incoming + K.AttackDamageVs(enemy, bot) * math.ceil(retreatTime / math.max(0.65, enemy:GetSecondsPerAttack()))
    local myAfter = bot:GetHealth() - postDisengageIncoming
    local enAfter = enEffHp - myThirdRaze
    return myAfter >= math.max(210, K.AttackDamageVs(enemy, bot) * 2.8) and myAfter >= (enAfter - 95)
end

function H.HandleStackLead(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not K.HasRazeStackLead(bot, enemy) or State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    for _, label in ipairs({"far", "mid"}) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if H.StackLeadThirdRazeOK(bot, enemy, ab, bot:GetLocation(), snapshot) then
            local action, aim = H.GetRazeActionType(bot, ab, enemy)
            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then return true end
        end
        if ab and U.IsRazeAbilityCastable(bot, ab) and distance > K.Center(label) + 150 then
            local point = enemy:GetLocation() + (bot:GetLocation()-enemy:GetLocation()):Normalized() * (K.Center(label)+150)
            if H.StackLeadThirdRazeOK(bot, enemy, ab, point, snapshot)
                and H.ApproachEnemyPoint(bot, enemy, point, 25, snapshot.enemyTowers, snapshot.allyCreeps, false, ab) then return true end
        end
    end
    if K.EnemyBandsAcross(enemy, distance, distance, 0.7) > 0 then
        local _, outer = K.EnemyBandsAcross(enemy, 0, 2000, 1.0)
        local safe = math.max(distance + 120, outer + 60)
        local point = enemy:GetLocation() + (bot:GetLocation()-enemy:GetLocation()):Normalized() * safe
        point = H.GetSafeApproach(bot, point, snapshot.enemyTowers, snapshot.allyCreeps)
        H.ClearRazeState()
        return H.BeginForcedRetreat(bot, point, 0.45)
    end
    return false
end

-- A confirmed first hit may be followed by ONE other ranged raze, even at
-- equal resources. This is not permission to initiate against an equal opponent.
function H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
    local chain = State.razeFollowup
    if not chain or chain.enemy ~= enemy or not U.CanQuery(enemy) then return nil end
    local now = GameTime()
    if now > chain.untilTime or now < chain.opened + C.RAZE.CAST_POINT then return nil end
    if not race or not race.valid or race.heCanKillSoon then return nil end
    local stacks, remaining = U.GetShadowrazeDebuff(enemy)
    if stacks <= chain.stacks then return nil end -- No blind chase after a miss.
    local ab = H.GetRazeAbilityByLabel(bot, chain.label)
    if not U.IsRazeAbilityCastable(bot, ab) then return nil end
    local center = U.GetRazeCenterByLabel(chain.label)
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist < 350 or dist > 1000 then return nil end
    local reach = center + C.RAZE.STRICT_RADIUS - 30
    local horizon = math.max(0, dist - reach) / math.max(1, bot:GetCurrentMovementSpeed())
        + C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08) + 0.1
    if horizon > chain.untilTime - now or remaining <= horizon + 0.1
        or not K.CanCatch(bot, enemy, reach, horizon) then return nil end
    local snap = snapshot or W.s or {}
    local goal = enemy:GetLocation() + (bot:GetLocation() - enemy:GetLocation()):Normalized() * center
    for _, tower in pairs(snap.enemyTowers or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 800
            or U.DistanceBetweenLocations(goal, tower:GetLocation()) < 800) then return nil end
    end
    local incoming, count = K.EnemyBurstVs(bot, enemy, math.min(dist, center), horizon, false)
    local enemyRange = (enemy:GetAttackRange() or 525) + 80
    if math.min(dist, center) > enemyRange
        and math.min(dist, center) <= enemyRange + enemy:GetCurrentMovementSpeed() * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot)
    end
    local regen = math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0)
    local extra = math.floor((K.EnemyManaBudget(enemy, true) + regen * horizon) / 75)
        - math.floor(K.EnemyManaBudget(enemy, true) / 75)
    if extra > 0 then
        incoming = incoming + K.EnemyRazeDamage(bot, enemy, math.min(3, count + extra))
            - K.EnemyRazeDamage(bot, enemy, count)
    end
    for _, creep in pairs(snap.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then
            incoming = incoming + K.AttackDamageVs(creep, bot)
                * math.ceil(horizon / math.max(0.6, creep:GetSecondsPerAttack()))
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then return nil end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    if bot:GetHealth() - incoming < math.max(110, K.AttackDamageVs(enemy, bot)) then return nil end
    if incoming > K.MyRazeDamage(bot, enemy, 1) + math.max(80, bot:GetHealth() - enemy:GetHealth()) then return nil end
    return ab, center
end

function H.HandlePendingRazeFollowup(bot, enemy, race, snapshot)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local ab, center = H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
    if not ab then return false end
    local action, aim = H.GetRazeActionType(bot, ab, enemy)
    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then return true end
    local predicted = U.PredictPosition(enemy, 0.3)
    local desired = center == C.RAZE.MID_CENTER and center + 150 or center
    local setup = predicted + (bot:GetLocation() - predicted):Normalized() * desired
    if not setup then return false end
    for _, tower in pairs(snapshot.enemyTowers or {}) do
        if tower and tower:IsAlive() and U.DistanceBetweenLocations(setup, tower:GetLocation()) < 800 then return false end
    end
    return H.ApproachEnemyPoint(bot, enemy, setup, 25, snapshot.enemyTowers or {}, snapshot.allyCreeps or {})
end

function H.EnemyStackNeedsImmediateExtension(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.6 then return false end
    -- Do not run to extend a stack on an enemy we cannot reach before it expires (previously
    -- a pointless jog after an enemy that left): the far raze must be reachable in the remaining stack time.
    if not K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS - 60, math.max(0.3, rem_time - C.RAZE.CAST_POINT)) then
        return false
    end
    -- Mana/defence discipline: extending a stack also costs 75 mana and must NEVER walk a wounded/outstatted hero forward.
    local R = K._race
    if R and R.valid and R.heCanKillSoon and not R.canKillNow then return false end
    if R and R.valid and R.losingHard and not R.canKillSoon then return false end
    local minSafeHp = math.max(220, K.AttackDamageVs(enemyHero, bot) * 3.0)
    local killing = R and R.valid and R.canKillSoon
    if killing then return bot:GetHealth() >= math.max(110, K.AttackDamageVs(enemyHero, bot) * 1.4) end
    if bot:GetHealth() < minSafeHp then return false end
    -- A clear advantage in the trade (edge >= 100, he cannot kill us right away) - extend the stack
    if R and R.valid and R.edge >= 100 and not R.heCanKillNow and (bot:GetMana() - 75) >= 75 then return true end
    if State.defensive and not H.HasTradeSupport(R) then return false end
    if H.HarassManaOK(bot, R) then return true end
    if stacks >= 2 and R and R.valid and R.edge >= 40 and (bot:GetMana() - 75) >= 75 then return true end
    return false
end

function H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not H.EnemyStackNeedsImmediateExtension(bot, enemyHero) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return true end
    if State.actionTaken then return false end

    State.prepTarget = nil
    State.attackTarget = nil
    State.attackStartTime = 0
    State.firedThisAttack = false
    State.aggroPullTime = 0
    State.deaggroTime = 0

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local isLethal = U.GetTwoRazeDamage(bot, enemyHero) >= enemyHero:GetHealth() * 0.90
    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, "AGGRESSIVE", isLethal, true)
    if ability and actionType then
        local data = U.GetRazeAbilityData(ability)
        if data and data.label == "near" and actionType == "TURN" then
            local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                ability = nil
                actionType = nil
            end
        end
        if ability and actionType and H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then
            return true
        end
    end

    local shouldCloseIn, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if shouldCloseIn and closePos then
        if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
            return true
        end
    end

    local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
    if setupPos then
        if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 45, enemyTowers, allyCreeps) then
            return true
        end
    end

    local desiredCenter = C.RAZE.MID_CENTER
    local enemyLoc = enemyHero:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = nil
    if dist > desiredCenter + 60 then
        local dir = (enemyLoc - botLoc):Normalized()
        desired = botLoc + dir * math.min(dist - desiredCenter, 380)
    elseif dist < desiredCenter - 100 then
        local dir = (botLoc - enemyLoc):Normalized()
        desired = enemyLoc + dir * desiredCenter
    else
        return false
    end
    if H.ApproachEnemyPoint(bot, enemyHero, desired, 45, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.LevelUpAbilities(bot)
    local order = (C.SKILL and C.SKILL.ORDER) or {}
    local lvl = bot:GetLevel()
    -- Count how many times each ability should be learned by the current level
    -- and learn what is missing (self-healing if a level was skipped).
    -- A level entry is an ability name OR a list: talents cost no points, so at
    -- 10/15/20/25 the talent is taken together with the next point (into "+2 all attributes").
    -- Deterministic: walk the configured order instead of pairs() over a hash table.
    local want = {}
    for i = 1, lvl do
        local entry = order[i]
        local names = (type(entry) == "table") and entry or ((type(entry) == "string") and { entry } or {})
        for _, name in ipairs(names) do
            want[name] = (want[name] or 0) + 1
            if not (C.SKILL and C.SKILL.ALLOW_FRENZY == false and name == "nevermore_frenzy") then
                local isTalent = string.find(name, "special_bonus", 1, true) ~= nil
                if isTalent or bot:GetAbilityPoints() > 0 then
                    local okA, ab = pcall(bot.GetAbilityByName, bot, name)
                    if okA and ab and ab.GetLevel and ab:GetLevel() < want[name] then
                        if not ab.CanAbilityBeUpgraded or ab:CanAbilityBeUpgraded() then
                            bot:ActionImmediate_LevelAbility(name)
                            return
                        end
                    end
                end
            end
        end
    end
end

function H.IsInDangerForRegen(bot, heroDist)
    heroDist = math.min(1600, heroDist or 850)
    local heroes = bot:GetNearbyHeroes(heroDist, true, BOT_MODE_NONE)
    if heroes and #heroes > 0 then return true end
    local creeps = bot:GetNearbyLaneCreeps(600, true)
    if creeps and #creeps > 0 then return true end
    local projs = bot:GetIncomingTrackingProjectiles()
    if projs and #projs > 0 then return true end
    return false
end

function H.HasEnemyProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster then
            local isEnemy = true
            if caster.GetTeam then
                isEnemy = caster:GetTeam() ~= bot:GetTeam()
            end
            if isEnemy then
                return true, p
            end
        end
    end
    return false, nil
end

-- Only Hero / Tower projectiles can cancel `modifier_flask_healing` in Dota 2 7.00-7.41f!
-- Ranged lane creep projectiles NEVER break Healing Salve — treating ranged creep attacks as
-- Salve-breaking caused `BAR 9:09-9:16` (`(1367,1047) -> (2543,2113)` walk away from Mid T1)!
function H.HasSalveBreakingProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster then
            local isEnemy = (not caster.GetTeam) or (caster:GetTeam() ~= bot:GetTeam())
            if isEnemy then
                local okH, isHero = pcall(function() return caster:IsHero() end)
                local okT, isTower = pcall(function() return caster:IsTower() end)
                if (okH and isHero) or (okT and isTower) then
                    return true, p
                end
            end
        end
    end
    return false, nil
end

function H.GetSalveSafeRetreatLocation(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local botLoc = bot:GetLocation()
    local safeDistance = 1120
    if enemyHero and U.CanQuery(enemyHero) then
        local enemyLoc = enemyHero:GetLocation()
        local dir = fountain - enemyLoc
        if U.DistanceBetweenLocations(fountain, enemyLoc) < 1 then
            dir = fountain - botLoc
        end
        dir = dir:Normalized()
        return enemyLoc + dir * safeDistance
    end
    -- When enemy hero is in fog, NEVER walk toward Fountain past `T1 + 420u` (`BAR 9:10` fix)!
    local t1Safe = P.GetT1Close(bot, 420)
    if t1Safe then
        return t1Safe
    end
    local dir = (fountain - botLoc):Normalized()
    return botLoc + dir * 280
end

function H.HandleActiveSalveSafety(bot, enemyHero)
    if not bot:HasModifier("modifier_flask_healing") then
        return false
    end
    if (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.96 then
        return false
    end
    local safeDistance = 1065
    local incomingProjectile = H.HasSalveBreakingProjectileIncoming(bot)
    local tooCloseToEnemy = false
    if enemyHero and U.CanQuery(enemyHero) then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if dist < safeDistance then
            tooCloseToEnemy = true
        end
    end
    if incomingProjectile or tooCloseToEnemy then
        local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
        H.BeginForcedRetreat(bot, safeLoc, 0.65)
        return true
    end
    -- Already outside `1065u` and 0 hero/tower projectiles: DO NOT freeze in place with `actionTaken = true`!
    -- Allow normal lane positioning / CS to operate smoothly inside XP range while Salve finishes ticking!
    return false
end

-- Safety condition: he has no time to turn around, catch up and land a second stack on us.
-- Finishing a creep right after the enemy hero's projectile. His projectile is in flight,
-- and after it lands the creep falls into my finish threshold -> hit now so my attack lands
-- right after his (the window between his hit and the creep dying).
function H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local now = GameTime()
    if now < (State.snipeCooldown or 0) then return false end
    if State.prepTarget then return false end
    local myPoint = bot:GetAttackPoint() or 0.5
    for _, c in pairs(enemyCreeps or {}) do
        if c and U.CanQuery(c) and c:IsAlive() then
            local okP, projs = pcall(function() return c:GetIncomingTrackingProjectiles() end)
            if okP and type(projs) == "table" then
                for _, pr in pairs(projs) do
                    if pr.is_attack and pr.caster == enemyHero then
                        local speed = 1200
                        local okS, sp = pcall(function() return enemyHero:GetAttackProjectileSpeed() end)
                        if okS and type(sp) == "number" and sp > 0 then speed = sp end
                        local eta = 0.3
                        if pr.location then
                            eta = U.DistanceBetweenLocations(pr.location, c:GetLocation()) / speed
                        end
                        if eta <= 0.7 then
                            local myDmg = U.SFDamageRange(bot, c).min
                            local ctx = U.GetTargetPredictionContext(c, { enemyHero })
                            local hpAfter = U.PredictHPWithContext(ctx, c, eta + 0.05, "avg")
                            -- his hit does not kill the creep but makes it mine
                            if hpAfter > 0 and hpAfter <= myDmg * 0.97 then
                                local travel = 0.2
                                local okPS, psp = pcall(function() return bot:GetAttackProjectileSpeed() end)
                                if okPS and type(psp) == "number" and psp > 0 then
                                    travel = U.DistanceBetweenLocations(bot:GetLocation(), c:GetLocation()) / psp
                                end
                                local impact = myPoint + travel + 0.03
                                -- my attack lands AFTER his projectile and inside the window before the creep dies
                                if impact >= eta - 0.06 and impact <= eta + 1.1 then
                                    if H.IsSafeToAttack(bot, c:GetLocation(), enemyTowers, allyCreeps) then
                                        State.prepTarget = c
                                        State.prepTargetTime = now
                                        State.snipeCooldown = now + 0.3
                                        if not U.IsAttackingAction(bot)
                                            or bot:GetAttackTarget() ~= c then
                                            bot:Action_AttackUnit(c, true)
                                            H.ClearMoveCache()
                                        end
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- At the end of an already-started dry duel, take the remaining swings instead of wasting them walking.
function H.HandleDryLastStand(bot,enemy,s)
    if State.actionTaken or bot:GetHealth()>bot:GetMaxHealth()*0.40 or not U.CanQuery(enemy) or enemy:GetAttackTarget()~=bot or bot:IsUsingAbility() or bot:IsChanneling()
        or bot:IsStunned() or (bot.IsDisarmed and bot:IsDisarmed()) or State.towerEscapeLoc then return false end
    local now=GameTime()
    local involved=bot:GetAttackTarget()==enemy
        or (State.heroAttackTarget==enemy and now-(State.heroAttackTime or -100)<2)
        or (State.heroCombatEnemy==enemy and now<(State.heroCombatUntil or 0))
    if not involved or GetUnitToLocationDistance(bot,enemy:GetLocation())>bot:GetAttackRange() then return false end
    if K.MyManaBudget(bot,true)+math.max(0,(bot.GetManaRegen and bot:GetManaRegen()) or 0)*0.8>=75
        or K.EnemyManaBudget(enemy,true)+math.max(0,(enemy.GetManaRegen and enemy:GetManaRegen()) or 0)*0.8>=75 then return false end
    local damage=bot:GetActualIncomingDamage(enemy:GetAttackDamage()+math.max(3,(enemy.GetBaseDamageVariance and enemy:GetBaseDamageVariance()) or 0),DAMAGE_TYPE_PHYSICAL)
    local committed=State.lastStandEnemy==enemy and now<(State.lastStandUntil or 0)
    if damage<=0 or (not committed and (bot:GetHealth()>damage*2
        or enemy:GetHealth()>math.max(enemy:GetMaxHealth()*0.40,K.AttackDamageVs(bot,enemy)*3))) then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    -- Explicit last-stand exception: only this dry, in-range case may cancel a prior hero retreat.
    H.ClearForcedRetreat();State.survivalLoc=nil;State.survivalUntil=0;State.fleeUntil=0
    State.dodgeLoc=nil;State.dodgeUntil=0;State.goingToFountain=false;State.fountainReason=nil
    State.towerChaseBlockedEnemy=nil;State.heroCombatAllowed=true
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.lastStandEnemy=enemy;State.lastStandUntil=now+1.0
    State.actionTaken=true;State.lastCombatStage="dry-last-stand"
    return true
end

-- After an exchange, a hero already in attack range gets an actionable answer, not a spacing tour.
function H.HandleContactTrade(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or enemy:GetAttackTarget()~=bot then return false end
    local ours,ourTime=U.GetShadowrazeDebuff(bot)
    local theirs,theirTime=U.GetShadowrazeDebuff(enemy)
    if ours<2 or theirs<2 or ourTime<=0.2 or theirTime<=0.2 then return false end
    local distance=GetUnitToLocationDistance(bot,enemy:GetLocation())
    if distance>bot:GetAttackRange() then return false end
    if H.HandleGuaranteedRazeKill(bot,enemy,s.enemyTowers or {},s.allyCreeps or {})
        or H.HandleGuaranteedAttackKill(bot,enemy,s.enemyTowers or {},s.allyCreeps or {}) then
        State.actionTaken=true;State.lastCombatStage="contact-trade-finish"
        return true
    end
    local horizon=(bot:GetAttackPoint() or 0.5)+distance/math.max(1,bot:GetAttackProjectileSpeed())+0.15
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    local R = K._race
    local losingContact = (bot:GetHealth()-incoming<math.max(120,K.AttackDamageVs(enemy,bot)*1.6))
        or (R and R.valid and R.losingHard and not R.canKillNow)
    if losingContact then
        local point=U.GetSafeDistancePosition(bot,enemy)
            or U.GetRetreatWaypoint(bot,(bot:GetLocation()-enemy:GetLocation()):Normalized())
        State.lastCombatStage="contact-trade-retreat"
        return H.BeginForcedRetreat(bot,point,2.0)
    end
    for _,label in ipairs({"near","mid","far"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast=State.aimingRaze==ab
                State.actionTaken=true;State.lastCombatStage="contact-trade-raze"
                return true
            end
        end
    end
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.heroCombatEnemy=enemy;State.heroCombatUntil=GameTime()+1.25
    State.actionTaken=true;State.lastCombatStage="contact-trade-attack"
    return true
end

-- ---------------------------------------------------------------------------------------------
-- FREE PRESSURE (2026-10-20, replay-driven)
-- In the 20.10 demo against a human SF the bot threw 2 hero right-clicks in 9 minutes (the human
-- threw 29) and went 130 seconds without a single raze while being right-clicked. Both handlers
-- below add exactly one action in windows where the bot previously did nothing, and every gate is
-- a veto: they can only fire when walking is NOT required (the target is already in range), the
-- expected incoming burst cannot kill us, no enemy tower is near, and no last hit is being stolen.
-- ---------------------------------------------------------------------------------------------

-- A last hit we would lose by swinging at the hero instead (same rule for razes: a 0.55 s cast).
local function FreePressureStealsLastHit(bot, s, pad)
    for _, creep in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:IsAlive() then
            local d = GetUnitToLocationDistance(bot, creep:GetLocation())
            if d <= bot:GetAttackRange() + (pad or 0)
                and creep:GetHealth() <= K.AttackDamageVs(bot, creep) + 20 then
                return true
            end
        end
    end
    return false
end

local function FreePressureTowerClear(bot, s, radius)
    for _, tower in pairs((s and s.enemyTowers) or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) < radius then
            return false
        end
    end
    return true
end

-- One raze when he is on top of us, when he just cast (hit or miss - both are answers),
-- and a bounded proactive raze in a window where nothing threatens us at all.
function H.FreePressureColdWindow(bot, enemy, cold)
    local pressured = H.IsEnemyPressuring(bot, enemy)
    local inWindow = State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)
    if cold == false then return pressured or inWindow end
    return (not pressured) and (not inWindow)
end

-- v4.3.5 replay hfghfghg 08:10.33: the bot took a point-blank Q + two autos while
-- holding 126 mana and a ready Q, but only answered at 08:12.33 after turning back
-- and forth. When we already carry a raze stack and the cast window is survivable,
-- issue the defensive coil directly instead of spending ticks on 40u face-steps.
function H.HandleStackedDefensiveRaze(bot, s, race)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() or bot:IsSilenced() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if race and race.canKillNow then return false end
    local stacks, remain = U.GetShadowrazeDebuff(bot)
    if (stacks or 0) < 1 or (remain or 0) < 0.85 then return false end
    if (bot:GetMana() or 0) < 75 then return false end
    if LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil) >= 2 then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local incoming = K.IncomingAttackDamage(bot, C.RAZE.CAST_POINT + 0.45, {
        enemy = enemy, creeps = s.enemyCreeps or {}, towers = s.enemyTowers or {},
        includePotential = true, unknownConservative = false,
    })
    -- Include a ready enemy coil, not only right-clicks: a defensive answer is
    -- illegal if the enemy can serialize a lethal raze inside our cast point.
    local burst = K.EnemyBurstVs(bot, enemy, d, C.RAZE.CAST_POINT + 0.25, false)
    incoming = math.max(incoming, burst or 0)
    if bot:GetHealth() <= incoming + math.max(60, K.AttackDamageVs(enemy, bot) * 0.75) then return false end
    for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local center = K.RazeCenter and K.RazeCenter(label)
                or (label == "near" and C.RAZE.NEAR_CENTER or (label == "mid" and C.RAZE.MID_CENTER or C.RAZE.FAR_CENTER))
            if math.abs(d - center) <= C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30) then
                H.ManageTreads(bot, "CAST")
                bot:Action_UseAbility(ab)
                H.StartRazeCast(ab, enemy, enemy:GetLocation(), C.RAZE.HIT_RADIUS, false)
                H.ClearMoveCache()
                State.actionTaken = true
                State.lastCombatStage = "stacked-defensive-raze"
                return true
            end
        end
    end
    return false
end

-- v4.3.5 replay hfghfghg 08:08-08:09: the bot walked from 463u to 97u into a
-- full-mana, full-HP enemy while holding only 122 mana (one coil vs six). This is
-- not equal-state mirroring; it is a resource deficit. Keep outer spacing until
-- the mana/HP gap closes. Lethal finishes are checked before this handler.
function H.HandleManaDeficitSpacing(bot, s, race)
    if State.actionTaken or State.forcedRetreatLoc or State.survivalLoc or State.goingToFountain then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if race and (race.canKillNow or race.canKillSoon) then return false end
    if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
    local enBudget = K.EnemyRazeBudget(enemy, true)
    local myBudget = K.MyRazeBudget(bot, true)
    if enBudget < myBudget + 2 then return false end
    local hpDef = (enemy:GetHealth() or 0) - (bot:GetHealth() or 0)
    if hpDef < 150 then return false end
    -- One coil in the bank is not enough to walk into a full-mana rival. With a
    -- large HP deficit (replay 04:36: 412 vs 837 HP, 174 vs 344 mana) even two
    -- coils do not justify point-blank contact.
    if (bot:GetMana() or 0) >= 150 and not (hpDef >= 250 and (bot:GetMana() or 0) < 225) then return false end
    if (bot:GetMana() or 0) >= 225 then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if d > 760 or d < 1 then return false end
    if LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil) >= 2 then return false end
    local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
    local point = bot:GetLocation() + away * 360
    point = H.ComputeCutOffSafeRetreatTarget(bot, enemy, point, 360)
    State.actionTaken = true
    State.lastCombatStage = "mana-deficit-spacing"
    return H.BeginForcedRetreat(bot, point, 0.85)
end

function H.HandleFreeRazeAnswer(bot, s, race, cold)
    FDBG("raze_calls")
    if not C.FREE_RAZE or not C.FREE_RAZE.ENABLED then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then FDBG("raze_busy") return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then FDBG("raze_busycast") return false end
    if State.aimingRaze then FDBG("raze_aiming") return false end
    if race and race.heCanKillSoon then FDBG("raze_race") return false end
    if not FreePressureTowerClear(bot, s, C.FREE_RAZE.TOWER_CLEAR) then FDBG("raze_tower") return false end

    local pressured = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot) or false
    local castAge = GameTime() - ((K._enemy and K._enemy.lastAnyCastAt) or -100)
    -- Answer = he is right-clicking us, or he just cast anything (a hit OR a miss: a miss is exactly
    -- the situation the demo showed the bot ignoring for 130 seconds).
    local answering = pressured or castAge <= C.FREE_RAZE.REPLY_WINDOW
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())

    -- v4.3.4: a rival who cannot reach 75 potential mana has no answer at all, so the
    -- "keep one coil in reserve" tax and the 55% HP floor no longer apply to him.
    local enemyCanAnswer = K.EnemyManaBudget(enemy, true)
        + math.max(0, (enemy.GetManaRegen and enemy:GetManaRegen() or 0)) * 1.2 >= 75
    if answering then
        if cold and not (C.FREE_RAZE.ALLOW_COLD_ANSWER and not (race and race.heCanKillSoon)) then
            -- The cold pipeline runs before any combat stage: leave answers to the combat
            -- pipeline, which has already judged the trade. Only the proactive branch is ours.
            FDBG("raze_cold_answering") return false
        end
        FDBG("raze_answering")
        if bot:GetMana() < 75 or hpPct < C.FREE_RAZE.MIN_HP_PCT_ANSWER then FDBG("raze_mana_hp") return false end
    else
        FDBG("raze_proactive")
        -- Nobody is threatening us: this is a free window. Reserve a spare cast only when
        -- he can actually use one against us.
        local needMana = enemyCanAnswer and C.FREE_RAZE.SURPLUS_MANA
            or (C.FREE_RAZE.SURPLUS_MANA_VS_DRY or 75)
        local needHp = enemyCanAnswer and C.FREE_RAZE.MIN_HP_PCT
            or (C.FREE_RAZE.MIN_HP_PCT_VS_DRY or C.FREE_RAZE.MIN_HP_PCT)
        if bot:GetMana() < needMana or hpPct < needHp then FDBG("raze_reserve") return false end
        if K.ShortReplyIncoming(bot, enemy, 1.2, s) > bot:GetHealth() * 0.25 then FDBG("raze_incoming") return false end
        if enemyCanAnswer and hpPct < C.FREE_RAZE.SAFE_VS_ANSWER_PCT then FDBG("raze_cananswer") return false end
    end

    -- He must already be inside one of our three bands: no walking, no setup position.
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local centers = { far = C.RAZE.FAR_CENTER, mid = C.RAZE.MID_CENTER, near = C.RAZE.NEAR_CENTER }
    local inBand = false
    for _, label in ipairs({ "far", "mid", "near" }) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if ab and U.IsRazeAbilityCastable(bot, ab)
            and math.abs(distance - centers[label]) <= C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30) then
            inBand = true
            break
        end
    end
    if not inBand then FDBG("raze_band") return false end

    local horizon = C.RAZE.CAST_POINT + 0.35
    local incoming = K.ShortReplyIncoming(bot, enemy, horizon, s)
    if bot:GetHealth() - incoming < math.max(C.FREE_RAZE.MIN_HP_AFTER, K.AttackDamageVs(enemy, bot) * 1.25) then
        FDBG("raze_incoming2") return false
    end
    if FreePressureStealsLastHit(bot, s, C.FREE_HIT.LASTHIT_PAD) then FDBG("raze_lasthit") return false end

    for _, label in ipairs({ "far", "mid", "near" }) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local action, aim = H.GetRazeActionType(bot, ab, enemy)
            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                State.shortCombatCast = State.aimingRaze == ab
                State.dodgeLoc = nil
                State.dodgeUntil = 0
                State.actionTaken = true
                State.lastCombatStage = answering and "free-raze-answer" or "free-raze-window"
                _G.__lastCombatStage = State.lastCombatStage
                FDBG(answering and "raze_fired_answer" or "raze_fired_window")
                return true
            end
        end
    end
    FDBG("raze_noaction")
    return false
end

-- A right-click that costs nothing: the target is ALREADY inside our attack range (no chase, no
-- wave break), the swing cannot get us killed, and it does not steal a last hit. The order is
-- re-issued every tick while the situation holds, so the hero keeps swinging.
function H.HandleFreeRightClick(bot, s, race)
    FDBG("hit_calls")
    if not C.FREE_HIT or not C.FREE_HIT.ENABLED then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then FDBG("hit_noenemy") return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then FDBG("hit_busy") return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then FDBG("hit_busycast") return false end
    if State.aimingRaze then FDBG("hit_aiming") return false end
    if race and race.heCanKillSoon then FDBG("hit_race") return false end
    local dEnemyNow = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local maxPokeDist = (bot:GetAttackRange() or 500) + 45
    if dEnemyNow > maxPokeDist then FDBG("hit_range") return false end
    if not FreePressureTowerClear(bot, s, C.FREE_HIT.TOWER_CLEAR) then FDBG("hit_tower") return false end
    if not H.IsSafeToHarass(bot, enemy:GetLocation(), s.enemyTowers or {}, s.allyCreeps or {}) then FDBG("hit_harass") return false end

    -- Immortal Right-Click Reciprocation & Walk-Up Harass (`v3.9.0`, `4 vs 25` autos fix!):
    -- Valve C++ `enemy:GetAttackTarget()` resets to `nil` immediately after orb-walk projectile launch (`ShaNachnetsya`
    -- orb-walked 25/25 right-clicks while `ehpPct > 0.35`, blocking `HandleFreeRightClick` on 100% of ticks after `02:30`!).
    -- Strike whenever: (a) he is hitting/recently hit us (`1.85s` orb-walk window), OR (b) he walked inside our `500u` range
    -- with `<= 2` enemy creeps on us and we hold healthy EHP (`>= 60%` HP or advantage)!
    local parityDry = race and race.valid and race.parityHold and race.bothDry
        and bot:GetHealth() >= enemy:GetHealth() - ((C.PARITY and C.PARITY.HP_LEAD_SLACK) or 90)
    local losingDryDuel = (not parityDry) and (K.EnemyManaBudget(enemy, true) < 75)
        and (bot:GetHealth() < enemy:GetHealth() - 25)
        and (K.AttackDamageVs(bot, enemy) < K.AttackDamageVs(enemy, bot) + 4)
    local pressured = (not losingDryDuel) and (((enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.85))) or false)
    local ehpPct = enemy:GetHealth() / math.max(1, enemy:GetMaxHealth())
    local aggroOnMe = 0
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then aggroOnMe = aggroOnMe + 1 end
    end
    local cleanWalkupPoke = dEnemyNow <= (bot:GetAttackRange() or 500) + 15
        and aggroOnMe <= 1
        and ((U.GetShadowrazeDebuff(bot) or 0) <= (U.GetShadowrazeDebuff(enemy) or 0))
        and (bot:GetHealth() >= bot:GetMaxHealth() * 0.58 or K.EnemyManaBudget(enemy, true) < 75)
    if not pressured and not cleanWalkupPoke and ehpPct > C.FREE_HIT.FINISH_HP_PCT then FDBG("hit_reason") return false end
    FDBG(pressured and "hit_pressured" or "hit_lowfoe")

    if FreePressureStealsLastHit(bot, s, C.FREE_HIT.LASTHIT_PAD) then FDBG("hit_lasthit") return false end

    local horizon = (bot:GetAttackPoint() or 0.5) + C.FREE_HIT.SETTLE_TIME
    local incoming = K.ShortReplyIncoming(bot, enemy, horizon, s)
    if bot:GetHealth() - incoming < math.max(C.FREE_HIT.SAFE_HP_ABS,
        K.AttackDamageVs(enemy, bot) * C.FREE_HIT.SAFE_HP_FACTOR) then
        FDBG("hit_incoming") return false
    end

    if not H.IssueHeroAttack(bot, enemy) then FDBG("hit_issuefail") return false end
    FDBG("hit_issued")
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    State.actionTaken = true
    State.lastCombatStage = "free-right-click"
    _G.__lastCombatStage = State.lastCombatStage
    return true
end

-- A survival retreat is separate from tactical spacing. No turn, mirror or chase
-- may steal its order, even when an enemy raze happens to be on cooldown.
-- Low HP alone must not cancel a winning, already-started dry right-click duel.
-- This is not permission to turn back during a retreat or to chase a fleeing hero.
function H.HandleWinningDryDuel(bot, enemy, snapshot)
    local now = GameTime()
    if not enemy or not U.CanQuery(enemy) then return false end
    if State.forcedRetreatLoc or State.survivalLoc
        or now < (State.fleeUntil or 0) or State.goingToFountain then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() or (bot.IsDisarmed and bot:IsDisarmed()) then return false end
    if bot:GetHealth() / math.max(1, bot:GetMaxHealth()) > 0.45 then return false end
    local continuing = bot:GetAttackTarget() == enemy
        or (State.heroAttackTarget == enemy and now - (State.heroAttackTime or -100) < 0.35)
    if not continuing or enemy:GetAttackTarget() ~= bot then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist > bot:GetAttackRange() or U.GetAngleDifference(bot, enemy:GetLocation()) > 25 then return false end
    -- Avoid projecting a clean duel while tower/creep damage is also incoming.
    for _, tower in pairs((snapshot and snapshot.enemyTowers) or {}) do
        if tower and tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) < 900 then return false end
    end
    for _, creep in pairs((snapshot and snapshot.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then return false end
    end
    local hp = bot:GetHealth()
    local enDamage = bot:GetActualIncomingDamage((enemy:GetAttackDamage() or 0)
        + math.max(3, enemy:GetBaseDamageVariance() or 0), DAMAGE_TYPE_PHYSICAL)
    local myDamage = U.SFDamageRange(bot, enemy).min
    if myDamage <= 0 or enDamage <= 0 then return false end
    -- Compare impact events, not "enemy hits NOW" versus our entire fresh windup.
    local function impacts(attacker, target, damage, own)
        local events = {}
        local period = math.max(0.1, attacker:GetSecondsPerAttack() or 1.7)
        local speed = math.max(1,attacker:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED)
        for _, projectile in pairs((target.GetIncomingTrackingProjectiles and target:GetIncomingTrackingProjectiles()) or {}) do
            if not projectile.is_attack or projectile.caster ~= attacker then return nil end
            if projectile.location then
                events[#events+1] = {time=U.DistanceBetweenLocations(projectile.location,target:GetLocation())/speed, damage=damage}
            elseif not own then
                events[#events+1] = {time=0,damage=damage}
            end
        end
        local last = attacker:GetLastAttackTime() or -100
        local travel = dist/speed
        local first
        if last > 0 and now-last <= period+0.1 then
            first = math.max(0,last+period-now) + travel
        else
            first = own and ((attacker:GetAttackPoint() or 0.5)+travel) or 0
        end
        first = math.max(0,first+(own and 0.04 or -0.08))
        for i=0,5 do events[#events+1]={time=first+i*period,damage=damage} end
        table.sort(events,function(x,y) return x.time<y.time end)
        return events
    end
    local outgoing = impacts(bot,enemy,myDamage,true)
    local incoming = impacts(enemy,bot,enDamage,false)
    if not outgoing or not incoming then return false end
    local function lethalAt(events,health)
        for _,e in ipairs(events) do
            health=health-e.damage
            if health<=0 then return e.time end
        end
        return math.huge
    end
    local enemyHp = enemy:GetHealth()+U.GetStickCharges(enemy)*15
        + math.max(0,enemy:GetHealthRegen() or 0)*4
    if U.HasItem(enemy,"item_faerie_fire") then enemyHp=enemyHp+85 end
    local killAt = lethalAt(outgoing,enemyHp)
    local dieAt = lethalAt(incoming,hp)
    if killAt>4 or killAt+0.06>=dieAt then return false end
    -- Include mango/wand charges and mana regenerated before our killing hit.
    if K.MyManaBudget(bot, true) + math.max(0, bot:GetManaRegen() or 0) * killAt >= 75
        or K.EnemyManaBudget(enemy, true) + math.max(0, enemy:GetManaRegen() or 0) * killAt >= 75 then return false end
    if not H.IssueHeroAttack(bot, enemy) then return false end
    State.lastCombatStage = "timed-dry-finish"
    State.actionTaken = true
    return true
end

function H.CanTakeShortCombatAction(bot,enemy,s)
    if not U.CanQuery(enemy) or State.actionTaken or State.goingToFountain
        or State.forcedRetreatLoc or State.survivalLoc or GameTime()<(State.fleeUntil or 0)
        or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    if State.towerChaseBlockedEnemy==enemy then
        if H.TowerChaseBlocked(bot,s) then return false end
        State.towerChaseBlockedEnemy=nil
    end
    return true
end

-- Keep a safe answer through its cast point, while still validating aim and new threats.
function H.HandleShortCombatCast(bot,enemy,s)
    if not State.shortCombatCast or not State.aimingRaze or State.aimingTarget~=enemy
        or not U.CanQuery(enemy) or not bot:IsUsingAbility() or State.forcedRetreatLoc
        or State.survivalLoc or State.goingToFountain or GameTime()<(State.fleeUntil or 0) then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    local remaining=math.max(0,C.RAZE.CAST_POINT-(GameTime()-State.aimingStartTime))
    if bot:GetHealth()-K.ShortReplyIncoming(bot,enemy,remaining+0.15,s)<math.max(60,K.AttackDamageVs(enemy,bot)) then return false end
    if H.HandleActiveRazeValidation(bot) then
        State.lastCombatStage="short-cast-validation"
        State.actionTaken=true
        return true
    end
    return false
end

-- A short stationary answer is not the same decision as tanking a 2.5-second combo.
function H.HandleSafeRazeReply(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or bot:GetMana()<75 then return false end
    local age=U.GetRecentEnemyRazeHitAge(enemy)
    local castAge=GameTime()-((K._enemy and K._enemy.lastAnyCastAt) or -100)
    local phase=K.EnemyPhase()
    local phaseThreat=phase and GetUnitToLocationDistance(bot,K.EnemyRazeCenter(enemy,phase))<=C.RAZE.HIT_RADIUS+20
    -- Right-click pressure is a reason to answer even when no raze landed on us and he has not
    -- cast for a while: an SF standing in our face taking free swings must not be free.
    local pressuredNow=(enemy.GetAttackTarget and enemy:GetAttackTarget()==bot) or false
    if not phaseThreat and age>0.8 and not pressuredNow and (castAge>1.0 or not H.IsEnemyPressuring(bot,enemy)) then return false end
    if K.HasRazeStackLead(bot,enemy) then return false end -- The bounded third-spell rule owns this case.
    local hitTime=GameTime()-age
    if not phaseThreat and age<=0.8 and State.mirrorAnsweredEnemy==enemy and State.mirrorAnsweredHit
        and math.abs(State.mirrorAnsweredHit-hitTime)<0.001 then return false end
    if GetUnitToLocationDistance(bot,enemy:GetLocation())<=bot:GetAttackRange()
        and U.SFDamageRange(bot,enemy).min>=enemy:GetHealth() then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,C.RAZE.CAST_POINT+0.3,s)
    if bot:GetHealth()-incoming<math.max(80,K.AttackDamageVs(enemy,bot)) then return false end
    -- `9056774541.dem` `02:00.87` (`tk=9258`, `230 HP` vs `736 HP / 265 MP` respawned enemy):
    -- NEVER freeze `0.55s` to fire a single non-lethal reply coil at `< 285 HP` into a healthy full-mana SF!
    if (bot:GetHealth() or 0) < 285 and (enemy:GetHealth() or 9999) > 420
        and ((enemy:GetMana() or 0) + U.GetMangoMana(enemy)) >= 150 then
        return false
    end
    for _,label in ipairs({(phaseThreat and phase) or U.GetRecentEnemyRazeHitLabel(enemy) or "far","far","mid","near"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast = State.aimingRaze==ab
                State.dodgeLoc=nil; State.dodgeUntil=0
                if State.shortCombatCast and label=="mid" and State.razeFollowup then State.razeFollowup.reply=true end
                State.lastCombatStage="safe-short-reply"
                State.actionTaken=true
                return true
            end
        end
    end
    return false
end

-- A confirmed middle reply owns one short far follow-up before generic stack spacing.
function H.HandleReplyFarFollowup(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or bot:GetMana()<75 then return false end
    local chain=State.razeFollowup
    if not chain or not chain.reply or chain.enemy~=enemy or chain.label~="far"
        or GameTime()>chain.untilTime or GameTime()<chain.opened+C.RAZE.CAST_POINT then return false end
    local stacks,remaining=U.GetShadowrazeDebuff(enemy)
    if stacks<=chain.stacks or K.HasRazeStackLead(bot,enemy) then return false end
    local ab=H.GetRazeAbilityByLabel(bot,"far")
    if not U.IsRazeAbilityCastable(bot,ab) then return false end
    local action,aim=H.GetRazeActionType(bot,ab,enemy)
    local point=bot:GetLocation()
    local dist=GetUnitToLocationDistance(bot,enemy:GetLocation())
    local move=0
    if not action then
        local desired=C.RAZE.FAR_CENTER-150
        if dist>=desired or desired-dist>160 then return false end
        move=desired-dist
        point=enemy:GetLocation()+(bot:GetLocation()-enemy:GetLocation()):Normalized()*desired
    end
    local horizon=C.RAZE.CAST_POINT+0.3+move/math.max(1,bot:GetCurrentMovementSpeed())
    if remaining<horizon+0.1 or GameTime()+horizon>chain.untilTime then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    if bot:GetHealth()-incoming<math.max(80,K.AttackDamageVs(enemy,bot)) then return false end
    if action then
        if not H.CastOrTurnRaze(bot,ab,action,aim,enemy) then return false end
        State.shortCombatCast=State.aimingRaze==ab
    else
        if not H.ApproachEnemyPoint(bot,enemy,point,25,s.enemyTowers or {},s.allyCreeps or {}) then return false end
    end
    State.dodgeLoc=nil;State.dodgeUntil=0
    State.lastCombatStage="reply-far-followup";State.actionTaken=true
    return true
end

-- Continue an existing close fight through one funded cooldown cycle; never initiate at parity.
function H.HandleManaCycleContinuation(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) then return false end
    if enemy:GetAttackTarget()~=bot or GetUnitToLocationDistance(bot,enemy:GetLocation())>bot:GetAttackRange() then return false end
    if not H.IsRazeFollowUp(bot,enemy) and not (State.heroCombatEnemy==enemy and GameTime()<State.heroCombatUntil) then return false end
    if not K.ManaCycleWindow(bot,enemy,s) then return false end
    for _,label in ipairs({"near","mid","far"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast = State.aimingRaze==ab
                State.lastCombatStage="mana-cycle-raze";State.actionTaken=true;return true
            end
        end
    end
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.lastCombatStage="mana-cycle-attack"
    State.actionTaken=true
    return true
end

function H.ComputeCutOffSafeRetreatTarget(bot, enemy, desiredPoint, minSpacing)
    local bLoc = bot:GetLocation()
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        return desiredPoint
    end
    local eLoc = enemy:GetLocation()
    local curDist = U.DistanceBetweenLocations(bLoc, eLoc)
    if curDist > 980 or curDist < 1 then
        return desiredPoint
    end
    local toGoal = desiredPoint - bLoc
    if toGoal:Length2D() < 10 then
        return desiredPoint
    end
    local goalDir = toGoal:Normalized()
    local toEnemy = (eLoc - bLoc):Normalized()
    local cutOffCos = goalDir.x * toEnemy.x + goalDir.y * toEnemy.y
    -- `auto-20261023-0050` `07:14.23` Cut-Off Fix:
    -- When the enemy stands BETWEEN us and Fountain (`cutOffCos > 0.40`), walking straight toward `desiredPoint`
    -- runs right into `Q`/`W` range! Arc `78 deg` around him away from his position while monotonically widening gap!
    if cutOffCos <= 0.40 then
        return desiredPoint
    end
    local away = (bLoc - eLoc):Normalized()
    local perpA = Vector(-away.y, away.x, 0)
    local perpB = Vector(away.y, -away.x, 0)
    local fnt = P.GetFountain(bot)
    local fntDir = (fnt - bLoc):Normalized()
    local candA = (away * 0.62 + perpA * 0.78):Normalized()
    local candB = (away * 0.62 + perpB * 0.78):Normalized()
    local scoreA = candA.x * fntDir.x + candA.y * fntDir.y
    local scoreB = candB.x * fntDir.x + candB.y * fntDir.y
    local ptA = bLoc + candA * (minSpacing or 420)
    local ptB = bLoc + candB * (minSpacing or 420)
    local passA = (type(IsLocationPassable) ~= "function") or IsLocationPassable(ptA)
    local passB = (type(IsLocationPassable) ~= "function") or IsLocationPassable(ptB)
    if passA and (not passB or scoreA >= scoreB) then return ptA end
    if passB then return ptB end
    return bLoc + away * (minSpacing or 420)
end

function H.HandleSurvivalRetreat(bot, enemy, race)
    local now = GameTime()
    local visible = enemy and U.CanQuery(enemy)
    local myHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = myHp / maxHp
    if visible and enemy:IsAlive() then
        local lr = U.SolveLethalRace(bot, enemy, W and W.s or nil)
        if lr and lr.winsFirstKill and lr.tKillHim <= 2.25 then
            State.survivalLoc = nil
            State.survivalUntil = 0
            return false
        end
    end
    local enAtk = visible and K.AttackDamageVs(enemy, bot) or 55
    local enBurstAvail = visible and K.EnemyBurstVs(bot, enemy, GetUnitToLocationDistance(bot, enemy:GetLocation()), 2.2, false) or 0
    local actualLethalRisk = (myHp <= 215)
        or (race and race.valid and (race.heCanKillNow or race.heCanKillSoon))
        or ((myHp - enBurstAvail) <= math.max(155, enAtk * 2.1))
    local crushingRightClick = visible
        and ((enemy:GetMana() or 0) + U.GetMangoMana(enemy) < 150)
        and myHp >= 310
        and K.AttackDamageVs(bot, enemy) >= enAtk + 9

    local danger = visible and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 1200
        and hpPct <= 0.45
        and actualLethalRisk
        and not crushingRightClick
        and enemy:GetHealth() / math.max(1, enemy:GetMaxHealth()) > hpPct + 0.12
    local active = State.survivalLoc ~= nil and now < (State.survivalUntil or 0)
    if active and visible and hpPct < 0.50 and actualLethalRisk and not crushingRightClick
        and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 990 then
        danger = true
    end
    local favourable = visible and race and race.valid and not race.heCanKillSoon
        and (race.spellWindow or H.GetPendingRazeFollowup(bot, enemy, race)
            or (race.edge >= 0 and myHp >= enemy:GetHealth()))
    if favourable or crushingRightClick then danger = false end
    if danger then State.survivalUntil = now + 1.6 end
    if now >= (State.survivalUntil or 0) or not danger then
        State.survivalLoc = nil
        State.survivalUntil = 0
        return false
    end
    -- Safe lane spacing anchor (`1,035u` toward own T1/fountain, wrapped in `ComputeCutOffSafeRetreatTarget`!):
    local fountain = P.GetFountain(bot)
    local anchorRef = visible and enemy:GetLocation() or bot:GetLocation()
    local homeDir = (fountain - anchorRef):Normalized()
    local rawTarget = anchorRef + homeDir * 1035
    State.survivalLoc = visible and H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawTarget, 440) or rawTarget
    if GetUnitToLocationDistance(bot, State.survivalLoc) < 85 then
        State.survivalUntil = 0
        State.survivalLoc = nil
        return false
    end
    State.fleeUntil = math.max(State.fleeUntil or 0, now + 0.9)
    local moving = bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO
    if moving and State.survivalOrderLoc == State.survivalLoc
        and now - (State.survivalOrderTime or -100) < 1.2 then
        State.actionTaken = true
        return true
    end
    State.survivalOrderLoc = State.survivalLoc
    State.survivalOrderTime = now
    return H.SmartMove(bot, State.survivalLoc, 60)
end


function H.HandleEnemyNearRazeCounter(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- Clean flee - no turning toward the enemy
    if GameTime() < (State.fleeUntil or 0) and GameTime() >= (State.commitKillUntil or 0) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q_enemy = enemyHero:GetAbilityByName("nevermore_shadowraze1")
    if not q_enemy or not q_enemy:IsInAbilityPhase() then return false end

    local enemyLoc = enemyHero:GetLocation()
    local enemyFacing = enemyHero:GetFacing()
    local rad = math.rad(enemyFacing)
    local forward = Vector(math.cos(rad), math.sin(rad), 0)
    local center = enemyLoc + forward * C.RAZE.NEAR_CENTER
    if U.DistanceBetweenLocations(center, bot:GetLocation()) > C.RAZE.HIT_RADIUS then
        return false
    end

    local q_bot = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q_bot or not U.IsRazeAbilityCastable(bot, q_bot) then return false end

    local botPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local myError = U.GetRazeHitErrorWithDesiredFacing(bot, botPred, C.RAZE.NEAR_CENTER)
    if myError <= C.RAZE.HIT_RADIUS + 30 then
        local actionType = "TURN"
        if U.GetAngleDifference(bot, botPred) <= C.RAZE.MAX_ANGLE_TO_CAST then
            actionType = "CAST"
        end
        if H.CastOrTurnRaze(bot, q_bot, actionType, botPred, enemyHero) then
            return true
        end
    end

    return false
end

function H.GetPotentialRecallHpPct(bot)
    local hp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local bonus = 0
    if bot:HasModifier("modifier_flask_healing") then
        bonus = bonus + 390
    elseif U.HasItem(bot, "item_flask") then
        bonus = bonus + 390
    end
    return math.min(maxHp, hp + bonus) / maxHp
end


-- Pro 1v1 Post-Kill Economy & Lane Reset (`tk=11000` live fix):
-- When we solo-kill the enemy SF, NEVER abandon an uncontested mid wave on a 7,000u walk to Fountain
-- if we have `>= 100g` (First Blood / kill bounty buys instant `item_flask` via courier!) OR already
-- own a Salve/Tango! Stay in lane, farm 100% of the uncontested wave (+4-8 CS & solo XP), and pop the
-- courier-delivered Salve right before enemy TP lands. Only walk to Fountain when `< 35% HP` WITH `< 100g`
-- AND zero healing items — and once walking to Fountain, NEVER abort halfway before 95% HP / 88% MP!
function H.HandlePostKillReset(bot, snapshot)
    local kills = snapshot and snapshot.myKills
    if type(kills) == "number" then
        local previous = State.postKillCount
        State.postKillCount = kills
        if previous ~= nil and kills > previous then
            H.ClearForcedRetreat()
            H.ClearTowerEscape()
            State.survivalLoc = nil
            State.survivalUntil = 0
            State.emergencyRetreat = nil
            State.commitKillUntil = 0
            State.nearChainUntil = 0
            State.dodgeLoc = nil
            local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
            -- Immediately start unlocking Backpack `item_flask` on the exact kill tick so its `6.0s` Backpack CD
            -- finishes LONG before the dead enemy hero respawns (`15–22s`) and channels TP (`+3.0s`)!
            if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
                H.EnsureConsumableReady(bot, "item_flask")
            end
            State.lastEnemyKillAt = GameTime()
            State.lastEnemyKillRespawnAt = GameTime() + math.max(12.0, math.min(28.0, 9.0 + ((snapshot and snapshot.enemyLastLevel) or 3) * 3.2))
            local hasRegenOrGold = ((bot:GetGold() or 0) >= 100)
                or U.HasItem(bot, "item_flask")
                or U.HasItem(bot, "item_tango")
                or bot:HasModifier("modifier_flask_healing")
                or bot:HasModifier("modifier_tango_heal")
            if hpPct <= 0.35 and not hasRegenOrGold then
                bot:Action_ClearActions(true)
                H.ClearRazeState()
                H.ClearMoveCache()
                State.prepTarget = nil
                State.needsTP = false -- Request TP immediately upon full Fountain restore.
                State.goingToFountain = true
                State.fountainReason = "POST_KILL"
            end
        end
    end
    -- Proactive Post-Kill Overstay Guard (`9056469656.dem` `03:07–03:12` Death #1 prevention):
    -- After shoving the wave post-kill, DO NOT sit `< 75% HP` or `< 150 MP` right next to enemy T1 (`<= 850u`)
    -- inside the `2.5s` window right as the full-HP/full-MP enemy hero is respawning! Step back to river (`>= 980u`
    -- from enemy T1) BEFORE they even finish channeling TP!
    if snapshot and snapshot.enemyAlive == false and State.lastEnemyKillRespawnAt
        and GameTime() >= State.lastEnemyKillRespawnAt - 2.5 then
        local hpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
        local myReadyRazes = K.MyReadyRazeCount(bot, true)
        local tLoc = snapshot.enemyT1Alive and snapshot.enemyT1Loc or nil
        if (hpPctNow < 0.78 or myReadyRazes < 2) and tLoc then
            if GetUnitToLocationDistance(bot, tLoc) < 980 then
                local fnt = P.GetFountain(bot)
                local safeRiver = tLoc + (fnt - tLoc):Normalized() * 1120
                H.SmartMove(bot, safeRiver, 45)
                State.actionTaken = true
                return true
            end
        end
    end
    if State.goingToFountain and State.fountainReason == "POST_KILL" then
        if H.HandleFountainRecall(bot) then return true end
        if State.needsTP then return H.HandleReturnTP(bot) end
    end
    return false
end

function H.ShouldGoToFountain(bot)
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local potentialHpPct = H.GetPotentialRecallHpPct(bot)
    if potentialHpPct < hpCritical then
        -- The enemy has exactly as few resources as we do - walking to the fountain simply hands
        -- him the lane and the wave. Keep the distance and regen.
        local enemyHero = W.s.enemy
        if enemyHero and U.EnemyResourcesAsWeak(bot, enemyHero, nil) then return false, nil end
        return true, "HP"
    end
    return false, nil
end

function H.ShouldAbortFountainRecall(bot)
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if hpPct >= hpCritical then
        return true
    end
    local potentialHpPct = H.GetPotentialRecallHpPct(bot)
    return potentialHpPct >= hpCritical
end

function H.IsAtFountain(bot)
    if bot.HasModifier and bot:HasModifier("modifier_fountain_aura_buff") then
        return true
    end
    local fountain = P.GetFountain(bot)
    local radius = math.max(1500, (C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 1500)
    return GetUnitToLocationDistance(bot, fountain) <= radius
end

function H.IsFountainFullyRestored(bot)
    local hp = bot:GetHealth()
    local maxHp = math.max(1, bot:GetMaxHealth())
    local mana = bot:GetMana()
    local maxMana = bot:GetMaxMana()
    local hpPct = hp / maxHp
    local manaPct = (maxMana > 0) and (mana / maxMana) or 1.0
    local waitHpPct = 0.95
    local waitManaPct = 0.88
    return hpPct >= waitHpPct and manaPct >= waitManaPct
end

function H.HandleFountainRecall(bot)
    if State.goingToFountain then
        if not bot:IsAlive() then
            State.goingToFountain = false
            State.fountainReason = nil
            return false
        end
        if not H.IsAtFountain(bot) and State.fountainReason ~= "EMERGENCY" and State.fountainReason ~= "POST_KILL" and H.ShouldAbortFountainRecall(bot) then
            State.goingToFountain = false
            State.fountainReason = nil
            H.ClearMoveCache()
            return false
        end
        if H.IsAtFountain(bot) then
            if H.IsFountainFullyRestored(bot) then
                State.goingToFountain = false
                State.fountainReason = nil
                State.needsTP = true
                return false
            else
                State.actionTaken = true
                return true
            end
        else
            local fountain = P.GetFountain(bot)
            H.SmartMove(bot, fountain, 80)
            State.actionTaken = true
            return true
        end
    end

    if State.emergencyRetreat then return false end
    if bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_tango_heal") then return false end
    if H.IsInDangerForRegen(bot, 900) then return false end
    local should, reason = H.ShouldGoToFountain(bot)
    if should then
        State.goingToFountain = true
        State.fountainReason = reason
        H.ClearForcedRetreat()
        local fountain = P.GetFountain(bot)
        H.SmartMove(bot, fountain, 80)
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleReturnTP(bot)
    local t1 = P.GetT1Close(bot)
    local fountain = P.GetFountain(bot)
    local distToT1 = GetUnitToLocationDistance(bot, t1)
    local minTpDist = math.max(2600, (C.TP and C.TP.RETURN_DISTANCE_FROM_T1) or 3000)
    local farFromT1 = distToT1 >= minTpDist
    local nearFount = H.IsAtFountain(bot)
    local gameStarted = (type(DotaTime) == "function") and (DotaTime() > 15) or (GameTime() > 20)

    -- Never waste an 80s TP cooldown on a short walk when already near T1 (< 2600u)!
    if not farFromT1 then
        State.needsTP = false
        State.tpSwapStep = 0
        return false
    end

    -- Whenever inside the Fountain after game start (e.g. respawn or manual/emergency recall), mark TP return!
    if nearFount and gameStarted then
        State.needsTP = true
    end

    -- v4.3.4: returning from a heal retreat ON FOOT wastes 10-15s of lane time per trip.
    -- Replay 9068981052: the bot salved at 02:41 and 04:02 while 3000-4800u from its T1,
    -- then walked all the way back (11 last hits conceded while >1500u from the wave)
    -- although it held a ready TP scroll the entire time. Teleport back once we are
    -- healthy again and still BEHIND our own T1 (never while sieging the enemy half).
    if not nearFount and not State.goingToFountain and gameStarted then
        local hpNow = bot:GetHealth() or 0
        local maxNow = math.max(1, bot:GetMaxHealth() or 1)
        local fntToT1 = U.DistanceBetweenLocations(fountain, t1)
        local botToFnt = GetUnitToLocationDistance(bot, fountain)
        local behindOurT1 = fntToT1 > 1 and botToFnt < fntToT1 - 200
        if behindOurT1 and hpNow >= maxNow * ((C.TP and C.TP.RETURN_AFTER_HEAL_HP) or 0.65) then
            State.needsTP = true
        end
    end

    if not State.needsTP then return false end
    if not gameStarted then return false end

    -- If inside or right next to Fountain, ensure full heal in Fountain aura BEFORE teleporting!
    if nearFount and not H.IsFountainFullyRestored(bot) then
        if not (bot.HasModifier and bot:HasModifier("modifier_fountain_aura_buff")) then
            H.SmartMove(bot, fountain, 40)
        else
            bot:Action_ClearActions(false)
        end
        State.actionTaken = true
        return true
    end

    -- A TP order was just issued: hold still briefly so channel starts cleanly without canceling it
    if GameTime() - (State.tpOrderTime or -100) < 0.6 then
        State.actionTaken = true
        return true
    end

    local tp = U.GetTPScroll(bot)
    if not tp then
        -- ONLY buy a TP scroll if the hero AND personal courier genuinely own ZERO TP scrolls anywhere!
        if not U.HasAnyTPScroll(bot) and nearFount and bot:GetGold() >= 100
            and GameTime() - (State.tpBuyTime or -100) > 15.0 then
            bot:ActionImmediate_PurchaseItem("item_tpscroll")
            State.tpBuyTime = GameTime()
            State.actionTaken = true
            return true
        end
        State.needsTP = false
        return false
    end

    State.tpSwapStep = 0
    local castOk, castable = pcall(function() return tp:IsFullyCastable() end)
    if castOk and castable and bot:GetMana() >= 75 then
        bot:Action_UseAbilityOnLocation(tp, t1)
        State.tpOrderTime = GameTime()
        State.goingToFountain = false
        State.needsTP = false
        State.actionTaken = true
        return true
    end

    -- Scroll on short cooldown (<= 6s) while standing in Fountain: wait in Fountain, then teleport!
    local cdOk, cd = pcall(tp.GetCooldownTimeRemaining, tp)
    if nearFount and cdOk and type(cd) == "number" and cd > 0 and cd <= 6.0 then
        State.actionTaken = true
        return true
    end

    -- Scroll on long cooldown (e.g. > 6s): clear needsTP so we NEVER waste TP near T1 25s later!
    State.needsTP = false
    return false
end

-- Defensive stance "I am weaker" (with hysteresis). The criterion is K.Race: a 6 s trade projection
-- (burst + right clicks + HP pool + towers), not just razes. While defending: do not answer his
-- right clicks without creep/tower support, do not harass, do not contest last hits,
-- stand behind our creeps (PASSIVE position), heal earlier.
function H.UpdateDefensive(bot, s, race)
    local now = s.now or GameTime()
    local cfg = C.DEFENSE or {}
    if not race or not race.valid then
        if not s.enemyAlive then State.defensive = false end
        return State.defensive
    end
    if race.spellWindow and not race.heCanKillSoon then
        State.defensive = false
        return false
    end
    if not State.defensive then
        if race.weaker then
            State.defensive = true
            State.defensiveSince = now
        end
    else
        local held = now - (State.defensiveSince or 0)
        if not race.weaker and race.edgeLong > -(cfg.EXIT_EDGE or 40) and held >= (cfg.MIN_HOLD_SEC or 2.0) then
            State.defensive = false
        end
    end
    return State.defensive
end

-- Support in the fight: my creeps are hitting him / he is under my tower.
function H.HasTradeSupport(race)
    local cfg = C.DEFENSE or {}
    if (State.enemyAggroCount or 0) >= (cfg.SUPPORT_CREEPS or 2) then return true end
    if race and race.valid and (race.myTowerOnHim or 0) > 0 then return true end
    return false
end

-- Can we spend 75 mana on a harass raze (not CS, not a finish): the reserve depends on the level.
-- followUp = the enemy has a fresh stack and is still in reach: the second/third raze finishes the stack
-- (+35/50/65/80 bonus per stack, he cannot answer) - the mana reserve does not apply.
function H.HarassManaOK(bot, race, followUp)
    local mana = H.GetPotentialCombatMana(bot)
    if mana < 75 then return false end
    if race and race.valid and race.canKillSoon then return true end
    if State.hunting then return true end -- Hunting: mana for 1 raze (+mango) is enough
    local cfg = C.MANA or {}
    local lvl = bot:GetLevel() or 1
    if followUp then
        -- At L1-L2 the "raze + stack finish" chain is limited by a 130 reserve (otherwise with
        -- fixed aiming the bot threw 3 razes in a row and sat at 66 mana for a minute)
        -- Exception - the enemy walked up close and took a near raze: finish with a chain
        -- of up to 3 razes (near -> mid -> far at the runner), no mana reserve.
        if GameTime() < (State.nearChainUntil or 0) then return true end
        local keep = cfg.FOLLOWUP_KEEP or 60
        if lvl <= (cfg.EARLY_LEVEL_L2 or 2) then keep = cfg.FOLLOWUP_KEEP_L2 or 130 end
        return (mana - 75) >= keep
    end
    local reserve = cfg.RESERVE_FOR_PRESSURE or 75
    if lvl <= (cfg.EARLY_LEVEL_L2 or 2) then
        reserve = cfg.EARLY_RESERVE_L2 or 150
    elseif lvl <= (cfg.EARLY_LEVEL_L4 or 4) then
        reserve = cfg.EARLY_RESERVE_L4 or 112
    end
    return (mana - 75) >= reserve
end

-- "Stack finish": the enemy has a fresh raze stack (remaining >= FOLLOWUP_MIN_REMAIN) and is within
-- band reach (accounting for his movement during the cast).
function H.IsRazeFollowUp(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    local stacks, rem = U.GetShadowrazeDebuff(enemyHero)
    if (stacks or 0) <= 0 then return false end
    if (rem or 0) < (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2) then return false end
    local pred = U.PredictPosition(enemyHero, C.RAZE.PREDICT_DELAY)
    local d = GetUnitToLocationDistance(bot, pred or enemyHero:GetLocation())
    return d <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 60
end

-- The enemy T1 is "busy" with a creep: its current target is not a hero, is alive, with HP for >= 2 shots.
-- The tower does not switch to a hero while the target is alive and nobody right-clicks the hero (a raze gives no aggro).
function H.TowerLockedOnCreep(t1)
    if not t1 then return false end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then return false end
    if t1.CanBeSeen and not t1:CanBeSeen() then return false end
    local okT, tgt = pcall(t1.GetAttackTarget, t1)
    if not okT or not tgt or not U.CanQuery(tgt) then return false end
    if tgt.IsHero and tgt:IsHero() then return false end
    local okD, dmg = pcall(t1.GetAttackDamage, t1)
    if not okD or type(dmg) ~= "number" or dmg <= 0 then dmg = 100 end
    return (tgt:GetHealth() or 0) >= dmg * 2
end


-- Convert a clear lane lead into ranged pressure, without requiring a prior
-- enemy miss or an already-open raze stack. Never bypass retreat or tower safety.
function H.HasLanePressureAdvantage(bot, enemy, race)
    if not enemy or not U.CanQuery(enemy) or not race or not race.valid then return false end
    if race.heCanKillSoon then return false end
    if race.spellWindow then return true end
    if race.edge < 0 then return false end
    local hp, enemyHp = bot:GetHealth(), enemy:GetHealth()
    local myHit, enemyHit = K.AttackDamageVs(bot, enemy), K.AttackDamageVs(enemy, bot)
    local levelLead = bot:GetLevel() > enemy:GetLevel()
    local soulLead = S.GetSouls(bot) - S.GetSouls(enemy)
    -- Absolute resources and the projected trade, never a percentage of our own pool.
    local healthLead = hp - enemyHp >= math.max(100, enemyHit * 1.5)
    local laneLead = levelLead and soulLead >= 4 and hp >= enemyHp
    local attackLead = myHit >= enemyHit * 1.20 and hp >= enemyHp and myHit > 0
    return healthLead or laneLead or attackLead

end

-- Observe incoming pressure independently of farm targets and attack intent.
function H.IsEnemyPressuring(bot, enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if enemy:GetAttackTarget() == bot then return true end
    local label = K.EnemyPhase()
    if label then
        local center = K.EnemyRazeCenter(enemy, label)
        if center and GetUnitToLocationDistance(bot, center) <= C.RAZE.HIT_RADIUS + 30 then return true end
    end
    if bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 2.0) then return true end
    if bot.WasRecentlyDamagedByPlayer and enemy.GetPlayerID then
        local id = enemy:GetPlayerID()
        if id and id >= 0 and bot:WasRecentlyDamagedByPlayer(id, 2.0) then return true end
    end
    if U.GetRecentEnemyRazeHitAge(enemy) <= 2.0 then return true end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if projectile.caster == enemy then return true end
        end
    end
    return false
end

-- v4.3.3 Human-like mirroring: remember a fresh enemy hero action so the answer can
-- land AFTER the sacred last hit ("he hits me -> I secure the creep -> I hit back slightly later").
-- This is a one-shot token, not a permanent attack order: it expires, is consumed on success,
-- and ConsumeDelayedHeroReply still vetoes lethal burst / tower / out-of-range / active retreat.
function H.NoteEnemyHeroAction(bot, enemy, s)
    local cfg = C.MIRROR_REPLY or {}
    if cfg.ENABLED == false or not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return end
    local now = GameTime()
    if State.heroReplyEnemy ~= enemy then
        State.heroReplyEnemy = enemy
        State.heroReplyAttackTime = -100
        State.heroReplyRazeTime = -100
        State.heroReplyRazeHit = -100
        State.heroReplyAnsweredAttack = false
        State.heroReplyAnsweredRaze = false
    end

    local razeAge = U.GetRecentEnemyRazeHitAge(enemy)
    if razeAge <= 0.55 then
        local hitTime = now - razeAge
        if math.abs((State.heroReplyRazeHit or -100) - hitTime) > 0.05 then
            State.heroReplyRazeHit = hitTime
            State.heroReplyRazeTime = hitTime
            State.heroReplyAnsweredRaze = false
        end
    end

    local attackNow = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot) or false
    if not attackNow and bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, pr in pairs(projs) do
                if pr and pr.caster == enemy then attackNow = true break end
            end
        end
    end
    if not attackNow and bot.WasRecentlyDamagedByHero and razeAge > 0.55
        and bot:WasRecentlyDamagedByHero(enemy, 0.45) then
        attackNow = true
    end
    if attackNow then
        State.heroReplyAttackTime = now
        State.heroReplyAnsweredAttack = false
    end
    if State.heroAttackTarget == enemy and (State.heroAttackTime or -100) >= (State.heroReplyAttackTime or -100) then
        State.heroReplyAnsweredAttack = true
    end
end

function H.IsSymmetricHeroState(bot, enemy, race)
    if race and race.valid then return race.parityHold and true or false end
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    local cfg = C.PARITY or {}
    if cfg.ENABLED == false then return false end
    local myHp = bot:GetHealth() or 0
    local enHp = enemy:GetHealth() or 0
    local myPct = myHp / math.max(1, bot:GetMaxHealth() or 1)
    local enPct = enHp / math.max(1, enemy:GetMaxHealth() or 1)
    return (bot:GetLevel() or 1) >= (enemy:GetLevel() or 1)
        and myHp >= (cfg.MIN_HP or 150)
        and math.abs(myPct - enPct) <= (cfg.HP_SHARE_TOL or 0.18)
end

function H.ConsumeDelayedHeroReply(bot, s, race)
    local cfg = C.MIRROR_REPLY or {}
    if cfg.ENABLED == false then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if State.heroReplyEnemy ~= enemy then return false end
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then return false end
    if L._imminentCS then return false end
    local now = GameTime()
    if State.forcedRetreatLoc or State.survivalLoc or now < (State.fleeUntil or 0) then return false end
    if State.towerChaseBlockedEnemy == enemy then return false end
    if race and race.valid and race.heCanKillNow and not race.canKillNow then return false end

    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local enAtk = K.AttackDamageVs(enemy, bot)
    local parity = race and race.valid and race.parityHold
    local towers, allies = s.enemyTowers or {}, s.allyCreeps or {}
    local prevPolicy, prevAllow = State.combatPolicyActive, State.heroCombatAllowed

    -- Prefer the mirrored raze when his raze is the fresh action: it is the strongest answer
    -- and does not require walking into auto-attack range. Still no chase / no tower dive.
    local razeAge = now - (State.heroReplyRazeTime or -100)
    if not State.heroReplyAnsweredRaze and razeAge >= 0 and razeAge <= (cfg.RAZE_WINDOW or 2.35) then
        if H.GetPotentialCombatMana(bot) >= 75 and not bot:IsSilenced() then
            local incoming = K.ShortReplyIncoming(bot, enemy, C.RAZE.CAST_POINT + 0.35, s)
            local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
            local safeHP = math.max(cfg.MIN_HP_ABS or 95, enAtk * (cfg.MIN_HP_FACTOR or 1.15))
            local razeSafe = (race and race.valid and race.canKillNow)
                or (race and race.bothDry)
                or (myHp - oneRaze >= (cfg.RAZE_MIN_HP_LEFT or 110))
            if myHp - incoming >= safeHP and razeSafe
                and H.IsSafeToHarass(bot, enemy:GetLocation(), towers, allies) then
                local hitLabel = U.GetRecentEnemyRazeHitLabel(enemy)
                local order = {}
                if hitLabel then order[#order + 1] = hitLabel end
                for _, label in ipairs(K.LABELS) do
                    if label ~= hitLabel then order[#order + 1] = label end
                end
                State.combatPolicyActive = false
                State.heroCombatAllowed = true
                for _, label in ipairs(order) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab)
                        and not H.IsTowerDiveRazeUnsafe(bot, enemy, ab, towers, allies) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.combatPolicyActive, State.heroCombatAllowed = prevPolicy, prevAllow
                            State.heroReplyAnsweredRaze = true
                            State.actionTaken = true
                            State.heroCombatEnemy = enemy
                            State.heroCombatUntil = now + 1.25
                            State.lastCombatStage = "delayed-raze-reply"
                            _G.__lastCombatStage = State.lastCombatStage
                            return true
                        end
                    end
                end
                State.combatPolicyActive, State.heroCombatAllowed = prevPolicy, prevAllow
            end
        end
    end

    local atkAge = now - (State.heroReplyAttackTime or -100)
    if not State.heroReplyAnsweredAttack and atkAge >= 0 and atkAge <= (cfg.ATTACK_WINDOW or 2.20) then
        local range = bot:GetAttackRange() or 500
        local maxD = range + (parity and (cfg.MAX_CHASE or 90) or 45)
        if dist > maxD then return false end
        if dist > range and race and race.valid and race.enemyFaster then return false end
        local incoming = K.ShortReplyIncoming(bot, enemy, (bot:GetAttackPoint() or 0.5) + 0.35, s)
        local safeHP = math.max(cfg.MIN_HP_ABS or 95, enAtk * (cfg.MIN_HP_FACTOR or 1.15))
        if myHp - incoming < safeHP and not (parity and myHp - incoming >= enAtk + 35) then return false end
        if not H.IsSafeToHarass(bot, enemy:GetLocation(), towers, allies) then return false end
        State.combatPolicyActive = false
        State.heroCombatAllowed = true
        local okAtk = H.IssueHeroAttack(bot, enemy, true)
        State.combatPolicyActive, State.heroCombatAllowed = prevPolicy, prevAllow
        if okAtk then
            State.heroReplyAnsweredAttack = true
            State.actionTaken = true
            State.heroCombatEnemy = enemy
            State.heroCombatUntil = now + 1.25
            State.lastCombatStage = "delayed-attack-reply"
            _G.__lastCombatStage = State.lastCombatStage
            return true
        end
    end
    return false
end

function H.TowerChaseBlocked(bot, snapshot)
    local enemy, tower = snapshot.enemy, snapshot.enemyT1
    if not U.CanQuery(enemy) or not tower or not tower:IsAlive() then return false end
    if GetUnitToLocationDistance(enemy, tower:GetLocation()) > 820 then return false end
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if distance <= bot:GetAttackRange() and H.IsSafeToHarass(bot, enemy:GetLocation(), snapshot.enemyTowers, snapshot.allyCreeps) then return false end
    if GetUnitToLocationDistance(bot, tower:GetLocation()) >= 900 then
        if State.aimingTarget == enemy and State.aimingRaze and bot:IsUsingAbility() then return false end
        for _, label in ipairs(K.LABELS) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if U.IsRazeAbilityCastable(bot, ab) and not H.IsTowerDiveRazeUnsafe(bot, enemy, ab, snapshot.enemyTowers, snapshot.allyCreeps) then
                local action = H.GetRazeActionType(bot, ab, enemy)
                if action then return false end
            end
        end
    end
    return true
end

function H.UpdateTowerChase(bot, snapshot)
    local enemy = snapshot.enemy
    if not H.TowerChaseBlocked(bot, snapshot) then
        State.towerChaseBlockedEnemy = nil
        return false
    end
    local wasChasing = bot:GetAttackTarget() == enemy
        or (State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)
            and bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO)
    State.towerChaseBlockedEnemy = enemy
    State.heroCombatAllowed = false
    State.heroCombatEnemy = nil
    State.heroCombatUntil = 0
    State.commitKillUntil = 0
    State.razeFollowup = nil
    if GetUnitToLocationDistance(bot, snapshot.enemyT1:GetLocation()) < 900
        or H.IsEnemyPressuring(bot, enemy) then
        return H.BeginForcedRetreat(bot, LN.TowerEscapePoint(bot, snapshot.enemyT1), 0.6)
    end
    if wasChasing then H.SafeClearActions(bot) end
    return false -- Outside danger: release the tick to lane work, not another chase.
end

-- One combat pipeline for both initiation and retaliation. Its caller owns the
-- tick: farm/prehit state is never consulted and cannot suppress a combat stage.
function H.RunCombatPriority(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not enemy or not U.CanQuery(enemy) then return false end
    if H.UpdateTowerChase(bot, snapshot) then return true end
    if State.towerChaseBlockedEnemy == enemy then return false end
    local towers, allies = snapshot.enemyTowers or {}, snapshot.allyCreeps or {}
    State.prepTarget = nil
    State.lhAttackTarget = nil
    State.aggroPullTime = 0
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    local function stage(name, ...)
        if H[name](...) then
            State.lastCombatStage = name
            State.actionTaken = true
            return true
        end
        return false
    end
    if stage("HandleEnemyTowerSafety", bot, snapshot, enemy) then return true end
    if stage("HandleEmergencyConsumables", bot, race) then return true end
    if stage("HandleGuaranteedRazeKill", bot, enemy, towers, allies) then return true end
    if stage("HandleGuaranteedAttackKill", bot, enemy, towers, allies) then return true end
    if stage("HandleEnemyRazeDodge", bot, enemy) then return true end
    -- Answer him: a cast he just threw (hit or miss) and any right-click pressure deserve one
    -- raze back while nothing threatens us. Runs before the combo ladder so it is not starved.
    if stage("HandleFreeRazeAnswer", bot, W.s, race, false) then return true end
    if race and race.valid and race.heCanKillSoon and not race.canKillNow then
        local point = U.GetSafeDistancePosition(bot, enemy)
            or U.GetRetreatWaypoint(bot, (bot:GetLocation() - enemy:GetLocation()):Normalized())
        State.lastCombatStage = "lethal-threat-retreat"
        State.commitKillUntil = 0
        return H.BeginForcedRetreat(bot, point, 1.0)
    end
    if State.aimingRaze and stage("HandleActiveRazeValidation", bot) then return true end
    if bot:IsUsingAbility() or bot:IsChanneling() then
        State.lastCombatStage = "finish-current-cast"
        State.actionTaken = true
        return true
    end
    if stage("HandleStackLead", bot, snapshot, race) then return true end
    -- Preserve a HERO swing, never a creep swing. Safety and lethal finishes above
    -- may interrupt it; ordinary movement/pressure below may not.
    if stage("ShouldHoldForHeroWindup", bot, snapshot, enemy, race) then return true end
    if stage("HandleInstantMirrorRaze", bot, enemy, race, snapshot) then return true end
    if stage("HandlePendingRazeFollowup", bot, enemy, race, snapshot) then return true end
    if race and race.spellWindow then
        if stage("HandleAdvantageRazePressure", bot, enemy, race, towers, allies, nil) then return true end
    end
    if H.CanContinueDryRazeChain(bot, enemy, race) then
        if H.TryRazeEnemy(bot, enemy, "AGGRESSIVE", towers, allies, false, false) then return true end
    end
    if stage("HandleEnemyNearRazeCounter", bot, enemy) then return true end
    if stage("ForceExtendEnemyStack", bot, enemy, towers, allies) then return true end
    if stage("HandleNearRazeReplyPressure", bot, enemy, towers, allies) then return true end
    if race and race.valid and race.canKillSoon then
        if stage("HandleLethalTwoRazeSequence", bot, enemy, towers, allies) then return true end
        if stage("HandleNearRazeFinish", bot, enemy, towers, allies) then return true end
    end
    if stage("HandleImmediateNearRazePunish", bot, enemy, "AGGRESSIVE", towers, allies) then return true end
    if stage("HandleCloseEnemyPunish", bot, enemy, towers, allies) then return true end
    if stage("HandleMirrorRazeTrade", bot, enemy, towers, allies, allies, snapshot.enemyCreeps or {}) then return true end
    if stage("HandleCloseAttackFinish", bot, enemy, towers, allies) then return true end
    local stacked, band = U.IsSecondStackDangerActive(bot, enemy)
    if stacked and band == "mid" and not (race and race.spellWindow) then
        if stage("HandleMidStackSpacing", bot, enemy, towers, allies) then return true end
    end
    if stage("HandleRetaliationAttack", bot, enemy, towers, allies) then return true end
    -- Generic attacks/approach are deliberately LAST, not an early return that
    -- makes every specialised combo handler unreachable.
    if stage("HandleAdvantageRazePressure", bot, enemy, race, towers, allies, nil) then return true end
    -- Last non-destructive option before conceding the tick: a free swing at what is already
    -- inside our attack range (the answer raze had its turn right after the dodge stage).
    if stage("HandleFreeRightClick", bot, W.s, race) then return true end
    -- CRITICAL (`v3.6.0` Anti-Winning-Retreat Fix):
    -- `RunCombatPriority` is entered when we are NOT losing the trade (`edge >= 0` / dominant HP / kill chase).
    -- If the enemy ran past `1150u` or both sides' spells are on short CD, NEVER trigger `BeginForcedRetreat`
    -- (`800ms` backward flee!) unless we are genuinely at risk right now — yield cleanly so CS / T1 siege / forward lane hold run!
    local dangerNow = (not race or not race.valid)
        or race.heCanKillSoon
        or race.losingHard
        or (((bot:GetHealth() or 0) - (race.enBurstSoon or 0)) < 170 and (race.edge or 0) < 40)
    if not dangerNow then
        return false
    end
    local point = U.GetSafeDistancePosition(bot, enemy)
        or U.GetRetreatWaypoint(bot, (bot:GetLocation() - enemy:GetLocation()):Normalized())
    State.lastCombatStage = "no-safe-action-retreat"
    return H.BeginForcedRetreat(bot, point, 0.8)
end

function H.HandleIncomingHeroPressure(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not H.IsEnemyPressuring(bot, enemy) then return false end
    if H.UpdateTowerChase(bot, snapshot) then return true end
    if State.towerChaseBlockedEnemy == enemy then return false end
    State.prepTarget = nil
    State.lhAttackTarget = nil
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    local valid = race and race.valid
    if valid and race.canKillNow then
        if H.HandleGuaranteedRazeKill(bot, enemy, snapshot.enemyTowers or {}, snapshot.allyCreeps or {}) then return true end
        if H.HandleGuaranteedAttackKill(bot, enemy, snapshot.enemyTowers or {}, snapshot.allyCreeps or {}) then return true end
    end
    local losing = not valid or (race.heCanKillSoon and not race.canKillNow)
        or (valid and race.losingHard and not race.spellWindow
            and not race.canKillSoon and not H.GetPendingRazeFollowup(bot, enemy, race, snapshot))
        or (valid and race.weakerSustained and not race.spellWindow
            and not race.canKillSoon and not H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
            and (bot:GetHealth() + 120 < (race.enEffHpNow or enemy:GetHealth()) or race.ttkMe < race.ttkHim * 0.62))
    if losing then
        State.commitKillUntil = 0
        H.ClearRazeState()
        local loc = U.GetSafeDistancePosition(bot, enemy)
        if not loc then
            local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
            loc = U.GetRetreatWaypoint(bot, away)
        end
        H.BeginForcedRetreat(bot, loc, 1.0)
        return true
    end
    -- Both response and initiative use the same specialist-first pipeline.
    local previous = State.intent
    State.intent = I.TRADE
    local acted = H.RunCombatPriority(bot, snapshot, race)
    State.intent = previous
    return acted

end

-- Combat owns the tick once selected. Creeps are not a reason to ignore an
-- attacker, but retreat, lethal damage and tower safety still take precedence.
function H.CanContinueDryRazeChain(bot, enemy, race)
    if not race or not race.valid or race.heCanKillSoon or not U.CanQuery(enemy) then return false end
    if K.EnemyManaBudget(enemy, true) + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * 0.7 >= 75 then return false end
    if not H.IsRazeFollowUp(bot, enemy) then return false end
    for _, label in ipairs(K.LABELS) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if U.IsRazeAbilityCastable(bot, ab) and H.GetRazeActionType(bot, ab, enemy) then return true end
    end
    return false
end

-- v4.3.6-tempo: hero-only pressure is forbidden when the tempo FSM says we are
-- protecting a lead dry, or catching up from behind without a punish window.
function H.TempoBlocksHeroPressure(bot, race)
    local st = T.Get(bot)
    if not st then return false end
    if race and race.valid and (race.canKillNow or race.canKillSoon or race.spellWindow) then return false end
    if st.mode == T.AHEAD then
        return st.dry and st.enemyMana ~= nil and st.enemyMana >= 75
    end
    if st.mode == T.BEHIND then
        if st.enemyDry and st.myMana >= 75 then return false end
        return st.dry or st.levelDeficit > 0 or st.soulDeficit >= 6
    end
    return false
end

function H.ShouldEngageHero(bot, enemy, race)
    if not enemy or not U.CanQuery(enemy) or not race or not race.valid or race.heCanKillSoon then return false end
    if H.TempoBlocksHeroPressure(bot, race) then return false end
    if State.towerChaseBlockedEnemy == enemy or H.TowerChaseBlocked(bot, W.s) then return false end
    if GetUnitToLocationDistance(bot, enemy:GetLocation()) > 1150 then return false end
    if H.CanContinueDryRazeChain(bot, enemy, race) then return true end
    if K.HasRazeStackLead(bot, enemy) and not H.IsEnemyPressuring(bot, enemy) then return false end
    if H.GetPendingRazeFollowup(bot, enemy, race) then return true end
    if H.HasLanePressureAdvantage(bot, enemy, race) then return true end
    if H.IsEnemyPressuring(bot, enemy) then return true end
    return State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)

end

-- Once our last-hit swing has started, a rival projectile is NOT grounds to
-- surrender it. Timing uncertainty can reverse arrival order at short distances.
function H.ShouldCancelCommittedLastHit(predictedHP, threshold, buffer, remaining, window)
    return predictedHP > threshold + buffer and remaining > 0.01 and remaining <= window
end

function H.HandleAdvantageRazePressure(bot, enemy, race, towers, allies, nextLastHit)
    if not H.ShouldEngageHero(bot, enemy, race) then return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc then return false end
    if State.intent == I.RETREAT or GameTime() < (State.fleeUntil or 0) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    -- A chosen hero fight may interrupt even a creep last-hit windup.
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if distance > 1150 then return false end
    local setupAbility, setupCenter
    local followUp = H.IsRazeFollowUp(bot, enemy)
    local spellBudget = bot:GetMana() >= 150 or (bot:GetMana() >= 75
        and ((race.enRazesSoon or 0) == 0 or followUp or race.canKillSoon
            or H.IsEnemyPressuring(bot, enemy)))
    for _, label in ipairs({"far", "mid", "near"}) do
        local ability = H.GetRazeAbilityByLabel(bot, label)
        if spellBudget and ability and U.IsRazeAbilityCastable(bot, ability) then
            local center = label == "far" and C.RAZE.FAR_CENTER or (label == "mid" and C.RAZE.MID_CENTER or C.RAZE.NEAR_CENTER)
            if not setupAbility and label ~= "near" then setupAbility, setupCenter = ability, center end
            if not H.IsTowerDiveRazeUnsafe(bot, enemy, ability, towers, allies) then
                local action, aim = H.GetRazeActionType(bot, ability, enemy)
                if action and H.CastOrTurnRaze(bot, ability, action, aim, enemy) then return true end
            end
        end
    end
    -- A lead also means right-click pressure, not waiting for spell mana/cooldowns.
    if distance <= bot:GetAttackRange() and H.IsSafeToHarass(bot, enemy:GetLocation(), towers, allies) then
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
    end
    if not setupAbility then setupCenter = bot:GetAttackRange() - 30 end
    -- Walk only a short step toward a ready mid/far band, never into near-raze range.
    if setupCenter and distance > setupCenter + 10 then
        local here = bot:GetLocation()
        local step = math.min(220, distance - setupCenter)
        local point = here + (enemy:GetLocation() - here):Normalized() * step
        return H.ApproachEnemyPoint(bot, enemy, point, 35, towers, allies, false)
    end
    return false
end

function H.EarlyRazePolicyBlocks(bot, enemyHero)
    local cfg = C.RAZE or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local razeLvl = (q and q:GetLevel()) or 0
    if razeLvl >= (cfg.AGGRO_MIN_RAZE_LEVEL or 2) then return false end
    if not U.CanQuery(enemyHero) then return true end
    -- Mirror / answer: he cast a raze (hit or missed) in the last MIRROR_WINDOW s
    local E = K._enemy
    if E and E.lastAnyCastAt and (GameTime() - E.lastAnyCastAt) <= (cfg.MIRROR_WINDOW or 2.5) then return false end
    if U.HasEnemyMissedRazeRecently() then return false end
    -- He walked up close: the near band starts a chain of up to 3 razes
    local pred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT) or enemyHero:GetLocation()
    local d = GetUnitToLocationDistance(bot, pred)
    local dNow = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if math.min(d, dNow) <= (cfg.EARLY_CHAIN_DIST or 360) then return false end
    -- An open chain window (he already took a near raze and is leaving)
    if GameTime() < (State.nearChainUntil or 0) then return false end
    return true
end

function H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false, current_mode end
    if not U.CanQuery(enemyHero) then return false, current_mode end
    if H.TempoBlocksHeroPressure(bot, K._race) then return false, current_mode end
    local intent = State.intent
    if intent == I.RETREAT then return false, current_mode end
    -- Mana reserve: pressure with razes only if mana for one more remains after the cast
    -- (except when the enemy cannot answer or we kill him).
    local R = K._race
    local killing = R and R.valid and (R.canKillSoon or State.hunting) -- Hunting = finishing
    local followUp = H.IsRazeFollowUp(bot, enemyHero)
    -- "Free pressure": the enemy has NO raze available (cooldown or mana) and we are
    -- ahead in the trade - raze without a mana reserve. The old reserve (112-150) kept the bot
    -- on right clicks only even though the enemy could not answer with a raze ("I have 1 coil, he has 0 - hit!").
    local freePressure = R and R.valid and (R.enRazesSoon or 0) == 0 and R.edge >= 0
        and bot:GetMana() >= 75
    -- Mana: reserve by level (at level 1-2 a "harmless" enemy is no reason to go to zero: mana is needed
    -- for last hits and the answer, and he will just regen the 64 damage). Finishing a stack - no reserve.
    if not killing and not freePressure and not H.HarassManaOK(bot, R, followUp) then
        return false, current_mode
    end
    -- Raze policy with 1 point (hero L1-L2): do NOT start a trade from range - he regens/eats a mango
    -- for the 85 damage while 75 mana (a quarter of the pool) is lost. Raze only: (a) as a mirror/answer
    -- to his cast, (b) when he walked up close himself (near->mid->far chain),
    -- (c) finishing a stack / killing. From 2 raze points (usually L3) aggression is as before.
    if not killing and not followUp and H.EarlyRazePolicyBlocks(bot, enemyHero) then
        return false, current_mode
    end
    -- Defence: raze him only with support (creeps/tower hitting him), to finish, or
    -- finishing a stack on a LEAVING enemy (he cannot answer, the stack is free)
    if State.defensive and not killing and not H.HasTradeSupport(R) then
        if not (followUp and K.IsEnemyMovingAway(bot, enemyHero)) then
            return false, current_mode
        end
    end
    if followUp then return true, "AGGRESSIVE" end
    if intent == I.ALLIN or intent == I.TRADE or intent == I.ZONE then return true, "AGGRESSIVE" end
    if intent == I.PUSH and R and R.valid and R.edge >= 0 then return true, "AGGRESSIVE" end
    if current_mode == "NEUTRAL" or current_mode == "AGGRESSIVE" then return true, current_mode end
    if bot:GetLevel() > 1 and U.HasEnemyMissedRazeRecently() and H.GetPotentialCombatMana(bot) >= 75 then
        return true, "AGGRESSIVE"
    end
    if aggroCount > 1 or H.GetPotentialCombatMana(bot) < 75 then return false, current_mode end
    local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
    local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
    local bracerDiff = U.GetItemCount(bot, "item_bracer") - U.GetItemCount(enemyHero, "item_bracer")
    if levelDiff > 0 or soulDiff >= 6 or bracerDiff > 0 then return true, "NEUTRAL" end
    return false, current_mode
end

function H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not U.CanQuery(enemyHero) then return false end
    if H.TempoBlocksHeroPressure(bot, K._race) then return false end
    if State.defensive and not H.HasTradeSupport(K._race) then return false end
    local interruptRegen = U.IsEnemyHighValueRegen(enemyHero)
    local enemyMissed = U.HasEnemyMissedRazeRecently() and bot:GetLevel() > 1
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local attackRange = bot:GetAttackRange() + 60
    if dist > attackRange then return false end
    local minDistStack = U.GetMinDistWithStack(bot, enemyHero)
    if minDistStack > 0 and dist < minDistStack then return false end
    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
        if interruptRegen then
            for _, tower in pairs(enemyTowers or {}) do
                if tower:IsAlive() and GetUnitToLocationDistance(tower, bot:GetLocation()) < 720 then
                    return false
                end
            end
        else
            return false
        end
    end
    if interruptRegen then
        return (bot:GetHealth() / bot:GetMaxHealth()) >= 0.30
    end
    local maxAggro = enemyMissed and 2 or 1
    if aggroCount > maxAggro then return false end
    if (bot:GetHealth() / bot:GetMaxHealth()) < C.HARASS.MIN_HP_PCT then return false end
    if current_mode == "PASSIVE" and not enemyMissed then
        local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
        local eHpPct = enemyHero:GetHealth() / enemyHero:GetMaxHealth()
        if (myHpPct - eHpPct) < -0.15 then
            local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
            local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
            if levelDiff <= 0 and soulDiff < 6 then return false end
        end
    end
    return true
end

function H.GetEnemyApproachDistance(enemyMissed)
    return enemyMissed and C.HARASS.APPROACH_DISTANCE_MISS or C.HARASS.APPROACH_DISTANCE
end

function H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.8 then return false end
    return true
end

function H.IsDryVsEnemyRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local myHasResource = H.GetPotentialCombatMana(bot) >= 75
    if myHasResource then return false end
    local enManaPool = (enemyHero:GetMana() or 0) + U.GetMangoMana(enemyHero)
    if U.HasItem(enemyHero, "item_magic_wand") or U.HasItem(enemyHero, "item_magic_stick") then
        enManaPool = enManaPool + 45
    end
    if enManaPool < 75 then return false end
    local myHp = bot:GetHealth() or 0
    -- `9056774541.dem` `02:35` (`16 vs 7` souls + `2x Bracer`, `myHp = 408`, `enemyMP = 96` -> ONLY `1` raze possible!):
    -- When the enemy can afford AT MOST ONE Shadowraze (`enManaPool < 150`), that single raze leaves us healthy (`>= 255 HP`),
    -- and we crush them in right-click damage (`myAtk >= enAtk + 9`), NEVER back off — contest 100% of CS & punish on sight!
    if enManaPool < 150 then
        local oneEnRaze = K.EnemyRazeDamage(bot, enemyHero, 1)
        if (myHp - oneEnRaze) >= 255 and K.AttackDamageVs(bot, enemyHero) >= K.AttackDamageVs(enemyHero, bot) + 9 then
            return false
        end
    end
    local R = K._race
    if R and R.valid and not R.heCanKillSoon and not R.uphillPenalty
        and myHp >= 620
        and (myHp - (R.enBurstSoon or 0)) >= math.max(260, (R.enEffHpNow or 300) + 100) then
        return false
    end
    return true
end

-- "Raze parity". The trade is roughly even (level, items) but he has mana for two
-- razes and we have one. Until we save as much, do not close into mid-band distance:
-- otherwise he catches us with the second raze and we have nothing to mirror with.
function H.IsManaBudgetDisadvantage(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local cfg = C.MANA or {}
    if cfg.PARITY_ENABLE == false then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local enBudget = K.EnemyRazeBudget(enemyHero, true)
    if enBudget < (cfg.PARITY_MIN_ENEMY or 2) then return false end
    local myBudget = K.MyRazeBudget(bot, true)
    if enBudget - myBudget < (cfg.PARITY_GAP or 1) then return false end
    -- A clear advantage in the trade - no fear: our edge has to be converted
    local R = K._race
    if R and R.valid and (R.edge >= 100 or R.canKillSoon) then return false end
    -- "Roughly equal": level and items
    if math.abs((bot:GetLevel() or 1) - (enemyHero:GetLevel() or 1)) > (cfg.PARITY_LEVEL_DIFF or 1) then
        return false
    end
    if math.abs(U.GetLaneItemPower(bot) - U.GetLaneItemPower(enemyHero)) > (cfg.PARITY_ITEM_DIFF or 0.35) then
        return false
    end
    return true
end

function H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    -- Harass raze - with the level-based mana reserve (like any pressure)
    if not H.HarassManaOK(bot, K._race) then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local heroPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local abilities = {
        bot:GetAbilityByName("nevermore_shadowraze2"),
        bot:GetAbilityByName("nevermore_shadowraze3"),
    }

    for _, creep in pairs(enemyCreeps or {}) do
        if creep and creep:IsAlive() then
            local name = creep:GetUnitName() or ""
            if name:find("ranged") then
                local creepPred = U.PredictPosition(creep, C.RAZE.CAST_POINT)
                if U.DistanceBetweenLocations(creepPred, heroPred) <= 180 then
                    local ctx = U.GetTargetPredictionContext(creep, allyAttackers)
                    local predHp = U.PredictHPWithContext(ctx, creep, C.RAZE.CAST_POINT + 0.07)
                    for _, ability in ipairs(abilities) do
                        if ability and U.IsRazeAbilityCastable(bot, ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
                            local data = U.GetRazeAbilityData(ability)
                            local baseDmg = ability:GetSpecialValueInt("shadowraze_damage") or 0
                            local actualCreepDmg = creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL)
                            local midPoint = Vector(
                                (creepPred.x + heroPred.x) * 0.5,
                                (creepPred.y + heroPred.y) * 0.5,
                                (creepPred.z + heroPred.z) * 0.5
                            )
                            local plannedError = U.GetRazeHitErrorWithDesiredFacing(bot, midPoint, data.center)
                            -- This is a "2 in 1" raze (creep + hero): the hero must be covered robustly
                            -- (now and after the cast), otherwise it is just 75 mana for one creep while the band
                            -- goes on cooldown right as he arrives
                            local heroErrAim = U.RobustRazeErrors(bot, enemyHero, data.center, C.RAZE.CAST_POINT)
                            local heroCovered = heroErrAim <= (C.RAZE.HIT_RADIUS - 60)
                            if predHp > 0 and predHp <= actualCreepDmg + 12 and plannedError <= C.RAZE.HIT_RADIUS and heroCovered then
                                local actionType = "TURN"
                                if U.GetAngleDifference(bot, midPoint) <= C.RAZE.MAX_ANGLE_TO_CAST then
                                    actionType = "CAST"
                                end
                                if H.CastOrTurnRaze(bot, ability, actionType, midPoint, enemyHero) then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Emergency consumables BEFORE retreats/salves: wand/faerie when nearly dead,
-- mango for a finish (the raze decides the fight). They used to be in HandleItemsAndConsumables
-- at the end of the tick - while retreating the tick ended earlier and the faerie "was not pressed before death".
function H.HandleEmergencyConsumables(bot, race, snapshot)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if GameTime() < (State.lastItemUseTime or 0) + 0.3 then return false end
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local curHp = bot:GetHealth() or 0
    local commitKill = GameTime() < (State.commitKillUntil or 0)
    local enemy = snapshot and snapshot.enemy or (W.s and W.s.enemy)
    local enemyLive = U.CanQuery(enemy)
    local distance = enemyLive and GetUnitToLocationDistance(bot, enemy:GetLocation()) or 99999

    -- Compute TRUE imminent impact damage (`imminentImpact`): ONLY real in-flight attack projectiles on `bot`,
    -- active enemy Shadowraze cast phase whose AOE covers `bot`, or melee/tower attack actively swinging at `bot`!
    -- NEVER waste `item_faerie_fire` (`-2` permanent attack damage!) at `18%–40%` HP with `0` projectiles in flight
    -- (`9056469656.dem` `02:02.72` `tk=6648`: `149/824 = 18.1% HP`, `Sha` at `873u` running away, `Flask` popped `0.66s` later!).
    local imminentImpact = 0
    if enemyLive then
        local label = K.EnemyPhase()
        if label then
            local center = K.EnemyRazeCenter(enemy, label)
            if center and GetUnitToLocationDistance(bot, center) <= C.RAZE.HIT_RADIUS + 30 then
                imminentImpact = imminentImpact + K.EnemyRazeDamage(bot, enemy, 1)
            end
        end
    end
    -- Projectile-aware: a launched projectile is not also counted as a fresh melee/tower swing.
    imminentImpact = imminentImpact + K.IncomingAttackDamage(bot, 0.6, {
        enemy = enemyLive and enemy or nil,
        creeps = (snapshot and snapshot.enemyCreeps) or {},
        towers = (snapshot and snapshot.enemyTowers) or {},
        includePotential = false,
        unknownConservative = false,
    })
    if hpPct < (C.ITEMS.STICK_USE_PCT or 0.10) and (imminentImpact > 0 or (enemyLive and distance <= 700)) then
        local stickItem = H.GetStickLikeItem(bot)
        if stickItem then
            bot:Action_UseAbility(stickItem)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    local imminentLethal = imminentImpact > 0 and curHp <= imminentImpact + 18
    local criticalLowFloor = hpPct <= 0.125
        and (imminentImpact > 0 or (enemyLive and distance <= 680) or not U.HasItem(bot, "item_flask"))
    if imminentLethal or criticalLowFloor then
        local faerie = U.GetActiveItemByName(bot, "item_faerie_fire")
        if faerie then
            bot:Action_UseAbility(faerie)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    -- Mango for the finish: let the raze decide the fight right now
    if commitKill and bot:GetMana() < K.RazeManaCost(bot) and (bot:GetMana() + U.GetMangoMana(bot)) >= K.RazeManaCost(bot) then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    return false
end

-- Plant only when healing is needed; identify the new tree by POSITION, never by handle.
-- (21.10 correction of the 20.10 finding) The bot does plant a branch - and then could not find
-- its own tree: `plan.before[tree]` is keyed by the tree userdata returned by GetNearbyTrees, and in
-- the real client two calls do not return the same userdata for the same tree.  So "not before[tree]"
-- was true for every tree and the bot ate whatever OLD tree happened to lie within 80 of the plant
-- point; the branch stayed on the map as a tree and the tango charge was spent on a stranger.
-- Now the "already there" set is stored as POSITIONS (matched within 12 units) and the plant point is
-- chosen so that no tree stands within 90 units of it - then the only tree that can be within 60 of
-- the point a second later is the one we planted.
-- =================================================================================================
-- SOURCE 2 `CDOTA_TempTree` (`BinaryObjectID = N_static + k`) IRON BRANCH + TANGO CONTROLLER
-- Valve's C++ `bot:GetNearbyTrees(r)` scans only the static spatial grid (`0 .. N_static - 1`,
-- `N_static = max(GetAllTrees()) + 1 = 3282` on `dota`) and never returns dynamic `CDOTA_TempTree`
-- entities planted by `item_branches` (ValveSoftware/Dota2-Gameplay#23152). Every `CDOTA_TempTree`
-- created during a match receives sequential `BinaryObjectID = N_static + k` (`3282, 3283, ...`),
-- which `bot:Action_UseAbilityOnTree(tango, treeId)` targets directly (`DOTA_UNIT_ORDER_CAST_TARGET_TREE`).
-- =================================================================================================
local BRANCH_CLEAR_RADIUS = 90
local BRANCH_FIND_RADIUS  = 65
local TEMPTREE_PROBE_OFFSETS = { 0, 1, 2, -1, 3, 4, -2, 5 }

local function CountUnitBranches(unit, maxSlot)
    if not unit or not U.CanQuery(unit) then return nil end
    local n = 0
    for i = 0, (maxSlot or 8) do
        local ok, it = pcall(function() return unit:GetItemInSlot(i) end)
        if ok and it and it:GetName() == "item_branches" then
            n = n + 1
        end
    end
    return n
end

function H.EnsureTreeRegistry()
    if State.staticTreeBaseId ~= nil then return State.staticTreeBaseId end
    local maxId = -1
    if type(GetAllTrees) == "function" then
        local ok, all = pcall(GetAllTrees)
        if ok and type(all) == "table" then
            for _, tid in pairs(all) do
                if type(tid) == "number" and tid > maxId then
                    maxId = tid
                end
            end
        end
    end
    State.staticTreeBaseId = (maxId >= 0) and (maxId + 1) or 3282
    State.tempTreeCount = State.tempTreeCount or 0
    return State.staticTreeBaseId
end

function H.UpdateTempTreeTracker(bot, enemy)
    H.EnsureTreeRegistry()
    local myB = CountUnitBranches(bot, 14)
    if myB ~= nil then
        if State.prevBotBranches ~= nil and myB < State.prevBotBranches and not State.branchTango then
            State.tempTreeCount = (State.tempTreeCount or 0) + (State.prevBotBranches - myB)
        end
        State.prevBotBranches = myB
    end
    if enemy and U.CanQuery(enemy) then
        local enB = CountUnitBranches(enemy, 8)
        if enB ~= nil then
            if State.prevEnemyBranches ~= nil and enB < State.prevEnemyBranches then
                State.tempTreeCount = (State.tempTreeCount or 0) + (State.prevEnemyBranches - enB)
            end
            State.prevEnemyBranches = enB
        end
    end
end

local function BranchPointClear(bot, point)
    for _, tree in pairs(bot:GetNearbyTrees(400) or {}) do
        if U.DistanceBetweenLocations(GetTreeLocation(tree), point) < BRANCH_CLEAR_RADIUS then return false end
    end
    return true
end

local function BranchIsOldTree(plan, loc)
    for _, old in pairs(plan.beforeLocs or {}) do
        if U.DistanceBetweenLocations(old, loc) < 12 then return true end
    end
    return false
end

function H.FindPlantedTreeViaAPI(bot, plan)
    for _, tree in pairs(bot:GetNearbyTrees(350) or {}) do
        if not plan.beforeSet[tree] then
            local loc = GetTreeLocation(tree)
            if loc and U.DistanceBetweenLocations(loc, plan.location) < BRANCH_FIND_RADIUS
                and not BranchIsOldTree(plan, loc) then
                return tree
            end
        end
    end
    if not plan.checkedAllTrees and type(GetAllTrees) == "function" then
        plan.checkedAllTrees = true
        local ok, all = pcall(GetAllTrees)
        if ok and type(all) == "table" then
            for _, tree in pairs(all) do
                if not plan.beforeSet[tree] then
                    local okL, loc = pcall(GetTreeLocation, tree)
                    if okL and loc and U.DistanceBetweenLocations(loc, plan.location) < BRANCH_FIND_RADIUS then
                        return tree
                    end
                end
            end
        end
    end
    return nil
end

-- PROVEN SOURCE 2 ENGINE INVARIANT (`libserver.so` + live `.dem` ticks `3990..4146` & `7704..7708`):
-- Human `DOTA_UNIT_ORDER_CAST_TARGET_TREE` accepts dynamic `CDOTA_TempTree` (`id >= N_static`, e.g. `3238+`),
-- whereas Valve's C++ `CDOTA_Bot::Action_UseAbilityOnTree(pAbility, iTree)` validates `0 <= iTree < N_static`
-- against the static map tree array (`ValveSoftware/Dota2-Gameplay#23152`, `#34354`) and silently drops ALL
-- `CDOTA_TempTree` targets! Planting `item_branches` from a Lua Bot therefore destroys `50g` + `-1 STR/AGI/INT`
-- permanently for ZERO healing. Keeping `item_branches` in slots `0..5` gives permanent `+1 all stats` (`+22 HP`,
-- `+12 MP`, `+1 DMG`), while `H.TryWaveSafeStaticTango` eats static trees cleanly with zero missed CS!
function H.HandleActiveBranchTango(_bot)
    State.branchTango = nil
    State.branchTangoSwapUntil = nil
    return false
end

function H.HandleBranchTango(_bot, _tango)
    State.branchTango = nil
    State.branchTangoSwapUntil = nil
    return false
end

function H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero)
    if GameTime()>=(State.branchTangoSwapUntil or -math.huge) then U.ManageInventorySlots(bot) end
    -- An eat-tree order was issued: hold position until modifier_tango_heal appears (up to 1 s)
    if State.tangoCastAt > 0 and (GameTime() - State.tangoCastAt) < 1.0 then
        if bot:HasModifier("modifier_tango_heal") then
            H.ClearTangoState()
            State.tangoFails = 0
        else
            State.actionTaken = true
            return true
        end
    end
    if GameTime() < State.lastItemUseTime + 0.3 then return false end
    if H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then return false end

    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    -- (Wand/faerie moved to HandleEmergencyConsumables - the start of the tick)
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local isHighValueBeingAttacked = false
    for _, c in pairs(enemyCreeps or {}) do
        if c:IsAlive() then
            local name = c:GetUnitName() or ""
            if name:find("ranged") or name:find("flagbearer") or name:find("siege") then
                if (c:GetHealth() / c:GetMaxHealth()) < 0.50 then
                    isHighValueBeingAttacked = true
                    break
                end
                for _, atk in pairs(allyAttackers or {}) do
                    if atk:IsAlive() and atk:GetAttackTarget() == c then
                        isHighValueBeingAttacked = true
                        break
                    end
                end
                if isHighValueBeingAttacked then break end
            end
        end
    end

    local tcfg = C.TANGO or {}
    local missingHp = bot:GetMaxHealth() - bot:GetHealth()
    local wantTango = hpPct < (tcfg.USE_HP_PCT or 0.80) and missingHp >= (tcfg.MIN_MISSING_HP or 100)
    -- In an active fight (TRADE/ALLIN) do not walk to trees while HP is above 60%; in ZONE eat below 60%
    local intent = State.intent
    if (intent == "TRADE" or intent == "ALLIN") and hpPct >= 0.60 then wantTango = false end
    if intent == "ZONE" and hpPct >= 0.60 then wantTango = false end
    if intent == "RETREAT" then wantTango = false end
    -- A "valuable creep under attack" delays the tango only at HP >= 50%
    if hpPct < 0.50 then isHighValueBeingAttacked = false end
    if bot:HasModifier("modifier_tango_heal") then
        H.ClearTangoState()
        wantTango = false
    end

    if wantTango and not isHighValueBeingAttacked then
        local tango = U.GetActiveItemByName(bot, "item_tango")
        if tango then
            local now = GameTime()
            -- An eat-tree order was already issued: wait for modifier_tango_heal without leaving the tree.
            -- Otherwise the next handler walks the bot away and the eat order is cancelled (loop).
            if State.tangoCastAt > 0 and (now - State.tangoCastAt) < 1.0 then
                State.actionTaken = true
                return true
            end
            if State.tangoCastAt > 0 then
                -- The order did not work within 1 s: try again, after two failures use another tree
                State.tangoFails = (State.tangoFails or 0) + 1
                State.tangoCastAt = 0
                if State.tangoFails >= 2 then
                    State.tangoBadTree = State.tangoTree
                    State.tangoBadTreeTime = now
                    State.tangoFails = 0
                    H.ClearTangoState()
                end
            end
            local branchAction,waitingForBranch=H.HandleBranchTango(bot,tango)
            if branchAction then return true end
            if waitingForBranch then return false end
            local tree, treeLoc = H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
            if tree and treeLoc then
                local distToTree = U.DistanceBetweenLocations(bot:GetLocation(), treeLoc)
                if distToTree > 165 then
                    H.SmartMove(bot, treeLoc, 40)
                    return true
                end
                bot:Action_UseAbilityOnTree(tango, tree)
                State.branchTangoDone=true
                State.lastItemUseTime = now
                State.tangoCastAt = now
                State.actionTaken = true
                return true
            end
        end
    elseif not wantTango then
        H.ClearTangoState()
    end

    return false
end

function H.ProcessTelemetry(bot)
    local now = GameTime()
    for i = #State.flyingProjectiles, 1, -1 do
        local proj = State.flyingProjectiles[i]
        if now > proj.impactTime + 0.15 then
            table.remove(State.flyingProjectiles, i)
        end
    end
end

function H.HandleEmergencyRetreat(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()

    if enemyHero and U.CanQuery(enemyHero) then
        local canOneShot, oneShotMethod = U.CanOneShotEnemyHero(bot, enemyHero)
        local canRazeKill, razeLabel = U.CanKillEnemyWithOneRaze(bot, enemyHero)
        if canOneShot then
            return false
        end
        if canRazeKill then
            return false
        end
    end

    if State.emergencyRetreat == "FOUNTAIN" and hpPct >= returnHpPct then
        if H.IsAtFountain(bot) then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            State.goingToFountain = true
            State.fountainReason = "HP"
        else
            -- HP recovered on the way (regen/tango/salve): the emergency retreat is over. Otherwise
            -- "FOUNTAIN" would stay in State and on the next HP dip below 50% would force
            -- a fountain run (committedFountain) for no real reason.
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            H.ClearForcedRetreat()
        end
        return false
    end

    local committedFountain = State.emergencyRetreat == "FOUNTAIN"
        and State.emergencyRetreatStartTime > 0
        and (GameTime() - State.emergencyRetreatStartTime) >= 5.0
        and distToFountain > ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500)

    if committedFountain then
        H.BeginForcedRetreat(bot, fountain, 1.0)
        return true
    end

    local reason, extraLoc = U.GetEmergencyRetreatReason(bot, enemyHero)
    if not reason then
        if State.emergencyRetreat then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
        end
        return false
    end

    if reason == "COURIER" and extraLoc then
        State.emergencyRetreat = "COURIER"
        State.emergencyRetreatStartTime = 0
        local botLoc = bot:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, extraLoc)
        if dist > 150 then
            local toFountain = (fountain - botLoc):Normalized()
            local toCourier = (extraLoc - botLoc):Normalized()
            local blended = (toCourier * 0.8 + toFountain * 0.2):Normalized()
            H.SmartMove(bot, botLoc + blended * math.min(dist, 400), 60)
        end
        State.actionTaken = true
        return true
    end

    if State.emergencyRetreat ~= "FOUNTAIN" then
        State.emergencyRetreatStartTime = GameTime()
    end
    State.emergencyRetreat = "FOUNTAIN"

    if distToFountain < ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500) then
        State.emergencyRetreat = nil
        State.goingToFountain = true
        State.fountainReason = "EMERGENCY"
        State.actionTaken = true
        return true
    end

    H.BeginForcedRetreat(bot, fountain, 1.0)
    return true
end

function H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if U.ShouldUseGlyphDefensive(bot, allyTowers) then
        U.UseGlyph(bot)
        State.actionTaken = true
        return true
    end
    if U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then
        U.UseGlyph(bot)
        State.glyphUsedForDive = true
        State.glyphDiveTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleForcedSalve(bot)
    if not U.ShouldForceSalve(bot) then return false end
    if GameTime() < State.lastForceSalveTime + 1.0 then return false end
    local nearbyEnemyHeroes = bot:GetNearbyHeroes(700, true, BOT_MODE_NONE)
    if nearbyEnemyHeroes and #nearbyEnemyHeroes > 0 then
        local fountain = P.GetFountain(bot)
        local botLoc = bot:GetLocation()
        H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 400, 60)
        State.actionTaken = true
        return true
    end
    local nearbyEnemyCreeps = bot:GetNearbyLaneCreeps(500, true) or {}
    for _, c in pairs(nearbyEnemyCreeps) do
        if U.CanQuery(c) and c:GetAttackTarget() == bot then -- Creep in fog -> do not query
            local fountain = P.GetFountain(bot)
            local botLoc = bot:GetLocation()
            H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 350, 60)
            State.actionTaken = true
            return true
        end
    end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if flask then
        if H.HasEnemyProjectileIncoming(bot) then
            local safeLoc = H.GetSalveSafeRetreatLocation(bot, nil)
            H.BeginForcedRetreat(bot, safeLoc, 0.65)
            return true
        end
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastForceSalveTime = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

-- Purchases have one owner: item_purchase_nevermore.lua.

function H.HandleSafeDistanceFromEnemy(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if canOneShot then
        H.IssueHeroAttack(bot, enemyHero)
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        return true
    end
    local canQuickRazeKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
        local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
        if ability then
            local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
            local angleDiff = U.GetAngleDifference(bot, predLoc)
            local actionType = angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, ability, actionType, predLoc, enemyHero) then
                return true
            end
        end
    end
    if not U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = isCritical and (SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950) or SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if dist < minDist then
        local duration = isCritical and 1.20 or 0.80
        H.BeginForcedRetreat(bot, safeLoc, duration)
        return true
    end
    return false
end

function H.HandleDryManaMidRazeAvoidance(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not H.IsDryVsEnemyRaze(bot, enemyHero) then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if State.actionTaken then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midDangerRadius = math.max(C.RAZE.STRICT_RADIUS, 210)
    if math.abs(dist - C.RAZE.MID_CENTER) > midDangerRadius then return false end
    -- Short step past the band edge (previously ~1000 toward the fountain -> back for a creep -> scared again)
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero)
    H.BeginForcedRetreat(bot, retreatLoc, 0.75)
    return true
end

function H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_DISTANCE) or 215
    local minDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MIN_DISTANCE) or 150
    local maxDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MAX_DISTANCE) or 250
    local tol = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_TOLERANCE) or 25
    if dist >= minDist and dist <= maxDist then
        H.SafeClearActions(bot)
        bot:Action_MoveToLocation(botLoc)
        State.lastMoveLoc = botLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return true
    end
    -- With a stack on us do NOT close on the enemy (near band = his right click + near raze
    -- with the bonus); "keep the answer distance" only if already adjacent (back off to 215)
    if dist > maxDist then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    H.SmartMove(bot, holdLoc, tol)
    State.actionTaken = true
    return true
end

function H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not secondStackActive or hitLabel ~= "near" then return false end
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if myStacks ~= 1 or myRemain <= C.RAZE.RETREAT_MIN_REMAIN then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            local actionType = U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.0)
    end

    if enemyIsHittingUs then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local attackRange = bot:GetAttackRange() + 60
        if dist <= attackRange then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end

    return H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
end

function H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreepsData, enemyCreepsData)
    if not U.CanQuery(enemyHero) or State.towerChaseBlockedEnemy==enemyHero or State.actionTaken then return false end
    local active,label=U.IsSecondStackDangerActive(bot,enemyHero)
    if not active or not label then return false end
    local ab=H.GetRazeAbilityByLabel(bot,label)
    if not U.IsRazeAbilityCastable(bot,ab) then return false end
    local action,aim=H.GetRazeActionType(bot,ab,enemyHero)
    if action then return H.CastOrTurnRaze(bot,ab,action,aim,enemyHero) end
    -- A real in-range attacker must not get free hits while we reposition for a different band.
    if enemyHero:GetAttackTarget()==bot and GetUnitToLocationDistance(bot,enemyHero:GetLocation())<=bot:GetAttackRange() then return false end
    local setup=U.GetRazeSetupPositionForAbility(bot,enemyHero,U.GetRazeCenterByLabel(label))
    return setup and H.ApproachEnemyPoint(bot,enemyHero,setup,35,enemyTowers,allyCreeps) or false
end

-- Instant mirror. His raze just landed on us (<= MIRROR_INSTANT_SEC): he stands
-- in the same band on our side (symmetry) - answer immediately with the same band (his copy is on a 9 s cd)
-- or with any band that covers robustly. Previously the answer came after the stack-exit rule and the
-- finish block, i.e. 0.5-1 s later when the enemy had already moved ("mirrors slowly").
-- Without closing: cast/turn in place only. No mirror if: his burst is lethal now; less than
-- MIRROR_MIN_HP_LEFT would remain after his next raze; we are under his T1 without a creep shield.
H._mirrorOrder = { nil, nil, nil }
function H.HandleInstantMirrorRaze(bot, enemyHero, race, s)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- While fleeing we MAY answer (an instant reply to his raze that hit us) -
    -- this is a deliberate "turn, cast, run again", not twitching (as it was before v2.6)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local age = U.GetRecentEnemyRazeHitAge(enemyHero)
    if age > ((C.RAZE and C.RAZE.MIRROR_INSTANT_SEC) or 0.7) then return false end
    -- Deduplicate the enemy HIT, not all our casts for 1.2 seconds.
    local hitTime = GameTime() - age
    if State.mirrorAnsweredEnemy == enemyHero and State.mirrorAnsweredHit
        and math.abs(State.mirrorAnsweredHit - hitTime) < 0.001 then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    local canKillNow = race and race.valid and race.canKillNow
    if race and race.valid and race.heCanKillNow and not canKillNow then return false end
    local oneRaze = K.EnemyRazeDamage(bot, enemyHero, 1)
    if not canKillNow and (bot:GetHealth() - oneRaze) < ((C.RAZE and C.RAZE.MIRROR_MIN_HP_LEFT) or 110) then
        return false
    end
    local underT1 = H.IsBotUnderEnemyT1(bot, s and s.enemyTowers or {})
    if underT1 and not H.TowerLockedOnCreep(s and s.enemyT1) then return false end
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
        return false
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemyHero)
    local order = H._mirrorOrder
    local n = 0
    if hitLabel then n = n + 1; order[n] = hitLabel end
    for i = 1, 3 do
        if K.LABELS[i] ~= hitLabel then n = n + 1; order[n] = K.LABELS[i] end
    end
    for i = 1, n do
        local ab = H.GetRazeAbilityByLabel(bot, order[i])
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                if U.DEBUG then print(string.format("[SF-BOT] instant mirror %s (%s) age=%.2f", order[i], actionType, age)) end
                return true
            end
        end
    end
    return false
end

function H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false end
    local shouldClose, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not shouldClose or not closePos then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local canQuickRazeKill, _ = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
    elseif U.IsInEnemyRazeKillThreat(bot, enemyHero) then
        return false
    end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            -- Via the shared CastOrTurnRaze (facing check + turn step, not walking to the enemy)
            local actionType = H.RazeFacingOK(bot, predicted) and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false end
    -- The mana reserve for the near punish was removed (v2.3 gated it with a 130 reserve: at 141 mana the bot
    -- silently stood in the near band and took stacks). The enemy walked up close - that is the best moment
    -- for a trade: a near raze now, mid/far at the runner. Only 75 mana is needed.
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and safeReplyLabel ~= "near" then return false end
    -- Robust - the near circle must cover the enemy both now and after the cast time
    -- (an enemy leaving the near band is not "punished" with a raze into thin air)
    -- A margin of >= 100 u from the near circle edge: an enemy standing at the edge (380-450) gets out of
    -- the circle during the cast as soon as he starts moving; such a target is hit by the mid raze (via GetBestRaze).
    if K.IsEnemyMovingAway(bot, enemyHero) then return false end
    local errAim, errFacing, predicted = U.RobustRazeErrors(bot, enemyHero, C.RAZE.NEAR_CENTER, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - 100
    if errAim > limit then return false end
    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then return false end
    if H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
        if oneRaze < enemyHero:GetHealth() then return false end
    end
    local actionType = "TURN"
    if errFacing <= limit then -- Same threshold as the candidate (no TURN dead zone)
        actionType = "CAST"
    end
    if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
        if actionType == "CAST" then
            -- Chain window: for the next ~5 s the stack-finishing razes go without a mana reserve
            State.nearChainUntil = GameTime() + ((C.RAZE and C.RAZE.NEAR_CHAIN_WINDOW) or 5.0)
        end
        return true
    end
    return false
end

-- The enemy walked up close - punishing him beats waiting for the last hit. Previously at this moment
-- the last-hit block ran (is_free_to_prehit = false) and the bot silently stood by the creep while being hit.
-- Try the near raze first; if it does not cover, finish for sure with mid/far
-- and extend the stack (he is already in reach, too late for him to leave).
function H.HandleCloseEnemyPunish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.RAZE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist > (cfg.PUNISH_CLOSE_RANGE or 520) then return false end
    if H.GetPotentialCombatMana(bot) < (cfg.PUNISH_MIN_POT_MANA or 150) then return false end
    local R = K._race
    local weWin = R and R.valid and (R.canKillSoon or R.edge > 0)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not weWin and not U.CanOneShotEnemyHero(bot, enemyHero) then
        return false
    end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then return false end

    if H.HandleImmediateNearRazePunish(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps) then
        return true
    end

    -- Near does not cover - hit with mid/far and extend the stack
    State.nearChainUntil = math.max(State.nearChainUntil or 0, GameTime() + (cfg.NEAR_CHAIN_WINDOW or 5.0))
    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, true) then
        return true
    end
    return false
end

function H.HandleBootDisadvantageMidRazeFear(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if not U.ShouldFearBootsMidRaze(bot, enemyHero) then return false end
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = (C.BOOT_FEAR and C.BOOT_FEAR.MID_RAZE_RADIUS) or 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- Short step past the band edge
    H.BeginForcedRetreat(bot, retreatLoc, (C.BOOT_FEAR and C.BOOT_FEAR.RETREAT_DURATION) or 0.95)
    return true
end

-- Is any "mid band fear" active (same conditions as the three handlers below,
-- without the distance check). The U._midFear flag makes the minimum enemy distance proactive.
function H.MidRazeFearActive(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) or not U.EnemyHasRaze(enemyHero) then return false end
    -- Do not back off past our own T1: the tower will punish him and retreating behind it loses the lane
    if H.IsNearOwnT1(bot, 400) then return false end
    if State.enemyReachedLevel2First and bot:GetLevel() < 2 then return true end
    if H.IsDryVsEnemyRaze(bot, enemyHero) then return true end
    if H.IsManaBudgetDisadvantage(bot, enemyHero) then return true end
    if U.ShouldFearBootsMidRaze(bot, enemyHero) and not U.IsInEnemyRazeKillThreat(bot, enemyHero)
        and not U.CanKillEnemyWithTwoRazes(bot, enemyHero) then
        return true
    end
    return false
end

function H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not State.enemyReachedLevel2First then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
        return false
    end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- Short step past the band edge
    H.BeginForcedRetreat(bot, retreatLoc, 0.90)
    return true
end

function H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps)
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    -- The tower is nearly down - stay under it and finish it
    if LN.IsTowerFinishable(bot, t1) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    local closestDist = math.huge
    local closestCreep = nil
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                local d = GetUnitToLocationDistance(t1, c:GetLocation())
                if d < closestDist then
                    closestDist = d
                    closestCreep = c
                end
            end
        end
    end
    local prevDist = State.enemyT1ClosestCreepDist
    State.enemyT1ClosestCreepDist = (closestCreep and closestDist) or nil
    State.enemyT1ClosestCreepTime = GameTime()
    local driftStart = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_START) or 620
    local driftHard = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_HARD) or 700
    local driftDelta = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_DELTA) or 22
    local shouldRetreat = false
    if not closestCreep then
        shouldRetreat = true
    elseif closestDist >= driftHard then
        shouldRetreat = true
    elseif prevDist and closestDist >= driftStart and closestDist > (prevDist + driftDelta) then
        shouldRetreat = true
    end
    if not shouldRetreat then return false end
    if H.TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps) then return true end
    local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
    H.BeginForcedRetreat(bot, safeLoc, 0.90)
    return true
end

function H.HandleGuaranteedAttackKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if not canOneShot then return false end
    local enDry = (U.GetPotentialManaForRaze(enemyHero) or 0) < 75
    local extraOneShotReach = (enDry and (bot:GetHealth() or 0) >= 85) and 215 or 60
    local attackRange = bot:GetAttackRange() + extraOneShotReach
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    -- Hitting a hero inside his T1 radius draws the tower onto us: only with an HP margin
    -- (>= 40 % and >= 3 tower shots) and not right after leaving the tower
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 then
        local hp = bot:GetHealth()
        if H.TowerBurnActive() or hp < bot:GetMaxHealth() * 0.40 or hp < 300 then return false end
    end
    if dist <= attackRange then
        H.ClearForcedRetreat()
        State.fleeUntil = 0
        State.commitKillUntil = GameTime() + 1.8
        H.IssueHeroAttack(bot, enemyHero)
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        State.commitKillUntil = GameTime() + 2.5
        return true
    end
    if dist <= attackRange + 300 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 250)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleGuaranteedRazeKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local dNowRazeKill = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if GameTime() < (State.reverseFarUntil or -1000) and dNowRazeKill < 575 then
        local away = (bot:GetLocation() - enemyHero:GetLocation()):Normalized()
        bot:Action_MoveToLocation(enemyHero:GetLocation() + away * 600)
        H.ClearMoveCache()
        State.actionTaken = true
        State.commitKillUntil = GameTime() + 2.0
        return true
    end
    local canKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if not canKill then
        -- Immortal Reverse Step-Back Far-Coil Finish (`Q -> W -> step-back E` at `210..515u`):
        -- Step cleanly out to `575u` FIRST so the `43u` 180-deg turn step lands at `532u` (`>= 515u`, zero ping-pong!)
        local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
        if eAb and eAb:GetLevel() > 0 and eAb:IsCooldownReady()
            and (bot:GetMana() + U.GetMangoMana(bot) + U.GetStickCharges(bot) * 15) >= 75
            and not bot:IsSilenced() and dNowRazeKill >= 210 and dNowRazeKill < 515
            and U.GetNRazeDamage(bot, enemyHero, 1) >= (enemyHero:GetHealth() or 9999) then
            State.reverseFarUntil = GameTime() + 1.2
            local away = (bot:GetLocation() - enemyHero:GetLocation()):Normalized()
            bot:Action_MoveToLocation(enemyHero:GetLocation() + away * 600)
            H.ClearMoveCache()
            State.actionTaken = true
            State.commitKillUntil = GameTime() + 2.0
            return true
        end
        return false
    end
    -- Do not cancel the swing of an attack that kills him anyway
    if H.IsHeroAttackWindupLocked(bot) then
        local oneShot = U.CanOneShotEnemyHero(bot, enemyHero)
        if oneShot then return false end
    end
    -- Pop Mango / Magic Stick immediately when lethal raze needs instant burst mana (`BAR 5:09` 27 MP + Mango vs 108 HP!)
    if (bot:GetMana() or 0) < 75 then
        if H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
        return false
    end
    local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
    if ability then
        local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
        local angleDiff = U.GetAngleDifference(bot, predLoc)
        if angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST then
            bot:Action_UseAbility(ability)
            H.StartRazeCast(ability, enemyHero, predLoc, C.RAZE.HIT_RADIUS)
            H.ClearMoveCache()
            -- "Finish" commitment: for the next seconds we do not run or twitch
            State.commitKillUntil = GameTime() + 2.5
            return true
        else
            -- CRITICAL (`9056469656.dem` `04:08.5s–04:11.3s` triple bug fix):
            -- NEVER pass a turn-to-kill step through `H.SmartMove` -> `U.ClampMinDistFromEnemy`, which flipped `stepLoc`
            -- `180 deg` AWAY from `predLoc` whenever `bot` was low HP! And step at least `C.RAZE.TURN_STEP` (`45u`) so
            -- Source 2 C++ turns SF `51.6 deg/tick` (`180 deg` in `3` ticks = `0.097s`) straight onto `predLoc` and one-shots!
            local botLoc = bot:GetLocation()
            local dir = (predLoc - botLoc):Normalized()
            local turnStep = math.max(C.RAZE.TURN_STEP or 40, 48)
            local stepLoc = botLoc + dir * math.min(turnStep, math.max(turnStep, U.DistanceBetweenLocations(botLoc, predLoc)))
            bot:Action_MoveToLocation(stepLoc)
            H.ClearMoveCache()
            State.actionTaken = true
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
    end
    return false
end

function H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 2.2)
    end
    if not enemyIsHittingUs and State.heroReplyEnemy == enemyHero
        and GameTime() - (State.heroReplyAttackTime or -100) <= ((C.MIRROR_REPLY and C.MIRROR_REPLY.ATTACK_WINDOW) or 2.2) then
        enemyIsHittingUs = true
    end

    if not enemyIsHittingUs then return false end

    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local R = K._race
    local parity = H.IsSymmetricHeroState(bot, enemyHero, R)

    -- I am weaker (level/souls/items/HP): the right-click trade is lost beforehand. Do not answer
    -- without support (my creeps/tower hitting him) - leave his attack radius toward our own
    -- creeps/tower. Chasing us while attacking, he loses distance (each attack = 0.5 s standing still)
    -- and his attack on a hero draws aggro from my creeps.
    if State.defensive and not parity and not H.HasTradeSupport(R) and not (R and R.valid and R.canKillSoon) then
        local enRange = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.KITE_PAD) or 140)
        if dist <= enRange then
            local botLoc = bot:GetLocation()
            local eLoc = enemyHero:GetLocation()
            local away = botLoc - eLoc
            if dist < 1 then away = P.GetT1Close(bot) - botLoc end
            away = away:Normalized()
            local toHome = (P.GetT1Close(bot) - botLoc):Normalized()
            local need = (enRange - dist) + 80
            local target = botLoc + (away * 0.6 + toHome * 0.4):Normalized() * need
            target = H.GetSafeApproach(bot, target, enemyTowers, allyCreeps)
            H.SmartMove(bot, target, 60)
            State.actionTaken = true
            return true
        end
        return false
    end

    if dist > bot:GetAttackRange() + 50 then return false end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local enAtk = K.AttackDamageVs(enemyHero, bot)
    if myHpPct < 0.25 and not (parity and bot:GetHealth() >= enAtk * 1.25 + 60) then return false end

    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then return false end

    H.IssueHeroAttack(bot, enemyHero, true)
    if State.heroReplyEnemy == enemyHero then State.heroReplyAnsweredAttack = true end
    State.lastHarassTime = GameTime()
    State.lastAggroTime = GameTime()
    State.aggroPullTime = GameTime() + 0.25
    return true
end


-- Raze dodging (any band), sticky tango, zoning, pushing, intents

-- Dodge: the enemy is in a raze cast phase and we are inside his circle -> leave the circle directly
-- (pathfinding movement) if we make it in time; otherwise counter-raze (trade) if his raze is not lethal.
function H.HandleEnemyRazeDodge(bot, enemyHero)
    local now = GameTime()
    local label, elapsed, remaining = K.EnemyPhase()
    if State.dodgeLoc and now < State.dodgeUntil then
        -- While dodging we keep watching his cast: he may CANCEL the raze
        -- (we left the circle) and immediately cast another band - previously we blindly ran for 0.6 s toward
        -- the old point and took a new raze at point blank ("dodges slowly").
        local E = K._enemy
        local newCast = label and (label ~= State.dodgeLabel
            or math.abs((E.phaseStart or -1) - (State.dodgePhaseStart or -2)) > 0.01)
        local cancelled = (not label) and (now - (State.dodgePhaseStart or -10)) < (C.RAZE.CAST_POINT - 0.05)
        if newCast then
            State.dodgeLoc = nil -- Re-evaluated below
        elseif cancelled then
            State.dodgeLoc = nil
            State.dodgeUntil = 0
            return false
        elseif label and enemyHero and U.CanQuery(enemyHero) then
            local liveCenter = K.EnemyRazeCenter(enemyHero, label)
            if U.DistanceBetweenLocations(bot:GetLocation(), liveCenter) > C.RAZE.HIT_RADIUS + 26 then
                State.dodgeLoc = nil
                State.dodgeUntil = 0
                return false
            end
            bot:Action_MoveToLocation(State.dodgeLoc)
            State.lastMoveLoc = State.dodgeLoc
            State.lastMoveTime = now
            State.actionTaken = true
            return true
        else
            State.dodgeLoc = nil
            State.dodgeUntil = 0
            return false
        end
    end
    State.dodgeLoc = nil
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not label then return false end
    local center = K.EnemyRazeCenter(enemyHero, label)
    local botLoc = bot:GetLocation()
    local dFromCenter = U.DistanceBetweenLocations(botLoc, center)
    local R = C.RAZE.HIT_RADIUS
    if dFromCenter > R + 40 then return false end

    local dmg = K.EnemyRazeDamage(bot, enemyHero, 1)
    local myHp = bot:GetHealth()
    local lethal = (dmg >= myHp - 25) or (myHp <= 260)
    local ms = bot:GetCurrentMovementSpeed() or 305
    local selfCasting = bot:IsUsingAbility() or bot:IsChanneling() or (State.aimingRaze ~= nil)

    -- Exact 360-degree analytic ray-circle exit solver + EXACT Radial Normal (`k = -1`):
    -- Evaluates the exact Euclidean shortest escape ray `(botLoc - center):Normalized()` (`sExit = rSafe - dFromCenter`)
    -- FIRST (saving 1–2 ticks on outer `Shadowraze3` edge pokes at `755..928u`!) plus 16 candidate rays around `360 deg`.
    local eLoc = enemyHero:GetLocation()
    local fnt = P.GetFountain(bot)
    local homeDir = (fnt - botLoc):Normalized()
    local px, py = botLoc.x - center.x, botLoc.y - center.y
    local p2 = px * px + py * py
    local pNorm = math.sqrt(math.max(1e-6, p2))
    local bestEscapeLoc, bestScore = nil, -1e9

    for _, pad in ipairs(lethal and { 18, 6 } or { 22, 8 }) do
        local rSafe = R + pad
        if dFromCenter >= rSafe then
            bestEscapeLoc = botLoc + homeDir * 120
            break
        end
        local r2Diff = rSafe * rSafe - p2
        for k = -1, 15 do
            local ux, uy
            if k == -1 then
                -- Exact shortest radial normal directly out of the `250u` Shadowraze circle!
                ux, uy = px / pNorm, py / pNorm
            else
                local ang = k * (2 * math.pi / 16)
                ux, uy = math.cos(ang), math.sin(ang)
            end
            local pDotU = px * ux + py * uy
            local sExit = -pDotU + math.sqrt(math.max(0, pDotU * pDotU + r2Diff))
            local cand = Vector(botLoc.x + ux * (sExit + 18), botLoc.y + uy * (sExit + 18), botLoc.z)
            if type(IsLocationPassable) ~= "function" or IsLocationPassable(cand) then
                local turnAng = U.GetAngleDifference(bot, cand)
                local turnTime = 0.03 * math.rad(turnAng) / 0.9
                if (remaining - turnTime - 0.015) * ms >= sExit then
                    local postEnemyDist = U.DistanceBetweenLocations(cand, eLoc)
                    local homeAlign = ux * homeDir.x + uy * homeDir.y
                    local score = postEnemyDist + homeAlign * 140 - sExit * 0.35
                    if score > bestScore then
                        bestScore = score
                        bestEscapeLoc = cand
                    end
                end
            end
        end
        if bestEscapeLoc then break end
    end

    if bestEscapeLoc and (not selfCasting or lethal) then
        if selfCasting then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
        end
        State.dodgeLoc = bestEscapeLoc
        State.dodgeUntil = now + remaining + 0.06
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        bot:Action_MoveToLocation(bestEscapeLoc)
        State.lastMoveLoc = bestEscapeLoc
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end

    -- `v4.0.0` Anti-Edge-Poke Synchronous Mirror Coil (`auto-20261023-0119` `Shadowraze3` Fix!):
    -- When `bestEscapeLoc == nil`, the incoming raze is ALREADY mathematically guaranteed to land inside `remaining`!
    -- Meanwhile, the casting enemy SF is FROZEN in his own `0.55s` animation lock!
    -- Therefore, whenever we comfortably survive his hit + follow-up (`myHp > dmg + enAtk + 95`) and are NOT fleeing in lethal
    -- danger (`not forcedRetreatLoc`), IMMEDIATELY fire our centered mirror raze (`E` at `700u`, `W` at `450u`, `Q` at `200u`)
    -- right into his frozen model so he NEVER gets a free `1-for-0` poke even when our HP sits between `32%..58%`!
    local R_race = K._race
    local dHeroCast = U.DistanceBetweenLocations(botLoc, eLoc)
    -- `v4.0.0` Outer `Shadowraze3` Mirror Reciprocity (`label == "far"`, `dHeroCast >= 645u`, `auto-20261023-0119` fix!)
    -- WHILE keeping `S8` + `S15` `0:00` inner `Q`/`W` (`< 645u`) 100% protected from `0.55s` conveyor self-root!
    local curMyStacks = U.GetShadowrazeDebuff(bot) or 0
    local outMatchedChase = ((enemyHero:GetLevel() or 1) > (bot:GetLevel() or 1))
        or (R_race and R_race.valid and (R_race.heCanKillSoon or R_race.heHasBootsLead))
    local safeFarMirror = (label == "far" and dHeroCast >= 660 and curMyStacks == 0 and not outMatchedChase and myHp > dmg + 125)
    local unsafeCloseTrade = ((myHp / math.max(1, bot:GetMaxHealth() or 1)) < 0.58)
        or outMatchedChase
        or (R_race and R_race.valid and R_race.losingHard)
    local unsafeToStandAndTrade = (State.forcedRetreatLoc ~= nil)
        or (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0))
        or (not safeFarMirror and unsafeCloseTrade)
        or (R_race and R_race.valid and R_race.heCanKillNow)
    if not selfCasting and not lethal and not unsafeToStandAndTrade then
        if (bot:GetMana() or 0) < 75 and H.MyReadyRazeExists and H.TryUseBurstManaItem and H.TryUseBurstManaItem(bot, true) then
            return true
        end
        if (bot:GetMana() or 0) >= 75 then
            for _, lbl in ipairs(H.BestCenteredRazeOrder(bot, enemyHero)) do
                local ab = H.GetRazeAbilityByLabel(bot, lbl)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
                    if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                        return true
                    end
                end
            end
        end
    end

    -- Even if caught inside the inner bullseye (`sExit > remaining * ms`) where we cannot fully exit
    -- coil #1 before detonate, NEVER stand still inside the center to eat coil #2/#3 right after!
    if not selfCasting then
        local stepOut = botLoc + homeDir * 240
        bot:Action_MoveToLocation(stepOut)
        State.lastMoveLoc = stepOut
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end
    return false
end

-- Sticky tango tree: pick once and keep it (COMMIT_TIME) until eaten / it became
-- dangerous / we got stuck. Filters: far from the enemy tower, not closer to the enemy, same height level.
function H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
    -- Defensive C++ `HSCRIPT` userdata guard: NEVER allow `pairs(userdata)` if arguments were reversed!
    if type(enemyHero) == "table" and type(enemyHero.GetLocation) ~= "function" then
        enemyHero, enemyTowers = enemyTowers, enemyHero
    end
    local safeTowerList = (type(enemyTowers) == "table") and enemyTowers or {}
    local now = GameTime()
    local cfg = C.TANGO or {}
    local botLoc = bot:GetLocation()
    local enemyLoc = (enemyHero and U.CanQuery(enemyHero)) and enemyHero:GetLocation() or nil

    if State.tangoTree and State.tangoTreeLoc then
        local age = now - State.tangoChosenAt
        local d = U.DistanceBetweenLocations(botLoc, State.tangoTreeLoc)
        if d < State.tangoBestDist - 15 then
            State.tangoBestDist = d
            State.tangoProgressAt = now
        end
        local stuck = d > 165 and (now - (State.tangoProgressAt or State.tangoChosenAt)) > (cfg.STUCK_TIME or 4.0)
        local unsafe = enemyLoc and U.DistanceBetweenLocations(State.tangoTreeLoc, enemyLoc) < ((cfg.ENEMY_MIN_DIST or 650) - 150)
        if age <= (cfg.COMMIT_TIME or 8.0) and not stuck and not unsafe then
            return State.tangoTree, State.tangoTreeLoc
        end
        if stuck then
            State.tangoBadTree = State.tangoTree
            State.tangoBadTreeTime = now
        end
        State.tangoTree = nil
        State.tangoTreeLoc = nil
    end

    local trees = bot:GetNearbyTrees(cfg.SEARCH_RADIUS or 1400)
    if not trees or #trees == 0 then return nil, nil end
    local myH = nil
    if type(GetHeightLevel) == "function" then myH = GetHeightLevel(botLoc) end
    local fountain = P.GetFountain(bot)
    local allyT1Loc = (W.s and W.s.allyT1Loc) or P.GetT1Close(bot)
    local t1FntDist = allyT1Loc and U.DistanceBetweenLocations(allyT1Loc, fountain) or 6800

    local best, bestLoc, bestScore = nil, nil, math.huge
    for pass = 1, 2 do
        for _, tree in ipairs(trees) do
            local bad = (State.tangoBadTree == tree) and (now - State.tangoBadTreeTime) < 20
            if not bad then
                local loc = GetTreeLocation(tree)
                local ok = true
                -- Strict Own-Side Tango Invariant (`v3.9.0`, `auto-20261022-2237` `00:53..01:22` `(-923, +867)` 29s Walk Fix!):
                -- NEVER choose a tree across the river or in the enemy jungle/triangle (`locFntDist > t1FntDist + 480`
                -- or `dist(tree, allyT1) > 1050u`)!
                local locFntDist = U.DistanceBetweenLocations(loc, fountain)
                if locFntDist > t1FntDist + 480 then ok = false end
                if ok and allyT1Loc and U.DistanceBetweenLocations(loc, allyT1Loc) > 1050 then ok = false end
                if ok then
                    for _, tower in pairs(safeTowerList) do
                        if tower:IsAlive() and GetUnitToLocationDistance(tower, loc) < (cfg.TOWER_MIN_DIST or 1125) then
                            ok = false
                            break
                        end
                    end
                end
                if ok and enemyLoc and U.DistanceBetweenLocations(loc, enemyLoc) < (cfg.ENEMY_MIN_DIST or 650) then ok = false end
                if ok and pass == 1 and myH and GetHeightLevel(loc) ~= myH then ok = false end
                if ok then
                    local score = U.DistanceBetweenLocations(botLoc, loc)
                    score = score + locFntDist * 0.14
                    if score < bestScore then
                        bestScore, best, bestLoc = score, tree, loc
                    end
                end
            end
        end
        if best then break end
    end
    if best then
        State.tangoTree = best
        State.tangoTreeLoc = bestLoc
        State.tangoChosenAt = now
        State.tangoBestDist = math.huge
        State.tangoProgressAt = now
    end
    return best, bestLoc
end

function H.ClearTangoState()
    State.tangoTree = nil
    State.tangoTreeLoc = nil
    State.tangoCastAt = 0
end

-- Context + the intent FSM. Returns the intent.
-- "Hunt" (complaint: +400 HP against a low-HP enemy and the bot farms). Go for the kill when:
-- raze >= 2 points, absolute HP edge >= HUNT_HP_EDGE, my HP >= HUNT_MIN_HP_PCT, he is not under
-- his T1, his burst on me from mid range is not dangerous (HUNT_SAFETY_HP margin), my burst over
-- HUNT_HORIZON with an approach into the mid band (razes that come off cooldown; mana WITH mango;
-- 1-2 right clicks) covers his HP, and he is catchable. Hysteresis: while hunting the thresholds are softer.
function H.ComputeHunt(bot, s, race, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) or not race or not race.valid then return false end
    -- He is TPing back to his T1 (fresh, full) - do not fly in
    if (State.enemyTPIncomingUntil or 0) > s.now then return false end
    local cfg = C.INTENT or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() < 2 then return false end
    local was = State.hunting and true or false
    local edgeNeed = (cfg.HUNT_HP_EDGE or 250) - (was and 60 or 0)
    if race.hpDiff < edgeNeed then return false end
    local myHp = race.myHp
    if (myHp / math.max(1, bot:GetMaxHealth())) < ((cfg.HUNT_MIN_HP_PCT or 0.40) - (was and 0.05 or 0)) then return false end
    if race.dist > ((cfg.HUNT_MAX_DIST or 1100) + (was and 150 or 0)) then return false end
    if race.heCanKillSoon then return false end
    local t1 = s and s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 760 then
            return false
        end
    end
    local dmg, n = K.MyHuntBurst(bot, enemyHero, cfg.HUNT_HORIZON or 4.0)
    if dmg < race.enHp + (was and -20 or 10) then return false end
    -- His answer during my finish: as many razes as I need (no more than his
    -- ready ones by cooldown/mana with mango), against my current stacks; right clicks are not counted - he is casting.
    -- His full 2.5 s burst (3 razes = ~970) is irrelevant here: he dies before the third.
    local hisReady = K.EnemyReadyRazeCount(enemyHero, 1.5, true)
    local hisN = math.min(math.max(n, 1), hisReady)
    local enBurst = K.EnemyRazeDamage(bot, enemyHero, hisN)
    if enBurst >= myHp - (cfg.HUNT_SAFETY_HP or 80) then return false end
    if not K.CanCatch(bot, enemyHero, C.RAZE.MID_CENTER + 200, 2.5) then return false end
    return true
end

function H.UpdateIntent(bot, s, race)
    local ctx = IntentCtx
    local enemyHero = s.enemy
    ctx.enemy = enemyHero ~= nil
    ctx.race = race
    ctx.myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    ctx.myRazes = K.MyReadyRazeCount(bot, true)
    ctx.healing = U.IsActivelyHealing(bot)
    ctx.enemyDist = s.enemyDist
    ctx.levelDeficit = enemyHero and math.max(0, (enemyHero:GetLevel() or 1) - (bot:GetLevel() or 1)) or 0
    local tempo = T.Get(bot)
    ctx.tempoBehind = tempo and tempo.mode == T.BEHIND
    ctx.tempoAhead = tempo and tempo.mode == T.AHEAD
    ctx.enemyAbsent = W.EnemyAbsent((C.INTENT and C.INTENT.ENEMY_ABSENT_SEC) or 5.0)
    -- A live enemy disappeared near the lane (highground/trees/fog) - most likely he is
    -- lurking, not gone. Do not count him as "absent" before 12 s.
    if ctx.enemyAbsent and s.enemyAlive and s.enemyLastLoc and s.enemyAbsentFor < 12.0 then
        if U.DistanceBetweenLocations(s.enemyLastLoc, bot:GetLocation()) < 1400 then
            ctx.enemyAbsent = false
        end
    end
    ctx.enemyDistToWave = enemyHero and LN.EnemyDistToAllyWave(enemyHero, s.allyCreeps) or 99999
    ctx.enemyUnderHisTower = false
    ctx.underEnemyTower = false
    local t1 = s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc then
            if enemyHero then
                ctx.enemyUnderHisTower = U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 720
            end
            ctx.underEnemyTower = LN.TowerDanger(bot, t1, s.allyCreeps, nil) >= 2
        end
    end
    ctx.canCatch = enemyHero and K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER, 2.0) or false
    ctx.defensive = State.defensive and not H.HasTradeSupport(race)
    ctx.waveAtMyTower = WV.AtMyTower(bot)
    ctx.waveNoPush = WV.BlockPush(bot, s)
    -- He is TPing to his T1 (channel visible / respawned after death)
    ctx.enemyTPIncoming = (State.enemyTPIncomingUntil or 0) > s.now
    ctx.enemyT1Dist = 99999
    if t1 then
        local okT1, t1Loc = pcall(t1.GetLocation, t1)
        if okT1 and t1Loc then
            ctx.enemyT1Dist = U.DistanceBetweenLocations(bot:GetLocation(), t1Loc)
        end
    end
    ctx.towerChaseBlocked = enemyHero ~= nil and State.towerChaseBlockedEnemy == enemyHero
    ctx.hunt = not ctx.towerChaseBlocked and H.ComputeHunt(bot, s, race, enemyHero)
    State.hunting = ctx.hunt
    local intent = I.Update(ctx, s.now)
    State.intent = intent
    if U.DEBUG and (s.now - State.lastIntentPrint) > 2.0 then
        State.lastIntentPrint = s.now
        print(string.format("[SF-BOT] intent=%s (%s) edge=%.0f myB=%.0f enB=%.0f dist=%.0f",
            intent, I.reason, race.valid and race.edge or 0, race.valid and race.myBurstSoon or 0,
            race.valid and race.enBurstSoon or 0, s.enemyDist))
    end
    return intent
end

-- Retreat under the RETREAT intent: get outside the enemy's ready bands toward our own T1.
-- If we are already far enough, do nothing (farming under the tower takes over).
function H.ExecuteRetreat(bot, enemyHero, race)
    -- We took the finish commitment - do not run
    if GameTime() < (State.commitKillUntil or 0) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local hp = bot:GetHealth()
    local critical = race.valid and race.enBurstNow >= hp
    H.BeginForcedRetreat(bot, safeLoc, critical and 1.0 or 0.6)
    return true
end

-- Zoning: stand between the enemy and our wave at HOLD_DIST (outside his near band), right-click him
-- when he is in attack range; do not leave the wave; do not stand in his READY bands.
function H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.ZONE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    -- 0) if he is in a band I can cast and mana allows - the raze (pressure) outranks positioning
    local canPressure = H.ShouldTryRazePressure(bot, enemyHero, "AGGRESSIVE", 0)
    if canPressure and dist <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS then
        if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return true end
    end
    local hold = cfg.HOLD_DIST or 520
    -- Do not stand in his ready band: push the distance past its edge
    local minSafe = race.valid and race.minSafeDist or 0
    if minSafe > hold then hold = minSafe end
    -- A right click if he is in range and it does not walk us into his ready band
    local attackRange = bot:GetAttackRange() + (cfg.ATTACK_RANGE_PAD or 40)
    if dist <= attackRange and dist >= minSafe - 30 then
        if H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) and not H.IsHeroAttackWindupLocked(bot) then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end
    local pos = LN.ZonePosition(bot, enemyHero, allyCreeps, hold, cfg.MAX_FROM_WAVE or 520)
    if not pos then return false end
    -- If the position requires closing on a fleeing enemy - do not run after him
    local dAfter = U.DistanceBetweenLocations(pos, enemyHero:GetLocation())
    if dAfter < dist - 60 and not K.CanCatch(bot, enemyHero, dAfter, 1.5) then
        return false
    end
    pos = H.GetSafeApproachLoose(bot, pos, enemyTowers or {}, allyCreeps or {})
    if GetUnitToLocationDistance(bot, pos) > 70 then
        return H.SmartMove(bot, pos, 45)
    end
    -- In place: hold the position (final positioning must not pull the bot away) but
    -- hand control over further on - items/regens must still run.
    State.holdPos = true
    return false
end

function H.HandleIncomingTeleport(bot, s)
    if bot:IsChanneling() then return false end
    local teleports = s and s.incomingEnemyTPs or {}
    if #teleports == 0 then return false end

    -- `9056469656.dem` `03:09.32–03:17.25` Death #1 Root-Cause Fix:
    -- An enemy hero channeling TP from Fountain lands with **100% HP, 100% Mana (all 3 Shadowrazes off CD = 467–850
    -- post-resist magic burst + physical right-clicks)**! Checking only `hpPct < 0.55 or mana < 75` let our bot stand
    -- at `(-1037, -949) -> (-1348, -1091)` (`452u` from `tp.location = (-927.5, -898.1)`) with `557/940 = 59.3% HP`
    -- and `96 MP` (`1` coil vs `3` fresh coils + `918 HP`!), eating `W + Q + 2 autos + E + auto` = instant death!
    -- Even when `s.enemy` is `nil` in Fountain fog during channel, compute exact arriving threat from `s.enemyLastLevel`!
    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = curHp / maxHp
    local totalMana = (bot:GetMana() or 0) + U.GetMangoMana(bot) + (U.GetStickCharges(bot) * 15)
    local myReadyRazes = K.MyReadyRazeCount(bot, true)
    local estEnLvl = (s and s.enemyLastLevel) or math.max(2, bot:GetLevel() or 3)
    local razeLvl = math.max(1, math.min(4, (estEnLvl >= 7 and 4) or (estEnLvl >= 5 and 3) or (estEnLvl >= 3 and 2) or 1))
    local basePer = (C.RAZE.BASE_DAMAGE and C.RAZE.BASE_DAMAGE[razeLvl]) or 85
    local stackPer = (C.RAZE.STACK_DAMAGE and C.RAZE.STACK_DAMAGE[razeLvl]) or 35
    local soulsPer = (C.RAZE.DAMAGE_PER_SOUL) or 2
    local rawThreeRaze = 3 * (basePer + 14 * soulsPer) + 3 * stackPer -- 0+1+2 stacks + estimated souls
    local estFreshBurst = bot:GetActualIncomingDamage(rawThreeRaze, DAMAGE_TYPE_MAGICAL)
        + (((s and s.enemyLastAttackDmg) or 55) * 2.2)

    local mustEvacuate = (hpPct < 0.80)
        or (myReadyRazes < 2)
        or (totalMana < 150)
        or (curHp <= estFreshBurst + 120)
        or U.IsActivelyHealing(bot)
        or U.HasItem(bot, "item_flask")
    if not mustEvacuate then return false end

    -- Safe standoff outside ALL 3 Shadowrazes (`700 + 250 = 950u`) + walk-up buffer (`1,180u`)!
    local safeRadius = C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 230 -- 1,180u
    for _, tp in pairs(teleports) do
        State.freshEnemyTPArrivalUntil = math.max(State.freshEnemyTPArrivalUntil or 0, GameTime() + (tp.time_remaining or 3.0) + 7.5)
        local distance = GetUnitToLocationDistance(bot, tp.location)
        local nearEnemyT1 = s.enemyT1 and s.enemyT1:IsAlive()
            and GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) < 1180
        if distance < safeRadius or nearEnemyT1 then
            -- Start unlocking any Backpack `item_flask` immediately while running away during the 3.0s TP channel!
            if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
                H.EnsureConsumableReady(bot, "item_flask")
            end
            local fountain = P.GetFountain(bot)
            local toFountain = (fountain - tp.location):Normalized()
            local point = tp.location + toFountain * (safeRadius + 140)
            point = H.GetSafeApproach(bot, point, s.enemyTowers, s.allyCreeps)
            if U.DistanceBetweenLocations(point, tp.location) < safeRadius then
                local away = bot:GetLocation() - tp.location
                if distance < 1 then away = toFountain end
                local dir = away:Normalized()
                for _, candDir in ipairs({ toFountain, dir, Vector(-dir.y, dir.x, 0), Vector(dir.y, -dir.x, 0) }) do
                    local candidate = H.GetSafeApproach(bot, tp.location + candDir * (safeRadius + 160), s.enemyTowers, s.allyCreeps)
                    if U.DistanceBetweenLocations(candidate, tp.location) >= safeRadius then
                        point = candidate
                        break
                    end
                end
            end
            State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, GameTime() + tp.time_remaining + 2.5)
            State.prepTarget = nil
            State.lhAttackTarget = nil
            H.ClearRazeState()
            State.commitKillUntil = 0
            State.actionTaken = true
            return H.BeginForcedRetreat(bot, point, math.max(1.35, math.min(4.2, tp.time_remaining + 1.25)))
        end
    end
    return false
end

-- Post-TP Arrival Full-Combo Standoff (`R2_2044` `03:45.33..03:56.57` Triple-Coil After TP Fix!):
-- Once the 3.0s TP channel finishes, `s.incomingEnemyTPs` empties immediately — while the freshly teleported SF
-- charges across the river at `100% HP / 100% MP` (`387 MP` = `Q + W + E` ready!). Maintain strict `>= 985u` standoff
-- (outside `Shadowraze3 = 950u`) and prep/cast owned `item_flask` while depleted!
function H.HandleFreshEnemyTPArrival(bot, s, earlyRace)
    if bot:IsChanneling() or bot:IsUsingAbility() then return false end
    local now = GameTime()
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        if s and s.enemyAlive == false then
            State.enemyWasDeadRecentlyUntil = now + 22.0
        end
        return false
    end
    -- Also detect hidden-trees post-respawn arrival (`90%+ HP` & `225+ MP` right after respawn) even if TP landed in deep FoW!
    if now < (State.enemyWasDeadRecentlyUntil or -1000) then
        State.enemyWasDeadRecentlyUntil = -1000
        if (enemy:GetHealth() / math.max(1, enemy:GetMaxHealth())) >= 0.88 and U.GetPotentialManaForRaze(enemy) >= 225 then
            State.freshEnemyTPArrivalUntil = math.max(State.freshEnemyTPArrivalUntil or 0, now + 8.0)
        end
    end
    if now >= (State.freshEnemyTPArrivalUntil or -1000) then return false end
    if H.CanTwoHitRightClickKill(bot, enemy, s) or (earlyRace and earlyRace.valid and earlyRace.canKillNow) then
        return false
    end
    local enHpPct = (enemy:GetHealth() or 0) / math.max(1, enemy:GetMaxHealth() or 1)
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    if enHpPct < 0.72 or enPotMana < 150 then return false end

    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = curHp / maxHp
    local myPotMana = U.GetPotentialManaForRaze(bot)
    local myReady = K.MyReadyRazeCount(bot, true)
    if hpPct >= 0.80 and myReady >= 2 and myPotMana >= 150 and not U.IsActivelyHealing(bot) then
        return false
    end

    if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
        H.EnsureConsumableReady(bot, "item_flask")
    end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local standDist = 990 -- outside `Shadowraze3` (`700 + 250 = 950u`) + step margin
    if d < standDist then
        local fnt = P.GetFountain(bot)
        local anchor = enemy:GetLocation() + (fnt - enemy:GetLocation()):Normalized() * (standDist + 75)
        State.prepTarget = nil
        State.lhAttackTarget = nil
        H.SmartMove(bot, anchor, 45)
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleSeekAlliedWave(bot, s, race)
    State.waveScoutPoint = nil
    if #(s.allyCreeps or {}) > 0 then State.lastAlliedWaveSeen = GameTime(); return false end
    if GameTime() - (State.lastAlliedWaveSeen or -100) < 1.0 then return false end
    if State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) or bot:IsUsingAbility() or bot:IsChanneling()
        or U.IsActivelyHealing(bot) or bot:GetHealth() < bot:GetMaxHealth()*0.55 then return false end
    if (State.branchTango and GameTime()-State.branchTango.time<1.5)
        or State.needsTP or (GameTime()>20 and H.IsAtFountain(bot))
        or U.GetActiveItemByName(bot,"item_ward_observer")
        or (State.tangoTree and U.GetActiveItemByName(bot,"item_tango")) then return false end
    local scout = P.GetT1Close(bot, 500)
    for _, tp in pairs(s.incomingEnemyTPs or {}) do
        if GetUnitToLocationDistance(bot, tp.location) < 1300 or U.DistanceBetweenLocations(scout, tp.location) < 1300 then return false end
    end
    if s.enemyT1 and s.enemyT1:IsAlive() and GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) < 900 then return false end
    local point = scout
    if U.CanQuery(s.enemy) then
        if GetUnitToLocationDistance(s.enemy, point) < 1100 or GetUnitToLocationDistance(bot, s.enemy:GetLocation()) < 1100
            or (race and race.valid and race.heCanKillSoon) then return false end
    elseif s.enemyAlive and s.enemyLastLoc and (s.enemyAbsentFor or 0) < 5
        and U.DistanceBetweenLocations(point, s.enemyLastLoc) < 1200 then return false end
    if bot.GetIncomingTrackingProjectiles and #(bot:GetIncomingTrackingProjectiles() or {}) > 0 then return false end
    for _, creep in pairs(s.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then return false end
    end
    for _, tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(tower, point) < 900 then return false end
    end
    State.waveScoutPoint = point
    if GetUnitToLocationDistance(bot, point) > 45 then return H.SmartMove(bot, point, 30) end
    State.holdPos = true
    return false
end

function H.LaneEnemyAbsent(s)
    if s.enemyAlive == false then return true end
    if U.CanQuery(s.enemy) then return (s.enemyDist or 0) > 1800 and LN.EnemyDistToAllyWave(s.enemy, s.allyCreeps) > 1600 end
    local unseen = s.enemyAbsentFor or 0
    if unseen < 5 then return false end
    if unseen < 12 and s.enemyLastLoc and s.bot
        and U.DistanceBetweenLocations(s.enemyLastLoc, s.bot:GetLocation()) < 1400 then return false end
    return true
end

function H.PriorityPushAllowed(bot, s, race)
    if State.branchTango and GameTime()-State.branchTango.time<1.5 then return false end
    if State.needsTP or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc or GameTime() < (State.fleeUntil or 0) then
        return false
    end
    -- Post-kill (`s.enemyAlive == false`, `HUD 09:01`!): lane creeps NEVER cancel Salve or Tango in Dota 2 7.41f,
    -- so shove the wave immediately while healing!
    if s.enemyAlive ~= false and (bot:GetHealth() < bot:GetMaxHealth()*0.5 or U.IsActivelyHealing(bot)) then
        return false
    end
    local teleports = s.incomingEnemyTPs or {}
    if #teleports == 0 and GameTime() < (State.enemyTPIncomingUntil or 0) then return false end
    for _, tp in pairs(teleports) do
        if GetUnitToLocationDistance(bot, tp.location) < 1800
            or (s.enemyT1 and GetUnitToLocationDistance(s.enemyT1, tp.location) < 1200) then return false end
    end
    if U.CanQuery(s.enemy) then
        local distance = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
        if H.IsEnemyPressuring(bot, s.enemy) and distance < 1400 then return false end
        if K.HasRazeStackLead(bot,s.enemy) and K.EnemyBandsAcross(s.enemy,distance,distance,0.7)>0 then return false end
    end
    if H.LaneEnemyAbsent(s) then return true end
    return race and race.valid and not race.heCanKillSoon and race.edge >= (C.INTENT.PUSH_EDGE or 260)
        and s.enemyT1 ~= nil and GetUnitToLocationDistance(bot,s.enemyT1:GetLocation()) <= 1180
end

function H.HandleSiegeGlyph(bot, s, race)
    local tower = s.enemyT1
    if not U.CanQuery(tower) or tower:HasModifier("modifier_fountain_glyph")
        or (not H.LaneEnemyAbsent(s) and not H.PriorityPushAllowed(bot, s, race))
        or not U.IsGlyphAvailable(bot) or GetUnitToLocationDistance(bot, tower:GetLocation()) > 1450 then return false end
    if U.ShouldUseGlyphDefensive(bot, s.allyTowers) then return U.UseGlyph(bot) end
    local tank = tower:GetAttackTarget()
    if not U.CanQuery(tank) or tank == bot or (tank.IsHero and tank:IsHero())
        or tank:HasModifier("modifier_fountain_glyph") then return false end
    local allied = false
    for _, c in pairs(s.allyCreeps or {}) do if c == tank then allied = true; break end end
    -- Siege Creep attacks T1 from `827u` center-to-center (`690u` range + `144u` tower hull — `9055695956.dem` `tk=14218..14412`)!
    -- NEVER blow our 300s team Glyph on an ordinary `125 HP` ranged creep while T1 still has > 340 HP (`3.0s` creep Glyph in 7.41f!):
    -- wait until enemy T1 ACTUALLY locks onto our Siege Creep (`LN.IsSiege(tank)`) OR T1 is finishable (`<= 340 HP`)!
    if not allied or GetUnitToLocationDistance(tank, tower:GetLocation()) > 900 then return false end
    local isSiegeTank = LN.IsSiege and LN.IsSiege(tank)
    local towerLow = (tower:GetHealth() or 9999) <= 340
    if not isSiegeTank and not towerLow then return false end
    local hit = tank:GetActualIncomingDamage(tower:GetAttackDamage(), DAMAGE_TYPE_PHYSICAL)
    local threshold = isSiegeTank and (hit * 2.55) or (hit * 1.35)
    local imminent = tank:GetHealth() <= threshold
    for _, projectile in pairs(tank:GetIncomingTrackingProjectiles() or {}) do
        if projectile.caster == tower and projectile.is_attack and tank:GetHealth() <= threshold + hit * 0.65 then imminent = true end
    end
    if not imminent then return false end
    return U.UseGlyph(bot)
end

function H.HandleSiegeTower(bot, race, s)
    local tower = s.enemyT1
    if not U.CanQuery(tower) or tower:HasModifier("modifier_fountain_glyph") then return false end
    local distance = GetUnitToLocationDistance(bot, tower:GetLocation())
    -- Must strictly exceed `LN.TowerEscapePoint` (`1035u`, where `9055695956.dem` deadlocked forever at `dRT1 = 912u > 900u`!)
    if distance > 1180 then return false end
    local finish = LN.IsTowerFinishable(bot, tower)
    if not finish then
        local enemyAbsent = H.LaneEnemyAbsent(s)
        local burnBlocks = H.TowerBurnActive() and not enemyAbsent
        -- `9056774541.dem` `01:45` (`tk=6266..6336`) Fix: With `2x Bracer`, `492 / 990 HP = 49.7% < 50%`!
        -- When the enemy hero is dead/absent (`enemyAbsent`), 240 HP under creep shield is 100% safe free T1 damage;
        -- when the enemy hero is present, require `min(430, maxHP * 0.43)` instead of a flat `50% maxHP` penalty on Bracers!
        local minSiegeHp = enemyAbsent and 240 or math.min(430, bot:GetMaxHealth() * 0.43)
        if bot:GetHealth() < minSiegeHp or burnBlocks or tower:GetAttackTarget() == bot then return false end
        local point = tower:GetLocation() + (bot:GetLocation()-tower:GetLocation()):Normalized() * math.max(100, bot:GetAttackRange() + 115)
        if U.CanQuery(s.enemy) and not K.StackLeadStepSafe(bot,s.enemy,point) then return false end
        local activeTank = tower:GetAttackTarget()
        local hasLiveCreepTank = U.CanQuery(activeTank) and activeTank ~= bot and not (activeTank.IsHero and activeTank:IsHero())
        if not LN.CanHitTower(bot, tower, s.allyCreeps, 1)
            or (not hasLiveCreepTank and LN.TowerShieldCount(tower, s.allyCreeps, point) < 1) then return false end
        local enemyDryPassive = U.CanQuery(s.enemy)
            and ((s.enemy:GetMana() or 0) + U.GetMangoMana(s.enemy) < 75)
            and not H.IsEnemyPressuring(bot, s.enemy)
        local enemyBehindOwnT1 = U.CanQuery(s.enemy)
            and GetUnitToLocationDistance(s.enemy, tower:GetLocation()) < GetUnitToLocationDistance(bot, tower:GetLocation()) + 40
            and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) >= 760
        if U.CanQuery(s.enemy) and (not race.valid or race.heCanKillSoon or H.IsEnemyPressuring(bot,s.enemy)
            or (not enemyDryPassive and not enemyBehindOwnT1 and race.edge < (C.INTENT.PUSH_EDGE or 260) and not LN.EnemyBusyWithWave(bot,s.enemy)
                and GetUnitToLocationDistance(bot,s.enemy:GetLocation()) <= 950)) then return false end
    end
    State.prepTarget = nil; State.lhAttackTarget = nil
    -- Max-Range Siege Stance (`v3.9.0`, `06:44.70` `481u -> 620u` fix):
    -- If we drifted closer than `560u` to enemy T1 between swings, step back to `615u` so exit takes `< 0.70s` (`0` bolts)!
    local dTowerNow = GetUnitToLocationDistance(bot, tower:GetLocation())
    local lastAtkAge = GameTime() - (bot:GetLastAttackTime() or -100)
    if dTowerNow < 560 and lastAtkAge < 0.65 then
        local standEdge = tower:GetLocation() + (P.GetFountain(bot) - tower:GetLocation()):Normalized() * 615
        H.SmartMove(bot, standEdge, 25)
        State.actionTaken = true
        return true
    end
    if bot:GetAttackTarget() ~= tower or not U.IsAttackingAction(bot) then
        bot:Action_AttackUnit(tower, false)
        H.ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

-- ---------------------------------------------------------------------------
-- (towerLH) Under MY tower the tower is the last-hitter, and the bot never contests it: measured
-- 17.8 enemy-creep deaths per game go to our own tower, 11.8 of them within 700 of the bot and
-- 78 % of those WITHOUT the bot ever having hit the creep in the previous 2 s.  A human takes
-- those creeps by pre-swinging so that the hit lands right after the tower shot.  This runs at the
-- LOWEST priority (after every ordinary last hit/deny/punish), so it only uses otherwise idle
-- attack cycles, and asks for at most 2 tower shots of head-room.
function H.HandleTowerStealLastHit(bot, enemyCreeps, allyTowers, enemyTowers, allyCreeps)
    if C.LASTHIT.TOWER_STEAL_LH == false then return false end
    if State.actionTaken or not enemyCreeps then return false end
    local act = bot:GetCurrentActionType()
    if (act == BOT_ACTION_TYPE_ATTACK or (BOT_ACTION_TYPE_ATTACKUNIT ~= nil and act == BOT_ACTION_TYPE_ATTACKUNIT)) then return false end   -- already swinging at something
    local best, bestScore = nil, math.huge
    for _, c in ipairs(enemyCreeps) do
        if U.CanQuery(c) then
            local onTower = false
            for _, t in ipairs(allyTowers or {}) do
                if t and t:IsAlive() and t:GetAttackTarget() == c then onTower = true; break end
            end
            if onTower then
                local loc = c:GetLocation()
                local dist = GetUnitToLocationDistance(bot, loc)
                if dist <= (bot:GetAttackRange() or 525) + (C.LASTHIT.TOWER_STEAL_RANGE_PAD or 35) then
                    local hp = c:GetHealth()
                    -- one tower shot, as it will actually land on a creep
                    local shot = 90
                    for _, t in ipairs(allyTowers or {}) do
                        if t and t:IsAlive() and t:GetAttackTarget() == c and t.GetAttackDamage then
                            local ok, v = pcall(t.GetAttackDamage, t)
                            if ok and type(v) == "number" and v > 0 then shot = v end
                            break
                        end
                    end
                    local realShot = shot
                    if c.GetActualIncomingDamage then
                        local ok, v = pcall(c.GetActualIncomingDamage, c, shot, DAMAGE_TYPE_PHYSICAL)
                        if ok and type(v) == "number" and v > 0 then realShot = v end
                    end
                    local dr = U.SFDamageRange(bot, c)
                    -- (21.10) Contest the creep our own tower is working on MUCH earlier: the old window
                    -- (2.2 tower shots + one of my hits) only fired when the creep was one shot from
                    -- death, and our windup (0.5 s) plus the projectile arrived after the tower's shot.
                    -- In the four 21.10 demos our own mid T1 ate 23/7/18/22 creeps of OUR farm (26-43 %)
                    -- and the bot got 0-9 last hits in the whole game.  Three of my hits of headroom.
                    if hp <= realShot * (C.LASTHIT.TOWER_STEAL_SHOTS or 2.2) + 3 * dr.avg and hp > dr.avg * 0.5 then
                        if H.IsSafeToAttack(bot, loc, enemyTowers, allyCreeps) then
                            local score = hp - realShot
                            if score < bestScore then bestScore, best = score, c end
                        end
                    end
                end
            end
        end
    end
    if best then
        bot:Action_AttackUnit(best, true)
        State.lhAttackTarget = best
        State.attackTarget = best
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandlePriorityPush(bot, s, race)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or not H.PriorityPushAllowed(bot,s,race) then return false end
    if H.HandleSiegeGlyph(bot,s,race) then State.actionTaken=true;return true end
    if H.HandleEnemyTowerSafety(bot,s,s.enemy) then return true end
    if H.HandleSiegeTower(bot,race,s) then return true end
    if not H.LaneEnemyAbsent(s) then return false end
    -- Only a real siege displaces last hits/denies; ordinary wave push fills their gaps.
    local enemyAttackers = U.MergeLists(s.enemyCreeps,s.enemyTowers)
    local allyAttackers = U.MergeLists(s.allyCreeps,s.allyTowers)
    local target, deny = L.GetBestTarget(bot,s.enemyCreeps,s.allyCreeps,enemyAttackers,allyAttackers,false)
    if target and U.GetTimeToKillable(bot,target,deny and enemyAttackers or allyAttackers) <= 1.85 then return false end
    if not LN.BestPushCreep(bot,s.enemyCreeps,(C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700,s.allyCreeps) then return false end
    State.prepTarget=nil;State.lhAttackTarget=nil
    return H.ExecutePush(bot,s.enemy,race,s,true)
end

function H.ExecutePush(bot, enemyHero, race, s, priority)
    if State.actionTaken then return false end
    if not WV.AllowPush(bot, s) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemyCreeps, allyCreeps, enemyTowers = s.enemyCreeps, s.allyCreeps, s.enemyTowers
    local t1 = s.enemyT1
    local myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local now = GameTime()

    if priority and H.HandleSiegeTower(bot, race, s) then return true end

    -- 0) Post-Kill Wave-Shove Shadowraze (`s.enemyAlive == false` ONLY via `WV.ShoveAllowed` —
    --    ZERO solo-creep razes while enemy hero is alive, instant wave crash right after killing him at `HUD 09:01`!)
    if WV.ShoveAllowed(bot, s) and #(enemyCreeps or {}) > 0 then
        for _, label in ipairs({ "mid", "near", "far" }) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                for _, c in pairs(enemyCreeps) do
                    if U.CanQuery(c) and c:IsAlive() then
                        local cLoc = c:GetLocation()
                        local hits = 0
                        for _, c2 in pairs(enemyCreeps) do
                            if U.CanQuery(c2) and c2:IsAlive()
                                and U.DistanceBetweenLocations(cLoc, c2:GetLocation()) <= C.RAZE.HIT_RADIUS * 1.6 then
                                hits = hits + 1
                            end
                        end
                        if hits >= 2 or (#enemyCreeps == 1 and (c:GetHealth() or 0) > 120) then
                            local action, aim = H.GetRazeActionType(bot, ab, c)
                            if action and H.CastOrTurnRaze(bot, ab, action, aim, c) then
                                WV.NoteShove(now)
                                return true
                            end
                        end
                    end
                end
            end
        end
        -- Right-click any alive enemy creep immediately when enemy hero is dead so the wave crashes in < 4s!
        local bestC, bestD = nil, math.huge
        for _, c in pairs(enemyCreeps) do
            if U.CanQuery(c) and c:IsAlive() and H.IsSafeToAttack(bot, c:GetLocation(), enemyTowers, allyCreeps) then
                local d = GetUnitToLocationDistance(bot, c:GetLocation())
                if d < bestD then bestD, bestC = d, c end
            end
        end
        if bestC then
            if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= bestC then
                bot:Action_AttackUnit(bestC, false)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    -- 1) enemy creeps nearby -> hit the "fat" ones (low HP is the last-hit zone, do not push-hit there)
    local pushCreep = LN.BestPushCreep(bot, enemyCreeps, (C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700, allyCreeps)
    -- The current push target dropped into the last-hit zone: stop attacking it continuously
    if not priority and U.IsAttackingAction(bot) then
        local cur = bot:GetAttackTarget()
        if cur and U.CanQuery(cur) and not (cur.IsHero and cur:IsHero()) and not (cur.IsTower and cur:IsTower())
            and State.lhAttackTarget ~= cur and (cur:GetHealth() or 0) <= LN.PushHpFloor(bot, cur, allyCreeps) then
            if pushCreep == cur then pushCreep = nil end
            if not pushCreep then
                bot:Action_ClearActions(false)
                H.ClearMoveCache()
                State.actionTaken = true
                return true
            end
        end
    end
    if pushCreep then
        if H.IsSafeToAttack(bot, pushCreep:GetLocation(), enemyTowers, allyCreeps) then
            if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= pushCreep then
                bot:Action_AttackUnit(pushCreep, false)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    if not priority and H.HandleSiegeTower(bot, race, s) then return true end

    -- 4) move forward with the wave (behind the front creep) if there are creeps
    local front = LN.FrontAllyCreep(bot, allyCreeps)
    if front then
        local fountain = P.GetFountain(bot)
        local dir = (fountain - front:GetLocation()):Normalized()
        local pos = front:GetLocation() + dir * 300
        pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
        -- "Moving with the wave" never walks under the T1: without a tower hit (item 2) there is nothing
        -- to do inside its radius (the creeps die - the tower switches to us). Stay >= 800.
        if t1 and t1:IsAlive() then
            local okTL, tl = pcall(t1.GetLocation, t1)
            if okTL and tl then
                local keep = ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) + 20
                if U.DistanceBetweenLocations(pos, tl) < keep then
                    pos = tl + (pos - tl):Normalized() * keep
                end
            end
        end
        if GetUnitToLocationDistance(bot, pos) > 120 then
            return H.SmartMove(bot, pos, 60)
        end
        State.holdPos = true -- In place behind the wave: do not let the final positioning pull us back
        return false
    end
    return false
end

-- Simulation-only probe (never used by the real client): the harness reads the last stage name
-- from the global namespace to attribute free-pressure orders. Zero cost outside the sim.

-- Helper: is friendly Mid T1 (`s.allyT1`) in critical 1v1 Sudden-Death danger (`HP <= 420` with enemy hero/wave nearby)?
-- In `DOTA_GAMEMODE_1V1MID`, friendly Mid T1 dying instantly destroys our Ancient (`tk=21442` BAR 9:10!).
function H.IsAllyT1InSuddenDeathDanger(bot, s)
    local t1 = s and s.allyT1
    if not t1 then return false, nil end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then return false, nil end
    local okH, tHp = pcall(t1.GetHealth, t1)
    local okL, tLoc = pcall(t1.GetLocation, t1)
    if not okH or not tHp or tHp > 420 or not okL or not tLoc then return false, nil end
    local enemy = s and s.enemy
    if enemy and U.CanQuery(enemy) and U.DistanceBetweenLocations(tLoc, enemy:GetLocation()) <= 1220 then
        return true, t1, tLoc
    end
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and U.DistanceBetweenLocations(tLoc, c:GetLocation()) <= 1020 then
            return true, t1, tLoc
        end
    end
    return false, nil, nil
end

-- Unified Top-Priority Executioner & Throne-Grade Mid T1 Defender (`BAR 4:10` + `BAR 5:09` + `BAR 6:12` + `BAR 9:10`):
--   1. `BAR 9:10` (`allyT1 <= 420 HP` Sudden-Death Defense): Glyph immediately, override Salve/Fountain flight,
--      pop Mango/Stick, nuke/kill any hero hitting our low-HP T1 (`552 HP` ShaNachnetsya @ `tk=21334`), and clear siege/creeps!
--   2. `BAR 4:10` (`ShaNachnetsya` `186 HP` Dire T1 Dive): Never run away while friendly T1 is shooting a tower diver —
--      pop Mango/Stick if needed, land covering Shadowraze + right-click under friendly T1 aura to execute 100% of divers!
--   3. `BAR 5:09` (`108 -> 212 HP`) & `BAR 6:12` (`283 HP` at `340u`): Immediately pop Mango/Stick and finish low-HP enemy SF!
function H.HandleCriticalAllyT1AndDivePunish(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local myHp = bot:GetHealth() or 0
    local enemy = s and s.enemy
    local t1Danger, allyT1, allyT1Loc = H.IsAllyT1InSuddenDeathDanger(bot, s)

    -- [1] THRONE-GRADE FRIENDLY MID T1 DEFENSE (`BAR 9:10`, `allyT1 HP <= 420`)
    -- v4.3.3: defending a dying T1 is NOT a licence to walk a 360 HP lvl4 SF into a 916 HP lvl6 SF.
    -- If we cannot win the first-kill race and the HP/level gap is large, defend from range / clear
    -- the wave / glyph, and never issue the old blind 440u step into auto-attack range.
    if t1Danger and allyT1 and allyT1Loc and myHp > 110 then
        local enemyNearT1 = enemy and U.CanQuery(enemy) and enemy:IsAlive()
            and U.DistanceBetweenLocations(allyT1Loc, enemy:GetLocation()) <= 1220
        local enHp = (enemyNearT1 and enemy:GetHealth()) or 9999
        local enAtk = (enemyNearT1 and K.AttackDamageVs(enemy, bot)) or 55
        local dHeroT1 = enemyNearT1 and GetUnitToLocationDistance(bot, enemy:GetLocation()) or 9999
        local enBurstT1 = enemyNearT1 and K.EnemyBurstVs(bot, enemy, dHeroT1, 1.2, false) or 0
        local lrT1 = enemyNearT1 and U.SolveLethalRace(bot, enemy, s) or nil
        local levelDefT1 = enemyNearT1 and ((enemy:GetLevel() or 1) - (bot:GetLevel() or 1)) or 0
        local canKillT1 = lrT1 and lrT1.winsFirstKill and (lrT1.tKillHim or 99) <= 2.5
        local tooWeakToDive = enemyNearT1 and not canKillT1
            and (myHp < enBurstT1 + enAtk * 1.6 + 70 or myHp < enHp * 0.55 or levelDefT1 >= 2)

        if not tooWeakToDive then
            State.goingToFountain = false
            State.fountainReason = nil
            State.emergencyRetreat = nil
            H.ClearForcedRetreat()
            State.fleeUntil = 0
        end
        if U.IsGlyphAvailable(bot) then
            U.UseGlyph(bot)
        end
        if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
            return true
        end

        if tooWeakToDive then
            -- Raze from the CURRENT position only; no approach, no right-click on the hero.
            local safeToCast = myHp >= enBurstT1 + enAtk * 1.2 + 60
            if safeToCast and (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
                for _, label in ipairs({ "far", "mid", "near" }) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
            -- Clear the sieging wave from range instead of feeding the hero.
            local urgentCreep, urgentDist = nil, math.huge
            for _, c in pairs((s and s.enemyCreeps) or {}) do
                if U.CanQuery(c) and c:IsAlive() then
                    local dc = U.DistanceBetweenLocations(allyT1Loc, c:GetLocation())
                    if dc < urgentDist then urgentDist, urgentCreep = dc, c end
                end
            end
            if urgentCreep then
                if (bot:GetMana() or 0) >= 75 then
                    for _, label in ipairs({ "far", "mid", "near" }) do
                        local ab = H.GetRazeAbilityByLabel(bot, label)
                        if ab and U.IsRazeAbilityCastable(bot, ab) then
                            local action, aim = H.GetRazeActionType(bot, ab, urgentCreep)
                            if action and H.CastOrTurnRaze(bot, ab, action, aim, urgentCreep) then
                                State.actionTaken = true
                                return true
                            end
                        end
                    end
                end
                if GetUnitToLocationDistance(bot, urgentCreep:GetLocation()) <= (bot:GetAttackRange() or 525)
                    and myHp >= enAtk + 80 then
                    bot:Action_AttackUnit(urgentCreep, true)
                    H.ClearMoveCache()
                    State.actionTaken = true
                    return true
                end
            end
            if dHeroT1 < 680 then
                local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
                H.SmartMove(bot, bot:GetLocation() + away * (720 - dHeroT1), 45)
                State.actionTaken = true
                return true
            end
            return false
        end

        -- Priority 1A: Enemy hero approaching/attacking our `< 420 HP` Mid T1 -> ALL-IN SOLO KILL!
        if enemyNearT1 then
            for _, label in ipairs({ "far", "mid", "near" }) do
                local ab = H.GetRazeAbilityByLabel(bot, label)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local action, aim = H.GetRazeActionType(bot, ab, enemy)
                    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                        State.commitKillUntil = GameTime() + 2.5
                        return true
                    end
                end
            end
            local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
            if dHero <= (bot:GetAttackRange() or 525) + 55 then
                if H.IssueHeroAttack(bot, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
            -- Close briskly into `far`/`mid`/attack range right beside our friendly T1!
            local stepTarget = enemy:GetLocation() + (allyT1Loc - enemy:GetLocation()):Normalized() * 440
            H.SmartMove(bot, stepTarget, 35, true)
            return true
        end
        -- Priority 1B: Enemy creeps threatening `< 420 HP` Mid T1 -> blast cluster with Raze & right-click!
        local urgentCreep, urgentDist = nil, math.huge
        for _, c in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(c) and c:IsAlive() then
                local dc = U.DistanceBetweenLocations(allyT1Loc, c:GetLocation())
                if dc < urgentDist then
                    urgentDist, urgentCreep = dc, c
                end
            end
        end
        if urgentCreep then
            if (bot:GetMana() or 0) >= 75 then
                for _, label in ipairs({ "far", "mid", "near" }) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, urgentCreep)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, urgentCreep) then
                            return true
                        end
                    end
                end
            end
            if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= urgentCreep then
                bot:Action_AttackUnit(urgentCreep, true)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end

    -- [2] ENEMY TOWER-DIVER EXECUTIONER (`BAR 4:10` + `auto-20261022-2237` `04:38` `(1808,1126)` & `05:45` Behind-T1 Dive Fix!)
    local myT1 = s and s.allyT1
    local enManaDive = K.EnemyManaBudget(enemy, true)
    local enemyZeroCoilDive = (enManaDive < 75) or (K.EnemyReadyRazeCount(enemy, 0.7, true) == 0)
    local minDivePunishHp = enemyZeroCoilDive and 115 or 195
    if myT1 and myHp >= minDivePunishHp and not (earlyRace and earlyRace.valid and earlyRace.heCanKillNow and not enemyZeroCoilDive) then
        local okA, tAlive = pcall(myT1.IsAlive, myT1)
        local okL, tLoc = pcall(myT1.GetLocation, myT1)
        if okA and tAlive and okL and tLoc then
            local fnt = P.GetFountain(bot)
            local dEnT1 = U.DistanceBetweenLocations(tLoc, enemy:GetLocation())
            local pastOurT1 = U.DistanceBetweenLocations(enemy:GetLocation(), fnt) <= U.DistanceBetweenLocations(tLoc, fnt) + 95
                and dEnT1 <= 1650
            if dEnT1 <= 830 or pastOurT1 then
                local okT, tTgt = pcall(myT1.GetAttackTarget, myT1)
                local lrDive = U.SolveLethalRace(bot, enemy, s)
                -- `auto-20261023-0119` Death #1 (`04:24.97` `384 HP` vs `978 HP` + 7 creeps past Radiant T1) Fix:
                -- NEVER blindly stand and fight a near-full-HP enemy + full wave behind our T1 unless our T1 is ACTUALLY
                -- shooting him (`tTgt == enemy` with survival margin), OR `SolveLethalRace` wins, OR we match his HP!
                local safePastT1 = pastOurT1 and (
                    (okT and tTgt == enemy and myHp >= K.EnemyBurstVs(bot, enemy, dEnT1, 1.0, false) + 75)
                    or (lrDive and lrDive.winsFirstKill and lrDive.tKillHim <= 2.5)
                    or ((enemy:GetHealth() or 9999) <= 465 and myHp >= 250)
                    or (myHp >= 360 and myHp >= (enemy:GetHealth() or 9999) * 0.58)
                )
                local towerShootingHim = (okT and tTgt == enemy and myHp >= 205)
                    or safePastT1
                    or (#(s.enemyCreeps or {}) == 0 and dEnT1 <= 760)
                if towerShootingHim
                    or (dEnT1 <= 755 and (enemy:GetHealth() or 9999) <= 465)
                    or (dEnT1 <= 830 and (((bot:GetMana() or 0) >= 75 and (enemy:GetHealth() or 9999) <= 465) or (enemy:GetHealth() or 9999) <= 285)) then
                    H.ClearForcedRetreat()
                    State.fleeUntil = 0
                    if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
                        State.commitKillUntil = GameTime() + 2.0
                        return true
                    end
                    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
                    local oneRazeDmg = K.MyRazeDamage(bot, enemy, 1)
                    local lastAtkDt = GameTime() - (bot:GetLastAttackTime() or -100)
                    local spa = bot:GetSecondsPerAttack() or 1.2
                    local alreadySwingingHero = (U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemy)
                    local swingRange = alreadySwingingHero
                        and ((bot:GetAttackRange() or 525) + 215)
                        or ((bot:GetAttackRange() or 525) + 35)
                    if myHp >= 225 and oneRazeDmg < (enemy:GetHealth() or 9999)
                        and dHero <= swingRange
                        and lastAtkDt >= spa * 0.80 then
                        if not alreadySwingingHero then
                            bot:Action_AttackUnit(enemy, true)
                            H.ClearMoveCache()
                        end
                        State.commitKillUntil = GameTime() + 2.0
                        State.actionTaken = true
                        return true
                    end
                    for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                        local ab = H.GetRazeAbilityByLabel(bot, label)
                        if ab and U.IsRazeAbilityCastable(bot, ab) then
                            local action, aim = H.GetRazeActionType(bot, ab, enemy)
                            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                                State.commitKillUntil = GameTime() + 2.0
                                return true
                            end
                        end
                    end
                    if myHp >= 210 and dHero <= (bot:GetAttackRange() or 525) + 60 then
                        if H.IssueHeroAttack(bot, enemy) then
                            State.commitKillUntil = GameTime() + 2.0
                            State.actionTaken = true
                            return true
                        end
                    elseif myHp >= 260 and dHero <= 950 then
                        local setup = enemy:GetLocation() + (tLoc - enemy:GetLocation()):Normalized() * 440
                        H.SmartMove(bot, setup, 35, true)
                        return true
                    end
                end
            end
        end
    end

    -- [3] CRITICAL LOW-HP ENEMY FINISH (`BAR 5:09`, `BAR 6:12`, `3:58` 2-Hit Zero-Mana Right-Click Kill, & `5:28` Centered `E`!)
    local enHp = enemy:GetHealth() or 9999
    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local underUnsafeEnemyT1 = false
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(tw, enemy:GetLocation()) < 740
            and not H._hasTankCreepUnderTower(tw, s.allyCreeps) then
            underUnsafeEnemyT1 = true
            break
        end
    end

    -- Pure TTK Race Lethal Override (`0119` `00:24.83` @ `42 HP` & `05:25.43` @ `90 HP` + `9055695956.dem` `3:58` @ `91 HP`):
    -- Uses exact `U.SolveLethalRace` `[0, tKillHim + 0.15s]` first-kill physics so SF NEVER aborts a winning kill at `< 195 HP`!
    local lrCrit = U.SolveLethalRace(bot, enemy, s)
    local myPhysHit = math.max(38, K.AttackDamageVs(bot, enemy))
    if not underUnsafeEnemyT1
        and ((lrCrit and lrCrit.winsFirstKill and lrCrit.tKillHim <= 2.35 and dHero <= math.max((bot:GetAttackRange() or 525) + 155, 880))
            or (enHp <= myPhysHit * 2.25
                and dHero <= (bot:GetAttackRange() or 525) + 135
                and myHp >= math.max(195, K.EnemyBurstVs(bot, enemy, dHero, 1.5, false) + 55))) then
        if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then
            return true
        end
    end

    local myPotMana = H.GetPotentialCombatMana(bot)
    local oneMyRaze = K.MyRazeDamage(bot, enemy, 1)
    local canFinishLow = (enHp <= math.max(275, oneMyRaze * 1.58) and myHp >= 290 and myPotMana >= 75)
        or (enHp <= 335 and myHp >= 420 and myPotMana >= 75 and dHero <= 680)
    if canFinishLow and dHero <= 955 and not underUnsafeEnemyT1
        and not (earlyRace and earlyRace.valid and earlyRace.heCanKillNow) then
        H.ClearForcedRetreat()
        State.fleeUntil = 0
        if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.0
            return true
        end
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.commitKillUntil = GameTime() + 2.0
                    return true
                end
            end
        end
        if dHero <= (bot:GetAttackRange() or 525) + 55 then
            if H.IssueHeroAttack(bot, enemy) then
                State.commitKillUntil = GameTime() + 2.0
                State.actionTaken = true
                return true
            end
        elseif K.CanCatch(bot, enemy, 660, 2.0) then
            local setup = U.GetRazeSetupPosition(bot, enemy)
            if setup and H.ApproachEnemyPoint(bot, enemy, setup, 35, s.enemyTowers, s.allyCreeps) then
                return true
            end
        end
    end

    return false
end

function H.CanTwoHitRightClickKill(bot, enemy, s)
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(tw, enemy:GetLocation()) < 740
            and not H._hasTankCreepUnderTower(tw, s.allyCreeps) then
            return false
        end
    end
    local lr = U.SolveLethalRace(bot, enemy, s)
    if lr and lr.winsFirstKill and lr.tKillHim <= 2.35 and dHero <= math.max((bot:GetAttackRange() or 525) + 155, 880) then
        return true
    end
    if dHero > (bot:GetAttackRange() or 525) + 135 then return false end
    local myPhysHit = math.max(38, K.AttackDamageVs(bot, enemy))
    local enHp = enemy:GetHealth() or 9999
    if enHp > myPhysHit * 2.25 then return false end
    return (bot:GetHealth() or 0) >= math.max(195, K.EnemyBurstVs(bot, enemy, dHero, 1.5, false) + 55)
end

-- Stage A (ABOVE RunSacredCS): Strictly prevents stopping/turning back for a creep last-hit when 1-2 hits
-- or an immediate enemy cast away from death while NEVER interrupting normal 0.000s-0.033s CS!
-- Uses Schmitt-trigger hysteresis (`+85u` exit margin) so we NEVER bang-bang stall at the boundary!
function H.InCriticalLethalDanger(bot, s, race)
    local myHp = bot:GetHealth() or 0
    local enemy = s and s.enemy
    local now = GameTime()

    -- Critical low-HP protection vs ACTUALLY AGGROED lane creeps (`R2_2044` `03:25..03:31.33` `@420u` Freeze Fix!):
    -- When `s.enemyAlive == false` (`ShaNachnetsya` just died at `03:20`!), unaggroed enemy creeps fighting our own wave
    -- at `417u` (`c:GetAttackTarget() ~= bot`) MUST NEVER paralyze SF at `@420u` until passive regen ticks `155 -> 156 HP`!
    if myHp <= 155 then
        local nearAggroCreeps = 0
        local noAllyShield = #(s and s.allyCreeps or {}) == 0
        for _, c in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(c) and c:IsAlive() then
                if c:GetAttackTarget() == bot or (noAllyShield and GetUnitToLocationDistance(bot, c:GetLocation()) <= 230) then
                    nearAggroCreeps = nearAggroCreeps + 1
                end
            end
        end
        if nearAggroCreeps >= 1 then
            State.critDangerHystUntil = now + 0.75
            return true
        end
    end

    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local enRange = (enemy:GetAttackRange() or 500)
    local valid = race and race.valid
    if valid and race.canKillNow then return false end
    local hystPad = (now < (State.critDangerHystUntil or -100)) and 85 or 0
    local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
    local twoRaze = K.EnemyRazeDamage(bot, enemy, 2)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local outMatched = valid and (race.heHasBootsLead or ((enemy:GetLevel() or 1) > (bot:GetLevel() or 1)))
    local safeRadiusForHp
    if myHp <= oneRaze + 45 or myHp <= 155 then
        safeRadiusForHp = math.max(enRange + 420, (race and race.minSafeDist or 960) + 60) + hystPad
    elseif outMatched and myHp <= twoRaze + enAtk * 1.15 then
        safeRadiusForHp = math.min(735, math.max(620, K.EnemyMinSafeDistance(enemy, 0.8))) + hystPad
    elseif myHp <= twoRaze + 35 then
        safeRadiusForHp = math.min(685, math.max(590, K.EnemyMinSafeDistance(enemy, 0.8))) + hystPad
    else
        safeRadiusForHp = enRange + 145 + hystPad
    end

    -- Stage A runs BEFORE `RunSacredCS`: trigger ONLY on genuine short-horizon (`<= 1.25s`) lethal threat!
    -- Previously `myHp - race.enBurstSoon <= 92` with `safeRadiusForHp = 845+85 = 930u` fired on 95% of ticks at
    -- `420..690 HP` (`02:44..05:48`), cancelling CS windups and letting `ShaNachnetsya` farm `41/12` vs `15/6`!
    local myStNow, myRemNow = U.GetShadowrazeDebuff(bot)
    local enAppNow = U.EnemyApproachSpeed(bot, enemy)
    local burstHorizon = (dist >= 645 and enAppNow < 65 and (myStNow or 0) <= 1 and myHp >= 390 and K.EnemyRazeReadyIn("far") > 4.0) and 0.65 or 1.25
    local burst125 = K.EnemyBurstVs(bot, enemy, dist, burstHorizon, false)
    local burstSafetyMargin = enAtk * 0.90
    local enManaPoolCrit = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    if (myStNow or 0) >= 1 and (myRemNow or 0) > 0.10 and (myRemNow or 0) <= 2.15
        and enManaPoolCrit >= 75 and not (valid and race.canKillNow) and dist < 955 then
        State.critDangerHystUntil = now + 0.45
        return true
    end
    local dominatingOneCoilTrade = (enManaPoolCrit < 150)
        and myHp >= 330
        and not (valid and race.heCanKillNow)
        and K.AttackDamageVs(bot, enemy) >= enAtk + 12
    if valid and not race.canKillSoon and not dominatingOneCoilTrade
        and (race.heCanKillNow or ((myHp - burst125) <= burstSafetyMargin))
        and dist < safeRadiusForHp then
        State.critDangerHystUntil = now + 0.55
        return true
    end
    if dist < safeRadiusForHp and myHp <= math.max(175, enAtk * 2.4) then
        State.critDangerHystUntil = now + 0.55
        return true
    end
    return false
end

-- Stage B (IMMEDIATELY BELOW RunSacredCS, ABOVE ALL OFFENSIVE COMBAT HANDLERS):
-- Also immediately kites back out of river lowground (`uphillPenalty`) / multi-creep aggro when enemy SF
-- auto-attacks us at early levels (`0:00` opening `HUD 01:01-01:08` 6-unanswered-autos fix)!
-- v4.3.6-tempo: resource-cycling clarity. The human bought/used clarity at 4:12
-- after a mango to refill 150 mana over 25s while safe; the bot never bought one.
-- Only hero/tower damage breaks clarity, so creep-wave farming does not cancel it.
function H.HandleTempoClarity(bot, s)
    if State.actionTaken or State.goingToFountain then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not T.ShouldUseClarity(bot, s) then return false end
    local clarity = U.GetActiveItemByName(bot, "item_clarity")
    if not clarity then
        local ok, it = H.EnsureConsumableReady(bot, "item_clarity")
        if ok then clarity = it end
    end
    if not clarity then return false end
    bot:Action_UseAbility(clarity)
    State.lastItemUseTime = GameTime()
    State.actionTaken = true
    return true
end

-- v4.3.6-tempo: XP-preserving spacing. Runs AFTER RunSacredCS (last hits/denies
-- already had priority) and BEFORE hero-only aggression. Three triggers:
--   AHEAD + dry + enemy can punish  -> protect the lead, do not coinflip;
--   BEHIND + dry/level-down         -> soak XP, farm, cycle regen, no hero-only trade;
--   EVEN  + dry + losing wave       -> the replay death had bot HP > enemy HP but
--                                      35 mana and 3 enemy creeps; v4.3.5 missed it.
function H.HandleTempoSpacing(bot, s, race)
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc then return false end
    if State.commitKillUntil and GameTime() < State.commitKillUntil then return false end
    if State.hunting then return false end
    if State.intent == I.RETREAT or State.intent == I.ALLIN then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local need = T.ShouldProtectLead(bot, s, race)
        or T.ShouldCatchupFarm(bot, s, race)
        or T.ShouldDryWaveSpace(bot, s, race)
    if not need then return false end
    -- De-aggro first if creeps are beating us and we have slack (same 1-tick A-click).
    local st = T.Get(bot)
    if st and st.aggroCount >= 2 and U.TryDeaggro(bot, s, nil, 0.5) then
        State.actionTaken = true
        return true
    end
    local anchor = T.XPAnchor(bot, s)
    if not anchor then return false end
    if GetUnitToLocationDistance(bot, anchor) <= 65 then return false end
    H.SmartMove(bot, anchor, 55)
    State.actionTaken = true
    return true
end

-- Stage B0 (`9055695956.dem` `0:00` `tk=4064` Even-Footing Anti-Conveyor Counter-Raze & `1:52` `tk=6360` Dry-Enemy Punish):
--   1. When enemy SF lands an opening coil/close trade (`myStacks >= 1` or close hero hit) while we are healthy on mana & HP
--      and behind on stacks (`enStacks < max(1, myStacks)`), NEVER run backward down his `200->450->700u` triple-raze ray
--      unanswered — immediately fire our best-centered counter-Shadowraze (`Q`/`W`/`E`) FIRST to equalize stacks!
--   2. When enemy hero is completely DRY on mana (`enemy:GetMana() < 75` => `0` counter-razes possible, `1:52` `SHA MP=20`)
--      and we hold `>= 135 MP` with no imminent creep CS, punish his walk-up immediately with our dead-center coil!
function H.HandleMirrorRazeCounterAndDryPunish(bot, s, earlyRace, csWaveBusy)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    -- Note: allow `< 75 MP` entry at top of `HandleMirrorRazeCounterAndDryPunish` so proactive `Mango`/`Wand` top-up & Salve break run!
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 then return false end

    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local twoEnRaze = K.EnemyRazeDamage(bot, enemy, 2)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local unsafeSoon = earlyRace and earlyRace.valid and earlyRace.heCanKillSoon
    if earlyRace and earlyRace.valid and earlyRace.heCanKillNow then return false end

    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0
    local enStacks = U.GetShadowrazeDebuff(enemy) or 0
    local recentlyHit = (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.35)) or false

    local myMana = bot:GetMana() or 0

    -- Immediate Enemy `modifier_flask_healing` Cancel (`0050` `01:44.5`: enemy healed `395 HP` right in front of us at `796u`!):
    if enemy:HasModifier("modifier_flask_healing") and danger == 0
        and myHp > K.EnemyBurstVs(bot, enemy, dHero, 0.9, false) + 85 then
        if dHero <= (bot:GetAttackRange() or 500) + 175 then
            H.IssueHeroAttack(bot, enemy)
            State.actionTaken = true
            return true
        elseif dHero <= 935 then
            if myMana < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            return true
                        end
                    end
                end
            end
        end
    end

    if myMana < 75 and K.MyReadyRazeCount(bot, true) < 1 then return false end

    -- Even-footing mirror answer ONLY on a FRESH opening hit (`myRem > 2.5` or `recentlyHit`, NEVER self-rooting `0.55s`
    -- on an about-to-expire stack `myRem <= 2.5s` right before free stack burnout!)
    local mirrorCounter = (not unsafeSoon)
        and (myHp >= twoEnRaze + enAtk * 2.1 + 65)
        and (myHp >= myMaxHp * 0.66)
        and ((myStacks >= 1 and myRem > 2.5) or (recentlyHit and dHero <= 440))
        and (enStacks < math.max(1, myStacks))
        and myHp >= (enemy:GetHealth() or 9999) * 0.62
        and dHero <= 915

    -- `v4.0.0` `Shadowraze3` Anti-Edge-Poke Counter-System (`auto-20261023-0119` CRITICAL FIX!):
    -- Case A (`Post-Far-Raze Punish`): Enemy SF JUST spent his `700u` `Shadowraze3` (`EnemyRazeReadyIn("far") > 4.5` OR landed
    -- a fresh stack `myRem > 5.0` at `dHero >= 645u`). At `645..925u`, his `Q (450u)`, `W (700u)`, and `500u` auto CANNOT
    -- reach us within `0.65s` (`enImmediateBurst == 0`!) — ALWAYS punish back with our centered `Shadowraze3` even at `30%..65% HP`!
    local approachSpd = U.EnemyApproachSpeed(bot, enemy)
    local outMatchedRunDown = (((enemy:GetLevel() or 1) > (bot:GetLevel() or 1))
        or (earlyRace and earlyRace.valid and earlyRace.heHasBootsLead))
        and approachSpd >= 95
        and myHp < (twoEnRaze + enAtk * 1.6 + 65)

    local enImmediateBurst = K.EnemyBurstVs(bot, enemy, dHero, 0.80, false)
    local farRazeReciprocity = (dHero >= 645 and dHero <= 925)
        and danger == 0
        and not outMatchedRunDown
        and myHp > enImmediateBurst + 95
        and ((K.EnemyRazeReadyIn("far") > 4.5 and (not csWaveBusy or (myStacks >= 1 and myRem > 5.0)))
            or (myStacks >= 1 and myRem > 5.0 and enStacks < myStacks))

    -- Case B (`Proactive Step-In Edge Intercept`): Enemy SF walks directly into `690..905u` facing us (`approach > 50`,
    -- `FacingCos >= 0.78`) to tap `Shadowraze3` while no lane CS is imminent (`not csWaveBusy`) — beat him to the draw first!
    local enFacingMe = (U.FacingCos and U.FacingCos(enemy, bot:GetLocation()) or 0) >= 0.78
    local proactiveEdgeIntercept = (not csWaveBusy)
        and (not unsafeSoon)
        and danger == 0
        and not outMatchedRunDown
        and myStacks == 0
        and dHero >= 695 and dHero <= 905
        and approachSpd > 50
        and enFacingMe
        and myHp > K.EnemyRazeDamage(bot, enemy, 1) + 155
        and enStacks >= myStacks

    -- `< 75 MP` enemy SF has ZERO coils available in reply (`9056469656.dem` `01:42–02:02` `SHA MP = 12..44`, `Bot MP = 97..131`!):
    -- punish any walk-up immediately with our dead-center coil whenever we hold `>= 75 MP` and survive physical reply!
    local enTotalMana = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local dryEnemyPunish = (not csWaveBusy)
        and (not unsafeSoon)
        and danger == 0
        and (enTotalMana < 75)
        and myMana >= 75
        and myHp >= math.max(215, enAtk * 2.7 + 45)
        and dHero <= 815

    if not mirrorCounter and not farRazeReciprocity and not proactiveEdgeIntercept and not dryEnemyPunish then
        return false
    end

    if myMana < 75 then
        if not bot:HasModifier("modifier_flask_healing") and H.TryUseBurstManaItem(bot, true) then
            return true
        end
        return false
    end

    for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local action, aim = H.GetRazeActionType(bot, ab, enemy)
            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                return true
            end
        end
    end
    return false
end

-- Stage B0.5 (`9056469656.dem` `01:36–02:02` Soul-Lead Passivity & `02:29–02:35` `284 HP / 15 MP` Dry-Enemy Free-Kill Fix):
-- Runs right AFTER `RunSacredCS` (never drops a 0.000s lane CS!) and BEFORE `InLosingHeroTrade` / `TryWaveSafeStaticTango`:
--   1. When enemy has `< 75 MP` (`0` Shadowrazes possible!) and we hold equal/superior damage or HP lead (`01:42–02:02`
--      `Bot 8–10 souls, Lvl 3` vs `Sha 4–5 souls, Lvl 2, 12–44 MP`; `02:32.92` `Bot 514 HP, 13S` vs `Sha 284 HP, 15 MP`),
--      NEVER let them right-click us for free (`0 vs 10` autos!) or walk away on `284 HP` — trade right-clicks decisively!
--   2. Also right BEFORE `RunSacredCS`, `H.HandleActiveLethalDuelFinish` prevents `RunSacredCS` from stealing our fatal
--      swing onto a lane creep (`04:07.32` `U315` creep hit when `Sha = 178 HP` at `d = 171.9u`!).
function H.HandleActiveLethalDuelFinish(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local enHp = enemy:GetHealth() or 9999
    local myHp = bot:GetHealth() or 0
    local myAtk = math.max(1, K.AttackDamageVs(bot, enemy))
    local enAtk = math.max(1, K.AttackDamageVs(enemy, bot))
    local enPotMana = U.GetPotentialManaForRaze(enemy)

    -- Exact First-Kill Time-To-Kill (`TTK_bot < TTK_enemy`) Solver (`auto-20261023-0119` `00:24.83` @ `42 HP` & `05:25.43` @ `90 HP`!):
    -- Runs BEFORE `InCriticalLethalDanger` so SF NEVER turns its back on a guaranteed kill when `tKillHim` resolves BEFORE enemy lethal!
    local lr = U.SolveLethalRace(bot, enemy, s)
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 and myHp < 340 and not (lr and lr.winsFirstKill and lr.tKillHim <= 1.25 and myHp >= 145) then
        return false
    end

    local creepsOnMeNow = 0
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == bot
            and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 260 then
            creepsOnMeNow = creepsOnMeNow + 1
        end
    end
    local oneShotDryKill = (enPotMana < 75)
        and (enHp <= myAtk * 1.08)
        and (myHp > enAtk + creepsOnMeNow * 12 + 12 or GameTime() < (State.oneShotFinishUntil or 0))
    local extendedDryKillReach = oneShotDryKill and 235
        or ((enPotMana < 75 and enHp <= myAtk * 2.6 and myHp >= 185) and 175
            or ((lr and lr.winsFirstKill and lr.tKillHim <= 2.35) and 380 or 85))
    if d > (bot:GetAttackRange() or 500) + extendedDryKillReach then return false end

    local myOneRaze = U.GetNRazeDamage(bot, enemy, 1)
    local hasReadyRaze = K.MyReadyRazeCount(bot, true) >= 1
    local myShots = math.ceil(enHp / myAtk)
    local enShots = math.ceil(myHp / enAtk)
    local dryWinningFinish = myShots <= 4
        and (enPotMana < 75 or not (earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon)))
        and (myShots + 1 <= enShots)
        and myHp >= 185
    local ttkFirstKillWin = (lr and lr.winsFirstKill and lr.tKillHim <= 2.35)
    local duelLethalNow = oneShotDryKill
        or ttkFirstKillWin
        or (enHp <= myAtk * 3.1 and myHp >= math.max(165, K.EnemyBurstVs(bot, enemy, d, 1.15, false) + 25))
        or (hasReadyRaze and enHp <= myOneRaze + myAtk * 1.65 and myHp >= math.max(165, K.EnemyBurstVs(bot, enemy, d, 0.95, false) + 20))
        or dryWinningFinish
    if not duelLethalNow then return false end
    if oneShotDryKill then
        State.oneShotFinishUntil = GameTime() + 1.15
    end

    -- Lock in kill commitment & clear ALL retreat/flee states immediately!
    H.ClearForcedRetreat()
    State.fleeUntil = 0
    State.critDangerHystUntil = 0
    State.survivalUntil = 0
    State.survivalLoc = nil

    -- Instant `0.00s` Emergency Burst EHP (`9058240714.dem` `1:54.03` Fix!):
    --   * `Magic Stick / Wand` (`0` attack damage loss!) fires at `lr.needStickHeal` or `<= 35% HP`.
    --   * `Faerie Fire` (`-2` permanent attack damage!) fires STRICTLY ONLY at `lr.needFaerieHeal` (`<= 0.85s` lethal) or `<= 15% HP`!
    local maxHpNow = math.max(1, bot:GetMaxHealth() or 1)
    if lr and (lr.needStickHeal or lr.needFaerieHeal or (myHp <= (lr.enDmgBeforeDeath or 0) + 75 and myHp <= maxHpNow * 0.35)) then
        local wand = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
        if wand and wand:IsFullyCastable() and U.GetStickCharges(bot) > 0 then
            bot:Action_UseAbility(wand)
            State.commitKillUntil = GameTime() + 2.5
            State.actionTaken = true
            return true
        end
        if lr.needFaerieHeal or myHp <= maxHpNow * 0.15 then
            local ff = U.GetActiveItemByName(bot, "item_faerie_fire")
            if ff and ff:IsFullyCastable() then
                bot:Action_UseAbility(ff)
                State.commitKillUntil = GameTime() + 2.5
                State.actionTaken = true
                return true
            end
        end
    end

    -- If a single right-click ALREADY kills the enemy (`enHp <= myAtk * 1.08`) inside reach, swing/step IMMEDIATELY (`~0.35s`)
    -- instead of spending `0.55s` + `75 MP` on a raze windup or flip-flopping at `d = 600u` (`9058240714.dem` `2:04.6` `50 HP` fix!):
    if enHp <= myAtk * 1.08 and d <= (bot:GetAttackRange() or 500) + (oneShotDryKill and 235 or 95) then
        State.prepTarget = nil
        State.lhAttackTarget = nil
        H.IssueHeroAttack(bot, enemy)
        State.commitKillUntil = GameTime() + 2.4
        State.actionTaken = true
        return true
    end

    -- Fire lethal/near-lethal centered raze if ready, otherwise lock right-click directly onto enemy hero!
    if (bot:GetMana() or 0) < 75 and K.MyManaBudget(bot, true) >= 75 and hasReadyRaze then
        if H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
    end
    if (bot:GetMana() or 0) >= 75 then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.commitKillUntil = GameTime() + 2.5
                    return true
                end
            end
        end
        -- `Demo 2` `7:41` Step-Back Execution: ONLY `nevermore_shadowraze3` is ready while `d` is inside `[200..620u]`
        -- inner deadzone — step back ONLY when kinematically reachable within `<= 0.85s` (`tWalkOut <= 0.85`), otherwise
        -- strike immediately with hero right-click instead of turning our back to a fast pursuer!
        local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
        local _, enRemNow = U.GetShadowrazeDebuff(enemy)
        local appClose = math.max(0, U.EnemyApproachSpeed(bot, enemy))
        local myMsClose = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 310)
        local needDist = math.min(680, math.max(545, 505 + appClose * 0.62))
        local tWalkOut = math.max(0, needDist - d) / math.max(30, myMsClose - appClose)
        if eAb and U.IsRazeAbilityCastable(bot, eAb) and d >= 200 and d < 620
            and myShots >= 3
            and tWalkOut <= 0.85
            and ((enRemNow or 0) == 0 or (enRemNow or 0) >= 0.85) then
            local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
            bot:Action_MoveToLocation(enemy:GetLocation() + away * (needDist + 65))
            H.ClearMoveCache()
            State.prepTarget = nil
            State.lhAttackTarget = nil
            State.commitKillUntil = GameTime() + 2.2
            State.actionTaken = true
            return true
        end
    end
    State.prepTarget = nil
    State.lhAttackTarget = nil
    H.IssueHeroAttack(bot, enemy)
    State.commitKillUntil = GameTime() + 2.2
    State.actionTaken = true
    return true
end

-- `v4.2.0` Multi-Stack Combo Finisher & Anti-`Raze3`-Bait Counter-Geometry
-- Eliminates ALL FOUR replay outplays simultaneously:
--   * Mode A (`Demo 2` `7:41`): 2-stack/3-stack lethal execution INCLUDING `0.15s` step-back `[250..470u] -> 510u` for 3rd-stack `Raze3 (310 dmg)`!
--   * Mode B (`Demo 1` `1:20` & `Demo 2` `7:13.3`): Immediate 2nd/3rd-stack overlap chain (`E -> W` at `[455..670u]`, `Q -> W` at `[210..435u]`)
--     whenever enemy already carries our stack (`enStacks >= 1`) and we survive `0.72s` — NEVER aborting ready `W` to flee!
--   * Mode C (`Demo 2` `7:07` & `Demo 1` `1:40`): Anti-`Raze3`-Bait Outer Kite Punish! When enemy spends long `E (700u)` and runs forward
--     to land `2`-stack `W (450u)`, fire our `E` IN PLACE from `[725..895u]` (NEVER walking into `< 715u`!) and hold `[775..835u]` outside `W`!
function H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, lethalOrChainOnly)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsSilenced() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 then return false end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local myMana = bot:GetMana() or 0
    local potMana = K.MyManaBudget(bot, true)
    local enHp = enemy:GetHealth() or 9999
    local enEffHp = enHp + (U.GetStickCharges(enemy) * 15)
    local enStacks, enRem = U.GetShadowrazeDebuff(enemy)
    enStacks, enRem = enStacks or 0, enRem or 0
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks, myRem = myStacks or 0, myRem or 0
    local myAtk = K.AttackDamageVs(bot, enemy)
    local myNextRaze = U.GetNRazeDamage(bot, enemy, 1)

    -- MODE A: Lethal Next-Stack Execution (including `[240..475u] -> 510u` step-back for 3rd-stack `Raze3`!)
    if potMana >= 75 and myNextRaze > 0 and enEffHp <= (myNextRaze + (d <= 540 and myAtk * 0.95 or 0)) then
        local inc065 = K.EnemyBurstVs(bot, enemy, d, 0.65, false)
        if myHp > inc065 + 25 or myNextRaze >= enEffHp then
            H.ClearForcedRetreat()
            State.fleeUntil = 0
            State.critDangerHystUntil = 0
            State.survivalUntil = 0
            State.survivalLoc = nil
            if myMana < 75 and H.TryUseBurstManaItem(bot, true) then
                State.commitKillUntil = GameTime() + 2.5
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.commitKillUntil = GameTime() + 2.5
                            return true
                        end
                    end
                end
                local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
                local appClose = math.max(0, U.EnemyApproachSpeed(bot, enemy))
                local myMsClose = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 310)
                local needDist = math.min(680, math.max(545, 505 + appClose * 0.62))
                local tWalkOut = math.max(0, needDist - d) / math.max(30, myMsClose - appClose)
                if eAb and U.IsRazeAbilityCastable(bot, eAb) and d >= 200 and d < 620
                    and math.ceil(enHp / math.max(1, myAtk)) >= 3
                    and tWalkOut <= 0.85 and (enRem == 0 or enRem >= 0.85) then
                    local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
                    local stepBackPt = enemy:GetLocation() + away * (needDist + 65)
                    bot:Action_MoveToLocation(stepBackPt)
                    H.ClearMoveCache()
                    State.commitKillUntil = GameTime() + 2.2
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    -- MODE B: Immediate Overlap 2nd/3rd-Stack Chain (`Demo 1` `1:20` & `Demo 2` `7:13.3`!)
    -- Strictly requires either:
    --   * enemy ALREADY spent both `far` & `mid` razes (`Demo 1` `1:20` at `d >= 460u` -> `0` counter-razes possible!), OR
    --   * we survive the full `2.2s` combo (`not heCanKillSoon`, `not uphillPenalty`, `myHp > burst22 + 95`), so we NEVER
    --     self-root `0.55s` in river lowground into a lethal L4 triple-raze (`S8` safety preserved 100%!).
    if enStacks >= 1 and enRem >= 0.85 and potMana >= 75 and d <= 905 then
        local burst22 = K.EnemyBurstVs(bot, enemy, d, 2.2, false)
        local oneHitPhys = bot:GetActualIncomingDamage(enemy:GetAttackDamage() or 55, DAMAGE_TYPE_PHYSICAL)
        local aggroCreeps = 0
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == bot
                and GetUnitToLocationDistance(bot, ec:GetLocation()) < 340 then
                aggroCreeps = aggroCreeps + 1
            end
        end
        local spinCastDanger = oneHitPhys * ((d <= 720 or U.EnemyApproachSpeed(bot, enemy) > 120) and 2.1 or 1.2)
            + aggroCreeps * 26
        local safeSpinHp = (myHp > math.max(225, spinCastDanger + 75))
            and (((enemy:GetLevel() or 1) <= (bot:GetLevel() or 1)) or myHp >= 340)
        local enemySpentMidAndFar = (K.EnemyRazeReadyIn("far") > 2.0 and K.EnemyRazeReadyIn("mid") > 2.0 and d >= 460)
        local safeToChainHere = safeSpinHp and (enemySpentMidAndFar
            or (myHp > burst22 + 95
                and myHp >= 260
                and not (earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.uphillPenalty))))
        if safeToChainHere then
            if myMana < 75 and not bot:HasModifier("modifier_flask_healing") and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            H.ClearForcedRetreat()
                            State.fleeUntil = 0
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    if lethalOrChainOnly then return false end

    -- MODE C: Anti-`Raze3`-Bait Outer Kite Punish (`Demo 2` `7:07` & `Demo 1` `1:40`!)
    -- Enemy just spent long `Shadowraze3` (`EnemyRazeReadyIn("far") > 4.0`) and still holds `Shadowraze2` (`<= 700u`) + mana:
    --   1. If in `[705..905u]` and our `far` raze is ready: fire `Shadowraze3` IN PLACE immediately (NEVER step into `< 715u`!)
    --   2. Once our `far` raze is on CD (or enemy runs forward with `approach > 35` while we hold `myStacks >= 1`), hold `785u`
    --      strictly outside enemy's `700u` `Shadowraze2` circle until our debuff expires or our next coil comes up!
    local enFarSpent = K.EnemyRazeReadyIn("far") > 4.0
    local enMidThreat = K.EnemyRazeReadyIn("mid") <= 1.5 and K.EnemyManaBudget(enemy, true) >= 75
    if enFarSpent and d >= 690 and d <= 940 then
        local farAb = H.GetRazeAbilityByLabel(bot, "far")
        local appNow = math.max(0, U.EnemyApproachSpeed(bot, enemy))
        local enInCastNow = K.EnemyPhase() ~= nil
        -- GRANDMASTER CHECKMATE vs `Demo 2` `7:07` Bait:
        -- If we ALREADY hold `myStacks >= 1` and enemy still holds `W (<= 700u)`, NEVER self-root `0.55s` at `d = 755u`
        -- where a `350 ms` advancing enemy closes `193u -> 562u <= 700u` for a `2-stack W`!
        -- Glide out toward `900u` FIRST until either:
        --   (a) enemy whiffs `W` (`enInCastNow and d > 710` — rooted outside `700u`!), OR
        --   (b) `d - appNow * 0.62 >= 712` (`d >= 885..935u`: `Raze3` hits while enemy stays `> 712u` outside `W`!).
        local mustKiteWFirst = (myStacks >= 1 and myRem > 0.65 and enMidThreat)
            and not (earlyRace and earlyRace.valid and earlyRace.canKillSoon)
            and not (enInCastNow and d > 710)
            and ((d - appNow * 0.62) < 712)
        if mustKiteWFirst then
            local fnt = P.GetFountain(bot)
            local homeDir = (fnt - enemy:GetLocation()):Normalized()
            local kiteRing = enemy:GetLocation() + homeDir * 900
            H.SmartMove(bot, kiteRing, 35)
            State.actionTaken = true
            return true
        end
        if farAb and U.IsRazeAbilityCastable(bot, farAb) and myHp > 195 then
            local action, aim = H.GetRazeActionType(bot, farAb, enemy)
            if action and H.CastOrTurnRaze(bot, farAb, action, aim, enemy) then
                State.actionTaken = true
                return true
            end
        elseif myStacks >= 1 and myRem > 0.65 and enMidThreat
            and not (earlyRace and earlyRace.valid and earlyRace.canKillSoon) then
            if d < 785 then
                local fnt = P.GetFountain(bot)
                local homeDir = (fnt - enemy:GetLocation()):Normalized()
                local kiteRing = enemy:GetLocation() + homeDir * 815
                H.SmartMove(bot, kiteRing, 35)
                State.actionTaken = true
                return true
            end
        end
    end

    return false
end

-- `v4.2.0` Close Duel Hero-Attack Lock (`Demo 2` `7:40.87` & `Demo 1` `3:55`) + Equal-State Stand-Ground Anti-Zoning (`Demo 2` 25x)
function H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, preSacredCS, imminentCreepCS)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local enHp = enemy:GetHealth() or 9999
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    local enStacks, enRem = U.GetShadowrazeDebuff(enemy)
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    local fightingNow = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.8))

    if preSacredCS then
        -- STRICT Close-Duel Lock: fires ONLY inside active all-in hero duels (`d <= 555u`) so normal lane CS is NEVER touched!
        -- `9058240714.dem` `1:53.50..2:06.30` Root-Cause Fix (`-391 HP` tanking 4 enemy lane creeps + 25% uphill miss!):
        --   * Account explicitly for BOTH `uphillHitFactor` (`0.75` from river `z=0` into HG `z=128`) AND all live enemy creeps
        --     inside Source 2 `460u` aggro radius (`enemyCreepsInAggro * 13.0` DPS) + creeps already hitting `bot` (`creepsHittingBot`)!
        --   * When `creepsHittingBot >= 2` while enemy still needs `> 2` right-clicks (`enHp > myAtk * 2.15`), NEVER spam
        --     `IssueHeroAttack` in a 4-creep ring — immediately fire a 1-tick Source 2 Creep De-Aggro onto an allied creep
        --     and step back behind our allied wave!
        local bLocDuel = bot:GetLocation()
        local eLocDuel = enemy:GetLocation()
        local uphillHitFactor = ((eLocDuel.z or 0) - (bLocDuel.z or 0) >= 90) and 0.75 or 1.0
        local effMyAtk = math.max(1, myAtk * uphillHitFactor)
        local enemyCreepsInAggro, creepsHittingBot, bestDeaggAlly, bestDeaggDist = 0, 0, nil, math.huge
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc <= 460 or U.DistanceBetweenLocations(eLocDuel, ec:GetLocation()) <= 440 then
                    enemyCreepsInAggro = enemyCreepsInAggro + 1
                end
                if dc <= 250 and ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                    creepsHittingBot = creepsHittingBot + 1
                end
            end
        end
        for _, ac in pairs(s.allyCreeps or {}) do
            if ac and U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 65 then
                local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                if da < bestDeaggDist then
                    bestDeaggDist, bestDeaggAlly = da, ac
                end
            end
        end

        if creepsHittingBot >= 2 and enHp > myAtk * 2.15 and ((bot:GetMana() or 0) < 75 or K.MyReadyRazeCount(bot, true) == 0) then
            if U.TryDeaggro(bot, s, nil, 999) then
                State.actionTaken = true
                return true
            end
            local fnt = P.GetFountain(bot)
            local refBack = bestDeaggAlly and bestDeaggAlly:GetLocation() or bLocDuel
            local safeStep = U.SteerAroundObstacles(bot, refBack + (fnt - refBack):Normalized() * 235, s)
            H.SmartMove(bot, safeStep, 25)
            State.actionTaken = true
            return true
        end

        local mySpaD = math.max(0.55, bot:GetSecondsPerAttack() or 1.25)
        local enSpaD = math.max(0.55, enemy:GetSecondsPerAttack() or 1.25)
        local incomingDpsWithCreeps = (enAtk / enSpaD) + enemyCreepsInAggro * 12.5
        local outgoingDpsTrue = effMyAtk / mySpaD
        local blockedByCreepPack = (enemyCreepsInAggro >= 3 or (enemyCreepsInAggro >= 2 and uphillHitFactor < 1.0))
            and enHp > myAtk * 2.15
        local winningDrySoulDuel = (enPotMana < 75)
            and not blockedByCreepPack
            and d <= (bot:GetAttackRange() or 500) + 120
            and (myHp >= 150 or enHp <= myAtk * 1.15)
            and myHp >= enHp * 0.76
            and (effMyAtk >= enAtk + 8 or (fightingNow and enHp <= effMyAtk * 3.1))
            and (enHp / math.max(1, outgoingDpsTrue)) + 0.15 <= (myHp / math.max(1, incomingDpsWithCreeps))
        local activeStackedCloseDuel = d <= 545
            and (((enStacks or 0) >= 1 and (enRem or 0) > 1.8) or ((myStacks or 0) >= 1 and (myRem or 0) > 1.8 and fightingNow))
            and (myHp <= myMaxHp * 0.86 or enHp <= 560)
            and not H.InCriticalLethalDanger(bot, s, earlyRace)
            and (earlyRace and earlyRace.valid and ((earlyRace.edge or 0) >= -85 or earlyRace.canKillSoon))

        if not winningDrySoulDuel and not activeStackedCloseDuel then
            return false
        end

        H.ClearForcedRetreat()
        State.fleeUntil = 0
        if not bot:IsSilenced() then
            if (bot:GetMana() or 0) < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if (bot:GetMana() or 0) >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
        H.IssueHeroAttack(bot, enemy)
        State.actionTaken = true
        return true
    end

    -- Post-CS Equal-State Stand-Ground Anti-Zoning (`Demo 2` 25 forward step-ins fix!):
    -- When no creep CS is opening right now (`not imminentCreepCS`) and the rival hero aggressively steps forward
    -- across/into the wave (`d <= 685u`, `approach > 32` or standing past his creeps toward our fountain) on EVEN or
    -- FAVOURABLE resources, immediately punish with a centered coil + right-click instead of backing off the wave!
    if imminentCreepCS then return false end
    if d > 685 or myHp < 310 or myHp < enHp * 0.72 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or (earlyRace.edge or 0) < -65 or earlyRace.uphillPenalty) then
        return false
    end

    local approach = U.EnemyApproachSpeed(bot, enemy)
    local fnt = P.GetFountain(bot)
    local waveCenter = LN.AllyWaveCenter(s.allyCreeps)
    local steppedPastWave = waveCenter ~= nil
        and U.DistanceBetweenLocations(enemy:GetLocation(), fnt) <= U.DistanceBetweenLocations(waveCenter, fnt) + 125
    if approach <= 32 and not steppedPastWave and not fightingNow then
        return false
    end

    if not bot:IsSilenced() and (bot:GetMana() or 0) >= 75 then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end
    if d <= (bot:GetAttackRange() or 500) + 65 then
        local prevPolicy, prevAllow = State.combatPolicyActive, State.heroCombatAllowed
        State.combatPolicyActive = false
        State.heroCombatAllowed = true
        local okAtk = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive, State.heroCombatAllowed = prevPolicy, prevAllow
        if okAtk then
            State.actionTaken = true
            return true
        end
    end
    return false
end

function H.HandleDryEnemyAndSoulLeadHarass(bot, s, earlyRace, csWaveBusy)
    if State.actionTaken or csWaveBusy or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local atkRange = bot:GetAttackRange() or 500
    local enHp = enemy:GetHealth() or 9999
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local rawMyHp = bot:GetHealth() or 0
    local inFlightOnMe = 0
    if bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, pr in pairs(projs) do
                if pr then
                    local caster = pr.caster
                    if caster and caster.IsHero and caster:IsHero() then
                        inFlightOnMe = inFlightOnMe + enAtk
                    else
                        inFlightOnMe = inFlightOnMe + 18
                    end
                end
            end
        end
    end
    local myHp = math.max(1, rawMyHp - inFlightOnMe)
    local enTotalMana = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local enemyDry = (enTotalMana < 75) and (K.EnemyPhase() == nil)
    local uphill = earlyRace and earlyRace.valid and earlyRace.uphillPenalty

    local creepsOnMe = 0
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then
            creepsOnMe = creepsOnMe + 1
        end
    end

    -- Case 1: Enemy has ZERO spell threat (`< 75 MP`) — right-click punish on our soul/HP advantage!
    local crushingSoulLead = (enTotalMana < 150 and myAtk >= enAtk + 12 and (myHp - K.EnemyRazeDamage(bot, enemy, 1)) >= 255)
        or (enTotalMana < 225 and myAtk >= enAtk + 18 and (myHp - K.EnemyRazeDamage(bot, enemy, 2)) >= 75)
    local winningHitTrade = (math.ceil(enHp / math.max(1, myAtk)) <= math.ceil(myHp / math.max(1, enAtk)))
        or (myHp >= enHp * 0.88)
        or ((bot:GetMana() or 0) >= 75 and myHp >= enHp * 0.60)
    local pressDryKill = enemyDry and myHp >= 225 and not uphill
        and ((myAtk >= enAtk - 2 and creepsOnMe <= 1 and winningHitTrade)
            or (myHp >= enHp + 110 and enHp <= 400 and creepsOnMe <= 2))
    -- Case 2: Clear Soul/Attack-Damage Dominance (`>= +7` hero hit damage) with safe spell parity OR
    -- crushing `16 vs 7` soul + `2x Bracer` right-click dominance vs a `1`-coil (`< 150 MP`) enemy (`9056774541.dem` `02:35`!)
    local pressSoulLead = myHp >= 300 and creepsOnMe <= 1
        and earlyRace and earlyRace.valid and not earlyRace.heCanKillSoon
        and ((myAtk >= enAtk + 7 and not uphill and (earlyRace.edge or 0) >= 45)
            or crushingSoulLead)

    local maxReach = ((enemyDry and myHp >= enHp + 110 and enHp <= 400)
        or (enemyDry and myAtk >= enAtk + 12 and myHp >= 265)
        or crushingSoulLead)
        and (atkRange + 245) or (atkRange + 65)
    if (pressDryKill or pressSoulLead) and d <= maxReach then
        H.IssueHeroAttack(bot, enemy)
        State.lastHarassTime = GameTime()
        return true
    end
    return false
end

function H.InLosingHeroTrade(bot, s, race)
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local enHp = enemy:GetHealth() or 9999
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = myHp / myMaxHp
    local enRange = (enemy:GetAttackRange() or 500)
    local valid = race and race.valid
    local outMatched = valid and (race.heHasBootsLead or ((enemy:GetLevel() or 1) > (bot:GetLevel() or 1)))
    if valid and (race.canKillNow
        or (not outMatched and race.canKillSoon and (race.edge or 0) >= -30)
        or (race.canKillSoon and not race.heCanKillSoon and (race.edge or 0) >= 60)) then
        return false
    end

    -- `9056469656.dem` `02:29–02:35` & `01:42–02:02` Fix: NEVER treat a pure dry-mana right-click trade on flat/allied ground
    -- as "losing" when the enemy has `< 75 MP` (`0` Shadowrazes!) and we beat them decisively in HP / right-click TTK!
    local enTotalPool = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local enemyDry = (enTotalPool < 75) and (K.EnemyPhase() == nil)
    local winningDryBrawl = valid and not race.uphillPenalty
        and ((enemyDry and myHp >= enHp + 110 and (race.ttkHim or 999) < (race.ttkMe or 999) * 0.80)
            or (enemyDry and myHp >= 300 and myHp >= enHp - 40 and K.AttackDamageVs(bot, enemy) >= K.AttackDamageVs(enemy, bot) + 6)
            or (enTotalPool < 150 and not race.heCanKillSoon and (myHp - K.EnemyRazeDamage(bot, enemy, 1)) >= 255
                and K.AttackDamageVs(bot, enemy) >= K.AttackDamageVs(enemy, bot) + 12))
    if winningDryBrawl then return false end

    local lethalGuardDist = outMatched
        and math.max(845, enRange + 300, (race.minSafeDist or 0) + 90)
        or math.max(enRange + 280, (race.minSafeDist or 0) + 90)
    if valid and race.heCanKillSoon and dist <= lethalGuardDist then
        return true
    end

    local beingAttacked = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.1))
        or false
    -- Never stand on river lowground (`uphillPenalty`) or tanking >= 2 creeps eating enemy right-clicks!
    local creepAggroOnMe = 0
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then
            creepAggroOnMe = creepAggroOnMe + 1
        end
    end
    if beingAttacked and dist <= enRange + 110 and valid and not race.spellWindow then
        if race.uphillPenalty or creepAggroOnMe >= 2 or ((bot:GetLevel() or 1) <= 3 and (race.edgeLong or 0) < -65) then
            return true
        end
    end
    if valid and race.losingHard and not race.spellWindow
        and (beingAttacked or (hpPct <= 0.55 and dist <= enRange + 240))
        and dist <= enRange + 295 then
        return true
    end

    return false
end

function H.DisengageFromLethalTrade(bot, s, race)
    local enemy = s and s.enemy
    State.commitKillUntil = 0
    State.prepTarget = nil
    State.lhAttackTarget = nil
    H.ClearRazeState()
    H.ManageTreads(bot, "SURVIVE")
    local fountain = P.GetFountain(bot)
    local bLoc = bot:GetLocation()
    if (bot:GetHealth() or 0) <= 165 then
        -- Stay inside 1,220u XP range behind our T1 if courier Salve is on the way, else smooth retreat!
        local dir = (fountain - bLoc):Normalized()
        local wp = bLoc + dir * math.min(620, U.DistanceBetweenLocations(bLoc, fountain))
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, wp, 0.75)
    end
    if enemy and U.CanQuery(enemy) then
        local eLoc = enemy:GetLocation()
        local myHp = bot:GetHealth() or 0
        local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
        local twoRaze = K.EnemyRazeDamage(bot, enemy, 2)
        local enAtk = K.AttackDamageVs(enemy, bot)
        if myHp <= math.max(175, oneRaze + 45) and H.HandleSurvivalRetreat(bot, enemy, race) then
            State.actionTaken = true
            return true
        end
        -- Hold exact `920u..1080u` Outer-Hedge on our own highground:
        -- Note (`30.000 Hz` physics proof from `S5`/`S6`): when low HP (`myHp <= twoRaze + 140`), NEVER reduce
        -- radial escape speed (`v * cos(theta)` must stay `1.00 * 305 u/s` to clear `950u` `Shadowraze3` in minimum ticks!);
        -- only add a slight `22 deg` (`cos = 0.93`) diagonal offset right after an opening close `Q` (`curDist <= 460`) when healthy!
        local homeDir = (fountain - eLoc):Normalized()
        local approach = U.EnemyApproachSpeed(bot, enemy)
        local baseDist = (myHp <= twoRaze + enAtk * 2.1 + 40) and 940 or 780
        local targetDist = math.min(1180, baseDist + math.min(220, approach * 0.8))
        local curDist = U.DistanceBetweenLocations(bLoc, eLoc)
        local isEnemySF = (enemy:GetUnitName() == "npc_dota_hero_nevermore")
        -- 1. Defensive Snap-Coil Counter when being run down by a faster dry/0-coil enemy (`Death #1` `05:42..05:48` fix!):
        --    When enemy has `0` coils available (`< 75 MP` or all CDs), outruns us (`enMS > myMS + 10`), is inside `520u`,
        --    and we have mana + survive the `0.55s` cast window between his autos (`myHp >= enAtk + 45`), fire our
        --    dead-center defensive `Shadowraze` instead of dying with `166 MP` & `3/3` unused coils!
        local myMS = bot:GetCurrentMovementSpeed() or 305
        local enMS = enemy:GetCurrentMovementSpeed() or 305
        local enNoCoils = K.EnemyManaBudget(enemy, true) < 75 or K.EnemyReadyRazeCount(enemy, 0.7, true) == 0
        if enNoCoils and enMS > myMS + 10 and curDist <= 520 and (bot:GetMana() or 0) >= 75
            and myHp >= enAtk + 45 and not H.HasEnemyProjectileIncoming(bot) then
            for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                local ab = H.GetRazeAbilityByLabel(bot, label)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local action, aim = H.GetRazeActionType(bot, ab, enemy)
                    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                        State.actionTaken = true
                        return true
                    end
                end
            end
        end
        -- 2. Immortal Coil-Ray Break (`Death #2` `06:48.37..06:50.70` `33 deg` Q->W->E straight-line death fix!):
        --    When enemy SF enters shadowraze cast animation (`inCastNow ~= nil`) inside `curDist <= 585u`, step
        --    `64 deg` laterally with a sticky locked side (`State.coilBreakSide` for `1.2s`, NEVER flipping sign as
        --    enemy rotates!). When enemy is NOT casting (chasing with right-clicks), sprint at `100%` radial speed!
        local inCastNow = K.EnemyPhase() ~= nil
        if isEnemySF and not enNoCoils and inCastNow and curDist >= 180 and curDist <= 585 then
            local nowT = GameTime()
            local perp = Vector(-homeDir.y, homeDir.x, 0)
            local side = (nowT < (State.coilBreakUntil or 0)) and State.coilBreakSide or nil
            if not side then
                local eFaceRad = math.rad((enemy.GetFacing and enemy:GetFacing()) or 0)
                local rayX, rayY = math.cos(eFaceRad), math.sin(eFaceRad)
                local rel = bLoc - eLoc
                local crossRay = rayX * rel.y - rayY * rel.x
                if math.abs(crossRay) > 25 then
                    side = (crossRay >= 0) and 1.0 or -1.0
                else
                    local fnt = P.GetFountain(bot)
                    local dPlus = U.DistanceBetweenLocations(bLoc + perp * 160, fnt)
                    local dMinus = U.DistanceBetweenLocations(bLoc - perp * 160, fnt)
                    side = (dPlus <= dMinus) and 1.0 or -1.0
                end
                local testPt = bLoc + (homeDir * 0.44 + perp * (side * 0.90)):Normalized() * 340
                if W.s and W.s.enemyT1Loc and U.DistanceBetweenLocations(testPt, W.s.enemyT1Loc) < 880 then
                    side = -side
                end
                State.coilBreakSide = side
                State.coilBreakUntil = nowT + 1.20
            end
            local sidestepDir = (homeDir * 0.44 + perp * (side * 0.90)):Normalized()
            local lateralPoint = bLoc + sidestepDir * 360
            State.actionTaken = true
            return H.BeginForcedRetreat(bot, lateralPoint, 0.45)
        end
        local rawPoint = eLoc + homeDir * targetDist
        local point = H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawPoint, 440)
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, point, 0.65)
    end
    return false
end

-- Find an item in slots `0..8`; if in Backpack `6..8`, swap it into the lowest-priority active slot `0..5`
-- cleanly (`branchTangoSwapUntil` holds `ManageInventorySlots` back until the 6.0s Backpack CD unlocks & casts!).
-- Multiple Backpack consumables (e.g. `item_flask` + `item_ward_observer`) swap into DISTINCT active slots on the same tick!
function H.EnsureConsumableReady(bot, itemName)
    local slot = bot:FindItemSlot(itemName)
    if slot < 0 or slot > 8 then return nil, false end
    if slot <= 5 then
        local it = bot:GetItemInSlot(slot)
        -- Hold `branchTangoSwapUntil` BOTH during the 6.0s Backpack CD AND during the short walk/turn to use it!
        State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or -1000, GameTime() + 2.5)
        return it, (it ~= nil and it:IsFullyCastable())
    end
    local bestSlot, bestPrio = nil, math.huge
    for i = 0, 5 do
        local it = bot:GetItemInSlot(i)
        if not it then
            bestSlot = i
            break
        end
        local nm = it:GetName()
        -- Strictly respect unified `U.GetEffectiveItemPriority` AND NEVER displace another active consumable
        -- (`item_tango` / `item_enchanted_mango` / `item_flask` / `item_ward_observer`) — breaks 100% of swap loops!
        if not U.IsProtectedCombatItem(nm)
            and nm ~= "item_flask" and nm ~= "item_ward_observer"
            and nm ~= "item_tango" and nm ~= "item_enchanted_mango"
            and nm ~= "item_faerie_fire" and nm ~= "item_magic_stick"
            and nm ~= "item_magic_wand" then
            local pr = U.GetEffectiveItemPriority(bot, nm)
            if pr < bestPrio then
                bestPrio = pr
                bestSlot = i
            end
        end
    end
    if bestSlot ~= nil then
        bot:ActionImmediate_SwapItems(slot, bestSlot)
        State.branchTangoSwapUntil = GameTime() + 8.5
        local moved = bot:GetItemInSlot(bestSlot)
        return moved, (moved ~= nil and moved:IsFullyCastable())
    end
    return nil, false
end

-- Immediate Anti-Free-Harass Retaliation (`auto-20261023-1329-start-ShaNachnetsya.dem` `tk=6142..6326` & `tk=10644..10874` Fix!):
-- Whenever the live rival hero right-clicks us within `720u` outside an active final CS windup, NEVER stand idle or
-- auto-attack full-HP creeps while taking unanswered right-clicks! Immediately punish with a centered `Shadowraze` +
-- right-click (when healthy/even), OR step crisply outside his attack range (when low/outmatched)!
function H.HandleAntiFreeHarassRetaliation(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if d > 730 then return false end

    local activelyHittingMe = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.35))
    if not activelyHittingMe then return false end

    -- Never brawl inside enemy T1 attack range!
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(bot, tw:GetLocation()) <= 760 then
            return H.DisengageFromLethalTrade(bot, s, earlyRace)
        end
    end

    local enAtk = K.AttackDamageVs(enemy, bot)
    local myAtk = K.AttackDamageVs(bot, enemy)
    local inFlightOnMe = 0
    if bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, pr in pairs(projs) do
                if pr then
                    local caster = pr.caster
                    inFlightOnMe = inFlightOnMe + ((caster and caster.IsHero and caster:IsHero()) and enAtk or 18)
                end
            end
        end
    end
    local myEffHp = math.max(1, (bot:GetHealth() or 0) - inFlightOnMe)
    local enHp = enemy:GetHealth() or 9999
    local lr = U.SolveLethalRace(bot, enemy, s)
    local mySt, myRem = U.GetShadowrazeDebuff(bot)

    -- If low HP or carrying dangerous fresh stacks without first-kill advantage, step clean outside his attack range!
    -- v4.3.3: a symmetric dry/equal-resource trade is not "low HP fear" when the TTK is not lost.
    local parityHold = earlyRace and earlyRace.valid and earlyRace.parityHold
    local parityFloor = enAtk * 1.25 + 60
    if not (lr and lr.winsFirstKill) then
        if (myEffHp < 235 and not (parityHold and myEffHp >= parityFloor))
            or ((mySt or 0) >= 2 and (myRem or 0) > 0.4)
            or (H.InLosingHeroTrade(bot, s, earlyRace) and not parityHold) then
            return H.DisengageFromLethalTrade(bot, s, earlyRace)
        end
    end

    -- 1. Punish brazen close/mid/far right-click harass immediately with a dead-center `Shadowraze`!
    local canPopMango = (bot:GetMana() or 0) < 75 and myEffHp >= 260 and d <= 650
    if canPopMango and H.TryUseBurstManaItem(bot, true) then
        return true
    end
    if not bot:IsSilenced() and (bot:GetMana() or 0) >= 75 and not ((mySt or 0) == 1 and (myRem or 0) <= 2.0 and (myRem or 0) > 0.2) then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    -- 2. Return crisp right-click when trade is even/favorable (`myEffHp >= enHp * 0.62` or winning hit count), else kite back!
    local winningOrEvenClick = (lr and lr.winsFirstKill)
        or (math.ceil(enHp / math.max(1, myAtk)) <= math.ceil(myEffHp / math.max(1, enAtk)) + 1 and myEffHp >= 270)
        or (myEffHp >= enHp * 0.68 and myEffHp >= 260)
        or (parityHold and myEffHp >= parityFloor and myEffHp >= enHp * 0.62)
    if winningOrEvenClick and d <= (bot:GetAttackRange() or 500) + 95 then
        local prevPolicy = State.combatPolicyActive
        local prevAllow = State.heroCombatAllowed
        State.combatPolicyActive = false
        State.heroCombatAllowed = true
        local okAtk = H.IssueHeroAttack(bot, enemy, true)
        State.combatPolicyActive = prevPolicy
        State.heroCombatAllowed = prevAllow
        if okAtk then
            if State.heroReplyEnemy == enemy then State.heroReplyAnsweredAttack = true end
            State.actionTaken = true
            return true
        end
    end

    return H.DisengageFromLethalTrade(bot, s, earlyRace)
end

-- Safe Enemy Observer/Sentry Deward (`A16` Team-Guarded Ward Check + Free Highground Vision Denial!):
-- Strictly requires `w:GetTeam() ~= bot:GetTeam()` so own/allied Observer Wards are NEVER attacked!
function H.HandleFreeEnemyWardDeward(bot, s)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if L._imminentCS then return false end
    if type(GetUnitList) ~= "function" or not UNIT_LIST_ENEMY_WARDS then return false end
    local enemy = s and s.enemy
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() and (s.enemyDist or 9999) <= 760 then
        return false
    end
    local danger = LN.TowerDanger(bot, s and s.enemyT1 or nil, s and s.allyCreeps or nil, nil)
    if danger >= 1 then return false end
    local ok, wards = pcall(GetUnitList, UNIT_LIST_ENEMY_WARDS)
    if not ok or type(wards) ~= "table" then return false end
    local myTeam = bot:GetTeam()
    local maxReach = (bot:GetAttackRange() or 500) + 95
    for _, w in pairs(wards) do
        local wName = (w and w.GetUnitName and w:GetUnitName()) or ""
        if wName:find("ward") and U.CanQuery(w) and w:IsAlive() and w.GetTeam and w:GetTeam() ~= myTeam then
            if GetUnitToLocationDistance(bot, w:GetLocation()) <= maxReach then
                if not (U.IsAttackingAction(bot) and bot:GetAttackTarget() == w) then
                    bot:Action_AttackUnit(w, true)
                    H.ClearMoveCache()
                end
                State.actionTaken = true
                return true
            end
        end
    end
    return false
end

-- Top-Level Highground Observer Ward Planter (fixes pre-horn & 5:00 Night Ward staying unplanted in slot/backpack!)
function H.HandlePriorityWardPlant(bot, s)
    local now = GameTime()
    if now < (State.lastWardCheckAt or -100) then return false end
    if bot:FindItemSlot("item_ward_observer") < 0 or bot:FindItemSlot("item_ward_observer") > 8 then
        return false
    end
    local dtime = DotaTime()
    local enemyNear = s and s.enemy and U.CanQuery(s.enemy) and s.enemyDist <= 880
    local creepsBusy = s and (#(s.enemyCreeps or {}) > 0) and dtime >= 0
    if enemyNear or creepsBusy then return false end

    local ward, castable = H.EnsureConsumableReady(bot, "item_ward_observer")
    local wardLoc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
    if not wardLoc then return false end
    local d = GetUnitToLocationDistance(bot, wardLoc)
    if castable and ward then
        if d <= 475 then
            bot:Action_UseAbilityOnLocation(ward, wardLoc)
            State.lastWardCheckAt = now + 1.0
            State.actionTaken = true
            return true
        else
            H.SmartMove(bot, wardLoc, 45)
            State.actionTaken = true
            return true
        end
    elseif dtime < -6 and d > 420 then
        H.SmartMove(bot, wardLoc, 45)
        State.actionTaken = true
        return true
    end
    return false
end

-- Top-Level Proactive Salve Trigger & Active `modifier_flask_healing` Guard (ABOVE `RunSacredCS` & `holdSpot`!):
-- Eliminates Death #1 (`690/1034 HP` with unused `[0]Flask(1)`) & Death #2 (`614/1078 HP` idle for `12s` with `[0]Flask(1)`),
-- AND fixes `9056469656.dem` `02:03–02:18` (`tk=6668..7098`): when enemy SF has `< 75 MP` (cannot cast `Shadowraze3` at `950u`!),
-- `safeDist` drops from `1065u` to `enemyAttackRange + 185` (`685u`), letting our SF hold ground under own T1 and farm `4/4` CS!
function H.HandleProactiveAndActiveSalve(bot, s, _earlyRace)
    local enemy = s and s.enemy
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local curHp = bot:GetHealth() or 0
    local missingHp = maxHp - curHp
    local hpPct = curHp / maxHp
    local fountain = P.GetFountain(bot)
    local safeDist = 1120 -- Default clearance vs `Shadowraze3` (`950u`) + walk lead (`Demo 1` `2:47` & `4:10` Fix!)
    local enApproachSpd = 0
    if enemy and U.CanQuery(enemy) then
        enApproachSpd = U.EnemyApproachSpeed(bot, enemy)
        local enAtkR = (enemy.GetAttackRange and enemy:GetAttackRange()) or 500
        if K.EnemyManaBudget(enemy, true) < 75 or not U.EnemyHasRaze(enemy) then
            safeDist = math.max(690, enAtkR + 205 + math.min(180, enApproachSpd * 0.7))
        else
            safeDist = math.min(1290, math.max(1110, enAtkR + 240, K.EnemyMinSafeDistance(enemy, 1.0) + 95 + math.min(200, enApproachSpd * 0.85)))
        end
    end

    -- Also treat an enemy who dipped into river/highground FoW `< 4.5s` ago at `enemyLastLoc` as LIVE threat (`Demo 1` `2:45.4` Fix!)
    local fogEnemyLoc = (not (enemy and U.CanQuery(enemy)))
        and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 4.5
        and s.enemyLastLoc or nil
    local effEnemyLoc = (enemy and U.CanQuery(enemy) and enemy:GetLocation()) or fogEnemyLoc
    local effEnemyDist = effEnemyLoc and GetUnitToLocationDistance(bot, effEnemyLoc) or 9999

    -- 1. Protect active Healing Salve ONLY against real Salve-breaking sources (Dota 2 7.00-7.41f rule:
    -- ONLY Hero / Tower / Player-Controlled / Roshan hits >= 20 dmg cancel `modifier_flask_healing`; lane creeps NEVER break Salve!).
    if bot:HasModifier("modifier_flask_healing") then
        if hpPct >= 0.96 then
            State.branchTangoSwapUntil = 0
            return false
        end
        -- Never throw away a free hero kill right in front of us when already above lethal threshold!
        if enemy and U.CanQuery(enemy) and enemy:IsAlive() and curHp >= 240
            and not (_earlyRace and _earlyRace.valid and _earlyRace.heCanKillSoon) then
            if U.CanOneShotEnemyHero(bot, enemy) or U.CanQuickTurnKillWithRaze(bot, enemy)
                or (curHp >= 300 and H.CanTwoHitRightClickKill(bot, enemy, s)) then
                return false
            end
        end
        local needStepBack = H.HasSalveBreakingProjectileIncoming(bot)
        local hystThreshold = (GameTime() < (State.salveStepBackHystUntil or -1000)) and (safeDist + 110) or safeDist
        if effEnemyLoc and effEnemyDist < hystThreshold then
            needStepBack = true
        end
        -- Also step out of enemy creep vision (`< 540u`) while enemy mid is unseen in recent FoW (`Demo 1` `2:46.8` Fix!):
        if not (enemy and U.CanQuery(enemy)) and s and s.enemyAlive ~= false and (s.enemyAbsentFor or 0) <= 6.5 then
            for _, ec in pairs(s.enemyCreeps or {}) do
                if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) < 540 then
                    needStepBack = true
                    break
                end
            end
        end
        for _, tw in pairs((s and s.enemyTowers) or {}) do
            if tw and tw:IsAlive() and GetUnitToLocationDistance(bot, tw:GetLocation()) < 830 then
                needStepBack = true
                break
            end
        end
        if needStepBack then
            State.salveStepBackHystUntil = GameTime() + 1.05
            local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 520)) or (bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 320)
            local anchor = behindT1
            if effEnemyLoc then
                local rawAnchor = effEnemyLoc + (fountain - effEnemyLoc):Normalized() * (safeDist + 115)
                local behindDeep = (P.GetBehindT1 and P.GetBehindT1(bot, 780)) or behindT1
                if U.DistanceBetweenLocations(rawAnchor, fountain) < U.DistanceBetweenLocations(behindDeep, fountain) then
                    anchor = behindDeep
                else
                    anchor = rawAnchor
                end
            end
            if U.DistanceBetweenLocations(bot:GetLocation(), fountain) > U.DistanceBetweenLocations(anchor, fountain) then
                H.SmartMove(bot, anchor, 40)
            end
            State.actionTaken = true
            return true
        end
        -- When already at safe distance with NO enemy lane creeps to farm (`#enemyCreeps == 0`), HOLD STILL until Salve finishes
        -- so `holdSpot (363, 525)` NEVER marches a healing hero right back into `ShaNachnetsya`'s `Shadowraze3` (`S47` = `0` reversals!).
        if #(s and s.enemyCreeps or {}) == 0 then
            State.actionTaken = true
            return true
        end
        return false
    end

    -- 2. Trigger owned Healing Salve (`missingHp >= 300` OR `hpPct <= 0.62`, slots `0..8`)
    if missingHp < 300 and hpPct > 0.62 then return false end
    if H.IsAtFountain(bot) then return false end
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() and GetUnitToLocationDistance(bot, enemy:GetLocation()) <= safeDist then
        if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
        local dominatingLevel = ((bot:GetLevel() or 1) > (enemy:GetLevel() or 1))
            and curHp >= 460
            and not (_earlyRace and _earlyRace.valid and _earlyRace.heCanKillSoon)
        local winningCombat = _earlyRace and _earlyRace.valid
            and (_earlyRace.canKillNow or _earlyRace.canKillSoon
                or (((_earlyRace.edge or 0) > 65) and curHp >= 450 and not _earlyRace.heCanKillSoon))
        if dominatingLevel or winningCombat then
            return false
        end
    end
    local flaskSlot = bot:FindItemSlot("item_flask")
    if flaskSlot < 0 or flaskSlot > 8 then return false end

    local flask, castable = H.EnsureConsumableReady(bot, "item_flask")
    local unsafeHere = H.HasSalveBreakingProjectileIncoming(bot)
    if effEnemyLoc and effEnemyDist < (safeDist + 45) then
        unsafeHere = true
    end
    -- NEVER pop `Healing Salve` inside enemy lane creep vision (`< 540u`) while enemy mid is alive in recent FoW (`<= 6.5s`):
    -- enemy creeps grant shared vision directly to the unseen enemy SF right behind the wave (`Demo 1` `2:47` & `4:10` Fix!).
    if not (enemy and U.CanQuery(enemy)) and s and s.enemyAlive ~= false and (s.enemyAbsentFor or 0) <= 6.5 then
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) < 540 then
                unsafeHere = true
                break
            end
        end
    end
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(bot, tw:GetLocation()) < 830 then
            unsafeHere = true
            break
        end
    end
    if unsafeHere then
        local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 520)) or (bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 320)
        local anchor = behindT1
        if effEnemyLoc then
            local rawAnchor = effEnemyLoc + (fountain - effEnemyLoc):Normalized() * (safeDist + 95)
            local behindDeep = (P.GetBehindT1 and P.GetBehindT1(bot, 780)) or behindT1
            if U.DistanceBetweenLocations(rawAnchor, fountain) < U.DistanceBetweenLocations(behindDeep, fountain) then
                anchor = behindDeep
            else
                anchor = rawAnchor
            end
        end
        if U.DistanceBetweenLocations(bot:GetLocation(), fountain) > U.DistanceBetweenLocations(anchor, fountain) then
            H.SmartMove(bot, anchor, 40)
        end
        State.actionTaken = true
        return true
    end

    -- `ShaNachnetsya` Immortal Stat-Drop Salve Amplification (`06:27.90..06:45.70` replay mechanic):
    -- Move `Bracer`/`Circlet` into free Backpack slots BEFORE `Action_UseAbilityOnEntity(flask, bot)` and hold
    -- `State.branchTangoSwapUntil = GameTime() + 8.15` across the 8.0s Salve channel so `ManageInventorySlots`
    -- restores them AFTER `modifier_flask_healing` completes (`+145..+287` bonus effective HP in live Dota 2 C++!)
    if castable and flask and GameTime() > (State.lastSalveCastAt or -1000) + 0.25 then
        H.ManageTreads(bot, "FIGHT") -- AGI/INT before healing so switching back to STR multiplies restored HP%
        local didSwap = false
        local safeOutOfCombat = not (enemy and U.CanQuery(enemy) and GetUnitToLocationDistance(bot, enemy:GetLocation()) < safeDist)
        if safeOutOfCombat then
            for sSlot = 0, 5 do
                local it = bot:GetItemInSlot(sSlot)
                if it and (it:GetName() == "item_bracer" or it:GetName() == "item_circlet") then
                    for bpSlot = 6, 8 do
                        if not bot:GetItemInSlot(bpSlot) then
                            bot:ActionImmediate_SwapItems(sSlot, bpSlot)
                            didSwap = true
                            break
                        end
                    end
                end
            end
        end
        if didSwap then
            State.branchTangoSwapUntil = GameTime() + 8.15
        end
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastSalveCastAt = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    -- `R2_2044` `04:21..04:26` `(1653, 1533) <-> (1450, 1334)` 1.00s Ping-Pong Fix:
    -- While an owned `item_flask` just moved out of Backpack (`flask ~= nil`, `not castable`) and no lane creeps exist,
    -- hold safely behind our T1 for the remaining Backpack unlock seconds so `holdSpot` & `EmergencyRetreat` NEVER fight!
    if flask and not castable and #(s and s.enemyCreeps or {}) == 0 then
        local waitAnchor = (P.GetBehindT1 and P.GetBehindT1(bot, 420)) or bot:GetLocation()
        if U.DistanceBetweenLocations(bot:GetLocation(), fountain) > U.DistanceBetweenLocations(waitAnchor, fountain) then
            H.SmartMove(bot, waitAnchor, 45)
        end
        State.actionTaken = true
        return true
    end
    return false
end

-- `ShaNachnetsya` Immortal Stat-Drop + AGI-Tread Mango Amplification (out-of-combat between waves):
-- Momentarily swaps up to 2 stat items (`Bracer` / `Circlet`) to free Backpack slots, pops `Mango` (`+100` flat MP
-- on reduced max-mana pool = `+135..+170` effective restored MP!), and swaps stat items right back!
function H.TryBackpackAmpMango(bot, s)
    -- Urgent Low-Mana Mango Pop (`auto-20261023-1329-start-ShaNachnetsya.dem` `tk=9902..11852` Fix!):
    -- If SF is below `90 MP` (cannot cast even a single safe `Shadowraze` + buffer!), pop `Mango` IMMEDIATELY at ANY HP%
    -- and EVEN during an active wave without dropping stat items — NEVER starve at `< 75 MP` for 65 seconds holding Mango!
    if (bot:GetMana() or 0) < 90 then
        local mangoUrgent, castUrgent = H.EnsureConsumableReady(bot, "item_enchanted_mango")
        if castUrgent and mangoUrgent then
            bot:Action_UseAbility(mangoUrgent)
            State.lastItemUseTime = GameTime()
            State.branchTangoSwapUntil = 0
            State.actionTaken = true
            return true
        end
        return false
    end

    -- v4.3.5: the old "drop two Bracers, eat mango, swap back" micro lost 320 max HP
    -- for 8+ seconds in the supplied replay. Keep the urgent mango use above, but do
    -- not perform stat-drop amplification unless a future replay proves it safe.
    if not (C.ITEMS and C.ITEMS.BACKPACK_MANGO_AMP) then return false end
    if (bot:GetMaxMana() - bot:GetMana()) < 115 then return false end
    if (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.65 then return false end
    if s and s.enemy and U.CanQuery(s.enemy) and s.enemyDist <= 1050 then return false end
    if s and #(s.enemyCreeps or {}) > 0 then return false end
    local mango, castable = H.EnsureConsumableReady(bot, "item_enchanted_mango")
    if not castable or not mango then return false end
    H.ManageTreads(bot, "FIGHT") -- Switch away from INT before flat +100 MP restore!
    local swapped = {}
    for sSlot = 0, 5 do
        local it = bot:GetItemInSlot(sSlot)
        if it then
            local nm = it:GetName()
            if nm == "item_bracer" or nm == "item_circlet" then
                for bp = 6, 8 do
                    if not bot:GetItemInSlot(bp) then
                        bot:ActionImmediate_SwapItems(sSlot, bp)
                        swapped[#swapped + 1] = { sSlot, bp }
                        break
                    end
                end
            end
        end
    end
    if #swapped > 0 then
        State.branchTangoSwapUntil = GameTime() + 0.15
    end
    bot:Action_UseAbility(mango)
    State.lastItemUseTime = GameTime()
    State.actionTaken = true
    return true
end

-- Wave-Safe Static-Tree Tango Controller (runs AFTER `RunSacredCS`, BEFORE `holdSpot` — NEVER plants TempTree,
-- NEVER drops a 0.000s lane CS, `userdata`-safe `(bot, enemyHero, enemyTowers)` argument order!).
function H.TryWaveSafeStaticTango(bot, s, csWaveBusy)
    if bot:HasModifier("modifier_tango_heal") or bot:HasModifier("modifier_flask_healing") then
        State.tangoCastAt = 0
        return false
    end
    local missingHp = (bot:GetMaxHealth() or 0) - (bot:GetHealth() or 0)
    local hpPct = (bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 1)
    if missingHp < 115 and hpPct > 0.82 then return false end
    if H.IsAtFountain(bot) then return false end
    local tangoSlot = bot:FindItemSlot("item_tango")
    if tangoSlot < 0 or tangoSlot > 8 then return false end

    local now = GameTime()
    if State.tangoCastAt and now < State.tangoCastAt then
        State.actionTaken = true
        return true
    end

    -- CRITICAL (`auto-20261023-1329-start-ShaNachnetsya.dem` `tk=9902..11852` Infinite Swap Fix!):
    -- ALWAYS validate `tree` AND `dist <= allowedTreeWalk` BEFORE calling `EnsureConsumableReady("item_tango")`!
    -- Previously, swapping `Tango` into slot `0..5` BEFORE checking `dist <= 360u` caused `TryWaveSafeStaticTango` to
    -- return `false` once unlocked at `t = 6.0s`, letting `ManageInventorySlots` kick `Tango` back to Backpack at `7.5s` forever!
    local tree = H.GetStickyTangoTree(bot, s and s.enemy or nil, s and s.enemyTowers or {})
    if not tree then return false end
    local treeLoc = GetTreeLocation(tree)
    if not treeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, treeLoc)
    local waveActive = s and (#(s.enemyCreeps or {}) > 0 or #(s.allyCreeps or {}) > 0)
    local unopposedEnemyWave = s and #(s.enemyCreeps or {}) > 0 and #(s.allyCreeps or {}) == 0
    local enemyLive = s and s.enemy and U.CanQuery(s.enemy)
    -- Allow `<= 920u` ramp-tree walk when below `65% HP` (from river `(0,0)` to our T1 highground trees is `620..880u` —
    -- previously walking down to the river during the 6.0s Backpack CD put the tree at `700..870u > 520u`!)
    local maxSafeTreeWalk = unopposedEnemyWave and 185 or ((not csWaveBusy and enemyLive and hpPct <= 0.80) and 300 or 240)
    local allowedWalk = (hpPct <= 0.65 and not unopposedEnemyWave) and 920 or maxSafeTreeWalk
    if waveActive and dist > allowedWalk then
        return false
    end

    local tango, castable = H.EnsureConsumableReady(bot, "item_tango")
    if not tango then return false end
    if not castable then
        -- Pre-walk toward the safe ramp tree while Backpack CD counts down when no CS is active (or HP <= 55%)!
        if (not csWaveBusy and (not waveActive or hpPct <= 0.55)) and dist > 155 then
            H.SmartMove(bot, treeLoc, 40)
            State.actionTaken = true
            return true
        end
        return false
    end

    if dist <= 165 then
        if State.lastTriedTreeId == tree and State.lastTriedTreeAt and now - State.lastTriedTreeAt > 0.65 and now - State.lastTriedTreeAt < 3.0 then
            State.blacklistedTrees = State.blacklistedTrees or {}
            State.blacklistedTrees[tree] = now + 15.0
            State.stickyTangoTree = nil
            State.lastTriedTreeId = nil
            return false
        end
        bot:Action_UseAbilityOnTree(tango, tree)
        State.lastTriedTreeId = tree
        State.lastTriedTreeAt = now
        State.lastItemUseTime = now
        State.tangoCastAt = now + 0.55
        State.branchTangoSwapUntil = 0
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end
    H.SmartMove(bot, treeLoc, 40)
    State.actionTaken = true
    return true
end

function H.RealThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    -- Track attack animation before any handler can cancel or re-issue an order.
    H.UpdateAttackActivity(bot)

    State.actionTaken = false
    State.combatPolicyActive = false
    State.holdPos = false
    _G.__lastCombatStage = nil
    FDBG("think")
    U.BeginPredictionFrame()

    -- World snapshot + enemy raze tracker
    local s = W.Update(bot)
    K.UpdateEnemyTracker(bot, s.enemy)
    -- v4.3.6-tempo: observable AHEAD/EVEN/BEHIND FSM with hysteresis.
    State.tempo = T.Update(bot, s)
    H._enemyHeroNear = s.enemy -- GetSafeApproach & HandleActiveRazeValidation read live enemy hero
    -- The hit/miss tracker for his razes - before decisions (the instant mirror reads it)
    if s.enemy then U.UpdateEnemyRazeMissTracker(bot, s.enemy) end
    H.NoteEnemyHeroAction(bot, s.enemy, s)

    -- A visible channel/respawn gives a conservative arrival warning only when
    -- no actual visible landing point is available. It is not a known destination.
    if #(s.incomingEnemyTPs or {}) == 0 and s.enemy and U.IsEnemyTPChanneling(s.enemy) then
        State.enemyTPIncomingUntil = s.now + 3.0
    end
    if #(s.incomingEnemyTPs or {}) == 0 and s.enemyAlive and State.enemyWasAlive == false then
        State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, s.now + 6.0)
    end
    State.enemyWasAlive = s.enemyAlive

    -- A TP channel is running - no orders (any order cancels the teleport to the T1)
    if bot:IsChanneling() then
        State.actionTaken = true
        return
    end

    H.LevelUpAbilities(bot)
    -- v4.3.5: a completed Bracer/Boots in the backpack is a real stat loss, not a
    -- harmless swap cooldown. Restore it even while branchTangoSwapUntil is active.
    U.RestoreCombatStats(bot)

    -- Keep active inventory organized UNLESS a Backpack consumable is actively unlocking/casting (`branchTangoSwapUntil`)
    if GameTime() >= (State.branchTangoSwapUntil or -1000) then
        U.ManageInventorySlots(bot)
    end
    local earlyRace = K.Race(bot, s.enemy, false, s)

    -- Emergency survival consumables WITH full earlyRace context (Faerie Fire +85, Stick/Wand, Mango)
    if H.HandleEmergencyConsumables(bot, earlyRace, s) then return end
    if H.HandleIncomingTeleport(bot, s) then return end
    if H.HandleFreshEnemyTPArrival(bot, s, earlyRace) then return end

    -- FOUNTAIN RESPAWN / HEAL + IMMEDIATE TP TO MID T1 (runs BEFORE RunSacredCS and empty-wave holdSpot!)
    if H.HandleReturnTP(bot) then return end

    -- =========================================================================
    -- SACRED 30.000 Hz BALLISTIC CS & IMMORTAL LANE SUSTAIN PRIORITY GATE
    -- =========================================================================
    if H.HandleActiveRazeValidation(bot) then return end
    if bot:IsUsingAbility() then return end
    if s.enemy then
        local lrQuick = U.SolveLethalRace(bot, s.enemy, s)
        if lrQuick and lrQuick.winsFirstKill and lrQuick.needEmergencyHeal then
            local wandQuick = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
            if wandQuick and wandQuick:IsFullyCastable() and U.GetStickCharges(bot) > 0 then
                bot:Action_UseAbility(wandQuick)
                State.actionTaken = true
                return
            end
            local ffQuick = U.GetActiveItemByName(bot, "item_faerie_fire")
            if ffQuick and ffQuick:IsFullyCastable() and (bot:GetHealth() or 999) <= math.max(95, (bot:GetMaxHealth() or 600) * 0.15) then
                bot:Action_UseAbility(ffQuick)
                State.actionTaken = true
                return
            end
        end
        if H.HandleGuaranteedRazeKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
        if H.HandleGuaranteedAttackKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
    end
    if H.HandleEnemyRazeDodge(bot, s.enemy) then return end
    -- Instant `0`-tick Siege Glyph check runs BEFORE `HandleEnemyTowerSafety` (`9055695956.dem` `tk=14412` fix:
    -- `ActionImmediate_Glyph` does NOT consume our hero's unit order and works even while SF stands back at `912u`!)
    H.HandleSiegeGlyph(bot, s, earlyRace)
    if H.HandleEnemyTowerSafety(bot, s, s.enemy) then return end

    -- Throne-Grade Mid T1 Sudden-Death Defense (`BAR 9:10`), Tower-Diver Execution (`BAR 4:10`), & Low-HP Finish (`BAR 5:09`/`6:12`)
    if H.HandleCriticalAllyT1AndDivePunish(bot, s, earlyRace) then return end

    -- Top-Level Post-Kill Check BEFORE `goingToFountain` clear so an actual low-HP 0-gold reset never aborts halfway!
    if H.HandlePostKillReset(bot, s) then return end

    -- Top-Level Salve Trigger & Active `modifier_flask_healing` Protection (`missingHp >= 300` -> full 100% HP!)
    if H.HandleProactiveAndActiveSalve(bot, s, earlyRace) then return end

    -- Pre-horn & safe Night Highground Observer Ward Planter
    if H.HandlePriorityWardPlant(bot, s) then return end

    -- CRITICAL `v4.0.0`–`v4.2.0` FIRST-KILL `TTK` & MULTI-STACK COMBO OVERRIDE:
    -- MUST execute ABOVE `InCriticalLethalDanger` so lethal 3rd-stack `Raze3` (`Demo 2` `7:41`), 2nd-stack overlap chains
    -- (`Demo 1` `1:20` & `Demo 2` `7:13.3`), and dominant dry-mana duels (`Demo 1` `3:55`) NEVER abort to flee!
    if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then return end
    if H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, true) then return end

    -- Stage A: Critical life & Outer-Hedge `Shadowraze3` Bait/Dodge Protection
    -- `auto-20261022-2237-start-ShaNachnetsya.dem` `05:42` (`Death #1`) Fix:
    -- If an enemy SF already closed inside point-blank `Shadowraze1` (`115..325u`), our stack timer is fresh (`> 2.5s`,
    -- preserving `S43` last-second expiry sprint!), and enemy carries `0` raze stacks while we have `>= 180 HP` and `Q` ready,
    -- fire ONE instant defensive `Snap-Q` BEFORE disengaging so we never die with `297 MP` unused (`0` inward steps)!
    if H.InCriticalLethalDanger(bot, s, earlyRace) then
        if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive() and not bot:IsSilenced() then
            local dClose = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
            local mySt, myRemT = U.GetShadowrazeDebuff(bot)
            local enSt = U.GetShadowrazeDebuff(s.enemy) or 0
            local qAb = bot:GetAbilityByName("nevermore_shadowraze1")
            if dClose >= 115 and dClose <= 325
                and (mySt == 0 or (myRemT or 0) > 2.5)
                and enSt == 0
                and (bot:GetHealth() or 0) >= 180
                and (bot:GetMana() or 0) >= 75
                and qAb and qAb:GetLevel() > 0 and qAb:IsCooldownReady() then
                local eLocNow = U.PredictPosition(s.enemy, C.RAZE.CAST_POINT)
                if U.GetAngleDifference(bot, eLocNow) <= C.RAZE.MAX_ANGLE_TO_CAST then
                    H.ManageTreads(bot, "CAST")
                    bot:Action_UseAbility(qAb)
                    H.StartRazeCast(qAb, s.enemy, eLocNow, C.RAZE.HIT_RADIUS, false)
                    H.ClearMoveCache()
                    return
                else
                    H.SmartFace(bot, eLocNow)
                    State.actionTaken = true
                    return
                end
            end
        end
        if H.DisengageFromLethalTrade(bot, s, earlyRace) then return end
    end

    -- Post-Kill Rapid Wave Crash (`HUD 09:01`, `s.enemyAlive == false`):
    -- When the enemy hero is DEAD on the scoreboard, the wave is NOT under our own T1 (where `RunSacredCS`
    -- MUST run `TryUnderTowerPrep` + `0.033s` phase-locked CS!), and NO lane creep is within `1.0s` of CS, shove fast!
    local waveUnderOwnT1 = false
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and ec:IsAlive() and H.IsNearOwnT1(ec, 760) then
            waveUnderOwnT1 = true
            break
        end
    end
    if s.enemyAlive == false and not waveUnderOwnT1 and #(s.enemyCreeps or {}) > 0 then
        local eAtk = U.MergeLists(s.enemyCreeps, s.enemyTowers)
        local aAtk = U.MergeLists(s.allyCreeps, s.allyTowers)
        local lhNow, isDeny = L.GetBestTarget(bot, s.enemyCreeps, s.allyCreeps, eAtk, aAtk, false)
        local imminentCS = lhNow and U.GetTimeToKillable(bot, lhNow, isDeny and eAtk or aAtk) <= 1.85
        if not imminentCS and H.HandlePriorityPush(bot, s, earlyRace) then
            return
        end
    end

    -- Never let `RunSacredCS` steal our fatal swing onto a lane creep mid-duel (`9056469656.dem` `04:07.32` `U315` &
    -- `Demo 2` `7:40.87` `50 HP` melee creep mid-duel at `d = 355u` & `Demo 1` `3:55` `20 vs 11` soul brawl!)
    if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then return end
    -- v4.3.5: resource-deficit spacing and stacked defensive coil outrank generic
    -- hero brawl / last-hit walking, but never a proven lethal finish.
    if H.HandleStackedDefensiveRaze(bot, s, earlyRace) then return end
    if H.HandleManaDeficitSpacing(bot, s, earlyRace) then return end
    if H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, true, false) then return end

    local csRazeHook = function(ab, targetCreep, rSpot, radius, isCS)
        H.ManageTreads(bot, "CAST")
        bot:Action_UseAbility(ab)
        H.StartRazeCast(ab, targetCreep, rSpot, radius or C.RAZE.HIT_RADIUS, isCS ~= false)
        H.ClearMoveCache()
    end
    local csActed, csWaveBusy = L.RunSacredCS(bot, s, earlyRace, P, csRazeHook)
    if csActed then
        if not H.IsAtFountain(bot) and State.fountainReason ~= "POST_KILL" then
            State.goingToFountain = false
        end
        State.actionTaken = true
        return
    end

    -- v4.3.3: the human-like answer is allowed to land AFTER the sacred CS tick.
    -- If RunSacredCS owned this tick, the token stays alive and is consumed on the next free tick.
    if H.ConsumeDelayedHeroReply(bot, s, earlyRace) then return end

    -- Shielded Enemy T1 Siege Priority (`9056774541.dem` `01:45` fix):
    -- Whenever `RunSacredCS` has NO active CS/deny window right now (`not csActed`), hit enemy T1 under creep shield EVEN IF
    -- fresh full-HP enemy creeps just spawned behind T1 (`#enemyCreeps > 0`), snapping seamlessly to CS/deny on its opening tick!
    if U.CanQuery(s.enemyT1) and #(s.allyCreeps or {}) >= 1 then
        local enemyBehindT1 = not (s.enemy and U.CanQuery(s.enemy))
            or (GetUnitToLocationDistance(s.enemy, s.enemyT1:GetLocation()) < GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) + 80
                and s.enemy:GetHealth() > U.GetNRazeDamage(bot, s.enemy, 1) + 40)
        if enemyBehindT1 and H.HandleSiegeTower(bot, earlyRace, s) then
            State.actionTaken = true
            return
        end
    end

    -- Hold active hero windup BEFORE lower combat stages (`9056774541.dem` `03:29–03:33` `tk=13526..13628`:
    -- previously `ShouldHoldForHeroWindup` sat below `Stage B0` / `RunCombatPriority`, self-cancelling 4 near-launch
    -- right-clicks in a row on `ShaNachnetsya` `0.15s` before projectile launch!):
    if s.enemy and U.CanQuery(s.enemy) and H.ShouldHoldForHeroWindup(bot, s, s.enemy, earlyRace) then
        return
    end

    -- v4.3.6-tempo: clarity + XP-preserving spacing before hero-only aggression.
    if H.HandleTempoClarity(bot, s) then return end
    if not csBusy and H.HandleTempoSpacing(bot, s, earlyRace) then return end

    -- Stage B0 (`0:00` Even-Footing Mirror Counter-Raze, `< 75 MP` Dry-Enemy Coil Punish, Anti-`Raze3`-Bait Kite Ring & Stand-Ground Anti-Zoning):
    -- Gate by `L._imminentCS` (`kOpen <= 26` ticks), NOT `csWaveBusy` (`HP < 72%` which blocked `Stage B0` on 99.9% of ticks!)
    local imminentCreepCS = L._imminentCS and true or false
    if H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, false) then return end
    if H.HandleMirrorRazeCounterAndDryPunish(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, false, imminentCreepCS) then return end
    if H.HandleDryEnemyAndSoulLeadHarass(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleAntiFreeHarassRetaliation(bot, s, earlyRace) then return end
    if H.HandleFreeEnemyWardDeward(bot, s) then return end

    -- Stage B: Losing trade / dry-mana / uphill-aggro disengage — blocks ALL offensive combat pre-handlers!
    if H.InLosingHeroTrade(bot, s, earlyRace) then
        if H.DisengageFromLethalTrade(bot, s, earlyRace) then return end
    end

    -- Instant `0`-tick Mango pop FIRST, then Wave-safe Static-Tree Tango (run BEFORE empty-wave `holdSpot`!)
    if H.TryBackpackAmpMango(bot, s) then return end
    if H.TryWaveSafeStaticTango(bot, s, csWaveBusy) then return end

    -- Preserve active forced/survival retreat BEFORE empty-wave holdSpot WITH Zero-Stall Arrival check!
    if H.TickForcedRetreat(bot, s) then return end
    if State.survivalLoc and GameTime() < (State.survivalUntil or 0) then
        if U.DistanceBetweenLocations(bot:GetLocation(), State.survivalLoc) <= 65 then
            State.survivalLoc = nil
            State.survivalUntil = 0
        else
            H.SmartMove(bot, State.survivalLoc, 60)
            return
        end
    end

    -- Outside Fountain: never abandon mid lane on a 7,000-unit walk unless critically < 105 HP or committed POST_KILL!
    if not H.IsAtFountain(bot) and bot:GetHealth() >= 105 and State.fountainReason ~= "POST_KILL" then
        State.goingToFountain = false
    end

    -- Between waves (0 visible lane creeps): hold crisp mid equilibrium / T1 highground instead of walking to base —
    -- UNLESS we are actively dominating / finishing a live enemy hero right in front of us after wave clear
    -- (`9055695956.dem` `7:05` `tk=15836`: waves just died to razes at `519u` while BOT was Level 7 vs Level 5 —
    -- returning early here walked BOT `1,300u` back to `Vector(395, 405)` mid-fight instead of killing `ShaNachnetsya`!)
    local fightingEnemyInLane = s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
        and (s.enemyDist or 9999) <= 1050
        and (H.CanTwoHitRightClickKill(bot, s.enemy, s)
            or (((bot:GetLevel() or 1) > (s.enemy:GetLevel() or 1)) and (bot:GetHealth() or 0) >= 620
                and not (earlyRace and earlyRace.valid and earlyRace.heCanKillSoon))
            or (earlyRace and earlyRace.valid and (earlyRace.canKillNow
                or (earlyRace.canKillSoon and not earlyRace.heCanKillSoon and (earlyRace.edge or 0) >= 40)
                or ((s.enemyDist or 9999) <= 560 and not earlyRace.heCanKillSoon and (earlyRace.edge or 0) >= 25))))
    if not fightingEnemyInLane and not State.emergencyRetreat and not State.goingToFountain
        and #(s.enemyCreeps or {}) == 0 and #(s.allyCreeps or {}) == 0 and bot:GetHealth() >= 105 then
        H.ManageTreads(bot, nil)
        local holdSpot = P.GetLasthitPosition(bot, {}, {}, nil, "NEUTRAL")
        if holdSpot and U.DistanceBetweenLocations(bot:GetLocation(), holdSpot) > 55 then
            H.SmartMove(bot, holdSpot, 45)
        end
        State.actionTaken = true
        return
    end

    if H.HandleSurvivalRetreat(bot, s.enemy, earlyRace) then return end

    if H.HandleShortCombatCast(bot,s.enemy,s) then return end
    if H.HandleSafeRazeReply(bot,s.enemy,s) then return end
    if H.HandleReplyFarFollowup(bot,s.enemy,s) then return end
    if H.HandleManaCycleContinuation(bot,s.enemy,s) then return end
    if H.HandleContactTrade(bot,s.enemy,s) then return end
    -- Free pressure: both handlers veto themselves in every risky or busy situation
    -- (retreat, fountain, low HP, tower, lethal burst, imminent last hit, aimed raze).
    if H.HandleFreeRazeAnswer(bot,s,earlyRace,true) then return end
    if H.HandleFreeRightClick(bot,s,earlyRace) then return end

    -- A committed retreat owns the tick WITH Zero-Stall Arrival check!
    if H.TickForcedRetreat(bot, s) then return end

    if bot:GetHealth() < 105 and H.HandleSurvivalRetreat(bot, s.enemy, earlyRace) then return end
    if H.HandleSeekAlliedWave(bot, s, earlyRace) then return end
    if (not csWaveBusy or s.enemyAlive == false) and H.HandlePriorityPush(bot, s, earlyRace) then return end
    if H.UpdateTowerChase(bot, s) then return end
    local stackChaseSafe = not (earlyRace and earlyRace.valid
        and (earlyRace.losingHard or earlyRace.heHasBootsLead or ((s.enemy and s.enemy:GetLevel() or 1) > (bot:GetLevel() or 1))))
        and (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.55
    if stackChaseSafe and H.HandleStackLead(bot, s, earlyRace) then return end
    H.UpdateDefensive(bot, s, earlyRace)
    State.enemyAggroCount = 0
    for _, creep in pairs(s.allyCreeps or {}) do
        if s.enemy and U.CanQuery(creep) and creep:GetAttackTarget() == s.enemy then
            State.enemyAggroCount = State.enemyAggroCount + 1
        end
    end
    State.combatPolicyActive = true
    State.heroCombatAllowed = State.towerChaseBlockedEnemy ~= s.enemy
        and (H.ShouldEngageHero(bot, s.enemy, earlyRace)
            or H.IsEnemyPressuring(bot, s.enemy)
            or (earlyRace.valid and earlyRace.canKillNow))
    if H.HandleIncomingHeroPressure(bot, s, earlyRace) then return end
    if State.heroCombatAllowed and not State.goingToFountain
        and GameTime() >= (State.fleeUntil or 0) then
        local previous = State.intent
        State.intent = I.TRADE
        local acted = H.RunCombatPriority(bot, s, earlyRace)
        State.intent = previous
        if acted then return end
    end

    if H.HandleActiveRazeValidation(bot) then return end

    -- A guaranteed finish comes before dodging and everything else: if we can kill
    -- him with a raze/click right now - kill immediately, do not postpone it for seconds
    if s.enemy then
        if H.HandleGuaranteedRazeKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
        if H.HandleGuaranteedAttackKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
    end

    -- Dodging the enemy raze outranks even our own cast (if the raze is lethal)
    if H.HandleEnemyRazeDodge(bot, s.enemy) then return end

    if bot:IsUsingAbility() then return end

    H.ProcessTelemetry(bot)

    -- Power Treads are handled by H.ManageTreads - on an idle tick (end of RealThink),
    -- on the first retreat tick (strength) and on the tick before a raze cast (intelligence). The old call
    -- here issued a switch order EVERY tick and overrode the combat orders.

    local enemyHero = s.enemy

    -- The race (absolute HP, razes available to both sides) and the intent for the tick
    local race = earlyRace
    local intent = H.UpdateIntent(bot, s, race)

    -- A swing at the hero is in progress - let it land (see ShouldHoldForHeroWindup)
    if enemyHero and H.ShouldHoldForHeroWindup(bot, s, enemyHero, race) then
        State.actionTaken = true
        return
    end

    -- Emergency consumables (faerie/wand/mango for a finish) - right after the swing,
    -- before salves and retreats
    if H.HandleEmergencyConsumables(bot, race) then return end

    if H.HandleActiveSalveSafety(bot, enemyHero) then return end
    if H.HandleEnemyNearRazeCounter(bot, enemyHero) then return end
    if enemyHero and H.HandleInstantMirrorRaze(bot, enemyHero, race, s) then return end

    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
    end
    if enemyHero and U.CanQuery(enemyHero) and U.EnemyHasRaze(enemyHero) then
        if bot:GetLevel() < 2 and enemyHero:GetLevel() >= 2 then
            State.enemyReachedLevel2First = true
        end
    end

    -- (Guaranteed finishes moved up - before dodging and the swing)
    if H.HandleReturnTP(bot) then return end

    -- Defence against the enemy T1 - before everything else
    if H.HandleEnemyTowerSafety(bot, s, enemyHero) then return end

    -- The enemy T1 is nearly down - finish it before any retreat or last hit
    if H.HandleEnemyTowerFinish(bot, s, enemyHero) then return end

    if H.HandleEmergencyRetreat(bot, enemyHero) then return end

    -- RETREAT intent: get out of the enemy's ready bands (his available burst is lethal)
    if intent == I.RETREAT and enemyHero then
        if H.ExecuteRetreat(bot, enemyHero, race) then return end
    end

    if H.HandleForcedSalve(bot) then return end
    if H.HandleFountainRecall(bot) then return end

    -- The intent is still RETREAT but we are already at a safe distance (ExecuteRetreat
    -- returned false). Previously control fell through to last hits/prehit - those turned
    -- the bot toward the creep pack, the enemy caught up, run again - a crooked zigzag instead of leaving.
    -- Keep a clean step straight away from the enemy while he is near.
    if intent == I.RETREAT and enemyHero and U.CanQuery(enemyHero) and not State.actionTaken then
        local bLoc, eLoc = bot:GetLocation(), enemyHero:GetLocation()
        local d = U.DistanceBetweenLocations(bLoc, eLoc)
        if d < 1100 and d >= 1 then
            H.SmartMove(bot, bLoc + (bLoc - eLoc):Normalized() * 160, 60)
            return
        end
    end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local mpPct = bot:GetMana() / bot:GetMaxMana()
    local flask = U.GetActiveItemByName(bot, "item_flask")
    local clarity = U.GetActiveItemByName(bot, "item_clarity")
    local hasMango = U.HasItem(bot, "item_enchanted_mango")
    local isHealing = bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_clarity_potion")
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50

    if bot:HasModifier("modifier_clarity_potion") and not bot:HasModifier("modifier_flask_healing") and myHpPct >= returnHpPct then
        isHealing = false
        H.ClearForcedRetreat()
    end

    -- CRITICAL `Demo 1` `2:46.30` FIX: NEVER allow this legacy fallback block to bypass
    -- `H.HandleProactiveAndActiveSalve`'s FoW memory (`enemyAbsentFor < 4.5s`), creep clearance
    -- (`520u`), and T1 hull bypass (`BehindT1` + `SteerAroundObstacles`)! `needsFlask` is handled
    -- exclusively in `H.HandleProactiveAndActiveSalve`.
    local needsFlask = false
    local needsClarity = (mpPct < 0.4 and clarity and not isHealing and not hasMango)

    if isHealing or needsFlask or needsClarity then
        local fountain = P.GetFountain(bot)
        local dangerRange = 850
        if enemyHero and enemyHero:GetUnitName() == "npc_dota_hero_nevermore" then
            if bot:HasModifier("modifier_flask_healing") or needsFlask then
                dangerRange = C.REGEN.FLASK_SAFE_DISTANCE or 1150
            else
                dangerRange = C.REGEN.ENEMY_SAFE_DISTANCE or 1100
            end
        end
        if H.IsInDangerForRegen(bot, dangerRange) then
            local moveLoc = P.GetT1Close(bot)
            if enemyHero then
                local dir = (fountain - enemyHero:GetLocation()):Normalized()
                moveLoc = enemyHero:GetLocation() + dir * dangerRange
            end
            H.BeginForcedRetreat(bot, moveLoc, 0.85)
            return
        end
        if needsFlask and GameTime() > State.lastItemUseTime + 0.3 then
            if H.HasEnemyProjectileIncoming(bot) then
                local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
                H.BeginForcedRetreat(bot, safeLoc, 0.65)
                return
            end
            bot:Action_UseAbilityOnEntity(flask, bot)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return
        elseif needsClarity and GameTime() > State.lastItemUseTime + 0.3 then
            bot:Action_UseAbilityOnEntity(clarity, bot)
            State.lastItemUseTime = GameTime()
            return
        elseif isHealing then
            -- Lists from the world snapshot (filtered through CanQuery - no creeps in fog)
            local enemyCreepsNearby = s.enemyCreeps or {}
            local allyCreepsNearby = s.allyCreeps or {}
            if #allyCreepsNearby == 0 then
                local targetPos = P.GetT1Close(bot)
                if GetUnitToLocationDistance(bot, targetPos) > 45 then
                    H.SmartMove(bot, targetPos, 60)
                end
            elseif bot:HasModifier("modifier_flask_healing") then
                local safeLoc = P.GetLasthitPosition(bot, enemyCreepsNearby, allyCreepsNearby, nil, "PASSIVE")
                if enemyHero and U.CanQuery(enemyHero) then
                    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
                    if distToEnemy < dangerRange then
                        local dir = (fountain - enemyHero:GetLocation()):Normalized()
                        safeLoc = enemyHero:GetLocation() + dir * dangerRange
                    end
                end
                if not H.IsInDangerForRegen(bot, dangerRange) then
                    H.SmartMove(bot, safeLoc, 60)
                end
            end
            if State.actionTaken or #allyCreepsNearby == 0 or bot:HasModifier("modifier_flask_healing") then return end
        end
    end

    local enemyCreeps = s.enemyCreeps
    local allyCreeps = s.allyCreeps
    local enemyTowers = s.enemyTowers
    local allyTowers = s.allyTowers
    local enemyAttackers = U.MergeLists(enemyCreeps, enemyTowers)
    local allyAttackers = U.MergeLists(allyCreeps, allyTowers)
    -- The enemy hero also hits creeps (finishes his own = deny, finishes mine). His attack
    -- is accounted for in the target HP forecast (GetAttackTarget() == target): the "safe" last-hit window
    -- closes with his attack -> hit earlier/immediately instead of waiting for a moment he takes.
    if enemyHero and U.CanQuery(enemyHero) then
        table.insert(enemyAttackers, enemyHero)
        table.insert(allyAttackers, enemyHero)
    end
    local enemyNearWave = enemyHero ~= nil and s.enemyDist <= 1300

    U.UpdateAllyCreepHealthTracking(allyCreeps)


    local current_mode = U.GetPlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    if State.defensive then current_mode = "PASSIVE" end
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local enemyMissedAggro = enemyMissed and bot:GetLevel() > 1
    if bot:GetLevel() <= 1 and enemyMissed and current_mode == "AGGRESSIVE" then
        current_mode = "NEUTRAL"
    end

    if H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then return end
    if H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps) then return end

    local inKillThreat = U.IsInEnemyRazeKillThreat(bot, enemyHero)
    local secondStackActive, secondStackLabel = false, nil
    if enemyHero then
        secondStackActive, secondStackLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    end

    if enemyHero and secondStackActive and secondStackLabel == "near" then
        if H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if inKillThreat then
        if H.HandleSafeDistanceFromEnemy(bot, enemyHero) then return end
    end

    U._midFear = (enemyHero ~= nil) and H.MidRazeFearActive(bot, enemyHero) or false
    if enemyHero and H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero) then return end
    if enemyHero and H.HandleDryManaMidRazeAvoidance(bot, enemyHero) then return end

    -- Stacks on us: the decision is based on the enemy's available burst and absolute HP (not "2 stacks = run").
    -- If his razes are on cooldown / out of mana / the band is out of reach - keep pressing.
    if enemyHero then
        local shouldFear, fearLoc = U.ShouldRetreatFromEnemyRazeStack(bot, enemyHero)
        if shouldFear and fearLoc then
            H.BeginForcedRetreat(bot, fearLoc, 0.80)
            return
        end
    end

    if enemyHero and H.HandleBootDisadvantageMidRazeFear(bot, enemyHero) then return end

    local mustRetreatFromT1Soon = U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not mustRetreatFromT1Soon and s.enemyT1 then
        -- The shield is gone (creeps ran off after the enemy / died) and we are still inside the tower radius
        local okLoc, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, bot:GetLocation()) <= ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) then
            if LN.TowerDanger(bot, s.enemyT1, allyCreeps, nil) >= 2 then
                mustRetreatFromT1Soon = true
            end
        end
    end
    if mustRetreatFromT1Soon and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
        and not (s.enemyT1 and LN.IsTowerFinishable(bot, s.enemyT1)) then
        -- Do NOT spend the glyph just to get out of the tower (an accidental entry into the T1 radius without a finish
        -- burned the glyph for 5 minutes) - just walk out
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    if enemyHero and not inKillThreat then
        if H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and H.GetPotentialCombatMana(bot) >= 150 and not inKillThreat then
        local q = bot:GetAbilityByName("nevermore_shadowraze1")
        if q and q:GetLevel() > 0 then
            local dmg2 = U.GetTwoRazeDamage(bot, enemyHero)
            local lethal = dmg2 >= enemyHero:GetHealth()
            local Rr = K._race
            if Rr and Rr.valid then
                -- Only razes that are REALLY available (cooldowns/mana), not "two razes by formula"
                lethal = Rr.canKillSoon
            end
            if intent == I.RETREAT then lethal = false end
            if lethal then
                local myBoots = U.HasItem(bot, "item_boots") or U.HasItem(bot, "item_power_treads")
                local eBoots = U.HasItem(enemyHero, "item_boots") or U.HasItem(enemyHero, "item_power_treads")
                local canChase = myBoots and not eBoots
                local chaseTargetLoc = enemyHero:GetLocation()
                local isSafeChase = true
                for _, tower in pairs(enemyTowers) do
                    if tower:IsAlive() then
                        local name = tower:GetUnitName() or ""
                        if name:find("tower2") or name:find("tower3") or name:find("tower4") then
                            if GetUnitToLocationDistance(tower, chaseTargetLoc) < 850 then
                                isSafeChase = false
                                break
                            end
                        end
                    end
                end
                local glyphActive = State.glyphUsedForDive and (GameTime() - State.glyphDiveTime) < 5.0
                local normalSafe = (H.GetSafeApproachLoose(bot, chaseTargetLoc, enemyTowers, allyCreeps) == chaseTargetLoc)
                -- His T1 is busy with our creep (>= 2 shots), HP >= 50%, his burst is not lethal:
                -- razes under the tower give no aggro - the finish is allowed
                local towerLockedSafe = isSafeChase and H.TowerLockedOnCreep(s.enemyT1)
                    and myHpPct >= 0.5 and not (Rr and Rr.valid and Rr.heCanKillSoon)
                    and not H.TowerBurnActive()
                if (canChase and isSafeChase) or normalSafe or glyphActive or towerLockedSafe then
                    if H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, true, false) then
                        return
                    end
                end
            end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreeps, enemyCreeps) then return end
    end

    if enemyHero and not inKillThreat and secondStackActive then
        if secondStackLabel == "mid" then
            if H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        elseif secondStackLabel == "near" then
            if H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    local ward = U.GetActiveItemByName(bot, "item_ward_observer")
    if ward and not H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then
        local wardLoc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
        local distToWard = GetUnitToLocationDistance(bot, wardLoc)
        if distToWard > 450 then
            H.SmartMove(bot, wardLoc, 60)
        else
            bot:Action_UseAbilityOnLocation(ward, wardLoc)
            H.ClearMoveCache()
        end
        return
    end

    local aggroCount = 0
    local closeCreepsCount = 0
    local hasRangedAggro = false
    local is_taking_damage = bot:WasRecentlyDamagedByCreep(1.5)
    -- How many of MY creeps are hitting the enemy hero (support in the trade)
    local enemyAggroCount = 0
    if enemyHero and U.CanQuery(enemyHero) then
        for _, c in pairs(allyCreeps) do
            if U.CanQuery(c) and c:GetAttackTarget() == enemyHero then enemyAggroCount = enemyAggroCount + 1 end
        end
    end
    State.enemyAggroCount = enemyAggroCount
    for _, c in pairs(enemyCreeps) do
        if c:IsAlive() then
            if U.CanQuery(c) and c:GetAttackTarget() == bot then
                aggroCount = aggroCount + 1
                local name = c:GetUnitName() or ""
                if name:find("ranged") or name:find("siege") then hasRangedAggro = true end
            end
            if GetUnitToLocationDistance(bot, c:GetLocation()) < 350 then
                closeCreepsCount = closeCreepsCount + 1
            end
        end
    end

    if U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero) then
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    local is_under_my_tower = false
    for _, t in pairs(allyTowers) do
        if GetUnitToLocationDistance(bot, t:GetLocation()) < 850 then
            is_under_my_tower = true
            break
        end
    end

    -- Shared 3s creep aggro-drop. Never cancel an unreleased hero windup or the protected last-hit target.
    -- Do not queue a same-tick retreat after the allied attack order; let the next tick re-evaluate.
    if U.TryDeaggro(bot, { enemyCreeps = enemyCreeps, allyCreeps = allyCreeps }, State.lhAttackTarget, 999) then
        H.ClearMoveCache()
        State.deaggroTime = GameTime() + ((C.AGGRO and C.AGGRO.DEAGGRO_COOLDOWN) or 3.05)
        return
    end

    if GameTime() < State.aggroPullTime then
        if H.IsHeroAttackWindupLocked(bot) then return end
        if H.IsInHeroAttackAnimation(bot) then return end
        H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
        return
    end

    local bestTarget, isDeny = L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    -- Do not take a last hit that requires entering his ready band in a bad trade:
    -- otherwise it is an endless "approach for the creep - get scared - back off", and every approach is his raze on us.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) then
        local fearMin = U.GetFearMinDist(bot, enemyHero)
        if fearMin > 0 then
            local eLoc = enemyHero:GetLocation()
            local cLoc = bestTarget:GetLocation()
            local botD = U.DistanceBetweenLocations(bot:GetLocation(), eLoc)
            local inRangeNow = GetUnitToLocationDistance(bot, cLoc) <= bot:GetAttackRange() + 20
            local creepD = U.DistanceBetweenLocations(cLoc, eLoc)
            if not (inRangeNow and botD >= fearMin - 40) and creepD < fearMin - bot:GetAttackRange() + 40 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Do not walk for a creep into a point where his available burst (ready bands + right clicks)
    -- kills me: otherwise "approached for the creep -> became lethal -> RETREAT for 1 s -> came back"
    -- in a loop every 2-3 s (twitching). Take only what is reachable from a non-lethal distance.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) and race.valid and not race.canKillNow then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        local atkD = U.DistanceBetweenLocations(atkPos, eLoc)
        local curD = U.DistanceBetweenLocations(bLoc, eLoc)
        if atkD < curD - 30 then
            local burst = K.EnemyBurstVs(bot, enemyHero, atkD, 2.5, false)
            if burst >= bot:GetHealth() - 20 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Defence (clearly weaker, no creep/tower support): do not enter his attack
    -- radius for a last hit - every entry is 1-2 of his hits (70+ per hit with 20 souls and bracers), a creep
    -- is not worth that. Take only what is reachable from outside his radius, or while he is busy with the wave.
    local myHpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if bestTarget and enemyHero and State.defensive and race.valid and race.weakerSustained
        and U.CanQuery(enemyHero) and not H.HasTradeSupport(race) then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local hisReach = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.CONTEST_PAD) or 80)
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        -- Skip a creep only if it is really pressuring us (hitting us / hit us in the last
        -- 3 s) or we are low with his raze ready. Merely "standing by the wave" is no reason to give up
        -- all the farm: previously a weaker bot with that rule took not a single creep.
        local pressing = false
        if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then pressing = true end
        if not pressing and bot.WasRecentlyDamagedByHero then
            pressing = bot:WasRecentlyDamagedByHero(enemyHero, 3.0) and true or false
        end
        if not pressing and myHpPctNow <= 0.45 and (race.enRazesSoon or 0) >= 1 then
            pressing = true
        end
        if pressing and U.DistanceBetweenLocations(atkPos, eLoc) <= hisReach and not LN.EnemyBusyWithWave(bot, enemyHero) then
            bestTarget, isDeny = nil, false
        end
    end
    local bestTargetTime = 999
    if bestTarget then
        bestTargetTime = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
    end
    local lasthitImminent = bestTarget ~= nil and bestTargetTime >= 0 and bestTargetTime <= 1.2

    local am_i_tanking_too_much = false
    if not allyCreeps or #allyCreeps == 0 then
        if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) then am_i_tanking_too_much = true end
    else
        if aggroCount >= 3 or (aggroCount >= 2 and bot:GetHealth() < 400) then am_i_tanking_too_much = true end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then
        if aggroCount <= 1 then am_i_tanking_too_much = false end
    end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            local fountain = P.GetFountain(bot)
            local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 250
            H.SmartMove(bot, safe_pos, 60)
            return
        end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then am_i_tanking_too_much = false end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
            return
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        if H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and U.IsEnemyHighValueRegen(enemyHero) then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if bot:GetMana() >= 75 and distToEnemy <= 1100 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
        local attackRange = bot:GetAttackRange() + 60
        if distToEnemy <= attackRange then
            if myHpPct > 0.30 and H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
                H.IssueHeroAttack(bot, enemyHero)
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return
            end
        elseif distToEnemy <= C.HARASS.INTERRUPT_APPROACH and myHpPct > 0.40 and H.GetPotentialCombatMana(bot) >= 75 then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local approachLoc = botLoc + dir * math.min(distToEnemy - attackRange + 50, 400)
            approachLoc = U.ClampMinDistFromEnemy(bot, enemyHero, approachLoc)
            if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 60, enemyTowers, allyCreeps) then
                return
            end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        local eStacks, eRem = U.GetShadowrazeDebuff(enemyHero)
        -- Extending 2 stacks is a combo continuation: allowed with a favourable trade or by the mana reserve
        local extendOk = (race.valid and race.edge >= 0 and bot:GetMana() >= 75) or H.HarassManaOK(bot, race)
        if eStacks >= 2 and eRem <= C.RAZE.EXTEND_AT + 0.6 and extendOk and not State.defensive then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and enemyMissedAggro
        and H.HarassManaOK(bot, race) and not State.defensive then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if distToEnemy <= 950 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    -- ZONE: keep the enemy away from our wave (if no last hit is available right now)
    if intent == I.ZONE and enemyHero and not lasthitImminent and not am_i_tanking_too_much and not inKillThreat then
        if H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers) then return end
    end

    if H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero) then return end

    -- prepTarget (the creep for a "pre-hit") was NEVER reset (except by ForceExtend):
    -- after the first pre-hit, harass, push and the pre-hit itself were disabled forever while the dead handle
    -- was queried every tick. Reset when: the target is dead/invisible, the hit landed, or > 2.5 s passed.
    if State.prepTarget then
        local pt = State.prepTarget
        local age = GameTime() - (State.prepTargetTime or 0)
        if not U.CanQuery(pt) or age > 2.5
            or (not U.IsAttackingAction(bot) and age > 0.6) then
            State.prepTarget = nil
            State.prepTargetTime = 0
        end
    end

    -- The enemy projectile is already flying at the creep, his hit is not enough to finish it, and after
    -- it lands the creep becomes mine - send our attack RIGHT AFTER his projectile.
    if H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps) then return end

    local is_free_to_prehit = true
    if bestTarget then
        local t_killable = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
        if t_killable < (bot:GetSecondsPerAttack() + 0.3) then is_free_to_prehit = false end
    end

    local prehit_target = nil
    if is_free_to_prehit and not State.prepTarget and not am_i_tanking_too_much then
        local attack_cd = bot:GetSecondsPerAttack()
        for _, c in pairs(enemyCreeps) do
            if U.CanQuery(c) then
                local in_tower_range = false
                for _, t in pairs(allyTowers) do
                    if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                        in_tower_range = true
                        break
                    end
                end
                -- "HP shaping": the pre-hit is allowed outside our own tower too if the enemy cannot
                -- punish it (far from the creep / busy with the wave / no ready razes) and we are not under his T1.
                local prehit_ok = in_tower_range
                if not prehit_ok and (C.LASTHIT.PREHIT_ANYWHERE ~= false) and not inKillThreat and not State.defensive then
                    local eFar = true
                    if enemyHero and U.CanQuery(enemyHero) then
                        local dce = U.DistanceBetweenLocations(c:GetLocation(), enemyHero:GetLocation())
                        local R = K._race
                        eFar = dce > 850 or LN.EnemyBusyWithWave(bot, enemyHero) or (R and R.valid and R.enRazesSoon == 0)
                    end
                    local underEnemyTower = false
                    for _, t in pairs(enemyTowers) do
                        if t:IsAlive() and GetUnitToLocationDistance(t, c:GetLocation()) < 800 then underEnemyTower = true break end
                    end
                    prehit_ok = eFar and not underEnemyTower
                end
                if prehit_ok then
                    local myDmg = U.SFDamageRange(bot, c).min
                    local hp = c:GetHealth()
                    if hp > (myDmg * 1.5) then
                        local ctx_normal = U.GetTargetPredictionContext(c, allyAttackers)
                        if not U.HasLasthitWindow(ctx_normal, c, myDmg, 0) then
                            local ctx_prehit = U.WithHypotheticalDamage(ctx_normal, myDmg)
                            if U.HasLasthitWindow(ctx_prehit, c, myDmg, attack_cd) then
                                prehit_target = c
                                break
                            end
                        end
                    end
                end
            end
        end

        if not prehit_target then
            for _, c in pairs(allyCreeps) do
                if c:IsAlive() and (c:GetHealth() / c:GetMaxHealth()) < 0.5 then
                    local in_enemy_tower_range = false
                    for _, t in pairs(enemyTowers) do
                        if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                            in_enemy_tower_range = true
                            break
                        end
                    end
                    if in_enemy_tower_range then
                        local eSF = enemyHero
                        local eDmg = eSF and U.CanQuery(eSF) and eSF:GetAttackDamage() or U.SFDamageRange(bot, c).min
                        local myDmg = U.SFDamageRange(bot, c).min
                        local hp = c:GetHealth()
                        if hp > myDmg then
                            local ctx_normal = U.GetTargetPredictionContext(c, enemyAttackers)
                            if U.HasLasthitWindow(ctx_normal, c, eDmg, 0) then
                                local ctx_prehit = U.WithHypotheticalDamage(ctx_normal, myDmg)
                                if not U.HasLasthitWindow(ctx_prehit, c, eDmg, 0) then
                                    prehit_target = c
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if prehit_target then
            local tower_proj_flying = false
            local projs = prehit_target:GetIncomingTrackingProjectiles()
            if projs then
                for _, p in pairs(projs) do
                    if p.is_attack and p.caster and p.caster:IsTower() then
                        tower_proj_flying = true
                        break
                    end
                end
            end
            if not tower_proj_flying then
                State.prepTarget = prehit_target
                State.prepTargetTime = GameTime()
                if H.IsSafeToAttack(bot, prehit_target:GetLocation(), enemyTowers, allyCreeps) then
                    if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= prehit_target then
                        -- ONE attack (previously a continuous attack: the second hit cut the creep into the zone
                        -- where our own creeps finished it)
                        bot:Action_AttackUnit(prehit_target, true)
                        H.ClearMoveCache()
                    end
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, bot:GetLocation(), enemyTowers, allyCreeps), 60)
                end
                return
            end
        end
    end

    -- Finishing a stack on the enemy does not wait for the 1.9 s "free window" before a last hit: the cast is 0.55 s,
    -- we only yield to a last hit that must be taken within the next 0.7 s.
    -- A stack-finishing raze outranks a last hit when the last hit is not "right now" (<= 0.45 s):
    -- a raze on a stacked hero (~120-160 damage + stack extension) is worth more than one creep
    local followUpNow = enemyHero and H.IsRazeFollowUp(bot, enemyHero) and (bestTargetTime < 0 or bestTargetTime > 0.45)
    -- Hunting (State.hunting) outranks the last hit and is not blocked by a stack on us (his burst on us
    -- was already checked in ComputeHunt with the stack taken into account)
    local hunting = (State.hunting and enemyHero ~= nil) or false
    -- The enemy walked up close and we have mana for two razes - the trade beats waiting for the
    -- last hit (previously is_free_to_prehit = false here and the bot silently stood by the creep)
    local punishWindow = enemyHero ~= nil
        and (s.enemyDist <= ((C.RAZE and C.RAZE.PUNISH_CLOSE_RANGE) or 520))
        and H.GetPotentialCombatMana(bot) >= ((C.RAZE and C.RAZE.PUNISH_MIN_POT_MANA) or 150)
    local allowHarass = (is_free_to_prehit or enemyMissedAggro or followUpNow or hunting or punishWindow) and not State.prepTarget and not inKillThreat and (not secondStackActive or hunting or punishWindow)
    -- "Stack finish only" window (a last hit in 0.45-1.9 s): only razes are allowed (0.55 s cast),
    -- while a right click on the hero (0.5 s swing + 1.6 s cooldown) would cost the last hit.
    local razeOnlyWindow = followUpNow and not (is_free_to_prehit or enemyMissedAggro or hunting)
    -- No aggression under RETREAT; under FARM - no closing on the enemy (only if he came to us)
    if intent == I.RETREAT then allowHarass = false end
    local allowApproach = (intent == I.TRADE or intent == I.ALLIN)
    
    if H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps) then return end

    if allowHarass and enemyHero then
        local canRazePressure, razeMode = H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
        if canRazePressure then
            if H.TryRazeEnemy(bot, enemyHero, razeMode, enemyTowers, allyCreeps, false, false) then return end
        end
        if razeOnlyWindow then
            -- The stack finish did not work (no coverage/mana) - go back to the last hit
        elseif H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps) then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return
        end

        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local approachThreshold = H.GetEnemyApproachDistance(enemyMissedAggro)
        local minHpPct = enemyMissedAggro and C.HARASS.MIN_HP_PCT_MISS or C.HARASS.MIN_HP_PCT
        local effectiveMode = enemyMissedAggro and "AGGRESSIVE" or current_mode
        if hunting then
            approachThreshold = (C.INTENT and C.INTENT.HUNT_MAX_DIST or 1100) + 150
            minHpPct = (C.INTENT and C.INTENT.HUNT_MIN_HP_PCT) or 0.40
            effectiveMode = "AGGRESSIVE"
        end
        if allowApproach and not razeOnlyWindow
            and (effectiveMode == "AGGRESSIVE" or (effectiveMode == "NEUTRAL" and enemyMissedAggro))
            and aggroCount <= 1
            and myHpPct >= minHpPct
            and dist > bot:GetAttackRange() + 50
            and dist < approachThreshold then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local stepIn = math.min(dist - bot:GetAttackRange() + 30, 350)
            local rawApproach = botLoc + dir * stepIn
            local futureDist = U.DistanceBetweenLocations(rawApproach, enemyHero:GetLocation())
            if U.ShouldFearBootsMidRaze(bot, enemyHero) and math.abs(futureDist - C.RAZE.MID_CENTER) <= 220 then
                return
            end
            local rawApproachClamped = U.ClampMinDistFromEnemy(bot, enemyHero, rawApproach)
            -- If "fear" pushed the point beyond the current position it is no longer an approach
            -- but a retreat: do not walk (otherwise the bot backed off endlessly from an advancing enemy)
            if U.DistanceBetweenLocations(rawApproachClamped, enemyHero:GetLocation()) >= dist - 20 then
                return
            end
            if H.ApproachEnemyPoint(bot, enemyHero, rawApproachClamped, 60, enemyTowers, allyCreeps) then
                return
            end
        end
    end

    local isAttacking = U.IsAttackingAction(bot)
    local target = bot:GetAttackTarget()
    -- The target went into fog/died: it must not be queried (otherwise "[Developer] ... cannot be seen" every tick)
    if isAttacking and target and not U.CanQuery(target) then
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
        isAttacking = false
        target = nil
    end
    local lhFallThrough = false
    if isAttacking and target and State.lhAttackTarget==target and not (target.IsHero and target:IsHero()) then
        local last=bot:GetLastAttackTime() or -100
        local released=false
        if State.attackTarget==target and State.attackStartTime>0
            and last>State.attackStartTime+0.01 and last<=GameTime() then
            for _,projectile in pairs(target:GetIncomingTrackingProjectiles() or {}) do
                if projectile.is_attack and projectile.caster==bot then released=true;break end
            end
        end
        local waitingForCooldown=bestTarget and bestTarget~=target and last>0
            and last<State.attackStartTime
            and last+bot:GetSecondsPerAttack()-GameTime()>(bot:GetAttackPoint() or 0.5)+0.08
        if released or waitingForCooldown then
            State.lhAttackTarget=nil;State.prepTarget=nil;State.attackTarget=nil
            State.attackStartTime=0;State.firedThisAttack=false
            lhFallThrough=true
        end
    end
    if isAttacking and target and not lhFallThrough then
        if State.attackTarget ~= target then
            State.attackTarget = target
            State.attackStartTime = GameTime()
            State.firedThisAttack = false
        end
        if State.prepTarget == target then return end
        local targetIsHero = target.IsHero and target:IsHero()
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        if targetIsHero then return end
        -- The attack is not a "last hit" (push/clearing the wave): the cancel logic does not apply to it - previously
        -- it cancelled EVERY such attack 0.08 s before the attack point (the creep was "too alive") and the bot
        -- twitched endlessly without dealing damage. If a real last hit ripens meanwhile - yield to it.
        if State.lhAttackTarget ~= target then
            if target == bestTarget then
                -- A continuous (push) attack on a creep that became a last-hit candidate:
                -- if it is killable right now - let the attack land; otherwise stop attacking,
                -- the last-hit logic below takes over the timing
                if bestTargetTime <= 0.05 then return end
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
                isAttacking = false
                target = nil
                lhFallThrough = true
            elseif bestTarget and bestTargetTime >= 0 and bestTargetTime <= (bot:GetSecondsPerAttack() + 0.4) then
                lhFallThrough = true
            else
                return
            end
        end
    end
    if isAttacking and target and not lhFallThrough then
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        local dist = GetUnitToLocationDistance(bot, target:GetLocation())
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local impact_time = remaining_windup + (dist / projSpeed)
        local isAlly = (target:GetTeam() == bot:GetTeam())
        local attackers = isAlly and enemyAttackers or allyAttackers
        local ctx = U.GetTargetPredictionContext(target, attackers)
        local predHP = U.PredictHPWithContext(ctx, target, impact_time, "avg")
        local atkCount = 0
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then atkCount = atkCount + 1 end
        end
        local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
        local kill_threshold = dmg - safety_margin
        local dmgRange = U.SFDamageRange(bot, target)
        local commit_threshold = math.max(kill_threshold, dmgRange.avg)
        local commit_buffer = C.LASTHIT.COMMIT_HP_BUFFER or 8
        local cancel_window = C.LASTHIT.CANCEL_WINDOW or math.max(0.03, math.min(0.08, ap * 0.20))
        local shouldCancel = H.ShouldCancelCommittedLastHit(predHP, commit_threshold, commit_buffer, remaining_windup, cancel_window)
        if shouldCancel then
            if remaining_windup > 0.01 and remaining_windup <= cancel_window then
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
            end
            return
        else
            if remaining_windup <= 0.05 and not State.firedThisAttack then
                State.firedThisAttack = true
            end
            return
        end
    else
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
    end

    -- The enemy walked up close - punish him without waiting for a last-hit window
    if enemyHero and not am_i_tanking_too_much and not State.prepTarget then
        if H.HandleCloseEnemyPunish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if bestTarget then
        local targetLoc = bestTarget:GetLocation()
        local botLoc = bot:GetLocation()
        local dist = GetUnitToLocationDistance(bot, targetLoc)
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local ap = bot:GetAttackPoint()
        local ms = bot:GetCurrentMovementSpeed() or 305
        local earliest_t_attack,current_t_attack=U.GetAttackImpactWindow(bot,bestTarget)
        local DESIRED_ATK_RANGE = 450
        local time_to_walk = math.max(0, dist - DESIRED_ATK_RANGE) / ms
        local ranged_t_attack = ap + (DESIRED_ATK_RANGE / projSpeed) + C.LASTHIT.NET_LATENCY
        local attackers = isDeny and enemyAttackers or allyAttackers
        local t_killable, t_window_end = U.GetTimeToKillable(bot, bestTarget, attackers)
        -- My hit must land AFTER the creep becomes killable (with the IMPACT_LEAD margin
        -- for jitter), and BEFORE our own creeps finish it. Previously a hit was allowed
        -- 0.05 s BEFORE the threshold -> systematic "hit too early, the creep survived".
        if t_killable < 0 then
            -- No window: our own creeps kill it first. If it is nearly killable - hit now (a chance).
            local hpNow = bestTarget:GetHealth()
            local dr = U.SFDamageRange(bot, bestTarget)
            if hpNow <= dr.avg + 4 and not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    State.attackTarget = bestTarget
                    State.attackStartTime = GameTime()
                    State.firedThisAttack = false
                    H.ClearMoveCache()
                    return
                end
            end
            t_killable = 999
        end
        if (time_to_walk + ranged_t_attack + 0.1) < t_killable then
            if dist > DESIRED_ATK_RANGE then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * DESIRED_ATK_RANGE, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            else
                if isAttacking then
                    bot:Action_ClearActions(true)
                    H.ClearMoveCache()
                end
            end
            return
        elseif U.LastHitImpactFits(earliest_t_attack, current_t_attack, t_killable, t_window_end) then
            if not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    State.attackTarget = bestTarget
                    State.attackStartTime = GameTime()
                    State.firedThisAttack = false
                    H.ClearMoveCache()
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, botLoc, enemyTowers, allyCreeps), 60)
                end
            end
            return
        else
            if dist > 500 then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * 480, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            end
            return
        end
    end

    -- AGGRO PULL (chapter 18): drag his wave back to my side with an attack order + a step back
    if WV.PULL ~= "off" and not State.actionTaken then
        if WV.PullTick(bot, s, enemyHero, GameTime()) then return end
    end

    -- WAVE SHOVE (chapter 18): raze the creep wave to crash it now - the stock bot never razes
    -- creeps.  Fires after the last-hit block, so a cs is never traded for a shove.
    if WV.SHOVE ~= "off" and not State.actionTaken and WV.ShoveAllowed(bot, s, enemyHero) then
        local tgt, abName = WV.FindShove(bot, s)
        if tgt then
            local ab = bot:GetAbilityByName(abName)
            if ab and ab:GetLevel() > 0 and U.IsRazeAbilityCastable(bot, ab) then
                local actionType, aimLoc = H.GetRazeActionType(bot, ab, tgt)
                if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, tgt) then
                    WV.NoteShove()
                    return
                end
            end
        end
    end

    if H.HandleTowerStealLastHit(bot, enemyCreeps, allyTowers, enemyTowers, allyCreeps) then return end

    -- PUSH: push the wave / hit the T1 under a shield (last hits have higher priority - we get here
    -- only when no last hit is imminent)
    -- Siege as a fallback plan: the intent is aggressive (ALLIN/ZONE/TRADE) but the enemy hides
    -- under his T1 and is unreachable while our edge is large and the wave is at the tower - hit the tower/creeps
    -- under a shield instead of standing around. (ExecutePush checks the shield, HP and enemy threat itself.)
    local siegeFallback = false
    if intent ~= I.PUSH and intent ~= I.RETREAT and intent ~= I.FARM and not State.defensive
        and race.valid and s.enemyT1 and myHpPct >= ((C.INTENT and C.INTENT.PUSH_MIN_HP_PCT) or 0.55)
        and race.edge >= ((C.INTENT and C.INTENT.PUSH_EDGE) or 260) and not race.heCanKillSoon then
        local okTL, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okTL and tLoc and GetUnitToLocationDistance(bot, tLoc) <= ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then
            siegeFallback = true
        end
    end
    if (intent == I.PUSH or siegeFallback) and not State.prepTarget and not am_i_tanking_too_much then
        if H.ExecutePush(bot, enemyHero, race, s) then return end
    end

    -- No creeps: walk to the lane (to the centre if far; otherwise to our own T1)
    local hasCreeps = (#allyCreeps > 0) or (#enemyCreeps > 0)
    -- Time hysteresis - creep lists are taken within 1200 of the bot, and when moving past
    -- that boundary "no creeps -> walk to the T1 (closer to the wave) -> creeps again -> back off"
    -- twitched 20 times a second. "No creeps" = not seen for >= 1.5 s.
    local nowC = GameTime()
    if hasCreeps then State.lastCreepsSeenTime = nowC end
    if not hasCreeps and (nowC - (State.lastCreepsSeenTime or -1e9)) < 1.5 then hasCreeps = true end
    if not hasCreeps and not U.IsActivelyHealing(bot) then
        -- No creeps (early game / the wave died): wait at our own T1 (the T1_CLOSE point).
        -- One target without "centre/T1" thresholds (they twitched at the 1500-from-centre boundary);
        -- the "between the T1 and the centre" point was removed - for Dire it landed in the river.
        local targetPos = State.waveScoutPoint or P.GetT1Close(bot)
        -- Do not route through the enemy T1 radius
        targetPos = H.GetSafeApproach(bot, targetPos, enemyTowers, allyCreeps)
        if GetUnitToLocationDistance(bot, targetPos) > 45 then
            H.SmartMove(bot, targetPos, 80)
        end
        return
    end

    if State.holdPos then return end

    local pos = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode)
    if enemyHero and U.CanQuery(enemyHero) then
        pos = U.ClampMinDistFromEnemy(bot, enemyHero, pos) -- Do not enter his band under "fear"
    end
    pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
    if GetUnitToLocationDistance(bot, pos) > 100 then
        H.SmartMove(bot, pos, 60)
    end

    -- The tick stayed free - switch the Power Treads for the current task
    if not State.actionTaken then
        H.ManageTreads(bot, nil)
    end
end

function Think()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then
        State.heroCombatEnemy = nil
        State.heroCombatUntil = 0
        State.survivalUntil = 0
        State.survivalLoc = nil
        State.needsTP = true
        State.emergencyRetreat = nil
        State.emergencyRetreatStartTime = 0
        State.emergencyTPQueued = false
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        State.goingToFountain = false
        State.fountainReason = nil
        State.enemyReachedLevel2First = false
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        H.ClearForcedRetreat()
        H.ClearTowerEscape()
        H.ClearRazeState()
        H.ClearMoveCache()
        H.ClearTangoState()
        State.dodgeLoc = nil
        State.dodgeUntil = 0
        State.intent = "FARM"
        I.Reset()
        return
    end

    local now = GameTime()
    if now - (State.lastThinkTick or -100) < 0.015 then return end
    State.lastThinkTick = now
    local success, err = pcall(H.RealThink)
    if not success then
        _G.__SF_RUNTIME_ERRORS = (_G.__SF_RUNTIME_ERRORS or 0) + 1
        _G.__SF_LAST_RUNTIME_ERROR = tostring(err)
        if _G.__SF_STRICT_ASSERT then
            error("[SF-BOT STRICT ASSERT] " .. tostring(err), 0)
        end
        if now - (State.lastErrorLog or -100) >= 1.0 then
            State.lastErrorLog = now
            print("[SF-BOT CRITICAL ERROR] " .. tostring(err))
        end
        -- Zero-Freeze Fail-Safe Recovery: NEVER leave the hero standing idle in lane if an unexpected API error occurs!
        pcall(function()
            local t1Safe = P.GetT1Close(bot, 380)
            if t1Safe and GetUnitToLocationDistance(bot, t1Safe) > 65 then
                bot:Action_MoveToLocation(t1Safe)
            end
        end)
    end
end
