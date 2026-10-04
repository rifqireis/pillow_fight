--[[
    Nama File  : SoundController.lua
    Layer      : Client (Sound)
    Deskripsi  : Menangani pemutaran efek suara client-side (Swing, Impact, dll).
                 Mendukung dynamic combo pitch, variasi anti-repetisi, dan safe respawn handling.
    Penulis    : System, Yusuf Ahayy
    Tanggal    : 24 Juli 2026
    Versi      : 1.1 (Refactored & Safe Respawn Fix)
    Dependensi : - LocalAnimEvent
                 - SoundConfig
                 - AttackResultEvent
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SoundConfig"))

local player = Players.LocalPlayer
local localAnimEvent = script.Parent:WaitForChild("LocalAnimEvent")
local attackResultEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AttackResultEvent")

-- === INISIALISASI SOUNDS & CONTAINER ===
local sounds = {}      -- sounds[soundName] = { Sound, Sound, ... }
local lastVariant = {} -- Varian terakhir yang dibunyikan

-- Buat Folder khusus di PlayerGui atau Character agar Sound terorganisir
local soundFolder = Instance.new("Folder")
soundFolder.Name = "CombatSounds"
soundFolder.Parent = player:WaitForChild("PlayerGui")

local function resolveSoundId(id)
	if typeof(id) == "number" then
		return "rbxassetid://" .. id
	end
	if type(id) ~= "string" or id == "" then
		return nil
	end
	if id:match("^%d+$") then
		return "rbxassetid://" .. id
	end
	return id
end

-- Dapatkan HumanoidRootPart saat ini secara aman (untuk penempelan audio 3D jika dibutuhkan)
local function getHRP()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Volume dasar tiap Sound disimpan terpisah supaya jitter & pengecilan
-- volume "suara lawan" selalu dihitung dari nilai asli, bukan dari volume
-- hasil pemutaran sebelumnya (kalau tidak, volumenya bakal melayang turun
-- atau naik terus tiap kali dibunyikan).
local baseVolume = {}

local function createSound(name, soundId)
	local soundInstance = Instance.new("Sound")
	soundInstance.Name = name
	soundInstance.SoundId = soundId
	soundInstance.Volume = 1
	-- Di-parent ke soundFolder (PlayerGui) agar tahan lama saat karakter Respawn
	soundInstance.Parent = soundFolder
	baseVolume[soundInstance] = soundInstance.Volume
	return soundInstance
end

for soundName, soundData in pairs(SoundConfig.COMBAT_SOUNDS) do
	local ids = (type(soundData) == "table") and soundData or { soundData }
	local variants = {}

	for index, rawId in ipairs(ids) do
		local soundId = resolveSoundId(rawId)
		if soundId then
			table.insert(variants, createSound(soundName .. "Sound" .. index, soundId))
		end
	end

	if #variants > 0 then
		sounds[soundName] = variants
		print("[SoundController] Suara " .. soundName .. " telah di-load (" .. #variants .. " varian).")
	end
end

-- === PLAYBACK HELPERS ===
local function getNextVariant(soundName)
	local variants = sounds[soundName]
	if not variants then return nil end

	local index = math.random(#variants)
	if #variants > 1 and index == lastVariant[soundName] then
		index = (index % #variants) + 1
	end
	lastVariant[soundName] = index

	return variants[index]
end

local PITCH_JITTER  = SoundConfig.PITCH_JITTER or 0
local VOLUME_JITTER = SoundConfig.VOLUME_JITTER or 0

local OPPONENT_VOLUME_SCALE = SoundConfig.OPPONENT_VOLUME_SCALE or 1
local OPPONENT_PITCH_SCALE  = SoundConfig.OPPONENT_PITCH_SCALE or 1

-- Deviasi acak simetris: jitter(0.04) -> antara 0.96 dan 1.04.
local function jitter(amount)
	if amount <= 0 then return 1 end
	return 1 + (math.random() * 2 - 1) * amount
end

-- Satu-satunya jalur pemutaran. Semua pemanggil lewat sini supaya jitter,
-- pitch combo, dan pengecilan "suara lawan" tidak pernah kelewat di salah
-- satu jalur.
--   pitchScale  = pengali pitch tambahan (combo pitch / suara lawan)
--   volumeScale = pengali volume tambahan (suara lawan)
local function playSound(soundName, pitchScale, volumeScale)
	local sound = getNextVariant(soundName)
	if not sound then return end

	-- Selalu dihitung ulang dari nilai dasar, bukan dari nilai sebelumnya --
	-- ini yang mencegah pitch combo bocor ke pukulan berikutnya (dulu
	-- ditangani dengan reset manual ke 1 di jalur non-combo saja).
	sound.PlaybackSpeed = (pitchScale or 1) * jitter(PITCH_JITTER)
	sound.Volume = (baseVolume[sound] or 1) * (volumeScale or 1) * jitter(VOLUME_JITTER)
	sound.TimePosition = 0
	sound:Play()
end

-- === COMBO PITCH CONFIG ===
local COMBO_PITCH_STEP = 0.02  -- Kenaikan pitch per combo count
local COMBO_PITCH_MAX  = 0.3   -- Batas atas kenaikan pitch
local lastComboCount   = 0

local COMBO_MILESTONE_STEP = SoundConfig.COMBO_MILESTONE_STEP or 5

local function playSoundWithComboPitch(soundName)
	local pitchBonus = math.min(lastComboCount * COMBO_PITCH_STEP, COMBO_PITCH_MAX)
	playSound(soundName, 1 + pitchBonus)
end

-- Suara yang datang dari lawan: lebih pelan & sedikit lebih rendah, supaya
-- bisa dibedakan dari suara sendiri walau asset-nya sama.
local function playOpponentSound(soundName)
	playSound(soundName, OPPONENT_PITCH_SCALE, OPPONENT_VOLUME_SCALE)
end

-- === EVENT LISTENERS ===
localAnimEvent.Event:Connect(function(actionType)
	if actionType:match("impact") then
		if sounds[actionType] then
			playSound(actionType)
		end
		return
	end

	if actionType == "light" or actionType == "heavy" or actionType == "dodge" then
		local soundName = actionType .. (actionType == "dodge" and "" or "_swing")
		playSound(soundName)
	end
end)

local function playImpact(attackType, useComboPitch)
	local soundKey = attackType .. "_impact"
	if useComboPitch then
		playSoundWithComboPitch(soundKey)
	else
		playSound(soundKey)
	end
end

attackResultEvent.OnClientEvent:Connect(function(actionType, success, extraData)
	if not success then return end

	if actionType == "comboUpdate" then
		local previous = lastComboCount

		if type(extraData) == "number" then
			lastComboCount = extraData
		end

		-- Bunyi milestone tiap kelipatan COMBO_MILESTONE_STEP, dan hanya saat
		-- combo BARU melewatinya (bukan tiap pukulan sesudahnya). Dicek dengan
		-- membandingkan ke nilai sebelumnya supaya reset combo ke 0 lalu naik
		-- lagi tidak membunyikan milestone dua kali di angka yang sama.
		if lastComboCount > previous
			and lastComboCount > 0
			and lastComboCount % COMBO_MILESTONE_STEP == 0
		then
			playSound("combo_milestone")
		end
		return
	end

	if actionType == "hitConfirm" then
		playImpact(extraData == "heavy" and "heavy" or "light", true)

	elseif actionType == "lightHurt" then
		playImpact("light")

	elseif actionType == "heavyHurt" then
		playImpact("heavy")

	elseif actionType == "opponentSwing" then
		-- Tanda audio bahwa lawan MULAI mengayun -- ini yang bikin heavy bisa
		-- dibaca dan di-dodge secara reaktif, bukan cuma ditebak. Sebelumnya
		-- pemain nol informasi audio soal serangan lawan.
		playOpponentSound(extraData == "heavy" and "heavy_swing" or "light_swing")

	elseif actionType == "perfectDodge" then
		playSound("perfect_dodge")

	elseif actionType == "stun" then
		playSound("stun")
	end
end)

-- KO: KOEvent ditembak ke kedua pemain di akhir ronde. Dipasang opsional
-- (WaitForChild bertimeout) mengikuti pola CameraController -- remote di
-- project ini dibuat manual di Studio, jadi skrip tidak boleh mati kalau
-- kebetulan remote-nya belum ada.
local koEvent = ReplicatedStorage.Remotes:FindFirstChild("KOEvent")
if koEvent then
	koEvent.OnClientEvent:Connect(function()
		playSound("ko")
	end)
else
	warn("[SoundController] KOEvent tidak ketemu -- suara KO dilewati.")
end

print("[SoundController] Berhasil diinisialisasi")