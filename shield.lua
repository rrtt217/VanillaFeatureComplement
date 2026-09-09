-- Shield usage tracking.
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
-- (some targeting the clicked block, some targeting air at (-1,255,-1)). Each
-- event is resolved independently: when the reported coords are an air use,
-- GetTargetedBlock re-traces the player's eye ray to recover the real targeted
-- block, so the consumed/not-consumed decision is reliable per-event and no
-- cross-event batching is needed.

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

---All hoe variants. Consumed when tilling grass / dirt into farmland.
local HoeItems =
{
    [E_ITEM_WOODEN_HOE] = true,
    [E_ITEM_STONE_HOE] = true,
    [E_ITEM_IRON_HOE] = true,
    [E_ITEM_GOLD_HOE] = true,
    [E_ITEM_DIAMOND_HOE] = true,
}

---All shovel variants. Consumed when flattening grass / dirt into grass path.
local ShovelItems =
{
    [E_ITEM_WOODEN_SHOVEL] = true,
    [E_ITEM_STONE_SHOVEL] = true,
    [E_ITEM_IRON_SHOVEL] = true,
    [E_ITEM_GOLD_SHOVEL] = true,
    [E_ITEM_DIAMOND_SHOVEL] = true,
}

---Helmet items (including leather cap). Equipped in the helmet slot.
local HelmetItems =
{
    [E_ITEM_LEATHER_CAP] = true,
    [E_ITEM_GOLD_HELMET] = true,
    [E_ITEM_CHAIN_HELMET] = true,
    [E_ITEM_IRON_HELMET] = true,
    [E_ITEM_DIAMOND_HELMET] = true,
}

---Chestplate items (including elytra). Equipped in the chestplate slot.
local ChestplateItems =
{
    [E_ITEM_LEATHER_TUNIC] = true,
    [E_ITEM_GOLD_CHESTPLATE] = true,
    [E_ITEM_CHAIN_CHESTPLATE] = true,
    [E_ITEM_IRON_CHESTPLATE] = true,
    [E_ITEM_DIAMOND_CHESTPLATE] = true,
    [E_ITEM_ELYTRA] = true,
}

---Leggings items. Equipped in the leggings slot.
local LeggingsItems =
{
    [E_ITEM_LEATHER_PANTS] = true,
    [E_ITEM_GOLD_LEGGINGS] = true,
    [E_ITEM_CHAIN_LEGGINGS] = true,
    [E_ITEM_IRON_LEGGINGS] = true,
    [E_ITEM_DIAMOND_LEGGINGS] = true,
}

---Boots items. Equipped in the boots slot.
local BootsItems =
{
    [E_ITEM_LEATHER_BOOTS] = true,
    [E_ITEM_GOLD_BOOTS] = true,
    [E_ITEM_CHAIN_BOOTS] = true,
    [E_ITEM_IRON_BOOTS] = true,
    [E_ITEM_DIAMOND_BOOTS] = true,
}

---All food items. In Cuberite, food (cItemFoodHandler descendants, which
---override IsFood() to true) cannot be used at all in creative mode --
---HandleUseItem returns early before StartEating / HOOK_PLAYER_USING_ITEM,
---so these never reach us in creative. In survival they are consumed only
---when the player is hungry (not satiated).
---
---Golden apple and chorus fruit are EXCLUDED from this table: Cuberite's
---HandleUseItem special-cases them so they bypass the creative/satiated
---guard and are still eaten in creative mode (see SpecialFoodItems).
local FoodItems =
{
    [E_ITEM_RED_APPLE] = true,
    [E_ITEM_BREAD] = true,
    [E_ITEM_RAW_PORKCHOP] = true,
    [E_ITEM_COOKED_PORKCHOP] = true,
    [E_ITEM_RAW_FISH] = true,
    [E_ITEM_COOKED_FISH] = true,
    [E_ITEM_RAW_BEEF] = true,
    [E_ITEM_STEAK] = true,
    [E_ITEM_RAW_CHICKEN] = true,
    [E_ITEM_COOKED_CHICKEN] = true,
    [E_ITEM_ROTTEN_FLESH] = true,
    [E_ITEM_RAW_MUTTON] = true,
    [E_ITEM_COOKED_MUTTON] = true,
    [E_ITEM_RAW_RABBIT] = true,
    [E_ITEM_COOKED_RABBIT] = true,
    [E_ITEM_RABBIT_STEW] = true,
    [E_ITEM_BEETROOT] = true,
    [E_ITEM_BEETROOT_SOUP] = true,
    [E_ITEM_CARROT] = true,
    [E_ITEM_BAKED_POTATO] = true,
    [E_ITEM_POISONOUS_POTATO] = true,
    [E_ITEM_PUMPKIN_PIE] = true,
    [E_ITEM_MELON_SLICE] = true,
    [E_ITEM_SPIDER_EYE] = true,
    [E_ITEM_COOKIE] = true,
}

