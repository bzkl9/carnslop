--============================================================
-- Blackened Trail Tracker + Leave Log + Notes + Blackened Says
--============================================================
-- LocalScript intended for StarterPlayerScripts
--
-- Features:
-- • Detects when a player gains the "Blackened" tag and creates
--   a numbered purple trail showing where they walked.
-- • Trail lasts up to TRAIL_DURATION
-- • Removed immediately if:
--      - Player loses the Blackened tag
--      - Player leaves the game
-- • Leave Log GUI toggles with L
-- • Leave Log GUI shows players who left + in-game time they left
-- • Names in leave log use DisplayName when available
-- • Separate Notes GUI opened/closed by button in Leave Log GUI
-- • Notes GUI is large and draggable
-- • Notes GUI stays open even if Leave Log GUI is closed
-- • Each note line gets a fixed in-game timestamp when first created
-- • Editing a line keeps the original timestamp
-- • Deleting a whole line removes that timestamp entry
-- • Separate Blackened Says GUI opened/closed by button in Leave Log GUI
-- • Captures ONLY what the current Blackened says
-- • Uses normal chat + legacy chat + bubble chat style capture
-- • Blackened chat log resets when a NEW Blackened appears
-- • Blackened lines are timestamped with in-game time
--============================================================

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local ChatService = game:GetService("Chat")
local CoreGui = game:GetService("CoreGui")

local LOCAL_PLAYER = Players.LocalPlayer
if not LOCAL_PLAYER then return end

--========================
-- CONFIG
--========================
local TARGET_NAME = "Blackened"

local TRAIL_DURATION = 7 * 60
local DROP_INTERVAL = 0.5
local RAYCAST_DISTANCE = 50

local MARKER_SIZE = Vector3.new(1, 0.2, 1)
local MARKER_COLOR = Color3.fromRGB(130, 0, 130)

local TOGGLE_KEY = Enum.KeyCode.L
local GUI_NAME = "BlackenedTrailTrackerGui"

local LEAVE_LOG_MAX = 120
local BLACKENED_CHAT_MAX = 220

local GUI_WATCHDOG_INTERVAL = 1.0
local STATE_SCAN_INTERVAL = 0.45

local NOTES_PLACEHOLDER = "Type notes here. Each new line gets a fixed timestamp."

-- blackened chat capture tuning
local FILTER_SLASH_IN_CHAT = true
local FILTER_SLASH_IN_BUBBLES = false
local IGNORE_BUBBLE_ELLIPSIS = false
local GLOBAL_DEDUP_SECONDS = 6.0
local BUBBLE_DELAY_SECONDS = 0.12
local FORCE_BUBBLE_RANGE = true
local HUGE_DISTANCE = 9e9
local DEDUPE_BY_TEXT_ONLY = true
local BUBBLE_MAX_PARENT_DEPTH = 20
local BUBBLE_RETRY_PASSES = 3
local BUBBLE_RETRY_INTERVAL = 0.18

--========================
-- PERSISTENT STORAGE
--========================
_G.BlackenedTrailTrackerPersist = _G.BlackenedTrailTrackerPersist or {
	leaveLogs = {},

	noteLines = {}, -- {id=number, timeText=string, text=string}
	nextNoteId = 1,
	lastRenderedLines = {},

	mainGuiOpen = true,
	notesGuiOpen = false,
	blackenedChatGuiOpen = false,

	mainGuiPos = {xScale = 0, xOffset = 20, yScale = 0, yOffset = 140},
	notesGuiPos = {xScale = 0, xOffset = 700, yScale = 0, yOffset = 120},
	blackenedChatGuiPos = {xScale = 0, xOffset = 470, yScale = 0, yOffset = 140},

	currentBlackenedUserId = 0,
	currentBlackenedName = "None",

	blackenedChatOwnerUserId = 0,
	blackenedChatOwnerName = "None",
	blackenedChatEntries = {}, -- {timeText=string, text=string}
}

local PERSIST = _G.BlackenedTrailTrackerPersist

--========================
-- CLEANUP PREVIOUS RUN
--========================
if _G.BlackenedTrailTrackerController and type(_G.BlackenedTrailTrackerController.Cleanup) == "function" then
	pcall(function()
		_G.BlackenedTrailTrackerController.Cleanup()
	end)
end

--========================
-- STATE
--========================
local controller = {
	conns = {},
	perPlayerConns = {},

	activeTrails = {},

	gui = nil,

	mainFrame = nil,
	leaveList = nil,
	leaveTitle = nil,
	notesToggleButton = nil,
	blackenedChatToggleButton = nil,
	mainCloseBtn = nil,

	notesFrame = nil,
	notesBox = nil,
	notesCloseBtn = nil,

	blackenedChatFrame = nil,
	blackenedChatList = nil,
	blackenedChatTitle = nil,
	blackenedChatCloseBtn = nil,

	uiConns = {},

	isApplyingNotesText = false,

	mainGuiOpen = PERSIST.mainGuiOpen,
	notesGuiOpen = PERSIST.notesGuiOpen,
	blackenedChatGuiOpen = PERSIST.blackenedChatGuiOpen,

	blackenedSeen = {}, -- key -> {t=clock, pr=priority}
	blackenedBubbleHooked = setmetatable({}, { __mode = "k" }),
	blackenedLastTextByLabel = setmetatable({}, { __mode = "k" }),
	blackenedRetryTokenByLabel = setmetatable({}, { __mode = "k" }),

	playerBlackenedState = {}, -- [Player] = bool
}

_G.BlackenedTrailTrackerController = controller

--========================
-- CONNECTION HELPERS
--========================
local function disconnectList(list)
	if not list then return end
	for _, c in ipairs(list) do
		pcall(function()
			c:Disconnect()
		end)
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

