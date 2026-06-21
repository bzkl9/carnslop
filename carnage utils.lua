local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")

local LOCAL_PLAYER = Players.LocalPlayer
if not LOCAL_PLAYER then return end

local TARGET_NAME = "Blackened"
local TRAIL_DURATION = 7 * 60
local HISTORY_INTERVAL = 2.5
local MIN_STEP_DISTANCE = 1.5
local RAYCAST_DISTANCE = 50
local ARROW_SIZE = Vector3.new(3.4, 0.05, 3.4)
local BLACKENED_MARKER_COLOR = Color3.fromRGB(255, 70, 70)
local BLACKENED_NUMBER_COLOR = Color3.fromRGB(0, 0, 0)
local VICTIM_MARKER_COLOR = Color3.fromRGB(0, 190, 255)
local VICTIM_NUMBER_COLOR = Color3.fromRGB(255, 255, 255)
local FLOW_UPDATE_INTERVAL = 0.1
local FLOW_SPEED = 5
local FLOW_SPACING = 0.7
local TOGGLE_KEY = Enum.KeyCode.L
local GUI_NAME = "BlackenedTrailTrackerGui"
local LEAVE_LOG_MAX = 120
local GUI_WATCHDOG_INTERVAL = 1
local STATE_SCAN_INTERVAL = 0.45

_G.BlackenedTrailTrackerPersist = _G.BlackenedTrailTrackerPersist or {}
local PERSIST = _G.BlackenedTrailTrackerPersist
PERSIST.leaveLogs = PERSIST.leaveLogs or {}
PERSIST.mainGuiOpen = PERSIST.mainGuiOpen ~= false
PERSIST.mainGuiPos = PERSIST.mainGuiPos or {
	xScale = 0,
	xOffset = 20,
	yScale = 0,
	yOffset = 140,
}

if _G.BlackenedTrailTrackerController and type(_G.BlackenedTrailTrackerController.Cleanup) == "function" then
	pcall(_G.BlackenedTrailTrackerController.Cleanup)
end

local controller = {
	running = true,
	conns = {},
	perPlayerConns = {},
	histories = {},
	activeTrails = {},
	victimTrails = {},
	deceasedSeen = {},
	userIdsByName = {},
	playerBlackenedState = {},
	currentBlackenedUserId = 0,
	gui = nil,
	mainFrame = nil,
	leaveList = nil,
	mainCloseBtn = nil,
	mainGuiOpen = PERSIST.mainGuiOpen,
}

_G.BlackenedTrailTrackerController = controller

local function disconnectList(list)
	if not list then return end
	for _, connection in ipairs(list) do
		pcall(function()
			connection:Disconnect()
		end)
	end
end

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(controller.conns, connection)
	return connection
end

local function stopTrailByUserId(userId)
	local data = controller.activeTrails[userId]
	if not data then return end
	data.running = false
	if data.folder then
		pcall(function()
			data.folder:Destroy()
		end)
	end
	controller.activeTrails[userId] = nil
end

local function stopAllTrails()
	local userIds = {}
	for userId in pairs(controller.activeTrails) do
		table.insert(userIds, userId)
	end
	for _, userId in ipairs(userIds) do
		stopTrailByUserId(userId)
	end
end

local function stopVictimTrail(userId)
	local data = controller.victimTrails[userId]
	if not data then return end
	data.running = false
	if data.folder then
		pcall(function()
			data.folder:Destroy()
		end)
	end
	controller.victimTrails[userId] = nil
end

local function stopAllVictimTrails()
	local userIds = {}
	for userId in pairs(controller.victimTrails) do
		table.insert(userIds, userId)
	end
	for _, userId in ipairs(userIds) do
		stopVictimTrail(userId)
	end
end

local function cleanup()
	controller.running = false
	disconnectList(controller.conns)
	controller.conns = {}
	for _, list in pairs(controller.perPlayerConns) do
		disconnectList(list)
	end
	controller.perPlayerConns = {}
	stopAllTrails()
	stopAllVictimTrails()
	if controller.gui then
		pcall(function()
			controller.gui:Destroy()
		end)
	end
	controller.gui = nil
	controller.mainFrame = nil
	controller.leaveList = nil
	controller.mainCloseBtn = nil
