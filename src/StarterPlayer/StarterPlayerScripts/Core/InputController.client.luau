--[[
    Nama File  : InputController
    Layer      : Client (Input)
    Deskripsi  : Mendengarkan input player (PC via Keyboard & Mobile via StarterGui), 
                 kirim ke server, dan mainkan animasi sesuai hasil dari server.
    Penulis    : Yusuf Ahayy & Epik
    Tanggal    : 09 Juli 2026 (Update Mobile StarterGui Integration & Safety Fix)
    Versi      : 2.7
    Dependensi : - ReplicatedStorage > Remotes > AttackFiredEvent
                 - ReplicatedStorage > Remotes > SyncMatchStateEvent
                 - ReplicatedStorage > Remotes > FFYLStateEvent
                 - ReplicatedStorage > Remotes > StunEvent
                 - ReplicatedStorage > Remotes > AttackResultEvent
                 - StarterGui > MobileBattleGui
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local attackFiredEvent = Remotes:WaitForChild("AttackFiredEvent")
local syncMatchStateEvent = Remotes:WaitForChild("SyncMatchStateEvent")
local matchLockEvent = Remotes:WaitForChild("MatchLockEvent")
local ffylStateEvent = Remotes:WaitForChild("FFYLStateEvent")
local stunEvent = Remotes:WaitForChild("StunEvent")
local attackResultEvent = Remotes:WaitForChild("AttackResultEvent")

local GameplayConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("GameplayConfig"))
local localAnimEvent = script.Parent:WaitForChild("LocalAnimEvent")

-- Akses PlayerModule Controls
local PlayerModule = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
local Controls = PlayerModule:GetControls()

--- State Match & Character Input Gate
local isPlaying = false
local isMobile = UserInputService.TouchEnabled

local isFFYLActive = false  -- true selama minigame FFYL
local isStunned    = false  -- true selama kena stun
local isAlive      = true   -- false saat kalah (defeat)

-- true dari MatchLockEvent(true) di awal match sampai MatchLockEvent(false)
-- pas match beneran kelar/batal -- MENCAKUP jeda antar ronde & countdown
-- "3..2..1..FIGHT!", bukan cuma pas ronde aktif (beda dengan isPlaying).
-- Dipakai buat kunci Controls (WASD/analog/lompat) supaya karakter yang lagi
-- "duduk" di arena gak bisa gerak sama sekali dari awal countdown, bukan
-- baru terkunci setelah "FIGHT!" ditembak.
local isLocked = false

-- Gerbang utama input client
local function canAct()
	-- Hard gate: isPlaying hanya berarti ronde sedang aktif. isLocked
	-- mencakup countdown/transisi, jadi input tidak boleh lolos walau
	-- kedua state sempat overlap karena remote datang di frame berbeda.
	-- isLocked hanya mengunci movement/Reset/Backpack selama match.
	-- Jangan dipakai sebagai gate aksi combat: MatchLockEvent memang true
	-- sepanjang SELURUH match, sedangkan isPlaying menjadi true saat FIGHT
	-- dan tetap true antar ronde. Kalau isLocked ikut dicek di sini,
	-- player tidak akan pernah bisa light/heavy/dodge selama match.
	return isPlaying
		and isAlive
		and not isFFYLActive
		and not isStunned
end

local lastUsed = {
	light = 0,
	heavy = 0,
	dodge = 0
}

local function canUse(actionType)
	local now = os.clock()
	if now - (lastUsed[actionType] or 0) >= (GameplayConfig.COOLDOWNS[actionType] or 0) then
		lastUsed[actionType] = now
		return true
	end
	return false
end

-- ================================================================
-- MOBILE INPUT INTEGRATION
-- ================================================================
local mobileGui = PlayerGui:WaitForChild("MobileBattleGui")
local container = mobileGui:WaitForChild("ButtonContainer")

local function processMobileAction(actionType)
	if not canAct() then return end
	if canUse(actionType) then
		print("[InputController] Mobile memicu aksi: " .. actionType)
		localAnimEvent:Fire(actionType)
		attackFiredEvent:FireServer(actionType)
	end
end

local function setupMobileButtons()
	local lightBtn = container:FindFirstChild("LightBtn")
	local heavyBtn = container:FindFirstChild("HeavyBtn")
	local dodgeBtn = container:FindFirstChild("DodgeBtn")

	if lightBtn then
		lightBtn.Activated:Connect(function()
			processMobileAction("light")
		end)
	end

	if heavyBtn then
		heavyBtn.Activated:Connect(function()
			processMobileAction("heavy")
		end)
	end

	if dodgeBtn then
		dodgeBtn.Activated:Connect(function()
			processMobileAction("dodge")
		end)
	end
end

if isMobile then
	setupMobileButtons()
end

-- ================================================================
-- SYSTEM & GUI HELPERS
-- ================================================================
local function setBackpackEnabled(enabled)
	task.spawn(function()
		local success = false
		local attempts = 0
		while not success and attempts < 5 do
			success = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, enabled)
			end)
			if not success then
				attempts += 1
				task.wait(0.2)
			end
		end
		if not success then
			warn("[InputController] Gagal mengatur Backpack CoreGui setelah 5 percobaan.")
		end
	end)
