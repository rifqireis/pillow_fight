-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : CombatController
    Layer      : Controller
    Deskripsi  : Penjaga gerbang remote event serangan dari client.
                 Melakukan validasi payload & state, lalu mengalirkan ke EnergyService,
                 HitboxService, dan BalanceService.
    Penulis    : Yusuf Ahayy, Rifqi RR
    Tanggal    : 4 Juli 2026
    Versi      : 2.1
]]

local CombatController = {}

-- Services & Repositories
local ServerScriptService = game:GetService("ServerScriptService")
local BotAnimationService = require(ServerScriptService.Core.Service.BotAnimationService)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local EnergyService = require(ServerScriptService.Core.Service.EnergyService)
local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local HitboxService = require(ServerScriptService.Core.Service.HitboxService)
local ComboService = require(ServerScriptService.Core.Service.ComboService)
local BalanceService = require(ServerScriptService.Core.Service.BalanceService)
local FFYLService = require(ServerScriptService.Core.Service.FFYLService)
local VFXService = require(ServerScriptService.Core.Service.VFXService)
local RemoteSafety = require(ServerScriptService.Core.Service.RemoteSafety)

-- Configs
local GameplayConfig = require(ReplicatedStorage.Configs.GameplayConfig)
local BalanceConfig = require(ReplicatedStorage.Configs.BalanceConfig)
local EnergyConfig = require(ReplicatedStorage.Configs.EnergyConfig)
local HitboxConfig = require(ReplicatedStorage.Configs.HitboxConfig)
local AnimationConfig = require(ReplicatedStorage.Configs.AnimationConfig)

-- Remotes
local AttackFiredEvent = ReplicatedStorage.Remotes:WaitForChild("AttackFiredEvent")
local AttackResultEvent = ReplicatedStorage.Remotes:WaitForChild("AttackResultEvent")
local FFYLCompleteEvent = ReplicatedStorage.Remotes:WaitForChild("FFYLCompleteEvent")

local VALID_ACTIONS = {
	light = true,
	heavy = true,
	dodge = true,
}

local lightHurtIndex = {}

-- Sinyal internal (BUKAN RemoteEvent -- ini BindableEvent server-only) yang
-- nyala tiap kali sebuah ayunan BENERAN mulai (lolos validasi cooldown/energi).
-- Dipakai BotAIService buat "denger" kapan lawan (manusia) mulai nyerang bot,
-- supaya bot bisa coba ngehindar dalam window reaksi tertentu -- tanpa ini
-- bot gak ada cara tau kapan harus dodge selain nebak-nebak random.
CombatController.AttackStarted = Instance.new("BindableEvent")

-- Validasi kelayakan pemain untuk berinteraksi/menerima damage
local function canBeHit(state)
	return state ~= nil
		and state.isPlaying
		and state.isAlive
		and not state.isFFYL
end

-- Immune sesaat pasca-bangun FFYL (lihat BalanceConfig.FFYL_WIN_IMMUNE_DURATION).
-- BalanceService.applyDamage sudah nge-skip damage-nya sendiri, tapi itu
-- nggak cukup: TANPA cek ini, resolveHit tetap lanjut manggil applyHit
-- (flinch + animasi hurt) dan spawnHitEffect walau balance-nya nggak
-- berkurang -- korban keliatan/kerasa "kena" padahal immune. Guard ini yang
-- bikin pukulan bener-bener nembus tanpa efek apapun selama window immune.
local function isImmune(state)
	return state ~= nil
		and state.ffylImmuneUntil ~= nil
		and os.clock() < state.ffylImmuneUntil
end

-- Pilih varian animasi hurt light berdasarkan arah kontak atau rotasi
local function pickLightHurtVariant(attackerPlayer, contact)
	local side = contact and contact.side
	if side then
		return HitboxConfig.HURT_VARIANT_BY_SIDE[side] or 1
	end

	local attackerId = attackerPlayer and attackerPlayer.UserId or 0
	local idx = (lightHurtIndex[attackerId] or 0) + 1
	if idx > 2 then idx = 1 end
	lightHurtIndex[attackerId] = idx

	return idx
end

