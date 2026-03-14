-- Modified version of BlackenedFinder GUI script
-- This version uses the GameTime value from ReplicatedStorage to timestamp history
-- and highlights overhead labels red when players carry dangerous items.
-- In addition, the history now records victims by scanning the workspace for players
-- whose models contain a 'Corpse' child, rather than relying on Humanoid.Died events.
-- NOTE: This script is intended to run as a LocalScript in StarterPlayerScripts.

-- The majority of the original script remains unchanged. Only the relevant
-- sections have been updated to fetch and display in‑game time and to
-- recolor overhead boxes for certain items. The history recording has
-- been updated to detect victims via workspace scanning.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LOCAL_PLAYER = Players.LocalPlayer
if not LOCAL_PLAYER then return end

local TARGET_NAME = "Blackened"
local TOGGLE_KEY = Enum.KeyCode.P
local SCAN_INTERVAL = 0.6
local GUI_WATCHDOG_INTERVAL = 1.0

-- Snapshot tuning
local SNAPSHOT_DELAY = 0.20
local SNAPSHOT_COOLDOWN = 0.85

-- Over-head items display tuning
local HEAD_GUI_NAME = "LiveItemsOverhead"
local OVERHEAD_UPDATE_THROTTLE = 0.20

-- History tuning
local HISTORY_MAX = 25
local DEATH_MATCH_WINDOW = 4.0 -- seconds: deaths in last N seconds get attached to the blackened event
local DEATH_RECORD_COOLDOWN = 1.0 -- prevent duplicate death records per player

local GUI_NAME = "BlackenedFinderGui"

-- When players are farther than this distance (in studs) from the local camera,
-- their overhead label will show a diamond indicator instead of the normal
-- backpack contents. This mirrors the original MaxDistance of the billboard.
local OVERHEAD_OUT_OF_RANGE_DISTANCE = 120

-- Key to toggle the player board. Only active when the main GUI is open.
local PLAYER_BOARD_KEY = Enum.KeyCode.K

--========================
-- PERSISTENT STORAGE (SURVIVES RE-RUNS)
--========================
_G.BlackenedFinderPersist = _G.BlackenedFinderPersist or {
    lastBlackenedUserId = 0,
    lastBlackenedName = "None",
    lastBlackenedItemsSnapshot = "(unknown)",
    lastSnapshotTimeByUserId = {}, -- [userId] = os.clock()

    -- history
    -- newest first: { t=os.time(), blackenedName, blackenedUserId, itemsSnapshot,
    --                deaths = {names...}, gameTimeMinutes = number? }
    history = {},
}

local PERSIST = _G.BlackenedFinderPersist

--========================
-- CLEANUP PREVIOUS RUN (BUT KEEP PERSIST)
--========================
if _G.BlackenedFinderController and type(_G.BlackenedFinderController.Cleanup) == "function" then
    pcall(function() _G.BlackenedFinderController.Cleanup() end)
end

local controller = {
    conns = {},
    perPlayerConns = {},

    gui = nil,
    frame = nil,
    list = nil,
    titleLabel = nil,
    closeBtn = nil,
    currentBlackenedLabel = nil,

    friendsList = nil,
    friendsTitle = nil,

    historyList = nil,
    historyTitle = nil,

    uiConns = {},

    overheadByPlayer = {},
    overheadConnsByPlayer = {},
    overheadLastUpdate = {}, -- [userId] = os.clock()

    -- Death tracking (for history)
    recentDeaths = {}, -- array of {t=os.clock(), userId, name}
    lastDeathTimeByUserId = {}, -- [userId]=os.clock()

    -- Toggle state (open/close)
    isOpen = true,

    -- where GUI is parented
    container = nil,

    -- Player board UI (for K key)
    playerBoardFrame = nil,
    playerBoardScroll = nil,
    playerBoardOpen = false,
    -- Mapping from Player instance to entry UI elements
    playerBoardEntries = {},
    -- Selection state: true if crossed out
    playerBoardSelections = {},
}

_G.BlackenedFinderController = controller

local function disconnectList(list)
    if not list then return end
    for _, c in ipairs(list) do
        pcall(function() c:Disconnect() end)
    end
end

local function connect(sig, fn)
    local c = sig:Connect(fn)
    table.insert(controller.conns, c)
    return c
end

local function disconnectUiConns()
    disconnectList(controller.uiConns)
    controller.uiConns = {}
end

local function destroyAllOverheads()
    for _, list in pairs(controller.overheadConnsByPlayer) do
        disconnectList(list)
    end
    controller.overheadConnsByPlayer = {}

    for _, g in pairs(controller.overheadByPlayer) do
        pcall(function() g:Destroy() end)
    end
    controller.overheadByPlayer = {}
    controller.overheadLastUpdate = {}
end

local function disconnectAll()
    disconnectList(controller.conns)
    controller.conns = {}

    for _, list in pairs(controller.perPlayerConns) do
        disconnectList(list)
    end
    controller.perPlayerConns = {}

    disconnectUiConns()
    destroyAllOverheads()

    if controller.gui then
        pcall(function() controller.gui:Destroy() end)
    end

    controller.gui = nil
    controller.frame = nil
    controller.list = nil
    controller.titleLabel = nil
    controller.closeBtn = nil
    controller.currentBlackenedLabel = nil
    controller.friendsList = nil
    controller.friendsTitle = nil
    controller.historyList = nil
    controller.historyTitle = nil
    controller.container = nil
end

controller.Cleanup = disconnectAll

--========================
-- HELPERS
--========================
local function getBestName(plr)
    local dn = ""
    pcall(function() dn = plr.DisplayName end)
    if type(dn) == "string" and dn ~= "" then
        return dn
    end
    return plr.Name
