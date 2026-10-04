--[[
    Nama File  : LeaderboardDisplayServer.server.lua
    Layer      : Server
    Deskripsi  : Mengambil data dari LeaderboardService dan menampilkan ke SurfaceGui papan 3D.
    Tanggal    : 17 Agustus 2026
    Versi      : 1.3 (Fix tinggi row yang ikut 100% container)
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local Workspace            = game:GetService("Workspace")

local LeaderboardService = require(ServerScriptService.Core.Service.LeaderboardService)

-- TEMPLATE ROW & FOLDER PAPAN
local templatesFolder = ReplicatedStorage:WaitForChild("Templates")
local rowTemplate     = templatesFolder:WaitForChild("LeaderboardRow")

-- Path Utama: game.Workspace.Leaderboard
local leaderboardFolder = Workspace:WaitForChild("Leaderboard")

-- KONFIGURASI PAPAN
local BOARDS_CONFIG = {
	{
		Type = "Wins",
		BoardName = "WinBoard",
		Title = "🏆 TOP WINS"
	},
	{
		Type = "WinStreak",
		BoardName = "WinStreakBoard",
		Title = "🔥 TOP WIN STREAK"
	},
	{
		Type = "PlayTime",
		BoardName = "PlayingTimeBoard",
		Title = "⏱ TOP PLAY TIME"
	}
}

local REFRESH_INTERVAL = 60 -- Papan tetap di-full-refresh tiap 60 detik sebagai fallback/full-sync

local TITLE_TEXT_SIZE_RANGE = { Min = 40, Max = 80 }
local ROW_TEXT_SIZE_RANGE   = { Min = 38, Max = 72 }

-- Tinggi FIXED tiap row, dalam pixel. Ini yang gantiin Size Frame template
-- yang defaultnya {1,0},{1,0} (100% tinggi container). Sengaja dikasih
-- headroom lebih dari MaxTextSize row (72px) biar teks nggak kepotong.
local ROW_HEIGHT = 72

-- Jarak (margin bottom) antar row, dalam pixel. Dipasang lewat
-- UIListLayout.Padding di ensureTitle().
local ROW_SPACING = 12

-- ================================================================
-- RESOLVE BOARD MODEL (dengan retry)
-- ================================================================
local function resolveBoardModel(config)
	if config.BoardModel and config.BoardModel.Parent then
		return config.BoardModel
	end

	local model = leaderboardFolder:FindFirstChild(config.BoardName)
	if model then
		config.BoardModel = model
	else
		config.BoardModel = nil
	end

	return config.BoardModel
end

-- ================================================================
-- HELPER: PASANG TextScaled + UITextSizeConstraint DI SATU LABEL
-- ================================================================
local function applyTextSizing(label, sizeRange)
	if not label then return end

	label.TextScaled = true

	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if not constraint then
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Parent = label
	end

	constraint.MinTextSize = sizeRange.Min
	constraint.MaxTextSize = sizeRange.Max
end

-- ================================================================
-- HELPER: PASTIKAN PAPAN PUNYA TITLE (BUAT KALAU BELUM ADA)
-- ================================================================
local function ensureTitle(surfaceGui, config)
	local title = surfaceGui:FindFirstChild("TitleLabel")
	local container = surfaceGui:FindFirstChildOfClass("Frame") or surfaceGui:FindFirstChild("Container")

	if not title then
		title = Instance.new("TextLabel")
		title.Name = "TitleLabel"
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, 0, 0.15, 0)
		title.Position = UDim2.new(0, 0, 0, 0)
		title.Font = Enum.Font.GothamBold
		title.TextColor3 = Color3.fromRGB(255, 255, 255)
		title.TextStrokeTransparency = 0.4
		title.ZIndex = 5
		title.Parent = surfaceGui
	end

	if container and not container:GetAttribute("PositionedManually") then
		container.Position = UDim2.new(container.Position.X.Scale, container.Position.X.Offset, 0.15, 0)
		container.Size = UDim2.new(container.Size.X.Scale, container.Size.X.Offset, 1 - 0.15, 0)
	end

	title.Text = config.Title or config.Type
	applyTextSizing(title, TITLE_TEXT_SIZE_RANGE)

	if container then
		local listLayout = container:FindFirstChildOfClass("UIListLayout")
		if listLayout then
			listLayout.VerticalAlignment = Enum.VerticalAlignment.Top
			listLayout.Padding = UDim.new(0, ROW_SPACING)
		end
	end
end

-- ================================================================
-- FUNGSI RENDER SATU PAPAN
-- ================================================================
local function updateBoardDisplay(config)
	local boardModel = resolveBoardModel(config)
	if not boardModel then return end

	local guiHolder = boardModel:FindFirstChild("GuiHolder")
	if not guiHolder then return end

	local surfaceGui = guiHolder:FindFirstChildOfClass("SurfaceGui")
	if not surfaceGui then return end

	local container = surfaceGui:FindFirstChildOfClass("Frame") or surfaceGui:FindFirstChild("Container")
	if not container then return end

	ensureTitle(surfaceGui, config)

	local topData = LeaderboardService.getTopData(config.Type, 10)

	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Frame") and child.Name == "LeaderboardEntry" then
			child:Destroy()
		end
	end

	for _, entry in ipairs(topData) do
		local newRow = rowTemplate:Clone()
		newRow.Name = "LeaderboardEntry"

		-- ★ FIX UTAMA ★
		-- Frame template LeaderboardRow Size-nya {1,0},{1,0} = 100% tinggi
		-- container. Makanya kalau data cuma 1 baris, row itu bentangnya
		-- sepanjang seluruh papan dan teksnya (yang center) jatuh di
		-- tengah-tengah papan -- bukan nempel di bawah title.
		-- UISizeConstraint (MinSize) yang dipasang sebelumnya TIDAK cukup
		-- karena itu cuma nge-clamp batas MINIMUM, sedangkan hasil scale
		-- 100% udah lebih besar dari minimum itu duluan (jadi gak pernah
		-- ke-trigger). Solusinya: paksa Size Y row jadi FIXED pixel,
		-- lebar (X) tetap ngikutin container penuh.
		newRow.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)

		local rankLabel  = newRow:FindFirstChild("RankLabel")
		local nameLabel  = newRow:FindFirstChild("NameLabel")
		local valueLabel = newRow:FindFirstChild("ValueLabel")

		if not (rankLabel and nameLabel and valueLabel) then
			warn(string.format(
				"[LeaderboardDisplay] Label hilang di LeaderboardRow (Rank=%s, Name=%s, Value=%s) -- cek nama child di ReplicatedStorage.Templates.LeaderboardRow",
				tostring(rankLabel ~= nil), tostring(nameLabel ~= nil), tostring(valueLabel ~= nil)
				))
		end

		if rankLabel  then rankLabel.Text  = "#" .. tostring(entry.Rank) end
		if nameLabel  then nameLabel.Text  = entry.Name end
		if valueLabel then valueLabel.Text = entry.Value end

		applyTextSizing(rankLabel, ROW_TEXT_SIZE_RANGE)
		applyTextSizing(nameLabel, ROW_TEXT_SIZE_RANGE)
		applyTextSizing(valueLabel, ROW_TEXT_SIZE_RANGE)

		-- Tinggi label ikut penuh tinggi row (yang sekarang udah fixed &
		-- benar), lebar (X) tetap sesuai yang diatur di Studio.
		for _, label in ipairs({ rankLabel, nameLabel, valueLabel }) do
			if label then
				label.Size = UDim2.new(label.Size.X.Scale, label.Size.X.Offset, 1, 0)
				label.Position = UDim2.new(label.Position.X.Scale, label.Position.X.Offset, 0, 0)
			end
		end

		if entry.Rank == 1 then
			if rankLabel then rankLabel.TextColor3 = Color3.fromRGB(255, 215, 0) end
		elseif entry.Rank == 2 then
			if rankLabel then rankLabel.TextColor3 = Color3.fromRGB(192, 192, 192) end
		elseif entry.Rank == 3 then
			if rankLabel then rankLabel.TextColor3 = Color3.fromRGB(205, 127, 50) end
		end

		newRow.Parent = container
	end

	print(string.format("[LeaderboardDisplay] Papan '%s' berhasil diperbarui!", config.Type))
end

-- ================================================================
-- REALTIME UPDATE (event-driven, langsung pas ada data baru)
-- ================================================================
LeaderboardService.BoardUpdated.Event:Connect(function(boardType)
	for _, config in ipairs(BOARDS_CONFIG) do
		if config.Type == boardType then
			updateBoardDisplay(config)
		end
	end
end)

-- ================================================================
-- LOOP FALLBACK / FULL-SYNC
-- ================================================================
task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL)

		for _, config in ipairs(BOARDS_CONFIG) do
			updateBoardDisplay(config)
			task.wait(2)
		end
	end
end)

for _, config in ipairs(BOARDS_CONFIG) do
	updateBoardDisplay(config)
	task.wait(2)
end