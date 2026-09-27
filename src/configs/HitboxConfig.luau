-- @ScriptType: ModuleScript
--[[
    Nama File  : HitboxConfig.lua
    Layer      : Config
    Deskripsi  : Konfigurasi hitbox bantal. Menentukan KAPAN sebuah ayunan
                 dianggap aktif (jendela kontak) dan SEBESAR apa area bantal
                 yang dihitung mengenai lawan.
                 Semua angka di sini dipakai HitboxService untuk memutuskan
                 apakah pukulan mendarat, dan pada detik ke berapa animasi
                 hurt lawan harus diputar.
    Penulis    : System
    Tanggal    : 02 Agustus 2026
    Versi      : 1.0
]]

local HitboxConfig = {}

-- Pakai hitbox aktif; false akan menonaktifkan deteksi tabrakan dan langsung menghitung kontak.
HitboxConfig.ENABLED = true

-- Jika tool bantal tidak ditemukan, tetap hitung kontak pada frame animasi agar match tidak hang.
HitboxConfig.FALLBACK_WHEN_NO_PILLOW = true

-- Debug visual dan log hitbox hanya untuk tuning; matikan saat rilis.
HitboxConfig.DEBUG = false
HitboxConfig.DEBUG_LIFETIME = 0.35
HitboxConfig.DEBUG_LOG = false

-- Nama part bantal yang dipakai sebagai sumber hitbox.
HitboxConfig.PILLOW_HITBOX_NAME = "Hitbox"

-- Ukuran deteksi bisa di-override atau mengikuti ukuran tool + padding.
HitboxConfig.SIZE_OVERRIDE = nil
HitboxConfig.SIZE_PADDING  = Vector3.new(2, 2, 3)
HitboxConfig.OFFSET = Vector3.new(0, 0, 0)
HitboxConfig.MAX_RANGE = 15

-- Jendela aktif tiap serangan, dihitung dari awal ayunan.
HitboxConfig.ACTIVE_WINDOW = {
	light = { start = 0.12, stop = 0.38 },
	heavy = { start = 0.20, stop = 0.55 },
}

-- Kompensasi ping dan toleransi jaringan untuk deteksi kontak.
HitboxConfig.MAX_PING_COMPENSATION = 0.25
HitboxConfig.LATENCY_GRACE         = 0.15

-- Pilihan varian hurt berdasarkan sisi datangnya pukulan.
HitboxConfig.HURT_VARIANT_BY_SIDE = {
	right = 1,
	left  = 2,
}
HitboxConfig.SIDE_DEADZONE = 0.15

return HitboxConfig