-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
	Nama File : BalanceService
	Layer     : Service
	Deskripsi : Mengelola keseimbangan, decay pasif, dan recovery FFYL.
	Penulis   : Rifqi RR, Abdul VVI
	Tanggal   : 23 Juni 2026
	Versi     : 1.2 -- nambah trigger stun VFX (dizzy stars) pas masuk/keluar FFYL
]]
local BalanceService = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Configs = ReplicatedStorage:WaitForChild("Configs")

local SyncBalanceEvent = Remotes:WaitForChild("SyncBalanceEvent")
local AttackResultEvent = Remotes:WaitForChild("AttackResultEvent")
local SyncOpponentStatsEvent = Remotes:WaitForChild("SyncOpponentStatsEvent")
local SyncEnergyEvent = Remotes:WaitForChild("SyncEnergyEvent")

local BalanceConfig = require(Configs:WaitForChild("BalanceConfig"))
local EnergyConfig = require(Configs:WaitForChild("EnergyConfig"))
local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local VFXService = require(ServerScriptService.Core.Service.VFXService)
local RemoteSafety = require(ServerScriptService.Core.Service.RemoteSafety)

local ArenaService
local function getOpponent(player)
	ArenaService = ArenaService or require(ServerScriptService.Core.Service.ArenaService)
	return ArenaService.getOpponent(player)
end

-- Bot bukan Instance Player, jadi Players:GetPlayers() tidak pernah
-- mengembalikannya. Semua tick gameplay harus memakai daftar gabungan ini.
local BotService

local function getActiveCombatants()
	local combatants = {}

	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(combatants, player)
	end

	BotService = BotService or require(ServerScriptService.Core.Service.BotService)
	for _, botPlayer in ipairs(BotService.getActivePlayers()) do
		table.insert(combatants, botPlayer)
	end

	return combatants
end

local function _syncBalance(player, newBalance)
	RemoteSafety.fire(SyncBalanceEvent, player, newBalance)

	local opponent = getOpponent(player)
	if opponent then
		RemoteSafety.fire(SyncOpponentStatsEvent, opponent, "balance", newBalance)
	end
end

local function _syncEnergy(player, newEnergy)
	RemoteSafety.fire(SyncEnergyEvent, player, newEnergy)

	local opponent = getOpponent(player)
	if opponent then
		RemoteSafety.fire(SyncOpponentStatsEvent, opponent, "energy", newEnergy)
	end
end

-- Masuk FFYL = mulai stun (dizzy stars + wajah pusing + SFX). Dipanggil
-- dari 2 tempat (passive decay & applyDamage) makanya di-satuin di sini.
local function _enterFFYL(player)
	PlayerStateRepository.set(player, "isFFYL", true)
	VFXService.setStunEffect(player, true)

	local FFYLService = require(ServerScriptService.Core.Service.FFYLService)
	FFYLService.startMinigame(player)
end

function BalanceService.startPassiveDecay()
	task.spawn(function()
		while true do
			task.wait(1)
			local allPlayers = getActiveCombatants()
			local now = os.clock() -- Ambil waktu server saat ini

			for _, player in ipairs(allPlayers) do
				local state = PlayerStateRepository.get(player)

				if state and state.isPlaying and state.isAlive and not state.isFFYL then

					-- Ambil data kapan terakhir kali pemain bergerak atau dipukul
					local lastActionTime = state.lastActionTime or 0
					local lastHitTime = state.lastHitTime or 0

					-- LOGIKA PENGECEKAN: Apakah pemain sudah diam/idle selama 5 detik?
					if (now - lastActionTime >= BalanceConfig.IDLE_DELAY) and (now - lastHitTime >= BalanceConfig.IDLE_DELAY) then
						local currentBalance = state.balance

						if currentBalance > BalanceConfig.MIN_BALANCE then
							local newBalance = currentBalance - BalanceConfig.DECAY_RATE

							if newBalance < BalanceConfig.MIN_BALANCE then
								newBalance = BalanceConfig.MIN_BALANCE
							end

							-- Simpan hasil pengurangan ke Repository RAM
							PlayerStateRepository.set(player, "balance", newBalance)

							_syncBalance(player, newBalance)

							-- JIKA BALANCE MENYENTUH 0 -> MASUK MODE FFYL
							if newBalance == BalanceConfig.MIN_BALANCE then
								_enterFFYL(player)
							end
						end
					end

				end
			end
		end
	end)
