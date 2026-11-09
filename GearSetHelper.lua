local addonName, ns = ...

local CHAT_PREFIX = "|cff33ff99[GearSetHelper]|r "
local DEBOUNCE_DELAY = 0.25
local SET_SWAP_SLOT_THRESHOLD = 4 -- this many slots changing at once is treated as a set swap

local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local ADDON_VERSION = (GetMetadata and GetMetadata(addonName, "Version")) or "?"

-- Saved settings and their defaults
local DEFAULTS = {
    enabled = true,          -- show the update prompt when gear changes
    skipKnownItems = true,   -- no prompt when the equipped item is already in a saved set
    showLoadMessage = true,  -- print the "Loaded" line on login
}

-- Key binding labels (Options -> Key Bindings -> AddOns -> GearSetHelper)
BINDING_HEADER_GEARSETHELPER = "GearSetHelper"
BINDING_NAME_GEARSETHELPER_TOGGLE = "Toggle update prompts on/off"

-- State tracking
local isSwappingSet = false       -- a full set swap started by the player is in progress
local isInternalOperation = false -- GearSetHelper itself is moving gear around
local operationActive = false     -- a set update pipeline is running
local debounceTimer = nil
local pendingSlots = {}
local pendingSlotOrder = {}
local queuedForCombat = false
local lastActiveSetKey = nil
local hasPrintedLoadMessage = false

-- Safe numeric slot fallbacks
local SLOT_HEAD      = INVSLOT_HEAD or 1
local SLOT_NECK      = INVSLOT_NECK or 2
local SLOT_SHOULDER  = INVSLOT_SHOULDER or 3
local SLOT_BODY      = INVSLOT_BODY or 4
local SLOT_CHEST     = INVSLOT_CHEST or 5
local SLOT_WAIST     = INVSLOT_WAIST or 6
local SLOT_LEGS      = INVSLOT_LEGS or 7
local SLOT_FEET      = INVSLOT_FEET or 8
local SLOT_WRIST     = INVSLOT_WRIST or 9
local SLOT_HAND      = INVSLOT_HAND or 10
local SLOT_FINGER1   = INVSLOT_FINGER1 or 11
local SLOT_FINGER2   = INVSLOT_FINGER2 or 12
local SLOT_TRINKET1  = INVSLOT_TRINKET1 or 13
local SLOT_TRINKET2  = INVSLOT_TRINKET2 or 14
local SLOT_BACK      = INVSLOT_BACK or 15
local SLOT_MAINHAND  = INVSLOT_MAINHAND or 16
local SLOT_OFFHAND   = INVSLOT_OFFHAND or 17
local SLOT_RANGED    = INVSLOT_RANGED or 18
local SLOT_TABARD    = INVSLOT_TABARD or 19

-- Human-readable slot names keyed by InventorySlotId
local SLOT_NAMES = {
    [SLOT_HEAD]      = HEADSLOT or "Head",
    [SLOT_NECK]      = NECKSLOT or "Neck",
    [SLOT_SHOULDER]  = SHOULDERSLOT or "Shoulder",
    [SLOT_BODY]      = SHIRTSLOT or "Shirt",
    [SLOT_CHEST]     = CHESTSLOT or "Chest",
    [SLOT_WAIST]     = WAISTSLOT or "Waist",
    [SLOT_LEGS]      = LEGSSLOT or "Legs",
    [SLOT_FEET]      = FEETSLOT or "Feet",
    [SLOT_WRIST]     = WRISTSLOT or "Wrist",
    [SLOT_HAND]      = HANDSSLOT or "Hands",
    [SLOT_FINGER1]   = "Finger 1",
    [SLOT_FINGER2]   = "Finger 2",
    [SLOT_TRINKET1]  = "Trinket 1",
    [SLOT_TRINKET2]  = "Trinket 2",
    [SLOT_BACK]      = BACKSLOT or "Back",
    [SLOT_MAINHAND]  = MAINHANDSLOT or "Main Hand",
    [SLOT_OFFHAND]   = SECONDARYHANDSLOT or "Off Hand",
    [SLOT_RANGED]    = RANGEDSLOT or "Ranged",
    [SLOT_TABARD]    = TABARDSLOT or "Tabard",
}

local ALL_EQUIPMENT_SLOTS = {
    SLOT_HEAD, SLOT_NECK, SLOT_SHOULDER, SLOT_BODY, SLOT_CHEST, SLOT_WAIST,
    SLOT_LEGS, SLOT_FEET, SLOT_WRIST, SLOT_HAND, SLOT_FINGER1, SLOT_FINGER2,
    SLOT_TRINKET1, SLOT_TRINKET2, SLOT_BACK, SLOT_MAINHAND, SLOT_OFFHAND,
    SLOT_RANGED, SLOT_TABARD,
}

-- Values C_EquipmentSet.GetItemLocations uses for slots that hold no real location
local LOC_EMPTY   = EQUIPMENT_SET_EMPTY_SLOT or 0
local LOC_IGNORED = EQUIPMENT_SET_IGNORED_SLOT or 1
local LOC_MISSING = EQUIPMENT_SET_ITEM_MISSING or -1

local function PrintMessage(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. tostring(msg))
    else
        print(CHAT_PREFIX .. tostring(msg))
    end
end

local function SlotName(slotID)
    return SLOT_NAMES[slotID] or ("Slot " .. tostring(slotID))
end

-- ============================================================================
-- Settings
-- ============================================================================

local function InitDB()
    GearSetHelperDB = GearSetHelperDB or {}
    for key, value in pairs(DEFAULTS) do
        if GearSetHelperDB[key] == nil then
            GearSetHelperDB[key] = value
        end
    end
end

local function GetSetting(key)
    if not GearSetHelperDB then
        return DEFAULTS[key]
    end
    local value = GearSetHelperDB[key]
    if value == nil then
        return DEFAULTS[key]
    end
    return value
end

local function IsEnabled()
    return GetSetting("enabled") ~= false
end

-- ============================================================================
-- Pending slot tracking
-- ============================================================================

local function ClearPendingSlots()
    wipe(pendingSlots)
    wipe(pendingSlotOrder)
end

local function RecordChangedSlot(slotID)
    if slotID and not pendingSlots[slotID] then
        pendingSlots[slotID] = true
        table.insert(pendingSlotOrder, slotID)
    end
end

local function CopyChangedSlotList()
    local list, map = {}, {}
    for _, slotID in ipairs(pendingSlotOrder) do
        table.insert(list, slotID)
        map[slotID] = true
    end
    return list, map
end

local function FormatChangedSlots()
    local names = {}
    for _, slotID in ipairs(pendingSlotOrder) do
        table.insert(names, SlotName(slotID))
    end
    if #names == 0 then
        return "Equipment"
    end
    return table.concat(names, ", ")
end

-- ============================================================================
-- Inventory & Bag Helpers
-- ============================================================================

local function GetEquippedSlotGUID(slotID)
    if ItemLocation and ItemLocation.CreateFromEquipmentSlot and C_Item and C_Item.DoesItemExist and C_Item.GetItemGUID then
        local ok, loc = pcall(ItemLocation.CreateFromEquipmentSlot, ItemLocation, slotID)
        if ok and loc and C_Item.DoesItemExist(loc) then
            return C_Item.GetItemGUID(loc)
        end
    end
    return nil
end

