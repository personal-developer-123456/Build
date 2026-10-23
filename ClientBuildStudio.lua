--[[
	ClientBuildStudio.lua  (ONE file: server + client)

	SETUP: create ONE Script (a normal Script, not a LocalScript) in ServerScriptService
	and paste this whole file into it. That's it.

	On the server it creates the sharing system and automatically hands a copy of itself
	to every player (as a client-side Script in ReplicatedStorage). That copy runs the
	build tool UI.

	Everything you build is CLIENT-SIDED (Workspace.ClientBuild, only you see it) until
	you press the Share button: "Share: ME" = only you, "Share: ALL" = other players see
	it too (the server mirrors your parts into Workspace.SharedBuild/<UserId>, validated,
	capped at 500 parts per player and rate-limited).

	Features
	  * Studio-style handles: Move (arrows), Rotate (rings with balls), Scale (squares)
	  * Tap / click a part to select it (works on touch)
	  * Freecam (PC: WASD/QE + hold right mouse | Mobile: joystick + drag to look)
	  * Save / Import via a copy-paste code (JSON text)
	  * Color, Material and Transparency menus, undo, duplicate, delete, snapping
	  * Scrollable bottom toolbar with big buttons for mobile

	PC shortcuts: F freecam | 1 Move | 2 Rotate | 3 Scale | Delete | Ctrl+Z undo | Ctrl+D duplicate
]]

local RunService = game:GetService("RunService")

