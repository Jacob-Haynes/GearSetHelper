local addonName, ns = ...

local POPUP_KEY = "GEARSET_UPDATE_PROMPT"
local DEBOUNCE_DELAY = 0.25
local CHAT_PREFIX = "|cff33ff99[GearSetHelper]|r "

-- State tracking
local isSwappingSet = false
local isInternalOperation = false
local isRefreshingPopup = false
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
    SLOT_HEAD,
    SLOT_NECK,
    SLOT_SHOULDER,
    SLOT_BODY,
    SLOT_CHEST,
    SLOT_WAIST,
    SLOT_LEGS,
    SLOT_FEET,
    SLOT_WRIST,
    SLOT_HAND,
    SLOT_FINGER1,
    SLOT_FINGER2,
    SLOT_TRINKET1,
    SLOT_TRINKET2,
    SLOT_BACK,
    SLOT_MAINHAND,
    SLOT_OFFHAND,
    SLOT_RANGED,
    SLOT_TABARD,
}

local function PrintMessage(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. tostring(msg))
    else
        print(CHAT_PREFIX .. tostring(msg))
    end
end

local function IsEnabled()
    return GearSetHelperDB and GearSetHelperDB.enabled ~= false
end

local function ClearPendingSlots()
    wipe(pendingSlots)
    wipe(pendingSlotOrder)
end

local function RecordChangedSlot(slotID)
    if not slotID then
        return
    end
    if not pendingSlots[slotID] then
        pendingSlots[slotID] = true
        table.insert(pendingSlotOrder, slotID)
    end
end

local function CopyChangedSlotList()
    local list = {}
    local map = {}
    for _, slotID in ipairs(pendingSlotOrder) do
        table.insert(list, slotID)
        map[slotID] = true
    end
    return list, map
end

local function FormatChangedSlots()
    local names = {}
    for _, slotID in ipairs(pendingSlotOrder) do
        table.insert(names, SLOT_NAMES[slotID] or ("Slot " .. tostring(slotID)))
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
    return {
        slotID = slotID,
        link = link,
        itemID = itemID,
        guid = guid,
    }
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

local function DoesCurrentGearMatchSnapshot(snapshot)
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        local expected = snapshot[slotID]
        if expected and not IsItemEquippedInSlot(expected, slotID) then
            return false
        end
    end
    return true
end

-- Equips a single snapshotted item into `targetSlotID` using Blizzard's standard
-- PickupContainerItem + PickupInventoryItem pattern (never calling ClearCursor after!).
local function EquipSnapshottedItemIntoSlot(itemInfo, targetSlotID, usedBagSlots)
    if not itemInfo then
        return true
    end
    if IsItemEquippedInSlot(itemInfo, targetSlotID) then
        return true
    end

    usedBagSlots = usedBagSlots or {}

    -- Check if the item is currently in another equipment slot (e.g. Ring 1 vs Ring 2)
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

    -- 1. Exact GUID match in bags
    if itemInfo.guid then
        for bag = 0, maxBag do
            local numSlots = GetNumBagSlots(bag)
            for bagSlot = 1, numSlots do
                local key = bag .. ":" .. bagSlot
                if not usedBagSlots[key] and GetBagSlotGUID(bag, bagSlot) == itemInfo.guid then
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

    -- 2. Exact itemLink match in bags
    if itemInfo.link then
        for bag = 0, maxBag do
            local numSlots = GetNumBagSlots(bag)
            for bagSlot = 1, numSlots do
                local key = bag .. ":" .. bagSlot
                if not usedBagSlots[key] and GetBagItemLink(bag, bagSlot) == itemInfo.link then
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

    -- 3. ItemID match in bags
    if itemInfo.itemID then
        for bag = 0, maxBag do
            local numSlots = GetNumBagSlots(bag)
            for bagSlot = 1, numSlots do
                local key = bag .. ":" .. bagSlot
                if not usedBagSlots[key] and GetBagItemID(bag, bagSlot) == itemInfo.itemID then
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

    -- 4. Native EquipItemByName fallback
    if EquipItemByName and (itemInfo.link or itemInfo.itemID) then
        pcall(EquipItemByName, itemInfo.link or itemInfo.itemID, targetSlotID)
        return true
    end

    return false
