-- @ScriptType: LocalScript
-- @ScriptType: LocalScript
-- @ScriptType: LocalScript
--[[
    Nama File  : TeleporterLabelCuller
    Layer      : Client (UI)
    Deskripsi  : Mengatur BillboardGui TextLabel di setiap ArenaTeleporterN.Teleporter:
                   - Cuma MAX_VISIBLE_LABELS teleporter TERDEKAT dari player yang nyala.
                   - Ukuran label TETAP (gak berubah sama sekali).
                   - Opacity teks (TextTransparency/TextStrokeTransparency) di-fade
                     sesuai jarak: deket = solid, makin jauh = makin transparan,
                     sampai akhirnya dimatikan (Enabled = false).
                   - Begitu player SUDAH MATCH (TeleporterLabelHideEvent = true,
                     ditembak MatchmakingService begitu antrean penuh/dapet lawan),
                     SEMUA label billboard dipaksa mati. Ini SENGAJA nembak lebih awal
                     daripada SyncMatchStateEvent -- SyncMatchStateEvent baru true
                     ~8-10 detik kemudian (setelah teleport ke spawn arena + countdown
                     ronde "3..2..1..FIGHT"), padahal dari saat antrean penuh pun
                     player udah gak perlu liat label lagi.
                   - SyncMatchStateEvent tetap didengerin juga sebagai lapisan kedua
                     (jaga-jaga andai TeleporterLabelHideEvent gagal ditembak/diterima).

    Tanggal    : 13 Agustus 2026
    Versi      : 8.0
    Dependensi : - Workspace > World > Environment > PillowArena > <ArenaTeleporterN> > Teleporter > BillboardGui > TextLabel
                 - ReplicatedStorage > Remotes > TeleporterLabelHideEvent
                 - ReplicatedStorage > Remotes > SyncMatchStateEvent
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local TeleporterLabelHideEvent = RemotesFolder:WaitForChild("TeleporterLabelHideEvent")
local SyncMatchStateEvent = RemotesFolder:WaitForChild("SyncMatchStateEvent")

local pillowArena = Workspace
	:WaitForChild("World")
	:WaitForChild("Environment")
	:WaitForChild("PillowArena")

-- ================================================================
-- STATE
-- ================================================================

local isMatched = false
local isInMatch = false

TeleporterLabelHideEvent.OnClientEvent:Connect(function(shouldHide)
	isMatched = shouldHide
end)

SyncMatchStateEvent.OnClientEvent:Connect(function(isPlaying)
	isInMatch = isPlaying
end)

-- ================================================================
-- CONFIGURATION
-- ================================================================

local MAX_VISIBLE_LABELS = 4

local NEAR_DISTANCE = 40
local FAR_DISTANCE = 150

local WAIT_TIMEOUT = 10

local DEBUG_PRINT = false
local lastDebugPrint = 0
local RUN_ID = tostring(math.random(1000, 9999))

-- ================================================================
-- ARENA REGISTRATION
-- ================================================================

local entries = {}

local function unregisterArena(arenaFolder)
	entries[arenaFolder] = nil
end

local function registerArena(arenaFolder)
	if not arenaFolder:IsA("Folder") then
		return
	end

	task.spawn(function()
		local teleporter = arenaFolder:WaitForChild(
			"Teleporter",
			WAIT_TIMEOUT
		)

		if not teleporter then
			warn(
				"[TeleporterLabelCuller#"
					.. RUN_ID
					.. "] "
					.. arenaFolder.Name
					.. ".Teleporter tidak ditemukan dalam "
					.. WAIT_TIMEOUT
					.. "s"
			)
			return
		end

		local billboard = teleporter:WaitForChild(
			"BillboardGui",
			WAIT_TIMEOUT
		)

		if not billboard then
			billboard = teleporter:FindFirstChildOfClass("BillboardGui")
		end

		if not billboard then
			warn(
				"[TeleporterLabelCuller#"
					.. RUN_ID
					.. "] "
					.. arenaFolder.Name
					.. ".Teleporter.BillboardGui tidak ditemukan"
			)
			return
		end

		local textLabels = {}

		for _, descendant in ipairs(billboard:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				table.insert(textLabels, {
					instance = descendant,
					originalTextTransparency = descendant.TextTransparency,
					originalStrokeTransparency = descendant.TextStrokeTransparency,
				})
			end
		end

		entries[arenaFolder] = {
			teleporter = teleporter,
			billboard = billboard,
			textLabels = textLabels,
		}

		print(
			string.format(
				"[TeleporterLabelCuller#%s] Terdaftar: %s (%d TextLabel)",
				RUN_ID,
				arenaFolder.Name,
				#textLabels
			)
		)
	end)

	arenaFolder.AncestryChanged:Connect(function(_, parent)
		if not parent then
			unregisterArena(arenaFolder)
		end
	end)
end

-- PENTING: connect listener DULU sebelum enumerate GetChildren(). Kalau
-- kebalik (enumerate dulu baru connect), ada celah waktu di antaranya --
-- arena folder yang ke-parent PAS di celah itu bakal gak ke-capture sama
-- snapshot GetChildren() ATAUPUN ChildAdded (listener-nya belum nyala),
-- jadi hilang selamanya dari `entries`. Kalau ini kena banyak/semua arena
-- sekaligus (misal server nge-build beberapa arena berurutan pas bareng
-- client connect), Heartbeat di bawah gak nyentuh billboard manapun, dan
-- semua label balik ke state default Studio-nya (Enabled = true) -- keliatan
-- "normal" semua, gak ke-cull. registerArena aman dipanggil dobel untuk
-- folder yang sama (cuma overwrite entry-nya), jadi urutan ini gak masalah.
pillowArena.ChildAdded:Connect(registerArena)
pillowArena.ChildRemoved:Connect(unregisterArena)

for _, child in ipairs(pillowArena:GetChildren()) do
	registerArena(child)
end

-- ================================================================
-- DISTANCE
-- ================================================================

local function getScaleForDistance(distance)
	if distance <= NEAR_DISTANCE then
		return 1
	end

	if distance >= FAR_DISTANCE then
		return 0
	end

	local alpha = (distance - NEAR_DISTANCE) / (FAR_DISTANCE - NEAR_DISTANCE)

	return 1 - alpha
end

-- ================================================================
-- UPDATE
-- ================================================================

RunService.Heartbeat:Connect(function()
	if isInMatch or isMatched then
		for _, entry in pairs(entries) do
			entry.billboard.Enabled = false
		end

		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	if not rootPart then
		for _, entry in pairs(entries) do
			entry.billboard.Enabled = false
		end

		return
	end

	local playerPosition = rootPart.Position

	local shouldPrintDebug = false

	if DEBUG_PRINT and os.clock() - lastDebugPrint >= 1 then
		shouldPrintDebug = true
		lastDebugPrint = os.clock()
	end

	local distances = {}

	for arenaFolder, entry in pairs(entries) do
		if entry.teleporter and entry.teleporter.Parent then
			table.insert(distances, {
				arenaName = arenaFolder.Name,
				entry = entry,
				distance = (entry.teleporter.Position - playerPosition).Magnitude,
			})
		end
	end

	table.sort(distances, function(a, b)
		return a.distance < b.distance
	end)

	for index, data in ipairs(distances) do
		local entry = data.entry
		local withinRank = index <= MAX_VISIBLE_LABELS
		local scale = getScaleForDistance(data.distance)

		if shouldPrintDebug then
			print(
				string.format(
					"[TeleporterLabelCuller#%s][DEBUG] #%d %s | jarak=%.1f | scale=%.2f | tampil=%s",
					RUN_ID,
					index,
					data.arenaName,
					data.distance,
					scale,
					tostring(withinRank and scale > 0)
				)
			)
		end

		if withinRank and scale > 0 then
			entry.billboard.Enabled = true

			local fadeAmount = 1 - scale

			for _, labelData in ipairs(entry.textLabels) do
				local label = labelData.instance

				label.TextTransparency =
					labelData.originalTextTransparency
					+ (1 - labelData.originalTextTransparency) * fadeAmount

				label.TextStrokeTransparency =
					labelData.originalStrokeTransparency
					+ (1 - labelData.originalStrokeTransparency) * fadeAmount
			end
		else
			entry.billboard.Enabled = false
		end
	end
end)

print(
	string.format(
		"[TeleporterLabelCuller#%s] Aktif | Max=%d | Near=%d | Far=%d",
		RUN_ID,
		MAX_VISIBLE_LABELS,
		NEAR_DISTANCE,
		FAR_DISTANCE
	)
)