local function cleanupTrails()
	for _, data in pairs(controller.activeTrails) do
		if data.connections then
			disconnectList(data.connections)
		end
		if data.parts then
			for _, p in ipairs(data.parts) do
				pcall(function() p:Destroy() end)
			end
		end
		if data.folder then
			pcall(function() data.folder:Destroy() end)
		end
	end
	controller.activeTrails = {}
end

local function disconnectAll()
	disconnectList(controller.conns)
	controller.conns = {}

	for _, list in pairs(controller.perPlayerConns) do
		disconnectList(list)
	end
	controller.perPlayerConns = {}

	disconnectUiConns()
	cleanupTrails()

	if controller.gui then
		pcall(function() controller.gui:Destroy() end)
	end

	controller.gui = nil
	controller.mainFrame = nil
	controller.leaveList = nil
	controller.leaveTitle = nil
	controller.notesToggleButton = nil
	controller.blackenedChatToggleButton = nil
	controller.mainCloseBtn = nil
	controller.notesFrame = nil
	controller.notesBox = nil
	controller.notesCloseBtn = nil
	controller.blackenedChatFrame = nil
	controller.blackenedChatList = nil
	controller.blackenedChatTitle = nil
	controller.blackenedChatCloseBtn = nil
	controller.isApplyingNotesText = false
end

controller.Cleanup = disconnectAll

--========================
-- HELPERS
--========================
local function getBestName(plr)
	local dn = ""
	pcall(function()
		dn = plr.DisplayName
	end)
	if type(dn) == "string" and dn ~= "" then
		return dn
	end
	return plr.Name
end

local function playerHasBlackened(plr)
	return plr and plr:FindFirstChild(TARGET_NAME) ~= nil
end

local function getHRP(plr)
	local char = plr.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart")
end

local function raycastFloor(char, origin)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Blacklist
	params.FilterDescendantsInstances = {char}

	local result = workspace:Raycast(origin, Vector3.new(0, -RAYCAST_DISTANCE, 0), params)
	if result then
		return result.Position + Vector3.new(0, 0.1, 0)
	end

	return origin - Vector3.new(0, 3, 0)
end

local function getPlayerGuiSafe()
	local ok, pg = pcall(function()
		return LOCAL_PLAYER:WaitForChild("PlayerGui", 10)
	end)
	if ok then return pg end
	return nil
end

local function getGuiContainer()
	local ok, core = pcall(function()
		return game:GetService("CoreGui")
	end)
	if ok and core then
		return core
	end
	return getPlayerGuiSafe()
end

local function makeUDim2FromPersist(posTbl, fallback)
	if type(posTbl) ~= "table" then
		return fallback
	end
	return UDim2.new(
		tonumber(posTbl.xScale) or fallback.X.Scale,
		tonumber(posTbl.xOffset) or fallback.X.Offset,
		tonumber(posTbl.yScale) or fallback.Y.Scale,
		tonumber(posTbl.yOffset) or fallback.Y.Offset
	)
end

local function savePersistPos(key, ud)
	if not ud then return end
	PERSIST[key] = {
		xScale = ud.X.Scale,
		xOffset = ud.X.Offset,
		yScale = ud.Y.Scale,
		yOffset = ud.Y.Offset,
	}
end

local function isGuiAlive()
	if not controller.gui or controller.gui.Parent == nil then return false end
	if not controller.mainFrame or controller.mainFrame.Parent == nil then return false end
	if not controller.leaveList or controller.leaveList.Parent == nil then return false end
	if not controller.notesToggleButton or controller.notesToggleButton.Parent == nil then return false end
	if not controller.blackenedChatToggleButton or controller.blackenedChatToggleButton.Parent == nil then return false end
	if not controller.notesFrame or controller.notesFrame.Parent == nil then return false end
	if not controller.notesBox or controller.notesBox.Parent == nil then return false end
	if not controller.blackenedChatFrame or controller.blackenedChatFrame.Parent == nil then return false end
	if not controller.blackenedChatList or controller.blackenedChatList.Parent == nil then return false end
	return true
end

--========================
-- IN-GAME TIME
--========================
local function getGameTimeMinutes()
	local val = ReplicatedStorage:FindFirstChild("GameTime")
	if not val then
		return nil
	end

	if val:IsA("ValueBase") then
		local ok, minutes = pcall(function()
			return val.Value
		end)
		if ok and type(minutes) == "number" then
			return minutes
		end
	end

	return nil
end

local function minutesToTimeString(minutes)
	if type(minutes) ~= "number" then
		return "??"
	end

	local total = math.floor(minutes)
	if total < 0 then total = 0 end

	local m = total % (24 * 60)
	local hours24 = math.floor(m / 60)
	local minutePart = m % 60

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

local function getCurrentGameTimeText()
	local mins = getGameTimeMinutes()
	if type(mins) == "number" then
		return minutesToTimeString(mins)
	end
	return "??"
end

--========================
-- LEAVE LOG
--========================
local function addLeaveLog(plr)
	if not plr then return end

	local entry = {
		name = getBestName(plr),
		timeText = getCurrentGameTimeText(),
		t = os.time(),
		userId = plr.UserId,
	}

	table.insert(PERSIST.leaveLogs, 1, entry)
	while #PERSIST.leaveLogs > LEAVE_LOG_MAX do
		table.remove(PERSIST.leaveLogs)
	end
end

--========================
-- NOTES
--========================
local function trimCR(s)
	return (s or ""):gsub("\r", "")
end

local function splitLinesPreserveBlank(str)
	str = trimCR(str)
	local out = {}

	if str == "" then
		return out
	end

	local startIndex = 1
	while true do
		local a, b = string.find(str, "\n", startIndex, true)
		if not a then
			table.insert(out, string.sub(str, startIndex))
			break
		end
		table.insert(out, string.sub(str, startIndex, a - 1))
		startIndex = b + 1
	end

	if string.sub(str, -1) == "\n" then
		table.insert(out, "")
	end

	return out
