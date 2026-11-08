local addonName, ns = ...

local POPUP_KEY = "GEARSET_UPDATE_PROMPT"
local DEBOUNCE_DELAY = 0.25
local CHAT_PREFIX = "|cff33ff99[GearSetHelper]|r "

-- State tracking
local isSwappingSet = false
local isInternalSave = false
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

-- Scans defined equipment sets to cache whichever set is currently marked as equipped.
local function RefreshLastActiveSet()
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

-- Saves the currently equipped gear into a single equipment set, preserving its name and icon.
local function UpdateSingleEquipmentSet(setID)
    if InCombatLockdown() then
        PrintMessage("Cannot update equipment sets while in combat.")
        return false
    end

    if setID == nil then
        setID = ResolveActiveSet()
    end
    if setID == nil then
        return false
    end

    local name, iconFileID = C_EquipmentSet.GetEquipmentSetInfo(setID)
    if not name then
        return false
    end

    isInternalSave = true
    C_EquipmentSet.SaveEquipmentSet(setID, iconFileID)
    isInternalSave = false

    lastActiveSetID = setID
    PrintMessage(string.format("Updated set %q.", name))
    return true
end

-- Iterates across all defined sets and saves the current equipped gear into each.
local function UpdateAllEquipmentSets()
    if InCombatLockdown() then
        PrintMessage("Cannot update equipment sets while in combat.")
        return
    end

    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if not setIDs or #setIDs == 0 then
        return
    end

    local updatedCount = 0
    isInternalSave = true
    for _, setID in ipairs(setIDs) do
        local name, iconFileID = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name then
            C_EquipmentSet.SaveEquipmentSet(setID, iconFileID)
            updatedCount = updatedCount + 1
        end
    end
    isInternalSave = false

    if updatedCount > 0 then
        PrintMessage(string.format("Updated %d %s.", updatedCount, updatedCount == 1 and "set" or "sets"))
    end
end

-- Native StaticPopup dialog definition
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
        ClearPendingSlots()
        local targetSetID = data and data.activeSetID or nil
        UpdateSingleEquipmentSet(targetSetID)
    end,
    OnCancel = function(self, data, reason)
        -- Guard against programmatic popup refreshes or combat hides triggering OnCancel.
        if isRefreshingPopup then
            return
        end
        ClearPendingSlots()
        -- In Blizzard's StaticPopup system, button2 routes through OnCancel.
        -- Handle both "override" and "clicked" while ignoring timeouts or programmatic hides.
        if reason == "override" or reason == "clicked" then
            UpdateAllEquipmentSets()
        end
    end,
    OnAlt = function()
        -- button3 ("Ignore"): dismiss cleanly with no action.
        ClearPendingSlots()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

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

    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if not setIDs or #setIDs == 0 then
        ClearPendingSlots()
        queuedForCombat = false
        return
    end

    local slotSummary = FormatChangedSlots()
    queuedForCombat = false

    local activeSetID, activeSetName = ResolveActiveSet()
    local popupData = {
        activeSetID = activeSetID,
        activeSetName = activeSetName,
    }

    if StaticPopup_Visible(POPUP_KEY) then
        isRefreshingPopup = true
        StaticPopup_Hide(POPUP_KEY)
        isRefreshingPopup = false
    end

    StaticPopup_Show(POPUP_KEY, slotSummary, nil, popupData)
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
        isSwappingSet = true
        if debounceTimer then
            debounceTimer:Cancel()
            debounceTimer = nil
        end
        ClearPendingSlots()

    elseif event == "EQUIPMENT_SWAP_FINISHED" then
        local completed, setID = ...
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
        if not isInternalSave then
            RefreshLastActiveSet()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local equipmentSlot, hasCurrent = ...
        -- Only prompt when a new item is equipped (hasCurrent == true) outside of a full set swap.
        if not IsEnabled() or isSwappingSet or isInternalSave or not hasCurrent then
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
        if StaticPopup_Visible(POPUP_KEY) then
            isRefreshingPopup = true
            StaticPopup_Hide(POPUP_KEY)
            isRefreshingPopup = false
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
        local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
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
