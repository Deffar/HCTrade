-- HCTrade.lua
-- 
-- Hardcore WoW (1.12.1) Trade Notification Addon
-- 
-- Monitors the HC chat channel for WTS/WTB messages and displays popup notifications
-- when trades match your character's level range (±5 levels by default).
--
-- Features:
-- - Level-based filtering (parses formats like "28+-", "25-30", "lvl 27")
-- - Custom keyword alerts (notify on specific items/words)
-- - Profession matching (alerts when someone needs your profession)
-- - Inventory alerts (special notification for WTB items you own)
-- - Item color coding (shows items in their quality colors if you own them)
-- - Bank scanning (tracks items in bank, alerts even when bank is closed)
-- - Configurable sounds, popup duration, and position
-- - WTB filtering (optionally only show WTB if you own the items)
--
-- Type /hct help for commands
--
-- CODE STRUCTURE GUIDE:
-- 1. Configuration & State Variables (lines ~25-80)
-- 2. Level Range Parser - extracts "28+-" style levels from messages  
-- 3. Helper Functions - IsTradeMessage, PlayerLevelInRange
-- 4. Inventory Scanner - scans bags/bank, caches items you own
-- 5. Profession Scanner - detects your professions for LF/LFW matching
-- 6. Custom Keyword Matching - checks for user-defined alert words
-- 7. Popup System - creates notification frames, handles stacking/fading
-- 8. Item Color Caching - scans tooltips to get item quality colors
-- 9. Message Hook - intercepts HC chat messages and triggers alerts
-- 10. Settings GUI - /hct menu panel for configuration
-- 11. Event Handlers - VARIABLES_LOADED, BAG_UPDATE, BANKFRAME_OPENED, etc.
-- 12. Slash Commands - /hct debug, /hct test, /hct menu, etc.

-- ================================================================
-- LUA 5.0 COMPATIBILITY (for older WoW 1.12.1 clients)
-- ================================================================
-- Some WoW clients use Lua 5.0 which doesn't have string.match or string.gmatch
-- This shim provides compatibility using string.find and string.gfind

if not string.match then
    string.match = function(s, pattern, init)
        init = init or 1
        local i, j, c1, c2, c3, c4, c5, c6, c7, c8, c9 = string.find(s, pattern, init)
        if i then
            return c1, c2, c3, c4, c5, c6, c7, c8, c9
        end
        return nil
    end
end

if not string.gmatch then
    -- In Lua 5.0, it's called string.gfind
    string.gmatch = string.gfind
end

HCTrade = HCTrade or {}
HCTradeDB = HCTradeDB or {}

-- ================================================================
-- CONFIGURATION & STATE VARIABLES
-- ================================================================

local TRADE_RANGE    = 5  -- Level range tolerance (±5 levels)
local notificationsEnabled = true  -- Master on/off switch (does not affect /hct test)
local hardcoreEnabled = true  -- HC channel monitoring on/off
local guildEnabled    = true  -- Guild channel monitoring on/off
local debugMode      = false   -- Print debug messages
local sniffMode      = false   -- Print all raw HC chat messages
local hookedFrame    = nil     -- The chat frame we're monitoring
local hookedIndex    = nil     -- Chat frame number (1-10)
local soundMuted     = false   -- Mute Alert.ogg (trade notifications)
local tradeskillMuted = false  -- Mute Tradeskill.ogg (profession alerts)
local inventoryAlerts = false  -- Enable special alerts for WTB items you own
local onlyOwnedWTB   = false   -- Filter: only show WTB if you own at least one item

-- Inventory tracking for "You have this!" alerts
local playerInventory = {}      -- { ["Item Name"] = true, ... }
local lastInventoryScan = 0     -- timestamp of last scan
local pendingInventoryScan = false  -- deferred scan flag
local INVENTORY_SCAN_COOLDOWN = 1.0  -- seconds between scans
local bankCache = {}            -- Cached bank items (persists when bank is closed)
local bankOpen = false          -- Whether bank window is currently open
local itemColorCache = {}       -- Cached item quality colors: { ["Item Name"] = "|cffXXXXXX", ... }

-- Level cache for senders without explicit level in their message
-- HCTradeDB.levelCache = { ["PlayerName"] = level, ... }
local LEVEL_CACHE_RANGE = 5  -- +/- range applied when using cached level

-- ================================================================
-- ITEM QUALITY & CUSTOM KEYWORDS
-- ================================================================

-- Item quality color codes (standard WoW colors)
-- Used for displaying items in their proper colors in popups
local QUALITY_COLORS = {
    ["Junk"]     = "|cff9d9d9d",  -- Gray
    ["Common"]   = "|cffffffff",  -- White
    ["Uncommon"] = "|cff1eff00",  -- Green
    ["Rare"]     = "|cff0070ff",  -- Blue
    ["Epic"]     = "|cffa335ee",  -- Purple
}

-- Custom keyword alerts: user-defined words/items to watch for
-- Format: { keyword="armor kit", color="|cff...", display="[Armor Kit]", quality="Uncommon" }
-- Loaded from SavedVariables (HCTradeDB.customKeywords) on login
local customKeywords = {}

-- ================================================================
-- PROFESSION DETECTION
-- ================================================================

-- Player's known professions (scanned on login and zone change)
-- Format: { {shortname="BS", fullname="Blacksmithing"}, ... }
local playerProfessions = {}

-- Profession abbreviation mapping for LF/LFW detection
-- Maps full profession names to common abbreviations used in trade chat
local PROF_ABBREVS = {
    ["blacksmithing"] = {"bs","blacksmith","blacksmithing"},
    ["leatherworking"] = {"lw","lws","leatherworking","leatherworker"},
    ["tailoring"]      = {"tailor","tailoring"},
    ["engineering"]    = {"eng","engi","engineering","engineer"},
    ["alchemy"]        = {"alch","alchemy","alchemist"},
    ["enchanting"]     = {"enchant","enchanting","enchanter"},
    ["herbalism"]      = {"herb","herbs","herbalism","herbalist"},
    ["mining"]         = {"mine","mining","miner"},
    ["skinning"]       = {"skin","skinning","skinner"},
    ["fishing"]        = {"fish","fishing","fisher"},
    ["cooking"]        = {"cook","cooking"},
    ["first aid"]      = {"fa","firstaid","first aid","first-aid"},
    ["jewelcrafting"]   = {"jc","jewelcrafting","jeweler","jewellery", "jwc", "jewelcrafter", "jewelcraft"},
}

-- ================================================================
-- LEVEL RANGE PARSER
-- ================================================================
-- Extracts level information from trade messages
-- Supports formats:
--   "28+-", "28+", "28-"       → 23-33 (±5 from base)
--   "28±"                      → 23-33 (±5 from base)
--   "25-30"                    → 25-30 (explicit range)
--   "lvl 27", "lv 27"          → 22-32 (±5 from level)
--   Bare numbers (fallback)    → ±5 from number
-- Returns: rangeMin, rangeMax (or nil if no level found)

local function ParseLevelRange(msg)
    local s = string.lower(msg)

    -- Pattern 1: "28+-", "28+--", etc. (at end of message)
    local base = string.match(s, "(%d+)%s*[%+%-][%+%-%/]+$")
    if not base then
        -- Pattern 2: "28+-" followed by non-digit
        base = string.match(s, "(%d+)%s*[%+%-][%+%-%/]+[^%d]")
    end
    if not base then
        -- Pattern 3: "28±" (plus-minus symbol, UTF-8 encoded as \194\177)
        base = string.match(s, "(%d+)%s*\194\177")
    end
    if not base then
        -- Pattern 4: "28+" or "28-" at end
        base = string.match(s, "(%d+)%s*[%+%-]$")
    end
    if not base then
        -- Pattern 5: "28+" or "28-" followed by non-digit/non-symbol
        base = string.match(s, "(%d+)%s*[%+%-][^%+%-%d/]")
    end
    if base then
        base = tonumber(base)
        if base and base >= 1 and base <= 60 then
            return math.max(1, base - TRADE_RANGE), math.min(60, base + TRADE_RANGE)
        end
    end

    -- Pattern 6: Explicit range "25-30"
    local a, b = string.match(s, "(%d+)%s*%-%s*(%d+)")
    if a and b then
        a, b = tonumber(a), tonumber(b)
        if a and b and a < b and b <= 60 then
            return a, b
        end
    end

    -- Pattern 7: "lvl 27", "lv 27"
    local lvl = string.match(s, "lv[le]*%.?%s*(%d+)")
    if lvl then
        lvl = tonumber(lvl)
        if lvl and lvl >= 1 and lvl <= 60 then
            return math.max(1, lvl - TRADE_RANGE), math.min(60, lvl + TRADE_RANGE)
        end
    end

    -- Fallback: Use first valid number found (±5 range)

    for num in string.gmatch(s, "%d+") do
        local n = tonumber(num)
        if n and n >= 1 and n <= 60 then
            return math.max(1, n - TRADE_RANGE), math.min(60, n + TRADE_RANGE)
        end
    end

    return nil, nil  -- No valid level found
end

-- ================================================================
-- HELPER FUNCTIONS
-- ================================================================

-- Check if message contains WTS or WTB
local function IsTradeMessage(msg)
    local s = string.lower(msg)
    return string.find(s, "wts") or string.find(s, "wtb") or string.find(s, "wtt")
end

-- Check if player's level is within the specified range
local function PlayerLevelInRange(rangeMin, rangeMax)
    return UnitLevel("player") >= rangeMin and UnitLevel("player") <= rangeMax
end

-- ================================================================
-- INVENTORY SCANNER
-- ================================================================
-- Scans player bags and bank for items
-- Creates a cache: playerInventory["Item Name"] = {inBags=bool, inBank=bool}
-- Bank items persist in bankCache when bank is closed
-- Called on BAG_UPDATE, BANKFRAME_OPENED, and periodically with cooldown

local function ScanInventory()
    -- Throttle scanning to prevent spam (max once per second)
    -- If called during cooldown, set pending flag so the OnUpdate ticker
    -- runs a final scan once the cooldown expires (handles bag-sort addons
    -- that fire many BAG_UPDATE events in quick succession)
    local now = GetTime()
    if now - lastInventoryScan < INVENTORY_SCAN_COOLDOWN then
        pendingInventoryScan = true
        return
    end
    lastInventoryScan = now
    pendingInventoryScan = false
    
    playerInventory = {}  -- Reset cache
    
    -- Helper function: Check if item is soulbound (we don't want to alert on these)
    local function IsSoulbound(bag, slot)
        local tooltipName = "HCTradeScanTooltip"
        if not getglobal(tooltipName) then
            CreateFrame("GameTooltip", tooltipName, nil, "GameTooltipTemplate")
        end
        local tooltip = getglobal(tooltipName)
        tooltip:SetOwner(UIParent, "ANCHOR_NONE")
        tooltip:SetBagItem(bag, slot)
        
        local isSoulbound = false
        for i = 1, tooltip:NumLines() do
            local line = getglobal(tooltipName .. "TextLeft" .. i)
            if line then
                local text = line:GetText()
                if text and (text == ITEM_SOULBOUND or text == ITEM_BIND_ON_PICKUP) then
                    isSoulbound = true
                    break
                end
            end
        end
        tooltip:Hide()
        return isSoulbound
    end
    
    -- Scan bags (0-4)
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local itemName = string.match(link, "%[(.-)%]")
                if itemName and not IsSoulbound(bag, slot) then
                    local lowerName = string.lower(itemName)
                    if not playerInventory[lowerName] then
                        playerInventory[lowerName] = {inBags = true, inBank = false}
                    else
                        playerInventory[lowerName].inBags = true
                    end
                end
            end
        end
    end
    
    -- Scan bank (bags 5-11 + bank slots -1) if bank is open
    if bankOpen then
        -- Scan bank bags (5-11)
        for bag = 5, 11 do
            local slots = GetContainerNumSlots(bag)
            if slots and slots > 0 then
                for slot = 1, slots do
                    local link = GetContainerItemLink(bag, slot)
                    if link then
                        local itemName = string.match(link, "%[(.-)%]")
                        if itemName and not IsSoulbound(bag, slot) then
                            local lowerName = string.lower(itemName)
                            if not playerInventory[lowerName] then
                                playerInventory[lowerName] = {inBags = false, inBank = true}
                            else
                                playerInventory[lowerName].inBank = true
                            end
                        end
                    end
                end
            end
        end
        
        -- Scan main bank (bag -1)
        local numBankSlots = GetNumBankSlots()
        for slot = 1, numBankSlots do
            local link = GetContainerItemLink(-1, slot)
            if link then
                local itemName = string.match(link, "%[(.-)%]")
                if itemName and not IsSoulbound(-1, slot) then
                    local lowerName = string.lower(itemName)
                    if not playerInventory[lowerName] then
                        playerInventory[lowerName] = {inBags = false, inBank = true}
                    else
                        playerInventory[lowerName].inBank = true
                    end
                end
            end
        end
        
        -- Update cached bank items
        bankCache = {}
        for itemName, locations in pairs(playerInventory) do
            if locations.inBank then
                bankCache[itemName] = true
            end
        end
    else
        -- Merge cached bank items when bank is closed
        for itemName, _ in pairs(bankCache) do
            if not playerInventory[itemName] then
                playerInventory[itemName] = {inBags = false, inBank = true}
            else
                playerInventory[itemName].inBank = true
            end
        end
    end
    
    if debugMode then
        local bagCount = 0
        local bankCount = 0
        for _, locations in pairs(playerInventory) do
            if locations.inBags then bagCount = bagCount + 1 end
            if locations.inBank then bankCount = bankCount + 1 end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Inventory] Scanned " .. bagCount .. " bag items, " .. bankCount .. " bank items|r")
    end