---Special food items (golden apple, chorus fruit). Cuberite's HandleUseItem
---special-cases these so they bypass the creative-mode / satiated guard that
---blocks normal food -- they are still eaten in creative mode. The client,
---however, does not play the eating animation in creative, so it treats the
---right-click as empty and would raise the shield. Since the server actually
---processes the eat (effects applied, chorus fruit teleports), the right-click
---IS consumed and the shield should NOT rise.
local SpecialFoodItems =
{
    [E_ITEM_GOLDEN_APPLE] = true,
    [E_ITEM_CHORUS_FRUIT] = true,
}

---Drinkable items (milk, potion). Unlike food, these are NOT blocked in
---creative mode -- Cuberite routes them through IsDrinkable() rather than
---IsFood(), so HandleUseItem does not apply the creative/satiated guard.
---They are always consumed (the right-click is used up), even though the
---item itself may not be removed from the inventory in creative.
local DrinkableItems =
{
    [E_ITEM_MILK] = true,
    [E_ITEM_POTION] = true,
}

---Whether the given block type is a rail (any variant).
---@param BlockType number
---@return boolean
local function IsRail(BlockType)
    return BlockType == E_BLOCK_RAIL
        or BlockType == E_BLOCK_POWERED_RAIL
        or BlockType == E_BLOCK_DETECTOR_RAIL
        or BlockType == E_BLOCK_ACTIVATOR_RAIL
end

---Whether the given block type is a fluid (water / lava, flowing or still).
---@param BlockType number
---@return boolean
local function IsFluid(BlockType)
    return BlockType == E_BLOCK_WATER
        or BlockType == E_BLOCK_STATIONARY_WATER
        or BlockType == E_BLOCK_LAVA
        or BlockType == E_BLOCK_STATIONARY_LAVA
end

---Whether the given block type is a non-fluid, non-air solid surface.
---@param BlockType number
---@return boolean
local function IsSolidSurface(BlockType)
    return BlockType ~= E_BLOCK_AIR and not IsFluid(BlockType)
end

---The player's default block interaction reach: the maximum line-segment
---distance from the eye to the intersection with a block's outline box.
---This is the segment length from eye to hit point, NOT the distance to the
---block's nearest point.
local PLAYER_REACH = 4.5

