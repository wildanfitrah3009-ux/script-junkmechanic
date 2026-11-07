-- JunkMechanics - merged review copy
--
-- Merge note:
-- The second uploaded file is an overlapping copy of the opening section of the first;
-- it ends earlier (mid-declaration) and does not provide a continuation.
-- The longer source was therefore retained once, avoiding duplicate local declarations.
--
-- IMPORTANT: The first source ends mid-function at Move.FreeSpot. That incomplete
-- function has been omitted here rather than inventing missing game logic.
-- This artifact is a cleaned partial source, not a verified complete/runnable release.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Environment = type(getgenv) == "function" and getgenv() or _G

if type(Environment.JunkMechanicsHub) == "table" and type(Environment.JunkMechanicsHub.Unload) == "function" then
	pcall(Environment.JunkMechanicsHub.Unload)
end

local Hub = {
	Running = true,
	Connections = {},
	Cleanups = {},
	Toggles = {},
}
Environment.JunkMechanicsHub = Hub

local LibraryUrl = "https://raw.githubusercontent.com/PookiePepelsss/Airflow-UI/refs/heads/main/Source.luau"
local CreditsUrl = "https://raw.githubusercontent.com/Bac0nHck/Something/refs/heads/main/telegram"

local Storage = {
	Folder = "JunkMechanics",
	Configs = "JunkMechanics/Configs",
	Settings = { AutoLoad = "", AutoSave = false },
}

function Storage.Ensure(path)
	if type(isfolder) ~= "function" or type(makefolder) ~= "function" then
		return
	end
	pcall(function()
		if not isfolder(path) then
			makefolder(path)
		end
	end)
end

function Storage.Write(name, content)
	if type(writefile) ~= "function" then
		return false
	end
	Storage.Ensure(Storage.Folder)
	return (pcall(writefile, Storage.Folder .. "/" .. name, content))
end

function Storage.Read(name, legacy)
	if type(readfile) ~= "function" or type(isfile) ~= "function" then
		return nil
	end
	local path = Storage.Folder .. "/" .. name
	local ok, content = pcall(function()
		if isfile(path) then
			return readfile(path)
		end
		if legacy and isfile(legacy) then
			local old = readfile(legacy)
			if Storage.Write(name, old) and type(delfile) == "function" then
				pcall(delfile, legacy)
			end
			return old
		end
		return nil
	end)
	if ok and type(content) == "string" then
		return content
	end
	return nil
end

function Storage.Load(name, legacy)
	local content = Storage.Read(name, legacy)
	if not content then
		return nil
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(content)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

function Storage.Save(name, data)
	local ok, content = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	return ok and Storage.Write(name, content)
end

function Storage.LoadSettings()
	local data = Storage.Load("settings.json")
	if data then
		Storage.Settings.AutoLoad = type(data.AutoLoad) == "string" and data.AutoLoad or ""
		Storage.Settings.AutoSave = data.AutoSave == true
	end
end

function Storage.SaveSettings()
	Storage.Save("settings.json", Storage.Settings)
end

function Storage.HasConfig(name)
	if type(name) ~= "string" or name == "" or type(isfile) ~= "function" then
		return false
	end
	local ok, exists = pcall(isfile, Storage.Configs .. "/" .. name .. ".json")
	return ok and exists == true
end

Storage.Ensure(Storage.Folder)
Storage.Ensure(Storage.Configs)
Storage.LoadSettings()

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameData = Shared:WaitForChild("Data")
local ClientFolder = ReplicatedStorage:WaitForChild("Client")

local function findPath(root, path)
	local current = root
	for _, name in ipairs(path) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name) or current:WaitForChild(name, 5)
	end
	return current
end

local function loadModule(root, path)
	local module = findPath(root, path)
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok then
		return result
	end
	return nil
end

local Net = loadModule(Shared, { "Net" })
local ReplicaClient = loadModule(Shared, { "Libs", "ReplicaClient" })
local VehicleData = loadModule(GameData, { "Vehicles", "Data" }) or {}
local Pricing = loadModule(GameData, { "Vehicles", "Pricing" })
local CarPartsData = loadModule(GameData, { "CarParts", "Data" })
local JunkConstants = loadModule(GameData, { "Junk", "Constants" }) or {}
local Junkyards = loadModule(GameData, { "Junk", "Junkyards" })
local Networth = loadModule(GameData, { "Analytics", "Networth" })
local SellConstants = loadModule(GameData, { "Sell", "Constants" }) or {}
local Sellers = loadModule(GameData, { "Sell", "Sellers" }) or {}
local MachineCatalog = loadModule(GameData, { "Machines", "Catalog" }) or {}
local ProfileReplica = loadModule(ClientFolder, { "Services", "ProfileReplica" })
local ConfirmationService = loadModule(ClientFolder, { "Services", "ConfirmationService" })
local PaintMaterials = loadModule(GameData, { "PaintShop", "Materials" })
local RoadData = loadModule(GameData, { "RoadGraph" })
local PaintCosts = loadModule(GameData, { "PaintShop", "Costs" })
local VehicleModel = loadModule(Shared, { "Util", "VehicleModel" })
local GeneralData = loadModule(GameData, { "General", "Gen" })

if type(Net) ~= "table" then
	warn("Junk Mechanics: network module not found")
	return
end

local SellActions = SellConstants.Actions or { Accept = "Accept", Decline = "Decline", Negotiate = "Negotiate" }

local HoistStates, HoistActions
do
	local gameplay = findPath(ClientFolder, { "Controllers", "Gameplay" })
	local hoist = gameplay and gameplay:FindFirstChild("HoistMinigame")
	local seen = {}
	local function isEnum(value)
		local count = 0
		for key, item in pairs(value) do
			if type(key) ~= "string" or (type(item) ~= "string" and type(item) ~= "number") then
				return false
			end
			count = count + 1
		end
		return count >= 2 and count <= 12
	end
	local function scan(value, depth)
		if type(value) ~= "table" or seen[value] or depth > 3 then
			return
		end
		seen[value] = true
		if HoistActions == nil and rawget(value, "Complete") ~= nil and rawget(value, "Cancel") ~= nil and isEnum(value) then
			HoistActions = value
		end
		if HoistStates == nil and rawget(value, "Active") ~= nil and rawget(value, "Complete") == nil and isEnum(value) then
			HoistStates = value
		end
		for _, inner in pairs(value) do
			scan(inner, depth + 1)
		end
	end
	if hoist then
		for _, item in ipairs(hoist:GetDescendants()) do
			if item:IsA("ModuleScript") then
				local ok, result = pcall(require, item)
				if ok then
					scan(result, 0)
				end
			end
		end
	end
	if type(HoistActions) ~= "table" or type(HoistActions.Complete) ~= "number" then
		HoistActions = { Cancel = 0, Complete = 1 }
	end
	if type(HoistStates) ~= "table" or type(HoistStates.Active) ~= "number" then
		HoistStates = { Active = 0, Complete = 1, Cancelled = 2 }
	end
end

local Suffixes = { "", "K", "M", "B", "T", "Qa" }

local function formatNumber(value)
	value = tonumber(value) or 0
	local negative = value < 0
	value = math.abs(value)
	local index = 1
	while value >= 1000 and index < #Suffixes do
		value = value / 1000
		index = index + 1
	end
	local text
	if index == 1 then
		text = tostring(math.floor(value + 0.5))
	else
		text = string.gsub(string.format("%.2f", value), "%.?0+$", "") .. Suffixes[index]
	end
	return (negative and "-" or "") .. text
end

local function formatMoney(value)
	value = tonumber(value) or 0
	local sign = value < 0 and "-" or ""
	local digits = tostring(math.floor(math.abs(value) + 0.5))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	grouped = string.gsub(grouped, "^,", "")
	return sign .. "$" .. grouped
end

local function formatTime(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor(seconds % 3600 / 60)
	local rest = seconds % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, rest)
	end
	return string.format("%d:%02d", minutes, rest)
end

local function parseAmount(text)
	text = string.gsub(tostring(text or ""), "[%s,%$]", "")
	if text == "" then
		return 0
	end
	local number, suffix = string.match(text, "^(%d*%.?%d+)(%a*)$")
	number = tonumber(number)
	if not number then
		return nil
	end
	if suffix == "" then
		return number
	end
	for index, name in ipairs(Suffixes) do
		if name ~= "" and string.lower(name) == string.lower(suffix) then
			return number * 1000 ^ (index - 1)
		end
	end
	return nil
end

