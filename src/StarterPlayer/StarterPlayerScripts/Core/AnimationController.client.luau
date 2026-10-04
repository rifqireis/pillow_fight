-- @ScriptType: LocalScript
--[[
    Nama File  : AnimationController
    Layer      : Client (Animation)
    Deskripsi  : Mengelola semua animasi pertempuran dengan transisi halus.
                 Mendengarkan sinyal dari server (AttackResultEvent) dan lokal (LocalAnimEvent).
                 Mendukung: Attack, Hurt, Dodge, Stun, Fall, Rise, Start, FFYL, dan Idle.
    Penulis    : Abdul VVI
    Tanggal    : 24 Juli 2026
    Versi      : 2.0
    Dependensi : AttackResultEvent, AnimationConfig, LocalAnimEvent, SyncMatchStateEvent
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local AnimationConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("AnimationConfig"))

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local animator = humanoid:WaitForChild("Animator")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local attackResultEvent = Remotes:WaitForChild("AttackResultEvent")
local syncMatchStateEvent = Remotes:WaitForChild("SyncMatchStateEvent")
local localAnimEvent = script.Parent:WaitForChild("LocalAnimEvent")

-- Cache & State
local tracks = {}
local lightAnimIndex = 1
local hurtAnimIndex = 1

local currentActionTrack = nil
local isInFFYL = false
local isStunned = false

-- Lacak track yang diprediksi per actionType (light/heavy/dodge), dipakai
-- buat validasi penolakan server (lihat attackResultEvent listener di bawah)
-- supaya penolakan attempt LAMA gak nyetop animasi attempt BARU yang sah.
local pendingPredictedTrack = {}

-- Helper: Ambil fade time dari config
local function getFadeTime(actionType, isStop)
	if isStop then
		return AnimationConfig.FADE_TIME.STOP or 0.2
	end

	local fadeMap = {
		light     = AnimationConfig.FADE_TIME.ATTACK,
		heavy     = AnimationConfig.FADE_TIME.ATTACK,
		dodge     = AnimationConfig.FADE_TIME.DODGE,
		stun      = AnimationConfig.FADE_TIME.STUN,
		fall      = AnimationConfig.FADE_TIME.STUN,
		rise      = AnimationConfig.FADE_TIME.RISE,
		start     = AnimationConfig.FADE_TIME.DEFAULT,
		lightHurt = AnimationConfig.FADE_TIME.HURT,
		heavyHurt = AnimationConfig.FADE_TIME.HURT,
		startFFYL = AnimationConfig.FADE_TIME.FFYL,
		endFFYL   = AnimationConfig.FADE_TIME.FFYL,
		defeat    = AnimationConfig.FADE_TIME.DEFEAT,
		idle      = AnimationConfig.FADE_TIME.IDLE,
	}

	return fadeMap[actionType] or AnimationConfig.FADE_TIME.DEFAULT or 0.15
end

-- Helper: Ambil speed dari config
local function getSpeed(actionType)
	return AnimationConfig.SPEED[actionType] or 1.0
end

-- Helper: Ambil weight dari config
local function getWeight(actionType)
	return AnimationConfig.WEIGHT[actionType] or 1.0
end

-- Helper: Preload asset animasi via ContentProvider
local function preloadAllAnimations()
	local assetsToPreload = {}

	local function collectIds(configTable)
		for _, animData in pairs(configTable) do
			if type(animData) == "table" then
				for _, id in ipairs(animData) do
					if id ~= "" then
						local anim = Instance.new("Animation")
						anim.AnimationId = id
						table.insert(assetsToPreload, anim)
					end
				end
			elseif type(animData) == "string" and animData ~= "" then
				local anim = Instance.new("Animation")
				anim.AnimationId = animData
				table.insert(assetsToPreload, anim)
			end
		end
	end

	collectIds(AnimationConfig.COMBAT_ANIMATIONS)
	collectIds(AnimationConfig.HURT_ANIMATIONS)
	collectIds(AnimationConfig.FFYL_ANIMATIONS)

	if #assetsToPreload > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(assetsToPreload)
		end)
	end
end

