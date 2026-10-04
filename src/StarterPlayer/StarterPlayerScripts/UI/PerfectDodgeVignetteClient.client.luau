-- @ScriptType: LocalScript
--[[
    Nama File  : PerfectDodgeVignetteClient
    Layer      : Client (UI)
    Deskripsi  : Vignette sinematik sekali-tembak saat perfect dodge.

                 Konsepnya nyontek vignette FFYL (ArenaUIController), tapi
                 beda peran: FFYL itu STATE (detak terus selama sekarat),
                 ini MOMEN. Envelope-nya: masuk nyaris instan pas dodge
                 kebaca (slam), nahan selama slow-mo jalan, lepas pelan
                 begitu waktu balik normal.

                 Durasi nahan diambil dari CameraConfig.DODGE_FEEDBACK.
                 PERFECT.SLOWMO_DURATION -- vignette & slow-mo emang harus
                 selesai barengan, jadi angkanya cukup ada di satu tempat.

    Dependensi :
        - ReplicatedStorage > Remotes > AttackResultEvent
        - ReplicatedStorage > Remotes > FFYLStateEvent
        - ReplicatedStorage > Remotes > SyncMatchStateEvent
        - ReplicatedStorage > Configs > CameraConfig (DODGE_VIGNETTE)
]]

-- ================================================================
-- SERVICES
-- ================================================================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Lighting          = game:GetService("Lighting")

local CameraConfig = require(
	ReplicatedStorage:WaitForChild("Configs"):WaitForChild("CameraConfig")
)

local VIGNETTE = CameraConfig.DODGE_VIGNETTE

if not VIGNETTE or not VIGNETTE.ENABLED then
	return
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local attackResultEvent   = remotes:WaitForChild("AttackResultEvent")
local ffylStateEvent      = remotes:WaitForChild("FFYLStateEvent")
local syncMatchStateEvent = remotes:WaitForChild("SyncMatchStateEvent")


-- ================================================================
-- KONSTANTA ENVELOPE
-- ================================================================

local PERFECT_FEEDBACK = CameraConfig.DODGE_FEEDBACK
	and CameraConfig.DODGE_FEEDBACK.PERFECT

local HOLD_DURATION = (PERFECT_FEEDBACK and PERFECT_FEEDBACK.SLOWMO_DURATION) or 0.9

local FADE_IN  = VIGNETTE.FADE_IN or 0.07
local FADE_OUT = VIGNETTE.FADE_OUT or 0.35

-- Overshoot tebal di puncak slam terus nyusut balik. Diturunin dari FADE_IN
-- (bukan knob config sendiri) supaya slam & settle-nya otomatis tetap
-- proporsional kalau FADE_IN diutak-atik.
local SETTLE_TIME = FADE_IN * 2.5

local THICKNESS       = VIGNETTE.THICKNESS or 0.34
local PUNCH_THICKNESS = VIGNETTE.PUNCH_THICKNESS or 0.16

local BREATHE_SPEED = VIGNETTE.BREATHE_SPEED or 4.5
local BREATHE_DEPTH = VIGNETTE.BREATHE_DEPTH or 0.1

local BLUR_CONFIG = VIGNETTE.BLUR or {}

local TIERS = {
	perfect = VIGNETTE.PERFECT,
	read    = VIGNETTE.READ,
}


-- ================================================================
-- SETUP GUI
-- ================================================================

-- DisplayOrder negatif: vignette harus nempel di BAWAH semua UI battle
-- (teks "PERFECT!", bar, tombol mobile). Kalau ditaruh di atas, teksnya
-- ikut keredupan padahal justru teks itu yang mau dibaca pemain di momen
-- ini. IgnoreGuiInset biar area topbar ikut ketutup -- vignette yang
-- bolong di atas langsung kelihatan seperti bug.
local screenGui = playerGui:FindFirstChild("PerfectDodgeVignetteGui")

if not screenGui then
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PerfectDodgeVignetteGui"
	screenGui.DisplayOrder = -1
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui
end

screenGui.Enabled = false
screenGui:ClearAllChildren()

-- Falloff gelap -> terang. Sengaja gak linear: keypoint tengah ditarik ke
-- 0.55 biar gelapnya numpuk di tepi layar dan cepat encer ke tengah, jadi
-- area main tetap kebaca.
local FALLOFF = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.45, 0.55),
	NumberSequenceKeypoint.new(1, 1),
})

