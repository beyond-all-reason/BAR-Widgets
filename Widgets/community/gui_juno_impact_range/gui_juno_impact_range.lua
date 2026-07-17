local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Juno Shot Ranges",
		desc = "Draws an AOE circle while targeting Juno, and after impact",
		author = "Rysica",
		date = "2026-07",
		license = "GNU GPL, v2 or later",
		layer = 5,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Localize
--------------------------------------------------------------------------------
local spGetProjectilesInRectangle = Spring.GetProjectilesInRectangle
local spGetProjectileDefID = Spring.GetProjectileDefID
local spGetProjectileTarget = Spring.GetProjectileTarget
local spGetProjectilePosition = Spring.GetProjectilePosition
local spGetProjectileTeamID = Spring.GetProjectileTeamID
local spGetGroundHeight = Spring.GetGroundHeight
local spGetMyAllyTeamID = Spring.GetMyAllyTeamID
local spGetTeamInfo = Spring.GetTeamInfo
local spGetUnitPosition = Spring.GetUnitPosition
local spIsGUIHidden = Spring.IsGUIHidden
local spIsSphereInView = Spring.IsSphereInView
local spGetGameFrame = Spring.GetGameFrame
local spGetActiveCommand = Spring.GetActiveCommand
local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spGetSelectedUnitsSorted = Spring.GetSelectedUnitsSorted
local spIsAboveMiniMap = Spring.IsAboveMiniMap
local spWorldToScreenCoords = Spring.WorldToScreenCoords

local mapSizeX = Game.mapSizeX
local mapSizeZ = Game.mapSizeZ

local glColor = gl.Color
local glLineWidth = gl.LineWidth
local glDepthTest = gl.DepthTest
local glDrawGroundCircle = gl.DrawGroundCircle

local math_ceil = math.ceil

local CMD_ATTACK = CMD.ATTACK
local CMD_MANUALFIRE = CMD.MANUALFIRE
local CMD_MANUAL_LAUNCH = GameCMD and GameCMD.MANUAL_LAUNCH

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local CIRCLE_DIVS = 96
local UPDATE_INTERVAL = 0.15 -- seconds
-- Persist circle for 27s after impact (gameframes at 30fps), then fade in last 0.5s.
local JUNO_EFFECT_TTL_FRAMES = 810 -- 27s
local JUNO_EFFECT_DECAY_FRAMES = 15 -- 0.5s at 30fps
local LINE_WIDTH = 2.2
local HEIGHT_OFFSET = 3
local TIMER_FONT_SIZE = 14

-- Green (matches BAR projectile-AOE juno color)
local ALLY_COLOR = { 0.25, 1.0, 0.35, 0.70 }
local ENEMY_COLOR = { 0.45, 1.0, 0.20, 0.75 }
local RETICLE_COLOR = { 0.87, 0.94, 0.40, 0.85 } -- match Attack AoE juno color
local AOE_DRAW_SCALE = 0.65 -- draw circle at 65% of true damage AOE

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local junoWeapons = {} -- weaponDefID -> { aoe = number }
local junoUnitAoe = {} -- unitDefID -> aoe of its juno weapon
local inFlight = {} -- proID -> pending impact data (not drawn)
local impacts = {} -- active ground circles after detonation
local updateAccum = 0
local myAllyTeamID = 0
local font

-- Targeting reticle (updated each draw)
local aimTx, aimTy, aimTz, aimAoe

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function IsJunoWeapon(wd)
	if not wd then
		return false
	end
	local name = (wd.name or ""):lower()
	if name:find("juno", 1, true) then
		return true
	end
	local cp = wd.customParams or wd.customparams
	if cp and (cp.junotype or cp.junoType) then
		return true
	end
	return false
end

