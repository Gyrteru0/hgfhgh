-- scripts/vscripts/bots/item_purchase_nevermore.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local K = require("bots/nevermore/combat")
local T = require("bots/nevermore/tempo")

local P = require("bots/nevermore/positioning")

local PurchaseTable = {
    "item_ward_observer",
    "item_tango",
    "item_branches",
    "item_circlet",
    "item_circlet",
    "item_enchanted_mango",
    "item_faerie_fire",

    -- Replay-adjusted 1v1 SF build: BOTH Bracers before Boots of Speed.
    -- The supplied replay showed the bot with one Bracer and no boots while the opponent had two Bracers;
    -- raw HP/damage from the second Bracer is prioritized over early movement speed.
    "item_gauntlets", "item_recipe_bracer",
    "item_gauntlets", "item_recipe_bracer",
    "item_boots",
    "item_magic_stick",

    -- Rush Power Treads with Belt of Strength FIRST (`+132 HP` in lane!) then Gloves of Haste
    "item_belt_of_strength",
    "item_gloves",

    "item_blade_of_alacrity", "item_belt_of_strength", "item_recipe_dragon_lance",

    "item_staff_of_wizardry", "item_robe", "item_recipe_kaya"
}

-- Per-bot purchase state (keyed by player ID)
local BotPurchaseState = {}

local function GetEnemyForPurchase(bot)
    local ok, list = pcall(GetUnitList, UNIT_LIST_ENEMY_HEROES)
    if ok and type(list) == "table" then
        for _, h in pairs(list) do
            if h and h.IsAlive and h:IsAlive() and h.GetUnitName and h:GetUnitName() == "npc_dota_hero_nevermore"
                and (not h.CanBeSeen or h:CanBeSeen()) then
                return h
            end
        end
    end
    local nearby = bot.GetNearbyHeroes and bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE) or nil
    if nearby then
        for _, h in pairs(nearby) do
            if h and h.IsHero and h:IsHero() and h:IsAlive() then return h end
        end
    end
    return nil
end

local function EnemyHasSalve(enemy)
    if not enemy then return false end
    if U.HasItem(enemy, "item_flask") then return true end
    if enemy.HasModifier and enemy:HasModifier("modifier_flask_healing") then return true end
    return false
end

local function SalveParityOK(bot, enemy, cfg)
    if cfg.SALVE_PARITY_ENABLE == false then return true end
    -- If the enemy is not visible, keep the old safety behaviour: we cannot prove HP parity.
    if not enemy then return true end
    -- If the enemy has a salve (or is already salving), a salve answer is allowed.
    if EnemyHasSalve(enemy) then return true end
    local deficit = (enemy:GetHealth() or 0) - (bot:GetHealth() or 0)
    return deficit >= (cfg.SALVE_HP_DEFICIT or 250)
end


-- Gets or creates the purchase state for a specific bot
local function GetBotState(bot)
    local pid = bot:GetPlayerID()
    if pid == nil or pid < 0 then
        return nil
    end

    if not BotPurchaseState[pid] then
        BotPurchaseState[pid] = {
            currentItemIndex = 1,
            lastSalveBuyTime = -1000,
            lastClarityBuy = -1000,
            extraMango = 0, extraSalve = 0,
            recoveryWindowAt = -1000, recoverySpent = 0, lastRecoveryBuy = -1000,
            lastShopAttempt = -1000,
            bought5MinWard = false,
            lastCourierCallTime = -1000,
            lastCourierCommandTime = -1000,
            lastCourierCommandState = nil,
            lastCourierBurstTime = -1000,
            resolvedCourierSlot = nil,
            trySlotOffset = 0,
        }
    end

    return BotPurchaseState[pid]