end

local function playerHasBlackened(plr)
    return plr:FindFirstChild(TARGET_NAME) ~= nil
end

local function getBackpack(plr)
    return plr:FindFirstChildOfClass("Backpack") or plr:FindFirstChild("Backpack")
end

-- Return a comma‑separated string of all live tools/hopperbins in backpack + character.
local function getLiveItemsString(plr)
    local items = {}

    local backpack = getBackpack(plr)
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") or child:IsA("HopperBin") then
                table.insert(items, child.Name)
            end
        end
    end

    local char = plr.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") then
                table.insert(items, child.Name)
            end
        end
    end

    table.sort(items, function(a, b) return a:lower() < b:lower() end)
    if #items == 0 then
        return "(empty)"
    end
    return table.concat(items, ", ")
end

-- Determine if the player currently has one of the "dangerous" items. If so,
-- their overhead box will be red.
local DANGEROUS_ITEMS = {
    Knife = true,
    ["Toy Hammer"] = true,
    ["Spiky Bat"] = true,
    Gloves = true,
    ["C4 Explosive"] = true,
    ["Explosive Collar"] = true,
    Gun = true,
    ["C9 Poison"] = true,
}

local function hasDangerousItem(plr)
    local backpack = getBackpack(plr)
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if (child:IsA("Tool") or child:IsA("HopperBin")) and DANGEROUS_ITEMS[child.Name] then
                return true
            end
        end
    end
    local char = plr.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") and DANGEROUS_ITEMS[child.Name] then
                return true
            end
        end
    end
    return false
end

-- Convert a minute count (such as GameTime) into a human‑readable time. The game
-- value increments continuously and may exceed a 24‑hour day. We reduce it into a
-- 24‑hour range (0–23h) and return a string like "11:00 AM". If minutes is nil
-- or not a number, returns "??".
local function minutesToTimeString(minutes)
    if type(minutes) ~= "number" then
        return "??"
    end
    -- Ensure non‑negative integer
    local total = math.floor(minutes)
    if total < 0 then total = 0 end

    -- Reduce into a single 24‑hour day
    local m = total % (24 * 60) -- 1440
    local hours24 = math.floor(m / 60)
    local minutePart = m % 60

    -- Compute 12‑hour time with AM/PM suffix
    local suffix = "AM"
    local hour12 = hours24
    if hours24 >= 12 then
        suffix = "PM"
        if hours24 > 12 then
            hour12 = hours24 - 12
        elseif hours24 == 12 then
            hour12 = 12
        end
    else
        suffix = "AM"
        if hours24 == 0 then
            hour12 = 12
        else
            hour12 = hours24
        end
    end

    return string.format("%d:%02d %s", hour12, minutePart, suffix)
end

local function getPlayerGuiSafe()
    local ok, pg = pcall(function()
        return LOCAL_PLAYER:WaitForChild("PlayerGui", 10)
    end)
    if ok then return pg end
    return nil
end

local function getGuiContainer()
    -- Prefer CoreGui so PlayerGui wipes won't delete it
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then
        return core
    end
    -- Fallback: PlayerGui
    return getPlayerGuiSafe()
end

local function isGuiAlive()
    if not controller.gui or controller.gui.Parent == nil then return false end
    if not controller.frame or controller.frame.Parent == nil then return false end
    if not controller.list or controller.list.Parent == nil then return false end
    if not controller.friendsList or controller.friendsList.Parent == nil then return false end
    if not controller.historyList or controller.historyList.Parent == nil then return false end
    return true
end

--========================
-- CURRENT BLACKENED (FROZEN SNAPSHOT) - PERSISTED
--========================
local function renderCurrentBlackenedLine()
    if not controller.currentBlackenedLabel then return end

    if PERSIST.lastBlackenedName == "None" or PERSIST.lastBlackenedUserId == 0 then
        controller.currentBlackenedLabel.Text = "Current Blackened: None"
        return
    end

    controller.currentBlackenedLabel.Text =
        ("Current Blackened: %s — %s"):format(PERSIST.lastBlackenedName, PERSIST.lastBlackenedItemsSnapshot or "(unknown)")
end

--========================
-- DEATH TRACKING (FOR HISTORY)
--========================
local function pruneRecentDeaths()
    local now = os.clock()
    local keep = {}
    for _, d in ipairs(controller.recentDeaths) do
        if (now - d.t) <= (DEATH_MATCH_WINDOW + 2.0) then
            table.insert(keep, d)
        end
    end
    controller.recentDeaths = keep
end

local function recordDeath(plr)
    if not plr or not plr:IsA("Player") then return end
    local uid = plr.UserId
    local now = os.clock()

    local last = controller.lastDeathTimeByUserId[uid]
    if last and (now - last) < DEATH_RECORD_COOLDOWN then
        return
    end
    controller.lastDeathTimeByUserId[uid] = now

    table.insert(controller.recentDeaths, {
        t = now,
        userId = uid,
        name = getBestName(plr),
    })
    pruneRecentDeaths()
end

local function hookHumanoidDeath(plr)
    local char = plr.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    table.insert(controller.perPlayerConns[plr], hum.Died:Connect(function()
        recordDeath(plr)
    end))
end

