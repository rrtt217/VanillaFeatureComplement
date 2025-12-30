-- Reference: https://minecraft.wiki/w/Weather
---@param Player cPlayer
---@param BlockX number
---@param BlockY number
---@param BlockZ number
---@param BlockFace number
---@param CursorX number
---@param CursorY number
---@param CursorZ number
---@param BlockType number
---@param BlockMeta number
function ClearWeatherOnPlayerSleep(Player, BlockX, BlockY, BlockZ, BlockFace, CursorX, CursorY, CursorZ, BlockType, BlockMeta)
    if BlockType == E_BLOCK_BED then
        -- Player Used Bed and try to sleep, so we start a QueueTask to see if the sleep has finished and has set the time to 0.
        Player:GetWorld():QueueTask(
            ---@param World cWorld
            function (World)
                LOG("Time:" .. tostring(World:GetTimeOfDay()))
                -- Behavior after Vanilla 21w44a. Before that the second condition doesn't exist.
                -- FIXME:There's a small possiblilty that the task is not executed in World Time 0, or player clicked the bed exactly in tick 0 when we shouldn't clear the weather.
                if World:GetTimeOfDay() < 1 and World:GetWeather() ~= wSunny then
                    World:SetWeather(wSunny)
                end
            end
        )
    end
end
