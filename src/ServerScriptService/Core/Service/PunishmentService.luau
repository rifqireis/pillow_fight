-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
	Nama File  : PunishmentService.lua
	Layer      : Service
	Deskripsi  : Menyimpan & menerapkan hukuman Layer 2 (anti-GB) secara
	             persisten lintas sesi lewat DataStoreService -- suspicionCount,
	             tangga eskalasi (Warn+Kick -> 1/3/7/30 hari), dan auto-reset
	             7 hari bersih. Lihat design doc anti-afk-gb-design.md
	             (§5 Eskalasi, §7 Data Model, §9 Keputusan Final) untuk spek penuh.
	Tanggal    : 15 Agustus 2026
	Versi      : 1.0
]]

local PunishmentService = {}

local DataStoreService = game:GetService("DataStoreService")

local AntiGbStore = DataStoreService:GetDataStore("AntiGB_v1")

-- Cache in-memory per sesi server -- dibaca sekali saat join (PunishmentService.load),
-- ditulis ke DataStore tiap kali berubah (bukan tiap frame), jadi jauh di
-- bawah rate-limit DataStore.
local _cache = {}

local SECONDS_PER_DAY = 24 * 60 * 60
-- §9: 7 hari bersih (tanpa kena Layer 2) -> suspicionCount reset ke 0.
-- escalationLevel TIDAK ikut reset -- persisten selamanya.
local AUTO_RESET_CLEAN_SECONDS = 7 * SECONDS_PER_DAY

-- Tangga hukuman §5. escalationLevel di-cap di MAX_ESCALATION_LEVEL --
-- begitu mentok, pelanggaran berikutnya tetap kena hukuman level itu lagi
-- (30 hari) tapi levelnya sendiri tidak naik lagi selama masih dalam
-- rentang 7 hari bersih (§9: tetap 30 hari selamanya SELAMA belum kena
-- auto-reset; lihat applyAutoResetIfDue -- escalationLevel ikut luntur ke 0
-- begitu pemain 7 hari bersih, sesuai §9 Keputusan Final).
local PUNISHMENT_LADDER = {
	[1] = {
		kickOnly = true,
		kickMessage = "Peringatan: sistem mendeteksi pola aktivitas tidak wajar (GB) berulang kali di akunmu. Pelanggaran berikutnya akan berakibat ban sementara.",
	},
	[2] = {
		durationSeconds = 1 * SECONDS_PER_DAY,
		kickMessage = "Akunmu diban 1 hari karena pola aktivitas tidak wajar (GB) yang terus berulang.",
	},
	[3] = {
		durationSeconds = 3 * SECONDS_PER_DAY,
		kickMessage = "Akunmu diban 3 hari karena pola aktivitas tidak wajar (GB) yang terus berulang.",
	},
	[4] = {
		durationSeconds = 7 * SECONDS_PER_DAY,
		kickMessage = "Akunmu diban 7 hari karena pola aktivitas tidak wajar (GB) yang terus berulang.",
	},
	[5] = {
		durationSeconds = 30 * SECONDS_PER_DAY,
		kickMessage = "Akunmu diban 30 hari karena pola aktivitas tidak wajar (GB) yang terus berulang.",
	},
}
local MAX_ESCALATION_LEVEL = 5
-- Trigger eskalasi tiap kelipatan berapa suspicionCount (§5: tiap 5 match).
local SUSPICION_TRIGGER_INTERVAL = 5

local function defaultData()
	return {
		suspicionCount = 0,
		escalationLevel = 0,
		banExpiresAt = 0,
		lastCleanTimestamp = os.time(),
	}
end

-- Terapkan auto-reset §9 (Keputusan Final): kalau sudah 7 hari bersih sejak
-- lastCleanTimestamp, suspicionCount DAN escalationLevel sama-sama balik ke 0
-- -- pemain yang sudah lama bersih dapat "kartu bersih" penuh, kembali ke
-- Warn+Kick kalau kambuh lagi nanti (bukan lanjut dari tangga terakhirnya).
local function applyAutoResetIfDue(data)
	if (data.suspicionCount > 0 or data.escalationLevel > 0)
		and (os.time() - data.lastCleanTimestamp) >= AUTO_RESET_CLEAN_SECONDS then
		print("[PunishmentService] Auto-reset suspicionCount & escalationLevel (7 hari bersih terlewati)")
		data.suspicionCount = 0
		data.escalationLevel = 0
	end
end

