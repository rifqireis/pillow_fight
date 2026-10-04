
--[[
    Nama File  : BalanceBarClient.lua
    Layer      : Client (UI)
    Deskripsi  : Menangani update visual Balance Bar (HpLeft) milik LocalPlayer.
    Penulis    : Yusuf Ahayy & System
    Tanggal    : 14 Agustus 2026
    Versi      : 1.1 (Refactored & Safety Fix)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Helper Modul
local BarFill = require(script.Parent:WaitForChild("BarFill"))
local AvatarUtil = require(script.Parent:WaitForChild("AvatarUtil"))

-- Configs
local GameplayConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("GameplayConfig"))
local BalanceConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("BalanceConfig"))

-- Remote Events
local SyncBalanceEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SyncBalanceEvent")

-- Delay sebelum BalanceBase (merah) mulai nyusul turun. Dipakein durasi
-- combo window yang sama dengan yang dipakai ComboService di server, biar
-- selama attacker masih "dalam combo" merahnya nunggu dulu.
local BASE_CATCHUP_DELAY = GameplayConfig.COMBO_WINDOW

-- Batas maksimum hold-nya (lihat komentar panjang di BalanceConfig). Dijaga
-- math.max biar gak pernah lebih kecil dari BASE_CATCHUP_DELAY -- kalau
-- kekecilan, delay combo window di atas jadi mubazir total.
local BASE_MAX_HOLD = math.max(BalanceConfig.BASE_MAX_HOLD_DURATION or 4, BASE_CATCHUP_DELAY)

-- ================================================================
-- EFEK KENA DAMAGE (flash + shake)
-- ================================================================

local FLASH_COLOR = Color3.fromRGB(255, 255, 255)

-- Kedip putihnya BalanceFill (hijau) -- pendek doang, cuma penanda benturan.
local FILL_FLASH_DURATION = 0.08

-- Tahap PUTIH -> MERAH punya BalanceBase:
--   HOLD = berapa lama putihnya diem dulu, biar sempat kebaca sebagai putih
--          dan bukan kedip yang kelewat cepat.
--   FADE = berapa lama lunturnya dari putih ke merah aslinya.
-- Total (0.12 + 0.3) sengaja dijaga di bawah BASE_CATCHUP_DELAY, jadi
-- warnanya udah selesai jadi merah sebelum bar-nya mulai nyusut.
local BASE_WHITE_HOLD = 0.12
local BASE_WHITE_FADE = 0.3

-- Drop minimum (skala 0-1) yang dihitung sebagai "kena pukul".
--
-- Decay pasif nurunin balance 2 poin per detik (BalanceConfig.DECAY_RATE),
-- dan itu nyampe ke sini lewat SyncBalanceEvent yang SAMA PERSIS kayak
-- pukulan -- gak ada penanda apa pun yang bedain keduanya. Tanpa ambang ini,
-- pemain yang cuma diam bakal kena flash putih + shake tiap detik seolah
-- lagi dipukulin, dan efek putih yang baru (lebih panjang dari flash lama)
-- bikin itu jauh lebih kelihatan.
--
-- 0.04 = 4 poin balance: aman di atas decay (2 poin) dan aman di bawah
-- pukulan paling kecil (LIGHT_HIT = 8 poin -> 0.08).
local MIN_DROP_FOR_FLASH = 0.04

-- Shake PANEL (HpLeft, avatar+nama+kedua bar sekaligus) -- LITE banget,
-- soalnya perubahan balance udah keliatan jelas dari bar-nya sendiri
-- ngecil/geser, jadi shake di sini cuma bumbu tipis doang, bukan reaksi utama.
local PANEL_BASE_SHAKE_COUNT = 2
local PANEL_BASE_SHAKE_OFFSET = 0.0004
local PANEL_SHAKE_STEP = 0.03
local PANEL_COMBO_SHAKE_BONUS = 0.00015
local PANEL_MAX_SHAKE_OFFSET = 0.0016
local PANEL_MAX_SHAKE_COUNT = 5

