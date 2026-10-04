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

-- Ekstrak ServerScriptService
print("Mengekstrak ServerScriptService -> src/ServerScriptService...")
exportTree(place.ServerScriptService, "src/ServerScriptService")

-- Ekstrak ReplicatedStorage
local repStorage = place.ReplicatedStorage
if repStorage:FindFirstChild("Configs") then
    print("Mengekstrak ReplicatedStorage/Configs -> src/ReplicatedStorage/Configs...")
    exportTree(repStorage.Configs, "src/ReplicatedStorage/Configs")
end

if repStorage:FindFirstChild("Shared") then
    print("Mengekstrak ReplicatedStorage/Shared -> src/ReplicatedStorage/Shared...")
    exportTree(repStorage.Shared, "src/ReplicatedStorage/Shared")
end

-- Ekstrak StarterPlayerScripts
local starterPlayer = place:FindFirstChild("StarterPlayer")
if starterPlayer and starterPlayer:FindFirstChild("StarterPlayerScripts") then
    print("Mengekstrak StarterPlayerScripts -> src/StarterPlayer/StarterPlayerScripts...")
    exportTree(starterPlayer.StarterPlayerScripts, "src/StarterPlayer/StarterPlayerScripts")
end

-- Ekstrak ReplicatedFirst
local repFirst = place:FindFirstChild("ReplicatedFirst")
if repFirst then
    print("Mengekstrak ReplicatedFirst -> src/ReplicatedFirst...")
    exportTree(repFirst, "src/ReplicatedFirst")
end

print("Ekstraksi selesai! Struktur 1:1 dengan Roblox Studio.")
