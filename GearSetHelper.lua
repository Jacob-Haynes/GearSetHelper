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
local lastActiveSetID = nil

-- Human-readable slot names keyed by InventorySlotId
local SLOT_NAMES = {
    [INVSLOT_HEAD]      = HEADSLOT or "Head",
    [INVSLOT_NECK]      = NECKSLOT or "Neck",
    [INVSLOT_SHOULDER]  = SHOULDERSLOT or "Shoulder",
    [INVSLOT_BODY]      = SHIRTSLOT or "Shirt",
    [INVSLOT_CHEST]     = CHESTSLOT or "Chest",
    [INVSLOT_WAIST]     = WAISTSLOT or "Waist",
    [INVSLOT_LEGS]      = LEGSSLOT or "Legs",
    [INVSLOT_FEET]      = FEETSLOT or "Feet",
    [INVSLOT_WRIST]     = WRISTSLOT or "Wrist",
    [INVSLOT_HAND]      = HANDSSLOT or "Hands",
    [INVSLOT_FINGER1]   = "Finger 1",
    [INVSLOT_FINGER2]   = "Finger 2",
    [INVSLOT_TRINKET1]  = "Trinket 1",
    [INVSLOT_TRINKET2]  = "Trinket 2",
    [INVSLOT_BACK]      = BACKSLOT or "Back",
    [INVSLOT_MAINHAND]  = MAINHANDSLOT or "Main Hand",
    [INVSLOT_OFFHAND]   = SECONDARYHANDSLOT or "Off Hand",
    [INVSLOT_RANGED]    = RANGEDSLOT or "Ranged",
    [INVSLOT_TABARD]    = TABARDSLOT or "Tabard",
}

local ALL_EQUIPMENT_SLOTS = {
    INVSLOT_HEAD,
    INVSLOT_NECK,
    INVSLOT_SHOULDER,
    INVSLOT_BODY,
    INVSLOT_CHEST,
    INVSLOT_WAIST,
    INVSLOT_LEGS,
    INVSLOT_FEET,
    INVSLOT_WRIST,
    INVSLOT_HAND,
    INVSLOT_FINGER1,
    INVSLOT_FINGER2,
    INVSLOT_TRINKET1,
    INVSLOT_TRINKET2,
    INVSLOT_BACK,
    INVSLOT_MAINHAND,
    INVSLOT_OFFHAND,
    INVSLOT_RANGED,
    INVSLOT_TABARD,
}

local function PrintMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. tostring(msg))
end

local function IsEnabled()
    return GearSetHelperDB and GearSetHelperDB.enabled ~= false
end

local function ClearPendingSlots()
    wipe(pendingSlots)
    wipe(pendingSlotOrder)
end

local function RecordChangedSlot(slotID)
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
        local loc = ItemLocation:CreateFromEquipmentSlot(slotID)
        if loc and C_Item.DoesItemExist(loc) then
            return C_Item.GetItemGUID(loc)
        end
    end
    return nil
end

local function GetBagSlotGUID(bag, bagSlot)
    if ItemLocation and ItemLocation.CreateFromBagAndSlot and C_Item and C_Item.DoesItemExist and C_Item.GetItemGUID then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, bagSlot)
        if loc and C_Item.DoesItemExist(loc) then
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

-- Equips a specific snapshotted item into `targetSlotID` from bags or another equipment slot.
local function EquipSnapshottedItemIntoSlot(itemInfo, targetSlotID)
    if not itemInfo then
        return true
    end
    if IsItemEquippedInSlot(itemInfo, targetSlotID) then
        return true
    end

    -- Check if the item is currently in another equipment slot (e.g. Ring 1 vs Ring 2)
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
    -- First pass: exact GUID match in bags
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

    -- Second pass: exact itemLink match in bags
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

-- Scans defined equipment sets to cache whichever set is currently marked as equipped.
local function RefreshLastActiveSet()
    if not C_EquipmentSet or not C_EquipmentSet.GetEquipmentSetIDs then
        return
    end
    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if not setIDs or #setIDs == 0 then
        lastActiveSetID = nil
        return
    end

    for _, setID in ipairs(setIDs) do
        local name, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name and isEquipped then
            lastActiveSetID = setID
            return
        end
    end