---Determine the block the given player is currently interacting with (the
---block their crosshair is aiming at).
---
---Casts a ray from the player's eye along the look direction and returns the
---first non-air block the ray passes through within MaxDistance. If no
---non-air block is hit within MaxDistance, returns E_BLOCK_AIR.
---
---Implementation notes:
---  * cLineBlockTracer:Trace does a DDA traversal that visits blocks in
---    near-to-far order (by ray-wall-crossing coefficient 0 -> 1) and only
---    reports blocks the segment [Start, End] actually passes through. So
---    the first non-air block reported IS the targeted block, and End
---    (= EyePos + Look * MaxDistance) already enforces the distance limit --
---    no manual distance / intersection check is needed.
---  * We cannot use cLineBlockTracer:FirstSolidHitTrace because it uses
---    cBlockInfo::IsSolid(), which treats fluids (water / lava) as
---    non-solid and skips them. Bucket scooping needs to target fluids,
---    so we use Trace with a custom "first non-air" callback instead.
---  * Cuberite's Lua API does not expose the actual block outline boxes
---    (cBlockHandler's collision/outline box interfaces are not exported),
---    so the DDA's full-cube traversal is the best approximation available.
---    For non-full blocks (stairs, slabs, fences, etc.) this is more lenient
---    than vanilla (a ray grazing their air portion still counts as a hit).
---    For this plugin's use case -- deciding whether a right-click with a
---    bucket / flint-and-steel / firework hit a block -- this is sufficient.
---@param Player cPlayer
---@param MaxDistance number?  max interaction distance (segment length), defaults to PLAYER_REACH (4.5)
---@return BLOCKTYPE BlockType  block type (E_BLOCK_AIR if none)
---@return Vector3i|nil BlockPos  block coords (nil if none)
local function GetTargetedBlock(Player, MaxDistance)
    MaxDistance = MaxDistance or PLAYER_REACH
    local World = Player:GetWorld()
    local EyePos = Player:GetEyePosition()
    local Look = Player:GetLookVector()
    Look:Normalize()
    local End = EyePos + Look * MaxDistance

    local Result = { BlockType = E_BLOCK_AIR, BlockPos = nil }

    local Callbacks =
    {
        OnNextBlock = function(BlockPos, BlockType, BlockMeta, EntryFace)
            if BlockType == E_BLOCK_AIR then
                return false  -- Air: keep tracing
            end
            -- First non-air block: the DDA only reports blocks the segment
            -- [EyePos, End] passes through, so this is the targeted block.
            Result.BlockType = BlockType
            Result.BlockPos = BlockPos
            return true  -- Hit, stop tracing
        end,
    }

    cLineBlockTracer:Trace(World, Callbacks, EyePos, End)
    return Result.BlockType, Result.BlockPos
end

---Whether a single USING_ITEM event indicates the main-hand item was consumed.
---
---The event's reported block coords can be (-1,255,-1) ("air use") even when
---the player is actually aiming at a block -- the client sometimes targets air
---for the secondary events of a single right-click. The caller resolves this
---by passing the real targeted block's type: for air-use events it comes from
---GetTargetedBlock (a server-side eye-ray trace), for normal events it comes
---from World:GetBlock at the reported coords. The per-event decision is then
---reliable on its own and no cross-event batching is needed.
---@param Player cPlayer
---@param Type number  item type at the time of the event
---@param BlockType number  block type the player is actually aiming at
---  (E_BLOCK_AIR if nothing is in reach; for air-use events this is the
---   GetTargetedBlock result, for normal events it is World:GetBlock at the
---   reported coords)
---@return boolean consumed, boolean definitive  (definitive=false => caller still raises shield if not consumed)
local function EvaluateEvent(Player, Type, BlockType)
    if ProjectileItems[Type] then
        return true, true
    end
    if Type == E_ITEM_FISHING_ROD then
        return true, true
    end
    if Type == E_ITEM_BOW then
        return Player:IsGameModeCreative() or Player:GetInventory():HasItems(cItem(E_ITEM_ARROW)), true
    end

    -- BlockType == E_BLOCK_AIR means the player is aiming at nothing within
    -- reach (either a real air use, or an air-use event whose eye-ray trace
    -- also found nothing). All block-dependent items below are not consumed
    -- in that case.
    local IsAir = (BlockType == E_BLOCK_AIR)

    -- The `Consumed` property for bucket interaction events is not precise. We do not actually rely on it though.
    if Type == E_ITEM_WATER_BUCKET or Type == E_ITEM_LAVA_BUCKET then
        -- Placing fluid: consumed iff the player's reach contains a solid
        -- block to pour onto. This is NOT the same as "the first non-air
        -- block is solid" -- the player may be aiming through a fluid (e.g.
        -- water covering a stone floor) and still place the fluid on the
        -- solid block beneath. Use FirstSolidHitTrace, which skips fluids
        -- (cBlockInfo::IsSolid returns false for water / lava) and reports
        -- the first solid block within reach, if any.
        local EyePos = Player:GetEyePosition()
        local Look = Player:GetLookVector()
        Look:Normalize()
        local End = EyePos + Look * PLAYER_REACH
        local HasSolid = cLineBlockTracer:FirstSolidHitTrace(Player:GetWorld(), EyePos, End)
        return HasSolid, true
    end
    if Type == E_ITEM_BUCKET then
        -- Scooping: consumed only against a fluid.
        if IsAir then
            return false, true
        end
        return IsFluid(BlockType), true
    end
    if BoatItems[Type] then
        -- Boats: same logic as the empty bucket -- placed on a fluid.
        if IsAir then
            return false, true
        end
        return IsFluid(BlockType), true
    end
    if MinecartItems[Type] then
        -- Minecarts: consumed only when placed on a rail; definitive either way.
        if IsAir then
            return false, true
        end
        return IsRail(BlockType), true
    end
    if HoeItems[Type] or ShovelItems[Type] then
        -- Hoe / shovel: consumed only against grass / dirt; definitive either way.
        if IsAir then
            return false, true
        end
        return BlockType == E_BLOCK_GRASS or BlockType == E_BLOCK_DIRT, true
    end
    if HelmetItems[Type] then
        -- Helmet: consumed only if the helmet slot is empty; definitive.
        return Player:GetEquippedHelmet():IsEmpty(), true
    end
    if ChestplateItems[Type] then
        -- Chestplate / elytra: consumed only if the chestplate slot is empty.
        return Player:GetEquippedChestplate():IsEmpty(), true
    end
    if LeggingsItems[Type] then
        -- Leggings: consumed only if the leggings slot is empty.
        return Player:GetEquippedLeggings():IsEmpty(), true
    end
    if BootsItems[Type] then
        -- Boots: consumed only if the boots slot is empty.
        return Player:GetEquippedBoots():IsEmpty(), true
    end
    if FoodItems[Type] then
        -- Food: in creative mode Cuberite blocks use entirely (HandleUseItem
        -- returns before HOOK_PLAYER_USING_ITEM), so this branch is only
        -- reached in survival / adventure. There, food is consumed only when
        -- the player is hungry (not satiated).
        return not Player:IsSatiated(), true
    end
    if SpecialFoodItems[Type] then
        -- Golden apple / chorus fruit: Cuberite special-cases these so they
        -- are eaten even in creative mode (effects applied, chorus fruit
        -- teleports). The right-click is always consumed, so the shield must
        -- not rise -- even though the client plays no eat animation in
        -- creative and would otherwise treat this as an empty right-click.
        return true, true
    end
    if DrinkableItems[Type] then
        -- Drinkables (milk, potion): usable in all gamemodes, the right-click
        -- is always consumed.
        return true, true
    end
    if Type == E_ITEM_SPAWN_EGG then
        -- Spawn egg: consumed iff it actually spawns a mob, i.e. the player is
        -- aiming at a non-air block (solid or fluid). Aiming at nothing within
        -- reach does NOT consume the egg.
        if IsAir then
            return false, true
        end
        return true, true
    end
    if Type == E_ITEM_FLINT_AND_STEEL then
        if IsAir then
            return false, true
        end
        return IsSolidSurface(BlockType), true
    end
    if Type == E_ITEM_FIREWORK_ROCKET then
        if Player:IsElytraFlying() then
            return true, true
        end
        if IsAir then
            return false, true
        end
        return IsSolidSurface(BlockType), true
    end

    return false, true
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
    local State = GetPlayerState(Player)
    if not State.IsUsingShield then
        State.IsUsingShield = true
        LOG("Player " .. Player:GetName() .. " used a shield!")
    end
