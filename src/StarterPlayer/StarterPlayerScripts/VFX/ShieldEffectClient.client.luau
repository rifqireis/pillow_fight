-- @ScriptType: LocalScript
-- @ScriptType: LocalScript
-- LocalScript
--[[
    ShieldEffectClient
    Dengerin ShieldEffectEvent dari VFXService (server). Pas isActive == true,
    clone ReplicatedStorage.Assets.ShieldEffect dan attach ke karakter
    targetPlayer. Pas isActive == false, matiin & bersihin clone-nya.

    Asset ShieldEffect bisa berbentuk apa aja (Model, BasePart, Attachment,
    atau langsung ParticleEmitter/Beam/Trail/Highlight) -- script ini
    nge-detect tipe-nya sendiri dan attach dengan cara yang sesuai.

    Taro script ini di folder client yang sama kayak HitEffectClient.lua
    (misal StarterPlayerScripts), sebagai LocalScript.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShieldEffectEvent = Remotes:WaitForChild("ShieldEffectEvent")

local Assets = ReplicatedStorage:WaitForChild("Assets")

-- FIX (shield gak pernah muncul): sebelumnya ini pakai Assets:WaitForChild("ShieldEffect")
-- TANPA timeout. Kalau asset "ShieldEffect" belum sempat dibuat di Studio,
-- baris itu NGE-HANG SELAMANYA -- script berhenti total di sini dan baris
-- ShieldEffectEvent.OnClientEvent:Connect() di bawah gak PERNAH kejalan,
-- jadi shield diam-diam gak akan pernah nyala walau server sudah ngirim
-- sinyalnya dengan benar. Sekarang pakai timeout 5 detik: kalau ketemu,
-- lanjut normal; kalau nggak, listener TETAP jalan (biar gampang re-test
-- begitu asset-nya ditambah, tanpa perlu rejoin) dan warning jelas dicetak
-- sekali biar gampang ketauan akar masalahnya.
local ShieldEffectAsset = Assets:WaitForChild("ShieldEffect", 5)
if not ShieldEffectAsset then
	warn("[ShieldEffectClient] ReplicatedStorage.Assets.ShieldEffect TIDAK KETEMU."
		.. " Shield effect gak akan tampil sampai asset ini dibuat manual di Studio"
		.. " (Model/BasePart/Attachment/ParticleEmitter/Beam/Trail/Highlight,"
		.. " nama harus persis 'ShieldEffect', parent-nya ReplicatedStorage.Assets).")
end

-- Berapa lama nunggu sebelum bener-bener :Destroy() abis dimatiin,
-- biar particle/trail yang lagi keluar sempet fade out dulu.
local CLEANUP_DELAY = 1.5

-- Offset posisi shield relatif ke attachPoint (HumanoidRootPart/Torso).
-- Naikin angka Y ini kalau shield-nya masih kerasa kerendahan.
local SHIELD_OFFSET = CFrame.new(0, 2, 0)

-- Efek "napas" (pulse): shield membesar-mengecil pelan selama aktif.
-- PULSE_MIN/MAX itu faktor skala relatif ke ukuran asli (1 = ukuran asli).
-- PULSE_DURATION = lama satu arah (membesar ATAU mengecil), jadi satu
-- siklus penuh (besar->kecil->besar) makan waktu 2x angka ini.
local PULSE_MIN = 1.0
local PULSE_MAX = 1.15
local PULSE_DURATION = 0.6

-- [UserId] = Instance (clone yang lagi aktif nempel di karakter dia).
-- Di-key pakai UserId (bukan objek Player/bot-nya langsung) supaya tetap
-- kena-match buat bot -- lihat catatan panjang di listener OnClientEvent
-- di bawah soal kenapa key objek gak reliable buat bot.
local activeEffects = {}
-- [UserId] = Tween (pulse yang lagi jalan, biar bisa di-Cancel pas shield mati)
local activePulses = {}

local function findAttachPoint(character)
	if not character then return nil end
	local root = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso")
	if root then return root end
	return character:FindFirstChildWhichIsA("BasePart")
end

-- Nyalain/matiin semua descendant yang punya property "Enabled"
-- (ParticleEmitter, Beam, Trail, Highlight, Fire, Smoke, dll).
local function setDescendantsEnabled(instance, enabled)
	if instance:IsA("ParticleEmitter") or instance:IsA("Beam") or instance:IsA("Trail")
		or instance:IsA("Highlight") or instance:IsA("Fire") or instance:IsA("Smoke") then
		instance.Enabled = enabled
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail")
			or descendant:IsA("Highlight") or descendant:IsA("Fire") or descendant:IsA("Smoke") then
			descendant.Enabled = enabled
		end
	end
end

-- Siapin semua BasePart di dalam Model biar bisa ikut nempel & gerak
-- bareng karakter sebagai SATU KESATUAN yang rigid.
--
-- BUG SEBELUMNYA (shield jatuh berantakan): cuma `primary` yang di-weld ke
-- attachPoint (karakter). Part LAIN di dalam model gak punya
-- weld/joint apapun ke primary-nya sama sekali -- begitu semua part
-- di-unanchor, part-part itu jadi rigid body LEPAS tanpa pegangan, dan
-- gravitasi langsung narik mereka jatuh terpisah dari primary-nya.
--
-- Fix: weld SEMUA part lain ke `primary` dulu (jadi satu rigid body utuh)
-- SEBELUM di-unanchor. WeldConstraint ngunci transform RELATIF antar dua
-- part persis di posisi mereka saat weld dibuat -- makanya urutannya harus
-- gini (weld dulu, baru unanchor), bukan kebalik.
local function prepareModelParts(model, primary)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true

			if part ~= primary then
				local internalWeld = Instance.new("WeldConstraint")
				internalWeld.Part0 = primary
				internalWeld.Part1 = part
				internalWeld.Parent = part
			end
		end
	end

	-- Unanchor SETELAH semua weld internal terpasang, biar gak ada part
	-- yang sempat "lepas" tanpa pegangan.
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end
end

-- Nyalain pulse membesar-mengecil di clone (Model pakai property Scale,
-- BasePart pakai Size). Reverses=true + RepeatCount=-1 bikin dia otomatis
-- bolak-balik kecil->besar->kecil selama tween-nya belum di-Cancel.
-- Base scale asli si model (contoh: 0.046). Dipake sebagai acuan relatif
-- buat PULSE_MIN/PULSE_MAX, BUKAN diganti jadi 1.0/1.15 mentah-mentah --
-- kalau kepaksa nge-set clone.Scale = 1.0 padahal base-nya 0.046, model
-- bakal melonjak ~21x lipat dari ukuran normalnya.
local function startPulse(clone)
	local tweenInfo = TweenInfo.new(
		PULSE_DURATION,
		Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut,
		-1,
		true
	)

	if clone:IsA("Model") then
		-- FIX: Model.Scale itu property READ-ONLY lewat assignment biasa.
		-- Buat DI-SET, Roblox ngewajibin lewat method :ScaleTo(), soalnya
		-- assignment langsung gak nge-trigger re-scaling part/joint di
		-- dalam model. TweenService juga gak bisa nge-tween method,
		-- makanya di sini kita tween NumberValue "proxy" dan tiap proxy-nya
		-- berubah, kita panggil clone:ScaleTo() manual.
		local baseScale = clone.Scale -- baca aman, misal 0.046
		if not baseScale or baseScale == 0 then
			warn("[ShieldEffectClient] Model '" .. clone.Name .. "' punya Scale invalid (" .. tostring(baseScale) .. ") -- efek pulse di-skip.")
			return nil
		end

		local proxy = Instance.new("NumberValue")
		proxy.Value = baseScale * PULSE_MIN
		proxy.Parent = clone -- ikut kehapus otomatis pas clone:Destroy()

		local ok = pcall(function()
			clone:ScaleTo(proxy.Value)
		end)
		if not ok then
			warn("[ShieldEffectClient] Model '" .. clone.Name .. "' gak bisa di-:ScaleTo() -- efek pulse di-skip, shield tetap jalan normal.")
			proxy:Destroy()
			return nil
		end

		local conn = proxy:GetPropertyChangedSignal("Value"):Connect(function()
			pcall(function()
				clone:ScaleTo(proxy.Value)
			end)
		end)

		local tween = TweenService:Create(proxy, tweenInfo, { Value = baseScale * PULSE_MAX })
		tween:Play()

		-- Simpen connection biar bisa di-disconnect pas shield mati
		-- (dibungkus dalam tabel bareng tween-nya)
		return { tween = tween, conn = conn, proxy = proxy }
	elseif clone:IsA("BasePart") then
		local originalSize = clone.Size
		clone.Size = originalSize * PULSE_MIN
		local tween = TweenService:Create(clone, tweenInfo, { Size = originalSize * PULSE_MAX })
		tween:Play()
		return { tween = tween }
	end

	return nil
end

local function attachShield(targetPlayer)
	-- Kalau tadi belum ketemu (asset belum dibuat pas script start), coba
	-- cek lagi sekarang -- siapa tau baru ditambahin belakangan.
	if not ShieldEffectAsset then
		ShieldEffectAsset = Assets:FindFirstChild("ShieldEffect")
		if not ShieldEffectAsset then
			warn("[ShieldEffectClient] Masih belum ada ReplicatedStorage.Assets.ShieldEffect -- shield di-skip.")
			return nil
		end
	end

	local character = targetPlayer.Character
	local attachPoint = findAttachPoint(character)
	if not attachPoint then return end

	local clone = ShieldEffectAsset:Clone()

	if clone:IsA("BasePart") then
		clone.Anchored = false
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.Massless = true

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = attachPoint
		weld.Part1 = clone
		weld.Parent = clone

		clone.CFrame = attachPoint.CFrame * SHIELD_OFFSET
		clone.Parent = character
	elseif clone:IsA("Attachment") then
		clone.Parent = attachPoint
		clone.CFrame = SHIELD_OFFSET
	elseif clone:IsA("Model") then
		-- Fallback: kalau PrimaryPart belum di-set di Studio, ambil BasePart
		-- pertama yang ketemu, biar model TETAP ke-posisikan & ke-weld ke
		-- karakter alih-alih diam-diam gak diapa-apain (bug lama).
		local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)

		if primary then
			if not clone.PrimaryPart then
				clone.PrimaryPart = primary
			end

			-- Weld internal (semua part lain -> primary) + unanchor HARUS
			-- dilakukan SEBELUM PivotTo, supaya WeldConstraint yang dibuat
			-- prepareModelParts ngunci relative transform yang masih UTUH
			-- sesuai bentuk asli model, bukan transform yang udah kepindah.
			prepareModelParts(clone, primary)

			clone:PivotTo(attachPoint.CFrame * SHIELD_OFFSET)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = attachPoint
			weld.Part1 = primary
			weld.Parent = primary
		else
			warn("[ShieldEffectClient] Model ShieldEffect gak punya BasePart sama sekali -- gak bisa di-posisikan.")
		end
		clone.Parent = character
	else
		-- ParticleEmitter / Beam / Trail / Highlight langsung, atau tipe lain
		clone.Parent = attachPoint
	end

	-- Defense-in-depth: startPulse sekarang udah aman (lihat fix pcall di
	-- dalamnya), tapi tetep dibungkus pcall di sini juga -- biar kalau ada
	-- error LAIN yang gak kepikiran di masa depan, attachShield() TETAP
	-- lanjut sampai return clone (gak berhenti di tengah kayak bug shield-
	-- nempel-selamanya yang kemarin).
	-- Di removeShield(), ganti bagian ini:
	local pulseTween = activePulses[key]
	if pulseTween then
		activePulses[key] = nil
		if pulseTween.conn then pulseTween.conn:Disconnect() end
		if pulseTween.tween then pulseTween.tween:Cancel() end
	end

	return clone
end

local function removeShield(targetPlayer)
	local key = targetPlayer.UserId
	local clone = activeEffects[key]
	if not clone then return end
	activeEffects[key] = nil

	-- Destroy() di bawah gak akan pernah kejalan, shield jadi nyangkut.
	local pulseTween = activePulses[key]
	if pulseTween then
		activePulses[key] = nil
		if typeof(pulseTween) == "table" and not pulseTween.Cancel then
			if pulseTween.conn then pulseTween.conn:Disconnect() end
			if pulseTween.tween then pulseTween.tween:Cancel() end
		else
			pulseTween:Cancel()
		end
	end

	for _, part in ipairs(clone:IsA("BasePart") and {clone} or clone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = 1
		end
	end
	setDescendantsEnabled(clone, false)

	task.delay(CLEANUP_DELAY, function()
		if clone then
			clone:Destroy()
		end
	end)
end

ShieldEffectEvent.OnClientEvent:Connect(function(targetPlayer, isActive)
	if not targetPlayer then return end

	-- FIX (shield bot nempel selamanya): sebelumnya activeEffects/activePulses
	-- di-key pakai `targetPlayer` (tabel/Instance itu sendiri) sebagai key.
	-- Buat Player ASLI ini aman -- Roblox ngejaga identitas Instance-nya
	-- konsisten tiap kali lewat RemoteEvent, jadi objek yang diterima client
	-- pas event ON & OFF itu sama persis. TAPI bot (lihat BotService.lua)
	-- bukan Instance Player, dia cuma Lua table biasa ({Name=.., UserId=..,
	-- Character=..}) -- setiap kali table itu dikirim lewat FireAllClients,
	-- dia di-SERIALIZE ULANG jadi table BARU di sisi client (isinya sama,
	-- tapi identitas objeknya beda). Karena Lua nge-index tabel by-reference,
	-- activeEffects[targetPlayer] pas OFF gak akan pernah ketemu entry yang
	-- disimpen pas ON -- shield bot jadi gak pernah kehapus.
	-- Sekarang di-key pakai targetPlayer.UserId (angka, dibandingkan
	-- by-value) yang tetap konsisten walau tabelnya di-serialize ulang.
	local key = targetPlayer.UserId

	if isActive then
		-- Kalo somehow udah ada efek lama yang nyangkut, bersihin dulu.
		if activeEffects[key] then
			local old = activeEffects[key]
			activeEffects[key] = nil
			local oldPulse = activePulses[key]
			if oldPulse then
				activePulses[key] = nil
				oldPulse:Cancel()
			end
			old:Destroy()
		end
		activeEffects[key] = attachShield(targetPlayer)
	else
		removeShield(targetPlayer)
	end
end)

-- Jaga-jaga: kalo karakter targetPlayer respawn/dihapus pas shield lagi
-- aktif, clone lama bakal ikut kehapus otomatis karena dia child dari
-- karakter itu -- tapi tabel activeEffects perlu dibersihin juga biar
-- gak nyimpen reference ke instance yang udah destroyed.
Players.PlayerRemoving:Connect(function(player)
	activeEffects[player.UserId] = nil
	activePulses[player.UserId] = nil
end)