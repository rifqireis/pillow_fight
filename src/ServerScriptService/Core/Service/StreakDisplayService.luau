-- @ScriptType: ModuleScript
--[[
    Nama File  : StreakDisplayService.lua
    Layer      : Service
    Penulis    : Yusuf Ahayyy
    Deskripsi  : Menampilkan jumlah win streak pemain sebagai BillboardGui
                 yang nempel di Head, posisinya DI ATAS nametag default Roblox
                 (yang otomatis muncul di atas kepala setiap karakter).

                 Kenapa BillboardGui di server (bukan RemoteEvent + GUI client)?
                 Karena BillboardGui yang di-parent ke Head di server otomatis
                 direplikasi ke SEMUA client tanpa perlu kirim event manual,
                 jadi lawan/pemain lain juga bisa lihat streak-nya.

                 CATATAN UKURAN: gui.Size sengaja pakai komponen SCALE (bukan
                 Offset/stud) supaya badge ini punya ukuran TETAP relatif ke
                 layar -- TIDAK ikut membesar saat kamera mendekat / mengecil
                 saat menjauh. Font juga TextScaled = false dengan TextSize
                 tetap, jadi ukuran teks selalu konsisten.

                 SISTEM TIER (v1.3 -- 8 tier, sampe 100+ win):
                   2-4    -> Bronze     : badge standar, breathing pulse halus
                   5-9    -> Silver     : pulse lebih kentara
                   10-19  -> Gold       : warna emas, pulse lebih gede
                   20-34  -> Platinum   : pulse makin cepet
                   35-49  -> Diamond    : + Sparkles nempel di kepala
                   50-74  -> Mythic     : + teks rainbow yang muter
                   75-99  -> Immortal   : rainbow makin cepet, glow makin tebel
                   100+   -> Godlike    : semua efek + shake/getar teks

                 EFEK VISUAL (v1.3):
                   1. Entrance "pop"  -- badge muncul dari kecil ke ukuran
                      normal pake EasingStyle.Back (ada overshoot dikit),
                      jadi berasa "nendang" pas nongol/naik tier.
                   2. Glow halo       -- Frame bulat blur-ish di belakang
                      panel, transparansinya napas bareng pulse.
                   3. Pulse breathing -- badge membesar-mengecil terus,
                      amplitudo & kecepatan naik seiring tier.
                   4. Rainbow spin    -- gradient warna muter di teks
                      (tier Mythic ke atas).
                   5. Sparkles        -- particle beneran (built-in Roblox
                      Sparkles instance) nempel di Head (tier Diamond ke atas).
                   6. Shake           -- teks getar tipis (khusus Godlike).

                 Semua tween jalan lewat TweenService di server; karena
                 BillboardGui & Sparkles di-parent ke Head yang direplikasi,
                 semua pemain lihat animasi yang sama tanpa RemoteEvent
                 tambahan. Semua tween di-Cancel otomatis lewat
                 gui.Destroying supaya gak nyisain tween nganggur pas
                 character respawn / streak berubah / badge diganti.

    Cara pakai : panggil StreakDisplayService.updateStreak(player, streak)
                 setiap kali winStreak berubah (sudah di-hook di LeaderboardService).
    Tanggal    : 18 Agustus 2026
    Versi      : 1.3 (8 tier sampe 100+, efek pop/glow/sparkles/shake)
]]

local StreakDisplayService = {}

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-- Streak minimum sebelum badge mulai ditampilkan.
-- (1 = langsung muncul begitu menang 1x, 2 = baru muncul mulai 2x beruntun, dst)
local MIN_STREAK_TO_SHOW = 2

-- Ukuran dasar badge dalam SCALE (persentase layar) -- jadi acuan sebelum
-- di-pulse membesar/mengecil atau di-pop pas pertama muncul.
local BASE_SIZE_X = 0.11
local BASE_SIZE_Y = 0.028

