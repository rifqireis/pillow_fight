-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- BotAnimationService
-- Server-side equivalent of StarterPlayerScripts/Core/AnimationController.
-- Bot tidak punya LocalScript, jadi SEMUA state animation harus dimainkan
-- langsung di Animator bot.

local BotAnimationService = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnimationConfig = require(ReplicatedStorage.Configs.AnimationConfig)

local animState = {}

local function loadTrack(animator, animId, priority, looped)
	if not animId or animId == "" then return nil end

	local anim = Instance.new("Animation")
	anim.AnimationId = animId

	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not track then
		anim:Destroy()
		return nil
	end

	track.Priority = priority
	track.Looped = looped == true
	return track
end

local function loadSet(animator, configTable, priority)
	local result = {}

	for actionType, animData in pairs(configTable) do
		if type(animData) == "table" then
			result[actionType] = {}
			for _, animId in ipairs(animData) do
				local track = loadTrack(
					animator,
					animId,
					priority,
					actionType == "fall" or actionType == "stun"
				)
				if track then
					table.insert(result[actionType], track)
				end
			end
		else
			local track = loadTrack(
				animator,
				animData,
				priority,
				actionType == "fall" or actionType == "stun"
			)
			if track then
				result[actionType] = track
			end
		end
	end

	return result
end

function BotAnimationService.attach(botPlayer)
	local character = botPlayer and botPlayer.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- Bersihkan state lama kalau bot di-attach ulang.
	BotAnimationService.detach(botPlayer)

	local tracks = {}
	for actionType, trackData in pairs(
		loadSet(animator, AnimationConfig.COMBAT_ANIMATIONS, Enum.AnimationPriority.Action)
		) do
		tracks[actionType] = trackData
	end

	for actionType, trackData in pairs(
		loadSet(animator, AnimationConfig.HURT_ANIMATIONS, Enum.AnimationPriority.Action2)
		) do
		tracks[actionType] = trackData
	end

	for actionType, trackData in pairs(
		loadSet(animator, AnimationConfig.FFYL_ANIMATIONS, Enum.AnimationPriority.Action4)
		) do
		tracks[actionType] = trackData
	end

	tracks.defeat = loadTrack(
		animator,
		AnimationConfig.DEFEAT_ANIMATION,
		Enum.AnimationPriority.Action4,
		false
	)

	tracks.idle = loadTrack(
		animator,
		AnimationConfig.MATCH_IDLE,
		Enum.AnimationPriority.Movement,
		true
	)

	animState[botPlayer] = {
		tracks = tracks,
		lightIndex = 1,
		hurtIndex = 1,
		currentActionTrack = nil,
	}

	-- Warm-up seluruh track supaya frame pertama tidak telat streaming.
	for _, trackData in pairs(tracks) do
		if typeof(trackData) == "Instance" and trackData:IsA("AnimationTrack") then
			pcall(function()
				trackData:Play(0, 0, 1)
				trackData:Stop(0)
			end)
		elseif type(trackData) == "table" then
			for _, track in ipairs(trackData) do
				pcall(function()
					track:Play(0, 0, 1)
					track:Stop(0)
				end)
			end
		end
	end
end

function BotAnimationService.detach(botPlayer)
	local state = animState[botPlayer]
	if not state then return end

	for _, trackData in pairs(state.tracks) do
		if typeof(trackData) == "Instance" and trackData:IsA("AnimationTrack") then
			pcall(function() trackData:Stop(0) end)
		elseif type(trackData) == "table" then
			for _, track in ipairs(trackData) do
				pcall(function() track:Stop(0) end)
			end
		end
	end

	animState[botPlayer] = nil
end

local function fade(actionType, stopping)
	if stopping then
		return AnimationConfig.FADE_TIME.STOP or 0.2
	end

	local map = {
		light = AnimationConfig.FADE_TIME.ATTACK,
		heavy = AnimationConfig.FADE_TIME.ATTACK,
		dodge = AnimationConfig.FADE_TIME.DODGE,
		stun = AnimationConfig.FADE_TIME.STUN,
		fall = AnimationConfig.FADE_TIME.STUN,
		rise = AnimationConfig.FADE_TIME.RISE,
		start = AnimationConfig.FADE_TIME.DEFAULT,
		lightHurt = AnimationConfig.FADE_TIME.HURT,
		heavyHurt = AnimationConfig.FADE_TIME.HURT,
		startFFYL = AnimationConfig.FADE_TIME.FFYL,
		endFFYL = AnimationConfig.FADE_TIME.FFYL,
		defeat = AnimationConfig.FADE_TIME.DEFEAT,
		idle = AnimationConfig.FADE_TIME.IDLE,
	}
	return map[actionType] or AnimationConfig.FADE_TIME.DEFAULT or 0.15
end

local function speed(actionType)
	return AnimationConfig.SPEED[actionType] or 1
end

local function weight(actionType)
	return AnimationConfig.WEIGHT[actionType] or 1
end

local function stopData(trackData, fadeOut)
	if typeof(trackData) == "Instance" and trackData:IsA("AnimationTrack") then
		if trackData.IsPlaying then trackData:Stop(fadeOut) end
	elseif type(trackData) == "table" then
		for _, track in ipairs(trackData) do
			if track.IsPlaying then track:Stop(fadeOut) end
		end
	end
end

local function stopType(state, actionType, fadeOut)
	stopData(state.tracks[actionType], fadeOut)
end

