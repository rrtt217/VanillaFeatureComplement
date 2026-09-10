-- Enable zooming out on the in-game map when using a crafting table

---Largest scale a map can be zoomed out to. Vanilla's map-extending recipe
---refuses to match beyond it, so the plugin does too.
local MAX_MAP_SCALE = 4

---Lore line marking a crafted item whose map still has to be zoomed out by the
---tick handler. Only used when the server cannot create a new map (see
---BuildZoomedOutMap).
local ZOOM_OUT_LORE = "This map is waiting to be zoomed out by a plugin."

---Find the map a filled-map item refers to, in any world (maps belong to the
---world they were created in). Returns nil when no such map exists.
---@param MapID number  the item's m_ItemDamage, which is the map's id
---@return cMap|nil
local function GetMapByID(MapID)
    local Found = nil
    cRoot:Get():ForEachWorld(
        ---@param World cWorld
        function(World)
            World:GetMapManager():DoWithMap(
                MapID,
                ---@param Map cMap
                function(Map)
                    Found = Map
                end)
        end)
    return Found
end

---Read the whole pixel grid of a map.
---@param Map cMap
---@return table  Snapshot[x][z] = colour id
local function SnapshotPixels(Map)
    local Width, Height = Map:GetWidth(), Map:GetHeight()
    local Snapshot = {}
    for x = 0, Width - 1 do
        local Column = {}
        for z = 0, Height - 1 do
            Column[z] = Map:GetPixel(x, z)
        end
        Snapshot[x] = Column
    end
    return Snapshot
end

---Draw a snapshot onto a map that covers twice the world area (scale + 1).
---
---cMap maps pixel (x, z) to the world block
---    (CenterX + (x - Width / 2) * 2^scale, CenterZ + (z - Height / 2) * 2^scale)
---(see cMap::UpdatePixel), so one pixel of the old map covers exactly the area of
---a 2x2 block of pixels on the zoomed-out map. Sampling the top-left pixel of every
---such block therefore keeps the picture aligned with the world: it shrinks into
---the central half of the new map, and the outer ring stays blank until it is
---explored -- which is what vanilla shows after zooming out. Wiping the map instead
---(the previous behaviour) threw the picture away for every area the holder does
---not stand in, because Cuberite only re-renders a 128 block radius around a player
---holding the map (cInventory::UpdateItems -> cItemMapHandler::OnUpdate ->
---cMap::UpdateRadius).
---@param Snapshot table  as returned by SnapshotPixels
---@param Target cMap      map at one scale above the snapshot
local function DrawZoomedOutPixels(Snapshot, Target)
    local Width, Height = Target:GetWidth(), Target:GetHeight()
    for x = 0, Width - 1 do
        for z = 0, Height - 1 do
            Target:SetPixel(x, z, cMap.E_BASE_COLOR_TRANSPARENT)
        end
    end
    local OffsetX, OffsetZ = math.floor(Width / 4), math.floor(Height / 4)
    for x = 0, Width - 2, 2 do
        for z = 0, Height - 2, 2 do
            local Colour = Snapshot[x] and Snapshot[x][z]
            if Colour and (Colour ~= cMap.E_BASE_COLOR_TRANSPARENT) then
                Target:SetPixel(OffsetX + math.floor(x / 2), OffsetZ + math.floor(z / 2), Colour)
            end
        end
    end
end

---Build the item the zoom-out recipe should hand out.
---
---Vanilla gives out a NEW map: the result has its own map id and its own copy of
---the picture, so the original map -- and every other copy of it in the world --
---keeps its scale and its data. That needs cMapManager::CreateMap, which upstream
---exposes to Lua only as DoWithMap, so on an unpatched server this returns nil and
---the caller falls back to zooming the original map in place.
---@param Map cMap  the original map, at a scale below MAX_MAP_SCALE
---@return cItem|nil
local function BuildZoomedOutMap(Map)
    local MapManager = Map:GetWorld():GetMapManager()
    if not MapManager.CreateMap then
        return nil
    end
    local NewMap = MapManager:CreateMap(Map:GetCenterX(), Map:GetCenterZ(), Map:GetScale() + 1)
    if not NewMap then
        return nil
    end
    DrawZoomedOutPixels(SnapshotPixels(Map), NewMap)
    return cItem(E_ITEM_MAP, 1, NewMap:GetID())