local function GetBagSlotGUID(bag, bagSlot)
    if ItemLocation and ItemLocation.CreateFromBagAndSlot and C_Item and C_Item.DoesItemExist and C_Item.GetItemGUID then
        local ok, loc = pcall(ItemLocation.CreateFromBagAndSlot, ItemLocation, bag, bagSlot)
        if ok and loc and C_Item.DoesItemExist(loc) then
            return C_Item.GetItemGUID(loc)
        end
    end
    return nil
end

local function GetNumBagSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag) or 0
    elseif GetContainerNumSlots then
        return GetContainerNumSlots(bag) or 0
    end
    return 0
end

local function GetBagItemLink(bag, bagSlot)
    if C_Container and C_Container.GetContainerItemLink then
        return C_Container.GetContainerItemLink(bag, bagSlot)
    elseif GetContainerItemLink then
        return GetContainerItemLink(bag, bagSlot)
    end
    return nil
end

local function GetBagItemID(bag, bagSlot)
    if C_Container and C_Container.GetContainerItemID then
        return C_Container.GetContainerItemID(bag, bagSlot)
    elseif GetContainerItemID then
        return GetContainerItemID(bag, bagSlot)
    end
    return nil
end

local function PickupBagItem(bag, bagSlot)
    if C_Container and C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, bagSlot)
    elseif PickupContainerItem then
        PickupContainerItem(bag, bagSlot)
    end
end

local function BagToInventoryID(bag)
    if C_Container and C_Container.ContainerIDToInventoryID then
        return C_Container.ContainerIDToInventoryID(bag)
    elseif ContainerIDToInventoryID then
        return ContainerIDToInventoryID(bag)
    end
    return nil
end

local function AnyEquippedSlotLocked()
    if not IsInventoryItemLocked then
        return false
    end
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        if IsInventoryItemLocked(slotID) then
            return true
        end
    end
    return false
end

local function SnapshotSlotItem(slotID)
    local link = GetInventoryItemLink("player", slotID)
    local itemID = GetInventoryItemID("player", slotID)
    local guid = GetEquippedSlotGUID(slotID)
    if not link and not itemID and not guid then
        return nil
    end
    return { slotID = slotID, link = link, itemID = itemID, guid = guid }
end

local function SnapshotAllWornGear()
    local snapshot = {}
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        snapshot[slotID] = SnapshotSlotItem(slotID)
    end
    return snapshot
end

local function IsItemEquippedInSlot(itemInfo, slotID)
    if not itemInfo then
        return GetInventoryItemID("player", slotID) == nil
    end
    local currentGUID = GetEquippedSlotGUID(slotID)
    if itemInfo.guid and currentGUID then
        return itemInfo.guid == currentGUID
    end
    local currentLink = GetInventoryItemLink("player", slotID)
    if itemInfo.link and currentLink and itemInfo.link == currentLink then
        return true
    end
    local currentID = GetInventoryItemID("player", slotID)
    if itemInfo.itemID and currentID and itemInfo.itemID == currentID then
        return true
    end
    return false
end

-- With includeEmpty, slots that were empty in the snapshot must also be empty now.
local function DoesCurrentGearMatchSnapshot(snapshot, includeEmpty)
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        local expected = snapshot[slotID]
        if expected then
            if not IsItemEquippedInSlot(expected, slotID) then
                return false
            end
        elseif includeEmpty and GetInventoryItemID("player", slotID) ~= nil then
            return false
        end
    end
    return true
end

local function ListMismatchedSlots(snapshot)
    local names = {}
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        local expected = snapshot[slotID]
        local mismatched
        if expected then
            mismatched = not IsItemEquippedInSlot(expected, slotID)
        else
            mismatched = GetInventoryItemID("player", slotID) ~= nil
        end
        if mismatched then
            table.insert(names, SlotName(slotID))
        end
    end
    return table.concat(names, ", ")
end

-- Equips one snapshotted item into `targetSlotID`, looking for it first in other
-- equipment slots, then in bags by GUID, link and itemID.
local function EquipSnapshottedItemIntoSlot(itemInfo, targetSlotID, usedBagSlots)
    if not itemInfo or IsItemEquippedInSlot(itemInfo, targetSlotID) then
        return true
    end
    usedBagSlots = usedBagSlots or {}

    -- Already worn in another slot (e.g. Ring 1 vs Ring 2): swap the two slots.
    if itemInfo.guid then
        for _, otherSlot in ipairs(ALL_EQUIPMENT_SLOTS) do
            if otherSlot ~= targetSlotID and GetEquippedSlotGUID(otherSlot) == itemInfo.guid then
                ClearCursor()
                PickupInventoryItem(otherSlot)
                if CursorHasItem() then
                    PickupInventoryItem(targetSlotID)
                end
                return true
            end
        end
    end

    local maxBag = NUM_BAG_SLOTS or 4
    local matchers = {}
    if itemInfo.guid then
        table.insert(matchers, function(bag, slot) return GetBagSlotGUID(bag, slot) == itemInfo.guid end)
    end
    if itemInfo.link then
        table.insert(matchers, function(bag, slot) return GetBagItemLink(bag, slot) == itemInfo.link end)
    end
    if itemInfo.itemID then
        table.insert(matchers, function(bag, slot) return GetBagItemID(bag, slot) == itemInfo.itemID end)
    end

    for _, matches in ipairs(matchers) do
        for bag = 0, maxBag do
            for bagSlot = 1, GetNumBagSlots(bag) do
                local key = bag .. ":" .. bagSlot
                if not usedBagSlots[key] and matches(bag, bagSlot) then
                    usedBagSlots[key] = true
                    ClearCursor()
                    PickupBagItem(bag, bagSlot)
                    if CursorHasItem() then
                        PickupInventoryItem(targetSlotID)
                    end
                    return true
                end
            end
        end
    end

    -- The global EquipItemByName was removed in 12.1.5 (which WoW Forever is built on).
    local equipByName = (C_Item and C_Item.EquipItemByName) or EquipItemByName
    if equipByName and (itemInfo.link or itemInfo.itemID) then
        pcall(equipByName, itemInfo.link or itemInfo.itemID, targetSlotID)
        return true
    end
    return false
end

-- Moves whatever is in `slotID` into the first bag with room.
local function UnequipSlotToBags(slotID)
    ClearCursor()
    PickupInventoryItem(slotID)
    if not CursorHasItem() then
        return
    end
    if PutItemInBackpack then
        PutItemInBackpack()
    end
    for bag = 1, NUM_BAG_SLOTS or 4 do
        if not CursorHasItem() then
            return
        end
        local invID = BagToInventoryID(bag)
        if invID and PutItemInBag then
            PutItemInBag(invID)
        end
    end
    if CursorHasItem() then
        ClearCursor()
    end
end

local function RestoreGearSnapshot(snapshot)
    local usedBagSlots = {}
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        local itemInfo = snapshot[slotID]
        if itemInfo and not IsItemEquippedInSlot(itemInfo, slotID) then
            EquipSnapshottedItemIntoSlot(itemInfo, slotID, usedBagSlots)
        end
    end
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        if not snapshot[slotID] and GetInventoryItemID("player", slotID) ~= nil
            and not (IsInventoryItemLocked and IsInventoryItemLocked(slotID)) then
            UnequipSlotToBags(slotID)
        end
    end
end

-- ============================================================================
-- Blizzard Equipment Manager helpers
-- ============================================================================

local function SafeSetCall(fn, setID)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, result = pcall(fn, setID)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