-- Cache RAM: streak terakhir tiap player, dipakai buat pasang ulang billboard
-- setiap kali character respawn (BillboardGui lama otomatis ikut hancur
-- bareng character lama).
local streakCache = {}

-- ================================================================
-- DATA TIER -- urutan dari PALING TINGGI ke PALING RENDAH, dicek pake
-- streak >= tier.min. Tinggal tambah/edit baris di sini buat nge-tweak
-- ambang batas atau efeknya, gak perlu ubah logic di bawah.
-- ================================================================
local TIERS = {
	{
		min = 100, label = "GODLIKE STREAK",
		color = Color3.fromRGB(255, 255, 255), strokeColor = Color3.fromRGB(80, 0, 90),
		textSize = 24, rainbow = true, rainbowSpeed = 1.2,
		sparkles = true, shake = true,
		pulseAmplitude = 0.22, pulseTime = 0.35,
		glowColor = Color3.fromRGB(255, 0, 200), glowTransparency = { 0.35, 0.75 },
	},
	{
		min = 75, label = "IMMORTAL STREAK",
		color = Color3.fromRGB(255, 255, 255), strokeColor = Color3.fromRGB(60, 0, 70),
		textSize = 22, rainbow = true, rainbowSpeed = 1.6,
		sparkles = true, shake = false,
		pulseAmplitude = 0.19, pulseTime = 0.4,
		glowColor = Color3.fromRGB(190, 60, 255), glowTransparency = { 0.4, 0.78 },
	},
	{
		min = 50, label = "MYTHIC STREAK",
		color = Color3.fromRGB(255, 255, 255), strokeColor = Color3.fromRGB(50, 10, 60),
		textSize = 21, rainbow = true, rainbowSpeed = 2.0,
		sparkles = true, shake = false,
		pulseAmplitude = 0.16, pulseTime = 0.45,
		glowColor = Color3.fromRGB(120, 80, 255), glowTransparency = { 0.45, 0.8 },
	},
	{
		min = 35, label = "DIAMOND STREAK",
		color = Color3.fromRGB(140, 230, 255), strokeColor = Color3.fromRGB(10, 50, 70),
		textSize = 20, rainbow = false,
		sparkles = true, shake = false,
		pulseAmplitude = 0.13, pulseTime = 0.55,
		glowColor = Color3.fromRGB(120, 220, 255), glowTransparency = { 0.5, 0.82 },
	},
	{
		min = 20, label = "PLATINUM STREAK",
		color = Color3.fromRGB(214, 226, 235), strokeColor = Color3.fromRGB(45, 55, 60),
		textSize = 19, rainbow = false,
		sparkles = false, shake = false,
		pulseAmplitude = 0.11, pulseTime = 0.65,
		glowColor = Color3.fromRGB(214, 226, 235), glowTransparency = { 0.55, 0.84 },
	},
	{
		min = 10, label = "GOLD STREAK",
		color = Color3.fromRGB(255, 215, 0), strokeColor = Color3.fromRGB(90, 60, 0),
		textSize = 18, rainbow = false,
		sparkles = false, shake = false,
		pulseAmplitude = 0.10, pulseTime = 0.8,
		glowColor = Color3.fromRGB(255, 215, 0), glowTransparency = { 0.6, 0.86 },
	},
	{
		min = 5, label = "SILVER STREAK",
		color = Color3.fromRGB(214, 232, 255), strokeColor = Color3.fromRGB(35, 45, 65),
		textSize = 17, rainbow = false,
		sparkles = false, shake = false,
		pulseAmplitude = 0.06, pulseTime = 1.0,
		glowColor = Color3.fromRGB(214, 232, 255), glowTransparency = { 0.65, 0.88 },
	},
	{
		min = 2, label = "WIN STREAK",
		color = Color3.fromRGB(255, 209, 60), strokeColor = Color3.fromRGB(40, 20, 0),
		textSize = 16, rainbow = false,
		sparkles = false, shake = false,
		pulseAmplitude = 0.03, pulseTime = 1.2,
		glowColor = Color3.fromRGB(255, 209, 60), glowTransparency = { 0.7, 0.9 },
	},
}

