-- @ScriptType: LocalScript
-- @ScriptType: LocalScript
-- @ScriptType: LocalScript
--[[
    Nama File  : ComboTextClient.lua
    Layer      : Client (UI)
    Deskripsi  : Menampilkan teks "Combo xN" dengan gaya fighting-game saat
                 attacker landing pukulan beruntun — scale punch, slide-in,
                 outline tebal — lalu fade out jika tidak ada hit baru.
                 Hanya tampil mulai combo x2 ke atas.
    Penulis    : System, Yusuf Ahayy
    Tanggal    : 14 Agustus 2026
    Versi      : 1.1 (Refactored & Deep Memory Clean)
    Dependensi : - ReplicatedStorage > Remotes > AttackResultEvent
                 - PlayerGui > BattleUI > ComboText (TextLabel)
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local attackResultEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AttackResultEvent")

-- ================================================================
-- CONSTANTS & CONFIGURATIONS
-- ================================================================
local BASE_STROKE_THICKNESS = 4
local PUNCH_SCALE           = 1.8
local PUNCH_TIME            = 0.12
local SETTLE_TIME           = 0.1
local FADE_DURATION        = 0.3

local PUNCH_SCALE_PER_COMBO = 0.08
local PUNCH_SCALE_MAX       = 3.2

-- "Gendut" pop tiap combo naik: sesaat sebelum settle ke ukuran akhir,
-- teks melebar (X) dan sedikit gepeng (Y) dulu kayak squash-and-stretch,
-- baru balik proporsional. GENDUT_X/GENDUT_Y itu pengali TAMBAHAN di atas
-- punchScale normal -- naikin GENDUT_X buat kesan "gendut" lebih parah.
local GENDUT_X = 1.18
local GENDUT_Y = 0.85

-- Glow/pulse di stroke biar combo text lebih "nyala" & kebaca, nyala terus
-- selama combo text tampil (bukan cuma sekali pas muncul).
local GLOW_PULSE_TIME  = 0.5
local GLOW_THICKNESS_MULT = 1.7

local COLOR_COOL = Color3.fromRGB(255, 140, 40)
local COLOR_HOT  = Color3.fromRGB(255, 60, 40)
local COLOR_PEAK = Color3.fromRGB(255, 230, 180)
local COLOR_RAMP_COMBO = 12

local MILESTONE_STEP                = 5
local MILESTONE_SCALE_BONUS        = 0.25
local MILESTONE_STROKE_MULT        = 1.8
local MILESTONE_STROKE_SETTLE_TIME = 0.35

-- Getar halus terus-terusan selama combo text tampil (bukan cuma sekali
-- pas landing hit) -- lihat startShakeLoop/stopShakeLoop di bawah.
local SHAKE_MAGNITUDE = 2.5
local SHAKE_STEP      = 1 / 30

local REST_SCALE_PER_COMBO = 0.035
local REST_SCALE_MAX       = 2.0
local HIDE_AFTER_IDLE      = 3.0

-- ================================================================
-- DYNAMIC UI BINDING (RESPAWN SAFE)
-- ================================================================
local battleUI, comboText, stroke
local basePosition, baseSize

local function bindUIReferences()
	battleUI  = playerGui:WaitForChild("BattleUI")
	comboText = battleUI:WaitForChild("ComboText")

	comboText.Font         = Enum.Font.GothamBlack
	comboText.TextColor3   = COLOR_COOL
	comboText.TextScaled   = true
	comboText.Visible      = false

	stroke = comboText:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Parent = comboText
	end

	stroke.Thickness       = BASE_STROKE_THICKNESS
	stroke.Color           = Color3.fromRGB(120, 50, 10)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual

	-- Base position/size aslinya ambil dari GUI Instance (diatur di Studio).
	-- Ditambah offset di sini biar gak perlu bongkar Studio tiap mau tuning.
	-- Diposisikan lebih ke kanan & lebih ke ATAS dibanding DodgeText -- combo
	-- scale-nya ikut membesar terus tiap combo naik (lihat getRestScale/
	-- getPunchScale di bawah), jadi perlu jarak lebih supaya gak numpuk sama
	-- DodgeText pas sama-sama gede. SIZE_BOOST dibalikin ke 1.0 (gak usah
	-- boost tambahan lagi) karena PUNCH_SCALE/REST_SCALE di atas udah bikin
	-- teksnya membesar sendiri -- ditumpuk boost lagi kemarin jadi kegedean.
	-- FIX (posisi beda antara PC & HP): NUDGE_X/NUDGE_Y sebelumnya pixel
	-- offset MATI (angka tetap dalam Offset). Offset pixel itu gak
	-- proporsional lintas device -- resolusi/aspect ratio HP beda jauh
	-- dari PC, jadi jumlah pixel yang sama bisa keliatan beda jauh
	-- posisinya. Percobaan pertama (kaliin sama rasio ViewportSize) masih
	-- salah arah dan hasilnya malah tambah jauh di HP.
	-- Solusi yang bener: jadiin nudge-nya SCALE (pecahan dari ukuran
	-- layar/container), bukan Offset pixel -- otomatis proporsional di
	-- device manapun, gak perlu hitung-hitung rasio resolusi lagi.
	local REFERENCE_WIDTH  = 1920  -- resolusi acuan waktu ditching NUDGE_X/Y
	local REFERENCE_HEIGHT = 1080
	local NUDGE_X_FRAC = 440 / REFERENCE_WIDTH   -- (+) = geser ke kanan, lebih jauh dari DodgeText
	local NUDGE_Y_FRAC = -85 / REFERENCE_HEIGHT  -- (-) = naik ke atas, lebih jauh dari DodgeText
	local SIZE_BOOST = 0.82                       -- 1.0 = ukuran asli Studio

	-- FIX (efek "numbuh dari pojok kanan-bawah" pas scale membesar):
	-- kalau AnchorPoint label ini bukan (0.5, 0.5) di Studio (biasanya
	-- default (0,0) = pojok kiri-atas), maka Size yang membesar cuma
	-- meluas ke kanan+bawah sementara pojok kiri-atas diam di tempat --
	-- keliatan kayak teksnya "bergerak" dari pojok itu. Paksa AnchorPoint
	-- ke tengah di sini (dikonversi ke SCALE, bukan Offset, biar hasilnya
	-- proporsional di semua ukuran layar), supaya semua tween Size di
	-- bawah (punch/settle/gendut) membesar SIMETRIS dari tengah.
	if comboText.AnchorPoint ~= Vector2.new(0.5, 0.5) then
		local absPos = comboText.AbsolutePosition
		local absSize = comboText.AbsoluteSize
		local containerSize = battleUI.AbsoluteSize

		comboText.AnchorPoint = Vector2.new(0.5, 0.5)

		if containerSize.X > 0 and containerSize.Y > 0 then
			local centerX = absPos.X + absSize.X * 0.5
			local centerY = absPos.Y + absSize.Y * 0.5
			comboText.Position = UDim2.fromScale(
				centerX / containerSize.X,
				centerY / containerSize.Y
			)
		else
			-- fallback kalau container belum ke-layout (jarang kejadian)
			comboText.Position = UDim2.fromOffset(
				absPos.X + absSize.X * 0.5,
				absPos.Y + absSize.Y * 0.5
			)
		end
	end

	local rawSize = comboText.Size
	basePosition = comboText.Position + UDim2.fromScale(NUDGE_X_FRAC, NUDGE_Y_FRAC)
	baseSize = UDim2.new(
		rawSize.X.Scale * SIZE_BOOST, rawSize.X.Offset * SIZE_BOOST,
		rawSize.Y.Scale * SIZE_BOOST, rawSize.Y.Offset * SIZE_BOOST
	)
end

bindUIReferences()

playerGui.ChildAdded:Connect(function(child)
	if child.Name == "BattleUI" then
		bindUIReferences()
	end
end)

-- Rebind kalau ViewportSize berubah (misal HP diputar landscape/portrait)
-- biar NUDGE_X/NUDGE_Y ke-scale ulang sesuai resolusi terbaru.
workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
	if battleUI and comboText then
		bindUIReferences()
	end
end)

-- ================================================================
-- STATE TRACKING
-- ================================================================
local activeThread   = nil
local hideThread     = nil
local currentComboId = 0
local activeTweens   = {}

local function cancelActiveTweens()
	for _, tween in ipairs(activeTweens) do
		if tween then
			tween:Cancel()
		end
	end
	table.clear(activeTweens)
end

-- ================================================================
-- MATH & COLOR UTILITIES
-- ================================================================
local function scaledSize(factor)
	return UDim2.new(
		baseSize.X.Scale * factor, baseSize.X.Offset * factor,
		baseSize.Y.Scale * factor, baseSize.Y.Offset * factor
	)
end

-- Kayak scaledSize tapi X & Y boleh beda faktor -- dipakai buat pop
-- "gendut" (squash-and-stretch) tiap combo naik.
local function nonUniformSize(xFactor, yFactor)
	return UDim2.new(
		baseSize.X.Scale * xFactor, baseSize.X.Offset * xFactor,
		baseSize.Y.Scale * yFactor, baseSize.Y.Offset * yFactor
	)
end

local function getPunchScale(comboCount, isMilestone)
	local scale = PUNCH_SCALE + math.max(0, comboCount - 2) * PUNCH_SCALE_PER_COMBO
	scale = math.min(scale, PUNCH_SCALE_MAX)

	if isMilestone then
		scale += MILESTONE_SCALE_BONUS
	end

	return scale
end

local function getRestScale(comboCount)
	local scale = 1 + math.max(0, comboCount - 2) * REST_SCALE_PER_COMBO
	return math.min(scale, REST_SCALE_MAX)
end

local function getComboColor(comboCount)
	local t = math.clamp((comboCount - 2) / math.max(1, COLOR_RAMP_COMBO - 2), 0, 1)

	if t < 0.5 then
		return COLOR_COOL:Lerp(COLOR_HOT, t / 0.5)
	else
		return COLOR_HOT:Lerp(COLOR_PEAK, (t - 0.5) / 0.5)
	end
end

-- ================================================================
-- ANIMATION CONTROLLERS
-- ================================================================
local shakeThread = nil
local glowThread  = nil

-- Getar halus terus-terusan selama combo text kelihatan (bukan cuma micro-
-- shake sesaat pas landing hit) -- dijalankan di thread terpisah dari
-- activeThread (punch/settle) supaya dua-duanya bisa jalan barengan tanpa
-- rebutan.
local function startShakeLoop()
	if shakeThread then
		task.cancel(shakeThread)
	end

	shakeThread = task.spawn(function()
		while comboText.Visible do
			local offsetX = (math.random() - 0.5) * 2 * SHAKE_MAGNITUDE
			local offsetY = (math.random() - 0.5) * 2 * SHAKE_MAGNITUDE
			comboText.Position = basePosition + UDim2.new(0, offsetX, 0, offsetY)
			task.wait(SHAKE_STEP)
		end
	end)
end

local function stopShakeLoop()
	if shakeThread then
		task.cancel(shakeThread)
		shakeThread = nil
	end
	comboText.Position = basePosition
end

-- Glow pulse di stroke -- nyala-redup berulang selama combo text kelihatan,
-- biar lebih "keluar"/kebaca dibanding stroke statis biasa.
local function startGlowPulse()
	if glowThread then
		task.cancel(glowThread)
	end

	glowThread = task.spawn(function()
		while comboText.Visible do
			local pulseUp = TweenService:Create(
				stroke,
				TweenInfo.new(GLOW_PULSE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Thickness = BASE_STROKE_THICKNESS * GLOW_THICKNESS_MULT }
			)
			pulseUp:Play()
			pulseUp.Completed:Wait()
			if not comboText.Visible then break end

			local pulseDown = TweenService:Create(
				stroke,
				TweenInfo.new(GLOW_PULSE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Thickness = BASE_STROKE_THICKNESS }
			)
			pulseDown:Play()
			pulseDown.Completed:Wait()
		end
	end)
end

local function stopGlowPulse()
	if glowThread then
		task.cancel(glowThread)
		glowThread = nil
	end
	stroke.Thickness = BASE_STROKE_THICKNESS
end

local function hideComboText()
	if activeThread then
		task.cancel(activeThread)
		activeThread = nil
	end

	stopShakeLoop()
	stopGlowPulse()
	cancelActiveTweens()

	activeThread = task.spawn(function()
		local fadeTween = TweenService:Create(
			comboText,
			TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1 }
		)
		local strokeFadeTween = TweenService:Create(
			stroke,
			TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Transparency = 1 }
		)

		table.insert(activeTweens, fadeTween)
		table.insert(activeTweens, strokeFadeTween)

		fadeTween:Play()
		strokeFadeTween:Play()
		fadeTween.Completed:Wait()

		comboText.Visible   = false
		comboText.Position  = basePosition
		comboText.Size      = baseSize
		stroke.Thickness    = BASE_STROKE_THICKNESS
		activeThread        = nil
		cancelActiveTweens()
	end)