end

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot then return end
    local alive = bot:IsAlive()

    local state = GetBotState(bot)
    if not state then return end
    if GameTime() < state.lastShopAttempt then
        state.lastShopAttempt = -1000
        state.lastCourierCallTime = -1000
        state.lastSalveBuyTime = -1000
        state.recoveryWindowAt = GameTime()
        state.resolvedCourierSlot = nil
        state.trySlotOffset = 0
    end
    if GameTime() - state.lastShopAttempt < 0.25 then return end
    state.lastShopAttempt = GameTime()
    local gold = bot:GetGold()

    -- 0. WARD AT 4:30 (270 seconds) — never buy a duplicate if starting ward is still in inventory!
    if DotaTime() >= 270 and not state.bought5MinWard then
        local alreadyHasWard = false
        for s = 0, 14 do
            local it = bot:GetItemInSlot(s)
            if it and it:GetName() == "item_ward_observer" then alreadyHasWard = true; break end
        end
        if alreadyHasWard then
            state.bought5MinWard = true
        else
            local result = bot:ActionImmediate_PurchaseItem("item_ward_observer")
            if result == (PURCHASE_ITEM_SUCCESS or 0) then state.bought5MinWard = true end
        end
    end

    -- Inventory + stash + dedicated TP slot + team courier: do not duplicate an item in delivery.
    local function owns(name)
        if name == "item_tpscroll" or name == "item_teleport_scroll" then
            return U.HasAnyTPScroll(bot)
        end
        for i = 0, 20 do
            local ok, it = pcall(bot.GetItemInSlot, bot, i)
            if ok and it and it:GetName() == name then return true end
        end
        local nCour = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        for i = 0, nCour - 1 do
            local courier = GetCourier(i)
            if courier and not courier:IsNull() then
                local cPid = courier.GetPlayerID and courier:GetPlayerID() or -1
                local mine = (cPid == bot:GetPlayerID())
                    or (state.resolvedCourierSlot ~= nil and i == state.resolvedCourierSlot)
                    or (nCour == 1 and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam()))
                if mine then
                    for slot = 0, 8 do
                        local ok, it = pcall(courier.GetItemInSlot, courier, slot)
                        if ok and it and it:GetName() == name then return true end
                    end
                end
            end
        end
        return false
    end

    -- Unconditional Pro Lane Reset Priority:
    -- NEVER sit below 66% HP (`missingHP >= 320`) in lane without a Healing Salve just because the
    -- enemy hero died (e.g. post-First-Blood `104/1034 HP` with `238g`) or stepped into night fog!
    local now = GameTime()
    local cfg = C.CONSUMABLE_BUY or {}
    if now - state.recoveryWindowAt >= (cfg.RECOVERY_WINDOW or 150) then
        state.recoveryWindowAt = now
        state.recoverySpent = 0
        state.extraSalve = 0
        state.extraMango = 0
    end
    local fntLoc = P.GetFountain(bot)
    local nearFountain = bot:HasModifier("modifier_fountain_aura_buff")
        or (fntLoc and GetUnitToLocationDistance(bot, fntLoc) <= 2000)
    local missingHP = bot:GetMaxHealth() - bot:GetHealth()
    local hpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())

    local recoveryBought = false
    -- Never buy consumables in death agony (`auto-20261022-2237` `05:48.17` bug: bought `Flask #5` at `72 HP`
    -- `0.067s` before dying, starving Boots by `-100g` and sitting unused after fountain respawn!).
    local closeEnemy = nil
    local nearbyH = bot.GetNearbyHeroes and bot:GetNearbyHeroes(850, true, BOT_MODE_NONE) or nil
    if nearbyH and nearbyH[1] then closeEnemy = nearbyH[1] end
    local incomingLethalOrDying = (bot:GetHealth() <= 195
        and ((bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(3.0))
            or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(3.0))
            or (closeEnemy ~= nil)))
        or (closeEnemy ~= nil and K.EnemyRazeDamage and ((closeEnemy:GetMana() or 0) >= 75)
            and (K.EnemyRazeDamage(bot, closeEnemy, 1) + 35 >= bot:GetHealth()))
    local salveEnemy = GetEnemyForPurchase(bot)
    local salveParityOK = SalveParityOK(bot, salveEnemy, cfg)
    local hasBootsOwned = owns("item_boots") or owns("item_power_treads")
    -- Unified time-scaled Salve cap (`A17` + `0050` `08:15` 60s walk-home fix):
    -- `<= 1` pre-Boots, `2` through 5:00, and `+1` every 3.5 minutes after 5:00 (max `4`) so SF NEVER abandons Mid T1 on foot!
    local dtimeNow = DotaTime()
    local maxExtraSalves = hasBootsOwned
        and math.min(4, 2 + math.floor(math.max(0, dtimeNow - 300) / 210))
        or 1
    local maxExtraMangoes = hasBootsOwned
        and math.min(3, 2 + math.floor(math.max(0, dtimeNow - 360) / 240))
        or 1
    -- v4.3.4: a salve must not repeatedly reset the gold bar for the NEXT core component.
    -- Replay 9068981052: the bot bought salves at 02:10 and 03:32 while sitting on the
    -- 210g Bracer recipe, so Bracer #1 only completed at 05:30 (human: 02:13).
    -- Priority A previously had NO reserve check (only the late branch did).
    local nextCore = PurchaseTable[state.currentItemIndex]
    local nextCoreCost = nextCore and GetItemCost(nextCore) or 0
    local coreAlmostReady = nextCoreCost > 0 and gold >= nextCoreCost - (cfg.CORE_RESERVE_MARGIN or 110)
    local salveReserveOK = (not coreAlmostReady) or hpPctNow <= (cfg.CORE_RESERVE_HP or 0.40)
    if alive and dtimeNow > 0 and not nearFountain and not incomingLethalOrDying then
        -- Priority A: Disciplined Healing Salve (`<= 1` pre-Boots, time-scaled post-Boots)
        local salveCD = math.max(cfg.RECOVERY_COOLDOWN or 22, 62)
        if state.extraSalve < maxExtraSalves
            and salveParityOK
            and salveReserveOK
            and (missingHP >= 340 or hpPctNow <= 0.48)
            and not bot:HasModifier("modifier_flask_healing")
            and not bot:HasModifier("modifier_tango_heal")
            and not owns("item_flask")
            and now - state.lastSalveBuyTime >= salveCD then
            local cost = GetItemCost("item_flask")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_flask") > 0
            if inStock and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_flask")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastSalveBuyTime = now
                    state.extraSalve = state.extraSalve + 1
                    gold = bot:GetGold()
                end
            end
        end

        -- v4.3.6-tempo: Clarity is the human's cheap long-refill (60g / 150 mana over 25s).
        -- Buy only when actually dry and safe enough to use it; never delays a bracer component.
        if not recoveryBought and state.currentItemIndex > 11
            and T.ShouldBuyClarity(bot, GetEnemyForPurchase(bot))
            and now - (state.lastClarityBuy or -1000) >= ((C.TEMPO and C.TEMPO.CLARITY_BUY_COOLDOWN) or 35)
            and not owns("item_clarity") then
            local cost = GetItemCost("item_clarity")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_clarity") > 0
            if inStock and state.recoverySpent + cost <= (cfg.RECOVERY_BUDGET or 360) and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_clarity")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastClarityBuy = now
                    state.lastRecoveryBuy = now
                    gold = bot:GetGold()
                end
            end
        end

        -- Priority B: Urgent Enchanted Mango replenishment (`<= 1` pre-Boots, `<= maxExtraMangoes` total!)
        if not recoveryBought and state.currentItemIndex > 11 -- both Bracers ordered before recovery mangoes
            and state.extraMango < maxExtraMangoes
            and now - state.lastRecoveryBuy >= 55
            and K.MyManaBudget(bot, true) < 125
            and (bot:GetMaxMana() - bot:GetMana()) >= 115
            and hpPctNow >= 0.52
            and not owns("item_enchanted_mango") then
            local cost = GetItemCost("item_enchanted_mango")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
            if inStock and state.recoverySpent + cost <= (cfg.RECOVERY_BUDGET or 340) and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.extraMango = state.extraMango + 1
                    gold = bot:GetGold()
                end
            end
        end
    end

    -- Main build has priority, especially both bracers. Advance only on success.
    local nextItem = PurchaseTable[state.currentItemIndex]
    if nextItem and gold >= GetItemCost(nextItem) then
        local result = bot:ActionImmediate_PurchaseItem(nextItem)
        if result == (PURCHASE_ITEM_SUCCESS or 0) then
            state.currentItemIndex = state.currentItemIndex + 1
        end
        gold = bot:GetGold()
    end

    local early = state.currentItemIndex <= 11 -- both bracers not yet ordered
    local interval = early and 120 or 90
    if alive and not recoveryBought and not incomingLethalOrDying and dtimeNow > 0 and GameTime() - state.lastSalveBuyTime >= interval
        and not bot:HasModifier("modifier_fountain_aura_buff") then
        local hp = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
        local name
        if hp < 0.35 and not bot:HasModifier("modifier_flask_healing")
            and state.extraSalve < maxExtraSalves and salveParityOK then
            name = "item_flask"
        elseif bot:GetMana() < 75 and hp >= 0.50 and state.extraMango < maxExtraMangoes then
            name = "item_enchanted_mango"
        elseif T.ShouldBuyClarity(bot, GetEnemyForPurchase(bot))
            and now - (state.lastClarityBuy or -1000) >= ((C.TEMPO and C.TEMPO.CLARITY_BUY_COOLDOWN) or 35) then
            name = "item_clarity"
        end
        local nextBuild = PurchaseTable[state.currentItemIndex]
        local reserve = math.max(210, nextBuild and GetItemCost(nextBuild) or 0)
        if name and not owns(name) and gold >= GetItemCost(name) + reserve then
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount(name) > 0
            if inStock then
                local result = bot:ActionImmediate_PurchaseItem(name)
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    state.lastSalveBuyTime = GameTime()
                    if name == "item_flask" then state.extraSalve = state.extraSalve + 1
                    elseif name == "item_clarity" then state.lastClarityBuy = GameTime()
                    else state.extraMango = state.extraMango + 1 end
                end
            end
        end
    end

    -- 3. SMART COURIER (Rolled back cleanly to `v3.9.0` pre-prestage behavior: ZERO custom spot pre-positioning,
    --    ZERO pre-horn movement, ONLY standard `COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS` when Stash holds items!)
    if GameTime() - state.lastCourierCallTime > 0.35 then
        local pid = bot:GetPlayerID()
        if pid < 0 then return end

        local numCouriers = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        if numCouriers <= 0 then return end

        -- v4.3.5: NEVER rotate through teammates' couriers. The replay contains five
        -- personal Dire couriers; the old fallback issued TAKE_AND_TRANSFER every
        -- 0.533s to whichever Beastmaster courier happened to be delivering.
        local myCourier = nil
        local pid = bot:GetPlayerID()
        for i = 0, numCouriers - 1 do
            local c = GetCourier(i)
            if c and not c:IsNull() and (not c.GetTeam or c:GetTeam() == bot:GetTeam()) then
                local cPid = c.GetPlayerID and c:GetPlayerID() or -1
                if cPid == pid then
                    myCourier = c; state.resolvedCourierSlot = i; break
                end
            end
        end
        if not myCourier then
            -- Source 2 may expose courier:GetPlayerID() == -1. Use the stable team
            -- slot mapping (the same contract used by item_purchase_beastmaster),
            -- but reject any courier that positively reports another owner.
            local slot = 0
            local okT, teamPlayers = pcall(GetTeamPlayers, bot:GetTeam())
            if okT and type(teamPlayers) == "table" then
                for index, id in pairs(teamPlayers) do
                    if id == pid then slot = index - 1; break end
                end
            end
            if slot >= 0 and slot < numCouriers then
                local c = GetCourier(slot)
                if c and not c:IsNull() and (not c.GetTeam or c:GetTeam() == bot:GetTeam()) then
                    local cPid = c.GetPlayerID and c:GetPlayerID() or -1
                    if cPid < 0 or cPid == pid then
                        myCourier = c; state.resolvedCourierSlot = slot
                    end
                end
            end
        end

        if myCourier and not myCourier:IsNull() then
            local state_c = GetCourierState(myCourier)
            local stashItemsCount = 0
            local onlyWardInStash = true
            local urgentCourier = false
            local stashHasFlask = false
            local stashHasMango = false
            local courierHasFlask = false

            for i = 9, 14 do
                local item = bot:GetItemInSlot(i)
                if item then
                    stashItemsCount = stashItemsCount + 1
                    local nm = item:GetName()
                    if nm ~= "item_ward_observer" then
                        onlyWardInStash = false
                    end
                    if nm == "item_flask" then stashHasFlask = true end
                    if nm == "item_enchanted_mango" then stashHasMango = true end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" then
                        urgentCourier = true
                    end
                    -- Boots/bracer/stick are urgent, but they are not a healing salve.
                end
            end

            local courierItemsCount = 0
            for slot = 0, 8 do
                local okI, cItem = pcall(myCourier.GetItemInSlot, myCourier, slot)
                if okI and cItem then
                    courierItemsCount = courierItemsCount + 1
                    local nm = cItem:GetName()
                    if nm == "item_flask" then courierHasFlask = true end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" then
                        urgentCourier = true
                    end
                end
            end

            local hasStash = stashItemsCount > 0 or (bot.GetStashValue and (bot:GetStashValue() or 0) > 0)
            local hasOnCourier = courierItemsCount > 0 or (bot.GetCourierValue and (bot:GetCourierValue() or 0) > 0)
            local courierDistFnt = fntLoc and GetUnitToLocationDistance(myCourier, fntLoc) or math.huge
            local courierNearBase = courierDistFnt <= 2200
            local onlySoloGauntlets = (stashItemsCount == 1) and not urgentCourier and (DotaTime() < 360)
                and (bot:GetItemInSlot(9) and bot:GetItemInSlot(9):GetName() == "item_gauntlets")
            local holdBatch = (stashItemsCount == 1 and onlyWardInStash) or onlySoloGauntlets
            local hpPctNow = (bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 1)
            local needFlaskTurnback = stashHasFlask and not courierHasFlask
                and not U.HasItem(bot, "item_flask") and not bot:HasModifier("modifier_flask_healing")
                and (hpPctNow < 0.35 or courierDistFnt <= 4800)
            -- Replay hfghfghg: mango bought 01:48.47 was still in stash at the 02:33.93
            -- death. A sub-75-mana hero must recall the personal courier immediately,
            -- not wait until it happens to return within 2200u of the fountain.
            local needManaTurnback = stashHasMango and (bot:GetMana() or 0) < 75
                and not U.GetActiveItemByName(bot, "item_enchanted_mango")
                and state_c == COURIER_STATE_RETURNING_TO_BASE
            local needShortBatchTurnback = courierNearBase and state_c == COURIER_STATE_DELIVERING_ITEMS
            if hasStash and not holdBatch then
                if state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                    or (state_c == COURIER_STATE_RETURNING_TO_BASE and courierNearBase)
                    or needFlaskTurnback or needManaTurnback or needShortBatchTurnback then
                    -- Throttle repeated identical commands. The old 0.35s reissue
                    -- produced 121 courier orders in this replay and could reset pathing.
                    if state_c ~= state.lastCourierCommandState
                        or GameTime() - (state.lastCourierCommandTime or -1000) >= 2.0 then
                        bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
                        state.lastCourierCommandTime = GameTime()
                        state.lastCourierCommandState = state_c
                    end
                    if urgentCourier and COURIER_ACTION_BURST
                        and GameTime() - (state.lastCourierBurstTime or -1000) >= 5.0 then
                        pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                        state.lastCourierBurstTime = GameTime()
                    end
                    state.lastCourierCallTime = GameTime()
                end
            elseif hasOnCourier and (state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                or state_c == COURIER_STATE_RETURNING_TO_BASE) then
                bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TRANSFER_ITEMS)
                if urgentCourier and COURIER_ACTION_BURST then
                    pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                end
                state.lastCourierCallTime = GameTime()
            end
        end
    end
end