end

local function EquipGearSnapshot(snapshot)
    local usedBagSlots = {}
    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        local itemInfo = snapshot[slotID]
        if itemInfo and not IsItemEquippedInSlot(itemInfo, slotID) then
            EquipSnapshottedItemIntoSlot(itemInfo, slotID, usedBagSlots)
        end
    end
end

-- Unpacks a location value from `C_EquipmentSet.GetItemLocations(setID)` across all WoW versions
local function UnpackSetItemLocation(location)
    if not location or location < 0 then
        return nil
    end

    if type(EquipmentManager_GetLocationData) == "function" then
        local ok, data = pcall(EquipmentManager_GetLocationData, location)
        if ok and type(data) == "table" then
            return {
                isPlayer = data.isPlayer or false,
                isBank   = data.isBank or false,
                isBags   = data.isBags or false,
                slot     = data.slot,
                bag      = data.bag,
            }
        end
    end

    local locPlayer = ITEM_INVENTORY_LOCATION_PLAYER or 0x00100000
    local locBank   = ITEM_INVENTORY_LOCATION_BANK   or 0x00200000
    local locBags   = ITEM_INVENTORY_LOCATION_BAGS   or 0x00400000
    local bagOffset = ITEM_INVENTORY_BAG_BIT_OFFSET  or 8

    local isPlayer = (bit.band(location, locPlayer) ~= 0)
    local isBank   = (bit.band(location, locBank) ~= 0)
    local isBags   = (bit.band(location, locBags) ~= 0)

    local slot = location
    if isPlayer then
        slot = slot - locPlayer
    elseif isBank then
        slot = slot - locBank
    end

    local bag = nil
    if isBags then
        slot = slot - locBags
        bag = bit.rshift(slot, bagOffset)
        slot = slot - bit.lshift(bag, bagOffset)
    end

    return {
        isPlayer = isPlayer,
        isBank   = isBank,
        isBags   = isBags,
        slot     = slot,
        bag      = bag,
    }
end

-- Equips all items belonging to `setID` EXCEPT `changedSlotMap`, keeping `newSlotItems`
-- equipped in `changedSlotMap`. Executed synchronously inside `OnClick` (hardware event)!
local function EquipBlizzardSetExceptChangedSlots(setID, changedSlotMap, newSlotItems)
    local usedBagSlots = {}

    -- Ensure the newly equipped item(s) are in their changed slots
    if newSlotItems then
        for slotID, itemInfo in pairs(newSlotItems) do
            if itemInfo and not IsItemEquippedInSlot(itemInfo, slotID) then
                EquipSnapshottedItemIntoSlot(itemInfo, slotID, usedBagSlots)
            end
        end
    end

    local okLoc, locations = false, nil
    if C_EquipmentSet.GetItemLocations then
        okLoc, locations = pcall(C_EquipmentSet.GetItemLocations, setID)
    end

    local okIDs, itemIDs = false, nil
    if C_EquipmentSet.GetItemIDs then
        okIDs, itemIDs = pcall(C_EquipmentSet.GetItemIDs, setID)
    end

    local ignoredSlots = nil
    if C_EquipmentSet.GetIgnoredSlots then
        local okIgn, ign = pcall(C_EquipmentSet.GetIgnoredSlots, setID)
        if okIgn and type(ign) == "table" then
            ignoredSlots = ign
        end
    end

    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        local isChanged = changedSlotMap and changedSlotMap[slotID]
        local isIgnored = ignoredSlots and ignoredSlots[slotID]

        if not isChanged and not isIgnored then
            local handled = false
            local location = (okLoc and type(locations) == "table") and locations[slotID] or nil

            if location and location > 1 then
                local loc = UnpackSetItemLocation(location)
                if loc then
                    if loc.isBags and loc.bag ~= nil and loc.slot ~= nil then
                        local key = loc.bag .. ":" .. loc.slot
                        usedBagSlots[key] = true
                        if EquipmentManager_EquipItemByLocation and EquipmentManager_RunAction then
                            local okAct, action = pcall(EquipmentManager_EquipItemByLocation, location, slotID)
                            if okAct and action then
                                pcall(EquipmentManager_RunAction, action)
                                handled = true
                            end
                        end
                        if not handled then
                            ClearCursor()
                            PickupBagItem(loc.bag, loc.slot)
                            if CursorHasItem() then
                                PickupInventoryItem(slotID)
                                handled = true
                            end
                        end
                    elseif loc.isPlayer and not loc.isBags and loc.slot then
                        if loc.slot == slotID then
                            handled = true
                        else
                            ClearCursor()
                            PickupInventoryItem(loc.slot)
                            if CursorHasItem() then
                                PickupInventoryItem(slotID)
                                handled = true
                            end
                        end
                    end
                end
            end

            -- Fallback: match by itemID in bags if location unpacking wasn't used
            if not handled and okIDs and type(itemIDs) == "table" then
                local targetItemID = itemIDs[slotID]
                if targetItemID and targetItemID > 0 and GetInventoryItemID("player", slotID) ~= targetItemID then
                    EquipSnapshottedItemIntoSlot({ itemID = targetItemID }, slotID, usedBagSlots)
                end
            end
        end
    end
