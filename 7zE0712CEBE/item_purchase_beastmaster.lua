-- scripts/vscripts/bots/item_purchase_beastmaster.lua

-- Strict purchase queue: 6 rings of protection for armor
local PurchaseTable = {
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection"
}

local currentItemIndex = 1

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot then return end

    local gold = bot:GetGold()

    -- 1. BUY RINGS
    if currentItemIndex <= #PurchaseTable then
        local nextItem = PurchaseTable[currentItemIndex]
        if gold >= GetItemCost(nextItem) then
            local result = bot:ActionImmediate_PurchaseItem(nextItem)
            if result == (PURCHASE_ITEM_SUCCESS or 0) then currentItemIndex = currentItemIndex + 1 end
        end
    end

    -- 2. PERSONAL COURIER
    -- In Dota, couriers are indexed 0-4 per team.
    -- We need to figure out which slot this Beastmaster occupies so we grab HIS courier.
    local numCouriers = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
    if numCouriers <= 0 then return end

    local myPlayerId = bot:GetPlayerID()
    local teamPlayers = GetTeamPlayers(bot:GetTeam())
    local myCourierIndex = 0

    for index, id in pairs(teamPlayers) do
        if id == myPlayerId then
            myCourierIndex = index - 1 -- Lua tables are 1-based, Dota API is 0-based
            break
        end
    end

    if myCourierIndex >= 0 and myCourierIndex < numCouriers then
        local courier = GetCourier(myCourierIndex)
        if courier and not courier:IsNull() and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam()) then
            local state = GetCourierState(courier)
            -- If the bot has a ring sitting in stash and his personal courier is idle
            if bot:GetStashValue() > 0 and (state == COURIER_STATE_IDLE or state == COURIER_STATE_AT_BASE) then
                bot:ActionImmediate_Courier(courier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
            end
        end
    end
end
