-- @ScriptType: Script
local ServerScriptService = game:GetService("ServerScriptService")

-- Otomatis mencari dan menjalankan PartService secara tahan banting
local partServiceModule = ServerScriptService:FindFirstChild("PartService", true)
if partServiceModule then
	local PartService = require(partServiceModule)
	if PartService.init then
		PartService.init()
	end
end