--========================
-- HISTORY
--========================
-- Retrieve the in‑game GameTime value from ReplicatedStorage. If the value is present
-- and is a ValueBase (NumberValue, IntValue, etc.), return its numeric value;
-- otherwise return nil.
local function getGameTimeMinutes()
    local ok, rs = pcall(function() return game:GetService("ReplicatedStorage") end)
    if not ok or not rs then
        return nil
    end
    local ok2, val = pcall(function()
        return rs:FindFirstChild("GameTime")
    end)
    if not ok2 or not val then
        return nil
    end
    -- Ensure it's a ValueBase instance that has a Value property
    if val and val:IsA("ValueBase") then
        local success, minutes = pcall(function()
            return val.Value
        end)
        if success and type(minutes) == "number" then
            return minutes
        end
    end
    return nil
end

--[[---------------------------------------------------------------------
    NEW: getVictimsAtDetection

    This helper scans all players in the server and checks their character
    models (or workspace models named after them) for a child named "Corpse".
    Any player whose model contains a "Corpse" is considered a victim at the
    moment the blackened player is detected.  Victim names are sorted
    alphabetically and returned.
]]-----------------------------------------------------------------------
local function getVictimsAtDetection(blackenedUserId)
    local victims = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.UserId ~= blackenedUserId then
            local char = plr.Character
            if not char then
                local ok, found = pcall(function()
                    return workspace:FindFirstChild(plr.Name)
                end)
                if ok then
                    char = found
                end
            end
            if char and char:FindFirstChild("Corpse") then
                table.insert(victims, getBestName(plr))
            end
        end
    end
    table.sort(victims, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
    return victims
end

local function addHistoryEntry(blackenedPlr)
    if not blackenedPlr or not blackenedPlr:IsA("Player") then return end

    -- No longer rely on recent Humanoid deaths.  Instead scan for victims now.
    local bUid = blackenedPlr.UserId

    local deaths = getVictimsAtDetection(bUid)

    -- Capture the current GameTime value from ReplicatedStorage at the moment of detection.
    local gameTimeMinutes = getGameTimeMinutes()

    local entry = {
        t = os.time(), -- keep server timestamp in case GameTime is unavailable
        blackenedName = getBestName(blackenedPlr),
        blackenedUserId = bUid,
        itemsSnapshot = PERSIST.lastBlackenedItemsSnapshot or "(unknown)",
        deaths = deaths,
        gameTimeMinutes = gameTimeMinutes,
    }

    table.insert(PERSIST.history, 1, entry)
    while #PERSIST.history > HISTORY_MAX do
        table.remove(PERSIST.history)
    end
end

local function snapshotBlackened(plr)
    if not plr or not plr:IsA("Player") then return end

    local uid = plr.UserId
    local now = os.clock()

    local lastT = PERSIST.lastSnapshotTimeByUserId[uid]
    if lastT and (now - lastT) < SNAPSHOT_COOLDOWN then
        return
    end
    PERSIST.lastSnapshotTimeByUserId[uid] = now

    task.spawn(function()
        task.wait(SNAPSHOT_DELAY)

        PERSIST.lastBlackenedUserId = uid
        PERSIST.lastBlackenedName = getBestName(plr)
        PERSIST.lastBlackenedItemsSnapshot = getLiveItemsString(plr)

        addHistoryEntry(plr)
        renderCurrentBlackenedLine()
    end)
end

--========================
-- OVERHEAD ITEMS GUI
--========================
local function getHeadOrRoot(char)
    if not char then return nil end
    local head = char:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then return hrp end
    return nil
end

local function ensureOverheadGui(plr)
    local char = plr.Character
    if not char then return nil end
    local adornee = getHeadOrRoot(char)
    if not adornee then return nil end

    local existing = controller.overheadByPlayer[plr]
    if existing and existing.Parent == adornee then
        return existing
    end

    if existing then
        pcall(function() existing:Destroy() end)
    end

    local bb = Instance.new("BillboardGui")
    bb.Name = HEAD_GUI_NAME
    bb.AlwaysOnTop = true
    bb.Size = UDim2.new(0, 260, 0, 50)
    bb.StudsOffset = Vector3.new(0, 2.8, 0)
    -- Do not limit distance; we handle out‑of‑range behavior in updateOverheadText
    bb.MaxDistance = 0
    bb.Parent = adornee

    local text = Instance.new("TextLabel")
    text.Name = "Items"
    text.BackgroundTransparency = 0.35
    text.BorderSizePixel = 0
    text.Size = UDim2.new(1, 0, 1, 0)
    text.Font = Enum.Font.SourceSansBold
    text.TextSize = 30
    text.TextWrapped = true
    text.TextColor3 = Color3.fromRGB(0, 0, 0)
    text.Text = ""
    -- Default background color is white; updateOverheadText may override it.
    text.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    text.Parent = bb

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = text

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.55
    stroke.Parent = text

    controller.overheadByPlayer[plr] = bb
    return bb
end

local function updateOverheadText(plr)
    local uid = plr.UserId
    local now = os.clock()
    local last = controller.overheadLastUpdate[uid]
    if last and (now - last) < OVERHEAD_UPDATE_THROTTLE then
        return
    end
    controller.overheadLastUpdate[uid] = now

    local bb = ensureOverheadGui(plr)
    if not bb then return end
    local label = bb:FindFirstChild("Items")
    if not label or not label:IsA("TextLabel") then return end
    -- Determine if the player is out of range from the local camera. If so,
    -- display a diamond indicator (white or red) instead of the item list.
    local camera = workspace.CurrentCamera
    local outOfRange = false
    if camera then
        local head = nil
        local char = plr.Character
        if char then
            head = getHeadOrRoot(char)
        end
        if head then
            local dist = (camera.CFrame.Position - head.Position).Magnitude
            if dist > OVERHEAD_OUT_OF_RANGE_DISTANCE then
                outOfRange = true
            end
        end
    end

    if outOfRange then
        -- When out of range, show a diamond. Use a red diamond when they have a
        -- dangerous item, otherwise white. Hide the label background.
        local dangerous = hasDangerousItem(plr)
        label.Text = "◆" -- diamond character
        label.TextColor3 = dangerous and Color3.fromRGB(255, 0, 0) or Color3.fromRGB(255, 255, 255)
        label.BackgroundTransparency = 1
    else
        -- In range: show the list of items with colored background. Reset text
        -- color to black and background transparency.
        label.Text = getLiveItemsString(plr)
        label.TextColor3 = Color3.fromRGB(0, 0, 0)
        label.BackgroundTransparency = 0.35
        -- Adjust the background color based on the presence of dangerous items.
        if hasDangerousItem(plr) then
            label.BackgroundColor3 = Color3.fromRGB(255, 0, 0) -- red for dangerous items
        else
            label.BackgroundColor3 = Color3.fromRGB(255, 255, 255) -- white otherwise
        end
    end
end

local function destroyOverhead(plr)
    local g = controller.overheadByPlayer[plr]
    if g then pcall(function() g:Destroy() end) end
    controller.overheadByPlayer[plr] = nil

    local conns = controller.overheadConnsByPlayer[plr]
    if conns then disconnectList(conns) end
    controller.overheadConnsByPlayer[plr] = nil
end

local function watchOverhead(plr)
    destroyOverhead(plr)
    controller.overheadConnsByPlayer[plr] = {}

    local function oconnect(sig, fn)
        local c = sig:Connect(fn)
        table.insert(controller.overheadConnsByPlayer[plr], c)
        return c
    end

    oconnect(plr.CharacterAdded, function()
        task.wait(0.1)
        updateOverheadText(plr)

        local char = plr.Character
        if char then
            oconnect(char.ChildAdded, function(ch)
                if ch:IsA("Tool") then updateOverheadText(plr) end
            end)
            oconnect(char.ChildRemoved, function(ch)
                if ch:IsA("Tool") then updateOverheadText(plr) end
            end)
        end
    end)

    oconnect(plr.CharacterRemoving, function()
        destroyOverhead(plr)
    end)

    local backpack = getBackpack(plr)
    if backpack then
        oconnect(backpack.ChildAdded, function(ch)
            if ch:IsA("Tool") or ch:IsA("HopperBin") then updateOverheadText(plr) end
        end)
        oconnect(backpack.ChildRemoved, function(ch)
            if ch:IsA("Tool") or ch:IsA("HopperBin") then updateOverheadText(plr) end
        end)
    end

    oconnect(plr.ChildAdded, function(child)
        if child and child.Name == "Backpack" then
            oconnect(child.ChildAdded, function(ch)
                if ch:IsA("Tool") or ch:IsA("HopperBin") then updateOverheadText(plr) end
            end)
            oconnect(child.ChildRemoved, function(ch)
                if ch:IsA("Tool") or ch:IsA("HopperBin") then updateOverheadText(plr) end
            end)
            updateOverheadText(plr)
        end
    end)

    task.spawn(function()
        task.wait(0.2)
        updateOverheadText(plr)
    end)
end

--========================
-- UI
--========================
local function makeScrollingFrame(parent, pos, size)
    local sf = Instance.new("ScrollingFrame")
    sf.BackgroundTransparency = 1
    sf.Position = pos
    sf.Size = size
    sf.BorderSizePixel = 0
    sf.ScrollBarThickness = 8
    sf.CanvasSize = UDim2.new(0, 0, 0, 0)
    sf.ZIndex = 11
    sf.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 8)
    layout.Parent = sf

    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        sf.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 10)
    end)

    return sf