end

-- Checks whether the player is currently wearing every available item of a Blizzard set
-- (excluding the newly changed slots), so we know if all slots are ready to save.
local function IsBlizzardSetCurrentlyWornExceptChangedSlots(setID, changedSlotMap)
    if not C_EquipmentSet or not C_EquipmentSet.GetItemIDs then
        local _, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        return isEquipped and true or false
    end

    local ok, itemIDs = pcall(C_EquipmentSet.GetItemIDs, setID)
    if not ok or type(itemIDs) ~= "table" then
        local _, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        return isEquipped and true or false
    end

    local ignoredSlots = nil
    if C_EquipmentSet.GetIgnoredSlots then
        local okIgn, ign = pcall(C_EquipmentSet.GetIgnoredSlots, setID)
        if okIgn and type(ign) == "table" then
            ignoredSlots = ign
        end
    end

    for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
        local isChangedSlot = changedSlotMap and changedSlotMap[slotID]
        local isIgnoredSlot = ignoredSlots and ignoredSlots[slotID]
        if not isChangedSlot and not isIgnoredSlot then
            local setItemID = itemIDs[slotID]
            if setItemID and setItemID > 0 then
                local wornItemID = GetInventoryItemID("player", slotID)
                if wornItemID ~= setItemID then
                    return false
                end
            end
        end
    end

    return true
end

-- ============================================================================
-- Unified Equipment Set Providers
-- ============================================================================

local function GetAllConfiguredSets()
    local sets = {}

    -- 1. Check ItemRack sets
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

    -- 2. Check Outfitter sets
    if type(gOutfitter_Settings) == "table" and type(gOutfitter_Settings.Outfits) == "table" then
        for category, outfitList in pairs(gOutfitter_Settings.Outfits) do
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

    -- 3. Check Blizzard C_EquipmentSet
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

local function RefreshLastActiveSet()
    local sets = GetAllConfiguredSets()
    if #sets == 0 then
        lastActiveSetKey = nil
        return
    end
    for _, s in ipairs(sets) do
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
            if s.provider == "blizzard" and IsBlizzardSetCurrentlyWornExceptChangedSlots(s.id, changedSlotMap) then
                return s
            end
        end
    end

    local bestFallback = nil
    local bestEquippedCount = -1
    for _, s in ipairs(sets) do
        if (s.numEquipped or 0) > bestEquippedCount then
            bestEquippedCount = s.numEquipped or 0
            bestFallback = s
        end
    end

    return bestFallback or sets[1]
end

-- Saves a Blizzard C_EquipmentSet while preserving its ignored slots.
local function SaveBlizzardSetPreservingIgnoredSlots(setID, changedSlotMap)
    local name = C_EquipmentSet.GetEquipmentSetInfo(setID)
    if not name then
        return false, nil
    end

    if C_EquipmentSet.GetIgnoredSlots and C_EquipmentSet.ClearIgnoredSlotsForSave and C_EquipmentSet.IgnoreSlotForSave then
        local ok, ignoredSlots = pcall(C_EquipmentSet.GetIgnoredSlots, setID)
        if ok and type(ignoredSlots) == "table" then
            C_EquipmentSet.ClearIgnoredSlotsForSave()
            for slot, isIgnored in pairs(ignoredSlots) do
                if isIgnored and not (changedSlotMap and changedSlotMap[slot]) then
                    C_EquipmentSet.IgnoreSlotForSave(slot)
                end
            end
        end
    end

    C_EquipmentSet.SaveEquipmentSet(setID)
    return true, name