end

-- Returns location info if player has the item in inventory (not equipped, not soulbound)
-- Returns: nil if not found, or {inBags=bool, inBank=bool}
local function HasInInventory(itemName)
    if not inventoryAlerts then return nil end
    return playerInventory[string.lower(itemName)]
end

-- ================================================================
-- PROFESSION SCANNER
-- ================================================================
-- Scans the player's skill list to detect known professions
-- Stores them in playerProfessions table with abbreviations for matching
-- Called on login and zone change

local function ScanProfessions()
    playerProfessions = {}
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank = GetSkillLineInfo(i)
        -- Only include actual skills (not headers) with skill rank > 0
        if name and not isHeader and rank and rank > 0 then
            local lower = string.lower(name)
            -- Match against known profession abbreviations
            for profKey, abbrevs in pairs(PROF_ABBREVS) do
                if lower == profKey then
                    table.insert(playerProfessions, {
                        fullname = name,
                        key      = profKey,
                        abbrevs  = abbrevs,  -- List of abbreviations to match
                        rank     = rank,
                    })
                    break
                end
            end
        end
    end
end

-- ================================================================
-- LEVEL CACHE (passive)
-- Records player levels we observe via friends list, guild roster,
-- party, raid, target, mouseover, and /who results. Used as a fallback
-- when a WTS/WTB message has no explicit level range. Persisted in
-- HCTradeDB.levelCache across sessions. No network traffic generated.
-- ================================================================

local function CacheLevel(name, level)
    if not name or not level or level == 0 then return end
    HCTradeDB.levelCache = HCTradeDB.levelCache or {}
    local cached = HCTradeDB.levelCache[name]
    -- Only overwrite if new level is higher (handles seeing someone level up)
    if not cached or level > cached then
        HCTradeDB.levelCache[name] = level
    end
end

local function GetCachedLevel(name)
    if not HCTradeDB.levelCache then return nil end
    return HCTradeDB.levelCache[name]
end

-- Class cache (parallel to level cache)
-- Stores raw English class token, e.g. "WARRIOR", "PALADIN"
-- HCTradeDB.classCache = { ["PlayerName"] = "CLASSNAME", ... }
local CLASS_COLORS = {
    WARRIOR = "|cffc79c6e",
    PALADIN = "|cfff58cba",
    HUNTER  = "|cffabd473",
    ROGUE   = "|cfffff569",
    PRIEST  = "|cffffffff",
    SHAMAN  = "|cff0070de",
    MAGE    = "|cff69ccf0",
    WARLOCK = "|cff9482c9",
    DRUID   = "|cffff7d0a",
}

local function CacheClass(name, class)
    if not name or not class or class == "" then return end
    HCTradeDB.classCache = HCTradeDB.classCache or {}
    HCTradeDB.classCache[name] = string.upper(class)
end

local function GetCachedClass(name)
    if not HCTradeDB.classCache then return nil end
    return HCTradeDB.classCache[name]
end

local function GetClassColor(class)
    if not class then return nil end
    return CLASS_COLORS[string.upper(class)]
end

local function ScanFriendsLevels()
    for i = 1, GetNumFriends() do
        local name, level, class = GetFriendInfo(i)
        CacheLevel(name, level)
        CacheClass(name, class)
    end
end

local function ScanGuildLevels()
    if not IsInGuild() then return end
    for i = 1, GetNumGuildMembers() do
        local name, _, _, level, class = GetGuildRosterInfo(i)
        CacheLevel(name, level)
        CacheClass(name, class)
    end
end

local function ScanRaidLevels()
    for i = 1, GetNumRaidMembers() do
        local name, _, _, level, class = GetRaidRosterInfo(i)
        CacheLevel(name, level)
        CacheClass(name, class)
    end
end

local function ScanPartyLevels()
    for i = 1, GetNumPartyMembers() do
        local unit = "party"..i
        CacheLevel(UnitName(unit), UnitLevel(unit))
        local _, class = UnitClass(unit)
        CacheClass(UnitName(unit), class)
    end
end

local function ScanTargetLevel()
    if UnitIsPlayer("target") then
        CacheLevel(UnitName("target"), UnitLevel("target"))
        local _, class = UnitClass("target")
        CacheClass(UnitName("target"), class)
    end
end

local function ScanMouseoverLevel()
    if UnitIsPlayer("mouseover") then
        CacheLevel(UnitName("mouseover"), UnitLevel("mouseover"))
        local _, class = UnitClass("mouseover")
        CacheClass(UnitName("mouseover"), class)
    end
end

local function ScanWhoLevels()
    for i = 1, GetNumWhoResults() do
        local name, _, level, _, class = GetWhoInfo(i)
        CacheLevel(name, level)
        CacheClass(name, class)
    end
end

-- ================================================================
-- PROFESSION MATCHING (LF/LFW Detection)
-- ================================================================

-- Keywords that indicate someone is looking for crafting services
-- "LF BS", "LFW enchanter", "need BS my mats", etc.
local CRAFT_KEYWORDS = {
    "craft", "make", "create", "my mats", "your mats", "my matz", "your matz"
}

-- Items commonly associated with each profession
-- Used to detect requests like "LF leather worker for armor kit"
local PROFESSION_ITEMS = {
    ["blacksmithing"] = {"armor", "weapon", "shield", "plate", "mail", "sharpening stone", "weightstone"},
    ["leatherworking"] = {"leather", "hide", "skinning knife", "armor kit", "cloak", "bag", "salt", "salt shaker", "shaker"},
    ["tailoring"] = {"cloth", "bag", "robe", "shirt", "mageweave", "runecloth", "silk", "wool", "linen"},
    ["engineering"] = {"bomb", "scope", "goggles", "target dummy", "rocket", "grenade", "dynamite"},
    ["alchemy"] = {"potion", "elixir", "flask", "transmute"},
    ["enchanting"] = {"enchant", "enchanting"},
    ["herbalism"] = {"herb", "flower", "leaf", "bloom", "root", "weed"},
    ["mining"] = {"ore", "mining", "bar", "stones", "stone", "gem", "gems"},
    ["skinning"] = {"leather", "hide", "skinning knife", "pelt", "fur"},
    ["fishing"] = {"fish", "fishing"},
    ["cooking"] = {"food", "cooking", "food buff"},
    ["first aid"] = {"bandage", "first aid"},
    ["jewelcrafting"] = {"gem", "jewelcrafting", "jewelry", "ring", "necklace", "trinket", "neck", "finger", "wrist"},
}

-- Returns the matching profession entry if msg mentions one of the player's professions
local function MatchesProfession(msg)
    local s = string.lower(msg)

    -- Gate: only match professions if the message is a request for services,
    -- not a WTS post. Require either WTB or a "looking for" keyword.
    local hasLookingFor = string.find(s, "%f[%a]lfc?%f[%A]") or
                          string.find(s, "looking for") or
                          string.find(s, "%f[%a]wtb%f[%A]")
    if not hasLookingFor then return nil end

    -- First check direct profession mentions (LF BS, LF Enchanter, etc.)
    for _, prof in ipairs(playerProfessions) do
        for _, abbrev in ipairs(prof.abbrevs) do
            -- Match as a whole word (surrounded by spaces/start/end/punctuation)
            local pattern = "[%s%p^]" .. abbrev .. "[%s%p$]"
            if string.find(" " .. s .. " ", "%s" .. abbrev .. "%s") or
               string.find(" " .. s .. " ", "%p" .. abbrev .. "%s") or
               string.find(" " .. s .. " ", "%s" .. abbrev .. "%p") then
                return prof
            end
        end
    end
    
    -- Check for crafting keywords + profession-specific items
    local hasCraftKeyword = false
    for _, keyword in ipairs(CRAFT_KEYWORDS) do
        if string.find(s, keyword, 1, true) then
            hasCraftKeyword = true
            break
        end
    end
    
    if hasCraftKeyword then
        for _, prof in ipairs(playerProfessions) do
            local items = PROFESSION_ITEMS[prof.key]
            if items then
                for _, item in ipairs(items) do
                    if string.find(s, item, 1, true) then
                        return prof
                    end
                end
            end
        end
    end
    
    return nil
end

-- ================================================================
-- CUSTOM KEYWORD MATCHING
-- ================================================================
-- Checks if message matches any user-defined custom keywords
-- Returns: keyword object {keyword, color, display, quality} or nil
-- Supports exact match, plural matching ("wand" matches "wands"), and singular matching

-- Returns the matching custom keyword entry (case-insensitive)
local function MatchesCustomKeyword(msg)
    local s = string.lower(msg)
    
    -- Debug: print what we're searching for
    if debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[CustomKW Debug] Searching in: '" .. s .. "'|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[CustomKW Debug] Have " .. table.getn(customKeywords) .. " keywords loaded|r")
    end
    
    for _, kw in ipairs(customKeywords) do
        local keyword = string.lower(kw.keyword)
        
        if debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[CustomKW Debug] Testing keyword: '" .. keyword .. "'|r")
        end
        
        -- Try exact match first
        if string.find(s, keyword, 1, true) then
            if debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00cc00[CustomKW Debug] EXACT MATCH!|r")
            end
            return kw
        end
        -- Try with 's' appended (for plural matching)
        if string.find(s, keyword .. "s", 1, true) then
            if debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00cc00[CustomKW Debug] PLURAL MATCH (added 's')!|r")
            end
            return kw
        end
        -- If keyword ends with 's', try without it (reverse plural matching)
        if string.sub(keyword, -1) == "s" then
            local singular = string.sub(keyword, 1, -2)
            if string.find(s, singular, 1, true) then
                if debugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00cc00[CustomKW Debug] SINGULAR MATCH (removed 's')!|r")
                end
                return kw
            end
        end
    end
    
    if debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[CustomKW Debug] No match found|r")
    end
    
    return nil
end

-- ================================================================
-- POPUP STACK
-- ================================================================

local FADE_HOLD   = 12
local FADE_TIME   = 2
local STACK_GAP   = 4
local popupPool   = {}
local activeStack = {}

-- Anchor position — loaded from DB on login, updated on /hct lock
local ANCHOR_X    = 0
local ANCHOR_Y    = -180
local anchorFrame = nil  -- forward declaration so Restack can reference it
local soundMuted  = false

-- ESC-to-dismiss catcher frame: an invisible frame registered in
-- UISpecialFrames so that pressing ESC while popups are visible clears
-- the entire popup stack. Shown whenever activeStack is non-empty,
-- hidden whenever it becomes empty. ESC fires the OnHide handler which
-- dismisses every active popup at once.
local escCatcher = CreateFrame("Frame", "HCTradePopupEscCatcher", UIParent)
escCatcher:SetWidth(1) escCatcher:SetHeight(1)
escCatcher:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)  -- off-screen
escCatcher:Hide()
tinsert(UISpecialFrames, "HCTradePopupEscCatcher")
local escCatcherSuppress = false  -- prevents recursion when we hide it ourselves
escCatcher:SetScript("OnHide", function()
    if escCatcherSuppress then return end
    -- ESC was pressed (or some other code hid us): clear all popups
    for i = table.getn(activeStack), 1, -1 do
        local f = activeStack[i]
        table.remove(activeStack, i)
        f:Hide()
    end
end)