--========================================================================
-- SERVER HALF
--========================================================================
if RunService:IsServer() then
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Workspace = game:GetService("Workspace")

	local CONFIG = {
		MaxPartsPerPlayer = 500,
		MaxSetsPerFire = 200,
		MaxDelsPerFire = 200,
		BucketSize = 1000, -- burst allowance (part updates)
		RefillPerSecond = 500, -- sustained part updates per second
		MaxPosition = 5000, -- studs from the origin
		MinSize = 0.1,
		MaxSize = 256,
		CanCollide = true, -- set false if you don't want shared parts to block players
	}

	local KINDS = { Block = true, Ball = true, Cylinder = true, Wedge = true }

	--========================================================================
	-- Setup
	--========================================================================
	local remote = ReplicatedStorage:FindFirstChild("BuildSync")
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "BuildSync"
		remote.Parent = ReplicatedStorage
	end

	-- Deliver the client half: this same script is cloned as a client-side Script.
	-- Every player runs the copy (it takes the CLIENT HALF branch below).
	if script:IsA("Script") and script.RunContext ~= Enum.RunContext.Client then
		local ok, err = pcall(function()
			local copy = script:Clone()
			copy.Name = "ClientBuildStudio_ClientCopy"
			copy.RunContext = Enum.RunContext.Client
			copy.Parent = ReplicatedStorage
		end)
		if not ok then
			warn("[ClientBuildStudio] Couldn't create the client copy: " .. tostring(err)
				.. " | Fallback: put a copy of this same script in StarterPlayerScripts as a LocalScript.")
		end
	end

	local root = Workspace:FindFirstChild("SharedBuild")
	if not root then
		root = Instance.new("Folder")
		root.Name = "SharedBuild"
		root.Parent = Workspace
	end

	local states = {} -- [player] = { folder, parts, count, tokens, last, lastNotice }

	local function setupPlayer(player)
		if states[player] then return end
		local folder = Instance.new("Folder")
		folder.Name = tostring(player.UserId)
		folder.Parent = root
		states[player] = {
			folder = folder,
			parts = {},
			count = 0,
			tokens = CONFIG.BucketSize,
			last = os.clock(),
			lastNotice = 0,
		}
	end

	local function clearState(state)
		state.folder:ClearAllChildren()
		state.parts = {}
		state.count = 0
	end

	Players.PlayerAdded:Connect(setupPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		setupPlayer(p)
	end

	Players.PlayerRemoving:Connect(function(player)
		local state = states[player]
		if state then
			state.folder:Destroy()
			states[player] = nil
		end
	end)

	--========================================================================
	-- Validation
	--========================================================================
	local function validNum(n)
		return typeof(n) == "number" and n == n and math.abs(n) < 1e6
	end

	local function sanitize(d)
		if typeof(d) ~= "table" then return nil end

		local id = d.id
		if typeof(id) ~= "string" or #id == 0 or #id > 40 then return nil end
		if typeof(d.k) ~= "string" or not KINDS[d.k] then return nil end
		if typeof(d.cf) ~= "CFrame" or typeof(d.s) ~= "Vector3" or typeof(d.c) ~= "Color3" then
			return nil
		end

		for _, n in ipairs({ d.cf:GetComponents() }) do
			if not validNum(n) then return nil end
		end
		if d.cf.Position.Magnitude > CONFIG.MaxPosition then return nil end

		if not (validNum(d.s.X) and validNum(d.s.Y) and validNum(d.s.Z)) then return nil end
		local size = Vector3.new(
			math.clamp(d.s.X, CONFIG.MinSize, CONFIG.MaxSize),
			math.clamp(d.s.Y, CONFIG.MinSize, CONFIG.MaxSize),
			math.clamp(d.s.Z, CONFIG.MinSize, CONFIG.MaxSize)
		)

		local material = Enum.Material.Plastic
		if typeof(d.m) == "string" then
			material = Enum.Material:FromName(d.m) or Enum.Material.Plastic
		end

		local transparency = 0
		if validNum(d.t) then
			transparency = math.clamp(d.t, 0, 1)
		end

		return {
			id = id,
			k = d.k,
			cf = d.cf,
			s = size,
			c = d.c,
			m = material,
			t = transparency,
		}
	end

	--========================================================================
	-- Applying changes
	--========================================================================
	local function applySet(state, d)
		local part = state.parts[d.id]
		if part and part.Parent ~= state.folder then
			state.parts[d.id] = nil
			state.count -= 1
			part = nil
		end

		local isNew = false
		if not part then
			if state.count >= CONFIG.MaxPartsPerPlayer then
				return false
			end
			if d.k == "Wedge" then
				part = Instance.new("WedgePart")
			else
				part = Instance.new("Part")
				part.Shape = Enum.PartType[d.k]
			end
			part.Name = d.id
			part.Anchored = true
			part.CanCollide = CONFIG.CanCollide
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			state.parts[d.id] = part
			state.count += 1
			isNew = true
		end

		part.Size = d.s
		part.CFrame = d.cf
		part.Color = d.c
		part.Material = d.m
		part.Transparency = d.t
		if isNew then
			part.Parent = state.folder
		end
		return true
	end

	local function applyDelete(state, id)
		if typeof(id) ~= "string" then return end
		local part = state.parts[id]
		if part then
			part:Destroy()
			state.parts[id] = nil
			state.count -= 1
		end
	end

	--========================================================================
	-- Remote handler
	--========================================================================
	remote.OnServerEvent:Connect(function(player, kind, payload)
		local state = states[player]
		if not state then return end

		if kind == "clear" then
			clearState(state)
			return
		end

		if kind ~= "sync" or typeof(payload) ~= "table" then return end
		local sets, dels = payload.sets, payload.dels
		if typeof(sets) ~= "table" then sets = {} end
		if typeof(dels) ~= "table" then dels = {} end

		local nSets = math.min(#sets, CONFIG.MaxSetsPerFire)
		local nDels = math.min(#dels, CONFIG.MaxDelsPerFire)

		-- rate limit (token bucket)
		local now = os.clock()
		state.tokens = math.min(CONFIG.BucketSize, state.tokens + (now - state.last) * CONFIG.RefillPerSecond)
		state.last = now
		local cost = nSets + nDels
		if cost > state.tokens then
			return
		end
		state.tokens -= cost

		for i = 1, nDels do
			applyDelete(state, dels[i])
		end

		local hitLimit = false
		for i = 1, nSets do
			local d = sanitize(sets[i])
			if d and not applySet(state, d) then
				hitLimit = true
			end
		end

		if hitLimit and now - state.lastNotice > 5 then
			state.lastNotice = now
			remote:FireClient(player, "limit", CONFIG.MaxPartsPerPlayer)
		end
	end)

	return
end

--========================================================================
-- CLIENT HALF
--========================================================================

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--========================================================================
-- Config
--========================================================================
local CFG = {
	MoveSnap = 1, -- studs
	RotSnap = 15, -- degrees
	ScaleSnap = 1, -- studs
	MinSize = 0.1,
	SpawnDistance = 14,
	FlySpeed = 40,
	FastMultiplier = 3,
	MouseSens = 0.25,
	TouchSens = 0.3,
	MaxImportParts = 3000,
}

local PALETTE = {
	Color3.fromRGB(242, 243, 243), -- white
	Color3.fromRGB(163, 162, 165), -- grey
	Color3.fromRGB(99, 95, 98),    -- dark grey
	Color3.fromRGB(27, 42, 53),    -- black
	Color3.fromRGB(196, 40, 28),   -- red
	Color3.fromRGB(218, 133, 65),  -- orange
	Color3.fromRGB(245, 205, 48),  -- yellow
	Color3.fromRGB(75, 151, 75),   -- green
	Color3.fromRGB(40, 127, 71),   -- dark green
	Color3.fromRGB(13, 105, 172),  -- blue
	Color3.fromRGB(52, 142, 64),   -- lime-ish green
	Color3.fromRGB(107, 50, 124),  -- purple
	Color3.fromRGB(215, 197, 154), -- tan
	Color3.fromRGB(124, 92, 70),   -- brown
	Color3.fromRGB(255, 152, 220), -- pink
	Color3.fromRGB(4, 175, 236),   -- cyan
}

local MATERIALS = {
	Enum.Material.Plastic,
	Enum.Material.SmoothPlastic,
	Enum.Material.Wood,
	Enum.Material.Metal,
	Enum.Material.Concrete,
	Enum.Material.Brick,
	Enum.Material.Glass,
	Enum.Material.Neon,
	Enum.Material.Grass,
	Enum.Material.Sand,
	Enum.Material.Marble,
	Enum.Material.Granite,
	Enum.Material.Slate,
	Enum.Material.Fabric,
	Enum.Material.Ice,
	Enum.Material.Foil,
}

local COLOR_BTN = Color3.fromRGB(50, 52, 60)
local COLOR_ACTIVE = Color3.fromRGB(0, 120, 215)

--========================================================================
-- State
--========================================================================
local mode = "Move" -- "Move" | "Rotate" | "Scale"
local snapOn = true
local selected = nil
local colorIndex, matIndex = 1, 1
local undoStack = {}

local handleActive = false -- true while a handle is being dragged
local lastHandleTime = 0

local updateModeButtons = function() end -- replaced once the GUI exists
local onSelectionChanged = function() end -- replaced once the GUI exists
local toast = function(_msg) end

local function getCamera()
	return Workspace.CurrentCamera
end

local function snapN(v, step)
	return math.round(v / step) * step
end

local function pushUndo(fn)
	table.insert(undoStack, fn)
	if #undoStack > 100 then
		table.remove(undoStack, 1)
	end
end

--========================================================================
-- Build folder + parts
--========================================================================
local buildFolder = Workspace:FindFirstChild("ClientBuild")
if not buildFolder then
	buildFolder = Instance.new("Folder")
	buildFolder.Name = "ClientBuild"
	buildFolder.Parent = Workspace
end

local function newPart(kind)
	local p
	if kind == "Wedge" then
		p = Instance.new("WedgePart")
	else
		p = Instance.new("Part")
		local ok = pcall(function()
			p.Shape = Enum.PartType[kind]
		end)
		if not ok then
			p.Shape = Enum.PartType.Block
		end
	end
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = Vector3.new(4, 4, 4)
	p.Color = PALETTE[colorIndex]
	p.Material = MATERIALS[matIndex]
	p.Parent = buildFolder
	return p
end

local function kindOf(p)
	if p:IsA("WedgePart") then
		return "Wedge"
	end
	return p.Shape.Name -- Block / Ball / Cylinder
end

--========================================================================
-- Save / Import (JSON text)
--========================================================================
local function r4(n)
	return math.floor(n * 10000 + 0.5) / 10000
end

local function serialize()
	local out = {}
	for _, p in ipairs(buildFolder:GetChildren()) do
		if p:IsA("BasePart") then
			local comps = { p.CFrame:GetComponents() }
			for i, v in ipairs(comps) do
				comps[i] = r4(v)
			end
			table.insert(out, {
				k = kindOf(p),
				c = comps,
				s = { r4(p.Size.X), r4(p.Size.Y), r4(p.Size.Z) },
				col = p.Color:ToHex(),
				m = p.Material.Name,
				t = r4(p.Transparency),
			})
		end
	end
	return HttpService:JSONEncode({ v = 1, parts = out })
end

local selectPart -- forward declaration

local function buildFromData(d)
	if type(d) ~= "table" or type(d.s) ~= "table" or #d.s ~= 3 or type(d.c) ~= "table" or #d.c ~= 12 then
		return nil
	end
	for _, n in ipairs(d.s) do
		if type(n) ~= "number" then return nil end
	end
	for _, n in ipairs(d.c) do
		if type(n) ~= "number" then return nil end
	end

	local p = newPart(type(d.k) == "string" and d.k or "Block")
	p.Size = Vector3.new(d.s[1], d.s[2], d.s[3])
	p.CFrame = CFrame.new(table.unpack(d.c))
	pcall(function()
		if d.col then p.Color = Color3.fromHex(d.col) end
	end)
	pcall(function()
		local m = Enum.Material:FromName(d.m)
		if m then p.Material = m end
	end)
	if type(d.t) == "number" then
		p.Transparency = math.clamp(d.t, 0, 1)
	end
	return p
end

local function clearAll()
	selectPart(nil)
	buildFolder:ClearAllChildren()
	undoStack = {}
end

local function importJSON(str, replace)
	local ok, data = pcall(function()
		return HttpService:JSONDecode(str)
	end)
	if not ok or type(data) ~= "table" or type(data.parts) ~= "table" then
		toast("Invalid save code")
		return
	end
	if replace then
		clearAll()
	end
	local created = {}
	for i, d in ipairs(data.parts) do
		if i > CFG.MaxImportParts then break end
		local ok2, p = pcall(buildFromData, d)
		if ok2 and p then
			table.insert(created, p)
		end
	end
	if not replace and #created > 0 then
		pushUndo(function()
			for _, p in ipairs(created) do
				if p == selected then selectPart(nil) end
				p.Parent = nil
			end
		end)
	end
	toast(("Imported %d parts"):format(#created))
end

--========================================================================
-- GUI root
--========================================================================
local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local gui = new("ScreenGui", {
	Name = "ClientBuildStudio",
	ResetOnSpawn = false,
	DisplayOrder = 10,
	ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
}, playerGui)

local toastLabel = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 10),
	Size = UDim2.new(0.9, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Color3.fromRGB(20, 20, 25),
	BackgroundTransparency = 0.2,
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.GothamMedium,
	TextSize = 15,
	TextWrapped = true,
	Visible = false,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, toastLabel)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
}, toastLabel)
new("UISizeConstraint", { MaxSize = Vector2.new(520, math.huge) }, toastLabel)

local toastId = 0
toast = function(msg)
	toastId += 1
	local id = toastId
	toastLabel.Text = msg
	toastLabel.Visible = true
	task.delay(3, function()
		if toastId == id then
			toastLabel.Visible = false
		end
	end)
end

--========================================================================
-- Selection + Studio-style handles
--========================================================================
local selBox = new("SelectionBox", {
	Color3 = Color3.fromRGB(0, 170, 255),
	LineThickness = 0.03,
}, gui)

local moveHandles = new("Handles", {
	Style = Enum.HandlesStyle.Movement,
	Faces = Faces.new(Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Left,
		Enum.NormalId.Right, Enum.NormalId.Front, Enum.NormalId.Back),
	Color3 = Color3.fromRGB(255, 200, 50),
}, gui)

local scaleHandles = new("Handles", {
	Style = Enum.HandlesStyle.Resize,
	Faces = Faces.new(Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Left,
		Enum.NormalId.Right, Enum.NormalId.Front, Enum.NormalId.Back),
	Color3 = Color3.fromRGB(120, 220, 255),
}, gui)

local rotateHandles = new("ArcHandles", {
	Axes = Axes.new(Enum.Axis.X, Enum.Axis.Y, Enum.Axis.Z),
	Color3 = Color3.fromRGB(90, 160, 255),
}, gui)

local function refreshHandles()
	local p = selected
	selBox.Adornee = p
	moveHandles.Adornee = (p and mode == "Move") and p or nil
	scaleHandles.Adornee = (p and mode == "Scale") and p or nil
	rotateHandles.Adornee = (p and mode == "Rotate") and p or nil
end

selectPart = function(p)
	selected = p
	refreshHandles()
	onSelectionChanged()
end

local function setMode(m)
	mode = m
	refreshHandles()
	updateModeButtons()
end

-- Shared drag bookkeeping
local origCF, origSize

local function beginEdit()
	if not selected then return end
	origCF, origSize = selected.CFrame, selected.Size
	handleActive = true
	lastHandleTime = os.clock()
end

local function endEdit()
	handleActive = false
	lastHandleTime = os.clock()
	local part, cf, size = selected, origCF, origSize
	if part and cf and size and (part.CFrame ~= cf or part.Size ~= size) then
		pushUndo(function()
			part.Size = size
			part.CFrame = cf
		end)
	end
end

-- MOVE (arrows)
moveHandles.MouseButton1Down:Connect(beginEdit)
moveHandles.MouseDrag:Connect(function(face, distance)
	if not selected or not origCF then return end
	local d = snapOn and snapN(distance, CFG.MoveSnap) or distance
	local dir = origCF:VectorToWorldSpace(Vector3.FromNormalId(face))
	selected.CFrame = origCF + dir * d
end)
moveHandles.MouseButton1Up:Connect(endEdit)

-- SCALE (squares)
scaleHandles.MouseButton1Down:Connect(beginEdit)
scaleHandles.MouseDrag:Connect(function(face, distance)
	if not selected or not origCF then return end
	local d = snapOn and snapN(distance, CFG.ScaleSnap) or distance
	local axis = Vector3.FromNormalId(face)
	local axisAbs = Vector3.new(math.abs(axis.X), math.abs(axis.Y), math.abs(axis.Z))
	local current = origSize.X * axisAbs.X + origSize.Y * axisAbs.Y + origSize.Z * axisAbs.Z
	local newLen = math.max(CFG.MinSize, current + d)
	d = newLen - current

	local newSize
	if selected:IsA("Part") and selected.Shape == Enum.PartType.Ball then
		newSize = origSize * (newLen / current) -- balls stay round
	else
		newSize = origSize + axisAbs * d
	end
	selected.Size = newSize
	selected.CFrame = origCF + origCF:VectorToWorldSpace(axis) * (d / 2)
end)
scaleHandles.MouseButton1Up:Connect(endEdit)

-- ROTATE (rings with balls)
rotateHandles.MouseButton1Down:Connect(beginEdit)
rotateHandles.MouseDrag:Connect(function(axis, relativeAngle)
	if not selected or not origCF then return end
	local a = relativeAngle
	if snapOn then
		local step = math.rad(CFG.RotSnap)
		a = math.round(a / step) * step
	end
	selected.CFrame = origCF * CFrame.fromAxisAngle(Vector3.FromAxis(axis), a)
end)
rotateHandles.MouseButton1Up:Connect(endEdit)

--========================================================================
-- Actions
--========================================================================
local function addPart(kind)
	local cam = getCamera()
	local p = newPart(kind)
	local pos = (cam.CFrame * CFrame.new(0, 0, -CFG.SpawnDistance)).Position
	if snapOn then
		pos = Vector3.new(snapN(pos.X, CFG.MoveSnap), snapN(pos.Y, CFG.MoveSnap), snapN(pos.Z, CFG.MoveSnap))
	end
	p.CFrame = CFrame.new(pos)
	selectPart(p)
	pushUndo(function()
		if selected == p then selectPart(nil) end
		p.Parent = nil
	end)
end

local function duplicateSelected()
	local src = selected
	if not src then toast("Select a part first") return end
	local p = src:Clone()
	p.CFrame = src.CFrame + src.CFrame.RightVector * (src.Size.X + 0.5)
	p.Parent = buildFolder
	selectPart(p)
	pushUndo(function()
		if selected == p then selectPart(nil) end
		p.Parent = nil
	end)
end

local function deleteSelected()
	local p = selected
	if not p then toast("Select a part first") return end
	selectPart(nil)
	p.Parent = nil
	pushUndo(function()
		p.Parent = buildFolder
	end)
end

local function undo()
	local fn = table.remove(undoStack)
	if fn then
		fn()
	else
		toast("Nothing to undo")
	end
end

--========================================================================
-- Freecam
--========================================================================
local freecam = false
local camPos = Vector3.zero
local yaw, pitch = 0, 0
local flySpeed = CFG.FlySpeed
local keys = {}
local rmbDown = false
local joyVec = Vector2.zero
local upHeld, downHeld = 0, 0
local touchLooks = {}
local controls = nil
local onFreecamChanged = function(_on) end

local function getControls()
	if controls then return controls end
	local ok, res = pcall(function()
		local module = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 3)
		return require(module):GetControls()
	end)
	if ok then controls = res end
	return controls
end

local function setFreecam(on)
	if on == freecam then return end
	freecam = on
	keys = {}
	rmbDown = false
	touchLooks = {}
	upHeld, downHeld = 0, 0
	local cam = getCamera()
	local c = getControls()

	if on then
		local rx, ry = cam.CFrame:ToOrientation()
		pitch, yaw = rx, ry
		camPos = cam.CFrame.Position
		cam.CameraType = Enum.CameraType.Scriptable
		if c then c:Disable() end
		if UserInputService.TouchEnabled then
			toast("Freecam: left stick = move, drag the right side to look, ▲▼ = up/down")
		else
			toast("Freecam: WASD move, Q/E down/up, hold right mouse to look, scroll = speed")
		end
	else
		cam.CameraType = Enum.CameraType.Custom
		if c then c:Enable() end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	onFreecamChanged(on)
end

RunService:BindToRenderStep("ClientBuildFreecam", Enum.RenderPriority.Camera.Value + 1, function(dt)
	if not freecam then return end
	local cam = getCamera()
	local rot = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)

	local move = Vector3.zero
	if keys[Enum.KeyCode.W] then move += Vector3.new(0, 0, -1) end
	if keys[Enum.KeyCode.S] then move += Vector3.new(0, 0, 1) end
	if keys[Enum.KeyCode.A] then move += Vector3.new(-1, 0, 0) end
	if keys[Enum.KeyCode.D] then move += Vector3.new(1, 0, 0) end
	move += Vector3.new(joyVec.X, 0, joyVec.Y)
	if move.Magnitude > 1 then move = move.Unit end

	local vert = upHeld - downHeld
	if keys[Enum.KeyCode.E] or keys[Enum.KeyCode.Space] then vert += 1 end
	if keys[Enum.KeyCode.Q] then vert -= 1 end

	local speed = flySpeed * ((keys[Enum.KeyCode.LeftShift] and CFG.FastMultiplier) or 1)
	camPos += (rot:VectorToWorldSpace(move) + Vector3.new(0, vert, 0)) * speed * dt
	cam.CFrame = CFrame.new(camPos) * rot
end)