-- Returns slotID -> { kind = "item" | "empty" | "ignored" | "missing", itemID = n }
local function GetBlizzardSetSlotStates(setID)
    local itemIDs   = SafeSetCall(C_EquipmentSet.GetItemIDs, setID)
    local locations = SafeSetCall(C_EquipmentSet.GetItemLocations, setID)
    local ignored   = SafeSetCall(C_EquipmentSet.GetIgnoredSlots, setID)

    local states = {}
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        local itemID = itemIDs and itemIDs[slotID] or nil
        local location = locations and locations[slotID] or nil
        if (ignored and ignored[slotID]) or location == LOC_IGNORED then
            states[slotID] = { kind = "ignored" }
        elseif location == LOC_MISSING then
            -- -1 is also used for slots the set can't fill at all; only a real saved
            -- item counts as missing.
            if itemID and itemID > 0 then
                states[slotID] = { kind = "missing", itemID = itemID }
            else
                states[slotID] = { kind = "ignored" }
            end
        elseif itemID and itemID > 0 then
            states[slotID] = { kind = "item", itemID = itemID }
        else
            states[slotID] = { kind = "empty" }
        end
    end
    return states, itemIDs ~= nil
end

-- True when every slot of the set (except `changedSlotMap`) is what the player wears.
-- Strict mode also requires the set's empty slots to be empty and fails on missing items;
-- it is used to decide whether a set can be saved without swapping any gear.
local function IsBlizzardSetWornExcept(setID, changedSlotMap, strict)
    local states, haveItemIDs = GetBlizzardSetSlotStates(setID)
    if not haveItemIDs then
        local _, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        return isEquipped and true or false
    end
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        if not (changedSlotMap and changedSlotMap[slotID]) then
            local state = states[slotID]
            local worn = GetInventoryItemID("player", slotID)
            if state.kind == "item" then
                if worn ~= state.itemID then
                    return false
                end
            elseif strict and state.kind == "empty" then
                if worn ~= nil then
                    return false
                end
            elseif strict and state.kind == "missing" then
                return false
            end
        end
    end
    return true
end

local function GetMissingSetSlots(setID, changedSlotMap)
    local states = GetBlizzardSetSlotStates(setID)
    local names = {}
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        if states[slotID].kind == "missing" and not (changedSlotMap and changedSlotMap[slotID]) then
            table.insert(names, SlotName(slotID))
        end
    end
    return names
end

local function UseBlizzardSet(setID)
    if C_EquipmentSet and C_EquipmentSet.UseEquipmentSet then
        pcall(C_EquipmentSet.UseEquipmentSet, setID)
    elseif EquipmentManager_EquipSet then
        pcall(EquipmentManager_EquipSet, setID)
    end
end

-- Saves a Blizzard set from worn gear while keeping its ignored slots ignored, so a
-- set that deliberately ignores e.g. its trinket slots never picks up a new trinket.
local function SaveBlizzardSetPreservingIgnoredSlots(setID)
    local name = C_EquipmentSet.GetEquipmentSetInfo(setID)
    if not name then
        return false, nil
    end

    if C_EquipmentSet.GetIgnoredSlots and C_EquipmentSet.ClearIgnoredSlotsForSave and C_EquipmentSet.IgnoreSlotForSave then
        local ok, ignoredSlots = pcall(C_EquipmentSet.GetIgnoredSlots, setID)
        if ok and type(ignoredSlots) == "table" then
            C_EquipmentSet.ClearIgnoredSlotsForSave()
            for slot, isIgnored in pairs(ignoredSlots) do
                if isIgnored then
                    C_EquipmentSet.IgnoreSlotForSave(slot)
                end
            end
        end
    end

    C_EquipmentSet.SaveEquipmentSet(setID)
    return true, name
end

-- ============================================================================
-- Unified Equipment Set Providers (ItemRack, Outfitter, Blizzard)
-- ============================================================================

local function GetAllConfiguredSets()
    local sets = {}

    -- 1. ItemRack sets
    if type(ItemRackUser) == "table" and type(ItemRackUser.Sets) == "table" then
        local currentSet = ItemRackUser.CurrentSet
        local names = {}
        for setName, setTable in pairs(ItemRackUser.Sets) do
            if type(setName) == "string" and string.sub(setName, 1, 1) ~= "~" and type(setTable) == "table" then
                table.insert(names, setName)
            end
        end
        table.sort(names)
        for _, setName in ipairs(names) do
            local setTable = ItemRackUser.Sets[setName]
            local isEquipped = (currentSet == setName)
            if ItemRack and type(ItemRack.IsSetEquipped) == "function" then
                local ok, res = pcall(ItemRack.IsSetEquipped, setName)
                if ok and res then
                    isEquipped = true
                end
            end
            table.insert(sets, {
                key = "itemrack:" .. setName,
                provider = "itemrack",
                id = setName,
                name = setName,
                icon = setTable.icon or 134400,
                isEquipped = isEquipped,
                numEquipped = isEquipped and 19 or 0,
            })
        end
    end

    -- 2. Outfitter outfits
    if type(gOutfitter_Settings) == "table" and type(gOutfitter_Settings.Outfits) == "table" then
        for _, outfitList in pairs(gOutfitter_Settings.Outfits) do
            if type(outfitList) == "table" then
                for _, outfit in ipairs(outfitList) do
                    if type(outfit) == "table" and outfit.Name and outfit.Name ~= "" then
                        table.insert(sets, {
                            key = "outfitter:" .. outfit.Name,
                            provider = "outfitter",
                            id = outfit.Name,
                            outfitRef = outfit,
                            name = outfit.Name,
                            icon = outfit.Icon or 134400,
                            isEquipped = false,
                            numEquipped = 0,
                        })
                    end
                end
            end
        end
    end

    -- 3. Blizzard Equipment Manager
    if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs then
        local ok, setIDs = pcall(C_EquipmentSet.GetEquipmentSetIDs)
        if ok and type(setIDs) == "table" then
            for _, setID in ipairs(setIDs) do
                local name, iconFileID, _, isEquipped, _, numEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
                if name then
                    table.insert(sets, {
                        key = "blizzard:" .. tostring(setID),
                        provider = "blizzard",
                        id = setID,
                        name = name,
                        icon = iconFileID or 134400,
                        isEquipped = isEquipped and true or false,
                        numEquipped = numEquipped or 0,
                    })
                end
            end
        end
    end

    return sets
end

local function ParseItemRackID(value)
    if value == nil or value == 0 then
        return nil
    end
    return tonumber(string.match(tostring(value), "^(%d+)"))
end

-- True when `itemID` is saved in any slot of any configured set.
local function IsItemInAnySet(itemID, sets)
    if not itemID then
        return false
    end
    sets = sets or GetAllConfiguredSets()
    for _, entry in ipairs(sets) do
        if entry.provider == "blizzard" then
            local itemIDs = SafeSetCall(C_EquipmentSet.GetItemIDs, entry.id)
            if itemIDs then
                for _, id in pairs(itemIDs) do
                    if id == itemID then
                        return true
                    end
                end
            end
        elseif entry.provider == "itemrack" then
            local setTable = ItemRackUser and ItemRackUser.Sets and ItemRackUser.Sets[entry.id]
            if type(setTable) == "table" and type(setTable.equip) == "table" then
                for _, value in pairs(setTable.equip) do
                    if ParseItemRackID(value) == itemID then
                        return true
                    end
                end
            end
        elseif entry.provider == "outfitter" then
            local items = entry.outfitRef and entry.outfitRef.Items
            if type(items) == "table" then
                for _, item in pairs(items) do
                    if type(item) == "table" and tonumber(item.Code) == itemID then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function RefreshLastActiveSet()
    for _, s in ipairs(GetAllConfiguredSets()) do
        if s.isEquipped then
            lastActiveSetKey = s.key
            return
        end
    end
