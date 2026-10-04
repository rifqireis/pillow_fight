-- @ScriptType: LocalScript
--[[
    Nama File  : MusicController.lua
    Layer      : Client (Sound)
    Deskripsi  : Memutar BGM lobby dan arena, dengan crossfade saat berpindah.
                 Lobby diputar sejak pemain masuk game; server mengirim
                 MusicStateEvent saat match dimulai dan saat kembali ke lobby.
    Penulis    : System, Yusuf Ahayy
    Tanggal    : 08 Agustus 2026
    Versi      : 1.1 (Refactored & Fixed)
    Dependensi : - ReplicatedStorage > Configs > SoundConfig
                 - ReplicatedStorage > Remotes > MusicStateEvent
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService      = game:GetService("SoundService")
local TweenService      = game:GetService("TweenService")
local ContentProvider   = game:GetService("ContentProvider")

local SoundConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SoundConfig"))

local MUSIC      = SoundConfig.MUSIC or {}
local TRACK_LIST = MUSIC.TRACKS or {}
local FADE_TIME  = MUSIC.FADE_TIME or 1.5

-- Remote dari ArenaService dengan timeout
local remotes         = ReplicatedStorage:WaitForChild("Remotes")
local musicStateEvent = remotes:WaitForChild("MusicStateEvent", 15)

-- ================================================================
-- SETUP SOUND GROUP & TRACKS
-- ================================================================
local musicGroup = SoundService:FindFirstChild("MusicGroup")
if not musicGroup then
	musicGroup = Instance.new("SoundGroup")
	musicGroup.Name = "MusicGroup"
	musicGroup.Volume = 1
	musicGroup.Parent = SoundService
end

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

local tracks = {}
local soundsToPreload = {}

for state, info in pairs(TRACK_LIST) do
	local soundId = resolveSoundId(type(info) == "table" and info.id or info)

	if soundId then
		local soundName = state .. "Music"
		local sound = SoundService:FindFirstChild(soundName)

		if not sound then
			sound = Instance.new("Sound")
			sound.Name = soundName
			sound.Parent = SoundService
		end

		sound.SoundId = soundId
		sound.Looped = true
		sound.Volume = 0
		sound.SoundGroup = musicGroup

		tracks[state] = {
			sound = sound,
			volume = (type(info) == "table" and info.volume) or 0.5,
		}

		table.insert(soundsToPreload, sound)
		print("[MusicController] BGM " .. state .. " (ID: " .. soundId .. ") telah di-load.")
	else
		warn("[MusicController] BGM " .. state .. " dilewati — ID belum diisi di SoundConfig")
	end
end

-- Preload BGM di background agar siap diputar tanpa delay
if #soundsToPreload > 0 then
	task.spawn(function()
		ContentProvider:PreloadAsync(soundsToPreload)
	end)
end

-- ================================================================
-- CROSSFADE SYSTEM
-- ================================================================
local currentState = nil
local activeTweens = {}

local function fadeTo(track, targetVolume, onFinished)
	-- Batalkan tween yang sedang berjalan untuk track ini jika ada
	if activeTweens[track] then
		activeTweens[track]:Cancel()
		activeTweens[track] = nil
	end

	local tween = TweenService:Create(
		track.sound,
		TweenInfo.new(FADE_TIME, Enum.EasingStyle.Linear),
		{ Volume = targetVolume }
	)
	activeTweens[track] = tween

	tween.Completed:Connect(function(playbackState)
		if activeTweens[track] == tween then
			activeTweens[track] = nil
		end

		if playbackState == Enum.PlaybackState.Completed then
			if onFinished then
				onFinished()
			end
		end
	end)

	tween:Play()
end

local function setMusicState(newState)
	if newState == currentState then return end
	currentState = newState

	for state, track in pairs(tracks) do
		if state == newState then
			-- Pastikan sound aktif diputar
			if not track.sound.IsPlaying then
				track.sound.Volume = 0
				track.sound:Play()
			end
			-- Mulai fade-in ke target volume
			fadeTo(track, track.volume)
		else
			-- Fade-out untuk track lain yang sedang berjalan / memiliki volume > 0
			if track.sound.IsPlaying or track.sound.Volume > 0 then
				fadeTo(track, 0, function()
					-- Stop suara hanya jika state aktif saat ini BUKAN track ini lagi
					if currentState ~= state then
						track.sound:Stop()
					end
				end)
			end
		end
	end

	print("[MusicController] BGM berpindah ke " .. tostring(newState))
end

-- ================================================================
-- EVENT LISTENERS & INITIALIZATION
-- ================================================================
setMusicState("lobby")

if musicStateEvent then
	musicStateEvent.OnClientEvent:Connect(function(state)
		if state == nil or TRACK_LIST[state] then
			setMusicState(state)
		else
			warn("[MusicController] State musik tidak dikenal: " .. tostring(state))
		end
	end)
else
	warn("[MusicController] MusicStateEvent tidak ditemukan — BGM berhenti di lobby")
end

print("[MusicController] Berhasil diinisialisasi")