-- scripts/vscripts/bots/hero_selection.lua

local BotHeroes = {
    "npc_dota_hero_nevermore",    -- Bot 1 (Mid)
    "npc_dota_hero_beastmaster",  -- Bot 2 (Jungle)
    "npc_dota_hero_beastmaster",  -- Bot 3 (Jungle)
    "npc_dota_hero_beastmaster",  -- Bot 4 (Jungle)
    "npc_dota_hero_beastmaster",  -- Bot 5 (Jungle)
}

local AllBeastmaster = {
    "npc_dota_hero_beastmaster",
    "npc_dota_hero_beastmaster",
    "npc_dota_hero_beastmaster",
    "npc_dota_hero_beastmaster",
    "npc_dota_hero_beastmaster",
}

function GetBotNames()
    return {
        "Gyrteru",
        "Mid SF = Jungle",
        "Mid SF = Jungle",
        "Mid SF = Jungle",
        "Mid SF = Jungle",
    }
end

-- Returns true if there is a real (non-bot) player in the team
function HasRealPlayerInTeam()
    local players = GetTeamPlayers(GetTeam())
    for _, playerId in pairs(players) do
        if not IsPlayerBot(playerId) then
            return true
        end
    end
    return false
end

function Think()
    local players = GetTeamPlayers(GetTeam())
    local botIndex = 1

    -- If there is a real player, pick Beastmaster for every bot and leave SF alone
    local heroesToPick = HasRealPlayerInTeam() and AllBeastmaster or BotHeroes

    for _, playerId in pairs(players) do
        if IsPlayerBot(playerId) then
            -- If a hero hasn't been selected yet
            if GetSelectedHeroName(playerId) == "" then
                -- Guard against running off the end of the array
                local heroToPick = heroesToPick[botIndex] or "npc_dota_hero_beastmaster"
                SelectHero(playerId, heroToPick)
            end
            botIndex = botIndex + 1
        end
    end
end

function UpdateLaneAssignments()
    -- Lanes don't matter for bots with custom AI (bot_*.lua),
    -- but the engine requires us to return a table like [playerID] = LANE_*
    local assignments = {}
    local players = GetTeamPlayers(GetTeam())

    for i, playerId in pairs(players) do
        if i == 1 then
            assignments[playerId] = LANE_MID
        else
            assignments[playerId] = LANE_BOT -- Filler bots "officially" assigned to bot lane
        end
    end
    return assignments
end