local function flat(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function unit(vector, fallback)
	if vector.Magnitude < 0.001 then
		return fallback or Vector3.new(1, 0, 0)
	end
	return vector.Unit
end

local function getRoot()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local character = LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function raycast(origin, direction, exclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude or {}
	params.IgnoreWater = true
	return Workspace:Raycast(origin, direction, params)
end

local function getProfile()
	if type(ProfileReplica) ~= "table" then
		return nil
	end
	local replica = rawget(ProfileReplica, "_replica")
	if type(replica) == "table" and type(replica.Data) == "table" then
		return replica.Data
	end
	local ok, snapshot = pcall(function()
		return ProfileReplica:GetSnapshot()
	end)
	if ok and type(snapshot) == "table" then
		return snapshot
	end
	return nil
end

local function getMoney()
	local profile = getProfile()
	local economy = profile and profile.Economy
	return type(economy) == "table" and tonumber(economy.Money) or 0
end

local Status = {
	Text = "Idle",
	Detail = "",
	Since = os.clock(),
	Message = "-",
	Npc = "-",
	Log = {},
}

local function setStatus(text, detail)
	detail = detail and tostring(detail) or ""
	if Status.Text ~= text or Status.Detail ~= detail then
		Status.Since = os.clock()
		table.insert(Status.Log, 1, os.date("%H:%M:%S") .. " " .. text .. (detail ~= "" and (" - " .. detail) or ""))
		if #Status.Log > 60 then
			table.remove(Status.Log)
		end
	end
	Status.Text = text
	Status.Detail = detail
end

local Stats = {
	StartMoney = nil,
	StartTime = os.clock(),
	Bought = 0,
	Sold = 0,
	Spent = 0,
	Earned = 0,
	Errors = 0,
	Repaired = 0,
	Wheels = 0,
	WheelSpent = 0,
	LastCar = nil,
	LastProfit = nil,
	BestProfit = nil,
	Cycles = 0,
	CycleTime = 0,
}

local Job = {
	Running = false,
	Cancel = false,
	Name = nil,
}

local function checkpoint()
	if not Hub.Running or Job.Cancel then
		error("JobCancelled", 0)
	end
end

local function sleep(seconds)
	local deadline = os.clock() + (seconds or 0)
	repeat
		checkpoint()
		task.wait(math.clamp(deadline - os.clock(), 0, 0.1))
	until os.clock() >= deadline
	checkpoint()
end

local function waitFor(predicate, timeout, step)
	local deadline = os.clock() + (timeout or 5)
	while os.clock() < deadline do
		checkpoint()
		local ok, result = pcall(predicate)
		if ok and result then
			return result
		end
		task.wait(step or 0.1)
	end
	local ok, result = pcall(predicate)
	if ok and result then
		return result
	end
	return nil
end

function Hub.On(event, callback)
	if type(event) ~= "table" or type(event.On) ~= "function" then
		return
	end
	local ok, disconnect = pcall(event.On, callback)
	if ok and disconnect ~= nil then
		table.insert(Hub.Cleanups, disconnect)
	end
end

function Hub.Fire(event, ...)
	if type(event) ~= "table" or type(event.Fire) ~= "function" then
		return false
	end
	local ok = pcall(event.Fire, ...)
	return ok
end

local State = {
	Farm = false,
	AutoBuy = false,
	AutoRepair = false,
	AutoSell = false,
	AutoMinigames = true,
	AntiAfk = true,
	QuickTravel = true,
	DriveSpeed = 70,
	TravelMode = "Teleport",
	GlideSpeed = 150,
	PlayerTeleport = true,
	RepairBattery = true,
	RepairMechanical = true,
	RepairEngine = true,
	RepairRadiator = true,
	AutoMissingParts = true,
	FixWheels = true,
	WheelMinWear = 0.3,
	Paint = true,
	PaintColor = "Random",
	UseGarage = true,
	UseAllGarageCars = false,
	MinWear = 0.02,
	WashDelay = 3,
	WeldDelay = 6,
	Seller = "Juan",
	UseLupin = true,
	Negotiate = false,
	MaxRisk = 20,
	RickMinPercent = 90,
}

local Filter = {
	Tiers = {},
	Cars = {},
	Junkyards = {},
	MinPrice = 0,
	MaxPrice = 0,
	MinProfit = 0,
	MinMargin = 0,
	Reserve = 0,
	Sort = "Best Profit",
}

local CarOptions, CarByLabel = {}, {}
do
	local list = {}
	for key, info in pairs(VehicleData) do
		if type(info) == "table" and tonumber(info.Price) then
			table.insert(list, {
				Key = key,
				Name = tostring(info.DisplayName or key),
				Tier = tonumber(info.Tier) or 0,
				Price = tonumber(info.Price) or 0,
			})
		end
	end
	table.sort(list, function(a, b)
		if a.Tier ~= b.Tier then
			return a.Tier < b.Tier
		end
		return a.Price < b.Price
	end)
	for _, entry in ipairs(list) do
		local label = string.format("T%d %s", entry.Tier, entry.Name)
		if CarByLabel[label] then
			label = label .. " (" .. entry.Key .. ")"
		end
		CarByLabel[label] = entry.Key
		table.insert(CarOptions, label)
	end
end

local JunkyardList = {}
if type(Junkyards) == "table" and type(Junkyards.ByGrade) == "table" then
	for grade, info in pairs(Junkyards.ByGrade) do
		if type(info) == "table" then
			table.insert(JunkyardList, {
				Grade = grade,
				Name = tostring(info.DisplayName or ("Junkyard " .. tostring(grade))),
				Required = tonumber(info.RequiredNetworth) or 0,
				Fee = tonumber(info.TeleportFee) or 5000,
			})
		end
	end
	table.sort(JunkyardList, function(a, b)
		return a.Grade < b.Grade
	end)
end

local JunkyardOptions, JunkyardByLabel = {}, {}
for _, entry in ipairs(JunkyardList) do
	JunkyardByLabel[entry.Name] = entry.Grade
	table.insert(JunkyardOptions, entry.Name)
end

local JunkyardFallback = {
	[1] = Vector3.new(553, 83, -1828),
	[2] = Vector3.new(486, 83, -2052),
	[3] = Vector3.new(1949, 83, -198),
	[4] = Vector3.new(2053, 83, 845),
}

local Places = {
	Workshop = Vector3.new(524, 84, -1330),
	Juan = Vector3.new(860, 83, -1596),
	Rick = Vector3.new(497, 83, -1714),
	MrLupin = Vector3.new(1258, 84, -100),
}

local function junkyardInfo(grade)
	for _, entry in ipairs(JunkyardList) do
		if entry.Grade == grade then
			return entry
		end
	end
	return nil
end

local function junkyardCenter(grade)
	local buildings = Workspace:FindFirstChild("Buildings")
	local yard = buildings and buildings:FindFirstChild("JunkYard")
	local grades = yard and yard:FindFirstChild("Grades")
	local folder = grades and grades:FindFirstChild(tostring(grade))
	local npc = folder and folder:FindFirstChild("Zack")
	if npc and npc:IsA("Model") then
		return npc:GetPivot().Position
	end
	return JunkyardFallback[grade]
end

local function junkyardUnlocked(grade)
	local info = junkyardInfo(grade)
	if not info or info.Required <= 0 then
		return true
	end
	local profile = getProfile()
	if not (profile and type(Networth) == "table" and type(Networth.Compute) == "function") then
		return true
	end
	local ok, value = pcall(Networth.Compute, profile)
	if not ok then
		return true
	end
	return (tonumber(value) or 0) >= info.Required
end

local function nearestJunkyard(position)
	local bestGrade, bestDistance
	for _, entry in ipairs(JunkyardList) do
		local center = junkyardCenter(entry.Grade)
		if center then
			local distance = (flat(center) - flat(position)).Magnitude
			if not bestDistance or distance < bestDistance then
				bestGrade, bestDistance = entry.Grade, distance
			end
		end
	end
	return bestGrade, bestDistance
end

local Car = {}

function Car.Get()
	local folder = Workspace:FindFirstChild("Vehicles")
	if not folder then
		return nil
	end
	local named = folder:FindFirstChild(tostring(LocalPlayer.UserId))
	if named and named:IsA("Model") and named:GetAttribute("OwnerUserId") == LocalPlayer.UserId and named.PrimaryPart then
		return named
	end
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model.PrimaryPart and model:GetAttribute("OwnerUserId") == LocalPlayer.UserId and model:GetAttribute("IsGarageDisplayVehicle") ~= true and model:GetAttribute("TutorialForUserId") == nil and model:GetAttribute("IsTestDrive") ~= true then
			return model
		end
	end
	return nil
end

function Car.Record(car)
	local profile = getProfile()
	local id = car and car:GetAttribute("GarageVehicleId")
	local garage = profile and profile.Garage
	local vehicles = type(garage) == "table" and garage.Vehicles
	if id and type(vehicles) == "table" then
		return vehicles[id]
	end
	return nil
end

function Car.Name(car)
	local key = car and car:GetAttribute("VehicleName")
	local info = key and VehicleData[key]
	return info and tostring(info.DisplayName or key) or tostring(key or "?"), key
end

function Car.Value(car)
	local record = Car.Record(car)
	local key = car and car:GetAttribute("VehicleName")
	if record and key and type(Pricing) == "table" and Pricing.ComputeStoredValue then
		local ok, value = pcall(Pricing.ComputeStoredValue, key, record)
		if ok and tonumber(value) then
			return value
		end
	end
	return nil
end

function Car.Condition(car)
	local record = Car.Record(car)
	local key = car and car:GetAttribute("VehicleName")
	if record and key and type(Pricing) == "table" and Pricing.ComputeStoredCondition then
		local ok, value = pcall(Pricing.ComputeStoredCondition, key, record)
		if ok and tonumber(value) then
			return value
		end
	end
	return nil
end

function Car.FullValue(key)
	if type(Pricing) == "table" and Pricing.ComputeSellPayout then
		local ok, value = pcall(Pricing.ComputeSellPayout, key, 1, 1)
		if ok and tonumber(value) then
			return value
		end
	end
	local info = VehicleData[key]
	local price = info and tonumber(info.Price) or 0
	local rate = info and tonumber(info.Profit) or 0
	return math.floor(price * (1 + math.clamp(rate, 0, 0.95)))
end

function Car.Seat(car)
	local seats = car and car:FindFirstChild("Seats")
	local seat = seats and seats:FindFirstChild("Drive")
	if seat and seat:IsA("BasePart") then
		return seat
	end
	return car and car:FindFirstChildWhichIsA("VehicleSeat", true)
end

function Car.Forward(car)
	local seat = Car.Seat(car)
	local look = seat and seat.CFrame.LookVector or -car:GetPivot().LookVector
	return unit(flat(look), Vector3.new(0, 0, -1))
end

function Car.Size(car)
	local _, size = car:GetBoundingBox()
	return math.max(size.X, size.Z) / 2, math.min(size.X, size.Z) / 2
end

function Car.PartsFolder(car)
	local primary = car and car.PrimaryPart
	return primary and primary:FindFirstChild("CarParts")
end

function Car.Installed(car, slot)
	local folder = Car.PartsFolder(car)
	if not folder then
		return nil
	end
	for _, item in ipairs(folder:GetChildren()) do
		if item.Name == slot and not item:IsA("Attachment") and item:GetAttribute("CarPart") == true then
			return item
		end
	end
	return nil
end

function Car.Drop(car)
	local primary = car and car.PrimaryPart
	local hitboxes = primary and primary:FindFirstChild("Hitboxes")
	local drop = hitboxes and hitboxes:FindFirstChild("Drop")
	if drop and drop:IsA("BasePart") then
		return drop
	end
	return nil
end

function Car.Hood(car)
	for _, item in ipairs(car:GetDescendants()) do
		if item:IsA("BasePart") and CollectionService:HasTag(item, "HoodPart") then
			return item
		end
	end
	local body = car:FindFirstChild("Body")
	local hood = body and body:FindFirstChild("Hood")
	if hood then
		if hood:IsA("BasePart") then
			return hood
		end
		return hood:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function Car.HoodOpen(car)
	local hood = Car.Hood(car)
	local primary = car and car.PrimaryPart
	if not (hood and primary) then
		return nil
	end
	local relative = primary.CFrame:ToObjectSpace(hood.CFrame)
	return math.deg(math.acos(math.clamp(relative.UpVector.Y, -1, 1))) > 25
end

function Car.StandPoint(car, point)
	local center = car:GetPivot().Position
	local forward = Car.Forward(car)
	local halfLength = Car.Size(car)
	local front = center + forward * (halfLength + 3.5)
	local back = center - forward * (halfLength + 3.5)
	local choice = back
	if (front - point).Magnitude < (back - point).Magnitude then
		choice = front
	end
	local root = getRoot()
	return Vector3.new(choice.X, root and root.Position.Y or point.Y, choice.Z)
end

local SlotNeeds = {
	CylinderHead = "Engine",
	Transmission = "Engine",
	IntakeManifold = "CylinderHead",
	ExhaustManifold = "CylinderHead",
	Turbocharger = "CylinderHead",
	Supercharger = "CylinderHead",
}

function Car.SlotFilled(car, slot)
	local record = Car.Record(car)
	local slots = record and record.CarParts
	local info = type(slots) == "table" and slots[slot]
	if type(info) ~= "table" then
		return true
	end
	return type(info.Variant) == "string" and info.Variant ~= ""
end

function Car.MissingSlots(car)
	local list = {}
	local record = Car.Record(car)
	local slots = record and record.CarParts
	if type(slots) ~= "table" then
		return list
	end
	local groups = type(CarPartsData) == "table" and CarPartsData.Groups
	for slot, info in pairs(slots) do
		local group = type(groups) == "table" and groups[slot]
		local optional = type(group) == "table" and group.Optional == true
		if not optional and type(info) == "table" and info.Variant == "" then
			table.insert(list, slot)
		end
	end
	return list
end

local ExtractOrder = { "IntakeManifold", "ExhaustManifold", "Radiator", "Battery", "CylinderHead", "Transmission", "Engine" }
local ExtractRank = {}
for index, slot in ipairs(ExtractOrder) do
	ExtractRank[slot] = index
end

local Parts = {}

function Parts.Kind(slot)
	if slot == "Engine" then
		return "Engine"
	end
	local groups = type(CarPartsData) == "table" and CarPartsData.Groups
	local group = type(groups) == "table" and groups[slot]
	local partType = type(group) == "table" and group.Type
	if partType == "Mechanical" or partType == "Battery" or partType == "Washable" then
		return partType
	end
	if slot == "Battery" then
		return "Battery"
	end
	if slot == "Radiator" then
		return "Washable"
	end
	return nil
end

function Parts.Enabled(kind)
	if kind == "Battery" then
		return State.RepairBattery
	elseif kind == "Mechanical" then
		return State.RepairMechanical
	elseif kind == "Engine" then
		return State.RepairEngine
	elseif kind == "Washable" then
		return State.RepairRadiator
	end
	return false
end

function Parts.Worn(car)
	local list = {}
	local record = Car.Record(car)
	local slots = record and record.CarParts
	if type(slots) ~= "table" then
		return list
	end
	for slot, info in pairs(slots) do
		if type(info) == "table" and type(info.Variant) == "string" and info.Variant ~= "" then
			local wear = tonumber(info.Wear) or 0
			local kind = Parts.Kind(slot)
			if kind and wear > State.MinWear and Parts.Enabled(kind) then
				table.insert(list, { Slot = slot, Kind = kind, Wear = wear })
			end
		end
	end
	table.sort(list, function(a, b)
		return (ExtractRank[a.Slot] or 99) < (ExtractRank[b.Slot] or 99)
	end)
	return list
end

function Parts.Slot(item)
	local slot = item:GetAttribute("Slot")
	if type(slot) == "string" and slot ~= "" then
		return slot
	end
	local name = item:GetAttribute("CarPartName")
	if type(name) ~= "string" then
		return nil
	end
	if type(CarPartsData) == "table" and type(CarPartsData.GetVariant) == "function" then
		local ok, variant = pcall(CarPartsData.GetVariant, name)
		if ok and type(variant) == "table" and type(variant.Group) == "string" then
			return variant.Group
		end
	end
	return (string.match(name, "^([^:]+)"))
end

function Parts.Extracted(vehicleKey)
	local list = {}
	local folder = Workspace:FindFirstChild("ExtractedCarParts")
	if not folder then
		return list
	end
	for _, item in ipairs(folder:GetChildren()) do
		if item:GetAttribute("OwnerUserId") == LocalPlayer.UserId and Parts.Slot(item) ~= nil then
			local source = item:GetAttribute("SourceVehicleName")
			if vehicleKey == nil or source == nil or source == vehicleKey then
				table.insert(list, item)
			end
		end
	end
	return list
end

function Parts.FindExtracted(slot, vehicleKey)
	for _, item in ipairs(Parts.Extracted(vehicleKey)) do
		if Parts.Slot(item) == slot then
			return item
		end
	end
	return nil
end

function Parts.Body(target)
	if target:IsA("BasePart") then
		return target
	end
	if target:IsA("Model") then
		return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function Parts.Position(target)
	local body = Parts.Body(target)
	if body then
		return body.Position
	end
	if target:IsA("Model") then
		return target:GetPivot().Position
	end
	return nil
end

function Parts.Wear(target)
	return tonumber(target:GetAttribute("Wear")) or 0
end

local Carry = {
	Target = nil,
	Goal = nil,
	LastSend = 0,
}

table.insert(Hub.Connections, RunService.PostSimulation:Connect(function()
	local target = Carry.Target
	if not target then
		return
	end
	if not target.Parent or target:GetAttribute("DraggedByUserId") ~= LocalPlayer.UserId then
		return
	end
	local root = getRoot()
	if not root then
		return
	end
	local goal = Carry.Goal
	if typeof(goal) ~= "Vector3" then
		goal = root.Position + unit(flat(root.CFrame.LookVector)) * 4.5 + Vector3.new(0, Carry.Height or 1.5, 0)
	end
	local body = Parts.Body(target)
	local align = body and body:FindFirstChildOfClass("AlignPosition")
	if align then
		align.Position = goal
	end
	local now = os.clock()
	if now - Carry.LastSend >= 1 / 30 then
		Carry.LastSend = now
		pcall(Net.DragPositionUpdated.Fire, goal.X, goal.Y, goal.Z)
	end
end))

function Parts.Grab(target)
	if target:GetAttribute("DraggedByUserId") == LocalPlayer.UserId then
		Carry.Target = target
		Carry.Goal = nil
		return true
	end
	for _ = 1, 3 do
		checkpoint()
		if not target.Parent or target:GetAttribute("InMachine") == true then
			return false
		end
		Hub.Fire(Net.DragGrabRequested, target)
		local grabbed = waitFor(function()
			local body = Parts.Body(target)
			return target:GetAttribute("DraggedByUserId") == LocalPlayer.UserId and body ~= nil and body:FindFirstChildOfClass("AlignPosition") ~= nil
		end, 2)
		if grabbed then
			Carry.Target = target
			Carry.Goal = nil
			return true
		end
		sleep(0.3)
	end
	return false
end

function Parts.Release()
	Carry.Target = nil
	Carry.Goal = nil
	Hub.Fire(Net.DragReleaseRequested)
end

local Machines = {}

local MachineTags = {
	Battery = MachineCatalog.BatteryCharger and MachineCatalog.BatteryCharger.Tag or "BATTERY_CHARGER",
	Mechanical = MachineCatalog.GrindingMachine and MachineCatalog.GrindingMachine.Tag or "GRINDING_MACHINE",
	Engine = MachineCatalog.Hoist and MachineCatalog.Hoist.Tag or "HOIST_MACHINE",
	Washable = MachineCatalog.Sink and MachineCatalog.Sink.Tag or "SINK",
}

local MachineSpots = {
	Battery = MachineCatalog.BatteryCharger and MachineCatalog.BatteryCharger.PositionTag or "BatteryChargerPos",
	Mechanical = MachineCatalog.GrindingMachine and MachineCatalog.GrindingMachine.PositionTag or "GRINDING_VISUALS",
	Washable = MachineCatalog.Sink and MachineCatalog.Sink.PositionTag or "WATER_VISUALS",
}

local MachineTimeouts = {
	Battery = 35,
	Mechanical = 45,
	Engine = 50,
	Washable = 40,
}

local LiftTag = MachineCatalog.Hydraulics and MachineCatalog.Hydraulics.Tag or "HYDRAULICS"

function Machines.Zone(machine, kind)
	local hitbox = machine:FindFirstChild("Hitbox", true)
	if hitbox and hitbox:IsA("BasePart") then
		return hitbox.Position
	end
	local pivot = machine:GetPivot().Position
	local tag = MachineSpots[kind]
	if tag then
		local best, bestDistance
		for _, item in ipairs(CollectionService:GetTagged(tag)) do
			local position
			if item:IsA("Attachment") then
				position = item.WorldPosition
			elseif item:IsA("BasePart") then
				position = item.Position
			end
			if position then
				local distance = (position - pivot).Magnitude
				if distance < 10 and (not bestDistance or distance < bestDistance) then
					best, bestDistance = position, distance
				end
			end
		end
		if best then
			return best + Vector3.new(0, 0.8, 0)
		end
	end
	return pivot + Vector3.new(0, 1.5, 0)
end

function Machines.Find(kind, near, reserved)
	local tag = MachineTags[kind]
	if not tag then
		return nil
	end
	local best, bestDistance
	for _, machine in ipairs(CollectionService:GetTagged(tag)) do
		if machine:IsA("Model") and machine:IsDescendantOf(Workspace) and not reserved[machine] and machine:GetAttribute("Occupied") ~= true then
			local position = Machines.Zone(machine, kind)
			if position.Y > -40 then
				local distance = (position - near).Magnitude
				if distance < 160 and (not bestDistance or distance < bestDistance) then
					best, bestDistance = machine, distance
				end
			end
		end
	end
	return best
end

function Machines.LiftBusy(lift, myCar)
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if not vehicles then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { vehicles }
	local parts = Workspace:GetPartBoundsInBox(lift:GetPivot(), Vector3.new(9, 14, 9), params)
	for _, part in ipairs(parts) do
		if not (myCar and part:IsDescendantOf(myCar)) then
			return true
		end
	end
	return false
end

function Machines.FindLift(near, myCar)
	local best, bestDistance
	for _, lift in ipairs(CollectionService:GetTagged(LiftTag)) do
		if lift:IsA("Model") and lift:IsDescendantOf(Workspace) then
			local position = lift:GetPivot().Position
			if position.Y > 0 and (flat(position) - flat(Places.Workshop)).Magnitude < 150 then
				local blocked = lift:GetAttribute("BlockedByUserId")
				local free = lift:GetAttribute("Occupied") ~= true and (blocked == nil or blocked == LocalPlayer.UserId)
				if free and not Machines.LiftBusy(lift, myCar) then
					local distance = (position - near).Magnitude
					if not bestDistance or distance < bestDistance then
						best, bestDistance = lift, distance
					end
				end
			end
		end
	end
	return best
end

function Machines.LiftLayout(lift)
	local pivot = lift:GetPivot()
	local exclude = { LocalPlayer.Character, Workspace:FindFirstChild("Vehicles"), Workspace:FindFirstChild("ExtractedCarParts") }
	local floor = raycast(pivot.Position + Vector3.new(0, 2, 0), Vector3.new(0, -20, 0), exclude)
	local floorY = floor and floor.Position.Y or (pivot.Position.Y - 6)
	local center = Vector3.new(pivot.Position.X, floorY, pivot.Position.Z)
	local look = unit(flat(pivot.LookVector), Vector3.new(0, 0, -1))
	local across = Vector3.new(-look.Z, 0, look.X)
	local origin = center + Vector3.new(0, 2.5, 0)
	local hitA = raycast(origin, across * 40, exclude)
	local hitB = raycast(origin, -across * 40, exclude)
	local freeA = hitA and hitA.Distance or 40
	local freeB = hitB and hitB.Distance or 40
	local entrance = freeA >= freeB and across or -across
	return center, entrance
end

local Move = {}
local Travel = { Last = nil }

local function ownsPart(part)
	if type(isnetworkowner) ~= "function" or not part then
		return true
	end
	local ok, result = pcall(isnetworkowner, part)
	return not ok or result == true
end


function Move.Stream(position)
	pcall(function()
		LocalPlayer:RequestStreamAroundAsync(position, 2)
	end)
end

function Move.Path(from, to, radius, walking)
	local path = PathfindingService:CreatePath({
		AgentRadius = radius,
		AgentHeight = walking and 5 or 6,
		AgentCanJump = walking == true,
		AgentCanClimb = false,
		WaypointSpacing = walking and 4 or 10,
	})
	local ok = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		local waypoints = path:GetWaypoints()
		if #waypoints >= 2 then
			return waypoints
		end
	end
	return nil
end

function Move.Distance(goal)
	local root = getRoot()
	if not root then
		return math.huge
	end
	return (flat(root.Position) - flat(goal)).Magnitude
end

local Pace = {
	HopRange = 80,
	Limit = 200,
	Recover = 16,
	Debt = 0,
	Stamp = os.clock(),
	Penalty = 0,
	Resets = 0,
	Sprinting = false,
}

function Pace.Settle()
	local now = os.clock()
	Pace.Debt = math.max(0, Pace.Debt - (now - Pace.Stamp) * Pace.Recover)
	Pace.Stamp = now
	return Pace.Debt
end

function Pace.Allows(distance)
	return os.clock() > Pace.Penalty and Pace.Settle() + distance <= Pace.Limit
end

function Move.Sprint(on)
	on = on == true
	if Pace.Sprinting == on then
		return
	end
	Pace.Sprinting = on
	Hub.Fire(Net.StaminaSprintToggled, on)
end

function Move.Unseat()
	local humanoid = getHumanoid()
	if not (humanoid and humanoid.SeatPart) then
		return true
	end
	local seat = humanoid.SeatPart
	local vehicle = seat:FindFirstAncestorOfClass("Model")
	while vehicle and vehicle.Parent and vehicle.Parent ~= Workspace:FindFirstChild("Vehicles") do
		vehicle = vehicle.Parent:FindFirstAncestorOfClass("Model")
	end
	if vehicle then
		Move.ExitCar(vehicle)
	else
		humanoid.Sit = false
		sleep(0.6)
	end
	return humanoid.SeatPart == nil
end

function Move.Fly(goal, tolerance, speed)
	local character = LocalPlayer.Character
	local root, humanoid = getRoot(), getHumanoid()
	if not (character and root and humanoid) then
		return false
	end
	if not Move.Unseat() then
		return false
	end
	tolerance = tolerance or 2
	local stopDistance = tolerance > 3 and (tolerance - 1.5) or 0.3
	if Move.Distance(goal) <= stopDistance then
		return true
	end
	speed = speed or State.GlideSpeed
	if Carry.Target then
		speed = math.min(speed, 90)
	end
	local saved, touch = {}, {}
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			saved[part] = part.CanCollide
			touch[part] = part.CanTouch
			part.CanCollide = false
			part.CanTouch = false
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, Workspace:FindFirstChild("Vehicles"), Workspace:FindFirstChild("ExtractedCarParts") }
	params.RespectCanCollide = true
	local floor = Workspace:Raycast(root.Position, Vector3.new(0, -12, 0), params)
	local hip = floor and (root.Position.Y - floor.Position.Y) or 3
	if hip < 2 or hip > 5 then
		hip = 3
	end
	local origin = root.Position
	local commanded = origin
	local lastY = commanded.Y
	local finished, reset = false, false
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if not Hub.Running or Job.Cancel or not root.Parent or humanoid.SeatPart then
			finished = true
			connection:Disconnect()
			return
		end
		dt = math.max(dt, 1 / 240)
		if (flat(root.Position) - flat(commanded)).Magnitude > speed * dt * 1.5 + 6 then
			Pace.Last = string.format("%s %s | flew %.0f/%.0f | jumped %.0f | anchored %s", os.date("%H:%M:%S"), Status.Text .. (Status.Detail ~= "" and (" - " .. Status.Detail) or ""), (flat(commanded) - flat(origin)).Magnitude, (flat(goal) - flat(origin)).Magnitude, (flat(root.Position) - flat(commanded)).Magnitude, tostring(root.Anchored))
			reset = true
			finished = true
			connection:Disconnect()
			return
		end
		local delta = flat(goal - commanded)
		local distance = delta.Magnitude
		if distance <= stopDistance then
			root.CFrame = CFrame.new(commanded) * root.CFrame.Rotation
			root.AssemblyLinearVelocity = Vector3.zero
			finished = true
			connection:Disconnect()
			return
		end
		local direction = delta.Unit
		local nextPosition = commanded + direction * math.min(speed * dt, distance)
		local hit = Workspace:Raycast(Vector3.new(nextPosition.X, lastY + 4, nextPosition.Z), Vector3.new(0, -14, 0), params)
		if hit then
			local candidate = hit.Position.Y + hip
			if math.abs(candidate - lastY) < 3 then
				lastY = candidate
			end
		end
		commanded = Vector3.new(nextPosition.X, lastY, nextPosition.Z)
		root.CFrame = CFrame.lookAt(commanded, commanded + direction)
		root.AssemblyLinearVelocity = direction * speed
	end)
	table.insert(Hub.Connections, connection)
	local deadline = os.clock() + 4 + Move.Distance(goal) / math.max(speed, 1) * 2
	while not finished and os.clock() < deadline do
		task.wait(0.03)
	end
	if connection.Connected then
		connection:Disconnect()
	end
	for part, value in pairs(saved) do
		if part.Parent then
			part.CanCollide = value
		end
	end
	root.AssemblyLinearVelocity = Vector3.zero
	task.delay(0.5, function()
		for part, value in pairs(touch) do
			if part.Parent then
				part.CanTouch = value
			end
		end
	end)
	Pace.Settle()
	Pace.Debt = Pace.Debt + (flat(commanded) - flat(origin)).Magnitude
	if reset then
		Pace.Resets = Pace.Resets + 1
		Pace.Penalty = os.clock() + 120
		Pace.Debt = Pace.Limit
		sleep(0.5)
		return false
	end
	if Carry.Target then
		sleep(0.1)
	elseif (flat(commanded) - flat(origin)).Magnitude < 25 then
		sleep(0.2)
	else
		sleep(0.4)
	end
	return Move.Distance(goal) <= math.max(tolerance, stopDistance + 0.5)
