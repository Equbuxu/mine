local helper = {}
--#region CONFIG----
local cfg = {}
cfg.localConfig = {
	--if true, the program will attempt to download and use the config from remoteConfigPath
	--useful if you have many turtles and you don't want to change the config of each one manually
	useRemoteConfig = false,
	remoteConfigPath = "http://localhost:33344/config.lua",
	--this command will be used when the program is started as "mine def" (mineLoop overrides this command)
	defaultCommand = "cube 3 3 8",
	--false: build walls/floor/ceiling everywhere, true: only where there is fluid
	plugFluidsOnly = true,
	--maximum taxicab distance from enterance point when collecting ores, 0 = disable ore traversal
	oreTraversalRadius = 0,
	--layer mining order, use "z" for branch mining, "y" for anything else
	--"y" - mine top to bottom layer by layer, "z" - mine forward in vertical slices
	layerSeparationAxis="y",
	--false: use regular chests, true: use entangled chests
	--if true, the turtle will place a single entangled chest to drop off items and break it afterwards.
	--tested with chests from https://www.curseforge.com/minecraft/mc-mods/kibe
	useEntangledChests = false,
	--false: refuel from inventory, true: refuel from (a different) entangled chest
	--if true, the turtle won't store any coal. Instead, when refueling, it will place the entangled chest, grab fuel from it, refuel, and then break the chest.
	useFuelEntangledChest = false,
	--true: use two chuck loaders to mine indefinitely without moving into unloaded chunks. 
	--This doesn't work with chunk loaders from https://www.curseforge.com/minecraft/mc-mods/kibe, but might work with some other mod.
	--After an area is mined, the turtle will shift by mineLoopOffset and execute mineLoopCommand
	--mineLoopCommand is used in place of defaultCommand when launching as "mine def"
	mineLoop = false,
	mineLoopOffset = {x=0, y=0, z=8},
	mineLoopCommand = "rcube 1 1 1"
}

cfg.getRemoteConfig = function(remotePath)
	local handle = http.get(remotePath)
	if not handle then
		helper.printError("Server not responding, using local")
		return nil
	end
	local data = handle.readAll()
	handle.close()
	local deser = textutils.unserialise(data)
	if not deser then
		helper.printError("Couldn't parse remote config, using local")
		return nil
	end
	for key,_ in pairs(cfg.localConfig) do
		if deser[key] == nil then
			helper.printError("No key", key, "in remote config, using local")
			return nil
		end
	end
	return deser
end

cfg.processConfig = function()
	local config = cfg.localConfig
	if cfg.localConfig.useRemoteConfig then
		helper.print("Downloading config..")
		local remoteConfig = cfg.getRemoteConfig(config.remoteConfigPath)
		config = remoteConfig or cfg.localConfig
	end
	return config
end

--#endregion
--#region CONSTANTS----

local SOUTH = 0
local WEST = 1
local NORTH = 2
local EAST = 3

local CHEST_SLOT = "chest_slot"
local BLOCK_SLOT = "block_slot"
local FUEL_SLOT = "fuel_slot"
local FUEL_CHEST_SLOT = "fuel_chest_slot"
local CHUNK_LOADER_SLOT = "chunk_loader_slot"
local MISC_SLOT = "misc_slot"

local ACTION = 0
local TASK = 1

local PATHFIND_INSIDE_AREA = 0
local PATHFIND_OUTSIDE_AREA = 1
local PATHFIND_INSIDE_NONPRESERVED_AREA = 2
local PATHFIND_ANYWHERE_NONPRESERVED = 3

local SUCCESS = 0
local FAILED_NONONE_COMPONENTCOUNT = 1
local FAILED_TURTLE_NOTINREGION = 2
local FAILED_REGION_EMPTY = 4

local REFUEL_THRESHOLD = 500
local RETRY_DELAY = 3

local FALLING_BLOCKS = {
	["minecraft:gravel"] = true,
	["minecraft:sand"] = true
}

--#endregion
--#region WRAPPER----

local wrapt = (function()
	local self = {
		selectedSlot = 1,
		direction = SOUTH,
		x = 0,
		y = 0,
		z = 0
	}

	local public = {}

	--wrap everything in turtle
	for key,value in pairs(turtle) do
		public[key] = value
	end
	--init turtle selected slot
	turtle.select(self.selectedSlot);

	public.select = function(slot)
		if self.selectedSlot ~= slot then
			turtle.select(slot)
			self.selectedSlot = slot
		end
	end

	public.forward = function()
		local success = turtle.forward()
		if not success then
			return success
		end
		if self.direction == EAST then
			self.x = self.x + 1
		elseif self.direction == WEST then
			self.x = self.x - 1
		elseif self.direction == SOUTH then
			self.z = self.z + 1
		elseif self.direction == NORTH then
			self.z = self.z - 1
		end
		return success
	end

	public.up = function()
		local success = turtle.up()
		if not success then
			return success
		end
		self.y = self.y + 1
		return success
	end

	public.down = function()
		local success = turtle.down()
		if not success then
			return success
		end
		self.y = self.y - 1
		return success
	end

	public.turnRight = function()
		local success = turtle.turnRight()
		if not success then
			return success
		end
		self.direction = self.direction + 1
		if self.direction > 3 then
			self.direction = 0
		end
		return success
	end

	public.turnLeft = function()
		local success = turtle.turnLeft()
		if not success then
			return success
		end
		self.direction = self.direction - 1
		if self.direction < 0 then
			self.direction = 3
		end
		return success
	end

	public.getX = function() return self.x end
	public.getY = function() return self.y end
	public.getZ = function() return self.z end
	public.getDirection = function() return self.direction end
	public.getPosition = function() return {x = self.x, y = self.y, z = self.z, direction = self.direction} end

	return public
end)()

--#endregion
--#region DEBUG FUNCTIONS----

local debug = {
	dumpPoints = function(points, filename)
		local file = fs.open(filename .. ".txt","w")
		for key, value in pairs(points) do
			local line =
				tostring(value.x)..","..
				tostring(value.y)..","..
				tostring(value.z)..","
			if value.adjacent then
				line = line .. "0,128,0"
			elseif value.inacc then
				line = line .. "255,0,0"
			elseif value.triple then
				line = line .. "0,255,0"
			elseif value.checkedInFirstPass then
				line = line .. "0,0,0"
			else
				helper.printError("Invalid block type when dumping points")
			end

			if math.abs(value.z) < 100 then
				file.writeLine(line)
			end
		end
		file.close()
	end,

	dumpPath = function(points, filename)
		local file = fs.open(filename .. ".txt","w")
		for key, value in pairs(points) do
			if tonumber(key) then
				local line =
					tostring(value.x)..","..
					tostring(value.y)..","..
					tostring(value.z)
				file.writeLine(line)
			end
		end
		file.close()
	end,

	dumpLayers = function(layers, filename)
		for index, layer in ipairs(layers) do
			local file = fs.open(filename .. tostring(index) .. ".txt","w")
			for _, value in ipairs(layer) do
				local line =
					tostring(value.x)..","..
					tostring(value.y)..","..
					tostring(value.z)..","
				if value.adjacent then
					line = line .. "0,128,0"
				elseif value.inacc then
					line = line .. "255,0,0"
				elseif value.triple then
					line = line .. "0,255,0"
				elseif value.checkedInFirstPass then
					line = line .. "0,0,0"
				else
					helper.printError("Invalid block type when dumping layers")
				end
				file.writeLine(line)
			end
			file.close()
		end
	end
}