--========================================================================
-- Toolbar
--========================================================================
local bar = new("ScrollingFrame", {
	Name = "Toolbar",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -8),
	Size = UDim2.new(1, -16, 0, 60),
	BackgroundColor3 = Color3.fromRGB(25, 25, 30),
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollingDirection = Enum.ScrollingDirection.X,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.X,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, bar)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
	VerticalAlignment = Enum.VerticalAlignment.Center,
}, bar)
new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, bar)

local order = 0
local function addButton(text, callback)
	order += 1
	local b = new("TextButton", {
		Text = text,
		Size = UDim2.fromOffset(74, 44),
		BackgroundColor3 = COLOR_BTN,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		LayoutOrder = order,
	}, bar)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
	b.Activated:Connect(callback)
	return b
end

-- Add shapes
addButton("+ Block", function() addPart("Block") end)
addButton("+ Ball", function() addPart("Ball") end)
addButton("+ Cyl", function() addPart("Cylinder") end)
addButton("+ Wedge", function() addPart("Wedge") end)

-- Tool modes
local modeButtons = {}
modeButtons.Move = addButton("Move", function() setMode("Move") end)
modeButtons.Rotate = addButton("Rotate", function() setMode("Rotate") end)
modeButtons.Scale = addButton("Scale", function() setMode("Scale") end)
updateModeButtons = function()
	for m, b in pairs(modeButtons) do
		b.BackgroundColor3 = (m == mode) and COLOR_ACTIVE or COLOR_BTN
	end
