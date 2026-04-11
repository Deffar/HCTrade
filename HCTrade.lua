-- HCTrade.lua

HCTrade = HCTrade or {}
HCTradeDB = HCTradeDB or {}

local TRADE_RANGE = 5
local debugMode   = false
local sniffMode   = false
local hookedFrame = nil
local hookedIndex = nil

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
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    f:SetBackdropColor(0, 0, 0, 0.85)
    f:SetBackdropBorderColor(1.0, 0.82, 0, 1)

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
    whisperText:SetTextColor(1.0, 0.82, 0)
    f.whisperBtn  = whisperBtn
    f.whisperText = whisperText
    whisperBtn:SetScript("OnClick", function()
        if f._sender then
            ChatFrame_OpenChat("/w " .. f._sender .. " ", DEFAULT_CHAT_FRAME)
        end
    end)

    local msgText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    msgText:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -36)
    msgText:SetWidth(200)
    msgText:SetJustifyH("LEFT")
    msgText:SetNonSpaceWrap(false)
    msgText:SetTextColor(1, 1, 1)
    f.msgText = msgText

    local rangeText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rangeText:SetPoint("TOPLEFT", msgText, "BOTTOMLEFT", 0, -4)
    rangeText:SetWidth(200)
    rangeText:SetHeight(14)
    rangeText:SetJustifyH("LEFT")
    f.rangeText = rangeText

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

    -- Recolour WTS and WTB at start of message
    result = string.gsub(result, "^WTS%s", WTS_COLOUR .. "WTS" .. RESET_CODE .. " ")
    result = string.gsub(result, "^WTB%s", WTB_COLOUR .. "WTB" .. RESET_CODE .. " ")

    return result
end

-- ================================================================
-- SHOW POPUP
-- ================================================================

local function ShowPopup(sender, msg, rawMsg, rangeMin, rangeMax)
    local f  = AcquirePopup()
    local GOLD  = "|cffffd100"
    local WHITE = "|cffffffff"
    local RESET = "|r"

    local MAX_W     = 350   -- hard cap on frame width
    local MIN_W     = 120   -- minimum frame width
    local PAD       = 24    -- left + right padding
    local CONTENT_W = 250   -- wrap text at this width regardless of frame size

    f._sender = sender
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
    local headerW  = MeasureWidth("HC Trade - level match!")
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

    if not rangeMin then return end
    if not PlayerLevelInRange(rangeMin, rangeMax) then return end
    ShowPopup(sender, msg, rawMsg or msg, rangeMin, rangeMax)
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
        local rawSender, msg = string.match(plain, "<(.-)>%s*(.*)")
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
        -- Load saved anchor position
        if HCTradeDB.anchorX then ANCHOR_X = HCTradeDB.anchorX end
        if HCTradeDB.anchorY then ANCHOR_Y = HCTradeDB.anchorY end
    end
    if not hookedFrame then
        HookHCFrame()
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

local menuFrame = nil

