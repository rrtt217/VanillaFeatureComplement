-- Enable cloning the map with a craft table.
--
-- Vanilla Minecraft implements map cloning as a shapeless recipe: exactly ONE
-- filled map plus 1..8 empty maps (any arrangement, stacks allowed; the grid
-- itself bounds the count - a 2x2 grid fits 1, a 3x3 grid fits 8). The result
-- is one filled map per empty map plus the original, all sharing the source
-- map's data, so every copy stays in sync as the world is explored.
--
---@param Player cPlayer
---@param Grid cCraftingGrid
---@param Recipe cCraftingRecipe
function MapCloningOnCraftingNoRecipe(Player, Grid, Recipe)
    local Width = Grid:GetWidth()
    local Height = Grid:GetHeight()

    local MapPos = nil       -- grid position of the single filled map
    local EmptyCount = 0     -- total number of empty maps (sum of stack counts)

    -- Scan the grid: exactly one filled map, at least one empty map and nothing
    -- else. Unlike the old code this does not require adjacency, matching the
    -- vanilla shapeless recipe (place the empty maps anywhere around/next to it).
    for x = 0, Width - 1 do
        for y = 0, Height - 1 do
            local Item = Grid:GetItem(x, y)
            local ItemType = Item.m_ItemType
            if ItemType == E_ITEM_EMPTY_MAP then
                EmptyCount = EmptyCount + Item.m_ItemCount
            elseif ItemType == E_ITEM_MAP then
                if (MapPos ~= nil) or (Item.m_ItemCount ~= 1) then
                    -- More than one filled map (or a stack of them): not cloning.
                    return false
                end
                MapPos = { x = x, y = y }
            elseif not Item:IsEmpty() then
                -- Anything else means this is not the cloning recipe.
                return false
            end
        end
    end

    -- Need exactly one filled map and at least one empty map.
    if (MapPos == nil) or (EmptyCount < 1) then
        return false
    end

    -- Fill in the recipe. Ingredients are the map and every empty map; the full
    -- slot stack is listed so ConsumeIngredients consumes all of it (CopyOne
    -- would leave stacked empty maps behind).
    Recipe:SetIngredient(MapPos.x, MapPos.y, Grid:GetItem(MapPos.x, MapPos.y):CopyOne())
    for x = 0, Width - 1 do
        for y = 0, Height - 1 do
            local Item = Grid:GetItem(x, y)
            if Item.m_ItemType == E_ITEM_EMPTY_MAP then
                Recipe:SetIngredient(x, y, Item)
            end
        end
    end

    -- Result: one copy per empty map plus the original, all sharing the map data.
    Recipe:SetResult(Grid:GetItem(MapPos.x, MapPos.y):CopyOne():AddCount(EmptyCount))

    -- Return true so Cuberite applies the recipe we just filled (see OnCraftingNoRecipe
    -- docs: returning false/nil means "no recipe will be used").
    return true
end