-- @ScriptType: LocalScript
--[[
    Nama File  : DodgeTextClient
    Layer      : Client (UI)
    Name       : Yusuf Kece
    Deskripsi  : Menampilkan teks "DODGE!" saat dodge berhasil.
                 Animasi: slide-in, scale punch, micro-shake, hold, fade-out.

    Dependensi :
        - ReplicatedStorage > Remotes > AttackResultEvent
        - PlayerGui > BattleUI > DodgeText (TextLabel)
]]

-- ================================================================
-- SERVICES
-- ================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")


-- ================================================================
-- REFERENCES
-- ================================================================

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local attackResultEvent = ReplicatedStorage
	:WaitForChild("Remotes")
	:WaitForChild("AttackResultEvent")

local battleUI = playerGui:WaitForChild("BattleUI")
local dodgeText = battleUI:WaitForChild("DodgeText")


-- ================================================================
-- VISUAL SETUP
-- ================================================================

dodgeText.Font = Enum.Font.GothamBlack
dodgeText.TextColor3 = Color3.fromRGB(255, 230, 80)
dodgeText.TextScaled = true

local stroke = dodgeText:FindFirstChildOfClass("UIStroke")

if not stroke then
	stroke = Instance.new("UIStroke")
	stroke.Parent = dodgeText
end

stroke.Thickness = 3
stroke.Color = Color3.fromRGB(120, 20, 20)
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual


-- ================================================================
-- STATE & CONFIGURATION
-- ================================================================

-- Base position/size aslinya ambil langsung dari GUI Instance (diatur di
-- Studio). Ditambah offset + boost di sini biar gak perlu bongkar Studio
-- tiap mau tuning ukuran/posisi -- geser NUDGE_X buat kanan/kiri, naikin
-- SIZE_BOOST buat gedein semua tahap animasi (slide-in, punch, settle).
local NUDGE_X = -55     -- (+) = geser ke kanan, (-) = ke kiri
local NUDGE_Y = 40        -- (+) = turun, (-) = naik
local SIZE_BOOST = 0.75  -- 1.0 = ukuran asli Studio

local rawSize = dodgeText.Size
local basePosition = dodgeText.Position + UDim2.new(0, NUDGE_X, 0, NUDGE_Y)
local baseSize = UDim2.new(
	rawSize.X.Scale * SIZE_BOOST, rawSize.X.Offset * SIZE_BOOST,
	rawSize.Y.Scale * SIZE_BOOST, rawSize.Y.Offset * SIZE_BOOST
)

local SLIDE_OFFSET = UDim2.new(0, -40, 0, 0)
local PUNCH_SCALE = 1.25

local PUNCH_TIME = 0.12
local SETTLE_TIME = 0.1

local SHAKE_MAGNITUDE = 4
local SHAKE_DURATION = 0.15

local HOLD_TIME = 0.35
local FADE_DURATION = 0.35

-- Getar pendek & lebih kasar tepat sebelum teks hilang -- kesan "disentil"
-- sebelum lenyap, beda dari micro-shake pas muncul (SHAKE_MAGNITUDE) yang
-- lebih halus.
local EXIT_SHAKE_MAGNITUDE = 7
local EXIT_SHAKE_DURATION = 0.18

-- Dua kualitas dodge dibedakan lewat teks & warna, bukan cuma "ada/nggak
-- ada teks". Perfect dodge harus kebaca sebagai pencapaian yang beda kelas
-- dari dodge biasa -- dia yang dikasih flourish kamera + hadiah energi +
-- stagger ke lawan (lihat CombatController.resolveHit).
local DODGE_STYLES = {
	normal = {
		text        = "DODGE!",
		textColor   = Color3.fromRGB(255, 230, 80),  -- kuning
		strokeColor = Color3.fromRGB(120, 20, 20),
	},
	perfect = {
		text        = "PERFECT!",
		textColor   = Color3.fromRGB(120, 245, 255), -- cyan terang
		strokeColor = Color3.fromRGB(20, 60, 120),
	},
	read = {
		text        = "KEBACA!",
		textColor   = Color3.fromRGB(255, 110, 90), -- merah
		strokeColor = Color3.fromRGB(90, 15, 15),
	},
}

local activeThread = nil
local activeTweens = {}


-- ================================================================
-- HELPERS
-- ================================================================

local function scaledSize(factor)
	return UDim2.new(
		baseSize.X.Scale * factor,
		baseSize.X.Offset * factor,
		baseSize.Y.Scale * factor,
		baseSize.Y.Offset * factor
	)
end

local function cancelActiveTweens()
	for _, tween in activeTweens do
		tween:Cancel()
	end

	table.clear(activeTweens)
end

local function createTween(instance, tweenInfo, properties)
	local tween = TweenService:Create(instance, tweenInfo, properties)
	table.insert(activeTweens, tween)

	return tween
end


-- ================================================================
-- DODGE TEXT
-- ================================================================

