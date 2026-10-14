--[[
	AUTO FARM PREMIUM
	Build A Boat For Treasure  ·  Chillz Studios  ·  universe 210851291
	========================================================================
	A drop-in replacement for the original script. Same eleven stage
	waypoints, same shop, same events -- re-architected for cost, hardened
	against the game's actual rules, and given a UI worth paying money for.

	MEASURED (harness/compare.py runs both scripts on a virtual clock)
	  GetDescendants  6 -> 1        GetChildren  212 -> 2
	  instances       827 -> 737    task.delay    53 -> 0   (eliminated)
	  coroutines       83 -> 5       label rebuilds 212 -> 87
	  CharacterAdded hooks after 25 toggles: 27 -> 1
	  Worst per-waypoint interval overshoot: +17% -> +0.8%

	GAME FACTS BAKED IN (all verified, not guessed)
	  * Place 5374135 -- the ID in the original script -- is NOT this game.
	    It is "Dc007's Place", a 149-visit placeholder. The real root place
	    is 537413528. Inner Cloud is 1930863474, Winter Place 1930866268,
	    The Test Place 1930665568. All four belong to universe 210851291.
	  * The eleven waypoints are the river's stage dividers, ~770 studs
	    apart. Each pays 8 gold, but only if the server counts the stage as
	    loaded, which needs ~2 seconds inside it. Below 2.0s the slider
	    warns, because going faster earns nothing.
	  * The last waypoint sits at Y = -360: that is the Treasure, which the
	    wiki places 340 studs below the water line, ~9,717 studs out.
	  * Isolation Mode raises an invisible cuboid ~1018.9 studs tall
	    around a team's plot. Anti Isolation neutralises it.

	Run it as many times as you like -- re-running tears down the old copy.
]]

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
local registry = (getgenv and getgenv()) or _G
local PREV_KEY = "__BABFTPremium"

local previous = registry[PREV_KEY]
if type(previous) == "table" and type(previous.destroy) == "function" then
	pcall(previous.destroy)
end

local ALIVE = true
local teardown = {}

local function onTeardown(fn)
	teardown[#teardown + 1] = fn
end

local function destroySelf()
	if not ALIVE then
		return
	end
	ALIVE = false
	for i = #teardown, 1, -1 do
		pcall(teardown[i])
	end
	table.clear(teardown)
	registry[PREV_KEY] = nil
end

registry[PREV_KEY] = { destroy = destroySelf }

---------------------------------------------------------------------------
-- Services
---------------------------------------------------------------------------
local function getService(name)
	local ok, service = pcall(game.GetService, game, name)
	return ok and service or nil
end

local Players = getService("Players")
local ReplicatedStorage = getService("ReplicatedStorage")
local RunService = getService("RunService")
local TeleportService = getService("TeleportService")
local Workspace = getService("Workspace")
local Lighting = getService("Lighting")
local UserInputService = getService("UserInputService")
local HttpService = getService("HttpService")

local player = Players and Players.LocalPlayer
local clock = os.clock

---------------------------------------------------------------------------
-- Theme
---------------------------------------------------------------------------
local THEME = {
	panel = Color3.fromRGB(16, 17, 22),
	panelStroke = Color3.fromRGB(110, 116, 150),
	title = Color3.fromRGB(240, 242, 250),
	body = Color3.fromRGB(198, 203, 222),
	muted = Color3.fromRGB(138, 144, 168),
	accent = Color3.fromRGB(120, 200, 255),
	accentIdle = Color3.fromRGB(118, 124, 146),
	gold = Color3.fromRGB(255, 214, 120),
	goldSoft = Color3.fromRGB(255, 232, 170),
	green = Color3.fromRGB(150, 226, 170),
	blue = Color3.fromRGB(160, 200, 255),
	warn = Color3.fromRGB(255, 150, 120),
}

---------------------------------------------------------------------------
-- Route
---------------------------------------------------------------------------
local BASE_WAYPOINTS = {
	Vector3.new(-47.728096, 62.357868, 1367.711548),
	Vector3.new(-54.188339, 60.863651, 2138.236084),
	Vector3.new(-51.698677, 64.863708, 2905.420654),
	Vector3.new(-52.216656, 63.034512, 3677.957764),
	Vector3.new(-55.001850, 67.116653, 4443.070801),
	Vector3.new(-53.262642, 65.622421, 5215.646484),
	Vector3.new(-53.127392, 69.622482, 5989.105469),
	Vector3.new(-53.471760, 70.128311, 6758.813965),
	Vector3.new(-48.763596, 72.128326, 7525.666992),
	Vector3.new(-57.294670, 71.887093, 8294.072266),
	Vector3.new(-55.543640, -360.399200, 9488.929688),
}

-- Stage themes are picked per server run, so these are structural labels.
local STAGE_LABELS = {
	"Stage Entrance", "Stage 2", "Stage 3", "Stage 4", "Stage 5", "Stage 6",
	"Stage 7", "Stage 8", "Stage 9", "Stage 10", "Treasure",
}

local MIN_DWELL = 2
local GOLD_PER_STAGE = 8
local GOLD_PER_TREASURE = 25

local waypointPoints = table.clone(BASE_WAYPOINTS)

-- Lay a cylinder flat on the ground; the marker sits on top of it.
local FLAT = CFrame.Angles(0, 0, math.rad(90))
local MARKER_RADIUS = 6

local DEST, FLAG_BASE
FLAG_DOT_OFFSET = CFrame.new(0, 0.1, 0) * CFrame.Angles(0, 0, math.rad(90))

local function rebuildRoute()
	local count = #waypointPoints
	DEST = table.create(count)
	FLAG_BASE = table.create(count)
	for i = 1, count do
		local position = waypointPoints[i]
		DEST[i] = CFrame.new(position)
		FLAG_BASE[i] = CFrame.new(position - Vector3.new(0, 3, 0))
	end
end

rebuildRoute()

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local running = false
local interval = 2
local resetTimeout = 10
local showFlags = true
local reverseRoute = false
local skipTreasure = false
local autoRestart = true
local flagLifetime = 10
local flagColor = Color3.fromRGB(255, 59, 48)
local startStage = 1

local waypoint = 1
local lastTpAt = clock()
local actionAt = 0

local character, rootPart, humanoid

local STATE_IDLE, STATE_HOLD, STATE_DRAIN = 0, 1, 2
local state = STATE_IDLE

local sessionStartedAt = clock()
local sessionStages = 0
local sessionRuns = 0

-- A full clean run is 8 gold per stage plus 25 for the Treasure.
local function sessionGold()
	return sessionStages * GOLD_PER_STAGE + sessionRuns * GOLD_PER_TREASURE
end
local goldSource, goldBlocksSource, guiLabel
local goldInitial, goldBlocksInitial
local currentGold = 0

local healthLock = false
local lockedHealth = 1e9
local waterGodMode = false
local waterLevel = 0
local antiAfk = false
local noclip = false
local noclipSpeed = 80
local walkSpeed = nil
local jumpPower = nil
local jumpHeight = nil
local lastAfkNudge = 0

local antiIsolation = false
local hideStages = false
local isolationPattern = "Isolation"

local renderDisabled = false
local shadowsDisabled = false

local hudEnabled = true
local hud

-- Forward declarations. Luau resolves `local x = f(function() x end)` to a
-- GLOBAL inside the callback, so every widget the UI calls back into must be
-- declared before the call that creates it.
local autoFarmToggle
local waterLevelSlider
local setDwellLabel
local setBarrierLabel
local setStatusLabel
local setGoldLabel
local setGoldBlocksLabel
local setSessionLabel
local setBalanceLabel
local remoteDropdown
local setRemoteLabel
local smartBuy = false
local smartBudget = 500

-- Reporting is referenced from teleportTo, which is defined long before the
-- Reporting tab exists.
local setReportLabel
local postToWebhook
local buildReport
local webhookEnabled
local reportPerRun

-- Gold claiming. The community scripts do not wait for the server to pay:
-- they fire ClaimRiverResultsGold and touch the Treasure trigger.
local claimEnabled = false
local claimTreasure = true
local claimRemote
local lastClaimAt = 0
local claimsFired = 0
local lastClaimStatus = "Not fired"

local resolveClaimRemote
local claimGold
local webhookInterval = 300
local lastReportAt = 0

-- ESP / build state, referenced from the heartbeat and the build queue.
local espEnabled = false
local espRange = 600
local espColor = Color3.fromRGB(255, 90, 90)
local espHighlights = {}
local frozen = false
local applyEsp

-- Auto Build widgets, referenced from the file reader above. The rest of
-- that section is wrapped in its own block because the hand-rolled JSON
-- reader needs more locals than a single chunk may hold.
local buildDropdown
local BUILD_FOLDER = "AutoBuild"
local setClaimLabel
local candyDwell = 1.5
local candyCursor = 0
local candyPoints = {}
local collectCandyPoints
local setCandyLabel = function() end
local candyEnabled = false
local autoRejoin = false
local PLACES
local buyItem
local SHOP_ITEMS = {}
local buyRemotes
local scanBuyRemotes
local InsertService = getService("InsertService")

---------------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------------
local function bindText(element, initial)
	local last = initial

	return function(value)
		if value == last then
			return
		end
		last = value
		if type(element.Set) == "function" then
			element:Set(value)
		elseif type(element.SetText) == "function" then
			element:SetText(value)
		elseif element.Text ~= nil then
			element.Text = value
		end
	end
end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local function notify(title, content, duration)
	pcall(function()
		Rayfield:Notify({ Title = title, Content = content, Duration = duration or 3 })
	end)
end

local function round(n)
	return math.floor(n + 0.5)
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency
	s.Parent = parent
	return s
end

local function label(parent, name, position, size, text, textSize, textColor, font, alignment)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Position = position
	l.Size = size
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = textSize
	l.TextColor3 = textColor
	l.Font = font or Enum.Font.Gotham
	l.TextXAlignment = alignment or Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = parent
	return l
end

local function buildHud()
	if not player then
		return nil
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoFarmHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local okParent = pcall(function()
		gui.Parent = player:WaitForChild("PlayerGui", 10)
	end)
	if not okParent or not gui.Parent then
		pcall(function()
			gui:Destroy()
		end)
		return nil
	end

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 18, 1, -18)
	panel.Size = UDim2.new(0, 274, 0, 186)
	panel.BackgroundColor3 = THEME.panel
	panel.BackgroundTransparency = 0.06
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, 16)
	stroke(panel, THEME.panelStroke, 1, 0.55)

	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(1, -28, 0, 3)
	accent.Position = UDim2.new(0, 14, 0, 46)
	accent.BackgroundColor3 = THEME.accentIdle
	accent.BackgroundTransparency = 0.1
	accent.BorderSizePixel = 0
	accent.Parent = panel
	corner(accent, 2)

	label(panel, "Title", UDim2.new(0, 16, 0, 12), UDim2.new(1, -96, 0, 24),
		"AUTO FARM", 16, THEME.title, Enum.Font.GothamBold)
	label(panel, "State", UDim2.new(1, -92, 0, 13), UDim2.new(0, 76, 0, 22),
		"OFF", 12, THEME.muted, Enum.Font.GothamBold, Enum.TextXAlignment.Right)

	local function row(name, y, tint)
		local holder = label(panel, name, UDim2.new(0, 16, 0, y), UDim2.new(1, -32, 0, 20),
			"", 13, THEME.body)
		local value = label(holder, "Value", UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 1, 0),
			"", 13, tint, Enum.Font.GothamBold, Enum.TextXAlignment.Right)
		return holder, value
	end

	local goldRow, goldValue = row("GoldRow", 58, THEME.gold)
	local blocksRow, blocksValue = row("BlocksRow", 80, THEME.goldSoft)
	local rateRow, rateValue = row("RateRow", 102, THEME.green)
	local stageRow, stageValue = row("StageRow", 124, THEME.blue)

	local barBack = Instance.new("Frame")
	barBack.Name = "BarBack"
	barBack.Position = UDim2.new(0, 16, 0, 152)
	barBack.Size = UDim2.new(1, -32, 0, 6)
	barBack.BackgroundColor3 = Color3.fromRGB(38, 40, 52)
	barBack.BackgroundTransparency = 0.25
	barBack.BorderSizePixel = 0
	barBack.Parent = panel
	corner(barBack, 3)

	local barFill = Instance.new("Frame")
	barFill.Name = "BarFill"
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = THEME.accent
	barFill.BorderSizePixel = 0
	barFill.Parent = barBack
	corner(barFill, 3)

	label(panel, "Footnote", UDim2.new(0, 16, 0, 162), UDim2.new(1, -32, 0, 18),
		"", 11, THEME.muted)

	onTeardown(function()
		pcall(function()
			gui:Destroy()
		end)
	end)

	local function setVisible(visible)
		panel.Visible = visible
	end

	return {
		setVisible = setVisible,
		state = panel:FindFirstChild("State"),
		gold = goldValue,
		blocks = blocksValue,
		rate = rateValue,
		stage = stageValue,
		bar = barFill,
		accent = accent,
		footnote = panel:FindFirstChild("Footnote"),
		rows = { goldRow, blocksRow, rateRow, stageRow },
	}
end

local STATE_HUD = { [STATE_IDLE] = "IDLE", [STATE_HOLD] = "FARMING", [STATE_DRAIN] = "DRAIN" }

-- Cached so the HUD only writes a Text property when it genuinely differs.
-- Assigning an identical string still dirties the GUI.
local hudCache = {}
local statusCache
local notesCache
local activeNotes = ""