end

-- Resolves the best candidate for the player's "Active Set":
-- 1. Any set currently marked `isEquipped` by the API.
-- 2. The last known equipped set prior to equipping the new item.
-- 3. The set with the highest number of currently equipped items (fallback).
local function ResolveActiveSet()
    if not C_EquipmentSet or not C_EquipmentSet.GetEquipmentSetIDs then
        return nil, nil, nil
    end
    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if not setIDs or #setIDs == 0 then
        return nil, nil, nil
    end

    local bestFallbackID, bestFallbackName, bestFallbackIcon
    local bestEquippedCount = -1

    for _, setID in ipairs(setIDs) do
        local name, iconFileID, _, isEquipped, _, numEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name then
            if isEquipped then
                return setID, name, iconFileID
            end
            if (numEquipped or 0) > bestEquippedCount then
                bestEquippedCount = numEquipped or 0
                bestFallbackID = setID
                bestFallbackName = name
                bestFallbackIcon = iconFileID
            end
        end
    end

    if lastActiveSetID ~= nil then
        local name, iconFileID = C_EquipmentSet.GetEquipmentSetInfo(lastActiveSetID)
        if name then
            return lastActiveSetID, name, iconFileID
        end
    end

    return bestFallbackID, bestFallbackName, bestFallbackIcon
end

-- Saves a set while preserving its ignored slots (except for any slot that was just updated).
local function SaveSetPreservingIgnoredSlots(setID, changedSlotMap)
    local name, iconFileID = C_EquipmentSet.GetEquipmentSetInfo(setID)
    if not name then
        return false, nil
    end

    if C_EquipmentSet.GetIgnoredSlots and C_EquipmentSet.ClearIgnoredSlotsForSave and C_EquipmentSet.IgnoreSlotForSave then
        local ignoredSlots = C_EquipmentSet.GetIgnoredSlots(setID)
        if ignoredSlots then
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

-- Slot-Only Set Update Pipeline:
-- Updates ONLY the newly equipped slot(s) on target equipment sets without overwriting
-- their other slots with the currently active set's gear.
local activeSwapCallback = nil

