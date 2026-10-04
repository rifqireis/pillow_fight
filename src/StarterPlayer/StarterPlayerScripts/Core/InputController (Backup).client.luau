-- @ScriptType: LocalScript
--[[
    Nama File  : InputController
    Layer      : Client (Input)
    Deskripsi  : Mendengarkan input player, kirim ke server,
                 dan mainkan animasi sesuai hasil dari server.
    Penulis    : Yusuf Ahayy
    Tanggal    : 26 Juni 2026
    Versi      : 2.3
    Dependensi : - ReplicatedStorage > Remotes > AttackFiredEvent
                 - ReplicatedStorage > Remotes > AttackResultEvent
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local attackFiredEvent = Remotes:WaitForChild("AttackFiredEvent")
local syncMatchStateEvent = Remotes:WaitForChild("SyncMatchStateEvent")
local GameplayConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("GameplayConfig"))

local PlayerModule = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
local Controls = PlayerModule:GetControls()

local isPlaying = false

syncMatchStateEvent.OnClientEvent:Connect(function(state)
	isPlaying = state
	if isPlaying then
		Controls:Disable()
	else
		Controls:Enable()
	end
end)

local lastUsed = {
	light = 0,
	heavy = 0,
	dodge = 0
}

local function canUse(actionType)
	local now = os.clock()
	if now - (lastUsed[actionType] or 0) >= (GameplayConfig.COOLDOWNS[actionType] or 0) then
		lastUsed[actionType] = now
		return true
	end
	return false
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if not isPlaying then return end

	if input.KeyCode == Enum.KeyCode.E then
		if canUse("light") then
			attackFiredEvent:FireServer("light")
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		if canUse("heavy") then
			attackFiredEvent:FireServer("heavy")
		end
	elseif input.KeyCode == Enum.KeyCode.Q then
		if canUse("dodge") then
			attackFiredEvent:FireServer("dodge")
		end
	end

end)

