-- @ScriptType: ModuleScript
--[[
    Nama File  : MatchController
    Layer      : Controller (ServerScriptService/Core/Controller)
    Deskripsi  : Menangani deteksi fisik awal pemain pada pad Teleporter arena.
                 Mengubah visual pad (Neon) dan mengalirkan antrean ke MatchmakingService.
    Penulis    : Vikri Abdullah [EPIK]
    Tanggal    : 27-06-2026
    Versi      : 3.1
    Dependensi : MatchmakingService, PlayerStateRepository
]]

local MatchController = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local MatchmakingService = require(ServerScriptService.Core.Service.MatchmakingService)

local function getPlayerFromHit(hit)
	if not hit or not hit.Parent then return nil end
	return Players:GetPlayerFromCharacter(hit.Parent)
end

local function setupArenaTeleporter(arenaFolder)
	local arenaName = arenaFolder.Name
	local teleporter = arenaFolder:WaitForChild("Teleporter", 5)

	if not teleporter then
		warn("[MatchController] Gagal memuat " .. arenaName .. " — Part 'Teleporter' tidak ditemukan.")
		return
	end

	local originalMaterial = teleporter.Material

	-- Pemicu antrean saat pad diinjak
	teleporter.Touched:Connect(function(hit)
		local player = getPlayerFromHit(hit)
		if not player then return end

		local state = PlayerStateRepository.get(player)
		if state and state.isInMatchmaking then
			return
		end

		teleporter.Material = Enum.Material.Neon
		MatchmakingService.addPlayerToQueue(player, arenaName)
	end)

	-- Reset visual pad saat pemicu terlepas
	teleporter.TouchEnded:Connect(function(hit)
		local player = getPlayerFromHit(hit)
		if not player then return end

		task.delay(0.1, function()
			teleporter.Material = originalMaterial
		end)
	end)

	print("[MatchController] Teleporter dimuat untuk: " .. arenaName)
end

function MatchController.init()
	local pillowArena = Workspace:WaitForChild("World"):WaitForChild("Environment"):WaitForChild("PillowArena")

	-- Setup seluruh folder arena yang sudah ada
	for _, child in ipairs(pillowArena:GetChildren()) do
		if child:IsA("Folder") then
			task.spawn(setupArenaTeleporter, child)
		end
	end

	-- Listener jika ada folder arena baru dimasukkan secara dinamis
	pillowArena.ChildAdded:Connect(function(child)
		if child:IsA("Folder") then
			task.spawn(setupArenaTeleporter, child)
		end
	end)

	print("[MatchController] Listener Aktif")
end

return MatchController