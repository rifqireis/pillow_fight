-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : EnergyService
    Layer      : Service (ServerScriptService/Core/Service)
    Deskripsi  : Mengelola sistem energi pemain, konsumsi energi per aksi,
                 regenerasi pasif, dan mekanisme penalti stun ketika energi habis.
    Penulis    : Yusuf Ahayy
    Tanggal    : 25 Juni 2026
    Versi      : 1.2 -- nambah trigger stun VFX (dizzy stars) pas energi habis/pulih
    Dependensi : PlayerStateRepository, EnergyConfig, SyncEnergyEvent, StunEvent
]]

local EnergyService = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Configs = ReplicatedStorage:WaitForChild("Configs")

local SyncEnergyEvent = Remotes:WaitForChild("SyncEnergyEvent")
local StunEvent = Remotes:WaitForChild("StunEvent")
local SyncOpponentStatsEvent = Remotes:WaitForChild("SyncOpponentStatsEvent")
local AttackResultEvent = Remotes:WaitForChild("AttackResultEvent")

local EnergyConfig = require(Configs:WaitForChild("EnergyConfig"))
local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local VFXService = require(ServerScriptService.Core.Service.VFXService)
local RemoteSafety = require(ServerScriptService.Core.Service.RemoteSafety)

local ArenaService
local function getOpponent(player)
	ArenaService = ArenaService or require(ServerScriptService.Core.Service.ArenaService)
	return ArenaService.getOpponent(player)
end

local BotService

-- Bot bukan Instance Player, jadi Players:GetPlayers() tidak pernah
-- mengembalikannya. Regen energi harus memproses player + bot.
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

local lastActionTime = {}

-- Sinkronisasi energi ke pemain dan lawan
local function syncToClient(player, newEnergy)
	RemoteSafety.fire(SyncEnergyEvent, player, newEnergy)

	local opponent = getOpponent(player)
	if opponent then
		RemoteSafety.fire(SyncOpponentStatsEvent, opponent, "energy", newEnergy)
	end
end

-- Menerapkan efek stun saat energi habis
local function applyStun(player)
	PlayerStateRepository.set(player, "isStun", true)
	RemoteSafety.fire(StunEvent, player)
	RemoteSafety.fire(AttackResultEvent, player, "stun", true)
	VFXService.setStunEffect(player, true)
	print("[EnergyService] " .. player.Name .. " terkena STUN!")

	task.delay(EnergyConfig.STUN_DURATION, function()
		local state = PlayerStateRepository.get(player)
		if state then
			PlayerStateRepository.set(player, "isStun", false)
			RemoteSafety.fire(AttackResultEvent, player, "stun_end", true)
			VFXService.setStunEffect(player, false)
			print("[EnergyService] " .. player.Name .. " stun selesai.")
		end
	end)
end

-- Mengkonsumsi energi sesuai tipe aksi
function EnergyService.consumeEnergy(player, actionType)
	local state = PlayerStateRepository.get(player)

	if not state or state.isStun or state.isFFYL or not state.isPlaying or not state.isAlive then
		return false
	end

	local cost = 0
	if actionType == "light" then
		cost = EnergyConfig.COST_LIGHT
	elseif actionType == "heavy" then
		cost = EnergyConfig.COST_HEAVY
	elseif actionType == "dodge" then
		cost = EnergyConfig.COST_DODGE
	else
		warn("[EnergyService] Tipe aksi tidak dikenal: " .. tostring(actionType))
		return false
	end

	if state.energy < cost then
		return false
	end

	lastActionTime[player.UserId] = os.clock()

	local oldEnergy = state.energy
	local newEnergy = math.max(EnergyConfig.MIN_ENERGY, oldEnergy - cost)
	PlayerStateRepository.set(player, "energy", newEnergy)
	syncToClient(player, newEnergy)

	print("[EnergyService] " .. player.Name .. " pakai " .. actionType .. " | Energi: " .. oldEnergy .. " > " .. newEnergy)


	if newEnergy <= EnergyConfig.MIN_ENERGY then
		applyStun(player)
	end

	return true
end

-- Mengembalikan energi ke pemain (dipakai hadiah PERFECT DODGE).
--
-- Sengaja TIDAK menyentuh lastActionTime: perfect dodge itu hadiah, bukan
-- aksi baru, jadi jangan sampai malah nunda regen pasif pemain yang barusan
-- main bagus. Di-clamp ke MAX_ENERGY dan tetap sync ke lawan supaya bar
-- energi di layar lawan ikut naik -- lawan harus lihat kalau dia baru saja
-- kebaca, itu bagian dari informasi pertarungan.
function EnergyService.refund(player, amount)
	local state = PlayerStateRepository.get(player)
	if not state or not amount or amount <= 0 then return end

	local newEnergy = math.min(EnergyConfig.MAX_ENERGY, state.energy + amount)
	if newEnergy == state.energy then return end

	PlayerStateRepository.set(player, "energy", newEnergy)
	syncToClient(player, newEnergy)
end

-- Reset timer regen ketika ronde baru dimulai.
function EnergyService.resetPlayer(player)
	if player then
		lastActionTime[player.UserId] = os.clock()
	end
end

-- Memulai loop pemulihan energi pasif saat pemain tidak melakukan aksi
function EnergyService.startPassiveRegen()
	task.spawn(function()
		while true do
			task.wait(0.1)

			for _, player in ipairs(getActiveCombatants()) do
				local state = PlayerStateRepository.get(player)

				if state and state.isPlaying and state.isAlive and not state.isStun and not state.isFFYL then
					local lastAction = lastActionTime[player.UserId] or 0
					if os.clock() - lastAction >= EnergyConfig.ENERGY_REGEN_DELAY then
						if state.energy < EnergyConfig.MAX_ENERGY then
							local newEnergy = math.min(
								EnergyConfig.MAX_ENERGY,
								state.energy + EnergyConfig.ENERGY_REGEN_RATE
							)
							PlayerStateRepository.set(player, "energy", newEnergy)
							syncToClient(player, newEnergy)
						end
					end
				end
			end
		end
	end)
end

return EnergyService