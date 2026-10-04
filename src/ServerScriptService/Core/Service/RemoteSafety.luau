-- @ScriptType: ModuleScript
--[[
    Nama File  : RemoteSafety
    Layer      : Service (ServerScriptService/Core/Service)
    Deskripsi  : Wrapper aman untuk remote:FireClient(player, ...), plus
                 satu sumber kebenaran untuk "apakah player ini bot?".

                 Bot AI (lihat BotService/BotConfig) direpresentasikan
                 sebagai Lua table biasa, BUKAN Instance Player asli --
                 jadi dia tidak punya koneksi client/PlayerGui sama sekali.
                 Manggil remote:FireClient(botPlayer, ...) langsung akan
                 error ("invalid argument #1, Player expected") karena
                 FireClient cuma nerima Instance Player asli.

                 PENTING: JANGAN PERNAH cek "player.IsBot" langsung di file
                 lain. Instance Roblox asli (Player beneran) akan ERROR
                 ("IsBot is not a valid member of Player") kalau di-index
                 properti yang gak ada -- beda sama Lua table biasa yang
                 cuma balikin nil. Selalu pakai RemoteSafety.isBot(player)
                 di sini, yang aman buat DUA jenis "player" (Instance asli
                 maupun table bot).
    Tanggal    : 17 Agustus 2026
    Diubah     : 17 Agustus 2026 -- fix urutan cek di isRealPlayer (lihat
                 catatan PENTING di atas), tambah RemoteSafety.isBot()
    Dependensi : (tidak ada)
]]

local RemoteSafety = {}

-- Cek apakah "player" ini proxy bot (Lua table biasa dari BotService),
-- bukan Instance Player Roblox asli. Instance SELALU dicek lewat typeof()
-- dulu -- baru aman nyentuh field custom seperti .IsBot setelah itu.
function RemoteSafety.isBot(player)
	if not player then return false end
	if typeof(player) ~= "Instance" then
		-- Bukan Instance sama sekali -> pasti proxy bot (table biasa).
		return true
	end
	-- Instance asli. Player Roblox beneran tidak akan pernah error di sini
	-- karena kita sudah pastikan dia Instance -- tinggal cek kelasnya.
	return not player:IsA("Player")
end

-- Cek apakah "player" adalah pemain Roblox asli yang beneran bisa nerima
-- RemoteEvent (kebalikan dari isBot, plus mastiin dia Player valid).
local function isRealPlayer(player)
	if not player then return false end
	return typeof(player) == "Instance" and player:IsA("Player")
end
RemoteSafety.isRealPlayer = isRealPlayer

-- Ganti langsung remote:FireClient(player, ...) jadi
-- RemoteSafety.fire(remote, player, ...).
function RemoteSafety.fire(remote, player, ...)
	if not remote then return end
	if not isRealPlayer(player) then return end

	local ok, err = pcall(remote.FireClient, remote, player, ...)
	if not ok then
		warn("[RemoteSafety] FireClient gagal ke " .. tostring(player.Name) .. " (" .. remote.Name .. "): " .. tostring(err))
	end
end

-- Broadcast ke banyak pemain sekaligus (bot di dalam list otomatis di-skip
-- satu-satu lewat RemoteSafety.fire, tidak menggagalkan yang lain).
function RemoteSafety.fireAll(remote, players, ...)
	for _, player in ipairs(players) do
		RemoteSafety.fire(remote, player, ...)
	end
end

return RemoteSafety