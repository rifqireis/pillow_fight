-- @ScriptType: LocalScript
-- MatchUIVisibilityClient.lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")

-- MatchLockEvent = true sejak ArenaService.startMatch() sampai match beneran
-- kelar/batal (endMatch/abortMatch) -- mencakup SEMUA ronde + jeda transisi
-- + countdown di antaranya. Ini satu-satunya sinyal yang benar buat "lagi di
-- dalam match", jadi dipakai sebagai sumber kebenaran tunggal untuk hide UI
-- selama match, menggantikan kombinasi isPlaying/isMatched/isWaitingRound
-- yang sebelumnya gampang ke-reset keliru oleh SyncMatchStateEvent(false)
-- yang ditembak ulang di SETIAP awal ronde (lihat ArenaService.resetPlayerStats).
local MatchLockEvent = remotes:WaitForChild("MatchLockEvent")

local isInMatch = false
local isOnPad = false

local function getShopUI()
	return playerGui:FindFirstChild("PlayerGui") or playerGui:WaitForChild("PlayerGui", 5)
end

local function setShopUIEnabled(enabled)
	local ui = getShopUI()
	if ui then
		ui.Enabled = enabled
	end
end

local function setCoreUIEnabled(enabled)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, enabled)
	end)
	pcall(function()
		StarterGui:SetCore("TopbarEnabled", enabled)
	end)
end

local function refreshVisibility()
	local shouldHide = isInMatch or isOnPad
	setShopUIEnabled(not shouldHide)
	setCoreUIEnabled(not shouldHide)
end

refreshVisibility()

playerGui.ChildAdded:Connect(function(child)
	if child.Name == "PlayerGui" and child:IsA("ScreenGui") then
		child.Enabled = not (isInMatch or isOnPad)
	end
end)

-- Sumber kebenaran tunggal: nyala true dari awal match sampai match beneran
-- selesai/batal, mencakup semua ronde + countdown antar ronde.
MatchLockEvent.OnClientEvent:Connect(function(locked)
	isInMatch = locked == true
	refreshVisibility()
end)

-- Tetap hide UI begitu pemain berdiri di pad antrean (sebelum MatchLockEvent
-- nyala), supaya lobby juga bersih pas lagi nunggu matchmaking di pad.
local WAIT_TIMEOUT = 10
local touchedPadsCount = 0
local registeredTeleporters = {}

local function getPlayerFromHit(hit)
	if not hit or not hit.Parent then
		return nil
	end
	return Players:GetPlayerFromCharacter(hit.Parent)
end

local function onPadTouched(hit)
	if getPlayerFromHit(hit) ~= player then
		return
	end
	touchedPadsCount += 1
	if not isOnPad then
		isOnPad = true
		refreshVisibility()
	end
end

local function onPadTouchEnded(hit)
	if getPlayerFromHit(hit) ~= player then
		return
	end
	touchedPadsCount = math.max(0, touchedPadsCount - 1)
	task.delay(0.15, function()
		if touchedPadsCount <= 0 then
			isOnPad = false
			refreshVisibility()
		end
	end)
end

local function registerArenaTeleporter(arenaFolder)
	if not arenaFolder:IsA("Folder") then
		return
	end
	task.spawn(function()
		local teleporter = arenaFolder:WaitForChild("Teleporter", WAIT_TIMEOUT)
		if not teleporter or registeredTeleporters[teleporter] then
			return
		end
		registeredTeleporters[teleporter] = true
		teleporter.Touched:Connect(onPadTouched)
		teleporter.TouchEnded:Connect(onPadTouchEnded)
	end)
	arenaFolder.AncestryChanged:Connect(function(_, parent)
		if not parent then
			local teleporter = arenaFolder:FindFirstChild("Teleporter")
			if teleporter then
				registeredTeleporters[teleporter] = nil
			end
		end
	end)
end

task.spawn(function()
	local Workspace = game:GetService("Workspace")
	local pillowArena = Workspace
		:WaitForChild("World", WAIT_TIMEOUT)
		:WaitForChild("Environment", WAIT_TIMEOUT)
		:WaitForChild("PillowArena", WAIT_TIMEOUT)
	pillowArena.ChildAdded:Connect(registerArenaTeleporter)
	for _, child in ipairs(pillowArena:GetChildren()) do
		registerArenaTeleporter(child)
	end
end)

player.CharacterAdded:Connect(function()
	touchedPadsCount = 0
	isOnPad = false
	refreshVisibility()
end)

print("[MatchUIVisibilityClient] Ready")