end

function Move.Run(goal, tolerance, timeout)
	tolerance = tolerance or 3
	local deadline = os.clock() + (timeout or 45)
	if not Move.Unseat() then
		return false
	end
	local humanoid
	Move.Sprint(true)
	local ok, result = pcall(function()
		local failures = 0
		while os.clock() < deadline do
			checkpoint()
			local root
			humanoid, root = getHumanoid(), getRoot()
			if not (humanoid and root) then
				sleep(0.5)
			elseif humanoid.SeatPart then
				return false
			else
				if Move.Distance(goal) <= tolerance then
					return true
				end
				local waypoints = Move.Path(root.Position, goal, 2, true) or {
					{ Position = root.Position, Action = Enum.PathWaypointAction.Walk },
					{ Position = goal, Action = Enum.PathWaypointAction.Walk },
				}
				local moved = 0
				local stuck = false
				for index = 2, #waypoints do
					local waypoint = waypoints[index]
					if waypoint.Action == Enum.PathWaypointAction.Jump then
						humanoid.Jump = true
					end
					humanoid:MoveTo(waypoint.Position)
					local last, lastMove = root.Position, os.clock()
					while (flat(root.Position) - flat(waypoint.Position)).Magnitude > 2 do
						checkpoint()
						if Move.Distance(goal) <= tolerance then
							return true
						end
						if os.clock() > deadline or humanoid.SeatPart then
							return Move.Distance(goal) <= tolerance
						end
						local step = (root.Position - last).Magnitude
						if step > 1 then
							moved = moved + step
							last, lastMove = root.Position, os.clock()
						elseif os.clock() - lastMove > 0.7 then
							humanoid.Jump = true
							if os.clock() - lastMove > 2 then
								stuck = true
								break
							end
						end
						task.wait(0.05)
					end
					if stuck then
						break
					end
				end
				if Move.Distance(goal) <= tolerance then
					return true
				end
				if moved < 4 then
					failures = failures + 1
					if failures >= 4 then
						return false
					end
					local direction = unit(flat(goal - root.Position))
					if Pace.Allows(8) then
						Move.Fly(root.Position + direction * math.min(8, Move.Distance(goal)), 1.5, 40)
					else
						humanoid.Jump = true
						humanoid:MoveTo(root.Position - direction * 4 + Vector3.new(direction.Z, 0, -direction.X) * 4)
						task.wait(0.6)
					end
				end
			end
		end
		return Move.Distance(goal) <= tolerance
	end)
	Move.Sprint(false)
	local stopHumanoid, stopRoot = getHumanoid(), getRoot()
	if stopHumanoid and stopRoot then
		stopHumanoid:MoveTo(stopRoot.Position)
	end
	if not ok then
		error(result, 0)
	end
	return result == true