end

-- Updates only the changed slot(s) in an ItemRack set directly in `ItemRackUser.Sets`.
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

-- Updates only the changed slot(s) in an Outfitter outfit directly.
local function UpdateOutfitterSetSlots(outfit, changedSlotList)
    if type(outfit) ~= "table" or not outfit.Name then
        return false, nil
    end
    outfit.Items = outfit.Items or {}
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
    local slotsToUpdate = (#changedSlotList > 0) and changedSlotList or ALL_EQUIPMENT_SLOTS
    for _, slotID in ipairs(slotsToUpdate) do
        local slotName = SLOT_TO_OUTFITTER[slotID]
        local itemID = GetInventoryItemID("player", slotID)
        if slotName and itemID then
            local itemName, itemLink = GetItemInfo(itemID)
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

-- Forward declaration for continuation UI when a hardware click is needed
local ShowHardwareContinuationPrompt

-- ============================================================================
-- Hardware-Safe Slot-Only Set Update Pipeline
-- ============================================================================

-- Polls until inventory item locks clear after an `OnClick` swap, then invokes `onReady()`.
local function WaitForSwapLocksToSettle(targetSetID, changedSlotMap, onReady)
    local attempts = 0
    local maxAttempts = 25 -- up to 2.5s

    local function Check()
        if InCombatLockdown() then
            onReady(false)
            return
        end
        attempts = attempts + 1
        local locked = AnyEquippedSlotLocked()
        local worn = IsBlizzardSetCurrentlyWornExceptChangedSlots(targetSetID, changedSlotMap)

        if not locked and (worn or attempts >= 4) then
            C_Timer.After(0.1, function()
                onReady(true)
            end)
            return
        end

        if attempts >= maxAttempts then
            onReady(true)
            return
        end

        C_Timer.After(0.1, Check)
    end

    C_Timer.After(0.15, Check)
end

local function RunSlotOnlySetUpdates(targetEntries, changedSlotList, changedSlotMap, summaryMode)
    if InCombatLockdown() then
        PrintMessage("Cannot update equipment sets while in combat.")
        return
    end
    if not targetEntries or #targetEntries == 0 then
        return
    end

    local allSets = GetAllConfiguredSets()
    local activeEntry = ResolveActiveSetEntry(allSets, changedSlotMap)
    local currentActiveKey = activeEntry and activeEntry.key or nil

    local originalWornGear = SnapshotAllWornGear()
    local newSlotItems = {}
    for _, slotID in ipairs(changedSlotList) do
        newSlotItems[slotID] = originalWornGear[slotID]
    end

    isInternalOperation = true
    local updatedNames = {}
    local blizzardNonActiveQueue = {}

    for _, entry in ipairs(targetEntries) do
        if entry.provider == "itemrack" then
            local ok, name = UpdateItemRackSetSlots(entry.id, changedSlotList)
            if ok then
                table.insert(updatedNames, name)
            end
        elseif entry.provider == "outfitter" then
            local ok, name = UpdateOutfitterSetSlots(entry.outfitRef, changedSlotList)
            if ok then
                table.insert(updatedNames, name)
            end
        elseif entry.provider == "blizzard" then
            local isAlreadyWorn = (#changedSlotList == 0)
                or IsBlizzardSetCurrentlyWornExceptChangedSlots(entry.id, changedSlotMap)
            if isAlreadyWorn then
                local ok, name = SaveBlizzardSetPreservingIgnoredSlots(entry.id, changedSlotMap)
                if ok then
                    table.insert(updatedNames, name)
                    lastActiveSetKey = entry.key
                end
            else
                table.insert(blizzardNonActiveQueue, entry)
            end
        end
    end

    -- If no non-active Blizzard sets need swapping, finish immediately!
    if #blizzardNonActiveQueue == 0 then
        isInternalOperation = false
        local count = #updatedNames
        if summaryMode == "all" and count > 0 then
            PrintMessage(string.format("Updated %d %s.", count, count == 1 and "set" or "sets"))
        elseif count == 1 then
            PrintMessage(string.format("Updated set %q.", updatedNames[1]))
        end
        return
    end

    local queueIndex = 0

    local function FinishComplete()
        isInternalOperation = false
        if currentActiveKey then
            lastActiveSetKey = currentActiveKey
        else
            RefreshLastActiveSet()
        end

        local count = #updatedNames
        if summaryMode == "all" then
            PrintMessage(string.format("Updated %d %s.", count, count == 1 and "set" or "sets"))
        elseif count == 1 then
            PrintMessage(string.format("Updated set %q (equipped slot only).", updatedNames[1]))
        elseif count > 1 then
            PrintMessage(string.format("Updated %d sets.", count))
        end
    end

    local function RestoreOriginalGearStep()
        if DoesCurrentGearMatchSnapshot(originalWornGear) then
            FinishComplete()
            return
        end

        -- Try restoring automatically first
        EquipGearSnapshot(originalWornGear)

        C_Timer.After(0.35, function()
            if DoesCurrentGearMatchSnapshot(originalWornGear) then
                FinishComplete()
            else
                -- Client requires a hardware click to swap back to the original gear
                local activeName = (activeEntry and activeEntry.name) or "Equipped Gear"
                ShowHardwareContinuationPrompt(
                    string.format("Saved %q!\nClick below to switch back to %s:", updatedNames[#updatedNames] or "Set", activeName),
                    "Restore " .. activeName,
                    function()
                        EquipGearSnapshot(originalWornGear)
                        C_Timer.After(0.25, FinishComplete)
                    end,
                    FinishComplete
                )
            end
        end)
    end

    -- Executes inside a hardware event (`OnClick`) to swap into `targetEntry`'s non-changed slots,
    -- wait for locks to clear, save `targetEntry`, and advance.
    local function ExecuteNonActiveSetInHardwareEvent(targetEntry)
        local targetSetID = targetEntry.id
        local setName = C_EquipmentSet.GetEquipmentSetInfo(targetSetID)
        if not setName then
            return
        end

        -- Synchronously inside `OnClick`: equip all of `targetSetID`'s items EXCEPT `changedSlotMap`,
        -- leaving the newly equipped item worn in `changedSlotMap`!
        EquipBlizzardSetExceptChangedSlots(targetSetID, changedSlotMap, newSlotItems)

        WaitForSwapLocksToSettle(targetSetID, changedSlotMap, function()
            if not InCombatLockdown() then
                local ok, savedName = SaveBlizzardSetPreservingIgnoredSlots(targetSetID, changedSlotMap)
                if ok then
                    table.insert(updatedNames, savedName)
                end
            end

            queueIndex = queueIndex + 1
            local nextEntry = blizzardNonActiveQueue[queueIndex]
            if not nextEntry then
                C_Timer.After(0.2, RestoreOriginalGearStep)
            else
                -- Try starting the next set automatically; if blocked by hardware restriction, prompt 1 click
                EquipBlizzardSetExceptChangedSlots(nextEntry.id, changedSlotMap, newSlotItems)
                C_Timer.After(0.35, function()
                    if IsBlizzardSetCurrentlyWornExceptChangedSlots(nextEntry.id, changedSlotMap) then
                        local ok, savedName = SaveBlizzardSetPreservingIgnoredSlots(nextEntry.id, changedSlotMap)
                        if ok then
                            table.insert(updatedNames, savedName)
                        end
                        queueIndex = queueIndex + 1
                        if not blizzardNonActiveQueue[queueIndex] then
                            C_Timer.After(0.2, RestoreOriginalGearStep)
                        else
                            local upcoming = blizzardNonActiveQueue[queueIndex]
                            ShowHardwareContinuationPrompt(
                                string.format("Saved %q!\nClick to update next set (%s):", savedName or "Set", upcoming.name),
                                "Update " .. upcoming.name,
                                function()
                                    ExecuteNonActiveSetInHardwareEvent(upcoming)
                                end,
                                RestoreOriginalGearStep
                            )
                        end
                    else
                        ShowHardwareContinuationPrompt(
                            string.format("Saved %q!\nClick to update next set (%s):", updatedNames[#updatedNames] or "Set", nextEntry.name),
                            "Update " .. nextEntry.name,
                            function()
                                ExecuteNonActiveSetInHardwareEvent(nextEntry)
                            end,
                            RestoreOriginalGearStep
                        )
                    end
                end)
            end
        end)
    end

    -- Kick off the first non-active set SYNCHRONOUSLY inside the current `OnClick` hardware event!
    queueIndex = 1
    ExecuteNonActiveSetInHardwareEvent(blizzardNonActiveQueue[1])
end

local function UpdateSingleSetEntry(entry, changedSlotList, changedSlotMap)
    if not entry then
        entry = ResolveActiveSetEntry(nil, changedSlotMap)
    end
    if not entry then
        return
    end
    changedSlotList = changedSlotList or {}
    changedSlotMap = changedSlotMap or {}
    RunSlotOnlySetUpdates({ entry }, changedSlotList, changedSlotMap, "single")
end

local function UpdateAllSetEntries(changedSlotList, changedSlotMap)
    local sets = GetAllConfiguredSets()
    if #sets == 0 then
        return
    end
    changedSlotList = changedSlotList or {}
    changedSlotMap = changedSlotMap or {}
    RunSlotOnlySetUpdates(sets, changedSlotList, changedSlotMap, "all")
end

-- Keep StaticPopupDialogs["GEARSET_UPDATE_PROMPT"] registered for compatibility
StaticPopupDialogs[POPUP_KEY] = {
    text = "Equipped new item in %s. Update gear sets?",
    button1 = "Active Set",
    button2 = "All Sets",
    button3 = "Ignore",
    OnShow = function(self, data)
        local activeButtonText = "Active Set"
        if data and data.activeSetName then
            activeButtonText = string.format("Active Set (%s)", data.activeSetName)
        end
        local btn1 = self.button1 or (self.GetButton1 and self:GetButton1())
        if btn1 then
            btn1:SetText(activeButtonText)
        end
    end,
    OnAccept = function(self, data)
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        UpdateSingleSetEntry(data and data.activeEntry or nil, slots, slotMap)
    end,
    OnCancel = function(self, data, reason)
        if isRefreshingPopup then
            return
        end
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        if reason == "override" or reason == "clicked" then
            UpdateAllSetEntries(slots, slotMap)
        end
    end,
    OnAlt = function()
        ClearPendingSlots()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Safe Backdrop helper that works across all Classic / Forever / Retail clients
local function ApplyDarkBackdrop(frame, isDialog)
    if not frame.SetBackdrop and BackdropTemplateMixin then
        Mixin(frame, BackdropTemplateMixin)
    end
    if frame.SetBackdrop then
        if isDialog then
            frame:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true,
                tileSize = 32,
                edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 },
            })
        else
            frame:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true,
                tileSize = 16,
                edgeSize = 14,
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

-- Custom Prompt Dialog with Set Selector Dropdown
local promptFrame = nil

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

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("GearSetHelper")
    f.title = title

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -38)
    text:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -38)
    text:SetJustifyH("CENTER")
    text:SetWordWrap(true)
    f.text = text

    local ddLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ddLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 28, -74)
    ddLabel:SetText("Target Set:")
    f.ddLabel = ddLabel

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
    f.btnUpdateSet = btnUpdateSet

    local btnAllSets = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnAllSets:SetSize(105, 24)
    btnAllSets:SetPoint("BOTTOM", f, "BOTTOM", 5, 18)
    btnAllSets:SetText("All Sets")
    f.btnAllSets = btnAllSets

    local btnIgnore = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnIgnore:SetSize(95, 24)
    btnIgnore:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 18)
    btnIgnore:SetText("Ignore")
    f.btnIgnore = btnIgnore

    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "GearSetHelperPromptFrame")
    end

    promptFrame = f
    return f
