-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : HitboxService.lua
    Layer      : Service
    Deskripsi  : Deteksi kontak pukulan dan validasi jendela aktif.
    Penulis    : System
    Tanggal    : 02 Agustus 2026
    Versi      : 1.0
]]

local HitboxService = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local Debris            = game:GetService("Debris")

local HitboxConfig    = require(ReplicatedStorage.Configs.HitboxConfig)
local GameplayConfig  = require(ReplicatedStorage.Configs.GameplayConfig)
local AnimationConfig = require(ReplicatedStorage.Configs.AnimationConfig)

-- Cari part bantal yang sedang dipegang karakter.
local function getPillowPart(character)
	if not character then return nil end

	local tool = character:FindFirstChild(GameplayConfig.PILLOW_TOOL_NAME)
	if not (tool and tool:IsA("Tool")) then
		-- Nama Tool bisa saja berbeda di Studio; ambil Tool apa pun yang dipegang.
		tool = character:FindFirstChildOfClass("Tool")
	end
	if not tool then return nil end

	local named = tool:FindFirstChild(HitboxConfig.PILLOW_HITBOX_NAME)
	if named and named:IsA("BasePart") then
		return named
	end

	local handle = tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		return handle
	end

	return tool:FindFirstChildWhichIsA("BasePart")
end

-- Kompensasi ping agar jendela aktif mengikuti posisi server.
local function getPing(player)
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)

	if ok and type(ping) == "number" then
		return math.clamp(ping, 0, HitboxConfig.MAX_PING_COMPENSATION)
	end

	return 0
end

-- Batasi overlap query hanya ke karakter lawan.
local function buildOverlapParams(victimCharacter)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { victimCharacter }
	params.RespectCanCollide = false
	return params
end

-- Ambil part lawan paling dekat dengan pusat hitbox.
local function pickHitPart(parts, center)
	local bestPart, bestDistance

	for _, part in ipairs(parts) do
		if not part:FindFirstAncestorWhichIsA("Tool") then
			local distance = (part.Position - center).Magnitude
			if not bestDistance or distance < bestDistance then
				bestPart, bestDistance = part, distance
			end
		end
	end

	return bestPart
end

-- Tentukan arah datangnya pukulan untuk memilih variant hurt.
local function resolveSide(victimCharacter, hitPosition)
	local root = victimCharacter:FindFirstChild("HumanoidRootPart")
	if not root then return nil end

	local relative = root.CFrame:PointToObjectSpace(hitPosition)
	if math.abs(relative.X) < HitboxConfig.SIDE_DEADZONE then
		-- Tepat di garis tengah — sisi tidak bisa ditentukan dengan yakin.
		return nil
	end

	return (relative.X >= 0) and "right" or "left"
end

local debugFolder

local function drawDebugBox(cframe, size, isHit)
	if not HitboxConfig.DEBUG then return end

	if not debugFolder or not debugFolder.Parent then
		debugFolder = Instance.new("Folder")
		debugFolder.Name = "HitboxDebug"
		debugFolder.Parent = Workspace
	end

	local box = Instance.new("Part")
	box.Size         = size
	box.CFrame       = cframe
	box.Anchored     = true
	box.CanCollide   = false
	box.CanQuery     = false
	box.CanTouch     = false
	box.Transparency = 0.7
	box.Material     = Enum.Material.Neon
	box.Color        = isHit and Color3.fromRGB(80, 255, 120) or Color3.fromRGB(255, 90, 90)
	box.Parent       = debugFolder

	Debris:AddItem(box, HitboxConfig.DEBUG_LIFETIME)
end