-- Inisialisasi set animasi ke Animator
local function loadAnimationSet(configTable, priorityLevel)
	for actionType, animData in pairs(configTable) do
		if type(animData) == "table" then
			tracks[actionType] = {}
			for _, animId in ipairs(animData) do
				if animId ~= "" then
					local animInstance = Instance.new("Animation")
					animInstance.AnimationId = animId

					local track = animator:LoadAnimation(animInstance)
					track.Priority = priorityLevel
					track.Looped = (actionType == "fall" or actionType == "stun")
					table.insert(tracks[actionType], track)
				end
			end
		else
			local animId = animData
			if animId ~= "" then
				local animInstance = Instance.new("Animation")
				animInstance.AnimationId = animId

				local track = animator:LoadAnimation(animInstance)
				track.Priority = priorityLevel
				track.Looped = (actionType == "fall" or actionType == "stun")
				tracks[actionType] = track
			end
		end
	end
end

-- Warm-up: paksa keyframe tiap AnimationTrack ke-download sekarang, bukan
-- pas pertama kali beneran dipakai di combat. Play(0,0,1) lalu Stop(0)
-- langsung -> weight 0 & fade time 0 jadi gak keliatan di karakter, tapi
-- Roblox tetap streaming data keyframe-nya. Ini yang nutup bug damage
-- gak ke-detect pas swing pertama kali pakai suatu animasi.
local function warmUpTracks(trackTable)
	for _, trackData in pairs(trackTable) do
		if typeof(trackData) == "Instance" and trackData:IsA("AnimationTrack") then
			local ok = pcall(function()
				trackData:Play(0, 0, 1)
				trackData:Stop(0)
			end)
		elseif type(trackData) == "table" then
			for _, t in ipairs(trackData) do
				if typeof(t) == "Instance" and t:IsA("AnimationTrack") then
					pcall(function()
						t:Play(0, 0, 1)
						t:Stop(0)
					end)
				end
			end
		end
	end
end

-- Load Animasi Awal
loadAnimationSet(AnimationConfig.COMBAT_ANIMATIONS, Enum.AnimationPriority.Action)
loadAnimationSet(AnimationConfig.HURT_ANIMATIONS, Enum.AnimationPriority.Action2)
loadAnimationSet(AnimationConfig.FFYL_ANIMATIONS, Enum.AnimationPriority.Action4)
warmUpTracks(tracks)

if AnimationConfig.DEFEAT_ANIMATION and AnimationConfig.DEFEAT_ANIMATION ~= "" then
	local defeatAnim = Instance.new("Animation")
	defeatAnim.AnimationId = AnimationConfig.DEFEAT_ANIMATION
	local defeatTrack = animator:LoadAnimation(defeatAnim)
	defeatTrack.Priority = Enum.AnimationPriority.Action4
	defeatTrack.Looped = false
	tracks["defeat"] = defeatTrack
end

if AnimationConfig.MATCH_IDLE and AnimationConfig.MATCH_IDLE ~= "" then
	local idleAnim = Instance.new("Animation")
	idleAnim.AnimationId = AnimationConfig.MATCH_IDLE
	local idleTrack = animator:LoadAnimation(idleAnim)
	idleTrack.Priority = Enum.AnimationPriority.Movement
	idleTrack.Looped = true
	tracks["idle"] = idleTrack
end

-- Helper: Stop semua track dari tipe tertentu
local function stopAllTracksOf(actionType, fadeOut)
	local trackData = tracks[actionType]
	if not trackData then return end
	if type(trackData) == "table" then
		for _, t in ipairs(trackData) do
			if t.IsPlaying then t:Stop(fadeOut) end
		end
	elseif typeof(trackData) == "Instance" and trackData.IsPlaying then
		trackData:Stop(fadeOut)
	end
end

