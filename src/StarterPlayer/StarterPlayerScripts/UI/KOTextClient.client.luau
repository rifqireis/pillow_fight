-- @ScriptType: LocalScript
--[[
    Nama File  : KOTextClient
    Layer      : Client (UI)
    Deskripsi  : Menampilkan teks besar di tengah layar begitu ada pemain
                 kalah FFYL -- labelnya BUKAN cuma "K.O.!" tapi diundi acak
                 dari KOConfig.LABELS (diundi di SERVER, lihat ArenaService,
                 supaya kedua pemain lihat teks yang sama). Teks masuk pakai
                 spring fisik (skala + rotasi + jatuh dikit) -- bukan cuma
                 TweenService biasa -- supaya kurva kecepatannya kerasa
                 organik/smooth, dibungkus impact flash + micro-shake pas
                 landing biar kesan KO-nya berat. Total dari muncul sampai
                 hilang total dijaga di sekitar KOConfig.DISPLAY_DURATION
                 (default 2 detik).
    Dependensi : - ReplicatedStorage > Remotes > KOEvent
                 - ReplicatedStorage > Configs > KOConfig
]]

-- @ScriptType: LocalScript

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local KOConfig = require(
	ReplicatedStorage:WaitForChild("Configs"):WaitForChild("KOConfig")
)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local koEvent = ReplicatedStorage
	:WaitForChild("Remotes")
	:WaitForChild("KOEvent")

-- ================================================================
-- GUI SETUP
-- ================================================================

local screenGui = playerGui:FindFirstChild("KOTextGui")

if not screenGui then
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "KOTextGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 15
	screenGui.Parent = playerGui
end

local koFlash = screenGui:FindFirstChild("KOFlash")

if not koFlash then
	koFlash = Instance.new("Frame")
	koFlash.Name = "KOFlash"
	koFlash.AnchorPoint = Vector2.new(0.5, 0.5)
	koFlash.Position = UDim2.fromScale(0.5, 0.5)
	koFlash.Size = UDim2.fromScale(1, 1)
	koFlash.BackgroundColor3 = Color3.new(1, 1, 1)
	koFlash.BackgroundTransparency = 1
	koFlash.ZIndex = 1
	koFlash.Parent = screenGui
end

local koText = screenGui:FindFirstChild("KOText")

if not koText then
	koText = Instance.new("TextLabel")
	koText.Name = "KOText"
	koText.AnchorPoint = Vector2.new(0.5, 0.5)
	koText.Position = UDim2.fromScale(0.8, 0.46)
	koText.Size = UDim2.fromScale(0.34, 0.09)
	koText.BackgroundTransparency = 1
	koText.Font = Enum.Font.GothamBlack
	koText.TextScaled = true
	koText.TextColor3 = Color3.fromRGB(255, 60, 60)
	koText.TextTransparency = 1
	koText.ZIndex = 2
	koText.Visible = false
	koText.Parent = screenGui
end

local stroke = koText:FindFirstChildOfClass("UIStroke")

if not stroke then
	stroke = Instance.new("UIStroke")
	stroke.Parent = koText
end

stroke.Thickness = 4
stroke.Color = Color3.fromRGB(20, 0, 0)
stroke.Transparency = 1
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual

-- ================================================================
-- CONFIGURATION
-- ================================================================

local baseTextColor = koText.TextColor3
local basePosition = koText.Position
local baseSize = koText.Size

local ENTRANCE_STIFFNESS = 240
local ENTRANCE_DAMPING = 16
local ENTRANCE_SCALE_FROM = 0.5
local ENTRANCE_ROTATION_FROM = 22
local ENTRANCE_ROTATION_TO = 6
local ENTRANCE_SLIDE_FROM = 0.45
local ENTRANCE_DROP = -0.03
local ENTRANCE_SETTLE_EPS = 0.001
local ENTRANCE_MAX_TIME = 0.35

local FADE_IN_TIME = 0.06
local FLASH_IN_TIME = 0.04
local FLASH_OUT_TIME = 0.18
local FADE_TIME = 0.35

local SHAKE_MAGNITUDE = 5
local SHAKE_DURATION = 0.1
local SHAKE_STEP = 1 / 30

local ESTIMATED_ENTRANCE_TIME = 0.22
local displayDuration = KOConfig.DISPLAY_DURATION or 2

local holdTime = math.max(
	0,
	displayDuration
	- ESTIMATED_ENTRANCE_TIME
	- SHAKE_DURATION
	- FADE_TIME
)

-- ================================================================
-- ENTRANCE SPRING
-- ================================================================

local function scaledSize(factor)
	return UDim2.new(
		baseSize.X.Scale * factor,
		baseSize.X.Offset * factor,
		baseSize.Y.Scale * factor,
		baseSize.Y.Offset * factor
	)
end

