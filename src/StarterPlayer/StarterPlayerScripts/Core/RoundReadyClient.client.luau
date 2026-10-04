-- @ScriptType: LocalScript
--[[
    Nama File  : RoundReadyClient
    Layer      : Client (Core)
	Penulis    : Yusuf Ahayy
    Tanggal    : 17 Agustus 2026
    Deskripsi  : Sisi client dari ready-handshake ronde. Server (ArenaService.
                 startRound -> waitForPlayersReady) nembak RoundReadyEvent
                 begitu teleport ke arena selesai, dan MENUNGGU kedua pemain
                 fire balik sebelum lanjut ke reset stats/UI/countdown. Ini
                 nutup celah lag/ms beda-beda antar pemain -- tanpa ini,
                 server langsung asumsi client udah siap begitu PivotTo
                 dipanggil, padahal replikasi ke client yang koneksinya lebih
                 lambat bisa telat.

                 Script ini SENGAJA simpel: begitu prompt-nya diterima,
                 langsung fire balik. Round-trip time (kirim -> proses ->
                 balik) itu sendiri sudah jadi indikator kasar kondisi
                 jaringan pemain saat itu -- gak perlu logic tambahan di
                 client buat "nunggu" apa-apa lagi, karena karakter/seat/
                 kamera pemain ini sendiri udah pasti ke-render duluan
                 sebelum LocalScript ini sempat jalan.

    Dependensi : - ReplicatedStorage > Remotes > RoundReadyEvent
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local RoundReadyEvent = RemotesFolder:WaitForChild("RoundReadyEvent")

RoundReadyEvent.OnClientEvent:Connect(function()
	RoundReadyEvent:FireServer()
end)