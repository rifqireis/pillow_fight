-- @ScriptType: ModuleScript
--[[
	Nama File : GameplayConfig
	Layer     : Config
	Deskripsi : Konstanta konfigurasi gameplay
	Penulis   : Abdul VVI
	Tanggal   : 25 Juni 2026
	Versi     : 1.3
	Dependensi: -
]]

-- QUestion is this needed???
local Workspace = game:GetService("Workspace")

local GameplayConfig = {
	-- Konfigurasi matchmaking [Epik], Ubah MAX_TELEPORTER_PLAYERS to 1 untuk debugging.
	MATCHMAKING_COUNTDOWN = 3, -- Durasi hitung mundur dalam detik
	MAX_TELEPORTER_PLAYERS = 2, -- Jumlah pemain untuk memulai match

	getArenaTeleporterFolder = function(arenaTeleporterName)
		local pillowArena = Workspace:WaitForChild("World")
			:WaitForChild("Environment")
			:WaitForChild("PillowArena")

		return pillowArena:WaitForChild(arenaTeleporterName)
	end,

	-- ============================================================
	-- TUNING COMBAT (light vs heavy)
	-- ============================================================
	-- Peran tiap serangan sengaja dibedakan supaya dua-duanya punya alasan
	-- dipakai. Angka lama (light 10 dmg/0.5s/10 energi, heavy 20/0.75s/18)
	-- bikin heavy MENANG DI SEMUA METRIK -- DPS-nya lebih tinggi (26.7 vs 20)
	-- DAN damage-per-energi-nya lebih hemat (1.11 vs 1.00) -- jadi light
	-- praktis nggak punya peran sama sekali.
	--
	-- Sekarang trade-off-nya dibalik jadi eksplisit:
	--   LIGHT = alat sustain. DPS lebih rendah, tapi paling hemat energi
	--           (1.14 dmg/energi) & startup cepat, jadi susah dihukum.
	--           Satu bar energi penuh = ~14 pukulan / ~112 damage.
	--   HEAVY = alat burst/punish. DPS tertinggi tapi PALING BOROS
	--           (1.00 dmg/energi) & startup lambat (gampang dibaca lawan,
	--           lihat HitboxConfig.ACTIVE_WINDOW). Satu bar energi penuh =
	--           ~4 pukulan / ~88 damage.
	-- Angka damage-nya sendiri ada di BalanceConfig.LIGHT_HIT/HEAVY_HIT,
	-- biaya energinya di EnergyConfig.COST_*. Ketiganya saling terkait --
	-- kalau salah satu diubah, hitung ulang dua-duanya.
	COOLDOWNS = {
		light = 0.42,
		heavy = 0.9,
		dodge = 1
	},

	-- Durasi kebal (i-frame) setelah melakukan dodge. Serangan lawan meleset
	-- jika korban baru saja dodge dalam rentang waktu ini.
	--
	-- Angka ini WAJIB dibaca berpasangan dengan COOLDOWNS.dodge (1.0).
	-- Selisih keduanya = durasi pemain sudah "membayar" dodge (energi
	-- kepotong, tombolnya terkunci, animasinya jalan) TAPI sama sekali
	-- nggak kebal. Selisih yang kegedean langsung kerasa nggak adil:
	-- pemain lihat karakternya jelas-jelas lagi menghindar tapi tetap kena.
	--
	-- Riwayat:
	--   1.0  -> i-frame == cooldown, kebal ~100% sepanjang waktu. Dodge
	--           bukan bacaan, tapi tombol yang ditahan terus. Rusak.
	--   0.45 -> kebablasan ke arah sebaliknya: selisih 0.55 detik, jadi 55%
	--           siklus dodge itu "kelihatan menghindar tapi bisa kena".
	--   0.65 -> sekarang. Selisih turun ke 0.35 detik.
	--
	-- 0.65 juga dipilih supaya LEBIH LEBAR dari jendela kontak efektif
	-- serangan. Jendela di HitboxConfig.ACTIVE_WINDOW itu BUKAN angka
	-- sebenarnya -- HitboxService masih nambahin ping + LATENCY_GRACE ke
	-- batas akhirnya, jadi light yang tertulis 0.12-0.38 (0.26s) aslinya
	-- selebar ~0.41s di ping rendah. Kalau i-frame lebih sempit dari itu,
	-- dodge dengan timing bagus pun masih bisa kelewatan di ujung jendela.
	DODGE_IFRAME = 0.65,

	-- ============================================================
	-- PERFECT DODGE (just-dodge)
	-- ============================================================
	-- Dodge dipecah jadi dua kualitas, bukan satu hasil biner:
	--   NORMAL  = pukulan lewat karena kebetulan masih ada i-frame sisa
	--             (dodge-nya kepagian/asal). Hadiahnya cuma: nggak kena.
	--   PERFECT = dodge dilakukan TEPAT sebelum bantal mendarat, artinya
	--             pemain beneran baca serangan lawan. Ini yang dikasih
	--             flourish kamera + hadiah mekanis.
	--
	-- Diukur dari jarak waktu antara input dodge dan saat kontak terjadi:
	-- makin KECIL jedanya, makin reaktif dodge-nya. Jeda besar (mendekati
	-- DODGE_IFRAME) berarti dodge-nya kepagian.
	--
	-- Dipakai CombatController.resolveHit. WAJIB ADA -- kalau key ini hilang
	-- (mis. kena revert waktu merge), resolveHit langsung error di tiap
	-- pukulan yang kena dodge: "attempt to compare number <= nil".
	-- Ikut naik waktu DODGE_IFRAME dinaikin 0.45 -> 0.65. Kalau dibiarkan di
	-- 0.18, perfect dodge malah jadi lebih susah secara relatif: porsinya
	-- terhadap total i-frame menyusut dari 40% jadi 28%. 0.22 menjaga
	-- perfect tetap terasa sebagai bacaan yang tajam (34% dari i-frame),
	-- bukan tebakan yang mustahil.
	PERFECT_DODGE_WINDOW = 0.22,

	-- Hukuman buat penyerang yang kena perfect dodge: dia nggak bisa
	-- menyerang selama ini (dihitung dari saat kontak). Ini yang bikin
	-- perfect dodge menghasilkan GILIRAN, bukan cuma "nggak kena" --
	-- pemain yang baca dengan benar dapat jendela balas yang dijamin.
	PERFECT_DODGE_PUNISH = 0.45,

	-- ============================================================
	-- FLINCH (jeda aksi setelah kena pukul)
	-- ============================================================
	-- DULU: satu angka mati 0.5 detik buat semua jenis pukulan, di-hardcode
	-- di CombatController. Masalahnya 0.5 itu >= cooldown light, jadi
	-- penyerang yang mendarat duluan bisa nge-loop light SELAMANYA dan
	-- korban nggak akan pernah punya celah buat balas -- cuma bisa dodge.
	-- Efeknya match nggak punya struktur "giliran gue / giliran lu".
	--
	-- Sekarang flinch selalu LEBIH PENDEK dari cooldown penyerangnya,
	-- jadi korban selalu dapat celah nyata:
	--   light: flinch 0.22 vs cooldown 0.42 -> celah ~0.20 detik (ketat)
	--   heavy: flinch 0.38 vs cooldown 0.90 -> celah ~0.52 detik (lega)
	-- Ini yang bikin heavy jadi "high reward, tapi nyerahin tempo".
	--
	-- Dipakai CombatController.applyHit. WAJIB ADA -- kalau key ini hilang,
	-- applyHit error di tiap pukulan yang mendarat: "attempt to index nil
	-- with 'light'".
	FLINCH = {
		light = 0.22,
		heavy = 0.38,
	},

	-- Nama Tool bantal di StarterPack. Otomatis di-equip saat ronde dimulai
	-- dan hotbar disembunyikan supaya tidak bisa dilepas di tengah match.
	PILLOW_TOOL_NAME = "Pillow",

	-- Jendela waktu (detik) buat combo attack. Kalau attacker berhasil
	-- landing pukulan berikutnya dalam rentang ini, combo naik. Kalau
	-- kelewat waktu ini (atau serangannya di-dodge), combo direset.
	COMBO_WINDOW = 2.5,

	-- Deteksi AFK (Layer 1): berapa detik seorang pemain boleh sama sekali
	-- tidak menyerang/dodge sebelum dianggap AFK oleh ArenaService. Karakter
	-- duduk terus sepanjang match (analog nonaktif), jadi "aktivitas" di sini
	-- murni action combat (light/heavy/dodge), bukan movement.
	AFK_TIMEOUT = 20,
	-- Seberapa sering ArenaService mengecek status AFK selama ronde berjalan.
	AFK_CHECK_INTERVAL = 2,

	-- Deteksi pola GB/suspicious (Layer 2): pemain "aktif" secara teknis
	-- (lolos Layer 1) tapi rate action-nya jauh di bawah standar kompetitif.
	-- Lihat design doc anti-afk-gb-design.md untuk rincian.
	GB_WINDOW_DURATION = 15, -- Durasi tiap rolling window, dalam detik.
	GB_MIN_ACTIONS = 3, -- Minimal action (light/heavy/dodge) per window.
	GB_BAD_WINDOWS_LIMIT = 3, -- Window buruk berturut-turut sebelum match di-invalidate.

	-- Ready-handshake sebelum countdown ronde dimulai: server nembak
	-- RoundReadyEvent ke kedua pemain begitu selesai teleport, client
	-- langsung fire balik sebagai ack. Ini nutup celah kalau salah satu
	-- pemain lagi lag/ms tinggi -- countdown gak akan mulai sebelum
	-- KEDUA client konfirmasi siap (bukan asumsi "pasti udah sampai").
	-- ROUND_READY_TIMEOUT = batas atas nunggu ack sebelum match dipaksa
	-- lanjut anyway (biar 1 pemain dengan koneksi jelek/mati gak bikin
	-- match nyangkut selamanya).
	ROUND_READY_TIMEOUT = 5,

	-- Koreksi halus (studs) buat posisi berdiri karakter di titik spawn
	-- arena/lobby. ArenaService ngitung base offset otomatis dari HipHeight
	-- rig + setengah tinggi HumanoidRootPart (rumus standar R6), tapi angka
	-- itu gak selalu 100% pas ke geometri bambu/spawn point yang sebenarnya
	-- di scene ini -- proporsi rig custom bisa beda dikit dari asumsi.
	--
	-- CARA TUNING: masuk Play/Studio, kalau karakter masih kelihatan
	-- ngambang dikit di atas bambu -> turunin angka ini (bikin lebih
	-- negatif, mis. -0.3). Kalau kakinya nembus/nenggelam ke bambu ->
	-- naikin (mis. +0.3). Ubah 0.1-0.3 per percobaan, gak usah drastis.
	STANDING_HEIGHT_ADJUST = -0.9,
}
GameplayConfig.LIGHTATTACK_KEY =  Enum.KeyCode.E
GameplayConfig.HEAVYATTACK_KEY = Enum.UserInputType.MouseButton2
GameplayConfig.DODGE_KEY = Enum.KeyCode.Q

return GameplayConfig