local function RunSlotOnlySetUpdates(targetSetIDs, changedSlotList, changedSlotMap, summaryMode)
    if InCombatLockdown() then
        PrintMessage("Cannot update equipment sets while in combat.")
        return
    end
    if not targetSetIDs or #targetSetIDs == 0 then
        return
    end

    local currentActiveSetID = ResolveActiveSet()
    local originalWornGear = SnapshotAllWornGear()
    local newSlotItems = {}
    for _, slotID in ipairs(changedSlotList) do
        newSlotItems[slotID] = originalWornGear[slotID]
    end

    -- If we have no specific changed slots recorded, fall back to direct save on the active set.
    if #changedSlotList == 0 then
        isInternalOperation = true
        local updatedCount = 0
        local lastUpdatedName = nil
        for _, setID in ipairs(targetSetIDs) do
            local ok, name = SaveSetPreservingIgnoredSlots(setID, nil)
            if ok then
                updatedCount = updatedCount + 1
                lastUpdatedName = name
            end
        end
        isInternalOperation = false
        if summaryMode == "all" and updatedCount > 0 then
            PrintMessage(string.format("Updated %d %s.", updatedCount, updatedCount == 1 and "set" or "sets"))
        elseif lastUpdatedName then
            PrintMessage(string.format("Updated set %q.", lastUpdatedName))
        end
        return
    end

    isInternalOperation = true
    local updatedNames = {}
    local nonActiveQueue = {}
    local updatedActiveSet = false

    -- 1. If the currently active set is in the target list, save it immediately (0 swaps needed)
    --    because the player is already wearing all of its gear + the newly equipped item(s).
    for _, setID in ipairs(targetSetIDs) do
        if currentActiveSetID ~= nil and setID == currentActiveSetID then
            local ok, name = SaveSetPreservingIgnoredSlots(setID, changedSlotMap)
            if ok then
                table.insert(updatedNames, name)
                updatedActiveSet = true
                lastActiveSetID = setID
            end
        else
            table.insert(nonActiveQueue, setID)
        end
    end

    -- If there are no non-active sets to update, finish immediately!
    if #nonActiveQueue == 0 then
        isInternalOperation = false
        if summaryMode == "all" then
            PrintMessage(string.format("Updated %d %s.", #updatedNames, #updatedNames == 1 and "set" or "sets"))
        elseif #updatedNames == 1 then
            PrintMessage(string.format("Updated set %q.", updatedNames[1]))
        end
        return
    end

    -- 2. Process non-active sets sequentially:
    --    For each non-active set:
    --      a) Equip the non-active set (`C_EquipmentSet.UseEquipmentSet(setID)`)
    --      b) Re-equip only the newly equipped item(s) into `changedSlotList`
    --      c) Save the non-active set (`SaveSetPreservingIgnoredSlots`)
    --    Finally, restore the player's original worn gear.
    local queueIndex = 0

    local function FinishAndRestoreOriginalGear()
        activeSwapCallback = nil

        -- Restore the player's original worn gear across all slots
        if updatedActiveSet and currentActiveSetID then
            C_EquipmentSet.UseEquipmentSet(currentActiveSetID)
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
                if currentActiveSetID then
                    lastActiveSetID = currentActiveSetID
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
        local targetSetID = nonActiveQueue[queueIndex]
        if not targetSetID then
            FinishAndRestoreOriginalGear()
            return
        end

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

            -- Equip ONLY the newly changed slot(s) onto this set
            for _, slotID in ipairs(changedSlotList) do
                local newItem = newSlotItems[slotID]
                if newItem then
                    EquipSnapshottedItemIntoSlot(newItem, slotID)
                end
            end

            -- Wait briefly for the slot change to settle, then save the set
            C_Timer.After(0.15, function()
                if not InCombatLockdown() then
                    local ok, savedName = SaveSetPreservingIgnoredSlots(targetSetID, changedSlotMap)
                    if ok then
                        table.insert(updatedNames, savedName)
                    end
                end
                ProcessNextNonActiveSet()
            end)
        end

        activeSwapCallback = OnTargetSetEquipped
        local swapInitiated = C_EquipmentSet.UseEquipmentSet(targetSetID)
        -- Fallback timer in case all items of targetSetID were already worn and no swap event fires
        C_Timer.After(0.25, function()
            if not stepHandled or not swapInitiated then
                OnTargetSetEquipped()
            end
        end)
    end

    ProcessNextNonActiveSet()
end

local function UpdateSingleEquipmentSet(setID, changedSlotList, changedSlotMap)
    if setID == nil then
        setID = ResolveActiveSet()
    end
    if setID == nil then
        return
    end
    changedSlotList = changedSlotList or {}
    changedSlotMap = changedSlotMap or {}
    RunSlotOnlySetUpdates({ setID }, changedSlotList, changedSlotMap, "single")
end

local function UpdateAllEquipmentSets(changedSlotList, changedSlotMap)
    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if not setIDs or #setIDs == 0 then
        return
    end
    changedSlotList = changedSlotList or {}
    changedSlotMap = changedSlotMap or {}
    RunSlotOnlySetUpdates(setIDs, changedSlotList, changedSlotMap, "all")
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
        local targetSetID = data and data.activeSetID or nil
        UpdateSingleEquipmentSet(targetSetID, slots, slotMap)
    end,
    OnCancel = function(self, data, reason)
        if isRefreshingPopup then
            return
        end
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        if reason == "override" or reason == "clicked" then
            UpdateAllEquipmentSets(slots, slotMap)
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

-- Custom Prompt Dialog with Set Selector Dropdown
local promptFrame = nil