end

local function ResolveActiveSetEntry(sets, changedSlotMap)
    sets = sets or GetAllConfiguredSets()
    if #sets == 0 then
        return nil
    end

    for _, s in ipairs(sets) do
        if s.isEquipped then
            return s
        end
    end

    if lastActiveSetKey ~= nil then
        for _, s in ipairs(sets) do
            if s.key == lastActiveSetKey then
                return s
            end
        end
    end

    if changedSlotMap then
        for _, s in ipairs(sets) do
            if s.provider == "blizzard" and IsBlizzardSetWornExcept(s.id, changedSlotMap, false) then
                return s
            end
        end
    end

    local best, bestCount = nil, -1
    for _, s in ipairs(sets) do
        if (s.numEquipped or 0) > bestCount then
            bestCount = s.numEquipped or 0
            best = s
        end
    end
    return best or sets[1]
end

-- Updates only the changed slot(s) of an ItemRack set directly in `ItemRackUser.Sets`.
local function UpdateItemRackSetSlots(setName, changedSlotList)
    if type(ItemRackUser) ~= "table" or type(ItemRackUser.Sets) ~= "table" then
        return false, nil
    end
    local setTable = ItemRackUser.Sets[setName]
    if type(setTable) ~= "table" or type(setTable.equip) ~= "table" then
        return false, nil
    end

    local slotsToUpdate = (#changedSlotList > 0) and changedSlotList or ALL_EQUIPMENT_SLOTS
    for _, slotID in ipairs(slotsToUpdate) do
        local newID = nil
        if ItemRack and type(ItemRack.GetID) == "function" then
            local ok, id = pcall(ItemRack.GetID, slotID)
            if ok then
                newID = id
            end
        end
        if not newID then
            local itemID = GetInventoryItemID("player", slotID)
            newID = itemID and tostring(itemID) or 0
        end
        setTable.equip[slotID] = newID
    end

    if ItemRack and type(ItemRack.UpdateCurrentSet) == "function" then
        pcall(ItemRack.UpdateCurrentSet)
    end
    return true, setName
end

local SLOT_TO_OUTFITTER = {
    [SLOT_HEAD]     = "HeadSlot",
    [SLOT_NECK]     = "NeckSlot",
    [SLOT_SHOULDER] = "ShoulderSlot",
    [SLOT_BODY]     = "ShirtSlot",
    [SLOT_CHEST]    = "ChestSlot",
    [SLOT_WAIST]    = "WaistSlot",
    [SLOT_LEGS]     = "LegsSlot",
    [SLOT_FEET]     = "FeetSlot",
    [SLOT_WRIST]    = "WristSlot",
    [SLOT_HAND]     = "HandsSlot",
    [SLOT_FINGER1]  = "Finger0Slot",
    [SLOT_FINGER2]  = "Finger1Slot",
    [SLOT_TRINKET1] = "Trinket0Slot",
    [SLOT_TRINKET2] = "Trinket1Slot",
    [SLOT_BACK]     = "BackSlot",
    [SLOT_MAINHAND] = "MainHandSlot",
    [SLOT_OFFHAND]  = "SecondaryHandSlot",
    [SLOT_RANGED]   = "RangedSlot",
    [SLOT_TABARD]   = "TabardSlot",
}

-- Updates only the changed slot(s) of an Outfitter outfit directly.
local function UpdateOutfitterSetSlots(outfit, changedSlotList)
    if type(outfit) ~= "table" or not outfit.Name then
        return false, nil
    end
    outfit.Items = outfit.Items or {}
    local slotsToUpdate = (#changedSlotList > 0) and changedSlotList or ALL_EQUIPMENT_SLOTS
    for _, slotID in ipairs(slotsToUpdate) do
        local slotName = SLOT_TO_OUTFITTER[slotID]
        local itemID = GetInventoryItemID("player", slotID)
        if slotName and itemID then
            local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
            local itemName, itemLink = getInfo(itemID)
            outfit.Items[slotName] = {
                Code = itemID,
                SubCode = 0,
                Name = itemName or "",
                Link = itemLink,
            }
        end
    end
    return true, outfit.Name
end

-- ============================================================================
-- Set Update Pipeline
-- ============================================================================
--
-- Blizzard sets can only be saved from what the player is wearing. To change one
-- slot of a set that is not currently worn we:
--   1. equip that set (C_EquipmentSet.UseEquipmentSet),
--   2. put the new item(s) back into the changed slot(s),
--   3. save the set,
--   4. repeat for the next set, then put the original gear back on.
-- Each step waits until the client confirms the swap (no locked slots and the
-- expected items worn). A set is never saved unless the swap was verified, so a
-- failed swap skips that set instead of overwriting it with the wrong gear.

local operationErrorHandler = nil -- best-effort cleanup for the running operation
local pendingCombatRestore = nil   -- gear to put back once combat ends

local function FinishOperationState(delay)
    operationErrorHandler = nil
    -- Late PLAYER_EQUIPMENT_CHANGED events from our own swaps can still arrive; keep
    -- ignoring them briefly so they do not reopen the prompt.
    C_Timer.After(delay or 0.5, function()
        isInternalOperation = false
        operationActive = false
        ClearPendingSlots()
        if debounceTimer then
            debounceTimer:Cancel()
            debounceTimer = nil
        end
    end)
end

-- Wraps a callback so a Lua error can never leave the addon stuck mid-operation.
local function Guard(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            PrintMessage("|cffff4444Error while updating sets:|r " .. tostring(err))
            local handler = operationErrorHandler
            operationErrorHandler = nil
            if handler then
                pcall(handler)
            end
            -- Longer quiet period: the cleanup's own gear swaps are still landing.
            FinishOperationState(1.5)
        end
    end
end

-- Polls until `predicate()` holds on two consecutive ticks with no equipment slot
-- locked, calling `retry()` now and then while waiting. Calls onDone(ok, reason).
local function WaitFor(predicate, timeout, retry, onDone)
    local INTERVAL = 0.1
    local elapsed, sinceRetry, stableTicks = 0, 0, 0
    local tick
    tick = Guard(function()
        if InCombatLockdown() then
            onDone(false, "combat")
            return
        end
        local busy = AnyEquippedSlotLocked()
        if not busy and predicate() then
            stableTicks = stableTicks + 1
            if stableTicks >= 2 then
                onDone(true)
                return
            end
        else
            stableTicks = 0
        end
        elapsed = elapsed + INTERVAL
        sinceRetry = sinceRetry + INTERVAL
        if elapsed >= timeout then
            onDone(false, "timeout")
            return
        end
        if retry and not busy and stableTicks == 0 and sinceRetry >= 0.75 then
            sinceRetry = 0
            if CursorHasItem() then
                ClearCursor()
            end
            retry()
        end
        C_Timer.After(INTERVAL, tick)
    end)
    C_Timer.After(INTERVAL, tick)
end

local function GetItemEquipLoc(itemID)
    if not itemID then
        return nil
    end
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if getInstant then
        local _, _, _, equipLoc = getInstant(itemID)
        return equipLoc
    end
    return nil
end

local function CopySlots(list)
    local newList, newMap = {}, {}
    for _, slotID in ipairs(list) do
        table.insert(newList, slotID)
        newMap[slotID] = true
    end
    return newList, newMap
end

local function AddSlot(list, map, slotID)
    if not map[slotID] then
        map[slotID] = true
        table.insert(list, slotID)
    end
end

-- A two-hander and an off-hand can't be worn together, so changing one weapon slot
-- can force a change in the other. Returns the slots to update for this set.
local function ChangedSlotsForSet(states, baseList)
    local list, map = CopySlots(baseList)
    -- New two-hander: every set's off-hand must end up empty.
    if map[SLOT_MAINHAND] and GetItemEquipLoc(GetInventoryItemID("player", SLOT_MAINHAND)) == "INVTYPE_2HWEAPON" then
        AddSlot(list, map, SLOT_OFFHAND)
    end
    -- New off-hand on a set built around a two-hander: it takes your current main hand.
    if map[SLOT_OFFHAND] and not map[SLOT_MAINHAND] and states then
        local mainHand = states[SLOT_MAINHAND]
        if mainHand and mainHand.kind == "item" and GetItemEquipLoc(mainHand.itemID) == "INVTYPE_2HWEAPON" then
            AddSlot(list, map, SLOT_MAINHAND)
        end
    end
    return list, map
end

local function AllSlotsIgnored(states, list)
    for _, slotID in ipairs(list) do
        if states[slotID].kind ~= "ignored" then
            return false
        end
    end
    return true
end

local function RunSetUpdates(targetEntries, changedSlotList, summaryMode)
    if operationActive then
        PrintMessage("A set update is already in progress.")
        return
    end
    if InCombatLockdown() then
        PrintMessage("Cannot update equipment sets while in combat.")
        return
    end
    -- Never treat "no changed slots" as "save everything": that would copy the gear you
    -- are wearing into every target set.
    if not targetEntries or #targetEntries == 0 or not changedSlotList or #changedSlotList == 0 then
        return
    end

    operationActive = true
    isInternalOperation = true

    local _, baseMap = CopySlots(changedSlotList)
    local activeEntry = ResolveActiveSetEntry(GetAllConfiguredSets(), baseMap)
    local originalGear = SnapshotAllWornGear()

    local updatedNames = {}
    local skipped = {}
    local swapQueue = {}

    operationErrorHandler = function()
        RestoreGearSnapshot(originalGear)
    end

    -- Sets that can be updated without moving any gear are done straight away.
    for _, entry in ipairs(targetEntries) do
        if entry.provider == "itemrack" then
            local ok, name = UpdateItemRackSetSlots(entry.id, ChangedSlotsForSet(nil, changedSlotList))
            if ok then
                table.insert(updatedNames, name)
            end
        elseif entry.provider == "outfitter" then
            local ok, name = UpdateOutfitterSetSlots(entry.outfitRef, ChangedSlotsForSet(nil, changedSlotList))
            if ok then
                table.insert(updatedNames, name)
            end
        elseif entry.provider == "blizzard" then
            local states = GetBlizzardSetSlotStates(entry.id)
            local list, map = ChangedSlotsForSet(states, changedSlotList)
            if AllSlotsIgnored(states, list) then
                table.insert(skipped, { name = entry.name, reason = "the set ignores that slot" })
            elseif IsBlizzardSetWornExcept(entry.id, map, true) then
                local ok, name = SaveBlizzardSetPreservingIgnoredSlots(entry.id)
                if ok then
                    table.insert(updatedNames, name)
                end
            else
                table.insert(swapQueue, { entry = entry, list = list, map = map })
            end
        end
    end

    local function Finish(aborted)
        local count = #updatedNames
        if count == 1 and summaryMode ~= "all" then
            PrintMessage(string.format("Updated set %q.", updatedNames[1]))
        elseif count > 0 then
            PrintMessage(string.format("Updated %d %s: %s.", count, count == 1 and "set" or "sets", table.concat(updatedNames, ", ")))
        end
        for _, s in ipairs(skipped) do
            PrintMessage(string.format("|cffffd100Skipped %q|r - %s", s.name, s.reason))
        end
        if count == 0 and #skipped == 0 and not aborted then
            PrintMessage("No sets were updated.")
        end

        if activeEntry then
            lastActiveSetKey = activeEntry.key
        end
        if not aborted then
            RefreshLastActiveSet()
        end
        FinishOperationState()
    end

    local function AbortForCombat()
        PrintMessage("|cffff4444Combat started - set update stopped.|r Your gear will be put back when combat ends.")
        pendingCombatRestore = originalGear
        Finish(true)
    end

    local function Restore()
        if DoesCurrentGearMatchSnapshot(originalGear, true) then
            Finish()
            return
        end
        RestoreGearSnapshot(originalGear)
        WaitFor(
            function() return DoesCurrentGearMatchSnapshot(originalGear, true) end,
            6,
            function() RestoreGearSnapshot(originalGear) end,
            function(ok, reason)
                if reason == "combat" then
                    AbortForCombat()
                    return
                end
                if not ok then
                    PrintMessage("|cffffd100Could not fully restore your gear|r (" .. ListMismatchedSlots(originalGear) .. "). Re-equip those slots manually.")
                end
                Finish()
            end
        )
    end

    -- Puts the original item (or nothing) back into each of `map`'s slots, main hand
    -- first so a two-hander clears the off-hand before the off-hand is checked.
    local function EquipNewItems(map)
        local used = {}
        for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
            local info = originalGear[slotID]
            if map[slotID] and info and not IsItemEquippedInSlot(info, slotID) then
                EquipSnapshottedItemIntoSlot(info, slotID, used)
            end
        end
        for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
            if map[slotID] and not originalGear[slotID] and GetInventoryItemID("player", slotID) ~= nil
                and not (IsInventoryItemLocked and IsInventoryItemLocked(slotID)) then
                UnequipSlotToBags(slotID)
            end
        end
    end

    local function NewItemsWorn(map)
        for slotID in pairs(map) do
            if not IsItemEquippedInSlot(originalGear[slotID], slotID) then
                return false
            end
        end
        return true
    end

    local index = 0
    local ProcessNext
    ProcessNext = function()
        index = index + 1
        local job = swapQueue[index]
        if not job then
            Restore()
            return
        end
        local entry, map = job.entry, job.map

        local missing = GetMissingSetSlots(entry.id, map)
        if #missing > 0 then
            table.insert(skipped, { name = entry.name, reason = "items not in your bags: " .. table.concat(missing, ", ") })
            ProcessNext()
            return
        end

        -- Step 1: put the target set on.
        UseBlizzardSet(entry.id)
        WaitFor(
            function() return IsBlizzardSetWornExcept(entry.id, map, true) end,
            5,
            function() UseBlizzardSet(entry.id) end,
            function(ok, reason)
                if reason == "combat" then
                    AbortForCombat()
                    return
                end
                if not ok then
                    table.insert(skipped, { name = entry.name, reason = "could not equip the set (full bags or items in the bank?)" })
                    ProcessNext()
                    return
                end

                -- Step 2: put the new item(s) back in the changed slot(s), then save.
                EquipNewItems(map)
                WaitFor(
                    function() return NewItemsWorn(map) and IsBlizzardSetWornExcept(entry.id, map, true) end,
                    5,
                    function() EquipNewItems(map) end,
                    function(ok2, reason2)
                        if reason2 == "combat" then
                            AbortForCombat()
                            return
                        end
                        if ok2 then
                            local saved, name = SaveBlizzardSetPreservingIgnoredSlots(entry.id)
                            if saved then
                                table.insert(updatedNames, name)
                            end
                        else
                            table.insert(skipped, { name = entry.name, reason = "could not re-equip the new item" })
                        end
                        ProcessNext()
                    end
                )
            end
        )
    end

    if #swapQueue == 0 then
        Finish()
    else
        Guard(ProcessNext)()
    end
end

-- Puts gear back after combat interrupted an update.
local function RunPendingCombatRestore()
    local snapshot = pendingCombatRestore
    if not snapshot then
        return
    end
    if operationActive then
        -- The interrupted operation is still winding down; try again shortly.
        C_Timer.After(1, function()
            if not InCombatLockdown() then
                RunPendingCombatRestore()
            end
        end)
        return
    end
    pendingCombatRestore = nil
    if DoesCurrentGearMatchSnapshot(snapshot, true) then
        return
    end
    operationActive = true
    isInternalOperation = true
    RestoreGearSnapshot(snapshot)
    WaitFor(
        function() return DoesCurrentGearMatchSnapshot(snapshot, true) end,
        6,
        function() RestoreGearSnapshot(snapshot) end,
        function(ok, reason)
            if reason == "combat" then
                pendingCombatRestore = snapshot
            elseif ok then
                PrintMessage("Restored the gear you were wearing before combat.")
            else
                PrintMessage("|cffffd100Could not fully restore your gear|r (" .. ListMismatchedSlots(snapshot) .. "). Re-equip those slots manually.")
            end
            FinishOperationState()
        end
    )
end

local function UpdateSingleSetEntry(entry, changedSlotList)
    entry = entry or ResolveActiveSetEntry(nil, nil)
    if not entry then
        return
    end
    RunSetUpdates({ entry }, changedSlotList, "single")
end

local function UpdateAllSetEntries(changedSlotList)
    local sets = GetAllConfiguredSets()
    if #sets == 0 then
        return
    end
    RunSetUpdates(sets, changedSlotList, "all")
end

-- ============================================================================
-- Update Prompt (set picker dialog)
-- ============================================================================

-- Backdrop helper that works across Classic / Forever / Retail clients
local function ApplyDarkBackdrop(frame, isDialog)
    if not frame.SetBackdrop and BackdropTemplateMixin then
        Mixin(frame, BackdropTemplateMixin)
    end
    if frame.SetBackdrop then
        if isDialog then
            frame:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 },
            })
        else
            frame:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 14,
                insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            frame:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
            frame:SetBackdropBorderColor(0.65, 0.65, 0.65, 1)
        end
    else
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.06, 0.06, 0.92)
    end