end

local function makeGui()
    local container = getGuiContainer()
    if not container then return nil end
    controller.container = container

    local existing = container:FindFirstChild(GUI_NAME)
    if existing then pcall(function() existing:Destroy() end) end

    local screen = Instance.new("ScreenGui")
    screen.Name = GUI_NAME
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.DisplayOrder = 999999
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screen.Parent = container

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 560, 0, 670) -- bigger to fit history
    frame.Position = UDim2.new(0, 20, 0, 140)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    frame.BackgroundTransparency = 0.12
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.ZIndex = 10
    frame.Visible = controller.isOpen
    frame.Parent = screen

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.6
    stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 12, 0, 10)
    title.Size = UDim2.new(1, -90, 0, 24)
    title.Font = Enum.Font.SourceSansBold
    title.TextSize = 22
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.Text = "Blackened / Backpack Scanner"
    title.ZIndex = 11
    title.Parent = frame

    local closeBtn = Instance.new("TextButton")
    closeBtn.Position = UDim2.new(1, -36, 0, 10)
    closeBtn.Size = UDim2.new(0, 24, 0, 24)
    closeBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    closeBtn.BorderSizePixel = 0
    closeBtn.Font = Enum.Font.SourceSansBold
    closeBtn.TextSize = 18
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Text = "×"
    closeBtn.ZIndex = 12
    closeBtn.Parent = frame

    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0, 8)
    closeCorner.Parent = closeBtn

    local hint = Instance.new("TextLabel")
    hint.BackgroundTransparency = 1
    hint.Position = UDim2.new(0, 12, 0, 34)
    hint.Size = UDim2.new(1, -24, 0, 18)
    hint.Font = Enum.Font.SourceSans
    hint.TextSize = 16
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextColor3 = Color3.fromRGB(180, 180, 180)
    hint.Text = "P toggle • Drag • K board"
    hint.ZIndex = 11
    hint.Parent = frame

    local current = Instance.new("TextLabel")
    current.BackgroundTransparency = 1
    current.Position = UDim2.new(0, 12, 0, 54)
    current.Size = UDim2.new(1, -24, 0, 20)
    current.Font = Enum.Font.SourceSansBold
    current.TextSize = 18
    current.TextXAlignment = Enum.TextXAlignment.Left
    current.TextColor3 = Color3.fromRGB(255, 230, 160)
    current.ZIndex = 11
    current.Parent = frame

    local header = Instance.new("TextLabel")
    header.BackgroundTransparency = 1
    header.Position = UDim2.new(0, 12, 0, 78)
    header.Size = UDim2.new(1, -24, 0, 18)
    header.Font = Enum.Font.SourceSansBold
    header.TextSize = 16
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.TextColor3 = Color3.fromRGB(210, 210, 210)
    header.Text = "Player — Current Items (Blackened players are tagged)"
    header.ZIndex = 11
    header.Parent = frame

    local list = makeScrollingFrame(frame, UDim2.new(0, 12, 0, 100), UDim2.new(1, -24, 0, 260))

    local divider = Instance.new("Frame")
    divider.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
    divider.BackgroundTransparency = 0.7
    divider.BorderSizePixel = 0
    divider.Position = UDim2.new(0, 12, 0, 370)
    divider.Size = UDim2.new(1, -24, 0, 1)
    divider.ZIndex = 11
    divider.Parent = frame

    local friendsTitle = Instance.new("TextLabel")
    friendsTitle.BackgroundTransparency = 1
    friendsTitle.Position = UDim2.new(0, 12, 0, 380)
    friendsTitle.Size = UDim2.new(1, -24, 0, 18)
    friendsTitle.Font = Enum.Font.SourceSansBold
    friendsTitle.TextSize = 16
    friendsTitle.TextXAlignment = Enum.TextXAlignment.Left
    friendsTitle.TextColor3 = Color3.fromRGB(210, 210, 210)
    friendsTitle.Text = "Friends in server (connections)"
    friendsTitle.ZIndex = 11
    friendsTitle.Parent = frame

    local friendsList = makeScrollingFrame(frame, UDim2.new(0, 12, 0, 402), UDim2.new(1, -24, 0, 110))

    local divider2 = Instance.new("Frame")
    divider2.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
    divider2.BackgroundTransparency = 0.7
    divider2.BorderSizePixel = 0
    divider2.Position = UDim2.new(0, 12, 0, 520)
    divider2.Size = UDim2.new(1, -24, 0, 1)
    divider2.ZIndex = 11
    divider2.Parent = frame

    local historyTitle = Instance.new("TextLabel")
    historyTitle.BackgroundTransparency = 1
    historyTitle.Position = UDim2.new(0, 12, 0, 530)
    historyTitle.Size = UDim2.new(1, -24, 0, 18)
    historyTitle.Font = Enum.Font.SourceSansBold
    historyTitle.TextSize = 16
    historyTitle.TextXAlignment = Enum.TextXAlignment.Left
    historyTitle.TextColor3 = Color3.fromRGB(210, 210, 210)
    historyTitle.Text = "History (Blackened + deaths at detection)"
    historyTitle.ZIndex = 11
    historyTitle.Parent = frame

    local historyList = makeScrollingFrame(frame, UDim2.new(0, 12, 0, 552), UDim2.new(1, -24, 0, 106))

    -- Dragging
    local dragging = false
    local dragStart, startPos
    local function updateDrag(input)
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end

    connect(frame.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position

            local endedConn
            endedConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if endedConn then endedConn:Disconnect() end
                end
            end)
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            updateDrag(input)
        end
    end)

    return screen, frame, list, closeBtn, title, current, friendsList, friendsTitle, historyList, historyTitle
