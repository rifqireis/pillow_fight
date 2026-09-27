--[[
    Nama File  : FFYLConfig
    Layer      : Config (Shared)
    Deskripsi  : Konfigurasi visual dan animasi untuk mode FFYL (Vignette & Blur Pulse)
    Penulis    : Rifqi RR
    Tanggal    : 03 Juli 2026
    Versi      : 1.0
]]

local FFYLConfig = {
	-- Parameter Visual Vignette
	VIGNETTE = {
		ASSET_ID = "rbxassetid://108271189576982",
		PULSE_SPEED = 6,          -- Kecepatan detak
		MIN_TRANSPARENCY = 0.2,   -- Paling terang saat puncak detak
		MAX_TRANSPARENCY = 0.7,   -- Paling redup saat jeda detak
		MAX_SCALE_BOOST = 0.08,   -- Skala mekar (8%)
	},

	-- Parameter Visual Blur
	BLUR = {
		NAME = "FFYLBlur",
		MIN_SIZE = 2,             -- Ukuran blur saat jeda detak
		MAX_SIZE = 12,            -- Ukuran blur saat puncak detak
	}
}

return FFYLConfig 