end

local function stripLeadingTimestamps(line)
	line = tostring(line or "")
	while true do
		local stripped, count = line:gsub("^%b[]%s*", "", 1)
		if count == 0 then
			break
		end
		line = stripped
	end
	return line
end

local function getDisplayTextFromNoteLines(noteLines)
	local lines = {}
	for _, note in ipairs(noteLines) do
		table.insert(lines, string.format("[%s] %s", tostring(note.timeText or "??"), tostring(note.text or "")))
	end
	return table.concat(lines, "\n")
end

local function copyRenderedLines()
	local out = {}
	for _, note in ipairs(PERSIST.noteLines) do
		table.insert(out, {
			id = note.id,
			timeText = note.timeText,
			text = note.text,
		})
	end
	return out
end

local function applyNotesTextToBox()
	if not controller.notesBox then return end
	controller.isApplyingNotesText = true
	controller.notesBox.Text = getDisplayTextFromNoteLines(PERSIST.noteLines)
	controller.isApplyingNotesText = false
	PERSIST.lastRenderedLines = copyRenderedLines()
end

local function getNextNoteId()
	local id = PERSIST.nextNoteId or 1
	PERSIST.nextNoteId = id + 1
	return id
end

local function syncNotesFromText(rawText)
	rawText = trimCR(rawText or "")
	local inputLines = splitLinesPreserveBlank(rawText)
	local previousRendered = PERSIST.lastRenderedLines or {}

	local newNoteLines = {}
	local prevCount = #previousRendered
	local newCount = #inputLines
	local count = math.max(prevCount, newCount)

	for i = 1, count do
		local newRaw = inputLines[i]
		local oldRendered = previousRendered[i]

		if newRaw ~= nil then
			local cleanText = stripLeadingTimestamps(newRaw)

			if oldRendered then
				table.insert(newNoteLines, {
					id = oldRendered.id,
					timeText = oldRendered.timeText,
					text = cleanText,
				})
			else
				table.insert(newNoteLines, {
					id = getNextNoteId(),
					timeText = getCurrentGameTimeText(),
					text = cleanText,
				})
			end
		end
	end

	while #newNoteLines > 0 and tostring(newNoteLines[#newNoteLines].text or "") == "" do
		table.remove(newNoteLines, #newNoteLines)
	end

	PERSIST.noteLines = newNoteLines
	PERSIST.lastRenderedLines = copyRenderedLines()
end

--========================
-- BLACKENED CHAT STATE
--========================
local function clearBlackenedChatFor(plr)
	PERSIST.blackenedChatEntries = {}
	if plr then
		PERSIST.blackenedChatOwnerUserId = plr.UserId
		PERSIST.blackenedChatOwnerName = getBestName(plr)
	end
end

local function setCurrentBlackened(plr)
	if plr and plr:IsA("Player") then
		local uid = plr.UserId
		local name = getBestName(plr)

		local oldCurrent = PERSIST.currentBlackenedUserId
		PERSIST.currentBlackenedUserId = uid
		PERSIST.currentBlackenedName = name

		if uid ~= oldCurrent then
			clearBlackenedChatFor(plr)
		end
	else
		PERSIST.currentBlackenedUserId = 0
		PERSIST.currentBlackenedName = "None"
	end
end

local function addBlackenedChatEntry(text)
	text = trimCR(tostring(text or ""))
	if text == "" then return end

	local entry = {
		timeText = getCurrentGameTimeText(),
		text = text,
	}

	table.insert(PERSIST.blackenedChatEntries, 1, entry)
	while #PERSIST.blackenedChatEntries > BLACKENED_CHAT_MAX do
		table.remove(PERSIST.blackenedChatEntries)
	end
end

local function findCurrentBlackenedPlayer()
	for _, plr in ipairs(Players:GetPlayers()) do
		if playerHasBlackened(plr) then
			return plr
		end
	end
	return nil
end

--========================
-- UI HELPERS
--========================
local function clearTextChildren(parent)
	if not parent then return end
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
end

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
	layout.Padding = UDim.new(0, 6)
	layout.Parent = sf

	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		sf.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
	end)

	return sf
end

local function addDragBehavior(frame, persistKey)
	local dragging = false
	local dragStart
	local startPos

	connect(frame.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position

			local endedConn
			endedConn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					savePersistPos(persistKey, frame.Position)
					if endedConn then
						endedConn:Disconnect()
					end
				end
			end)
		end
	end)

	connect(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)
end