end

---Lower the shield (only on the true -> false transition).
---@param Player cPlayer
local function ReleaseShield(Player)
    local State = GetPlayerState(Player)
    if State.IsUsingShield then
        State.IsUsingShield = false
        LOG("Player " .. Player:GetName() .. " released a shield!")
    end
end

-- HOOK_PLAYER_USING_ITEM: the "shield raised" signal, fired on the tick the
-- client pressed right-click. For each event we decide immediately whether
-- the main-hand item was consumed (using GetTargetedBlock as the air-use
-- fallback for the real targeted block); if it was not consumed, the offhand
-- shield raises. No cross-event batching is needed.
---@param Player cPlayer
---@param BlockX number
---@param BlockY number
---@param BlockZ number
---@param BlockFace number
---@param CursorX number
---@param CursorY number
---@param CursorZ number
---@return boolean|nil  true to cancel the item use, nil/false otherwise
function CheckUseShieldOnUsingItem(Player, BlockX, BlockY, BlockZ, BlockFace, CursorX, CursorY, CursorZ)
    local Item = Player:GetEquippedItem()
    local ItemOffhand = Player:GetOffHandEquipedItem()
    LOG("Player " .. Player:GetName() .. " using item".. Item.m_ItemType .. "and" .. ItemOffhand.m_ItemType .. " at block " .. BlockX .. "," .. BlockY .. "," .. BlockZ ..
        " cursor " .. CursorX .. "," .. CursorY .. "," .. CursorZ)

    -- Trace the block the player is currently aiming at (independent of the
    -- event's reported block coords, which can be (-1,255,-1) for air uses).
    local TargetType, TargetPos = GetTargetedBlock(Player)
    if TargetPos then
        LOG("Player " .. Player:GetName() .. " targeting block " .. TargetType ..
            " at " .. TargetPos.x .. "," .. TargetPos.y .. "," .. TargetPos.z)
    else
        LOG("Player " .. Player:GetName() .. " targeting block AIR (nothing in reach)")
    end

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

    -- Resolve the block type the player is actually aiming at. For normal
    -- events this is World:GetBlock at the reported coords; for air-use events
    -- (coords == -1,255,-1) we reuse the GetTargetedBlock trace above. This
    -- fetches the block type exactly once per event.
    local IsAirUse = (BlockX == -1 and BlockY == 255 and BlockZ == -1)
    local BlockType
    if IsAirUse then
        BlockType = TargetType  -- from GetTargetedBlock above (E_BLOCK_AIR if none)
    else
        BlockType = Player:GetWorld():GetBlock(Vector3i(BlockX, BlockY, BlockZ))
    end

    local Consumed, Definitive = EvaluateEvent(Player, Type, BlockType)

    -- With GetTargetedBlock as the air-use fallback, every event is now
    -- definitive: the consumed/not-consumed decision is made per-event from
    -- the real targeted block, so no cross-event batching is needed.
    if not Consumed then
        RaiseShield(Player)
    end
    LOG("Player " .. Player:GetName() .. " using item " .. Type ..
        " consumed=" .. tostring(Consumed) ..
        " definitive=" .. tostring(Definitive) ..
        " blockType=" .. BlockType)
end

-- HOOK_WORLD_TICK: apply deferred shield durability loss (recorded by
-- HOOK_TAKE_DAMAGE). Cuberite does not implement shield durability natively,
-- so we use a probability-based break: chance = loss / 336, reduced by
-- Unbreaking. (The former per-tick batch evaluation was removed: each
-- USING_ITEM event is now resolved immediately in CheckUseShieldOnUsingItem
-- via GetTargetedBlock, so there is nothing to defer.)
---@param World cWorld
---@param TimeDelta number  milliseconds since the last tick
---@param LastTickDurationMSec number
function CheckUseShieldOnTick(World, TimeDelta, LastTickDurationMSec)
    World:ForEachPlayer(
        ---@param Player cPlayer
        function(Player)
            -- Apply deferred shield durability loss (recorded by HOOK_TAKE_DAMAGE).
            -- Cuberite does not implement shield durability natively, so we use a
            -- probability-based break: chance = loss / 336, reduced by Unbreaking.
            local State = GetPlayerState(Player)
            local Loss = State.PendingShieldDurabilityLoss
            if Loss and Loss > 0 then
                State.PendingShieldDurabilityLoss = 0
                local ShieldItem, SlotNum
                local Main = Player:GetEquippedItem()
                if Main and IsShield(Main.m_ItemType) then
                    ShieldItem = Main
                    SlotNum = nil  -- main hand, use DamageEquippedItem-like removal
                else
                    local Off = Player:GetOffHandEquipedItem()
                    if Off and IsShield(Off.m_ItemType) then
                        ShieldItem = Off
                        SlotNum = cInventory.invShieldOffset
                    end
                end
                if ShieldItem then
                    local UnbreakingLevel = ShieldItem.m_Enchantments:GetLevel(cEnchantments.enchUnbreaking)
                    local BreakChance = (Loss / 336) * (100 / (UnbreakingLevel + 1)) / 100
                    LOG("Player " .. Player:GetName() .. " shield break chance: " .. tostring(BreakChance)
                        .. " (loss=" .. Loss .. " unbreaking=" .. UnbreakingLevel .. ")")
                    if math.random() < BreakChance then
                        LOG("Player " .. Player:GetName() .. " shield broke!")
                        ReleaseShield(Player)
                        if SlotNum then
                            Player:GetInventory():SetShieldSlot(cItem())
                        else
                            Player:GetInventory():RemoveOneEquippedItem()
                        end
                    end
                end
            end
        end
    )
end

-- HOOK_PLAYER_SHOOTING: the "shield released" signal. Fires both when a bow is
-- shot and when a raised shield is lowered (same SHOOT status packet), so this
-- is the reliable release event.
---@param Player cPlayer
---@return boolean|nil  true to cancel the shot, nil/false otherwise
function CheckUseShieldOnShooting(Player)
    ReleaseShield(Player)
end

-- HOOK_PLAYER_TOSSING_ITEM: dropping the held item. Only release if the dropped
-- item was the shield currently being held up, or if neither hand holds a
-- shield anymore (the shield got moved away). Dropping a normal item does NOT
-- release the shield.
---@param Player cPlayer
---@return boolean|nil  true to cancel the toss, nil/false otherwise
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

-- HOOK_PLAYER_RIGHT_CLICK: fires at the very start of both HandleRightClick
-- (right-click a block, BlockFace >= 0) and HandleUseItem (right-click air,
-- BlockFace == BLOCK_FACE_NONE), BEFORE Cuberite's food/item-use dispatch.
--
-- This is the ONLY hook that fires for two cases where HOOK_PLAYER_USING_ITEM
-- never fires, but the client still plays a right-click animation and would
-- raise an offhand shield:
--   (1) Empty main hand -- nothing to use, server does nothing, but the
--       client swings the arm.
--   (2) Creative mode holding normal food -- Cuberite's HandleUseItem blocks
--       food use in creative (IsFood() && IsGameModeCreative() -> return)
--       before StartEating / HOOK_PLAYER_USING_ITEM, so the server does
--       nothing, but the client (which doesn't know about the server-side
--       block) plays no eat animation and treats it as an empty right-click.
-- In both cases the right-click is NOT consumed by any item, so the offhand
-- shield SHOULD raise. We do this here.
--
-- We only handle the right-click-air case (BlockFace == BLOCK_FACE_NONE).
-- Right-clicking a block may be consumed by the block (chest, lever, etc.),
-- which is a real use of the right-click and should NOT raise the shield;
-- HOOK_PLAYER_RIGHT_CLICK fires before we can tell whether the block is
-- usable, so we conservatively skip it.
--
-- The pre-existing offhand-cancel logic (return true when the main hand is
-- empty and the offhand holds an item) is kept: it cancels the packet so the
-- client does not play an offhand animation the server would silently drop.
---@param Player cPlayer
---@param BlockX number
---@param BlockY number
---@param BlockZ number
---@param BlockFace number
---@param CursorX number
---@param CursorY number
---@param CursorZ number
---@return boolean|nil  true to cancel the right-click, nil/false otherwise
function CheckUseShieldOnRightClick(Player, BlockX, BlockY, BlockZ, BlockFace, CursorX, CursorY, CursorZ)
    local ItemOffhand = Player:GetOffHandEquipedItem()
    local OffhandHasShield = ItemOffhand and IsShield(ItemOffhand.m_ItemType)

    -- Only the right-click-air case (HandleUseItem) needs shield raising.
    -- HandleUseItem passes BLOCK_FACE_NONE and the sentinel block coords.
    if BlockFace == BLOCK_FACE_NONE then
        local Item = Player:GetEquippedItem()
        local MainEmpty = (not Item) or Item:IsEmpty()
        local MainIsCreativeFood = Item and FoodItems[Item.m_ItemType] and Player:IsGameModeCreative()

        if OffhandHasShield and (MainEmpty or MainIsCreativeFood) then
            -- Right-click not consumed by any item: raise the offhand shield.
            RaiseShield(Player)
            LOG("Player " .. Player:GetName() .. " raised shield via right-click (main "
                .. (MainEmpty and "empty" or "creative food") .. ")")
        end
    end

    -- Reject offhand interactions the server would silently drop. Cuberite
    -- forces a_UsedMainHand = true in HandleRightClick, so an offhand
    -- right-click on a block is processed as the (empty) main hand and the
    -- server does nothing. Returning true cancels the packet so the client
    -- does not play an animation the server ignores.
    if ItemOffhand and not ItemOffhand:IsEmpty() then
        local Item = Player:GetEquippedItem()
        -- Only block when the main hand is empty: that is the case where
        -- vanilla would defer to the offhand but Cuberite silently drops it.
        -- If the main hand holds a placeable/usable item the server already
        -- handles it via the main hand, so the offhand click is a harmless
        -- no-op.
        if Item and Item:IsEmpty() then
            return true
        end
    end
end

-- ============================================================================
-- Shield blocking mechanics
-- ============================================================================


---Damage types that CAN be blocked by a shield (in <= 1.12.2).
local BlockableDamageTypes =
{
    [dtAttack] = true,        -- Melee (mob melee, player melee)
    [dtRangedAttack] = true,  -- Arrows, tridents, snowballs, eggs, shulker bullets, fireballs, llama spit, wither skulls
    [dtExplosion] = true,     -- Creeper, ghast fireball, end crystal, bed, respawn anchor, TNT
}

---Whether the attack comes from the player's front (within the shield's
---horizontal 180-degree arc). Uses the relative position of the attacker
---when available; falls back to the knockback vector direction for attacks
---without an attacker (e.g. explosions).
---@param Player cPlayer
---@param Attacker cEntity|nil  the attacking entity (mob or projectile), or nil
---@param Knockback Vector3d|nil  the TDI.Knockback vector, used when Attacker is nil
---@return boolean
local function IsAttackFromFront(Player, Attacker, Knockback)
    local ToAttacker
    if Attacker then
        -- Vector from player to attacker (horizontal only).
        ToAttacker = Vector3d(
            Attacker:GetPosX() - Player:GetPosX(),
            0,
            Attacker:GetPosZ() - Player:GetPosZ()
        )
    elseif Knockback then
        -- Knockback points from attacker toward receiver. Reverse it to get
        -- the direction from receiver toward attacker.
        ToAttacker = Vector3d(-Knockback.x, 0, -Knockback.z)
    else
        return false
    end

    if ToAttacker:SqrLength() < 1e-6 then
        return true  -- Attacker is essentially on top of the player; block it.
    end
    -- Player's look vector (horizontal only).
    local Look = Vector3d(Player:GetLookVector())
    Look.y = 0
    if Look:SqrLength() < 1e-6 then
        return false
    end
    ToAttacker:Normalize()
    Look:Normalize()
    -- Dot > 0 means the attacker is in front (angle < 90 degrees).
    return (ToAttacker:Dot(Look) > 0)
