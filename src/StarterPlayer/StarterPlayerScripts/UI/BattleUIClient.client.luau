-- @ScriptType: LocalScript
--[[
    Nama File  : BattleUIClient.lua
    Layer      : Client (UI)
    Deskripsi  : Menyalakan BattleUI hanya selama pertandingan berlangsung.
                 Di lobby seluruh panel (HpLeft, HpRight, FFYL) disembunyikan.
                 Aman dari isu ResetOnSpawn dan character respawn.
    Penulis    : System, Yusuf Ahayy
    Tanggal    : 01 Agustus 2026
    Versi      : 1.1 (Refactored & Respawn Safe)
    Dependensi : - ReplicatedStorage > Remotes > SyncMatchStateEvent
                 - StarterGui > BattleUI
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SyncMatchStateEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SyncMatchStateEvent")

-- Cache status pertandingan saat ini
local currentMatchState = false

-- Fungsi untuk mendapatkan instans BattleUI yang paling aktif & valid
local function getBattleUI()
	return playerGui:FindFirstChild("BattleUI") or playerGui:WaitForChild("BattleUI")
end

local function setUIEnabled(enabled)
	currentMatchState = enabled
	local ui = getBattleUI()
	if ui then
		ui.Enabled = enabled
	end
end

-- Sembunyikan UI saat awal masuk lobby
setUIEnabled(false)

-- ================================================================
-- HANDLING RESPAWN / RE-BINDING
-- ================================================================
-- Jika ResetOnSpawn = true, pastikan status .Enabled diterapkan kembali ke UI baru
playerGui.ChildAdded:Connect(function(child)
	if child.Name == "BattleUI" and child:IsA("ScreenGui") then
		child.Enabled = currentMatchState
	end
end)

-- ================================================================
-- EVENT LISTENER
-- ================================================================
SyncMatchStateEvent.OnClientEvent:Connect(function(isPlaying)
	setUIEnabled(isPlaying == true)
end)

print("[BattleUIClient] Berhasil diinisialisasi & Siap menangani Respawn")