-- ================================================================
-- HELPER: Tentuin tier visual berdasarkan panjang streak
-- ================================================================
local function getStreakTier(streak)
	for _, tier in ipairs(TIERS) do
		if streak >= tier.min then
			return tier
		end
	end
	return TIERS[#TIERS] -- fallback, gak kepake selama MIN_STREAK_TO_SHOW >= tier terendah
end

-- ================================================================
-- HELPER: Bikin BillboardGui streak (badge + teks + semua efek tier)
-- ================================================================
local function buildStreakGui(streak)
	local tier = getStreakTier(streak)

	local gui = Instance.new("BillboardGui")
	gui.Name = "WinStreakDisplay"
	-- Mulai dari ukuran 0 -- ini titik awal buat animasi "pop" pas gui
	-- baru di-parent (di-tween membesar ke BASE_SIZE_X/Y di bawah).
	gui.Size = UDim2.new(0, 0, 0, 0)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 80
	gui.LightInfluence = 0

	-- Glow halo -- frame bulat lebih gede di belakang panel, transparansinya
	-- napas bareng pulse biar berasa nyala.
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.new(0.5, 0, 0.5, 0)
	glow.Size = UDim2.new(1.35, 0, 1.35, 0)
	glow.BackgroundColor3 = tier.glowColor
	glow.BackgroundTransparency = tier.glowTransparency[1]
	glow.BorderSizePixel = 0
	glow.ZIndex = 0
	glow.Parent = gui

	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = glow

	-- Panel bulat semi-transparan di belakang teks, biar keliatan kayak
	-- "badge" beneran, bukan cuma teks ngambang doang.
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.BackgroundColor3 = Color3.fromRGB(15, 10, 5)
	panel.BackgroundTransparency = 0.35
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.BorderSizePixel = 0
	panel.ZIndex = 1
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Thickness = 1.5
	panelStroke.Color = tier.strokeColor
	panelStroke.Transparency = 0.15
	panelStroke.Parent = panel

	local label = Instance.new("TextLabel")
	label.Name = "StreakLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.ZIndex = 2
	label.Font = Enum.Font.FredokaOne -- font tebal & bulat, gampang kebaca
	label.TextScaled = false
	label.TextSize = tier.textSize
	label.TextColor3 = tier.color
	label.TextStrokeTransparency = 1 -- outline diganti UIStroke biar lebih tajam
	label.Text = string.format("\240\159\148\165 %d %s", streak, tier.label) -- 🔥 emoji
	label.Parent = gui

	local labelStroke = Instance.new("UIStroke")
	labelStroke.Thickness = 1.5
	labelStroke.Color = tier.strokeColor
	labelStroke.Parent = label

	-- Rainbow gradient -- muter terus, kecepatan beda-beda tiap tier
	-- (Mythic paling lambat, Godlike paling kenceng).
	if tier.rainbow then
		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 128)),
			ColorSequenceKeypoint.new(0.20, Color3.fromRGB(255, 140, 0)),
			ColorSequenceKeypoint.new(0.40, Color3.fromRGB(255, 230, 0)),
			ColorSequenceKeypoint.new(0.60, Color3.fromRGB(0, 220, 130)),
			ColorSequenceKeypoint.new(0.80, Color3.fromRGB(0, 160, 255)),
			ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 128)),
		})
		gradient.Parent = label

		local rotateTween = TweenService:Create(
			gradient,
			TweenInfo.new(2.5 / tier.rainbowSpeed, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1, false),
			{ Rotation = 360 }
		)
		rotateTween:Play()

		gui.Destroying:Connect(function()
			rotateTween:Cancel()
		end)
	end

	-- Shake -- teks getar tipis, khusus tier paling puncak (Godlike) biar
	-- berasa "gila-gilaan".
	if tier.shake then
		local shakeTween = TweenService:Create(
			label,
			TweenInfo.new(0.09, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Rotation = 4 }
		)
		shakeTween:Play()

		gui.Destroying:Connect(function()
			shakeTween:Cancel()
		end)
	end

	-- Entrance "pop" -- badge membesar dari 0 ke ukuran normal pake
	-- EasingStyle.Back (ada overshoot dikit, kayak nendang), baru abis itu
	-- lanjut ke pulse breathing loop.
	local popTween = TweenService:Create(
		gui,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.new(BASE_SIZE_X, 0, BASE_SIZE_Y, 0) }
	)

	local pulseTween
	if tier.pulseAmplitude then
		local growSize = UDim2.new(
			BASE_SIZE_X * (1 + tier.pulseAmplitude), 0,
			BASE_SIZE_Y * (1 + tier.pulseAmplitude), 0
		)
		pulseTween = TweenService:Create(
			gui,
			TweenInfo.new(tier.pulseTime, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Size = growSize }
		)

		local glowGrowTween = TweenService:Create(
			glow,
			TweenInfo.new(tier.pulseTime, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = tier.glowTransparency[2] }
		)
		glowGrowTween:Play()
		gui.Destroying:Connect(function()
			glowGrowTween:Cancel()
		end)
	end

	popTween.Completed:Connect(function()
		if pulseTween then
			pulseTween:Play()
		end
	end)
	popTween:Play()

	gui.Destroying:Connect(function()
		popTween:Cancel()
		if pulseTween then
			pulseTween:Cancel()
		end
	end)

	return gui, tier