local function Restack()
    -- Show/hide the ESC catcher based on whether any popups are visible
    if table.getn(activeStack) > 0 then
        if not escCatcher:IsVisible() then
            escCatcher:Show()
        end
    else
        if escCatcher:IsVisible() then
            escCatcherSuppress = true
            escCatcher:Hide()
            escCatcherSuppress = false
        end
    end

    if anchorFrame and anchorFrame:IsVisible() then
        -- Anchor popups relative to the anchor frame itself — no coordinate conversion
        local y = 0
        for _, f in ipairs(activeStack) do
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", 0, y)
            y = y - f:GetHeight() - STACK_GAP
        end
    else
        local y = ANCHOR_Y
        for _, f in ipairs(activeStack) do
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", ANCHOR_X, y)
            y = y - f:GetHeight() - STACK_GAP
        end
    end
end

local function RemoveFromStack(f)
    for i, v in ipairs(activeStack) do
        if v == f then
            table.remove(activeStack, i)
            break
        end
    end
    f:Hide()
    Restack()
end

local function AcquirePopup()
    for _, f in ipairs(popupPool) do
        if not f:IsVisible() then
            f:SetAlpha(1)
            return f
        end
    end

  local f = CreateFrame("Frame", nil, UIParent)
    f:SetWidth(200)
    f:SetHeight(90)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    f:SetBackdropColor(0, 0, 0, 0.85)
    f:SetBackdropBorderColor(1.0, 0.82, 0, 1)

    -- Right-click to close
    f:SetScript("OnMouseDown", function()
        if arg1 == "RightButton" then
            RemoveFromStack(f)
        end
    end)

    local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
    header:SetWidth(200)
    header:SetText("HC Trade - level match!")
    header:SetTextColor(1.0, 0.82, 0)
    f.header = header

    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetWidth(14) closeBtn:SetHeight(14)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    closeBtn:SetBackdropColor(0, 0, 0, 1)
    closeBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    local xStr = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xStr:SetAllPoints(closeBtn)
    xStr:SetJustifyH("CENTER") xStr:SetJustifyV("MIDDLE")
    xStr:SetText("X") xStr:SetTextColor(0.7, 0.2, 0.2)
    closeBtn:SetScript("OnClick",  function() RemoveFromStack(f) end)
    closeBtn:SetScript("OnEnter",  function() this:SetBackdropBorderColor(1, 0.2, 0.2, 1) end)
    closeBtn:SetScript("OnLeave",  function() this:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) end)

    local whisperBtn = CreateFrame("Button", nil, f)
    whisperBtn:SetHeight(14)
    whisperBtn:SetWidth(200)
    whisperBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22)

    local whisperText = whisperBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    whisperText:SetPoint("TOPLEFT",     whisperBtn, "TOPLEFT",     0, 0)
    whisperText:SetPoint("BOTTOMRIGHT", whisperBtn, "BOTTOMRIGHT", 0, 0)
    whisperText:SetJustifyH("LEFT")
    whisperText:SetTextColor(1, 1, 1)
    f.whisperBtn  = whisperBtn
    f.whisperText = whisperText
    whisperBtn:SetScript("OnClick", function()
        if f._sender then
            ChatFrame_OpenChat("/w " .. f._sender .. " ", DEFAULT_CHAT_FRAME)
        end
    end)

    local rangeText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rangeText:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -38)
    rangeText:SetWidth(200)
    rangeText:SetHeight(14)
    rangeText:SetJustifyH("LEFT")
    f.rangeText = rangeText

    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -54)
    div:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -54)
    div:SetTexture(0.3, 0.3, 0.3, 1)
    f.divider = div

    local msgText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    msgText:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -60)
    msgText:SetWidth(200)
    msgText:SetJustifyH("LEFT")
    msgText:SetNonSpaceWrap(false)
    -- Don't set text color - let color codes in the text work
    f.msgText = msgText

    f.timer = 0
    f:SetScript("OnUpdate", function()
        if not f:IsVisible() then return end
        -- Apply deferred width on first tick after Show
        if f._needsResize then
            f._needsResize = false
            local dw = f._dynW or 200
            local iw = dw - 16
            f:SetWidth(dw)
            f.header:SetWidth(iw - 20)
            f.whisperBtn:SetWidth(iw)
            f.whisperText:SetWidth(iw)
            f.msgText:SetWidth(iw)
            f.rangeText:SetWidth(iw)
        end
        f.timer = f.timer + arg1
        local remaining = FADE_HOLD - f.timer
        if remaining <= -FADE_TIME then
            RemoveFromStack(f)
        elseif remaining <= 0 then
            f:SetAlpha(1 + remaining / FADE_TIME)
        else
            f:SetAlpha(1)
        end
    end)

    f:Hide()
    table.insert(popupPool, f)
    return f
end

-- ================================================================
-- SMART WRAP
-- Strips colour codes, wraps plain text respecting [Item] atomicity.
-- ================================================================

-- Measure real pixel width using a FontString that is shown off-screen
local measureFrame = nil
local measureFS    = nil

local function MeasureWidth(text)
    if not measureFrame then
        measureFrame = CreateFrame("Frame", nil, UIParent)
        measureFrame:SetWidth(2000)
        measureFrame:SetHeight(20)
        measureFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -3000, 0)
        measureFrame:Show()
        measureFS = measureFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        measureFS:SetPoint("TOPLEFT", measureFrame, "TOPLEFT", 0, 0)
        measureFS:SetWidth(2000)
        measureFS:SetJustifyH("LEFT")
    end
    measureFS:SetText(text)
    return measureFS:GetStringWidth()
end

local function StripCodes(s)
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    s = string.gsub(s, "|H.-|h(.-)%|h", "%1")
    s = string.gsub(s, "|T.-|t", "")
    s = string.gsub(s, "|[^|]", "")
    return s
end

local function SmartWrap(rawMsg, maxW)
    -- Work on plain text only — reliable, no code-position mapping needed
    local plain = StripCodes(rawMsg)

    -- Tokenise plain text, treating [bracketed names] as atomic
    local tokens = {}
    local pos = 1
    local len = string.len(plain)
    while pos <= len do
        while pos <= len and string.sub(plain, pos, pos) == " " do
            pos = pos + 1
        end
        if pos > len then break end
        if string.sub(plain, pos, pos) == "[" then
            local e = string.find(plain, "]", pos, true) or len
            table.insert(tokens, string.sub(plain, pos, e))
            pos = e + 1
        else
            local s = pos
            while pos <= len do
                local c = string.sub(plain, pos, pos)
                if c == " " or c == "[" then break end
                pos = pos + 1
            end
            if pos > s then
                table.insert(tokens, string.sub(plain, s, pos - 1))
            end
        end
    end

    if table.getn(tokens) == 0 then return plain, 1 end

    -- Build lines
    local lines = {}
    local currentLine = ""
    local currentW = 0

    for ti = 1, table.getn(tokens) do
        local tok = tokens[ti]
        local tokW = MeasureWidth(tok)
        if currentLine == "" then
            currentLine = tok
            currentW = tokW
        elseif currentW + MeasureWidth(" ") + tokW > maxW then
            table.insert(lines, currentLine)
            currentLine = tok
            currentW = tokW
        else
            currentLine = currentLine .. " " .. tok
            currentW = currentW + MeasureWidth(" ") + tokW
        end
    end
    if currentLine ~= "" then table.insert(lines, currentLine) end

    local result = ""
    for idx = 1, table.getn(lines) do
        result = (idx == 1) and lines[idx] or (result .. "\n" .. lines[idx])
    end
    return result, table.getn(lines)
end

-- ================================================================
-- RECOLOUR ITEMS
-- After SmartWrap returns plain text, re-apply colours to [Item] tokens
-- by extracting the colour codes that prefixed them in the original rawMsg.
-- Also recolours WTS/WTB words.
-- ================================================================

local WTS_COLOUR = "|cff7aaac8"
local WTB_COLOUR = "|cff7aaac8"
local RESET_CODE = "|r"

local function RecolourItems(plainText, rawMsg)
    -- Since HC addon strips color codes, we need to find item colors ourselves
    -- Scan bags for items and read their quality from tooltips
    
    if debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[RecolourItems] plainText: " .. plainText .. "|r")
    end

    local result = plainText
    local itemsFound = {}
    
    -- Create tooltip for scanning if it doesn't exist
    if not HCTradeScanTooltip then
        CreateFrame("GameTooltip", "HCTradeScanTooltip", nil, "GameTooltipTemplate")
    end
    
    -- Find all [Item Name] patterns in the message
    for itemName in string.gmatch(plainText, "%[(.-)%]") do
        if not itemsFound[itemName] then
            itemsFound[itemName] = true
            
            local colorCode = itemColorCache[itemName]  -- Check cache first
            
            if debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Cache Check] itemName='" .. itemName .. "' cached value='" .. (colorCode or "nil") .. "'|r")
            end
            
            if not colorCode or colorCode == "" then
                -- Scan bags for this item
                local foundBag, foundSlot = nil, nil
                for bag = 0, 4 do
                    for slot = 1, GetContainerNumSlots(bag) do
                        local link = GetContainerItemLink(bag, slot)
                        if link then
                            local linkItemName = string.match(link, "%[(.-)%]")
                            if linkItemName and linkItemName == itemName then
                                foundBag = bag
                                foundSlot = slot
                                break
                            end
                        end
                    end
                    if foundBag then break end
                end
                
                -- If not in bags, check bank if open
                if not foundBag and bankOpen then
                    for bag = 5, 11 do
                        for slot = 1, GetContainerNumSlots(bag) or 0 do
                            local link = GetContainerItemLink(bag, slot)
                            if link then
                                local linkItemName = string.match(link, "%[(.-)%]")
                                if linkItemName and linkItemName == itemName then
                                    foundBag = bag
                                    foundSlot = slot
                                    break
                                end
                            end
                        end
                        if foundBag then break end
                    end
                end
                
                -- Found the item in bags/bank - now read its color from tooltip
                if foundBag and foundSlot then
                    HCTradeScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                    HCTradeScanTooltip:ClearLines()
                    HCTradeScanTooltip:SetBagItem(foundBag, foundSlot)  -- Load item into tooltip
                    
                    -- Read the RGB color of the first line (item name)
                    local nameText = getglobal("HCTradeScanTooltipTextLeft1")
                    if nameText then
                        local r, g, b = nameText:GetTextColor()  -- Get RGB values (0.0-1.0)
                        
                        if debugMode then
                            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Tooltip] RGB = " .. string.format("%.2f, %.2f, %.2f", r, g, b) .. "|r")
                        end
                        
                        -- Map RGB color to quality code
                        -- Reference RGB values from WoW 1.12.1:
                        -- Poor (gray):     0.62, 0.62, 0.62
                        -- Common (white):  1.0,  1.0,  1.0
                        -- Uncommon (green): 0.12, 1.0,  0.0
                        -- Rare (blue):     0.0,  0.44, 0.87
                        -- Epic (purple):   0.64, 0.21, 0.93
                        
                        if r > 0.6 and g > 0.6 and b > 0.6 then
                            -- High values on all channels = gray or white
                            if r > 0.9 then
                                colorCode = QUALITY_COLORS["Common"] or "|cffffffff"  -- White
                            else
                                colorCode = QUALITY_COLORS["Junk"] or "|cff9d9d9d"  -- Gray
                            end
                        elseif g > 0.9 and r < 0.2 and b < 0.2 then
                            -- High green, low red/blue = uncommon (green)
                            colorCode = QUALITY_COLORS["Uncommon"] or "|cff1eff00"
                        elseif b > 0.8 and r < 0.2 and g < 0.5 then
                            -- High blue, low red/green = rare (blue)
                            colorCode = QUALITY_COLORS["Rare"] or "|cff0070ff"
                        elseif r > 0.6 and b > 0.8 and g < 0.3 then
                            -- High red+blue, low green = epic (purple)
                            colorCode = QUALITY_COLORS["Epic"] or "|cffa335ee"
                        else
                            colorCode = "|cffffffff"  -- Default to white if can't determine
                        end
                        
                        if debugMode then
                            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Tooltip] Assigned colorCode = '" .. (colorCode or "nil") .. "'|r")
                        end
                        
                        -- Cache the color permanently (saved to HCTradeDB on logout)
                        itemColorCache[itemName] = colorCode
                        if debugMode then
                            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[RecolourItems] Found & cached: [" .. itemName .. "] RGB(" .. string.format("%.2f,%.2f,%.2f",r,g,b) .. ") color=" .. colorCode .. "|r")
                        end
                    end
                    HCTradeScanTooltip:Hide()
                elseif debugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[RecolourItems] Item not in bags/bank - will show white|r")
                end
            else
                if debugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[RecolourItems] Using cached color for [" .. itemName .. "]: " .. colorCode .. "|r")
                end
            end
            
            if colorCode then
                -- Escape special pattern characters in the item name
                local escapedName = string.gsub(itemName, "([%[%]%(%)%.%+%-%*%?%^%$%%])", "%%%1")
                -- Match [ItemName] with any character (including newline) after
                local pattern = "(%[" .. escapedName .. "%])"
                local replacement = colorCode .. "[" .. itemName .. "]" .. RESET_CODE
                
                if debugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Replace] Pattern: '" .. pattern .. "'|r")
                    DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Replace] With: '" .. replacement .. "'|r")
                    DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Replace] Before: '" .. result .. "'|r")
                end
                
                result = string.gsub(result, pattern, replacement)
                
                if debugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Replace] After: '" .. result .. "'|r")
                end
            end
        end
    end

    -- Recolour WTS, WTB, and WTT (case-insensitive, preserves original casing)
    result = string.gsub(result, "^([Ww][Tt][Ss])%s",   WTS_COLOUR .. "%1" .. RESET_CODE .. " ")
    result = string.gsub(result, "%s([Ww][Tt][Ss])%s", " " .. WTS_COLOUR .. "%1" .. RESET_CODE .. " ")
    result = string.gsub(result, "\n([Ww][Tt][Ss])%s", "\n" .. WTS_COLOUR .. "%1" .. RESET_CODE .. " ")

    result = string.gsub(result, "^([Ww][Tt][Bb])%s",   WTB_COLOUR .. "%1" .. RESET_CODE .. " ")
    result = string.gsub(result, "%s([Ww][Tt][Bb])%s", " " .. WTB_COLOUR .. "%1" .. RESET_CODE .. " ")
    result = string.gsub(result, "\n([Ww][Tt][Bb])%s", "\n" .. WTB_COLOUR .. "%1" .. RESET_CODE .. " ")

    result = string.gsub(result, "^([Ww][Tt][Tt])%s",   WTB_COLOUR .. "%1" .. RESET_CODE .. " ")
    result = string.gsub(result, "%s([Ww][Tt][Tt])%s", " " .. WTB_COLOUR .. "%1" .. RESET_CODE .. " ")
    result = string.gsub(result, "\n([Ww][Tt][Tt])%s", "\n" .. WTB_COLOUR .. "%1" .. RESET_CODE .. " ")

    return result