-- Empat pita gradient di tiap tepi layar. Rotation nentuin ujung mana yang
-- pekat: 0 = kiri, 90 = atas, 180 = kanan, 270 = bawah. Pita yang ketemu di
-- pojok saling numpuk -- itu justru yang bikin pojokan paling gelap, persis
-- kayak vignette beneran.
local BAND_SPECS = {
	{ name = "Left",   anchor = Vector2.new(0, 0), position = UDim2.fromScale(0, 0), rotation = 0,   vertical = false },
	{ name = "Right",  anchor = Vector2.new(1, 0), position = UDim2.fromScale(1, 0), rotation = 180, vertical = false },
	{ name = "Top",    anchor = Vector2.new(0, 0), position = UDim2.fromScale(0, 0), rotation = 90,  vertical = true },
	{ name = "Bottom", anchor = Vector2.new(0, 1), position = UDim2.fromScale(0, 1), rotation = 270, vertical = true },
}

local bands = {}
local vignetteImage = nil

local assetId = VIGNETTE.ASSET_ID

if assetId and assetId ~= "" then
	-- Jalur gambar: satu ImageLabel di tengah, di-tint per tier.
	vignetteImage = Instance.new("ImageLabel")
	vignetteImage.Name = "Vignette"
	vignetteImage.AnchorPoint = Vector2.new(0.5, 0.5)
	vignetteImage.Position = UDim2.fromScale(0.5, 0.5)
	vignetteImage.Size = UDim2.fromScale(1, 1)
	vignetteImage.BackgroundTransparency = 1
	vignetteImage.BorderSizePixel = 0
	vignetteImage.Image = assetId
	vignetteImage.ImageTransparency = 1
	vignetteImage.ScaleType = Enum.ScaleType.Stretch
	vignetteImage.Parent = screenGui
else
	-- Jalur prosedural: gak butuh asset sama sekali, dan warnanya bebas
	-- di-tint per tier tanpa risiko ketabrak warna bawaan gambar.
	for _, spec in ipairs(BAND_SPECS) do
		local band = Instance.new("Frame")
		band.Name = spec.name
		band.AnchorPoint = spec.anchor
		band.Position = spec.position
		band.Size = spec.vertical
			and UDim2.fromScale(1, THICKNESS)
			or UDim2.fromScale(THICKNESS, 1)
		band.BackgroundColor3 = Color3.new(0, 0, 0)
		band.BackgroundTransparency = 1
		band.BorderSizePixel = 0
		band.Parent = screenGui

		local gradient = Instance.new("UIGradient")
		gradient.Rotation = spec.rotation
		gradient.Transparency = FALLOFF
		gradient.Parent = band

		table.insert(bands, { frame = band, vertical = spec.vertical })
	end
end

-- Blur sendiri, BUKAN numpang FFYLBlur milik ArenaUIController. Dua sistem
-- yang nulis ke satu BlurEffect bakal saling nimpa Size tiap frame; lagipula
-- vignette ini emang di-skip selama FFYL (lihat isFFYLActive di bawah), jadi
-- dua blur ini gak pernah hidup barengan.
local blur = nil

if BLUR_CONFIG.ENABLED then
	local blurName = BLUR_CONFIG.NAME or "PerfectDodgeBlur"

	blur = Lighting:FindFirstChild(blurName)

	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = blurName
		blur.Parent = Lighting
	end

	blur.Size = 0
	blur.Enabled = false
end


-- ================================================================
-- STATE
-- ================================================================

local connection = nil
local elapsed = 0
local activeTier = nil

-- Intensitas yang lagi kepasang di layar frame ini. Dicatat karena efeknya
-- bisa dipotong kapan aja (impact baru masuk sebelum slam-nya kelar) --
-- fase lepas harus mulai turun dari posisi terkini, bukan dari 1, biar
-- gak nyentak naik dulu sebelum ilang.
local currentIntensity = 0

local releaseStartedAt = nil
local releaseFromIntensity = 0

local isFFYLActive = false


-- ================================================================
-- APPLY
-- ================================================================

local function applyLook(intensity, thickness)
	-- transparency 1 = ilang total, PEAK_TRANSPARENCY = paling pekat.
	local peak = (activeTier and activeTier.PEAK_TRANSPARENCY) or 0.15
	local color = (activeTier and activeTier.COLOR) or Color3.new(1, 1, 1)
	local transparency = 1 - intensity * (1 - peak)

	if vignetteImage then
		-- Gambar gak punya "tebal pita", jadi tebalnya diterjemahin jadi
		-- skala: makin tebal = makin mekar keluar layar.
		local scale = 1 + (thickness - THICKNESS)

		vignetteImage.ImageColor3 = color
		vignetteImage.ImageTransparency = transparency
		vignetteImage.Size = UDim2.fromScale(scale, scale)
	else
		for _, band in ipairs(bands) do
			band.frame.BackgroundColor3 = color
			band.frame.BackgroundTransparency = transparency
			band.frame.Size = band.vertical
				and UDim2.fromScale(1, thickness)
				or UDim2.fromScale(thickness, 1)
		end
	end

	if blur then
		blur.Size = (BLUR_CONFIG.MAX_SIZE or 5) * intensity
	end
