-- Location: StarterPlayer > StarterPlayerScripts > InputHandler
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local damageEvent = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DamageEvent")

-- Config
local ATTACK_KEY = Enum.KeyCode.E

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end -- Abaikan jika sedang mengetik di chat

	if input.KeyCode == ATTACK_KEY then
		local target = mouse.Target

		if target and target.Parent then
			-- Cek apakah yang diklik adalah Model yang punya Humanoid (Musuh/Player)
			local enemyModel = target.Parent
			local enemyHumanoid = enemyModel:FindFirstChild("Humanoid")

			if enemyHumanoid then
				-- Kirim sinyal ke server: "Saya mau serang Humanoid ini"
				damageEvent:FireServer(enemyHumanoid)
			end
		end
	end
end)