end

function BalanceService.applyDamage(player, amount)
	local state = PlayerStateRepository.get(player)

	-- Hanya berlaku untuk pemain yang aktif bertanding dan belum FFYL
	if not state or not state.isPlaying or not state.isAlive or state.isFFYL then
		return
	end

	-- Immune sesaat setelah menang FFYL (lihat BalanceConfig.FFYL_WIN_IMMUNE_DURATION),
	-- biar nggak langsung kena pukulan susulan pas baru aja bangun.
	if state.ffylImmuneUntil and os.clock() < state.ffylImmuneUntil then
		print("[BalanceService] " .. player.Name .. " immune, damage diabaikan.")
		return
	end

	local currentBalance = state.balance
	if currentBalance <= BalanceConfig.MIN_BALANCE then return end

	local newBalance = math.max(BalanceConfig.MIN_BALANCE, currentBalance - amount)
	PlayerStateRepository.set(player, "balance", newBalance)
	print("[BalanceService] " .. player.Name .. " terkena pukulan. Keseimbangan: " .. newBalance)

	_syncBalance(player, newBalance)

	-- Keseimbangan habis -> masuk mode kritis FFYL
	if newBalance <= BalanceConfig.MIN_BALANCE then
		print("[BalanceService] " .. player.Name .. " terjatuh, memasuki keadaan kritis FFYL!")
		_enterFFYL(player)
	end
end