end

-- ================================================================
-- SHOW POPUP
-- ================================================================

local function ShowPopup(sender, msg, rawMsg, rangeMin, rangeMax, header, borderColor, customSound)
    local f  = AcquirePopup()
    local GOLD  = "|cffffd100"
    local WHITE = "|cffffffff"
    local RESET = "|r"

    local MAX_W     = 350   -- hard cap on frame width
    local MIN_W     = 120   -- minimum frame width
    local PAD       = 24    -- left + right padding
    local CONTENT_W = 250   -- wrap text at this width regardless of frame size

    f._sender = sender
    f.header:SetText(header or "HCTrade - level match!")
    -- Color the sender name by class if cached, otherwise default magenta
    local senderColor = "|cffff00ff"  -- default magenta (unknown class)
    local cachedClass = GetCachedClass(sender)
    if cachedClass then
        local classCol = GetClassColor(cachedClass)
        if classCol then senderColor = classCol end
    end
    f.whisperText:SetText(senderColor .. "<" .. sender .. ">|r  |cffaaaaaa[click to whisper]|r")
    
    -- Set custom border color if provided (default gold: 1.0, 0.82, 0)
    if borderColor then
        f:SetBackdropBorderColor(borderColor.r, borderColor.g, borderColor.b, 1)
        f.header:SetTextColor(borderColor.r, borderColor.g, borderColor.b)
    else
        f:SetBackdropBorderColor(1.0, 0.82, 0, 1)
        f.header:SetTextColor(1.0, 0.82, 0)
    end
    
    -- First pass: wrap at CONTENT_W to find natural line breaks
    local wrappedMsg, lineCount = SmartWrap(rawMsg, CONTENT_W)

    -- Measure longest line to get dynW
    local longestW = MIN_W - PAD
    local plainWrapped = StripCodes(wrappedMsg)
    local lstart = 1
    while lstart <= string.len(plainWrapped) do
        local lend = string.find(plainWrapped, "\n", lstart)
        if not lend then lend = string.len(plainWrapped) + 1 end
        local lineW = MeasureWidth(string.sub(plainWrapped, lstart, lend - 1))
        if lineW > longestW then longestW = lineW end
        lstart = lend + 1
    end
    local rangeW   = MeasureWidth("Level: " .. rangeMin .. "-" .. rangeMax)
    local headerW  = MeasureWidth(header or "HCTrade - level match!")
    local whisperW = MeasureWidth("<" .. sender .. ">  [click to whisper]")
    if rangeW   > longestW then longestW = rangeW   end
    if headerW  > longestW then longestW = headerW  end
    if whisperW > longestW then longestW = whisperW end
    local dynW = math.min(MAX_W, math.max(MIN_W, longestW + PAD))

    -- Second pass: re-wrap at actual content width so text fills the frame
    wrappedMsg, lineCount = SmartWrap(rawMsg, dynW - PAD)
    f.msgText:SetText(RecolourItems(wrappedMsg, rawMsg))
    f._lineCount = lineCount

    f.rangeText:SetText(GOLD .. "Level: " .. RESET .. WHITE .. rangeMin .. "-" .. rangeMax .. RESET)

    f.timer = 0
    f:SetAlpha(1)

    local LINE_H  = 14
    local msgH    = f._lineCount * LINE_H
    local totalH  = 20 + 18 + msgH + 4 + 14 + 10
    local innerW  = dynW - 16

    f._dynW = dynW
    f._needsResize = true
    f:SetHeight(totalH)

    table.insert(activeStack, f)
    Restack()
    f:Show()

    if not soundMuted then
        if customSound then
            PlaySoundFile(customSound)
        else
            PlaySoundFile("Interface\\AddOns\\HCTrade\\Sound\\Alert.ogg")
        end
    end
end

-- ================================================================
-- CORE MESSAGE PROCESSOR
-- ================================================================
-- Main entry point for processing HC chat messages
-- Flow:
-- 1. Check if message contains WTS/WTB
-- 2. Parse level range from message
-- 3. Check if player's level is in range
-- 4. Priority checks (in order):
--    a. Custom keywords - user-defined alerts
--    b. Inventory alerts - WTB items you own
--    c. Profession matches - LF BS, LF enchanter, etc.
--    d. Standard trade match - any WTS/WTB in level range
-- Each check returns early if it triggers, so only one popup per message

local function ProcessHCMessage(sender, msg, rawMsg)
    -- Master switch: skip everything if notifications are disabled
    if not notificationsEnabled then return end
    -- Ignore non-trade messages
    if not IsTradeMessage(msg) then return end

    local rangeMin, rangeMax = ParseLevelRange(msg)
    local pl = UnitLevel("player")

    -- Fallback: if no level range was found in the message, try to use
    -- the sender's cached level (gathered passively from friends/guild/
    -- party/raid/target/mouseover/who results)
    local usedCachedLevel = false
    if not rangeMin then
        local cached = GetCachedLevel(sender)
        if cached then
            rangeMin = math.max(1, cached - LEVEL_CACHE_RANGE)
            rangeMax = math.min(60, cached + LEVEL_CACHE_RANGE)
            usedCachedLevel = true
            if debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[HCTrade] Using cached level " .. cached .. " for " .. sender .. "|r")
            end
        end
    end

    -- Debug output: show what we parsed
    if debugMode then
        local GOLD  = "|cffffd100"
        local WHITE = "|cffffffff"
        local RED   = "|cffff4444"
        local GREEN = "|cff00cc00"
        local RESET = "|r"
        local rangeStr = rangeMin and (rangeMin .. "-" .. rangeMax) or "none"
        local matchStr
        if not rangeMin then
            matchStr = RED .. "no level found" .. RESET
        elseif PlayerLevelInRange(rangeMin, rangeMax) then
            matchStr = GREEN .. "MATCH (your lvl " .. pl .. " in " .. rangeStr .. ")" .. RESET
        else
            matchStr = RED .. "no match (your lvl " .. pl .. " not in " .. rangeStr .. ")" .. RESET
        end
        DEFAULT_CHAT_FRAME:AddMessage(GOLD .. "[HCTrade] " .. RESET .. WHITE .. sender .. RESET .. ": " .. msg)
        DEFAULT_CHAT_FRAME:AddMessage(GOLD .. "  => range: " .. WHITE .. rangeStr .. RESET .. "  " .. matchStr)
        DEFAULT_CHAT_FRAME:AddMessage(GOLD .. "  => raw msg fed to parser: |r|cffffffff" .. msg .. "|r")
    end

    -- PRIORITY 1: Custom keyword match (highest priority)
    -- Check for user-defined keywords (e.g., "wand", "armor kit")
    -- These trigger regardless of profession/inventory
    if rangeMin and PlayerLevelInRange(rangeMin, rangeMax) then
        if debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[HCTrade] Checking custom keywords...|r")
        end
        local kw = MatchesCustomKeyword(msg)
        if kw then
            -- Build display message with keyword highlighted in its chosen color
            local displayMsg = rawMsg or msg
            local escaped = string.gsub(kw.keyword, "([%[%]%(%)%.%+%-%*%?%^%$%%])", "%%%1")
            local coloured = kw.color .. "[" .. kw.display .. "]|r"
            displayMsg = string.gsub(displayMsg, escaped, coloured)
            local kwHeader = "HCTrade - WTB"
            if string.find(string.lower(msg), "wts") then kwHeader = "HCTrade - WTS" end
            ShowPopup(sender, msg, displayMsg, rangeMin, rangeMax, kwHeader)
            return  -- Early return - Alert.ogg plays inside ShowPopup
        end
    end

    -- PRIORITY 2: Inventory match - WTB items you own
    -- Special green notification when someone wants to buy items you have
    if rangeMin and PlayerLevelInRange(rangeMin, rangeMax) and inventoryAlerts then
        if debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[HCTrade] Checking inventory (enabled: " .. tostring(inventoryAlerts) .. ")...|r")
        end
        if string.find(string.lower(msg), "wtb") or string.find(string.lower(msg), "wtt") then
            -- Extract item names from message
            for itemName in string.gmatch(msg, "%[(.-)%]") do
                if debugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Inventory] Testing item: '" .. itemName .. "'|r")
                end
                local location = HasInInventory(itemName)
                if location then
                    if debugMode then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc00[Inventory] Match found: " .. itemName .. "|r")
                    end
                    -- Build header based on location
                    local locationText = ""
                    if location.inBags and location.inBank then
                        locationText = " (Bags + Bank)"
                    elseif location.inBags then
                        locationText = " (Bags)"
                    elseif location.inBank then
                        locationText = " (Bank)"
                    end
                    -- Green-gold border for "You have this!" alerts with custom Inventory sound
                    ShowPopup(sender, msg, rawMsg or msg, rangeMin, rangeMax, "HCTrade - " .. locationText, {r=0.4, g=0.8, b=0.2}, "Interface\\AddOns\\HCTrade\\Sound\\Inventory.ogg")
                    return
                end
            end
            if debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[Inventory] No match found|r")
            end
        end
    end

    -- Check for profession match (LF BS, LF Enchanter, etc.)
    if rangeMin and PlayerLevelInRange(rangeMin, rangeMax) then
        local prof = MatchesProfession(msg)
        if prof then
            ShowPopup(sender, msg, rawMsg or msg, rangeMin, rangeMax, "HCTrade - " .. prof.fullname)
            if not tradeskillMuted then
                PlaySoundFile("Interface\\AddOns\\HCTrade\\Sound\\Tradeskill.ogg")
            end
            return  -- Early return
        end
    end

    -- PRIORITY 4: Standard trade match
    -- Any WTS/WTB message that matches level range
    -- (This is the fallback if none of the above matched)
    if not rangeMin then return end  -- No level found in message
    if not PlayerLevelInRange(rangeMin, rangeMax) then return end  -- Out of level range
    
    -- Optional filter: "Only show WTB if you own at least one item"
    -- If enabled, skip WTB messages unless they mention items you have
    local isWTB = string.find(string.lower(msg), "wtb")
    if onlyOwnedWTB and isWTB then
        local hasOwnedItem = false
        for itemName in string.gmatch(msg, "%[(.-)%]") do
            if HasInInventory(itemName) then
                hasOwnedItem = true
                break
            end
        end
        
        if not hasOwnedItem then
            if debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Filter] WTB filtered (no owned items, onlyOwnedWTB=true)|r")
            end
            return  -- Skip this WTB
        end
    end
    
    -- Show standard trade notification
    local tradeHeader = "HCTrade - WTB"
    if string.find(string.lower(msg), "wts") then tradeHeader = "HCTrade - WTS" end
    ShowPopup(sender, msg, rawMsg or msg, rangeMin, rangeMax, tradeHeader)