local function runEntranceSpring(tiltSign)
	local scaleValue = ENTRANCE_SCALE_FROM
	local scaleVelocity = 0

	local rotationTarget = ENTRANCE_ROTATION_TO * tiltSign
	local rotationValue = ENTRANCE_ROTATION_FROM * tiltSign
	local rotationVelocity = 0

	local dropValue = ENTRANCE_DROP
	local dropVelocity = 0

	local slideValue = ENTRANCE_SLIDE_FROM
	local slideVelocity = 0

	local elapsed = 0

	while elapsed < ENTRANCE_MAX_TIME do
		local deltaTime = RunService.Heartbeat:Wait()
		elapsed += deltaTime

		local remaining = math.min(deltaTime, 0.1)

		while remaining > 0 do
			local step = math.min(remaining, 1 / 120)
			remaining -= step

			scaleVelocity += (
				-ENTRANCE_STIFFNESS * (scaleValue - 1)
				- ENTRANCE_DAMPING * scaleVelocity
			) * step

			scaleValue += scaleVelocity * step

			rotationVelocity += (
				-ENTRANCE_STIFFNESS * (rotationValue - rotationTarget)
				- ENTRANCE_DAMPING * rotationVelocity
			) * step

			rotationValue += rotationVelocity * step

			dropVelocity += (
				-ENTRANCE_STIFFNESS * dropValue
				- ENTRANCE_DAMPING * dropVelocity
			) * step

			dropValue += dropVelocity * step

			slideVelocity += (
				-ENTRANCE_STIFFNESS * slideValue
				- ENTRANCE_DAMPING * slideVelocity
			) * step

			slideValue += slideVelocity * step
		end

		koText.Size = scaledSize(scaleValue)
		koText.Rotation = rotationValue
		koText.Position = basePosition + UDim2.new(
			slideValue,
			0,
			dropValue,
			0
		)

		local settled =
			math.abs(scaleValue - 1) < ENTRANCE_SETTLE_EPS
			and math.abs(scaleVelocity) < ENTRANCE_SETTLE_EPS
			and math.abs(rotationValue - rotationTarget) < 0.05
			and math.abs(rotationVelocity) < 0.05
			and math.abs(dropValue) < ENTRANCE_SETTLE_EPS
			and math.abs(dropVelocity) < ENTRANCE_SETTLE_EPS
			and math.abs(slideValue) < ENTRANCE_SETTLE_EPS
			and math.abs(slideVelocity) < ENTRANCE_SETTLE_EPS

		if settled then
			break
		end
	end

	koText.Size = baseSize
	koText.Rotation = rotationTarget
	koText.Position = basePosition
end

-- ================================================================
-- LANDING SHAKE
-- ================================================================

local function runLandingShake()
	local elapsed = 0

	while elapsed < SHAKE_DURATION do
		local falloff = 1 - (elapsed / SHAKE_DURATION)

		local offsetX = (math.random() - 0.5) * 2 * SHAKE_MAGNITUDE * falloff
		local offsetY = (math.random() - 0.5) * 2 * SHAKE_MAGNITUDE * falloff

		koText.Position = basePosition + UDim2.fromOffset(offsetX, offsetY)

		task.wait(SHAKE_STEP)
		elapsed += SHAKE_STEP
	end

	koText.Position = basePosition
end

-- ================================================================
-- KO SEQUENCE
-- ================================================================

local activeThread

local function showKOText(label)
	if activeThread then
		task.cancel(activeThread)
	end

	activeThread = task.spawn(function()
		local tiltSign = math.random(0, 1) == 0 and -1 or 1

		koText.Text = label
		koText.Visible = true
		koText.TextTransparency = 1
		koText.TextColor3 = Color3.new(1, 1, 1)

		stroke.Transparency = 1
		koFlash.BackgroundTransparency = 1

		TweenService:Create(
			koText,
			TweenInfo.new(
				FADE_IN_TIME,
				Enum.EasingStyle.Linear,
				Enum.EasingDirection.Out
			),
			{ TextTransparency = 0 }
		):Play()

		TweenService:Create(
			stroke,
			TweenInfo.new(
				FADE_IN_TIME,
				Enum.EasingStyle.Linear,
				Enum.EasingDirection.Out
			),
			{ Transparency = 0 }
		):Play()

		local flashIn = TweenService:Create(
			koFlash,
			TweenInfo.new(
				FLASH_IN_TIME,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			),
			{ BackgroundTransparency = 0.55 }
		)

		flashIn:Play()

		flashIn.Completed:Connect(function()
			TweenService:Create(
				koFlash,
				TweenInfo.new(
					FLASH_OUT_TIME,
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.In
				),
				{ BackgroundTransparency = 1 }
			):Play()
		end)

		TweenService:Create(
			koText,
			TweenInfo.new(
				FLASH_IN_TIME + FLASH_OUT_TIME,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			),
			{ TextColor3 = baseTextColor }
		):Play()

		runEntranceSpring(tiltSign)
		runLandingShake()

		task.wait(holdTime)

		local fadeTween = TweenService:Create(
			koText,
			TweenInfo.new(
				FADE_TIME,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.In
			),
			{ TextTransparency = 1 }
		)

		local strokeFadeTween = TweenService:Create(
			stroke,
			TweenInfo.new(
				FADE_TIME,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.In
			),
			{ Transparency = 1 }
		)

		fadeTween:Play()
		strokeFadeTween:Play()

		fadeTween.Completed:Wait()

		koText.Visible = false
		koText.Size = baseSize
		koText.Rotation = 0
		koText.Position = basePosition

		activeThread = nil
	end)
end

-- ================================================================
-- EVENT
-- ================================================================

koEvent.OnClientEvent:Connect(function(label)
	showKOText(label or "K.O.!")
end)

print("[KOTextClient] Berhasil diinisialisasi")