end

local function showComboText(comboCount)
	if activeThread then
		task.cancel(activeThread)
		activeThread = nil
	end

	cancelActiveTweens()

	local isMilestone = comboCount % MILESTONE_STEP == 0

	comboText.Text             = "COMBO x" .. comboCount
	comboText.Visible          = true
	comboText.TextTransparency = 0
	comboText.TextColor3       = getComboColor(comboCount)
	stroke.Transparency        = 0
	comboText.Position         = basePosition
	comboText.Size             = scaledSize(0.85)

	startShakeLoop()
	startGlowPulse()

	local punchScale = getPunchScale(comboCount, isMilestone)

	activeThread = task.spawn(function()
		-- Pop "gendut": melebar (X) & sedikit gepeng (Y) dulu, bukan
		-- langsung membesar proporsional -- kesan lebih hidup/bouncy tiap
		-- combo naik.
		local punchTween = TweenService:Create(
			comboText,
			TweenInfo.new(PUNCH_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = nonUniformSize(punchScale * GENDUT_X, punchScale * GENDUT_Y) }
		)
		table.insert(activeTweens, punchTween)
		punchTween:Play()
		punchTween.Completed:Wait()

		local restScale = getRestScale(comboCount)
		local settleTween = TweenService:Create(
			comboText,
			TweenInfo.new(SETTLE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = scaledSize(restScale) }
		)
		table.insert(activeTweens, settleTween)
		settleTween:Play()

		if isMilestone then
			-- Glow loop juga nargetin stroke.Thickness -- hentikan sebentar
			-- biar gak rebutan sama pop milestone, lanjut lagi sesudahnya.
			stopGlowPulse()

			stroke.Thickness = BASE_STROKE_THICKNESS * MILESTONE_STROKE_MULT
			local strokeSettleTween = TweenService:Create(
				stroke,
				TweenInfo.new(MILESTONE_STROKE_SETTLE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Thickness = BASE_STROKE_THICKNESS }
			)
			table.insert(activeTweens, strokeSettleTween)
			strokeSettleTween:Play()
			strokeSettleTween.Completed:Wait()

			if comboText.Visible then
				startGlowPulse()
			end
		end

		activeThread = nil
	end)

	-- Timer Auto-Hide saat Idle
	currentComboId += 1
	local myComboId = currentComboId

	if hideThread then
		task.cancel(hideThread)
		hideThread = nil
	end

	hideThread = task.spawn(function()
		task.wait(HIDE_AFTER_IDLE)
		if myComboId == currentComboId then
			hideComboText()
		end
	end)
end

-- ================================================================
-- REMOTE EVENT LISTENER
-- ================================================================
attackResultEvent.OnClientEvent:Connect(function(actionType, success, comboCount)
	if actionType ~= "comboUpdate" or not success then return end

	if comboCount and comboCount >= 2 then
		showComboText(comboCount)
	else
		currentComboId += 1
		if hideThread then
			task.cancel(hideThread)
			hideThread = nil
		end
		if comboText.Visible then
			hideComboText()
		end
	end
end)

print("[ComboTextClient] Berhasil diinisialisasi")