end
updateModeButtons()

local snapBtn
snapBtn = addButton("Snap: ON", function()
	snapOn = not snapOn
	snapBtn.Text = snapOn and "Snap: ON" or "Snap: OFF"
end)

-- Popup menus (Color / Material): pick exactly what you want
local function makeMenu(cellSize)
	local f = new("Frame", {
		Visible = false,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -76),
		Size = UDim2.new(0.92, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(30, 31, 38),
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, gui)
	new("UICorner", { CornerRadius = UDim.new(0, 12) }, f)
	new("UISizeConstraint", { MaxSize = Vector2.new(420, math.huge) }, f)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
	}, f)
	new("UIGridLayout", {
		CellSize = cellSize,
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}, f)
	return f
end

local colorMenu = makeMenu(UDim2.fromOffset(44, 44))
local matMenu = makeMenu(UDim2.fromOffset(90, 40))

local transMenu -- built below, after the material menu

local function closeMenus()
	colorMenu.Visible = false
	matMenu.Visible = false
	if transMenu then
		transMenu.Visible = false
	end
end

local function toggleMenu(menu)
	local wasOpen = menu.Visible
	closeMenus()
	menu.Visible = not wasOpen
end

-- Color menu
local colorBtn
local swatches = {}

local function refreshColorMenu()
	local c = PALETTE[colorIndex]
	colorBtn.BackgroundColor3 = c
	colorBtn.TextColor3 = (c.R + c.G + c.B > 1.8) and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
	for i, s in ipairs(swatches) do
		s.stroke.Enabled = (i == colorIndex)
	end