-- Shake BALANCE FILL (bar hijau doang) -- juga di-lite-in, alasan sama:
-- fill-nya sendiri udah drop instan pas kena damage, jadi shake ini cuma
-- penegas kecil, bukan efek yang harus mendominasi.
local FILL_BASE_SHAKE_COUNT = 3
local FILL_BASE_SHAKE_OFFSET = 0.006
local FILL_SHAKE_STEP = 0.025
local FILL_COMBO_SHAKE_BONUS = 0.0025
local FILL_MAX_SHAKE_OFFSET = 0.016
local FILL_MAX_SHAKE_COUNT = 7

-- References
local balanceBar = nil -- BalanceFill (hijau) -> nilai balance saat ini, drop instan
local balanceBaseBar = nil -- BalanceBase (merah) -> nyusul turun setelah combo selesai
local baseCatchupThread = nil

-- Kapan hold merah yang SEKARANG mulai, yaitu pukulan pertama yang belum
-- kesusul. nil = merah lagi gak nahan apa-apa (udah nyusul / lagi penuh).
-- Ini yang bikin batas BASE_MAX_HOLD ngitung dari pukulan PERTAMA, sementara
-- delay normalnya tetap ngitung dari pukulan TERAKHIR.
local baseHoldStartClock = nil

local hpLeftFrame = nil -- buat shake
local balanceFrame, balanceFillObj, balanceBaseObj = nil, nil, nil -- buat flash warna
local balanceFillOriginalColor, balanceBaseOriginalColor = nil, nil

-- Pegangan buat tahap putih -> merah punya BalanceBase (lihat flashDamage),
-- supaya pukulan berikutnya bisa ngebatalin tahap yang lagi jalan.
local baseColorTween = nil
local baseWhiteThread = nil

-- Posisi asli buat shake, di-cache SEKALI di setupUI. Lihat komentar panjang
-- di runPositionShake soal kenapa ini nggak boleh dibaca live dari
-- obj.Position tiap kali shake dimulai.
local hpLeftOriginalPosition = nil

-- Lacak combo hit yang MASUK (bukan combo yang kita keluarin), dipakai buat
-- nentuin seberapa kenceng shake-nya. Pakai jendela waktu yang sama dengan
-- combo window server, jadi konsisten sama delay BalanceBase di atas.
local incomingComboCount = 0
local lastIncomingHitClock = 0

local activePanelShakeThread = nil
local activeFillShakeThread = nil

-- Balance bar bisa jadi ImageLabel (dipakai bareng UIGradient buat masking di
-- BarFill) atau Frame biasa, jadi tint-nya disesuaikan sama tipe object-nya.
local function getTintProperty(obj)
	if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		return "ImageColor3"
	end
	return "BackgroundColor3"
end

-- Urutan efek pas kena pukul (ini yang bikin bar-nya kerasa "hidup",
-- bukan cuma geser diam-diam):
--   1. BalanceFill (hijau) kedip PUTIH sekejap -> rasa benturannya.
--   2. BalanceBase (merah) ikut di-set PUTIH juga, jadi potongan yang barusan
--      kepotong itu kelihatan PUTIH dulu -- bukan langsung merah.
--   3. Putihnya ditahan sebentar, baru luntur pelan-pelan ke merah aslinya.
-- Di mata pemain: putih muncul -> putih ilang -> merahnya baru nongol.
--
-- Munculnya merah dikerjain lewat WARNA, bukan Transparency. Transparency
-- BalanceBase udah dipakai BarFill buat masking panjang bar (UIGradient),
-- jadi kalau disentuh dari sini malah tabrakan sama panjang bar-nya sendiri.
local function flashDamage()
	-- (1) Hijau: kedip putih singkat, langsung balik sendiri.
	if balanceFillObj then
		balanceFillObj[getTintProperty(balanceFillObj)] = FLASH_COLOR

		task.delay(FILL_FLASH_DURATION, function()
			if balanceFillObj and balanceFillOriginalColor then
				balanceFillObj[getTintProperty(balanceFillObj)] = balanceFillOriginalColor
			end
		end)
	end

	if not balanceBaseObj or not balanceBaseOriginalColor then return end

	-- Pukulan baru selalu ngerebut efeknya: tahap lama dibatalin dulu biar
	-- warnanya balik PUTIH PENUH dari awal. Kalau dibiarin nerusin luntur
	-- yang setengah jalan, hit ke-2 dan seterusnya putihnya makin gak
	-- kelihatan -- padahal justru pas lagi rame-ramenya.
	if baseColorTween then
		baseColorTween:Cancel()
		baseColorTween = nil
	end
	if baseWhiteThread then
		task.cancel(baseWhiteThread)
		baseWhiteThread = nil
	end

	local baseProp = getTintProperty(balanceBaseObj)
	balanceBaseObj[baseProp] = FLASH_COLOR

	-- (2) + (3) Tahan putihnya, baru luntur ke merah.
	baseWhiteThread = task.delay(BASE_WHITE_HOLD, function()
		baseWhiteThread = nil
		if not balanceBaseObj or not balanceBaseOriginalColor then return end

		baseColorTween = TweenService:Create(
			balanceBaseObj,
			TweenInfo.new(BASE_WHITE_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ [baseProp] = balanceBaseOriginalColor }
		)
		baseColorTween:Play()
	end)