end

local function hookGuiButtons()
    disconnectUiConns()
    if controller.closeBtn then
        table.insert(controller.uiConns, controller.closeBtn.MouseButton1Click:Connect(function()
            controller.isOpen = false
            if controller.frame then controller.frame.Visible = false end
        end))
    end
end

local function ensureGui()
    if isGuiAlive() then
        if controller.frame then controller.frame.Visible = controller.isOpen end
        return true
    end

    local built = { makeGui() }
    if not built[1] then return false end

    controller.gui = built[1]
    controller.frame = built[2]
    controller.list = built[3]
    controller.closeBtn = built[4]
    controller.titleLabel = built[5]
    controller.currentBlackenedLabel = built[6]
    controller.friendsList = built[7]
    controller.friendsTitle = built[8]
    controller.historyList = built[9]
    controller.historyTitle = built[10]

    hookGuiButtons()
    renderCurrentBlackenedLine()

    if controller.frame then controller.frame.Visible = controller.isOpen end
    return true
end

ensureGui()

--========================
-- UI BUILDERS
--========================
local state = {} -- [Player] = { hasBlackened = bool, items = string }

local function clearTextChildren(sf)
    if not sf then return end
    for _, child in ipairs(sf:GetChildren()) do
        if child:IsA("TextLabel") then child:Destroy() end
    end
end