--========================
-- MAIN GUI
--========================
local function makeMainGui(screen)
	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Size = UDim2.new(0, 470, 0, 440)
	frame.Position = makeUDim2FromPersist(PERSIST.mainGuiPos, UDim2.new(0, 20, 0, 140))
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Visible = controller.mainGuiOpen
	frame.ZIndex = 10
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
	title.Text = "Blackened Trail Tracker"
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
	hint.Position = UDim2.new(0, 12, 0, 36)
	hint.Size = UDim2.new(1, -24, 0, 18)
	hint.Font = Enum.Font.SourceSans
	hint.TextSize = 16
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = Color3.fromRGB(180, 180, 180)
	hint.Text = "L toggle • Leave logs use ReplicatedStorage.GameTime"
	hint.ZIndex = 11
	hint.Parent = frame

	local leaveTitle = Instance.new("TextLabel")
	leaveTitle.BackgroundTransparency = 1
	leaveTitle.Position = UDim2.new(0, 12, 0, 66)
	leaveTitle.Size = UDim2.new(1, -24, 0, 22)
	leaveTitle.Font = Enum.Font.SourceSansBold
	leaveTitle.TextSize = 18
	leaveTitle.TextXAlignment = Enum.TextXAlignment.Left
	leaveTitle.TextColor3 = Color3.fromRGB(230, 230, 230)
	leaveTitle.Text = "Leave Log"
	leaveTitle.ZIndex = 11
	leaveTitle.Parent = frame

	local notesToggleButton = Instance.new("TextButton")
	notesToggleButton.Position = UDim2.new(0, 12, 0, 92)
	notesToggleButton.Size = UDim2.new(0, 120, 0, 28)
	notesToggleButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
	notesToggleButton.BorderSizePixel = 0
	notesToggleButton.Font = Enum.Font.SourceSansBold
	notesToggleButton.TextSize = 18
	notesToggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	notesToggleButton.Text = controller.notesGuiOpen and "Close Notes" or "Open Notes"
	notesToggleButton.ZIndex = 12
	notesToggleButton.Parent = frame

	local notesToggleCorner = Instance.new("UICorner")
	notesToggleCorner.CornerRadius = UDim.new(0, 8)
	notesToggleCorner.Parent = notesToggleButton

	local blackenedChatToggleButton = Instance.new("TextButton")
	blackenedChatToggleButton.Position = UDim2.new(0, 142, 0, 92)
	blackenedChatToggleButton.Size = UDim2.new(0, 160, 0, 28)
	blackenedChatToggleButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
	blackenedChatToggleButton.BorderSizePixel = 0
	blackenedChatToggleButton.Font = Enum.Font.SourceSansBold
	blackenedChatToggleButton.TextSize = 18
	blackenedChatToggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	blackenedChatToggleButton.Text = controller.blackenedChatGuiOpen and "Close Says Log" or "Open Says Log"
	blackenedChatToggleButton.ZIndex = 12
	blackenedChatToggleButton.Parent = frame

	local blackenedToggleCorner = Instance.new("UICorner")
	blackenedToggleCorner.CornerRadius = UDim.new(0, 8)
	blackenedToggleCorner.Parent = blackenedChatToggleButton

	local leaveList = makeScrollingFrame(frame, UDim2.new(0, 12, 0, 130), UDim2.new(1, -24, 1, -142))

	addDragBehavior(frame, "mainGuiPos")

	return frame, leaveList, leaveTitle, notesToggleButton, blackenedChatToggleButton, closeBtn
end

--========================
-- NOTES GUI
--========================
local function makeNotesGui(screen)
	local frame = Instance.new("Frame")
	frame.Name = "NotesWindow"
	frame.Size = UDim2.new(0, 700, 0, 520)
	frame.Position = makeUDim2FromPersist(PERSIST.notesGuiPos, UDim2.new(0, 700, 0, 120))
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Visible = controller.notesGuiOpen
	frame.ZIndex = 30
	frame.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Transparency = 0.55
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 12, 0, 10)
	title.Size = UDim2.new(1, -90, 0, 24)
	title.Font = Enum.Font.SourceSansBold
	title.TextSize = 24
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Text = "Notes"
	title.ZIndex = 31
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
	closeBtn.ZIndex = 32
	closeBtn.Parent = frame

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeBtn

	local info = Instance.new("TextLabel")
	info.BackgroundTransparency = 1
	info.Position = UDim2.new(0, 12, 0, 38)
	info.Size = UDim2.new(1, -24, 0, 18)
	info.Font = Enum.Font.SourceSans
	info.TextSize = 16
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextColor3 = Color3.fromRGB(180, 180, 180)
	info.Text = "New lines get stamped once. Editing keeps the original time."
	info.ZIndex = 31
	info.Parent = frame

	local notesBox = Instance.new("TextBox")
	notesBox.Name = "NotesBox"
	notesBox.ClearTextOnFocus = false
	notesBox.MultiLine = true
	notesBox.TextWrapped = false
	notesBox.TextXAlignment = Enum.TextXAlignment.Left
	notesBox.TextYAlignment = Enum.TextYAlignment.Top
	notesBox.Font = Enum.Font.Code
	notesBox.TextSize = 18
	notesBox.TextColor3 = Color3.fromRGB(245, 245, 245)
	notesBox.PlaceholderText = NOTES_PLACEHOLDER
	notesBox.PlaceholderColor3 = Color3.fromRGB(150, 150, 150)
	notesBox.BackgroundColor3 = Color3.fromRGB(14, 14, 14)
	notesBox.BorderSizePixel = 0
	notesBox.Position = UDim2.new(0, 12, 0, 64)
	notesBox.Size = UDim2.new(1, -24, 1, -76)
	notesBox.Text = ""
	notesBox.ZIndex = 31
	notesBox.Parent = frame

	local notesCorner = Instance.new("UICorner")
	notesCorner.CornerRadius = UDim.new(0, 8)
	notesCorner.Parent = notesBox

	addDragBehavior(frame, "notesGuiPos")

	return frame, notesBox, closeBtn
end

--========================
-- BLACKENED CHAT GUI
--========================
local function makeBlackenedChatGui(screen)
	local frame = Instance.new("Frame")
	frame.Name = "BlackenedChatWindow"
	frame.Size = UDim2.new(0, 520, 0, 420)
	frame.Position = makeUDim2FromPersist(PERSIST.blackenedChatGuiPos, UDim2.new(0, 470, 0, 140))
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Visible = controller.blackenedChatGuiOpen
	frame.ZIndex = 40
	frame.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Transparency = 0.55
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 12, 0, 10)
	title.Size = UDim2.new(1, -90, 0, 24)
	title.Font = Enum.Font.SourceSansBold
	title.TextSize = 24
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Text = "Blackened Says"
	title.ZIndex = 41
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
	closeBtn.ZIndex = 42
	closeBtn.Parent = frame

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeBtn

	local info = Instance.new("TextLabel")
	info.BackgroundTransparency = 1
	info.Position = UDim2.new(0, 12, 0, 38)
	info.Size = UDim2.new(1, -24, 0, 18)
	info.Font = Enum.Font.SourceSans
	info.TextSize = 16
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextColor3 = Color3.fromRGB(180, 180, 180)
	info.Text = "Only captures what the current Blackened says."
	info.ZIndex = 41
	info.Parent = frame

	local list = makeScrollingFrame(frame, UDim2.new(0, 12, 0, 64), UDim2.new(1, -24, 1, -76))
	list.ZIndex = 41

	addDragBehavior(frame, "blackenedChatGuiPos")

	return frame, list, title, closeBtn