end

-- ================================================================
-- CHAT FRAME HOOK
-- ================================================================
-- Intercepts messages added to the HC chat frame
-- Extracts sender name and message text, then processes for trade alerts

local function DoHook(frame, label)
    if hookedFrame == frame then return end

    -- Unhook previous frame if any: restore its original AddMessage
    if hookedFrame and hookedFrame._hctOrigAddMessage then
        hookedFrame.AddMessage = hookedFrame._hctOrigAddMessage
        hookedFrame._hctOrigAddMessage = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Unhooked previous frame.")
    end

    hookedFrame = frame

    -- Save original on the frame itself so we can restore it later
    frame._hctOrigAddMessage = frame.AddMessage
    local origAddMessage = frame.AddMessage
    frame.AddMessage = function(self, text, r, g, b, id)
        origAddMessage(self, text, r, g, b, id)
        if not text then return end
        -- Strip for parsing (plain text only)
        local plain = text
        plain = string.gsub(plain, "|H.-|h(.-)%|h", "%1")
        plain = string.gsub(plain, "|c%x%x%x%x%x%x%x%x", "")
        plain = string.gsub(plain, "|r", "")
        plain = string.gsub(plain, "|T.-|t", "")
        plain = string.gsub(plain, "|[^|]", "")
        if sniffMode then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[HCTrade sniff]|r " .. plain)
        end
        -- Master + HC sub-toggle gate
        if not (notificationsEnabled and hardcoreEnabled) then return end
        -- Channel filter: only process Hardcore channel messages
        if not (string.find(plain, "%[Hardcore%]") or string.find(plain, "^%[HC%]") or string.find(plain, "%s%[HC%]")) then
            return
        end
        -- Extract sender and message body
        -- Try [Hardcore] [sender]: format
        local rawSender, msg = string.match(plain, "%[Hardcore%]%s*%[(.-)%]:?%s*(.*)")
        if not rawSender then
            -- Try [H] [sender]: format
            rawSender, msg = string.match(plain, "%[HC%]%s*%[(.-)%]:?%s*(.*)")
        end
        if not rawSender then
            -- Fallback: <sender> format
            rawSender, msg = string.match(plain, "<(.-)>%s*(.*)")
        end
        if not rawSender or not msg or msg == "" then return end
        local sender = string.match(rawSender, "^%d+:(.+)") or rawSender
        -- Extract rawMsg from original text (preserves colour codes and item links)
        local rawMsg = text
        -- Try to strip everything up through "[sender]:" or "<sender>"
        local stripped = string.match(rawMsg, "%[Hardcore%].-%[.-%]:?%s*(.*)")
        if not stripped then
            stripped = string.match(rawMsg, "%[HC%].-%[.-%]:?%s*(.*)")
        end
        if not stripped then
            stripped = string.match(rawMsg, "<.->%s*(.*)")
        end
        rawMsg = stripped or msg
        ProcessHCMessage(sender, msg, rawMsg)
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Hooked frame " .. label .. ".")
end

local function HookHCFrame()
    for i = 1, 10 do
        local tab = getglobal("ChatFrame" .. i .. "Tab")
        if tab then
            local title = tab:GetText() or ""
            if string.find(string.upper(title), "HC") then
                hookedIndex = i
                DoHook(getglobal("ChatFrame" .. i), i .. ' ("' .. title .. '")')
                return
            end
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cffff4444HCTrade:|r No HC frame found. Use |cffffffff/hct status|r to see all frames, then |cffffffff/hct hook N|r to hook frame N manually.")
end

-- ================================================================
-- EVENT HANDLERS
-- ================================================================
-- Responds to game events to keep data synchronized:
-- - VARIABLES_LOADED: Load saved settings from WTF folder
-- - PLAYER_ENTERING_WORLD: Scan professions/inventory, hook HC frame
-- - PLAYER_LOGOUT: Save item color cache to disk
-- - BAG_UPDATE: Rescan inventory when items change
-- - BANKFRAME_OPENED: Mark bank as open, scan bank items
-- - BANKFRAME_CLOSED: Mark bank as closed, save bank cache
-- - PLAYERBANKSLOTS_CHANGED: Rescan bank if window is open

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("VARIABLES_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("BANKFRAME_OPENED")
eventFrame:RegisterEvent("BANKFRAME_CLOSED")
eventFrame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
eventFrame:RegisterEvent("FRIENDLIST_UPDATE")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
eventFrame:RegisterEvent("WHO_LIST_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_GUILD")
eventFrame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        -- Load all saved settings from HCTradeDB (SavedVariables)
        if HCTradeDB.anchorX     then ANCHOR_X       = HCTradeDB.anchorX     end
        if HCTradeDB.anchorY     then ANCHOR_Y       = HCTradeDB.anchorY     end
        if HCTradeDB.soundMuted  ~= nil then soundMuted      = HCTradeDB.soundMuted  end
        if HCTradeDB.notificationsEnabled ~= nil then notificationsEnabled = HCTradeDB.notificationsEnabled end
        if HCTradeDB.hardcoreEnabled      ~= nil then hardcoreEnabled      = HCTradeDB.hardcoreEnabled      end
        if HCTradeDB.guildEnabled         ~= nil then guildEnabled         = HCTradeDB.guildEnabled         end
        if HCTradeDB.tradeskillMuted ~= nil then tradeskillMuted = HCTradeDB.tradeskillMuted end
        if HCTradeDB.inventoryAlerts ~= nil then inventoryAlerts = HCTradeDB.inventoryAlerts end
        if HCTradeDB.onlyOwnedWTB ~= nil then onlyOwnedWTB = HCTradeDB.onlyOwnedWTB end
        if HCTradeDB.fadeHold    then FADE_HOLD      = HCTradeDB.fadeHold    end
        
        -- Load custom keywords list
        customKeywords = {}
        if HCTradeDB.customKeywords then
            for _, kw in ipairs(HCTradeDB.customKeywords) do
                table.insert(customKeywords, kw)
            end
        end
        
        -- Load bank item cache (persists when bank is closed)
        if HCTradeDB.bankCache then
            bankCache = HCTradeDB.bankCache
        end
        
        -- Load item color cache (prevents re-scanning items every session)
        if HCTradeDB.itemColorCache then
            itemColorCache = HCTradeDB.itemColorCache
        end

        -- Initialize level cache (passive sender level tracking)
        HCTradeDB.levelCache = HCTradeDB.levelCache or {}
        HCTradeDB.classCache = HCTradeDB.classCache or {}
        
        ScanProfessions()  -- Detect player's professions
        ScanInventory()    -- Initial inventory scan
    end
    
    if event == "PLAYER_ENTERING_WORLD" then
        -- Rescan on login/reload (professions might have changed)
        ScanProfessions()
        ScanInventory()
        -- Seed level cache with what we already know
        CacheLevel(UnitName("player"), UnitLevel("player"))
        local _, playerClass = UnitClass("player")
        CacheClass(UnitName("player"), playerClass)
        ScanFriendsLevels()
        ScanGuildLevels()
        ScanPartyLevels()
        ScanRaidLevels()
        -- Auto-hook HC chat frame if not already hooked
        if not hookedFrame then
            -- Try saved manual choice first
            if HCTradeDB.hookedIndex then
                local savedFrame = getglobal("ChatFrame" .. HCTradeDB.hookedIndex)
                if savedFrame then
                    local tab = getglobal("ChatFrame" .. HCTradeDB.hookedIndex .. "Tab")
                    local title = (tab and tab:GetText()) or "?"
                    hookedIndex = HCTradeDB.hookedIndex
                    DoHook(savedFrame, HCTradeDB.hookedIndex .. ' ("' .. title .. '") [restored]')
                else
                    HookHCFrame()
                end
            else
                HookHCFrame()
            end
        end
    end
    
    if event == "BAG_UPDATE" then
        -- Rescan inventory when items are added/removed from bags
        ScanInventory()
    end
    
    if event == "BANKFRAME_OPENED" then
        bankOpen = true
        ScanInventory()
    end
    if event == "BANKFRAME_CLOSED" then
        bankOpen = false
        -- Save bank cache to DB before closing
        HCTradeDB.bankCache = bankCache
        -- Also save item color cache
        HCTradeDB.itemColorCache = itemColorCache
    end
    if event == "PLAYER_LOGOUT" then
        -- Save item color cache on logout
        HCTradeDB.itemColorCache = itemColorCache
    end
    if event == "PLAYERBANKSLOTS_CHANGED" then
        if bankOpen then
            ScanInventory()
        end
    end

    -- Level cache events (passive, no network traffic)
    if event == "FRIENDLIST_UPDATE" then
        ScanFriendsLevels()
    end
    if event == "GUILD_ROSTER_UPDATE" then
        ScanGuildLevels()
    end
    if event == "RAID_ROSTER_UPDATE" then
        ScanRaidLevels()
    end
    if event == "PARTY_MEMBERS_CHANGED" then
        ScanPartyLevels()
    end
    if event == "PLAYER_TARGET_CHANGED" then
        ScanTargetLevel()
    end
    if event == "UPDATE_MOUSEOVER_UNIT" then
        ScanMouseoverLevel()
    end
    if event == "WHO_LIST_UPDATE" then
        ScanWhoLevels()
    end
    if event == "CHAT_MSG_GUILD" then
        -- arg1 = message body, arg2 = sender name (no [G]/<lvl:name> prefix on raw event)
        if notificationsEnabled and guildEnabled and arg1 and arg2 then
            ProcessHCMessage(arg2, arg1, arg1)
        end
    end
end)

-- Deferred inventory scan ticker: runs a final scan ~1s after a burst
-- of BAG_UPDATE events (e.g. from a bag-sort addon). Cheap when idle:
-- a single boolean check per frame.
eventFrame:SetScript("OnUpdate", function()
    if pendingInventoryScan then
        local now = GetTime()
        if now - lastInventoryScan >= INVENTORY_SCAN_COOLDOWN then
            ScanInventory()
        end
    end
end)

-- ================================================================
-- SLASH COMMANDS  /hct
-- ================================================================

-- ================================================================
-- ANCHOR FRAME (shown during /hct unlock for repositioning)
-- ================================================================