end

local function applyColor(i)
	colorIndex = i
	local c = PALETTE[i]
	if selected then
		local p, old = selected, selected.Color
		p.Color = c
		pushUndo(function() p.Color = old end)
	end
	refreshColorMenu()
	closeMenus()
end

colorBtn = addButton("Color", function() toggleMenu(colorMenu) end)

for i, c in ipairs(PALETTE) do
	local s = new("TextButton", {
		Text = "",
		BackgroundColor3 = c,
		LayoutOrder = i,
		ZIndex = 5,
	}, colorMenu)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, s)
	local stroke = new("UIStroke", {
		Color = Color3.fromRGB(0, 170, 255),
		Thickness = 3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Enabled = false,
	}, s)
	swatches[i] = { button = s, stroke = stroke }
	s.Activated:Connect(function() applyColor(i) end)
end
refreshColorMenu()

-- Material menu
local matBtn
local matButtons = {}

local function refreshMatMenu()
	matBtn.Text = "Mat: " .. MATERIALS[matIndex].Name
	for i, b in ipairs(matButtons) do
		b.BackgroundColor3 = (i == matIndex) and COLOR_ACTIVE or COLOR_BTN
	end
end

local function applyMaterial(i)
	matIndex = i
	local m = MATERIALS[i]
	if selected then
		local p, old = selected, selected.Material
		p.Material = m
		pushUndo(function() p.Material = old end)
	end
	refreshMatMenu()
	closeMenus()