end

local function ConfigureStandardPromptButtons(f)
    f.ddLabel:Show()
    f.ddButton:Show()

    f.btnUpdateSet:SetSize(115, 24)
    f.btnUpdateSet:ClearAllPoints()
    f.btnUpdateSet:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 18)
    f.btnUpdateSet:SetText("Update Set")
    f.btnUpdateSet:SetScript("OnClick", function()
        local selectedEntry = f.selectedEntry
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        f.ddList:Hide()
        f:Hide()
        UpdateSingleSetEntry(selectedEntry, slots, slotMap)
    end)
    f.btnUpdateSet:Show()

    f.btnAllSets:SetSize(105, 24)
    f.btnAllSets:ClearAllPoints()
    f.btnAllSets:SetPoint("BOTTOM", f, "BOTTOM", 5, 18)
    f.btnAllSets:SetText("All Sets")
    f.btnAllSets:SetScript("OnClick", function()
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        f.ddList:Hide()
        f:Hide()
        UpdateAllSetEntries(slots, slotMap)
    end)
    f.btnAllSets:Show()

    f.btnIgnore:SetSize(95, 24)
    f.btnIgnore:ClearAllPoints()
    f.btnIgnore:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 18)
    f.btnIgnore:SetText("Ignore")
    f.btnIgnore:SetScript("OnClick", function()
        ClearPendingSlots()
        f.ddList:Hide()
        f:Hide()
    end)
    f.btnIgnore:Show()
