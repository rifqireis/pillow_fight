-- @ScriptType: ModuleScript

--[[
	Nama File : EnergyConfig
	Layer     : Config
	Deskripsi : Konstanta konfigurasi sistem energi pemain
	Penulis   : Yusuf Ahayy
	Tanggal   : 25 Juni 2026
	Versi     : 1.0
	Dependensi: -
]]

local EnergyConfig = {}

--Batas Energi
EnergyConfig.MIN_ENERGY = 0
EnergyConfig.MAX_ENERGY = 100

-- Regen +10% tiap 0.1 detik, hanya aktif jika tidak ada input selama 2 detik
-- Nilai ini bisa diubah setelah konfirmasi dengan Zora
EnergyConfig.ENERGY_REGEN_RATE = 10

EnergyConfig.ENERGY_REGEN_DELAY = 1.4

--Energi perserangan konsumsinya disini
-- EnergyConfig.COST_LIGHT = 10  --Serangan ringan (E Click)
--EnergyConfig.COST_HEAVY = 18  --Serangan beratl (Spasi Click)
--EnergyConfig.COST_DODGE = 7  --Dodge (Q Key)

-- ================================================================
-- ATURAN KELIPATAN ENERGI -- BACA SEBELUM MENGUBAH ANGKA APA PUN
-- ================================================================
-- Stun kehabisan energi dipicu saat energi menyentuh TEPAT 0
-- (lihat EnergyService.consumeEnergy). Supaya angkanya bisa benar-benar
-- mendarat di nol, SEMUA nilai yang menambah/mengurangi energi wajib
-- kelipatan ENERGY_STEP, dan ENERGY_STEP wajib membagi habis MAX_ENERGY.
--
-- Energi mulai dari 100 (kelipatan 5). Selama tiap perubahan juga kelipatan
-- 5, nilainya selalu tinggal di kisi kelipatan 5 -- jadi dari 5, aksi
-- termurah membawanya persis ke 0 dan stun menyala.
--
-- Kalau ada SATU saja nilai yang keluar dari kisi ini (misal refund 12,
-- atau pemulihan FFYL yang menghasilkan 73), energi bakal melenceng dan
-- TIDAK PERNAH LAGI menyentuh nol -- stun-nya mati diam-diam, tanpa error
-- apa pun. Itu persis yang dulu terjadi waktu biaya light diubah 10 -> 7.
--
-- Yang wajib kelipatan ENERGY_STEP:
--   COST_LIGHT / COST_HEAVY / COST_DODGE   (di bawah)
--   PERFECT_DODGE_REFUND                    (di bawah)
--   ENERGY_REGEN_RATE                       (di atas)
--   pemulihan energi FFYL                   (BalanceService.recoverFFYL)
EnergyConfig.ENERGY_STEP = 5

-- Kenapa basisnya 5, bukan 10:
-- Dengan biaya 10/20, MUSTAHIL bikin light punya peran. Syaratnya bentrok --
--   light lebih hemat : dmg_light / 10  > dmg_heavy / 20  -> dmg_light > dmg_heavy/2
--   heavy lebih tinggi DPS: dmg_heavy / 0.9 > dmg_light / 0.42 -> dmg_heavy > 2.14*dmg_light
-- digabung jadi dmg_light > 1.07 * dmg_light, yang nggak mungkin dipenuhi
-- berapa pun damage-nya. Penyebabnya rasio biaya (1:2) terlalu rapat
-- dibanding rasio cooldown (1:2.14). Rasio 1:4 (5 vs 20) melonggarkan itu.
--
-- Hasilnya (damage di BalanceConfig, cooldown di GameplayConfig):
--   LIGHT  8 dmg / 5 energi / 0.42s -> DPS 19.0 | 1.60 dmg per energi | 20 pukulan per bar
--   HEAVY 22 dmg / 20 energi / 0.9s -> DPS 24.4 | 1.10 dmg per energi |  5 pukulan per bar
-- Heavy unggul 28% di DPS, light unggul 45% di efisiensi. Dua-duanya punya alasan dipakai.
EnergyConfig.COST_LIGHT = 5   --Serangan ringan (klik kiri)
EnergyConfig.COST_HEAVY = 20  --Serangan berat (klik kanan)
EnergyConfig.COST_DODGE = 5   --Dodge (Q Key)

-- Energi yang dikembalikan kalau pemain berhasil PERFECT DODGE. Sengaja
-- lebih besar dari COST_DODGE supaya baca serangan lawan dengan benar itu
-- untung bersih -- bukan cuma "nggak rugi". Ini yang bikin pemain berani
-- dodge reaktif (nunggu & baca) daripada dodge preventif (spam).
--
-- Dipakai CombatController.resolveHit lewat EnergyService.refund. WAJIB ADA:
-- kalau key ini hilang, refund() dipanggil dengan amount = nil.
--
-- 12 -> 10 supaya tetap kelipatan ENERGY_STEP (lihat aturan di atas). Kalau
-- dibiarkan 12, sekali perfect dodge saja energi melenceng dari kisi dan
-- stun kehabisan energi nggak akan pernah menyala lagi sampai ronde habis.
EnergyConfig.PERFECT_DODGE_REFUND = 10

--Stun Durasi
EnergyConfig.STUN_DURATION = 1 --DALAM HITUNGAN DETIK

return EnergyConfig