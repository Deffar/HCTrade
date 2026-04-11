-- HCTrade.lua

HCTrade = HCTrade or {}
HCTradeDB = HCTradeDB or {}

local TRADE_RANGE    = 5
local debugMode      = false
local sniffMode      = false
local hookedFrame    = nil
local hookedIndex    = nil
local soundMuted     = false   -- mute Alert.ogg (trade notifications)
local tradeskillMuted = false  -- mute Tradeskill.ogg

-- Quality colour codes (Wowpedia)
local QUALITY_COLORS = {
    ["Junk"]     = "|cff9d9d9d",
    ["Common"]   = "|cffffffff",
    ["Uncommon"] = "|cff1eff00",
    ["Rare"]     = "|cff0070ff",
    ["Epic"]     = "|cffa335ee",
}

-- Custom keyword list: { keyword="armor kit", color="|cff...", display="[Armor Kit]" }
-- Loaded from HCTradeDB.customKeywords on login
local customKeywords = {}

-- Player professions: scanned on login/zone change
-- { shortname="BS", fullname="Blacksmithing" }
local playerProfessions = {}

-- Profession abbreviation map
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
}

-- ================================================================
-- LEVEL RANGE PARSER
-- ================================================================

local function ParseLevelRange(msg)
    local s = string.lower(msg)

    local base = string.match(s, "(%d+)%s*[%+%-][%+%-%/]+$")
    if not base then
        base = string.match(s, "(%d+)%s*[%+%-][%+%-%/]+[^%d]")
    end
    if not base then
        base = string.match(s, "(%d+)%s*\194\177")
    end
    if not base then
        base = string.match(s, "(%d+)%s*[%+%-]$")
    end
    if not base then
        base = string.match(s, "(%d+)%s*[%+%-][^%+%-%d/]")
    end
    if base then
        base = tonumber(base)
        if base and base >= 1 and base <= 60 then
            return math.max(1, base - TRADE_RANGE), math.min(60, base + TRADE_RANGE)
        end
    end

    local a, b = string.match(s, "(%d+)%s*%-%s*(%d+)")
    if a and b then
        a, b = tonumber(a), tonumber(b)
        if a and b and a < b and b <= 60 then
            return a, b
        end
    end

    local lvl = string.match(s, "lv[le]*%.?%s*(%d+)")
    if lvl then
        lvl = tonumber(lvl)
        if lvl and lvl >= 1 and lvl <= 60 then
            return math.max(1, lvl - TRADE_RANGE), math.min(60, lvl + TRADE_RANGE)
        end
    end

    for num in string.gmatch(s, "%d+") do
        local n = tonumber(num)
        if n and n >= 1 and n <= 60 then
            return math.max(1, n - TRADE_RANGE), math.min(60, n + TRADE_RANGE)
        end
    end

    return nil, nil
end

local function IsTradeMessage(msg)
    local s = string.lower(msg)
    return string.find(s, "wts") or string.find(s, "wtb")
end

local function PlayerLevelInRange(rangeMin, rangeMax)
    return UnitLevel("player") >= rangeMin and UnitLevel("player") <= rangeMax
end

-- ================================================================
-- PROFESSION SCANNER
-- ================================================================

local function ScanProfessions()
    playerProfessions = {}
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank = GetSkillLineInfo(i)
        if name and not isHeader and rank and rank > 0 then
            local lower = string.lower(name)
            for profKey, abbrevs in pairs(PROF_ABBREVS) do
                if lower == profKey then
                    table.insert(playerProfessions, {
                        fullname = name,
                        key      = profKey,
                        abbrevs  = abbrevs,
                        rank     = rank,
                    })
                    break
                end
            end
        end
    end
end

-- Crafting-related keywords that indicate a crafting request
local CRAFT_KEYWORDS = {
    "craft", "make", "create", "my mats", "your mats", "my matz", "your matz"
}