--#endregion
--#region HELPER FUNCTIONS----

helper.deltaToDirection = function(dX, dZ)
	if dX > 0 then
		return EAST
	elseif dX < 0 then
		return WEST
	elseif dZ > 0 then
		return SOUTH
	elseif dZ < 0 then
		return NORTH
	end
	error("Invalid delta", 2)
end

helper.tableLength = function(T)
	local count = 0
	for _ in pairs(T) do count = count + 1 end
	return count
end

helper.getIndex = function(x, y, z)
	return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

helper.isPosEqual = function(pos1, pos2)
	return pos1.x == pos2.x and pos1.y == pos2.y and pos1.z == pos2.z
end

helper.getSurroundings = function(pos)
	return {
		[helper.getIndex(pos.x + 1, pos.y, pos.z)] = {x = pos.x + 1, y = pos.y, z = pos.z},
		[helper.getIndex(pos.x - 1, pos.y, pos.z)] = {x = pos.x - 1, y = pos.y, z = pos.z},
		[helper.getIndex(pos.x, pos.y + 1, pos.z)] = {x = pos.x, y = pos.y + 1, z = pos.z},
		[helper.getIndex(pos.x, pos.y - 1, pos.z)] = {x = pos.x, y = pos.y - 1, z = pos.z},
		[helper.getIndex(pos.x, pos.y, pos.z + 1)] = {x = pos.x, y = pos.y, z = pos.z + 1},
		[helper.getIndex(pos.x, pos.y, pos.z - 1)] = {x = pos.x, y = pos.y, z = pos.z - 1}
	}
end

helper.getForwardPos = function(currentPos)
	local newPos = {x = currentPos.x, y = currentPos.y, z = currentPos.z}
	if currentPos.direction == EAST then
		newPos.x = newPos.x + 1
	elseif currentPos.direction == WEST then
		newPos.x = newPos.x - 1
	elseif currentPos.direction == SOUTH then
		newPos.z = newPos.z + 1
	elseif currentPos.direction == NORTH then
		newPos.z = newPos.z - 1
	end
	return newPos
end

helper.distance = function(from, to)
	return math.abs(from.x - to.x) + math.abs(from.y - to.y) + math.abs(from.z - to.z)
end

helper.sign = function(number)
    return number > 0 and 1 or (number == 0 and 0 or -1)
end

helper.inRange = function(number, a, b)
	return number >= a and number <= b
end

helper.splitString = function(string, separator)
	if not separator then separator = "%s" end
	local split = {}
	for str in string.gmatch(string, "([^"..separator.."]+)") do
		table.insert(split, str)
	end
	return split
end