end

function Move.WalkTo(goal, tolerance, timeout)
	tolerance = tolerance or 3
	local distance = Move.Distance(goal)
	if State.PlayerTeleport and distance <= Pace.HopRange and Pace.Allows(distance) then
		if Move.Fly(goal, tolerance) then
			return true
		end
		if os.clock() > Pace.Penalty then
			return Move.Distance(goal) <= tolerance
		end
	end
	return Move.Run(goal, tolerance, timeout)
end

function Move.Hop(target)
	local root = getRoot()
	if not root then
		return
	end
	local delta = target - root.Position
	if delta.Magnitude > 14 then
		target = root.Position + delta.Unit * 14
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.new(target) * root.CFrame.Rotation
end

function Move.StopCar(car)
	local primary = car and car.PrimaryPart
	if primary then
		primary.AssemblyLinearVelocity = Vector3.new(0, math.min(primary.AssemblyLinearVelocity.Y, 0), 0)
		primary.AssemblyAngularVelocity = Vector3.zero
	end
end

function Move.Reverse(car, seconds)
	local primary = car.PrimaryPart
	local deadline = os.clock() + seconds
	while os.clock() < deadline and primary.Parent do
		checkpoint()
		local back = -Car.Forward(car)
		primary.AssemblyLinearVelocity = Vector3.new(back.X * 14, math.min(primary.AssemblyLinearVelocity.Y, 4), back.Z * 14)
		task.wait()
	end
	Move.StopCar(car)
