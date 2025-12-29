---@param Entity cEntity
---@param World cWorld
function GenerateEndPlatformOnEntityChangingWorld(Entity, World)
    local SpawnPos = World:GetSpawnPos()
    local hasBeenGenerated = SpawnPos:EqualsEps(Vector3i(100,50,0),0.001)
    if not hasBeenGenerated then
        World:SetSpawn(100,50,0)
    end
    if World:GetDimension() ~= dimEnd then
        return
    end
    World:ChunkStay(
    {{6,0},{6,-1}},nil,
    function ()
        for x = 98, 102 do
            for y = 49, 51 do
                for z = -2, 2 do
                    if hasBeenGenerated then
                        World:DropBlockAsPickups(Vector3i(x,y,z))
                    else
                        World:SetBlock(Vector3i(x,y,z),0,0)
                    end
                end
            end
        end
        for x = 98, 102 do
            for z = -2, 2 do
                if World:GetBlock(Vector3i(x,48,z)) ~= E_BLOCK_OBSIDIAN then
                    if hasBeenGenerated then
                        World:DropBlockAsPickups(Vector3i(x,y,48))
                    end
                    World:SetBlock(Vector3i(x,48,z),E_BLOCK_OBSIDIAN,0)
                end
            end
        end
        Entity:TeleportToCoords(100.5,50,0.5)
    end
    )
end