local function rebuildHistoryUI()
    if not ensureGui() then return end
    clearTextChildren(controller.historyList)

    if not PERSIST.history or #PERSIST.history == 0 then
        local row = Instance.new("TextLabel")
        row.BackgroundTransparency = 1
        row.Size = UDim2.new(1, -4, 0, 22)
        row.Font = Enum.Font.SourceSansItalic
        row.TextSize = 18
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextColor3 = Color3.fromRGB(180, 180, 180)
        row.ZIndex = 11
        row.Text = "No history yet."
        row.Parent = controller.historyList
        return
    end

    for _, e in ipairs(PERSIST.history) do
        -- Determine timestamp to display. If a GameTime minutes value is present,
        -- convert it to a human readable time; otherwise fall back to real time.
        local ts = "??"
        if type(e.gameTimeMinutes) == "number" then
            ts = minutesToTimeString(e.gameTimeMinutes)
        else
            pcall(function()
                ts = os.date("%H:%M:%S", e.t or os.time())
            end)
        end

        local deathsText = ""
        if e.deaths and #e.deaths > 0 then
            deathsText = (" | Deaths: %s"):format(table.concat(e.deaths, ", "))
        else
            deathsText = " | Deaths: (none)"
        end

        local row = Instance.new("TextLabel")
        row.BackgroundTransparency = 1
        row.Size = UDim2.new(1, -4, 0, 0)
        row.AutomaticSize = Enum.AutomaticSize.Y
        row.Font = Enum.Font.SourceSans
        row.TextSize = 18
        row.TextWrapped = true
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextYAlignment = Enum.TextYAlignment.Top
        row.TextColor3 = Color3.fromRGB(235, 235, 235)
        row.ZIndex = 11

        row.Text = ("• [%s] Blackened: %s — %s%s"):format(
            ts,
            tostring(e.blackenedName or "Unknown"),
            tostring(e.itemsSnapshot or "(unknown)"),
            deathsText
        )

        row.Parent = controller.historyList
    end
end

local function rebuildFriendsUI()
    if not ensureGui() then return end
    clearTextChildren(controller.friendsList)

    local plrs = Players:GetPlayers()
    table.sort(plrs, function(a, b) return getBestName(a):lower() < getBestName(b):lower() end)

    local pairs = {}
    for i = 1, #plrs do
        for j = i + 1, #plrs do
            local a, b = plrs[i], plrs[j]
            local ok, areFriends = pcall(function()
                return a:IsFriendsWith(b.UserId)
            end)
            if ok and areFriends then
                table.insert(pairs, {a = a, b = b})
            end
        end
    end

    if #pairs == 0 then
        local row = Instance.new("TextLabel")
        row.BackgroundTransparency = 1
        row.Size = UDim2.new(1, -4, 0, 22)
        row.Font = Enum.Font.SourceSansItalic
        row.TextSize = 18
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextColor3 = Color3.fromRGB(180, 180, 180)
        row.ZIndex = 11
        row.Text = "No friend connections found (or blocked by permissions)."
        row.Parent = controller.friendsList
        return
    end

    for _, pair in ipairs(pairs) do
        local row = Instance.new("TextLabel")
        row.BackgroundTransparency = 1
        row.Size = UDim2.new(1, -4, 0, 0)
        row.AutomaticSize = Enum.AutomaticSize.Y
        row.Font = Enum.Font.SourceSans
        row.TextSize = 18
        row.TextWrapped = true
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextYAlignment = Enum.TextYAlignment.Top
        row.TextColor3 = Color3.fromRGB(235, 235, 235)
        row.ZIndex = 11
        row.Text = ("• %s ↔ %s"):format(getBestName(pair.a), getBestName(pair.b))
        row.Parent = controller.friendsList
    end
end

local function rebuildPlayersUI()
    if not ensureGui() then return end
    clearTextChildren(controller.list)

    local players = Players:GetPlayers()
    table.sort(players, function(a, b) return getBestName(a):lower() < getBestName(b):lower() end)

    local blackenedCount = 0
    for _, plr in ipairs(players) do
        local s = state[plr]
        if not s then
            s = { hasBlackened = playerHasBlackened(plr), items = getLiveItemsString(plr) }
            state[plr] = s
        end

        if s.hasBlackened then blackenedCount += 1 end

        local row = Instance.new("TextLabel")
        row.BackgroundTransparency = 1
        row.Size = UDim2.new(1, -4, 0, 0)
        row.AutomaticSize = Enum.AutomaticSize.Y
        row.Font = Enum.Font.SourceSans
        row.TextSize = 18
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextYAlignment = Enum.TextYAlignment.Top
        row.TextWrapped = true
        row.TextColor3 = Color3.fromRGB(235, 235, 235)
        row.ZIndex = 11

        local tag = s.hasBlackened and "[Blackened] " or ""
        row.Text = ("• %s%s — %s"):format(tag, getBestName(plr), s.items)
        row.Parent = controller.list
    end

    if controller.titleLabel then
        controller.titleLabel.Text = ("Blackened / Backpack Scanner  (Blackened: %d)"):format(blackenedCount)
    end
end

local function rebuildAllUI()
    rebuildPlayersUI()
    rebuildFriendsUI()
    rebuildHistoryUI()
    renderCurrentBlackenedLine()
end

--========================
-- PLAYER BOARD UI
--========================
-- Create the player board GUI if it doesn't exist. Returns true on success.
local function ensurePlayerBoard()
    -- Only create if the main ScreenGui exists
    if not controller.gui then return false end
    if controller.playerBoardFrame then return true end

    -- Create a semi‑transparent frame to hold the player board
    local frame = Instance.new("Frame")
    frame.Name = "PlayerBoard"
    frame.Size = UDim2.new(0, 350, 0, 480)
    -- Position it to the right of the main panel by default
    frame.Position = UDim2.new(0, 600, 0, 140)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0
    frame.Visible = false
    frame.ZIndex = 20
    frame.Parent = controller.gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.6
    stroke.Parent = frame

    -- Title label
    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 12, 0, 10)
    title.Size = UDim2.new(1, -24, 0, 24)
    title.Font = Enum.Font.SourceSansBold
    title.TextSize = 20
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Players"
    title.ZIndex = 21
    title.Parent = frame

    -- Scrolling list for players
    local scroll = Instance.new("ScrollingFrame")
    scroll.BackgroundTransparency = 1
    scroll.Position = UDim2.new(0, 10, 0, 40)
    scroll.Size = UDim2.new(1, -20, 1, -50)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 8
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.ZIndex = 21
    scroll.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 8)
    layout.Parent = scroll

    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        scroll.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 10)
    end)

    controller.playerBoardFrame = frame
    controller.playerBoardScroll = scroll
    controller.playerBoardEntries = {}
    controller.playerBoardSelections = {}

    return true