end

local Roads = { Graph = nil, Edges = nil }

function Roads.Sample(a, b, link)
	local points = { a }
	if link.UseSpline == true and typeof(link.CP1) == "Vector3" and typeof(link.CP2) == "Vector3" then
		local p1, p2 = a + link.CP1, b + link.CP2
		local steps = math.max(4, math.ceil((tonumber(link.Length) or (b - a).Magnitude) / 6))
		for i = 1, steps - 1 do
			local t = i / steps
			local u = 1 - t
			table.insert(points, a * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + b * (t * t * t))
		end
	else
		local steps = math.max(1, math.floor((b - a).Magnitude / 10))
		for i = 1, steps - 1 do
			table.insert(points, a:Lerp(b, i / steps))
		end
	end
	table.insert(points, b)
	return points
end

function Roads.Load()
	if Roads.Graph then
		return Roads.Graph
	end
	if type(RoadData) ~= "table" then
		return nil
	end
	local graph, edges = {}, {}
	for id, info in pairs(RoadData) do
		if type(info) == "table" and typeof(info.Position) == "Vector3" then
			graph[id] = { Id = id, Position = info.Position, Links = {} }
		end
	end
	for id, info in pairs(RoadData) do
		local from = graph[id]
		if from and type(info.Connections) == "table" then
			for other, link in pairs(info.Connections) do
				local to = graph[other]
				if to and type(link) == "table" then
					local points = Roads.Sample(from.Position, to.Position, link)
					local length = 0
					for i = 2, #points do
						length = length + (points[i] - points[i - 1]).Magnitude
					end
					local edge = { From = id, To = other, Points = points, Length = length, Both = link.Direction ~= "forward" }
					table.insert(edges, edge)
					table.insert(from.Links, { To = other, Edge = edge, Reverse = false })
					if edge.Both then
						table.insert(to.Links, { To = id, Edge = edge, Reverse = true })
					end
				end
			end
		end
	end
	Roads.Graph, Roads.Edges = graph, edges
	return graph
