-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[ 
	Nama File : PlayerStateRepository
	Layer : Repository
	Deskripsi :  
	Penulis : Rifqi RR
			  Yusuf Ahayy (Energy Ahayy)
			  Abdul Vaiz (isPlaying)
	Tanggal : 23 Juni 2026
	Diubah : 2 Juli 2026
	Versi : 2.0
	Dependensi :	- BalanceConfig 
]]

local PlayerStateRepository = {}
local _state = {}

local BalanceConfig = require(
	game:GetService("ReplicatedStorage").Configs.BalanceConfig
)

-- EnergyConfig di-require secara lazy di dalam init() untuk menghindari
-- recursive require: EnergyService → PlayerStateRepository → EnergyConfig
-- sementara EnergyService sendiri juga membutuhkan EnergyConfig.
local EnergyConfig

-- player == game.Players.PlayerAdded dan seterusnya
function PlayerStateRepository.init(player)
	-- Lazy load EnergyConfig saat pertama kali dibutuhkan
	if not EnergyConfig then
		EnergyConfig = require(game:GetService("ReplicatedStorage").Configs.EnergyConfig)
	end

	local playerId = player.UserId

	_state[playerId] = {
		-- data player

		--Balance (Rifziq Reis)
		balance = BalanceConfig.MAX_BALANCE, 
		isAlive = true,
		isFFYL = false, -- Mode FFYL
		ffylSurvivalCount = 0, -- Berapa kali pemain berhasil menang FFYL (per ronde)

		-- Timestamp (os.clock) sampai kapan pemain immune dari damage
		-- setelah berhasil menang minigame FFYL. Diisi BalanceService.recoverFFYL,
		-- dicek di BalanceService.applyDamage. 0 = tidak sedang immune.
		ffylImmuneUntil = 0,

		-- Energy (Energy Ahayy Yusud Ahayy)
		energy = EnergyConfig.MAX_ENERGY,
		isStun = false, -- <---Ditaruh koma di akhir biar kalau ada yang ngebuat dia bawah gak ada error

		-- Matchmaking Teleporter (Epik)
		isInMatchmaking = false,
		isPlaying = false,
		cooldowns = {},

		-- Combo (dipakai ComboService)
		comboCount = 0,
		lastComboTime = 0,

		-- Timestamp (os.clock) sampai kapan pemain ini tidak boleh menyerang.
		-- Diisi CombatController dari dua sumber: flinch setelah kena pukul
		-- (durasinya per jenis pukulan, GameplayConfig.FLINCH) dan stagger
		-- setelah serangannya kena PERFECT DODGE lawan
		-- (GameplayConfig.PERFECT_DODGE_PUNISH). Dodge selalu dikecualikan,
		-- jadi ini tidak pernah mengunci pemain tanpa jalan keluar.
		-- Direset ArenaService.resetPlayerStats tiap ronde baru.
		flinchUntil = 0,

		-- Anti-AFK Layer 1 (dipakai ArenaService): waktu terakhir kali pemain
		-- melakukan action (light/heavy/dodge). Karakter duduk terus selama
		-- match, jadi ini TIDAK termasuk movement/lompat.
		lastActionTime = os.clock(),

		-- Anti-GB Layer 2 (dipakai ArenaService): jumlah action dalam
		-- rolling window saat ini. Diincrement CombatController tiap action
		-- sukses, direset ArenaService tiap window (GB_WINDOW_DURATION) habis.
		windowActionCount = 0,

		-- Anti-Farming Layer 3 (dipakai RepeatOpponentService): UserId lawan
		-- di match TERAKHIR yang beneran selesai (win/loss) untuk pemain ini.
		-- 0 = belum pernah main match yang selesai di sesi ini. Dipakai untuk
		-- mendeteksi selingan lawan lain di antara 2 match melawan pasangan
		-- yang sama (streak farming wajib beruntun tanpa selingan).
		lastMatchOpponentUserId = 0,
		sessionWins = 0,
		sessionPlayTime = 0,
	}

	print("[PlayerStateRepository] ID Player" ..player.Name .. " : " .. playerId)
end

-- function get -> mengembalikan nilai dari key yang diinput (atribut player)
function PlayerStateRepository.get(player)
	if not player then
		warn("[PlayerStateRepository] Fungsi get() dipanggil tapi parameter player nil!")
		return nil
	end

	local playerId = player.UserId

	return _state[player.UserId]
end

-- function set -> mengubah nilai dari key yang diinput (atribut player)
function PlayerStateRepository.set(player, key, value)
	if not player then
		warn("[PlayerStateRepository] Fungsi set() dipanggil tapi parameter player nil!")
		return
	end


	if not _state[player.UserId] then
		return
	end
	_state[player.UserId][key] = value
end

function PlayerStateRepository.remove(player)
	local playerId = player.UserId
	if _state[playerId] then
		_state[playerId] = nil
		print("[PlayerStateRepository] Data Player " .. player.Name .. " dihapus")
	end
end

return PlayerStateRepository