end

-- Clear existing entries from the player board
local function clearPlayerBoard()
    if controller.playerBoardScroll then
        for _, child in ipairs(controller.playerBoardScroll:GetChildren()) do
            if child:IsA("Frame") then
                child:Destroy()
            end
        end
    end
    controller.playerBoardEntries = {}
end

-- Update visibility of the cross overlay for a given player
local function updatePlayerSelectionVisual(plr)
    local entry = controller.playerBoardEntries[plr]
    if entry and entry.cross then
        entry.cross.Visible = controller.playerBoardSelections[plr] and true or false
    end
end

-- Toggle selection (cross overlay) for the given player
local function togglePlayerSelection(plr)
    local current = controller.playerBoardSelections[plr]
    controller.playerBoardSelections[plr] = not current
    updatePlayerSelectionVisual(plr)
end

-- Build the player board entries list. Only call when the board is open.
local function buildPlayerBoard()
    if not ensurePlayerBoard() then return end
    clearPlayerBoard()
    local plrs = Players:GetPlayers()
    -- Sort players by display name
    table.sort(plrs, function(a, b) return getBestName(a):lower() < getBestName(b):lower() end)
    for _, plr in ipairs(plrs) do
        -- Entry frame
        local entryFrame = Instance.new("Frame")
        entryFrame.BackgroundTransparency = 1
        entryFrame.Size = UDim2.new(1, 0, 0, 60)
        entryFrame.LayoutOrder = _
        entryFrame.ZIndex = 22
        entryFrame.Parent = controller.playerBoardScroll

        -- Avatar image button
        local thumbSize = Enum.ThumbnailSize.Size100x100
        local thumbType = Enum.ThumbnailType.HeadShot
        local thumbUrl = nil
        local ok, url, isReady
        ok, url, isReady = pcall(function()
            return Players:GetUserThumbnailAsync(plr.UserId, thumbType, thumbSize)
        end)
        if ok and url then
            thumbUrl = url
        else
            thumbUrl = ""
        end
        local img = Instance.new("ImageButton")
        img.Size = UDim2.new(0, 48, 0, 48)
        img.Position = UDim2.new(0, 0, 0, 6)
        img.Image = thumbUrl
        img.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
        img.BorderSizePixel = 0
        img.ZIndex = 23
        img.Parent = entryFrame

        -- Cross overlay
        local cross = Instance.new("TextLabel")
        cross.Size = UDim2.new(1, 0, 1, 0)
        cross.Position = UDim2.new(0, 0, 0, 0)
        cross.BackgroundTransparency = 1
        cross.Text = "✖"
        cross.TextColor3 = Color3.fromRGB(255, 0, 0)
        cross.TextScaled = true
        cross.Visible = controller.playerBoardSelections[plr] and true or false
        cross.ZIndex = 24
        cross.Parent = img

        -- Name label
        local nameLabel = Instance.new("TextLabel")
        nameLabel.BackgroundTransparency = 1
        nameLabel.Position = UDim2.new(0, 58, 0, 18)
        nameLabel.Size = UDim2.new(1, -58, 0, 20)
        nameLabel.Font = Enum.Font.SourceSans
        nameLabel.TextSize = 18
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.TextYAlignment = Enum.TextYAlignment.Center
        nameLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
        nameLabel.Text = getBestName(plr)
        nameLabel.ZIndex = 23
        nameLabel.Parent = entryFrame

        -- Store entry data
        controller.playerBoardEntries[plr] = {frame = entryFrame, button = img, cross = cross, name = nameLabel}

        -- Click handler to toggle cross overlay
        img.MouseButton1Click:Connect(function()
            togglePlayerSelection(plr)
        end)
    end
end

local function setState(plr, hasIt, itemsStr)
    local s = state[plr]
    if not s then
        s = { hasBlackened = false, items = "(unknown)" }
        state[plr] = s
    end

    local changed = false
    local oldHas = s.hasBlackened

    if typeof(hasIt) == "boolean" and s.hasBlackened ~= hasIt then
        s.hasBlackened = hasIt
        changed = true
        if (oldHas == false) and (hasIt == true) then
            snapshotBlackened(plr)
        end
    end

    if typeof(itemsStr) == "string" and s.items ~= itemsStr then
        s.items = itemsStr
        changed = true
    end

    if changed then
        rebuildAllUI()
    end
end

--========================
-- WATCHERS
--========================
local function watchBackpack(plr, backpack)
    local function updateItems()
        setState(plr, nil, getLiveItemsString(plr))
        updateOverheadText(plr)
    end

    updateItems()

    table.insert(controller.perPlayerConns[plr], backpack.ChildAdded:Connect(function(ch)
        if ch:IsA("Tool") or ch:IsA("HopperBin") then updateItems() end
    end))
    table.insert(controller.perPlayerConns[plr], backpack.ChildRemoved:Connect(function(ch)
        if ch:IsA("Tool") or ch:IsA("HopperBin") then updateItems() end
    end))
