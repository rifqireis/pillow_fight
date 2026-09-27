-- @ScriptType: ModuleScript
--[[
    Nama File  : ComboService.lua
    Layer      : Service
    Deskripsi  : Menghitung combo serangan beruntun milik attacker.
                 Combo naik tiap kali attacker landing pukulan dalam jendela
                 waktu GameplayConfig.COMBO_WINDOW sejak pukulan sebelumnya.
                 Combo direset kalau jendela waktu habis atau serangannya
                 di-dodge (di-counter) oleh korban.
    Dependensi : - ServerScriptService > Core > Repository > PlayerStateRepository
                 - ReplicatedStorage > Configs > GameplayConfig
]]

local ComboService = {}

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local GameplayConfig        = require(ReplicatedStorage.Configs.GameplayConfig)

-- ================================================================
-- Dipanggil CombatController setiap kali pukulan attacker BENAR-BENAR
-- landing (sesudah lolos cek dodge/i-frame korban).
-- Kembalian: comboCount terbaru attacker (angka bulat >= 1).
-- ================================================================
function ComboService.onHitLanded(attacker)
	local state = PlayerStateRepository.get(attacker)
	if not state then return 1 end

	local now = os.clock()
	local lastComboTime = state.lastComboTime or 0
	local withinWindow = (now - lastComboTime) <= GameplayConfig.COMBO_WINDOW

	local newCombo = withinWindow and ((state.comboCount or 0) + 1) or 1

	PlayerStateRepository.set(attacker, "comboCount", newCombo)
	PlayerStateRepository.set(attacker, "lastComboTime", now)

	return newCombo
end

-- ================================================================
-- Dipanggil saat serangan attacker di-dodge (di-counter) korban, atau
-- kapan pun combo harus diputus paksa (mis. attacker kalah/disconnect).
-- ================================================================
function ComboService.reset(attacker)
	PlayerStateRepository.set(attacker, "comboCount", 0)
	PlayerStateRepository.set(attacker, "lastComboTime", 0)
end

-- ================================================================
-- Baca combo count saat ini tanpa mengubah apa pun. Dipakai kalau ada
-- yang perlu tahu combo attacker tanpa memicu perhitungan baru.
-- ================================================================
function ComboService.get(attacker)
	local state = PlayerStateRepository.get(attacker)
	return state and state.comboCount or 0
end

return ComboService