end

local promptFrame = nil

-- keepPending: keep the recorded slots (used when combat hides the prompt so it can
-- come back afterwards). Any other close, including Escape, discards them.
local function HidePrompt(keepPending)
    if promptFrame and promptFrame:IsShown() then
        promptFrame.keepPending = keepPending
        promptFrame:Hide()
        promptFrame.keepPending = nil
    end
end

local function GetOrCreatePromptFrame()
    if promptFrame then
        return promptFrame
    end

    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    local f = CreateFrame("Frame", "GearSetHelperPromptFrame", UIParent, template)
    f:SetSize(380, 165)
    f:SetPoint("TOP", UIParent, "TOP", 0, -135)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    ApplyDarkBackdrop(f, true)
    f:SetScript("OnHide", function(self)
        if self.ddList then
            self.ddList:Hide()
        end
        if not self.keepPending then
            ClearPendingSlots()
        end
    end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("GearSetHelper")

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -38)
    text:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -38)
    text:SetJustifyH("CENTER")
    text:SetWordWrap(true)
    f.text = text

    local ddLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ddLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 28, -74)
    ddLabel:SetText("Target Set:")

    local ddButton = CreateFrame("Button", nil, f, template)
    ddButton:SetSize(245, 26)
    ddButton:SetPoint("LEFT", ddLabel, "RIGHT", 8, 0)
    ApplyDarkBackdrop(ddButton, false)

    local ddIcon = ddButton:CreateTexture(nil, "ARTWORK")
    ddIcon:SetSize(18, 18)
    ddIcon:SetPoint("LEFT", ddButton, "LEFT", 6, 0)
    ddButton.icon = ddIcon

    local ddText = ddButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ddText:SetPoint("LEFT", ddIcon, "RIGHT", 6, 0)
    ddText:SetPoint("RIGHT", ddButton, "RIGHT", -22, 0)
    ddText:SetJustifyH("LEFT")
    ddButton.label = ddText

    local ddArrow = ddButton:CreateTexture(nil, "ARTWORK")
    ddArrow:SetSize(16, 16)
    ddArrow:SetPoint("RIGHT", ddButton, "RIGHT", -4, 0)
    ddArrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")

    local ddList = CreateFrame("Frame", nil, ddButton, template)
    ddList:SetPoint("TOPLEFT", ddButton, "BOTTOMLEFT", 0, -2)
    ddList:SetPoint("TOPRIGHT", ddButton, "BOTTOMRIGHT", 0, -2)
    ddList:SetFrameStrata("TOOLTIP")
    ApplyDarkBackdrop(ddList, false)
    ddList:Hide()

    f.ddButton = ddButton
    f.ddList = ddList
    f.optionButtons = {}

    ddButton:SetScript("OnClick", function()
        if ddList:IsShown() then
            ddList:Hide()
        else
            ddList:Show()
        end
    end)

    local btnUpdateSet = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnUpdateSet:SetSize(115, 24)
    btnUpdateSet:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 18)
    btnUpdateSet:SetText("Update Set")
    btnUpdateSet:SetScript("OnClick", function()
        local selectedEntry = f.selectedEntry
        local slots = CopyChangedSlotList()
        local isTest = f.isTest
        HidePrompt()
        if isTest then
            PrintMessage(string.format("Test prompt: would update %q. Nothing was changed.", selectedEntry and selectedEntry.name or "?"))
            return
        end
        UpdateSingleSetEntry(selectedEntry, slots)
    end)

    local btnAllSets = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnAllSets:SetSize(105, 24)
    btnAllSets:SetPoint("BOTTOM", f, "BOTTOM", 5, 18)
    btnAllSets:SetText("All Sets")
    btnAllSets:SetScript("OnClick", function()
        local slots = CopyChangedSlotList()
        local isTest = f.isTest
        HidePrompt()
        if isTest then
            PrintMessage("Test prompt: would update all sets. Nothing was changed.")
            return
        end
        UpdateAllSetEntries(slots)
    end)

    local btnIgnore = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnIgnore:SetSize(95, 24)
    btnIgnore:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 18)
    btnIgnore:SetText("Ignore")
    btnIgnore:SetScript("OnClick", function()
        HidePrompt()
    end)

    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "GearSetHelperPromptFrame")
    end

    promptFrame = f
    return f