local function CreateAnchorFrame()
    if anchorFrame then return end
    anchorFrame = CreateFrame("Frame", "HCTradeAnchor", UIParent)
    anchorFrame:SetWidth(120)
    anchorFrame:SetHeight(16)
    anchorFrame:SetFrameStrata("TOOLTIP")  -- above popups so it's clickable
    anchorFrame:SetMovable(true)
    anchorFrame:EnableMouse(true)
    anchorFrame:SetClampedToScreen(true)
    anchorFrame:RegisterForDrag("LeftButton")
    anchorFrame:SetScript("OnDragStart", function()
        -- Record cursor position and current anchor offset at drag start
        local scale = UIParent:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        this._dragStartCX = cx / scale
        this._dragStartCY = cy / scale
        this._dragStartAX = ANCHOR_X
        this._dragStartAY = ANCHOR_Y
        this:SetScript("OnUpdate", function()
            local s = UIParent:GetEffectiveScale()
            local mx, my = GetCursorPosition()
            mx = mx / s
            my = my / s
            local dx = mx - this._dragStartCX
            local dy = my - this._dragStartCY
            ANCHOR_X = this._dragStartAX + dx
            ANCHOR_Y = this._dragStartAY + dy
            -- Reposition anchor frame to match
            anchorFrame:ClearAllPoints()
            anchorFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", ANCHOR_X, ANCHOR_Y)
            Restack()
        end)
    end)
    anchorFrame:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
    end)
    anchorFrame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    anchorFrame:SetBackdropColor(0, 0, 0, 0.5)
    anchorFrame:SetBackdropBorderColor(1.0, 0.3, 0.3, 1)  -- red border so it's obvious

    local label = anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", anchorFrame, "CENTER", 0, 0)
    label:SetText("|cffff4444[drag]|r")
    label:SetTextColor(1.0, 0.82, 0)

    anchorFrame:Hide()
end

local function ShowAnchor()
    CreateAnchorFrame()
    anchorFrame:ClearAllPoints()
    anchorFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", ANCHOR_X, ANCHOR_Y)
    anchorFrame:Show()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Anchor unlocked. Drag to reposition, then type |cffffffff/hct lock|r.")
end

local function LockAnchor()
    if not anchorFrame or not anchorFrame:IsVisible() then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Anchor is not open. Use |cffffffff/hct unlock|r first.")
        return
    end
    -- ANCHOR_X/Y were already updated on drag stop — just save and hide
    HCTradeDB.anchorX = ANCHOR_X
    HCTradeDB.anchorY = ANCHOR_Y
    anchorFrame:Hide()
    Restack()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Anchor saved at (" .. math.floor(ANCHOR_X) .. ", " .. math.floor(ANCHOR_Y) .. ").")
end


-- ================================================================
-- MENU GUI
-- ================================================================

local menuFrame    = nil
local kwListFrames = {}  -- list of row frames for custom keywords

local function SaveCustomKeywords()
    HCTradeDB.customKeywords = {}
    for _, kw in ipairs(customKeywords) do
        table.insert(HCTradeDB.customKeywords, kw)
    end
end