end

---@param Player cPlayer
---@param Grid cCraftingGrid
---@param Recipe cCraftingRecipe
function MapZoomoutOnCraftingNoRecipe(Player, Grid, Recipe)
    local Item = cItem()
    if Grid:GetWidth() < 3 or Grid:GetHeight() < 3 then
        -- Not enough space for the recipe.
        return false
    end
    for x = 0, 2 do
        for y = 0, 2 do
            Item = Grid:GetItem(x, y)
            -- Anywhere except the center must be a paper to allow map zooming out
            if Item.m_ItemType ~= E_ITEM_PAPER and x ~= 1 and y ~= 1 then
                return false
            end
            if x == 1 and y == 1 then
                -- The center must be a filled map
                if Item.m_ItemType ~= E_ITEM_MAP then
                    return false
                end
            end
        end
    end

    local MapItem = Grid:GetItem(1, 1)
    local Map = GetMapByID(MapItem.m_ItemDamage)
    if (Map == nil) or (Map:GetScale() >= MAX_MAP_SCALE) then
        -- Unknown map, or already zoomed out as far as maps go: no recipe.
        return false
    end

    -- Set the recipe result.
    for x = 0, 2 do
        for y = 0, 2 do
            if x == 1 and y == 1 then
                Recipe:SetIngredient(x, y, MapItem:CopyOne())
            else
                Recipe:SetIngredient(x, y, cItem(E_ITEM_PAPER))
            end
        end
    end

    local Result = BuildZoomedOutMap(Map)
    if Result == nil then
        -- No way to create a new map on this server: zoom the original map in place
        -- on the next tick instead, marking the crafted item so the tick handler can
        -- find it again (the item is the only thing the crafting hook can hand over).
        Result = MapItem:CopyOne()
        local Lore = Result.m_LoreTable
        table.insert(Lore, ZOOM_OUT_LORE)
        Result.m_LoreTable = Lore
        GetPlayerState(Player).CheckZoomOut = true
    end
    Recipe:SetResult(Result)
    return true
end

---Zoom a map out in place, keeping the picture it already has.
---@param Map cMap
function ZoomOutMap(Map)
    if not Map then
        return
    end
    local Scale = Map:GetScale()
    if Scale >= MAX_MAP_SCALE then
        return
    end
    -- Snapshot first: SetScale only reinterprets the very same pixel buffer, so
    -- the old picture has to be read while it is still aligned with the world.
    local Snapshot = SnapshotPixels(Map)
    -- SetScale just zooms out the map.
    Map:SetScale(Scale + 1)
    DrawZoomedOutPixels(Snapshot, Map)
end

---@param World cWorld
---@param TimeDelta number
---@param LastTickDurationMSec number
function CheckForZoomOutMapOnTick(World, TimeDelta, LastTickDurationMSec)
    World:ForEachPlayer(
        ---@param Player cPlayer
        function (Player)
            local State = GetPlayerState(Player)
            if not State.CheckZoomOut then
                return
            end
            local inventory = Player:GetInventory()
            for i = cInventory.invInventoryOffset, cInventory.invShieldOffset do
                local item = cItem(inventory:GetSlot(i))
                if item.m_ItemType == E_ITEM_MAP and item.m_LoreTable then
                    local loretable = item.m_LoreTable
                    local match = false
                    for j = #loretable, 1 ,-1 do
                        if loretable[j] == ZOOM_OUT_LORE then
                            -- Reference: https://github.com/cuberite/cuberite/blob/master/src/Items/ItemEmptyMap.h#L51
                            -- the damage value of the map item is NewMap->GetID() & 0x7fff. In short range 0-32767, it equals to MapID.
                            -- Now zooming out the map, as the recipe itself could not.
                            ZoomOutMap(GetMapByID(item.m_ItemDamage))
                            match = true
                            -- removes the lore.
                            table.remove(loretable,j)
                        end
                    end
                    if match then
                        item.m_LoreTable = loretable
                        inventory:SetSlot(i,item)
                        State.CheckZoomOut = false
                    end
                end
            end
        end
    )
end