end

local function SetPromptDropdownSelection(f, entry, isActive)
    f.selectedEntry = entry
    f.ddButton.icon:SetTexture((entry and entry.icon) or 134400)
    local name = (entry and entry.name) or "Set"
    if isActive then
        f.ddButton.label:SetText(string.format("%s |cff33ff99(Active)|r", name))
    else
        f.ddButton.label:SetText(name)
    end
end

local function PopulatePromptDropdown(f, sets, activeEntry)
    for _, btn in ipairs(f.optionButtons) do
        btn:Hide()
    end

    local rowHeight = 22
    local count = 0
    local defaultEntry, defaultIsActive

    for _, entry in ipairs(sets) do
        count = count + 1
        local isActive = (activeEntry ~= nil and entry.key == activeEntry.key)
        if not defaultEntry or isActive then
            defaultEntry = entry
            defaultIsActive = isActive
        end

        local optBtn = f.optionButtons[count]
        if not optBtn then
            optBtn = CreateFrame("Button", nil, f.ddList)
            optBtn:SetHeight(rowHeight)

            local hl = optBtn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 0.82, 0, 0.25)

            local icon = optBtn:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", optBtn, "LEFT", 6, 0)
            optBtn.icon = icon

            local label = optBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
            label:SetPoint("RIGHT", optBtn, "RIGHT", -6, 0)
            label:SetJustifyH("LEFT")
            optBtn.label = label

            f.optionButtons[count] = optBtn
        end

        optBtn:ClearAllPoints()
        optBtn:SetPoint("TOPLEFT", f.ddList, "TOPLEFT", 4, -4 - (count - 1) * rowHeight)
        optBtn:SetPoint("TOPRIGHT", f.ddList, "TOPRIGHT", -4, -4 - (count - 1) * rowHeight)
        optBtn.icon:SetTexture(entry.icon or 134400)
        if isActive then
            optBtn.label:SetText(string.format("%s |cff33ff99(Active)|r", entry.name))
        else
            optBtn.label:SetText(entry.name)
        end

        local capturedEntry, capturedActive = entry, isActive
        optBtn:SetScript("OnClick", function()
            SetPromptDropdownSelection(f, capturedEntry, capturedActive)
            f.ddList:Hide()
        end)
        optBtn:Show()
    end

    f.ddList:SetHeight(math.max(28, count * rowHeight + 8))
    if defaultEntry then
        SetPromptDropdownSelection(f, defaultEntry, defaultIsActive)
    end