end

---Find the shield the player is currently holding up (main or off hand).
---Returns the cItem, or nil if no shield is equipped.
---@param Player cPlayer
---@return cItem|nil
local function GetHeldShield(Player)
    local Main = Player:GetEquippedItem()
    if Main and IsShield(Main.m_ItemType) then
        return Main
    end
    local Off = Player:GetOffHandEquipedItem()
    if Off and IsShield(Off.m_ItemType) then
        return Off
    end
    return nil
end

-- HOOK_TAKE_DAMAGE: implement shield blocking. When a player with a raised
-- shield is attacked from the front by a blockable damage type, the damage is
-- negated, knockback is reduced, and the shield takes durability damage.
---@param Receiver cEntity  the entity taking damage
---@param TDI TakeDamageInfo  the damage info, modifiable
---@return boolean  true to cancel the damage
function CheckUseShieldOnTakeDamage(Receiver, TDI)
    -- Only players can use shields.
    if not Receiver:IsPlayer() then
        return false
    end
    local Player = Receiver
    local State = GetPlayerState(Player)

    -- Log the damage event for debugging.
    local AttackerPos = "nil"
    if TDI.Attacker then
        AttackerPos = TDI.Attacker:GetPosX() .. "," .. TDI.Attacker:GetPosY() .. "," .. TDI.Attacker:GetPosZ()
    end
    LOG("Player " .. Player:GetName() .. " took damage: type=" .. tostring(TDI.DamageType)
        .. " raw=" .. tostring(TDI.RawDamage)
        .. " final=" .. tostring(TDI.FinalDamage)
        .. " attackerPos=" .. AttackerPos
        .. " shieldRaised=" .. tostring(State.IsUsingShield))

    -- The shield must be raised (IsUsingShield flag set by USING_ITEM).
    if not State.IsUsingShield then
        return false
    end

    -- Only blockable damage types.
    if not BlockableDamageTypes[TDI.DamageType] then
        return false
    end

    -- The attack must come from the front.
    if not IsAttackFromFront(Player, TDI.Attacker, TDI.Knockback) then
        return false
    end

    -- Record the blocked amount so HOOK_WORLD_TICK can apply shield durability
    -- loss later. Return true to cancel the damage entirely (no damage, no
    -- knockback, no hurt animation).
    local BlockedDamage = TDI.FinalDamage
    if BlockedDamage >= 3 then
        State.PendingShieldDurabilityLoss = (State.PendingShieldDurabilityLoss or 0)
            + math.floor(BlockedDamage) + 1
    end

    return true
