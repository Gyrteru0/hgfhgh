local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local P = {}

function P.GetFountain(bot)
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function P.GetT1Tower(bot)
    if type(GetTower) == "function" and TOWER_MID_1 ~= nil then
        local tower = GetTower(bot:GetTeam(), TOWER_MID_1)
        if tower and tower:IsAlive() and (not tower.CanBeSeen or tower:CanBeSeen()) then
            return tower:GetLocation()
        end
    end
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
end

function P.GetT1Close(bot, distance)
    local tower = P.GetT1Tower(bot)
    local enemyTeam = bot:GetTeam() == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT
    local enemyLoc = bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    if type(GetTower) == "function" and TOWER_MID_1 ~= nil then
        local enemyTower = GetTower(enemyTeam, TOWER_MID_1)
        if enemyTower and enemyTower:IsAlive() and (not enemyTower.CanBeSeen or enemyTower:CanBeSeen()) then
            enemyLoc = enemyTower:GetLocation() or enemyLoc
        end
    end
    local home = (enemyLoc - tower):Normalized()
    return tower + home * (distance or 180)
end

-- True defensive point BEHIND allied T1 toward Fountain (never forward into river — fixes `R2_2044` `04:16..04:26`
-- `(1653, 1533) <-> (1450, 1334)` Salve oscillation where `GetT1Close(bot, 420)` pointed SW toward enemy!).
function P.GetBehindT1(bot, distance)
    local tower = P.GetT1Tower(bot)
    local fnt = P.GetFountain(bot)
    local back = (fnt - tower):Normalized()
    return tower + back * (distance or 400)
end

-- Upgrade river points (height level 1) up toward allied highground bank when attacking highground creeps,
-- eliminating the 25% Source 2 uphill miss rate completely whenever safe.
function P.AvoidUphillMiss(bot, candidatePos, targetLoc, maxRange)
    if type(GetHeightLevel) ~= "function" or not candidatePos or not targetLoc then
        return candidatePos
    end
    local th = GetHeightLevel(targetLoc)
    local ch = GetHeightLevel(candidatePos)
    if ch >= th then return candidatePos end

    local fountain = P.GetFountain(bot)
    local toFountain = (fountain - candidatePos):Normalized()
    maxRange = maxRange or ((bot:GetAttackRange() or 525) - 25)

    -- Search radially & along allied ramp for closest non-river highground point still inside attack range
    for step = 60, 320, 40 do
        local test = candidatePos + toFountain * step
        local dx, dy = test.x - targetLoc.x, test.y - targetLoc.y
        if math.sqrt(dx * dx + dy * dy) <= maxRange and GetHeightLevel(test) >= th then
            return test
        end
    end
    -- Also test walking right onto the creep's own highground lip if close enough
    local towardTarget = (targetLoc - candidatePos):Normalized()
    for step = 60, 260, 40 do
        local test = candidatePos + towardTarget * step
        local dx, dy = test.x - targetLoc.x, test.y - targetLoc.y
        if math.sqrt(dx * dx + dy * dy) <= maxRange and GetHeightLevel(test) >= th then
            return test
        end
    end
    return candidatePos
end

