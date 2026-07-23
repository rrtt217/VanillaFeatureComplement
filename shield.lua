-- Shield usage tracking with event batching.
--
-- Cuberite has no dedicated shield hook. Shields go through the generic item-use
-- path in cClientHandle::HandleRightClick (the ItemUseable branch):
--     CallHookPlayerUsingItem  ->  ItemHandler::OnItemUse  ->  CallHookPlayerUsedItem
-- All three happen in the SAME tick, on the tick the client pressed right-click.
-- HOOK_PLAYER_USING_ITEM is the "shield raised" signal, and HOOK_PLAYER_SHOOTING
-- is the "shield released" signal (it fires both when a bow is shot AND when a
-- raised shield is lowered). There is no per-tick firing.
--
-- A single IsUsingShield flag is used: the player has only one shield state,
-- and shield behavior is independent of which hand holds it. Vanilla raises the
-- main-hand shield first if both hands hold shields.
--
-- Bucket items produce MULTIPLE USING_ITEM/USED_ITEM events per right-click
-- (some targeting the clicked block, some targeting air at (-1,255,-1)). To
-- handle this, events for "conditional" items (buckets, flint-and-steel,
-- firework) are batched per tick and evaluated in HOOK_TICK of the next tick.
-- Additionally, USED_ITEM checks whether the equipped item type changed (e.g.
-- bucket -> water_bucket) to detect successful consumption that the event
-- position alone can't reveal (e.g. scooping a shallow fluid with no block in
-- reach produces only an air event, but the bucket IS consumed).

---Items that unconditionally consume the right-click and so never raise the
---shield when held in the main hand.
local ProjectileItems =
{
    [E_ITEM_SNOWBALL] = true,
    [E_ITEM_EGG] = true,
    [E_ITEM_ENDER_PEARL] = true,
    [E_ITEM_EYE_OF_ENDER] = true,
    [E_ITEM_FIRE_CHARGE] = true,
    [E_ITEM_SPLASH_POTION] = true,
    [E_ITEM_BOTTLE_O_ENCHANTING] = true,
}

---All boat variants. Same logic as the empty bucket: consumed only against a
---fluid (they are placed on water).
local BoatItems =
{
    [E_ITEM_BOAT] = true,
    [E_ITEM_SPRUCE_BOAT] = true,
    [E_ITEM_BIRCH_BOAT] = true,
    [E_ITEM_JUNGLE_BOAT] = true,
    [E_ITEM_ACACIA_BOAT] = true,
    [E_ITEM_DARK_OAK_BOAT] = true,
}

---All minecart variants. Consumed only when placed on a rail.
local MinecartItems =
{
    [E_ITEM_MINECART] = true,
    [E_ITEM_CHEST_MINECART] = true,
    [E_ITEM_FURNACE_MINECART] = true,
    [E_ITEM_MINECART_WITH_TNT] = true,
    [E_ITEM_MINECART_WITH_HOPPER] = true,
}

---Whether the block at the given coords is a rail (any variant).
---@param World cWorld
---@param BlockX number
---@param BlockY number
---@param BlockZ number
---@return boolean
local function IsRail(World, BlockX, BlockY, BlockZ)
    local BlockType = World:GetBlock(Vector3i(BlockX, BlockY, BlockZ))
    return BlockType == E_BLOCK_RAIL
        or BlockType == E_BLOCK_POWERED_RAIL
        or BlockType == E_BLOCK_DETECTOR_RAIL
        or BlockType == E_BLOCK_ACTIVATOR_RAIL
end

---Items whose consumption depends on the target block / state. These are
---batched per tick and evaluated together, because a single right-click can
---produce multiple USING_ITEM events (some targeting air).
local ConditionalItems =
{
    [E_ITEM_BUCKET] = true,
    [E_ITEM_WATER_BUCKET] = true,
    [E_ITEM_LAVA_BUCKET] = true,
    [E_ITEM_FLINT_AND_STEEL] = true,
    [E_ITEM_FIREWORK_ROCKET] = true,
}

