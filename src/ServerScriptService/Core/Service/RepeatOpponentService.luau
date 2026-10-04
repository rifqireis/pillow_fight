-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
	Nama File  : RepeatOpponentService.lua
	Layer      : Service
	Penulis    : Yusuf Ahayy
	Deskripsi  : Layer 3 -- Repeat-Opponent Farming Cooldown. Melacak match
	             beruntun antara SATU PASANGAN akun spesifik (bukan per akun
	             seperti Layer 1/2) dan memberi matchmaking cooldown pada
	             pasangan itu kalau salah satu pihak menang 10x beruntun tanpa
	             selingan lawan lain. Lihat design doc anti-afk-gb-design.md
	             (§6 Layer 3, §7 Data Model, §9 Keputusan Final) untuk spek penuh.

	Catatan implementasi vs desain awal:
	- Desain awal (§6) membayangkan MatchmakingService punya "pool" kandidat
	  dan bisa "coba kandidat lain" kalau pasangan lagi cooldown. Codebase
	  aktual (MatchmakingService.lua) tidak punya pool seperti itu -- pemain
	  manual pilih teleporter arena, dan slotnya cuma diisi siapa pun yang
	  join teleporter itu. Makanya pengecekan cooldown di sini dipanggil
	  MatchmakingService SAAT seorang pemain mau JOIN antrean suatu
	  teleporter, dibandingkan terhadap pemain yang SUDAH ada di antrean itu
	  -- kalau kena cooldown, join-nya ditolak (bukan "coba kandidat lain",
	  karena memang tidak ada pool), pemain yang sudah nunggu tidak terusik,
	  dan pemain yang ditolak tetap bebas antre di teleporter lain.
	- escalationLevel IKUT di-auto-reset ke tangga bawah bareng streakCount,
	  sesuai §9 (Keputusan Final) -- konsisten dengan PunishmentService.lua
	  (Layer 2) yang juga sudah disesuaikan mengikuti §9.
	Tanggal    : 15 Agustus 2026
	Versi      : 1.1
]]

local RepeatOpponentService = {}

local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")

local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)

local RepeatOpponentStore = DataStoreService:GetDataStore("RepeatOpponent_v1")

-- Cache in-memory per sesi server, keyed per PASANGAN akun (bukan per akun).
-- Dimuat on-demand (lazy) saat pertama kali pasangan itu benar-benar
-- dibutuhkan (dicek atau dicatat) -- beda dari PunishmentService yang wajib
-- di-load saat PlayerAdded, karena di sini tidak ada hook join/leave yang
-- pas (datanya bukan milik satu akun). Jumlah pasangan yang benar-benar
-- pernah main bareng biasanya jauh lebih kecil dari populasi pemain, jadi
-- tetap nangkring di cache selama server hidup itu aman.
local _cache = {}

local SECONDS_PER_DAY = 24 * 60 * 60
local SECONDS_PER_MINUTE = 60
local SECONDS_PER_HOUR = 60 * 60

-- §9: disamakan dengan Layer 2 -- 7 hari bersih (tanpa memicu streak baru)
-- -> streakCount pasangan ini luntur ke 0.
local AUTO_RESET_CLEAN_SECONDS = 7 * SECONDS_PER_DAY

-- Match beruntun (satu arah) yang memicu cooldown. §6.
local STREAK_LIMIT = 10

-- Tangga cooldown §6. Dobel tiap kali terulang, mentok di tangga ke-5 (6 jam)
-- selama pasangan ini belum kena auto-reset (§9: tidak ada tindakan lanjutan
-- setelah mentok, tapi escalationLevel ikut luntur ke 0 begitu 7 hari bersih --
-- lihat applyAutoResetIfDue).
local COOLDOWN_LADDER = {
	[1] = 15 * SECONDS_PER_MINUTE,
	[2] = 30 * SECONDS_PER_MINUTE,
	[3] = 1 * SECONDS_PER_HOUR,
	[4] = 3 * SECONDS_PER_HOUR,
	[5] = 6 * SECONDS_PER_HOUR,
}
local MAX_ESCALATION_LEVEL = 5

