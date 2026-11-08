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

-- Safe numeric slot fallbacks in case any global constant is missing on a client flavor
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

-- Inventory & GUID helpers for slot-specific equipment updates
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

local function PickupBagItem(bag, bagSlot)
    if C_Container and C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, bagSlot)
    elseif PickupContainerItem then
        PickupContainerItem(bag, bagSlot)
    end
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
    if itemInfo.link and currentLink then
        return itemInfo.link == currentLink
    end
    local currentID = GetInventoryItemID("player", slotID)
    if itemInfo.itemID and currentID then
        return itemInfo.itemID == currentID
    end
    return false
end

local function EquipSnapshottedItemIntoSlot(itemInfo, targetSlotID)
    if not itemInfo then
        return true
    end
    if IsItemEquippedInSlot(itemInfo, targetSlotID) then
        return true
    end

    if itemInfo.guid then
        for _, otherSlot in ipairs(ALL_EQUIPMENT_SLOTS) do
            if otherSlot ~= targetSlotID and GetEquippedSlotGUID(otherSlot) == itemInfo.guid then
                ClearCursor()
                PickupInventoryItem(otherSlot)
                EquipCursorItem(targetSlotID)
                ClearCursor()
                return true
            end
        end
    end

    local maxBag = NUM_BAG_SLOTS or 4
    if itemInfo.guid then
        for bag = 0, maxBag do
            local numSlots = GetNumBagSlots(bag)
            for bagSlot = 1, numSlots do
                if GetBagSlotGUID(bag, bagSlot) == itemInfo.guid then
                    ClearCursor()
                    PickupBagItem(bag, bagSlot)
                    EquipCursorItem(targetSlotID)
                    ClearCursor()
                    return true
                end
            end
        end
    end

    if itemInfo.link then
        for bag = 0, maxBag do
            local numSlots = GetNumBagSlots(bag)
            for bagSlot = 1, numSlots do
                if GetBagItemLink(bag, bagSlot) == itemInfo.link then
                    ClearCursor()
                    PickupBagItem(bag, bagSlot)
                    EquipCursorItem(targetSlotID)
                    ClearCursor()
                    return true
                end
            end
        end
    end

    return false
end

-- ============================================================================
-- Unified Equipment Set Providers:
-- Supports:
-- 1. Blizzard `C_EquipmentSet` (Retail & Classic/Forever Equipment Manager)
-- 2. `ItemRack` (`ItemRackUser.Sets`)
-- 3. `Outfitter` (`gOutfitter_Settings.Outfits`)
-- ============================================================================

local function GetAllConfiguredSets()
    local sets = {}

    -- 1. Check ItemRack sets (widely used in Classic / WoW Forever)
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

local function ResolveActiveSetEntry(sets)
    sets = sets or GetAllConfiguredSets()
    if #sets == 0 then
        return nil
    end

    local bestFallback = nil
    local bestEquippedCount = -1

    for _, s in ipairs(sets) do
        if s.isEquipped then
            return s
        end
        if (s.numEquipped or 0) > bestEquippedCount then
            bestEquippedCount = s.numEquipped or 0
            bestFallback = s
        end
    end

    if lastActiveSetKey ~= nil then
        for _, s in ipairs(sets) do
            if s.key == lastActiveSetKey then
                return s
            end
        end
    end

    return bestFallback or sets[1]
end

-- Saves a Blizzard C_EquipmentSet while preserving its ignored slots.
local function SaveBlizzardSetPreservingIgnoredSlots(setID, changedSlotMap)
    local name, iconFileID = C_EquipmentSet.GetEquipmentSetInfo(setID)
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

    C_EquipmentSet.SaveEquipmentSet(setID, iconFileID)
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

-- Slot-Only Set Update Pipeline
local activeSwapCallback = nil