---Whether the block at the given coords is a fluid (water / lava, flowing or
---still). Returns true for fluids, false for anything else (including air).
---@param World cWorld
---@param BlockX number
---@param BlockY number
---@param BlockZ number
---@return boolean
local function IsFluid(World, BlockX, BlockY, BlockZ)
    local BlockType = World:GetBlock(Vector3i(BlockX, BlockY, BlockZ))
    return BlockType == E_BLOCK_WATER
        or BlockType == E_BLOCK_STATIONARY_WATER
        or BlockType == E_BLOCK_LAVA
        or BlockType == E_BLOCK_STATIONARY_LAVA
end

---Whether the block at the given coords is a non-fluid, non-air solid surface.
---@param World cWorld
---@param BlockX number
---@param BlockY number
---@param BlockZ number
---@return boolean
local function IsSolidSurface(World, BlockX, BlockY, BlockZ)
    local BlockType = World:GetBlock(Vector3i(BlockX, BlockY, BlockZ))
    return BlockType ~= E_BLOCK_AIR and not IsFluid(World, BlockX, BlockY, BlockZ)
end

---Whether a single USING_ITEM event indicates the main-hand item was consumed.
---For conditional items this is a per-event guess; the final decision is made
---by combining all events of the tick (see EvaluateBatch).
---@param Player cPlayer
---@param Type number  item type at the time of the event
---@param BlockX number
---@param BlockY number
---@param BlockZ number
---@return boolean consumed, boolean definitive  (definitive=false => needs batching)
local function EvaluateEvent(Player, Type, BlockX, BlockY, BlockZ)
    if ProjectileItems[Type] then
        return true, true
    end
    if Type == E_ITEM_FISHING_ROD then
        return true, true
    end
    if Type == E_ITEM_BOW then
        return Player:IsGameModeCreative() or Player:GetInventory():HasItems(cItem(E_ITEM_ARROW)), true
    end

    local IsAirUse = (BlockX == -1 and BlockY == 255 and BlockZ == -1)

    -- The `Consumed` property for bucket interaction events is not precise. We do not actually rely on it though.
    if Type == E_ITEM_WATER_BUCKET or Type == E_ITEM_LAVA_BUCKET then
        -- Placing fluid: consumed only against a solid surface.
        if IsAirUse then
            return false, false
        end
        return IsSolidSurface(Player:GetWorld(), BlockX, BlockY, BlockZ), false
    end
    if Type == E_ITEM_BUCKET then
        -- Scooping: consumed only against a fluid.
        if IsAirUse then
            return false, false
        end
        return IsFluid(Player:GetWorld(), BlockX, BlockY, BlockZ), false
    end
    if BoatItems[Type] then
        -- Boats: same logic as the empty bucket -- placed on a fluid.
        if IsAirUse then
            return false, false
        end
        return IsFluid(Player:GetWorld(), BlockX, BlockY, BlockZ), false
    end
    if MinecartItems[Type] then
        -- Minecarts: consumed only when placed on a rail; definitive either way.
        if IsAirUse then
            return false, true
        end
        return IsRail(Player:GetWorld(), BlockX, BlockY, BlockZ), true
    end
    if Type == E_ITEM_SPAWN_EGG then
        -- Spawn egg: consumed against a solid block. Against a non-solid block
        -- (fluid / air) the server can't tell, so default to consumed.
        if IsAirUse then
            return true, true
        end
        local BlockType = Player:GetWorld():GetBlock(Vector3i(BlockX, BlockY, BlockZ))
        if BlockType == E_BLOCK_AIR or IsFluid(Player:GetWorld(), BlockX, BlockY, BlockZ) then
            return true, true
        end
        return true, true
    end
    if Type == E_ITEM_FLINT_AND_STEEL then
        if IsAirUse then
            return false, false
        end
        return IsSolidSurface(Player:GetWorld(), BlockX, BlockY, BlockZ), true
    end
    if Type == E_ITEM_FIREWORK_ROCKET then
        if Player:IsElytraFlying() then
            return true, true
        end
        if IsAirUse then
            return false, false
        end
        return IsSolidSurface(Player:GetWorld(), BlockX, BlockY, BlockZ), true
    end

    return false, true
end

