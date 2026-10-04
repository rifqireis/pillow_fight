-- @ScriptType: LocalScript
-- @ScriptType: LocalScript
-- @ScriptType: LocalScript

--[[
    Nama File  : FFYLClient
    Layer      : Client (UI)
    Deskripsi  : Menjalankan minigame Fight For Your Life.
                 Panel dibuka lewat FFYLStateEvent, pemain menekan
                 SPASI atau tap di mobile sampai bar penuh, lalu
                 client melaporkan FFYLCompleteEvent.

                 Server tetap menjadi authority untuk hasil FFYL.

    Tanggal    : 01 Agustus 2026
    Versi      : 1.0

    Dependensi :
        - ReplicatedStorage > Remotes > FFYLStateEvent
        - ReplicatedStorage > Remotes > FFYLCompleteEvent
        - ReplicatedStorage > Configs > BalanceConfig
        - StarterGui > BattleUI > FFYL
        - BarFill module
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local isMobile = UserInputService.TouchEnabled

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local FFYLStateEvent = remotes:WaitForChild("FFYLStateEvent")
local FFYLCompleteEvent = remotes:WaitForChild("FFYLCompleteEvent")

local BalanceConfig = require(
	ReplicatedStorage:WaitForChild("Configs"):WaitForChild("BalanceConfig")
)

-- ================================================================
-- UI REFERENCES
-- ================================================================

local battleUI = playerGui:WaitForChild("BattleUI")
local ffylPanel = battleUI:WaitForChild("FFYL")
local track = ffylPanel:WaitForChild("BalanceFrame")

local TweenService = game:GetService("TweenService")

-- Recursive (bukan cuma child langsung) -- jaga-jaga kalau FFYLText
-- ternyata nested di dalam frame lain, bukan langsung di bawah panel FFYL.
local promptLabel = ffylPanel:FindFirstChild("FFYLText", true)

if not promptLabel then
	warn("[FFYLClient] FFYLText gak ketemu di dalam " .. ffylPanel:GetFullName() .. " -- teks FFYL gak akan tampil sampai ini dibenerin di Studio.")
end

-- ================================================================
-- STYLING TEKS FFYL
-- ================================================================
-- Studio properties gak ke-export ke file ini, jadi style di-set dari
-- script biar gak perlu diutak-atik manual di Explorer/Properties.
-- TextScaled bikin teks otomatis segede mungkin ngisi kotak TextLabel-nya
-- (kalau kotaknya sendiri kecil di Studio, gedein Size TextLabel-nya biar
-- efek TextScaled ini kelihatan maksimal).
local textScale
if promptLabel then
	promptLabel.Font = Enum.Font.GothamBlack
	promptLabel.TextScaled = true
	promptLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	promptLabel.TextStrokeTransparency = 0
	promptLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	promptLabel.TextWrapped = true
	promptLabel.TextXAlignment = Enum.TextXAlignment.Center
	promptLabel.TextYAlignment = Enum.TextYAlignment.Center
	promptLabel.BackgroundTransparency = 1

	-- FIX v2: sebelumnya promptLabel dibiarkan nested di dalam panel FFYL
	-- (yang emang cuma dibikin pas-pasan buat nampung bar-nya doang) --
	-- makanya Size relatif ke panel itu tetep kelihatan kecil dan
	-- numpuk sama teks bawaan si bar.
	--
	-- Sekarang promptLabel di-REPARENT langsung ke battleUI (top level,
	-- se-level sama panel FFYL, bukan child-nya lagi) supaya Size/Position
	-- dia relatif ke SELURUH LAYAR, bukan ke kotak kecil punya panel.
	-- Konsekuensinya: karena udah bukan child ffylPanel lagi, dia gak akan
	-- ikut kesembunyiin otomatis pas ffylPanel.Visible = false -- makanya
	-- visibility-nya sekarang di-set manual di openPanel()/closePanel().
	promptLabel.Parent = battleUI
	promptLabel.ZIndex = 50 -- di atas panel & bar biar gak ketutupan

	promptLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	promptLabel.Size = UDim2.fromScale(0.8, 0.16)
	-- Y = 0.5 itu tengah layar; digeser dikit ke bawah (0.62) sesuai
	-- permintaan, sekalian ngejauh dari bar FFYL yang biasanya ada di
	-- sekitar tengah layar juga -- biar gak numpuk.
	promptLabel.Position = UDim2.fromScale(0.5, 0.62)

	-- Batasi ukuran font: gede beneran (biar kebaca dari jauh & jelas ini
	-- teks instruksi, bukan teks bar), tapi tetap ada batas atas biar
	-- gak "meledak" ngelewatin kotaknya sendiri di layar sempit.
	local sizeConstraint = promptLabel:FindFirstChildOfClass("UITextSizeConstraint")
		or Instance.new("UITextSizeConstraint")
	sizeConstraint.MaxTextSize = 72
	sizeConstraint.MinTextSize = 24
	sizeConstraint.Parent = promptLabel

	-- UIScale buat efek "pulse" pas di-tap, tanpa ganggu Size aslinya.
	textScale = promptLabel:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	textScale.Parent = promptLabel
end

-- Nge-"pop" teks tiap kali kena tap/spasi -- feedback visual instan biar
-- kerasa "nendang", bukan cuma bar-nya doang yang gerak.
local pulseTween
local function pulseText()
	if not textScale then
		return
	end

	if pulseTween then
		pulseTween:Cancel()
	end

	textScale.Scale = 1.25
	pulseTween = TweenService:Create(
		textScale,
		TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	)
	pulseTween:Play()
end

-- Tombol combat mobile (Light/Heavy/Dodge). Cuma dicari kalau di mobile,
-- dan gagal ambil salah satu gak boleh nge-crash script ini -- FFYL tetap
-- harus jalan walau tombolnya belum ke-load / GUI-nya beda struktur.
local mobileButtons = {}

if isMobile then
	task.spawn(function()
		local ok, mobileGui = pcall(function()
			return playerGui:WaitForChild("MobileBattleGui", 5)
		end)

		if not ok or not mobileGui then
			return
		end

		local container = mobileGui:FindFirstChild("ButtonContainer")
		if not container then
			return
		end

		mobileButtons = {
			container:FindFirstChild("LightBtn"),
			container:FindFirstChild("HeavyBtn"),
			container:FindFirstChild("DodgeBtn"),
		}
	end)
end

local function setMobileButtonsVisible(visible)
	if not isMobile then
		return
	end

	for _, btn in ipairs(mobileButtons) do
		if btn then
			btn.Visible = visible
		end
	end
end


-- ================================================================
-- STATE
-- ================================================================

local isActive = false
local hasReported = false
local pressCount = 0
local deadline = 0


-- ================================================================
-- BAR
-- ================================================================

local BarFill = require(script.Parent:WaitForChild("BarFill"))
local fillBar = BarFill.new(track, "FFYL.BalanceFrame fill", "center")

-- Dulu pakai fillBar:set() (smoothing-chase lambat, SMOOTHING=14 di
-- BarFill) -- kelihatan "nyendat" karena tiap tap gak langsung
-- kelihatan, nyusul beberapa frame kemudian. Sempat dicoba fillBar:snap()
-- (instan) -- kebalikannya, jadi "zep zep" patah-patah karena bar
-- lompat instan tanpa animasi sama sekali.
--
-- Sekarang pakai fillBar:tweenTo() dengan DURASI PENDEK (0.08 detik).
-- Tiap tap bikin bar meluncur cepat dari posisi sekarang ke posisi baru
-- dalam waktu singkat -- kelihatan halus (ada animasinya, gak instan)
-- TAPI tetap ngejar kenceng sesuai tap asli (gak ketinggalan/nunggu
-- lama kayak smoothing-chase). Kalau tap berikutnya masuk sebelum tween
-- sebelumnya kelar, tweenTo otomatis mulai tween baru dari posisi
-- terkini -- jadi tetap responsif walau di-mash cepat.
local FILL_TWEEN_DURATION = 0.08

local function setFillRatio(ratio)
	if fillBar then
		fillBar:tweenTo(ratio, FILL_TWEEN_DURATION)
	end
end

local function resetFill()
	if fillBar then
		fillBar:snap(0)
	end
end


-- ================================================================
-- PANEL
-- ================================================================

-- Teks dasar prompt, beda antara mobile (tap) & PC (keyboard).
local PROMPT_TEXT = isMobile and "TapTap in FFYL mode!" or "Space for FightForYourLife!"

local function closePanel()
	isActive = false
	ffylPanel.Visible = false
	resetFill()

	-- promptLabel udah gak nested di ffylPanel lagi (lihat catatan FIX v2
	-- di atas), jadi visibility-nya WAJIB di-toggle manual di sini juga.
	if promptLabel then
		promptLabel.Visible = false
	end

	-- Match balik tombol combat mobile begitu FFYL selesai.
	setMobileButtonsVisible(true)
end

local function openPanel(duration)
	isActive = true
	hasReported = false
	pressCount = 0
	deadline = os.clock() + duration

	resetFill()

	if promptLabel then
		promptLabel.Text = PROMPT_TEXT
		-- Reset warna ke putih tiap panel dibuka lagi (ronde baru).
		promptLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		promptLabel.Visible = true
	end

	ffylPanel.Visible = true

	-- Sembunyikan tombol Light/Heavy/Dodge selama FFYL supaya gak
	-- kepencet gak sengaja pas lagi tap-tap ngisi bar.
	setMobileButtonsVisible(false)
end

-- Panel default tertutup. Server yang mengatur kapan FFYL dibuka.
closePanel()


-- ================================================================
-- INPUT
-- ================================================================

local function registerPress()
	if not isActive or hasReported then
		return
	end

	pressCount += 1

	setFillRatio(
		pressCount / BalanceConfig.FFYL_MASH_COUNT
	)

	pulseText()

	if pressCount >= BalanceConfig.FFYL_MASH_COUNT then
		-- Lapor satu kali. Server tetap menentukan hasil akhirnya.
		hasReported = true
		FFYLCompleteEvent:FireServer()

		-- Sembunyikan langsung agar respons terasa instan.
		closePanel()
	end
end


-- ================================================================
-- SERVER STATE
-- ================================================================

FFYLStateEvent.OnClientEvent:Connect(function(active, duration)
	if active then
		openPanel(duration or BalanceConfig.FFYL_DURATION)
	else
		closePanel()
	end
end)


-- ================================================================
-- KEYBOARD & TOUCH INPUT
-- ================================================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.Space then
		registerPress()
	elseif input.UserInputType == Enum.UserInputType.Touch then
		-- Touch-down langsung, BUKAN TouchTap. TouchTap nunggu gesture
		-- penuh (jari nempel -> lepas -> baru dicek valid/enggaknya),
		-- jadi pas di-mash cepat sebagian sentuhan ke-drop karena gak
		-- sempat "selesai" jadi tap yang valid sebelum sentuhan
		-- berikutnya masuk. InputBegan nembak persis pas jari nyentuh
		-- layar, gak ada gesture yang perlu ditunggu -> gak ada tap
		-- yang hilang walau di-mash secepat apapun.
		registerPress()
	end
end)


-- ================================================================
-- COUNTDOWN UI
-- ================================================================

if promptLabel then
	RunService.RenderStepped:Connect(function()
		if not isActive then
			return
		end

		-- Teksnya statis (PROMPT_TEXT doang, gak ada angka detik) --
		-- durasi FFYL sekarang gak selalu sama tiap kali, jadi angka
		-- countdown-nya gak ditampilin lagi. Warna merah pas waktu mepet
		-- tetap jalan karena itu ngitung dari `deadline` asli (ngikutin
		-- durasi yang dikirim server tiap FFYL, bukan hardcode 5 detik).
		local remaining = math.max(0, deadline - os.clock())

		if remaining <= 2 then
			promptLabel.TextColor3 = Color3.fromRGB(255, 70, 70)
		else
			promptLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		end
	end)
end