end

matBtn = addButton("Mat", function() toggleMenu(matMenu) end)
matBtn.TextSize = 12

for i, m in ipairs(MATERIALS) do
	local b = new("TextButton", {
		Text = m.Name,
		BackgroundColor3 = COLOR_BTN,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		LayoutOrder = i,
		ZIndex = 5,
	}, matMenu)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
	matButtons[i] = b
	b.Activated:Connect(function() applyMaterial(i) end)
end
refreshMatMenu()

-- Transparency menu: slider + presets
transMenu = new("Frame", {
	Visible = false,
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -76),
	Size = UDim2.new(0.92, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Color3.fromRGB(30, 31, 38),
	BackgroundTransparency = 0.05,
	BorderSizePixel = 0,
	ZIndex = 4,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 12) }, transMenu)
new("UISizeConstraint", { MaxSize = Vector2.new(420, math.huge) }, transMenu)
new("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12),
	PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
}, transMenu)
new("UIListLayout", {
	Padding = UDim.new(0, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, transMenu)

local transLabel = new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.GothamMedium,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = 1,
	ZIndex = 5,
}, transMenu)

local track = new("Frame", {
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundTransparency = 1,
	Active = true, -- sinks input so dragging the slider never rotates the camera
	LayoutOrder = 2,
	ZIndex = 5,
}, transMenu)
local sliderBar = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 0, 0.5, 0),
	Size = UDim2.new(1, 0, 0, 8),
	BackgroundColor3 = Color3.fromRGB(70, 72, 82),
	BorderSizePixel = 0,
	ZIndex = 5,
}, track)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, sliderBar)
local fill = new("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = COLOR_ACTIVE,
	BorderSizePixel = 0,
	ZIndex = 6,
}, sliderBar)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
local knob = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0, 0, 0.5, 0),
	Size = UDim2.fromOffset(30, 30),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	ZIndex = 7,
}, track)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

local function setTransUI(v)
	fill.Size = UDim2.fromScale(v, 1)
	knob.Position = UDim2.new(v, 0, 0.5, 0)
	transLabel.Text = ("Transparency: %d%%"):format(math.round(v * 100))
end

local sliding, slideInput, slidePart, slideOld = false, nil, nil, 0

local function transFromInput(input)
	-- only X is used, so the top-bar inset can't throw it off
	local v = (input.Position.X - sliderBar.AbsolutePosition.X) / math.max(sliderBar.AbsoluteSize.X, 1)
	return math.round(math.clamp(v, 0, 1) * 20) / 20 -- 5% steps
end

track.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if (t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1) and selected then
		sliding, slideInput = true, input
		slidePart, slideOld = selected, selected.Transparency
		local v = transFromInput(input)
		slidePart.Transparency = v
		setTransUI(v)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not sliding or not slidePart then return end
	local isDrag = input == slideInput
		or (input.UserInputType == Enum.UserInputType.MouseMovement
			and slideInput.UserInputType == Enum.UserInputType.MouseButton1)
	if isDrag then
		local v = transFromInput(input)
		slidePart.Transparency = v
		setTransUI(v)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not sliding then return end
	local ended = input == slideInput
		or (slideInput.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1)
	if ended then
		sliding = false
		local p, old = slidePart, slideOld
		if p and p.Transparency ~= old then
			pushUndo(function() p.Transparency = old end)
		end
	end
end)

local presetRow = new("Frame", {
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundTransparency = 1,
	LayoutOrder = 3,
	ZIndex = 5,
}, transMenu)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, presetRow)

for i, pct in ipairs({ 0, 25, 50, 75, 100 }) do
	local b = new("TextButton", {
		Text = pct .. "%",
		Size = UDim2.new(0.2, -7, 1, 0),
		BackgroundColor3 = COLOR_BTN,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		LayoutOrder = i,
		ZIndex = 6,
	}, presetRow)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
	b.Activated:Connect(function()
		if not selected then return end
		local p, old, v = selected, selected.Transparency, pct / 100
		if old == v then return end
		p.Transparency = v
		setTransUI(v)
		pushUndo(function() p.Transparency = old end)
	end)
end

onSelectionChanged = function()
	if selected then
		setTransUI(selected.Transparency)
	else
		transMenu.Visible = false
	end
end

addButton("Trans", function()
	if not selected then
		toast("Select a part first")
		return
	end
	setTransUI(selected.Transparency)
	toggleMenu(transMenu)
end)

addButton("Dup", duplicateSelected)
addButton("Del", deleteSelected)
addButton("Undo", undo)

local freecamBtn
freecamBtn = addButton("Freecam", function() setFreecam(not freecam) end)

--========================================================================
-- Share toggle (needs ClientBuildStudio_server.lua in ServerScriptService)
--========================================================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local syncRemote = nil
local shareOn = false
local sent = {} -- [part] = last snapshot sent to the server
local partIds = setmetatable({}, { __mode = "k" }) -- [part] = id
local SYNC_INTERVAL = 0.1
local SYNC_CHUNK = 150
local syncAcc = 0

local function getSyncRemote()
	if syncRemote then return syncRemote end
	local r = ReplicatedStorage:WaitForChild("BuildSync", 3)
	if r then
		syncRemote = r
		r.OnClientEvent:Connect(function(kind, n)
			if kind == "limit" then
				toast(("Shared build limit reached (%d parts). Extra parts stay local only."):format(n or 0))
			end
		end)
	end
	return syncRemote
end

local function idFor(part)
	local id = partIds[part]
	if not id then
		id = HttpService:GenerateGUID(false):gsub("-", "")
		partIds[part] = id
	end
	return id