-- Items associated with each profession for crafting detection
local PROFESSION_ITEMS = {
    ["blacksmithing"] = {"armor", "weapon", "shield", "plate", "mail", "sharpening stone", "weightstone"},
    ["leatherworking"] = {"leather", "hide", "skinning knife", "armor kit", "cloak", "bag"},
    ["tailoring"] = {"cloth", "bag", "robe", "shirt", "netherweave", "mageweave", "runecloth", "silk"},
    ["engineering"] = {"bomb", "scope", "goggles", "trinket", "target dummy", "rocket", "grenade"},
    ["alchemy"] = {"potion", "elixir", "flask", "transmute"},
    ["enchanting"] = {"enchant", "enchanting"},
}

-- Returns the matching profession entry if msg mentions one of the player's professions
local function MatchesProfession(msg)
    local s = string.lower(msg)
    
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

local function Restack()
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
    whisperText:SetTextColor(1.0, 0, 1.0)
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
    msgText:SetTextColor(1, 1, 1)
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
    -- Build a table mapping item name -> colour code from rawMsg
    -- rawMsg contains patterns like: |cffXXXXXX[Item Name]|r
    -- or from game links: |cffXXXXXX|Hitem:...|h[Item Name]|h|r
    local itemColours = {}

    -- Pattern 1: plain colour code before [Item]
    -- e.g. |cff1eff00[Greater Magic Wand]|r
    local searchPos = 1
    while true do
        local cs, ce = string.find(rawMsg, "|c%x%x%x%x%x%x%x%x", searchPos)
        if not cs then break end
        local colCode = string.sub(rawMsg, cs, ce)
        -- Find the next [ after this colour code (skipping any |H link data)
        local bracketS = string.find(rawMsg, "%[", ce + 1)
        if bracketS and bracketS <= ce + 30 then
            local bracketE = string.find(rawMsg, "%]", bracketS)
            if bracketE then
                local itemName = string.sub(rawMsg, bracketS, bracketE)
                itemColours[itemName] = colCode
            end
        end
        searchPos = ce + 1
    end

    -- Apply colours to plain text: find each [Item] and wrap it
    local result = plainText
    -- Sort by length descending to avoid partial matches
    local items = {}
    for name, _ in pairs(itemColours) do
        table.insert(items, name)
    end
    table.sort(items, function(a, b) return string.len(a) > string.len(b) end)

    for _, name in ipairs(items) do
        local col = itemColours[name]
        -- Escape magic chars in name for gsub
        local escaped = string.gsub(name, "([%[%]%(%)%.%+%-%*%?%^%$%%])", "%%%1")
        result = string.gsub(result, escaped, col .. name .. RESET_CODE)
    end

    -- Recolour WTS and WTB (match at start or after space/newline)
    result = string.gsub(result, "^WTS%s", WTS_COLOUR .. "WTS" .. RESET_CODE .. " ")
    result = string.gsub(result, "^WTB%s", WTB_COLOUR .. "WTB" .. RESET_CODE .. " ")
    result = string.gsub(result, "%sWTS%s", " " .. WTS_COLOUR .. "WTS" .. RESET_CODE .. " ")
    result = string.gsub(result, "%sWTB%s", " " .. WTB_COLOUR .. "WTB" .. RESET_CODE .. " ")
    result = string.gsub(result, "\nWTS%s", "\n" .. WTS_COLOUR .. "WTS" .. RESET_CODE .. " ")
    result = string.gsub(result, "\nWTB%s", "\n" .. WTB_COLOUR .. "WTB" .. RESET_CODE .. " ")

    return result
end

-- ================================================================
-- SHOW POPUP
-- ================================================================

local function ShowPopup(sender, msg, rawMsg, rangeMin, rangeMax, header)
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
    f.whisperText:SetText("<" .. sender .. ">  |cffaaaaaa[click to whisper]|r")
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
        PlaySoundFile("Interface\\AddOns\\HCTrade\\Sound\\Alert.ogg")
    end
end

-- ================================================================
-- CORE PROCESSOR
-- ================================================================

local function ProcessHCMessage(sender, msg, rawMsg)
    if not IsTradeMessage(msg) then return end

    local rangeMin, rangeMax = ParseLevelRange(msg)
    local pl = UnitLevel("player")

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

    -- Check for custom keyword match (always notify if level matches, regardless of profession)
    if rangeMin and PlayerLevelInRange(rangeMin, rangeMax) then
        if debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[HCTrade] Checking custom keywords...|r")
        end
        local kw = MatchesCustomKeyword(msg)
        if kw then
            -- Build a rawMsg that highlights the keyword
            local displayMsg = rawMsg or msg
            -- Replace the keyword in the display with coloured [Keyword]
            local escaped = string.gsub(kw.keyword, "([%[%]%(%)%.%+%-%*%?%^%$%%])", "%%%1")
            local coloured = kw.color .. "[" .. kw.display .. "]|r"
            displayMsg = string.gsub(displayMsg, escaped, coloured)
            local kwHeader = "HCTrade - WTB"
            if string.find(string.lower(msg), "wts") then kwHeader = "HCTrade - WTS" end
            ShowPopup(sender, msg, displayMsg, rangeMin, rangeMax, kwHeader)
            return  -- Alert.ogg plays inside ShowPopup already
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
            return
        end
    end

    -- Standard trade match
    if not rangeMin then return end
    if not PlayerLevelInRange(rangeMin, rangeMax) then return end
    local tradeHeader = "HCTrade - WTB"
    if string.find(string.lower(msg), "wts") then tradeHeader = "HCTrade - WTS" end
    ShowPopup(sender, msg, rawMsg or msg, rangeMin, rangeMax, tradeHeader)
end

-- ================================================================
-- FRAME HOOK
-- ================================================================

local function DoHook(frame, label)
    if hookedFrame == frame then return end
    hookedFrame = frame

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

        -- Extract sender and plain message body for parsing
        -- Support both <sender> and [sender] formats
        local rawSender, msg = string.match(plain, "<(.-)>%s*(.*)")
        if not rawSender then
            -- Try [HC] [sender] format
            rawSender, msg = string.match(plain, "%[HC%]%s*%[(.-)%]%s*(.*)")
        end
        if not rawSender or not msg or msg == "" then return end

        local sender = string.match(rawSender, "^%d+:(.+)") or rawSender

        msg = string.gsub(msg, "^%%[HC%%]%s*", "")
        if msg == "" then return end

        -- Extract rawMsg from original text (preserves colour codes and item links)
        -- Strip only the timestamp prefix and the sender angle-bracket block,
        -- leaving the message body fully intact with all |c codes and |H links.
        local rawMsg = string.match(text, "<.->%s*(.*)")
        if rawMsg then
            -- Remove leading [HC] channel tag if present (plain brackets, no codes)
            rawMsg = string.gsub(rawMsg, "^%[HC%]%s*", "")
        end
        rawMsg = rawMsg or msg

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
-- EVENTS
-- ================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("VARIABLES_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        if HCTradeDB.anchorX     then ANCHOR_X       = HCTradeDB.anchorX     end
        if HCTradeDB.anchorY     then ANCHOR_Y       = HCTradeDB.anchorY     end
        if HCTradeDB.soundMuted  ~= nil then soundMuted      = HCTradeDB.soundMuted  end
        if HCTradeDB.tradeskillMuted ~= nil then tradeskillMuted = HCTradeDB.tradeskillMuted end
        if HCTradeDB.fadeHold    then FADE_HOLD      = HCTradeDB.fadeHold    end
        -- Load custom keywords
        customKeywords = {}
        if HCTradeDB.customKeywords then
            for _, kw in ipairs(HCTradeDB.customKeywords) do
                table.insert(customKeywords, kw)
            end
        end
        ScanProfessions()
    end
    if event == "PLAYER_ENTERING_WORLD" then
        ScanProfessions()
        if not hookedFrame then
            HookHCFrame()
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
    menuFrame:SetHeight(263)
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

    -- Row 2+3: Sound checkboxes
    menuFrame.chkSound = MakeCheckbox("Trade sound", -58, not soundMuted, function(checked)
        soundMuted = not checked
        HCTradeDB.soundMuted = soundMuted
    end)
    menuFrame.chkTradeskill = MakeCheckbox("Tradeskill sound", -76, not tradeskillMuted, function(checked)
        tradeskillMuted = not checked
        HCTradeDB.tradeskillMuted = tradeskillMuted
    end)

    -- Row 4: Test Notification (left half) and Popup Hold Time Slider (right half)
    MakeHalfBtn("Test Notification", PAD, -104, function() SlashCmdList["HCT"]("test") end)

    -- Popup Hold Time Slider (right side, centered vertically with button)
    local sliderX = PAD + HALF_W + 4
    local sliderY = -108  -- Center vertically with 22px button height

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
    div1:SetPoint("TOPLEFT",  menuFrame, "TOPLEFT",  PAD, -136)
    div1:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -PAD, -136)
    div1:SetTexture(0.3, 0.3, 0.3, 1)

    -- Custom Keywords title
    local kwTitle = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    kwTitle:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", PAD, -143)
    kwTitle:SetText("Custom Keywords  |cffaaaaaa(|r|cffffffff/hct |r|cff00ffffls|r|cffaaaaaa)|r")
    kwTitle:SetTextColor(1.0, 0.82, 0)

    -- Keyword input
    local kwInput = CreateFrame("EditBox", "HCTradeKWInput", menuFrame)
    kwInput:SetFontObject(GameFontHighlightSmall)
    kwInput:SetWidth(HALF_W) kwInput:SetHeight(18)
    kwInput:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", PAD, -160)
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
    MakeHalfBtn("Print List", PAD + HALF_W + 4, -188, function()
        SlashCmdList["HCT"]("ls")
    end)

    -- Divider 2
    local div2 = menuFrame:CreateTexture(nil, "ARTWORK")
    div2:SetHeight(1)
    div2:SetPoint("TOPLEFT",  menuFrame, "TOPLEFT",  PAD, -220)
    div2:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -PAD, -220)
    div2:SetTexture(0.3, 0.3, 0.3, 1)

    -- Help | Close
    MakeHalfBtn("Help",  PAD,               -227, function() SlashCmdList["HCT"]("help") end)
    MakeHalfBtn("Close", PAD + HALF_W + 4,  -227, function() menuFrame:Hide() end)

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
    if menuFrame.chkSound     then menuFrame.chkSound:SetChecked(    not soundMuted      and 1 or 0) end
    if menuFrame.chkTradeskill then menuFrame.chkTradeskill:SetChecked(not tradeskillMuted and 1 or 0) end
    if menuFrame:IsVisible() then
        menuFrame:Hide()
    else
        menuFrame:Show()
    end