---Combine all batched events for a player in a tick to decide whether the
---main-hand item was consumed. If any event is definitively consumed, the
---item was used. Otherwise fall back to checking whether the equipped item
---type changed since the batch started (e.g. bucket -> water_bucket), which
---catches the "scoop shallow fluid with no block in reach" case that produces
---only air events but still consumes the bucket.
---@param Player cPlayer
---@return boolean
local function EvaluateBatch(Player)
    local Batch = Player.ShieldBatch
    if not Batch or #Batch == 0 then
        return false
    end

    --- Typical empty bucket right clicking a solid block without a fluid in reach produces 4 USING_ITEM events:
    if #Batch >= 3 then
        return false
    end

    --- Typical empty bucket right clicking fluids without reaching a solid block produces 1 USING_ITEM events:
    if #Batch == 1 then
        return true
    end

    --- Typical empty bucket right clicking a shallow fluid with solid block in reach produces 2 USING_ITEM events, not all of their position are (-1,255,-1):
    --- Typical water/lava bucket placing fluids on a solid block produces 2 USING_ITEM events, not all of their position are (-1,255,-1):
    --- Typical bucket-air interactions produces 2 USING_ITEM events, all of their position are (-1,255,-1):
    if #Batch == 2 then
        local Ev1 = Batch[1]
        local Ev2 = Batch[2]
        if Ev1.BlockX == -1 and Ev1.BlockY == 255 and Ev1.BlockZ == -1 and
           Ev2.BlockX == -1 and Ev2.BlockY == 255 and Ev2.BlockZ == -1 then
            return false
        else
            return true
        end
    end

    return false
end

---Whether the item is a shield.
---@param ItemType number
---@return boolean
local function IsShield(ItemType)
    return ItemType == E_ITEM_SHIELD
end

---Raise the shield (only on the false -> true transition).
---@param Player cPlayer
local function RaiseShield(Player)
    if not Player.IsUsingShield then
        Player.IsUsingShield = true
        LOG("Player " .. Player:GetName() .. " used a shield!")
    end
end

---Lower the shield (only on the true -> false transition).
---@param Player cPlayer
local function ReleaseShield(Player)
    if Player.IsUsingShield then
        Player.IsUsingShield = false
        LOG("Player " .. Player:GetName() .. " released a shield!")
    end
end

-- HOOK_PLAYER_USING_ITEM: the "shield raised" signal, fired on the tick the
-- client pressed right-click. For unconditional items (projectiles, fishing
-- rod, bow) the decision is immediate. For conditional items (buckets, flint,
-- firework) the event is recorded in a per-tick batch and evaluated in the next
-- tick's HOOK_TICK, so all events of the same right-click are combined.
function CheckUseShieldOnUsingItem(Player, BlockX, BlockY, BlockZ, BlockFace, CursorX, CursorY, CursorZ)
    local Item = Player:GetEquippedItem()
    local ItemOffhand = Player:GetOffHandEquipedItem()
    LOG("Player " .. Player:GetName() .. " using item".. Item.m_ItemType .. "and" .. ItemOffhand.m_ItemType .. " at block " .. BlockX .. "," .. BlockY .. "," .. BlockZ ..
        " cursor " .. CursorX .. "," .. CursorY .. "," .. CursorZ)

    if Item and IsShield(Item.m_ItemType) then
        -- Main hand is a shield: it always raises (shields are not blacklisted).
        RaiseShield(Player)
        return
    end

    if not (ItemOffhand and IsShield(ItemOffhand.m_ItemType)) then
        return
    end

    -- Offhand shield: depends on whether the main-hand item is consumed.
    if not Item or Item:IsEmpty() then
        RaiseShield(Player)
        return
    end

    local Type = Item.m_ItemType
    local Consumed, Definitive = EvaluateEvent(Player, Type, BlockX, BlockY, BlockZ)

    if Definitive then
        if not Consumed then
            RaiseShield(Player)
        end
        return
    end

    -- Conditional, non-definitive event: batch it for the next tick.
    local WorldAge = Player:GetWorld():GetWorldAge()

    if not Player.ShieldBatch or Player.ShieldBatchTick ~= WorldAge then
        Player.ShieldBatch = {}
        Player.ShieldBatchTick = WorldAge
        Player.ShieldBatchItemType = Type
    end
    table.insert(Player.ShieldBatch, {
        Consumed = Consumed,
        Definitive = Definitive,
        ItemType = Type,
        BlockX = BlockX,
        BlockY = BlockY,
        BlockZ = BlockZ,
        CursorX = CursorX,
        CursorY = CursorY,
        CursorZ = CursorZ,
        WorldAge = WorldAge,
    })
    LOG("Player " .. Player:GetName() .. " batched event #" .. #Player.ShieldBatch ..
        " at worldage " .. WorldAge ..
        " type " .. Type ..
        " consumed=" .. tostring(Consumed) ..
        " definitive=" .. tostring(Definitive) ..
        " block " .. BlockX .. "," .. BlockY .. "," .. BlockZ ..
        " cursor " .. CursorX .. "," .. CursorY .. "," .. CursorZ)