end

local function snapshotOf(part)
	return { cf = part.CFrame, s = part.Size, c = part.Color, m = part.Material, t = part.Transparency }
end

local function snapChanged(a, b)
	return a.cf ~= b.cf or a.s ~= b.s or a.c ~= b.c or a.m ~= b.m or a.t ~= b.t
end

RunService.Heartbeat:Connect(function(dt)
	if not shareOn or not syncRemote then return end
	syncAcc += dt
	if syncAcc < SYNC_INTERVAL then return end
	syncAcc = 0

	local sets, dels = {}, {}

	for part in pairs(sent) do
		if part.Parent ~= buildFolder then
			table.insert(dels, partIds[part])
			sent[part] = nil
		end
	end

	for _, part in ipairs(buildFolder:GetChildren()) do
		if part:IsA("BasePart") then
			local snap = snapshotOf(part)
			local old = sent[part]
			if not old or snapChanged(old, snap) then
				sent[part] = snap
				table.insert(sets, {
					id = idFor(part),
					k = kindOf(part),
					cf = snap.cf,
					s = snap.s,
					c = snap.c,
					m = snap.m.Name,
					t = snap.t,
				})
			end
		end
	end

	-- send in chunks so big imports don't create one huge message
	local si, di = 1, 1
	while si <= #sets or di <= #dels do
		local chunk = { sets = {}, dels = {} }
		local budget = SYNC_CHUNK
		while di <= #dels and budget > 0 do
			table.insert(chunk.dels, dels[di])
			di += 1
			budget -= 1
		end
		while si <= #sets and budget > 0 do
			table.insert(chunk.sets, sets[si])
			si += 1
			budget -= 1
		end
		syncRemote:FireServer("sync", chunk)
	end
end)

-- Your own shared parts come back from the server too; hide that copy for you
-- (you already see your local one) so there's no flicker/overlap.
local userIdStr = tostring(player.UserId)
local function hideOwnMirror(inst)
	if inst:IsA("BasePart") then
		local folder = inst.Parent
		if folder and folder.Name == userIdStr and folder.Parent and folder.Parent.Name == "SharedBuild" then
			inst.LocalTransparencyModifier = 1
		end
	end
end
Workspace.DescendantAdded:Connect(hideOwnMirror)
do
	local existing = Workspace:FindFirstChild("SharedBuild")
	if existing then
		for _, d in ipairs(existing:GetDescendants()) do
			hideOwnMirror(d)
		end
	end
end

local shareBtn
local function updateShareBtn()
	shareBtn.Text = shareOn and "Share: ALL" or "Share: ME"
	shareBtn.BackgroundColor3 = shareOn and Color3.fromRGB(40, 150, 80) or COLOR_BTN
end

shareBtn = addButton("Share: ME", function()
	if not shareOn then
		if not getSyncRemote() then
			toast("Sharing needs ClientBuildStudio_server.lua in ServerScriptService (as a Script).")
			return
		end
		shareOn = true
		sent = {}
		syncAcc = SYNC_INTERVAL
		toast("Sharing ON: other players can see your build now.")
	else
		shareOn = false
		sent = {}
		if syncRemote then
			syncRemote:FireServer("clear")
		end
		toast("Sharing OFF: only you can see your build.")
	end
	updateShareBtn()
end)
updateShareBtn()

-- Save / Import panel
local panel = new("Frame", {
	Visible = false,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.42),
	Size = UDim2.fromScale(0.92, 0.6),
	BackgroundColor3 = Color3.fromRGB(30, 31, 38),
	BorderSizePixel = 0,
	ZIndex = 5,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 12) }, panel)
new("UISizeConstraint", { MaxSize = Vector2.new(560, 420) }, panel)

local panelTitle = new("TextLabel", {
	Position = UDim2.fromOffset(12, 8),
	Size = UDim2.new(1, -24, 0, 36),
	BackgroundTransparency = 1,
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 6,
}, panel)

local box = new("TextBox", {
	Position = UDim2.fromOffset(12, 48),
	Size = UDim2.new(1, -24, 1, -112),
	BackgroundColor3 = Color3.fromRGB(18, 18, 22),
	TextColor3 = Color3.fromRGB(220, 220, 220),
	PlaceholderText = "Paste a save code here…",
	Font = Enum.Font.Code,
	TextSize = 12,
	TextWrapped = true,
	ClearTextOnFocus = false,
	MultiLine = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	ZIndex = 6,
}, panel)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, box)

local panelRow = new("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 12, 1, -10),
	Size = UDim2.new(1, -24, 0, 44),
	BackgroundTransparency = 1,
	ZIndex = 6,
}, panel)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, panelRow)

local function panelButton(text, cb, layoutOrder)
	local b = new("TextButton", {
		Text = text,
		Size = UDim2.new(0.33, -6, 1, 0),
		BackgroundColor3 = COLOR_BTN,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		LayoutOrder = layoutOrder,
		ZIndex = 7,
	}, panelRow)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
	b.Activated:Connect(cb)
	return b
end

panelButton("Import (add)", function() importJSON(box.Text, false) end, 1)
panelButton("Import (replace)", function() importJSON(box.Text, true) end, 2)
panelButton("Close", function() panel.Visible = false end, 3)

local function openPanel(isSave)
	panel.Visible = true
	if isSave then
		box.Text = serialize()
		panelTitle.Text = "SAVE: tap the box, select all, copy and keep it somewhere safe."
	else
		box.Text = ""
		panelTitle.Text = "IMPORT: paste a save code below, then press Import."
	end
end