end

--========================
-- UI REBUILD
--========================
local function rebuildLeaveLogUI()
	if not controller.leaveList then return end
	clearTextChildren(controller.leaveList)

	if #PERSIST.leaveLogs == 0 then
		local row = Instance.new("TextLabel")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -4, 0, 22)
		row.Font = Enum.Font.SourceSansItalic
		row.TextSize = 18
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = Color3.fromRGB(180, 180, 180)
		row.ZIndex = 11
		row.Text = "No leave logs yet."
		row.Parent = controller.leaveList
		return
	end

	for _, e in ipairs(PERSIST.leaveLogs) do
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
		row.Text = string.format("• [%s] %s left", tostring(e.timeText or "??"), tostring(e.name or "Unknown"))
		row.Parent = controller.leaveList
	end
end

local function rebuildBlackenedChatUI()
	if not controller.blackenedChatList then return end
	clearTextChildren(controller.blackenedChatList)

	if controller.blackenedChatTitle then
		if PERSIST.currentBlackenedUserId ~= 0 then
			controller.blackenedChatTitle.Text = "Blackened Says — " .. tostring(PERSIST.currentBlackenedName or "Unknown")
		elseif PERSIST.blackenedChatOwnerUserId ~= 0 then
			controller.blackenedChatTitle.Text = "Blackened Says — Last: " .. tostring(PERSIST.blackenedChatOwnerName or "Unknown")
		else
			controller.blackenedChatTitle.Text = "Blackened Says — None"
		end
	end

	if #PERSIST.blackenedChatEntries == 0 then
		local row = Instance.new("TextLabel")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -4, 0, 22)
		row.Font = Enum.Font.SourceSansItalic
		row.TextSize = 18
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = Color3.fromRGB(180, 180, 180)
		row.ZIndex = 41
		row.Text = "No blackened chat yet."
		row.Parent = controller.blackenedChatList
		return
	end

	for i = #PERSIST.blackenedChatEntries, 1, -1 do
		local e = PERSIST.blackenedChatEntries[i]

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
		row.ZIndex = 41
		row.Text = string.format("• [%s] %s", tostring(e.timeText or "??"), tostring(e.text or ""))
		row.Parent = controller.blackenedChatList
	end
end

local function refreshWindowVisibility()
	if controller.mainFrame then
		controller.mainFrame.Visible = controller.mainGuiOpen
	end
	if controller.notesFrame then
		controller.notesFrame.Visible = controller.notesGuiOpen
	end
	if controller.blackenedChatFrame then
		controller.blackenedChatFrame.Visible = controller.blackenedChatGuiOpen
	end
	if controller.notesToggleButton then
		controller.notesToggleButton.Text = controller.notesGuiOpen and "Close Notes" or "Open Notes"
	end
	if controller.blackenedChatToggleButton then
		controller.blackenedChatToggleButton.Text = controller.blackenedChatGuiOpen and "Close Says Log" or "Open Says Log"
	end
end

local function hookGuiButtons()
	disconnectUiConns()

	if controller.mainCloseBtn then
		table.insert(controller.uiConns, controller.mainCloseBtn.MouseButton1Click:Connect(function()
			controller.mainGuiOpen = false
			PERSIST.mainGuiOpen = false
			refreshWindowVisibility()
		end))
	end

	if controller.notesToggleButton then
		table.insert(controller.uiConns, controller.notesToggleButton.MouseButton1Click:Connect(function()
			controller.notesGuiOpen = not controller.notesGuiOpen
			PERSIST.notesGuiOpen = controller.notesGuiOpen
			refreshWindowVisibility()
		end))
	end

	if controller.blackenedChatToggleButton then
		table.insert(controller.uiConns, controller.blackenedChatToggleButton.MouseButton1Click:Connect(function()
			controller.blackenedChatGuiOpen = not controller.blackenedChatGuiOpen
			PERSIST.blackenedChatGuiOpen = controller.blackenedChatGuiOpen
			refreshWindowVisibility()
		end))
	end

	if controller.notesCloseBtn then
		table.insert(controller.uiConns, controller.notesCloseBtn.MouseButton1Click:Connect(function()
			controller.notesGuiOpen = false
			PERSIST.notesGuiOpen = false
			refreshWindowVisibility()
		end))
	end

	if controller.blackenedChatCloseBtn then
		table.insert(controller.uiConns, controller.blackenedChatCloseBtn.MouseButton1Click:Connect(function()
			controller.blackenedChatGuiOpen = false
			PERSIST.blackenedChatGuiOpen = false
			refreshWindowVisibility()
		end))
	end

	if controller.notesBox then
		table.insert(controller.uiConns, controller.notesBox.FocusLost:Connect(function()
			if controller.isApplyingNotesText then return end
			syncNotesFromText(controller.notesBox.Text)
			applyNotesTextToBox()
		end))
	end
end