end

local function segmentClosest(position, a, b)
	local ab = flat(b - a)
	local denominator = ab:Dot(ab)
	local t = 0
	if denominator > 0 then
		t = math.clamp(flat(position - a):Dot(ab) / denominator, 0, 1)
	end
	return a + (b - a) * t, t
end

function Roads.Project(position)
	local best
	for _, edge in ipairs(Roads.Edges or {}) do
		local points = edge.Points
		for i = 1, #points - 1 do
			local point, t = segmentClosest(position, points[i], points[i + 1])
			local score = (flat(point) - flat(position)).Magnitude + math.abs(point.Y - position.Y) * 3
			if not best or score < best.Score then
				best = { Edge = edge, Index = i, T = t, Point = point, Score = score }
			end
		end
	end
	return best
end

local function forwardPart(spot)
	local points = spot.Edge.Points
	local list = { spot.Point }
	local length = (points[spot.Index + 1] - spot.Point).Magnitude
	for i = spot.Index + 1, #points do
		table.insert(list, points[i])
		if i > spot.Index + 1 then
			length = length + (points[i] - points[i - 1]).Magnitude
		end
	end
	return list, length
end

local function backwardPart(spot)
	local points = spot.Edge.Points
	local list = { spot.Point }
	local length = (spot.Point - points[spot.Index]).Magnitude
	for i = spot.Index, 1, -1 do
		table.insert(list, points[i])
		if i < spot.Index then
			length = length + (points[i] - points[i + 1]).Magnitude
		end
	end
	return list, length
end

local function reversed(list)
	local result = {}
	for i = #list, 1, -1 do
		table.insert(result, list[i])
	end
	return result
end

