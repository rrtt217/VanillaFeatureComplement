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
    if Player:GetWorld():GetBlock(Vector3i(BlockX,BlockY,BlockZ)) == E_BLOCK_AIR and Player:GetEquippedItem().m_ItemType == E_ITEM_FIREWORK_ROCKET and Player:IsElytraFlying() then
        Player.ElytraFireWorkID = Player:GetWorld():CreateProjectile(Player:GetPosX(),Player:GetPosY(),Player:GetPosZ(),cProjectileEntity.pkFirework,Player,Player:GetEquippedItem(),Player:GetSpeed())
        if Player:GetGameMode() == gmSurvival then
            Player:TossEquippedItem(1)
        end
        if Player.ElytraFireWorkID == 0 then
            math.randomseed(os.time())
            -- Player.ElytraFireWorkTime = Player:GetEquippedItem().m_FireworkItem["FlightTimeInTicks"]
            -- Can't get actual data, set to 20~60 ticks.
            Player.ElytraFireWorkTime = math.random(20,60)
        end
    elseif Player:GetEquippedItem().m_ItemType == E_ITEM_FIREWORK_ROCKET and Player:IsElytraFlying() then
        return true
    end
end

-- Reference: https://zh.minecraft.wiki/w/%E9%9E%98%E7%BF%85 (not in English Minecraft Wiki)
function SpeedUpPlayerOnTick(TimeDelta)
    cRoot:Get():ForEachPlayer(
        ---@param Player cPlayer
        function (Player)
            Player:GetWorld():DoWithEntityByID(Player.ElytraFireWorkID or 0,
            ---@param Entity cEntity
            function (Entity)
                if Lastpos and Player:IsElytraFlying() then
                    local look_vector = Vector3d(Player:GetLookVector())
                    -- LOG("Speed:".. "x" .. tostring(speed.x) .. "y"  .. tostring(speed.y) .. "z" .. tostring(speed.z))
                    -- Speed always returns 0, so use pos - lastpos.
                    local final_speed = Vector3d((0.85*(Player:GetPosX() - Lastpos.x) + 0.5*look_vector.x)/TimeDelta*1000 ,(0.85*(Player:GetPosY() - Lastpos.y) + 0.5*look_vector.y)/TimeDelta*1000 ,(0.85*(Player:GetPosZ() - Lastpos.z) + 0.5*look_vector.z)/TimeDelta*1000 )
                    Player:SetSpeed(final_speed)
                    Entity:SetSpeed(final_speed)
                    Entity:SetPosition(Player:GetPosition())
                end
            end
        )
            if (not Player.ElytraFireWorkID or Player.ElytraFireWorkID == 0) and (Player.ElytraFireWorkTime and Player.ElytraFireWorkTime >= 0) and Lastpos and Player:IsElytraFlying() then
                local look_vector = Vector3d(Player:GetLookVector())
                -- LOG("Speed:".. "x" .. tostring(speed.x) .. "y"  .. tostring(speed.y) .. "z" .. tostring(speed.z))
                local final_speed = Vector3d((0.85*(Player:GetPosX() - Lastpos.x) + 0.5*look_vector.x)/TimeDelta*1000 ,(0.85*(Player:GetPosY() - Lastpos.y) + 0.5*look_vector.y)/TimeDelta*1000 ,(0.85*(Player:GetPosZ() - Lastpos.z) + 0.5*look_vector.z)/TimeDelta*1000 )
                Player:SetSpeed(final_speed)
                Player.ElytraFireWorkTime = Player.ElytraFireWorkTime - 1
            end
        _G.Lastpos = Player:GetPosition()
        end
    )
end