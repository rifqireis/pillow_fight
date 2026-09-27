-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : FFYLService
    Layer      : Service (ServerScriptService/Core/Service)
    Deskripsi  : Mengelola status dan logika minigame Fight For Your Life (FFYL).
                 Menangani timer server, evaluasi keberhasilan spasi, dan transisi ke KO.
    Penulis    : Yusuf Ahayy, Rifqi RR
    Tanggal    : 4 Juli 2026
    Versi      : 2.1
    Dependensi : BalanceConfig, PlayerStateRepository, ArenaService, BalanceService, CombatController
]]

local FFYLService = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Configs = ReplicatedStorage:WaitForChild("Configs")

local FFYLStateEvent = Remotes:WaitForChild("FFYLStateEvent")

local BalanceConfig = require(Configs:WaitForChild("BalanceConfig"))
local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local RemoteSafety = require(ServerScriptService.Core.Service.RemoteSafety)

-- Memunculkan UI minigame dan memulai timer server
function FFYLService.startMinigame(player)
	PlayerStateRepository.set(player, "ffylStartTime", os.clock())
	RemoteSafety.fire(FFYLStateEvent, player, true, BalanceConfig.FFYL_DURATION)
	print("[FFYLService] Minigame FFYL dimulai untuk: " .. player.Name)

	-- Memicu animasi awal FFYL
	local CombatController = require(ServerScriptService.Core.Controller.CombatController)
	CombatController.triggerFFYLAnimation(player, "startFFYL")

	-- Timer batas waktu bertahan hidup di server
	task.delay(BalanceConfig.FFYL_DURATION, function()
		local state = PlayerStateRepository.get(player)
		if state and state.isFFYL and state.isAlive then
			FFYLService.handleFailure(player)
		end
	end)
end

-- Menangani keberhasilan pemain menyelesaikan minigame spasi
function FFYLService.handleSuccess(player)
	local state = PlayerStateRepository.get(player)
	if not state or not state.isFFYL or not state.isAlive then
		return
	end

	FFYLService.cleanupUI(player)

	local CombatController = require(ServerScriptService.Core.Controller.CombatController)
	CombatController.triggerFFYLAnimation(player, "endFFYL")

	local BalanceService = require(ServerScriptService.Core.Service.BalanceService)
	BalanceService.recoverFFYL(player)
end

-- Menangani kegagalan pemain jika waktu minigame habis
function FFYLService.handleFailure(player)
	FFYLService.cleanupUI(player)
	PlayerStateRepository.set(player, "isAlive", false)
	PlayerStateRepository.set(player, "isFFYL", false)

	-- Notifikasi efek KO ke arena sebelum transisi animasi kekalahan
	local ArenaService = require(ServerScriptService.Core.Service.ArenaService)
	ArenaService.notifyKO(player)

	print("[FFYLService] " .. player.Name .. " gagal bertahan hidup.")
	ArenaService.handlePlayerDefeated(player)
end

-- Menutup UI minigame di sisi client
function FFYLService.cleanupUI(player)
	RemoteSafety.fire(FFYLStateEvent, player, false)
	print("[FFYLService] Panel FFYL ditutup untuk: " .. player.Name)
end

return FFYLService