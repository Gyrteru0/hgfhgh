
local C = require("bots/nevermore/constants")

local S = {}

function S.GetSouls(bot)
    local numModifiers = bot:NumModifiers()
    if numModifiers and numModifiers > 0 then
        for i = 0, numModifiers - 1 do
            local modName = bot:GetModifierName(i)
            if modName == "modifier_nevermore_necromastery" then
                return bot:GetModifierStackCount(i) or 0
            end
        end
    end
    return 0
end

-- 7.41f: 1 damage per soul, +0.8 every 6 hero levels (an estimate; the real damage is GetAttackDamage()).
function S.GetDamagePerSoul(bot)
    local level = (bot and bot:GetLevel()) or 1
    -- KV: "hero_levelup +0.8, levelup_interval 6" -> the bonus at levels 6, 12, 18, 24
    local steps = math.floor(math.max(0, level) / 6)
    return (C.NECROMASTERY.BASE_DMG_PER_SOUL or 1.0)
        + (C.NECROMASTERY.DMG_PER_SOUL_PER_6_LEVELS or 0.8) * steps
end

function S.GetSoulDamageBonus(bot)
    return S.GetSouls(bot) * S.GetDamagePerSoul(bot)
end

return S
