--============================================================
-- Blackened Trail Tracker
--============================================================
-- Detects when a player gains the "Blackened" tag and creates
-- a numbered purple trail showing where they walked.
--
-- Trail rules:
-- • Lasts up to 3 minutes
-- • Removed immediately if:
--      - Player loses the Blackened tag
--      - Player leaves the game
--============================================================

local Players = game:GetService("Players")

--========================
-- CONFIG
--========================
local TARGET_NAME = "Blackened"

local TRAIL_DURATION = 7 * 60
local DROP_INTERVAL = 0.5
local RAYCAST_DISTANCE = 50

local MARKER_SIZE = Vector3.new(1,0.2,1)
local MARKER_COLOR = Color3.fromRGB(130,0,130)

--========================
-- STATE
--========================
local activeTrails = {} 
-- [userId] = {running=true, parts={}, connections={}}

--========================
-- HELPERS
--========================
local function playerHasBlackened(plr)
	return plr:FindFirstChild(TARGET_NAME) ~= nil
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

	local result = workspace:Raycast(origin, Vector3.new(0,-RAYCAST_DISTANCE,0), params)

	if result then
		return result.Position + Vector3.new(0,0.1,0)
	end

	return origin - Vector3.new(0,3,0)
end

--========================
-- CLEANUP
--========================
local function stopTrail(plr)
	local data = activeTrails[plr.UserId]
	if not data then return end

	data.running = false

	for _,c in ipairs(data.connections) do
		pcall(function() c:Disconnect() end)
	end

	for _,p in ipairs(data.parts) do
		pcall(function() p:Destroy() end)
	end

	activeTrails[plr.UserId] = nil
end

--========================
-- CREATE MARKER
--========================
local function createMarker(parent,pos,index)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Size = MARKER_SIZE
	part.Material = Enum.Material.Neon
	part.Color = MARKER_COLOR
	part.CFrame = CFrame.new(pos)
	part.Parent = parent

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(0,36,0,36)
	gui.StudsOffset = Vector3.new(0,1.5,0)
	gui.AlwaysOnTop = true
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1,0,1,0)
	label.Text = tostring(index)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.TextColor3 = Color3.new(1,1,1)
	label.Parent = gui

	return part
end

--========================
-- TRAIL LOGIC
--========================
local function startTrail(plr)

	if activeTrails[plr.UserId] then return end

	local container = Instance.new("Folder")
	container.Name = "Trail_"..plr.Name.."_"..os.time()
	container.Parent = workspace

	local data = {
		running = true,
		parts = {},
		connections = {}
	}

	activeTrails[plr.UserId] = data

	-- stop if blackened removed
	table.insert(data.connections,
		plr.ChildRemoved:Connect(function(child)
			if child.Name == TARGET_NAME then
				stopTrail(plr)
			end
		end)
	)

	-- stop if player leaves
	table.insert(data.connections,
		plr.AncestryChanged:Connect(function(_,parent)
			if parent == nil then
				stopTrail(plr)
			end
		end)
	)

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

				local floorPos = raycastFloor(plr.Character,hrp.Position)

				local marker = createMarker(container,floorPos,index)

				table.insert(data.parts,marker)
			end

			task.wait(DROP_INTERVAL)
		end

		stopTrail(plr)

	end)
end

--========================
-- PLAYER WATCHING
--========================
local function watchPlayer(plr)

	if playerHasBlackened(plr) then
		startTrail(plr)
	end

	plr.ChildAdded:Connect(function(child)
		if child.Name == TARGET_NAME then
			startTrail(plr)
		end
	end)

end

for _,plr in ipairs(Players:GetPlayers()) do
	watchPlayer(plr)
end

Players.PlayerAdded:Connect(watchPlayer)

Players.PlayerRemoving:Connect(function(plr)
	stopTrail(plr)
end)

print("[BlackenedTrailTracker] Loaded.")