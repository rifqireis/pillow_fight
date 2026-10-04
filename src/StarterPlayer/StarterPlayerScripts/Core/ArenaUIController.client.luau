--[[
    Nama File  : ArenaUIController
    Layer      : Client
    Deskripsi  : Menangani pengumuman UI untuk arena (Round, Fight, Winner)
                 serta efek visual Vignette dan Blur berdetak saat mode FFYL.
    Penulis    : Abdul Vaiz
    Tanggal    : 03 Juli 2026
    Versi      : 1.0
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local ArenaAnnouncementEvent = remotes:WaitForChild("ArenaAnnouncementEvent")
local FFYLStateEvent = remotes:WaitForChild("FFYLStateEvent")

-- ================================================================
-- 1. SETUP UI ANNOUNCEMENT
-- ================================================================
local screenGui = playerGui:FindFirstChild("ArenaAnnouncementGui")
if not screenGui then
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ArenaAnnouncementGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui
end

local textLabel = screenGui:FindFirstChild("AnnouncementLabel")
if not textLabel then
	textLabel = Instance.new("TextLabel")
	textLabel.Name = "AnnouncementLabel"
	textLabel.Size = UDim2.new(1, 0, 0.2, 0)
	textLabel.Position = UDim2.new(0, 0, 0.2, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.GothamBlack
	textLabel.TextScaled = true
	textLabel.TextColor3 = Color3.new(1, 1, 1)
	textLabel.TextStrokeTransparency = 0
	textLabel.TextTransparency = 1
	textLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	textLabel.Parent = screenGui
end

local activeTween = nil

-- ================================================================
-- 2. SETUP UI VIGNETTE FFYL & BLUR
-- ================================================================
local ffylGui = playerGui:WaitForChild("FFYLVignette")
local vignette = ffylGui:FindFirstChildOfClass("ImageLabel") or ffylGui:FindFirstChild("ImageLabel")

-- Setup Blur Effect otomatis di Lighting
local ffylBlur = Lighting:FindFirstChild("FFYLBlur")
if not ffylBlur then
	ffylBlur = Instance.new("BlurEffect")
	ffylBlur.Name = "FFYLBlur"
	ffylBlur.Size = 0
	ffylBlur.Enabled = false
	ffylBlur.Parent = Lighting
end

if vignette then
	print("[ArenaUIController] Vignette ditemukan.")
else
	print("[ArenaUIController] Vignette belum dibuat, menyiapkan fallback...")
end

-- Fallback jika belum ada ImageLabel Vignette
if not vignette then
	local vignetteGui = playerGui:FindFirstChild("FFYLVignetteGui")
	if not vignetteGui then
		vignetteGui = Instance.new("ScreenGui")
		vignetteGui.Name = "FFYLVignetteGui"
		vignetteGui.DisplayOrder = 10
		vignetteGui.ResetOnSpawn = false
		vignetteGui.Parent = playerGui
	end

	vignette = vignetteGui:FindFirstChild("FFYLVignette")
	if not vignette then
		vignette = Instance.new("ImageLabel")
		vignette.Name = "FFYLVignette"
		vignette.AnchorPoint = Vector2.new(0.5, 0.5)
		vignette.Position = UDim2.new(0.5, 0, 0.5, 0)
		vignette.Size = UDim2.new(1, 0, 1, 0)
		vignette.BackgroundTransparency = 1
		vignette.Image = "rbxassetid://131015264" -- Asset ID Vignette Merah
		vignette.ImageTransparency = 1
		vignette.Visible = true
		vignette.Parent = vignetteGui
	end
end

-- ================================================================
-- 3. LOGIKA DETAK VIGNETTE & BLUR FFYL
-- ================================================================
local ffylConnection = nil

local PULSE_SPEED = 6          -- Kecepatan detak jantung
local MIN_TRANSPARENCY = 0.2   -- Paling terang saat puncak detak
local MAX_TRANSPARENCY = 0.7   -- Paling redup saat jeda detak
local MAX_SCALE_BOOST = 0.08   -- Skala mekar (8%)
local MIN_BLUR = 2            -- Ukuran blur saat jeda detak (paling tipis)
local MAX_BLUR = 12           -- Ukuran blur saat puncak detak (paling tebal)

local function startFFYLPulse()
	if ffylConnection then return end
	ffylGui.Enabled = true
	ffylBlur.Enabled = true

	ffylConnection = RunService.RenderStepped:Connect(function()
		local pulse = (math.sin(os.clock() * PULSE_SPEED) + 1) / 2

		-- Animasi Ukuran & Transparansi Vignette
		local currentScale = 1 + (pulse * MAX_SCALE_BOOST)
		vignette.Size = UDim2.new(currentScale, 0, currentScale, 0)
		vignette.ImageTransparency = MAX_TRANSPARENCY - (pulse * (MAX_TRANSPARENCY - MIN_TRANSPARENCY))

		-- Animasi Ukuran Blur
		ffylBlur.Size = MIN_BLUR + (pulse * (MAX_BLUR - MIN_BLUR))
	end)
end

local function stopFFYLPulse()
	if ffylConnection then
		ffylConnection:Disconnect()
		ffylConnection = nil
	end

	-- Reset Vignette
	vignette.ImageTransparency = 1
	vignette.Size = UDim2.new(1, 0, 1, 0)
	ffylGui.Enabled = false

	-- Reset & Matikan Blur
	ffylBlur.Size = 0
	ffylBlur.Enabled = false
end

-- ================================================================
-- 4. EVENT LISTENERS
-- ================================================================
ArenaAnnouncementEvent.OnClientEvent:Connect(function(message, duration)
	duration = duration or 2

	if activeTween then
		activeTween:Cancel()
	end

	textLabel.Text = message
	textLabel.TextTransparency = 1
	textLabel.TextStrokeTransparency = 1
	textLabel.Size = UDim2.new(1, 0, 0.1, 0)
	textLabel.Position = UDim2.new(0, 0, 0.25, 0)

	-- Animasi Muncul (Fade In + Pop)
	local tweenIn = TweenService:Create(textLabel, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		TextTransparency = 0,
		TextStrokeTransparency = 0,
		Size = UDim2.new(1, 0, 0.2, 0),
		Position = UDim2.new(0, 0, 0.2, 0)
	})
	tweenIn:Play()
	activeTween = tweenIn

	-- Tunggu durasi pesan
	task.delay(duration, function()
		if textLabel.Text == message then
			local tweenOut = TweenService:Create(textLabel, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				TextTransparency = 1,
				TextStrokeTransparency = 1
			})
			tweenOut:Play()
			activeTween = tweenOut
		end
	end)
end)

-- Listener FFYL State (Detak Vignette & Blur)
FFYLStateEvent.OnClientEvent:Connect(function(isFFYL)
	if isFFYL then
		startFFYLPulse()
	else
		stopFFYLPulse()
	end
end)

print("[ArenaUIController] Berhasil diinisialisasi")