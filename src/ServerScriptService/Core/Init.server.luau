-- @ScriptType: Script
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

-- REQUIRE SERVICES
local Core = ServerScriptService:FindFirstChild("Core", true) or ServerScriptService:WaitForChild("Core")
local Services = Core.Service
local ArenaService       = require(Services.ArenaService)
local BalanceService     = require(Services.BalanceService)
local EnergyService      = require(Services.EnergyService)
local LeaderboardService = require(Services.LeaderboardService)
local PlayerDataService  = require(Services.PlayerDataService) -- DITAMBAHKAN
local PunishmentService  = require(Services.PunishmentService) -- Anti-GB Layer 2: suspicionCount & ban persisten
local StreakDisplayService = require(Services.StreakDisplayService) -- DITAMBAHKAN: badge win streak gak pernah ke-init
local PartService        = require(Services.PartService)

local PlayerStateRepository = require(Core.Repository.PlayerStateRepository)

-- REQUIRE CONTROLLERS
local Controllers = Core.Controller
local CombatController = require(Controllers.CombatController)
local MatchController   = require(Controllers.MatchController) -- DITAMBAHKAN BALIK, INI YANG BIKIN PAD TELEPORTER MATI

-- INIT SERVICES
if ArenaService.init then ArenaService.init() end
if BalanceService.startPassiveDecay then BalanceService.startPassiveDecay() end
if EnergyService.startPassiveRegen then EnergyService.startPassiveRegen() end
if StreakDisplayService.init then StreakDisplayService.init() end -- WAJIB: tanpa ini, badge gak pernah dipasang ulang pas character respawn, dan updateStreak() pas player baru join (sebelum character spawn) gak ada yang nge-reapply dari cache
if PartService.init then PartService.init() end

-- INIT CONTROLLERS
if CombatController.init then CombatController.init() end
if MatchController.init then MatchController.init() end -- DITAMBAHKAN BALIK

-- ================================================================
-- HANDLERS PLAYER JOIN & LEAVE
-- ================================================================
local function handlePlayerJoined(player)
	-- 0. Muat data AntiGB (suspicionCount/escalation/ban) DULU
	PunishmentService.load(player)
	if PunishmentService.checkBanOnJoin(player) then
		return
	end

	-- 1. Load data lama dari DataStore ke PlayerStateRepository
	local loadOk = PlayerDataService.loadData(player)
	if not loadOk then
		-- GetAsync gagal terus setelah retry -- JANGAN biarkan pemain main
		-- dengan data kosong yang bakal ke-treat sebagai progress asli.
		player:Kick("Gagal memuat data kamu. Silakan coba join lagi dalam beberapa saat.")
		return
	end

	-- 2. Mulai catat waktu sesi bermain
	LeaderboardService.onPlayerJoined(player)
end

local function handlePlayerLeaving(player)
	-- 1. Tangani jika pemain keluar saat match berjalan
	if ArenaService.handlePlayerLeaving then
		ArenaService.handlePlayerLeaving(player)
	end
	-- 2. Akumulasi PlayTime di PlayerStateRepository
	LeaderboardService.onPlayerLeaving(player)
	-- 3. Simpan seluruh data permanen ke DataStore
	PlayerDataService.saveData(player)
	-- 4. Pastikan data AntiGB (suspicionCount/escalation/ban) ke-persist & cache bersih
	PunishmentService.cleanup(player)

	-- 5. FIX (memory leak): hapus entry player ini dari PlayerStateRepository.
	-- WAJIB PALING TERAKHIR -- semua langkah di atas (ArenaService, Leaderboard,
	-- PlayerDataService) masih butuh baca PlayerStateRepository.get(player).
	-- Tanpa ini, _state[playerId] nyangkut selamanya di memori server walau
	-- pemainnya sudah lama keluar.
	PlayerStateRepository.remove(player)
end

Players.PlayerAdded:Connect(handlePlayerJoined)
Players.PlayerRemoving:Connect(handlePlayerLeaving)

-- Pengaman jika server di-shutdown mendadak (Save semua player yang tersisa)
game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		handlePlayerLeaving(player)
	end
end)

-- Handle existing players (untuk testing di Studio)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(handlePlayerJoined, player)
end