end

controller.Cleanup = cleanup

local function getBestName(player)
	local displayName = ""
	pcall(function()
		displayName = player.DisplayName
	end)
	if type(displayName) == "string" and displayName ~= "" then
		return displayName
	end
	return player.Name
end

local function playerHasBlackened(player)
	return player and player:FindFirstChild(TARGET_NAME) ~= nil
end

local function getHRP(player)
	local character = player.Character
	if not character then return nil end
	return character:FindFirstChild("HumanoidRootPart")
end

local function raycastFloor(character, origin)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Blacklist
	params.FilterDescendantsInstances = character and { character } or {}
	local result = workspace:Raycast(origin, Vector3.new(0, -RAYCAST_DISTANCE, 0), params)
	if result then
		return result.Position + Vector3.new(0, 0.1, 0)
	end
	return origin - Vector3.new(0, 3, 0)
end

local function getPlayerGuiSafe()
	local ok, playerGui = pcall(function()
		return LOCAL_PLAYER:WaitForChild("PlayerGui", 10)
	end)
	if ok then return playerGui end
	return nil
end

local function getGuiContainer()
	local ok, core = pcall(function()
		return CoreGui
	end)
	if ok and core then return core end
	return getPlayerGuiSafe()
end

local function makeUDim2FromPersist(value, fallback)
	if type(value) ~= "table" then return fallback end
	return UDim2.new(
		tonumber(value.xScale) or fallback.X.Scale,
		tonumber(value.xOffset) or fallback.X.Offset,
		tonumber(value.yScale) or fallback.Y.Scale,
		tonumber(value.yOffset) or fallback.Y.Offset
	)
end

local function saveMainPosition(position)
	PERSIST.mainGuiPos = {
		xScale = position.X.Scale,
		xOffset = position.X.Offset,
		yScale = position.Y.Scale,
		yOffset = position.Y.Offset,
	}
end

local function getGameTimeMinutes()
	local value = ReplicatedStorage:FindFirstChild("GameTime")
	if not value or not value:IsA("ValueBase") then return nil end
	local ok, minutes = pcall(function()
		return value.Value
	end)
	if ok and type(minutes) == "number" then return minutes end
	return nil
end

local function minutesToTimeString(minutes)
	if type(minutes) ~= "number" then return "??" end
	local total = math.max(0, math.floor(minutes)) % (24 * 60)
	local hour24 = math.floor(total / 60)
	local minute = total % 60
	local suffix = hour24 >= 12 and "PM" or "AM"
	local hour12 = hour24 % 12
	if hour12 == 0 then hour12 = 12 end
	return string.format("%d:%02d %s", hour12, minute, suffix)
end

local function getCurrentGameTimeText()
	return minutesToTimeString(getGameTimeMinutes())
end

local function addLeaveLog(player)
	table.insert(PERSIST.leaveLogs, 1, {
		name = getBestName(player),
		timeText = getCurrentGameTimeText(),
		t = os.time(),
		userId = player.UserId,
	})
	while #PERSIST.leaveLogs > LEAVE_LOG_MAX do
		table.remove(PERSIST.leaveLogs)
	end
end

local function clearTextChildren(parent)
	if not parent then return end
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
end

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
	for _, entry in ipairs(PERSIST.leaveLogs) do
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
		row.Text = string.format("- [%s] %s left", tostring(entry.timeText or "??"), tostring(entry.name or "Unknown"))
		row.Parent = controller.leaveList
	end
end

local function addDragBehavior(frame)
	local dragging = false
	local dragStart
	local startPosition
	connect(frame.InputBegan, function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		dragging = true
		dragStart = input.Position
		startPosition = frame.Position
		local endedConnection
		endedConnection = input.Changed:Connect(function()
			if input.UserInputState ~= Enum.UserInputState.End then return end
			dragging = false
			saveMainPosition(frame.Position)
			endedConnection:Disconnect()
		end)
	end)
	connect(UserInputService.InputChanged, function(input)
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end)
end