local function GetOrCreatePromptFrame()
    if promptFrame then
        return promptFrame
    end

    local f = CreateFrame("Frame", "GearSetHelperPromptFrame", UIParent, "BackdropTemplate")
    f:SetSize(380, 165)
    f:SetPoint("TOP", UIParent, "TOP", 0, -135)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end

    -- Title text
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("GearSetHelper")
    f.title = title

    -- Prompt description text
    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -38)
    text:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -38)
    text:SetJustifyH("CENTER")
    text:SetWordWrap(true)
    f.text = text

    -- Dropdown label
    local ddLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ddLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 28, -74)
    ddLabel:SetText("Target Set:")

    -- Custom Cross-Flavor Set Dropdown Button
    local ddButton = CreateFrame("Button", nil, f, "BackdropTemplate")
    ddButton:SetSize(245, 26)
    ddButton:SetPoint("LEFT", ddLabel, "RIGHT", 8, 0)
    if ddButton.SetBackdrop then
        ddButton:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        ddButton:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
        ddButton:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end

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

    -- Dropdown expandable menu list
    local ddList = CreateFrame("Frame", nil, ddButton, "BackdropTemplate")
    ddList:SetPoint("TOPLEFT", ddButton, "BOTTOMLEFT", 0, -2)
    ddList:SetPoint("TOPRIGHT", ddButton, "BOTTOMRIGHT", 0, -2)
    ddList:SetFrameStrata("TOOLTIP")
    if ddList.SetBackdrop then
        ddList:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        ddList:SetBackdropColor(0.05, 0.05, 0.05, 0.98)
        ddList:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
    end
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

    -- Action Buttons:
    -- 1. Update Selected Set
    local btnUpdateSet = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnUpdateSet:SetSize(115, 24)
    btnUpdateSet:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 18)
    btnUpdateSet:SetText("Update Set")
    btnUpdateSet:SetScript("OnClick", function()
        local selectedSetID = f.selectedSetID
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        ddList:Hide()
        f:Hide()
        UpdateSingleEquipmentSet(selectedSetID, slots, slotMap)
    end)
    f.btnUpdateSet = btnUpdateSet

    -- 2. All Sets
    local btnAllSets = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnAllSets:SetSize(105, 24)
    btnAllSets:SetPoint("BOTTOM", f, "BOTTOM", 5, 18)
    btnAllSets:SetText("All Sets")
    btnAllSets:SetScript("OnClick", function()
        local slots, slotMap = CopyChangedSlotList()
        ClearPendingSlots()
        ddList:Hide()
        f:Hide()
        UpdateAllEquipmentSets(slots, slotMap)
    end)
    f.btnAllSets = btnAllSets

    -- 3. Ignore
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

    -- Allow pressing Escape to close
    table.insert(UISpecialFrames, "GearSetHelperPromptFrame")

    promptFrame = f
    return f
end

local function SetPromptDropdownSelection(f, setID, setName, iconFileID, isActive)
    f.selectedSetID = setID
    f.ddButton.icon:SetTexture(iconFileID or 134400)
    if isActive then
        f.ddButton.label:SetText(string.format("%s |cff33ff99(Active)|r", setName or "Set"))
    else
        f.ddButton.label:SetText(setName or "Set")
    end
end

local function PopulatePromptDropdown(f, setIDs, activeSetID)
    for _, btn in ipairs(f.optionButtons) do
        btn:Hide()
    end

    local rowHeight = 22
    local count = 0
    local defaultSetID, defaultName, defaultIcon, defaultIsActive

    for _, setID in ipairs(setIDs) do
        local name, iconFileID = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name then
            count = count + 1
            local isActive = (activeSetID ~= nil and setID == activeSetID)
            if not defaultSetID or isActive then
                defaultSetID = setID
                defaultName = name
                defaultIcon = iconFileID
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
            optBtn.icon:SetTexture(iconFileID or 134400)
            if isActive then
                optBtn.label:SetText(string.format("%s |cff33ff99(Active)|r", name))
            else
                optBtn.label:SetText(name)
            end

            optBtn:SetScript("OnClick", function()
                SetPromptDropdownSelection(f, setID, name, iconFileID, isActive)
                f.ddList:Hide()
            end)
            optBtn:Show()
        end
    end

    f.ddList:SetHeight(math.max(28, count * rowHeight + 8))
    if defaultSetID then
        SetPromptDropdownSelection(f, defaultSetID, defaultName, defaultIcon, defaultIsActive)
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

