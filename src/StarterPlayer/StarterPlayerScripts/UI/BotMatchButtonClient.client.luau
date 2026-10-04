-- @ScriptType: LocalScript
-- @ScriptType: LocalScript
--[[
    Nama File  : BotMatchButtonClient
    Layer      : Client (UI)
    Deskripsi  : Tombol "LAWAN BOT" -- muncul di tengah-bawah layar CUMA pas
                 pemain lagi SENDIRIAN nunggu di antrean arena teleporter.
                 Server (MatchmakingService.showBotButton/hideBotButton) yang
                 nentuin sepenuhnya kapan tombol ini tampil/hilang lewat
                 BotButtonVisibilityEvent -- script ini gak nebak-nebak state
                 antrean sendiri di client sama sekali, cuma nurut sinyal.

                 Diklik -> tembak RequestBotMatchEvent ke server buat langsung
                 minta slot ke-2 diisi bot, gak usah nunggu auto-trigger
                 BotConfig.AUTO_MATCH_WAIT_SECONDS (15 detik).

                 GUI dibikin manual lewat kode (belum ada instance-nya di
                 Studio sama sekali) -- polanya niru KOTextClient/
                 DodgeTextClient: ScreenGui dengan ResetOnSpawn = false,
                 di-parent ke PlayerGui, cek FindFirstChild dulu sebelum
                 bikin baru (aman kalau script ini somehow ke-load ulang).
    Dependensi : - ReplicatedStorage > Remotes > BotButtonVisibilityEvent
                   (auto-created oleh MatchmakingService, lihat catatan di sana)
                 - ReplicatedStorage > Remotes > RequestBotMatchEvent
                   (WAJIB dibuat MANUAL di Studio -- lihat catatan
                   MatchmakingService.lua di bagian bawah file, task.spawn
                   yang WaitForChild remote ini)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local BotButtonVisibilityEvent = remotesFolder:WaitForChild("BotButtonVisibilityEvent")

-- RequestBotMatchEvent WAJIB dibuat manual di Studio (lihat catatan di atas).
-- Pakai WaitForChild ber-timeout (bukan nunggu selamanya) supaya kalau
-- instance-nya belum sempat dibikin, script ini tetap jalan (tombol tetap
-- bisa nongol lewat BotButtonVisibilityEvent), cuma klik-nya yang gak
-- berfungsi sampai remote-nya beneran ada.
local RequestBotMatchEvent = remotesFolder:WaitForChild("RequestBotMatchEvent", 15)

if not RequestBotMatchEvent then
	warn("[BotMatchButtonClient] RequestBotMatchEvent belum ditemukan di ReplicatedStorage.Remotes -- tombol 'Lawan Bot' gak akan berfungsi sampai instance-nya dibuat manual di Studio.")
end

-- ================================================================
-- GUI SETUP
-- ================================================================

local screenGui = playerGui:FindFirstChild("BotMatchButtonGui")
if not screenGui then
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BotMatchButtonGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = playerGui
end

local button = screenGui:FindFirstChild("BotMatchButton")
if not button then
	button = Instance.new("TextButton")
	button.Name = "BotMatchButton"
	-- Tengah-bawah layar, ~100px dari tepi bawah -- diturunin dikit dari
	-- posisi awal (140px), tapi masih cukup jauh dari thumbstick/jump
	-- button bawaan Roblox di mobile (yang nempel di pojok kiri/kanan
	-- bawah, bukan tengah).
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -20)
	button.Size = UDim2.fromOffset(230, 56)
	button.BackgroundColor3 = Color3.fromRGB(220, 60, 50)
	button.AutoButtonColor = false
	button.Text = "LAWAN BOT"
	button.Font = Enum.Font.GothamBlack
	button.TextSize = 22
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Visible = false
	button.ZIndex = 10
	button.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(120, 20, 20)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = button

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(245, 100, 70)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 40, 40)),
	})
	gradient.Rotation = 90
	gradient.Parent = button

	local subLabel = Instance.new("TextLabel")
	subLabel.Name = "SubLabel"
	subLabel.BackgroundTransparency = 1
	-- Dipindah ke ATAS tombol (tadinya di bawah tombol).
	subLabel.AnchorPoint = Vector2.new(0.5, 1)
	subLabel.Position = UDim2.new(0.5, 0, 0, -4)
	subLabel.Size = UDim2.new(1, 0, 0, 18)
	subLabel.Font = Enum.Font.GothamMedium
	subLabel.TextSize = 13
	subLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	subLabel.TextTransparency = 0.25
	subLabel.TextStrokeTransparency = 0.6
	subLabel.Text = "Isi slot lawan dengan bot"
	subLabel.Parent = button
end

local FULL_SIZE = UDim2.fromOffset(230, 56)

-- ================================================================
-- STATE
-- ================================================================

-- true selagi nunggu respons server abis nge-klik (dicegah klik dobel,
-- lihat catatan SEND_TIMEOUT di bawah soal kenapa ini gak nyangkut selamanya).
local isSending = false
local SEND_TIMEOUT = 5 -- detik

local function setButtonPressedVisual(pressed)
	button.Active = not pressed
	TweenService:Create(button, TweenInfo.new(0.15), {
		BackgroundTransparency = pressed and 0.5 or 0,
	}):Play()
end

local function showButton()
	isSending = false
	setButtonPressedVisual(false)

	if button.Visible then return end -- sudah tampil, gak usah replay animasi

	button.Visible = true
	button.Size = UDim2.fromOffset(0, 0)
	TweenService:Create(
		button,
		TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = FULL_SIZE }
	):Play()
end

local function hideButton()
	isSending = false
	button.Visible = false
	button.Size = FULL_SIZE
	setButtonPressedVisual(false)
end

-- ================================================================
-- EVENT LISTENERS
-- ================================================================

BotButtonVisibilityEvent.OnClientEvent:Connect(function(shouldShow)
	if shouldShow then
		showButton()
	else
		hideButton()
	end
end)

button.MouseButton1Click:Connect(function()
	if isSending or not button.Visible then return end
	if not RequestBotMatchEvent then
		warn("[BotMatchButtonClient] RequestBotMatchEvent gak tersedia, klik diabaikan.")
		return
	end

	isSending = true
	setButtonPressedVisual(true)
	RequestBotMatchEvent:FireServer()

	-- Fallback re-enable: normalnya server bakal langsung nembak
	-- BotButtonVisibilityEvent(false) begitu bot beneran keisi (yang
	-- nutup tombol lewat hideButton di atas). Tapi kalau request ini
	-- kebetulan ditolak diam-diam di server (state race -- lihat catatan
	-- MatchmakingService.requestBotMatch soal kondisi #queue ~= 1, dst),
	-- tombol jangan nyangkut ke-disable selamanya -- kasih jendela waktu
	-- biar pemain bisa coba klik lagi.
	task.delay(SEND_TIMEOUT, function()
		if isSending then
			isSending = false
			setButtonPressedVisual(false)
		end
	end)
end)

print("[BotMatchButtonClient] Berhasil diinisialisasi.")