local function stopConflicts(state, actionType)
	local f = fade(actionType, true)

	-- Idle adalah baseline match, bukan overlay untuk action. Player client
	-- juga mematikan idle saat masuk action; bot harus punya lifecycle yang
	-- sama supaya track R6 tidak terus blend di bawah attack/fall/rise.
	if actionType ~= "idle" then
		stopType(state, "idle", math.min(f, 0.08))
	end

	if actionType == "stun" then
		stopData(state.currentActionTrack, f)
		state.currentActionTrack = nil
		stopType(state, "lightHurt", f)
		stopType(state, "heavyHurt", f)
		stopType(state, "dodge", f)

	elseif actionType == "fall" then
		stopData(state.currentActionTrack, f)
		state.currentActionTrack = nil
		stopType(state, "lightHurt", f)
		stopType(state, "heavyHurt", f)

		-- BUG FIX (animasi bot keliatan patah/skip pas kalah ronde biasa,
		-- bukan match-ending defeat): "fall" ditembak tepat setelah bot
		-- gagal minigame FFYL, sementara track "startFFYL" (looped, priority
		-- Action4) masih nyala dan belum pernah di-stop di cabang ini --
		-- beda dengan cabang "defeat" di bawah yang sudah benar. Priority
		-- startFFYL lebih tinggi dari fall (Action2), jadi dia "menang" dan
		-- fall keliatan ke-skip/gak jalan mulus sebelum akhirnya nyusul.
		-- Sama juga stun bisa nyangkut kalau sempat kena flinch pas
		-- FFYL gagal. Stop keduanya di sini, konsisten dengan "defeat".
		stopType(state, "stun", f)
		stopType(state, "startFFYL", f)

	elseif actionType == "rise" or actionType == "start" or actionType == "endFFYL" then
		stopType(state, "fall", f)
		stopType(state, "stun", f)
		stopType(state, "startFFYL", f)
		stopType(state, "defeat", f)

	elseif actionType == "light" or actionType == "heavy" or actionType == "dodge" then
		stopData(state.currentActionTrack, 0.05)
		state.currentActionTrack = nil
		stopType(state, "lightHurt", 0.05)
		stopType(state, "heavyHurt", 0.05)
		stopType(state, "start", 0.05)
		stopType(state, "rise", 0.05)

	elseif actionType == "lightHurt" or actionType == "heavyHurt" then
		stopData(state.currentActionTrack, f)
		state.currentActionTrack = nil
		stopType(state, "lightHurt", 0.05)
		stopType(state, "heavyHurt", 0.05)

	elseif actionType == "startFFYL" then
		stopData(state.currentActionTrack, f)
		state.currentActionTrack = nil
		stopType(state, "lightHurt", f)
		stopType(state, "heavyHurt", f)
		stopType(state, "stun", f)
		stopType(state, "fall", f)

	elseif actionType == "defeat" then
		stopData(state.currentActionTrack, f)
		state.currentActionTrack = nil
		stopType(state, "lightHurt", f)
		stopType(state, "heavyHurt", f)
		stopType(state, "stun", f)
		stopType(state, "fall", f)
		stopType(state, "startFFYL", f)
	end
end

-- Balikin AnimationTrack yang beneran dimainkan (atau nil kalau gak ada
-- track valid buat actionType ini / bot ini belum di-attach). Dipakai
-- caller (mis. ArenaService) yang perlu tau track.Length buat nunggu
-- animasi ini BENERAN kelar sebelum ngelakuin hal lain yang bisa
-- konflik sama root motion animasinya (lihat catatan "rise" di
-- ArenaService.startRound soal race condition reposisi/seat).
function BotAnimationService.play(botPlayer, actionType, variantIndex)
	local state = animState[botPlayer]
	if not state then return nil end

	local trackData = state.tracks[actionType]
	if not trackData then return nil end

	stopConflicts(state, actionType)

	local track
	if type(trackData) == "table" then
		if #trackData == 0 then return nil end

		if variantIndex and trackData[variantIndex] then
			track = trackData[variantIndex]
		elseif actionType == "light" then
			track = trackData[state.lightIndex]
			state.lightIndex = (state.lightIndex % #trackData) + 1
		elseif actionType == "lightHurt" then
			track = trackData[state.hurtIndex]
			state.hurtIndex = (state.hurtIndex % #trackData) + 1
		else
			track = trackData[math.random(1, #trackData)]
		end
	else
		track = trackData
	end

	if not track then return nil end

	track:Stop(0)
	track:Play(fade(actionType, false), weight(actionType), speed(actionType))

	if actionType == "light" or actionType == "heavy" or actionType == "dodge" then
		state.currentActionTrack = track

		-- Setelah action selesai, idle dikembalikan jika bot masih berada
		-- dalam state playing. Jangan lakukan ini untuk fall/defeat karena
		-- keduanya memang harus meninggalkan idle sampai ronde berikutnya.
		task.spawn(function()
			local finished = false
			pcall(function()
				track.Stopped:Wait()
				finished = true
			end)
			if not finished then return end
			local current = animState[botPlayer]
			if current ~= state then return end
			if state.currentActionTrack == track then
				state.currentActionTrack = nil
				local idle = state.tracks.idle
				if idle and not idle.IsPlaying then
					idle:Play(fade("idle", false), weight("idle"), speed("idle"))
				end
			end
		end)
	end

	return track
end

function BotAnimationService.stop(botPlayer, actionType)
	local state = animState[botPlayer]
	if not state then return end
	stopType(state, actionType, fade(actionType, true))
end

function BotAnimationService.isPlaying(botPlayer, actionType)
	local state = animState[botPlayer]
	if not state then return false end

	local data = state.tracks[actionType]
	if typeof(data) == "Instance" then
		return data.IsPlaying
	elseif type(data) == "table" then
		for _, track in ipairs(data) do
			if track.IsPlaying then return true end
		end
	end
	return false
end

return BotAnimationService