function CombatController.init()
	-- Listener pembersihan memori saat player keluar
	Players.PlayerRemoving:Connect(function(player)
		lightHurtIndex[player.UserId] = nil
	end)

	AttackFiredEvent.OnServerEvent:Connect(function(player, actionType)
		-- Validasi payload
		if type(actionType) ~= "string" or not VALID_ACTIONS[actionType] then
			warn("[CombatController] Payload tidak valid dari " .. player.Name)
			return
		end

		CombatController.performAction(player, actionType)
	end)

	-- Listener input mash space dari client (FFYL)
	FFYLCompleteEvent.OnServerEvent:Connect(function(player)
		FFYLService.handleSuccess(player)
	end)

	print("[CombatController] Listener Aktif")
end

-- Memproses satu aksi (light/heavy/dodge): validasi flinch/cooldown/energi,
-- lalu alirkan ke swing/dodge yang sesuai. Diextract dari listener
-- AttackFiredEvent supaya bisa dipanggil LANGSUNG (bypass remote) oleh
-- BotAIService -- bot gak punya client buat nembak AttackFiredEvent, tapi
-- tetap harus lewat validasi yang SAMA PERSIS kayak pemain asli (biar gak
-- curang: tetap kena cooldown & biaya energi yang sama).
function CombatController.performAction(player, actionType)
	local playerState = PlayerStateRepository.get(player)
	if not playerState then return end

	-- Validasi state pemain
	if not canBeHit(playerState) then
		RemoteSafety.fire(AttackResultEvent, player, actionType, false)
		return
	end

	local now = os.clock()

	-- Validasi flinch / stagger.
	--
	-- `flinchUntil` sekarang timestamp absolut, bukan hasil hitungan
	-- `lastHitTime + 0.5` yang di-hardcode kayak dulu. Alasannya dua:
	--   1. durasinya beda per jenis pukulan (GameplayConfig.FLINCH), jadi
	--      harus diputuskan di titik kena, bukan di titik dibaca; dan
	--   2. stagger dari PERFECT DODGE numpang mekanisme yang sama --
	--      penyerang yang kebaca dikunci pakai field ini juga, padahal
	--      dia sendiri nggak kena pukul (lastHitTime-nya nggak berubah).
	-- Dodge tetap dikecualikan supaya korban selalu punya jalan keluar.
	local flinchUntil = playerState.flinchUntil or 0
	if actionType ~= "dodge" and now < flinchUntil then
		-- Rollback ke client. Tanpa ini animasi ayunan yang sudah
		-- terlanjur diputar secara optimis (client-side prediction di
		-- InputController) bakal jalan sampai selesai padahal server
		-- menolaknya -- pemain lihat karakternya mengayun tapi tidak
		-- terjadi apa-apa, tanpa petunjuk kenapa. AnimationController
		-- sudah punya penanganan success=false, cuma memang tidak pernah
		-- dikirimi dari cabang ini.
		RemoteSafety.fire(AttackResultEvent, player, actionType, false)
		return
	end

	-- Update cooldown
	playerState.cooldowns[actionType] = now

	-- Konsumsi energi & proses aksi
	local success = EnergyService.consumeEnergy(player, actionType)
	if success then
		PlayerStateRepository.set(player, "lastActionTime", now)

		-- Anti-GB Layer 2: hitung action ini ke rolling window saat ini.
		-- ArenaService yang mereset counter ini tiap window habis.
		local state = PlayerStateRepository.get(player)
		local windowCount = (state and state.windowActionCount) or 0
		PlayerStateRepository.set(player, "windowActionCount", windowCount + 1)

		if actionType == "dodge" then
			PlayerStateRepository.set(player, "lastDodgeTime", now)
		elseif actionType == "light" or actionType == "heavy" then
			local ArenaService = require(ServerScriptService.Core.Service.ArenaService)
			local opponent = ArenaService.getOpponent(player)

			if opponent then
				CombatController.startSwing(player, opponent, actionType)
			end
		end
	end

	RemoteSafety.fire(AttackResultEvent, player, actionType, success)

	return success
end