-- Simpan data pemain dari cache ke DataStore.
--
-- FIX (race lintas-server): dulu pakai SetAsync polos -- kalau pemain yang
-- sama kena Layer 2 di SERVER LAIN dalam waktu berdekatan, server ini bisa
-- menimpa balik data terbaru itu dengan versi cache-nya sendiri yang lebih
-- lama (lost update), misal ban yang baru saja dijatuhkan server lain
-- "kehapus" begitu server ini nulis. UpdateAsync kasih kita oldData (nilai
-- TERBARU di DataStore tepat sebelum nulis) yang dipakai untuk digabung:
--   - suspicionCount/lastCleanTimestamp: ambil dari record yang lebih baru
--     (berdasarkan lastCleanTimestamp), karena dua-duanya representasi state
--     yang sama-sama nambah seiring waktu di satu arah.
--   - escalationLevel/banExpiresAt: SELALU ambil yang lebih besar dari kedua
--     sisi, supaya hukuman yang sudah dijatuhkan di server manapun tidak
--     pernah sengaja "terhapus" oleh tulisan dari server lain yang belum tahu.
local function persist(userId)
	local data = _cache[userId]
	if not data then return end

	local dataKey = "AntiGB_" .. tostring(userId)
	local success, err = pcall(function()
		AntiGbStore:UpdateAsync(dataKey, function(oldData)
			if not oldData then return data end

			local newer = (data.lastCleanTimestamp or 0) >= (oldData.lastCleanTimestamp or 0)
				and data or oldData

			local merged = {
				suspicionCount = newer.suspicionCount or 0,
				escalationLevel = math.max(data.escalationLevel or 0, oldData.escalationLevel or 0),
				banExpiresAt = math.max(data.banExpiresAt or 0, oldData.banExpiresAt or 0),
				lastCleanTimestamp = math.max(data.lastCleanTimestamp or 0, oldData.lastCleanTimestamp or 0),
			}

			_cache[userId] = merged
			return merged
		end)
	end)

	if not success then
		warn("[PunishmentService] GAGAL menyimpan data untuk UserId " .. userId .. ": " .. tostring(err))
	end
end

-- Muat data pemain dari DataStore ke cache. WAJIB dipanggil sekali saat
-- join (lewat Init.server.lua) sebelum fungsi lain di modul ini dipakai.
function PunishmentService.load(player)
	local userId = player.UserId
	local dataKey = "AntiGB_" .. tostring(userId)

	local success, result = pcall(function()
		return AntiGbStore:GetAsync(dataKey)
	end)

	if success and result then
		_cache[userId] = result
		print("[PunishmentService] Berhasil memuat data AntiGB lama untuk " .. player.Name)
	else
		if not success then
			warn("[PunishmentService] GAGAL memuat data " .. player.Name .. ": " .. tostring(result))
		end
		_cache[userId] = defaultData()
	end

	return _cache[userId]
end

-- Dipanggil dari PlayerAdded (lewat Init.server.lua), SETELAH PunishmentService.load.
-- Cek apakah pemain ini sedang dalam masa ban aktif -- kalau iya, kick dengan
-- sisa waktu ban dan kembalikan true supaya Init.server.lua tahu untuk skip
-- proses join selanjutnya.
function PunishmentService.checkBanOnJoin(player)
	local data = _cache[player.UserId]
	if not data then return false end

	applyAutoResetIfDue(data)

	local now = os.time()
	if data.banExpiresAt and data.banExpiresAt > now then
		local remainingDays = math.ceil((data.banExpiresAt - now) / SECONDS_PER_DAY)
		player:Kick(("Akunmu sedang diban karena pola aktivitas tidak wajar (GB). Sisa waktu ban: %d hari."):format(remainingDays))
		return true
	end

	return false
end

-- Dipanggil ArenaService.handleSuspiciousPattern saat match di-invalidate
-- karena Layer 2. Nambah suspicionCount, cek trigger eskalasi tiap kelipatan
-- SUSPICION_TRIGGER_INTERVAL, terapkan hukuman sesuai tangga §5 kalau kena.
function PunishmentService.recordSuspiciousMatch(player)
	local data = _cache[player.UserId]
	if not data then
		data = PunishmentService.load(player)
	end

	applyAutoResetIfDue(data)

	data.suspicionCount = data.suspicionCount + 1
	data.lastCleanTimestamp = os.time()

	print("[PunishmentService] " .. player.Name .. " suspicionCount sekarang " .. data.suspicionCount)

	if data.suspicionCount % SUSPICION_TRIGGER_INTERVAL == 0 then
		data.escalationLevel = math.min(data.escalationLevel + 1, MAX_ESCALATION_LEVEL)
		local punishment = PUNISHMENT_LADDER[data.escalationLevel]

		if punishment then
			if punishment.kickOnly then
				print("[PunishmentService] " .. player.Name .. " kena Warn+Kick (escalationLevel " .. data.escalationLevel .. ")")
			else
				data.banExpiresAt = os.time() + punishment.durationSeconds
				print("[PunishmentService] " .. player.Name .. " kena ban (escalationLevel " .. data.escalationLevel .. "), sampai " .. os.date("%c", data.banExpiresAt))
			end

			persist(player.UserId)
			player:Kick(punishment.kickMessage)
			return
		end
	end

	persist(player.UserId)
end

-- Dipanggil dari PlayerRemoving (lewat Init.server.lua). Pastikan perubahan
-- terakhir ke-persist, lalu bersihkan cache supaya tidak numpuk di memori.
function PunishmentService.cleanup(player)
	local userId = player.UserId
	if _cache[userId] then
		persist(userId)
		_cache[userId] = nil
	end
end

return PunishmentService