local function ShowUpdatePrompt()
    if not IsEnabled() then
        ClearPendingSlots()
        queuedForCombat = false
        return
    end

    if InCombatLockdown() then
        queuedForCombat = true
        return
    end

    if not C_EquipmentSet or not C_EquipmentSet.GetEquipmentSetIDs then
        ClearPendingSlots()
        queuedForCombat = false
        return
    end

    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if not setIDs or #setIDs == 0 then
        ClearPendingSlots()
        queuedForCombat = false
        return
    end

    local slotSummary = FormatChangedSlots()
    queuedForCombat = false

    local activeSetID = ResolveActiveSet()
    local f = GetOrCreatePromptFrame()
    f.text:SetText(string.format("Equipped new item in |cffffd100%s|r.\nUpdate only that slot in your gear sets?", slotSummary))
    PopulatePromptDropdown(f, setIDs, activeSetID)
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
        ShowUpdatePrompt()
    end)
end

-- Event frame setup
local eventFrame = CreateFrame("Frame", "GearSetHelperFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("EQUIPMENT_SWAP_PENDING")
eventFrame:RegisterEvent("EQUIPMENT_SWAP_FINISHED")
eventFrame:RegisterEvent("EQUIPMENT_SETS_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

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
        RefreshLastActiveSet()

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

        if completed and setID then
            lastActiveSetID = setID
        else
            RefreshLastActiveSet()
        end
        -- Defer clearing `isSwappingSet` briefly so trailing same-frame equipment events are ignored.
        C_Timer.After(0.1, function()
            isSwappingSet = false
        end)

    elseif event == "EQUIPMENT_SETS_CHANGED" then
        if not isInternalOperation then
            RefreshLastActiveSet()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local equipmentSlot, hasCurrent = ...
        -- Only prompt when a new item is equipped (hasCurrent == true) outside of a full set swap or internal save.
        if not IsEnabled() or isSwappingSet or isInternalOperation or not hasCurrent then
            return
        end

        RecordChangedSlot(equipmentSlot)
        ScheduleDebouncedPrompt()

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat: cancel active timers and hide any open prompt safely until combat ends.
        if debounceTimer then
            debounceTimer:Cancel()
            debounceTimer = nil
            queuedForCombat = true
        end
        if HideUpdatePromptForCombat() then
            queuedForCombat = true
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat: process any queued equipment change prompt.
        if queuedForCombat then
            ShowUpdatePrompt()
        end
    end
end)

-- Slash command registration (/gsh and /gearsethelper)
SLASH_GEARSETHELPER1 = "/gsh"
SLASH_GEARSETHELPER2 = "/gearsethelper"

SlashCmdList["GEARSETHELPER"] = function(msg)
    GearSetHelperDB = GearSetHelperDB or { enabled = true }

    local command = string.lower(string.match(msg or "", "^%s*(%S*)") or "")

    if command == "toggle" then
        GearSetHelperDB.enabled = not IsEnabled()
        local stateText = GearSetHelperDB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
        PrintMessage("Equipment set update prompts are now " .. stateText .. ".")

    elseif command == "status" then
        local stateText = IsEnabled() and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
        local setIDs = C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetEquipmentSetIDs()
        local numSets = setIDs and #setIDs or 0
        local _, activeSetName = ResolveActiveSet()
        PrintMessage(string.format(
            "Status: %s | Configured sets: %d | Active set: %s",
            stateText,
            numSets,
            activeSetName or "None"
        ))

    else
        PrintMessage("Commands:")
        PrintMessage("  |cffffd100/gsh toggle|r - Enable or disable equipment set update prompts.")
        PrintMessage("  |cffffd100/gsh status|r - Show current addon status and detected active set.")
    end
end