function BalanceService.recoverFFYL(player)
	local state = PlayerStateRepository.get(player)

	-- VALIDASI: Pastikan pemain memang benar sedang dalam mode FFYL dan masih hidup
	if state and state.isFFYL and state.isAlive then
		-- Hitung berapa kali sudah survive FFYL sebelumnya
		local state = PlayerStateRepository.get(player)

		if state and state.isFFYL and state.isAlive then
			local survivalCount = state.ffylSurvivalCount or 0
			local startTime = state.ffylStartTime or os.clock()

			-- 1. HITUNG RATING KECEPATAN (0.0 sampai 1.0)
			local totalDuration = BalanceConfig.FFYL_DURATION or 5
			local timeTaken = math.clamp(os.clock() - startTime, 0, totalDuration)
			local timeLeft = totalDuration - timeTaken

			-- speedRatio: 1.0 (sangat cepat/0 detik) s/d 0.0 (sangat lambat/5 detik)
			local speedRatio = math.clamp(timeLeft / totalDuration, 0, 1)

			-- 2. HITUNG PENALTY BERDASARKAN SURVIVAL COUNT (Sistem Lama)
			local penalty = survivalCount * BalanceConfig.FFYL_RECOVERY_PENALTY
			local maxPossibleRecovery = math.max(
				BalanceConfig.FFYL_RECOVERY_MIN,
				BalanceConfig.FFYL_RECOVERY_BASE - penalty
			)

			-- 3. KALIKAN DENGAN SPEED RATIO (Dynamic Balance Recovery)
			-- Jika cepat: dapat 100% dari maxPossibleRecovery
			-- Jika lambat: minimal dapat 25% dari maxPossibleRecovery (agar tidak nol)
			local MIN_SPEED_MULTIPLIER = 0.25 
			local finalMultiplier = MIN_SPEED_MULTIPLIER + (speedRatio * (1 - MIN_SPEED_MULTIPLIER))

			local recoveryBalance = math.floor(maxPossibleRecovery * finalMultiplier)
			local newBalance = math.min(BalanceConfig.MAX_BALANCE, state.balance + recoveryBalance)

			-- 4. DYNAMIC ENERGY RECOVERY (Makin cepat, energi makin penuh)
			-- Contoh: Min 30% Energy, Max 100% Energy tergantung speedRatio
			local minEnergyPercent = 0.30
			local energyPercent = minEnergyPercent + (speedRatio * (1 - minEnergyPercent))

			-- Dibulatkan ke kelipatan ENERGY_STEP, bukan math.floor biasa.
			-- math.floor menghasilkan angka sembarang (mis. 100 * 0.73 = 73),
			-- dan itu menendang energi pemain keluar dari kisi kelipatan yang
			-- dijaga EnergyConfig. Akibatnya energi tidak akan pernah lagi
			-- mendarat tepat di 0, dan stun kehabisan energi mati diam-diam
			-- sampai ronde berakhir. Lihat aturan kelipatan di EnergyConfig.
			local step = EnergyConfig.ENERGY_STEP
			local rawEnergy = EnergyConfig.MAX_ENERGY * energyPercent
			local newEnergy = math.clamp(
				math.floor(rawEnergy / step + 0.5) * step,
				EnergyConfig.MIN_ENERGY,
				EnergyConfig.MAX_ENERGY
			)

			-- 5. UPDATE STATE
			PlayerStateRepository.set(player, "balance", newBalance)
			PlayerStateRepository.set(player, "energy", newEnergy)
			PlayerStateRepository.set(player, "isFFYL", false)
			PlayerStateRepository.set(player, "ffylSurvivalCount", survivalCount + 1)

			-- Kasih immune sesaat biar nggak langsung digebukin lagi begitu bangun
			PlayerStateRepository.set(player, "ffylImmuneUntil", os.clock() + BalanceConfig.FFYL_WIN_IMMUNE_DURATION)

			_syncBalance(player, newBalance)
			_syncEnergy(player, newEnergy)

			-- Shield effect nyala SELAMA window immune ini doang (mis. 0.4s),
			-- bukan nunggu VFXService.setShieldEffect(false) dipanggil dari
			-- tempat lain -- soalnya immune di sini murni timer pasif
			-- (ffylImmuneUntil), gak ada event terpisah buat "immune habis".
			-- task.delay dengan durasi yang SAMA PERSIS jadi cara paling
			-- akurat buat matiin shield tepat saat window-nya beneran abis.
			print("[BalanceService][DEBUG] Shield ON dikirim buat " .. player.Name
				.. " (window sampai t=" .. string.format("%.2f", os.clock() + BalanceConfig.FFYL_WIN_IMMUNE_DURATION) .. ")")
			VFXService.setShieldEffect(player, true)
			task.delay(BalanceConfig.FFYL_WIN_IMMUNE_DURATION, function()
				-- Guard: kalau sempat menang FFYL LAGI sebelum delay ini
				-- selesai (immune baru udah nyala), jangan matiin shield yang
				-- itu -- cukup skip, biar delay milik window terbaru yang
				-- nentuin kapan shield beneran mati.
				local currentState = PlayerStateRepository.get(player)
				if not currentState then
					print("[BalanceService][DEBUG] Shield OFF timer nyala tapi state " .. player.Name .. " udah gak ada (player leave?)")
					return
				end
				if currentState.ffylImmuneUntil then
					local windowSudahLewat = os.clock() >= currentState.ffylImmuneUntil
					print("[BalanceService][DEBUG] Cek shield OFF buat " .. player.Name
						.. " | now=" .. string.format("%.2f", os.clock())
						.. " | ffylImmuneUntil=" .. string.format("%.2f", currentState.ffylImmuneUntil)
						.. " | windowSudahLewat=" .. tostring(windowSudahLewat))
					if windowSudahLewat then
						print("[BalanceService][DEBUG] -> Shield OFF dikirim buat " .. player.Name)
						VFXService.setShieldEffect(player, false)
					else
						print("[BalanceService][DEBUG] -> Skip matiin shield " .. player.Name .. " (ada window immune baru yang lebih panjang)")
					end
				end
			end)
		end
	end
end


return BalanceService