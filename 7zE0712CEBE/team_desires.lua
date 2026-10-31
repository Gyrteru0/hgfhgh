-- scripts/vscripts/bots/team_desires.lua
function GetDesiredLanes()
    return {
        [LANE_TOP]    = 1.0,
        [LANE_MID]    = 1.0,
        [LANE_BOT]    = 2.0,
        [LANE_JUNGLE] = 0,
    }
end