end

-- HOOK_PROJECTILE_HIT_ENTITY: when a projectile hits a player with a raised
-- shield from the front, deflect the projectile instead of letting it hit.
---@param ProjectileEntity cProjectileEntity  the projectile
---@param Entity cEntity  the entity being hit
---@return boolean  true to make the projectile fly through (no hit)
function CheckUseShieldOnProjectileHitEntity(ProjectileEntity, Entity)
    if not Entity:IsPlayer() then
        return false
    end
    local Player = Entity

    if not GetPlayerState(Player).IsUsingShield then
        return false
    end

    -- Determine attack direction from the projectile's position relative to the
    -- player (the projectile is at the attacker's side when it hits).
    if not IsAttackFromFront(Player, ProjectileEntity) then
        return false
    end

    if ProjectileEntity:GetProjectileKind() ~= cProjectileEntity.pkArrow and ProjectileEntity:GetProjectileKind() ~= cProjectileEntity.pkGhastFireball then
        ProjectileEntity:Destroy()
        return true
    end

    -- Deflect(For Arrows): return true so the projectile flies through (does not hit).
    -- Bounce it back by reversing its horizontal speed.
    local Speed = ProjectileEntity:GetSpeed()
    Speed.x = -Speed.x
    Speed.z = -Speed.z
    ProjectileEntity:SetSpeed(Speed)
    return true
end