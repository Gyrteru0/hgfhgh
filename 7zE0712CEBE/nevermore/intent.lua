--
-- The bot's intent for the tick: a finite state machine with hysteresis (minimum time in a state +
-- different enter/exit thresholds) so it does not flip between modes every frame.
--
-- States (by priority):
-- RETREAT - the enemy can kill me with his available burst and I cannot kill him "right now";
-- ALLIN   - I kill him with my available burst (and can reach him);
-- ZONE    - I am stronger in absolute HP and the enemy is at my wave: keep him off the creeps;
-- TRADE   - the trade is favourable/even and the enemy is in reach: pressure with razes/clicks;
-- PUSH    - the enemy is dead/unseen for >5 s, or a large advantage: push the wave, hit the T1 under a shield;
-- FARM    - default: last hits/denies.

local C = require("bots/nevermore/constants")

local I = {}

I.RETREAT, I.ALLIN, I.ZONE, I.TRADE, I.PUSH, I.FARM = "RETREAT", "ALLIN", "ZONE", "TRADE", "PUSH", "FARM"

local PRIO = { RETREAT = 5, ALLIN = 4, ZONE = 3, TRADE = 3, PUSH = 2, FARM = 1 }
local DWELL = { RETREAT = 0.9, ALLIN = 0.6, ZONE = 1.2, TRADE = 0.8, PUSH = 3.0, FARM = 0.4 }

local CFG = C.INTENT or {}
local PUSH_EDGE    = CFG.PUSH_EDGE or 260
local ZONE_EDGE    = CFG.ZONE_EDGE or 70
local TRADE_EDGE   = CFG.TRADE_EDGE or -30
local LOW_HP_PCT   = CFG.LOW_HP_PCT or 0.22
local PUSH_MIN_HP  = CFG.PUSH_MIN_HP_PCT or 0.55
local PUSH_KEEP_HP = CFG.PUSH_KEEP_HP_PCT or 0.45
local ZONE_WAVE_DIST = CFG.ZONE_WAVE_DIST or 900

I.state = I.FARM
I.since = -1
I.reason = ""