local function makeScrollingFrame(parent)
	local scrollingFrame = Instance.new("ScrollingFrame")
	scrollingFrame.BackgroundTransparency = 1
	scrollingFrame.Position = UDim2.new(0, 12, 0, 96)
	scrollingFrame.Size = UDim2.new(1, -24, 1, -108)
	scrollingFrame.BorderSizePixel = 0
	scrollingFrame.ScrollBarThickness = 8
	scrollingFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollingFrame.ZIndex = 11
	scrollingFrame.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = scrollingFrame
	connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
		scrollingFrame.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
	end)
	return scrollingFrame
end

local function isGuiAlive()
	return controller.gui ~= nil
		and controller.gui.Parent ~= nil
		and controller.mainFrame ~= nil
		and controller.mainFrame.Parent ~= nil
		and controller.leaveList ~= nil
		and controller.leaveList.Parent ~= nil
end

local function refreshWindowVisibility()
	if controller.mainFrame then
		controller.mainFrame.Visible = controller.mainGuiOpen
	end
end

local function ensureGui()
	if isGuiAlive() then
		refreshWindowVisibility()
		return true
	end
	local container = getGuiContainer()
	if not container then return false end
	local existing = container:FindFirstChild(GUI_NAME)
	if existing then existing:Destroy() end
	local screen = Instance.new("ScreenGui")
	screen.Name = GUI_NAME
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 999999
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = container
	controller.gui = screen
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
	controller.mainFrame = frame
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
	local closeButton = Instance.new("TextButton")
	closeButton.Position = UDim2.new(1, -36, 0, 10)
	closeButton.Size = UDim2.new(0, 24, 0, 24)
	closeButton.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	closeButton.BorderSizePixel = 0
	closeButton.Font = Enum.Font.SourceSansBold
	closeButton.TextSize = 16
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.Text = "X"
	closeButton.ZIndex = 12
	closeButton.Parent = frame
	controller.mainCloseBtn = closeButton
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeButton
	local hint = Instance.new("TextLabel")
	hint.BackgroundTransparency = 1
	hint.Position = UDim2.new(0, 12, 0, 36)
	hint.Size = UDim2.new(1, -24, 0, 18)
	hint.Font = Enum.Font.SourceSans
	hint.TextSize = 16
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = Color3.fromRGB(180, 180, 180)
	hint.Text = "L toggle - Leave logs use ReplicatedStorage.GameTime"
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
	controller.leaveList = makeScrollingFrame(frame)
	addDragBehavior(frame)
	connect(closeButton.MouseButton1Click, function()
		controller.mainGuiOpen = false
		PERSIST.mainGuiOpen = false
		refreshWindowVisibility()
	end)
	rebuildLeaveLogUI()
	refreshWindowVisibility()
	return true
end

local function ensureHistory(player)
	local history = controller.histories[player.UserId]
	if history then return history end
	history = {
		points = {},
		nextId = 1,
	}
	controller.histories[player.UserId] = history
	return history
end