local function ensureGui()
	if isGuiAlive() then
		refreshWindowVisibility()
		return true
	end

	local container = getGuiContainer()
	if not container then
		return false
	end

	local existing = container:FindFirstChild(GUI_NAME)
	if existing then
		pcall(function() existing:Destroy() end)
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = GUI_NAME
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 999999
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = container

	controller.gui = screen

	local mainFrame, leaveList, leaveTitle, notesToggleButton, blackenedChatToggleButton, mainCloseBtn = makeMainGui(screen)
	controller.mainFrame = mainFrame
	controller.leaveList = leaveList
	controller.leaveTitle = leaveTitle
	controller.notesToggleButton = notesToggleButton
	controller.blackenedChatToggleButton = blackenedChatToggleButton
	controller.mainCloseBtn = mainCloseBtn

	local notesFrame, notesBox, notesCloseBtn = makeNotesGui(screen)
	controller.notesFrame = notesFrame
	controller.notesBox = notesBox
	controller.notesCloseBtn = notesCloseBtn

	local blackenedChatFrame, blackenedChatList, blackenedChatTitle, blackenedChatCloseBtn = makeBlackenedChatGui(screen)
	controller.blackenedChatFrame = blackenedChatFrame
	controller.blackenedChatList = blackenedChatList
	controller.blackenedChatTitle = blackenedChatTitle
	controller.blackenedChatCloseBtn = blackenedChatCloseBtn

	hookGuiButtons()
	rebuildLeaveLogUI()
	rebuildBlackenedChatUI()
	applyNotesTextToBox()
	refreshWindowVisibility()

	return true
end

--========================
-- TRAIL LOGIC
--========================
local function stopTrail(plr)
	local data = controller.activeTrails[plr.UserId]
	if not data then return end

	data.running = false

	if data.connections then
		disconnectList(data.connections)
	end

	if data.parts then
		for _, p in ipairs(data.parts) do
			pcall(function() p:Destroy() end)
		end
	end

	if data.folder then
		pcall(function() data.folder:Destroy() end)
	end

	controller.activeTrails[plr.UserId] = nil
end

local function createMarker(parent, pos, index)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Size = MARKER_SIZE
	part.Material = Enum.Material.Neon
	part.Color = MARKER_COLOR
	part.CFrame = CFrame.new(pos)
	part.Parent = parent

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(0, 36, 0, 36)
	gui.StudsOffset = Vector3.new(0, 1.5, 0)
	gui.AlwaysOnTop = true
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Text = tostring(index)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = gui

	return part
end

local function startTrail(plr)
	if controller.activeTrails[plr.UserId] then return end

	local container = Instance.new("Folder")
	container.Name = "Trail_" .. plr.Name .. "_" .. os.time()
	container.Parent = workspace

	local data = {
		running = true,
		parts = {},
		connections = {},
		folder = container,
	}

	controller.activeTrails[plr.UserId] = data

	table.insert(data.connections, plr.ChildRemoved:Connect(function(child)
		if child.Name == TARGET_NAME then
			stopTrail(plr)
		end
	end))

	table.insert(data.connections, plr.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			stopTrail(plr)
		end
	end))

	task.spawn(function()
		local startTime = os.clock()
		local index = 0

		while data.running do
			if os.clock() - startTime >= TRAIL_DURATION then
				break
			end

			if not playerHasBlackened(plr) then
				break
			end

			local hrp = getHRP(plr)
			if hrp then
				index += 1
				local floorPos = raycastFloor(plr.Character, hrp.Position)
				local marker = createMarker(container, floorPos, index)
				table.insert(data.parts, marker)
			end

			task.wait(DROP_INTERVAL)
		end

		stopTrail(plr)
	end)
end

--========================
-- BLACKENED CHAT CAPTURE
--========================
local function isSlashCommand(msg)
	return type(msg) == "string" and msg:sub(1, 1) == "/"
end

local function cleanText(s)
	if type(s) ~= "string" then return "" end
	return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function pruneBlackenedSeen()
	local now = os.clock()
	for k, v in pairs(controller.blackenedSeen) do
		if (now - v.t) > (GLOBAL_DEDUP_SECONDS + 1) then
			controller.blackenedSeen[k] = nil
		end
	end
end

local function markBlackenedSeen(key, pr)
	controller.blackenedSeen[key] = { t = os.clock(), pr = pr }
end

local function blockedByBlackenedKey(key, pr)
	local now = os.clock()
	local prev = controller.blackenedSeen[key]
	if prev and (now - prev.t) <= GLOBAL_DEDUP_SECONDS then
		if pr <= prev.pr then
			return true
		else
			controller.blackenedSeen[key] = { t = now, pr = pr }
			return false
		end
	end
	return false
end

local function shouldLogBlackened(uid, text, priority)
	pruneBlackenedSeen()
	local speakerKey = tostring(uid or 0) .. "|" .. tostring(text or "")
	local textKey = "TEXT|" .. tostring(text or "")

	if DEDUPE_BY_TEXT_ONLY then
		if blockedByBlackenedKey(textKey, priority) then
			return false
		end
		markBlackenedSeen(textKey, priority)
	end

	if blockedByBlackenedKey(speakerKey, priority) then
		return false
	end
	markBlackenedSeen(speakerKey, priority)
	return true
end

local function logBlackenedTextFromPlayer(plr, text, priority)
	if not plr or not plr:IsA("Player") then return end
	text = cleanText(text)
	if text == "" then return end

	if PERSIST.currentBlackenedUserId == 0 then return end
	if plr.UserId ~= PERSIST.currentBlackenedUserId then return end

	if not shouldLogBlackened(plr.UserId, text, priority) then
		return
	end

	addBlackenedChatEntry(text)
	rebuildBlackenedChatUI()
end

local function resolvePlayerFromTextSource(textSource)
	if not textSource then return nil end
	local uid = textSource.UserId
	if typeof(uid) == "number" then
		return Players:GetPlayerByUserId(uid)
	end
	return nil
end

