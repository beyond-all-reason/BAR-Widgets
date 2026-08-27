function widget:GetInfo()
	return {
		name    = "Auto FPS Boost",
		desc    = "Automatically lowers graphics effects when FPS drops and restores them when it recovers. /fpsboost: toggle. /fpsboost status: status window.",
		author  = "Matthieu (Arginou57)",
		date    = "2026-08-27",
		license = "GNU GPL v2 or later",
		layer   = -99999,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Settings (tweakable)
--------------------------------------------------------------------------------
local FPS_LOW      = 45   -- below this FPS: reduce details
local FPS_HIGH     = 70   -- above this FPS: restore details
local CHECK_PERIOD = 1.0  -- seconds between two FPS samples
local SAMPLES_DOWN = 3    -- consecutive samples below FPS_LOW before stepping down
local SAMPLES_UP   = 10   -- consecutive samples above FPS_HIGH before stepping up

-- Expensive widgets disabled at level 2, then 3, then 4 (only if they were active).
-- Ordered by cost measured with the Widget Profiler (late-game 8v8 battles).
local LEVEL2_WIDGETS = {
	"Picture-in-Picture Minimap", -- 5.1% (while spectating)
	"Commands FX",                -- 3.0% + ~580kB/s of allocations, scales with action
	"Defense Range GL4",          -- 1.6% late game
	"Sensor Ranges Radar",        -- 1.5% late game
	"Contrast Adaptive Sharpen",  -- ~1.1%, purely cosmetic
	"Decals GL4",                 -- 0.8%
	"Sensor Ranges Sonar",        -- 0.7% (the naval counterpart of Radar)
	"Sensor Ranges Jammer",
	"Ground AO Plates GL4",       -- cosmetic ambient occlusion under buildings
	"Ground AO Plates Features GL4",
	"Map Edge Extension",         -- cosmetic map edge mirroring
	"Fog Diagonal Lines GL4",
}
local LEVEL3_WIDGETS = {
	"AdvPlayersList",             -- ~2% but the player list disappears
	"Reclaim Field Highlight",    -- ~90kB/s of allocations
	"AllyCursors",
	"Airjets GL4",
	"GUI Shader",                 -- blur behind UI panels, up to 2.7% measured
	"Bloom Shader Deferred",      -- often already off; only disabled if active
	"SSAO",
	"Distortion GL4",
}
-- Level 4 "survival mode": almost no visual effects left
local LEVEL4_WIDGETS = {
	"LUPS Orb GL4",               -- depends on Lups: disable BEFORE it so it gets restored properly
	"Lups",                       -- the Lua effects engine: kills most visual effects
	"Health Bars GL4",            -- expensive in big battles; health bars are lost
	"Rank Icons GL4",
	"Orb Effects GL4",
	"Mapmarks FX",
	"Metalspots",
	"Ally Selected Units",
	"Deferred rendering GL4",     -- dynamic lights from explosions/lasers
}
local MAX_LEVEL = 4

--------------------------------------------------------------------------------

local spGetFPS       = Spring.GetFPS
local spSetConfigInt = Spring.SetConfigInt
local spGetConfigInt = Spring.GetConfigInt
local spSendCommands = Spring.SendCommands
local spEcho         = Spring.Echo

local autoMode  = true
local level     = 0      -- 0 = everything normal, 4 = survival mode
local timer     = 0
local lowCount  = 0
local highCount = 0
local showStatus  = false -- status window (/fpsboost status)
local lastFps     = 0     -- last FPS sample
local avgFps      = 0     -- smoothed average, insensitive to micro-freezes
local baselineFps = nil   -- average FPS when the first step-down triggered (for the gain display)
local vsx, vsy = Spring.GetViewGeometry()

-- original values, saved at startup
local saved = {}
-- widgets WE disabled (so we only ever re-enable those)
local disabledByMe = {}
-- snapshot taken at Shutdown: re-enable commands sent during a teardown
-- (game end, /luaui reload) can get lost; this list is persisted through
-- GetConfigData so it can be replayed next session
local shutdownPending = {}
-- widgets to re-enable once the game is up and running (commands sent while
-- loading are lost, so we wait until the game is actually running)
local restoreQueue = {}
local restoreDelay = 0

local function echo(msg)
	spEcho("\255\100\255\100[Auto FPS Boost]\255\255\255\255 " .. msg)
end

-- The widgetHandler exposed to widgets cannot disable other widgets:
-- we go through the official "luaui disablewidget/enablewidget <name>" commands.
-- eligible[] = widgets active at startup (from the widget selector config): we
-- never touch a widget the player disabled themselves.
local eligible = {}

local function buildEligible()
	local cfg = VFS and VFS.LoadFile and VFS.LoadFile("LuaUI/Config/BYAR.lua", VFS.RAW)
	for _, lst in ipairs({ LEVEL2_WIDGETS, LEVEL3_WIDGETS, LEVEL4_WIDGETS }) do
		for _, name in ipairs(lst) do
			if cfg then
				local esc = name:gsub("%p", "%%%1")
				local n = cfg:match('%["' .. esc .. '"%]%s*=%s*(%d+)')
					or cfg:match('\n%s*' .. esc .. '%s*=%s*(%d+)')
				eligible[name] = (n == nil) or (tonumber(n) > 0)
			else
				eligible[name] = true -- config unreadable: default behaviour
			end
		end
	end
end

local function disableWidgets(list)
	for _, name in ipairs(list) do
		if eligible[name] and not disabledByMe[name] then
			spSendCommands("luaui disablewidget " .. name)
			disabledByMe[name] = true
		end
	end
end

local function enableWidgets(list)
	for _, name in ipairs(list) do
		if disabledByMe[name] then
			spSendCommands("luaui enablewidget " .. name)
			disabledByMe[name] = nil
		end
	end
end

local function applyLevel(newLevel)
	if newLevel == level then return end
	local old = level
	level = newLevel

	if level >= 1 then
		spSetConfigInt("MaxParticles",     math.floor(saved.maxParticles * 0.5))
		spSetConfigInt("MaxNanoParticles", math.floor(saved.maxNano * 0.5))
	else
		spSetConfigInt("MaxParticles",     saved.maxParticles)
		spSetConfigInt("MaxNanoParticles", saved.maxNano)
	end

	if level >= 2 then
		-- units turn into icons sooner = far fewer 3D models to draw
		spSendCommands("disticon " .. math.floor(saved.iconDist * 0.6))
		-- distant wrecks are no longer drawn (there are a LOT of them late game)
		spSetConfigInt("FeatureDrawDistance", math.min(saved.featureDraw, 1200))
		spSetConfigInt("FeatureFadeDistance", math.min(saved.featureFade, 1000))
		disableWidgets(LEVEL2_WIDGETS)
	else
		spSendCommands("disticon " .. saved.iconDist)
		spSetConfigInt("FeatureDrawDistance", saved.featureDraw)
		spSetConfigInt("FeatureFadeDistance", saved.featureFade)
		enableWidgets(LEVEL2_WIDGETS)
	end

	if level >= 3 then
		spSetConfigInt("MaxParticles",     math.floor(saved.maxParticles * 0.25))
		spSetConfigInt("MaxNanoParticles", math.floor(saved.maxNano * 0.25))
		spSendCommands("disticon " .. math.floor(saved.iconDist * 0.35))
		-- engine levers: no effect if already at minimum in the player's settings
		if saved.shadows > 0 then spSendCommands("shadows 0") end
		if saved.water > 0 then spSendCommands("water 0") end
		if saved.groundDetail > 60 then spSendCommands("grounddetail 60") end
		if saved.groundDecals > 0 then spSendCommands("grounddecals 0") end
		disableWidgets(LEVEL3_WIDGETS)
	elseif old >= 3 then
		if saved.shadows > 0 then spSendCommands("shadows " .. saved.shadows) end
		if saved.water > 0 then spSendCommands("water " .. saved.water) end
		if saved.groundDetail > 60 then spSendCommands("grounddetail " .. saved.groundDetail) end
		if saved.groundDecals > 0 then spSendCommands("grounddecals " .. saved.groundDecals) end
		enableWidgets(LEVEL3_WIDGETS)
	end

	if level >= 4 then
		-- survival mode: almost no particles, icons everywhere, wrecks only up close
		spSetConfigInt("MaxParticles", 200)
		spSetConfigInt("MaxNanoParticles", 0)
		spSendCommands("disticon " .. math.max(30, math.floor(saved.iconDist * 0.2)))
		spSetConfigInt("FeatureDrawDistance", math.min(saved.featureDraw, 600))
		spSetConfigInt("FeatureFadeDistance", math.min(saved.featureFade, 500))
		-- simplified unit and map rendering (same commands as BAR's "lowest" preset)
		if saved.cus > 0 then spSendCommands("luarules disablecusgl4") end
		if saved.advMapShading > 0 then spSendCommands("advmapshading 0") end
		disableWidgets(LEVEL4_WIDGETS)
	elseif old >= 4 then
		if saved.cus > 0 then spSendCommands("luarules reloadcusgl4") end
		if saved.advMapShading > 0 then spSendCommands("advmapshading 1") end
		enableWidgets(LEVEL4_WIDGETS)
	end

	if level > old then
		if old == 0 then baselineFps = math.floor(avgFps + 0.5) end
		echo("low FPS, details reduced (level " .. level .. "/" .. MAX_LEVEL .. ")")
	else
		if level == 0 then baselineFps = nil end
		echo("FPS OK, details restored (level " .. level .. "/" .. MAX_LEVEL .. ")")
	end
end

function widget:Initialize()
	buildEligible()
	saved.maxParticles = spGetConfigInt("MaxParticles", 20000)
	saved.maxNano      = spGetConfigInt("MaxNanoParticles", 5000)
	saved.iconDist     = spGetConfigInt("UnitIconDist", 160)
	saved.featureDraw  = spGetConfigInt("FeatureDrawDistance", 2500)
	saved.featureFade  = spGetConfigInt("FeatureFadeDistance", 2000)
	saved.shadows      = spGetConfigInt("Shadows", 0)
	saved.water        = spGetConfigInt("Water", 0)
	saved.groundDetail = spGetConfigInt("GroundDetail", 100)
	saved.groundDecals = spGetConfigInt("GroundDecals", 0)
	saved.cus          = spGetConfigInt("cus2", 1)          -- Custom Unit Shaders GL4
	saved.advMapShading = spGetConfigInt("AdvMapShading", 1)
	echo("active — thresholds: reduce below " .. FPS_LOW .. " FPS, restore above " .. FPS_HIGH .. " FPS. /fpsboost to toggle.")
end

function widget:Shutdown()
	-- snapshot BEFORE restoring: if the commands sent during the teardown are
	-- lost, GetConfigData still persists the list
	shutdownPending = {}
	for name in pairs(disabledByMe) do
		shutdownPending[#shutdownPending + 1] = name
	end
	applyLevel(0)
end

-- Safety net: disabling a widget is persisted by BAR in its config. If our
-- restore could not run (crash, teardown), the list is recovered here next
-- session and everything is re-enabled.
function widget:GetConfigData()
	local list = {}
	for name in pairs(disabledByMe) do
		list[#list + 1] = name
	end
	for _, name in ipairs(shutdownPending) do
		list[#list + 1] = name
	end
	return { pendingRestore = list }
end

function widget:SetConfigData(data)
	if data and data.pendingRestore then
		-- do NOT send the commands now: they would be lost while loading;
		-- they are replayed from Update() once the game is running
		for _, name in ipairs(data.pendingRestore) do
			restoreQueue[#restoreQueue + 1] = name
		end
	end
end

function widget:Update(dt)
	-- replay pending re-enables once the game is properly up
	if #restoreQueue > 0 then
		restoreDelay = restoreDelay + dt
		if restoreDelay > 2 then
			local n = 0
			for _, name in ipairs(restoreQueue) do
				spSendCommands("luaui enablewidget " .. name)
				eligible[name] = true
				n = n + 1
			end
			restoreQueue = {}
			echo(n .. " widget(s) re-enabled (restore from previous session)")
		end
	end

	if not autoMode then return end
	timer = timer + dt
	if timer < CHECK_PERIOD then return end
	timer = 0

	local fps = spGetFPS()
	lastFps = fps
	avgFps = (avgFps == 0) and fps or (avgFps * 0.7 + fps * 0.3)
	if fps < FPS_LOW then
		lowCount = lowCount + 1
		highCount = 0
		if lowCount >= SAMPLES_DOWN and level < MAX_LEVEL then
			lowCount = 0
			applyLevel(level + 1)
		end
	elseif fps > FPS_HIGH then
		highCount = highCount + 1
		lowCount = 0
		if highCount >= SAMPLES_UP and level > 0 then
			highCount = 0
			applyLevel(level - 1)
		end
	else
		lowCount = 0
		highCount = 0
	end
end

function widget:TextCommand(command)
	if command == "fpsboost repair" then
		-- re-enables every widget from our lists except the ones BAR disables
		-- by default: use this if a restore was lost (crash, bug)
		local DEFAULT_OFF = {
			["Bloom Shader Deferred"] = true,
			["SSAO"] = true,
			["Distortion GL4"] = true,
			["Deferred rendering GL4"] = true,
		}
		local n = 0
		for _, lst in ipairs({ LEVEL2_WIDGETS, LEVEL3_WIDGETS, LEVEL4_WIDGETS }) do
			for _, name in ipairs(lst) do
				if not DEFAULT_OFF[name] then
					spSendCommands("luaui enablewidget " .. name)
					eligible[name] = true
					n = n + 1
				end
			end
		end
		echo("repair: " .. n .. " widgets re-enabled — adjust in F11 if needed")
		return true
	elseif command == "fpsboost status" then
		showStatus = not showStatus
		echo(showStatus and "status window shown" or "status window hidden")
		return true
	elseif command == "fpsboost" then
		autoMode = not autoMode
		if autoMode then
			echo("automatic mode enabled")
		else
			applyLevel(0)
			echo("automatic mode disabled, settings restored")
		end
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Status window (/fpsboost status)
--------------------------------------------------------------------------------

local LEVEL_NAMES = { [0] = "normal", "light", "medium", "heavy", "survival" }

function widget:ViewResize()
	vsx, vsy = Spring.GetViewGeometry()
end

function widget:DrawScreen()
	if not showStatus then return end
	local fps = spGetFPS()
	local x = 12
	local y = math.floor(vsy * 0.5) -- below the minimap
	local w, h = 250, 96
	local pad = 10
	local lh = 19 -- line height

	gl.Color(0, 0, 0, 0.6)
	gl.Rect(x, y, x + w, y + h)
	-- colored edge stripe by level: green = normal, orange = reduced, red = survival
	if level == 0 then gl.Color(0.4, 1, 0.4, 0.9)
	elseif level < 3 then gl.Color(1, 0.8, 0.3, 0.9)
	else gl.Color(1, 0.4, 0.4, 0.9) end
	gl.Rect(x, y, x + 4, y + h)

	gl.Color(1, 1, 1, 1)
	local ty = y + h - pad - 12
	gl.Text("\255\100\255\100Auto FPS Boost" .. (autoMode and "" or "  \255\255\120\120(AUTO OFF)"), x + pad, ty, 15, "o")
	ty = ty - lh
	gl.Text(("FPS: %d"):format(fps), x + pad, ty, 13, "o")
	ty = ty - lh
	gl.Text(("Level: %d/%d (%s)"):format(level, MAX_LEVEL, LEVEL_NAMES[level]), x + pad, ty, 13, "o")
	ty = ty - lh
	if level > 0 and baselineFps then
		local gain = math.floor(avgFps + 0.5) - baselineFps
		local col = gain >= 0 and "\255\120\255\120+" or "\255\255\120\120"
		gl.Text(("Gain: %s%d FPS\255\255\255\255 (before boost: %d)"):format(col, gain, baselineFps), x + pad, ty, 13, "o")
	else
		gl.Text("\255\180\180\180No optimization active", x + pad, ty, 13, "o")
	end
end
