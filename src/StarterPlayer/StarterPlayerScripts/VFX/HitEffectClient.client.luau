-- @ScriptType: LocalScript
--[[
    HitEffectClient.lua
    Terima HitEffectEvent (position, actionType) dari server dan spawn efek
    hit secara lokal di client -- gak clone-di-server-lalu-replicate, biar
    gak ada delay replikasi Model.

    Fix log terakhir: emitter dengan Rate > 0 cuma di-Enabled sebentar
    (CONTINUOUS_EMIT_DURATION), jadi partikel yang keluar kesedikit hampir
    invisible. Sekarang semua emitter selalu di-Emit() manual (burst instan)
    dulu, baru kalau Rate > 0 dibiarin nyala bentar buat ekor tambahan.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")

local VFXConfig = require(ReplicatedStorage.Configs.VFXConfig)
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HitEffectEvent = Remotes:WaitForChild("HitEffectEvent")

local DEBUG = false -- set true buat nyalain print diagnostic per-spawn

local POOL_SIZE = 6
local POOL_PARK_POSITION = Vector3.new(0, -500, 0)
local CONTINUOUS_EMIT_DURATION = 0.3 -- durasi "ekor" buat emitter Rate > 0
local DEFAULT_BURST_COUNT = 15

-- ============================================================
-- Helpers
-- ============================================================

local function forceAnchorParts(model)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end
end

local function ensurePrimaryPart(model)
	if not model:IsA("Model") then return true end
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
	return model.PrimaryPart ~= nil
end

local function setEmittersEnabled(instance, enabled)
	for _, e in ipairs(instance:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = enabled
		end
	end
end

-- Burst instan buat semua emitter, plus "ekor" nyala bentar kalau Rate > 0.
local function playEmitters(instance, actionType)
	local burstCount = VFXConfig.HIT.COUNT[actionType] or VFXConfig.HIT.COUNT.light or DEFAULT_BURST_COUNT

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant:Emit(descendant:GetAttribute("EmitCount") or burstCount)

			if descendant.Rate > 0 then
				descendant.Enabled = true
				task.delay(CONTINUOUS_EMIT_DURATION, function()
					descendant.Enabled = false
				end)
			end
		elseif descendant:IsA("Sound") then
			descendant:Play()
		end
	end
end

-- ============================================================
-- Object pool
-- ============================================================

local pool = {}

local function createPooledClone(template)
	local clone = template:Clone()

	if clone:IsA("Model") then
		forceAnchorParts(clone)
		if ensurePrimaryPart(clone) then
			clone:PivotTo(CFrame.new(POOL_PARK_POSITION))
		else
			warn("[HitEffectClient] '" .. clone.Name .. "' tidak punya PrimaryPart/BasePart -- gak bisa direposisi")
		end
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new(POOL_PARK_POSITION)
		clone.Anchored = true
		clone.CanCollide = false
	end

	setEmittersEnabled(clone, false)
	clone.Parent = Workspace
	return clone
end

local function warmPool(template)
	for _ = 1, POOL_SIZE do
		table.insert(pool, createPooledClone(template))
	end
end

local function borrowFromPool(template)
	return table.remove(pool) or createPooledClone(template)
end

local function returnToPool(clone)
	if not clone or not clone.Parent then return end

	setEmittersEnabled(clone, false)

	if clone:IsA("Model") and clone.PrimaryPart then
		clone:PivotTo(CFrame.new(POOL_PARK_POSITION))
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new(POOL_PARK_POSITION)
	end

	table.insert(pool, clone)
end

-- ============================================================
-- Effect spawning
-- ============================================================

local hitEffectTemplate = nil
local function getHitEffectTemplate()
	if hitEffectTemplate then return hitEffectTemplate end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	hitEffectTemplate = assets and assets:FindFirstChild("HitEffect")
	return hitEffectTemplate
end

local function spawnFallbackEffect(position, actionType)
	local cfg = VFXConfig.HIT

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Name = "HitVFX"
	attachment.Parent = Workspace.Terrain

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = cfg.TEXTURE
	emitter.Color = cfg.COLOR[actionType] or cfg.COLOR.light
	emitter.Size = cfg.SIZE
	emitter.Lifetime = cfg.LIFETIME
	emitter.Speed = cfg.SPEED
	emitter.SpreadAngle = cfg.SPREAD
	emitter.Rate = 0
	emitter.Parent = attachment
	emitter:Emit(cfg.COUNT[actionType] or cfg.COUNT.light)

	Debris:AddItem(attachment, cfg.CLEANUP_DELAY)
end

local function debugPrint(instance, position)
	if not DEBUG then return end
	for _, e in ipairs(instance:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			print(string.format("[HitEffectClient][DIAG] %s Enabled=%s Rate=%s Texture=%s",
				e.Name, tostring(e.Enabled), tostring(e.Rate), e.Texture))
		end
	end
	print("[HitEffectClient][DIAG] spawned at", position)
end

local function spawnCustomEffect(template, position, actionType)
	local instance = borrowFromPool(template)

	if instance:IsA("Model") then
		forceAnchorParts(instance)
		if ensurePrimaryPart(instance) then
			instance:PivotTo(CFrame.new(position))
		else
			warn("[HitEffectClient] instance '" .. instance.Name .. "' gagal direposisi, pakai fallback")
			returnToPool(instance)
			spawnFallbackEffect(position, actionType)
			return
		end
	elseif instance:IsA("BasePart") then
		instance.CFrame = CFrame.new(position)
	end

	playEmitters(instance, actionType)
	debugPrint(instance, position)

	task.delay(VFXConfig.HIT.CLEANUP_DELAY, function()
		returnToPool(instance)
	end)
end

-- ============================================================
-- Event handler
-- ============================================================

HitEffectEvent.OnClientEvent:Connect(function(position, actionType)
	if typeof(position) ~= "Vector3" then
		warn("[HitEffectClient] position bukan Vector3 (" .. typeof(position) .. ")")
		return
	end

	local template = getHitEffectTemplate()
	if template then
		spawnCustomEffect(template, position, actionType)
	else
		spawnFallbackEffect(position, actionType)
	end
end)

-- ============================================================
-- Init: preload asset dulu baru warm pool, biar clone pertama gak stutter
-- ============================================================

local assetsFolder = ReplicatedStorage:WaitForChild("Assets", 10)
local template = assetsFolder and assetsFolder:WaitForChild("HitEffect", 10)

if template then
	hitEffectTemplate = template

	local toPreload = {}
	for _, d in ipairs(template:GetDescendants()) do
		if d:IsA("ParticleEmitter") or d:IsA("Decal") or d:IsA("Texture")
			or d:IsA("MeshPart") or d:IsA("SpecialMesh") or d:IsA("Sound") then
			table.insert(toPreload, d)
		end
	end
	if #toPreload > 0 then
		ContentProvider:PreloadAsync(toPreload)
	end

	warmPool(template)
else
	warn("[HitEffectClient] ReplicatedStorage.Assets.HitEffect tidak ketemu -- pakai fallback particle")
end