end


-- ================================================================
-- STOP
-- ================================================================

local function stopVignette()
	if connection then
		connection:Disconnect()
		connection = nil
	end

	elapsed = 0
	activeTier = nil
	currentIntensity = 0
	releaseStartedAt = nil
	releaseFromIntensity = 0

	screenGui.Enabled = false

	if blur then
		blur.Size = 0
		blur.Enabled = false
	end
end

-- Potong efek di tengah jalan tapi tetap lewat fase lepas -- dipakai pas ada
-- impact baru, yang di CameraController juga jadi pemutus slow-mo. Kalau
-- vignette-nya dimatiin mentah di situ, layar kelihatan "kedip" pas
-- pertarungan lanjut.
local function releaseVignette()
	if not connection or releaseStartedAt then
		return
	end

	releaseStartedAt = elapsed
	releaseFromIntensity = currentIntensity
end


-- ================================================================
-- RENDER LOOP
-- ================================================================

local function onRenderStep(deltaTime)
	elapsed += deltaTime

	local intensity
	local punch

	if releaseStartedAt then
		local t = math.clamp((elapsed - releaseStartedAt) / FADE_OUT, 0, 1)

		-- Kuadrat: turunnya cepat di awal terus melandai -- gelapnya
		-- "dilepas", bukan dipotong.
		intensity = releaseFromIntensity * (1 - t) * (1 - t)
		punch = 0

		if t >= 1 then
			stopVignette()
			return
		end

	elseif elapsed < FADE_IN then
		local t = elapsed / FADE_IN

		intensity = 1 - (1 - t) * (1 - t)
		punch = intensity -- tebal ikut naik barengan, jadi kerasa nge-slam

	else
		intensity = 1
		punch = math.max(0, 1 - (elapsed - FADE_IN) / SETTLE_TIME)

		-- Denyut halus selama nahan. Terang & tebal naik-turun BARENGAN
		-- (bukan berlawanan) -- kalau dibikin berlawanan hasilnya kelihatan
		-- goyang, bukan bernapas.
		local breathe = (math.sin(elapsed * BREATHE_SPEED) + 1) / 2
		intensity = intensity * (1 - BREATHE_DEPTH + BREATHE_DEPTH * breathe)
		punch = punch + BREATHE_DEPTH * breathe * 0.5

		if elapsed >= HOLD_DURATION then
			releaseStartedAt = elapsed
			releaseFromIntensity = intensity
		end
	end

	currentIntensity = intensity
	applyLook(intensity, THICKNESS + PUNCH_THICKNESS * punch)
end


-- ================================================================
-- START
-- ================================================================

local function startVignette(tierName)
	local tier = TIERS[tierName]

	if not tier then
		return
	end

	-- Selama FFYL layar udah dipegang vignette merah berdetak milik
	-- ArenaUIController. Numpuk dua vignette bikin dua-duanya gak kebaca --
	-- CameraController juga nge-skip dodge feedback dengan alasan sama.
	if isFFYLActive then
		return
	end

	activeTier = tier
	elapsed = 0
	currentIntensity = 0
	releaseStartedAt = nil
	releaseFromIntensity = 1

	screenGui.Enabled = true

	if blur then
		blur.Enabled = true
	end

	applyLook(0, THICKNESS)

	if not connection then
		connection = RunService.RenderStepped:Connect(onRenderStep)
	end
end


-- ================================================================
-- EVENT
-- ================================================================

-- Momen yang di CameraController juga membatalkan slow-mo. Begitu waktu
-- jalan normal lagi, vignette-nya ikut dilepas -- gelapnya nempel ke slow-mo,
-- bukan ke stopwatch sendiri.
local IMPACT_ACTIONS = {
	hitConfirm = true,
	lightHurt  = true,
	heavyHurt  = true,
	fall       = true,
	defeat     = true,
}

attackResultEvent.OnClientEvent:Connect(function(actionType, success)
	if not success then
		return
	end

	if actionType == "perfectDodge" then
		startVignette("perfect")

	elseif actionType == "perfectDodgeHit" then
		startVignette("read")

	elseif IMPACT_ACTIONS[actionType] then
		releaseVignette()
	end
end)

ffylStateEvent.OnClientEvent:Connect(function(active)
	isFFYLActive = active

	if active then
		stopVignette()
	end
end)

syncMatchStateEvent.OnClientEvent:Connect(function(isPlaying)
	if not isPlaying then
		stopVignette()
	end
end)

player.CharacterAdded:Connect(stopVignette)

print("[PerfectDodgeVignetteClient] Berhasil diinisialisasi")