end

-- ================================================================

SLASH_HCTRADE1 = "/hctrade"
SlashCmdList["HCTRADE"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Use |cffffffff/hct help|r for commands.")
end

SLASH_HCT1 = "/hct"
SlashCmdList["HCT"] = function(msg)
    local cmd = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))

    if cmd == "" then
        -- /hct with no arguments opens menu
        ToggleMenu()

    elseif cmd == "menu" then
        ToggleMenu()

    elseif cmd == "debug" then
        debugMode = not debugMode
        local state = debugMode and "|cff00cc00ON|r" or "|cffff4444OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Debug " .. state)

    elseif cmd == "sniff" then
        sniffMode = not sniffMode
        local state = sniffMode and "|cff00cc00ON|r" or "|cffff4444OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Sniff " .. state ..
            " - every message arriving in the hooked frame will be printed.")
        if sniffMode and not hookedFrame then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Warning: no frame is hooked yet!")
        end

    elseif cmd == "status" then
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

    elseif cmd == "help" or cmd == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r To get help, type |cffffffff/hct help |cff00ffffcorrect<command>|r for details.")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Example: |cffffffff/hct help |cff00ffffstatus|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r List of commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/hct |cff00ffffmenu|r   |cffffffff/hct |cff00fffftest|r    |cffffffff/hct |cff00ffffunlock|r  |cffffffff/hct |cff00fffflock|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/hct |cff00ffffdebug|r  |cffffffff/hct |cff00ffffsniff|r   |cffffffff/hct |cff00ffffstatus|r  |cffffffff/hct |cff00ffffhook N|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/hct |cff00ffffls|r     |cffffffff/hct |cff00ffffrm N|r")

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
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Unknown command '" .. topic .. "'. Type /hct help for a list.")
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Unknown command. Type |cffffffff/hct help|r for a list.")
    end
end

DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Loaded. Type |cffffffff/hct help|r for commands.")