local function CreateMenuFrame()
    if menuFrame then return end

    menuFrame = CreateFrame("Frame", "HCTradeMenu", UIParent)
    menuFrame:SetWidth(220)
    menuFrame:SetHeight(182)
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
    local BTN_W = 220 - PAD * 2
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

    -- Layout (each row = 22px tall, 5px gap between rows, divider = 9px total)
    -- Row 1: Help (full width)                        y=-30
    -- Row 2: Unlock Anchor | Reset Anchor (half)      y=-57
    -- Row 3: Test Popups (full)                       y=-84
    -- Row 4: Sound (full)                             y=-111
    -- Divider                                          y=-140
    -- Row 5: Status (full)                            y=-146
    -- Divider                                          y=-175
    -- Row 6: Debug (full)                             y=-181
    -- Row 7: Sniff (full)                             y=-208

    -- Row 1: Help
    MakeBtn("Help", -30, function()
        SlashCmdList["HCT"]("help")
    end)

    -- Row 2: Unlock Anchor | Reset Anchor
    local anchorBtn = MakeHalfBtn("Unlock Anchor", PAD, -57, function()
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

    MakeHalfBtn("Reset Anchor", PAD + HALF_W + 4, -57, function()
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

    -- Row 3: Test Popups
    MakeBtn("Test Popups", -84, function()
        SlashCmdList["HCT"]("test")
    end)

    -- Row 4: Sound toggle
    local soundBtn = MakeBtn("Sound: ON", -111, function()
        soundMuted = not soundMuted
        local state = soundMuted and "OFF" or "ON"
        this:SetText("Sound: " .. state)
        local r = soundMuted and 0.6 or 0.2
        this._restR, this._restG, this._restB = r, 0.2, 0.2
        this:SetBackdropBorderColor(r, 0.2, 0.2, 1)
    end)
    menuFrame.soundBtn = soundBtn

    -- Divider
    local div1 = menuFrame:CreateTexture(nil, "ARTWORK")
    div1:SetHeight(1)
    div1:SetPoint("TOPLEFT",  menuFrame, "TOPLEFT",  PAD, -140)
    div1:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -PAD, -140)
    div1:SetTexture(0.3, 0.3, 0.3, 1)

    -- Row 5: Status
    MakeBtn("Status", -146, function()
        SlashCmdList["HCT"]("status")
    end)

    menuFrame:Hide()
end

local function ToggleMenu()
    CreateMenuFrame()
    -- Sync button states on open
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

    if menuFrame.soundBtn then
        local r = soundMuted and 0.6 or 0.2
        menuFrame.soundBtn:SetText("Sound: " .. (soundMuted and "OFF" or "ON"))
        menuFrame.soundBtn._restR, menuFrame.soundBtn._restG, menuFrame.soundBtn._restB = r, 0.2, 0.2
        menuFrame.soundBtn:SetBackdropBorderColor(r, 0.2, 0.2, 1)
    end
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

    if cmd == "menu" then
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

    elseif cmd == "unlock" then
        ShowAnchor()

    elseif cmd == "lock" then
        LockAnchor()

    elseif cmd == "test" then
        local pl  = UnitLevel("player")
        local lo  = math.max(1,  pl - TRADE_RANGE)
        local hi  = math.min(60, pl + TRADE_RANGE)
        ShowPopup("Sarun",    "WTS [Swiftness Potion] [Lesser Mana Potion] [Healing Potion] " .. pl .. "+-",
                              "WTS |cffffffff[Swiftness Potion]|r |cffffffff[Lesser Mana Potion]|r |cffffffff[Healing Potion]|r " .. pl .. "+-", lo, hi)
        ShowPopup("Deffar",   "WTB [Citrine] " .. pl .. "+-",
                              "WTB |cffffffff[Citrine]|r " .. pl .. "+-", lo, hi)
        ShowPopup("Kamyczek", "WTS [Greater Magic Wand] " .. pl .. "+-",
                              "WTS |cff1eff00[Greater Magic Wand]|r " .. pl .. "+-", lo, hi)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Test: 3 popups spawned for level " .. pl .. ".")

    elseif cmd == "help" or cmd == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Commands - type |cffffffff/hct help <command>|r for details:")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/hct menu|r   |cffffffff/hct test|r    |cffffffff/hct unlock|r  |cffffffff/hct lock|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/hct debug|r  |cffffffff/hct sniff|r   |cffffffff/hct status|r  |cffffffff/hct hook N|r")

    elseif string.sub(cmd, 1, 5) == "help " then
        local topic = string.gsub(cmd, "^help%s+", "")
        local G = "|cffffd100"
        if topic == "menu" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "/hct menu|r - Opens the HCTrade GUI panel.")
            DEFAULT_CHAT_FRAME:AddMessage("  Buttons for test, debug, sniff, anchor unlock/lock and reset.")
        elseif topic == "test" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "/hct test|r - Spawns 3 example popups at your current level.")
            DEFAULT_CHAT_FRAME:AddMessage("  Lets you verify sizing, colours and position without needing live HC traffic.")
        elseif topic == "unlock" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "/hct unlock|r - Shows a small drag handle at the popup anchor point.")
            DEFAULT_CHAT_FRAME:AddMessage("  Drag it anywhere on screen, then type /hct lock to save.")
        elseif topic == "lock" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "/hct lock|r - Saves the anchor position and hides the drag handle.")
            DEFAULT_CHAT_FRAME:AddMessage("  Position persists across sessions.")
        elseif topic == "debug" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "/hct debug|r - Toggles debug mode.")
            DEFAULT_CHAT_FRAME:AddMessage("  When ON, every HC WTS/WTB is printed with its parsed level range")
            DEFAULT_CHAT_FRAME:AddMessage("  and whether it matched your level. Good for testing the parser.")
        elseif topic == "sniff" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "/hct sniff|r - Toggles sniff mode.")
            DEFAULT_CHAT_FRAME:AddMessage("  Prints every raw message arriving in the hooked HC frame.")
            DEFAULT_CHAT_FRAME:AddMessage("  Use this if popups aren't triggering - check what the frame sees.")
        elseif topic == "status" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "/hct status|r - Lists all chat frame tab names.")
            DEFAULT_CHAT_FRAME:AddMessage("  Shows which frame is currently hooked for HC detection.")
        elseif topic == "hook" then
            DEFAULT_CHAT_FRAME:AddMessage(G .. "/hct hook N|r - Manually hooks chat frame number N.")
            DEFAULT_CHAT_FRAME:AddMessage("  Use if the HC frame was not auto-detected on login.")
            DEFAULT_CHAT_FRAME:AddMessage("  Run /hct status first to find the right frame number.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Unknown command '" .. topic .. "'. Type /hct help for a list.")
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HCTrade:|r Unknown command. Type |cffffffff/hct help|r for a list.")
    end
end

DEFAULT_CHAT_FRAME:AddMessage("|cffffd100HCTrade:|r Loaded. Type |cffffffff/hct help|r for commands.")