function P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, prepareTarget, mode)
    local fountain = P.GetFountain(bot)

    -- Farm cleanly under our T1 WITHOUT letting unshielded enemy melee creeps beat on our hero body
    -- (`9056469656.dem` `01:20` `(90, 981)` 9 free melee creep hits & `02:34` `(293, 374)` stationary tanking!):
    -- When `#allyCreeps == 0` and any live non-killable enemy creep under our T1 is aggroed onto `bot` (`GetAttackTarget() == bot`),
    -- step 435u back past our own T1 toward Fountain so Dire/Radiant T1 tanks & damages the melee creeps for 0 HP cost!
    do
        local t1 = P.GetT1Tower(bot)
        if t1 and enemyCreeps and #enemyCreeps > 0 then
            local lowestCreep, lowestHP = nil, math.huge
            local meleeBeatingBot, beatingCount, minFntDist = nil, 0, math.huge
            local killThresh = (bot:GetAttackDamage() or 55) + 22
            local hpDamaged = (bot:GetHealth() or 999) < (bot:GetMaxHealth() or 999) * 0.72
            for _, c in pairs(enemyCreeps) do
                if c and c:IsAlive() then
                    local d = GetUnitToLocationDistance(c, t1)
                    if d <= 780 then
                        local hp = c:GetHealth()
                        if hp < lowestHP then
                            lowestHP, lowestCreep = hp, c
                        end
                        if (not allyCreeps or #allyCreeps == 0) and hp > killThresh
                            and c.GetAttackTarget and c:GetAttackTarget() == bot then
                            beatingCount = beatingCount + 1
                            local dFnt = GetUnitToLocationDistance(c, fountain)
                            if dFnt < minFntDist then
                                minFntDist, meleeBeatingBot = dFnt, c
                            end
                        end
                    end
                end
            end
            -- Stop kiting `435u` back as soon as the lowest under-T1 creep is within `1` tower hit (`killThresh + 115`),
            -- so SF steps straight into `175u` phase-locked stance with `0` turn-rate penalty BEFORE the killing window opens!
            if meleeBeatingBot and (hpDamaged or beatingCount >= 2) and lowestCreep and lowestHP > (killThresh + 115) then
                local cLoc = meleeBeatingBot:GetLocation()
                local dir = (fountain - cLoc):Normalized()
                return cLoc + dir * 435
            end
            if lowestCreep then
                local cLoc = lowestCreep:GetLocation()
                local dir = (fountain - cLoc):Normalized()
                local stand = (C.BALLISTIC and C.BALLISTIC.CLOSE_STAND_DIST) or 175
                return P.AvoidUphillMiss(bot, cLoc + dir * stand, cLoc)
            end
        end
    end

    local function safeNoShieldCS(p)
        if not p then return p end
        local Wmod = package.loaded["bots/nevermore/world"]
        local ws = Wmod and Wmod.s
        if ws and ws.enemyT1Alive ~= false and ws.enemyT1Loc and #(allyCreeps or {}) == 0 then
            local tLoc = ws.enemyT1Loc
            if U.DistanceBetweenLocations(p, tLoc) < 885 then
                return tLoc + (fountain - tLoc):Normalized() * 885
            end
        end
        return p
    end

    if prepareTarget and prepareTarget:IsAlive() then
        local cLoc = prepareTarget:GetLocation()
        local dir = (fountain - cLoc):Normalized()
        local stand = (mode == "PASSIVE") and 420 or ((C.BALLISTIC and C.BALLISTIC.CLOSE_STAND_DIST) or 175)
        return safeNoShieldCS(P.AvoidUphillMiss(bot, cLoc + dir * stand, cLoc))
    end

    if not allyCreeps or #allyCreeps == 0 then
        if enemyCreeps and #enemyCreeps > 0 then
            -- Kite/hold safely at max range toward our tower without losing sight or missing dying low-HP enemy creeps
            local bestC, bestHP = nil, math.huge
            for _, c in pairs(enemyCreeps) do
                if c and c:IsAlive() and c:GetHealth() < bestHP then
                    bestHP, bestC = c:GetHealth(), c
                end
            end
            if bestC then
                local cLoc = bestC:GetLocation()
                local dir = (fountain - cLoc):Normalized()
                return safeNoShieldCS(P.AvoidUphillMiss(bot, cLoc + dir * 430, cLoc))
            end
        end
        return P.GetT1Close(bot)
    end

    local enemyT1 = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    local frontAlly = allyCreeps[1]
    local minDist = math.huge
    for _, c in pairs(allyCreeps) do
        if c and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, enemyT1)
            if d < minDist then
                minDist = d
                frontAlly = c
            end
        end
    end
    local fLoc = frontAlly:GetLocation()
    local dir = (fountain - fLoc):Normalized()
    local dist_from_creeps = 260
    if mode == "PASSIVE" then
        dist_from_creeps = 460
    elseif mode == "AGGRESSIVE" then
        dist_from_creeps = 175
    end
    do
        local WV = package.loaded["bots/nevermore/wave"]
        if WV then dist_from_creeps = WV.WaveDist(bot, dist_from_creeps, mode) end
    end
    local aimRef = fLoc
    if prepareTarget and prepareTarget.GetLocation then
        aimRef = prepareTarget:GetLocation()
    elseif enemyCreeps then
        for _, ec in pairs(enemyCreeps) do
            if ec and ec:IsAlive() then
                local el = ec:GetLocation()
                if type(GetHeightLevel) == "function" and GetHeightLevel(el) > GetHeightLevel(aimRef) then
                    aimRef = el
                    break
                end
            end
        end
    end
    local res = P.AvoidUphillMiss(bot, fLoc + dir * dist_from_creeps, aimRef)
    -- Forward-Zoning Enemy Guard (`R2_2044` `02:39` `A464(-348,-215)` & `03:53` `A300(-541,-360)` Root Cause!):
    -- When a live enemy hero steps PAST the creep wave onto our side (`eFntDist < resFntDist + 180`), `fLoc + dir * dist`
    -- lands BEHIND the enemy hero's back! Never walk past/through a non-lethal enemy hero just to reach `frontAlly`!
    if bot.GetNearbyHeroes then
        local nearEnemies = bot:GetNearbyHeroes(1500, true, BOT_MODE_NONE)
        local eh = nearEnemies and nearEnemies[1] or nil
        if eh and (not eh.CanBeSeen or eh:CanBeSeen()) and eh:IsAlive() and (eh:GetHealth() or 999) > 220 then
            local eLoc = eh:GetLocation()
            local dxE, dyE = fountain.x - eLoc.x, fountain.y - eLoc.y
            local dxR, dyR = fountain.x - res.x, fountain.y - res.y
            local eFntDist = math.sqrt(dxE * dxE + dyE * dyE)
            local rFntDist = math.sqrt(dxR * dxR + dyR * dyR)
            -- Trigger strictly when `res` lies AT or BEHIND `eh` (`rFntDist > eFntDist - 80`), i.e., `eh` literally
            -- stepped across the wave onto our side between `bot` and `res`!
            -- `v4.2.0` Anti-Zoning Stand-Ground Upgrade: when healthy/even (`myHp >= ehHp * 0.78`), hold `385u` inside
            -- BOTH creep last-hit range AND hero counter-attack range instead of backing `560u` out of XP/CS range!
            if rFntDist > eFntDist - 80 then
                local myHpNow = bot:GetHealth() or 0
                local ehHpNow = eh:GetHealth() or 999
                local canStandGround = (myHpNow >= 320 and myHpNow >= ehHpNow * 0.78 and mode ~= "PASSIVE")
                local standPad = canStandGround and 385 or ((mode == "PASSIVE") and 545 or 485)
                local homeDir = (fountain - eLoc):Normalized()
                res = P.AvoidUphillMiss(bot, eLoc + homeDir * standPad, eLoc)
            end
        end
    end
    -- Fog-of-War Enemy T1 No-Shield Guard (`v3.9.0`, `auto-20261022-2237` Death #2 `06:47.03` Root Cause Fix!):
    -- When the last allied creep under Radiant T1 died at `06:45.03` and highground `goodguys_tower1_mid (-1544, -1408)`
    -- dropped into Fog of War (`CanBeSeen() == false`), `P.GetLasthitPosition(bot, enemyCreeps, {}, ...)` sent SF back
    -- to `(-955, -753)` (`880.8u`) right into a live T1 bolt + L7 `PowerTreads` SF! Never anchor inside `955u` without shield!
    local Wmod = package.loaded["bots/nevermore/world"]
    local ws = Wmod and Wmod.s
    if ws and ws.enemyT1Alive ~= false and ws.enemyT1Loc and ws.enemy and #(allyCreeps or {}) == 0 then
        local tLoc = ws.enemyT1Loc
        local dT1 = U.DistanceBetweenLocations(res, tLoc)
        if dT1 < 885 then
            res = tLoc + (fountain - tLoc):Normalized() * 885
        end
    end
    return res
end

return P