-- Jalankan satu ayunan dan kembalikan kontak jika berhasil mengenai target.
function HitboxService.strike(attacker, victim, actionType)
	local window = HitboxConfig.ACTIVE_WINDOW[actionType]
	if not window then
		warn("[HitboxService] Tidak ada ACTIVE_WINDOW untuk aksi: " .. tostring(actionType))
		return nil
	end

	local attackerCharacter = attacker.Character
	local victimCharacter   = victim.Character
	if not (attackerCharacter and victimCharacter) then return nil end

	-- Animasi yang diputar lebih cepat berarti frame kontaknya datang lebih awal.
	local speed = AnimationConfig.SPEED[actionType] or 1
	if speed <= 0 then speed = 1 end

	-- FIX (damage kadang gak masuk cuma pas live, aman di Studio test):
	-- `now` di sini itu waktu SERVER nerima AttackFiredEvent, yang udah
	-- otomatis telat ~setengah round-trip dari saat attacker mulai ayun
	-- di client-nya. GetNetworkPing() balikin ROUND-TRIP time, jadi kalau
	-- ditambahin FULL ke `now`, window pengecekan jadi mundur DUA KALI
	-- lipat dari yang seharusnya (telat alami + telat tambahan).
	-- Di Studio test (ping ~0) ini gak kerasa, tapi di live server
	-- (ping asli) window bisa mundur ratusan ms dari posisi bantal
	-- yang sebenarnya -- bantal server-side udah lewat duluan pas
	-- baru mulai dicek, padahal attacker udah lihat kontak "kena"
	-- secara visual. Makanya dipakai SETENGAH (one-way) bukan full RTT.
	local networkDelay = getPing(attacker) * 0.5
	local now          = os.clock()
	local startAt      = now + (window.start / speed) + networkDelay
	local stopAt       = now + (window.stop  / speed) + networkDelay + HitboxConfig.LATENCY_GRACE

	if HitboxConfig.DEBUG_LOG then
		-- TAMBAH: jarak STATIS root-ke-root saat ayunan dimulai (bukan jarak
		-- bantal yang lagi mengayun). Ini buat misahin dua kemungkinan:
		-- (a) seat-nya sendiri emang lebih dari MAX reach -> root-to-root
		--     sudah jauh dari awal, gak akan pernah ke-fix cuma dengan naikin
		--     SIZE_PADDING.
		-- (b) seat-nya deket, tapi arc ayunan (pillowPart) gak pernah ngarah
		--     ke root lawan -> root-to-root deket, tapi minDist bantal tetap jauh.
		local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
		local victimRootAtStart = victimCharacter:FindFirstChild("HumanoidRootPart")
		local rootToRoot = (attackerRoot and victimRootAtStart)
			and (attackerRoot.Position - victimRootAtStart.Position).Magnitude
			or nil

		print(("[HitboxDebug] SWING attacker=%s action=%s speed=%.2f ping=%.3f window=%.2f-%.2f rootToRoot=%s")
			:format(attacker.Name, actionType, speed, networkDelay, window.start, window.stop,
				rootToRoot and string.format("%.2f", rootToRoot) or "nil"))
	end

	-- ── Fase 1: tunggu sampai bantal mulai melintas ──
	while os.clock() < startAt do
		RunService.Heartbeat:Wait()
	end

	local params = buildOverlapParams(victimCharacter)

	local framesChecked   = 0
	local framesInRange   = 0
	local framesNoPillow  = 0
	local closestMiss     = nil -- jarak cframe-ke-victimRoot terdekat yang tetap tidak ada touched part

	-- ── Fase 2: periksa tabrakan tiap frame selama jendela aktif ──
	while os.clock() < stopAt do
		-- Salah satu pemain respawn di tengah ayunan: ayunan ini dibatalkan.
		if attacker.Character ~= attackerCharacter or victim.Character ~= victimCharacter then
			return nil
		end

		local pillowPart = getPillowPart(attackerCharacter)

		if not pillowPart then
			framesNoPillow += 1
			if HitboxConfig.FALLBACK_WHEN_NO_PILLOW then
				warn("[HitboxService] Bantal " .. attacker.Name .. " tidak ditemukan;"
					.. " pukulan dihitung mendarat tanpa deteksi tabrakan.")
				return { part = nil, position = nil, side = nil, fallback = true }
			end
			return nil
		end

		framesChecked += 1

		local size = HitboxConfig.SIZE_OVERRIDE or (pillowPart.Size + HitboxConfig.SIZE_PADDING)
		local cframe = pillowPart.CFrame * CFrame.new(HitboxConfig.OFFSET)

		-- Early-out murah: bantal masih jauh dari lawan, tidak perlu query.
		local victimRoot = victimCharacter:FindFirstChild("HumanoidRootPart")
		local distanceToVictim = victimRoot and (cframe.Position - victimRoot.Position).Magnitude
		local inRange = (not victimRoot) or (distanceToVictim <= HitboxConfig.MAX_RANGE)

		if inRange then
			framesInRange += 1
			local touched = Workspace:GetPartBoundsInBox(cframe, size, params)
			local hitPart = pickHitPart(touched, cframe.Position)

			if HitboxConfig.DEBUG_LOG and distanceToVictim then
				if not closestMiss or distanceToVictim < closestMiss.distance then
					closestMiss = { distance = distanceToVictim, touchedCount = #touched, victimRootLoaded = true }
				end
			end

			if hitPart then
				if HitboxConfig.DEBUG_LOG then
					print(("[HitboxDebug] HIT attacker=%s framesChecked=%d framesInRange=%d framesNoPillow=%d")
						:format(attacker.Name, framesChecked, framesInRange, framesNoPillow))
				end

				drawDebugBox(cframe, size, true)

				-- Sisi dihitung dari posisi BANTAL, bukan posisi part yang kena:
				-- pusat torso selalu ada di garis tengah korban sehingga tidak
				-- bisa membedakan kanan/kiri, sedangkan bantal jelas berada di
				-- salah satu sisi.
				return {
					part     = hitPart,
					position = cframe.Position,
					side     = resolveSide(victimCharacter, cframe.Position),
					fallback = false,
				}
			end

			drawDebugBox(cframe, size, false)
		end

		RunService.Heartbeat:Wait()
	end

	-- Jendela aktif habis tanpa sentuhan — pukulan meleset.
	if HitboxConfig.DEBUG_LOG then
		if framesChecked == 0 then
			print(("[HitboxDebug] MISS attacker=%s action=%s -- BANTAL TIDAK PERNAH KETEMU selama jendela aktif (framesNoPillow=%d)")
				:format(attacker.Name, actionType, framesNoPillow))
		elseif framesInRange == 0 then
			local lastDist = closestMiss and closestMiss.distance
			print(("[HitboxDebug] MISS attacker=%s action=%s -- bantal ketemu (%d frame) tapi TIDAK PERNAH masuk MAX_RANGE (%.1f). Jarak terakhir ke victimRoot=%s")
				:format(attacker.Name, actionType, framesChecked, HitboxConfig.MAX_RANGE, tostring(lastDist)))
		else
			print(("[HitboxDebug] MISS attacker=%s action=%s -- masuk range %d/%d frame tapi GetPartBoundsInBox gak pernah nemu part victim (closest touchedCount=%s @ dist=%.2f)")
				:format(attacker.Name, actionType, framesInRange, framesChecked,
					tostring(closestMiss and closestMiss.touchedCount), closestMiss and closestMiss.distance or -1))
		end
	end

	return nil
end

return HitboxService