local function getPlayerFromSpeakerString(speaker)
	if type(speaker) ~= "string" or speaker == "" then
		return nil
	end
	local plr = Players:FindFirstChild(speaker)
	if plr then return plr end
	for _, candidate in ipairs(Players:GetPlayers()) do
		if candidate.Name == speaker then
			return candidate
		end
	end
	return nil
end

local function getLabelTextRobust(lbl)
	if not lbl then return "" end

	local txt = ""
	pcall(function()
		txt = lbl.Text or ""
	end)
	txt = cleanText(txt)

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

	if controller.gui and lbl:IsDescendantOf(controller.gui) then
		return false
	end

	local bb = findBillboardGui(lbl)
	if bb and isCharacterAdornee(bb) then
		return true
	end

	local p = lbl.Parent
	local depth = 0
	while p and depth < BUBBLE_MAX_PARENT_DEPTH do
		local n = (p.Name or ""):lower()
		if n:find("bubble") or n:find("bubblechat") or n:find("chatbubble") then
			return true
		end
		if p:IsA("BillboardGui") and isCharacterAdornee(p) then
			return true
		end
		p = p.Parent
		depth += 1
	end
	return false
end

local function bubbleOwnerPlayer(lbl)
	local bb = findBillboardGui(lbl)
	if bb and bb.Adornee then
		local model = bb.Adornee:FindFirstAncestorOfClass("Model")
		if model then
			return Players:GetPlayerFromCharacter(model)
		end
	end
	return nil
end

local function handleBubbleLabel(lbl)
	if not lbl or not lbl.Parent then return end
	if not isProbablyBubbleLabel(lbl) then return end

	local text = getLabelTextRobust(lbl)
	if text == "" then return end
	if IGNORE_BUBBLE_ELLIPSIS and text == "..." then return end
	if FILTER_SLASH_IN_BUBBLES and isSlashCommand(text) then return end

	local last = controller.blackenedLastTextByLabel[lbl]
	if last == text then return end
	controller.blackenedLastTextByLabel[lbl] = text

	local plr = bubbleOwnerPlayer(lbl)
	if not plr then return end

	task.delay(BUBBLE_DELAY_SECONDS, function()
		if not lbl.Parent then return end
		local finalText = getLabelTextRobust(lbl)
		if finalText == "" then return end
		if IGNORE_BUBBLE_ELLIPSIS and finalText == "..." then return end
		if FILTER_SLASH_IN_BUBBLES and isSlashCommand(finalText) then return end

		controller.blackenedLastTextByLabel[lbl] = finalText
		logBlackenedTextFromPlayer(plr, finalText, 1)
	end)
end

local function scheduleLabelRetries(lbl)
	if not (lbl and (lbl:IsA("TextLabel") or lbl:IsA("TextButton"))) then return end
	if not lbl.Parent then return end

	local tok = (controller.blackenedRetryTokenByLabel[lbl] or 0) + 1
	controller.blackenedRetryTokenByLabel[lbl] = tok

	for i = 1, BUBBLE_RETRY_PASSES do
		task.delay(BUBBLE_RETRY_INTERVAL * i, function()
			if not lbl.Parent then return end
			if controller.blackenedRetryTokenByLabel[lbl] ~= tok then return end
			pcall(function()
				handleBubbleLabel(lbl)
			end)
		end)
	end
end

local function hookBubbleLabel(lbl)
	if not (lbl and (lbl:IsA("TextLabel") or lbl:IsA("TextButton"))) then return end
	if controller.blackenedBubbleHooked[lbl] then
		pcall(function()
			handleBubbleLabel(lbl)
		end)
		scheduleLabelRetries(lbl)
		return
	end

	controller.blackenedBubbleHooked[lbl] = true

	pcall(function()
		handleBubbleLabel(lbl)
	end)
	scheduleLabelRetries(lbl)

	table.insert(controller.conns, lbl:GetPropertyChangedSignal("Text"):Connect(function()
		pcall(function()
			handleBubbleLabel(lbl)
		end)
		scheduleLabelRetries(lbl)
	end))

	pcall(function()
		table.insert(controller.conns, lbl:GetPropertyChangedSignal("Visible"):Connect(function()
			pcall(function()
				handleBubbleLabel(lbl)
			end)
			scheduleLabelRetries(lbl)
		end))
	end)

	table.insert(controller.conns, lbl.AncestryChanged:Connect(function(_, parent)
		if not parent then
			controller.blackenedLastTextByLabel[lbl] = nil
			controller.blackenedBubbleHooked[lbl] = nil
			controller.blackenedRetryTokenByLabel[lbl] = nil
		else
			pcall(function()
				handleBubbleLabel(lbl)
			end)
			scheduleLabelRetries(lbl)
		end
	end))
end