local function CreateMenuFrame()
    if menuFrame then return end

    menuFrame = CreateFrame("Frame", "HCTradeMenu", UIParent)
    menuFrame:SetWidth(260)
    menuFrame:SetHeight(353)
    menuFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    menuFrame:SetFrameStrata("DIALOG")
    menuFrame:SetMovable(true)
    menuFrame:EnableMouse(true)
    menuFrame:SetClampedToScreen(true)
    menuFrame:RegisterForDrag("LeftButton")
    menuFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    menuFrame:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)
    menuFrame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    menuFrame:SetBackdropColor(0, 0, 0, 0.85)
    menuFrame:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    tinsert(UISpecialFrames, "HCTradeMenu")

    -- Title
    local title = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", menuFrame, "TOP", 0, -10)
    title:SetText("HCTrade")
    title:SetTextColor(1.0, 0.82, 0)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, menuFrame)
    closeBtn:SetWidth(18) closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -2, -2)
    closeBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    closeBtn:SetBackdropColor(0, 0, 0, 1)
    closeBtn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    local xStr = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xStr:SetAllPoints(closeBtn)
    xStr:SetJustifyH("CENTER") xStr:SetJustifyV("MIDDLE")
    xStr:SetText("X") xStr:SetTextColor(0.7, 0.2, 0.2)
    closeBtn:SetScript("OnClick", function() menuFrame:Hide() end)
    closeBtn:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, 0.2, 0.2, 1) end)
    closeBtn:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) end)

    -- Helper: styled button
    local PAD = 14
    local BTN_W = 260 - PAD * 2
    local BTN_H = 22

    local function MakeBtn(label, yOff, onClick)
        local b = CreateFrame("Button", nil, menuFrame, "UIPanelButtonTemplate")
        b:SetWidth(BTN_W) b:SetHeight(BTN_H)
        b:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", PAD, yOff)
        b:SetText(label)
        b:GetFontString():SetTextColor(1.0, 0.82, 0)
        -- Strip Blizzard textures
        if b:GetNormalTexture()    then b:GetNormalTexture():SetTexture(nil)    end
        if b:GetPushedTexture()    then b:GetPushedTexture():SetTexture(nil)    end
        if b:GetHighlightTexture() then b:GetHighlightTexture():SetTexture(nil) end
        if b:GetDisabledTexture()  then b:GetDisabledTexture():SetTexture(nil)  end
        b:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false, tileSize = 0, edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        b:SetBackdropColor(0, 0, 0, 1)
        b:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        b._restR, b._restG, b._restB, b._restA = 0.2, 0.2, 0.2, 1
        b:SetScript("OnEnter", function()
            this.isHovered = true
            this:SetBackdropBorderColor(1.0, 0.82, 0, 1)
        end)
        b:SetScript("OnLeave", function()
            this.isHovered = false
            this:SetBackdropBorderColor(this._restR, this._restG, this._restB, this._restA)
        end)
        b:SetScript("OnClick", onClick)
        return b
    end

    -- Helper: half-width button (for paired buttons)
    local HALF_W = math.floor((BTN_W - 4) / 2)
    local function MakeHalfBtn(label, xOff, yOff, onClick)
        local b = CreateFrame("Button", nil, menuFrame, "UIPanelButtonTemplate")
        b:SetWidth(HALF_W) b:SetHeight(BTN_H)
        b:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", xOff, yOff)
        b:SetText(label)
        b:GetFontString():SetTextColor(1.0, 0.82, 0)
        if b:GetNormalTexture()    then b:GetNormalTexture():SetTexture(nil)    end
        if b:GetPushedTexture()    then b:GetPushedTexture():SetTexture(nil)    end
        if b:GetHighlightTexture() then b:GetHighlightTexture():SetTexture(nil) end
        if b:GetDisabledTexture()  then b:GetDisabledTexture():SetTexture(nil)  end
        b:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false, tileSize = 0, edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        b:SetBackdropColor(0, 0, 0, 1)
        b:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        b._restR, b._restG, b._restB, b._restA = 0.2, 0.2, 0.2, 1
        b:SetScript("OnEnter", function()
            this.isHovered = true
            this:SetBackdropBorderColor(1.0, 0.82, 0, 1)
        end)
        b:SetScript("OnLeave", function()
            this.isHovered = false
            this:SetBackdropBorderColor(this._restR, this._restG, this._restB, this._restA)
        end)
        b:SetScript("OnClick", onClick)
        return b
    end

    -- Helper: make a FishingVolume-style checkbox
    local chkCounter = 0
    local function MakeCheckbox(label, yOff, initVal, onChange)
        chkCounter = chkCounter + 1
        local chkName = "HCTradeChk" .. chkCounter
        local chk = CreateFrame("CheckButton", chkName, menuFrame, "OptionsCheckButtonTemplate")
        chk:SetWidth(18) chk:SetHeight(18)
        chk:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", PAD, yOff)

        -- StripBlizzard
        local n = chk:GetName()
        for _, tex in pairs({"Left","Middle","Right","DisabledLeft","DisabledMiddle","DisabledRight"}) do
            if getglobal(n..tex) then getglobal(n..tex):SetTexture(nil) end
        end
        if chk:GetNormalTexture()    then chk:GetNormalTexture():SetTexture(nil)    end
        if chk:GetPushedTexture()    then chk:GetPushedTexture():SetTexture(nil)    end
        if chk:GetHighlightTexture() then chk:GetHighlightTexture():SetTexture(nil) end

        -- ApplyPFStyle (with hover)
        chk:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false, tileSize = 0, edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        chk:SetBackdropColor(0, 0, 0, 1)
        chk:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        chk:SetScript("OnEnter", function()
            this.isHovered = true
            this:SetBackdropBorderColor(1.0, 0.82, 0, 1)
        end)
        chk:SetScript("OnLeave", function()
            this.isHovered = false
            this:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        end)

        -- Gold check texture inset like FishingVolume
        local checkTex = chk:GetCheckedTexture()
        if checkTex then
            checkTex:SetTexture(1, 0.82, 0, 0.8)
            checkTex:ClearAllPoints()
            checkTex:SetPoint("TOPLEFT",     chk, "TOPLEFT",     5, -5)
            checkTex:SetPoint("BOTTOMRIGHT", chk, "BOTTOMRIGHT", -5,  5)
        end

        chk:SetChecked(initVal and 1 or 0)
        chk:SetScript("OnClick", function() onChange(this:GetChecked() == 1) end)

        -- Label
        local lbl = getglobal(chkName .. "Text")
        if lbl then
            lbl:SetText(label)
            lbl:SetTextColor(1.0, 0.82, 0)
            lbl:SetPoint("LEFT", chk, "RIGHT", 5, 0)
        end

        -- Invisible label button so clicking the text also toggles (FishingVolume style)
        local labelBtn = CreateFrame("Button", nil, menuFrame)
        labelBtn:SetPoint("TOPLEFT",  chk, "TOPLEFT", 0, 0)
        labelBtn:SetPoint("BOTTOMRIGHT", menuFrame, "TOPRIGHT", -PAD, yOff - 18)
        labelBtn:SetScript("OnClick",  function() chk:Click() end)
        labelBtn:SetScript("OnEnter",  function()
            chk.isHovered = true
            chk:SetBackdropBorderColor(1.0, 0.82, 0, 1)
        end)
        labelBtn:SetScript("OnLeave",  function()
            chk.isHovered = false
            chk:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        end)

        chk.labelBtn = labelBtn
        return chk
    end

    -- ================================================================
    -- MENU ROWS
    -- ================================================================

    -- Row 1: Unlock Anchor | Reset Anchor
    local anchorBtn = MakeHalfBtn("Unlock Anchor", PAD, -30, function()
        if anchorFrame and anchorFrame:IsVisible() then
            SlashCmdList["HCT"]("lock")
            this:SetText("Unlock Anchor")
            this._restR, this._restG, this._restB = 0.2, 0.2, 0.2
            this:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        else
            SlashCmdList["HCT"]("unlock")
            this:SetText("Lock Anchor")
            this._restR, this._restG, this._restB = 1.0, 0.82, 0
            this:SetBackdropBorderColor(1.0, 0.82, 0, 1)
        end
    end)
    menuFrame.anchorBtn = anchorBtn

    MakeHalfBtn("Reset Anchor", PAD + HALF_W + 4, -30, function()
        ANCHOR_X = 0
        ANCHOR_Y = -180
        HCTradeDB.anchorX = ANCHOR_X
        HCTradeDB.anchorY = ANCHOR_Y
        if anchorFrame and anchorFrame:IsVisible() then
            anchorFrame:ClearAllPoints()
            anchorFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", ANCHOR_X, ANCHOR_Y)
        end
        Restack()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Anchor position reset.")
    end)

    -- Row 2+3+4+5: Sound and filter checkboxes
     -- Helper to gray out/restore a checkbox label based on master state
    local function UpdateMasterGating()
    local function setGrayed(chk, grayed)
            if not chk then return end
            local lbl = getglobal(chk:GetName() .. "Text")
            if lbl then
                if grayed then lbl:SetTextColor(0.4, 0.4, 0.4)
                else           lbl:SetTextColor(1.0, 0.82, 0) end
            end
            if grayed then
                chk:EnableMouse(false)
                if chk.labelBtn then chk.labelBtn:EnableMouse(false) end
                chk:SetBackdropColor(0.1, 0.1, 0.1, 1)
                chk:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)
                local checkTex = chk:GetCheckedTexture()
                if checkTex then checkTex:SetTexture(0.4, 0.4, 0.4, 0.5) end
            else
                chk:EnableMouse(true)
                if chk.labelBtn then chk.labelBtn:EnableMouse(true) end
                chk:SetBackdropColor(0, 0, 0, 1)
                chk:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
                local checkTex = chk:GetCheckedTexture()
                if checkTex then checkTex:SetTexture(1, 0.82, 0, 0.8) end
            end
        end
        local grayed = not notificationsEnabled
        setGrayed(menuFrame.chkHardcore, grayed)
        setGrayed(menuFrame.chkGuild,    grayed)
    end
    menuFrame.UpdateMasterGating = UpdateMasterGating

    menuFrame.chkSound = MakeCheckbox("WTS sound", -58, not soundMuted, function(checked)
        soundMuted = not checked
        HCTradeDB.soundMuted = soundMuted
    end)
    menuFrame.chkInventory = MakeCheckbox("WTB/WTT sound", -76, inventoryAlerts, function(checked)
        inventoryAlerts = checked
        HCTradeDB.inventoryAlerts = inventoryAlerts
        if inventoryAlerts then
            ScanInventory()
        end
    end)
    menuFrame.chkTradeskill = MakeCheckbox("Profession sound", -94, not tradeskillMuted, function(checked)
        tradeskillMuted = not checked
        HCTradeDB.tradeskillMuted = tradeskillMuted
    end)
    menuFrame.chkOnlyOwned = MakeCheckbox("Only show WTB/WTT items you own", -112, onlyOwnedWTB, function(checked)
        onlyOwnedWTB = checked
        HCTradeDB.onlyOwnedWTB = onlyOwnedWTB
    end)
    menuFrame.chkEnabled = MakeCheckbox("Notifications", -130, notificationsEnabled, function(checked)
        notificationsEnabled = checked
        HCTradeDB.notificationsEnabled = notificationsEnabled
        local state = notificationsEnabled and "|cff00cc00ENABLED|r" or "|cffff4444DISABLED|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Notifications " .. state)
        UpdateMasterGating()
    end)
    menuFrame.chkHardcore = MakeCheckbox("Hardcore Notifications", -148, hardcoreEnabled, function(checked)
        hardcoreEnabled = checked
        HCTradeDB.hardcoreEnabled = hardcoreEnabled
    end)
    menuFrame.chkGuild = MakeCheckbox("Guild Notifications", -166, guildEnabled, function(checked)
        guildEnabled = checked
        HCTradeDB.guildEnabled = guildEnabled
    end)
    UpdateMasterGating()

    -- Row 6: Test Notification (left half) and Popup Hold Time Slider (right half)
    MakeHalfBtn("Test Notification", PAD, -194, function() SlashCmdList["HCT"]("test") end)

    -- Popup Hold Time Slider (right side, centered vertically with button)
    local sliderX = PAD + HALF_W + 4
    local sliderY = -198  -- Center vertically with 22px button height (adjusted for new checkbox)

    local holdSlider = CreateFrame("Slider", "HCTradeHoldSlider", menuFrame)
    holdSlider:SetOrientation("HORIZONTAL")
    holdSlider:SetWidth(HALF_W - 22)
    holdSlider:SetHeight(14)
    holdSlider:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", sliderX, sliderY)
    holdSlider:SetMinMaxValues(5, 30)
    holdSlider:SetValueStep(1)
    holdSlider:SetValue(HCTradeDB.fadeHold or FADE_HOLD)
    
    holdSlider:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    holdSlider:SetBackdropColor(0, 0, 0, 1)
    holdSlider:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    
    local thumb = holdSlider:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(1.0, 0.82, 0)
    thumb:SetWidth(8)
    thumb:SetHeight(16)
    holdSlider:SetThumbTexture(thumb)
    
    local sliderValue = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sliderValue:SetPoint("LEFT", holdSlider, "RIGHT", 8, 0)
    sliderValue:SetText(math.floor(holdSlider:GetValue()) .. "s")
    sliderValue:SetTextColor(1, 1, 1)
    
    holdSlider:SetScript("OnValueChanged", function()
        local val = math.floor(this:GetValue())
        sliderValue:SetText(val .. "s")
        FADE_HOLD = val
        HCTradeDB.fadeHold = val
    end)

    -- Divider 1
    local div1 = menuFrame:CreateTexture(nil, "ARTWORK")
    div1:SetHeight(1)
    div1:SetPoint("TOPLEFT",  menuFrame, "TOPLEFT",  PAD, -226)
    div1:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -PAD, -226)
    div1:SetTexture(0.3, 0.3, 0.3, 1)

    -- Custom Keywords title
    local kwTitle = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    kwTitle:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", PAD, -233)
    kwTitle:SetText("Custom Keywords  |cffaaaaaa(|r|cffffffff/hct |r|cff00ffffls|r|cffaaaaaa)|r")
    kwTitle:SetTextColor(1.0, 0.82, 0)

    -- Keyword input
    local kwInput = CreateFrame("EditBox", "HCTradeKWInput", menuFrame)
    kwInput:SetFontObject(GameFontHighlightSmall)
    kwInput:SetWidth(HALF_W) kwInput:SetHeight(18)
    kwInput:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", PAD, -250)
    kwInput:SetAutoFocus(false)
    kwInput:SetMaxLetters(30)
    kwInput:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    kwInput:SetBackdropColor(0, 0, 0, 1)
    kwInput:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    kwInput:SetTextColor(1, 1, 1)
    kwInput:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    menuFrame.kwInput = kwInput

    -- Quality cycle button (78px) + margin (4) + plus (28) = 110 = HALF_W
    local QUALITIES = {"Common", "Uncommon", "Rare", "Epic", "Junk"}
    local qualityIdx = 1
    local qualBtn = CreateFrame("Button", nil, menuFrame)
    qualBtn:SetWidth(82) qualBtn:SetHeight(18)
    qualBtn:SetPoint("LEFT", kwInput, "RIGHT", 4, 0)
    qualBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    qualBtn:SetBackdropColor(0, 0, 0, 1)
    qualBtn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    qualBtn:SetScript("OnEnter", function() this:SetBackdropBorderColor(1.0, 0.82, 0, 1) end)
    qualBtn:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) end)
    local qualLbl = qualBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    qualLbl:SetAllPoints(qualBtn)
    qualLbl:SetJustifyH("CENTER")
    local function UpdateQualLabel()
        local q = QUALITIES[qualityIdx]
        local col = QUALITY_COLORS[q] or "|cffffffff"
        qualLbl:SetText(col .. q .. "|r")
    end
    UpdateQualLabel()
    qualBtn:SetScript("OnClick", function()
        qualityIdx = qualityIdx + 1
        if qualityIdx > table.getn(QUALITIES) then qualityIdx = 1 end
        UpdateQualLabel()
    end)

    -- Add (+) button
    local addBtn = CreateFrame("Button", nil, menuFrame, "UIPanelButtonTemplate")
    addBtn:SetWidth(28) addBtn:SetHeight(18)
    addBtn:SetPoint("LEFT", qualBtn, "RIGHT", 4, 0)
    addBtn:SetText("+")
    addBtn:GetFontString():SetTextColor(1.0, 0.82, 0)
    if addBtn:GetNormalTexture()    then addBtn:GetNormalTexture():SetTexture(nil)    end
    if addBtn:GetPushedTexture()    then addBtn:GetPushedTexture():SetTexture(nil)    end
    if addBtn:GetHighlightTexture() then addBtn:GetHighlightTexture():SetTexture(nil) end
    addBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    addBtn:SetBackdropColor(0, 0, 0, 1)
    addBtn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    addBtn:SetScript("OnEnter", function() this:SetBackdropBorderColor(1.0, 0.82, 0, 1) end)
    addBtn:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) end)
    addBtn:SetScript("OnClick", function()
        local text = kwInput:GetText()
        text = string.gsub(text, "^%s*(.-)%s*$", "%1")
        if text == "" then return end
        
        -- Check for duplicates (case-insensitive, including plural forms)
        local lowerText = string.lower(text)
        for _, kw in ipairs(customKeywords) do
            local existing = string.lower(kw.keyword)
            
            -- Check exact match
            if existing == lowerText then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Already in list: " .. kw.color .. "[" .. kw.display .. "]|r")
                kwInput:SetText("")
                return
            end
            
            -- Check if new word is plural of existing (existing + "s")
            if lowerText == existing .. "s" then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Plural of existing keyword: " .. kw.color .. "[" .. kw.display .. "]|r")
                kwInput:SetText("")
                return
            end
            
            -- Check if existing is plural of new word (new + "s")
            if existing == lowerText .. "s" then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Singular of existing keyword: " .. kw.color .. "[" .. kw.display .. "]|r")
                kwInput:SetText("")
                return
            end
        end
        
        local q   = QUALITIES[qualityIdx]
        local col = QUALITY_COLORS[q] or "|cffffffff"
        local display = string.gsub(string.lower(text), "(%a)([%w_']*)", function(a,b) return string.upper(a)..b end)
        table.insert(customKeywords, { keyword = string.lower(text), color = col, display = display, quality = q })
        SaveCustomKeywords()
        kwInput:SetText("")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Added: " .. col .. "[" .. display .. "]|r  (|cffffffff/hct ls|r to manage)")
    end)

    -- List button (right side, same row as add)
    MakeHalfBtn("Print List", PAD + HALF_W + 4, -278, function()
        SlashCmdList["HCT"]("ls")
    end)

    -- Divider 2
    local div2 = menuFrame:CreateTexture(nil, "ARTWORK")
    div2:SetHeight(1)
    div2:SetPoint("TOPLEFT",  menuFrame, "TOPLEFT",  PAD, -310)
    div2:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -PAD, -310)
    div2:SetTexture(0.3, 0.3, 0.3, 1)

    -- Help | Close
    MakeHalfBtn("Help",  PAD,               -317, function() SlashCmdList["HCT"]("help") end)
    MakeHalfBtn("Close", PAD + HALF_W + 4,  -317, function() menuFrame:Hide() end)

    menuFrame:Hide()
end

local function ToggleMenu()
    CreateMenuFrame()
    -- Sync anchor button
    if menuFrame.anchorBtn then
        if anchorFrame and anchorFrame:IsVisible() then
            menuFrame.anchorBtn:SetText("Lock Anchor")
            menuFrame.anchorBtn._restR, menuFrame.anchorBtn._restG, menuFrame.anchorBtn._restB = 1.0, 0.82, 0
            menuFrame.anchorBtn:SetBackdropBorderColor(1.0, 0.82, 0, 1)
        else
            menuFrame.anchorBtn:SetText("Unlock Anchor")
            menuFrame.anchorBtn._restR, menuFrame.anchorBtn._restG, menuFrame.anchorBtn._restB = 0.2, 0.2, 0.2
            menuFrame.anchorBtn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        end
    end
    -- Sync checkboxes
    if menuFrame.chkSound      then menuFrame.chkSound:SetChecked(    not soundMuted      and 1 or 0) end
    if menuFrame.chkTradeskill then menuFrame.chkTradeskill:SetChecked(not tradeskillMuted and 1 or 0) end
    if menuFrame.chkInventory  then menuFrame.chkInventory:SetChecked( inventoryAlerts     and 1 or 0) end
    if menuFrame.chkEnabled    then menuFrame.chkEnabled:SetChecked(   notificationsEnabled and 1 or 0) end
    if menuFrame.chkOnlyOwned  then menuFrame.chkOnlyOwned:SetChecked( onlyOwnedWTB        and 1 or 0) end
    if menuFrame.chkHardcore   then menuFrame.chkHardcore:SetChecked(  hardcoreEnabled     and 1 or 0) end
    if menuFrame.chkGuild      then menuFrame.chkGuild:SetChecked(     guildEnabled        and 1 or 0) end
    if menuFrame.UpdateMasterGating then menuFrame.UpdateMasterGating() end
    if menuFrame:IsVisible() then
        menuFrame:Hide()
    else
        menuFrame:Show()
    end
end

-- ================================================================
-- SLASH COMMANDS
-- ================================================================
-- Command interface for users to control the addon
-- Main commands:
-- /hct or /hct menu - Open settings GUI
-- /hct debug - Toggle debug output
-- /hct sniff - Print all raw HC messages
-- /hct status - List chat frames
-- /hct hook N - Manually hook chat frame number N
-- /hct test - Spawn test popups
-- /hct unlock/lock - Position adjustment mode
-- /hct ls - List custom keywords
-- /hct rm N - Remove custom keyword number N
-- /hct help [command] - Show help