local function RunSlotOnlySetUpdates(targetEntries, changedSlotList, changedSlotMap, summaryMode)
    if InCombatLockdown() then
        PrintMessage("Cannot update equipment sets while in combat.")
        return
    end
    if not targetEntries or #targetEntries == 0 then
        return
    end

    local allSets = GetAllConfiguredSets()
    local activeEntry = ResolveActiveSetEntry(allSets)
    local currentActiveKey = activeEntry and activeEntry.key or nil

    local originalWornGear = SnapshotAllWornGear()
    local newSlotItems = {}
    for _, slotID in ipairs(changedSlotList) do
        newSlotItems[slotID] = originalWornGear[slotID]
    end

    isInternalOperation = true
    local updatedNames = {}
    local blizzardNonActiveQueue = {}
    local updatedActiveBlizzardSet = false
    local activeBlizzardSetID = nil

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
            if #changedSlotList == 0 or (currentActiveKey and entry.key == currentActiveKey) then
                local ok, name = SaveBlizzardSetPreservingIgnoredSlots(entry.id, changedSlotMap)
                if ok then
                    table.insert(updatedNames, name)
                    updatedActiveBlizzardSet = true
                    activeBlizzardSetID = entry.id
                    lastActiveSetKey = entry.key
                end
            else
                table.insert(blizzardNonActiveQueue, entry)
            end
        end
    end

    -- If there are no non-active Blizzard sets requiring a temporary swap, finish right away!
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

    local function FinishAndRestoreOriginalGear()
        activeSwapCallback = nil

        if updatedActiveBlizzardSet and activeBlizzardSetID then
            C_EquipmentSet.UseEquipmentSet(activeBlizzardSetID)
        end

        C_Timer.After(0.15, function()
            if not InCombatLockdown() then
                for _, slotID in ipairs(ALL_EQUIPMENT_SLOTS) do
                    local origItem = originalWornGear[slotID]
                    if origItem then
                        EquipSnapshottedItemIntoSlot(origItem, slotID)
                    end
                end
            end

            C_Timer.After(0.15, function()
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
            end)
        end)
    end

    local function ProcessNextNonActiveSet()
        if InCombatLockdown() then
            activeSwapCallback = nil
            isInternalOperation = false
            PrintMessage("Combat started; aborted remaining set updates.")
            return
        end

        queueIndex = queueIndex + 1
        local targetEntry = blizzardNonActiveQueue[queueIndex]
        if not targetEntry then
            FinishAndRestoreOriginalGear()
            return
        end

        local targetSetID = targetEntry.id
        local setName = C_EquipmentSet.GetEquipmentSetInfo(targetSetID)
        if not setName then
            ProcessNextNonActiveSet()
            return
        end

        local stepHandled = false
        local function OnTargetSetEquipped()
            if stepHandled then
                return
            end
            stepHandled = true
            activeSwapCallback = nil

            if InCombatLockdown() then
                isInternalOperation = false
                return
            end

            for _, slotID in ipairs(changedSlotList) do
                local newItem = newSlotItems[slotID]
                if newItem then
                    EquipSnapshottedItemIntoSlot(newItem, slotID)
                end
            end

            C_Timer.After(0.15, function()
                if not InCombatLockdown() then
                    local ok, savedName = SaveBlizzardSetPreservingIgnoredSlots(targetSetID, changedSlotMap)
                    if ok then
                        table.insert(updatedNames, savedName)
                    end
                end
                ProcessNextNonActiveSet()
            end)
        end

        activeSwapCallback = OnTargetSetEquipped
        local swapInitiated = C_EquipmentSet.UseEquipmentSet(targetSetID)
        C_Timer.After(0.25, function()
            if not stepHandled or not swapInitiated then
                OnTargetSetEquipped()
            end
        end)
    end

    ProcessNextNonActiveSet()
end

local function UpdateSingleSetEntry(entry, changedSlotList, changedSlotMap)
    if not entry then
        entry = ResolveActiveSetEntry()
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
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        ddList:Hide()
        f:Hide()
        UpdateSingleSetEntry(selectedEntry, slots, slotMap)
    end)
    f.btnUpdateSet = btnUpdateSet

    local btnAllSets = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnAllSets:SetSize(105, 24)
    btnAllSets:SetPoint("BOTTOM", f, "BOTTOM", 5, 18)
    btnAllSets:SetText("All Sets")
    btnAllSets:SetScript("OnClick", function()
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        ddList:Hide()
        f:Hide()
        UpdateAllSetEntries(slots, slotMap)
    end)
    f.btnAllSets = btnAllSets

    local btnIgnore = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnIgnore:SetSize(95, 24)
    btnIgnore:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 18)
    btnIgnore:SetText("Ignore")
    btnIgnore:SetScript("OnClick", function()
        ClearPendingSlots()
        ddList:Hide()
        f:Hide()
    end)
    f.btnIgnore = btnIgnore

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
    queuedForCombat = false

    local activeEntry = ResolveActiveSetEntry(sets)
    local f = GetOrCreatePromptFrame()
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

-- Event frame setup (using pcall so client-specific events never abort loading)
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
        -- Enable built-in equipment manager CVar on Classic/Forever clients if supported
        if SetCVar then
            pcall(SetCVar, "equipmentManager", "1")
        end
        RefreshLastActiveSet()
        if not hasPrintedLoadMessage then
            hasPrintedLoadMessage = true
            local sets = GetAllConfiguredSets()
            PrintMessage(string.format("Loaded (%d %s detected). Type |cffffd100/gsh|r for commands.", #sets, #sets == 1 and "set" or "sets"))
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
            if activeSwapCallback then
                local cb = activeSwapCallback
                activeSwapCallback = nil
                cb()
            end
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
        -- In some Classic/Forever builds `hasCurrent` can be boolean or 1/nil; check GetInventoryItemID directly as fallback
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
