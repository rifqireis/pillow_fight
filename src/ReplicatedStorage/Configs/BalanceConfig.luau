-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
Nama File   : BalanceConfig.lua
Layer       : Config
Deskripsi   : Konfigurasi nilai keseimbangan (balance), durasi dan mekanik
              penyelamatan FFYL (Fight For Your Life), serta besaran damage
              pukulan terhadap keseimbangan pemain.
Penulis     : GREEN PENDAP / Yusuf Ahayy
Tanggal     : 14 Agustus 2026
Versi       : 1.0
]]

local BalanceConfig = {}

BalanceConfig.MIN_BALANCE = 0
BalanceConfig.MAX_BALANCE = 100
BalanceConfig.DECAY_RATE = 2

BalanceConfig.IDLE_DELAY = 5
BalanceConfig.FFYL_DURATION = 5

BalanceConfig.FFYL_MASH_COUNT = 10

BalanceConfig.FFYL_RECOVERY_BASE    = 40
BalanceConfig.FFYL_RECOVERY_PENALTY = 10
BalanceConfig.FFYL_RECOVERY_MIN     = 10

-- Durasi immune (detik) setelah pemain BERHASIL menang minigame FFYL.
-- Selama durasi ini, applyDamage() di-skip total supaya pemain nggak
-- langsung kena combo/pukulan susulan pas baru aja bangun dari FFYL.
BalanceConfig.FFYL_WIN_IMMUNE_DURATION = 1

--BalanceConfig.LIGHT_HIT = 10
--BalanceConfig.HEAVY_HIT = 20


-- Damage per pukulan. Lihat komentar panjang di GameplayConfig.COOLDOWNS
-- soal kenapa angkanya diubah -- singkatnya: dulu heavy unggul di DPS DAN
-- di efisiensi energi sekaligus, jadi light nggak punya alasan dipakai.
-- Sekarang heavy menang DPS tapi kalah efisiensi, light sebaliknya.
BalanceConfig.LIGHT_HIT = 8
BalanceConfig.HEAVY_HIT = 22



-- Durasi TETAP (detik) buat BalanceBase (merah) nyusul turun ke posisi
-- BalanceFill setelah combo window abis. Dipakai lewat BarFill:tweenTo(),
-- jadi berapa pun besar drop-nya, animasi turunnya selalu kelar persis
-- dalam durasi ini (dengan easing, bukan garis lurus).
BalanceConfig.BASE_SHRINK_DURATION = 0.6

BalanceConfig.BASE_MAX_HOLD_DURATION = 4

return BalanceConfig