-- @ScriptType: ModuleScript
--[[
    Nama File : CameraConfig.lua
    Layer     : Config
    Deskripsi : Konfigurasi camera lock, shake, impact kick, hitstop,
                head follow, attack camera, dodge/FFYL/KO feedback,
                FALLEN_CAM, dan BLINK.
    Penulis   : System
    Tanggal   : 15 Agustus 2026
    Versi     : 1.2
]]

local CameraConfig = {}

-- ============================================================
-- CAMERA LOCK
-- ============================================================

CameraConfig.LOCK = {
	ENABLED = true,
	MODE = "Side", -- "OverShoulder" | "Side"
	FOV = 73,

	-- Over Shoulder
	DISTANCE = 6,
	HEIGHT = 3,
	SHOULDER_OFFSET = 3,

	-- Side
	SIDE_DISTANCE = 15,
	SIDE_HEIGHT = 4,

	-- Focus
	FOCUS_HEIGHT = 2,
	AIM_BIAS = 0.75, -- 0 = diri sendiri, 1 = lawan
	SMOOTHNESS = 0.2,
	FALLBACK_DISTANCE = 8,

	-- FFYL focus
	FFYL = {
		FOCUS_BIAS = 0.15,
		BLEND_SPEED = 3.5,
	},
}

-- ============================================================
-- CAMERA SHAKE
-- ============================================================

CameraConfig.SHAKE = {
	ENABLED = true,
	MAX_TRAUMA = 1,
	DECAY = 1.8,
	FREQUENCY = 18,
	ROTATION = Vector3.new(5, 5, 2.5),
	TRANSLATION = Vector3.new(0.5, 0.5, 0.25),

	PRESETS = {
		-- Attack swing (sebelum hit confirm)
		lightSwing = 0.16,
		heavySwing = 0.32,

		-- Hit confirm (serangan benar-benar kena) - dibuat lebih tipis
		-- dari shake korban (lightHurt/heavyHurt), sekadar feedback
		-- "kena" buat attacker, bukan sebesar shake yang dirasakan korban.
		lightConfirm = 0.35,
		heavyConfirm = 0.55,

		-- Victim / hurt
		lightHurt = 0.5,
		heavyHurt = 0.85,

		-- Other
		stun = 0.85,
		fall = 0.9,
		startFFYL = 1.0,
	},

	COMBO = {
		PER_HIT = 0.05,
		MAX_BONUS = 0.5,
		MILESTONE_STEP = 5,
		MILESTONE_BONUS = 0.35,
	},
}

-- ============================================================
-- IMPACT KICK
-- ============================================================

CameraConfig.KICK = {
	ENABLED = true,
	STIFFNESS = 170,
	DAMPING = 22,
	MAX_OFFSET = 3,
	MAX_ANGLE = 12,

	PRESETS = {
		-- Attack swing
		lightSwing = { PUSH = 0.10, LIFT = 0.02, DOLLY = -0.08, PITCH = 0.5, ROLL = -0.3 },
		heavySwing = { PUSH = 0.22, LIFT = 0.04, DOLLY = -0.15, PITCH = 1.0, ROLL = -0.6 },

		-- Hit confirm
		lightConfirm = { PUSH = 0.30, LIFT = 0.04, DOLLY = -0.20, PITCH = 1.2, ROLL = -0.8 },
		heavyConfirm = { PUSH = 0.55, LIFT = 0.08, DOLLY = -0.40, PITCH = 2.2, ROLL = -1.5 },

		-- Victim / hurt
		lightHurt = { PUSH = -0.45, LIFT = 0.10, DOLLY = 0.15, PITCH = -2.2, ROLL = 1.8 },
		heavyHurt = { PUSH = -0.90, LIFT = 0.22, DOLLY = 0.35, PITCH = -4.0, ROLL = 3.2 },
		stun = { PUSH = -0.60, LIFT = 0.15, DOLLY = 0.30, PITCH = -3.0, ROLL = 2.5 },
		fall = { PUSH = 0.00, LIFT = -0.55, DOLLY = 0.20, PITCH = -5.0, ROLL = 2.0 },
		startFFYL = { PUSH = -0.35, LIFT = -0.50, DOLLY = 0.50, PITCH = -3.5, ROLL = 3.0 },
	},
}

-- ============================================================
-- HITSTOP
-- ============================================================

CameraConfig.HITSTOP = {
	ENABLED = true,
	FREEZE_ANIMATION = true,
	FREEZE_OPPONENT = true,
	MAX_DURATION = 0.15,

	DURATION = {
		lightHurt = 0.055,
		heavyHurt = 0.090,
		lightConfirm = 0.045,
		heavyConfirm = 0.080,
		stun = 0.100,
		fall = 0.070,
		startFFYL = 0.120,
	},
}

