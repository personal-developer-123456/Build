--// GEN TAB: BRUSHES, PARAMETRIC BUILDERS, SMART SNAP ------------------------
do
	local pGen = addPage("Gen")

	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include

	--// Smart snap ---------------------------------------------------------------
	-- Snaps a point to the nearest corner (rank 1), edge (rank 2) or face (rank 3)
	-- of a nearby build part, as long as it is within `reach` studs.
	local function signOf(x)
		return x < 0 and -1 or 1
	end

	local function snapPointToPart(point, part, reach)
		local cf = part.CFrame
		local h = part.Size / 2
		local p = cf:PointToObjectSpace(point)
		local sx, sy, sz = signOf(p.X), signOf(p.Y), signOf(p.Z)
		local cx = math.clamp(p.X, -h.X, h.X)
		local cy = math.clamp(p.Y, -h.Y, h.Y)
		local cz = math.clamp(p.Z, -h.Z, h.Z)
		local best, bestRank, bestDist
		local function consider(candidate, rank)
			local d = (candidate - p).Magnitude
			if d <= reach and (not bestRank or rank < bestRank or (rank == bestRank and d < bestDist)) then
				best, bestRank, bestDist = candidate, rank, d
			end
		end
		consider(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z), 1) -- corner
		consider(Vector3.new(cx, sy * h.Y, sz * h.Z), 2) -- edges
		consider(Vector3.new(sx * h.X, cy, sz * h.Z), 2)
		consider(Vector3.new(sx * h.X, sy * h.Y, cz), 2)
		consider(Vector3.new(sx * h.X, cy, cz), 3) -- faces
		consider(Vector3.new(cx, sy * h.Y, cz), 3)
		consider(Vector3.new(cx, cy, sz * h.Z), 3)
		if best then return cf:PointToWorldSpace(best), bestRank, bestDist end
		return nil
	end

	local function findSnap(point, reach)
		overlap.FilterDescendantsInstances = { container } -- re-set each time: `container` can be swapped by the self-tests
		local best, bestRank, bestDist
		for _, part in ipairs(Workspace:GetPartBoundsInRadius(point, reach, overlap)) do
			local wp, rank, dist = snapPointToPart(point, part, reach)
			if wp and (not bestRank or rank < bestRank or (rank == bestRank and dist < bestDist)) then
				best, bestRank, bestDist = wp, rank, dist
			end
		end
		return best, bestRank, bestDist
	end

	-- Moves a placement CFrame so the best corner of the ghost lines up with a
	-- feature of a nearby part. Returns the new CFrame and the snap point (or nil).
	local function smartSnapCF(cf, size)
		local h = size / 2
		local bestOffset, bestRank, bestDist, bestTarget
		for sx = -1, 1, 2 do
			for sy = -1, 1, 2 do
				for sz = -1, 1, 2 do
					local corner_ = cf * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)
					local wp, rank, dist = findSnap(corner_, state.smartReach)
					if wp and (not bestRank or rank < bestRank or (rank == bestRank and dist < bestDist)) then
						bestOffset, bestRank, bestDist, bestTarget = wp - corner_, rank, dist, wp
					end
				end
			end
		end
		if bestOffset then return cf + bestOffset, bestTarget end
		return cf, nil
	end

	-- the placement CFrame used by the ghost AND by placing (Part 1 calls this by name)
	local baseCompute = computePlacementCF
	computePlacementCF = function(result)
		if state.genMode ~= "Single" then
			P3.snapTarget = nil
			return nil -- brush modes draw their own preview instead of the single ghost
		end
		local cf = baseCompute(result)
		if cf and state.smartSnap then
			local snapped, target = smartSnapCF(cf, placementSize())
			P3.snapTarget = target
			return snapped
		end
		P3.snapTarget = nil
		return cf
	end

	-- grid snap + smart snap for a clicked world point (brush start / end)
	local function genPoint(result)
		local p = result.Position
		if state.snapEnabled then
			local step = gridStep()
			local n = result.Normal
			local function axis(v, nn)
				if math.abs(nn) > 0.9 then return v end -- keep the contact axis exact
				return snap(v, step)
			end
			p = Vector3.new(axis(p.X, n.X), axis(p.Y, n.Y), axis(p.Z, n.Z))
		end
		P3.snapTarget = nil
		if state.smartSnap then
			local wp = findSnap(p, state.smartReach)
			if wp then
				p = wp
				P3.snapTarget = wp
			end
		end
		return p
	end

	--// Brushes ------------------------------------------------------------------
	-- Each brush turns two points into ONE box ("region"): { cf, size }
	local function genRegion(mode, a, b)
		local th, ht = state.genThickness, state.genHeight
		if mode == "Line" then
			local d = b - a
			if d.Magnitude < 0.05 then return nil end
			local up = math.abs(d.Unit.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
			return { cf = CFrame.lookAt((a + b) / 2, b, up), size = Vector3.new(th, th, d.Magnitude) }
		elseif mode == "Wall" then
			local flat = Vector3.new(b.X, a.Y, b.Z)
			local d = flat - a
			if d.Magnitude < 0.05 then return nil end
			local mid = (a + flat) / 2 + Vector3.new(0, ht / 2, 0)
			return { cf = CFrame.lookAt(mid, mid + d.Unit), size = Vector3.new(th, ht, d.Magnitude) }
		elseif mode == "Floor" then
			local dx, dz = math.abs(b.X - a.X), math.abs(b.Z - a.Z)
			if dx < 0.05 or dz < 0.05 then return nil end
			return { cf = CFrame.new((a.X + b.X) / 2, a.Y + th / 2, (a.Z + b.Z) / 2), size = Vector3.new(dx, th, dz) }
		elseif mode == "Fill" then
			local dx, dz = math.abs(b.X - a.X), math.abs(b.Z - a.Z)
			if dx < 0.05 or dz < 0.05 then return nil end
			local y0, y1 = math.min(a.Y, b.Y), math.max(a.Y, b.Y)
			if y1 - y0 < 0.05 then y1 = y0 + ht end -- flat click: extrude upwards by the height setting
			return {
				cf = CFrame.new((a.X + b.X) / 2, (y0 + y1) / 2, (a.Z + b.Z) / 2),
				size = Vector3.new(dx, y1 - y0, dz),
			}
		end
		return nil
	end

	local function specsFromRegion(region)
		if state.genMode == "Fill" and state.fillTiled then
			-- tile the region with copies of the current part, stretched slightly so there are no gaps
			local cell = placementSize()
			local size = region.size
			local nx = math.max(1, math.floor(size.X / cell.X + 0.5))
			local ny = math.max(1, math.floor(size.Y / cell.Y + 0.5))
			local nz = math.max(1, math.floor(size.Z / cell.Z + 0.5))
			if nx * ny * nz > CONFIG.MaxParts - partCount() then
				ui.notify("Fill needs " .. (nx * ny * nz) .. " parts - over the limit")
				return nil
			end
			local origin = region.cf.Position - size / 2
			local step = Vector3.new(size.X / nx, size.Y / ny, size.Z / nz)
			local specs = {}
			for i = 0, nx - 1 do
				for j = 0, ny - 1 do
					for k = 0, nz - 1 do
						specs[#specs + 1] = {
							shape = state.shape.Name,
							size = step,
							cf = CFrame.new(origin + Vector3.new((i + 0.5) * step.X, (j + 0.5) * step.Y, (k + 0.5) * step.Z)),
						}
					end
				end
			end
			return specs
		end
		return { { shape = "Block", size = region.size, cf = region.cf } }
	end

	local function genClick(result)
		P3.lastClick = result.Position
		local pt = genPoint(result)
		if not P3.genStart then
			P3.genStart = pt
			ui.notify(state.genMode .. ": now pick the end point")
			return
		end
		local region = genRegion(state.genMode, P3.genStart, pt)
		P3.genStart = nil
		if not region then
			ui.notify("Too small - try again")
			return
		end
		local specs = specsFromRegion(region)
		if specs then buildFromSpecs(state.genMode, specs, CFrame.new(), false) end
	end

	-- brush modes take over world clicks while the Build tool is active
	local originalPointer = onWorldPointer
	onWorldPointer = function(ray)
		local hit = castRay(ray)
		if hit then P3.lastClick = hit.Position end
		if state.tool == "Build" and state.genMode ~= "Single" then
			if hit then genClick(hit) end
			return
		end
		originalPointer(ray)
	end

	-- Enter / PLACE only make sense for single parts
	local originalPlace = placeAtAim
	placeAtAim = function()
		if state.genMode ~= "Single" then
			ui.notify("Brush mode: click a start point, then an end point")
			return
		end
		originalPlace()
	end

	function P3.cycleBrush()
		local idx = table.find(MODES, state.genMode) or 1
		state.genMode = MODES[idx % #MODES + 1]
		P3.genStart = nil
		state.aim = nil
		refreshAll()
		ui.notify("Brush: " .. state.genMode)
	end

	--// Previews (start marker, region box, snap guide lines) -------------------
	local startMarker = makeMarker(Enum.PartType.Ball, Vector3.new(0.9, 0.9, 0.9), THEME.Good)
	local previewBox = makeMarker(Enum.PartType.Block, Vector3.one, THEME.Accent, 0.6)
	previewBox.Material = Enum.Material.SmoothPlastic
	local guides = {
		makeMarker(Enum.PartType.Block, Vector3.new(8, 0.06, 0.06), Color3.fromRGB(255, 90, 90)),
		makeMarker(Enum.PartType.Block, Vector3.new(0.06, 8, 0.06), Color3.fromRGB(90, 255, 120)),
		makeMarker(Enum.PartType.Block, Vector3.new(0.06, 0.06, 8), Color3.fromRGB(90, 150, 255)),
	}

	local function hoverPoint()
		if not hoverAimActive() then return nil end
		local loc = UserInputService:GetMouseLocation()
		if isOverUI(loc) then return nil end
		local r = castRay(Workspace.CurrentCamera:ViewportPointToRay(loc.X, loc.Y))
		return r and genPoint(r) or nil
	end

	connect(RunService.RenderStepped, function()
		local cam = Workspace.CurrentCamera
		if not cam then return end
		local brush = state.tool == "Build" and state.genMode ~= "Single"
		if not brush then P3.genStart = nil end

		local region
		if brush then
			P3.snapTarget = nil
			local hp = hoverPoint() -- also refreshes P3.snapTarget
			if hp and P3.genStart then region = genRegion(state.genMode, P3.genStart, hp) end
		end

		startMarker.Parent = (brush and P3.genStart) and cam or nil
		if brush and P3.genStart then startMarker.Position = P3.genStart end

		if region then
			previewBox.Size = clampV(region.size)
			previewBox.CFrame = region.cf
			previewBox.Parent = cam
		else
			previewBox.Parent = nil
		end

		local showGuides = P3.snapTarget ~= nil and state.tool == "Build" and (brush or state.showGhost)
		for i, g in ipairs(guides) do
			if showGuides then
				g.CFrame = CFrame.new(P3.snapTarget)
				g.Parent = cam
			else
				g.Parent = nil
			end
		end
	end)

	--// Parametric builders ------------------------------------------------------
	-- Local space: origin = bottom centre of the structure, it grows towards -Z
	-- (the way the camera was facing). params = { key, label, default, min, max, step }
	local BUILDERS = {
		{
			name = "Stairs",
			params = {
				{ "n", "Steps", 8, 1, 64, 1 }, { "w", "Width", 6, 1, 64, 1 },
				{ "rise", "Rise per step", 1, 0.25, 8, 0.25 }, { "run", "Depth per step", 2, 0.5, 16, 0.5 },
			},
			make = function(p)
				local specs = {}
				for i = 0, math.floor(p.n) - 1 do
					local h = p.rise * (i + 1) -- solid steps, so nothing floats
					specs[#specs + 1] = {
						size = Vector3.new(p.w, h, p.run), cf = CFrame.new(0, h / 2, -(i + 0.5) * p.run), name = "Stair",
					}
				end
				return specs
			end,
		},
		{
			name = "Arch",
			params = {
				{ "radius", "Opening radius", 6, 2, 60, 1 }, { "thick", "Thickness", 2, 0.5, 16, 0.5 },
				{ "depth", "Depth", 3, 0.5, 32, 0.5 }, { "segs", "Segments", 12, 4, 48, 1 },
				{ "legs", "Pillar height", 6, 0, 64, 1 },
			},
			make = function(p)
				local specs = {}
				local segs = math.floor(p.segs)
				local dTheta = math.pi / segs
				local chord = 2 * (p.radius + p.thick) * math.sin(dTheta / 2)
				local rc = p.radius + p.thick / 2
				for i = 0, segs - 1 do
					local th = (i + 0.5) * dTheta
					specs[#specs + 1] = {
						size = Vector3.new(chord, p.thick, p.depth),
						cf = CFrame.new(rc * math.cos(th), p.legs + rc * math.sin(th), 0) * CFrame.Angles(0, 0, th - math.pi / 2),
						name = "Arch",
					}
				end
				if p.legs > 0 then
					for _, side in ipairs({ -1, 1 }) do
						specs[#specs + 1] = {
							size = Vector3.new(p.thick, p.legs, p.depth), cf = CFrame.new(side * rc, p.legs / 2, 0), name = "Pillar",
						}
					end
				end
				return specs
			end,
		},
		{
			name = "Roof",
			params = {
				{ "width", "Width", 12, 2, 128, 1 }, { "length", "Length", 14, 2, 128, 1 },
				{ "pitch", "Pitch (degrees)", 30, 5, 70, 5 },
			},
			make = function(p)
				local a = math.rad(p.pitch)
				local half = p.width / 2
				local slope = half / math.cos(a)
				local rise = half * math.tan(a)
				return {
					{ size = Vector3.new(slope, 0.6, p.length), cf = CFrame.new(-half / 2, rise / 2, 0) * CFrame.Angles(0, 0, a), name = "Roof" },
					{ size = Vector3.new(slope, 0.6, p.length), cf = CFrame.new(half / 2, rise / 2, 0) * CFrame.Angles(0, 0, -a), name = "Roof" },
				}
			end,
		},
		{
			name = "Column",
			params = { { "height", "Height", 12, 3, 128, 1 }, { "radius", "Radius", 1.5, 0.5, 16, 0.5 } },
			make = function(p)
				local base = 2 * p.radius + 1
				return {
					{ size = Vector3.new(base, 1, base), cf = CFrame.new(0, 0.5, 0), name = "ColumnBase" },
					{
						shape = "Cylinder", -- cylinders run along X, so turn it upright
						size = Vector3.new(p.height - 2, 2 * p.radius, 2 * p.radius),
						cf = CFrame.new(0, 1 + (p.height - 2) / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
						name = "ColumnShaft",
					},
					{ size = Vector3.new(base, 1, base), cf = CFrame.new(0, p.height - 0.5, 0), name = "ColumnCap" },
				}
			end,
		},
		{
			name = "Fence",
			params = {
				{ "length", "Length", 16, 2, 256, 2 }, { "spacing", "Post spacing", 4, 1, 32, 1 },
				{ "height", "Height", 4, 1, 32, 1 },
			},
			make = function(p)
				local specs = {}
				local n = math.max(1, math.floor(p.length / p.spacing + 0.5))
				for i = 0, n do
					local x = -p.length / 2 + p.length * i / n
					specs[#specs + 1] = { size = Vector3.new(0.6, p.height, 0.6), cf = CFrame.new(x, p.height / 2, 0), name = "FencePost" }
				end
				for _, f in ipairs({ 0.35, 0.8 }) do
					specs[#specs + 1] = { size = Vector3.new(p.length, 0.3, 0.3), cf = CFrame.new(0, p.height * f, 0), name = "FenceRail" }
				end
				return specs
			end,
		},
	}

	--// Tab UI -------------------------------------------------------------------
	header(pGen, "BRUSH MODE (Build tool)")
	chipRow(pGen, nil, MODES, function()
		return table.find(MODES, state.genMode)
	end, function(i)
		state.genMode = MODES[i]
		P3.genStart = nil
		state.aim = nil
	end, 56)
	label(pGen, "Single = normal placing. Line / Wall / Floor / Fill: click a start point, then an end point. Key B cycles the modes.", {
		Color = THEME.SubText, TextSize = 11, AutoSize = true,
	})
	labeledStepper(pGen, "Wall / fill height", 1, 0.25, 256, function()
		return state.genHeight
	end, function(v)
		state.genHeight = v
	end)
	labeledStepper(pGen, "Thickness", 0.25, 0.05, 64, function()
		return state.genThickness
	end, function(v)
		state.genThickness = v
	end)
	toggle(pGen, "Fill: tile parts", function()
		return state.fillTiled
	end, function(v)
		state.fillTiled = v
	end)

	header(pGen, "SMART SNAP")
	toggle(pGen, "Smart snap", function()
		return state.smartSnap
	end, function(v)
		state.smartSnap = v
	end)
	labeledStepper(pGen, "Snap reach (studs)", 0.25, 0.25, 8, function()
		return state.smartReach
	end, function(v)
		state.smartReach = v
	end)
	label(pGen, "Snaps to corners, edges and faces of nearby parts and draws red / green / blue guide lines. Locked or hidden parts are ignored.", {
		Color = THEME.SubText, TextSize = 11, AutoSize = true,
	})

	label(pGen, "Builders appear at the centre of your screen (on the surface you are looking at), facing the camera.", {
		Color = THEME.SubText, TextSize = 11, AutoSize = true,
	})
	state.gen = {}
	for _, b in ipairs(BUILDERS) do
		state.gen[b.name] = {}
		for _, prm in ipairs(b.params) do state.gen[b.name][prm[1]] = prm[3] end
		header(pGen, "BUILDER: " .. string.upper(b.name))
		for _, prm in ipairs(b.params) do
			local key = prm[1]
			labeledStepper(pGen, prm[2], prm[6], prm[4], prm[5], function()
				return state.gen[b.name][key]
			end, function(v)
				state.gen[b.name][key] = v
			end)
		end
		button(pGen, "Place " .. string.lower(b.name), UDim2.new(1, 0, 0, 36), function()
			buildFromSpecs(b.name, b.make(state.gen[b.name]), screenAnchor(), true)
		end, THEME.Good)
	end

	addTooltip(tabButtons.Gen, "Brushes, stairs / arch / roof builders, smart snap")
end

