-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : BotAIService
    Layer      : Service (ServerScriptService/Core/Service)
    Deskripsi  : Otak AI bot -- nyalain loop keputusan server-side (nyerang
                 light/heavy sesuai energi), dengerin sinyal serangan masuk
                 buat coba dodge dalam window reaksi, dan simulasi "mash"
                 minigame FFYL. Semua aksi bot lewat
                 CombatController.performAction() -- JALUR YANG SAMA PERSIS
                 kayak pemain asli (lewat validasi cooldown/energi/flinch
                 yang sama), jadi bot gak curang & gak bisa spam.

                 PENTING (lihat catatan di start()): ArenaService manggil
                 BotAIService.start() di SETIAP AWAL RONDE (bukan cuma sekali
                 di awal match) -- kalau start() gak idempoten, ronde 2+ bakal
                 numpuk beberapa loop AI sekaligus jalan bareng buat bot yang
                 sama. start() SELALU stop() sesi lama dulu sebelum mulai
                 sesi baru untuk bot itu.

                 BotAIService.stop() WAJIB dipanggil manual saat bot
                 di-cleanup (lihat BotService.destroy & ArenaService
                 endMatch/abortMatch, fase berikutnya) -- gak ada mekanisme
                 otomatis yang nyetop loop ini kalau gak dipanggil manual.

                 PATCH 17 Agustus 2026 (animasi): bot gak punya client, jadi
                 AttackResultEvent yang biasanya nge-trigger animasi di
                 AnimationController (LocalScript) SELALU no-op buat bot
                 (RemoteSafety.fire cek isRealPlayer -- lihat catatan di
                 RemoteSafety.lua). BotAnimationService.play() dipanggil
                 LANGSUNG di sini, tepat di titik BotAIService sendiri yang
                 tahu paling awal & paling pasti bahwa suatu aksi BENERAN
                 berhasil -- bukan nebak dari sinyal lain:
                   - runDecisionLoop     -> light/heavy, HANYA kalau
                     CombatController.performAction() balikin true (energi
                     cukup & gak lagi flinch)
                   - connectDodgeReaction -> dodge, HANYA kalau performAction
                     dodge balikin true (dodge tetap bisa ditolak walau
                     lolos guard isPlaying/isAlive/isFFYL di atasnya --
                     mis. energi dodge gak cukup)
                   - start()/stop()      -> idle nyala begitu AI aktif,
                     berhenti begitu AI di-stop (ronde selesai/bot cleanup)
    Tanggal    : 17 Agustus 2026
    Dependensi : BotConfig, EnergyConfig, BalanceConfig, PlayerStateRepository,
                 CombatController, FFYLService, BotAnimationService
]]

local BotAIService = {}

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BotConfig = require(ReplicatedStorage.Configs.BotConfig)
local EnergyConfig = require(ReplicatedStorage.Configs.EnergyConfig)
local BalanceConfig = require(ReplicatedStorage.Configs.BalanceConfig)
local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local CombatController = require(ServerScriptService.Core.Controller.CombatController)
local BotAnimationService = require(ServerScriptService.Core.Service.BotAnimationService)

-- sessions[botPlayer] = { active = bool, connections = {Connection, ...} }
local sessions = {}

-- Satu dodge aktif pada satu waktu. Tanpa gate ini, beberapa AttackStarted
-- yang datang berdekatan bisa membuat beberapa task reaction hidup bersamaan
-- dan semuanya mencoba dodge ketika window sudah berubah.
local dodgeBusyUntil = {}

local function randomRange(min, max)
	return min + math.random() * (max - min)
end

-- Hentikan semua loop/koneksi AI milik satu bot. Aman dipanggil berkali-kali
-- (no-op kalau memang gak ada sesi aktif).
function BotAIService.stop(botPlayer)
	local session = sessions[botPlayer]
	dodgeBusyUntil[botPlayer] = nil
	if not session then return end

	session.active = false
	for _, connection in ipairs(session.connections) do
		connection:Disconnect()
	end

	-- Matikan idle bareng sesi -- kalau nggak, animasi idle bot nyangkut
	-- muter terus walau AI-nya udah berhenti (mis. ronde selesai / bot
	-- lagi di-cleanup lewat BotService.destroy).
	BotAnimationService.stop(botPlayer, "idle")

	sessions[botPlayer] = nil
end

-- Loop keputusan nyerang: tiap DECISION_INTERVAL, cek energi bot -- kalau
-- cukup, pilih light/heavy (HEAVY_CHANCE) dan lempar lewat
-- CombatController.performAction (tervalidasi cooldown/energi/flinch
-- SAMA PERSIS kayak pemain asli).
local function runDecisionLoop(botPlayer, session)
	while session.active do
		task.wait(randomRange(BotConfig.DECISION_INTERVAL_MIN, BotConfig.DECISION_INTERVAL_MAX))
		if not session.active then return end

		local state = PlayerStateRepository.get(botPlayer)
		if not state or not state.isPlaying or not state.isAlive then
			-- Ronde/match belum mulai lagi (transisi) atau bot ini sudah
			-- kalah -- jangan nyerang, tapi loop TETAP jalan (nunggu ronde
			-- berikutnya) karena stop() eksplisit yang nentuin kapan sesi
			-- ini beneran berhenti, bukan status match sesaat.
			continue
		end
		if state.isFFYL then
			-- Lagi FFYL -- CombatController.performAction bakal nolak
			-- aksi apa pun dari state ini, jadi gak usah dicoba sama sekali.
			continue
		end

		local energyRatio = (state.energy or 0) / EnergyConfig.MAX_ENERGY
		if energyRatio < BotConfig.MIN_ENERGY_RATIO_TO_ATTACK then
			continue
		end

		local actionType = (math.random() <= BotConfig.HEAVY_CHANCE) and "heavy" or "light"
		local success = CombatController.performAction(botPlayer, actionType)

		-- Cuma mainin animasi kalau aksinya BENERAN lolos validasi server
		-- (energi cukup & gak lagi flinch) -- rig bot gak boleh mengayun
		-- kalau serangannya sendiri ditolak, sama kayak pemain asli yang
		-- animasinya di-rollback lewat attackResultEvent success=false.
		if success then
			BotAnimationService.play(botPlayer, actionType)
		end
	end