end

-- Drops pending slots whose newly equipped item is already saved in some set.
local function FilterKnownItemSlots(sets)
    local remaining = {}
    for _, slotID in ipairs(pendingSlotOrder) do
        local itemID = GetInventoryItemID("player", slotID)
        if not (itemID and IsItemInAnySet(itemID, sets)) then
            table.insert(remaining, slotID)
        end
    end
    if #remaining ~= #pendingSlotOrder then
        ClearPendingSlots()
        for _, slotID in ipairs(remaining) do
            RecordChangedSlot(slotID)
        end
    end
    return #remaining > 0
end

local function ShowUpdatePrompt(isTest)
    if not isTest and not IsEnabled() then
        ClearPendingSlots()
        queuedForCombat = false
        return
    end

    if InCombatLockdown() then
        queuedForCombat = true
        return
    end
    queuedForCombat = false

    if not isTest then
        -- Several slots changing at once is a set swap (ItemRack, Outfitter, or a
        -- macro), not a new item.
        if #pendingSlotOrder >= SET_SWAP_SLOT_THRESHOLD then
            ClearPendingSlots()
            return
        end
        -- Only slots that still hold an item count; unequipping is not a new item.
        local filled = {}
        for _, slotID in ipairs(pendingSlotOrder) do
            if GetInventoryItemID("player", slotID) ~= nil then
                table.insert(filled, slotID)
            end
        end
        ClearPendingSlots()
        for _, slotID in ipairs(filled) do
            RecordChangedSlot(slotID)
        end
        if #filled == 0 then
            return
        end
    end

    local sets = GetAllConfiguredSets()
    if #sets == 0 then
        local slotSummary = FormatChangedSlots()
        ClearPendingSlots()
        PrintMessage(string.format(
            "Equipped new item in %s, but no equipment sets were found. Create a set first or run |cffffd100/gsh create <SetName>|r.",
            slotSummary
        ))
        return
    end

    if not isTest and GetSetting("skipKnownItems") and not FilterKnownItemSlots(sets) then
        ClearPendingSlots()
        return
    end

    local slotSummary = FormatChangedSlots()
    local _, changedSlotMap = CopyChangedSlotList()
    local activeEntry = ResolveActiveSetEntry(sets, changedSlotMap)

    local f = GetOrCreatePromptFrame()
    f.isTest = isTest and true or false
    if isTest then
        f.text:SetText(string.format("|cff888888[Test - buttons won't change anything]|r\nEquipped new item in |cffffd100%s|r.", slotSummary))
    else
        f.text:SetText(string.format("Equipped new item in |cffffd100%s|r.\nUpdate only that slot in your gear sets?", slotSummary))
    end
    PopulatePromptDropdown(f, sets, activeEntry)
    f.ddList:Hide()
    f:Show()
end

local function ScheduleDebouncedPrompt()
    if debounceTimer then
        debounceTimer:Cancel()
    end
    debounceTimer = C_Timer.NewTimer(DEBOUNCE_DELAY, function()
        debounceTimer = nil
        ShowUpdatePrompt(false)
    end)
end

-- ============================================================================
-- Enable / disable (slash command, key binding, settings panel)
-- ============================================================================

local RefreshOptionsPanel -- defined with the settings panel below

local function SetEnabled(value)
    InitDB()
    GearSetHelperDB.enabled = value and true or false
    if not GearSetHelperDB.enabled then
        if debounceTimer then
            debounceTimer:Cancel()
            debounceTimer = nil
        end
        ClearPendingSlots()
        queuedForCombat = false
        HidePrompt()
    end
    local stateText = GearSetHelperDB.enabled and "|cff00ff00enabled|r" or "|cffff4444disabled|r"
    PrintMessage("Update prompts " .. stateText .. ".")
    if RefreshOptionsPanel then
        RefreshOptionsPanel()
    end
end

-- Global so Bindings.xml can call it.
function GearSetHelper_Toggle()
    SetEnabled(not IsEnabled())
end

-- ============================================================================
-- Settings panel (Options -> AddOns -> GearSetHelper)
-- ============================================================================

local optionsPanel, optionsCategory
local optionCheckboxes = {}

RefreshOptionsPanel = function()
    for key, cb in pairs(optionCheckboxes) do
        cb:SetChecked(GetSetting(key) and true or false)
    end
    if optionsPanel and optionsPanel.bindingText then
        local key = GetBindingKey and GetBindingKey("GEARSETHELPER_TOGGLE")
        if key then
            optionsPanel.bindingText:SetText("Toggle key: |cffffd100" .. key .. "|r  (change it in Key Bindings > AddOns > GearSetHelper)")
        else
            optionsPanel.bindingText:SetText("Toggle key: |cff888888not bound|r  (set one in Key Bindings > AddOns > GearSetHelper)")
        end
    end
end

local function CreateOptionCheckbox(parent, anchor, key, label, description, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)

    local labelText = cb.text or cb.Text
    if not labelText then
        labelText = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    end
    labelText:SetFontObject("GameFontHighlight")
    labelText:ClearAllPoints()
    labelText:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    labelText:SetText(label)

    local desc = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 30, 2)
    desc:SetWidth(540)
    desc:SetJustifyH("LEFT")
    desc:SetTextColor(0.75, 0.75, 0.75)
    desc:SetText(description)

    cb:SetScript("OnClick", function(self)
        local value = self:GetChecked() and true or false
        if onChange then
            onChange(value)
        else
            InitDB()
            GearSetHelperDB[key] = value
        end
    end)

    optionCheckboxes[key] = cb
    return desc
end

