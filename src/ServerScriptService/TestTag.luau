-- @ScriptType: ModuleScript
--[[
    Nama File  : TestTag.luau
    Deskripsi  : Skrip contoh/pengujian untuk mengetes pendeteksi tag 'part'
                 di Workspace secara manual.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local PartService = require(ServerScriptService.Core.Service.PartService)

local TestTag = {}

--- Menjalankan pengecekan manual dan mencetak semua part yang memiliki tag 'part' di Workspace
function TestTag.cekPartDiWorkspace()
	print("========== [TestTag: Cek Part di Workspace] ==========")
	local parts = PartService.AmbilSemuaPartDenganTag("part")

	print(string.format("Ditemukan %d part dengan tag 'part' di Workspace:", #parts))
	for index, part in ipairs(parts) do
		print(string.format("  [%d] Nama: %s | Path: %s | Posisi: %s", 
			index, 
			part.Name, 
			part:GetFullName(), 
			tostring(part.Position)
		))
	end
	print("======================================================")
	return parts
end

return TestTag