-- Hentikan animasi berkonflik secara halus
local function stopConflictingAnimations(actionType)
	local fadeOut = getFadeTime(actionType, true)

	if actionType == "stun" then
		if currentActionTrack and currentActionTrack.IsPlaying then
			currentActionTrack:Stop(fadeOut)
			currentActionTrack = nil
		end
		stopAllTracksOf("lightHurt", fadeOut)
		stopAllTracksOf("heavyHurt", fadeOut)
		stopAllTracksOf("dodge", fadeOut)
	end

	if actionType == "fall" then
		if currentActionTrack and currentActionTrack.IsPlaying then
			currentActionTrack:Stop(fadeOut)
			currentActionTrack = nil
		end
		stopAllTracksOf("lightHurt", fadeOut)
		stopAllTracksOf("heavyHurt", fadeOut)
	end

	if actionType == "rise" or actionType == "start" or actionType == "endFFYL" then
		stopAllTracksOf("fall", fadeOut)
		stopAllTracksOf("stun", fadeOut)
		stopAllTracksOf("startFFYL", fadeOut)
		stopAllTracksOf("defeat", fadeOut)
	end

	if actionType == "light" or actionType == "heavy" or actionType == "dodge" then
		if currentActionTrack and currentActionTrack.IsPlaying then
			currentActionTrack:Stop(0.05)
		end
		stopAllTracksOf("lightHurt", 0.05)
		stopAllTracksOf("heavyHurt", 0.05)
		stopAllTracksOf("start", 0.05)
		stopAllTracksOf("rise", 0.05)
	end

	if actionType == "lightHurt" or actionType == "heavyHurt" then
		if currentActionTrack and currentActionTrack.IsPlaying then
			currentActionTrack:Stop(fadeOut)
			currentActionTrack = nil
		end
		stopAllTracksOf("lightHurt", 0.05)
		stopAllTracksOf("heavyHurt", 0.05)
	end

	if actionType == "startFFYL" then
		if currentActionTrack and currentActionTrack.IsPlaying then
			currentActionTrack:Stop(fadeOut)
			currentActionTrack = nil
		end
		stopAllTracksOf("lightHurt", fadeOut)
		stopAllTracksOf("heavyHurt", fadeOut)
		stopAllTracksOf("stun", fadeOut)
		stopAllTracksOf("fall", fadeOut)
	end

	if actionType == "defeat" then
		if currentActionTrack and currentActionTrack.IsPlaying then
			currentActionTrack:Stop(fadeOut)
			currentActionTrack = nil
		end
		stopAllTracksOf("lightHurt", fadeOut)
		stopAllTracksOf("heavyHurt", fadeOut)
		stopAllTracksOf("stun", fadeOut)
		stopAllTracksOf("fall", fadeOut)
		stopAllTracksOf("startFFYL", fadeOut)
	end
end

