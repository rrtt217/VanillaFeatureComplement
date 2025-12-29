-- Enable cloning the map with a craft table.
---@param Player cPlayer
---@param Grid cCraftingGrid
---@param Recipe cCraftingRecipe
function MapCloningOnCraftingNoRecipe(Player, Grid, Recipe)
    local Item = cItem()
    local map_pos = {x = -1,y = -1}
    local empty_map_pos = {x = -1,y = -1}
    local width = Grid:GetWidth()
    local height = Grid:GetHeight()
    for x = 0, (width - 1) do
        for y = 0, (height - 1) do
            Item = Grid:GetItem(x,y)
            if Item.m_ItemType == E_ITEM_EMPTY_MAP then
                if x < width - 1 and Grid:GetItem(x+1,y).m_ItemType == E_ITEM_MAP then
                    map_pos = {x = x + 1,y = y}
                    empty_map_pos = {x = x,y = y}
                    break
                elseif y < height - 1 and Grid:GetItem(x,y+1).m_ItemType == E_ITEM_MAP then
                    map_pos = {x = x,y = y + 1}
                    empty_map_pos = {x = x,y = y}
                    break
                end
            elseif Item.m_ItemType == E_ITEM_MAP then
                if x < width - 1 and Grid:GetItem(x+1,y).m_ItemType == E_ITEM_EMPTY_MAP then
                    empty_map_pos = {x = x + 1,y = y}
                    map_pos = {x = x,y = y}
                    break
                elseif y < height - 1 and Grid:GetItem(x,y+1).m_ItemType == E_ITEM_EMPTY_MAP then
                    empty_map_pos = {x = x,y = y + 1}
                    map_pos = {x = x,y = y}
                    break
                end
            end
        end
    end
    -- no match
    if map_pos.x < 0 then
        return false
    end
    -- excess items in grid
    for x = 0, (width - 1) do
        for y = 0, (height - 1) do
            if (x ~= map_pos.x or y ~= map_pos.y ) and (x ~= empty_map_pos.x and y ~= empty_map_pos.y) and not Grid:GetItem(x,y):IsEmpty() then
                return false
            end
        end
    end
    Recipe:SetIngredient(map_pos.x,map_pos.y,Grid:GetItem(map_pos.x,map_pos.y):CopyOne())
    Recipe:SetIngredient(empty_map_pos.x,empty_map_pos.y,Grid:GetItem(empty_map_pos.x,empty_map_pos.y):CopyOne())
    Recipe:SetResult(Grid:GetItem(map_pos.x,map_pos.y):CopyOne():AddCount(1))
end