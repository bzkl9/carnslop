--============================================================
--====================  CHAT LOGS GUI  =======================
--============================================================
-- Improved UI:
--  • Cleaner look (no timestamps, no CHAT/BUBBLE tags)
--  • Name colors (deterministic “Roblox-like” per-name color)
--  • Won’t yank you to bottom if you’re scrolling up
--  • Scalable (Ctrl + MouseWheel) + buttons (+ / - / Reset)
--  • Resizable (drag bottom-right handle)
--  • Uses DISPLAY NAMES (falls back to Username if needed)
--  • Keeps your original capture + bubble watcher + dedupe logic

do
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local TextChatService = game:GetService("TextChatService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local CoreGui = game:GetService("CoreGui")
    local TextService = game:GetService("TextService")
    local ChatService = game:GetService("Chat")
    local RunService = game:GetService("RunService")

    local LP = Players.LocalPlayer
    if not LP then return end

    -- Kill previous instance
    if _G.ChatLogsController and type(_G.ChatLogsController.Cleanup) == "function" then
        pcall(_G.ChatLogsController.Cleanup)
        _G.ChatLogsController = nil
    end

    local controller = {}
    _G.ChatLogsController = controller

    local running = true
    local connections = {}

    --==================== Settings ====================
    local TOGGLE_KEY = Enum.KeyCode.LeftBracket
    local MAX_LINES = 350
    local COPY_LAST_COUNT = 500

    local FILTER_SLASH_IN_CHAT = true
    local FILTER_SLASH_IN_BUBBLES = false
    local IGNORE_BUBBLE_ELLIPSIS = false

    local GLOBAL_DEDUP_SECONDS = 6.0
    local BUBBLE_DELAY_SECONDS = 0.12

    local FORCE_BUBBLE_RANGE = true
    local HUGE_DISTANCE = 9e9

    local BUBBLE_BLOCK_EXACT = { "murder" }

    -- Dedupe by TEXT only too (helps when bubble owner is Unknown)
    local DEDUPE_BY_TEXT_ONLY = true

    -- Auto-scroll behavior
    local STICKY_BOTTOM_THRESHOLD = 28 -- px: if within this, we consider you "at bottom"
    --==================================================

    if FORCE_BUBBLE_RANGE then
        pcall(function()
            local cfg = TextChatService:FindFirstChild("BubbleChatConfiguration")
            if cfg then
                cfg.Enabled = true
                if cfg.MaxDistance ~= nil then cfg.MaxDistance = HUGE_DISTANCE end
                if cfg.MinimizeDistance ~= nil then cfg.MinimizeDistance = HUGE_DISTANCE end
            end
        end)
        pcall(function()
            ChatService:SetBubbleChatSettings({
                MaxDistance = HUGE_DISTANCE,
                MinimizeDistance = HUGE_DISTANCE
            })
        end)
    end

    local function cleanup()
        running = false
        for _, c in ipairs(connections) do
            pcall(function() c:Disconnect() end)
        end
        connections = {}
        pcall(function()
            if controller.Gui and controller.Gui.Parent then
                controller.Gui:Destroy()
            end
        end)
        controller.Gui = nil
        if _G.ChatLogsController == controller then
            _G.ChatLogsController = nil
        end
    end
    controller.Cleanup = cleanup

    local function isSlashCommand(msg)
        return type(msg) == "string" and msg:sub(1, 1) == "/"
    end

    local function cleanText(s)
        if type(s) ~= "string" then return "" end
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        return s
    end

    local function isBlockedBubbleExact(text)
        local t = cleanText(text):lower()
        for _, bad in ipairs(BUBBLE_BLOCK_EXACT) do
            if t == bad then return true end
        end
        return false
    end

    --==================== Display name helpers =====================
    local function getDisplayNameFromPlayer(plr)
        if not plr then return nil end
        local dn = plr.DisplayName
        if type(dn) == "string" and dn ~= "" then return dn end
        return plr.Name
    end

    local function getDisplayNameFromUserId(userId)
        if typeof(userId) ~= "number" then return nil end
        local plr = Players:GetPlayerByUserId(userId)
        if plr then return getDisplayNameFromPlayer(plr) end
        return nil
    end

    -- For legacy chat speaker strings, try to map to Player
    local function getDisplayNameFromSpeakerString(speaker)
        if type(speaker) ~= "string" or speaker == "" then return "Unknown" end
        local plr = Players:FindFirstChild(speaker)
        if plr then return getDisplayNameFromPlayer(plr) end
        return speaker -- fallback (some games use non-username speakers)
    end

    --==================== Name color (deterministic) =====================
    local function hashNameToColor(name)
        name = tostring(name or "Unknown")
        local h = 2166136261
        for i = 1, #name do
            h = bit32.bxor(h, name:byte(i))
            h = (h * 16777619) % 2^32
        end

        local hue = (h % 360) / 360
        local sat = 0.62
        local val = 0.95

        local i = math.floor(hue * 6)
        local f = hue * 6 - i
        local p = val * (1 - sat)
        local q = val * (1 - f * sat)
        local t = val * (1 - (1 - f) * sat)
        i = i % 6

        local r, g, b
        if i == 0 then r, g, b = val, t, p
        elseif i == 1 then r, g, b = q, val, p
        elseif i == 2 then r, g, b = p, val, t
        elseif i == 3 then r, g, b = p, q, val
        elseif i == 4 then r, g, b = t, p, val
        else r, g, b = val, p, q end

        local damp = 0.95
        return Color3.new(r * damp, g * damp, b * damp)
    end

    local function rgbString(c3)
        local r = math.floor(c3.R * 255 + 0.5)
        local g = math.floor(c3.G * 255 + 0.5)
        local b = math.floor(c3.B * 255 + 0.5)
        return string.format("rgb(%d,%d,%d)", r, g, b)
    end

    local function escapeRichText(s)
        s = tostring(s or "")
        s = s:gsub("&", "&amp;")
        s = s:gsub("<", "&lt;")
        s = s:gsub(">", "&gt;")
        s = s:gsub("\"", "&quot;")
        s = s:gsub("'", "&apos;")
        return s
    end

    --==================== GUI =========================
    local gui = Instance.new("ScreenGui")
    gui.Name = "ChatLogsGui"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local ok = pcall(function() gui.Parent = CoreGui end)
    if not ok then gui.Parent = LP:WaitForChild("PlayerGui") end
    controller.Gui = gui

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 600, 0, 360)
    frame.Position = UDim2.new(0, 40, 0, 120)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 20)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = gui

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 10)
    frameCorner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = Color3.fromRGB(55, 55, 60)
    stroke.Transparency = 0.2
    stroke.Parent = frame

    local scaleObj = Instance.new("UIScale")
    scaleObj.Scale = 1
    scaleObj.Parent = frame

    local top = Instance.new("Frame")
    top.Name = "TopBar"
    top.Size = UDim2.new(1, 0, 0, 34)
    top.BackgroundColor3 = Color3.fromRGB(26, 26, 30)
    top.BorderSizePixel = 0
    top.Parent = frame

    local topCorner = Instance.new("UICorner")
    topCorner.CornerRadius = UDim.new(0, 10)
    topCorner.Parent = top

    local topMask = Instance.new("Frame")
    topMask.BackgroundColor3 = top.BackgroundColor3
    topMask.BorderSizePixel = 0
    topMask.Size = UDim2.new(1, 0, 0, 12)
    topMask.Position = UDim2.new(0, 0, 1, -12)
    topMask.Parent = top

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -255, 1, 0)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextColor3 = Color3.fromRGB(235, 235, 235)
    title.Text = "Chat Logs  (toggle: [)   |   Ctrl+Wheel = scale"
    title.Parent = top

    local function makeTopBtn(txt, xOffset)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 40, 0, 24)
        b.Position = UDim2.new(1, xOffset, 0.5, -12)
        b.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 14
        b.TextColor3 = Color3.fromRGB(245, 245, 245)
        b.Text = txt
        b.AutoButtonColor = true
        b.Parent = top

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 7)
        c.Parent = b

        local s = Instance.new("UIStroke")
        s.Thickness = 1
        s.Color = Color3.fromRGB(70, 70, 78)
        s.Transparency = 0.35
        s.Parent = b

        return b
    end

    local btnCopy  = makeTopBtn("CP", -204)
    local btnMinus = makeTopBtn("-", -160)
    local btnReset = makeTopBtn("1x", -116)
    local btnPlus  = makeTopBtn("+", -72)

    local closeBtn = makeTopBtn("X", -28)
    closeBtn.BackgroundColor3 = Color3.fromRGB(56, 32, 32)

    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 1, -34)
    body.Position = UDim2.new(0, 0, 0, 34)
    body.BackgroundTransparency = 1
    body.Parent = frame

    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "Scroll"
    scroll.Size = UDim2.new(1, -14, 1, -14)
    scroll.Position = UDim2.new(0, 7, 0, 7)
    scroll.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 8
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
    scroll.Parent = body

    local scrollCorner = Instance.new("UICorner")
    scrollCorner.CornerRadius = UDim.new(0, 10)
    scrollCorner.Parent = scroll

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = scroll

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 10)
    pad.PaddingLeft = UDim.new(0, 10)
    pad.PaddingRight = UDim.new(0, 10)
    pad.Parent = scroll

    local newPill = Instance.new("TextButton")
    newPill.Name = "NewPill"
    newPill.AnchorPoint = Vector2.new(1, 1)
    newPill.Position = UDim2.new(1, -16, 1, -16)
    newPill.Size = UDim2.new(0, 150, 0, 28)
    newPill.BackgroundColor3 = Color3.fromRGB(45, 60, 90)
    newPill.BorderSizePixel = 0
    newPill.Font = Enum.Font.GothamBold
    newPill.TextSize = 13
    newPill.TextColor3 = Color3.fromRGB(245, 245, 245)
    newPill.Text = "New messages ▾"
    newPill.Visible = false
    newPill.Parent = body

    local newPillCorner = Instance.new("UICorner")
    newPillCorner.CornerRadius = UDim.new(0, 999)
    newPillCorner.Parent = newPill

    local newPillStroke = Instance.new("UIStroke")
    newPillStroke.Thickness = 1
    newPillStroke.Color = Color3.fromRGB(95, 115, 155)
    newPillStroke.Transparency = 0.2
    newPillStroke.Parent = newPill

    local resizer = Instance.new("Frame")
    resizer.Name = "Resizer"
    resizer.AnchorPoint = Vector2.new(1, 1)
    resizer.Position = UDim2.new(1, -6, 1, -6)
    resizer.Size = UDim2.new(0, 18, 0, 18)
    resizer.BackgroundColor3 = Color3.fromRGB(60, 60, 68)
    resizer.BorderSizePixel = 0
    resizer.Parent = frame

    local rCorner = Instance.new("UICorner")
    rCorner.CornerRadius = UDim.new(0, 6)
    rCorner.Parent = resizer

    local rStroke = Instance.new("UIStroke")
    rStroke.Thickness = 1
    rStroke.Color = Color3.fromRGB(95, 95, 110)
    rStroke.Transparency = 0.25
    rStroke.Parent = resizer

    local rIcon = Instance.new("TextLabel")
    rIcon.BackgroundTransparency = 1
    rIcon.Size = UDim2.new(1, 0, 1, 0)
    rIcon.Font = Enum.Font.GothamBold
    rIcon.TextSize = 14
    rIcon.TextColor3 = Color3.fromRGB(230, 230, 235)
    rIcon.Text = "↘"
    rIcon.Parent = resizer

    --==================== Visibility / Toggle =====================
    frame.Visible = true
    connections[#connections+1] = closeBtn.MouseButton1Click:Connect(function() frame.Visible = false end)
    connections[#connections+1] = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.KeyCode == TOGGLE_KEY then
            frame.Visible = not frame.Visible
        end
    end)

    --==================== Scale controls =====================
    local function clampScale(s)
        return math.clamp(s, 0.65, 1.6)
    end

    local function setScale(s)
        scaleObj.Scale = clampScale(s)
    end

    connections[#connections+1] = btnPlus.MouseButton1Click:Connect(function()
        setScale(scaleObj.Scale + 0.08)
    end)
    connections[#connections+1] = btnMinus.MouseButton1Click:Connect(function()
        setScale(scaleObj.Scale - 0.08)
    end)
    connections[#connections+1] = btnReset.MouseButton1Click:Connect(function()
        setScale(1)
    end)

    connections[#connections+1] = UserInputService.InputChanged:Connect(function(input, gpe)
        if not running then return end
        if gpe then return end
        if input.UserInputType == Enum.UserInputType.MouseWheel then
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
                local delta = input.Position.Z
                if delta > 0 then
                    setScale(scaleObj.Scale + 0.06)
                elseif delta < 0 then
                    setScale(scaleObj.Scale - 0.06)
                end
            end
        end
    end)

    --==================== Resize drag handle =====================
    do
        local dragging = false
        local startMouse
        local startSize

        local minW, minH = 420, 260
        local maxW, maxH = 1100, 820

        local function getMousePos()
            local m = UserInputService:GetMouseLocation()
            return Vector2.new(m.X, m.Y)
        end

        connections[#connections+1] = resizer.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                startMouse = getMousePos()
                startSize = frame.AbsoluteSize
            end
        end)

        connections[#connections+1] = UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)

        connections[#connections+1] = RunService.RenderStepped:Connect(function()
            if not dragging then return end
            if not running then return end

            local cur = getMousePos()
            local delta = cur - startMouse

            local newW = math.clamp(startSize.X + delta.X, minW, maxW)
            local newH = math.clamp(startSize.Y + delta.Y, minH, maxH)

            frame.Size = UDim2.new(0, newW, 0, newH)
        end)
    end

    --==================== Scroll stickiness helpers =====================
    local function getCanvasY()
        return scroll.CanvasSize.Y.Offset
    end

    local function getWindowY()
        return scroll.AbsoluteWindowSize.Y
    end

    local function getMaxScrollY()
        return math.max(0, getCanvasY() - getWindowY())
    end

    local function isNearBottom()
        local maxY = getMaxScrollY()
        local y = scroll.CanvasPosition.Y
        return (maxY - y) <= STICKY_BOTTOM_THRESHOLD
    end

    local function snapToBottom()
        scroll.CanvasPosition = Vector2.new(0, getMaxScrollY())
        newPill.Visible = false
    end

    connections[#connections+1] = newPill.MouseButton1Click:Connect(function()
        snapToBottom()
    end)

    connections[#connections+1] = scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        if not running then return end
        if isNearBottom() then
            newPill.Visible = false
        end
    end)

    --==================== Dedupe + priority =====================
    local seen = {} -- key -> {t=clock, pr=priority}
    local function pruneSeen()
        local now = os.clock()
        for k, v in pairs(seen) do
            if (now - v.t) > (GLOBAL_DEDUP_SECONDS + 1) then
                seen[k] = nil
            end
        end
    end

    local function markSeen(key, pr)
        seen[key] = { t = os.clock(), pr = pr }
    end

    local function blockedByKey(key, pr)
        local now = os.clock()
        local prev = seen[key]
        if prev and (now - prev.t) <= GLOBAL_DEDUP_SECONDS then
            if pr <= prev.pr then
                return true
            else
                seen[key] = { t = now, pr = pr }
                return false
            end
        end
        return false
    end

    local function shouldLog(displayName, text, priority)
        pruneSeen()
        local nameKey = (displayName or "Unknown") .. "|" .. (text or "")
        local textKey = "TEXT|" .. (text or "")

        if DEDUPE_BY_TEXT_ONLY then
            if blockedByKey(textKey, priority) then
                return false
            end
            markSeen(textKey, priority)
        end

        if blockedByKey(nameKey, priority) then
            return false
        end
        markSeen(nameKey, priority)
        return true
    end

    --==================== Line rendering =====================
    local lineIndex = 0
    local logHistory = {} -- stores accepted/logged lines in order: {name=..., text=...}

    local function updateCanvas(stickToBottom, prevPosY)
        task.defer(function()
            if not running then return end

            local y = layout.AbsoluteContentSize.Y + 20
            scroll.CanvasSize = UDim2.new(0, 0, 0, y)

            if stickToBottom then
                snapToBottom()
            else
                scroll.CanvasPosition = Vector2.new(0, math.clamp(prevPosY or scroll.CanvasPosition.Y, 0, getMaxScrollY()))
                newPill.Visible = true
            end
        end)
    end

    local function addLineRich(displayName, message)
        if not running or not scroll.Parent then return end

        local count = 0
        for _, ch in ipairs(scroll:GetChildren()) do
            if ch:IsA("Frame") and ch.Name == "Line" then
                count += 1
            end
        end
        if count >= MAX_LINES then
            for _, ch in ipairs(scroll:GetChildren()) do
                if ch:IsA("Frame") and ch.Name == "Line" then
                    ch:Destroy()
                    break
                end
            end
        end

        local stick = isNearBottom()
        local prevY = scroll.CanvasPosition.Y

        lineIndex += 1
        local isOdd = (lineIndex % 2 == 1)

        local line = Instance.new("Frame")
        line.Name = "Line"
        line.BackgroundColor3 = isOdd and Color3.fromRGB(20, 20, 24) or Color3.fromRGB(18, 18, 22)
        line.BackgroundTransparency = 0.1
        line.BorderSizePixel = 0
        line.Size = UDim2.new(1, -6, 0, 24)
        line.Parent = scroll

        local lc = Instance.new("UICorner")
        lc.CornerRadius = UDim.new(0, 8)
        lc.Parent = line

        local ls = Instance.new("UIStroke")
        ls.Thickness = 1
        ls.Color = Color3.fromRGB(55, 55, 62)
        ls.Transparency = 0.78
        ls.Parent = line

        local lbl = Instance.new("TextLabel")
        lbl.BackgroundTransparency = 1
        lbl.Position = UDim2.new(0, 10, 0, 6)
        lbl.Size = UDim2.new(1, -20, 0, 18)
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 14
        lbl.TextColor3 = Color3.fromRGB(235, 235, 235)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextYAlignment = Enum.TextYAlignment.Top
        lbl.TextWrapped = true
        lbl.RichText = true
        lbl.Parent = line

        local safeName = escapeRichText(displayName or "Unknown")
        local safeMsg  = escapeRichText(message or "")
        local c = hashNameToColor(displayName) -- color based on display name (what you see)
        local cStr = rgbString(c)

        lbl.Text = string.format(
            '<b><font color="%s">%s</font></b><font color="rgb(230,230,235)">: %s</font>',
            cStr, safeName, safeMsg
        )

        task.defer(function()
            if not running then return end
            if not (lbl and lbl.Parent) then return end

            local maxWidth = math.max(50, lbl.AbsoluteSize.X)
            local bounds = TextService:GetTextSize(lbl.Text, lbl.TextSize, lbl.Font, Vector2.new(maxWidth, 9999))
            local h = math.max(22, bounds.Y + 2)

            line.Size = UDim2.new(1, -6, 0, h + 12)
            lbl.Size = UDim2.new(1, -20, 0, h + 2)

            updateCanvas(stick, prevY)
        end)
    end

    local function logLine(displayName, text, priority)
        if not shouldLog(displayName, text, priority) then return end

        local dn = tostring(displayName or "?")
        local msg = tostring(text or "")

        -- keep full logged history (trimmed to a reasonable cap)
        logHistory[#logHistory + 1] = { name = dn, text = msg }
        if #logHistory > 3000 then
            table.remove(logHistory, 1)
        end

        addLineRich(dn, msg)
    end

    --==================== Copy recent chat (last 150) =====================
    local function buildCopyText()
        local n = #logHistory
        if n <= 0 then
            return ""
        end

        local startIdx = math.max(1, n - COPY_LAST_COUNT + 1)
        local out = table.create(n - startIdx + 1)

        for i = startIdx, n do
            local row = logHistory[i]
            out[#out + 1] = string.format("%s: %s", tostring(row.name or "Unknown"), tostring(row.text or ""))
        end

        return table.concat(out, "\n")
    end

    local function tryCopyToClipboard(text)
        if type(text) ~= "string" then return false, "invalid text" end

        local env = (getgenv and getgenv()) or _G
        local fns = {
            rawget(env, "setclipboard"),
            rawget(env, "toclipboard"),
            rawget(env, "ClipboardSet"),
            (type(setclipboard) == "function" and setclipboard or nil),
            (type(toclipboard) == "function" and toclipboard or nil),
            (type(ClipboardSet) == "function" and ClipboardSet or nil),
        }

        for _, fn in ipairs(fns) do
            if type(fn) == "function" then
                local okCall = pcall(fn, text)
                if okCall then
                    return true
                end
            end
        end

        return false, "clipboard function not available"
    end

    local copyBtnOriginalText = btnCopy.Text
    local copyBtnResetToken = 0

    local function flashCopyButton(tempText)
        copyBtnResetToken += 1
        local token = copyBtnResetToken
        btnCopy.Text = tempText
        task.delay(1.0, function()
            if not running then return end
            if token ~= copyBtnResetToken then return end
            if btnCopy and btnCopy.Parent then
                btnCopy.Text = copyBtnOriginalText
            end
        end)
    end

    connections[#connections+1] = btnCopy.MouseButton1Click:Connect(function()
        local payload = buildCopyText()
        if payload == "" then
            flashCopyButton("0")
            return
        end

        local okCopy = tryCopyToClipboard(payload)
        if okCopy then
            flashCopyButton("OK")
        else
            flashCopyButton("ERR")
        end
    end)

    --==================== Chat capture =====================
    local function resolvePlayerFromTextSource(textSource)
        if not textSource then return nil end
        local uid = textSource.UserId
        if typeof(uid) == "number" then
            return Players:GetPlayerByUserId(uid)
        end
        return nil
    end

    local legacyHooked = false
    do
        local events = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if events then
            local msgEvent = events:FindFirstChild("OnMessageDoneFiltering")
            if msgEvent and msgEvent:IsA("RemoteEvent") then
                legacyHooked = true
                connections[#connections+1] = msgEvent.OnClientEvent:Connect(function(messageData)
                    local text = cleanText(messageData and (messageData.Message or messageData.MessageText) or "")
                    if text == "" then return end
                    if FILTER_SLASH_IN_CHAT and isSlashCommand(text) then return end

                    local speaker = messageData.FromSpeaker or messageData.SpeakerName or "Unknown"
                    local displayName = getDisplayNameFromSpeakerString(speaker)

                    logLine(displayName, text, 2)
                end)
            end
        end
    end

    if TextChatService and TextChatService.MessageReceived then
        connections[#connections+1] = TextChatService.MessageReceived:Connect(function(message)
            local text = cleanText(message.Text or "")
            if text == "" then return end
            if FILTER_SLASH_IN_CHAT and isSlashCommand(text) then return end

            local source = message.TextSource
            local plr = resolvePlayerFromTextSource(source)
            local displayName

            if plr then
                displayName = getDisplayNameFromPlayer(plr)
            else
                -- try userId anyway
                displayName = source and getDisplayNameFromUserId(source.UserId) or nil
                -- fallback to whatever name we have
                if not displayName then
                    displayName = (source and source.Name) or "Unknown"
                end
            end

            logLine(displayName, text, 2)
        end)
    end

    --==================== Bubble UI watcher (expanded + lighter robust) =====================
    local lastTextByLabel = setmetatable({}, { __mode = "k" }) -- weak keys
    local hookedLabelSet = setmetatable({}, { __mode = "k" })  -- weak keys
    local retryTokenByLabel = setmetatable({}, { __mode = "k" })

    -- Lightweight retries (bubbles usually stay on screen long enough)
    local BUBBLE_RETRY_PASSES = 3
    local BUBBLE_RETRY_INTERVAL = 0.18
    local BUBBLE_MAX_PARENT_DEPTH = 20

    local function getLabelTextRobust(lbl)
        if not lbl then return "" end

        local txt = ""
        pcall(function()
            txt = lbl.Text or ""
        end)
        txt = cleanText(txt)

        -- Prefer ContentText if it exists and is non-empty (can help with rich text labels)
        local okContent, content = pcall(function()
            return lbl.ContentText
        end)
        if okContent and type(content) == "string" then
            local ct = cleanText(content)
            if ct ~= "" then
                return ct
            end
        end

        return txt
    end

    local function findBillboardGui(inst)
        local p = inst
        for _ = 1, BUBBLE_MAX_PARENT_DEPTH do
            if not p then return nil end
            if p:IsA("BillboardGui") then return p end
            p = p.Parent
        end
        return nil
    end

    local function isCharacterAdornee(bb)
        if not (bb and bb.Adornee) then return false end
        local model = bb.Adornee:FindFirstAncestorOfClass("Model")
        if not model then return false end
        local plr = Players:GetPlayerFromCharacter(model)
        return plr ~= nil
    end

    local function isProbablyBubbleLabel(lbl)
        if not (lbl and (lbl:IsA("TextLabel") or lbl:IsA("TextButton"))) then return false end

        -- Never treat our own GUI as bubble UI
        if controller.Gui and lbl:IsDescendantOf(controller.Gui) then
            return false
        end

        local bb = findBillboardGui(lbl)
        if bb and isCharacterAdornee(bb) then
            return true
        end

        -- Fallback by ancestry names (some games rename bubble containers)
        local p = lbl.Parent
        local depth = 0
        while p and depth < BUBBLE_MAX_PARENT_DEPTH do
            local n = (p.Name or ""):lower()
            if n:find("bubble") or n:find("bubblechat") or n:find("chatbubble") then
                return true
            end
            if p:IsA("BillboardGui") then
                -- Non-standard bubble billboard but still character attached
                if isCharacterAdornee(p) then
                    return true
                end
            end
            p = p.Parent
            depth += 1
        end
        return false
    end

    local function bubbleOwnerDisplayName(lbl)
        local bb = findBillboardGui(lbl)
        if bb and bb.Adornee then
            local model = bb.Adornee:FindFirstAncestorOfClass("Model")
            if model then
                local plr = Players:GetPlayerFromCharacter(model)
                if plr then
                    return getDisplayNameFromPlayer(plr)
                end
            end
        end
        return "Unknown"
    end

    local function handleBubbleLabel(lbl)
        if not running or not lbl or not lbl.Parent then return end
        if not isProbablyBubbleLabel(lbl) then return end

        local text = getLabelTextRobust(lbl)
        if text == "" then return end
        if IGNORE_BUBBLE_ELLIPSIS and text == "..." then return end
        if FILTER_SLASH_IN_BUBBLES and isSlashCommand(text) then return end
        if isBlockedBubbleExact(text) then return end

        local last = lastTextByLabel[lbl]
        if last == text then return end
        lastTextByLabel[lbl] = text

        local whoDisplay = bubbleOwnerDisplayName(lbl)

        task.delay(BUBBLE_DELAY_SECONDS, function()
            if not running then return end
            if not lbl.Parent then return end

            -- Re-read after delay in case initial text was placeholder / partial render
            local finalText = getLabelTextRobust(lbl)
            if finalText == "" then return end
            if IGNORE_BUBBLE_ELLIPSIS and finalText == "..." then return end
            if FILTER_SLASH_IN_BUBBLES and isSlashCommand(finalText) then return end
            if isBlockedBubbleExact(finalText) then return end

            lastTextByLabel[lbl] = finalText
            logLine(whoDisplay, finalText, 1)
        end)
    end

    local function scheduleLabelRetries(lbl)
        if not (lbl and (lbl:IsA("TextLabel") or lbl:IsA("TextButton"))) then return end
        if not lbl.Parent then return end

        local tok = (retryTokenByLabel[lbl] or 0) + 1
        retryTokenByLabel[lbl] = tok

        for i = 1, BUBBLE_RETRY_PASSES do
            task.delay(BUBBLE_RETRY_INTERVAL * i, function()
                if not running then return end
                if not lbl.Parent then return end
                if retryTokenByLabel[lbl] ~= tok then return end
                pcall(function() handleBubbleLabel(lbl) end)
            end)
        end
    end

    local function hookLabel(lbl)
        if not (lbl and (lbl:IsA("TextLabel") or lbl:IsA("TextButton"))) then return end
        if hookedLabelSet[lbl] then
            -- no new connections; just a quick retry attempt
            pcall(function() handleBubbleLabel(lbl) end)
            scheduleLabelRetries(lbl)
            return
        end
        hookedLabelSet[lbl] = true

        -- Initial attempt + a few delayed retries (cheap + effective)
        pcall(function() handleBubbleLabel(lbl) end)
        scheduleLabelRetries(lbl)

        connections[#connections+1] = lbl:GetPropertyChangedSignal("Text"):Connect(function()
            pcall(function() handleBubbleLabel(lbl) end)
            scheduleLabelRetries(lbl)
        end)

        -- Some bubble labels are hidden then shown / re-used
        pcall(function()
            connections[#connections+1] = lbl:GetPropertyChangedSignal("Visible"):Connect(function()
                pcall(function() handleBubbleLabel(lbl) end)
                scheduleLabelRetries(lbl)
            end)
        end)

        connections[#connections+1] = lbl.AncestryChanged:Connect(function(_, parent)
            if not parent then
                lastTextByLabel[lbl] = nil
                hookedLabelSet[lbl] = nil
                retryTokenByLabel[lbl] = nil
            else
                pcall(function() handleBubbleLabel(lbl) end)
                scheduleLabelRetries(lbl)
            end
        end)
    end

    local function hookBillboard(bb)
        if not (bb and bb:IsA("BillboardGui")) then return end

        -- Immediate scan of only this bubble subtree (cheap)
        for _, d in ipairs(bb:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                hookLabel(d)
            end
        end

        -- Watch only inside this billboard
        connections[#connections+1] = bb.DescendantAdded:Connect(function(d)
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                task.defer(function()
                    if running and d.Parent then
                        hookLabel(d)
                    end
                end)
            end
        end)
    end

    local function scanAndWatch(rootGui)
        for _, d in ipairs(rootGui:GetDescendants()) do
            if d:IsA("BillboardGui") then
                -- Hook billboard subtrees (more targeted than hooking every label first)
                hookBillboard(d)
            elseif d:IsA("TextLabel") or d:IsA("TextButton") then
                -- Fallback for non-standard structures
                hookLabel(d)
            end
        end

        connections[#connections+1] = rootGui.DescendantAdded:Connect(function(d)
            if d:IsA("BillboardGui") then
                task.defer(function()
                    if running and d.Parent then
                        hookBillboard(d)
                    end
                end)
            elseif d:IsA("TextLabel") or d:IsA("TextButton") then
                task.defer(function()
                    if running and d.Parent then
                        hookLabel(d)
                    end
                end)
            end
        end)
    end

    scanAndWatch(CoreGui)
    scanAndWatch(LP:WaitForChild("PlayerGui"))

    addLineRich("SYS", "Ready. DisplayNames ON. Scroll up safely (won’t auto-pull). Click “New messages” to jump. Ctrl+Wheel to scale; drag ↘ to resize.")
end