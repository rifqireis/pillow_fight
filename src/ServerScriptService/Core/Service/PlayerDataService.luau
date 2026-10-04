-- @ScriptType: ModuleScript
--[[
	Nama File : PlayerDataService.lua
	Penulis   : Rifqi RR / Yusuf Ahayyy
	Layer     : Service
	Deskripsi : Mengelola penyimpanan permanen (Save/Load) data pemain ke DataStore.
	            v2.0: retry+kick saat load gagal, delta-save (UpdateAsync) saat save
	            biar progress lama gak pernah ketimpa 0 walau ada request yang gagal.
	Tanggal   : 21 Agustus 2026
	Versi     : 2.0
]]

local PlayerDataService = {}

local DataStoreService     = game:GetService("DataStoreService")
local ServerScriptService  = game:GetService("ServerScriptService")

local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local StreakDisplayService  = require(ServerScriptService.Core.Service.StreakDisplayService)

local PlayerDataStore = DataStoreService:GetDataStore("PlayerData_v1")

local DEFAULT_DATA = {
	totalWins = 0,
	winStreak = 0,
	bestWinStreak = 0,
	totalPlayTime = 0
}

-- Retry config buat loadData
local LOAD_MAX_ATTEMPTS = 3
local LOAD_RETRY_WAIT   = 2 -- detik jeda antar attempt

-- ================================================================
-- LOAD DATA (Saat Player Join)
-- ================================================================
-- Return TRUE kalau load berhasil (baik dapet data lama ATAU memang pemain
-- baru/nil), FALSE kalau GetAsync gagal terus sampai attempt terakhir.
-- Init.server.lua WAJIB ngecek return value ini dan Kick() pemain kalau
-- false -- supaya gak ada lagi skenario "main pakai data kosong yang
-- ke-treat sebagai data asli".
function PlayerDataService.loadData(player)
	PlayerStateRepository.init(player)

	local dataKey = "Player_" .. tostring(player.UserId)

	local success, savedData
	for attempt = 1, LOAD_MAX_ATTEMPTS do
		success, savedData = pcall(function()
			return PlayerDataStore:GetAsync(dataKey)
		end)

		if success then
			break
		end

		warn(string.format(
			"[PlayerDataService] GetAsync gagal untuk %s (attempt %d/%d): %s",
			player.Name, attempt, LOAD_MAX_ATTEMPTS, tostring(savedData)
			))

		if attempt < LOAD_MAX_ATTEMPTS then
			task.wait(LOAD_RETRY_WAIT)
		end
	end

	if not success then
		-- Gagal total setelah semua attempt. JANGAN diam-diam fallback ke
		-- DEFAULT_DATA seolah ini pemain baru -- itu sumber bug reset-nya.
		-- Isi RAM dengan default cuma biar gak ada nil-error di sistem lain,
		-- tapi caller (Init.server.lua) HARUS kick pemain ini.
		PlayerStateRepository.set(player, "totalWins", 0)
		PlayerStateRepository.set(player, "winStreak", 0)
		PlayerStateRepository.set(player, "bestWinStreak", 0)
		PlayerStateRepository.set(player, "totalPlayTime", 0)

		warn("[PlayerDataService] GAGAL TOTAL memuat data " .. player.Name .. " setelah " .. LOAD_MAX_ATTEMPTS .. "x percobaan.")
		return false
	end

	-- success == true di sini. savedData bisa nil (memang pemain baru) atau
	-- table (data lama) -- dua-duanya kasus normal, bukan kegagalan.
	savedData = savedData or DEFAULT_DATA

	if savedData == DEFAULT_DATA then
		print("[PlayerDataService] Memuat data baru untuk " .. player.Name)
	else
		print("[PlayerDataService] Berhasil memuat data lama untuk " .. player.Name)
	end

	PlayerStateRepository.set(player, "totalWins", savedData.totalWins or 0)
	PlayerStateRepository.set(player, "winStreak", savedData.winStreak or 0)
	PlayerStateRepository.set(player, "bestWinStreak", savedData.bestWinStreak or 0)
	PlayerStateRepository.set(player, "totalPlayTime", savedData.totalPlayTime or 0)

	StreakDisplayService.updateStreak(player, savedData.winStreak or 0)

	return true
end

-- ================================================================
-- SAVE DATA (Saat Player Leave / Server Shutting Down)
-- ================================================================
-- Delta-save pakai UpdateAsync: totalWins & totalPlayTime yang disimpan
-- BUKAN nilai absolut dari RAM, tapi "nilai TERAKHIR di DataStore + apa
-- yang didapat sesi ini" (sessionWins/sessionPlayTime). Jadi walau loadData
-- di awal sesi entah kenapa start dari 0, save di akhir tetap nambahin ke
-- angka lama yang bener -- gak pernah nimpa jadi 0.
-- winStreak tetap overwrite langsung (bukan akumulatif), bestWinStreak
-- pakai math.max biar gak pernah turun.
function PlayerDataService.saveData(player)
	local state = PlayerStateRepository.get(player)
	if not state then return end

	local deltaWins       = state.sessionWins or 0
	local deltaPlayTime   = state.sessionPlayTime or 0
	local currentWinStreak = state.winStreak or 0
	local currentBestStreak = state.bestWinStreak or 0

	local dataKey = "Player_" .. tostring(player.UserId)

	local success, err = pcall(function()
		PlayerDataStore:UpdateAsync(dataKey, function(old)
			old = old or DEFAULT_DATA
			return {
				totalWins     = (old.totalWins or 0) + deltaWins,
				winStreak     = currentWinStreak,
				bestWinStreak = math.max(old.bestWinStreak or 0, currentBestStreak),
				totalPlayTime = (old.totalPlayTime or 0) + deltaPlayTime,
			}
		end)
	end)

	if success then
		print(string.format(
			"[PlayerDataService] Berhasil menyimpan data %s (+%d win, +%ds playtime sesi ini)",
			player.Name, deltaWins, deltaPlayTime
			))
	else
		warn("[PlayerDataService] GAGAL menyimpan data " .. player.Name .. ": " .. tostring(err))
	end
end

return PlayerDataService