-- Key DataStore & cache: gabungan dua UserId yang diurutkan, supaya key
-- selalu konsisten terlepas urutan siapa yang query duluan (§6 catatan
-- implementasi).
local function pairKey(userIdA, userIdB)
	local lo, hi = math.min(userIdA, userIdB), math.max(userIdA, userIdB)
	return "Pair_" .. tostring(lo) .. "_" .. tostring(hi)
end

local function defaultData()
	return {
		streakCount = 0,
		streakWinnerId = 0,
		escalationLevel = 0,
		cooldownExpiresAt = 0,
		lastCleanTimestamp = os.time(),
	}
end

-- Terapkan auto-reset §9 (Keputusan Final): kalau sudah 7 hari bersih sejak
-- lastCleanTimestamp, streakCount DAN escalationLevel pasangan ini sama-sama
-- balik ke 0. cooldownExpiresAt TIDAK ikut direset di sini -- cooldown yang
-- SEDANG aktif tetap jalan sampai habis waktunya sendiri; auto-reset cuma
-- mempengaruhi status "bersih" pasangan ini ke depannya, bukan membatalkan
-- cooldown yang sudah kadung dijatuhkan.
local function applyAutoResetIfDue(data)
	if (data.streakCount > 0 or data.escalationLevel > 0)
		and (os.time() - data.lastCleanTimestamp) >= AUTO_RESET_CLEAN_SECONDS then
		print("[RepeatOpponentService] Auto-reset streakCount & escalationLevel (7 hari bersih terlewati)")
		data.streakCount = 0
		data.streakWinnerId = 0
		data.escalationLevel = 0
	end
end

-- FIX (race lintas-server, sama seperti PunishmentService): SetAsync polos
-- bisa lost-update kalau pasangan pemain yang sama kebetulan main lagi di
-- SERVER LAIN dalam waktu berdekatan. UpdateAsync + merge lewat oldData:
--   - streakCount/streakWinnerId/lastCleanTimestamp: ambil dari record yang
--     lebih baru (berdasarkan lastCleanTimestamp) -- streak cuma valid
--     dibaca utuh dari SATU sumber, tidak bisa di-max-kan per field karena
--     "siapa lagi unggul" bisa beda arah antara dua record.
--   - escalationLevel/cooldownExpiresAt: SELALU ambil yang lebih besar,
--     supaya cooldown farming yang sudah dijatuhkan di server manapun tidak
--     sengaja "terhapus" oleh tulisan dari server lain yang belum tahu.
local function persist(key)
	local data = _cache[key]
	if not data then return end

	local success, err = pcall(function()
		RepeatOpponentStore:UpdateAsync(key, function(oldData)
			if not oldData then return data end

			local newer = (data.lastCleanTimestamp or 0) >= (oldData.lastCleanTimestamp or 0)
				and data or oldData

			local merged = {
				streakCount = newer.streakCount or 0,
				streakWinnerId = newer.streakWinnerId or 0,
				escalationLevel = math.max(data.escalationLevel or 0, oldData.escalationLevel or 0),
				cooldownExpiresAt = math.max(data.cooldownExpiresAt or 0, oldData.cooldownExpiresAt or 0),
				lastCleanTimestamp = math.max(data.lastCleanTimestamp or 0, oldData.lastCleanTimestamp or 0),
			}

			_cache[key] = merged
			return merged
		end)
	end)

	if not success then
		warn("[RepeatOpponentService] GAGAL menyimpan data untuk " .. key .. ": " .. tostring(err))
	end
end

-- Ambil data pasangan dari cache kalau sudah ada, atau muat dari DataStore
-- (lazy load, lihat catatan cache di atas).
local function loadPair(key)
	if _cache[key] then return _cache[key] end

	local success, result = pcall(function()
		return RepeatOpponentStore:GetAsync(key)
	end)

	if success and result then
		_cache[key] = result
	else
		if not success then
			warn("[RepeatOpponentService] GAGAL memuat data " .. key .. ": " .. tostring(result))
		end
		_cache[key] = defaultData()
	end

	return _cache[key]
end

