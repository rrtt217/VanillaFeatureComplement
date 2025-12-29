-- Enable zooming out on the in-game map when using a crafting table
-- Due to the limitation of the lua plugin, you don't need to actually finish the crafting process to zoom out the map.
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
    -- All checks passed, zoom out the map
    local MapItem = Grid:GetItem(1, 1)
    -- Reference: https://github.com/cuberite/cuberite/blob/master/src/Items/ItemEmptyMap.h#L51
    -- the damage value of the map item is NewMap->GetID() & 0x7fff. In short range 0-32767, it equals to MapID.
    -- Now setting up callback to zoom out the map.
    cRoot:Get():ForEachWorld(
    ---@param World cWorld
    function (World)
        World:GetMapManager():DoWithMap(MapItem.m_ItemDamage,ZoomOutMap)
    end)
    -- Set the recipe result.
    for x = 0, 2 do
        for y = 0, 2 do
            if x == 1 and y == 1 then 
                Recipe:SetIngredient(x,y,MapItem:CopyOne())
            else
                Recipe:SetIngredient(x,y,cItem(E_ITEM_PAPER))
            end
        end
    end
    Recipe:SetResult(MapItem:CopyOne())
    -- It seems that this doesn't work.
    Recipe:ConsumeIngredients(Grid)
    return true
end

---@param Map cMap
function ZoomOutMap(Map)
    if not Map then
        return
    end
    if Map:GetScale() < 4 then
        -- SetScale just zooms out the map.
        Map:SetScale(Map:GetScale() + 1)
        -- Wipe the map data
        for x = 0, Map:GetWidth() - 1 do
            for y = 0, Map:GetHeight() - 1 do
                Map:SetPixel(x,y,Map.E_BASE_COLOR_TRANSPARENT)
            end
        end
        -- Now all set.
    end
end