local function BuildWeaponCache()
	junoWeapons = {}
	junoUnitAoe = {}

	for wdid, wd in pairs(WeaponDefs) do
		if IsJunoWeapon(wd) then
			local aoe = wd.damageAreaOfEffect or wd.areaofeffect or 0
			if aoe > 0 then
				junoWeapons[wdid] = { aoe = aoe }
			end
		end
	end

	for udid, ud in pairs(UnitDefs) do
		local weapons = ud.weapons
		if weapons then
			for i = 1, #weapons do
				local wdid = weapons[i].weaponDef
				local info = wdid and junoWeapons[wdid]
				if info then
					junoUnitAoe[udid] = info.aoe
					break
				end
			end
		end
	end
end

local function GetProjectileTargetPos(proID)
	local targetType, targetData = spGetProjectileTarget(proID)
	if not targetType then
		return nil
	end

	-- Ground
	if targetType == 103 then -- 'g'
		if type(targetData) == "table" then
			return targetData[1], targetData[2], targetData[3]
		end
	-- Unit
	elseif targetType == 117 then -- 'u'
		local ux, uy, uz = spGetUnitPosition(targetData)
		if ux then
			return ux, uy, uz
		end
	-- Projectile (interceptor)
	elseif targetType == 112 then -- 'p'
		local px, py, pz = spGetProjectilePosition(targetData)
		if px then
			return px, py, pz
		end
	end
	return nil
end

local function ColorForTeam(teamID)
	local _, _, _, _, _, allyTeamID = spGetTeamInfo(teamID)
	if allyTeamID == myAllyTeamID then
		return ALLY_COLOR
	end
	return ENEMY_COLOR
end

local function ImpactAlpha(ageFrames, baseAlpha)
	if ageFrames >= JUNO_EFFECT_TTL_FRAMES then
		return 0
	end
	local remaining = JUNO_EFFECT_TTL_FRAMES - ageFrames
	if remaining < JUNO_EFFECT_DECAY_FRAMES then
		return baseAlpha * (remaining / JUNO_EFFECT_DECAY_FRAMES)
	end
	return baseAlpha
end

local function IsJunoAimCommand(cmd)
	if not cmd then
		return false
	end
	if cmd == CMD_MANUALFIRE or cmd == CMD_ATTACK then
		return true
	end
	if CMD_MANUAL_LAUNCH and cmd == CMD_MANUAL_LAUNCH then
		return true
	end
	return false
end

local function GetSelectedJunoAoe()
	local sel = spGetSelectedUnitsSorted()
	if not sel then
		return nil
	end
	local bestAoe
	for unitDefID, _ in pairs(sel) do
		local aoe = junoUnitAoe[unitDefID]
		if aoe and (not bestAoe or aoe > bestAoe) then
			bestAoe = aoe
		end
	end
	return bestAoe
end

local function UpdateAimReticle()
	aimTx, aimTy, aimTz, aimAoe = nil, nil, nil, nil

	local _, cmd = spGetActiveCommand()
	if not IsJunoAimCommand(cmd) then
		return
	end

	local aoe = GetSelectedJunoAoe()
	if not aoe then
		return
	end

	local mx, my = spGetMouseState()
	if not mx or spIsAboveMiniMap(mx, my) then
		return
	end

	local _, pos = spTraceScreenRay(mx, my, true)
	if not pos then
		return
	end

	aimTx = pos[1]
	aimTy = (pos[2] or 0) + HEIGHT_OFFSET
	aimTz = pos[3]
	aimAoe = aoe
end

