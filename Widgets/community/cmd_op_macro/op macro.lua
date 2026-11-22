function widget:GetInfo()
	return {
		name    = "op macro",
		desc    = "automate many macro tasks. best used with a long queue full of windmills, with construction turrets, energy storages, solars and converters at the end."
		author  = "Kuchy",
		date    = "2026-11-03",
		license = "GNU GPL, v2 or later",
		layer   = 0,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------
local ENERGY_THRESHOLD    = 0.50   -- low energy: turrets assist windmills when energy is below this fraction
local CHECK_INTERVAL      = 15     -- in game frames (30 frames = 1 second)
local EXCESS_FILL         = 0.70   -- energy counts as excessing when storage is above this fraction and average income exceeds average spending
local AVERAGE_SECONDS     = 3      -- window used to average energy income and spending
local FAST_SECONDS        = 0.5    -- shorter window used right after a construction turret has been built
local FAST_DURATION       = 5      -- how long (in seconds) the shorter window stays active after a turret is built
local METAL_THRESHOLD     = 100    -- stored metal above this sends constructors to the nearest nano turret
local SOLAR_METAL_MIN     = 75     -- low energy: turrets only assist basic solars while stored metal is above this
local SOLAR_JUMP_METAL    = 100    -- low energy + low wind: constructors jump to a queued basic solar while stored metal is above this
local WIND_THRESHOLD      = 8      -- ...and the current wind speed is below this
local CONVERTER_ENERGY_FILL = 0.95 -- once you own a basic converter, constructors only jump to further ones while energy is above this fraction
local RECLAIM_METAL_MAX   = 75     -- solar reclaim: stored metal must be below this...
local RECLAIM_ENERGY_FILL = 0.80   -- ...energy must be above this fraction (and you need a finished basic converter and energy storage)
local AVG_WIND_THRESHOLD  = 12     -- maps whose average wind, (2/3) * (max^3 - min^3) / (max^2 - min^2), is below this put advanced solars ahead of energy storage; otherwise energy storage goes first
local SUPPORT_ENERGY_FILL = 0.70   -- support rule: energy must be above this fraction...
local SUPPORT_METAL_FILL  = 0.05   -- ...and metal below this fraction
local PRESERVE_QUEUE      = true   -- true: the target build is moved to the front and skipped orders stay queued behind it; false: skipped orders are deleted
local DEBUG               = false  -- set to true to print chat messages about what the widget does

--------------------------------------------------------------------------------
-- Locals
--------------------------------------------------------------------------------
local spGetMyTeamID         = Spring.GetMyTeamID
local spGetTeamResources    = Spring.GetTeamResources
local spGetTeamUnitsByDefs  = Spring.GetTeamUnitsByDefs
local spGetUnitsInCylinder  = Spring.GetUnitsInCylinder
local spGetUnitDefID        = Spring.GetUnitDefID
local spGetUnitPosition     = Spring.GetUnitPosition
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitIsBuilding   = Spring.GetUnitIsBuilding
local spGetUnitCurrentCmd   = Spring.GetUnitCurrentCommand
local spGetUnitCommandCount = Spring.GetUnitCommandCount
local spGiveOrderToUnit     = Spring.GiveOrderToUnit
local spGetSpectatingState  = Spring.GetSpectatingState
local spValidUnitID         = Spring.ValidUnitID
local spFindUnitCmdDesc     = Spring.FindUnitCmdDesc
local spGetUnitCmdDescs     = Spring.GetUnitCmdDescs

local CMD_REPAIR   = CMD.REPAIR
local CMD_REMOVE   = CMD.REMOVE
local CMD_INSERT   = CMD.INSERT
local CMD_RECLAIM  = CMD.RECLAIM
local CMD_PRIORITY = 34567   -- BAR's builder priority command: 0 = low, 1 = high

local myTeamID
local lowWindMap = false  -- set on load from the map's average wind

-- Unit names (Armada, Cortex, Legion). Names that do not exist in your version are ignored.
local turretNames    = { "armnanotc", "cornanotc", "legnanotc" }
local windmillNames  = { "armwin", "corwin", "legwin", "armwint2", "corwint2", "legwint2" }
local storageNames   = { "armestor", "corestor", "legestor", "armuwadves", "coruwadves", "legadvestore" }
local converterNames = { "armmakr", "cormakr", "legeconv" }          -- basic (T1) energy converters
local advSolarNames  = { "armadvsol", "coradvsol", "legadvsol" }     -- advanced solar collectors
local solarNames     = { "armsolar", "corsolar", "legsolar" }        -- basic solar collectors (assisted on low energy, like windmills)
local mexNames       = { "armmex", "cormex", "legmex", "armuwmex", "coruwmex", "leguwmex" } -- T1 metal extractors

local turretDefs      = {}  -- list of nano turret unitDefIDs
local turretRange     = {}  -- unitDefID -> build distance
local turretSet       = {}  -- set of nano turret unitDefIDs
local windmillDefs    = {}  -- set of windmill unitDefIDs
local solarSet        = {}  -- set of basic solar unitDefIDs
local solarDefList    = {}  -- list form of solarSet
local windmillSolarSet = {} -- windmills and basic solars together
local storageSet      = {}  -- set of energy storage unitDefIDs
local storageDefList  = {}  -- list form of storageSet, for counting owned storages
local converterSet    = {}  -- set of basic converter unitDefIDs
local converterDefList = {} -- list form of converterSet, for counting owned converters
local advSolarSet     = {}  -- set of advanced solar unitDefIDs
local mexSet          = {}  -- set of T1 metal extractor unitDefIDs
local constructorDefs = {}  -- list of mobile builder unitDefIDs

local raised = {}  -- unitID -> true for units this widget switched to high priority

-- Solar reclaim state: the solar being reclaimed and the turrets assigned to it
local reclaimTarget
local reclaimStartFrame = 0
local reclaimTurrets = {}  -- turretID -> true

local function setToNames(set)
	local names = {}
	for id in pairs(set) do
		names[#names + 1] = UnitDefs[id].name
	end
	return table.concat(names, ", ")
end

local function addNames(names, set, list)
	for _, name in ipairs(names) do
		local def = UnitDefNames[name]
		if def then
			set[def.id] = true
			if list then
				list[#list + 1] = def.id
			end
		end
	end
end

local function buildDefTables()
	for _, name in ipairs(turretNames) do
		local def = UnitDefNames[name]
		if def then
			turretDefs[#turretDefs + 1] = def.id
			turretSet[def.id] = true
			turretRange[def.id] = def.buildDistance or 400
		end
	end
	addNames(windmillNames, windmillDefs)
	addNames(solarNames, solarSet, solarDefList)
	for id in pairs(windmillDefs) do
		windmillSolarSet[id] = true
	end
	for id in pairs(solarSet) do
		windmillSolarSet[id] = true
	end
	addNames(storageNames, storageSet, storageDefList)
	addNames(converterNames, converterSet)
	addNames(advSolarNames, advSolarSet)
	addNames(mexNames, mexSet)

	-- Also detect from game data, in case a unit name differs between factions or versions
	for id, def in pairs(UnitDefs) do
		local cp = def.customParams
		if cp then
			if cp.energyconv_capacity then
				local level = tonumber(cp.techlevel)
				local capacity = tonumber(cp.energyconv_capacity) or math.huge
				if (level and level <= 1) or (not level and capacity <= 100) then
					converterSet[id] = true
				end
			end
			if (def.extractsMetal or 0) > 0 and tonumber(cp.techlevel) == 1 then
				mexSet[id] = true
			end
		end
		if def.isBuilder and def.canMove and not def.isFactory then
			constructorDefs[#constructorDefs + 1] = id
		end
	end

	for id in pairs(converterSet) do
		converterDefList[#converterDefList + 1] = id
	end

	if DEBUG then
		Spring.Echo("Nano Windmill Assist: basic converters detected: " .. setToNames(converterSet))
		Spring.Echo("Nano Windmill Assist: T1 metal extractors detected: " .. setToNames(mexSet))
		Spring.Echo("Nano Windmill Assist: advanced solars detected: " .. setToNames(advSolarSet))
	end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function resourceFraction(resource)
	local current, storage = spGetTeamResources(myTeamID, resource)
	if not current or not storage or storage <= 0 then
		return nil
	end
	return current / storage
end

local reportedNoPriority = {}

-- Finds the priority command on a unit (by id or by action name) and returns its id and current state
local function findPriorityCmd(unitID)
	local descs = spGetUnitCmdDescs(unitID)
	if not descs then
		return nil
	end
	for idx = 1, #descs do
		local d = descs[idx]
		if d.id == CMD_PRIORITY or d.action == "priority" then
			return d.id, tonumber(d.params and d.params[1])
		end
	end
	return nil
end

-- Only sends the priority command to units that have it, and only when the state actually changes
local function setPriority(unitID, high)
	local cmdID, current = findPriorityCmd(unitID)
	if not cmdID then
		if DEBUG then
			local defID = spGetUnitDefID(unitID)
			if defID and not reportedNoPriority[defID] then
				reportedNoPriority[defID] = true
				Spring.Echo("Nano Windmill Assist: " .. UnitDefs[defID].name .. " has no priority command")
			end
		end
		return
	end
	local wanted = high and 1 or 0
	if DEBUG then
		Spring.Echo(string.format("Nano Windmill Assist: unit %d priority command %d, current state %s, wanted %d",
			unitID, cmdID, tostring(current), wanted))
	end
	if current ~= wanted then
		spGiveOrderToUnit(unitID, cmdID, { wanted }, 0)
	end
end

-- Closest unfinished building of a type in defSet within the turret's build range
local function findBuildTarget(turretID, tx, tz, range, defSet)
	local best, bestDistSq
	local nearby = spGetUnitsInCylinder(tx, tz, range, myTeamID)
	for i = 1, #nearby do
		local uID = nearby[i]
		if uID ~= turretID and defSet[spGetUnitDefID(uID)] then
			local beingBuilt, progress = spGetUnitIsBeingBuilt(uID)
			if beingBuilt and progress < 1 then
				local ux, _, uz = spGetUnitPosition(uID)
				if ux then
					local dx, dz = ux - tx, uz - tz
					local d = dx * dx + dz * dz
					if not bestDistSq or d < bestDistSq then
						best, bestDistSq = uID, d
					end
				end
			end
		end
	end
	return best
end

local function alreadyAssisting(turretID, targetID)
	local cmdID, _, _, param1 = spGetUnitCurrentCmd(turretID, 1)
	return cmdID == CMD_REPAIR and param1 == targetID
end

-- Replaces the turret's current order so the target gets priority
local function assistTarget(turretID, targetID)
	if not alreadyAssisting(turretID, targetID) then
		spGiveOrderToUnit(turretID, CMD_REPAIR, { targetID }, 0)
	end
end

local function isBuildingMex(unitID)
	local buildee = spGetUnitIsBuilding(unitID)
	if not buildee or not mexSet[spGetUnitDefID(buildee)] then
		return false
	end
	local beingBuilt = spGetUnitIsBeingBuilt(buildee)
	return beingBuilt and true or false
end

--------------------------------------------------------------------------------
-- Construction turrets
--   1. T1 metal extractor being built in range -> high priority, assist it, back to low priority afterwards
--   2. Energy below ENERGY_THRESHOLD           -> assist windmills (and basic solars while metal is above SOLAR_METAL_MIN)
--   3. Energy above SUPPORT_ENERGY_FILL and metal below SUPPORT_METAL_FILL
--                                              -> assist nano turrets, then energy storage, then advanced solar
--   Otherwise default behavior.
--------------------------------------------------------------------------------
local function manageTurrets()
	local fEnergy = resourceFraction("energy")
	local fMetal  = resourceFraction("metal")
	local metalStored = spGetTeamResources(myTeamID, "metal") or 0
	-- Windmills are always assisted on low energy; basic solars only while enough metal is stored
	local lowEnergySet = (metalStored > SOLAR_METAL_MIN) and windmillSolarSet or windmillDefs
	local lowEnergy   = fEnergy ~= nil and fEnergy < ENERGY_THRESHOLD
	local supportMode = fEnergy ~= nil and fMetal ~= nil
		and fEnergy > SUPPORT_ENERGY_FILL and fMetal < SUPPORT_METAL_FILL

	local turrets = spGetTeamUnitsByDefs(myTeamID, turretDefs)
	for i = 1, #turrets do
		local tID = turrets[i]
		local tx, _, tz = spGetUnitPosition(tID)
		if tx then
			local range = turretRange[spGetUnitDefID(tID)]

			local mex = findBuildTarget(tID, tx, tz, range, mexSet)
			if mex then
				reclaimTurrets[tID] = nil  -- metal extractors take priority over reclaiming a solar
				if not raised[tID] then
					setPriority(tID, true)
					raised[tID] = true
					if DEBUG then
						Spring.Echo("Nano Windmill Assist: turret " .. tID .. " set to high priority for a metal extractor")
					end
				end
				assistTarget(tID, mex)
			else
				if raised[tID] then
					setPriority(tID, false)
					raised[tID] = nil
				end

				local target
				if reclaimTurrets[tID] then
					-- busy reclaiming a solar: leave the turret alone
				elseif lowEnergy then
					target = findBuildTarget(tID, tx, tz, range, lowEnergySet)
				elseif supportMode then
					target = findBuildTarget(tID, tx, tz, range, turretSet)
						or findBuildTarget(tID, tx, tz, range, storageSet)
						or findBuildTarget(tID, tx, tz, range, advSolarSet)
				end
				if target then
					assistTarget(tID, target)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Constructors: high priority while building a T1 metal extractor or while one is anywhere in
-- their build queue, low priority otherwise
--------------------------------------------------------------------------------
local function queueHasMex(unitID)
	local count = spGetUnitCommandCount(unitID)
	if not count then
		return false
	end
	for i = 1, math.min(count, 100) do
		local cmdID = spGetUnitCurrentCmd(unitID, i)
		if not cmdID then
			return false
		end
		if cmdID < 0 and mexSet[-cmdID] then
			return true
		end
	end
	return false
end

local function manageBuilderPriorities()
	local builders = spGetTeamUnitsByDefs(myTeamID, constructorDefs)
	for i = 1, #builders do
		local bID = builders[i]
		if isBuildingMex(bID) or queueHasMex(bID) then
			if not raised[bID] then
				setPriority(bID, true)
				raised[bID] = true
				if DEBUG then
					Spring.Echo("Nano Windmill Assist: constructor " .. bID .. " set to high priority for a metal extractor")
				end
			end
		elseif raised[bID] then
			setPriority(bID, false)
			raised[bID] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Excess energy: constructors skip their queue
--------------------------------------------------------------------------------
local historyIncome  = {}
local historyExpense = {}
local HISTORY_SIZE   = math.ceil(AVERAGE_SECONDS * 30 / CHECK_INTERVAL)
local FAST_SIZE      = math.min(HISTORY_SIZE, math.max(1, math.ceil(FAST_SECONDS * 30 / CHECK_INTERVAL)))
local fastUntilFrame = 0  -- game frame until which the short window is used

-- Samples energy income/spending on every check, then compares their averages over the last
-- AVERAGE_SECONDS (or the last FAST_SECONDS for FAST_DURATION seconds after a nano turret finishes).
-- Needs a full window of samples first (about AVERAGE_SECONDS after loading).
local function energyIsExcessing(frame)
	local current, storage, _, income, expense = spGetTeamResources(myTeamID, "energy")
	if not current or not storage or storage <= 0 then
		return false
	end

	historyIncome[#historyIncome + 1] = income
	historyExpense[#historyExpense + 1] = expense
	if #historyIncome > HISTORY_SIZE then
		table.remove(historyIncome, 1)
		table.remove(historyExpense, 1)
	end
	if #historyIncome < HISTORY_SIZE then
		return false
	end

	-- Right after a nano turret finishes, only the latest samples count so the next jump happens quickly
	local window = (frame < fastUntilFrame) and FAST_SIZE or HISTORY_SIZE
	local sumIncome, sumExpense = 0, 0
	for i = #historyIncome - window + 1, #historyIncome do
		sumIncome = sumIncome + historyIncome[i]
		sumExpense = sumExpense + historyExpense[i]
	end
	return (current / storage) > EXCESS_FILL and sumIncome > sumExpense
end

-- Chooses what constructors should jump to, in order of preference:
--   metal above threshold             -> nano turret first
--   no energy storage owned yet       -> energy storage and advanced solar (advanced solar first on
--                                        low-wind maps, energy storage first otherwise)
--   otherwise                         -> basic energy converter (the first one right away, further ones
--                                        only while energy is above CONVERTER_ENERGY_FILL)
-- Storages under construction count as owned, so a constructor that just started one is not pulled away.
local function pickTargetSets()
	local sets = {}
	local metal = spGetTeamResources(myTeamID, "metal")
	if metal and metal > METAL_THRESHOLD then
		sets[#sets + 1] = turretSet
	end
	if #spGetTeamUnitsByDefs(myTeamID, storageDefList) == 0 then
		if lowWindMap then
			sets[#sets + 1] = advSolarSet
			sets[#sets + 1] = storageSet
		else
			sets[#sets + 1] = storageSet
			sets[#sets + 1] = advSolarSet
		end
	else
		-- The first converter follows the normal excess rule; further ones need energy above CONVERTER_ENERGY_FILL.
		-- Converters under construction count as owned.
		local fEnergy = resourceFraction("energy")
		if #spGetTeamUnitsByDefs(myTeamID, converterDefList) == 0
			or (fEnergy and fEnergy > CONVERTER_ENERGY_FILL) then
			sets[#sets + 1] = converterSet
		end
	end
	return sets
end

local function isPriorityBuild(cmdID)
	if not cmdID or cmdID >= 0 then
		return false
	end
	local defID = -cmdID
	return (turretSet[defID] or storageSet[defID] or advSolarSet[defID] or converterSet[defID] or mexSet[defID]) and true or false
end

-- Brings the first build order matching the most preferred set in targetSets to the front of the
-- queue. Sets are tried in order, so a later set is only used when the queue holds nothing from the
-- earlier ones. Leaves the queue untouched if nothing matches, or the constructor is already working
-- on a nano turret, energy storage, basic converter or metal extractor.
-- A metal extractor in the queue always keeps its place: the target is never moved ahead of one,
-- it stops directly behind the last metal extractor that precedes it.
local function skipQueueToTarget(unitID, targetSets)
	if isBuildingMex(unitID) then
		return  -- currently building a metal extractor
	end
	local count = spGetUnitCommandCount(unitID)
	if not count or count < 2 then
		return
	end
	if isPriorityBuild((spGetUnitCurrentCmd(unitID, 1))) then
		return
	end

	-- Read the queue once
	local queue = {}
	for i = 1, count do
		local cmdID, opts, tag, x, y, z, facing = spGetUnitCurrentCmd(unitID, i)
		if not cmdID then
			break
		end
		queue[i] = { cmdID = cmdID, opts = opts, tag = tag, x = x, y = y, z = z, facing = facing }
	end

	for _, targetSet in ipairs(targetSets) do
		local lastMex = 0  -- queue index of the last metal extractor order seen so far
		for i = 1, #queue do
			local cmd = queue[i]
			if cmd.cmdID < 0 then
				local defID = -cmd.cmdID
				if mexSet[defID] then
					lastMex = i
				elseif targetSet[defID] then
					if i == lastMex + 1 then
						return  -- already as far forward as allowed
					end
					if PRESERVE_QUEUE then
						-- Move the target forward (behind any metal extractor); the orders it jumps over stay queued behind it.
						-- The original is removed first so the engine does not see a duplicate order.
						if DEBUG then
							Spring.Echo(string.format("Nano Windmill Assist: unit %d moved a build ahead of %d queued orders", unitID, i - 1 - lastMex))
						end
						spGiveOrderToUnit(unitID, CMD_REMOVE, { cmd.tag }, 0)
						spGiveOrderToUnit(unitID, CMD_INSERT,
							{ lastMex, cmd.cmdID, cmd.opts, cmd.x, cmd.y, cmd.z, cmd.facing or 0 }, CMD.OPT_ALT)
					else
						if DEBUG then
							Spring.Echo(string.format("Nano Windmill Assist: unit %d skipped %d queued orders", unitID, i - 1 - lastMex))
						end
						for t = lastMex + 1, i - 1 do
							spGiveOrderToUnit(unitID, CMD_REMOVE, { queue[t].tag }, 0)
						end
					end
					return
				end
			end
		end
	end
end

-- Low energy, enough metal and little wind: windmills will not carry the economy, so constructors
-- jump to a basic solar in their queue
local solarTargetSets = { solarSet }

local function needsSolar()
	local fEnergy = resourceFraction("energy")
	if not fEnergy or fEnergy >= ENERGY_THRESHOLD then
		return false
	end
	local metal = spGetTeamResources(myTeamID, "metal")
	if not metal or metal <= SOLAR_JUMP_METAL then
		return false
	end
	local wind = select(4, Spring.GetWind())
	return wind ~= nil and wind < WIND_THRESHOLD
end

--------------------------------------------------------------------------------
-- Solar reclaim: with little metal but a healthy energy economy, all construction turrets in range
-- reclaim one basic solar (the one with the most turrets in range), one solar at a time
--------------------------------------------------------------------------------
local function hasFinished(defList)
	local units = spGetTeamUnitsByDefs(myTeamID, defList)
	for i = 1, #units do
		if not spGetUnitIsBeingBuilt(units[i]) then
			return true
		end
	end
	return false
end

-- Is this unit currently reclaiming one of my basic solars?
local function reclaimingSolar(unitID)
	local cmdID, _, _, target = spGetUnitCurrentCmd(unitID, 1)
	if cmdID ~= CMD_RECLAIM or not target then
		return false
	end
	local defID = spGetUnitDefID(target)
	return defID ~= nil and solarSet[defID] == true
end

-- Any turret or constructor reclaiming a basic solar counts, including ones ordered by hand
local function solarBeingReclaimed()
	for _, defList in ipairs({ turretDefs, constructorDefs }) do
		local units = spGetTeamUnitsByDefs(myTeamID, defList)
		for i = 1, #units do
			if reclaimingSolar(units[i]) then
				return true
			end
		end
	end
	return false
end

-- Ends the tracked reclaim once the solar is gone or none of the assigned turrets are still on it
local function updateReclaimState(frame)
	if not reclaimTarget then
		return
	end
	local active = spValidUnitID(reclaimTarget)
	if active and frame - reclaimStartFrame > 60 then  -- give the orders time to arrive first
		active = false
		for tID in pairs(reclaimTurrets) do
			local cmdID, _, _, target = spGetUnitCurrentCmd(tID, 1)
			if cmdID == CMD_RECLAIM and target == reclaimTarget then
				active = true
				break
			end
		end
	end
	if not active then
		reclaimTarget = nil
		reclaimTurrets = {}
	end
end

local function tryStartSolarReclaim(frame)
	if reclaimTarget or #solarDefList == 0 then
		return
	end
	local metal = spGetTeamResources(myTeamID, "metal")
	local fEnergy = resourceFraction("energy")
	if not metal or metal >= RECLAIM_METAL_MAX or not fEnergy or fEnergy <= RECLAIM_ENERGY_FILL then
		return
	end
	if not hasFinished(converterDefList) or not hasFinished(storageDefList) then
		return
	end
	if solarBeingReclaimed() then
		return
	end

	local turrets = {}
	local list = spGetTeamUnitsByDefs(myTeamID, turretDefs)
	for i = 1, #list do
		local tID = list[i]
		local x, _, z = spGetUnitPosition(tID)
		if x and not spGetUnitIsBeingBuilt(tID) then
			turrets[#turrets + 1] = { id = tID, x = x, z = z, r = turretRange[spGetUnitDefID(tID)] }
		end
	end
	if #turrets == 0 then
		return
	end

	-- Pick the finished basic solar with the most turrets in range
	local bestSolar, bestTurrets
	local solars = spGetTeamUnitsByDefs(myTeamID, solarDefList)
	for i = 1, #solars do
		local sID = solars[i]
		if not spGetUnitIsBeingBuilt(sID) then
			local sx, _, sz = spGetUnitPosition(sID)
			if sx then
				local inRange = {}
				for j = 1, #turrets do
					local t = turrets[j]
					local dx, dz = t.x - sx, t.z - sz
					if dx * dx + dz * dz <= t.r * t.r then
						inRange[#inRange + 1] = t.id
					end
				end
				if #inRange > 0 and (not bestTurrets or #inRange > #bestTurrets) then
					bestSolar, bestTurrets = sID, inRange
				end
			end
		end
	end
	if not bestSolar then
		return
	end

	for i = 1, #bestTurrets do
		spGiveOrderToUnit(bestTurrets[i], CMD_RECLAIM, { bestSolar }, 0)
		reclaimTurrets[bestTurrets[i]] = true
	end
	reclaimTarget = bestSolar
	reclaimStartFrame = frame
	if DEBUG then
		Spring.Echo(string.format("Nano Windmill Assist: %d turrets reclaiming basic solar %d", #bestTurrets, bestSolar))
	end
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
function widget:GameFrame(n)
	if n % CHECK_INTERVAL ~= 0 then
		return
	end

	updateReclaimState(n)
	tryStartSolarReclaim(n)
	manageTurrets()
	manageBuilderPriorities()

	-- energyIsExcessing must run on every check, since it records the income/spending samples
	local targetSets
	if energyIsExcessing(n) then
		targetSets = pickTargetSets()
	elseif needsSolar() then
		targetSets = solarTargetSets
	end
	if targetSets and #targetSets > 0 then
		local builders = spGetTeamUnitsByDefs(myTeamID, constructorDefs)
		for i = 1, #builders do
			skipQueueToTarget(builders[i], targetSets)
		end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
local function checkSpectator()
	if spGetSpectatingState() then
		widgetHandler:RemoveWidget()
		return true
	end
	return false
end

function widget:Initialize()
	if checkSpectator() then return end
	myTeamID = spGetMyTeamID()
	buildDefTables()
	local wMin, wMax = Game.windMin or 0, Game.windMax or 0
	local avgWind
	if wMax > wMin then
		avgWind = (2 / 3) * (wMax ^ 3 - wMin ^ 3) / (wMax ^ 2 - wMin ^ 2)
	else
		avgWind = wMax  -- constant wind
	end
	lowWindMap = avgWind < AVG_WIND_THRESHOLD
	if DEBUG then
		Spring.Echo(string.format("Nano Windmill Assist: map average wind %.1f, %s", avgWind,
			lowWindMap and "advanced solars go before energy storage" or "energy storage goes before advanced solars"))
	end
	if #turretDefs == 0 or next(windmillDefs) == nil then
		Spring.Echo("Nano Windmill Assist: required unit definitions not found, removing widget")
		widgetHandler:RemoveWidget()
	end
end

function widget:PlayerChanged()
	if checkSpectator() then return end
	myTeamID = spGetMyTeamID()
end

function widget:UnitDestroyed(unitID)
	raised[unitID] = nil
	reclaimTurrets[unitID] = nil
end

-- A construction turret just finished: switch to the short averaging window for a while
function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if unitTeam == myTeamID and turretSet[unitDefID] then
		fastUntilFrame = Spring.GetGameFrame() + FAST_DURATION * 30
		if DEBUG then
			Spring.Echo("Nano Windmill Assist: construction turret finished, using the short energy window for " .. FAST_DURATION .. "s")
		end
	end
end

-- Put anything this widget raised back to low priority when it is unloaded
function widget:Shutdown()
	for unitID in pairs(raised) do
		if spValidUnitID(unitID) then
			setPriority(unitID, false)
		end
	end
end