-- ============================================================
-- HEAD FOLLOW
-- ============================================================

CameraConfig.HEAD_FOLLOW = {
	ENABLED = true,
	INTENSITY = 1.1,
	MAX_OFFSET = 2.2,
	MAX_TRAUMA = 1,
	DECAY = 1.8,
	DODGE_TRAUMA = 0.55,
}

-- ============================================================
-- ATTACK CAMERA
-- ============================================================

CameraConfig.ATTACK_CAM = {
	ENABLED = true,

	HEAVY = {
		ZOOM_DISTANCE = 2.2,
		OUT_SPEED = 9,
		RETURN_SPEED = 6,
		CANCEL_SPEED = 12,
		HOLD_TIME = 0.28,
		FOLLOW_INTENSITY = 0.4,
		FOLLOW_MAX_OFFSET = 1.4,
	},
}

-- ============================================================
-- DODGE FEEDBACK
-- ============================================================

CameraConfig.DODGE_FEEDBACK = {
	ENABLED = true,

	ZOOM_DISTANCE = 8.1,
	ZOOM_IN_SPEED = 20,
	ZOOM_RETURN_SPEED = 5,

	-- Dua tingkat, bukan satu efek yang sama buat semua dodge. Yang dibedakan
	-- KEDALAMAN dan DURASInya, jadi pemain langsung bisa merasakan bedanya
	-- tanpa harus baca teks: dodge biasa cuma "sentuhan" singkat, perfect
	-- dodge benar-benar menghentikan waktu.
	--
	-- ATURAN PENTING: SLOWMO_DURATION kedua tingkat WAJIB lebih kecil dari
	-- GameplayConfig.COOLDOWNS.dodge (1.0). Alasannya ada di cara kerja
	-- applySlowmoToCharacter: tiap slow-mo baru MEMBATALKAN timer "balik ke
	-- normal" milik sesi sebelumnya lalu menjadwalkan yang baru. Kalau
	-- durasinya lebih panjang dari jarak antar dodge, timer itu selalu keburu
	-- dibatalkan sebelum sempat jalan -- jadwal baliknya diundur terus dan
	-- karakter nggak pernah kembali ke kecepatan normal. (Itu yang terjadi
	-- dengan angka lama: durasi 1.8 detik vs cooldown dodge 1.0 detik.)
	NORMAL = {
		SLOWMO_SPEED    = 0.45, -- masih jelas melambat, tapi tetap bisa diikuti
		SLOWMO_DURATION = 0.28,
		ZOOM_SCALE      = 0.45, -- zoom ikut lebih tipis
	},

	PERFECT = {
		SLOWMO_SPEED    = 0.15,
		SLOWMO_DURATION = 0.9,
		ZOOM_SCALE      = 1,
	},
}

-- ============================================================
-- DODGE VIGNETTE (sinematik perfect dodge)
-- ============================================================
-- Vignette layar buat momen perfect dodge -- konsepnya sama kayak vignette
-- FFYL (ArenaUIController), tapi ini SEKALI TEMBAK, bukan detak terus-
-- menerus: masuk cepat pas dodge kebaca, nahan selama slow-mo jalan, terus
-- lepas begitu waktu balik normal.
--
-- Durasi nahan-nya sengaja NGIKUTIN DODGE_FEEDBACK.PERFECT.SLOWMO_DURATION
-- (dibaca langsung di PerfectDodgeVignetteClient, bukan diketik ulang di
-- sini) supaya vignette & slow-mo selalu selesai barengan. Kalau angka
-- slow-mo diubah, vignette-nya ikut otomatis -- gak ada dua angka yang
-- harus diinget buat disamain.
--
-- GUI-nya dibikin di Studio, BUKAN dari script: StarterGui > ScreenGui
-- "PerfectDodgeVignette" > ImageLabel. Angka di bawah ini cuma ngatur cara
-- gambar itu dianimasiin -- gambar & penempatannya urusan Studio.
CameraConfig.DODGE_VIGNETTE = {
	ENABLED = true,

	FADE_IN  = 0.07, -- masuknya nyaris instan -- ini momen "kena"
	FADE_OUT = 0.35, -- keluarnya pelan, biar kerasa napas setelah slow-mo

	-- Mekar ekstra di frame pertama terus nyusut balik ke ukuran normal.
	-- Ini yang bikin masuknya kerasa nge-SLAM, bukan sekadar fade in.
	PUNCH_SCALE = 0.14,

	-- Denyut halus selama nahan. Bukan detak jantung kayak FFYL (yang
	-- sengaja bikin panik) -- di sini cuma biar frame-nya gak kelihatan
	-- beku kayak gambar diam.
	BREATHE_SPEED = 4.5,
	BREATHE_DEPTH = 0.1,

	-- Blur tipis. Sengaja jauh lebih kecil dari blur FFYL (max 12): pemain
	-- masih harus bisa baca gerakan lawan buat nyambung serangan balik.
	BLUR = {
		ENABLED  = true,
		NAME     = "PerfectDodgeBlur",
		MAX_SIZE = 5,
	},

	-- Warna ngikutin bahasa warna DodgeTextClient (cyan = berhasil baca,
	-- merah = kebaca), tapi versi GELAPnya. Ini penting: vignette itu
	-- BAYANGAN, bukan lampu. Kalau diisi cyan terang (120,245,255) persis
	-- kayak warna teksnya, tepi layar malah nyala kayak flash -- yang keluar
	-- efek "glow", bukan framing sinematik.
	--
	-- COLOR dipasang ke ImageColor3, jadi ini NGALIIN warna asli gambarnya.
	-- Cuma jalan bener kalau gambar vignette-nya putih/abu-abu; kalau
	-- gambarnya udah berwarna (mis. vignette merah kayak punya FFYL), isi
	-- COLOR = nil biar script gak nyentuh warnanya sama sekali dan warna yang
	-- diset di Studio yang dipakai.
	--
	-- Yang kebaca dikasih versi lebih tipis (PEAK_TRANSPARENCY lebih besar):
	-- ini momen kemenangan si pendodge, bukan dia.
	PERFECT = {
		COLOR             = Color3.fromRGB(10, 52, 72),
		PEAK_TRANSPARENCY = 0.1,
	},

	READ = {
		COLOR             = Color3.fromRGB(64, 12, 12),
		PEAK_TRANSPARENCY = 0.26,
	},
}
-- ============================================================
-- FFYL FEEDBACK
-- ============================================================

