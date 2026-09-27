-- dump.lua
local place = remodel.readPlaceFile("place.rbxlx")

local function exportTree(instance, targetPath)
    remodel.createDirAll(targetPath)
    for _, child in ipairs(instance:GetChildren()) do
        if child.ClassName == "Folder" then
            exportTree(child, targetPath .. "/" .. child.Name)
        elseif child.ClassName == "Script" then
            local name = child.Name:gsub("%.server$", "")
            remodel.writeFile(targetPath .. "/" .. name .. ".server.luau", child.Source)
        elseif child.ClassName == "LocalScript" then
            local name = child.Name:gsub("%.client$", "")
            remodel.writeFile(targetPath .. "/" .. name .. ".client.luau", child.Source)
        elseif child.ClassName == "ModuleScript" then
            remodel.writeFile(targetPath .. "/" .. child.Name .. ".luau", child.Source)
        end
    end
end

-- Ekstrak ServerScriptService ke src/server
print("Mengekstrak ServerScriptService...")
exportTree(place.ServerScriptService, "src/server")

-- Ekstrak ReplicatedStorage.Configs ke src/configs
local repStorage = place.ReplicatedStorage
if repStorage:FindFirstChild("Configs") then
    print("Mengekstrak ReplicatedStorage/Configs...")
    exportTree(repStorage.Configs, "src/configs")
end

-- Ekstrak ReplicatedStorage.Shared ke src/shared
if repStorage:FindFirstChild("Shared") then
    print("Mengekstrak ReplicatedStorage/Shared...")
    exportTree(repStorage.Shared, "src/shared")
end

print("Ekstraksi selesai! Semua script aman di lokal.")