-- Memulai siklus ayunan serangan
--
-- CATATAN FIX (spam-cancel bug): dulu ada "swing lock" yang MENOLAK input
-- serangan baru kalau ayunan sebelumnya masih dalam window aktifnya. Client
-- di sisi lain sudah kadung memutar animasi baru secara optimis begitu
-- ditekan, jadi begitu server balas "ditolak", animasi yang baru itu ikut
-- disetop juga -- padahal animasi ayunan SEBELUMNYA juga sudah disetop
-- duluan oleh client sendiri buat kasih jalan ke animasi baru. Efeknya:
-- dua-duanya keliatan batal, walau ayunan pertama sebenarnya sukses & kena
-- damage di server.
--
-- Sekarang: ayunan baru TIDAK PERNAH ditolak gara-gara ayunan lama masih
-- jalan. Sebaliknya, ayunan baru langsung MEMBATALKAN (cancel-in) ayunan
-- lama lewat swingToken -- match dengan apa yang client udah lakuin secara
-- visual. Ayunan lama yang kepotong tidak akan menghasilkan damage lagi
-- (dicek di resolveHit), tapi ayunan baru tetap lanjut normal. Rate-limit
-- spam tetap dijaga lewat cooldown per actionType di listener atas.
function CombatController.startSwing(attacker, victim, actionType)
	-- Kabarin "ada ayunan mulai" -- BotAIService dengerin ini buat mutusin
	-- dodge kalau dia yang jadi korban (victim). Fire SEBELUM delay window
	-- HitboxService supaya bot punya waktu reaksi sebelum kontak beneran
	-- di-cek (lihat window.start di HitboxService.strike).
	CombatController.AttackStarted:Fire(attacker, victim, actionType)
	RemoteSafety.fire(AttackResultEvent, victim, "opponentSwing", true, actionType)

	local trail = VFXService.primeSwingTrail(attacker, actionType)

	local attackerState = PlayerStateRepository.get(attacker)
	local swingToken = ((attackerState and attackerState.swingId) or 0) + 1
	PlayerStateRepository.set(attacker, "swingId", swingToken)

	if not HitboxConfig.ENABLED then
		CombatController.resolveHit(attacker, victim, actionType, nil, swingToken)
		VFXService.endSwingTrail(trail)
		return
	end

	task.spawn(function()
		local contact = HitboxService.strike(attacker, victim, actionType)
		VFXService.endSwingTrail(trail)

		if not contact then return end
		CombatController.resolveHit(attacker, victim, actionType, contact, swingToken)
	end)
end