addButton("Save", function() openPanel(true) end)
addButton("Load", function() openPanel(false) end)

--========================================================================
-- Freecam touch UI (joystick + up/down)
--========================================================================
local JOY_R = 50
local joyBase = new("Frame", {
	Name = "Joystick",
	Size = UDim2.fromOffset(130, 130),
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 30, 1, -90),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.6,
	Active = true,
	Visible = false,
}, gui)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, joyBase)
local joyKnob = new("Frame", {
	Size = UDim2.fromOffset(56, 56),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BackgroundTransparency = 0.3,
}, joyBase)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, joyKnob)

local joyTouch, joyStart
joyBase.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch and not joyTouch then
		joyTouch = input
		joyStart = Vector2.new(input.Position.X, input.Position.Y)
	end
end)

local function holdButton(text, yOffset, setter)
	local b = new("TextButton", {
		Text = text,
		Size = UDim2.fromOffset(60, 60),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, yOffset),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 24,
		AutoButtonColor = false,
		Visible = false,
	}, gui)
	new("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
	b.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
			setter(1)
		end
	end)
	b.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
			setter(0)
		end
	end)
	return b
end

local upBtn = holdButton("▲", -150, function(v) upHeld = v end)
local downBtn = holdButton("▼", -84, function(v) downHeld = v end)

onFreecamChanged = function(on)
	freecamBtn.BackgroundColor3 = on and COLOR_ACTIVE or COLOR_BTN
	local touchUi = on and UserInputService.TouchEnabled
	joyBase.Visible = touchUi
	upBtn.Visible = touchUi
	downBtn.Visible = touchUi
	if not on then
		joyTouch, joyVec = nil, Vector2.zero
		joyKnob.Position = UDim2.fromScale(0.5, 0.5)
	end
end

--========================================================================
-- Input
--========================================================================
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { buildFolder }

local function pickAt(pos)
	local ray = getCamera():ScreenPointToRay(pos.X, pos.Y)
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, rayParams)
	return result and result.Instance or nil
end

local pressInfo = setmetatable({}, { __mode = "k" })

UserInputService.InputBegan:Connect(function(input, gp)
	local t = input.UserInputType

	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		pressInfo[input] = {
			pos = Vector2.new(input.Position.X, input.Position.Y),
			time = os.clock(),
			gp = gp,
		}
		if t == Enum.UserInputType.Touch and freecam and not gp then
			touchLooks[input] = true
		end

	elseif t == Enum.UserInputType.MouseButton2 then
		if freecam and not gp then
			rmbDown = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end

	elseif t == Enum.UserInputType.Keyboard then
		if gp then return end
		local k = input.KeyCode
		keys[k] = true
		local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)

		if k == Enum.KeyCode.F then
			setFreecam(not freecam)
		elseif k == Enum.KeyCode.One then
			setMode("Move")
		elseif k == Enum.KeyCode.Two then
			setMode("Rotate")
		elseif k == Enum.KeyCode.Three then
			setMode("Scale")
		elseif k == Enum.KeyCode.Delete or k == Enum.KeyCode.Backspace then
			deleteSelected()
		elseif k == Enum.KeyCode.Z and ctrl then
			undo()
		elseif k == Enum.KeyCode.D and ctrl then
			duplicateSelected()
		end
	end
end)

UserInputService.InputChanged:Connect(function(input, _gp)
	local t = input.UserInputType

	-- joystick
	if input == joyTouch then
		local off = Vector2.new(input.Position.X, input.Position.Y) - joyStart
		if off.Magnitude > JOY_R then
			off = off.Unit * JOY_R
		end
		joyVec = off / JOY_R
		joyKnob.Position = UDim2.new(0.5, off.X, 0.5, off.Y)
		return
	end

	if not freecam then return end

	if t == Enum.UserInputType.MouseMovement and rmbDown then
		yaw -= math.rad(input.Delta.X * CFG.MouseSens)
		pitch = math.clamp(pitch - math.rad(input.Delta.Y * CFG.MouseSens), -1.55, 1.55)

	elseif t == Enum.UserInputType.MouseWheel then
		flySpeed = math.clamp(flySpeed * (1 + 0.15 * input.Position.Z), 5, 400)

	elseif t == Enum.UserInputType.Touch and touchLooks[input] and not handleActive then
		yaw -= math.rad(input.Delta.X * CFG.TouchSens)
		pitch = math.clamp(pitch - math.rad(input.Delta.Y * CFG.TouchSens), -1.55, 1.55)
	end
end)

UserInputService.InputEnded:Connect(function(input, _gp)
	local t = input.UserInputType

	if input == joyTouch then
		joyTouch = nil
		joyVec = Vector2.zero
		joyKnob.Position = UDim2.fromScale(0.5, 0.5)
	end
	touchLooks[input] = nil

	if t == Enum.UserInputType.Keyboard then
		keys[input.KeyCode] = nil

	elseif t == Enum.UserInputType.MouseButton2 then
		rmbDown = false
		if freecam then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end

	elseif t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		local info = pressInfo[input]
		pressInfo[input] = nil
		if not info or info.gp then return end
		if panel.Visible then return end
		closeMenus()

		local endPos = Vector2.new(input.Position.X, input.Position.Y)
		local isTap = (endPos - info.pos).Magnitude < 12 and (os.clock() - info.time) < 0.5
		if not isTap then return end
		if handleActive or (os.clock() - lastHandleTime) < 0.3 then return end

		local hit = pickAt(info.pos)
		if hit and hit:IsDescendantOf(buildFolder) then
			selectPart(hit)
		else
			selectPart(nil)
		end
	end
end)

toast("Build tool ready: tap + Block to start. Tap a part to select it.")
