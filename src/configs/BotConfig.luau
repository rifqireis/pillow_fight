-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : BotConfig
    Layer      : Config
    Deskripsi  : Konstanta buat lawan AI Bot (dipakai BotService & BotAIService).
                 Server masih sepi, jadi bot ini yang ngisi slot ke-2 kalau
                 gak ada pemain lain -- baik otomatis (nunggu kelamaan
                 sendirian) maupun manual (minta lawan bot langsung).
    Tanggal    : 17 Agustus 2026
]]

local BotConfig = {}

-- ================================================================
-- TRIGGER OTOMATIS
-- ================================================================
-- Berapa detik seorang pemain boleh sendirian di antrean sebelum bot
-- otomatis ikut ngantre buat ngisi slot ke-2.
BotConfig.AUTO_MATCH_WAIT_SECONDS = 15

-- ================================================================
-- IDENTITAS BOT
-- ================================================================
-- UserId NEGATIF dipakai (sama seperti UserId test-client Studio) supaya
-- gampang dibedain dari akun asli di mana pun kode ngecek `player.UserId`,
-- dan otomatis ke-skip dari OrderedDataStore leaderboard (lihat
-- LeaderboardService.isRealPlayer). Tiap bot yang lagi aktif dapat UserId
-- unik (BotService yang generate, basis awal di bawah ini) supaya beberapa
-- bot bisa aktif bersamaan di arena berbeda tanpa tabrakan slot di
-- PlayerStateRepository (yang key-nya per UserId).
BotConfig.USERID_BASE = -100000

-- Daftar nama bot yang dipakai bergantian (dipilih acak tiap bot spawn).
BotConfig.NAMES = {
	"Itzyx BOT",
	"Pillow AI",
	"AI Ganteng",
	"AL Trainer",
}

-- ================================================================
-- KESULITAN / "KEPINTARAN" AI
-- ================================================================
-- Semua angka di bawah ini yang bikin bot kerasa "beneran main", bukan
-- cuma nabrak-nabrakin tombol asal:

-- Jeda antar keputusan AI (detik). Tiap tick, bot re-evaluasi mau
-- nyerang/nunggu berdasarkan energi & kondisi lawan.
BotConfig.DECISION_INTERVAL_MIN = 0.35
BotConfig.DECISION_INTERVAL_MAX = 0.75

-- Peluang bot pilih HEAVY dibanding LIGHT ketika memutuskan menyerang
-- (heavy: damage besar tapi cooldown & energi lebih mahal -- lihat
-- BalanceConfig/EnergyConfig).
BotConfig.HEAVY_CHANCE = 0.3

-- Ambang energi minimum (persentase dari MAX_ENERGY) sebelum bot berhenti
-- nyerang & milih nunggu regen dulu -- biar gak langsung stun sendiri.
BotConfig.MIN_ENERGY_RATIO_TO_ATTACK = 0.35

-- "Refleks" dodge: begitu CombatController.AttackStarted nembak (lawan
-- mulai nyerang bot), bot nunggu REACTION_DELAY detik dulu (simulasi waktu
-- reaksi) baru nge-dodge. Rentang ini SENGAJA gak instan (0 detik) --
-- kalau instan bot jadi gak bisa dikalahin sama sekali (unfair/gak seru).
BotConfig.REACTION_DELAY_MIN = 0.04
BotConfig.REACTION_DELAY_MAX = 0.10

-- Peluang bot BENERAN berhasil dodge setelah reaction delay di atas
-- (mensimulasikan "kadang telat baca gerakan lawan"). 1.0 = selalu coba,
-- 0.0 = gak pernah coba dodge sama sekali.
BotConfig.DODGE_SUCCESS_CHANCE = 0.55

-- Jangan coba dodge kalau bot BARU SAJA dodge (kena cooldown dodge yang
-- sama kayak pemain -- lihat GameplayConfig.COOLDOWNS.dodge) -- dicek
-- otomatis lewat CombatController.performAction, angka ini cuma buat AI
-- gak spam nyoba percuma waktu masih cooldown.

-- ================================================================
-- FFYL (Fight For Your Life)
-- ================================================================
-- Bot "mash" FFYL secara otomatis. Jeda sebelum bot berhasil menyelesaikan
-- minigame (simulasi waktu mash) -- diroll acak di antara MIN & MAX, TAPI
-- dibatasi supaya gak pernah melebihi BalanceConfig.FFYL_DURATION (kalau
-- itu lebih pendek dari MAX di bawah, dipotong otomatis oleh BotAIService).
BotConfig.FFYL_SUCCESS_DELAY_MIN = 0.8
BotConfig.FFYL_SUCCESS_DELAY_MAX = 2.2

-- Peluang bot BERHASIL survive FFYL (kalau gagal, dia sengaja gak mash
-- sampai waktu habis -> K.O.). Dibikin tinggi (bukan 100%) supaya match
-- vs bot tetap punya kemungkinan menang telak buat pemain, bukan selalu
-- best-of-3 penuh.
BotConfig.FFYL_SUCCESS_CHANCE = 0.75

return BotConfig