end

-- HOOK_TICK: process any pending shield batch from the previous tick. If the
-- main-hand item was not consumed across all batched events, raise the shield.
function CheckUseShieldOnTick(TimeDelta)
    cRoot:Get():ForEachPlayer(
        ---@param Player cPlayer
        function(Player)
            local Batch = Player.ShieldBatch
            if not Batch or #Batch == 0 then
                return
            end
            -- Only process batches from a previous tick; same-tick batches are
            -- still being collected.
            local WorldAge = Player:GetWorld():GetWorldAge()
            if Player.ShieldBatchTick == WorldAge then
                return
            end

            local Name = Player:GetName()
            LOG("Player " .. Name .. " evaluating batch of " .. #Batch ..
                " event(s) from worldage " .. Player.ShieldBatchTick ..
                " (now " .. WorldAge .. ")")
            for i, Ev in ipairs(Batch) do
                LOG("  event #" .. i ..
                    " type " .. Ev.ItemType ..
                    " consumed=" .. tostring(Ev.Consumed) ..
                    " definitive=" .. tostring(Ev.Definitive) ..
                    " block " .. Ev.BlockX .. "," .. Ev.BlockY .. "," .. Ev.BlockZ ..
                    " cursor " .. Ev.CursorX .. "," .. Ev.CursorY .. "," .. Ev.CursorZ ..
                    " worldage " .. Ev.WorldAge)
            end

            local Consumed = EvaluateBatch(Player)
            local CurrentType = Player:GetEquippedItem().m_ItemType
            LOG("Player " .. Name .. " batch result: consumed=" .. tostring(Consumed) ..
                " batchItemType=" .. Player.ShieldBatchItemType ..
                " currentItemType=" .. CurrentType)

            if not Consumed then
                RaiseShield(Player)
            end
            Player.ShieldBatch = nil
        end
    )
end

-- HOOK_PLAYER_SHOOTING: the "shield released" signal. Fires both when a bow is
-- shot and when a raised shield is lowered (same SHOOT status packet), so this
-- is the reliable release event.
function CheckUseShieldOnShooting(Player)
    ReleaseShield(Player)
end

-- HOOK_PLAYER_TOSSING_ITEM: dropping the held item. Only release if the dropped
-- item was the shield currently being held up, or if neither hand holds a
-- shield anymore (the shield got moved away). Dropping a normal item does NOT
-- release the shield.
function CheckUseShieldOnTossingItem(Player)
    local Item = Player:GetEquippedItem()
    local ItemOffhand = Player:GetOffHandEquipedItem()
    local MainIsShield = Item and IsShield(Item.m_ItemType)
    local OffIsShield = ItemOffhand and IsShield(ItemOffhand.m_ItemType)
    -- If the player just dropped their raised shield, or no shield remains in
    -- either hand, lower the state. Otherwise keep it (e.g. tossed a sword
    -- while blocking with an offhand shield).
    if not MainIsShield and not OffIsShield then
        ReleaseShield(Player)
    end
end

-- Reject offhand interactions the server would silently drop. Cuberite forces
-- a_UsedMainHand = true in HandleRightClick, so an offhand right-click on a
-- block is processed as the (empty) main hand and the server does nothing.
-- Returning true cancels the packet so the client does not play an animation
-- the server ignores (e.g. raising an offhand shield that never raises).
function CheckUseShieldOnRightClick(Player, BlockX, BlockY, BlockZ, BlockFace, CursorX, CursorY, CursorZ)
    local ItemOffhand = Player:GetOffHandEquipedItem()
    if ItemOffhand and not ItemOffhand:IsEmpty() then
        local Item = Player:GetEquippedItem()
        -- Only block when the main hand is empty: that is the case where vanilla
        -- would defer to the offhand but Cuberite silently drops it. If the main
        -- hand holds a placeable/usable item the server already handles it via
        -- the main hand, so the offhand click is a harmless no-op.
        if Item and Item:IsEmpty() then
            return true
        end
    end
end