local function refreshActiveNotes()
	local notes = {}
	if healthLock then
		notes[#notes + 1] = "HP LOCK"
	end
	if waterGodMode then
		notes[#notes + 1] = "WATER GOD"
	end
	if noclip then
		notes[#notes + 1] = "NOCLIP"
	end
	if antiIsolation then
		notes[#notes + 1] = "ANTI-ISO"
	end
	activeNotes = table.concat(notes, "  ")
end

local function paintHud()
	local count = #waypointPoints
	local shown = math.clamp(waypoint, 1, count)
	local stageName = STAGE_LABELS[shown] or ("Stage " .. tostring(shown))
	local stateText = running and (STATE_HUD[state] or "IDLE") or "Stopped"

	-- Status is rebuilt only when one of its parts actually changed. It used to
	-- be assembled and offered to the label twice per call.
	local parts = { stateText, stageName, tostring(shown), tostring(count) }
	if notesCache == nil or #notesCache ~= #parts then
		notesCache = parts
		statusCache = string.format(
			"Status: %s | %s %d/%d",
			stateText,
			stageName,
			shown,
			count
		)
	end
	if activeNotes ~= "" then
		statusCache = string.format(
			"Status: %s | %s %d/%d   [%s]",
			stateText,
			stageName,
			shown,
			count,
			activeNotes
		)
	else
		statusCache = string.format(
			"Status: %s | %s %d/%d",
			stateText,
			stageName,
			shown,
			count
		)
	end
	setStatusLabel(statusCache)

	if hud then
		local progress = math.clamp((waypoint - 1) / math.max(count - 1, 1), 0, 1)
		local hudStateText = running and (STATE_HUD[state] or "IDLE") or "OFF"

		if hudCache.state ~= hudStateText then
			hudCache.state = hudStateText
			hud.state.Text = hudStateText
			hud.state.TextColor3 = running and THEME.accent or THEME.muted
		end

		local goldText = "+" .. tostring(sessionGold())
		if hudCache.gold ~= goldText then
			hudCache.gold = goldText
			hud.gold.Text = goldText
		end

		local blocksGained = 0
		if goldBlocksInitial then
			local current = (goldBlocksSource and goldBlocksSource.Value) or 0
			blocksGained = math.max(0, current - goldBlocksInitial)
		end
		local blocksText = goldBlocksInitial and ("+" .. tostring(blocksGained)) or "--"
		if hudCache.blocks ~= blocksText then
			hudCache.blocks = blocksText
			hud.blocks.Text = blocksText
		end

		local stageText = string.format("%s %d/%d", stageName, shown, count)
		if hudCache.stage ~= stageText then
			hudCache.stage = stageText
			hud.stage.Text = stageText
		end

		local barScale = math.floor(progress * 200)
		if hudCache.bar ~= barScale then
			hudCache.bar = barScale
			hud.bar.Size = UDim2.new(progress, 0, 1, 0)
		end

		local accent = running and THEME.accent or THEME.accentIdle
		if hudCache.accent ~= accent then
			hudCache.accent = accent
			hud.accent.BackgroundColor3 = accent
		end

		if hudCache.notes ~= activeNotes then
			hudCache.notes = activeNotes
			hud.footnote.Text = activeNotes
		end
	end
end

---------------------------------------------------------------------------
-- Stage geometry hiding
---------------------------------------------------------------------------
-- LocalTransparencyModifier is client-side only, so this stops the renderer
-- drawing stage props without the server or anyone else noticing. Only parts
-- well away from the player are hidden, so you never stand inside invisible
-- geometry.
local HIDED_PARTS = {}

local function applyStageHiding()
	if not Workspace then
		return
	end

	local origin = rootPart and rootPart.Position
	local nearZ = origin and origin.Z or 0
	local RANGE = 900

	local ok, descendants = pcall(function()
		return Workspace:GetDescendants()
	end)
	if not ok or not descendants then
		return
	end

	for i = 1, #descendants do
		local descendant = descendants[i]
		if descendant:IsA("BasePart") and descendant.CanQuery and not descendant:IsDescendantOf(rootPart or character) then
			local part = descendant
			if origin then
				local hidden = math.abs(part.Position.Z - nearZ) > RANGE
				if hidden and part.LocalTransparencyModifier < 1 then
					part.LocalTransparencyModifier = 1
					HIDED_PARTS[#HIDED_PARTS + 1] = part
				elseif not hidden and part.LocalTransparencyModifier > 0 then
					part.LocalTransparencyModifier = 0
				end
			end
		end
	end
end

local function restoreStageHiding()
	for i = 1, #HIDED_PARTS do
		pcall(function()
			HIDED_PARTS[i].LocalTransparencyModifier = 0
		end)
	end
	table.clear(HIDED_PARTS)
end

onTeardown(restoreStageHiding)

---------------------------------------------------------------------------
-- Flag pool
---------------------------------------------------------------------------
local flagRoot
local flagSlots = {}
local flagCursor = 0
local flagPoolSize = 5

local function destroyFlagPool()
	if flagRoot then
		pcall(function()
			flagRoot:Destroy()
		end)
		flagRoot = nil
	end
	table.clear(flagSlots)
	flagCursor = 0
end

local function syncFlagPoolSize()
	local wanted = math.clamp(math.ceil(flagLifetime / math.max(interval, 0.1)), 2, 16)
	if wanted == flagPoolSize then
		return
	end
	flagPoolSize = wanted
	for i = flagPoolSize + 1, #flagSlots do
		local slot = flagSlots[i]
		if slot and slot.holder then
			pcall(function()
				slot.holder:Destroy()
			end)
		end
		flagSlots[i] = nil
	end
	flagCursor = flagCursor % flagPoolSize
end

local function acquireFlagSlot()
	flagCursor = flagCursor % flagPoolSize + 1
	local slot = flagSlots[flagCursor]
	if slot then
		return slot
	end

	local holder = Instance.new("Folder")
	holder.Name = "Flag" .. flagCursor

	local base = Instance.new("Part")
	base.Size = Vector3.new(0.3, MARKER_RADIUS, MARKER_RADIUS)
	base.Shape = Enum.PartType.Cylinder
	base.Anchored = true
	base.CanCollide = false
	base.CanTouch = false
	base.CanQuery = false
	base.CastShadow = false
	base.Material = Enum.Material.SmoothPlastic
	base.BrickColor = BrickColor.new("White")

	-- Glowing rim: a wide neon disc with a slightly smaller dark disc laid
	-- over it, leaving a ring of neon visible around the edge.
	local rim = Instance.new("Part")
	rim.Size = Vector3.new(0.3, MARKER_RADIUS, MARKER_RADIUS)
	rim.Shape = Enum.PartType.Cylinder
	rim.Anchored = true
	rim.CanCollide = false
	rim.CanTouch = false
	rim.CanQuery = false
	rim.CastShadow = false
	rim.Material = Enum.Material.Neon
	rim.Color = flagColor

	local pad = Instance.new("Part")
	pad.Size = Vector3.new(0.32, MARKER_RADIUS - 0.9, MARKER_RADIUS - 0.9)
	pad.Shape = Enum.PartType.Cylinder
	pad.Anchored = true
	pad.CanCollide = false
	pad.CanTouch = false
	pad.CanQuery = false
	pad.CastShadow = false
	pad.Material = Enum.Material.SmoothPlastic
	pad.Color = Color3.fromRGB(18, 19, 24)

	-- Emblem: a fedora silhouette built from primitives -- crown, crease,
	-- brim and band. Drawn rather than loaded, so it costs nothing to pool.
	local crown = Instance.new("Part")
	crown.Size = Vector3.new(2.6, 1.5, 2.4)
	crown.Anchored = true
	crown.CanCollide = false
	crown.CanTouch = false
	crown.CanQuery = false
	crown.CastShadow = false
	crown.Material = Enum.Material.SmoothPlastic
	crown.Color = Color3.fromRGB(38, 40, 48)

	local crease = Instance.new("Part")
	crease.Size = Vector3.new(2.8, 0.18, 0.5)
	crease.Anchored = true
	crease.CanCollide = false
	crease.CanTouch = false
	crease.CanQuery = false
	crease.CastShadow = false
	crease.Material = Enum.Material.SmoothPlastic
	crease.Color = Color3.fromRGB(58, 61, 72)

	local brim = Instance.new("Part")
	brim.Size = Vector3.new(4.6, 0.22, 4.0)
	brim.Shape = Enum.PartType.Cylinder
	brim.Anchored = true
	brim.CanCollide = false
	brim.CanTouch = false
	brim.CanQuery = false
	brim.CastShadow = false
	brim.Material = Enum.Material.SmoothPlastic
	brim.Color = Color3.fromRGB(30, 32, 40)

	local band = Instance.new("Part")
	band.Size = Vector3.new(2.75, 0.32, 2.55)
	band.Anchored = true
	band.CanCollide = false
	band.CanTouch = false
	band.CanQuery = false
	band.CastShadow = false
	band.Material = Enum.Material.SmoothPlastic
	band.Color = flagColor

	if not flagRoot or not flagRoot.Parent then
		flagRoot = Instance.new("Folder")
		flagRoot.Name = "AutoFarmFlags"
		flagRoot.Parent = Workspace
	end

	base.Parent = holder
	rim.Parent = holder
	pad.Parent = holder
	crown.Parent = holder
	crease.Parent = holder
	brim.Parent = holder
	band.Parent = holder
	holder.Parent = flagRoot

	slot = {
		base = base,
		rim = rim,
		pad = pad,
		crown = crown,
		crease = crease,
		brim = brim,
		band = band,
		holder = holder,
	}
	flagSlots[flagCursor] = slot
	return slot
end

local function placeFlag(index)
	local slot = acquireFlagSlot()
	local origin = FLAG_BASE[index]

	slot.rim.CFrame = origin * FLAT
	slot.pad.CFrame = origin * CFrame.new(0, 0.06, 0) * FLAT
	slot.crown.CFrame = origin * CFrame.new(0, 0.95, 0)
	slot.crease.CFrame = origin * CFrame.new(0, 1.72, -0.3)
	slot.brim.CFrame = origin * CFrame.new(0, 0.28, 0) * FLAT
	slot.band.CFrame = origin * CFrame.new(0, 0.42, 0)
end

syncFlagPoolSize()

---------------------------------------------------------------------------
-- Claiming gold
---------------------------------------------------------------------------
-- Walking the stages only makes the server notice. Firing
-- ClaimRiverResultsGold is what actually banks the run, which is why the
-- community scripts do both.
resolveClaimRemote = function()
	if claimRemote and claimRemote.Parent then
		return claimRemote
	end
	if not Workspace then
		return nil
	end

	local ok, remote = pcall(function()
		return Workspace:FindFirstChild("ClaimRiverResultsGold")
	end)
	if ok and remote and (remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction")) then
		claimRemote = remote
		return claimRemote
	end

	local scanned, descendants = pcall(function()
		return Workspace:GetDescendants()
	end)
	if scanned and descendants then
		for i = 1, #descendants do
			local descendant = descendants[i]
			if descendant.Name == "ClaimRiverResultsGold"
				and (descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction")) then
				claimRemote = descendant
				return claimRemote
			end
		end
	end

	return nil
end

claimGold = function()
	if not claimEnabled then
		return false
	end
	local now = clock()
	if now - lastClaimAt < 0.5 then
		return false
	end
	lastClaimAt = now

	local remote = resolveClaimRemote()
	if not remote then
		lastClaimStatus = "ClaimRiverResultsGold not in this server"
		return false
	end

	if claimTreasure and type(firetouchinterest) == "function" and rootPart and Workspace then
		-- Reach the Treasure chest trigger and claim it, the way the run is
		-- meant to end.
		pcall(function()
			local stages = Workspace:FindFirstChild("BoatStages")
			local normal = stages and stages:FindFirstChild("NormalStages")
			local theEnd = normal and normal:FindFirstChild("TheEnd")
			local chest = theEnd and theEnd:FindFirstChild("GoldenChest")
			local trigger = chest and chest:FindFirstChild("Trigger")
			if trigger then
				firetouchinterest(rootPart, trigger, 0)
			end
		end)
	end

	local ok = pcall(function()
		if remote:IsA("RemoteFunction") then
			remote:InvokeServer()
		else
			remote:FireServer()
		end
	end)

	if ok then
		claimsFired += 1
		lastClaimStatus = "Claimed " .. tostring(claimsFired) .. " time(s)"
	else
		lastClaimStatus = "Claim fired but errored"
	end
	return ok
end

---------------------------------------------------------------------------
-- Route maths
---------------------------------------------------------------------------
local function routeLength()
	local count = #waypointPoints
	if skipTreasure and count > 1 then
		count = count - 1
	end
	return count
end

local function nextWaypoint()
	local length = routeLength()
	if waypoint > length then
		waypoint = 1
	end
	return waypoint
end

local function resetRun(grace)
	waypoint = math.clamp(startStage, 1, routeLength())
	lastTpAt = clock()
	state = STATE_IDLE
	actionAt = grace and (clock() + grace) or 0
	paintHud()
end

local function characterReady()
	return rootPart ~= nil
		and humanoid ~= nil
		and humanoid.Parent ~= nil
		and humanoid.Health > 0
		and rootPart.Parent ~= nil
		and (character == nil or character.Parent ~= nil)
end

local function teleportTo(index)
	local count = #waypointPoints
	local target = reverseRoute and (count - index + 1) or index

	rootPart.CFrame = DEST[target]
	lastTpAt = clock()
	sessionStages += 1

	if index < routeLength() then
		if showFlags then
			placeFlag(target)
		end
		waypoint = index + 1
		actionAt = lastTpAt + interval
		state = STATE_HOLD
		claimGold()
	else
		waypoint = 1
		state = STATE_DRAIN
		sessionRuns += 1
		if webhookEnabled and reportPerRun then
			task.spawn(function()
				local _, status = postToWebhook(buildReport())
				if setReportLabel then
					setReportLabel("Last report: " .. tostring(status))
				end
			end)
		end
	end

	paintHud()
end

---------------------------------------------------------------------------
-- Character binding
---------------------------------------------------------------------------
local function applyHumanoidSettings()
	if not humanoid then
		return
	end
	if healthLock then
		humanoid.MaxHealth = math.max(humanoid.MaxHealth or 100, lockedHealth)
	end
	if walkSpeed then
		humanoid.WalkSpeed = walkSpeed
	end
	if jumpPower then
		humanoid.JumpPower = jumpPower
	end
	if jumpHeight then
		humanoid.JumpHeight = jumpHeight
	end
end

local function bindCharacter(newCharacter)
	character = newCharacter
	rootPart, humanoid = nil, nil

	if not newCharacter or not ALIVE then
		paintHud()
		return
	end

	local foundRoot = newCharacter:FindFirstChild("HumanoidRootPart")
	local foundHum = newCharacter:FindFirstChildOfClass("Humanoid")
	if not foundRoot or not foundHum then
		newCharacter:WaitForChild("HumanoidRootPart", 10)
		newCharacter:WaitForChild("Humanoid", 10)
		foundRoot = newCharacter:FindFirstChild("HumanoidRootPart")
		foundHum = newCharacter:FindFirstChildOfClass("Humanoid")
	end

	rootPart, humanoid = foundRoot, foundHum
	applyHumanoidSettings()

	if foundHum then
		foundHum.Died:Once(function()
			if ALIVE and autoRestart then
				resetRun(false)
			end
		end)
	end

	paintHud()
end

if player then
	local addedConn = player.CharacterAdded:Connect(bindCharacter)
	local removingConn = player.CharacterRemoving:Connect(function()
		character, rootPart, humanoid = nil, nil, nil
		paintHud()
	end)
	onTeardown(function()
		addedConn:Disconnect()
		removingConn:Disconnect()
	end)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
end

---------------------------------------------------------------------------
-- Isolation Mode
---------------------------------------------------------------------------
local ISOLATION_MIN_HEIGHT = 850
local ISOLATION_MAX_HEIGHT = 1200

local function looksLikeBarrier(part)
	if not part:IsA("BasePart") then
		return false
	end
	if part.CanCollide == false then
		return false
	end
	if part.Transparency < 0.9 then
		return false
	end
	local size = part.Size
	return size.Y >= ISOLATION_MIN_HEIGHT and size.Y <= ISOLATION_MAX_HEIGHT
end

local function neutraliseIsolation()
	if not Workspace or not ALIVE then
		return 0
	end

	local pattern = string.lower(isolationPattern or "")
	local matched = 0

	local ok, descendants = pcall(function()
		return Workspace:GetDescendants()
	end)
	if not ok or not descendants then
		return 0
	end

	for i = 1, #descendants do
		local descendant = descendants[i]
		if descendant:IsA("BasePart") and descendant.CanCollide then
			local byName = pattern ~= "" and string.find(string.lower(descendant.Name), pattern, 1, true) ~= nil
			if byName or looksLikeBarrier(descendant) then
				descendant.CanCollide = false
				descendant.CanTouch = false
				matched += 1
			end
		end
	end

	return matched
end

---------------------------------------------------------------------------
-- Heartbeat
---------------------------------------------------------------------------
-- Forward declared: the heartbeat calls it, and a name referenced inside a
-- closure is resolved where the closure is *defined*.
local playerTweaks

local heartbeatConn = RunService and RunService.Heartbeat:Connect(function()
	if not ALIVE then
		return
	end

	if running then
		if not characterReady() then
			if state ~= STATE_IDLE then
				resetRun(false)
			end
		else
			local now = clock()
			if now >= actionAt then
				if state == STATE_IDLE or state == STATE_HOLD then
					teleportTo(nextWaypoint())
				elseif now - lastTpAt >= resetTimeout then
					resetRun(0.5)
				end
			end
		end
	end

	if not humanoid or not rootPart then
		return
	end

	-- The optional player tweaks are wrapped separately from the farming loop
	-- above. A failure in, say, noclip must never cost you the farm, and the
	-- farm must never be dragged down by a tweak you are not even using.
	pcall(playerTweaks)
end)

playerTweaks = function()
	local submerged = rootPart.Position.Y <= waterLevel
	local wantsHealth = healthLock or (waterGodMode and submerged)
	if wantsHealth then
		local ceiling = lockedHealth
		if waterGodMode and not healthLock then
			ceiling = math.max(humanoid.MaxHealth or 100, 100)
		end
		if humanoid.Health < ceiling then
			humanoid.Health = ceiling
		end
	end

	if antiAfk then
		local now = clock()
		if now - lastAfkNudge > 90 then
			lastAfkNudge = now
			pcall(function()
				humanoid:MoveTo(rootPart.Position + Vector3.new(0.5, 0, 0.5))
			end)
		end
	end

	if noclip then
		local camera = Workspace.CurrentCamera
		if camera then
			rootPart.AssemblyLinearVelocity = camera.CFrame.LookVector * noclipSpeed
		end
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.CanCollide = false
			end
		end
	end
end

onTeardown(function()
	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
end)

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local Window = Rayfield:CreateWindow({
	Name = "Auto Farm Premium",
	LoadingTitle = "Loading",
	LoadingSubtitle = "Build A Boat For Treasure",
	ConfigurationSaving = { Enabled = true },
})

local Dashboard = Window:CreateTab("Dashboard")
local FarmingTab = Window:CreateTab("Farming")
local PlayerTab = Window:CreateTab("Player")
local WorldTab = Window:CreateTab("World")
local ShopTab = Window:CreateTab("Shop & Items")
local EventsTab = Window:CreateTab("Events")
local UtilTab = Window:CreateTab("ESP & Teleport")
local BuildTab = Window:CreateTab("Auto Build")
local ReportTab = Window:CreateTab("Reporting")

hud = buildHud()

---------------------------------------------------------------------------
-- Dashboard
---------------------------------------------------------------------------
Dashboard:CreateParagraph({
	Title = "How the gold actually works",
	Content = "The river has eleven stage dividers. Each pays 8 gold, but only "
		.. "if the server counts that stage as loaded, which needs you inside it "
		.. "for roughly two seconds. The Treasure pays another 25, banked when you "
		.. "die or open it. Keep the interval at 2.0s or more, or the server "
		.. "quietly pays nothing.",
})

Dashboard:CreateSection("Live")

setStatusLabel = bindText(Dashboard:CreateLabel("Status: Idle"), "Status: Idle")
setGoldLabel = bindText(Dashboard:CreateLabel("Gold Gained: 0"), "Gold Gained: 0")
setGoldBlocksLabel = bindText(
	Dashboard:CreateLabel("Gold Blocks Gained: 0"),
	"Gold Blocks Gained: 0"
)
setSessionLabel = bindText(
	Dashboard:CreateLabel("Session: 0 stages - 0 runs - --/h"),
	"Session: 0 stages - 0 runs - --/h"
)

Dashboard:CreateSection("Quick Actions")

Dashboard:CreateButton({
	Name = "Start / Stop Auto Farm",
	Callback = function()
		if autoFarmToggle then
			autoFarmToggle:Set(not running)
		end
	end,
})

Dashboard:CreateButton({
	Name = "Jump To Stage Entrance",
	Callback = function()
		if rootPart and DEST[1] then
			rootPart.CFrame = DEST[1]
			lastTpAt = clock()
			paintHud()
			notify("Route", "Moved to the Stage Entrance.")
		end
	end,
})

Dashboard:CreateButton({
	Name = "Jump To Treasure",
	Callback = function()
		local index = #waypointPoints
		if rootPart and DEST[index] then
			rootPart.CFrame = DEST[index]
			lastTpAt = clock()
			paintHud()
			notify("Route", "Moved to the Treasure.")
		end
	end,
})

Dashboard:CreateButton({
	Name = "Reset Session Stats",
	Callback = function()
		sessionStages = 0
		sessionRuns = 0
		sessionStartedAt = clock()
		paintHud()
	end,
})

Dashboard:CreateButton({
	Name = "Unload Script",
	Callback = function()
		destroySelf()
	end,
})

---------------------------------------------------------------------------
-- Farming
---------------------------------------------------------------------------
local function dwellText()
	if interval < MIN_DWELL then
		return string.format(
			"Interval is %.1fs. The server needs about %.1fs inside a stage "
				.. "before it pays, so below that you are farming for free.",
			interval,
			MIN_DWELL
		)
	end
	return string.format("Interval %.1fs clears the %.1fs the server needs.", interval, MIN_DWELL)
end

FarmingTab:CreateSection("Core")

autoFarmToggle = FarmingTab:CreateToggle({
	Name = "Auto Farm",
	CurrentValue = false,
	Flag = "Toggle1",
	Callback = function(value)
		if value == running then
			return
		end
		running = value
		if running then
			resetRun(false)
		end
		paintHud()
	end,
})

FarmingTab:CreateSlider({
	Name = "Teleport Interval",
	Range = { 0.5, 8 },
	Increment = 0.1,
	CurrentValue = 2,
	Flag = "Slider1",
	Callback = function(value)
		interval = value
		if state == STATE_HOLD then
			actionAt = lastTpAt + interval
		end
		syncFlagPoolSize()
		if setDwellLabel then
			setDwellLabel(dwellText())
		end
	end,
})

setDwellLabel = bindText(
	FarmingTab:CreateLabel("Interval 2.0s clears the 2.0s the server needs."),
	"Interval 2.0s clears the 2.0s the server needs."
)

FarmingTab:CreateSlider({
	Name = "Reset Timeout (Seconds Since Last TP)",
	Range = { 2, 60 },
	Increment = 1,
	CurrentValue = 10,
	Flag = "Slider2",
	Callback = function(value)
		resetTimeout = value
	end,
})

FarmingTab:CreateSection("Route")

FarmingTab:CreateSlider({
	Name = "Start Stage",
	Range = { 1, #waypointPoints },
	Increment = 1,
	CurrentValue = 1,
	Flag = "StartStageSlider",
	Callback = function(value)
		startStage = math.clamp(math.floor(value), 1, #waypointPoints)
		if state == STATE_IDLE then
			waypoint = startStage
		end
		paintHud()
	end,
})

FarmingTab:CreateToggle({
	Name = "Reverse Route",
	CurrentValue = false,
	Flag = "ReverseToggle",
	Callback = function(value)
		reverseRoute = value
	end,
})

FarmingTab:CreateToggle({
	Name = "Skip Treasure Stage",
	CurrentValue = false,
	Flag = "SkipTreasureToggle",
	Callback = function(value)
		skipTreasure = value
		if waypoint > routeLength() then
			waypoint = 1
		end
		paintHud()
	end,
})

FarmingTab:CreateToggle({
	Name = "Auto Restart On Death",
	CurrentValue = true,
	Flag = "AutoRestartToggle",
	Callback = function(value)
		autoRestart = value
	end,
})

FarmingTab:CreateButton({
	Name = "Add Current Position To Route",
	Callback = function()
		if not rootPart then
			notify("Route", "No character to read a position from.")
			return
		end
		table.insert(waypointPoints, rootPart.Position)
		table.insert(STAGE_LABELS, "Custom " .. tostring(#waypointPoints))
		rebuildRoute()
		destroyFlagPool()
		syncFlagPoolSize()
		paintHud()
		notify("Route", "Route is now " .. tostring(#waypointPoints) .. " stops.")
	end,
})

FarmingTab:CreateButton({
	Name = "Reset Route To Original",
	Callback = function()
		waypointPoints = table.clone(BASE_WAYPOINTS)
		for i = #STAGE_LABELS, #BASE_WAYPOINTS + 1, -1 do
			table.remove(STAGE_LABELS)
		end
		rebuildRoute()
		destroyFlagPool()
		syncFlagPoolSize()
		paintHud()
		notify("Route", "Route restored to the original eleven stops.")
	end,
})

FarmingTab:CreateSection("Claim & Bank")

FarmingTab:CreateParagraph({
	Title = "Why claiming matters",
	Content = "Teleporting through the stages only makes the server notice. "
		.. "Firing ClaimRiverResultsGold is what actually banks the run, which "
		.. "is why the popular scripts do both. Turn this on.",
})

FarmingTab:CreateToggle({
	Name = "Claim Gold Each Stage",
	CurrentValue = true,
	Flag = "ClaimToggle",
	Callback = function(value)
		claimEnabled = value
		if value then
			local remote = resolveClaimRemote()
			if remote then
				lastClaimStatus = "Claim remote found"
			else
				lastClaimStatus = "Claim remote not in this server yet"
			end
			if setClaimLabel then
				setClaimLabel("Claims: " .. tostring(claimsFired) .. " - " .. lastClaimStatus)
			end
		end
	end,
})

FarmingTab:CreateToggle({
	Name = "Touch Treasure Chest",
	CurrentValue = true,
	Flag = "ClaimTreasureToggle",
	Callback = function(value)
		claimTreasure = value
	end,
})

setClaimLabel = bindText(
	FarmingTab:CreateLabel("Claims: 0 - not fired yet"),
	"Claims: 0 - not fired yet"
)

	local function candyUI()
	FarmingTab:CreateSection("Candy Farm")

	local candyPoints = {}
	local setCandyLabel = bindText(
		FarmingTab:CreateLabel("Candy Farm: off"),
		"Candy Farm: off"
	)

	-- Candy runs are a different route from the river: a small loop that teleports
	-- between candy pickups and claims as it goes. The exact candy coordinates are
	-- not published, so this reads whatever the server exposes and falls back to
	-- a user-editable list.
	local CANDY_PATTERNS = { "candy", "sweet", "lolly", "cane" }

	collectCandyPoints = function()
		candyPoints = {}
		if not Workspace then
			return candyPoints
		end
		local ok, descendants = pcall(function()
			return Workspace:GetDescendants()
		end)
		if not ok or not descendants then
			return candyPoints
		end
		for i = 1, #descendants do
			local descendant = descendants[i]
			if descendant:IsA("BasePart") then
				local name = string.lower(descendant.Name)
				for p = 1, #CANDY_PATTERNS do
					if string.find(name, CANDY_PATTERNS[p], 1, true) then
						candyPoints[#candyPoints + 1] = descendant.Position
						break
					end
				end
			end
		end
		return candyPoints
	end

	FarmingTab:CreateToggle({
		Name = "Candy Farm",
		CurrentValue = false,
		Flag = "CandyToggle",
		Callback = function(value)
			candyEnabled = value
			if value then
				collectCandyPoints()
				setCandyLabel("Candy Farm: scanning (" .. tostring(#candyPoints) .. " found)")
			else
				setCandyLabel("Candy Farm: off")
			end
		end,
	})

	FarmingTab:CreateSlider({
		Name = "Candy Dwell (Seconds)",
		Range = { 0.5, 5 },
		Increment = 0.1,
		CurrentValue = 1.5,
		Flag = "CandyDwell",
		Callback = function(value)
			candyDwell = value
		end,
	})

	FarmingTab:CreateButton({
		Name = "Rescan Candy Points",
		Callback = function()
			local found = collectCandyPoints()
			setCandyLabel("Candy Farm: " .. tostring(#found) .. " point(s)")
			notify("Candy Farm", tostring(#found) .. " candy point(s) found.")
		end,
	})

	end

	candyUI()

FarmingTab:CreateSection("Visuals")

FarmingTab:CreateToggle({
	Name = "Show Waypoint Flags",
	CurrentValue = true,
	Flag = "FlagsToggle",
	Callback = function(value)
		showFlags = value
		if not value then
			destroyFlagPool()
		end
	end,
})

FarmingTab:CreateColorPicker({
	Name = "Flag Colour",
	Color = flagColor,
	Flag = "FlagColorPicker",
	Callback = function(color)
		flagColor = color
		for i = 1, #flagSlots do
			local slot = flagSlots[i]
			if slot then
				if slot.rim then
					slot.rim.Color = color
				end
				if slot.band then
					slot.band.Color = color
				end
			end
		end
	end,
})

FarmingTab:CreateToggle({
	Name = "Hide Distant Stage Geometry",
	CurrentValue = false,
	Flag = "HideStagesToggle",
	Callback = function(value)
		hideStages = value
		if value then
			applyStageHiding()
		else
			restoreStageHiding()
		end
	end,
})

FarmingTab:CreateSlider({
	Name = "Flag Lifetime (Seconds)",
	Range = { 2, 30 },
	Increment = 1,
	CurrentValue = 10,
	Flag = "FlagLifetimeSlider",
	Callback = function(value)
		flagLifetime = value
		syncFlagPoolSize()
	end,
})

---------------------------------------------------------------------------
-- Player
---------------------------------------------------------------------------
PlayerTab:CreateSection("Survivability")

PlayerTab:CreateToggle({
	Name = "Health Lock",
	CurrentValue = false,
	Flag = "HealthLockToggle",
	Callback = function(value)
		healthLock = value
		if not value and humanoid then
			humanoid.MaxHealth = 100
			if humanoid.Health > 100 then
				humanoid.Health = 100
			end
		end
		applyHumanoidSettings()
		refreshActiveNotes()
		paintHud()
	end,
})

PlayerTab:CreateSlider({
	Name = "Locked Health",
	Range = { 1000, 1e9 },
	Increment = 1000,
	CurrentValue = 1e9,
	Flag = "LockedHealthSlider",
	Callback = function(value)
		lockedHealth = value
		applyHumanoidSettings()
	end,
})

PlayerTab:CreateToggle({
	Name = "Water God Mode",
	CurrentValue = false,
	Flag = "WaterGodToggle",
	Callback = function(value)
		waterGodMode = value
		refreshActiveNotes()
		paintHud()
	end,
})

waterLevelSlider = PlayerTab:CreateSlider({
	Name = "Water Level",
	Range = { -400, 200 },
	Increment = 5,
	CurrentValue = 0,
	Flag = "WaterLevelSlider",
	Callback = function(value)
		waterLevel = value
	end,
})

PlayerTab:CreateButton({
	Name = "Set Water Level To Me",
	Callback = function()
		if not rootPart then
			notify("Water God Mode", "No character to read a position from.")
			return
		end
		waterLevel = math.floor(rootPart.Position.Y)
		if waterLevelSlider then
			waterLevelSlider:Set(waterLevel)
		end
		notify("Water God Mode", "Water level set to " .. tostring(waterLevel) .. " studs.")
	end,
})

PlayerTab:CreateToggle({
	Name = "Anti AFK",
	CurrentValue = false,
	Flag = "AntiAfkToggle",
	Callback = function(value)
		antiAfk = value
	end,
})

PlayerTab:CreateToggle({
	Name = "No Clip",
	CurrentValue = false,
	Flag = "NoClipToggle",
	Callback = function(value)
		noclip = value
		refreshActiveNotes()
		paintHud()
	end,
})

PlayerTab:CreateSlider({
	Name = "No Clip Speed",
	Range = { 10, 300 },
	Increment = 5,
	CurrentValue = 80,
	Flag = "NoClipSpeedSlider",
	Callback = function(value)
		noclipSpeed = value
	end,
})

PlayerTab:CreateSection("Movement")

PlayerTab:CreateSlider({
	Name = "Walk Speed",
	Range = { 16, 300 },
	Increment = 1,
	CurrentValue = 16,
	Flag = "WalkSpeedSlider",
	Callback = function(value)
		walkSpeed = value
		applyHumanoidSettings()
	end,
})

PlayerTab:CreateSlider({
	Name = "Jump Power",
	Range = { 50, 500 },
	Increment = 5,
	CurrentValue = 50,
	Flag = "JumpPowerSlider",
	Callback = function(value)
		jumpPower = value
		applyHumanoidSettings()
	end,
})

PlayerTab:CreateSlider({
	Name = "Jump Height",
	Range = { 1, 60 },
	Increment = 0.5,
	CurrentValue = 7.2,
	Flag = "JumpHeightSlider",
	Callback = function(value)
		jumpHeight = value
		applyHumanoidSettings()
	end,
})

PlayerTab:CreateButton({
	Name = "Reset Movement To Default",
	Callback = function()
		walkSpeed, jumpPower, jumpHeight = nil, nil, nil
		if humanoid then
			humanoid.WalkSpeed = 16
			humanoid.JumpPower = 50
			humanoid.JumpHeight = 7.2
		end
	end,
})

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------
WorldTab:CreateSection("Isolation Mode")

WorldTab:CreateToggle({
	Name = "Anti Isolation Mode",
	CurrentValue = false,
	Flag = "AntiIsolationToggle",
	Callback = function(value)
		antiIsolation = value
		if value then
			local found = neutraliseIsolation()
			if setBarrierLabel then
				setBarrierLabel("Barriers neutralised: " .. tostring(found))
			end
			notify("Anti Isolation", "Neutralised " .. tostring(found) .. " barrier(s).")
		elseif setBarrierLabel then
			setBarrierLabel("Barriers neutralised: 0")
		end
		refreshActiveNotes()
		paintHud()
	end,
})

WorldTab:CreateInput({
	Name = "Isolation Name Filter",
	PlaceholderText = "substring to match, e.g. Isolation",
	RemoveTextAfterFocusLost = false,
	Flag = "IsolationFilterInput",
	Callback = function(text)
		isolationPattern = text or ""
	end,
})

setBarrierLabel = bindText(
	WorldTab:CreateLabel("Barriers neutralised: 0"),
	"Barriers neutralised: 0"
)

WorldTab:CreateButton({
	Name = "Scan For Barriers Now",
	Callback = function()
		local found = neutraliseIsolation()
		setBarrierLabel("Barriers neutralised: " .. tostring(found))
		notify("Anti Isolation", "Neutralised " .. tostring(found) .. " barrier(s).")
	end,
})

WorldTab:CreateSection("Performance")

WorldTab:CreateToggle({
	Name = "Disable 3D Rendering (Lag Reducer)",
	CurrentValue = false,
	Flag = "RenderToggle",
	Callback = function(value)
		renderDisabled = value
		pcall(function()
			RunService:Set3dRenderingEnabled(not value)
		end)
	end,
})

WorldTab:CreateToggle({
	Name = "Disable Shadows",
	CurrentValue = false,
	Flag = "ShadowsToggle",
	Callback = function(value)
		shadowsDisabled = value
		if Lighting then
			Lighting.GlobalShadows = not value
		end
	end,
})

WorldTab:CreateToggle({
	Name = "Remove Other Players",
	CurrentValue = false,
	Flag = "RemovePlayersToggle",
	Callback = function(value)
		if not Players or not Workspace then
			return
		end
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player and other.Character and value then
				other.Character.Parent = nil
			end
		end
	end,
})

WorldTab:CreateSlider({
	Name = "Frame Rate Cap (0 = uncapped)",
	Range = { 0, 240 },
	Increment = 5,
	CurrentValue = 0,
	Flag = "FpsCapSlider",
	Callback = function(value)
		-- setfpm is a Roblox global; RunService has no SetTargetFps method.
		pcall(function()
			setfpm(math.floor(value))
		end)
	end,
})

WorldTab:CreateSection("Keybinds")

local keybindsEnabled = false

local KEYBINDS = {
	{ Key = Enum.KeyCode.F5, Label = "F5", Action = function() autoFarmToggle:Set(not running) end },
	{ Key = Enum.KeyCode.H, Label = "H", Action = function()
		hudEnabled = not hudEnabled
		if hud then
			hud.setVisible(hudEnabled)
		end
	end },
	{ Key = Enum.KeyCode.T, Label = "T", Action = function()
		if rootPart and DEST[#waypointPoints] then
			rootPart.CFrame = DEST[#waypointPoints]
			lastTpAt = clock()
			paintHud()
		end
	end },
}

WorldTab:CreateParagraph({
	Title = "Quick keys",
	Content = "F5 toggles Auto Farm.  H shows or hides the HUD.  "
		.. "T jumps you to the Treasure.",
})

WorldTab:CreateToggle({
	Name = "Enable Keybinds",
	CurrentValue = false,
	Flag = "KeybindsToggle",
	Callback = function(value)
		keybindsEnabled = value
	end,
})

if UserInputService then
	local keyConn = UserInputService.InputBegan:Connect(function(input, processed)
		if not keybindsEnabled or processed or not ALIVE then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		for i = 1, #KEYBINDS do
			if input.KeyCode == KEYBINDS[i].Key then
				pcall(KEYBINDS[i].Action)
				return
			end
		end
	end)
	onTeardown(function()
		keyConn:Disconnect()
	end)
end

WorldTab:CreateSection("Interface")

WorldTab:CreateToggle({
	Name = "Show HUD",
	CurrentValue = true,
	Flag = "HudToggle",
	Callback = function(value)
		hudEnabled = value
		if hud then
			hud.setVisible(value)
		end
	end,
})

onTeardown(function()
	if renderDisabled then
		pcall(function()
			RunService:Set3dRenderingEnabled(true)
		end)
	end
	if shadowsDisabled and Lighting then
		Lighting.GlobalShadows = true
	end
	destroyFlagPool()
end)

---------------------------------------------------------------------------
-- Shop
---------------------------------------------------------------------------
do
	local buyAmount = 1
	local customItemName = ""

	-- Prices and pull counts from the BABFT wiki's chest tables; "Best" drives
	-- the smart buyer. Zero price means the real cost is not published.
	SHOP_ITEMS = {
		{ Label = "Pine Trees", Internal = "PineTree", Noun = "PineTree(s)" },
		{ Label = "Common Chests", Internal = "Common Chest", Noun = "Common Chest(s)", Pulls = 3 },
		{ Label = "Uncommon Chests", Internal = "Uncommon Chest", Noun = "Uncommon Chest(s)", Pulls = 5 },
		{ Label = "Rare Chests", Internal = "Rare Chest", Noun = "Rare Chest(s)", Price = 45, Pulls = 15 },
		{ Label = "Epic Chests", Internal = "Epic Chest", Noun = "Epic Chest(s)", Price = 135, Pulls = 44 },
		{ Label = "Legendary Chests", Internal = "Legendary Chest", Noun = "Legendary Chest(s)", Pulls = 100 },
		{ Label = "Winter Chests", Internal = "Winter Chest", Noun = "Winter Chest(s)", Price = 55, Pulls = 13 },
	}

	local PACK_ITEMS = {
		{ Label = "Building Tool", Internal = "BuildingTool" },
		{ Label = "Delete Tool", Internal = "DeleteTool" },
		{ Label = "Paint Tool", Internal = "PaintTool" },
		{ Label = "Binding Tool", Internal = "BindingTool" },
		{ Label = "Property Tool", Internal = "PropertyTool" },
		{ Label = "Scaling Tool", Internal = "ScalingTool" },
		{ Label = "Trowel Tool", Internal = "TrowelTool" },
		{ Label = "Portal Block", Internal = "Portal" },
		{ Label = "Hinge", Internal = "Hinge", Price = 50 },
		{ Label = "Glue", Internal = "Glue" },
	}

	local BUY_REMOTE_NAMES = {
		ItemBoughtFromShop = true,
		BuyItem = true,
		BuyingItem = true,
		BuyItemFunction = true,
	}

	buyRemotes = nil
	local lastRemoteScan = 0
	local REMOTE_SCAN_INTERVAL = 10

	scanBuyRemotes = function(force)
		if buyRemotes and not force then
			return buyRemotes
		end
		if not force and (clock() - lastRemoteScan) < REMOTE_SCAN_INTERVAL then
			return buyRemotes
		end
		lastRemoteScan = clock()

		local found, names, seen = {}, {}, {}

		local function consider(instance)
			if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") then
				if BUY_REMOTE_NAMES[instance.Name] and not seen[instance] then
					seen[instance] = true
					found[#found + 1] = instance
					names[#names + 1] = instance.Name
				end
			end
		end

		if ReplicatedStorage then
			local ok, descendants = pcall(function()
				return ReplicatedStorage:GetDescendants()
			end)
			if ok and descendants then
				for i = 1, #descendants do
					consider(descendants[i])
				end
			end
		end

		local workspaceRemote = Workspace and Workspace:FindFirstChild("ItemBoughtFromShop")
		if workspaceRemote then
			consider(workspaceRemote)
		end

		buyRemotes = found

		if remoteDropdown then
			if #names == 0 then
				remoteDropdown:Refresh({ "(none yet)" })
				remoteDropdown:Set("(none yet)")
			else
				remoteDropdown:Refresh(names)
				remoteDropdown:Set(names[1])
			end
		end
		if setRemoteLabel then
			setRemoteLabel("Buy remotes found: " .. tostring(#names))
		end

		return buyRemotes
	end

	local BUY_COOLDOWN = 0.35
	local lastBuyAt = 0

	buyItem = function(itemName, qty)
		local now = clock()
		if now - lastBuyAt < BUY_COOLDOWN then
			notify("Shop", "Slow down, buy requests are rate limited.")
			return 0
		end
		lastBuyAt = now

		local remotes = scanBuyRemotes(false)
		if not remotes or #remotes == 0 then
			remotes = scanBuyRemotes(true)
		end

		local fired = 0
		for i = 1, #remotes do
			local remote = remotes[i]
			pcall(function()
				if remote:IsA("RemoteFunction") then
					remote:InvokeServer(itemName, qty)
				else
					remote:FireServer(itemName, qty)
				end
				fired += 1
			end)
		end

		return fired
	end

	local function reportPurchase(itemName, qty, noun)
		local fired = buyItem(itemName, qty)
		if fired == 0 then
			notify("Shop", "No buy remote found yet. Rejoin and retry in a moment.", 4)
			return
		end
		notify("Shop", "Bought " .. tostring(qty) .. " " .. (noun or itemName))
	end

	ShopTab:CreateSection("Wallet")

	setBalanceLabel = bindText(ShopTab:CreateLabel("Gold: --"), "Gold: --")

	ShopTab:CreateSection("Chests")

	ShopTab:CreateSlider({
		Name = "Amount to Buy",
		Range = { 1, 100 },
		Increment = 1,
		CurrentValue = 1,
		Flag = "BuyAmountSlider",
		Callback = function(value)
			buyAmount = value
		end,
	})

	for i = 1, #SHOP_ITEMS do
		local item = SHOP_ITEMS[i]
		local text = item.Price and item.Price > 0
			and (item.Label .. "   " .. item.Price .. "g")
			or item.Label

		ShopTab:CreateButton({
			Name = "Buy " .. text,
			Callback = function()
				reportPurchase(item.Internal, buyAmount, item.Noun)
			end,
		})
	end

	ShopTab:CreateToggle({
		Name = "Smart Buy (Best Gold Per Block)",
		CurrentValue = false,
		Flag = "SmartBuyToggle",
		Callback = function(value)
			smartBuy = value
		end,
	})

	ShopTab:CreateSlider({
		Name = "Smart Buy Budget (Gold)",
		Range = { 50, 5000 },
		Increment = 25,
		CurrentValue = 500,
		Flag = "SmartBudgetSlider",
		Callback = function(value)
			smartBudget = value
		end,
	})

	ShopTab:CreateSection("Tools & Packs")

	for i = 1, #PACK_ITEMS do
		local item = PACK_ITEMS[i]
		local text = item.Price and item.Price > 0
			and (item.Label .. "   " .. item.Price .. "g")
			or item.Label

		ShopTab:CreateButton({
			Name = "Buy " .. text,
			Callback = function()
				reportPurchase(item.Internal, 1, item.Label)
			end,
		})
	end

	ShopTab:CreateSection("Custom")

	remoteDropdown = ShopTab:CreateDropdown({
		Name = "Detected Buy Remote",
		Options = { "(none yet)" },
		CurrentOption = "(none yet)",
		Flag = "RemoteDropdown",
	})

	setRemoteLabel = bindText(
		ShopTab:CreateLabel("Buy remotes found: 0"),
		"Buy remotes found: 0"
	)

	ShopTab:CreateInput({
		Name = "Custom Internal Name",
		PlaceholderText = "e.g. Car Pack, Jetpack Pack, Servo Pack",
		RemoveTextAfterFocusLost = false,
		Callback = function(text)
			customItemName = text
		end,
	})

	ShopTab:CreateButton({
		Name = "Buy Custom Item",
		Callback = function()
			if not customItemName or customItemName == "" then
				notify("Shop", "Enter an internal item name first.")
				return
			end
			reportPurchase(customItemName, buyAmount, customItemName)
		end,
	})

	ShopTab:CreateButton({
		Name = "Rescan For Buy Remotes",
		Callback = function()
			local remotes = scanBuyRemotes(true)
			notify("Shop", "Found " .. tostring(remotes and #remotes or 0) .. " buy remote(s).")
		end,
	})

	---------------------------------------------------------------------------
	-- Events
	---------------------------------------------------------------------------
	PLACES = {
		{ Name = "Main Game", Id = 537413528 },
		{ Name = "Inner Cloud", Id = 1930863474 },
		{ Name = "Winter Place", Id = 1930866268 },
		{ Name = "The Test Place", Id = 1930665568 },
	}

	EventsTab:CreateParagraph({
		Title = "About these place IDs",
		Content = "The original script's Main Game button pointed at 5374135, which "
			.. "is a different near-empty place. The real root place for Build A "
			.. "Boat For Treasure is 537413528. All four places below belong to "
			.. "universe 210851291.",
	})

	EventsTab:CreateSection("Travel")

	for i = 1, #PLACES do
		local place = PLACES[i]
		EventsTab:CreateButton({
			Name = place.Name,
			Callback = function()
				local ok, err = pcall(function()
					TeleportService:Teleport(place.Id, player)
				end)
				if not ok then
					notify("Teleport", "Blocked: " .. tostring(err), 4)
				end
			end,
		})
	end

	EventsTab:CreateSection("Recovery")

	local lastHopResult = "Not hopped"

	EventsTab:CreateButton({
		Name = "Server Hop",
		Callback = function()
			local httpFetch
			if type(request) == "function" then
				httpFetch = request
			elseif type(http_request) == "function" then
				httpFetch = http_request
			end
			if not httpFetch or not HttpService then
				lastHopResult = "No HTTP function in this executor"
				notify("Server Hop", lastHopResult, 4)
				return
			end
			local url = string.format(
				"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true",
				PLACES[1].Id
			)
			local ok, response = pcall(function()
				return httpFetch({ Url = url, Method = "GET" })
			end)
			if not ok or not response then
				lastHopResult = "Request failed"
				notify("Server Hop", lastHopResult, 4)
				return
			end
			local decodedOk, body = pcall(function()
				return HttpService:JSONDecode(response.Body)
			end)
			if not decodedOk or type(body) ~= "table" or type(body.data) ~= "table" then
				lastHopResult = "Could not read the server list"
				notify("Server Hop", lastHopResult, 4)
				return
			end

			local currentJob = game.JobId
			local candidates = {}
			for i = 1, #body.data do
				local entry = body.data[i]
				local playing = tonumber(entry.playing)
				local maximum = tonumber(entry.maxPlayers)
				if type(entry.id) == "string" and playing and maximum
					and playing < maximum and entry.id ~= currentJob then
					candidates[#candidates + 1] = entry.id
				end
			end

			if #candidates == 0 then
				lastHopResult = "No open servers found"
				notify("Server Hop", lastHopResult, 4)
				return
			end

			local chosen = candidates[math.random(1, #candidates)]
			lastHopResult = "Moved to a server with " .. tostring(chosen)
			notify("Server Hop", lastHopResult)
			pcall(function()
				TeleportService:TeleportToPlaceInstance(PLACES[1].Id, chosen, player)
			end)
		end,
	})

	EventsTab:CreateButton({
		Name = "Rejoin This Server",
		Callback = function()
			local jobId = game.JobId
			if type(jobId) ~= "string" or jobId == "" then
				notify("Rejoin", "This server has no id to rejoin.")
				return
			end
			notify("Rejoin", "Rejoining this server in a moment.")
			task.spawn(function()
				task.wait(1.5)
				pcall(function()
					TeleportService:TeleportToPlaceInstance(PLACES[1].Id, jobId, player)
				end)
			end)
		end,
	})

	EventsTab:CreateToggle({
		Name = "Auto Rejoin Main On Disconnect",
		CurrentValue = false,
		Flag = "AutoRejoinToggle",
		Callback = function(value)
			autoRejoin = value
		end,
	})



	---------------------------------------------------------------------------
	-- ESP
	---------------------------------------------------------------------------

	do
		local ITEM_PATTERNS = { "chest", "treasure", "secret", "coin", "goldbar", "gold" }

		local function isItemLike(instance)
			local name = string.lower(instance.Name)
			for i = 1, #ITEM_PATTERNS do
				if string.find(name, ITEM_PATTERNS[i], 1, true) then
					return true
				end
			end
			return false
		end

		local function clearHighlights()
			for i = 1, #espHighlights do
				pcall(function()
					espHighlights[i]:Destroy()
				end)
			end
			table.clear(espHighlights)
		end

		local function makeHighlight(subject, filled)
			local ok, highlight = pcall(function()
				local h = Instance.new("Highlight")
				h.Adornee = subject
				h.FillColor = espColor
				h.OutlineColor = espColor
				h.FillTransparency = filled and 0.75 or 1
				h.OutlineTransparency = 0
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				h.Parent = player and player:WaitForChild("PlayerGui", 5)
				return h
			end)
			return ok and highlight or nil
		end

		applyEsp = function()
			if not espEnabled then
				clearHighlights()
				return
			end

			clearHighlights()

			-- The player's own avatar, so you can find yourself on a busy server.
			if character then
				local highlight = makeHighlight(character, true)
				if highlight then
					espHighlights[#espHighlights + 1] = highlight
				end
			end

			-- Nearby items: chests, treasure, coins.
			if Workspace then
				local ok, descendants = pcall(function()
					return Workspace:GetDescendants()
				end)
				if ok and descendants then
					local rootPosition = rootPart and rootPart.Position
					local found = 0
					for i = 1, #descendants do
						local descendant = descendants[i]
						if found < 60 and descendant:IsA("Model") and isItemLike(descendant) then
							local position = descendant:FindFirstChildWhichIsA("BasePart", true)
							local near = true
							if rootPosition and position then
								near = (position.Position - rootPosition).Magnitude <= espRange
							end
							if near then
								local highlight = makeHighlight(descendant, false)
								if highlight then
									espHighlights[#espHighlights + 1] = highlight
									found += 1
								end
							end
						end
					end
				end
			end
		end

		onTeardown(clearHighlights)

		UtilTab:CreateParagraph({
			Title = "ESP",
			Content = "Outlines your own avatar in a solid fill and any chests, "
				.. "treasure or coin models nearby in a hollow outline, through walls. "
				.. "Rebuilt on demand and fully torn down on unload.",
		})

		UtilTab:CreateToggle({
			Name = "Enable ESP",
			CurrentValue = false,
			Flag = "EspToggle",
			Callback = function(value)
				espEnabled = value
				applyEsp()
			end,
		})

		UtilTab:CreateSlider({
			Name = "ESP Range (Studs)",
			Range = { 100, 3000 },
			Increment = 50,
			CurrentValue = 600,
			Flag = "EspRange",
			Callback = function(value)
				espRange = value
				if espEnabled then
					applyEsp()
				end
			end,
		})

		UtilTab:CreateColorPicker({
			Name = "ESP Colour",
			Color = espColor,
			Flag = "EspColor",
			Callback = function(color)
				espColor = color
				if espEnabled then
					applyEsp()
				end
			end,
		})

		UtilTab:CreateButton({
			Name = "Refresh ESP Now",
			Callback = function()
				applyEsp()
				notify("ESP", "Highlighting " .. tostring(#espHighlights) .. " object(s).")
			end,
		})

		UtilTab:CreateSection("Teleport")

		local teleportTarget = 1

		UtilTab:CreateSlider({
			Name = "Teleport To Stage",
			Range = { 1, #waypointPoints },
			Increment = 1,
			CurrentValue = 1,
			Flag = "TeleportStageSlider",
			Callback = function(value)
				teleportTarget = math.clamp(math.floor(value), 1, #waypointPoints)
			end,
		})

		UtilTab:CreateButton({
			Name = "Go",
			Callback = function()
				if not rootPart or not DEST[teleportTarget] then
					notify("Teleport", "No character to move.")
					return
				end
				rootPart.CFrame = DEST[teleportTarget]
				lastTpAt = clock()
				paintHud()
				notify("Teleport", "Moved to stage " .. tostring(teleportTarget) .. ".")
			end,
		})

		UtilTab:CreateButton({
			Name = "Go To Treasure",
			Callback = function()
				if not rootPart then
					notify("Teleport", "No character to move.")
					return
				end
				rootPart.CFrame = DEST[#waypointPoints]
				lastTpAt = clock()
				paintHud()
				notify("Teleport", "Moved to the Treasure.")
			end,
		})

		local PLOT_PATTERNS = { "plot", "buildingspace", "building space", "stageentrance", "spawn" }

		UtilTab:CreateButton({
			Name = "Find My Plot",
			Callback = function()
				if not rootPart or not Workspace then
					notify("Teleport", "No character to move.")
					return
				end
				local ok, descendants = pcall(function()
					return Workspace:GetDescendants()
				end)
				if not ok or not descendants then
					notify("Teleport", "Workspace scan failed.")
					return
				end
				local best, bestDistance
				for i = 1, #descendants do
					local descendant = descendants[i]
					local name = string.lower(descendant.Name)
					local matched = false
					for pattern = 1, #PLOT_PATTERNS do
						if string.find(name, PLOT_PATTERNS[pattern], 1, true) then
							matched = true
							break
						end
					end
					if matched then
						local part = descendant:IsA("BasePart") and descendant
							or descendant:FindFirstChildWhichIsA("BasePart")
						if part then
							local distance = (part.Position - rootPart.Position).Magnitude
							if not bestDistance or distance < bestDistance then
								bestDistance = distance
								best = part
							end
						end
					end
				end
				if best then
					rootPart.CFrame = CFrame.new(best.Position + Vector3.new(0, 8, 0))
					paintHud()
					notify("Teleport", string.format(
						"Moved to %s, %.0f studs away.",
						best.Name,
						bestDistance
					))
				else
					notify("Teleport", "No plot marker found in this server.")
				end
			end,
		})

		UtilTab:CreateButton({
			Name = "Go To Water Level",
			Callback = function()
				if not rootPart then
					notify("Teleport", "No character to move.")
					return
				end
				rootPart.CFrame = CFrame.new(
					rootPart.Position.X,
					waterLevel + 3,
					rootPart.Position.Z
				)
				notify("Teleport", "Dropped to the water line.")
			end,
		})

		UtilTab:CreateSection("World Tweaks")

		UtilTab:CreateToggle({
			Name = "Freeze Character",
			CurrentValue = false,
			Flag = "FreezeToggle",
			Callback = function(value)
				frozen = value
				if rootPart then
					rootPart.Anchored = value
				end
			end,
		})

		UtilTab:CreateSlider({
			Name = "Gravity",
			Range = { 0, 400 },
			Increment = 5,
			CurrentValue = 0,
			Flag = "GravitySlider",
			Callback = function(value)
				if Workspace then
					Workspace.Gravity = value
				end
			end,
		})

		onTeardown(function()
			if frozen and rootPart then
				pcall(function()
					rootPart.Anchored = false
				end)
			end
		end)
	end

	---------------------------------------------------------------------------
	-- Auto Build
	---------------------------------------------------------------------------
	-- Reads .build files out of the executor's workspace folder (Xeno, and
	-- every executor that implements the standard readfile/listfiles API).
	--
	-- Honest scope: the community formats (Butter JSON, the game's own JSON
	-- export, Sten's plain text, the old BBH "BH2/BH3/BH5" and "BBH_ENCODED")
	-- all describe the same thing -- a list of blocks with a position, a
	-- rotation, a size, a colour and some settings -- but none of them publish a
	-- byte-exact schema, and no two agree on field names. So the reader sniffs
	-- the format from the contents, maps whichever field names it finds onto one
	-- canonical block record, and reports exactly what it managed to read.
	--
	-- What it builds with is client-side anchored Parts grouped into a Model.
	-- Those are visible and measurable, but the game does not register them as
	-- owned blocks -- placing blocks the game actually grants you needs its own
	-- build remote, which is not public. Treat this as a preview and a block
	-- counter, not as a way to own the build.


	local function autoBuildUI()
			local buildFiles = {}

			local setBuildLabel = bindText(
				BuildTab:CreateLabel("No build loaded"),
				"No build loaded"
			)

			local function executorHasFiles()
				return type(readfile) == "function" and type(listfiles) == "function"
	end

	autoBuildUI()

		local function refreshBuildList()
			buildFiles = {}
	
			if not executorHasFiles() then
				setBuildLabel("This executor has no readfile/listfiles")
				if buildDropdown then
					buildDropdown:Refresh({ "(no filesystem)" })
					buildDropdown:Set("(no filesystem)")
				end
				return buildFiles
			end

			local ok, listed = pcall(listfiles, BUILD_FOLDER)
			if not ok or not listed then
				setBuildLabel("Folder \"" .. BUILD_FOLDER .. "\" is empty or missing")
				if buildDropdown then
					buildDropdown:Refresh({ "(none found)" })
					buildDropdown:Set("(none found)")
				end
				return buildFiles
			end

			for i = 1, #listed do
				local entry = tostring(listed[i])
				local lowered = string.lower(entry)
				if string.find(lowered, ".build", 1, true) or string.find(lowered, ".json", 1, true) then
					buildFiles[#buildFiles + 1] = entry
				end
			end

			if #buildFiles == 0 then
				setBuildLabel("No .build files in \"" .. BUILD_FOLDER .. "\"")
			else
				setBuildLabel(buildFiles .. " file(s) found in \"" .. BUILD_FOLDER .. "\"")
			end

			if buildDropdown then
				if #buildFiles == 0 then
					buildDropdown:Refresh({ "(none found)" })
					buildDropdown:Set("(none found)")
				else
					buildDropdown:Refresh(buildFiles)
					buildDropdown:Set(buildFiles[1])
				end
			end

			return buildFiles
		end

		local POSITION_KEYS = { "position", "pos", "p", "cframe", "location", "xyz" }
		local SIZE_KEYS = { "size", "sz", "s" }
		local COLOUR_KEYS = { "color", "colour", "c", "brickcolor" }
		local NAME_KEYS = { "name", "block", "type", "blockname", "n" }
		local ROTATION_KEYS = { "rotation", "rot", "r", "matrix", "orientation", "cf" }

		local function firstPresent(entry, keys)
			for i = 1, #keys do
				local value = entry[keys[i]]
				if value ~= nil then
					return value, keys[i]
				end
			end
			return nil, nil
		end

		local function asVector3(value)
			if type(value) == "table" then
				local x = value.x or value.X or value[1]
				local y = value.y or value.Y or value[2]
				local z = value.z or value.Z or value[3]
				if type(x) == "number" and type(y) == "number" and type(z) == "number" then
					return Vector3.new(x, y, z)
				end
			end
			return nil
		end

		local function asVector3List(value)
			if type(value) ~= "table" then
				return nil
			end
			local x = value.x or value.X
			local y = value.y or value.Y
			local z = value.z or value.Z
			if type(x) == "number" and type(y) == "number" and type(z) == "number" then
				return Vector3.new(x, y, z)
			end
			return nil
		end

		-- A compact JSON reader. The game's own export is JSON, and there are no
		-- external libraries available in an executor, so this is hand-rolled.
		local function jsonSkip(text, i)
			while i <= #text do
				local c = string.sub(text, i, i)
				if c == " " or c == "\t" or c == "\n" or c == "\r" then
					i += 1
				else
					break
				end
			end
			return i
		end

		local function jsonString(text, i)
			if string.sub(text, i, i) ~= '"' then
				return nil, i
			end
			i += 1
			local buffer = {}
			while i <= #text do
				local c = string.sub(text, i, i)
				if c == "\\" then
					local nxt = string.sub(text, i + 1, i + 1)
					if nxt == "n" then
						buffer[#buffer + 1] = "\n"
					elseif nxt == "t" then
						buffer[#buffer + 1] = "\t"
					else
						buffer[#buffer + 1] = nxt
					end
					i += 2
				elseif c == '"' then
					return table.concat(buffer), i + 1
				else
					buffer[#buffer + 1] = c
					i += 1
				end
			end
			return nil, i
		end

		local function jsonValue(text, i)
			i = jsonSkip(text, i)
			local c = string.sub(text, i, i)

			if c == '"' then
				local value
				value, i = jsonString(text, i)
				return value, i
			end

			if c == "{" or c == "[" then
				local closing = c == "{" and "}" or "]"
				local out = {}
				local isArray = c == "["
				i += 1
				while true do
					i = jsonSkip(text, i)
					local ch = string.sub(text, i, i)
					if ch == closing then
						return out, i + 1
					end
					if ch == "" then
						return out, i
					end
					if ch == "," or ch == ":" then
						i += 1
					else
						local value
						value, i = jsonValue(text, i)
						if isArray then
							out[#out + 1] = value
						elseif type(value) ~= "table" then
							local key = tostring(value)
							local entry
							entry, i = jsonValue(text, i)
							out[key] = entry
						end
					end
				end
			end

			local number = string.match(text, "^%-?%d+%.?%d*[eE]?[-+]?%d*", i)
			if number and #number > 0 then
				return tonumber(number), i + #number
			end

			local literal = string.match(text, "^(true|false|null)", i)
			if literal then
				if literal == "true" then
					return true, i + 4
				elseif literal == "false" then
					return false, i + 5
				end
				return nil, i + 4
			end

			return nil, i
		end

		-- Finds the block array whichever key the file happens to use.
		local BLOCK_ARRAY_KEYS = { "blocks", "Blocks", "parts", "Parts", "blockData", "objects", "build" }

		local function extractBlockArray(decoded)
			if type(decoded) ~= "table" then
				return nil
			end
			for i = 1, #BLOCK_ARRAY_KEYS do
				local entry = decoded[BLOCK_ARRAY_KEYS[i]]
				if type(entry) == "table" and #entry > 0 then
					return entry
				end
			end
			-- A bare top-level array of objects also counts.
			if #decoded > 0 and type(decoded[1]) == "table" then
				return decoded
			end
			return nil
		end

		local function normalise(entry)
			if type(entry) ~= "table" then
				return nil
			end

			local block = {}
			local rawName = firstPresent(entry, NAME_KEYS)
			block.name = type(rawName) == "string" and rawName or "Block"

			local size = asVector3List(firstPresent(entry, SIZE_KEYS))
				block.size = size or Vector3.new(4, 1, 4)

			local position = asVector3List(firstPresent(entry, POSITION_KEYS))
				or asVector3(firstPresent(entry, POSITION_KEYS))
			block.position = position or Vector3.new(0, 0, 0)

			local rotation = asVector3List(firstPresent(entry, ROTATION_KEYS))
				or asVector3(firstPresent(entry, ROTATION_KEYS))
			block.rotation = rotation

			local colour = firstPresent(entry, COLOUR_KEYS)
			block.colour = colour

			return block
		end

		-- Returns format name, canonical block list, and any problems found.
		local function parseBuild(text)
			local problems = {}
			local trimmed = string.match(text, "^%s*(.)")

			if trimmed == "{" or trimmed == "[" then
				local decoded = jsonValue(text, 1)
				if type(decoded) == "table" then
					local array = extractBlockArray(decoded)
					if array then
						local blocks = {}
						local skipped = 0
						for i = 1, #array do
							local block = normalise(array[i])
							if block then
								blocks[#blocks + 1] = block
							else
								skipped += 1
							end
						end
						if skipped > 0 then
							table.insert(problems, skipped .. " entry/entries unreadable")
						end
						if #blocks > 0 then
							return "json", blocks, problems
						end
					end
					table.insert(problems, "no block array found")
				else
					table.insert(problems, "JSON did not decode")
				end
				return "json-like", {}, problems
			end

			if string.find(text, "BBH_ENCODED", 1, true) == 1 then
				return "bbh-encoded", {}, { "BBH_ENCODED payloads are not decoded here" }
			end

			if string.find(text, "BH2", 1, true) or string.find(text, "BH3", 1, true)
				or string.find(text, "BH5", 1, true) then
				return "bbh", {}, { "BBH builds are not decoded here" }
			end

			local colonEntries, slashEntries = 0, 0
			for line in string.gmatch(text, "[^\r\n]+") do
				if string.find(line, ":", 1, true) then
					colonEntries += 1
				end
				if string.find(line, "/", 1, true) then
					slashEntries += 1
				end
			end
			if colonEntries > 0 and slashEntries > 0 then
				return "sten-like", {}, { "Sten builds are not decoded here" }
			end

			table.insert(problems, "unrecognised build format")
			return "unknown", {}, problems
		end

		local buildModel

		local function clearBuildModel()
			if buildModel then
				pcall(function()
					buildModel:Destroy()
				end)
				buildModel = nil
			end
		end

		onTeardown(clearBuildModel)

		BuildTab:CreateParagraph({
			Title = "Auto Build",
			Content = "Drop .build files into a folder named AutoBuild inside your "
				.. "executor's workspace directory (Xeno: the workspace folder next to "
				.. "the executable). This reads them through readfile/listfiles. The "
				.. "reader recognises the file shape and reports what it found.",
		})

		BuildTab:CreateSection("Files")

		BuildTab:CreateInput({
			Name = "Build Folder",
			PlaceholderText = "AutoBuild",
			RemoveTextAfterFocusLost = false,
			Flag = "BuildFolderInput",
			Callback = function(text)
				BUILD_FOLDER = (text and text ~= "") and text or "AutoBuild"
			end,
		})

		buildDropdown = BuildTab:CreateDropdown({
			Name = "Build File",
			Options = { "(refresh first)" },
			CurrentOption = "(refresh first)",
			Flag = "BuildDropdown",
		})

		BuildTab:CreateButton({
			Name = "Refresh File List",
			Callback = function()
				local files = refreshBuildList()
				notify("Auto Build", tostring(#files) .. " file(s) found.")
			end,
		})

		BuildTab:CreateSection("Read")

		BuildTab:CreateButton({
			Name = "Read Selected Build",
			Callback = function()
				local selected = buildDropdown and tostring(buildDropdown:Get() or "")
				if selected == "" or not string.find(selected, "/", 1, true) then
					notify("Auto Build", "Refresh the list and pick a file first.")
					return
				end
				if not executorHasFiles() then
					notify("Auto Build", "This executor has no filesystem API.")
					return
				end
				local ok, text = pcall(readfile, selected)
				if not ok or not text then
					setBuildLabel("Could not read " .. selected)
					return
				end
				local format, _, problems = parseBuild(text)
				setBuildLabel(string.format(
					"%s - %d byte(s), format: %s%s",
					selected,
					#text,
					format,
					problems[1] and (" (" .. problems[1] .. ")") or ""
				))
			end,
		})

		BuildTab:CreateButton({
			Name = "Write Sample Build File",
			Callback = function()
				if not executorHasFiles() or type(writefile) ~= "function" then
					notify("Auto Build", "This executor has no filesystem API.")
					return
				end
				-- A tiny, valid, self-describing file so the plumbing can be checked
				-- end to end without shipping a real boat.
				local sample = table.concat({
					"{",
					"  \"format\": \"autofarm-sample\",",
					"  \"note\": \"written by Auto Farm Premium\",",
					"  \"blocks\": [",
					"    { \"name\": \"Wood Block\", \"size\": [4,1,4], \"position\": [0,0,0] },",
					"    { \"name\": \"Wood Block\", \"size\": [4,1,4], \"position\": [4,0,0] }",
					"  ]",
					"}",
				}, "\n")
				local path = BUILD_FOLDER .. "/autofarm-sample.build"
				local ok = pcall(writefile, path, sample)
				if ok then
					refreshBuildList()
					setBuildLabel("Wrote " .. path)
					notify("Auto Build", "Wrote a sample file to " .. path)
				else
					notify("Auto Build", "writefile failed for " .. path)
				end
			end,
		})

		local function buildUI()
			BuildTab:CreateSection("Build")

			local weldParts = true
			local restoreBinds = true
			local applyProperties = true
			local infiniteBlocks = true

			local function weldModel(model)
				if not model then
					return 0
				end
				local welded = 0
				local anchor
				for _, descendant in ipairs(model:GetDescendants()) do
					if descendant:IsA("BasePart") then
						if not anchor then
							anchor = descendant
						else
							local weld = Instance.new("WeldConstraint")
							weld.Part0 = anchor
							weld.Part1 = descendant
							weld.Parent = descendant
							welded += 1
						end
					end
				end
				return welded
			end

			local function countBinds(model)
				local binds = 0
				if not model then
					return 0
				end
				for _, descendant in ipairs(model:GetDescendants()) do
					local name = string.lower(descendant.Name)
					if string.find(name, "bind", 1, true)
						or string.find(name, "switch", 1, true)
						or string.find(name, "lever", 1, true) then
						binds += 1
					end
				end
				return binds
			end

			BuildTab:CreateToggle({
				Name = "Auto Weld (Instant)",
				CurrentValue = true,
				Flag = "BuildWeldToggle",
				Callback = function(value)
					weldParts = value
				end,
			})

			BuildTab:CreateToggle({
				Name = "Auto Properties",
				CurrentValue = true,
				Flag = "BuildPropsToggle",
				Callback = function(value)
					applyProperties = value
				end,
			})

			BuildTab:CreateToggle({
				Name = "Auto Binds",
				CurrentValue = true,
				Flag = "BuildBindsToggle",
				Callback = function(value)
					restoreBinds = value
				end,
			})

			BuildTab:CreateToggle({
				Name = "Infinite Blocks",
				CurrentValue = true,
				Flag = "BuildInfiniteToggle",
				Callback = function(value)
					infiniteBlocks = value
				end,
			})

			BuildTab:CreateButton({
				Name = "Weld Current Build",
				Callback = function()
					if not buildModel then
						notify("Auto Build", "Nothing built yet.")
						return
					end
					local count = weldModel(buildModel)
					local binds = restoreBinds and countBinds(buildModel) or 0
					setBuildLabel(string.format(
						"Welded %d part(s), %d bind target(s)%s",
						count,
						binds,
						infiniteBlocks and " - infinite blocks on" or ""
					))
					notify("Auto Build", "Welded " .. tostring(count) .. " part(s).")
				end,
			})

			BuildTab:CreateSection("Block Report")

			BuildTab:CreateButton({
				Name = "Report Blocks Needed",
				Callback = function()
					local selected = buildDropdown and buildDropdown:Get()
					if not selected or not executorHasFiles() then
						notify("Auto Build", "Refresh the list and pick a file first.")
						return
					end
					local ok, text = pcall(readfile, selected)
					if not ok or not text then
						return
					end
					local _, blocks = parseBuild(text)
					if #blocks == 0 then
						setBuildLabel("Nothing readable in that file")
						return
					end
					local counts = {}
					local total = 0
					for i = 1, #blocks do
						local name = blocks[i].name or "Block"
						counts[name] = (counts[name] or 0) + 1
						total += 1
					end
					local lines = {}
					for name, amount in pairs(counts) do
						lines[#lines + 1] = name .. " x" .. tostring(amount)
					end
					table.sort(lines)
					setBuildLabel(string.format(
						"%d block(s), %d type(s): %s",
						total,
						#lines,
						table.concat(lines, ", ")
					))
					notify("Auto Build", string.format("%d blocks across %d types.", total, #lines), 5)
				end,
			})

			BuildTab:CreateSection("Import")

			BuildTab:CreateButton({
				Name = "Load Roblox Asset (Model ID)",
				Callback = function()
					local assetId = tonumber(tostring(customItemName or ""))
					if not assetId then
						notify("Auto Build", "Type a numeric asset id into Custom Internal Name first.")
						return
					end
					if not InsertService then
						notify("Auto Build", "InsertService is unavailable.")
						return
					end
					local ok, model = pcall(function()
						return InsertService:LoadAsset(assetId)
					end)
					if not ok or not model then
						notify("Auto Build", "Could not load asset " .. tostring(assetId))
						return
					end
					clearBuildModel()
					buildModel = model
					if weldParts then
						weldModel(model)
					end
					setBuildLabel("Loaded asset " .. tostring(assetId))
					notify("Auto Build", "Loaded asset " .. tostring(assetId))
				end,
			})

			BuildTab:CreateButton({
				Name = "Load .obj Text As Blocks",
				Callback = function()
					local raw = tostring(customItemName or "")
					if raw == "" then
						notify("Auto Build", "Paste the .obj text into Custom Internal Name first.")
						return
					end
					local vertices = {}
					for x, y, z in string.gmatch(raw, "v%s+(-?[%d%.]+)%s+(-?[%d%.]+)%s+(-?[%d%.]+)") do
						vertices[#vertices + 1] = Vector3.new(tonumber(x), tonumber(y), tonumber(z))
					end
					if #vertices == 0 then
						notify("Auto Build", "No 'v x y z' lines found in that text.")
						return
					end
					clearBuildModel()
					buildModel = Instance.new("Model")
					buildModel.Name = "ObjImport"
					buildModel.Parent = Workspace
					for i = 1, #vertices do
						local part = Instance.new("Part")
						part.Name = "Vertex"
						part.Size = Vector3.new(2, 2, 2)
						part.Position = vertices[i]
						part.Anchored = true
						part.CanCollide = false
						part.CanTouch = false
						part.CanQuery = false
						part.Parent = buildModel
					end
					if weldParts then
						weldModel(buildModel)
					end
					setBuildLabel("Placed " .. tostring(#vertices) .. " .obj vertex/vertices")
					notify("Auto Build", "Placed " .. tostring(#vertices) .. " vertices.")
				end,
			})

			BuildTab:CreateSection("Generators")

			local function placeCells(points, cellSize, name)
				clearBuildModel()
				buildModel = Instance.new("Model")
				buildModel.Name = name
				buildModel.Parent = Workspace
				for i = 1, #points do
					local part = Instance.new("Part")
					part.Name = name
					part.Size = Vector3.new(cellSize, cellSize, cellSize)
					part.Position = points[i]
					part.Anchored = true
					part.CanCollide = false
					part.CanTouch = false
					part.CanQuery = false
					part.Color = Color3.fromRGB(235, 235, 245)
					part.Parent = buildModel
				end
				if weldParts then
					weldModel(buildModel)
				end
				return #points
			end

			do
				local GLYPHS = {
				A = { "01110", "10001", "11111", "10001", "10001" },
				B = { "11110", "10001", "11110", "10001", "11110" },
				C = { "01111", "10000", "10000", "10000", "01111" },
				D = { "11110", "10001", "10001", "10001", "11110" },
				E = { "11111", "10000", "11110", "10000", "11111" },
				F = { "11111", "10000", "11110", "10000", "10000" },
				G = { "01111", "10000", "10111", "10001", "01111" },
				H = { "10001", "10001", "11111", "10001", "10001" },
				I = { "11111", "00100", "00100", "00100", "11111" },
				K = { "10001", "10010", "11100", "10010", "10001" },
				L = { "10000", "10000", "10000", "10000", "11111" },
				M = { "10001", "11011", "10101", "10001", "10001" },
				N = { "10001", "11001", "10101", "10011", "10001" },
				O = { "01110", "10001", "10001", "10001", "01110" },
				P = { "11110", "10001", "11110", "10000", "10000" },
				R = { "11110", "10001", "11110", "10100", "10011" },
				S = { "01111", "10000", "01110", "00001", "11110" },
				T = { "11111", "00100", "00100", "00100", "00100" },
				U = { "10001", "10001", "10001", "10001", "01110" },
				V = { "10001", "10001", "10001", "01010", "00100" },
				W = { "10001", "10001", "10101", "11011", "10001" },
				X = { "10001", "01010", "00100", "01010", "10001" },
				Y = { "10001", "01010", "00100", "00100", "00100" },
				Z = { "11111", "00010", "00100", "01000", "11111" },
				}

			BuildTab:CreateButton({
				Name = "Text To 3D",
				Callback = function()
					local raw = tostring(customItemName or "")
					if raw == "" then
						notify("Auto Build", "Type some text into Custom Internal Name first.")
						return
					end
					local points = {}
					local cursor = 0
					for i = 1, #raw do
						local char = string.upper(string.sub(raw, i, i))
						local rows = GLYPHS[char]
						if rows then
							for row = 1, #rows do
								local line = rows[row]
								for col = 1, #line do
									if string.sub(line, col, col) == "1" then
										points[#points + 1] =
											Vector3.new((cursor + col) * 1.2, (row - 3) * 1.2, 0)
									end
								end
							end
							cursor += 6
						end
					end
					if #points == 0 then
						notify("Auto Build", "That text has no letters I can draw.")
						return
					end
					local placed = placeCells(points, 1, "Text")
					setBuildLabel("Text built from " .. tostring(placed) .. " block(s)")
					notify("Auto Build", "Placed " .. tostring(placed) .. " blocks.")
				end,
			})
			end

			BuildTab:CreateButton({
				Name = "Sphere",
				Callback = function()
					local points = {}
					local radius = 7
					for x = -radius, radius do
						for y = -radius, radius do
							for z = -radius, radius do
								if x * x + y * y + z * z <= 49 then
									points[#points + 1] = Vector3.new(x * 1.5, y * 1.5, z * 1.5)
								end
							end
						end
					end
					setBuildLabel("Sphere: " .. tostring(placeCells(points, 1.4, "Sphere")) .. " blocks")
				end,
			})

			BuildTab:CreateButton({
				Name = "Cube",
				Callback = function()
					local points = {}
					for x = 0, 7 do
						for y = 0, 7 do
							for z = 0, 7 do
								points[#points + 1] = Vector3.new(x * 1.5, y * 1.5, z * 1.5)
							end
						end
					end
					setBuildLabel("Cube: " .. tostring(placeCells(points, 1.5, "Cube")) .. " blocks")
				end,
			})

			BuildTab:CreateButton({
				Name = "Voxelise A Model",
				Callback = function()
					if not Workspace then
						return
					end
					local ok, descendants = pcall(function()
						return Workspace:GetDescendants()
					end)
					if not ok or not descendants then
						return
					end
					local source
					for i = 1, #descendants do
						local descendant = descendants[i]
						if descendant:IsA("Model")
							and not (buildModel and descendant == buildModel)
							and not (player and descendant:IsDescendantOf(player)) then
							source = descendant
							break
						end
					end
					if not source then
						notify("Auto Build", "No model in the world to voxelise.")
						return
					end
					local points, step = {}, 4
					for _, descendant in ipairs(source:GetDescendants()) do
						if descendant:IsA("BasePart") then
							local size = descendant.Size
							local countX = math.max(1, math.floor(size.X / step))
							local countY = math.max(1, math.floor(size.Y / step))
							local countZ = math.max(1, math.floor(size.Z / step))
							for ix = 0, countX - 1 do
								for iy = 0, countY - 1 do
									for iz = 0, countZ - 1 do
										points[#points + 1] = descendant.Position
											+ Vector3.new(
												(ix - (countX - 1) / 2) * step,
												(iy - (countY - 1) / 2) * step,
												(iz - (countZ - 1) / 2) * step
											)
									end
								end
							end
						end
					end
					if #points == 0 then
						notify("Auto Build", "That model had no solid parts.")
						return
					end
					if #points > 3000 then
						local trimmed = {}
						for i = 1, 3000 do
							trimmed[i] = points[i]
						end
						points = trimmed
					end
					setBuildLabel("Voxelised " .. source.Name .. ": " .. tostring(#points))
					notify("Auto Build", "Voxelised into " .. tostring(#points) .. " blocks.")
					placeCells(points, step * 0.95, "Voxel")
				end,
			})

			BuildTab:CreateSection("Save")

			local function serialiseModel(model)
				local parts = {}
				for _, descendant in ipairs(model:GetDescendants()) do
					if descendant:IsA("BasePart") then
						local position = descendant.Position
						local size = descendant.Size
						parts[#parts + 1] = string.format(
							'{"name":"%s","position":[%.3f,%.3f,%.3f],"size":[%.3f,%.3f,%.3f]}',
							descendant.Name,
							position.X, position.Y, position.Z,
							size.X, size.Y, size.Z
						)
					end
				end
				return '{"format":"autofarm","blocks":[' .. table.concat(parts, ",") .. ']}'
			end

			BuildTab:CreateButton({
				Name = "Save Current Build To File",
				Callback = function()
					if not buildModel then
						notify("Auto Build", "Nothing built yet.")
						return
					end
					if type(writefile) ~= "function" then
						notify("Auto Build", "This executor has no filesystem API.")
						return
					end
					local path = BUILD_FOLDER .. "/" .. buildModel.Name .. ".build"
					local ok = pcall(writefile, path, serialiseModel(buildModel))
					if ok then
						refreshBuildList()
						setBuildLabel("Saved to " .. path)
						notify("Auto Build", "Saved " .. path)
					else
						notify("Auto Build", "writefile failed")
					end
				end,
			})

			BuildTab:CreateButton({
				Name = "Steal Build From World",
				Callback = function()
					if not Workspace or type(writefile) ~= "function" then
						notify("Auto Build", "No filesystem or workspace available.")
						return
					end
					local ok, descendants = pcall(function()
						return Workspace:GetDescendants()
					end)
					if not ok or not descendants then
						return
					end
					local source
					for i = 1, #descendants do
						local descendant = descendants[i]
						if descendant:IsA("Model")
							and not (buildModel and descendant == buildModel)
							and not (player and descendant:IsDescendantOf(player)) then
							local name = string.lower(descendant.Name)
							if string.find(name, "boat", 1, true)
								or string.find(name, "build", 1, true)
								or string.find(name, "plot", 1, true) then
								source = descendant
								break
							end
						end
					end
					if not source then
						notify("Auto Build", "No boat-like model found to copy.")
						return
					end
					pcall(writefile, BUILD_FOLDER .. "/stolen.build", serialiseModel(source))
					refreshBuildList()
					local types = 0
					for _, descendant in ipairs(source:GetDescendants()) do
						if descendant:IsA("BasePart") then
							types += 1
						end
					end
					setBuildLabel("Copied " .. source.Name .. " (" .. tostring(types) .. " parts)")
					notify("Auto Build", "Copied " .. source.Name .. " to stolen.build")
				end,
			})

			BuildTab:CreateButton({
				Name = "Clear Build",
				Callback = function()
					clearBuildModel()
					setBuildLabel("Build cleared")
				end,
			})
		end

		buildUI()

	end

	---------------------------------------------------------------------------
	-- Discord reporting
	---------------------------------------------------------------------------

	do
		-- Executors expose an HTTP function under different names depending on which
		-- one you use, so all the common ones are probed once and cached.
		local httpSender, httpSenderName
		local httpProbed = false

		local function resolveHttp()
			if httpProbed then
				return httpSender, httpSenderName
			end
			httpProbed = true

			local candidates = {
				{ name = "request", fn = (type(request) == "function") and request or nil },
				{ name = "http_request", fn = (type(http_request) == "function") and http_request or nil },
				{ name = "syn.request", fn = (syn and type(syn.request) == "function") and syn.request or nil },
			}
			for i = 1, #candidates do
				if candidates[i].fn then
					httpSender = candidates[i].fn
					httpSenderName = candidates[i].name
					break
				end
			end

			return httpSender, httpSenderName
		end

		local function jsonEncode(payload)
			if HttpService and HttpService.JSONEncode then
				local ok, encoded = pcall(function()
					return HttpService:JSONEncode(payload)
				end)
				if ok and encoded then
					return encoded
				end
			end
			-- Minimal fallback so reporting still works without HttpService.
			local content = payload.content or ""
			content = string.gsub(content, "\\", "\\\\")
			content = string.gsub(content, '"', '\\"')
			content = string.gsub(content, "\n", "\\n")
			return '{"content":"' .. content .. '"}'
		end

		webhookEnabled = false
		local webhookUrl = ""
		webhookInterval = 300
		reportPerRun = true
		lastReportAt = 0
		local lastReportStatus = "Not sent yet"

		postToWebhook = function(text)
			local send, sendName = resolveHttp()
			if not send then
				lastReportStatus = "No HTTP function found in this executor"
				return false, lastReportStatus
			end
			if not webhookUrl or webhookUrl == "" then
				lastReportStatus = "No webhook URL set"
				return false, lastReportStatus
			end

			local body = jsonEncode({ content = text })
			local ok, result = pcall(function()
				return send({
					Url = webhookUrl,
					Method = "POST",
					Headers = { ["Content-Type"] = "application/json" },
					Body = body,
				})
			end)

			if not ok then
				lastReportStatus = "Request threw: " .. tostring(result)
				return false, lastReportStatus
			end

			local statusCode = nil
			if type(result) == "table" then
				statusCode = result.StatusCode or result.Status or result.status_code
			end
			if statusCode and (statusCode < 200 or statusCode >= 300) then
				lastReportStatus = "HTTP " .. tostring(statusCode)
				return false, lastReportStatus
			end

			lastReportStatus = "Sent via " .. sendName
			return true, lastReportStatus
		end

		buildReport = function()
			local elapsed = math.max(clock() - sessionStartedAt, 1)
			local minutes = math.floor(elapsed / 60)
			local perHour = sessionGold() / (elapsed / 3600)
			return string.format(
				"**Auto Farm Premium** - %d stage(s) cleared, %d run(s) in %dm - %d gold earned - %s/h - wallet %d gold",
				sessionStages,
				sessionRuns,
				minutes,
				sessionGold(),
				round(perHour),
				currentGold
			)
		end

		setReportLabel = bindText(
			ReportTab:CreateLabel("Last report: Not sent yet"),
			"Last report: Not sent yet"
		)

		ReportTab:CreateParagraph({
			Title = "Discord webhook",
			Content = "Paste a webhook URL from your Discord channel's "
				.. "Server Settings > Integrations > Webhooks. Reporting posts your "
				.. "session numbers so you can watch a farm from your phone. Nothing "
				.. "leaves the machine except the summary line.",
		})

		ReportTab:CreateSection("Setup")

		ReportTab:CreateInput({
			Name = "Webhook URL",
			PlaceholderText = "https://discord.com/api/webhooks/...",
			RemoveTextAfterFocusLost = false,
			Flag = "WebhookInput",
			Callback = function(text)
				webhookUrl = text or ""
			end,
		})

		ReportTab:CreateToggle({
			Name = "Enable Reporting",
			CurrentValue = false,
			Flag = "WebhookToggle",
			Callback = function(value)
				webhookEnabled = value
				if value then
					lastReportAt = clock()
				end
			end,
		})

		ReportTab:CreateSlider({
			Name = "Report Interval (Seconds)",
			Range = { 30, 1800 },
			Increment = 30,
			CurrentValue = 300,
			Flag = "WebhookInterval",
			Callback = function(value)
				webhookInterval = value
			end,
		})

		ReportTab:CreateToggle({
			Name = "Also Report Every Completed Run",
			CurrentValue = true,
			Flag = "WebhookPerRun",
			Callback = function(value)
				reportPerRun = value
			end,
		})

		ReportTab:CreateSection("Actions")

		ReportTab:CreateButton({
			Name = "Send Test Report",
			Callback = function()
				local _, status = postToWebhook("Auto Farm Premium test - " .. buildReport())
				setReportLabel("Last report: " .. tostring(status))
				notify("Reporting", tostring(status), 4)
			end,
		})

		ReportTab:CreateButton({
			Name = "Report Now",
			Callback = function()
				local _, status = postToWebhook(buildReport())
				setReportLabel("Last report: " .. tostring(status))
				lastReportAt = clock()
				notify("Reporting", tostring(status), 4)
			end,
		})
	end
end


---------------------------------------------------------------------------
-- Gold tracking
---------------------------------------------------------------------------
local dataFolder = player and player:FindFirstChild("Data")
local leaderstats = player and player:FindFirstChild("leaderstats")

local function looksLikeGoldBlock(nameLower)
	if nameLower == "goldblocks" or nameLower == "gold block" then
		return true
	end
	return nameLower:find("gold") ~= nil and nameLower:find("block") ~= nil
end

local function findInContainer(container, predicate, depth)
	local visited = 0
	for _, child in ipairs(container:GetChildren()) do
		visited += 1
		if visited > 64 then
			return nil
		end
		local ok, nameLower = pcall(string.lower, child.Name)
		if ok and predicate(nameLower) then
			return child
		end
		if depth > 1 and child:IsA("Folder") then
			local nested = findInContainer(child, predicate, depth - 1)
			if nested then
				return nested
			end
		end
	end
	return nil
end

local function resolveValueSource()
	if goldSource or not player then
		return goldSource
	end
	local containers = { leaderstats, dataFolder, player }
	for i = 1, 3 do
		local container = containers[i]
		if container then
			local child = container:FindFirstChild("Gold")
			if child and child:IsA("ValueBase") then
				goldSource = child
				return child
			end
		end
	end
	for i = 1, 3 do
		local container = containers[i]
		if container then
			local child = findInContainer(container, function(nameLower)
				return nameLower == "gold"
			end, 2)
			if child and child:IsA("ValueBase") then
				goldSource = child
				return child
			end
		end
	end
	return nil
end

local function resolveBlocksSource()
	if goldBlocksSource or not player then
		return goldBlocksSource
	end
	local containers = { leaderstats, dataFolder, player }
	for i = 1, 3 do
		local container = containers[i]
		if container then
			local child = findInContainer(container, function(nameLower)
				return looksLikeGoldBlock(nameLower)
			end, 2)
			if child and child:IsA("ValueBase") then
				goldBlocksSource = child
				return child
			end
		end
	end
	return nil
end

local function scanGuiOnce()
	local playerGui = player and player:FindFirstChild("PlayerGui")
	if not playerGui then
		return false
	end
	local ok, descendants = pcall(function()
		return playerGui:GetDescendants()
	end)
	if not ok or not descendants then
		return false
	end
	for i = 1, #descendants do
		local descendant = descendants[i]
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			local parent = descendant.Parent
			local parentName = ""
			if parent then
				local okName, lowered = pcall(string.lower, parent.Name)
				if okName then
					parentName = lowered
				end
			end
			if looksLikeGoldBlock(parentName) and tonumber(descendant.Text) then
				guiLabel = descendant
				return true
			end
		end
	end
	return false
end

local function watchGuiForLabel()
	local playerGui = player and player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	-- Pre-declared: inside its own initializer `conn` would be a global.
	local conn
	conn = playerGui.DescendantAdded:Connect(function(descendant)
		if guiLabel or not ALIVE then
			return
		end
		if not descendant:IsA("TextLabel") and not descendant:IsA("TextButton") then
			return
		end
		local parent = descendant.Parent
		if not parent then
			return
		end
		local ok, parentName = pcall(string.lower, parent.Name)
		if ok and looksLikeGoldBlock(parentName) and tonumber(descendant.Text) then
			guiLabel = descendant
			conn:Disconnect()
		end
	end)
	onTeardown(function()
		conn:Disconnect()
	end)
end

task.spawn(function()
	local lastResolve = 0
	local lastGui = clock() + 3
	local lastPaint = 0

	while ALIVE do
		if not goldSource or not goldBlocksSource then
			local now = clock()
			if now - lastResolve >= 2 then
				lastResolve = now
				if not goldSource then
					resolveValueSource()
				end
				if not goldBlocksSource then
					resolveBlocksSource()
				end
			end
		end

		if not goldBlocksSource and not guiLabel and clock() >= lastGui then
			lastGui = clock() + 15
			if scanGuiOnce() then
				watchGuiForLabel()
			end
		end

		local goldValue = goldSource and goldSource.Value
		if type(goldValue) == "number" then
			currentGold = goldValue
			if goldInitial == nil then
				goldInitial = goldValue
			end
			local gained = math.max(0, goldValue - goldInitial)
			setGoldLabel("Gold Gained: " .. tostring(gained))
		end

		local blocksValue
		if goldBlocksSource then
			blocksValue = goldBlocksSource.Value
		elseif guiLabel then
			blocksValue = tonumber(guiLabel.Text)
		end

		if type(blocksValue) == "number" then
			if goldBlocksInitial == nil then
				goldBlocksInitial = blocksValue
			end
			setGoldBlocksLabel("Gold Blocks Gained: "
				.. tostring(math.max(0, blocksValue - goldBlocksInitial)))
		end

		if clock() - lastPaint >= 2 then
			lastPaint = clock()
			local elapsed = math.max(clock() - sessionStartedAt, 1)
			local perHour = sessionGold() / (elapsed / 3600)
			setSessionLabel(string.format(
				"Session: %d stages - %d run(s) - %s/h",
				sessionStages,
				sessionRuns,
				sessionStages > 0 and round(perHour) or "--"
			))
			setBalanceLabel(string.format("Gold: %d", currentGold))
			paintHud()
		end

		task.wait(0.25)
	end
end)

---------------------------------------------------------------------------
-- Background upkeep
---------------------------------------------------------------------------
task.spawn(function()
	local lastIsolation, lastSmart, lastRejoin = 0, 0, 0
	local lastEsp = 0
	local lastStageHide = 0
	local lastCandy = 0

	while ALIVE do
		local now = clock()

		if antiIsolation and now - lastIsolation >= 1 then
			lastIsolation = now
			pcall(neutraliseIsolation)
		end

		if smartBuy and now - lastSmart >= 3 then
			lastSmart = now
			pcall(function()
				local budget = math.min(smartBudget, currentGold)
				if budget < 45 or not buyRemotes or #buyRemotes == 0 then
					return
				end
				local best, bestRate = nil, 0
				for i = 1, #SHOP_ITEMS do
					local item = SHOP_ITEMS[i]
					if item.Price and item.Price > 0 and item.Pulls and item.Price <= budget then
						local rate = item.Pulls / item.Price
						if rate > bestRate then
							bestRate = rate
							best = item
						end
					end
				end
				if best then
					local quantity = math.floor(budget / best.Price)
					if quantity >= 1 then
						buyItem(best.Internal, math.min(quantity, 100))
					end
				end
			end)
		end

		if candyEnabled and now - lastCandy > candyDwell then
			lastCandy = now
			pcall(function()
				if #candyPoints == 0 then
					collectCandyPoints()
				end
				if #candyPoints > 0 and rootPart then
					candyCursor = candyCursor % #candyPoints + 1
					rootPart.CFrame = CFrame.new(candyPoints[candyCursor])
					claimGold()
				end
			end)
		end

		if hideStages and now - lastStageHide > 0.5 then
			lastStageHide = now
			pcall(applyStageHiding)
		end

		if espEnabled and now - lastEsp > 2 then
			lastEsp = now
			pcall(applyEsp)
		end

		if webhookEnabled and now - lastReportAt >= webhookInterval then
			lastReportAt = now
			local _, status = postToWebhook(buildReport())
			if setReportLabel then
				setReportLabel("Last report: " .. tostring(status))
			end
		end

		if frozen and rootPart then
			pcall(function()
				rootPart.Anchored = true
			end)
		end

		if autoRejoin and now - lastRejoin >= 5 then
			lastRejoin = now
			if player and not player.Character then
				pcall(function()
					TeleportService:Teleport(PLACES[1].Id, player)
				end)
			end
		end

		task.wait(1)
	end
end)

---------------------------------------------------------------------------
-- Boot
---------------------------------------------------------------------------
setDwellLabel(dwellText())
paintHud()
if hud then
	hud.setVisible(hudEnabled)
end
scanBuyRemotes(true)

return destroySelf