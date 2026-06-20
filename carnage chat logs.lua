-- WhiteNoise-only chat log GUI.
-- Captures ONLY: ReplicatedStorage.Events.Trial.WhiteNoise.OnClientEvent

do
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local UserInputService = game:GetService("UserInputService")
    local CoreGui = game:GetService("CoreGui")
    local TextChatService = game:GetService("TextChatService")

    local localPlayer = Players.LocalPlayer
    if not localPlayer then
        return
    end

    -- Remove an older copy of this GUI/listener when the script is rerun.
    if _G.WhiteNoiseChatLogs and type(_G.WhiteNoiseChatLogs.Cleanup) == "function" then
        pcall(_G.WhiteNoiseChatLogs.Cleanup)
    end

    local controller = {}
    _G.WhiteNoiseChatLogs = controller

    local running = true
    local connections = {}
    local history = {}
    local MAX_LINES = 500
    local MATCH_WINDOW = 4
    local actualChat = {}
    local nextUnknownId = 0
    local unknownByColor = {}
    local unknownAssignments = {}
    local rowsByUnknown = {}

    local function connect(signal, callback)
        local connection = signal:Connect(callback)
        connections[#connections + 1] = connection
        return connection
    end

    local function cleanText(text)
        if type(text) ~= "string" then
            return ""
        end
        return text:gsub("^%s+", ""):gsub("%s+$", "")
    end

    local function displayName(player)
        if not player then
            return nil
        end
        if type(player.DisplayName) == "string" and player.DisplayName ~= "" then
            return player.DisplayName
        end
        return player.Name
    end

    local function pruneActualChat()
        local now = os.clock()
        for index = #actualChat, 1, -1 do
            if now - actualChat[index].time > MATCH_WINDOW + 2 then
                table.remove(actualChat, index)
            end
        end
    end

    -- Store real player chat silently. A message is displayed only when a
    -- matching WhiteNoise event arrives.
    local function rememberActualChat(name, text, source)
        text = cleanText(text)
        if type(name) ~= "string" or name == "" or text == "" then
            return
        end

        pruneActualChat()
        local now = os.clock()
        local key = string.lower(name) .. "\0" .. text

        -- Collapse the same message reported by different Roblox chat APIs,
        -- while preserving a real repeated message from the same source.
        for index = #actualChat, 1, -1 do
            local record = actualChat[index]
            if now - record.time > 1.5 then
                break
            end
            if record.key == key then
                if not record.sources[source] then
                    record.sources[source] = true
                    return
                end
                break
            end
        end

        actualChat[#actualChat + 1] = {
            key = key,
            name = name,
            text = text,
            time = now,
            used = false,
            sources = { [source] = true },
        }
    end

    local function findMatchingName(text)
        text = cleanText(text)
        pruneActualChat()

        local now = os.clock()
        local bestRecord
        local bestDistance = math.huge

        for _, record in ipairs(actualChat) do
            local distance = math.abs(now - record.time)
            if not record.used and record.text == text and distance <= MATCH_WINDOW then
                if distance < bestDistance then
                    bestRecord = record
                    bestDistance = distance
                end
            end
        end

        if bestRecord then
            bestRecord.used = true
            return bestRecord.name
        end
        return "Unknown"
    end

    -- GUI -----------------------------------------------------------------
    local gui = Instance.new("ScreenGui")
    gui.Name = "WhiteNoiseChatLogsGui"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local parented = pcall(function()
        gui.Parent = CoreGui
    end)
    if not parented then
        gui.Parent = localPlayer:WaitForChild("PlayerGui")
    end

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.fromOffset(600, 360)
    frame.Position = UDim2.fromOffset(40, 120)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 20)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = gui

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 10)
    frameCorner.Parent = frame

    local frameStroke = Instance.new("UIStroke")
    frameStroke.Thickness = 1
    frameStroke.Color = Color3.fromRGB(55, 55, 60)
    frameStroke.Transparency = 0.2
    frameStroke.Parent = frame

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
    topMask.Size = UDim2.new(1, 0, 0, 10)
    topMask.Position = UDim2.new(0, 0, 1, -10)
    topMask.BackgroundColor3 = top.BackgroundColor3
    topMask.BorderSizePixel = 0
    topMask.Parent = top

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -120, 1, 0)
    title.Position = UDim2.fromOffset(12, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextColor3 = Color3.fromRGB(235, 235, 235)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Chat Logs  (toggle: [)"
    title.Parent = top

    local function makeButton(text, rightOffset, width)
        local button = Instance.new("TextButton")
        button.Size = UDim2.fromOffset(width, 24)
        button.Position = UDim2.new(1, rightOffset, 0.5, -12)
        button.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
        button.BorderSizePixel = 0
        button.Font = Enum.Font.GothamBold
        button.TextSize = 12
        button.TextColor3 = Color3.fromRGB(245, 245, 245)
        button.Text = text
        button.Parent = top

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 7)
        corner.Parent = button
        return button
    end

    local copyButton = makeButton("COPY", -94, 48)
    local closeButton = makeButton("X", -40, 32)
    closeButton.BackgroundColor3 = Color3.fromRGB(56, 32, 32)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "Scroll"
    scroll.Size = UDim2.new(1, -14, 1, -48)
    scroll.Position = UDim2.fromOffset(7, 41)
    scroll.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 8
    scroll.CanvasSize = UDim2.fromOffset(0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.Parent = frame

    local scrollCorner = Instance.new("UICorner")
    scrollCorner.CornerRadius = UDim.new(0, 10)
    scrollCorner.Parent = scroll

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 10)
    padding.PaddingBottom = UDim.new(0, 10)
    padding.PaddingLeft = UDim.new(0, 10)
    padding.PaddingRight = UDim.new(0, 10)
    padding.Parent = scroll

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = scroll

    -- Assignment picker ---------------------------------------------------
    local picker = Instance.new("Frame")
    picker.Name = "AssignmentPicker"
    picker.AnchorPoint = Vector2.new(0.5, 0.5)
    picker.Position = UDim2.fromScale(0.5, 0.53)
    picker.Size = UDim2.fromOffset(330, 280)
    picker.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
    picker.BorderSizePixel = 0
    picker.Visible = false
    picker.ZIndex = 20
    picker.Parent = frame

    local pickerCorner = Instance.new("UICorner")
    pickerCorner.CornerRadius = UDim.new(0, 10)
    pickerCorner.Parent = picker

    local pickerStroke = Instance.new("UIStroke")
    pickerStroke.Color = Color3.fromRGB(90, 90, 105)
    pickerStroke.Thickness = 1
    pickerStroke.Parent = picker

    local pickerTitle = Instance.new("TextLabel")
    pickerTitle.Size = UDim2.new(1, -48, 0, 38)
    pickerTitle.Position = UDim2.fromOffset(12, 0)
    pickerTitle.BackgroundTransparency = 1
    pickerTitle.Font = Enum.Font.GothamBold
    pickerTitle.TextSize = 14
    pickerTitle.TextColor3 = Color3.fromRGB(240, 240, 245)
    pickerTitle.TextXAlignment = Enum.TextXAlignment.Left
    pickerTitle.ZIndex = 21
    pickerTitle.Parent = picker

    local pickerClose = Instance.new("TextButton")
    pickerClose.Size = UDim2.fromOffset(28, 26)
    pickerClose.Position = UDim2.new(1, -36, 0, 6)
    pickerClose.BackgroundColor3 = Color3.fromRGB(58, 35, 38)
    pickerClose.BorderSizePixel = 0
    pickerClose.Font = Enum.Font.GothamBold
    pickerClose.TextSize = 13
    pickerClose.TextColor3 = Color3.fromRGB(245, 245, 245)
    pickerClose.Text = "X"
    pickerClose.ZIndex = 21
    pickerClose.Parent = picker

    local pickerCloseCorner = Instance.new("UICorner")
    pickerCloseCorner.CornerRadius = UDim.new(0, 6)
    pickerCloseCorner.Parent = pickerClose

    local playerList = Instance.new("ScrollingFrame")
    playerList.Size = UDim2.new(1, -20, 1, -48)
    playerList.Position = UDim2.fromOffset(10, 40)
    playerList.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    playerList.BorderSizePixel = 0
    playerList.ScrollBarThickness = 7
    playerList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    playerList.CanvasSize = UDim2.fromOffset(0, 0)
    playerList.ZIndex = 21
    playerList.Parent = picker

    local playerListCorner = Instance.new("UICorner")
    playerListCorner.CornerRadius = UDim.new(0, 7)
    playerListCorner.Parent = playerList

    local playerListPadding = Instance.new("UIPadding")
    playerListPadding.PaddingTop = UDim.new(0, 7)
    playerListPadding.PaddingBottom = UDim.new(0, 7)
    playerListPadding.PaddingLeft = UDim.new(0, 7)
    playerListPadding.PaddingRight = UDim.new(0, 7)
    playerListPadding.Parent = playerList

    local playerListLayout = Instance.new("UIListLayout")
    playerListLayout.Padding = UDim.new(0, 5)
    playerListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    playerListLayout.Parent = playerList

    local function colorFingerprint(color)
        if typeof(color) ~= "Color3" then
            return nil
        end
        return string.format(
            "%d,%d,%d",
            math.floor(color.R * 255 + 0.5),
            math.floor(color.G * 255 + 0.5),
            math.floor(color.B * 255 + 0.5)
        )
    end

    local function findUnknownId(color)
        local fingerprint = colorFingerprint(color)
        return fingerprint and unknownByColor[fingerprint] or nil
    end

    local function getUnknownId(color)
        local fingerprint = colorFingerprint(color)
        if fingerprint and unknownByColor[fingerprint] then
            return unknownByColor[fingerprint]
        end

        nextUnknownId = nextUnknownId + 1
        local unknownId = nextUnknownId
        if fingerprint then
            unknownByColor[fingerprint] = unknownId
        end
        return unknownId
    end

    local function renderRow(row)
        if row.button and row.button.Parent then
            row.button.Text = row.name .. ": " .. row.text
        end
    end

    local function assignUnknown(unknownId, playerName)
        unknownAssignments[unknownId] = playerName
        for _, row in ipairs(rowsByUnknown[unknownId] or {}) do
            row.name = playerName
            renderRow(row)
        end
    end

    local function clearPlayerButtons()
        for _, child in ipairs(playerList:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
    end

    local function openPicker(unknownId)
        clearPlayerButtons()
        pickerTitle.Text = "Assign Unknown" .. tostring(unknownId)

        local players = Players:GetPlayers()
        table.sort(players, function(a, b)
            return string.lower(a.Name) < string.lower(b.Name)
        end)

        for order, player in ipairs(players) do
            local button = Instance.new("TextButton")
            button.Name = "PlayerOption"
            button.Size = UDim2.new(1, -4, 0, 34)
            button.BackgroundColor3 = Color3.fromRGB(38, 38, 46)
            button.BorderSizePixel = 0
            button.Font = Enum.Font.Gotham
            button.TextSize = 13
            button.TextColor3 = Color3.fromRGB(240, 240, 245)
            button.TextXAlignment = Enum.TextXAlignment.Left
            button.LayoutOrder = order
            button.ZIndex = 22

            if player.DisplayName ~= player.Name then
                button.Text = "   " .. player.DisplayName .. "  (@" .. player.Name .. ")"
            else
                button.Text = "   " .. player.Name
            end
            button.Parent = playerList

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 6)
            corner.Parent = button

            connect(button.MouseButton1Click, function()
                assignUnknown(unknownId, player.Name)
                picker.Visible = false
            end)
        end

        playerList.CanvasPosition = Vector2.zero
        picker.Visible = true
    end

    connect(pickerClose.MouseButton1Click, function()
        picker.Visible = false
    end)

    local function isNearBottom()
        local maxY = math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y)
        return maxY - scroll.CanvasPosition.Y <= 28
    end

    local function scrollToBottom()
        task.defer(function()
            if not running or not scroll.Parent then
                return
            end
            local maxY = math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y)
            scroll.CanvasPosition = Vector2.new(0, maxY)
        end)
    end

    local function removeRowFromUnknownGroup(row)
        if not row.unknownId then
            return
        end
        local group = rowsByUnknown[row.unknownId]
        if not group then
            return
        end
        for index = #group, 1, -1 do
            if group[index] == row then
                table.remove(group, index)
                break
            end
        end
    end

    local function addLine(name, text, color, unknownId)
        if not running or type(text) ~= "string" then
            return
        end

        text = cleanText(text)
        if text == "" then
            return
        end

        name = type(name) == "string" and name ~= "" and name or "Unknown"
        local stickToBottom = isNearBottom()

        local line = Instance.new("TextButton")
        line.Name = "Line"
        line.Size = UDim2.new(1, -6, 0, 24)
        line.AutomaticSize = Enum.AutomaticSize.Y
        line.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
        line.BackgroundTransparency = 0.1
        line.BorderSizePixel = 0
        line.Font = Enum.Font.Gotham
        line.TextSize = 14
        line.TextColor3 = typeof(color) == "Color3" and color or Color3.fromRGB(235, 235, 235)
        line.TextXAlignment = Enum.TextXAlignment.Left
        line.TextYAlignment = Enum.TextYAlignment.Top
        line.TextWrapped = true
        line.AutoButtonColor = unknownId ~= nil
        line.Parent = scroll

        local row = {
            button = line,
            name = name,
            text = text,
            unknownId = unknownId,
        }
        history[#history + 1] = row
        renderRow(row)

        if unknownId then
            rowsByUnknown[unknownId] = rowsByUnknown[unknownId] or {}
            rowsByUnknown[unknownId][#rowsByUnknown[unknownId] + 1] = row
            connect(line.MouseButton1Click, function()
                openPicker(unknownId)
            end)
        else
            line.Active = false
            line.Selectable = false
        end

        local linePadding = Instance.new("UIPadding")
        linePadding.PaddingTop = UDim.new(0, 6)
        linePadding.PaddingBottom = UDim.new(0, 6)
        linePadding.PaddingLeft = UDim.new(0, 10)
        linePadding.PaddingRight = UDim.new(0, 10)
        linePadding.Parent = line

        local lineCorner = Instance.new("UICorner")
        lineCorner.CornerRadius = UDim.new(0, 8)
        lineCorner.Parent = line

        while #history > MAX_LINES do
            local removed = table.remove(history, 1)
            removeRowFromUnknownGroup(removed)
            if removed.button and removed.button.Parent then
                removed.button:Destroy()
            end
        end

        if stickToBottom then
            scrollToBottom()
        end
    end

    -- Hidden name lookup: actual game chat is cached but never printed. ----
    pcall(function()
        connect(TextChatService.MessageReceived, function(message)
            local source = message.TextSource
            if not source then
                return
            end
            local player = Players:GetPlayerByUserId(source.UserId)
            local name = displayName(player) or source.Name
            rememberActualChat(name, message.Text, "text-chat")
        end)
    end)

    local hookedPlayers = setmetatable({}, { __mode = "k" })
    local function hookPlayer(player)
        if hookedPlayers[player] then
            return
        end
        hookedPlayers[player] = true
        connect(player.Chatted, function(message)
            rememberActualChat(displayName(player), message, "player-chatted")
        end)
    end

    for _, player in ipairs(Players:GetPlayers()) do
        hookPlayer(player)
    end
    connect(Players.PlayerAdded, hookPlayer)

    local function hookLegacyChat()
        local folder = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        local event = folder and folder:FindFirstChild("OnMessageDoneFiltering")
        if not event or not event:IsA("RemoteEvent") then
            return
        end

        connect(event.OnClientEvent, function(data)
            if type(data) ~= "table" then
                return
            end
            local speaker = data.FromSpeaker or data.SpeakerName
            local player = type(speaker) == "string" and Players:FindFirstChild(speaker) or nil
            local name = displayName(player) or speaker
            rememberActualChat(name, data.Message or data.MessageText, "legacy-chat")
        end)
    end
    hookLegacyChat()

    -- WhiteNoise remains the ONLY source that creates visible GUI lines. ---
    local Event = ReplicatedStorage:WaitForChild("Events")
        :WaitForChild("Trial")
        :WaitForChild("WhiteNoise")

    connect(Event.OnClientEvent, function(text, color)
        text = cleanText(text)
        if text == "" then
            return
        end

        -- Give the real chat event a moment to arrive if WhiteNoise fires first.
        task.delay(0.25, function()
            if running then
                local name = findMatchingName(text)
                local unknownId = findUnknownId(color)
                local unresolved = false

                if name == "Unknown" then
                    unknownId = unknownId or getUnknownId(color)
                    local assignedName = unknownAssignments[unknownId]
                    if assignedName then
                        name = assignedName
                    else
                        name = "Unknown" .. tostring(unknownId)
                        unresolved = true
                    end
                elseif unknownId then
                    -- A later real-chat match can automatically resolve older
                    -- lines that shared this WhiteNoise color.
                    assignUnknown(unknownId, name)
                end

                addLine(name, text, color, unresolved and unknownId or nil)
            end
        end)
    end)

    -- GUI controls only; these do not capture any other messages.
    connect(UserInputService.InputBegan, function(input, gameProcessed)
        if not gameProcessed and input.KeyCode == Enum.KeyCode.LeftBracket then
            frame.Visible = not frame.Visible
        end
    end)

    connect(closeButton.MouseButton1Click, function()
        frame.Visible = false
    end)

    connect(copyButton.MouseButton1Click, function()
        local output = table.create(#history)
        for index, row in ipairs(history) do
            output[index] = row.name .. ": " .. row.text
        end
        local payload = table.concat(output, "\n")
        local environment = (getgenv and getgenv()) or _G
        local clipboard = rawget(environment, "setclipboard") or rawget(environment, "toclipboard")

        if type(clipboard) == "function" then
            local copied = pcall(clipboard, payload)
            copyButton.Text = copied and "OK" or "ERR"
        else
            copyButton.Text = "N/A"
        end

        task.delay(1, function()
            if running and copyButton.Parent then
                copyButton.Text = "COPY"
            end
        end)
    end)

    function controller.Cleanup()
        if not running then
            return
        end
        running = false

        for _, connection in ipairs(connections) do
            pcall(function()
                connection:Disconnect()
            end)
        end
        table.clear(connections)

        if gui.Parent then
            gui:Destroy()
        end
        if _G.WhiteNoiseChatLogs == controller then
            _G.WhiteNoiseChatLogs = nil
        end
    end
end