-- Dipanggil MatchmakingService SEBELUM memasukkan seorang pemain ke antrean
-- teleporter yang sudah berisi pemain lain (lihat catatan implementasi di
-- atas berkas ini). True kalau pasangan (playerA, playerB) sedang cooldown --
-- juga mengembalikan sisa detik cooldown untuk keperluan pesan ke pemain.
function RepeatOpponentService.isPairOnCooldown(playerA, playerB)
	if not playerA or not playerB then return false, 0 end

	local key = pairKey(playerA.UserId, playerB.UserId)
	local data = loadPair(key)
	applyAutoResetIfDue(data)

	local now = os.time()
	if data.cooldownExpiresAt and data.cooldownExpiresAt > now then
		return true, data.cooldownExpiresAt - now
	end

	return false, 0
end

-- Dipanggil ArenaService.endMatch saat sebuah match BENERAN selesai dengan
-- win/loss (bukan match yang di-invalidate lewat Layer 1/2 -- match invalid
-- tidak mencerminkan siapa "menang" secara wajar, jadi sengaja tidak ikut
-- dihitung ke streak farming). Update streak per-arah §6, dan terapkan
-- cooldown kalau menyentuh STREAK_LIMIT.
function RepeatOpponentService.recordMatchResult(winner, loser)
	if not winner or not loser then return end

	local key = pairKey(winner.UserId, loser.UserId)
	local data = loadPair(key)
	applyAutoResetIfDue(data)

	-- Kontinuitas "beruntun tanpa selingan" (§6): match ini dianggap
	-- sambungan langsung dari kemenangan winner sebelumnya HANYA kalau match
	-- TERAKHIR yang dimainkan winner dan loser (masing-masing, sebelum match
	-- ini) sama-sama lawan satu sama lain. Kalau salah satu baru saja main
	-- lawan akun ketiga di antaranya, ini bukan match "beruntun" lagi.
	local winnerState = PlayerStateRepository.get(winner)
	local loserState = PlayerStateRepository.get(loser)
	local winnerPrevOpponent = (winnerState and winnerState.lastMatchOpponentUserId) or 0
	local loserPrevOpponent = (loserState and loserState.lastMatchOpponentUserId) or 0
	local isContiguous = (winnerPrevOpponent == loser.UserId) and (loserPrevOpponent == winner.UserId)

	if isContiguous and data.streakWinnerId == winner.UserId then
		data.streakCount = data.streakCount + 1
	else
		-- Baik streak berpindah arah (yang tadinya kalah sekarang menang)
		-- maupun ada selingan pihak ketiga -- dua-duanya bikin streak untuk
		-- arah "winner mengalahkan loser" ini mulai lagi dari 1 (§6: streak
		-- dihitung terpisah per arah).
		data.streakWinnerId = winner.UserId
		data.streakCount = 1
	end
	data.lastCleanTimestamp = os.time()

	-- Update jejak lawan terakhir SETELAH dipakai untuk cek kontinuitas di atas.
	if winnerState then PlayerStateRepository.set(winner, "lastMatchOpponentUserId", loser.UserId) end
	if loserState then PlayerStateRepository.set(loser, "lastMatchOpponentUserId", winner.UserId) end

	print("[RepeatOpponentService] " .. winner.Name .. " mengalahkan " .. loser.Name .. " -- streakCount pasangan ini sekarang " .. data.streakCount)

	if data.streakCount >= STREAK_LIMIT then
		data.escalationLevel = math.min(data.escalationLevel + 1, MAX_ESCALATION_LEVEL)
		local cooldownSeconds = COOLDOWN_LADDER[data.escalationLevel]
		data.cooldownExpiresAt = os.time() + cooldownSeconds
		-- Streak counter pasangan ini reset ke 0 setelah cooldown terpicu (§6).
		data.streakCount = 0
		data.streakWinnerId = 0

		print("[RepeatOpponentService] Cooldown farming dipicu untuk pasangan " .. key .. " (" .. cooldownSeconds .. "s, escalationLevel " .. data.escalationLevel .. ")")
	end

	persist(key)
end

return RepeatOpponentService