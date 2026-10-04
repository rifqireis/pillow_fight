-- @ScriptType: ModuleScript
--[[
    Nama File  : VFXConfig.lua
    Layer      : Config
    Deskripsi  : Konstanta tuning untuk efek visual (VFX) pertarungan:
                 rail/trail bantal saat mengayun & percikan saat kena hit.
                 Semua warna/tekstur/ukuran diatur di sini supaya VFXService
                 tidak perlu diutak-atik kalau cuma mau ganti tampilan.
    Penulis    : System
    Tanggal    : 14 Agustus 2026
    Versi      : 1.0
    Dependensi : -
]]
local VFXConfig = {}
-- ================================================================
-- RAIL SERANG (Trail bantal saat mengayun)
-- ================================================================
-- Trail Instance-nya sendiri dipasang manual di Studio: di dalam Tool
-- "Pillow" > Handle, bikin 2 Attachment ("TrailTop" & "TrailBottom") lalu
-- taruh 1 Trail sebagai anak Attachment "TrailTop" dengan
-- Attachment0 = TrailTop, Attachment1 = TrailBottom.
-- Trail otomatis CUMA kelihatan waktu attachment-nya bergerak cepat (pas
-- ayunan) -- diam pun tidak ada rail yang nongol, jadi tidak perlu logika
-- enable/disable tiap ayunan. VFXService cuma ganti warnanya sesuai jenis
-- serangan pas ayunan dimulai.
--
-- SEMENTARA DIMATIIN (WIDTH_SCALE = 0) buat ngetes apakah "efek kedua"
-- yang keliatan pas hit itu sebenarnya trail ini, bukan HitEffect.
-- Balikin ke 0.6 / 1 lagi kalau udah selesai ngetes.
VFXConfig.TRAIL = {
	ATTACHMENT_NAMES = { top = "TrailTop", bottom = "TrailBottom" },
	COLOR = {
		light = ColorSequence.new(Color3.fromRGB(255, 255, 255)),
		heavy = ColorSequence.new(Color3.fromRGB(255, 196, 80)),
	},
	TRANSPARENCY = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	}),
	WIDTH_SCALE = {
		light = NumberSequence.new(0.6), -- balik dari 0
		heavy = NumberSequence.new(1),   -- balik dari 0
	},
	LIFETIME = { light = 0.12, heavy = 0.2 },
}
-- ================================================================
-- EFEK KENA HIT (percikan di titik kontak bantal)
-- ================================================================
-- Dipakai VFXService.spawnHitEffect. Pakai tekstur bawaan Roblox
-- (rbxasset://) supaya tidak tergantung asset upload apa pun.
VFXConfig.HIT = {
	TEXTURE = "rbxasset://textures/particles/sparkles_main.dds",
	COLOR = {
		light = ColorSequence.new(Color3.fromRGB(255, 255, 255)),
		heavy = ColorSequence.new(Color3.fromRGB(255, 170, 60)),
	},
	COUNT = { light = 10, heavy = 22 },
	SIZE = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	}),
	LIFETIME = NumberRange.new(0.15, 0.3),
	SPEED    = NumberRange.new(6, 14),
	SPREAD   = Vector2.new(180, 180),
	-- Berapa lama Attachment sementara (tempat nempel ParticleEmitter)
	-- dibiarkan hidup sebelum di-Debris. Harus > LIFETIME.Max di atas.
	CLEANUP_DELAY = 1,
}
return VFXConfig