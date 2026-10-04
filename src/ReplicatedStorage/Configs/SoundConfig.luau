--[[
    Nama File  : SoundConfig.lua
    Layer      : Config
    Deskripsi  : Konfigurasi ID Suara untuk combat dan efek lainnya.
    Penulis    : System
    Tanggal    : 24 Juli 2026
    Versi      : 1.0
]]

local SoundConfig = {
	-- Konfigurasi Suara Combat
	--
	-- Slot yang masih "" belum punya asset -- sistemnya SUDAH terpasang dan
	-- pemicunya sudah jalan, jadi begitu ID-nya ditempel di sini suaranya
	-- langsung bunyi tanpa perlu ubah kode lagi. Slot kosong aman: dilewati
	-- diam-diam waktu load (lihat SoundController.resolveSoundId).
	COMBAT_SOUNDS = {
		light_swing = {
			"78097212089164", -- Ganti dengan ID Sound Swoosh (Light Attack) varian 1
			"139295619606403", -- Ganti dengan ID Sound Swoosh (Light Attack) varian 2
		},
		heavy_swing = {
			"126396501993494", -- Ganti dengan ID Sound Swoosh (Heavy Attack) varian 1
			-- TODO: tambah 1-2 varian lagi. Heavy itu serangan signature tapi
			-- bunyinya identik tiap kali -- paling cepat kerasa diulang-ulang.
		},

		dodge = "",       -- Ganti dengan ID Sound untuk Dodge

		light_impact = {
			"96011860549113", -- Ganti dengan ID Sound Impact (Light) varian 1
			"107072807842302", -- Ganti dengan ID Sound Impact (Light) varian 2
		},
		heavy_impact = {
			"140068327013806", -- Ganti dengan ID Sound Impact (Heavy) varian 1
			-- TODO: idem, minimal 2 varian.
		},

		-- ── Slot baru: momen yang selama ini benar-benar hening ──
		perfect_dodge = "", -- Sentakan/"ting" pas berhasil baca serangan lawan
		combo_milestone = "", -- Dipicu tiap kelipatan COMBO_MILESTONE_STEP
		stun = "",          -- Pas energi habis & pemain kena stun
		ko = "",            -- Pas ronde berakhir (KOEvent)
	},

	-- ================================================================
	-- VARIASI PLAYBACK
	-- ================================================================
	-- Tiap suara diberi jitter pitch & volume kecil tiap kali dibunyikan.
	-- Ini perbaikan paling murah untuk rasa "sample yang sama diulang":
	-- dulu playSound me-reset PlaybackSpeed ke 1 persis setiap kali, jadi
	-- dua pukulan beruntun bunyinya identik sampai ke sample-nya. Telinga
	-- sangat peka ke pengulangan sempurna -- deviasi 4% saja sudah cukup
	-- untuk membuatnya terdengar seperti dua pukulan berbeda.
	-- Nilai = deviasi maksimum ke atas/bawah (0.04 = ±4%).
	PITCH_JITTER  = 0.04,
	VOLUME_JITTER = 0.06,

	-- Suara yang berasal dari LAWAN dibedakan sedikit: lebih pelan & sedikit
	-- lebih rendah. Bukan sekadar hiasan -- ini yang bikin pemain bisa
	-- membedakan "ayunan gue" vs "ayunan lawan" tanpa harus lihat layar,
	-- padahal dua-duanya pakai asset yang sama persis.
	OPPONENT_VOLUME_SCALE = 0.75,
	OPPONENT_PITCH_SCALE  = 0.92,

	-- Tiap berapa combo suara milestone dibunyikan. Disamakan dengan
	-- CameraConfig.SHAKE.COMBO.MILESTONE_STEP supaya sentakan kamera dan
	-- suaranya jatuh di hitungan yang sama -- kalau beda, dua feedback ini
	-- malah saling melemahkan.
	COMBO_MILESTONE_STEP = 5,

	MUSIC = {
		-- Durasi crossfade (detik) saat berpindah antara lobby dan arena
		FADE_TIME = 1.5,

		TRACKS = {
			lobby = {
				id = "93126825009394",     -- Ganti dengan ID Sound BGM Lobby
				volume = 2,
			},
			arena = {
				id = "90752268837524",     -- Ganti dengan ID Sound BGM Arena
				volume = 2,
			},
		},
	},
}

return SoundConfig