end

local function watchPlayer(plr)
    if controller.perPlayerConns[plr] then return end
    controller.perPlayerConns[plr] = {}

    local function pconnect(sig, fn)
        local c = sig:Connect(fn)
        table.insert(controller.perPlayerConns[plr], c)
        return c
    end

    watchOverhead(plr)

    local hb = playerHasBlackened(plr)
    setState(plr, hb, getLiveItemsString(plr))

    if hb and PERSIST.lastBlackenedUserId == 0 then
        snapshotBlackened(plr)
    end

    -- Death hook on current character (and future respawns)
    pconnect(plr.CharacterAdded, function()
        task.wait(0.1)
        updateOverheadText(plr)
        setState(plr, nil, getLiveItemsString(plr))
        hookHumanoidDeath(plr)
    end)

    task.spawn(function()
        task.wait(0.15)
        hookHumanoidDeath(plr)
    end)

    pconnect(plr.ChildAdded, function(child)
        if child and child.Name == TARGET_NAME then
            snapshotBlackened(plr)
            setState(plr, true, nil)
        elseif child and child.Name == "Backpack" then
            watchBackpack(plr, child)
            updateOverheadText(plr)
        end
    end)

    pconnect(plr.ChildRemoved, function(child)
        if child and child.Name == TARGET_NAME then
            setState(plr, playerHasBlackened(plr), nil)
        elseif child and child.Name == "Backpack" then
            setState(plr, nil, "(no backpack)")
            updateOverheadText(plr)
        end
    end)

    local backpack = getBackpack(plr)
    if backpack then
        watchBackpack(plr, backpack)
    end

    pconnect(plr:GetPropertyChangedSignal("DisplayName"), function()
        rebuildAllUI()
        -- If the player board is open, rebuild it to reflect name change
        if controller.playerBoardOpen then
            buildPlayerBoard()
        end
    end)
end

local function unwatchPlayer(plr)
    local list = controller.perPlayerConns[plr]
    if list then disconnectList(list) end
    controller.perPlayerConns[plr] = nil
    state[plr] = nil

    destroyOverhead(plr)
    rebuildAllUI()
end

for _, plr in ipairs(Players:GetPlayers()) do
    watchPlayer(plr)
end
rebuildAllUI()

connect(Players.PlayerAdded, function(plr)
    watchPlayer(plr)
    rebuildAllUI()

    -- Rebuild player board if it is open
    if controller.playerBoardOpen then
        buildPlayerBoard()
    end
end)

connect(Players.PlayerRemoving, function(plr)
    unwatchPlayer(plr)
    rebuildAllUI()

    -- Remove entry and rebuild the player board if open
    if controller.playerBoardOpen then
        buildPlayerBoard()
    end
end)

--========================
-- TOGGLE KEY (OPEN/CLOSE like before)
--========================
connect(UserInputService.InputBegan, function(input, gp)
    if gp then return end
    -- Toggle main GUI with the designated key
    if input.KeyCode == TOGGLE_KEY then
        if not ensureGui() then return end
        controller.isOpen = not controller.isOpen
        if controller.frame then
            controller.frame.Visible = controller.isOpen
        end
        -- When closing the main GUI, also hide the player board
        if not controller.isOpen then
            controller.playerBoardOpen = false
            if controller.playerBoardFrame then
                controller.playerBoardFrame.Visible = false
            end
        end
        return
    end
    -- Toggle the player board when the main GUI is open
    if input.KeyCode == PLAYER_BOARD_KEY then
        -- Only allow toggling when the main GUI is visible
        if controller.isOpen then
            controller.playerBoardOpen = not controller.playerBoardOpen
            if controller.playerBoardOpen then
                -- Build and show the board
                if ensurePlayerBoard() then
                    buildPlayerBoard()
                    controller.playerBoardFrame.Visible = true
                end
            else
                -- Hide the board
                if controller.playerBoardFrame then
                    controller.playerBoardFrame.Visible = false
                end
            end
        end
    end
end)

--========================
-- WATCHDOGS
--========================
local accumScan = 0
local accumGui = 0

connect(RunService.Heartbeat, function(dt)
    accumScan += dt
    accumGui += dt

    -- GUI watchdog: rebuild if deleted, WITHOUT losing snapshot/history
    if accumGui >= GUI_WATCHDOG_INTERVAL then
        accumGui = 0
        if not isGuiAlive() then
            ensureGui()
            rebuildAllUI()
        else
            if controller.frame then
                controller.frame.Visible = controller.isOpen
            end
        end
    end

    -- state scan
    if accumScan < SCAN_INTERVAL then return end
    accumScan = 0

    pruneRecentDeaths()

    local changed = false
    for _, plr in ipairs(Players:GetPlayers()) do
        local s = state[plr]
        local hb = playerHasBlackened(plr)
        local it = getLiveItemsString(plr)

        if not s then
            state[plr] = { hasBlackened = hb, items = it }
            changed = true
            if hb and PERSIST.lastBlackenedUserId == 0 then
                snapshotBlackened(plr)
            end
        else
            if (s.hasBlackened == false) and (hb == true) then
                snapshotBlackened(plr)
            end
            if s.hasBlackened ~= hb or s.items ~= it then
                s.hasBlackened = hb
                s.items = it
                changed = true
            end
        end

        updateOverheadText(plr)
    end

    if changed then
        rebuildAllUI()
    else
        rebuildFriendsUI()
    end
end)

print("[BlackenedFinder] Loaded. CoreGui parent (fallback PlayerGui). P toggles open/close. History + deaths-at-detection enabled. Snapshot persists in _G.")