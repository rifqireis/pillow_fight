-- @ScriptType: LocalScript
-- @ScriptType: LocalScript

--[[
    Nama File  : EnergyBarClient
    Layer      : Client (UI)
    Deskripsi  : Menerima nilai energi dari server lalu memperbarui
                 energy bar secara smooth dengan client-side prediction.
    Penulis    : Yusuf Ahayy
    Tanggal    : 25 Juni 2026
    Versi      : 1.0

    Dependensi :
        - ReplicatedStorage > Remotes > SyncEnergyEvent
        - ReplicatedStorage > Remotes > StunEvent
        - ReplicatedStorage > Configs > EnergyConfig
        - Script.Parent.Parent > Core > LocalAnimEvent
        - PlayerGui > BattleUI > HpLeft
]]


-- ================================================================
-- SERVICES
-- ================================================================

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")


-- ================================================================
-- REFERENCES
-- ================================================================

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("Remotes")

local syncEnergyEvent = remotes:WaitForChild("SyncEnergyEvent")
local stunEvent = remotes:WaitForChild("StunEvent")

local energyConfig = require(
	ReplicatedStorage
		:WaitForChild("Configs")
		:WaitForChild("EnergyConfig")
)

local coreFolder = script.Parent.Parent:WaitForChild("Core")
local localAnimEvent = coreFolder:WaitForChild("LocalAnimEvent")


-- ================================================================
-- UI REFERENCES
-- ================================================================

local battleUI = playerGui:WaitForChild("BattleUI")
local hpLeft = battleUI:WaitForChild("HpLeft")

local energyFrame = hpLeft:WaitForChild("EnergyFrame")
local energyFill = energyFrame:WaitForChild("EnergyFill")

local energyLabel = energyFrame:FindFirstChild("EnergyLabel")

local stunLabel =
	hpLeft:FindFirstChild("StunLabel")
	or energyFrame:FindFirstChild("StunLabel")


-- ================================================================
-- CONFIGURATION
-- ================================================================

local TWEEN_DURATION = 0.09

local NORMAL_COLOR = Color3.fromRGB(0, 120, 255)
local FLASH_COLOR = Color3.fromRGB(255, 255, 255)

local SHAKE_COUNT = 4
local SHAKE_OFFSET = 0.005
local SHAKE_STEP = 0.03
local FLASH_DURATION = 0.1
local STUN_DURATION = 1

local tweenInfo = TweenInfo.new(
	TWEEN_DURATION,
	Enum.EasingStyle.Quad,
	Enum.EasingDirection.Out
)


-- ================================================================
-- STATE
-- ================================================================

local activeTween = nil
local lastEnergy = energyConfig.MAX_ENERGY


-- ================================================================
-- HELPERS
-- ================================================================

local function cancelActiveTween()
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
end

local function setEnergyFill(ratio)
	energyFill.Size = UDim2.new(ratio, 0, 1, 0)
end

local function updateEnergyLabel(energy)
	if energyLabel then
		energyLabel.Text = math.floor(energy) .. "%"
	end
end


-- ================================================================
-- ENERGY DAMAGE EFFECT
-- ================================================================

local function flashEnergyBar()
	energyFill.BackgroundColor3 = FLASH_COLOR

	task.delay(FLASH_DURATION, function()
		if energyFill then
			energyFill.BackgroundColor3 = NORMAL_COLOR
		end
	end)
end

local function shakeEnergyBar()
	task.spawn(function()
		for _ = 1, SHAKE_COUNT do
			energyFrame.Rotation = 0.6
			task.wait(SHAKE_STEP)
			energyFrame.Rotation = -0.6
			task.wait(SHAKE_STEP)
		end
		energyFrame.Rotation = 0
	end)
end


-- ================================================================
-- UPDATE ENERGY BAR
-- ================================================================

local function updateEnergyBar(newEnergy)
	local ratio = math.clamp(
		newEnergy / energyConfig.MAX_ENERGY,
		0,
		1
	)

	cancelActiveTween()

	if newEnergy < lastEnergy then
		-- Energi turun: langsung update + flash + shake.
		setEnergyFill(ratio)
		flashEnergyBar()
		shakeEnergyBar()
	else
		-- Energi naik: gunakan tween agar terlihat smooth.
		activeTween = TweenService:Create(
			energyFill,
			tweenInfo,
			{
				Size = UDim2.new(ratio, 0, 1, 0)
			}
		)

		activeTween:Play()

		activeTween.Completed:Once(function()
			activeTween = nil
		end)
	end

	lastEnergy = newEnergy
	updateEnergyLabel(newEnergy)
end


-- ================================================================
-- CHARACTER RESET
-- ================================================================

local function onCharacterAdded()
	cancelActiveTween()

	setEnergyFill(1)

	lastEnergy = energyConfig.MAX_ENERGY

	if stunLabel then
		stunLabel.Visible = false
	end

	if energyLabel then
		energyLabel.Text = "100%"
	end

	energyFill.BackgroundColor3 = NORMAL_COLOR
end

player.CharacterAdded:Connect(onCharacterAdded)

if player.Character then
	onCharacterAdded()
end


-- ================================================================
-- SERVER ENERGY SYNC
-- ================================================================

syncEnergyEvent.OnClientEvent:Connect(function(newEnergy)
	updateEnergyBar(newEnergy)
end)


-- ================================================================
-- CLIENT-SIDE ENERGY PREDICTION
-- ================================================================

localAnimEvent.Event:Connect(function(actionType)
	local cost = 0

	if actionType == "light" then
		cost = energyConfig.COST_LIGHT or 20
	elseif actionType == "heavy" then
		cost = energyConfig.COST_HEAVY or 30
	elseif actionType == "dodge" then
		cost = energyConfig.COST_DODGE or 10
	end

	if cost > 0 then
		local predictedEnergy = math.max(
			energyConfig.MIN_ENERGY,
			lastEnergy - cost
		)

		updateEnergyBar(predictedEnergy)
	end
end)


-- ================================================================
-- STUN UI
-- ================================================================

stunEvent.OnClientEvent:Connect(function()
	if not stunLabel then
		return
	end

	stunLabel.Visible = true

	task.delay(STUN_DURATION, function()
		if stunLabel then
			stunLabel.Visible = false
		end
	end)
end)