end

-- ================================================================
-- HELPER: Pasang/lepas Sparkles beneran (built-in Roblox particle) di
-- Head, khusus tier Diamond ke atas -- ini particle 3D asli, bukan cuma
-- efek UI, jadi keliatan lebih niat dari jauh.
-- ================================================================
local function applySparkles(head, tier)
	local existing = head:FindFirstChild("WinStreakSparkles")
	if existing then
		existing:Destroy()
	end

	if tier and tier.sparkles then
		local sparkles = Instance.new("Sparkles")
		sparkles.Name = "WinStreakSparkles"
		sparkles.SparkleColor = tier.glowColor
		sparkles.Parent = head
	end
end

-- ================================================================
-- HELPER: Pasang/lepas billboard + sparkles di character yang lagi aktif
-- ================================================================
local function applyToCharacter(player, streak)
	local character = player.Character
	if not character then return end

	local head = character:FindFirstChild("Head")
	if not head then return end

	local existingGui = head:FindFirstChild("WinStreakDisplay")
	if existingGui then
		existingGui:Destroy()
	end

	if streak >= MIN_STREAK_TO_SHOW then
		local gui, tier = buildStreakGui(streak)
		gui.Parent = head
		applySparkles(head, tier)
	else
		applySparkles(head, nil)
	end
end

-- ================================================================
-- PUBLIC: Dipanggil setiap kali winStreak pemain berubah
-- (dipanggil dari LeaderboardService.recordWin / recordLoss)
-- ================================================================
function StreakDisplayService.updateStreak(player, streak)
	if not player then return end
	streak = streak or 0

	streakCache[player.UserId] = streak
	applyToCharacter(player, streak)
end

-- ================================================================
-- INIT: Pasang ulang billboard tiap kali character respawn
-- ================================================================
function StreakDisplayService.init()
	local function hookPlayer(player)
		player.CharacterAdded:Connect(function(character)
			-- Tunggu Head kebentuk dulu sebelum di-parent-in BillboardGui
			local head = character:WaitForChild("Head", 5)
			if not head then return end

			local streak = streakCache[player.UserId] or 0
			applyToCharacter(player, streak)
		end)
	end

	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		streakCache[player.UserId] = nil
	end)
end

return StreakDisplayService