local function CreateOptionsPanel()
    if optionsPanel then
        return
    end

    local panel = CreateFrame("Frame", "GearSetHelperOptionsPanel", UIParent)
    panel.name = "GearSetHelper"
    panel:Hide()

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("GearSetHelper |cff888888v" .. ADDON_VERSION .. "|r")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetWidth(560)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Offers to update your equipment sets when you equip a new item.")

    local anchor = CreateOptionCheckbox(panel, subtitle, "enabled",
        "Enable update prompts",
        "Show the set picker when you equip a new item. Also toggled with /gsh toggle or the key binding below.",
        function(value) SetEnabled(value) end)

    anchor = CreateOptionCheckbox(panel, anchor, "skipKnownItems",
        "Don't prompt for items already in a set",
        "Skip the prompt when the item you equipped is already saved in any of your sets, e.g. when swapping gear by hand.")

    anchor = CreateOptionCheckbox(panel, anchor, "showLoadMessage",
        "Show login message",
        "Print the \"Loaded\" line in chat when you log in.")

    local bindingText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    bindingText:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -30, -20)
    bindingText:SetJustifyH("LEFT")
    panel.bindingText = bindingText

    local testButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testButton:SetSize(140, 24)
    testButton:SetPoint("TOPLEFT", bindingText, "BOTTOMLEFT", 0, -16)
    testButton:SetText("Show test prompt")
    testButton:SetScript("OnClick", function()
        ClearPendingSlots()
        RecordChangedSlot(SLOT_FINGER1)
        ShowUpdatePrompt(true)
    end)

    panel:SetScript("OnShow", RefreshOptionsPanel)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        optionsCategory = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(optionsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end

    optionsPanel = panel
end

local function OpenOptionsPanel()
    if InCombatLockdown() then
        PrintMessage("Settings can't be opened in combat.")
        return
    end
    if optionsCategory and Settings and Settings.OpenToCategory then
        local id = (optionsCategory.GetID and optionsCategory:GetID()) or optionsCategory.ID
        -- Settings.OpenToCategory is an alias of C_SettingsUtil.OpenSettingsPanel on 12.x.
        local ok = pcall(Settings.OpenToCategory, id)
        if not ok and C_SettingsUtil and C_SettingsUtil.OpenSettingsPanel then
            pcall(C_SettingsUtil.OpenSettingsPanel, id)
        end
    elseif optionsPanel and InterfaceOptionsFrame_OpenToCategory then
        -- Called twice: the first call can land on the wrong page on older clients.
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    else
        PrintMessage("Open Options > AddOns > GearSetHelper.")
    end
end

-- ============================================================================
-- Events
-- ============================================================================

local eventFrame = CreateFrame("Frame", "GearSetHelperFrame")
for _, ev in ipairs({
    "ADDON_LOADED",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_EQUIPMENT_CHANGED",
    "EQUIPMENT_SWAP_PENDING",
    "EQUIPMENT_SWAP_FINISHED",
    "EQUIPMENT_SETS_CHANGED",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
}) do
    pcall(eventFrame.RegisterEvent, eventFrame, ev)
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            InitDB()
            CreateOptionsPanel()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if SetCVar then
            pcall(SetCVar, "equipmentManager", "1")
        end
        RefreshLastActiveSet()
        if not hasPrintedLoadMessage then
            hasPrintedLoadMessage = true
            if GetSetting("showLoadMessage") then
                local sets = GetAllConfiguredSets()
                local state = IsEnabled() and "" or " |cffff4444(prompts disabled)|r"
                PrintMessage(string.format("Loaded v%s (%d %s detected)%s. Type |cffffd100/gsh|r for commands.",
                    ADDON_VERSION, #sets, #sets == 1 and "set" or "sets", state))
            end
        end

    elseif event == "EQUIPMENT_SWAP_PENDING" then
        if isInternalOperation then
            return
        end
        isSwappingSet = true
        if debounceTimer then
            debounceTimer:Cancel()
            debounceTimer = nil
        end
        -- A prompt left open across a set swap would describe gear that is no longer worn.
        HidePrompt()
        ClearPendingSlots()

    elseif event == "EQUIPMENT_SWAP_FINISHED" then
        -- Always clear the swap flag, even mid-operation, so it can never get stuck on.
        C_Timer.After(0.1, function()
            isSwappingSet = false
        end)
        if isInternalOperation then
            return
        end
        local completed, setID = ...
        if completed and setID ~= nil then
            lastActiveSetKey = "blizzard:" .. tostring(setID)
        else
            RefreshLastActiveSet()
        end

    elseif event == "EQUIPMENT_SETS_CHANGED" then
        if not isInternalOperation then
            RefreshLastActiveSet()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- The second payload (hasCurrent) has meant opposite things across client
        -- versions, so check the slot directly instead.
        local equipmentSlot = ...
        if not IsEnabled() or isSwappingSet or isInternalOperation then
            return
        end
        if not equipmentSlot or GetInventoryItemID("player", equipmentSlot) == nil then
            return
        end
        RecordChangedSlot(equipmentSlot)
        ScheduleDebouncedPrompt()

    elseif event == "PLAYER_REGEN_DISABLED" then
        if debounceTimer then
            debounceTimer:Cancel()
            debounceTimer = nil
            queuedForCombat = true
        end
        if promptFrame and promptFrame:IsShown() then
            HidePrompt(true)
            queuedForCombat = true
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingCombatRestore then
            ClearPendingSlots()
            queuedForCombat = false
            RunPendingCombatRestore()
        elseif queuedForCombat then
            ShowUpdatePrompt(false)
        end
    end
end)

-- ============================================================================
-- Slash commands (/gsh and /gearsethelper)
-- ============================================================================

SLASH_GEARSETHELPER1 = "/gsh"
SLASH_GEARSETHELPER2 = "/gearsethelper"

SlashCmdList["GEARSETHELPER"] = function(msg)
    InitDB()

    local raw = string.match(msg or "", "^%s*(.-)%s*$") or ""
    local command, rest = string.match(raw, "^(%S+)%s*(.-)$")
    command = string.lower(command or "")

    if command == "toggle" then
        GearSetHelper_Toggle()

    elseif command == "on" or command == "enable" then
        SetEnabled(true)

    elseif command == "off" or command == "disable" then
        SetEnabled(false)

    elseif command == "config" or command == "options" or command == "settings" then
        OpenOptionsPanel()

    elseif command == "status" then
        local stateText = IsEnabled() and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
        local sets = GetAllConfiguredSets()
        local activeEntry = ResolveActiveSetEntry(sets)
        PrintMessage(string.format(
            "Status: %s | Sets: %d | Active set: %s | Skip items already in a set: %s",
            stateText, #sets, activeEntry and activeEntry.name or "None",
            GetSetting("skipKnownItems") and "on" or "off"
        ))

    elseif command == "test" then
        ClearPendingSlots()
        RecordChangedSlot(SLOT_FINGER1)
        ShowUpdatePrompt(true)

    elseif command == "create" and rest and rest ~= "" then
        if C_EquipmentSet and C_EquipmentSet.CreateEquipmentSet then
            C_EquipmentSet.CreateEquipmentSet(rest)
            PrintMessage(string.format("Created equipment set %q from currently equipped gear.", rest))
        else
            PrintMessage("C_EquipmentSet.CreateEquipmentSet is not available on this client.")
        end

    else
        PrintMessage("Commands:")
        PrintMessage("  |cffffd100/gsh toggle|r - Turn update prompts on or off (also /gsh on, /gsh off).")
        PrintMessage("  |cffffd100/gsh config|r - Open the settings panel.")
        PrintMessage("  |cffffd100/gsh status|r - Show addon status and detected sets.")
        PrintMessage("  |cffffd100/gsh test|r - Open a test update prompt.")
        PrintMessage("  |cffffd100/gsh create <Name>|r - Create an equipment set from your current gear.")
    end
end
