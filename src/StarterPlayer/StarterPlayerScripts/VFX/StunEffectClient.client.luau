-- @ScriptType: LocalScript
--[[
    StunEffectClient.lua
    Nerima StunEffectEvent(targetPlayer, isActive) dan nampilin efek dizzy
    stars nempel di kepala karakter yang stun, ganti wajah ke StuntFace,
    muterin StuntSFX. Semua client liat efek ini.

    StuntEffect ditaruh di TENGAH kepala pakai WeldConstraint (bukan orbit
    manual per-frame) -- particle-nya sendiri udah muter bawaan, jadi cukup
    nempel diem di kepala dan otomatis ngikut gerakan karakter lewat weld.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local StunEffectEvent = Remotes:WaitForChild("StunEffectEvent")

local EFFECT_SCALE = 1.3 -- gedein dikit dari ukuran asli
local STUN_SAFETY_TIMEOUT = 4 -- detik; jaga-jaga kalau sinyal "stop" dari server kelewat

local assets = ReplicatedStorage:WaitForChild("Assets")
local sounds = ReplicatedStorage:WaitForChild("Sounds")

local stuntEffectTemplate = assets:WaitForChild("StuntEffect")
local stuntFaceDecal = assets:WaitForChild("StuntFace")
local stuntSFXTemplate = sounds:WaitForChild("StuntSFX")

-- [Character] = { part, weld, sound, face, originalFaceTexture }
local activeEffects = {}

local function findFaceDecal(head)
	return head:FindFirstChild("face") or head:FindFirstChildWhichIsA("Decal")
end

-- Siapin instance efek: resolve PrimaryPart (kalau Model), matiin collision
-- & massa, dan scale-up dikit. Return PrimaryPart/BasePart yang dipake buat
-- nge-weld, atau nil kalau gagal.
local function prepareEffectInstance(instance)
	if instance:IsA("Model") then
		if not instance.PrimaryPart then
			instance.PrimaryPart = instance:FindFirstChildWhichIsA("BasePart", true)
		end
		if not instance.PrimaryPart then return nil end

		for _, part in ipairs(instance:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Massless = true
			end
		end

		instance:ScaleTo(EFFECT_SCALE)
		return instance.PrimaryPart
	elseif instance:IsA("BasePart") then
		instance.CanCollide = false
		instance.Massless = true
		instance.Size *= EFFECT_SCALE
		return instance
	end
	return nil
end

local stopStunEffect -- forward declare, dipake di dalam startStunEffect

local function startStunEffect(character)
	if activeEffects[character] then return end

	local head = character:FindFirstChild("Head")
	if not head then return end

	local face = findFaceDecal(head)
	local originalFaceTexture = face and face.Texture
	if face then
		face.Texture = stuntFaceDecal.Texture
	end

	local effectInstance = stuntEffectTemplate:Clone()
	effectInstance.Parent = Workspace

	local anchorPart = prepareEffectInstance(effectInstance)
	if not anchorPart then
		warn("[StunEffectClient] StuntEffect gagal disiapkan (bukan Model/BasePart valid)")
		effectInstance:Destroy()
		return
	end

	if effectInstance:IsA("Model") then
		effectInstance:PivotTo(head.CFrame)
	else
		effectInstance.CFrame = head.CFrame
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = head
	weld.Part1 = anchorPart
	weld.Parent = anchorPart

	local sound = stuntSFXTemplate:Clone()
	sound.Parent = head
	sound:Play()

	local data = {
		part = effectInstance,
		weld = weld,
		sound = sound,
		face = face,
		originalFaceTexture = originalFaceTexture,
	}
	activeEffects[character] = data

	-- Safety net: kalau server lupa/gagal kirim isActive=false, efek ini
	-- tetap kebersihin sendiri, gak nyangkut permanen di kepala.
	task.delay(STUN_SAFETY_TIMEOUT, function()
		if activeEffects[character] == data then
			warn("[StunEffectClient] Stun effect > " .. STUN_SAFETY_TIMEOUT .. "s, auto-cleanup (cek server, kemungkinan sinyal stop kelewat)")
			stopStunEffect(character)
		end
	end)
end

function stopStunEffect(character)
	local data = activeEffects[character]
	if not data then return end

	if data.part then
		data.part:Destroy() -- otomatis nge-destroy WeldConstraint yang nempel di dalamnya
	end

	if data.sound then
		data.sound:Stop()
		data.sound:Destroy()
	end

	if data.face and data.originalFaceTexture then
		data.face.Texture = data.originalFaceTexture
	end

	activeEffects[character] = nil
end

StunEffectEvent.OnClientEvent:Connect(function(targetPlayer, isActive)
	local character = targetPlayer and targetPlayer.Character
	if not character then return end

	if isActive then
		startStunEffect(character)
	else
		stopStunEffect(character)
	end
end)

-- Jaga-jaga: karakter respawn/leave pas masih stun -> efek & sound gak nyangkut.
local function watchCharacterRemoving(player)
	player.CharacterRemoving:Connect(function(character)
		stopStunEffect(character)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	watchCharacterRemoving(player)
end
Players.PlayerAdded:Connect(watchCharacterRemoving)