-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    VFXService
    Server-side trigger buat efek visual pertarungan. Kirim sinyal kecil
    (posisi/player + tipe) ke client, client yang spawn instance-nya sendiri
    -- gak ada Model yang direplicate dari server, jadi gak ada delay.
]]
local VFXService = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VFXConfig = require(ReplicatedStorage.Configs.VFXConfig)
local GameplayConfig = require(ReplicatedStorage.Configs.GameplayConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HitEffectEvent = Remotes:WaitForChild("HitEffectEvent")

-- Auto-create kalau belum ada di Studio, sama kayak pola getOrCreateRemote
-- di ArenaService/MatchmakingService -- sebelumnya StunEffectEvent &
-- ShieldEffectEvent pakai WaitForChild polos, yang NGE-HANG SELAMANYA kalau
-- remote-nya belum sempat dibuat manual (nge-block require() VFXService,
-- ikut nge-block semua yang require dia). Sekarang self-heal, gak perlu
-- setup manual lagi.
local function getOrCreateRemote(name)
	local remote = Remotes:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end

local StunEffectEvent = getOrCreateRemote("StunEffectEvent")
local ShieldEffectEvent = getOrCreateRemote("ShieldEffectEvent")

local function getPillowTool(character)
	if not character then return nil end
	local tool = character:FindFirstChild(GameplayConfig.PILLOW_TOOL_NAME)
	if tool and tool:IsA("Tool") then return tool end
	return character:FindFirstChildOfClass("Tool")
end

local function getTrail(character)
	local tool = getPillowTool(character)
	if not tool then return nil end

	local handle = tool:FindFirstChild("Handle")
	if not handle then return nil end

	local topName = VFXConfig.TRAIL.ATTACHMENT_NAMES.top
	local topAttachment = handle:FindFirstChild(topName)
	if not topAttachment then return nil end

	return topAttachment:FindFirstChildWhichIsA("Trail")
end

function VFXService.primeSwingTrail(attacker, actionType)
	local trail = getTrail(attacker.Character)
	if not trail then return nil end

	local cfg = VFXConfig.TRAIL
	trail.Color = cfg.COLOR[actionType] or cfg.COLOR.light
	trail.Transparency = cfg.TRANSPARENCY
	trail.WidthScale = cfg.WIDTH_SCALE[actionType] or cfg.WIDTH_SCALE.light
	trail.Lifetime = cfg.LIFETIME[actionType] or cfg.LIFETIME.light
	trail.Enabled = true

	return trail
end

function VFXService.endSwingTrail(attackerOrTrail)
	local trail = attackerOrTrail
	if typeof(attackerOrTrail) ~= "Instance" then
		trail = getTrail(attackerOrTrail and attackerOrTrail.Character)
	end
	if trail then
		trail.Enabled = false
	end
end

-- Cuma nembak posisi + actionType -- spawn instance-nya dikerjain client
-- lewat HitEffectClient.lua.
function VFXService.spawnHitEffect(position, actionType)
	if not position then return end
	HitEffectEvent:FireAllClients(position, actionType)
end

-- Nyalain/matiin efek dizzy stars + wajah pusing di karakter targetPlayer.
-- Broadcast ke semua client (FireAllClients) karena efek ini harus keliatan
-- oleh SEMUA pemain, bukan cuma targetPlayer sendiri -- panggil ini dari
-- sistem stun yang udah ada, contoh:
--   VFXService.setStunEffect(player, true)   -- pas mulai stun
--   VFXService.setStunEffect(player, false)  -- pas stun selesai
function VFXService.setStunEffect(targetPlayer, isActive)
	if not targetPlayer then return end
	StunEffectEvent:FireAllClients(targetPlayer, isActive)
end

-- Nyalain/matiin efek shield (barrier/glow) di karakter targetPlayer.
-- Sama kayak setStunEffect: broadcast ke semua client soalnya shield
-- visualnya harus keliatan oleh semua orang, bukan cuma pemiliknya.
-- Server gak clone asset ShieldEffect sama sekali -- itu tugas client
-- (lewat ShieldEffectClient.lua, perlu dibikin, nyerupain HitEffectClient.lua
-- tapi ngeclone dari ReplicatedStorage.Assets.ShieldEffect dan nge-attach
-- ke karakter, bukan spawn one-shot di posisi).
-- Panggil dari sistem shield/block yang udah ada, contoh:
--   VFXService.setShieldEffect(player, true)   -- pas shield aktif
--   VFXService.setShieldEffect(player, false)  -- pas shield abis/dipatahin
function VFXService.setShieldEffect(targetPlayer, isActive)
	if not targetPlayer then return end
	ShieldEffectEvent:FireAllClients(targetPlayer, isActive)
end

return VFXService