helper.stringEndsWith = function (str, ending)
	return ending == "" or str:sub(-#ending) == ending
end

helper.tableContains = function(table, element, comparison)
	for _, value in pairs(table) do
		if comparison(value, element) then
			return true
		end
	end
	return false
end

helper.readOnlyTable = function(t)
	local mt = {
		__index = t,
		__newindex = function(t,k,v)
			error("Cannot write into a read-only table", 2)
		end
	}
	local proxy = {}
	setmetatable(proxy, mt)
	return proxy
end

helper.osYield = function()
---@diagnostic disable-next-line: undefined-field
	os.queueEvent("fakeEvent");
---@diagnostic disable-next-line: undefined-field
	os.pullEvent();
end

helper.printError = function(...)
	term.setTextColor(colors.red)
	print(...)
end

helper.printWarning = function(...)
	term.setTextColor(colors.yellow)
	print(...)
end

helper.print = function(...)
	term.setTextColor(colors.white)
	print(...)
end

helper.write = function(...)
	term.setTextColor(colors.white)
	term.write(...)
end

helper.read = function()
	term.setTextColor(colors.lightGray)
	local data = read()
	term.setTextColor(colors.white)
	return data
end

--#endregion
--#region SHAPE LIBRARY----

local shapes = {}

shapes.custom = {
	command = "custom",
	shortDesc = "custom <filename>",
	longDesc = "Executes a function named \"generate\" from the specified file and uses the data it returns as a shape",
	args = {"str"},
	generate = function(filename)
		local env = {
			table=table,
			fs=fs,
			http=http,
			io=io,
			math=math,
			os=os,
			parallel=parallel,
			string=string,
			vector=vector,
			textutils=textutils
		}
		local chunk, err = loadfile(filename, "bt", env)
		if err then
			helper.printError("Couldn't load file:", err);
			return {}
		end
		chunk();
		if type(env.generate) ~= "function" then
			helper.printError("File does not contain generate function")
			return {}
		end
		local generated = env.generate()
		if type(generated) ~= "table" then
			helper.printError("Generate function didn't return a table")
			return {}
		end
		local blocks = {}
		for _, value in ipairs(generated) do
			if type(value.x) ~= "number" or type(value.y) ~= "number" or type(value.z) ~= "number" then
				helper.printError("Invalid coordinates entry:", textutils.serialize(value))
				return {}
			end
			blocks[helper.getIndex(value.x, value.y, value.z)] = {x = value.x, y = value.y, z = value.z}
		end
		return blocks
	end
}

shapes.sphere = {
	command = "sphere",
	shortDesc = "sphere <diameter>",
	longDesc = "Mine a sphere of diameter <diameter>, starting from it's bottom center",
	args = {"2.."},
	generate = function(diameter)
		local radius = math.ceil(diameter / 2.0)
		local radiusSq = (diameter / 2.0) * (diameter / 2.0)
		local blocks = {}
		local first = nil
		for j=-radius,radius do
			for i=-radius,radius do
				for k=-radius,radius do
					if diameter % 2 == 0 then
						if math.pow(i+0.5, 2) + math.pow(j+0.5, 2) + math.pow(k+0.5, 2) < radiusSq then
							if not first then
								first = j
							end
							blocks[helper.getIndex(i,j-first,k)] = {x = i, y = j-first, z = k}
						end
					else
						if math.pow(i, 2) + math.pow(j, 2) + math.pow(k, 2) < radiusSq then
							if not first then
								first = j
							end
							blocks[helper.getIndex(i,j-first,k)] = {x = i, y = j-first, z = k}
						end
					end
				end
			end
			helper.osYield()
		end
		return blocks
	end
}

shapes.cuboid = {
	command="cube",
	shortDesc = "cube <left> <up> <forward>",
	longDesc = "Mine a cuboid of a specified size. Use negative values to dig in an opposite direction",
	args= {"..-2 2..", "..-2 2..", "..-2 2.."},
	generate = function(x, y, z)
		local blocks = {}
		local sX = helper.sign(x)
		local sY = helper.sign(y)
		local sZ = helper.sign(z)
		local tX = sX * (math.abs(x) - 1)
		local tY = sY * (math.abs(y) - 1)
		local tZ = sZ * (math.abs(z) - 1)
		for i=0,tX,sX do
			for j=0,tY,sY do
				for k=0,tZ,sZ do
					blocks[helper.getIndex(i,j,k)] = {x = i, y = j, z = k}
				end
			end
			helper.osYield()
		end
		return blocks
	end
}

shapes.centeredCuboid = {
	command="rcube",
	shortDesc = "rcube <leftR> <upR> <forwardR>",
	longDesc = "Mine a cuboid centered on the turtle. Each dimension is a \"radius\", so typing \"rcube 1 1 1\" will yield a 3x3x3 cube",
	args={"1..", "1..", "1.."},
	generate = function(rX, rY, rZ)
		local blocks = {}
		for i=-rX,rX do
			for j=-rY,rY do
				for k=-rZ,rZ do
					blocks[helper.getIndex(i,j,k)] = {x = i, y = j, z = k}
				end
			end
			helper.osYield()
		end
		return blocks
	end
}

shapes.branch = {
	command="branch",
	shortDesc = "branch <branchLen> <shaftLen>",
	longDesc = "Branch-mining. <branchLen> is the length of each branch, <shaftLen> is the length of the main shaft",
	args={"0..", "3.."},
	generate = function(xRadius, zDepth)
		local blocks = {}
		--generate corridor
		for x=-1,1 do
			for y=0,2 do
				for z=0,zDepth-1 do
					blocks[helper.getIndex(x,y,z)] = {x = x, y = y, z = z}
				end
			end
		end
		--generate branches
		for z=2,zDepth-1,2 do
			local y = (z % 4 == 2) and 0 or 2
			for x=0,xRadius-1 do
				blocks[helper.getIndex(x+2,y,z)] = {x = x+2, y = y, z = z}
				blocks[helper.getIndex(-x-2,y,z)] = {x = -x-2, y = y, z = z}
			end
		end
		return blocks
	end
}

--#endregion
--#region REGION PROCESSING----

local region = {}
region.createShape = function()
	local blocks = {}
	for i=-7,7 do
		for j=0,7 do
			for k=-7,7 do
				if i*i + j*j + k*k < 2.5*2.5 then
					blocks[helper.getIndex(i,j,k)] = {x = i, y = j, z = k}
				end
			end
		end
	end
	return blocks
end

region.cloneBlocks = function(allBlocks)
	local cloned = {}
	for key,value in pairs(allBlocks) do
		local blockClone = {
			x = value.x,
			y = value.y,
			z = value.z
		}
		cloned[key] = blockClone
	end
	return cloned
end

--mark blocks that are next to walls
region.markAdjacentInPlace = function(allBlocks)
	for key,value in pairs(allBlocks) do
		local xMinus = allBlocks[helper.getIndex(value.x - 1, value.y, value.z)]
		local xPlus = allBlocks[helper.getIndex(value.x + 1, value.y, value.z)]
		local yMinus = allBlocks[helper.getIndex(value.x, value.y - 1, value.z)]
		local yPlus = allBlocks[helper.getIndex(value.x, value.y + 1, value.z)]
		local zMinus = allBlocks[helper.getIndex(value.x, value.y, value.z - 1)]
		local zPlus = allBlocks[helper.getIndex(value.x, value.y, value.z + 1)]
		if not xMinus or not xPlus or not yMinus or not yPlus or not zMinus or not zPlus then
			value.adjacent = true
			if yMinus then yMinus.checkedInFirstPass = true end
			if yPlus then yPlus.checkedInFirstPass = true end
		end
	end
end

--mark positions where the turtle can check both the block above and the block below
region.markTripleInPlace = function(allBlocks)
	local minY = 9999999;
	for key,value in pairs(allBlocks) do
		if not value.checkedInFirstPass and not value.adjacent then
			minY = math.min(minY, value.y)
		end
	end
	for key,value in pairs(allBlocks) do
		if not value.checkedInFirstPass and not value.adjacent then
			local offset = (value.y - minY) % 3;
			if offset == 0 then
				local blockAbove = allBlocks[helper.getIndex(value.x, value.y+1, value.z)]
				if blockAbove ~= nil and blockAbove.checkedInFirstPass ~= true then
					value.checkedInFirstPass = true
				else
					value.inacc = true
				end
			elseif offset == 1 then
				value.triple = true
			elseif offset == 2 and allBlocks[helper.getIndex(value.x, value.y-1, value.z)] ~= nil then
				local blockBelow = allBlocks[helper.getIndex(value.x, value.y-1, value.z)]
				if blockBelow ~= nil and blockBelow.checkedInFirstPass ~= true then
					value.checkedInFirstPass = true
				else
					value.inacc = true
				end
			end
		end
	end
end

region.findConnectedComponents = function(allBlocks)
	local visited = {}
	local components = {}
	local counter = 0
	local lastTime = os.clock()
	for key,value in pairs(allBlocks) do
		if not visited[key] then
			local component = {}
			local toVisit = {[key] = value}
			while true do
				local newToVisit = {}
				local didSomething = false
				for currentKey,current in pairs(toVisit) do
					didSomething = true
					visited[currentKey] = true
					component[currentKey] = current
					local minusX = helper.getIndex(current.x-1, current.y, current.z)
					local plusX = helper.getIndex(current.x+1, current.y, current.z)
					local minusY = helper.getIndex(current.x, current.y-1, current.z)
					local plusY = helper.getIndex(current.x, current.y+1, current.z)
					local minusZ = helper.getIndex(current.x, current.y, current.z-1)
					local plusZ = helper.getIndex(current.x, current.y, current.z+1)
					if allBlocks[minusX] and not visited[minusX] then newToVisit[minusX] = allBlocks[minusX] end
					if allBlocks[plusX] and not visited[plusX] then newToVisit[plusX] = allBlocks[plusX] end
					if allBlocks[minusY] and not visited[minusY] then newToVisit[minusY] = allBlocks[minusY] end
					if allBlocks[plusY] and not visited[plusY] then newToVisit[plusY] = allBlocks[plusY] end
					if allBlocks[minusZ] and not visited[minusZ] then newToVisit[minusZ] = allBlocks[minusZ] end
					if allBlocks[plusZ] and not visited[plusZ] then newToVisit[plusZ] = allBlocks[plusZ] end

					counter = counter + 1
					if counter % 50 == 0 then
						local curTime = os.clock()
						if curTime - lastTime > 1 then
							lastTime = curTime
							helper.osYield()
						end
					end
				end
				toVisit = newToVisit
				if not didSomething then break end
			end
			table.insert(components, component)
		end
	end
	return components
end

region.separateLayers = function(allBlocks, direction)
	if direction ~= "y" and direction ~= "z" then
		error("Invalid direction value", 2)
	end
	local layers = {}
	local min = 999999
	local max = -999999
	for key,value in pairs(allBlocks) do
		if not (not value.adjacent and value.checkedInFirstPass) then
			local index = direction == "y" and value.y or value.z
			if not layers[index] then 
				layers[index] = {} 
			end
			layers[index][key] = value
			min = math.min(min, index)
			max = math.max(max, index)
		end
	end
	if min == 999999 then
		error("There should be at least one block in passed table", 2)
	end
	
	local reassLayers = {}
	for key, value in pairs(layers) do
		local index = direction == "y" and (max - min+1) - (key - min) or (key - min + 1)
		reassLayers[index] = value
	end
	return reassLayers
end

region.sortFunction = function(a, b) 
	return (a.y ~= b.y and a.y < b.y or (a.x ~= b.x and a.x > b.x or a.z > b.z))
end

region.findClosestPoint = function(location, points, usedPoints)
	local surroundings = helper.getSurroundings(location)
	local existingSurroundings = {}
	local foundClose = false
	for key,value in pairs(surroundings) do
		if points[key] and not usedPoints[key] then
			table.insert(existingSurroundings, value)
			foundClose = true
		end
	end
	if foundClose then
		table.sort(existingSurroundings, region.sortFunction)
		local closest = table.remove(existingSurroundings)
		return points[helper.getIndex(closest.x, closest.y, closest.z)]
	end

	local minDist = 999999
	local minValue = nil
	for key,value in pairs(points) do
		if not usedPoints[key] then
			local dist = helper.distance(value,location)
			if dist < minDist then
				minDist = dist
				minValue = value
			end
		end
	end
	if not minValue then
		return nil
	end
	return minValue
end

--travelling salesman, nearest neighbour method
region.findOptimalBlockOrder = function(layers)
	local newLayers = {}
	local lastTime = os.clock()
	for index, layer in ipairs(layers) do
		local newLayer = {}
		local usedPoints = {}
		local current = region.findClosestPoint({x=0,y=0,z=0}, layer, usedPoints)
		repeat
			usedPoints[helper.getIndex(current.x, current.y, current.z)] = true
			table.insert(newLayer, current)
			current = region.findClosestPoint(current, layer, usedPoints)
			local curTime = os.clock()
			if curTime - lastTime > 1 then
				lastTime = curTime
				helper.osYield()
			end
		until not current
		newLayers[index]=newLayer
	end
	return newLayers
end

region.createLayersFromArea = function(diggingArea, direction)
	local blocksToProcess = region.cloneBlocks(diggingArea)
	region.markAdjacentInPlace(blocksToProcess)
	region.markTripleInPlace(blocksToProcess)
	local layers = region.separateLayers(blocksToProcess, direction)
	local orderedLayers = region.findOptimalBlockOrder(layers)
	return orderedLayers
end

region.shiftRegion = function(shape, delta)
	local newShape = {}
	for key,value in pairs(shape) do
		local newPos = {x = value.x + delta.x, y = value.y + delta.y, z = value.z + delta.z}
		newShape[helper.getIndex(newPos.x, newPos.y, newPos.z)] = newPos
	end
	return newShape
end

region.reserveChests = function(blocks)
	local blocksCopy = {}
	local counter = 0
	for _,value in pairs(blocks) do
		counter = counter + 1
		blocksCopy[counter] = value
	end
	table.sort(blocksCopy, function(a,b)
		if a.y ~= b.y then return a.y > b.y
		elseif a.z~=b.z then return a.z > b.z
		else return a.x > b.x end
	end)

	return {reserved=blocksCopy}
end

region.validateRegion = function(blocks)
	local result = SUCCESS
	--there must be only one connected component
	local components = region.findConnectedComponents(blocks)
	if helper.tableLength(components) == 0 then
		result = result + FAILED_REGION_EMPTY
	end
	if helper.tableLength(components) > 1 then
		result = result + FAILED_NONONE_COMPONENTCOUNT
	end
	--the turtle must be inside of the region
	if not blocks[helper.getIndex(0,0,0)] then
		result = result + FAILED_TURTLE_NOTINREGION
	end
	return result
end

--#endregion
--#region PATHFINDING----

local path = {}
path.pathfindUpdateNeighbour = function(data, neighbour, destination, origin, neighbourIndex)
	local originIndex = helper.getIndex(origin.x, origin.y, origin.z)
	if not data[neighbourIndex] then
		data[neighbourIndex] = {}
		data[neighbourIndex].startDist = data[originIndex].startDist + 1
		data[neighbourIndex].heuristicDist = helper.distance(neighbour, destination)
		data[neighbourIndex].previous = origin
	elseif data[originIndex].startDist + 1 < data[neighbourIndex].startDist then
		data[neighbourIndex].startDist = data[originIndex].startDist + 1
		data[neighbourIndex].previous = origin
	end
end

path.traversable = function(area, index, pathfindingType)
	if pathfindingType == PATHFIND_INSIDE_AREA then
		return area[index] ~= nil
	elseif pathfindingType == PATHFIND_INSIDE_NONPRESERVED_AREA then
		return not not (area[index] and not area[index].preserve)
	elseif pathfindingType == PATHFIND_OUTSIDE_AREA then
		return area[index] == nil
	elseif PATHFIND_ANYWHERE_NONPRESERVED then
		return area[index] == nil or not area[index].preserve
	end
	error("Unknown pathfinding type", 3)
end

path.pathfind = function(from, to, allBlocks, pathfindingType)
	if helper.isPosEqual(from,to) then
		return {length = 0}
	end
	local data = {}
	local openSet = {}
	local closedSet = {}

	local current = from
	local curIndex = helper.getIndex(from.x, from.y, from.z)
	openSet[curIndex] = current

	data[curIndex] = {}
	data[curIndex].startDist = 0
	data[curIndex].heuristicDist = helper.distance(current, to)

	while true do
		local surroundings = helper.getSurroundings(current)
		for key,value in pairs(surroundings) do
			if path.traversable(allBlocks,key,pathfindingType) and not closedSet[key] then 
				path.pathfindUpdateNeighbour(data, value, to, current, key)
				openSet[key] = value
			end
		end

		closedSet[curIndex] = current
		openSet[curIndex] = nil

		local minN = 9999999
		local minValue = nil
		for key,value in pairs(openSet) do
			local sum = data[key].startDist + data[key].heuristicDist
			if sum < minN then
				minN = sum
				minValue = value
			end
		end
		current = minValue;

		if current == nil then
			helper.printWarning("No path from", from.x, from.y, from.z, "to", to.x, to.y, to.z)
			return false
		end

		curIndex = helper.getIndex(current.x, current.y, current.z)
		if helper.isPosEqual(current,to) then
			break
		end
	end

	local path = {}
	local counter = 1
	while current ~= nil do
		path[counter] = current
		counter = counter + 1
		current = data[helper.getIndex(current.x, current.y, current.z)].previous
	end

	local reversedPath = {}
	local newCounter = 1
	for i=counter-1,1,-1 do
		reversedPath[newCounter] = path[i]
		newCounter = newCounter + 1
	end
	reversedPath.length = newCounter-1;
	return reversedPath
end

--#endregion
--#region SLOT MANAGER----
local slots = (function()
	local slotAssignments = {}
	local assigned = false
	local public = {}

	local slotDesc = nil

	local generateDescription = function(config)
		local desc = {
			[CHEST_SLOT] = "Chests",
			[BLOCK_SLOT] = "Cobblestone",
			[FUEL_SLOT] = "Fuel (only coal supported)",
			[FUEL_CHEST_SLOT] = "Fuel Entangled Chest",
			[CHUNK_LOADER_SLOT] = "2 Chunk Loaders",
		}
		if config.useEntangledChests then
			desc[CHEST_SLOT] = "Entangled Chest"
		end
		return desc
	end

	public.assignSlots = function(config)
		if assigned then
			error("Slots have already been assigned", 2)
		end
		assigned = true

		local currentSlot = 1
		slotAssignments[CHEST_SLOT] = currentSlot
		currentSlot = currentSlot + 1
		if config.useFuelEntangledChest then
			slotAssignments[FUEL_CHEST_SLOT] = currentSlot
			currentSlot = currentSlot + 1
		else
			slotAssignments[FUEL_SLOT] = currentSlot
			currentSlot = currentSlot + 1
		end
		if config.mineLoop then
			slotAssignments[CHUNK_LOADER_SLOT] = currentSlot
			currentSlot = currentSlot + 1
		end
		slotAssignments[BLOCK_SLOT] = currentSlot
		currentSlot = currentSlot + 1
		slotAssignments[MISC_SLOT] = currentSlot
		currentSlot = currentSlot + 1

		slotDesc = generateDescription(config)
	end

	public.get = function(slotId)
		if slotAssignments[slotId] then
			return slotAssignments[slotId]
		else
			error("Slot " .. tostring(slotId) .. " was not assigned", 2)
		end
	end

	public.printSlotInfo = function()
		local inverse = {}
		for key,value in pairs(slotAssignments) do
			inverse[value] = key
		end
		for key,value in ipairs(inverse) do
			if value ~= MISC_SLOT then
				helper.print("\tSlot", key, "-", slotDesc[value])
			end
		end
	end

	return public
end)()

--#endregion
--#region UI----

local ui = {}

ui.printInfo = function()
	helper.print("Current fuel level is", wrapt.getFuelLevel())
	helper.print("Item slots, can change based on config:")
	slots.printSlotInfo()
end

ui.printProgramsInfo = function()
	helper.print("Select a program:")
	helper.print("\thelp <program>")
	for _,value in pairs(shapes) do
		helper.print("\t"..value.shortDesc)
	end
end

ui.tryShowHelp = function(input)
	if not input then
		return false
	end
	local split = helper.splitString(input)
	if split[1] ~= "help" then
		return false
	end

	if #split == 1 then
		ui.printProgramsInfo()
		return true
	end

	if #split ~= 2 then
		return false
	end

	local program = split[2]
	local shape = nil
	for key, value in pairs(shapes) do
		if value.command == program then
			shape = value
		end
	end

	if not shape then
		helper.printError("Unknown program")
		return true
	end
	helper.print("Usage:", shape.shortDesc)
	helper.print("\t"..shape.longDesc)
	return true
end

ui.testRange = function(range, value)
	if range == "str" then
		return "string"
	end
	if type(value) ~= "number" then
		return false
	end

	local subRanges = helper.splitString(range, " ")
	for _, range in ipairs(subRanges) do
		local borders = helper.splitString(range, "..")
		local tableLength = helper.tableLength(borders)
		if tableLength == 2 then
			local left = tonumber(borders[1])
			local right = tonumber(borders[2])
			if helper.inRange(value, left, right) then
				return true
			end
		elseif tableLength == 1 then
			local isLeft = string.sub(range, 0, 1) ~= "."
			local border = tonumber(borders[1])
			local good = isLeft and (value >= border) or not isLeft and (value <= border)
			if good then
				return true
			end
		end
	end
	return false
end

ui.parseArgs = function(argPattern, args)
	if helper.tableLength(argPattern) ~= helper.tableLength(args) then
		return nil
	end
	
	local parsed = {}
	for _,value in ipairs(args) do
		local number = tonumber(value)
		if not number then
			table.insert(parsed, value)
		end
		table.insert(parsed, number)
	end

	for index,value in ipairs(argPattern) do
		local result = ui.testRange(value, parsed[index])
		if result == "string" then
			parsed[index] = args[index]
		elseif not result then
			return nil
		end
	end
	return parsed
end

ui.parseProgram = function(string)
	if not string then
		return nil
	end

	local split = helper.splitString(string)
	if not split or helper.tableLength(split) == 0 then
		return nil
	end
	
	local program = split[1]
	local shape = nil
	for _, value in pairs(shapes) do
		if value.command == program then
			shape = value
		end
	end
	if not shape then
		return nil
	end

	local args = {table.unpack(split, 2, #split)}
	local parsed = ui.parseArgs(shape.args, args)
	if not parsed then
		return nil
	end

	return {shape = shape, args = parsed}
end

ui.promptForShape = function()
	local shape
	while true do
		helper.write("> ")
		local input = helper.read()
		shape = ui.parseProgram(input)
		if not shape then
			if not ui.tryShowHelp(input) then
				helper.printError("Invalid program")
			end
		else
			break
		end
	end
	return shape
end

ui.showValidationError = function(validationResult) 
	local error = "Invalid mining volume:";
	if bit32.band(validationResult, FAILED_REGION_EMPTY) ~= 0 then
		helper.printError("Invalid mining volume: \n\tVolume is empty")
		return
	end
	if bit32.band(validationResult, FAILED_NONONE_COMPONENTCOUNT) ~= 0 then
		error = error .. "\n\tVolume has multiple disconnected parts"
	end
	if bit32.band(validationResult, FAILED_TURTLE_NOTINREGION) ~= 0 then
		error = error .. "\n\tTurtle (pos(0,0,0)) not in volume"
	end
	helper.printError(error)
end

--#endregion

----THE REST OF THE CODE----

local function execWithSlot(func, slot)
	wrapt.select(slots.get(slot))
	local data = func()
	wrapt.select(slots.get(MISC_SLOT))
	return data
end

local function isWaterSource(inspectFunction)
	local success, data = inspectFunction()
	if success and data.name == "minecraft:water" and data.state.level == 0 then
		return true
	end
	return false
end

local function isFluidSource(inspectFunction)
	local success, data = inspectFunction()
	if success and (data.name == "minecraft:lava" or data.name == "minecraft:water") and data.state.level == 0 then
		return true
	end
	return false
end

local function isFluid(inspectFunction)
	local success, data = inspectFunction()
	if success and (data.name == "minecraft:lava" or data.name == "minecraft:water") then
		return true
	end
	return false
end

local function isSand(inspectFunction)
	local success, data = inspectFunction()
	if success and FALLING_BLOCKS[data.name] then
		return true
	end
	return false
end

local function isOre(inspectFunction)
	local success, data = inspectFunction()
	if success and helper.stringEndsWith(data.name, "_ore") then
		return true
	end
	return false
end


local function dropInventory(dropFunction)
	local dropped = true
	for i=slots.get(MISC_SLOT),16 do
		if wrapt.getItemCount(i) > 0 then
			wrapt.select(i)
			dropped = dropFunction() and dropped
		end
	end
	wrapt.select(slots.get(MISC_SLOT))
	return dropped
end

local function forceMoveForward()
	if isWaterSource(wrapt.inspect) then
		execWithSlot(wrapt.place, BLOCK_SLOT)
	end
	repeat
		wrapt.dig()
	until wrapt.forward()
end

local function plugTop(onlyFluids)
	if isSand(wrapt.inspectUp) then
		wrapt.digUp()
	end
	if not wrapt.detectUp() and not onlyFluids or onlyFluids and isFluid(wrapt.inspectUp) then
		if wrapt.getItemCount(slots.get(BLOCK_SLOT)) > 0 then
			local tries = 0
			repeat tries = tries + 1 until execWithSlot(wrapt.placeUp, BLOCK_SLOT) or tries > 10
		end
	end
end

local function plugBottom(onlyFluids)
	if not onlyFluids or isFluidSource(wrapt.inspectDown) then
		execWithSlot(wrapt.placeDown, BLOCK_SLOT)
	end
end

local function digAbove()
	if isFluidSource(wrapt.inspectUp) then
		execWithSlot(wrapt.placeUp, BLOCK_SLOT)
	end
	wrapt.digUp()
end

local function digBelow()
	if isFluidSource(wrapt.inspectDown) then
		execWithSlot(wrapt.placeDown, BLOCK_SLOT)
	end
	wrapt.digDown()
end

local function digInFront()
	if isFluidSource(wrapt.inspect) then
		execWithSlot(wrapt.place, BLOCK_SLOT)
	end
	wrapt.dig()
end

local function turnTowardsDirection(targetDir)
	local delta = (targetDir - wrapt.getDirection()) % 4
	if delta == 1 then
		wrapt.turnRight()
	elseif delta == 2 then
		wrapt.turnRight()
		wrapt.turnRight()
	elseif delta == 3 then
		wrapt.turnLeft()
	end
	if targetDir ~= wrapt.getDirection() then
		error("Could not turn to requested direction")
	end
end



local function stepTo(tX, tY, tZ)
	local dX = tX - wrapt.getX()
	local dY = tY - wrapt.getY()
	local dZ = tZ - wrapt.getZ()
	if dY < 0 then
		repeat wrapt.digDown() until wrapt.down()
	elseif dY > 0 then
		repeat wrapt.digUp() until wrapt.up()
	else
		local dir = helper.deltaToDirection(dX, dZ)
		turnTowardsDirection(dir)
		forceMoveForward()
	end
end

local function goToCoords(curBlock, pathfindingArea, pathfindingType)
	local pos = wrapt.getPosition()
	local path = path.pathfind(pos, curBlock, pathfindingArea, pathfindingType)
	if not path then
		return false
	end

	for k=1,path.length do
		if not (path[k].x == pos.x and path[k].y == pos.y and path[k].z == pos.z) then
			stepTo(path[k].x, path[k].y, path[k].z)
		end
	end
	return true
end



local function findOre(oresTable, startPos, rangeLimit)
	local ores = {}
	local isForwardCloseEnough = function() 
		return helper.distance(helper.getForwardPos(wrapt.getPosition()), startPos) <= rangeLimit
	end
	if isForwardCloseEnough() and isOre(wrapt.inspect) then
		table.insert(ores,helper.getForwardPos(wrapt.getPosition()))
	end
	local down = {x = wrapt.getX(), y = wrapt.getY() - 1, z = wrapt.getZ()}
	if helper.distance(down, startPos) <= rangeLimit and isOre(wrapt.inspectDown) then
		table.insert(ores, down)
	end
	local up = {x = wrapt.getX(), y = wrapt.getY() + 1, z = wrapt.getZ()}
	if helper.distance(up, startPos) <= rangeLimit and isOre(wrapt.inspectUp) then
		table.insert(ores, up)
	end
	wrapt.turnLeft()
	if isForwardCloseEnough() and isOre(wrapt.inspect) then
		table.insert(ores,helper.getForwardPos(wrapt.getPosition()))
	end
	wrapt.turnLeft()
	if isForwardCloseEnough() and isOre(wrapt.inspect) then
		table.insert(ores,helper.getForwardPos(wrapt.getPosition()))
	end
	wrapt.turnLeft()
	if isForwardCloseEnough() and isOre(wrapt.inspect) then
		table.insert(ores,helper.getForwardPos(wrapt.getPosition()))
	end
	for _,value in pairs(ores) do
		if not helper.tableContains(oresTable, value, helper.isPosEqual) then
			table.insert(oresTable, value)
		end
	end
end

--traverse an ore vein and return to original turtle position afterwards
local function traverseVein(blocks, rangeLimit)
	local startPos = wrapt.getPosition()
	local minePath = {}
	minePath[helper.getIndex(startPos.x, startPos.y, startPos.z)] = startPos

	local ores = {}
	local searchedPositions = {}
	while true do
		local currentIndex = helper.getIndex(wrapt.getX(),wrapt.getY(),wrapt.getZ())
		if not searchedPositions[currentIndex] then
			findOre(ores, startPos, rangeLimit)
			searchedPositions[currentIndex] = true
		end
		local targetOre = table.remove(ores)
		if not targetOre then
			goToCoords(startPos, minePath, PATHFIND_INSIDE_AREA)
			turnTowardsDirection(startPos.direction)
			break
		end
		local targetIndex = helper.getIndex(targetOre.x, targetOre.y, targetOre.z)
		if not blocks[targetIndex] or not blocks[targetIndex].preserve then
			minePath[helper.getIndex(targetOre.x, targetOre.y, targetOre.z)] = targetOre
			goToCoords(targetOre, minePath, PATHFIND_INSIDE_AREA)
		end
	end
end



--diggingOptions: plugFluidsOnly, oreTraversalRadius
local function processAdjacent(allBlocks, diggingOptions)
	local toPlace = {}

	local pos = wrapt.getPosition()

	local minusX = helper.getIndex(pos.x-1, pos.y, pos.z)
	local plusX = helper.getIndex(pos.x+1, pos.y, pos.z)
	local minusZ = helper.getIndex(pos.x, pos.y, pos.z-1)
	local plusZ = helper.getIndex(pos.x, pos.y, pos.z+1)

	if not allBlocks[minusX] then toPlace[minusX] = {x = pos.x - 1, y = pos.y, z = pos.z} end
	if not allBlocks[plusX] then toPlace[plusX] = {x = pos.x + 1, y = pos.y, z = pos.z} end
	if not allBlocks[minusZ] then toPlace[minusZ] = {x = pos.x, y = pos.y, z = pos.z - 1} end
	if not allBlocks[plusZ] then toPlace[plusZ] = {x = pos.x, y = pos.y, z = pos.z + 1} end

	for key,value in pairs(toPlace) do
		local dX = value.x - pos.x
		local dZ = value.z - pos.z
		local dir = helper.deltaToDirection(dX, dZ)
		turnTowardsDirection(dir)
		if diggingOptions.oreTraversalRadius > 0 and isOre(wrapt.inspect) then
			traverseVein(allBlocks, diggingOptions.oreTraversalRadius)
		end
		if not diggingOptions.plugFluidsOnly or isFluid(wrapt.inspect) then
			execWithSlot(wrapt.place, BLOCK_SLOT)
		end
	end

	local minusY = helper.getIndex(pos.x, pos.y-1, pos.z)
	local plusY = helper.getIndex(pos.x, pos.y+1, pos.z)

	if diggingOptions.oreTraversalRadius > 0 then
		if not allBlocks[minusY] and isOre(wrapt.inspectDown)
			or not allBlocks[plusY] and isOre(wrapt.inspectUp) then
			traverseVein(allBlocks, diggingOptions.oreTraversalRadius)
		end
	end

	if allBlocks[minusY] then
		if not allBlocks[minusY].preserve then digBelow() end
	else
		plugBottom(diggingOptions.plugFluidsOnly)
	end

	if allBlocks[plusY] then
		if not allBlocks[plusY].preserve then digAbove() end
	else
		plugTop(diggingOptions.plugFluidsOnly)
	end
end




local function processTriple(diggingArea)
	local pos = wrapt.getPosition()
	local minusY = helper.getIndex(pos.x, pos.y-1, pos.z)
	local plusY = helper.getIndex(pos.x, pos.y+1, pos.z)
	if not diggingArea[plusY].preserve then digAbove() end
	if not diggingArea[minusY].preserve then digBelow() end
end



local function sortInventory(sortFuel)
	--clear cobble slot
	local initCobbleData = wrapt.getItemDetail(slots.get(BLOCK_SLOT))
	if initCobbleData and initCobbleData.name ~= "minecraft:cobblestone" then
		wrapt.select(slots.get(BLOCK_SLOT))
		wrapt.drop()
	end

	--clear fuel slot
	if sortFuel then
		local initFuelData = wrapt.getItemDetail(slots.get(FUEL_SLOT))
		if initFuelData and initFuelData.name ~= "minecraft:coal" then
			wrapt.select(slots.get(FUEL_SLOT))
			wrapt.drop()
		end
	end

	--search inventory for cobble and fuel and put them in the right slots
	local fuelData = sortFuel and wrapt.getItemDetail(slots.get(FUEL_SLOT)) or {count=64}
	local cobbleData = wrapt.getItemDetail(slots.get(BLOCK_SLOT))

	if fuelData and cobbleData and fuelData.count > 32 and cobbleData.count > 32 then
		wrapt.select(slots.get(MISC_SLOT))
		return
	end

	for i=slots.get(MISC_SLOT),16 do
		local curData = wrapt.getItemDetail(i)
		if curData then
			if curData.name == "minecraft:cobblestone" then
				wrapt.select(i)
				wrapt.transferTo(slots.get(BLOCK_SLOT))
			elseif sortFuel and curData.name == "minecraft:coal" then
				wrapt.select(i)
				wrapt.transferTo(slots.get(FUEL_SLOT))
			end
		end
	end

	wrapt.select(slots.get(MISC_SLOT))
end



local function dropIntoEntangled(dropFunction)
	local result = false
	repeat
		result = dropInventory(dropFunction)
		if not result then
			helper.printWarning("Entangled chest is full, retrying..")
---@diagnostic disable-next-line: undefined-field
			os.sleep(RETRY_DELAY)
		end
	until result
end

local function findSuitableEntangledChestPos(diggingArea)
	local surroundings = helper.getSurroundings(wrapt.getPosition())
	local options = {}
	for key,value in pairs(surroundings) do
		if diggingArea[key] and not diggingArea[key].preserve then
			table.insert(options, value)
		end
	end
	local selectedOption = table.remove(options)
	if not selectedOption then
		error("Did the turtle just surround itself with chests?")
		return nil
	end
	return selectedOption
end

local function dropOffEntangledChest(diggingArea)
	local selectedOption = findSuitableEntangledChestPos(diggingArea)
	if not selectedOption then
		return
	end

	local curPosition = wrapt.getPosition()
	local delta = {x = selectedOption.x-curPosition.x, y = selectedOption.y-curPosition.y, z = selectedOption.z-curPosition.z}
	if delta.y < 0 then
		repeat digBelow() until execWithSlot(wrapt.placeDown, CHEST_SLOT)
		dropIntoEntangled(wrapt.dropDown)
		wrapt.select(slots.get(CHEST_SLOT))
		digBelow()
		wrapt.select(slots.get(MISC_SLOT))
	elseif delta.y > 0 then
		repeat digAbove() until execWithSlot(wrapt.placeUp, CHEST_SLOT)
		dropIntoEntangled(wrapt.dropUp)
		wrapt.select(slots.get(CHEST_SLOT))
		digAbove()
		wrapt.select(slots.get(MISC_SLOT))
	elseif delta.x ~= 0 or delta.y ~= 0 or delta.z ~= 0 then
		local direction = helper.deltaToDirection(delta.x, delta.z)
		turnTowardsDirection(direction)
		repeat digInFront() until execWithSlot(wrapt.place, CHEST_SLOT)
		dropIntoEntangled(wrapt.drop)
		wrapt.select(slots.get(CHEST_SLOT))
		digInFront()
		wrapt.select(slots.get(MISC_SLOT))
	else
		error("Something went really wrong")
	end
end

local function makeNewChestInPlace(chestData, diggingArea)
	local newPos = table.remove(chestData.reserved)
	if not newPos then
		error("Out of reserved chest spots")
		return false
	end
	chestData.placed = newPos
	
	local chestPosIndex = helper.getIndex(chestData.placed.x, chestData.placed.y, chestData.placed.z)
	chestData.reserved[chestPosIndex] = nil
	local blockAbove = {x = chestData.placed.x, y = chestData.placed.y+1, z = chestData.placed.z}
	if not goToCoords(diggingArea[helper.getIndex(blockAbove.x, blockAbove.y, blockAbove.z)], diggingArea, PATHFIND_INSIDE_NONPRESERVED_AREA) then
		helper.printWarning("Could not pathfind to new chest location, trying again ignoring walls...")
		if not goToCoords(diggingArea[helper.getIndex(blockAbove.x, blockAbove.y, blockAbove.z)], diggingArea, PATHFIND_ANYWHERE_NONPRESERVED) then
			helper.printWarning("Fallback pathfinding failed")
			return false
		end
	end
	digBelow()
	while true do
		local success = execWithSlot(wrapt.placeDown, CHEST_SLOT)
		if success then
			break
		end
		local chestData = wrapt.getItemDetail(slots.get(CHEST_SLOT))
		if not chestData then
			helper.printWarning("Out of chests. Add chests to slot", slots.get(CHEST_SLOT))
		end
---@diagnostic disable-next-line: undefined-field
		os.sleep(RETRY_DELAY)
	end
	diggingArea[chestPosIndex].preserve = true
	return true
end

local function dropOffNormally(chestData, diggingArea)
	if not chestData.placed then
		makeNewChestInPlace(chestData, diggingArea)
	end

	local blockAbove = {x = chestData.placed.x, y = chestData.placed.y+1, z = chestData.placed.z}
	if not goToCoords(diggingArea[helper.getIndex(blockAbove.x, blockAbove.y, blockAbove.z)], diggingArea, PATHFIND_INSIDE_NONPRESERVED_AREA) then
		helper.printWarning("Could not pathfind to chest location, trying again ignoring walls...")
		if not goToCoords(diggingArea[helper.getIndex(blockAbove.x, blockAbove.y, blockAbove.z)], diggingArea, PATHFIND_ANYWHERE_NONPRESERVED) then
			helper.printWarning("Fallback pathfinding failed too")
		end
	end
	repeat
		for i=slots.get(MISC_SLOT),16 do
			wrapt.select(i)
			if not wrapt.dropDown() and wrapt.getItemDetail(i) then
				makeNewChestInPlace(chestData, diggingArea)
				wrapt.dropDown()
			end
		end
	until not wrapt.getItemDetail(16)
	wrapt.select(slots.get(MISC_SLOT))
end

local function tryDropOffThings(chestData, diggingArea, entangledChest, force)
	if not wrapt.getItemDetail(16) and not force then
		return
	end

	if entangledChest then
		dropOffEntangledChest(diggingArea)
		return
	end

	dropOffNormally(chestData, diggingArea)
end



local function getFuelAndConsumeFromEntangled(suckFunction, dropFunction)
	local result = false
	wrapt.select(16)
	repeat
		repeat
			if not suckFunction(32) then
				helper.printWarning("Refuel chest is empty, retrying...")
				break
			end
			if not wrapt.refuel() then
				helper.printWarning("Refuel chest contains garbage, retrying...")
				while not dropFunction() do
					helper.printWarning("Could not return garbage back to the chest, retrying...")
---@diagnostic disable-next-line: undefined-field
					os.sleep(RETRY_DELAY)
				end
				break
			end
			result = wrapt.getFuelLevel() > REFUEL_THRESHOLD
		until result
		if not result then
---@diagnostic disable-next-line: undefined-field
			os.sleep(RETRY_DELAY)
		end
	until result
end

local function refuelEntangled(chestData, diggingArea, dropOffEntangled)
	tryDropOffThings(chestData, diggingArea, dropOffEntangled)
	
	local selectedOption = findSuitableEntangledChestPos(diggingArea)
	if not selectedOption then return end

	local curPosition = wrapt.getPosition()
	local delta = {x = selectedOption.x-curPosition.x, y = selectedOption.y-curPosition.y, z = selectedOption.z-curPosition.z}
	if delta.y < 0 then
		repeat digBelow() until execWithSlot(wrapt.placeDown, FUEL_CHEST_SLOT)
		getFuelAndConsumeFromEntangled(wrapt.suckDown, wrapt.dropDown)
		wrapt.select(slots.get(FUEL_CHEST_SLOT))
		digBelow()
		wrapt.select(slots.get(MISC_SLOT))
	elseif delta.y > 0 then
		repeat digAbove() until execWithSlot(wrapt.placeUp, FUEL_CHEST_SLOT)
		getFuelAndConsumeFromEntangled(wrapt.suckUp, wrapt.dropUp)
		wrapt.select(slots.get(FUEL_CHEST_SLOT))
		digAbove()
		wrapt.select(slots.get(MISC_SLOT))
	elseif delta.x ~= 0 or delta.y ~= 0 or delta.z ~= 0 then
		local direction = helper.deltaToDirection(delta.x, delta.z)
		turnTowardsDirection(direction)
		repeat digInFront() until execWithSlot(wrapt.place, FUEL_CHEST_SLOT)
		getFuelAndConsumeFromEntangled(wrapt.suck, wrapt.drop)
		wrapt.select(slots.get(FUEL_CHEST_SLOT))
		digInFront()
		wrapt.select(slots.get(MISC_SLOT))
	else
		error("Something went really wrong")
	end
end

local function refuelNormally()
	repeat
		local fuelData = wrapt.getItemDetail(slots.get(FUEL_SLOT))
		if not fuelData then
			sortInventory(true)
		end
		repeat
			local newFuelData = wrapt.getItemDetail(slots.get(FUEL_SLOT))
			if not newFuelData then
				helper.printWarning("Out of fuel. Put fuel in slot", slots.get(FUEL_SLOT))
	---@diagnostic disable-next-line: undefined-field
				os.sleep(RETRY_DELAY)
				helper.osYield()
			end
		until newFuelData
		execWithSlot(wrapt.refuel, FUEL_SLOT)
	until wrapt.getFuelLevel() > REFUEL_THRESHOLD
end

local function tryToRefuel(chestData, diggingArea, dropOffEntangledChest, refuelEntangledChest)
	if wrapt.getFuelLevel() < REFUEL_THRESHOLD then
		if refuelEntangledChest then 
			refuelEntangled(chestData, diggingArea, dropOffEntangledChest)
			return
		else
			refuelNormally()
			return
		end
	end
end



local function executeDigging(layers, diggingArea, chestData, config)
	local counter = 0
	for layerIndex, layer in ipairs(layers) do
		for blockIndex, block in ipairs(layer) do
			if counter % 5 == 0 or not wrapt.getItemDetail(slots.get(BLOCK_SLOT)) then
				sortInventory(not config.useFuelEntangledChest)
			end
			if counter % 5 == 0 then
				tryToRefuel(chestData, diggingArea, config.useEntangledChests, config.useFuelEntangledChest)
			end
			tryDropOffThings(chestData, diggingArea, config.useEntangledChests)
			if not diggingArea[helper.getIndex(block.x, block.y, block.z)].preserve then
				if not goToCoords(block, diggingArea, PATHFIND_INSIDE_NONPRESERVED_AREA) then
					helper.printWarning("Couldn't find a path to next block, trying again ingoring walls...")
					if not goToCoords(block, diggingArea, PATHFIND_ANYWHERE_NONPRESERVED) then
						helper.printWarning("Fallback pathfinding failed, skipping the block")
						break
					end
				end
				if block.adjacent then
					processAdjacent(diggingArea, config)
				elseif block.triple then
					processTriple(diggingArea)
				end
			end
			counter = counter + 1
		end
	end
	tryDropOffThings(chestData, diggingArea, config.useEntangledChests, true)
end

local function getValidatedRegion(config, default)
	ui.printInfo()
	ui.printProgramsInfo()
	while true do
		local shape = nil
		if default then
			shape = ui.parseProgram(config.defaultCommand)
			if not shape then
				helper.printError("defaultCommand is invalid")
				default = false
			end
		end

		if not default then
			shape = ui.promptForShape()
		end

		local genRegion = shape.shape.generate(table.unpack(shape.args))
		local validationResult = region.validateRegion(genRegion)
		if validationResult == SUCCESS then
			return genRegion
		end
		ui.showValidationError(validationResult)
	end
end

local function launchDigging(config, default)
	local diggingArea = getValidatedRegion(config, default)
	local layers = region.createLayersFromArea(diggingArea, config.layerSeparationAxis)
	local chestData = region.reserveChests(diggingArea)
	executeDigging(layers, diggingArea, chestData, config)
end


local function executeMineLoop(config)
	local cumDelta = {x = 0, y = 0, z = 0}
	local prevPos = nil
	while true do
		--create a region to dig
		local shape = ui.parseProgram(config.mineLoopCommand)
		local diggingArea = shape.shape.generate(table.unpack(shape.args))
		diggingArea = region.shiftRegion(diggingArea, cumDelta)
		local layers = region.createLayersFromArea(diggingArea, config.layerSeparationAxis)
		local chestData = region.reserveChests(diggingArea)

		--place chunk loader
		local chunkLoaderPos = table.remove(chestData.reserved)
		local chunkLoaderIndex = helper.getIndex(chunkLoaderPos.x, chunkLoaderPos.y, chunkLoaderPos.z)
		local blockAbove = {x = chunkLoaderPos.x, y = chunkLoaderPos.y+1, z = chunkLoaderPos.z}
		if prevPos then
			prevPos.preserve = true
			diggingArea[helper.getIndex(prevPos.x, prevPos.y, prevPos.z)] = prevPos
		end
		if not goToCoords(blockAbove, diggingArea, PATHFIND_ANYWHERE_NONPRESERVED) then
			helper.printError("Could not navigate to new chunk loader position, aborting...")
			return
		end
		repeat digBelow() until execWithSlot(wrapt.placeDown, CHUNK_LOADER_SLOT)
		diggingArea[chunkLoaderIndex].preserve = true

		--remove old chunk loader
		if prevPos then
			local prevBlockAbove = {x = prevPos.x, y = prevPos.y+1, z = prevPos.z}
			if not goToCoords(prevBlockAbove, diggingArea, PATHFIND_ANYWHERE_NONPRESERVED) then
				helper.printError("Could not navigate to previous chunkloader, aborting")
			end
			execWithSlot(digBelow, CHUNK_LOADER_SLOT)
			if not goToCoords(blockAbove, diggingArea, PATHFIND_ANYWHERE_NONPRESERVED) then
				helper.printError("Could not navigate back from old loader, aborting...")
				return
			end
		end

		--dig the region
		executeDigging(layers, diggingArea, chestData, config)

		prevPos = chunkLoaderPos
		cumDelta = {x = cumDelta.x + config.mineLoopOffset.x,y = cumDelta.y + config.mineLoopOffset.y,z = cumDelta.z + config.mineLoopOffset.z}
	end
end

local function launchMineLoop(config, autostart)
	helper.print("Verifying mineLoopCommand...")
	local shape = ui.parseProgram(config.mineLoopCommand)
	if not shape then
		helper.printError("mineLoopCommand is invalid")
		return
	end
	local areaToValidate = shape.shape.generate(table.unpack(shape.args))
	local validationResult = region.validateRegion(areaToValidate)
	if validationResult ~= SUCCESS then
		ui.showValidationError(validationResult)
		return
	end

	if not autostart then
		ui.printInfo()
		helper.print("Press Enter to start the loop")
		helper.read()
	end
	executeMineLoop(config)
end



local function main(...)
	local args = {...}
	local config = helper.readOnlyTable(cfg.processConfig())
	slots.assignSlots(config)

	local default = args[1] == "def"

	if config.mineLoop then
		launchMineLoop(config, default)
		return
	end
	
	launchDigging(config, default)
end

main(...)