end

-- Balikin BalanceBase ke merah SEKARANG juga, sekalian batalin tahap putih
-- yang mungkin lagi jalan. Dipakai pas balance NAIK (recovery FFYL / ronde
-- baru) dan pas UI di-rebind: jejak damage-nya udah gak ada, jadi jangan
-- sampai ada putih yang nyangkut di bar.
local function restoreBaseColor()
	if baseColorTween then
		baseColorTween:Cancel()
		baseColorTween = nil
	end
	if baseWhiteThread then
		task.cancel(baseWhiteThread)
		baseWhiteThread = nil
	end

	if balanceBaseObj and balanceBaseOriginalColor then
		balanceBaseObj[getTintProperty(balanceBaseObj)] = balanceBaseOriginalColor
	end
end

-- Helper umum: geser posisi X sebuah GuiObject bolak-balik sejumlah `count`
-- kali sejauh `offset` (scale), balik ke posisi asli di akhir.
--
-- FIX (bug "jalan ke samping"): originalPosition WAJIB posisi asli yang
-- benar-benar tetap (di-cache sekali di setupUI), BUKAN dibaca live dari
-- obj.Position. Shake sebelumnya bisa saja di-task.cancel() di tengah jalan
-- (lihat shakePanel/shakeFill) sebelum sempat balik ke posisi semula --
-- kalau originalPosition dibaca live saat itu, shake berikutnya bakal
-- menjadikan posisi offset yang ketinggalan itu sebagai "posisi asli" baru,
-- dan offset-nya numpuk terus tiap kali di-retrigger cepat (mis. decay
-- balance yang ngetick tiap frame) -- efeknya bar keliatan geser/jalan,
-- bukan getar di tempat.
local function runRotationShake(obj, count, maxAngle, step)
	return task.spawn(function()
		for _ = 1, count do
			obj.Rotation = maxAngle
			task.wait(step)
			obj.Rotation = -maxAngle
			task.wait(step)
		end
		obj.Rotation = 0
	end)
end

-- dropRatio: seberapa besar balance turun (0-1), makin gede makin berat hitnya.
-- Shake PANEL -- tipis, cuma ambience, dikecilin sesuai request (jangan
-- terlalu ramai gerak, biar fokus perhatian ke shake BalanceFill di bawah).
local function shakePanel(dropRatio, comboCount)
	if not hpLeftFrame or not hpLeftOriginalPosition then return end

	if activePanelShakeThread then
		task.cancel(activePanelShakeThread)
		activePanelShakeThread = nil
	end

	local heavyFactor = math.clamp(dropRatio / (BalanceConfig.HEAVY_HIT / BalanceConfig.MAX_BALANCE), 0.5, 1.5)
	local comboFactor = math.max(0, comboCount - 1)

	local offset = math.min(PANEL_MAX_SHAKE_OFFSET, (PANEL_BASE_SHAKE_OFFSET * heavyFactor) + (comboFactor * PANEL_COMBO_SHAKE_BONUS))
	local shakeCount = math.min(PANEL_MAX_SHAKE_COUNT, PANEL_BASE_SHAKE_COUNT + comboFactor)

	activePanelShakeThread = runRotationShake(hpLeftFrame, shakeCount, math.clamp(offset * 80, 0.2, 0.8), PANEL_SHAKE_STEP)