local function appendPoints(target, source, skipFirst)
	for i = skipFirst and 2 or 1, #source do
		local point = source[i]
		local last = target[#target]
		if not last or (point - last).Magnitude > 0.5 then
			table.insert(target, point)
		end
	end
end

function Roads.Route(from, to)
	local graph = Roads.Load()
	if not graph then
		return nil
	end
	local startSpot = Roads.Project(from)
	local goalSpot = Roads.Project(to)
	if not startSpot or not goalSpot then
		return nil
	end
	if startSpot.Edge == goalSpot.Edge then
		local a = startSpot.Index + startSpot.T
		local b = goalSpot.Index + goalSpot.T
		if b >= a or startSpot.Edge.Both then
			local points = startSpot.Edge.Points
			local list = { startSpot.Point }
			if b >= a then
				for i = startSpot.Index + 1, goalSpot.Index do
					table.insert(list, points[i])
				end
			else
				for i = startSpot.Index, goalSpot.Index + 1, -1 do
					table.insert(list, points[i])
				end
			end
			table.insert(list, goalSpot.Point)
			return list, startSpot, goalSpot
		end
	end
	local distance, previous, entry, done = {}, {}, {}, {}
	local starts = {}
	local forwardList, forwardLength = forwardPart(startSpot)
	starts[startSpot.Edge.To] = { Points = forwardList, Length = forwardLength }
	if startSpot.Edge.Both then
		local backList, backLength = backwardPart(startSpot)
		local current = starts[startSpot.Edge.From]
		if not current or backLength < current.Length then
			starts[startSpot.Edge.From] = { Points = backList, Length = backLength }
		end
	end
	for id, start in pairs(starts) do
		distance[id] = start.Length
		previous[id] = false
	end
	while true do
		local node, best = nil, math.huge
		for id, value in pairs(distance) do
			if not done[id] and value < best then
				node, best = id, value
			end
		end
		if not node then
			break
		end
		done[node] = true
		for _, link in ipairs(graph[node].Links) do
			local cost = best + link.Edge.Length
			if not done[link.To] and (distance[link.To] == nil or cost < distance[link.To]) then
				distance[link.To] = cost
				previous[link.To] = node
				entry[link.To] = link
			end
		end
	end
	local goalPoints = goalSpot.Edge.Points
	local finish, finishTail, finishCost
	if distance[goalSpot.Edge.From] then
		local tail = {}
		for i = 1, goalSpot.Index do
			table.insert(tail, goalPoints[i])
		end
		table.insert(tail, goalSpot.Point)
		local length = 0
		for i = 2, #tail do
			length = length + (tail[i] - tail[i - 1]).Magnitude
		end
		finish, finishTail, finishCost = goalSpot.Edge.From, tail, distance[goalSpot.Edge.From] + length
	end
	if goalSpot.Edge.Both and distance[goalSpot.Edge.To] then
		local tail = {}
		for i = #goalPoints, goalSpot.Index + 1, -1 do
			table.insert(tail, goalPoints[i])
		end
		table.insert(tail, goalSpot.Point)
		local length = 0
		for i = 2, #tail do
			length = length + (tail[i] - tail[i - 1]).Magnitude
		end
		local cost = distance[goalSpot.Edge.To] + length
		if not finishCost or cost < finishCost then
			finish, finishTail, finishCost = goalSpot.Edge.To, tail, cost
		end
	end
	if not finish then
		return nil
	end
	local chain = {}
	local node = finish
	while node do
		table.insert(chain, 1, node)
		local before = previous[node]
		if before == false or before == nil then
			break
		end
		node = before
	end
	local list = {}
	appendPoints(list, starts[chain[1]].Points, false)
	for i = 2, #chain do
		local link = entry[chain[i]]
		local points = link.Reverse and reversed(link.Edge.Points) or link.Edge.Points
		appendPoints(list, points, true)
	end
	appendPoints(list, finishTail, true)
	return list, startSpot, goalSpot
end

function Move.Densify(points, spacing)
	local result = {}
	for i = 1, #points do
		local point = points[i]
		if i > 1 then
			local previousPoint = points[i - 1]
			local gap = (point - previousPoint).Magnitude
			local steps = math.floor(gap / spacing)
			for step = 1, steps - 1 do
				table.insert(result, previousPoint:Lerp(point, step / steps))
			end
		end
		table.insert(result, point)
	end
	return result
end

function Move.StartPoint(car, goal)
	local center = car:GetPivot().Position
	local forward = Car.Forward(car)
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local halfLength, halfWidth = Car.Size(car)
	local toGoal = unit(flat(goal - center), forward)
	local sides = {
		forward * (halfLength + 4),
		(right:Dot(toGoal) >= 0 and right or -right) * (halfWidth + 4),
		(right:Dot(toGoal) >= 0 and -right or right) * (halfWidth + 4),
		-forward * (halfLength + 4),
	}
	local exclude = { car, LocalPlayer.Character }
	local origin = center + Vector3.new(0, 1.5, 0)
	for _, offset in ipairs(sides) do
		if not raycast(origin, offset, exclude) then
			local ground = raycast(origin + offset + Vector3.new(0, 3, 0), Vector3.new(0, -14, 0), exclude)
			if ground then
				return Vector3.new(ground.Position.X, center.Y, ground.Position.Z)
			end
		end
	end
	return center + forward * (halfLength + 4)
end

function Move.CarPathPoints(car, from, to)
	local _, halfWidth = Car.Size(car)
	for _, radius in ipairs({ math.clamp(halfWidth + 1.5, 3, 6.5), math.clamp(halfWidth + 0.5, 2.5, 5), 2.5 }) do
		local waypoints = Move.Path(from, to, radius, false)
		if waypoints then
			local list = {}
			for _, waypoint in ipairs(waypoints) do
				table.insert(list, waypoint.Position)
			end
			return list
		end
	end
	return nil
end

function Move.Occupied(position, car)
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if not vehicles then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { vehicles }
	for _, part in ipairs(Workspace:GetPartBoundsInRadius(position + Vector3.new(0, 2, 0), 5, params)) do
		if not part:IsDescendantOf(car) then
			return true
		end
	end
	return false
end

function Move.ClearBlocked(car, points)
	local count = #points
	local cache = {}
	local function occupied(index)
		local value = cache[index]
		if value == nil then
			value = Move.Occupied(points[index], car)
			cache[index] = value
		end
		return value
	end
	local result = {}
	local i = 1
	local detours = 0
	while i <= count do
		if i > 2 and i < count - 1 and occupied(i) and detours < 6 then
			local j = i
			while j < count and occupied(j) do
				j = j + 1
			end
			local after = math.min(count, j + 2)
			for _ = 1, 2 do
				if #result > 2 then
					table.remove(result)
				end
			end
			local before = result[#result] or points[1]
			local detour = Move.CarPathPoints(car, before, points[after])
			detours = detours + 1
			if detour and #detour >= 2 then
				appendPoints(result, detour, true)
			else
				for k = i, after do
					table.insert(result, points[k])
				end
			end
			i = after + 1
		else
			table.insert(result, points[i])
			i = i + 1
		end
	end
	return result
end

function Move.Plan(car, goal)
	local position = car:GetPivot().Position
	local start = Move.StartPoint(car, goal)
	local points
	if (flat(goal) - flat(position)).Magnitude > 140 and Roads.Load() then
		local road = Roads.Route(start, goal)
		if road and #road >= 2 then
			points = { position }
			if (flat(road[1]) - flat(start)).Magnitude > 12 then
				appendPoints(points, Move.CarPathPoints(car, start, road[1]) or { start, road[1] }, false)
			else
				appendPoints(points, { start }, false)
			end
			appendPoints(points, road, false)
			if (flat(goal) - flat(road[#road])).Magnitude > 8 then
				appendPoints(points, Move.CarPathPoints(car, road[#road], goal) or { road[#road], goal }, true)
			else
				appendPoints(points, { goal }, false)
			end
		end
	end
	if not points then
		points = { position }
		appendPoints(points, Move.CarPathPoints(car, start, goal) or { start, goal }, false)
	end
	return Move.Densify(Move.ClearBlocked(car, Move.Densify(points, 5)), 5)
end

function Move.Obstacle(car, forward, speed)
	local pivot = car:GetPivot()
	local halfLength, halfWidth = Car.Size(car)
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local reach = math.clamp(speed * 0.45, 5, 26)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { car, LocalPlayer.Character }
	params.RespectCanCollide = true
	local nearest
	for _, side in ipairs({ -0.85, 0, 0.85 }) do
		local origin = pivot.Position + forward * (halfLength - 1) + right * (halfWidth * side) + Vector3.new(0, 1.2, 0)
		local hit = Workspace:Raycast(origin, forward * reach, params)
		if hit and hit.Normal.Y < 0.6 then
			nearest = math.min(nearest or math.huge, hit.Distance)
		end
	end
	return nearest
end

function Move.Track(car, points, options)
	options = options or {}
	local primary = car.PrimaryPart
	local maxSpeed = options.Speed or State.DriveSpeed
	local arrive = options.Arrive or 5
	local offset = options.Offset or 0
	local offsetUntil = options.OffsetUntil or 0
	local goal = points[#points]
	local cumulative = { 0 }
	for i = 2, #points do
		cumulative[i] = cumulative[i - 1] + (flat(points[i]) - flat(points[i - 1])).Magnitude
	end
	local position0 = car:GetPivot().Position
	local index, nearest = 1, math.huge
	for i = 1, #points do
		local gap = (flat(points[i]) - flat(position0)).Magnitude
		if gap < nearest then
			index, nearest = i, gap
		end
	end
	local speed = math.max(0, flat(primary.AssemblyLinearVelocity):Dot(Car.Forward(car)))
	local lastProgress, bestGap = os.clock(), math.huge
	local ownerCheck, unownedSince = 0, nil
	local blockedSince = nil
	local finished, result = false, nil
	local connection
	local function finish(value)
		if not finished then
			finished, result = true, value
			connection:Disconnect()
		end
	end
	connection = RunService.Heartbeat:Connect(function(dt)
		if not Hub.Running or Job.Cancel or not car.Parent or not primary.Parent then
			finish("gone")
			return
		end
		local humanoid = getHumanoid()
		if not (humanoid and humanoid.SeatPart and humanoid.SeatPart:IsDescendantOf(car)) then
			finish("unseated")
			return
		end
		if os.clock() - ownerCheck > 0.5 then
			ownerCheck = os.clock()
			if ownsPart(primary) then
				unownedSince = nil
			else
				unownedSince = unownedSince or os.clock()
				if os.clock() - unownedSince > 1 then
					finish("unowned")
					return
				end
			end
		end
		dt = math.max(dt, 1 / 240)
		local pivot = car:GetPivot()
		local position = pivot.Position
		local closest, closestGap = index, (flat(points[index]) - flat(position)).Magnitude
		for i = index + 1, math.min(#points, index + 20) do
			local gap = (flat(points[i]) - flat(position)).Magnitude
			if gap < closestGap then
				closest, closestGap = i, gap
			end
		end
		if closest > index then
			index = closest
			lastProgress = os.clock()
			bestGap = math.huge
		end
		local toGoal = (flat(goal) - flat(position)).Magnitude
		if toGoal <= arrive and index >= #points - 4 then
			finish("arrived")
			return
		end
		local look = math.clamp(speed * 0.35, 6, 18)
		local targetIndex = index
		while targetIndex < #points and cumulative[targetIndex] - cumulative[index] < look do
			targetIndex = targetIndex + 1
		end
		local target = points[targetIndex]
		local forward = Car.Forward(car)
		if offset ~= 0 and cumulative[targetIndex] < offsetUntil then
			local segment = unit(flat(points[math.min(targetIndex + 1, #points)] - points[math.max(targetIndex - 1, 1)]), forward)
			target = target + Vector3.new(-segment.Z, 0, segment.X) * offset
		end
		local desired = unit(flat(target - position), forward)
		local angle = math.atan2(forward:Cross(desired).Y, forward:Dot(desired))
		local sharp = math.abs(angle)
		local scan = cumulative[index] + 12 + speed * 0.8
		local i = index
		while i < #points - 1 and cumulative[i] < scan do
			local direction = flat(points[i + 1] - points[i])
			if direction.Magnitude > 0.1 then
				local turnAhead = math.acos(math.clamp(direction.Unit:Dot(desired), -1, 1))
				if turnAhead > sharp then
					sharp = turnAhead
				end
			end
			i = i + 1
		end
		local limit = maxSpeed
		if sharp > math.rad(20) then
			limit = math.min(limit, maxSpeed * math.clamp(1 - (sharp - math.rad(20)) / math.rad(80), 0.2, 1))
		end
		limit = math.min(limit, math.max(7, toGoal * 1.4))
		if math.abs(angle) > math.rad(55) then
			limit = math.min(limit, 5)
		end
		local blocked = Move.Obstacle(car, forward, speed)
		if blocked and blocked > toGoal - 1 then
			blocked = nil
		end
		if blocked then
			limit = math.min(limit, math.max(0, blocked - 3) * 1.8)
			if blocked < 6 and speed < 2 then
				blockedSince = blockedSince or os.clock()
				if os.clock() - blockedSince > 1 then
					finish("blocked")
					return
				end
			else
				blockedSince = nil
			end
		else
			blockedSince = nil
		end
		if speed < limit then
			speed = math.min(limit, speed + 40 * dt)
		else
			speed = math.max(limit, speed - 90 * dt)
		end
		local maxTurn = math.rad(speed < 12 and 150 or 100) * dt
		local turn = math.clamp(angle, -maxTurn, maxTurn)
		local rotation = CFrame.Angles(0, turn, 0)
		car:PivotTo(CFrame.new(position) * rotation * pivot.Rotation)
		local heading = rotation:VectorToWorldSpace(forward)
		local velocity = primary.AssemblyLinearVelocity
		primary.AssemblyLinearVelocity = Vector3.new(heading.X * speed, math.min(velocity.Y, 4), heading.Z * speed)
		primary.AssemblyAngularVelocity = Vector3.zero
		local nextGap = (flat(points[math.min(index + 1, #points)]) - flat(position)).Magnitude
		if nextGap < bestGap - 0.75 then
			bestGap = nextGap
			lastProgress = os.clock()
		elseif os.clock() - lastProgress > 2.2 then
			finish("stuck")
		end
	end)
	table.insert(Hub.Connections, connection)
	while not finished do
		task.wait(0.05)
	end
	return result, index
end

function Move.Detour(car, points, index)
	local cumulative = { [index] = 0 }
	for i = index + 1, #points do
		cumulative[i] = cumulative[i - 1] + (flat(points[i]) - flat(points[i - 1])).Magnitude
	end
	for candidate = index + 1, #points do
		local ahead = cumulative[candidate]
		if ahead > 90 then
			break
		end
		if ahead >= 25 and (candidate == #points or ahead % 10 < 5) and not Move.Occupied(points[candidate], car) then
			local from = Move.StartPoint(car, points[candidate])
			local path = Move.CarPathPoints(car, from, points[candidate])
			if path and #path >= 2 then
				local list = { car:GetPivot().Position }
				appendPoints(list, path, false)
				for i = candidate + 1, #points do
					table.insert(list, points[i])
				end
				return Move.Densify(list, 5)
			end
		end
	end
	return nil
end

function Move.Glide(car, goal, finalForward, speed)
	speed = speed or State.GlideSpeed
	local primary = car.PrimaryPart
	if not primary then
		return false, "no car"
	end
	if not Move.EnterCar(car) then
		return false, "unseated"
	end
	Move.Stream(goal)
	local bounds, size = car:GetBoundingBox()
	local bottomOffset = car:GetPivot().Position.Y - (bounds.Position.Y - size.Y / 2)
	local saved = {}
	for _, root in ipairs({ car, LocalPlayer.Character }) do
		if root then
			for _, item in ipairs(root:GetDescendants()) do
				if item:IsA("BasePart") then
					saved[item] = item.CanCollide
					item.CanCollide = false
				end
			end
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { car, LocalPlayer.Character, Workspace:FindFirstChild("Vehicles"), Workspace:FindFirstChild("ExtractedCarParts") }
	params.RespectCanCollide = true
	local finalDirection = finalForward and unit(flat(finalForward)) or nil
	local lastY = car:GetPivot().Position.Y
	local finished, result = false, nil
	local ownerCheck, unownedSince = 0, nil
	local connection
	local function finish(value)
		if not finished then
			finished, result = true, value
			connection:Disconnect()
			primary.AssemblyLinearVelocity = Vector3.zero
			primary.AssemblyAngularVelocity = Vector3.zero
		end
	end
	local function groundAtPoint(point)
		local hit = Workspace:Raycast(Vector3.new(point.X, lastY + 6, point.Z), Vector3.new(0, -24, 0), params)
		if hit then
			local candidate = hit.Position.Y + bottomOffset + 0.3
			if math.abs(candidate - lastY) < 4 then
				return candidate
			end
		end
		return lastY
	end
	connection = RunService.Heartbeat:Connect(function(dt)
		if not Hub.Running or Job.Cancel or not car.Parent or not primary.Parent then
			finish("gone")
			return
		end
		local humanoid = getHumanoid()
		if not (humanoid and humanoid.SeatPart and humanoid.SeatPart:IsDescendantOf(car)) then
			finish("unseated")
			return
		end
		if os.clock() - ownerCheck > 0.5 then
			ownerCheck = os.clock()
			if ownsPart(primary) then
				unownedSince = nil
			else
				unownedSince = unownedSince or os.clock()
				if os.clock() - unownedSince > 1 then
					finish("unowned")
					return
				end
			end
		end
		dt = math.max(dt, 1 / 240)
		local pivot = car:GetPivot()
		local position = pivot.Position
		local delta = flat(goal - position)
		local forward = Car.Forward(car)
		if delta.Magnitude <= speed * dt + 0.5 then
			local y = groundAtPoint(goal)
			local facing = finalDirection or forward
			local angle = math.atan2(forward:Cross(facing).Y, forward:Dot(facing))
			car:PivotTo(CFrame.new(goal.X, y, goal.Z) * CFrame.Angles(0, angle, 0) * pivot.Rotation)
			finish("arrived")
			return
		end
		local direction = delta.Unit
		local nextPosition = position + direction * (speed * dt)
		local y = groundAtPoint(nextPosition)
		lastY = y
		local facing = direction
		if finalDirection and delta.Magnitude < 25 then
			facing = finalDirection
		end
		local angle = math.atan2(forward:Cross(facing).Y, forward:Dot(facing))
		local turn = math.clamp(angle, -math.rad(540) * dt, math.rad(540) * dt)
		car:PivotTo(CFrame.new(nextPosition.X, y, nextPosition.Z) * CFrame.Angles(0, turn, 0) * pivot.Rotation)
		primary.AssemblyLinearVelocity = direction * speed
		primary.AssemblyAngularVelocity = Vector3.zero
	end)
	table.insert(Hub.Connections, connection)
	while not finished do
		task.wait(0.05)
	end
	task.wait(0.1)
	for item, value in pairs(saved) do
		if item.Parent then
			item.CanCollide = value
		end
	end
	primary.AssemblyLinearVelocity = Vector3.zero
	primary.AssemblyAngularVelocity = Vector3.zero
	checkpoint()
	return result == "arrived", result
end

function Move.Drive(car, goal, speed, arrive, finalForward)
	if State.TravelMode == "Teleport" then
		local ok, reason = Move.Glide(car, goal, finalForward)
		if ok or reason == "gone" then
			return ok, reason
		end
		local again, why = Move.Glide(car, goal, finalForward)
		return again, why
	end
	speed = speed or State.DriveSpeed
	arrive = arrive or 6
	if not car.PrimaryPart then
		return false, "no car"
	end
	Move.Stream(goal)
	local points = Move.Plan(car, goal)
	local stuck = 0
	local offset = 0
	local offsetUntil = 0
	for _ = 1, 12 do
		checkpoint()
		if (flat(car:GetPivot().Position) - flat(goal)).Magnitude <= arrive then
			Move.StopCar(car)
			return true
		end
		local result, index = Move.Track(car, points, { Speed = speed, Arrive = arrive, Offset = offset, OffsetUntil = offsetUntil })
		checkpoint()
		if result == "arrived" then
			Move.StopCar(car)
			return true
		elseif result == "gone" then
			Move.StopCar(car)
			return false, result
		elseif result == "unseated" or result == "unowned" then
			Move.StopCar(car)
			if not Move.EnterCar(car) then
				return false, result
			end
		else
			stuck = stuck + 1
			Move.StopCar(car)
			Move.Reverse(car, 0.6)
			local detour = stuck <= 4 and Move.Detour(car, points, index or 1)
			if detour then
				points = detour
				offset = 0
			elseif stuck >= 3 and stuck % 3 == 0 then
				points = Move.Plan(car, goal)
				offset = 0
			else
				offset = stuck % 2 == 1 and 5 or -5
				local cumulative = 0
				for i = 2, math.min(index or 1, #points) do
					cumulative = cumulative + (flat(points[i]) - flat(points[i - 1])).Magnitude
				end
				offsetUntil = cumulative + 35
			end
			if stuck >= 7 then
				break
			end
		end
	end
	Move.StopCar(car)
	return false, "stuck"
end

function Move.Park(car, target, forward, speed, tolerance, timeout)
	forward = unit(flat(forward))
	local primary = car.PrimaryPart
	local finished = false
	local started = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if not Hub.Running or Job.Cancel or not car.Parent or not primary.Parent then
			connection:Disconnect()
			finished = true
			return
		end
		local pivot = car:GetPivot()
		local position = pivot.Position
		local delta = flat(target - position)
		local current = Car.Forward(car)
		local angle = math.atan2(current:Cross(forward).Y, current:Dot(forward))
		if (delta.Magnitude < (tolerance or 0.5) and math.abs(angle) < math.rad(tolerance and 6 or 1.5)) or os.clock() - started > (timeout or 12) then
			Move.StopCar(car)
			connection:Disconnect()
			finished = true
			return
		end
		local maxTurn = math.rad(150) * math.max(dt, 1 / 60)
		local turn = math.clamp(angle, -maxTurn, maxTurn)
		car:PivotTo(CFrame.new(position) * CFrame.Angles(0, turn, 0) * pivot.Rotation)
		local pace = math.abs(angle) > math.rad(10) and 0 or math.min(speed or 12, delta.Magnitude * 3)
		local velocity = delta.Magnitude > 0.05 and delta.Unit * pace or Vector3.zero
		primary.AssemblyLinearVelocity = Vector3.new(velocity.X, math.min(primary.AssemblyLinearVelocity.Y, 3), velocity.Z)
		primary.AssemblyAngularVelocity = Vector3.zero
	end)
	table.insert(Hub.Connections, connection)
	while not finished do
		task.wait(0.05)
	end
	checkpoint()
	return (flat(car:GetPivot().Position) - flat(target)).Magnitude
end