SLASH_HCTRADE1 = "/hctrade"
SlashCmdList["HCTRADE"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Use |cffffffff/hct help|r for commands.")
end

SLASH_HCT1 = "/hct"
SlashCmdList["HCT"] = function(msg)
    local cmd = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))

    if cmd == "" then
        -- /hct with no arguments opens the settings GUI
        ToggleMenu()

    elseif cmd == "menu" then
        ToggleMenu()

    elseif cmd == "debug" then
        -- Toggle debug mode: prints detailed message processing info
        debugMode = not debugMode
        local state = debugMode and "|cff00cc00ON|r" or "|cffff4444OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Debug " .. state)

    elseif cmd == "sniff" then
        -- Toggle sniff mode: prints ALL raw messages in hooked frame
        sniffMode = not sniffMode
        local state = sniffMode and "|cff00cc00ON|r" or "|cffff4444OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Sniff " .. state ..
            " - every message arriving in the hooked frame will be printed.")
        if sniffMode and not hookedFrame then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Warning: no frame is hooked yet!")
        end

    elseif cmd == "status" then
        -- List all chat frames and show which one is hooked
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Chat frame tabs:")
        for i = 1, 10 do
            local frame = getglobal("ChatFrame" .. i)
            local tab   = getglobal("ChatFrame" .. i .. "Tab")
            if frame and tab then
                local title  = tab:GetText() or "(no title)"
                local hooked = (hookedFrame == frame) and " |cff00cc00<< HOOKED|r" or ""
                DEFAULT_CHAT_FRAME:AddMessage("  Frame " .. i .. ": |cffffffff" .. title .. "|r" .. hooked)
            end
        end
        if hookedFrame then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Currently hooked: frame " .. (hookedIndex or "?"))
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r No frame currently hooked.")
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa(type |cffffffff/hct hook FRAMENUMBER|r |cffaaaaaa to hook HC chat channel)")

    elseif string.sub(cmd, 1, 4) == "hook" then
        local n = tonumber(string.match(cmd, "hook%s+(%d+)"))
        if not n then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Usage: /hct hook N  (e.g. /hct hook 3)")
            return
        end
        local frame = getglobal("ChatFrame" .. n)
        if not frame then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r ChatFrame" .. n .. " does not exist.")
            return
        end
        hookedFrame = nil
        hookedIndex = n
        HCTradeDB.hookedIndex = n  -- persist user's manual choice
        local tab   = getglobal("ChatFrame" .. n .. "Tab")
        local title = (tab and tab:GetText()) or "?"
        DoHook(frame, n .. ' ("' .. title .. '")')

    elseif cmd == "ls" then
        if table.getn(customKeywords) == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r No custom keywords. Add via |cffffffff/hct menu|r.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Custom keywords:")
            for i, kw in ipairs(customKeywords) do
                DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa" .. i .. ".|r " .. kw.color .. "[" .. kw.display .. "]|r  |cffaaaaaa(" .. (kw.quality or "Custom") .. ")|r")
            end
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa(remove with |cffffffff/hct rm N|r|cffaaaaaa)")
        end

    elseif string.sub(cmd, 1, 2) == "rm" then
        local n = tonumber(string.match(cmd, "rm%s+(%d+)"))
        if not n or n < 1 or n > table.getn(customKeywords) then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Usage: /hct rm N  (use /hct ls to see numbers)")
        else
            local removed = customKeywords[n]
            table.remove(customKeywords, n)
            SaveCustomKeywords()
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Removed: " .. removed.color .. "[" .. removed.display .. "]|r")
        end

    elseif cmd == "unlock" then
        ShowAnchor()

    elseif cmd == "lock" then
        LockAnchor()

    elseif cmd == "test" then
        local pl  = UnitLevel("player")
        local lo  = math.max(1,  pl - TRADE_RANGE)
        local hi  = math.min(60, pl + TRADE_RANGE)
        ShowPopup("Sarun",    "WTS [Swiftness Potion] [Lesser Mana Potion] [Healing Potion] " .. pl .. "+-",
                              "WTS |cffffffff[Swiftness Potion]|r |cffffffff[Lesser Mana Potion]|r |cffffffff[Healing Potion]|r " .. pl .. "+-", lo, hi, "HCTrade - WTS")
        ShowPopup("Deffar",   "WTB [Citrine] " .. pl .. "+-",
                              "WTB |cffffffff[Citrine]|r " .. pl .. "+-", lo, hi, "HCTrade - WTB")
        ShowPopup("Kamyczek", "WTS [Greater Magic Wand] " .. pl .. "+-",
                              "WTS |cff1eff00[Greater Magic Wand]|r " .. pl .. "+-", lo, hi, "HCTrade - WTS")
        -- Profession test popups
        local profCount = 0
        for _, prof in ipairs(playerProfessions) do
            local abbrev = prof.abbrevs[1]
            local testMsg = "LF " .. string.upper(abbrev) .. " " .. pl .. "+-"
            ShowPopup("TestPlayer", testMsg, testMsg, lo, hi, "HCTrade - " .. prof.fullname)
            profCount = profCount + 1
        end
        -- Play Tradeskill sound once if there were profession popups
        if profCount > 0 and not tradeskillMuted then
            PlaySoundFile("Interface\\AddOns\\HCTrade\\Sound\\Tradeskill.ogg")
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Test: 3 trade popups + " .. profCount .. " profession popup(s) for level " .. pl .. ".")

    elseif cmd == "cache" then
        local count = 0
        if HCTradeDB.levelCache then
            for _ in pairs(HCTradeDB.levelCache) do count = count + 1 end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Level cache: |cffffffff" .. count .. "|r player(s) tracked.")
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa(use |cffffffff/hct cache clear|r|cffaaaaaa to wipe)")

    elseif cmd == "cache clear" then
        HCTradeDB.levelCache = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Level cache cleared.")

    elseif cmd == "toggle" or cmd == "on" or cmd == "off" then
        if cmd == "on" then
            notificationsEnabled = true
        elseif cmd == "off" then
            notificationsEnabled = false
        else
            notificationsEnabled = not notificationsEnabled
        end
        HCTradeDB.notificationsEnabled = notificationsEnabled
        local state = notificationsEnabled and "|cff00cc00ENABLED|r" or "|cffff4444DISABLED|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Notifications " .. state)
        if menuFrame and menuFrame.chkEnabled then
            menuFrame.chkEnabled:SetChecked(notificationsEnabled and 1 or 0)
        end

    elseif cmd == "help" or cmd == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r To get help, type |cffffffff/hct help |cff00ffff<command>|r for details.")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Example: |cffffffff/hct help |cff00ffffstatus|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r List of commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/hct |cff00ffffmenu|r   |cffffffff/hct |cff00fffftest|r    |cffffffff/hct |cff00ffffunlock|r  |cffffffff/hct |cff00fffflock|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/hct |cff00ffffdebug|r  |cffffffff/hct |cff00ffffsniff|r   |cffffffff/hct |cff00ffffstatus|r  |cffffffff/hct |cff00ffffhook N|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/hct |cff00ffffls|r     |cffffffff/hct |cff00ffffrm N|r  |cffffffff/hct |cff00ffffcache|r  |cffffffff/hct |cff00ffffon|r/|cff00ffffoff|r")

    elseif string.sub(cmd, 1, 5) == "help " then
        local topic = string.gsub(cmd, "^help%s+", "")
        local G = "|cffffd100"
        if topic == "menu" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "menu|r - Opens the HCTrade GUI panel.")
            DEFAULT_CHAT_FRAME:AddMessage("  Buttons for test, debug, sniff, anchor unlock/lock and reset.")
        elseif topic == "test" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "test|r - Spawns 3 example popups at your current level.")
            DEFAULT_CHAT_FRAME:AddMessage("  Lets you verify sizing, colours and position without needing live HC traffic.")
        elseif topic == "unlock" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "unlock|r - Shows a small drag handle at the popup anchor point.")
            DEFAULT_CHAT_FRAME:AddMessage("  Drag it anywhere on screen, then type /hct lock to save.")
        elseif topic == "lock" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "lock|r - Saves the anchor position and hides the drag handle.")
            DEFAULT_CHAT_FRAME:AddMessage("  Position persists across sessions.")
        elseif topic == "debug" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "debug|r - Toggles debug mode.")
            DEFAULT_CHAT_FRAME:AddMessage("  When ON, every HC WTS/WTB is printed with its parsed level range")
            DEFAULT_CHAT_FRAME:AddMessage("  and whether it matched your level. Good for testing the parser.")
        elseif topic == "sniff" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "sniff|r - Toggles sniff mode.")
            DEFAULT_CHAT_FRAME:AddMessage("  Prints every raw message arriving in the hooked HC frame.")
            DEFAULT_CHAT_FRAME:AddMessage("  Use this if popups aren't triggering - check what the frame sees.")
        elseif topic == "status" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "status|r - Lists all chat frame tab names.")
            DEFAULT_CHAT_FRAME:AddMessage("  Shows which frame is currently hooked for HC detection.")
        elseif topic == "hook" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "hook|r - Manually hooks chat frame number <Number>.")
            DEFAULT_CHAT_FRAME:AddMessage("  Use if the HC frame was not auto-detected on login.")
            DEFAULT_CHAT_FRAME:AddMessage("  Run /hct status first to find the right frame number.")
        elseif topic == "ls" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "ls|r - Lists all custom keywords you've added.")
            DEFAULT_CHAT_FRAME:AddMessage("  Shows the number, display name, and quality color for each keyword.")
            DEFAULT_CHAT_FRAME:AddMessage("  Use the number with /hct rm to remove a keyword.")
        elseif topic == "rm" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "rm N|r - Removes custom keyword number N.")
            DEFAULT_CHAT_FRAME:AddMessage("  Run /hct ls first to see the list and find the number.")
            DEFAULT_CHAT_FRAME:AddMessage("  Example: /hct rm 3 removes the third keyword in your list.")
        elseif topic == "cache" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "cache|r - Shows how many players are in the level cache.")
            DEFAULT_CHAT_FRAME:AddMessage("  HCTrade passively records levels from friends, guild, party,")
            DEFAULT_CHAT_FRAME:AddMessage("  raid, target, mouseover, and /who results. These are used as")
            DEFAULT_CHAT_FRAME:AddMessage("  a fallback when a WTS/WTB has no level in the message.")
            DEFAULT_CHAT_FRAME:AddMessage("  Use |cffffffff/hct cache clear|r to wipe the cache.")
        elseif topic == "toggle" or topic == "on" or topic == "off" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "toggle|r - Enables/disables all popups and sounds.")
            DEFAULT_CHAT_FRAME:AddMessage("  Use |cffffffff/hct on|r or |cffffffff/hct off|r to set explicitly.")
            DEFAULT_CHAT_FRAME:AddMessage("  Background scans (inventory, level cache) keep running so")
            DEFAULT_CHAT_FRAME:AddMessage("  re-enabling is instant. /hct test still works when disabled.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Unknown command '" .. topic .. "'. Type /hct help for a list.")
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Unknown command. Type |cffffffff/hct help|r for a list.")
    end
end

-- ================================================================
-- ADDON LOADED
-- ================================================================
-- Print confirmation message when addon loads successfully

DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Loaded. Type |cffffffff/hct help|r for commands.")

-- End of HCTrade.lua
--
-- SAVED VARIABLES (stored in WTF/Account/ACCOUNT/SavedVariables/HCTrade.lua):
-- - HCTradeDB.anchorX, anchorY - Popup position
-- - HCTradeDB.soundMuted - Trade notification sound toggle
-- - HCTradeDB.tradeskillMuted - Profession alert sound toggle
-- - HCTradeDB.inventoryAlerts - "Owned items sound" toggle
-- - HCTradeDB.onlyOwnedWTB - "Only WTB items you own" filter
-- - HCTradeDB.fadeHold - Popup duration (5-30 seconds)
-- - HCTradeDB.customKeywords - User-defined keyword alerts
-- - HCTradeDB.bankCache - Cached bank items (persists when bank closed)
-- - HCTradeDB.itemColorCache - Cached item quality colors