end

-- Dengerin CombatController.AttackStarted (BindableEvent internal -- lihat
-- catatan di CombatController.startSwing). Kalau BOT ini yang jadi korban
-- (victim), tunggu REACTION_DELAY (simulasi waktu reaksi manusia), lalu
-- coba dodge dengan peluang DODGE_SUCCESS_CHANCE.
local function connectDodgeReaction(botPlayer, session)
	local connection = CombatController.AttackStarted.Event:Connect(function(attacker, victim, actionType)
		if victim ~= botPlayer then return end
		if not session.active then return end

		task.spawn(function()
			local now = os.clock()
			if (dodgeBusyUntil[botPlayer] or 0) > now then
				return
			end

			local reactionDelay = randomRange(
				BotConfig.REACTION_DELAY_MIN,
				BotConfig.REACTION_DELAY_MAX
			)
			dodgeBusyUntil[botPlayer] = now + reactionDelay + (BotConfig.DODGE_BUSY_WINDOW or 0.12)

			task.wait(reactionDelay)
			if not session.active then return end

			local state = PlayerStateRepository.get(botPlayer)
			if not state or not state.isPlaying or not state.isAlive or state.isFFYL then
				return
			end

			if math.random() <= BotConfig.DODGE_SUCCESS_CHANCE then
				local success = CombatController.performAction(botPlayer, "dodge")
				if success then
					BotAnimationService.play(botPlayer, "dodge")
				end
			end
			-- Kalau roll gak kena: sengaja TIDAK dodge -- ini yang bikin
			-- bot "kadang telat baca gerakan lawan" (lihat catatan
			-- BotConfig.DODGE_SUCCESS_CHANCE), bukan bug.
		end)
	end)

	table.insert(session.connections, connection)
end

-- Watcher FFYL: begitu bot masuk FFYL (state.isFFYL == true), jadwalkan
-- SATU percobaan "mash" (biar gak nyoba berkali-kali buat instance FFYL
-- yang sama). Peluang berhasil FFYL_SUCCESS_CHANCE; kalau roll gagal,
-- SENGAJA gak mash sama sekali -- biarkan timer alami FFYLService yang
-- nge-trigger handleFailure (K.O.) sendiri.
local function runFfylWatcher(botPlayer, session)
	local handledThisFfyl = false

	while session.active do
		task.wait(0.15)
		if not session.active then return end

		local state = PlayerStateRepository.get(botPlayer)
		if not state then continue end

		if not state.isFFYL then
			handledThisFfyl = false
			continue
		end

		if handledThisFfyl then continue end
		handledThisFfyl = true

		task.spawn(function()
			local mashDelay = randomRange(BotConfig.FFYL_SUCCESS_DELAY_MIN, BotConfig.FFYL_SUCCESS_DELAY_MAX)
			-- Jangan pernah lewatin durasi FFYL beneran -- kalau lebih
			-- panjang, potong biar tetap "berhasil dalam waktu" alih-alih
			-- keburu di-KO duluan sama timer FFYLService.
			mashDelay = math.min(mashDelay, math.max(BalanceConfig.FFYL_DURATION - 0.2, 0.1))
			task.wait(mashDelay)
			if not session.active then return end

			local currentState = PlayerStateRepository.get(botPlayer)
			if not currentState or not currentState.isFFYL or not currentState.isAlive then
				return
			end

			if math.random() <= BotConfig.FFYL_SUCCESS_CHANCE then
				local FFYLService = require(ServerScriptService.Core.Service.FFYLService)
				FFYLService.handleSuccess(botPlayer)
			end
		end)
	end
end

-- Nyalain AI buat satu bot. Dipanggil ArenaService.startRound() begitu
-- isPlaying baru jadi true untuk bot itu (persis titik yang sama pemain
-- asli mulai bisa menyerang) -- lihat catatan idempoten di atas.
function BotAIService.start(botPlayer, opponent)
	BotAIService.stop(botPlayer)

	local session = { active = true, connections = {} }
	sessions[botPlayer] = session

	connectDodgeReaction(botPlayer, session)
	task.spawn(runDecisionLoop, botPlayer, session)
	task.spawn(runFfylWatcher, botPlayer, session)

	-- Nyalain idle begitu AI aktif -- persis titik yang sama
	-- syncMatchStateEvent(true) nyalain idle track buat pemain asli.
	BotAnimationService.play(botPlayer, "idle")

	print("[BotAIService] AI aktif untuk " .. tostring(botPlayer.Name) .. " vs " .. tostring(opponent and opponent.Name))
end

return BotAIService