end

-- Shown only if the WoW client blocks an automated post-save gear restore/swap inside a timer,
-- giving a 1-click hardware event button to finish restoring or advancing.
ShowHardwareContinuationPrompt = function(messageText, primaryButtonText, onPrimaryClick, onCancelClick)
    if InCombatLockdown() then
        if onCancelClick then
            onCancelClick()
        end
        return
    end

    local f = GetOrCreatePromptFrame()
    f.ddList:Hide()
    f.ddLabel:Hide()
    f.ddButton:Hide()
    f.text:SetText(messageText)

    f.btnUpdateSet:SetSize(210, 26)
    f.btnUpdateSet:ClearAllPoints()
    f.btnUpdateSet:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 18)
    f.btnUpdateSet:SetText(primaryButtonText)
    f.btnUpdateSet:SetScript("OnClick", function()
        f:Hide()
        if onPrimaryClick then
            onPrimaryClick()
        end
    end)
    f.btnUpdateSet:Show()

    f.btnAllSets:Hide()

    f.btnIgnore:SetSize(105, 26)
    f.btnIgnore:ClearAllPoints()
    f.btnIgnore:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 18)
    f.btnIgnore:SetText("Keep Current")
    f.btnIgnore:SetScript("OnClick", function()
        f:Hide()
        if onCancelClick then
            onCancelClick()
        end
    end)
    f.btnIgnore:Show()

    f:Show()
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

        optBtn:SetPoint("TOPLEFT", f.ddList, "TOPLEFT", 4, -4 - (count - 1) * rowHeight)
        optBtn:SetPoint("TOPRIGHT", f.ddList, "TOPRIGHT", -4, -4 - (count - 1) * rowHeight)
        optBtn.icon:SetTexture(entry.icon or 134400)
        if isActive then
            optBtn.label:SetText(string.format("%s |cff33ff99(Active)|r", entry.name))
        else
            optBtn.label:SetText(entry.name)
        end

        local capturedEntry = entry
        local capturedActive = isActive
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

