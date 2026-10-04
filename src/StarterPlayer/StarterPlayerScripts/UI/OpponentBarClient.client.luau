
--[[
    Nama File  : OpponentBarClient
    Layer      : Client (UI)
    Deskripsi  : Mengisi panel stat lawan (BattleUI > HpRight) dari data yang
                 dikirim server lewat SyncOpponentStatsEvent.
    Tanggal    : 01 Agustus 2026
    Versi      : 1.0
    Dependensi : - ReplicatedStorage > Remotes > SyncOpponentStatsEvent
                 - StarterGui > BattleUI > HpRight
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local SyncOpponentStatsEvent = Remotes:WaitForChild("SyncOpponentStatsEvent")
local SyncOpponentEvent = Remotes:WaitForChild("SyncOpponentEvent", 15)

local BalanceConfig = require(
	ReplicatedStorage:WaitForChild("Configs"):WaitForChild("BalanceConfig")
)

local EnergyConfig = require(
	ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EnergyConfig")
)

local GameplayConfig = require(
	ReplicatedStorage:WaitForChild("Configs"):WaitForChild("GameplayConfig")
)

-- Delay sebelum BalanceBase (merah) nyusul turun, samain sama combo window
-- di server (ComboService) biar konsisten sama bar milik sendiri.
local BASE_CATCHUP_DELAY = GameplayConfig.COMBO_WINDOW

-- Batas maksimum hold merah, sama persis kayak di BalanceBarClient (alasan
-- lengkapnya ada di komentar BalanceConfig.BASE_MAX_HOLD_DURATION): tanpa ini
-- merah di panel lawan nyangkut penuh selama lawan digebukin beruntun.
local BASE_MAX_HOLD = math.max(BalanceConfig.BASE_MAX_HOLD_DURATION or 4, BASE_CATCHUP_DELAY)

-- ================================================================
-- EFEK KENA DAMAGE (flash + shake) -- sama polanya kayak BalanceBarClient
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

local BASE_SHAKE_COUNT = 3
local BASE_SHAKE_OFFSET = 0.0012
local SHAKE_STEP = 0.03
local COMBO_SHAKE_BONUS = 0.0005
local MAX_SHAKE_OFFSET = 0.005
local MAX_SHAKE_COUNT = 7

-- Shake BALANCE FILL (bar hijau doang) -- reaksi UTAMA pas lawan kena
-- damage, jauh lebih kenceng & lebih cepat dari shake panel di atas.
local FILL_BASE_SHAKE_COUNT = 4
local FILL_BASE_SHAKE_OFFSET = 0.02
local FILL_SHAKE_STEP = 0.02
local FILL_COMBO_SHAKE_BONUS = 0.008
local FILL_MAX_SHAKE_OFFSET = 0.055
local FILL_MAX_SHAKE_COUNT = 9

local balanceFillOriginalColor, balanceBaseOriginalColor = nil, nil

-- Pegangan tahap putih -> merah. Lihat catatan di BalanceBarClient.
local baseColorTween = nil
local baseWhiteThread = nil
local activePanelShakeThread = nil
local activeFillShakeThread = nil

-- Combo hit yang lagi kena ke lawan, dihitung dari drop balance-nya sendiri
-- (bukan dari AttackResultEvent) supaya waktunya selalu pas sama momen bar
-- turun -- comboUpdate dari server kadang nyampe telat 1 hit dibanding sync
-- balance-nya.
local incomingComboCount = 0
local lastIncomingHitClock = 0

-- ================================================================
-- UI REFERENCES
-- ================================================================

local battleUI = playerGui:WaitForChild("BattleUI")
local hpRight = battleUI:WaitForChild("HpRight")

local function findFill(frameName, fillName)
	local frame = hpRight:FindFirstChild(frameName)

	if not frame then
		warn(
			"[OpponentBarClient] BattleUI.HpRight."
				.. frameName
				.. " tidak ditemukan"
		)
		return nil
	end

	local fill = frame:FindFirstChild(fillName)

	if not fill then
		warn(
			"[OpponentBarClient] BattleUI.HpRight."
				.. frameName
				.. "."
				.. fillName
				.. " tidak ditemukan"
		)
	end

	return fill
end

local balanceFill = findFill("BalanceFrame", "BalanceFill")
local balanceBase = findFill("BalanceFrame", "BalanceBase")
local energyFill = findFill("EnergyFrame", "EnergyFill")

local BarFill = require(script.Parent:WaitForChild("BarFill"))

local balanceBar = BarFill.new(
	balanceFill,
	"HpRight.BalanceFill"
)

local balanceBaseBar = BarFill.new(
	balanceBase,
	"HpRight.BalanceBase"
)

local energyBar = BarFill.new(
	energyFill,
	"HpRight.EnergyFill"
)

if balanceFill then
	balanceFillOriginalColor = balanceFill:IsA("ImageLabel") and balanceFill.ImageColor3 or balanceFill.BackgroundColor3
end
if balanceBase then
	balanceBaseOriginalColor = balanceBase:IsA("ImageLabel") and balanceBase.ImageColor3 or balanceBase.BackgroundColor3
end

if balanceBar then
	balanceBar:snap(1)
end
if balanceBaseBar then
	balanceBaseBar:snap(1)
end

local baseCatchupThread = nil

-- Pukulan pertama yang belum kesusul merah. Lihat catatan di BalanceBarClient.
local baseHoldStartClock = nil

local function getTintProperty(obj)
	if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		return "ImageColor3"
	end
	return "BackgroundColor3"
end

-- Putih dulu, baru merah -- urutan & alasannya sama persis kayak
-- BalanceBarClient (lihat komentar panjang di sana).
local function flashDamage()
	if balanceFill then
		balanceFill[getTintProperty(balanceFill)] = FLASH_COLOR

		task.delay(FILL_FLASH_DURATION, function()
			if balanceFill and balanceFillOriginalColor then
				balanceFill[getTintProperty(balanceFill)] = balanceFillOriginalColor
			end
		end)
	end

	if not balanceBase or not balanceBaseOriginalColor then return end

	if baseColorTween then
		baseColorTween:Cancel()
		baseColorTween = nil
	end
	if baseWhiteThread then
		task.cancel(baseWhiteThread)
		baseWhiteThread = nil
	end

	local baseProp = getTintProperty(balanceBase)
	balanceBase[baseProp] = FLASH_COLOR

	baseWhiteThread = task.delay(BASE_WHITE_HOLD, function()
		baseWhiteThread = nil
		if not balanceBase or not balanceBaseOriginalColor then return end

		baseColorTween = TweenService:Create(
			balanceBase,
			TweenInfo.new(BASE_WHITE_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ [baseProp] = balanceBaseOriginalColor }
		)
		baseColorTween:Play()
	end)
end

-- Balikin BalanceBase ke merah sekarang juga (dipakai pas balance lawan NAIK:
-- recovery FFYL / ronde baru), biar gak ada putih yang nyangkut.
local function restoreBaseColor()
	if baseColorTween then
		baseColorTween:Cancel()
		baseColorTween = nil
	end
	if baseWhiteThread then
		task.cancel(baseWhiteThread)
		baseWhiteThread = nil
	end

	if balanceBase and balanceBaseOriginalColor then
		balanceBase[getTintProperty(balanceBase)] = balanceBaseOriginalColor
	end
end

-- Helper umum: geser posisi X sebuah GuiObject bolak-balik sejumlah `count`
-- kali sejauh `offset` (scale), balik ke posisi asli di akhir.
local function runRotationShake(obj, count, angle, step)
	return task.spawn(function()
		for _ = 1, count do
			obj.Rotation = angle
			task.wait(step)
			obj.Rotation = -angle
			task.wait(step)
		end
		obj.Rotation = 0
	end)
end

-- dropRatio: seberapa besar balance lawan turun (0-1), makin gede makin berat hitnya.
-- Shake PANEL -- tipis, cuma ambience.
local function shakePanel(dropRatio, comboCount)
	if not hpRight then return end

	if activePanelShakeThread then
		task.cancel(activePanelShakeThread)
		activePanelShakeThread = nil
	end

	local heavyFactor = math.clamp(dropRatio / (BalanceConfig.HEAVY_HIT / BalanceConfig.MAX_BALANCE), 0.5, 1.5)
	local comboFactor = math.max(0, comboCount - 1)

	local offset = math.min(MAX_SHAKE_OFFSET, (BASE_SHAKE_OFFSET * heavyFactor) + (comboFactor * COMBO_SHAKE_BONUS))
	local shakeCount = math.min(MAX_SHAKE_COUNT, BASE_SHAKE_COUNT + comboFactor)

	activePanelShakeThread = runRotationShake(hpRight, shakeCount, math.clamp(offset * 80, 0.2, 0.8), SHAKE_STEP)
end

-- Shake BALANCE FILL -- reaksi UTAMA pas lawan kena damage, jauh lebih kenceng.
local function shakeFill(dropRatio, comboCount)
	if not balanceFill then return end

	if activeFillShakeThread then
		task.cancel(activeFillShakeThread)
		activeFillShakeThread = nil
	end

	local heavyFactor = math.clamp(dropRatio / (BalanceConfig.HEAVY_HIT / BalanceConfig.MAX_BALANCE), 0.5, 1.5)
	local comboFactor = math.max(0, comboCount - 1)

	local offset = math.min(FILL_MAX_SHAKE_OFFSET, (FILL_BASE_SHAKE_OFFSET * heavyFactor) + (comboFactor * FILL_COMBO_SHAKE_BONUS))
	local shakeCount = math.min(FILL_MAX_SHAKE_COUNT, FILL_BASE_SHAKE_COUNT + comboFactor)

	activeFillShakeThread = runRotationShake(hpRight, shakeCount, math.clamp(offset * 120, 0.35, 1.2), FILL_SHAKE_STEP)
end

-- ================================================================
-- OPPONENT AVATAR
-- ================================================================

local AvatarUtil = require(script.Parent:WaitForChild("AvatarUtil"))
local avatarImage = hpRight:FindFirstChild("Avatar")

if not avatarImage then
	warn(
		"[OpponentBarClient] BattleUI.HpRight.Avatar tidak ditemukan"
	)
end

if SyncOpponentEvent and avatarImage then
	SyncOpponentEvent.OnClientEvent:Connect(function(opponent)
		if opponent then
			AvatarUtil.setThumbnail(avatarImage, opponent.UserId)
		else
			AvatarUtil.clear(avatarImage)
		end
	end)
elseif not SyncOpponentEvent then
	warn(
		"[OpponentBarClient] SyncOpponentEvent tidak ditemukan"
	)
end

-- ================================================================
-- STAT SYNC
-- ================================================================

SyncOpponentStatsEvent.OnClientEvent:Connect(function(statType, value)
	if statType == "balance" and balanceBar then
		local ratio = math.clamp(value / BalanceConfig.MAX_BALANCE, 0, 1)
		local previousRatio = balanceBar.target

		-- BalanceFill (hijau): drop instan pas lawan kena damage.
		balanceBar:snap(ratio)

		-- Ambang MIN_DROP_FOR_FLASH (bukan 0.0001) supaya tick decay pasif
		-- lawan gak kebaca sebagai pukulan. Lihat catatan di BalanceBarClient.
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

		if baseCatchupThread then
			task.cancel(baseCatchupThread)
			baseCatchupThread = nil
		end

		if ratio >= balanceBaseBar.target then
			-- Naik (recovery) -> merah ikut naik langsung, gak perlu delay.
			baseHoldStartClock = nil
			restoreBaseColor()
			balanceBaseBar:set(ratio)
		else
			-- Turun -> tunggu combo window dulu, baru BalanceBase nyusul
			-- dengan durasi TETAP + easing (lihat BarFill:tweenTo).
			--
			-- Deadline = yang paling cepat antara "combo window sejak pukulan
			-- TERAKHIR" dan "BASE_MAX_HOLD sejak pukulan PERTAMA yang belum
			-- kesusul". Aturan kedua yang bikin merah gak nyangkut penuh pas
			-- lawan kena pukul terus-terusan.
			local nowClock = os.clock()
			if not baseHoldStartClock then
				baseHoldStartClock = nowClock
			end

			local deadline = math.min(nowClock + BASE_CATCHUP_DELAY, baseHoldStartClock + BASE_MAX_HOLD)
			local holdDuration = math.max(0, deadline - nowClock)

			baseCatchupThread = task.delay(holdDuration, function()
				baseCatchupThread = nil
				baseHoldStartClock = nil
				balanceBaseBar:tweenTo(ratio, BalanceConfig.BASE_SHRINK_DURATION)
			end)
		end
	elseif statType == "energy" and energyBar then
		energyBar:set(value / EnergyConfig.MAX_ENERGY)
	end
end)

print("[OpponentBarClient] Listener SyncOpponentStatsEvent aktif")	