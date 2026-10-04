local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- RemoteEvent dari server
local showHealthBarEvent = ReplicatedStorage:WaitForChild("ShowHealthBarEvent")

-- Variabel untuk tracking health bar
local currentHealthBar = nil

-- Fungsi untuk membuat health bar
local function createHealthBar()
	-- Clone dari ServerStorage
	local healthBarTemplate = ServerStorage:FindFirstChild("HealthBar")
	if not healthBarTemplate then
		warn("HealthBar template tidak ditemukan di ServerStorage!")
		return nil
	end
	
	-- Clone ke player GUI
	local healthBar = healthBarTemplate:Clone()
	healthBar.Parent = playerGui
	
	return healthBar
end

-- Fungsi untuk update health bar
local function updateHealthBar(healthPercentage)
	if currentHealthBar then
		local healthFill = currentHealthBar:FindFirstChild("MainFrame"):FindFirstChild("BackgroundBar"):FindFirstChild("HealthFill")
		local healthText = currentHealthBar:FindFirstChild("MainFrame"):FindFirstChild("BackgroundBar"):FindFirstChild("HealthText")
		
		if healthFill and healthText then
			healthFill.Size = UDim2.new(healthPercentage, 0, 1, 0)
			healthText.Text = math.floor(healthPercentage * 100) .. "%"
			
			-- Ubah warna berdasarkan health
			if healthPercentage > 0.6 then
				healthFill.BackgroundColor3 = Color3.new(0, 1, 0) -- Hijau
			elseif healthPercentage > 0.3 then
				healthFill.BackgroundColor3 = Color3.new(1, 1, 0) -- Kuning
			else
				healthFill.BackgroundColor3 = Color3.new(1, 0, 0) -- Merah
			end
		end
	end
end

-- Fungsi untuk menampilkan health bar
local function showHealthBar()
	-- Hapus health bar lama jika ada
	if currentHealthBar then
		currentHealthBar:Destroy()
	end
	
	-- Buat health bar baru
	currentHealthBar = createHealthBar()
	
	if currentHealthBar then
		print("Health bar ditampilkan!")
	end
end

-- Connect ke RemoteEvent dari server
showHealthBarEvent.OnClientEvent:Connect(function(action, data)
	if action == "ShowHealthBar" then
		showHealthBar()
	elseif action == "UpdateHealth" then
		updateHealthBar(data)
	end
end)

-- Cleanup ketika character respawn
player.CharacterAdded:Connect(function()
	if currentHealthBar then
		currentHealthBar:Destroy()
		currentHealthBar = nil
	end
end)