--------------------------------------------------------------------------------
-- Tracking (silent until impact)
--------------------------------------------------------------------------------
local function UpdateTrackedProjectiles()
	local nowGF = spGetGameFrame()
	local seen = {}
	local all = spGetProjectilesInRectangle(0, 0, mapSizeX, mapSizeZ)

	if all then
		for i = 1, #all do
			local proID = all[i]
			local defID = spGetProjectileDefID(proID)
			local info = defID and junoWeapons[defID]
			if info then
				seen[proID] = true
				if not inFlight[proID] then
					local tx, ty, tz = GetProjectileTargetPos(proID)
					if tx then
						local groundY = spGetGroundHeight(tx, tz)
						if groundY and groundY > ty then
							ty = groundY
						end
						inFlight[proID] = {
							tx = tx,
							ty = ty + HEIGHT_OFFSET,
							tz = tz,
							aoe = info.aoe,
							color = ColorForTeam(spGetProjectileTeamID(proID) or -1),
						}
					end
				end
			end
		end
	end

	-- Projectile gone → assume impact; start ground circle
	for proID, data in pairs(inFlight) do
		if not seen[proID] then
			impacts[#impacts + 1] = {
				tx = data.tx,
				ty = data.ty,
				tz = data.tz,
				aoe = data.aoe,
				color = data.color,
				impactGF = nowGF,
			}
			inFlight[proID] = nil
		end
	end

	local i = 1
	while i <= #impacts do
		if (nowGF - impacts[i].impactGF) >= JUNO_EFFECT_TTL_FRAMES then
			impacts[i] = impacts[#impacts]
			impacts[#impacts] = nil
		else
			i = i + 1
		end
	end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
function widget:DrawWorld()
	if spIsGUIHidden() then
		return
	end

	UpdateAimReticle()

	if not aimTx and #impacts == 0 then
		return
	end

	glDepthTest(false)
	glLineWidth(LINE_WIDTH)

	-- Targeting reticle (0.65× AOE under cursor while aiming Juno)
	if aimTx then
		local radius = aimAoe * AOE_DRAW_SCALE
		if spIsSphereInView(aimTx, aimTy, aimTz, radius) then
			glColor(RETICLE_COLOR[1], RETICLE_COLOR[2], RETICLE_COLOR[3], RETICLE_COLOR[4])
			glDrawGroundCircle(aimTx, aimTy, aimTz, radius, CIRCLE_DIVS)
		end
	end

	-- Post-impact circles
	local nowGF = spGetGameFrame()
	for i = 1, #impacts do
		local data = impacts[i]
		local alpha = ImpactAlpha(nowGF - data.impactGF, data.color[4])
		local radius = data.aoe * AOE_DRAW_SCALE
		if alpha > 0.01 and spIsSphereInView(data.tx, data.ty, data.tz, radius) then
			glColor(data.color[1], data.color[2], data.color[3], alpha)
			glDrawGroundCircle(data.tx, data.ty, data.tz, radius, CIRCLE_DIVS)
		end
	end

	glLineWidth(1)
	glColor(1, 1, 1, 1)
	glDepthTest(true)
end

function widget:DrawScreen()
	if spIsGUIHidden() or #impacts == 0 or not font then
		return
	end

	local nowGF = spGetGameFrame()
	font:Begin()
	for i = 1, #impacts do
		local data = impacts[i]
		local remaining = JUNO_EFFECT_TTL_FRAMES - (nowGF - data.impactGF)
		if remaining > 0 then
			local radius = data.aoe * AOE_DRAW_SCALE
			if spIsSphereInView(data.tx, data.ty, data.tz, radius) then
				local sx, sy = spWorldToScreenCoords(data.tx, data.ty, data.tz)
				if sx and sy then
					local alpha = ImpactAlpha(nowGF - data.impactGF, 1)
					local secs = math_ceil(remaining / 30)
					font:SetTextColor(data.color[1], data.color[2], data.color[3], alpha)
					font:SetOutlineColor(0, 0, 0, alpha * 0.85)
					font:Print(secs .. "s", sx, sy, TIMER_FONT_SIZE, "oc")
				end
			end
		end
	end
	font:End()
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------
function widget:ViewResize()
	if WG and WG["fonts"] then
		font = WG["fonts"].getFont(nil, 1.2, 0.2, 18)
	end
end

function widget:Initialize()
	myAllyTeamID = spGetMyAllyTeamID()
	BuildWeaponCache()
	widget:ViewResize()
end

function widget:PlayerChanged()
	myAllyTeamID = spGetMyAllyTeamID()
	inFlight = {}
	impacts = {}
end

function widget:Update(dt)
	updateAccum = updateAccum + dt
	if updateAccum >= UPDATE_INTERVAL then
		updateAccum = 0
		UpdateTrackedProjectiles()
	end
end
