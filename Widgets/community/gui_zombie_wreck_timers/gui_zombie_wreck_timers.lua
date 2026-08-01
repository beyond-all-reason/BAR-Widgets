local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name    = "Zombie Wreck Timers",
		desc    = "When the Zombies modoption is on, shows a countdown over each wreck until it reanimates. '≤' = upper bound (wreck first seen after creation), '~' = wreck spent time out of LOS (timer may have been reset unseen). Display only.",
		author  = "Egzothicki",
		date    = "July 2026",
		license = "GNU GPL, v2 or later",
		layer   = 10,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local textSize    = 16    -- world size of the countdown text
local heightBonus = 25    -- how far above the wreck to float the text
local maxDrawDist = 7000  -- don't draw further than this from the camera
local warnSeconds = 15    -- flash below this (matches the game's mist warning)

--------------------------------------------------------------------------------
-- Zombie gadget timing (from luarules/gadgets/unit_zombies.lua):
--   delay = clamp(floor(metalCost / 16), 60, 180) seconds from corpse creation.
--   Due to gadget init order this table is built with Normal-mode constants on
--   every difficulty, so one formula covers all modes.
--   Any reclaim/resurrect build-step on the wreck RESETS the timer to full.
--------------------------------------------------------------------------------
local REZ_SPEED = 16
local REZ_MIN   = 60
local REZ_MAX   = 180

local gameSpeed = Game.gameSpeed

local spGetFeatureDefID    = Spring.GetFeatureDefID
local spGetFeaturePosition = Spring.GetFeaturePosition
local spGetFeatureResources = Spring.GetFeatureResources
local spGetAllFeatures     = Spring.GetAllFeatures
local spIsPosInLos         = Spring.IsPosInLos
local spGetGameFrame       = Spring.GetGameFrame
local spGetCameraPosition  = Spring.GetCameraPosition
local spIsGUIHidden        = Spring.IsGUIHidden

local glPushMatrix = gl.PushMatrix
local glPopMatrix  = gl.PopMatrix
local glTranslate  = gl.Translate
local glBillboard  = gl.Billboard
local glText       = gl.Text
local glDepthTest  = gl.DepthTest
local glColor      = gl.Color

local floor  = math.floor
local format = string.format

local delayFrames = {}  -- featureDefID -> spawn delay in frames
-- tracked[featureID] = { defID, x, y, z, spawnFrame, exact, hidden, lastMetal, lastReclaimLeft }
local tracked = {}

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function addFeature(featureID, frame, exact)
	local defID = spGetFeatureDefID(featureID)
	local delay = defID and delayFrames[defID]
	if not delay then
		return
	end
	local x, y, z = spGetFeaturePosition(featureID)
	if not x then
		return
	end
	local metal, _, _, _, reclaimLeft = spGetFeatureResources(featureID)
	tracked[featureID] = {
		defID = defID,
		x = x, y = y, z = z,
		spawnFrame = frame + delay,
		exact = exact,
		hidden = false,
		lastMetal = metal or 0,
		lastReclaimLeft = reclaimLeft or 1,
	}
end

function widget:Initialize()
	local zombies = Spring.GetModOptions().zombies
	if not zombies or zombies == "disabled" then
		widgetHandler:RemoveWidget(self)
		return
	end

	for unitDefID, unitDef in pairs(UnitDefs) do
		local corpseName = unitDef.corpse or unitDef.wreckName
		local corpseDef = corpseName and FeatureDefNames[corpseName and corpseName:lower() or ""]
		if not corpseDef and corpseName then
			corpseDef = FeatureDefNames[corpseName]
		end
		if corpseDef then
			local seconds = clamp(floor(unitDef.metalCost / REZ_SPEED), REZ_MIN, REZ_MAX)
			delayFrames[corpseDef.id] = seconds * gameSpeed
		end
	end

	if next(delayFrames) == nil then
		widgetHandler:RemoveWidget(self)
		return
	end

	-- wrecks already on the map: the gadget queued them when it initialized,
	-- so game-start features are exact; anything later is an upper bound
	local frame = spGetGameFrame()
	local exact = frame <= 30
	local features = spGetAllFeatures()
	for i = 1, #features do
		addFeature(features[i], frame, exact)
	end
end

function widget:FeatureCreated(featureID, allyTeamID)
	addFeature(featureID, spGetGameFrame(), true)
end

function widget:FeatureDestroyed(featureID)
	tracked[featureID] = nil
end

function widget:GameFrame(frame)
	if frame % 30 ~= 11 then
		return
	end

	-- discover wrecks we never saw the creation of (entered LOS later)
	local features = spGetAllFeatures()
	local seen = {}
	for i = 1, #features do
		local featureID = features[i]
		seen[featureID] = true
		if not tracked[featureID] then
			addFeature(featureID, frame, false)
		end
	end

	for featureID, data in pairs(tracked) do
		local x, y, z = spGetFeaturePosition(featureID)
		if not x then
			-- gone (destroyed/spawned out of view, or out of LOS for players)
			if not seen[featureID] and spIsPosInLos(data.x, data.y, data.z) then
				tracked[featureID] = nil
			else
				data.hidden = true -- can't observe it; timer may get reset unseen
			end
		else
			data.x, data.y, data.z = x, y, z
			if spIsPosInLos(x, y, z) then
				-- tamper detection: reclaim/rez build-steps reset the gadget timer
				local metal, _, _, _, reclaimLeft = spGetFeatureResources(featureID)
				metal = metal or 0
				reclaimLeft = reclaimLeft or 1
				if metal < data.lastMetal - 0.01 or reclaimLeft < data.lastReclaimLeft - 0.001 then
					data.spawnFrame = frame + delayFrames[data.defID]
					data.exact = true -- observed reset: timer is now known exactly
					data.hidden = false
				end
				data.lastMetal = metal
				data.lastReclaimLeft = reclaimLeft
				-- overdue while fully visible: we missed a reset somewhere, re-arm as upper bound
				if frame > data.spawnFrame + 3 * gameSpeed then
					data.spawnFrame = frame + delayFrames[data.defID]
					data.exact = false
				end
			else
				data.hidden = true
			end
		end
	end
end

function widget:DrawWorld()
	if spIsGUIHidden() or next(tracked) == nil then
		return
	end
	local frame = spGetGameFrame()
	local camX, camY, camZ = spGetCameraPosition()
	local maxDistSq = maxDrawDist * maxDrawDist

	glDepthTest(false)
	for featureID, data in pairs(tracked) do
		local remaining = (data.spawnFrame - frame) / gameSpeed
		if not data.exact or remaining >= 0 then
			local dx, dy, dz = data.x - camX, data.y - camY, data.z - camZ
			if (dx * dx + dy * dy + dz * dz) < maxDistSq then
				local text, r, g, b, a
				if not data.exact then
					-- unknown age (wreck first seen after creation): no fake countdown
					text, r, g, b, a = "?", 0.8, 0.8, 0.8, 0.7
				else
					if remaining >= 60 then
						text = format("%d:%02d", floor(remaining / 60), floor(remaining % 60))
					else
						text = format("%d", floor(remaining))
					end
					if data.hidden then
						text = "~" .. text
					end
					-- royal purple ladder: white above 2min, purple above 1min,
					-- deeper below, deep dark + pulse in the mist window
					r, g, b, a = 0.95, 0.95, 0.95, 0.85
					if remaining < warnSeconds then
						local pulse = 0.6 + 0.4 * math.sin(frame * 0.35)
						r, g, b, a = 0.45, 0.20, 0.75, pulse
					elseif remaining < 60 then
						r, g, b = 0.58, 0.36, 0.88
					elseif remaining < 120 then
						r, g, b = 0.78, 0.62, 1.0
					end
					if data.hidden then
						a = a * 0.6
					end
				end

				glPushMatrix()
				glTranslate(data.x, data.y + heightBonus, data.z)
				glBillboard()
				glColor(r, g, b, a)
				glText(text, 0, 0, textSize, "con")
				glPopMatrix()
			end
		end
	end
	glColor(1, 1, 1, 1)
	glDepthTest(true)
end
