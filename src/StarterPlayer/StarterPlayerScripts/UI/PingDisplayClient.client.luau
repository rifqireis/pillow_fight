-- @ScriptType: LocalScript
-- @ScriptType: LocalScript
--[[
    Nama File  : PingDisplayClient.lua
    Layer      : Client (UI)
    Deskripsi  : Nampilin ping pemain (ms) di pojok kanan atas, update tiap
                 1 detik, warnanya berubah sesuai kualitas koneksi (hijau/
                 kuning/merah). GUI-nya dibikin sendiri lewat script, jadi
                 gak perlu nyiapin apa-apa dulu di Studio -- tinggal taruh
                 script ini di StarterPlayerScripts, langsung jalan.
    Penulis    : System
    Tanggal    : 18 Agustus 2026
    Versi      : 1.2 (fix: responsive di HP -- posisi & ukuran ngikutin scale layar,
                 bukan pixel mati, jadi tetap nempel di tempat yang sama kayak
                 desktop -- deket avatar/HealthBar kiri atas -- di semua device)
]]

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local Workspace         = game:GetService("Workspace")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ================================================================
-- CONFIG
-- ================================================================
local UPDATE_INTERVAL = 1.0 -- detik, seberapa sering ping di-refresh

-- Posisi dikalibrasi dari target lama (62px, 140px) di resolusi referensi
-- desktop di bawah ini, terus dikonversi ke SCALE. Dengan scale, posisinya
-- otomatis proporsional di semua ukuran layar (HP, tablet, desktop) --
-- jadi tetap nempel di area yang sama relatif ke layar, bukan geser kayak
-- pas masih pixel absolut.
local REFERENCE_RESOLUTION = Vector2.new(1280, 720)
local REFERENCE_OFFSET     = Vector2.new(62, 140) -- posisi lama yang udah pas di desktop

local BASE_POSITION_SCALE = Vector2.new(
	REFERENCE_OFFSET.X / REFERENCE_RESOLUTION.X,
	REFERENCE_OFFSET.Y / REFERENCE_RESOLUTION.Y
)

-- Posisi HP udah pas, tapi desktop butuh naik dikit lagi. Daripada geser
-- REFERENCE_OFFSET (yang bakal ikut geser posisi HP juga karena sama-sama
-- scale-based), nudge ini KHUSUS jalan di device non-touch (mouse/desktop)
-- doang -- tinggal gedein angkanya (makin negatif = makin naik).
local DESKTOP_Y_NUDGE_PIXELS = -40

-- Ukuran dasar label (di resolusi referensi di atas), nanti di-scale
-- ngikutin lebar layar aktual biar gak kegedean/kekecilan di HP.
local BASE_SIZE = Vector2.new(90, 26)
local MIN_UI_SCALE = 0.85
local MAX_UI_SCALE = 1.35

-- Ambang batas kualitas koneksi (dalam ms) buat nentuin warna.
local THRESHOLD_GOOD   = 80  -- <= ini = hijau
local THRESHOLD_MEDIUM = 150 -- <= ini = kuning, di atasnya = merah

local COLOR_GOOD   = Color3.fromRGB(90, 230, 120)
local COLOR_MEDIUM = Color3.fromRGB(255, 200, 60)
local COLOR_BAD     = Color3.fromRGB(255, 90, 90)

-- ================================================================
-- BUILD UI
-- ================================================================
-- IgnoreGuiInset dimatiin biar label ngehormatin safe-area (topbar/notch)
-- bawaan Roblox -- penting di HP soalnya banyak device punya notch/status
-- bar yang makan tempat di pojok atas layar.
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PingDisplayGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.Parent = playerGui

local pingLabel = Instance.new("TextLabel")
pingLabel.Name = "PingLabel"
pingLabel.AnchorPoint = Vector2.new(0, 0)
pingLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
pingLabel.BackgroundTransparency = 0.5
pingLabel.BorderSizePixel = 0
pingLabel.Font = Enum.Font.GothamBold
pingLabel.TextSize = 16
pingLabel.TextColor3 = COLOR_GOOD
pingLabel.Text = "-- ms"
pingLabel.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 6)
corner.Parent = pingLabel

local uiScale = Instance.new("UIScale")
uiScale.Parent = pingLabel

-- ================================================================
-- RESPONSIVE LAYOUT
-- ================================================================
-- Dihitung ulang tiap kali ukuran layar berubah (buka app, rotate HP,
-- resize window desktop, dsb) supaya label selalu jatuh di posisi yang
-- sama secara relatif -- persis kayak posisinya di desktop.
local function getViewportSize()
	local camera = Workspace.CurrentCamera
	if camera then
		return camera.ViewportSize
	end
	return Vector2.new(1280, 720)
end

local function updateLayout()
	local viewport = getViewportSize()
	if viewport.X <= 0 or viewport.Y <= 0 then
		return
	end

	-- Posisi: scale murni (bukan offset), jadi proporsional di device manapun.
	-- Khusus desktop (non-touch), ditambah nudge offset pixel biar bisa naik
	-- sendiri tanpa ganggu posisi yang udah pas di HP.
	local isDesktop = not UserInputService.TouchEnabled
	local yOffset = isDesktop and DESKTOP_Y_NUDGE_PIXELS or 0

	pingLabel.Position = UDim2.new(BASE_POSITION_SCALE.X, 0, BASE_POSITION_SCALE.Y, yOffset)

	-- Ukuran: tetap pakai offset (biar teks gak ikut gepeng), tapi
	-- di-scale ngikutin lebar layar aktual dibanding resolusi referensi,
	-- dan di-clamp biar gak kekecilan di HP mungil atau kegedean di
	-- monitor lebar.
	local rawScale = viewport.X / REFERENCE_RESOLUTION.X
	local scaleFactor = math.clamp(rawScale, MIN_UI_SCALE, MAX_UI_SCALE)

	-- Di HP (touch device), tambahin dikit biar gampang kebaca dari jarak
	-- pegang yang lebih deket ke layar.
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		scaleFactor = math.clamp(scaleFactor * 1.08, MIN_UI_SCALE, MAX_UI_SCALE + 0.1)
	end

	pingLabel.Size = UDim2.new(0, BASE_SIZE.X, 0, BASE_SIZE.Y)
	uiScale.Scale = scaleFactor
end

updateLayout()

do
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateLayout)
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local newCamera = Workspace.CurrentCamera
		if newCamera then
			newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateLayout)
			updateLayout()
		end
	end)
end

-- ================================================================
-- PING LOOP
-- ================================================================
local function getPingMs()
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)

	if ok and type(ping) == "number" then
		return math.floor(ping * 1000 + 0.5)
	end

	return nil
end

local function getPingColor(pingMs)
	if pingMs <= THRESHOLD_GOOD then
		return COLOR_GOOD
	elseif pingMs <= THRESHOLD_MEDIUM then
		return COLOR_MEDIUM
	end
	return COLOR_BAD
end

task.spawn(function()
	while pingLabel.Parent do
		local pingMs = getPingMs()

		if pingMs then
			pingLabel.Text = pingMs .. " ms"
			pingLabel.TextColor3 = getPingColor(pingMs)
		else
			pingLabel.Text = "-- ms"
			pingLabel.TextColor3 = COLOR_MEDIUM
		end

		task.wait(UPDATE_INTERVAL)
	end
end)

print("[PingDisplayClient] Berhasil diinisialisasi")