local function HideUpdatePromptForCombat()
    if promptFrame and promptFrame:IsShown() then
        promptFrame.ddList:Hide()
        promptFrame:Hide()
        return true
    end
    if StaticPopup_Visible(POPUP_KEY) then
        isRefreshingPopup = true
        StaticPopup_Hide(POPUP_KEY)
        isRefreshingPopup = false
        return true
    end
    return false
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

    local sets = GetAllConfiguredSets()
    if #sets == 0 then
        local slotSummary = FormatChangedSlots()
        ClearPendingSlots()
        queuedForCombat = false
        PrintMessage(string.format(
            "Equipped new item in %s, but 0 equipment sets were detected. Create a set first or run |cffffd100/gsh create <SetName>|r.",
            slotSummary
        ))
        return
    end

    local slotSummary = FormatChangedSlots()
    local _, changedSlotMap = CopyChangedSlotList()
    queuedForCombat = false

    local activeEntry = ResolveActiveSetEntry(sets, changedSlotMap)
    local f = GetOrCreatePromptFrame()
    ConfigureStandardPromptButtons(f)
    f.text:SetText(string.format("Equipped new item in |cffffd100%s|r.\nUpdate only that slot in your gear sets?", slotSummary))
    PopulatePromptDropdown(f, sets, activeEntry)
    f.ddList:Hide()
    f:Show()