local function samplePlayer(player)
	local hrp = getHRP(player)
	if not hrp then return end
	local history = ensureHistory(player)
	local now = os.clock()
	local points = history.points
	local last = points[#points]
	if not last or (hrp.Position - last.position).Magnitude >= MIN_STEP_DISTANCE then
		table.insert(points, {
			id = history.nextId,
			t = now,
			position = hrp.Position,
		})
		history.nextId += 1
	end
end

local function createArrow(parent, position, targetPosition, index, markerColor, numberColor)
	local direction = Vector3.new(targetPosition.X - position.X, 0, targetPosition.Z - position.Z)
	if direction.Magnitude < 0.05 then return nil end
	direction = direction.Unit
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = ARROW_SIZE
	part.CFrame = CFrame.fromMatrix(position, direction, Vector3.new(0, 1, 0), direction:Cross(Vector3.new(0, 1, 0)))
	part.Parent = parent
	local surface = Instance.new("SurfaceGui")
	surface.Face = Enum.NormalId.Top
	surface.CanvasSize = Vector2.new(160, 160)
	surface.AlwaysOnTop = false
	surface.LightInfluence = 0
	surface.Parent = part
	local arrow = Instance.new("TextLabel")
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.new(1, 0, 1, 0)
	arrow.Text = utf8.char(10148)
	arrow.TextScaled = true
	arrow.Font = Enum.Font.GothamBold
	arrow.TextColor3 = markerColor
	arrow.TextStrokeColor3 = Color3.fromRGB(255, 255, 255)
	arrow.TextStrokeTransparency = 0.65
	arrow.TextTransparency = 0.12
	arrow.Parent = surface
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 36, 0, 36)
	billboard.StudsOffset = Vector3.new(0, 1.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = part
	local number = Instance.new("TextLabel")
	number.BackgroundTransparency = 1
	number.Size = UDim2.new(1, 0, 1, 0)
	number.Text = tostring(index)
	number.TextScaled = true
	number.Font = Enum.Font.SourceSansBold
	number.TextColor3 = numberColor
	number.TextStrokeColor3 = markerColor
	number.TextStrokeTransparency = 0.35
	number.Parent = billboard
	return {
		arrow = arrow,
		number = number,
	}
end

local function startTrail(player)
	if controller.activeTrails[player.UserId] then return end
	for userId in pairs(controller.activeTrails) do
		if userId ~= player.UserId then
			stopTrailByUserId(userId)
		end
	end
	local folder = Instance.new("Folder")
	folder.Name = "Trail_" .. player.Name .. "_" .. os.time()
	folder.Parent = workspace
	local data = {
		running = true,
		folder = folder,
		visuals = {},
	}
	controller.activeTrails[player.UserId] = data
	controller.currentBlackenedUserId = player.UserId
	task.spawn(function()
		local startedAt = os.clock()
		local lastRenderedId = 0
		local arrowNumber = 0
		local initialPoints = {}
		for _, point in ipairs(ensureHistory(player).points) do
			table.insert(initialPoints, point)
		end
		local lastPoint = initialPoints[1]
		if lastPoint then
			lastRenderedId = lastPoint.id
		end
		for index = 2, #initialPoints do
			if not data.running or not playerHasBlackened(player) then break end
			local point = initialPoints[index]
			arrowNumber += 1
			local floorPosition = raycastFloor(player.Character, lastPoint.position)
			local visual = createArrow(folder, floorPosition, point.position, arrowNumber, BLACKENED_MARKER_COLOR, BLACKENED_NUMBER_COLOR)
			if visual then
				table.insert(data.visuals, visual)
			end
			lastPoint = point
			lastRenderedId = point.id
			if arrowNumber % 30 == 0 then
				task.wait()
			end
		end
		while data.running do
			if os.clock() - startedAt >= TRAIL_DURATION then break end
			if not playerHasBlackened(player) then break end
			local history = ensureHistory(player)
			for _, point in ipairs(history.points) do
				if not data.running then break end
				if point.id > lastRenderedId then
					if lastPoint then
						arrowNumber += 1
						local floorPosition = raycastFloor(player.Character, lastPoint.position)
						local visual = createArrow(folder, floorPosition, point.position, arrowNumber, BLACKENED_MARKER_COLOR, BLACKENED_NUMBER_COLOR)
						if visual then
							table.insert(data.visuals, visual)
						end
					end
					lastPoint = point
					lastRenderedId = point.id
					if arrowNumber > 0 and arrowNumber % 30 == 0 then
						task.wait()
					end
				end
			end
			task.wait(0.1)
		end
		stopTrailByUserId(player.UserId)
	end)
end

local function startVictimTrail(userId)
	if controller.victimTrails[userId] then return end
	local history = controller.histories[userId]
	if not history or #history.points == 0 then return end
	local player = Players:GetPlayerByUserId(userId)
	local folder = Instance.new("Folder")
	folder.Name = "VictimTrail_" .. (player and player.Name or tostring(userId)) .. "_" .. os.time()
	folder.Parent = workspace
	local data = {
		running = true,
		folder = folder,
		visuals = {},
	}
	controller.victimTrails[userId] = data
	local points = {}
	for _, point in ipairs(history.points) do
		table.insert(points, point)
	end
	task.spawn(function()
		local startedAt = os.clock()
		for index = 1, #points - 1 do
			if not data.running then break end
			local point = points[index]
			local nextPoint = points[index + 1]
			local currentPlayer = Players:GetPlayerByUserId(userId)
			local character = currentPlayer and currentPlayer.Character or nil
			local floorPosition = raycastFloor(character, point.position)
			local visual = createArrow(folder, floorPosition, nextPoint.position, index, VICTIM_MARKER_COLOR, VICTIM_NUMBER_COLOR)
			if visual then
				table.insert(data.visuals, visual)
			end
			if index % 30 == 0 then
				task.wait()
			end
		end
		local remaining = TRAIL_DURATION - (os.clock() - startedAt)
		if data.running and remaining > 0 then
			task.wait(remaining)
		end
		stopVictimTrail(userId)
	end)
end

local function revealVictim(userId)
	userId = tonumber(userId)
	if not userId or userId <= 0 or controller.deceasedSeen[userId] then return end
	controller.deceasedSeen[userId] = true
	startVictimTrail(userId)
end

local function resolveVictimUserId(value, depth)
	depth = depth or 0
	if depth > 3 then return nil end
	local valueType = typeof(value)
	if valueType == "number" then
		return value > 0 and value or nil
	end
	if valueType == "string" then
		local player = Players:FindFirstChild(value)
		if player and player:IsA("Player") then
			return player.UserId
		end
		return controller.userIdsByName[value] or controller.userIdsByName[string.lower(value)]
	end
	if valueType == "Instance" then
		if value:IsA("Player") then
			return value.UserId
		end
		local character = value:IsA("Model") and value or value:FindFirstAncestorOfClass("Model")
		local player = character and Players:GetPlayerFromCharacter(character) or nil
		if player then
			return player.UserId
		end
		return resolveVictimUserId(character and character.Name or value.Name, depth + 1)
	end
	if valueType == "table" then
		local keys = {
			"Victim", "victim", "DeadPlayer", "deadPlayer", "Player", "player",
			"Character", "character", "UserId", "userId", "Name", "name",
		}
		for _, key in ipairs(keys) do
			if value[key] ~= nil then
				local userId = resolveVictimUserId(value[key], depth + 1)
				if userId then return userId end
			end
		end
		if value[2] ~= nil then
			local userId = resolveVictimUserId(value[2], depth + 1)
			if userId then return userId end
		end
		if value[1] ~= nil then
			return resolveVictimUserId(value[1], depth + 1)
		end
	end
	return nil
end

local function startDeathEventListening()
	task.spawn(function()
		local events = ReplicatedStorage:WaitForChild("Events", 30)
		if not events or not controller.running then return end
		local event = events:WaitForChild("PlayerHasDiedEvent", 30)
		if not event or not event:IsA("RemoteEvent") or not controller.running then return end
		connect(event.OnClientEvent, function(...)
			local args = table.pack(...)
			for index = args.n, 1, -1 do
				local userId = resolveVictimUserId(args[index])
				if userId then
					revealVictim(userId)
					return
				end
			end
		end)
	end)
end

local function findCurrentBlackenedPlayer()
	for _, player in ipairs(Players:GetPlayers()) do
		if playerHasBlackened(player) then return player end
	end
	return nil
end

local function activateCurrentBlackened(player)
	if not player then
		stopAllTrails()
		controller.currentBlackenedUserId = 0
		return
	end
	if controller.currentBlackenedUserId ~= player.UserId then
		stopAllTrails()
		controller.currentBlackenedUserId = player.UserId
		startTrail(player)
	end
end

local function watchPlayer(player)
	if controller.perPlayerConns[player] then return end
	controller.perPlayerConns[player] = {}
	controller.playerBlackenedState[player] = playerHasBlackened(player)
	controller.userIdsByName[player.Name] = player.UserId
	controller.userIdsByName[string.lower(player.Name)] = player.UserId
	ensureHistory(player)
	local function pconnect(signal, callback)
		local connection = signal:Connect(callback)
		table.insert(controller.perPlayerConns[player], connection)
	end
	pconnect(player.ChildAdded, function(child)
		if child.Name ~= TARGET_NAME then return end
		controller.playerBlackenedState[player] = true
		stopAllTrails()
		controller.currentBlackenedUserId = 0
		activateCurrentBlackened(player)
	end)
	pconnect(player.ChildRemoved, function(child)
		if child.Name ~= TARGET_NAME then return end
		controller.playerBlackenedState[player] = playerHasBlackened(player)
		if controller.currentBlackenedUserId == player.UserId then
			stopTrailByUserId(player.UserId)
			controller.currentBlackenedUserId = 0
			activateCurrentBlackened(findCurrentBlackenedPlayer())
		end
	end)
end

local function unwatchPlayer(player)
	disconnectList(controller.perPlayerConns[player])
	controller.perPlayerConns[player] = nil
	controller.playerBlackenedState[player] = nil
end

connect(UserInputService.InputBegan, function(input, gameProcessed)
	if gameProcessed or input.KeyCode ~= TOGGLE_KEY then return end
	if not ensureGui() then return end
	controller.mainGuiOpen = not controller.mainGuiOpen
	PERSIST.mainGuiOpen = controller.mainGuiOpen
	refreshWindowVisibility()
end)

for _, player in ipairs(Players:GetPlayers()) do
	watchPlayer(player)
	samplePlayer(player)
end

connect(Players.PlayerAdded, function(player)
	watchPlayer(player)
	samplePlayer(player)
end)

connect(Players.PlayerRemoving, function(player)
	addLeaveLog(player)
	rebuildLeaveLogUI()
	stopTrailByUserId(player.UserId)
	local wasCurrent = controller.currentBlackenedUserId == player.UserId
	unwatchPlayer(player)
	if wasCurrent then
		controller.currentBlackenedUserId = 0
		task.defer(function()
			activateCurrentBlackened(findCurrentBlackenedPlayer())
		end)
	end
end)

local function updateFlow(collection, now)
	for _, data in pairs(collection) do
		if data.running and data.visuals then
			for index, visual in ipairs(data.visuals) do
				local arrow = visual.arrow
				if arrow and arrow.Parent then
					local wave = (math.sin(now * FLOW_SPEED - index * FLOW_SPACING) + 1) * 0.5
					local pulse = wave ^ 5
					arrow.TextTransparency = 0.42 - pulse * 0.36
					arrow.TextStrokeTransparency = 0.86 - pulse * 0.56
				end
			end
		end
	end
end

local historyAccumulator = 0
local guiAccumulator = 0
local stateAccumulator = 0
local flowAccumulator = 0

connect(RunService.Heartbeat, function(deltaTime)
	historyAccumulator += deltaTime
	guiAccumulator += deltaTime
	stateAccumulator += deltaTime
	flowAccumulator += deltaTime
	if flowAccumulator >= FLOW_UPDATE_INTERVAL then
		flowAccumulator %= FLOW_UPDATE_INTERVAL
		local now = os.clock()
		updateFlow(controller.activeTrails, now)
		updateFlow(controller.victimTrails, now)
	end
	if historyAccumulator >= HISTORY_INTERVAL then
		historyAccumulator %= HISTORY_INTERVAL
		for _, player in ipairs(Players:GetPlayers()) do
			samplePlayer(player)
		end
	end
	if guiAccumulator >= GUI_WATCHDOG_INTERVAL then
		guiAccumulator = 0
		if not isGuiAlive() then
			ensureGui()
			rebuildLeaveLogUI()
		else
			refreshWindowVisibility()
		end
	end
	if stateAccumulator >= STATE_SCAN_INTERVAL then
		stateAccumulator = 0
		for _, player in ipairs(Players:GetPlayers()) do
			controller.playerBlackenedState[player] = playerHasBlackened(player)
		end
		local current = findCurrentBlackenedPlayer()
		if current then
			if controller.currentBlackenedUserId ~= current.UserId then
				activateCurrentBlackened(current)
			end
		elseif controller.currentBlackenedUserId ~= 0 then
			activateCurrentBlackened(nil)
		end
	end
end)

ensureGui()
rebuildLeaveLogUI()
activateCurrentBlackened(findCurrentBlackenedPlayer())
startDeathEventListening()

print("[BlackenedTrailTracker] Loaded. PlayerHasDiedEvent reveals cyan victim paths, red arrows show the Blackened path, and L toggles the leave log.")