local function showDodgeText(styleName)
	-- Hentikan sequence sebelumnya jika Dodge dipicu kembali.
	if activeThread then
		task.cancel(activeThread)
		activeThread = nil
	end

	cancelActiveTweens()

	-- Teks & warna di-set tiap kali dipanggil (bukan sekali di setup),
	-- karena label yang sama dipakai ulang buat dua gaya yang berbeda.
	local style = DODGE_STYLES[styleName] or DODGE_STYLES.normal
	dodgeText.Text = style.text
	dodgeText.TextColor3 = style.textColor
	stroke.Color = style.strokeColor

	activeThread = task.spawn(function()
		-- --------------------------------------------------------
		-- INITIAL STATE
		-- --------------------------------------------------------

		dodgeText.Visible = true
		dodgeText.TextTransparency = 0
		stroke.Transparency = 0

		dodgeText.Position = basePosition + SLIDE_OFFSET
		dodgeText.Size = scaledSize(0.6)


		-- --------------------------------------------------------
		-- 1. PUNCH
		-- Slide ke posisi asli + overshoot scale.
		-- --------------------------------------------------------

		local punchTween = createTween(
			dodgeText,
			TweenInfo.new(
				PUNCH_TIME,
				Enum.EasingStyle.Back,
				Enum.EasingDirection.Out
			),
			{
				Position = basePosition,
				Size = scaledSize(PUNCH_SCALE)
			}
		)

		punchTween:Play()
		punchTween.Completed:Wait()


		-- --------------------------------------------------------
		-- 2. SETTLE
		-- Kembalikan ukuran ke ukuran normal.
		-- --------------------------------------------------------

		local settleTween = createTween(
			dodgeText,
			TweenInfo.new(
				SETTLE_TIME,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			),
			{
				Size = baseSize
			}
		)

		settleTween:Play()


		-- --------------------------------------------------------
		-- 3. MICRO SHAKE
		-- --------------------------------------------------------

		local shakeElapsed = 0
		local shakeStep = 1 / 30

		while shakeElapsed < SHAKE_DURATION do
			local falloff = 1 - (shakeElapsed / SHAKE_DURATION)

			local offsetX =
				(math.random() - 0.5)
				* 2
				* SHAKE_MAGNITUDE
				* falloff

			local offsetY =
				(math.random() - 0.5)
				* 2
				* SHAKE_MAGNITUDE
				* falloff

			dodgeText.Position = basePosition
				+ UDim2.new(0, offsetX, 0, offsetY)

			task.wait(shakeStep)
			shakeElapsed += shakeStep
		end

		dodgeText.Position = basePosition


		-- --------------------------------------------------------
		-- 4. HOLD
		-- --------------------------------------------------------

		task.wait(HOLD_TIME)


		-- --------------------------------------------------------
		-- 4b. EXIT SHAKE (getar dulu sebelum ilang, kayak "disentil")
		-- --------------------------------------------------------

		local exitShakeElapsed = 0
		local exitShakeStep = 1 / 30

		while exitShakeElapsed < EXIT_SHAKE_DURATION do
			local falloff = 1 - (exitShakeElapsed / EXIT_SHAKE_DURATION)

			local offsetX =
				(math.random() - 0.5)
				* 2
				* EXIT_SHAKE_MAGNITUDE
				* falloff

			local offsetY =
				(math.random() - 0.5)
				* 2
				* EXIT_SHAKE_MAGNITUDE
				* falloff

			dodgeText.Position = basePosition
				+ UDim2.new(0, offsetX, 0, offsetY)

			task.wait(exitShakeStep)
			exitShakeElapsed += exitShakeStep
		end

		dodgeText.Position = basePosition


		-- --------------------------------------------------------
		-- 5. FADE OUT
		-- --------------------------------------------------------

		local fadeTween = createTween(
			dodgeText,
			TweenInfo.new(
				FADE_DURATION,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.In
			),
			{
				TextTransparency = 1
			}
		)

		local strokeFadeTween = createTween(
			stroke,
			TweenInfo.new(
				FADE_DURATION,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.In
			),
			{
				Transparency = 1
			}
		)

		fadeTween:Play()
		strokeFadeTween:Play()

		fadeTween.Completed:Wait()


		-- --------------------------------------------------------
		-- RESET
		-- --------------------------------------------------------

		dodgeText.Visible = false
		dodgeText.Position = basePosition
		dodgeText.Size = baseSize

		activeThread = nil
		table.clear(activeTweens)
	end)
end


-- ================================================================
-- EVENT
-- ================================================================

attackResultEvent.OnClientEvent:Connect(function(actionType, success)
	if not success then return end

	if actionType == "perfectDodge" then
		showDodgeText("perfect")
	elseif actionType == "perfectDodgeHit" then
		showDodgeText("read")
	elseif actionType == "dodgeSuccess" then
		showDodgeText("normal")
	end
end)

print("[DodgeTextClient] Berhasil diinisialisasi")