-- ctx (a reused table, filled in RealThink):
-- enemy (bool: the enemy is visible), race (K._race), myHpPct, myRazes (razes available with mana),
-- healing (bool), enemyDist, enemyDistToWave, enemyAbsent (bool), enemyUnderHisTower (bool),
-- canCatch (bool), underEnemyTower (bool: I am inside his T1 radius without a shield),
-- hunt (bool: "hunt" - see H.ComputeHunt),
-- defensive (bool: by the long projection (K.Race.weaker) I am weaker and without creep/tower support -
-- the aggressive ZONE/TRADE/PUSH-"advantage" intents are forbidden, leaving FARM/RETREAT/ALLIN)
function I.Update(ctx, now)
    local prev = I.state
    local R = ctx.race
    local rv = ctx.enemy and R and R.valid
    local want = I.FARM
    local reason = "default"
    local behind = (ctx.levelDeficit or 0) > 0 or ctx.tempoBehind == true

    -- A guaranteed finish (canKillNow) outranks even retreating:
    -- "if you can kill him before dying - kill him and do not be afraid" (a kill trade).
    -- The retreat triggers EARLIER (a 50 HP margin) but NOT when we are finishing ourselves and are
    -- ahead after the trade (edge >= 0) - "winning but running away" no longer happens.
    local heThreatens = R.heCanKillSoon or (R.enBurstSoon >= R.myHp - 50)
    local weWinTrade = R.canKillSoon and R.edge >= 0
    -- A clear advantage in the trade (edge >= 100) and he does NOT kill us instantly -
    -- no fear: a raze advantage (a higher raze level) has to convert into aggression,
    -- not retreat ("I am L3 with raze 2 and I am scared of L2 with raze 1")
    local weOutdamage = R.edge >= 100 and not R.heCanKillNow
    if rv and heThreatens and not R.canKillNow and not weWinTrade and not weOutdamage then
        want, reason = I.RETREAT, "enemy burst lethal"
    elseif ctx.towerChaseBlocked then
        want, reason = I.FARM, "enemy protected by tower"
    elseif rv and R.canKillNow then
        want, reason = I.ALLIN, "kill available"
    elseif rv and weWinTrade and ctx.canCatch then
        want, reason = I.ALLIN, "winning trade"
    elseif ctx.enemyTPIncoming and not ctx.healing and ctx.myHpPct < (CFG.TP_IN_MIN_HP_PCT or 0.55)
        and ((ctx.enemyT1Dist or 99999) <= 1500 or ctx.enemyDist <= 900) then
        -- We see his TP to the T1 (channel/respawn) - back off in advance if we are not in shape
        want, reason = I.RETREAT, "enemy tp incoming"
    elseif rv and R.spellWindow and not R.heCanKillSoon and (not behind or R.canKillSoon) then
        want, reason = I.TRADE, "safe spell resource window"
    elseif ctx.enemy and ctx.myHpPct < LOW_HP_PCT and not ctx.healing and ctx.enemyDist <= 1100 then
        want, reason = I.RETREAT, "low hp"
    elseif rv and (R.canKillSoon and not R.heCanKillSoon and ctx.canCatch) then
        want, reason = I.ALLIN, "kill soon"
    elseif rv and ctx.hunt and not behind then
        -- "Hunt" - a large HP edge, my burst over the horizon finishes him with an approach
        -- into the mid band (mana with mango), his burst is not dangerous to me
        want, reason = I.ALLIN, "hunt"
    elseif ctx.waveAtMyTower then
        want, reason = I.FARM, "wave at my tower"
    elseif ctx.enemyAbsent then
        want, reason = I.FARM, "enemy absent safe farm"
    elseif ctx.defensive then
        want, reason = I.FARM, "defensive"
    elseif rv and not behind and R.edge >= PUSH_EDGE and ctx.myHpPct >= PUSH_MIN_HP and ctx.myRazes >= 2
        and not R.heCanKillSoon and (ctx.enemyUnderHisTower or ctx.enemyDist > 1000) then
        want, reason = I.PUSH, "big advantage"
    elseif rv and not behind and ctx.enemyDistToWave <= ZONE_WAVE_DIST and R.edge >= ZONE_EDGE
        and not R.heCanKillSoon and ctx.myHpPct >= 0.35 then
        want, reason = I.ZONE, "stronger, enemy near wave"
    elseif rv and not behind and ((ctx.enemyDist <= 1000 and R.edge >= TRADE_EDGE)
        or (ctx.enemyDist <= 700 and R.edge >= -55 and ctx.myHpPct >= 0.48))
        and not R.heCanKillSoon then
        want, reason = I.TRADE, "trade ok"
    end

    -- Wave policy: downgrade a push that cannot crash into ordinary farming (never into idling).
    if want == I.PUSH and ctx.waveNoPush then
        if prev == I.PUSH then
            local WVm = package.loaded["bots/nevermore/wave"]
            if WVm then WVm.NoteBlock() end
        end
        want, reason = I.FARM, "wave policy"
    end

    if want ~= prev then
        local held = (I.since >= 0) and (now - I.since) or 999
        -- minimum time in a state unless the new one has higher priority
        local defensiveExit = ctx.defensive and (prev == I.ZONE or prev == I.TRADE or prev == I.PUSH)
        -- Urgent transitions are NOT delayed by dwell: a guaranteed finish - immediately,
        -- a lethal threat/low HP - run immediately (do not twitch between fighting and running).
        local urgent = reason == "enemy protected by tower" or reason == "safe spell resource window"
            or (want == I.ALLIN and rv and R.canKillNow)
            or (want == I.RETREAT and ((rv and R.heCanKillNow) or reason == "low hp"
                or reason == "enemy tp incoming" or reason == "enemy burst lethal"))
        if held < (DWELL[prev] or 0) and (PRIO[want] or 0) <= (PRIO[prev] or 0)
            and not defensiveExit and not urgent then
            want = prev
            reason = "dwell"
        end
        -- exit hysteresis
        if prev == I.RETREAT and want ~= I.ALLIN and rv and R.enBurstSoon >= R.myHp - 60 then
            want, reason = I.RETREAT, "retreat hysteresis"
        end
        -- Once the finish started - press it while he stays killable and we are not dying right now
        if prev == I.ALLIN and want == I.RETREAT and rv and R.canKillSoon
            and not R.heCanKillNow and ctx.enemyDist <= 900 and held < 1.2 then
            want, reason = I.ALLIN, "allin finish hysteresis"
        end
        if prev == I.PUSH and (want == I.FARM or want == I.TRADE or want == I.ZONE) and not defensiveExit then
            if ctx.enemyAbsent or (rv and R.edge >= PUSH_EDGE - 120 and ctx.myHpPct >= PUSH_KEEP_HP and not R.heCanKillSoon) then
                want, reason = I.PUSH, "push hysteresis"
            end
        end
        if prev == I.ZONE and (want == I.TRADE or want == I.FARM) and rv and not defensiveExit then
            if R.edge >= ZONE_EDGE - 80 and ctx.enemyDistToWave <= ZONE_WAVE_DIST + 200 and not R.heCanKillSoon then
                want, reason = I.ZONE, "zone hysteresis"
            end
        end
    end

    if want ~= prev then
        I.state = want
        I.since = now
    end
    I.reason = reason
    return I.state
end

function I.Reset()
    I.state = I.FARM
    I.since = -1
    I.reason = ""
end

return I
