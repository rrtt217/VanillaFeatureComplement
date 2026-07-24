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

---All food items. Consumed when the player is hungry (not satiated).
---Includes drinkable items (milk, potion) which use the same path.
local FoodItems =
{
    [E_ITEM_RED_APPLE] = true,
    [E_ITEM_GOLDEN_APPLE] = true,
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
    [E_ITEM_CHORUS_FRUIT] = true,
    [E_ITEM_PUMPKIN_PIE] = true,
    [E_ITEM_MELON_SLICE] = true,
    [E_ITEM_SPIDER_EYE] = true,
    [E_ITEM_COOKIE] = true,
    [E_ITEM_MILK] = true,
    [E_ITEM_POTION] = true,
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
    if HoeItems[Type] or ShovelItems[Type] then
        -- Hoe / shovel: consumed only against grass / dirt; definitive either way.
        if IsAirUse then
            return false, true
        end
        local BlockType = Player:GetWorld():GetBlock(Vector3i(BlockX, BlockY, BlockZ))
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
        -- Food / drink: consumed only when the player is hungry (not satiated).
        return not Player:IsSatiated(), true
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
---
---The batched events mechanism relies heavily on specific knowledge of how certain client sends USING_ITEM events for each item type. For now it only works on ViaFabricPlus/ViaForge.
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

-- HOOK_WORLD_TICK: process any pending shield batch from the previous tick. If the
-- main-hand item was not consumed across all batched events, raise the shield.
---@param World cWorld
---@param TimeDelta number  milliseconds since the last tick
---@param LastTickDurationMSec number
function CheckUseShieldOnTick(World, TimeDelta, LastTickDurationMSec)
    World:ForEachPlayer(
        ---@param Player cPlayer
        function(Player)
            -- Process pending shield batch from the previous tick.
            local Batch = Player.ShieldBatch
            if Batch and #Batch > 0 then
                local WorldAge = Player:GetWorld():GetWorldAge()
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

            -- Apply deferred shield durability loss (recorded by HOOK_TAKE_DAMAGE).
            -- Cuberite does not implement shield durability natively, so we use a
            -- probability-based break: chance = loss / 336, reduced by Unbreaking.
            local Loss = Player.PendingShieldDurabilityLoss
            if Loss and Loss > 0 then
                Player.PendingShieldDurabilityLoss = 0
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
                        if SlotNum then
                            Player:GetInventory()
                        else
                            Player:GetInventory():SetShieldSlot(cItem())
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

-- Reject offhand interactions the server would silently drop. Cuberite forces
-- a_UsedMainHand = true in HandleRightClick, so an offhand right-click on a
-- block is processed as the (empty) main hand and the server does nothing.
-- Returning true cancels the packet so the client does not play an animation
-- the server ignores (e.g. raising an offhand shield that never raises).
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

    -- Log the damage event for debugging.
    local AttackerPos = "nil"
    if TDI.Attacker then
        AttackerPos = TDI.Attacker:GetPosX() .. "," .. TDI.Attacker:GetPosY() .. "," .. TDI.Attacker:GetPosZ()
    end
    LOG("Player " .. Player:GetName() .. " took damage: type=" .. tostring(TDI.DamageType)
        .. " raw=" .. tostring(TDI.RawDamage)
        .. " final=" .. tostring(TDI.FinalDamage)
        .. " attackerPos=" .. AttackerPos
        .. " shieldRaised=" .. tostring(Player.IsUsingShield))

    -- The shield must be raised (IsUsingShield flag set by USING_ITEM).
    if not Player.IsUsingShield then
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
        Player.PendingShieldDurabilityLoss = (Player.PendingShieldDurabilityLoss or 0)
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

    if not Player.IsUsingShield then
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