end

-- Shake BALANCE FILL -- ini reaksi UTAMA pas kena damage, jauh lebih kenceng.
local function shakeFill(dropRatio, comboCount)
	if not balanceFillObj then return end

	if activeFillShakeThread then
		task.cancel(activeFillShakeThread)
		activeFillShakeThread = nil
	end

	local heavyFactor = math.clamp(dropRatio / (BalanceConfig.HEAVY_HIT / BalanceConfig.MAX_BALANCE), 0.5, 1.5)
	local comboFactor = math.max(0, comboCount - 1)

	local offset = math.min(FILL_MAX_SHAKE_OFFSET, (FILL_BASE_SHAKE_OFFSET * heavyFactor) + (comboFactor * FILL_COMBO_SHAKE_BONUS))
	local shakeCount = math.min(FILL_MAX_SHAKE_COUNT, FILL_BASE_SHAKE_COUNT + comboFactor)

	activeFillShakeThread = runRotationShake(hpLeftFrame, shakeCount, math.clamp(offset * 120, 0.35, 1.2), FILL_SHAKE_STEP)
end

local function setupUI()
	local battleUI = playerGui:WaitForChild("BattleUI")
	local hpLeft = battleUI:WaitForChild("HpLeft")
	local balanceBackground = hpLeft:WaitForChild("BalanceFrame")
	local balanceFill = balanceBackground:WaitForChild("BalanceFill")
	local balanceBase = balanceBackground:WaitForChild("BalanceBase")

	hpLeftFrame = hpLeft
	balanceFrame = balanceBackground
	balanceFillObj = balanceFill
	balanceBaseObj = balanceBase
	balanceFillOriginalColor = balanceFill[getTintProperty(balanceFill)]
	balanceBaseOriginalColor = balanceBase[getTintProperty(balanceBase)]

	-- Di-cache di sini, SEBELUM shake apa pun sempat jalan, supaya nilainya
	-- dijamin posisi asli dari layout -- bukan posisi offset sisa shake yang
	-- kepotong di tengah jalan.
	hpLeftOriginalPosition = hpLeft.Position

	-- Inisialisasi modul BarFill
	balanceBar = BarFill.new(balanceFill, "HpLeft.BalanceFill")
	balanceBaseBar = BarFill.new(balanceBase, "HpLeft.BalanceBase")

	-- Set Avatar Player
	local avatarImage = hpLeft:FindFirstChild("Avatar")
	if avatarImage then
		AvatarUtil.setThumbnail(avatarImage, localPlayer.UserId)
	else
		warn("[BalanceBarClient] BattleUI.HpLeft.Avatar (ImageLabel) tidak ditemukan — lewati foto profil")
	end

	-- Default nilai awal bar (Full/100%)
	balanceBar:snap(1)
	if balanceBaseBar then
		balanceBaseBar:snap(1)
	end

	if baseCatchupThread then
		task.cancel(baseCatchupThread)
		baseCatchupThread = nil
	end
	baseHoldStartClock = nil
	restoreBaseColor()

	if activePanelShakeThread then
		task.cancel(activePanelShakeThread)
		activePanelShakeThread = nil
	end
	if activeFillShakeThread then
		task.cancel(activeFillShakeThread)
		activeFillShakeThread = nil
	end
	incomingComboCount = 0
	lastIncomingHitClock = 0
end

-- Inisialisasi UI Pertama Kali
setupUI()

-- Tangani re-binding jika GUI di-reset saat respawn (ResetOnSpawn)
playerGui.ChildAdded:Connect(function(child)
	if child.Name == "BattleUI" then
		setupUI()
	end
end)