-- Menyelesaikan kontak serangan & kalkulasi damage
function CombatController.resolveHit(attacker, victim, actionType, contact, swingToken)
	-- Ayunan ini sudah "dipotong" oleh ayunan lebih baru dari attacker yang
	-- sama (spam-cancel) -- jangan proses hit-nya. Ini yang bikin perilakunya
	-- jadi "yang lama kepotong, lanjut ke input terakhir" alih-alih dua-duanya
	-- gugur.
	if swingToken then
		local attackerState = PlayerStateRepository.get(attacker)
		if not attackerState or attackerState.swingId ~= swingToken then
			return
		end
	end

	local victimState = PlayerStateRepository.get(victim)
	if not canBeHit(victimState) then return end

	local attackerState = PlayerStateRepository.get(attacker)
	if not canBeHit(attackerState) then return end

	-- Victim lagi immune (baru menang FFYL) -- anggap pukulan ini nembus
	-- tanpa kontak sama sekali: gak ada damage, gak ada flinch/animasi
	-- hurt, gak ada hit effect, gak ada combo buat attacker. Dicek SEBELUM
	-- logika dodge supaya immune selalu menang telak atas dodge-window,
	-- bukan cuma "ikut" salah satu cabangnya.
	if isImmune(victimState) then
		return
	end

	-- Validasi iframe dodge
	local now = os.clock()
	local lastDodge = victimState.lastDodgeTime or 0
	local sinceDodge = now - lastDodge

	if sinceDodge < GameplayConfig.DODGE_IFRAME then
		-- Kualitas dodge diukur dari SEBERAPA DEKAT input dodge ke saat
		-- kontak. Jeda kecil = korban beneran bereaksi ke ayunan yang lagi
		-- datang (perfect). Jeda besar = dodge-nya kepagian dan kebetulan
		-- i-frame-nya masih nyisa pas bantal lewat (normal).
		local isPerfect = sinceDodge <= GameplayConfig.PERFECT_DODGE_WINDOW

		ComboService.reset(attacker)
		RemoteSafety.fire(AttackResultEvent, attacker, "comboUpdate", true, 0)

		if isPerfect then
			-- Hadiah 1: energi balik lebih banyak dari ongkos dodge-nya,
			-- jadi baca yang benar itu untung bersih.
			EnergyService.refund(victim, EnergyConfig.PERFECT_DODGE_REFUND)

			-- Hadiah 2 (yang sebenarnya penting): penyerang di-stagger, jadi
			-- korban dapat GILIRAN -- jendela balas yang dijamin, bukan cuma
			-- "nggak kena". Numpang field flinchUntil yang sama dengan flinch
			-- kena-pukul; efeknya identik (nggak bisa nyerang, masih bisa
			-- dodge), cuma sumber sebabnya beda.
			PlayerStateRepository.set(
				attacker,
				"flinchUntil",
				now + GameplayConfig.PERFECT_DODGE_PUNISH
			)

			-- Dua event yang beda supaya UI bisa bedain siapa yang berhasil
			-- baca dan siapa yang kebaca. Kamera flourish dipicu dua-duanya
			-- (momen sinematik bersama), tapi teks "PERFECT!" cuma buat yang
			-- ngedodge.
			RemoteSafety.fire(AttackResultEvent, victim, "perfectDodge", true)
			RemoteSafety.fire(AttackResultEvent, attacker, "perfectDodgeHit", true)
		else
			-- Dodge biasa: cukup nggak kena. Tanpa flourish, tanpa hadiah.
			RemoteSafety.fire(AttackResultEvent, victim, "dodgeSuccess", true)
			RemoteSafety.fire(AttackResultEvent, attacker, "dodgeSuccess", true)
		end

		return
	end

	local damage = (actionType == "light")
		and BalanceConfig.LIGHT_HIT
		or BalanceConfig.HEAVY_HIT

	BalanceService.applyDamage(victim, damage)
	CombatController.applyHit(victim, attacker, actionType, contact)

	-- Spawning efek hit
	local hitPosition = contact and contact.position
	if not hitPosition then
		local victimRoot = victim.Character and victim.Character:FindFirstChild("HumanoidRootPart")
		hitPosition = victimRoot and victimRoot.Position
	end
	VFXService.spawnHitEffect(hitPosition, actionType)
	ComboService.reset(victim)
	RemoteSafety.fire(AttackResultEvent, victim, "comboUpdate", true, 0)

	-- Update combo & kirim hit confirm
	local comboCount = ComboService.onHitLanded(attacker)
	RemoteSafety.fire(AttackResultEvent, attacker, "comboUpdate", true, comboCount)
	RemoteSafety.fire(AttackResultEvent, attacker, "hitConfirm", true, actionType)
end

-- Menerapkan efek animasi hurt pada target
function CombatController.applyHit(victimPlayer, attackerPlayer, attackType, contact)
	local victimState = PlayerStateRepository.get(victimPlayer)
	if not victimState then return end

	local now = os.clock()
	PlayerStateRepository.set(victimPlayer, "lastHitTime", now)

	-- Durasi flinch ditentukan di sini (titik kena), karena cuma di sini
	-- kita tahu jenis pukulannya. Selalu lebih pendek dari cooldown
	-- penyerangnya -- lihat GameplayConfig.FLINCH.
	local flinchDuration = GameplayConfig.FLINCH[attackType] or GameplayConfig.FLINCH.light
	PlayerStateRepository.set(victimPlayer, "flinchUntil", now + flinchDuration)

	if attackType == "light" then
		RemoteSafety.fire(
			AttackResultEvent,
			victimPlayer,
			"lightHurt",
			true,
			pickLightHurtVariant(attackerPlayer, contact)
		)
		if RemoteSafety.isBot(victimPlayer) then
			BotAnimationService.play(victimPlayer, "lightHurt")
		end
	elseif attackType == "heavy" then
		RemoteSafety.fire(AttackResultEvent, victimPlayer, "heavyHurt", true)
		if RemoteSafety.isBot(victimPlayer) then
			BotAnimationService.play(victimPlayer, "heavyHurt")
		end
	end
end

-- Memicu animasi FFYL di client
function CombatController.triggerFFYLAnimation(player, animType)
	RemoteSafety.fire(AttackResultEvent, player, animType, true)
	if RemoteSafety.isBot(player) then
		BotAnimationService.play(player, animType)
	end
end

return CombatController