-- Memutar animasi
local function playAnimation(actionType, variantIndex)
	local trackData = tracks[actionType]
	if not trackData then return end

	stopConflictingAnimations(actionType)

	local track

	if type(trackData) == "table" then
		if variantIndex and variantIndex <= #trackData then
			track = trackData[variantIndex]
		elseif actionType == "light" then
			track = trackData[lightAnimIndex]
			lightAnimIndex = (lightAnimIndex % #trackData) + 1
		elseif actionType == "lightHurt" then
			track = trackData[hurtAnimIndex]
			hurtAnimIndex = (hurtAnimIndex % #trackData) + 1
		else
			track = trackData[math.random(1, #trackData)]
		end
	else
		track = trackData
	end

	if not track then return end

	local fadeIn = getFadeTime(actionType, false)
	local speed  = getSpeed(actionType)
	local weight = getWeight(actionType)

	track:Stop(0)
	track:Play(fadeIn, weight, speed)

	if actionType == "light" or actionType == "heavy" or actionType == "dodge" then
		currentActionTrack = track
		pendingPredictedTrack[actionType] = track
	end
end

-- Hentikan animasi
local function stopAnimation(actionType)
	local trackData = tracks[actionType]
	if not trackData then return end

	local fadeOut = getFadeTime(actionType, true)

	if type(trackData) == "table" then
		for _, t in ipairs(trackData) do
			if t.IsPlaying then t:Stop(fadeOut) end
		end
	elseif typeof(trackData) == "Instance" and trackData.IsPlaying then
		trackData:Stop(fadeOut)
	end
end

-- Event Listener: Client-Side Prediction
localAnimEvent.Event:Connect(function(actionType)
	if actionType == "impact" then return end
	if isStunned or isInFFYL then return end

	playAnimation(actionType)
end)

-- Event Listener: Server Authoritative
attackResultEvent.OnClientEvent:Connect(function(actionType, success, extraData)
	if actionType == "idle" then
		local idleTrack = tracks["idle"]
		if idleTrack and not idleTrack.IsPlaying then
			local fadein = getFadeTime("idle", false)
			idleTrack:Play(fadein)
		end
		return
	end

	if actionType == "hitConfirm" then return end

	if actionType == "stun_end" then
		isStunned = false
		stopAnimation("stun")
		return
	end

	if actionType == "startFFYL" then
		isInFFYL = true
		playAnimation("startFFYL")
		return
	end

	if actionType == "endFFYL" then
		isInFFYL = false
		playAnimation("endFFYL")
		return
	end

	if actionType == "defeat" then
		isInFFYL = false
		playAnimation("defeat")
		return
	end

	if not success then
		if actionType == "light" or actionType == "heavy" or actionType == "dodge" then
			-- Cuma stop kalau track yang ditolak ini MASIH yang lagi aktif
			-- sekarang. Kalau currentActionTrack udah beda (attempt baru
			-- yang valid udah keburu mulai), jangan diapa-apain -- biar
			-- gak nyetop animasi input terbaru cuma gara-gara penolakan
			-- basi buat attempt sebelumnya.
			local predicted = pendingPredictedTrack[actionType]
			if predicted and predicted == currentActionTrack then
				local fadeOut = getFadeTime(actionType, true)
				if predicted.IsPlaying then
					predicted:Stop(fadeOut)
				end
				currentActionTrack = nil
			end
		else
			stopAnimation(actionType)
		end
		return
	end

	if actionType == "lightHurt" then
		local variantIdx = (type(extraData) == "number") and extraData or nil
		playAnimation("lightHurt", variantIdx)
		return
	end

	if actionType == "heavyHurt" then
		playAnimation("heavyHurt")
		return
	end

	if actionType ~= "light" and actionType ~= "heavy" and actionType ~= "dodge" then
		if actionType == "stun" then
			isStunned = true
		end
		playAnimation(actionType)
	end
end)

-- Event Listener: Match State
syncMatchStateEvent.OnClientEvent:Connect(function(isPlaying)
	if isPlaying then
		isInFFYL = false
		isStunned = false
		currentActionTrack = nil

		stopAnimation("startFFYL")
		stopAnimation("fall")
		stopAnimation("stun")
		stopAnimation("defeat")
	end

	local idleTrack = tracks["idle"]
	if not idleTrack then return end

	if isPlaying then
		local fadein = getFadeTime("idle", false)
		idleTrack:Play(fadein)
	else
		local fadeout = getFadeTime("idle", true)
		idleTrack:Stop(fadeout)

		isInFFYL = false
		isStunned = false
		currentActionTrack = nil
		lightAnimIndex = 1
		hurtAnimIndex = 1
	end
end)

-- Reset & reload saat karakter respawn
player.CharacterAdded:Connect(function(newCharacter)
	character = newCharacter
	humanoid = character:WaitForChild("Humanoid")
	animator = humanoid:WaitForChild("Animator")

	tracks = {}
	currentActionTrack = nil
	lightAnimIndex = 1
	hurtAnimIndex = 1
	isInFFYL = false

	preloadAllAnimations()
	loadAnimationSet(AnimationConfig.COMBAT_ANIMATIONS, Enum.AnimationPriority.Action)
	loadAnimationSet(AnimationConfig.HURT_ANIMATIONS, Enum.AnimationPriority.Action2)
	loadAnimationSet(AnimationConfig.FFYL_ANIMATIONS, Enum.AnimationPriority.Action4)
	warmUpTracks(tracks)

	if AnimationConfig.DEFEAT_ANIMATION and AnimationConfig.DEFEAT_ANIMATION ~= "" then
		local defeatAnim = Instance.new("Animation")
		defeatAnim.AnimationId = AnimationConfig.DEFEAT_ANIMATION
		local defeatTrack = animator:LoadAnimation(defeatAnim)
		defeatTrack.Priority = Enum.AnimationPriority.Action4
		defeatTrack.Looped = false
		tracks["defeat"] = defeatTrack
	end

	if AnimationConfig.MATCH_IDLE and AnimationConfig.MATCH_IDLE ~= "" then
		local idleAnim = Instance.new("Animation")
		idleAnim.AnimationId = AnimationConfig.MATCH_IDLE
		local idleTrack = animator:LoadAnimation(idleAnim)
		idleTrack.Priority = Enum.AnimationPriority.Movement
		idleTrack.Looped = true
		tracks["idle"] = idleTrack
	end
end)