-- Update visual balance bar
local function updateBalanceUI(newBalance)
	if not balanceBar then return end
	if typeof(newBalance) ~= "number" then return end

	-- Clamp nilai agar selalu berada di antara 0 dan 100
	local clampedBalance = math.clamp(newBalance, 0, 100)

	-- Konversi ke skala 0 - 1 untuk BarFill (UIGradient)
	local ratio = clampedBalance / 100

	local previousRatio = balanceBar.target

	-- BalanceFill (hijau): langsung drop tanpa animasi, ini yang keliatan
	-- "kena damage" secara instan.
	balanceBar:snap(ratio)

	-- Efek visual pas kena damage beneran (bukan pas naik/recovery).
	--
	-- Ambangnya MIN_DROP_FOR_FLASH, bukan 0.0001 lagi -- alasan lengkapnya
	-- ada di komentar konstanta itu: decay pasif masuk lewat event yang sama
	-- persis kayak pukulan, jadi ambang lama bikin pemain yang cuma diam
	-- kelihatan kayak lagi dipukulin tiap detik.
	if ratio < previousRatio - MIN_DROP_FOR_FLASH then
		local now = os.clock()

		if now - lastIncomingHitClock <= BASE_CATCHUP_DELAY then
			incomingComboCount += 1
		else
			incomingComboCount = 1
		end
		lastIncomingHitClock = now

		flashDamage()
		shakePanel(previousRatio - ratio, incomingComboCount)
		shakeFill(previousRatio - ratio, incomingComboCount)
	end

	if not balanceBaseBar then return end

	-- Batalkan jadwal susul sebelumnya kalau ada serangan lanjutan masuk
	-- sebelum combo window abis -> BalanceBase (merah) ketahan dulu.
	if baseCatchupThread then
		task.cancel(baseCatchupThread)
		baseCatchupThread = nil
	end

	-- Balance naik (recovery/FFYL) -> merah ikut naik bareng, gak perlu delay.
	if ratio >= balanceBaseBar.target then
		baseHoldStartClock = nil
		restoreBaseColor()
		balanceBaseBar:set(ratio)
		return
	end

	-- Balance turun -> tunggu combo window, baru BalanceBase nyusul turun
	-- dengan durasi TETAP (BASE_SHRINK_DURATION) + easing, bukan speed-based
	-- lagi -- jadi berapa pun jauhnya jaraknya, animasi nyusutnya selalu
	-- kelar dalam waktu yang sama & terasa smooth (ngerem di ujung).
	--
	-- Deadline-nya diambil yang PALING CEPAT dari dua aturan:
	--   1. combo window sejak pukulan TERAKHIR (perilaku asli -- merah nunggu
	--      selama attacker masih dalam combo), dan
	--   2. BASE_MAX_HOLD sejak pukulan PERTAMA yang belum kesusul (batas baru).
	-- Aturan 2 yang bikin merah tetap turun bertahap pas pemain digebukin
	-- non-stop; tanpa itu aturan 1 ke-reset terus dan merah nyangkut penuh.
	local nowClock = os.clock()
	if not baseHoldStartClock then
		baseHoldStartClock = nowClock
	end

	local deadline = math.min(nowClock + BASE_CATCHUP_DELAY, baseHoldStartClock + BASE_MAX_HOLD)
	local holdDuration = math.max(0, deadline - nowClock)

	baseCatchupThread = task.delay(holdDuration, function()
		baseCatchupThread = nil
		-- Dinolkan supaya pukulan berikutnya mulai jendela hold yang BARU,
		-- bukan nerusin jendela lama yang udah kepakai habis.
		baseHoldStartClock = nil
		balanceBaseBar:tweenTo(ratio, BalanceConfig.BASE_SHRINK_DURATION)
	end)
end

-- Listener dari Server
SyncBalanceEvent.OnClientEvent:Connect(updateBalanceUI)

print("[UIManager] Listener SyncBalanceEvent di Client Aktif!")