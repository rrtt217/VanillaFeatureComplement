---@param Player cPlayer
---@param BlockX number
---@param BlockY number
---@param BlockZ number
---@param BlockFace any
---@param CursorX number
---@param CursorY number
---@param CursorZ number
-- Create a firework rocket entity when player use a firework rocket when ElytraFlying.
function StartPoweredFilghtOnPlayerUsingItem(Player, BlockX, BlockY, BlockZ, BlockFace, CursorX, CursorY, CursorZ)
    local State = GetPlayerState(Player)
    if Player:GetWorld():GetBlock(Vector3i(BlockX,BlockY,BlockZ)) == E_BLOCK_AIR and Player:GetEquippedItem().m_ItemType == E_ITEM_FIREWORK_ROCKET and Player:IsElytraFlying() then
        local Item = Player:GetEquippedItem()
        State.ElytraFireWorkID = Player:GetWorld():CreateProjectile(Player:GetPosX(),Player:GetPosY(),Player:GetPosZ(),cProjectileEntity.pkFirework,Player,Item,Player:GetSpeed())
        -- Charge the rocket. The boost is delivered either by the projectile entity
        -- (rocket with firework data) or by the per-tick speed push started below
        -- (rocket without firework data), so the rocket counts as used either way --
        -- one rocket per boost, as in vanilla. Use the IsXXX predicates instead of
        -- comparing GetGameMode() to a value: a player who inherits the gamemode
        -- from the world reports gmNotSet (-1), so a value comparison silently
        -- skipped the consumption for every world-default survival player.
        -- Vanilla consumes the rocket in survival and adventure, not in creative.
        if Player:IsGameModeSurvival() or Player:IsGameModeAdventure() then
            Player:GetInventory():RemoveOneEquippedItem()
        end
        if State.ElytraFireWorkID == 0 then
            -- cWorld:CreateProjectile returns cEntity::INVALID_ID (0) for a rocket
            -- without firework colours (cProjectileEntity::Create returns nullptr
            -- when m_FireworkItem.m_Colours is empty), so no entity exists for the
            -- client to boost from; the Lua API cannot supply the missing colours
            -- (m_Colours is not exposed to Lua, cFireworkItem cannot be built).
            -- Fall back to pushing the player along the look vector for a few ticks:
            -- cPlayer::BroadcastMovementUpdate sends that speed to the client as an
            -- Entity Velocity packet, so this push is not a no-op.
            DebugLog("Player " .. Player:GetName() .. " used a firework rocket without firework data (no colours); no boost entity could be spawned, using the speed-push fallback")
            math.randomseed(os.time())
            -- Player.ElytraFireWorkTime = Item.m_FireworkItem["FlightTimeInTicks"]
            -- Can't get actual data, set to 20~60 ticks.
            State.ElytraFireWorkTime = math.random(20,60)
        else
            -- A leftover fallback window from an earlier entity-less rocket must not
            -- keep pushing the player now that a real entity is doing the job.
            State.ElytraFireWorkTime = nil
        end
    elseif Player:GetEquippedItem().m_ItemType == E_ITEM_FIREWORK_ROCKET and Player:IsElytraFlying() then
        return true
    end
end

-- Reference: https://zh.minecraft.wiki/w/%E9%9E%98%E7%BF%85 (not in English Minecraft Wiki)
function SpeedUpPlayerOnTick(World, TimeDelta, LastTickDurationMSec)
    World:ForEachPlayer(
        ---@param Player cPlayer
        function (Player)
            local State = GetPlayerState(Player)
            Player:GetWorld():DoWithEntityByID(State.ElytraFireWorkID or 0,
            ---@param Entity cEntity
            function (Entity)
                if State.Lastpos and Player:IsElytraFlying() then
                    local look_vector = Vector3d(Player:GetLookVector())
                    -- Speed always returns 0, so use pos - lastpos.
                    local speed = ((Vector3d((Player:GetPosX() - State.Lastpos.x), (Player:GetPosY() - State.Lastpos.y), (Player:GetPosZ() - State.Lastpos.z))) / TimeDelta) * 1000
                    local final_speed = speed * 0.5 + look_vector * 1000 / TimeDelta * 0.85
                    Player:SetSpeed(final_speed)
                    Entity:SetSpeed(final_speed)
                    Entity:SetPosition(Player:GetPosition())
                end
            end
        )
            if (not State.ElytraFireWorkID or State.ElytraFireWorkID == 0) and (State.ElytraFireWorkTime and State.ElytraFireWorkTime >= 0) and State.Lastpos and Player:IsElytraFlying() then
                local look_vector = Vector3d(Player:GetLookVector())
                -- Speed always returns 0, so use pos - lastpos.
                local speed = ((Vector3d((Player:GetPosX() - State.Lastpos.x), (Player:GetPosY() - State.Lastpos.y), (Player:GetPosZ() - State.Lastpos.z))) / TimeDelta) * 1000
                local final_speed = speed * 0.5 + look_vector * 1000 / TimeDelta * 0.85
                Player:SetSpeed(final_speed)
                State.ElytraFireWorkTime = State.ElytraFireWorkTime - 1
            end
            State.Lastpos = Player:GetPosition()
        end
    )
end