end

local function ScheduleDebouncedPrompt()
    if debounceTimer then
        debounceTimer:Cancel()
        debounceTimer = nil
    end

    debounceTimer = C_Timer.NewTimer(DEBOUNCE_DELAY, function()
        debounceTimer = nil
        ShowUpdatePrompt(false)
    end)
end

-- Event frame setup
local eventFrame = CreateFrame("Frame", "GearSetHelperFrame")
local EVENTS_TO_REGISTER = {
    "ADDON_LOADED",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_EQUIPMENT_CHANGED",
    "EQUIPMENT_SWAP_PENDING",
    "EQUIPMENT_SWAP_FINISHED",
    "EQUIPMENT_SETS_CHANGED",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
}
for _, ev in ipairs(EVENTS_TO_REGISTER) do
    pcall(eventFrame.RegisterEvent, eventFrame, ev)
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            GearSetHelperDB = GearSetHelperDB or {}
            if GearSetHelperDB.enabled == nil then
                GearSetHelperDB.enabled = true
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if SetCVar then
            pcall(SetCVar, "equipmentManager", "1")
        end
        RefreshLastActiveSet()
        if not hasPrintedLoadMessage then
            hasPrintedLoadMessage = true
            local sets = GetAllConfiguredSets()
            PrintMessage(string.format("Loaded v1.0.5 (%d %s detected). Type |cffffd100/gsh|r for commands.", #sets, #sets == 1 and "set" or "sets"))
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
        ClearPendingSlots()

    elseif event == "EQUIPMENT_SWAP_FINISHED" then
        local completed, setID = ...
        if isInternalOperation then
            return
        end

        if completed and setID ~= nil then
            lastActiveSetKey = "blizzard:" .. tostring(setID)
        else
            RefreshLastActiveSet()
        end
        C_Timer.After(0.1, function()
            isSwappingSet = false
        end)

    elseif event == "EQUIPMENT_SETS_CHANGED" then
        if not isInternalOperation then
            RefreshLastActiveSet()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local equipmentSlot, hasCurrent = ...
        local slotHasItem = (hasCurrent == true) or (hasCurrent == 1) or (GetInventoryItemID("player", equipmentSlot) ~= nil)
        if not IsEnabled() or isSwappingSet or isInternalOperation or not slotHasItem then
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
        if HideUpdatePromptForCombat() then
            queuedForCombat = true
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if queuedForCombat then
            ShowUpdatePrompt(false)
        end
    end
end)

-- Slash command registration (/gsh and /gearsethelper)
SLASH_GEARSETHELPER1 = "/gsh"
SLASH_GEARSETHELPER2 = "/gearsethelper"

SlashCmdList["GEARSETHELPER"] = function(msg)
    GearSetHelperDB = GearSetHelperDB or { enabled = true }

    local raw = string.match(msg or "", "^%s*(.-)%s*$") or ""
    local command, rest = string.match(raw, "^(%S+)%s*(.-)$")
    command = string.lower(command or "")

    if command == "toggle" then
        GearSetHelperDB.enabled = not IsEnabled()
        local stateText = GearSetHelperDB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
        PrintMessage("Equipment set update prompts are now " .. stateText .. ".")

    elseif command == "status" then
        local stateText = IsEnabled() and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
        local sets = GetAllConfiguredSets()
        local activeEntry = ResolveActiveSetEntry(sets)
        PrintMessage(string.format(
            "Status: %s | Configured sets: %d | Active set: %s",
            stateText,
            #sets,
            activeEntry and activeEntry.name or "None"
        ))

    elseif command == "test" then
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
        PrintMessage("  |cffffd100/gsh toggle|r - Enable or disable equipment set update prompts.")
        PrintMessage("  |cffffd100/gsh status|r - Show current addon status and detected sets.")
        PrintMessage("  |cffffd100/gsh test|r - Open a test update prompt immediately.")
        PrintMessage("  |cffffd100/gsh create <Name>|r - Create a new equipment set from current gear.")
    end
end
