-- @ScriptType: ModuleScript
--[[
    Nama File  : KOConfig
    Layer      : Config (Shared)
    Deskripsi  : Konfigurasi teks "KO" yang muncul begitu ada pemain kalah
                 FFYL (lihat ArenaService.endRound). Labelnya dipilih ACAK
                 di server (bukan di masing-masing client) supaya pemenang
                 dan yang kalah sama-sama lihat teks yang persis sama saat
                 momen itu terjadi.
    Dipakai    : - ServerScriptService > Core > Service > ArenaService
                 - StarterPlayerScripts > UI > KOTextClient
]]

local KOConfig = {}

-- Daftar label yang bisa muncul. Tambah/ubah bebas di sini -- ArenaService
-- otomatis memilih salah satu secara acak tiap kali ada yang KO, tidak perlu
-- ubah kode lain.
KOConfig.LABELS = {
	"K.O.!",
	"KNOCKED OUT!",
	"DOWN FOR THE COUNT!",
	"LIGHTS OUT!",
	"PILLOW SMASHED!",
	"BONKED!",
	"GOOD NIGHT!",
	"FLATTENED!",
	"SLEEP TIGHT!",
	"NAPTIME!",
}

-- Total waktu teks berada di layar dari mulai muncul sampai benar-benar
-- hilang (detik). KOTextClient membagi angka ini sendiri jadi tahap
-- punch-in / hold / fade-out, jadi cukup ubah satu angka ini saja.
KOConfig.DISPLAY_DURATION = 2

return KOConfig