local function hookBillboard(bb)
	if not (bb and bb:IsA("BillboardGui")) then return end

	for _, d in ipairs(bb:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			hookBubbleLabel(d)
		end
	end

	table.insert(controller.conns, bb.DescendantAdded:Connect(function(d)
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			task.defer(function()
				if d.Parent then
					hookBubbleLabel(d)
				end
			end)
		end
	end))
end

local function scanAndWatchBubbleRoot(rootGui)
	for _, d in ipairs(rootGui:GetDescendants()) do
		if d:IsA("BillboardGui") then
			hookBillboard(d)
		elseif d:IsA("TextLabel") or d:IsA("TextButton") then
			hookBubbleLabel(d)
		end
	end

	table.insert(controller.conns, rootGui.DescendantAdded:Connect(function(d)
		if d:IsA("BillboardGui") then
			task.defer(function()
				if d.Parent then
					hookBillboard(d)
				end
			end)
		elseif d:IsA("TextLabel") or d:IsA("TextButton") then
			task.defer(function()
				if d.Parent then
					hookBubbleLabel(d)
				end
			end)
		end
	end))
end

local function setupBlackenedChatCapture()
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
				MinimizeDistance = HUGE_DISTANCE,
			})
		end)
	end

	local events = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
	if events then
		local msgEvent = events:FindFirstChild("OnMessageDoneFiltering")
		if msgEvent and msgEvent:IsA("RemoteEvent") then
			connect(msgEvent.OnClientEvent, function(messageData)
				local text = cleanText(messageData and (messageData.Message or messageData.MessageText) or "")
				if text == "" then return end
				if FILTER_SLASH_IN_CHAT and isSlashCommand(text) then return end

				local speaker = messageData.FromSpeaker or messageData.SpeakerName or "Unknown"
				local plr = getPlayerFromSpeakerString(speaker)
				if plr then
					logBlackenedTextFromPlayer(plr, text, 2)
				end
			end)
		end
	end

	if TextChatService and TextChatService.MessageReceived then
		connect(TextChatService.MessageReceived, function(message)
			local text = cleanText(message.Text or "")
			if text == "" then return end
			if FILTER_SLASH_IN_CHAT and isSlashCommand(text) then return end

			local source = message.TextSource
			local plr = resolvePlayerFromTextSource(source)
			if plr then
				logBlackenedTextFromPlayer(plr, text, 2)
			end
		end)
	end

	scanAndWatchBubbleRoot(CoreGui)
	local playerGui = getPlayerGuiSafe()
	if playerGui then
		scanAndWatchBubbleRoot(playerGui)
	end
end

--========================
-- PLAYER WATCHING
--========================
local function watchPlayer(plr)
	if controller.perPlayerConns[plr] then return end
	controller.perPlayerConns[plr] = {}
	controller.playerBlackenedState[plr] = playerHasBlackened(plr)

	local function pconnect(sig, fn)
		local c = sig:Connect(fn)
		table.insert(controller.perPlayerConns[plr], c)
		return c
	end

	if playerHasBlackened(plr) then
		startTrail(plr)
	end

	pconnect(plr.ChildAdded, function(child)
		if child.Name == TARGET_NAME then
			startTrail(plr)
			controller.playerBlackenedState[plr] = true
			setCurrentBlackened(plr)
			rebuildBlackenedChatUI()
		end
	end)

	pconnect(plr.ChildRemoved, function(child)
		if child.Name == TARGET_NAME then
			controller.playerBlackenedState[plr] = playerHasBlackened(plr)
		end
	end)
end

local function unwatchPlayer(plr)
	local list = controller.perPlayerConns[plr]
	if list then
		disconnectList(list)
	end
	controller.perPlayerConns[plr] = nil
	controller.playerBlackenedState[plr] = nil
end

--========================
-- KEY TOGGLE
--========================
connect(UserInputService.InputBegan, function(input, gp)
	if gp then return end

	if input.KeyCode == TOGGLE_KEY then
		if not ensureGui() then return end
		controller.mainGuiOpen = not controller.mainGuiOpen
		PERSIST.mainGuiOpen = controller.mainGuiOpen
		refreshWindowVisibility()
	end
end)

--========================
-- PLAYER EVENTS
--========================
for _, plr in ipairs(Players:GetPlayers()) do
	watchPlayer(plr)
end

Players.PlayerAdded:Connect(function(plr)
	watchPlayer(plr)
end)

Players.PlayerRemoving:Connect(function(plr)
	addLeaveLog(plr)
	rebuildLeaveLogUI()

	stopTrail(plr)
	unwatchPlayer(plr)

	if PERSIST.currentBlackenedUserId == plr.UserId then
		setCurrentBlackened(findCurrentBlackenedPlayer())
		rebuildBlackenedChatUI()
	end
end)

--========================
-- WATCHDOGS / SCAN
--========================
local accumGui = 0
local accumState = 0

connect(RunService.Heartbeat, function(dt)
	accumGui += dt
	accumState += dt

	if accumGui >= GUI_WATCHDOG_INTERVAL then
		accumGui = 0
		if not isGuiAlive() then
			ensureGui()
			rebuildLeaveLogUI()
			rebuildBlackenedChatUI()
			applyNotesTextToBox()
			refreshWindowVisibility()
		else
			refreshWindowVisibility()
		end
	end

	if accumState >= STATE_SCAN_INTERVAL then
		accumState = 0

		for _, plr in ipairs(Players:GetPlayers()) do
			local hb = playerHasBlackened(plr)
			local old = controller.playerBlackenedState[plr]

			if old == nil then
				controller.playerBlackenedState[plr] = hb
				if hb then
					startTrail(plr)
				end
			else
				if (old == false) and hb == true then
					startTrail(plr)
					setCurrentBlackened(plr)
					rebuildBlackenedChatUI()
				end
				controller.playerBlackenedState[plr] = hb
			end
		end

		local current = findCurrentBlackenedPlayer()
		if current then
			if PERSIST.currentBlackenedUserId ~= current.UserId then
				setCurrentBlackened(current)
				rebuildBlackenedChatUI()
			end
		else
			if PERSIST.currentBlackenedUserId ~= 0 then
				setCurrentBlackened(nil)
				rebuildBlackenedChatUI()
			end
		end
	end
end)

--========================
-- INITIALIZE
--========================
ensureGui()
rebuildLeaveLogUI()
applyNotesTextToBox()

local startupBlackened = findCurrentBlackenedPlayer()
if startupBlackened then
	setCurrentBlackened(startupBlackened)
end
rebuildBlackenedChatUI()
refreshWindowVisibility()

setupBlackenedChatCapture()

print("[BlackenedTrailTracker] Loaded. L toggles leave log GUI. Notes are separate. Blackened Says logs only the current Blackened and resets when a new Blackened appears.")