end

local function updatePlayerControls()
	if isLocked then
		Controls:Disable()
	else
		Controls:Enable()
	end
end

-- Matikan tombol Reset bawaan Roblox selama pemain masih tercatat di dalam
-- match (dari startMatch sampai match kelar/batal, mencakup jeda antar
-- ronde). Ini nutup bug lama: klik Reset di tengah match bikin karakter
-- lama hancur & muncul character baru padahal server masih anggap match
-- jalan (posisi jadi acak, tool ilang, dsb).
local function setResetButtonEnabled(enabled)
	local ok = pcall(function()
		StarterGui:SetCore("ResetButtonCallback", enabled)
	end)
	if not ok then
		warn("[InputController] Gagal mengatur ResetButtonCallback.")
	end
end

-- Tangani jika karakter respawn agar Controls tetap dalam kondisi terkunci saat match
LocalPlayer.CharacterAdded:Connect(function()
	task.wait(0.1)
	updatePlayerControls()
end)

-- ================================================================
-- REMOTE LISTENERS
-- ================================================================
syncMatchStateEvent.OnClientEvent:Connect(function(state)
	isPlaying = state
	if isMobile and mobileGui then
		mobileGui.Enabled = isPlaying
	end

	if isPlaying then
		isFFYLActive = false
		isStunned = false
		isAlive = true
	else
		-- Jangan simpan state combat lama ketika ronde/match selesai.
		isFFYLActive = false
		isStunned = false
		isAlive = true
	end
end)

matchLockEvent.OnClientEvent:Connect(function(locked)
	isLocked = locked
	setResetButtonEnabled(not locked)
	-- Controls DAN Backpack GUI dikunci dari sini (awal match, sebelum
	-- countdown ronde 1) sampai locked balik false (match kelar/batal) --
	-- bukan cuma pas isPlaying. isPlaying baru true tepat pas "FIGHT!",
	-- padahal server sudah nge-equip ulang bantal SEBELUM itu. Kalau
	-- Backpack GUI baru dikunci pas isPlaying, ada celah waktu di titik
	-- server equip ulang vs client kunci Backpack -- di celah itu pemain
	-- masih bisa pencet nomor slot/Backspace buat unequip manual, dan
	-- setelah itu gak ada equip ulang lagi -> bantal hilang dari tangan
	-- pas match sudah jalan. Kunci dari awal match nutup celah itu.
	setBackpackEnabled(not locked)
	updatePlayerControls()
end)

ffylStateEvent.OnClientEvent:Connect(function(active)
	isFFYLActive = active and true or false
end)

stunEvent.OnClientEvent:Connect(function()
	isStunned = true
end)

attackResultEvent.OnClientEvent:Connect(function(actionType, success)
	if not success then
		if lastUsed[actionType] then
			lastUsed[actionType] = 0
		end
		return
	end

	if actionType == "stun_end" then
		isStunned = false
	elseif actionType == "defeat" then
		isAlive = false
	elseif actionType == "rise" or actionType == "start" then
		isAlive = true
	end
end)

-- ================================================================
-- PC INPUT LISTENER
-- ================================================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if not canAct() then return end

	-- Light Attack (MouseButton1, O, atau [)
	if input.UserInputType == Enum.UserInputType.MouseButton1 
		or input.KeyCode == Enum.KeyCode.O 
		or input.KeyCode == Enum.KeyCode.LeftBracket then

		if canUse("light") then
			localAnimEvent:Fire("light")
			attackFiredEvent:FireServer("light")
		end

		-- Heavy Attack (MouseButton2, I, atau ])
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 
		or input.KeyCode == Enum.KeyCode.I 
		or input.KeyCode == Enum.KeyCode.RightBracket then

		if canUse("heavy") then
			localAnimEvent:Fire("heavy")
			attackFiredEvent:FireServer("heavy")
		end

		-- Dodge (Keyboard Q)
	elseif input.KeyCode == Enum.KeyCode.Q then
		if canUse("dodge") then
			localAnimEvent:Fire("dodge")
			attackFiredEvent:FireServer("dodge")
		end
	end
end)