CameraConfig.FFYL_FEEDBACK = {
	ENABLED = true,
	SLOWMO_SPEED = 0.15,
	SLOWMO_DURATION = 1,
	ZOOM_IN_DISTANCE = 7.5,
	ZOOM_SUSTAIN_DISTANCE = 6.8,
	ZOOM_IN_SPEED = 12,
	ZOOM_SUSTAIN_SPEED = 4,
	ZOOM_OUT_SPEED = 6,
}

-- ============================================================
-- FFYL SWAY
-- ============================================================

CameraConfig.FFYL_SWAY = {
	ENABLED = true,
	FREQUENCY = 0.7,
	ROTATION = Vector3.new(3.5, 2.5, 4),
	TRANSLATION = Vector3.new(0.4, 0.25, 0.15),
	RAMP_TIME = 0.5,
}

-- ============================================================
-- IDLE SWAY
-- ============================================================

CameraConfig.IDLE_SWAY = {
	ENABLED = true,
	FREQUENCY = 0.25,
	ROTATION = Vector3.new(0.6, 0.45, 0.3),
	TRANSLATION = Vector3.new(0.08, 0.06, 0.04),
	RAMP_TIME = 0.4,
}

-- ============================================================
-- KO FEEDBACK
-- ============================================================

CameraConfig.KO_FEEDBACK = {
	ENABLED = true,
	SLOWMO_SPEED = 0.55,
	SLOWMO_DURATION = 3.5,
	ZOOM_DISTANCE = 5,
	ZOOM_IN_SPEED = 8,
	ZOOM_OUT_SPEED = 5,
}

-- ============================================================
-- FALLEN CAMERA
-- ============================================================
-- Flow: kalah ronde -> FALLEN_CAM start -> kamera mendekati wajah
-- -> head terus diikuti -> HOLD_DURATION -> rise event -> BLINK
-- -> kamera kembali ke tengah. Kalau rise event tidak datang,
-- HOLD_DURATION jadi fallback otomatis.

CameraConfig.FALLEN_CAM = {
	ENABLED = true,

	DISTANCE = 3.8, -- jarak kamera dari wajah
	HEIGHT = 0.1,   -- offset vertikal kamera
	MOVE_SPEED = 3.2, -- kecepatan kamera mengikuti Head

	FOV = 58,
	FOV_SPEED = 4,

	HOLD_DURATION = 2.0, -- durasi bertahan sebelum BLINK otomatis
}

-- ============================================================
-- BLINK TRANSITION
-- ============================================================
-- Urutan: CLOSE (layar menghitam) -> HOLD (hitam penuh) ->
-- CAMERA CUT (kamera dipindah ke tengah) -> OPEN (layar terbuka).

CameraConfig.BLINK = {
	ENABLED = true,
	CLOSE_TIME = 0.12, -- nutup cepat, kayak reflex kedip
	HOLD_TIME = 0.08,  -- jeda hitam sebentar
	OPEN_TIME = 0.32,  -- buka lebih pelan & lembut, biar kerasa natural
}

return CameraConfig