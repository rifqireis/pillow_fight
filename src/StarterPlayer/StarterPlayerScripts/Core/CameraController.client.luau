-- @ScriptType: LocalScript
--[[
    Nama File : CameraController
    Layer     : Client (Camera)

    Deskripsi :
    Mengunci kamera menghadap lawan selama match (camera lock), memberi
    camera shake saat impact, head-follow saat terkena hit, attack camera,
    dodge feedback, FFYL feedback, KO feedback, FALLEN_CAM saat kalah
    ronde, dan BLINK transition saat bangkit.

    FLOW FALLEN CAM:
        kalah ronde / FFYL -> FALLEN_CAM aktif -> kamera bergerak ke
        depan wajah sendiri -> kamera mengikuti Head -> event "rise"
        -> BLINK -> layar hitam penuh -> kamera kembali ke posisi lock
        tengah -> layar dibuka kembali.
        Jika "rise" tidak datang, FALLEN_CAM.HOLD_DURATION jadi fallback
        otomatis untuk memicu BLINK.

    FLOW ATTACKER FEEDBACK (v1.6):
        mulai attack -> SWING (hanya kick, tanpa shake, karena serangan
        belum tentu kena) -> server confirm hit -> CONFIRM (shake + kick)
        -> hitstop.
        Kalau serangan meleset, tidak ada shake sama sekali - hanya kick
        kecil di awal serangan.

    Penulis  : Yusuf Ahayy
    Tanggal  : 15 Agustus 2026
    Versi    : 1.6
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local TweenService      = game:GetService("TweenService")

local CameraConfig   = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("CameraConfig"))
local GameplayConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("GameplayConfig"))

local LOCK           = CameraConfig.LOCK
local SHAKE          = CameraConfig.SHAKE
local KICK           = CameraConfig.KICK
local HITSTOP        = CameraConfig.HITSTOP
local HEAD_FOLLOW    = CameraConfig.HEAD_FOLLOW
local ATTACK_CAM     = CameraConfig.ATTACK_CAM
local DODGE_FEEDBACK = CameraConfig.DODGE_FEEDBACK
local FFYL_FEEDBACK  = CameraConfig.FFYL_FEEDBACK
local KO_FEEDBACK    = CameraConfig.KO_FEEDBACK
local FFYL_SWAY      = CameraConfig.FFYL_SWAY
local IDLE_SWAY      = CameraConfig.IDLE_SWAY
local FALLEN_CAM     = CameraConfig.FALLEN_CAM
local BLINK          = CameraConfig.BLINK

local PILLOW_TOOL_NAME = GameplayConfig.PILLOW_TOOL_NAME or "Pillow"

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")

local attackResultEvent   = remotes:WaitForChild("AttackResultEvent")
local syncMatchStateEvent = remotes:WaitForChild("SyncMatchStateEvent")
local syncOpponentEvent   = remotes:WaitForChild("SyncOpponentEvent", 15)
local localAnimEvent      = script.Parent:WaitForChild("LocalAnimEvent")
local ffylStateEvent      = remotes:WaitForChild("FFYLStateEvent")
local koEvent              = remotes:WaitForChild("KOEvent", 15)

-- ================================================================
-- STATE
-- ================================================================

local camera = Workspace.CurrentCamera

local isLocked       = false
local opponentPlayer = nil
local smoothedCFrame = nil

local trauma     = 0
local headTrauma = 0
local restHeadOffset = nil

local defaultFOV = camera.FieldOfView
local noiseSeed  = math.random() * 1000

-- Fallen camera
local hasFallen    = false
local fallenCFrame = nil
local fallenToken  = 0 -- membatalkan timer FALLEN_CAM lama

-- Blink
local blinkGui   = nil
local blinkFrame = nil
local blinkToken = 0 -- membatalkan blink lama

-- Camera effects
local effectClock = 0

local kickPos, kickVel = Vector3.zero, Vector3.zero
local kickAngle, kickAngVel = Vector3.zero, Vector3.zero

local hitstopUntil = 0

-- Slowmo cancel tracking (dodge/FFYL/KO slowmo)
-- slowmoTokens[character]     = generation counter. Naik tiap kali slowmo
--                                baru DIPICU atau DIBATALKAN buat karakter
--                                itu -- revert/listener dari sesi lama jadi
--                                otomatis no-op begitu token-nya beda.
-- trackOriginalSpeed[track]   = speed ASLI track itu (biasanya 1), disimpen
--                                SEKALI doang pas pertama kali kena modifikasi
--                                APAPUN (slowmo ATAU hitstop). Ini SATU-
--                                SATUNYA sumber "speed asli" yang dipakai
--                                BARENG oleh slowmo & hitstop, biar dua
--                                sistem itu gak rebutan/nimpa nilai originalnya
--                                masing-masing (itu penyebab animasi "skip").
-- activeSlowFactor[character] = faktor slowmo yang lagi aktif SEKARANG buat
--                                karakter itu (nil = gak ada slowmo aktif).
-- frozenTracksSet[track]      = karakter PEMILIK track itu selama dia lagi
--                                di-hitstop-freeze (nil = lagi gak di-freeze).
--                                Yang disimpen pemiliknya, bukan sekadar
--                                `true`, karena sekarang track LAWAN ikut
--                                di-freeze juga -- pas dilepas nanti, tiap
--                                track harus dibalikin pakai activeSlowFactor
--                                milik karakternya SENDIRI. Kalau semuanya
--                                dibalikin pakai player.Character (kayak dulu),
--                                track lawan bakal ngambil slow factor punya
--                                local player -- salah owner, speed-nya ngaco.
local slowmoTokens = setmetatable({}, { __mode = "k" })
local trackOriginalSpeed = setmetatable({}, { __mode = "k" })
local activeSlowFactor = setmetatable({}, { __mode = "k" })
local frozenTracksSet = setmetatable({}, { __mode = "k" })

-- Ambil speed asli track (sebelum disentuh slowmo/hitstop manapun).
-- Kalau belum pernah kesentuh sama sekali, track.Speed SEKARANG pasti
-- masih speed asli -- disimpen sekali di sini biar sistem lain (siapapun
-- yang nyentuh duluan) selalu ngambil dari sumber yang sama ini.
local function getTrueOriginalSpeed(track)
	local original = trackOriginalSpeed[track]
	if original == nil then
		original = track.Speed
		trackOriginalSpeed[track] = original
	end
	return original
end

-- Hitung & terapkan speed yang SEHARUSNYA buat track ini SEKARANG,
-- berdasarkan state hitstop & slowmo TERKINI -- bukan berdasarkan speed
-- track saat ini (yang bisa aja udah beda-beda tergantung urutan sistem
-- mana yang nyentuh duluan). Freeze (hitstop) prioritas tertinggi: kalau
-- lagi freeze, speed SELALU 0, gak peduli slowmo lagi aktif atau enggak.
-- Kalau enggak lagi freeze, speed ngikutin slowmo (kalau ada) atau balik
-- ke speed asli. Ini yang bikin dua sistem itu gak bisa saling nimpa
-- "original speed" versi masing-masing lagi.
local function applyTrackSpeed(character, track)
	local original = getTrueOriginalSpeed(track)

	if frozenTracksSet[track] then
		track:AdjustSpeed(0)
		return
	end

	local factor = character and activeSlowFactor[character]
	track:AdjustSpeed(factor and (original * factor) or original)
end

-- Attack camera
local attackCamZoom, attackCamTarget = 0, 0
local attackCamHoldUntil = 0
local attackCamCancelled = false
local pillowRestOffset = nil

-- Dodge camera
local dodgeZoom, dodgeZoomTarget = 0, 0
local dodgeZoomHoldUntil = 0

-- KO camera
local koZoom, koZoomTarget = 0, 0
local koBurstToken = 0

-- FFYL
local isFFYLActive = false
local ffylSwayRamp = 0
local ffylNoiseSeed = math.random() * 1000
local ffylZoom, ffylZoomTarget = 0, 0
local ffylBurstUntil = 0

-- Side mode selalu mulai dari midpoint.
local currentFocusBias = LOCK.MODE == "Side" and 0.5 or LOCK.AIM_BIAS

-- Idle sway
local idleSwayRamp = 0
local idleNoiseSeed = math.random() * 1000

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if Workspace.CurrentCamera then
		camera = Workspace.CurrentCamera
		smoothedCFrame = nil
	end
end)

-- ================================================================
-- HELPER FUNCTIONS
-- ================================================================

local function getRoot(targetPlayer)
	local character = targetPlayer and targetPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- ================================================================
-- BLINK GUI
-- ================================================================

local function ensureBlinkGui()
	if blinkFrame then return end

	local playerGui = player:WaitForChild("PlayerGui")

	blinkGui = Instance.new("ScreenGui")
	blinkGui.Name = "CameraBlinkGui"
	blinkGui.IgnoreGuiInset = true
	blinkGui.DisplayOrder = 1000
	blinkGui.ResetOnSpawn = false
	blinkGui.Parent = playerGui

	blinkFrame = Instance.new("Frame")
	blinkFrame.Name = "Blink"
	blinkFrame.Size = UDim2.fromScale(1, 1)
	blinkFrame.Position = UDim2.fromScale(0, 0)
	blinkFrame.BackgroundColor3 = Color3.new(0, 0, 0)
	blinkFrame.BorderSizePixel = 0
	blinkFrame.BackgroundTransparency = 1
	blinkFrame.ZIndex = 1000
	blinkFrame.Parent = blinkGui
end

-- ================================================================
-- RESET CAMERA EFFECTS
-- ================================================================

local function resetCameraEffects(preserveFallenState)
	trauma, headTrauma = 0, 0
	restHeadOffset = nil

	attackCamZoom, attackCamTarget = 0, 0
	attackCamCancelled = false
	attackCamHoldUntil = 0

	dodgeZoom, dodgeZoomTarget = 0, 0
	dodgeZoomHoldUntil = 0

	koZoom, koZoomTarget = 0, 0
	koBurstToken = koBurstToken + 1

	pillowRestOffset = nil

	isFFYLActive = false
	ffylSwayRamp = 0
	ffylZoom, ffylZoomTarget = 0, 0
	ffylBurstUntil = 0

	idleSwayRamp = 0

	-- Kalau lagi mid-transisi FALLEN_CAM/BLINK (mis. event "rise" dan
	-- SyncMatchStateEvent(false) datang hampir bersamaan saat ganti ronde),
	-- JANGAN sentuh hasFallen/fallenCFrame/blinkToken di sini. Kalau tetap
	-- dipaksa reset, blink yang sedang jalan langsung batal padahal layar
	-- belum sempat menghitam -- kamera jadi kelihatan nyentak/glitch alih-
	-- alih ketutup blink dengan mulus. Biarkan blink/fallback timer-nya
	-- sendiri yang membereskan state ini di waktu yang tepat.
	if preserveFallenState then
		return
	end

	-- Fallen camera
	hasFallen = false
	fallenCFrame = nil
	fallenToken = fallenToken + 1 -- batalkan semua timer FALLEN_CAM lama

	-- Blink
	blinkToken = blinkToken + 1
	if blinkFrame then
		blinkFrame.BackgroundTransparency = 1
	end
end

-- ================================================================
-- SHAKE
-- ================================================================

local function addTrauma(amount)
	if not SHAKE.ENABLED or not amount or amount <= 0 then return end
	trauma = math.min(trauma + amount, SHAKE.MAX_TRAUMA)
end

-- ================================================================
-- OPPONENT DIRECTION
-- ================================================================

local function getOpponentLocalDir()
	local selfRoot = getRoot(player)
	if not selfRoot then return nil end

	local opponentRoot = getRoot(opponentPlayer)
	local worldDir = opponentRoot
		and (opponentRoot.Position - selfRoot.Position)
		or selfRoot.CFrame.LookVector

	worldDir = Vector3.new(worldDir.X, 0, worldDir.Z)
	if worldDir.Magnitude < 0.01 then return nil end

	return camera.CFrame:VectorToObjectSpace(worldDir.Unit)
end

-- ================================================================
-- IMPACT KICK
-- ================================================================

local function addKick(presetName)
	if not KICK.ENABLED then return end

	local preset = KICK.PRESETS[presetName]
	if not preset then return end

	local localDir = getOpponentLocalDir() or Vector3.new(1, 0, 0)
	local sideSign = localDir.X >= 0 and 1 or -1

	kickPos = kickPos
		+ localDir * (preset.PUSH or 0)
		+ Vector3.new(0, preset.LIFT or 0, preset.DOLLY or 0)

	kickAngle = kickAngle
		+ Vector3.new(preset.PITCH or 0, 0, (preset.ROLL or 0) * sideSign)

	if kickPos.Magnitude > KICK.MAX_OFFSET then
		kickPos = kickPos.Unit * KICK.MAX_OFFSET
	end

	if kickAngle.Magnitude > KICK.MAX_ANGLE then
		kickAngle = kickAngle.Unit * KICK.MAX_ANGLE
	end
end

local function updateKick(deltaTime)
	if not KICK.ENABLED then return end

	if kickPos.Magnitude < 0.0005 and kickVel.Magnitude < 0.0005
		and kickAngle.Magnitude < 0.0005 and kickAngVel.Magnitude < 0.0005 then
		kickPos, kickVel = Vector3.zero, Vector3.zero
		kickAngle, kickAngVel = Vector3.zero, Vector3.zero
		return
	end

	local remaining = math.min(deltaTime, 0.1)

	while remaining > 0 do
		local step = math.min(remaining, 1 / 120)
		remaining = remaining - step

		kickVel = kickVel + (-KICK.STIFFNESS * kickPos - KICK.DAMPING * kickVel) * step
		kickPos = kickPos + kickVel * step

		kickAngVel = kickAngVel + (-KICK.STIFFNESS * kickAngle - KICK.DAMPING * kickAngVel) * step
		kickAngle = kickAngle + kickAngVel * step
	end
end

local function getKickOffset()
	if not KICK.ENABLED then return nil end
	if kickPos.Magnitude < 0.0005 and kickAngle.Magnitude < 0.0005 then return nil end

	return CFrame.new(kickPos)
		* CFrame.Angles(math.rad(kickAngle.X), math.rad(kickAngle.Y), math.rad(kickAngle.Z))
end

local function resetKick()
	kickPos, kickVel = Vector3.zero, Vector3.zero
	kickAngle, kickAngVel = Vector3.zero, Vector3.zero
end

-- ================================================================
-- HITSTOP
-- ================================================================

-- Bekukan semua track yang lagi jalan di SATU karakter. Dipakai buat
-- karakter sendiri maupun karakter lawan -- sama persis kayak
-- applySlowmoToCharacter yang emang udah nyentuh dua-duanya.
--
-- Nyentuh AnimationTrack milik pemain lain dari client ini aman: yang
-- berubah cuma playback speed LOKAL (client ini gak punya authority atas
-- animator pemain lain, jadi gak ada yang direplikasi balik). Persis itu
-- yang kita mau -- hitstop murni efek visual di layar masing-masing.
local function freezeCharacterAnimations(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if not frozenTracksSet[track] then
			frozenTracksSet[track] = character
			-- applyTrackSpeed bakal langsung nge-set ke 0 karena track ini
			-- sekarang udah masuk frozenTracksSet -- dan speed asli/faktor
			-- slowmo-nya (kalau ada) TETAP kesimpen utuh buat dipulihin
			-- nanti pas releaseAnimations, gak ketimpa.
			applyTrackSpeed(character, track)
		end
	end
end

local function releaseAnimations()
	-- Balikin ke speed yang SEHARUSNYA sekarang -- kalau slowmo masih
	-- aktif buat karakter ini (belum revert), track lanjut di speed
	-- ter-slow itu (bukan langsung full speed), baru bener-bener balik
	-- normal pas slowmo-nya sendiri yang revert. Kalau slowmo udah
	-- kelar duluan, langsung balik speed asli.
	--
	-- `owner` dibaca per-track (bukan pakai player.Character buat semua)
	-- supaya track lawan dibalikin pakai slow factor punya lawan sendiri.
	for track, owner in pairs(frozenTracksSet) do
		frozenTracksSet[track] = nil
		-- pcall: track-nya bisa aja udah kedestroy duluan (mis. pemiliknya
		-- respawn di tengah hitstop).
		pcall(function() applyTrackSpeed(owner, track) end)
	end
end

-- isImpact = momen yang melibatkan DUA karakter sekaligus (hit confirm &
-- kena hit). Cuma di momen itu lawan ikut dibekukan; hitstop personal
-- (stun/fall) tetap sendirian. Lihat CameraConfig.HITSTOP.FREEZE_OPPONENT.
local function beginHitstop(duration, isImpact)
	if not HITSTOP.ENABLED or not duration or duration <= 0 then return end

	local capped = math.min(duration, HITSTOP.MAX_DURATION)
	hitstopUntil = math.max(hitstopUntil, os.clock() + capped)

	if not HITSTOP.FREEZE_ANIMATION then return end

	freezeCharacterAnimations(player.Character)

	if isImpact and HITSTOP.FREEZE_OPPONENT then
		freezeCharacterAnimations(opponentPlayer and opponentPlayer.Character)
	end
end

local function clearHitstop()
	hitstopUntil = 0
	releaseAnimations()
end

-- ================================================================
-- HEAD FOLLOW
-- ================================================================

local function addHeadTrauma(amount)
	if not HEAD_FOLLOW.ENABLED or not amount or amount <= 0 then return end
	headTrauma = math.min(headTrauma + amount, HEAD_FOLLOW.MAX_TRAUMA)
end

local function getHeadFollowOffset(character)
	if not HEAD_FOLLOW.ENABLED or headTrauma <= 0.001 then
		restHeadOffset = nil
		return nil
	end

	local root = character and character:FindFirstChild("HumanoidRootPart")
	local head = character and character:FindFirstChild("Head")
	if not root or not head then return nil end

	local currentOffset = root.CFrame:ToObjectSpace(head.CFrame).Position

	if not restHeadOffset then
		restHeadOffset = currentOffset
		return nil
	end

	local localDelta = currentOffset - restHeadOffset
	local worldDelta = root.CFrame:VectorToWorldSpace(localDelta)
	worldDelta = worldDelta * HEAD_FOLLOW.INTENSITY * math.sqrt(headTrauma)

	if worldDelta.Magnitude > HEAD_FOLLOW.MAX_OFFSET then
		worldDelta = worldDelta.Unit * HEAD_FOLLOW.MAX_OFFSET
	end

	return worldDelta
end

-- ================================================================
-- SLOWMO
-- ================================================================

local function applySlowmoToCharacter(character, factor, duration)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end

	-- Sesi slowmo baru buat karakter ini -- generasi ini yang bakal
	-- divalidasi belakangan di revert/listener supaya sesi LAMA (kalau ada
	-- sisa) nggak bisa nimpa/numpuk sesi ini.
	local myToken = (slowmoTokens[character] or 0) + 1
	slowmoTokens[character] = myToken

	-- Faktor ini disimpen per-KARAKTER (bukan per-track) -- applyTrackSpeed
	-- baca dari sini, jadi hitstop yang lagi/bakal freeze track yang sama
	-- otomatis tau harus balikin ke speed ter-slow ini, bukan speed penuh,
	-- begitu freeze-nya lepas duluan sebelum slowmo ini kelar.
	activeSlowFactor[character] = factor

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		applyTrackSpeed(character, track)
	end

	local WATCH_WINDOW = 0.4
	local connection

	connection = animator.AnimationPlayed:Connect(function(track)
		if slowmoTokens[character] ~= myToken then return end
		applyTrackSpeed(character, track)
	end)

	task.delay(WATCH_WINDOW, function()
		if connection and connection.Connected then
			connection:Disconnect()
		end
	end)

	task.delay(duration, function()
		-- Kalau udah ada sesi slowmo/cancel yang lebih baru buat karakter
		-- ini, revert dari sesi lama ini SKIP -- biar gak nimpa state yang
		-- udah di-set sama sesi terbaru.
		if slowmoTokens[character] ~= myToken then return end

		activeSlowFactor[character] = nil

		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			applyTrackSpeed(character, track)
		end
	end)
end

-- Batalin slowmo yang lagi aktif di satu karakter, RIGHT NOW -- dipanggil
-- pas ada input baru (attack/dodge) dari pemiliknya, atau pas karakter itu
-- kena damage. Beda sama nunggu `duration` abis sendiri: ini instan &
-- eksplisit, jadi animasi lanjut jalan di speed normal seketika itu juga.
local function cancelSlowmoForCharacter(character)
	if not character then return end

	-- Naikin token duluan -- bikin semua revert timer & AnimationPlayed
	-- listener dari sesi sebelumnya jadi no-op otomatis.
	slowmoTokens[character] = (slowmoTokens[character] or 0) + 1
	activeSlowFactor[character] = nil

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		applyTrackSpeed(character, track)
	end
end

-- ================================================================
-- FFYL FEEDBACK
-- ================================================================

local function triggerFFYLBurst()
	if not FFYL_FEEDBACK or not FFYL_FEEDBACK.ENABLED then return end

	ffylZoomTarget = FFYL_FEEDBACK.ZOOM_IN_DISTANCE
	ffylBurstUntil = effectClock + FFYL_FEEDBACK.SLOWMO_DURATION

	applySlowmoToCharacter(player.Character, FFYL_FEEDBACK.SLOWMO_SPEED, FFYL_FEEDBACK.SLOWMO_DURATION)
end

-- ================================================================
-- KO FEEDBACK
-- ================================================================

local KO_SLOWMO_DELAY = 1.4

local function triggerKOFeedback()
	if not KO_FEEDBACK or not KO_FEEDBACK.ENABLED then return end

	koZoomTarget = KO_FEEDBACK.ZOOM_DISTANCE
	koBurstToken = koBurstToken + 1
	local myToken = koBurstToken

	task.delay(KO_SLOWMO_DELAY, function()
		if myToken ~= koBurstToken then return end

		applySlowmoToCharacter(player.Character, KO_FEEDBACK.SLOWMO_SPEED, KO_FEEDBACK.SLOWMO_DURATION)
		applySlowmoToCharacter(
			opponentPlayer and opponentPlayer.Character,
			KO_FEEDBACK.SLOWMO_SPEED,
			KO_FEEDBACK.SLOWMO_DURATION
		)
	end)
end

-- ================================================================
-- DODGE FEEDBACK
-- ================================================================

-- quality = "PERFECT" | "NORMAL". Dua-duanya dapat slow-mo, tapi beda
-- kedalaman & durasi -- lihat CameraConfig.DODGE_FEEDBACK.
local function triggerDodgeFeedback(quality)
	if not DODGE_FEEDBACK or not DODGE_FEEDBACK.ENABLED then return end
	if isFFYLActive then return end

	local tier = DODGE_FEEDBACK[quality] or DODGE_FEEDBACK.NORMAL
	if not tier then return end

	local duration = tier.SLOWMO_DURATION

	dodgeZoomTarget = DODGE_FEEDBACK.ZOOM_DISTANCE * (tier.ZOOM_SCALE or 1)
	dodgeZoomHoldUntil = effectClock + duration

	applySlowmoToCharacter(player.Character, tier.SLOWMO_SPEED, duration)
	applySlowmoToCharacter(
		opponentPlayer and opponentPlayer.Character,
		tier.SLOWMO_SPEED,
		duration
	)
end

-- ================================================================
-- ATTACK CAMERA
-- ================================================================

local function triggerAttackCam(presetName)
	local preset = ATTACK_CAM and ATTACK_CAM[presetName]
	if not ATTACK_CAM or not ATTACK_CAM.ENABLED or not preset then return end

	attackCamTarget = preset.ZOOM_DISTANCE
	attackCamHoldUntil = effectClock + preset.HOLD_TIME
	attackCamCancelled = false
end

local function cancelAttackCam()
	if attackCamTarget <= 0 and attackCamZoom <= 0.001 then return end

	attackCamHoldUntil = 0
	attackCamTarget = 0
	attackCamCancelled = true
end

-- ================================================================
-- PILLOW FOLLOW
-- ================================================================

local function getPillowFollowOffset(character)
	local preset = ATTACK_CAM and ATTACK_CAM.HEAVY
	if not preset or attackCamZoom <= 0.001 then
		pillowRestOffset = nil
		return nil
	end

	local root = character and character:FindFirstChild("HumanoidRootPart")
	local tool = character and character:FindFirstChild(PILLOW_TOOL_NAME)
	local handle = tool and tool:FindFirstChild("Handle")
	if not root or not handle then return nil end

	local currentOffset = root.CFrame:ToObjectSpace(handle.CFrame).Position

	if not pillowRestOffset then
		pillowRestOffset = currentOffset
		return nil
	end

	local localDelta = currentOffset - pillowRestOffset
	local worldDelta = root.CFrame:VectorToWorldSpace(localDelta) * preset.FOLLOW_INTENSITY

	if worldDelta.Magnitude > preset.FOLLOW_MAX_OFFSET then
		worldDelta = worldDelta.Unit * preset.FOLLOW_MAX_OFFSET
	end

	return worldDelta
end

-- ================================================================
-- SHAKE OFFSET
-- ================================================================

local function getShakeOffset(clock)
	local intensity = trauma ^ 1.4
	if intensity <= 0.0001 then return nil end

	local t = clock * SHAKE.FREQUENCY

	local rx = math.noise(t, noiseSeed, 0) * 2 * math.rad(SHAKE.ROTATION.X) * intensity
	local ry = math.noise(t, noiseSeed, 1) * 2 * math.rad(SHAKE.ROTATION.Y) * intensity
	local rz = math.noise(t, noiseSeed, 2) * 2 * math.rad(SHAKE.ROTATION.Z) * intensity

	local tx = math.noise(t, noiseSeed, 3) * 2 * SHAKE.TRANSLATION.X * intensity
	local ty = math.noise(t, noiseSeed, 4) * 2 * SHAKE.TRANSLATION.Y * intensity
	local tz = math.noise(t, noiseSeed, 5) * 2 * SHAKE.TRANSLATION.Z * intensity

	return CFrame.new(tx, ty, tz) * CFrame.Angles(rx, ry, rz)
end

-- ================================================================
-- FFYL SWAY
-- ================================================================

local function updateFFYLSwayRamp(deltaTime)
	local target = isFFYLActive and 1 or 0
	local rampSpeed = FFYL_SWAY.RAMP_TIME > 0 and (1 / FFYL_SWAY.RAMP_TIME) or 999
	local alpha = math.clamp(rampSpeed * deltaTime, 0, 1)

	ffylSwayRamp = ffylSwayRamp + (target - ffylSwayRamp) * alpha
end

local function getFFYLSwayOffset(clock)
	if not FFYL_SWAY.ENABLED or ffylSwayRamp <= 0.001 then return nil end

	local t = clock * FFYL_SWAY.FREQUENCY

	local rx = math.noise(t, ffylNoiseSeed, 0) * 2 * math.rad(FFYL_SWAY.ROTATION.X) * ffylSwayRamp
	local ry = math.noise(t, ffylNoiseSeed, 1) * 2 * math.rad(FFYL_SWAY.ROTATION.Y) * ffylSwayRamp
	local rz = math.noise(t, ffylNoiseSeed, 2) * 2 * math.rad(FFYL_SWAY.ROTATION.Z) * ffylSwayRamp

	local tx = math.noise(t, ffylNoiseSeed, 3) * 2 * FFYL_SWAY.TRANSLATION.X * ffylSwayRamp
	local ty = math.noise(t, ffylNoiseSeed, 4) * 2 * FFYL_SWAY.TRANSLATION.Y * ffylSwayRamp
	local tz = math.noise(t, ffylNoiseSeed, 5) * 2 * FFYL_SWAY.TRANSLATION.Z * ffylSwayRamp

	return CFrame.new(tx, ty, tz) * CFrame.Angles(rx, ry, rz)
end

-- ================================================================
-- IDLE SWAY
-- ================================================================

local function updateIdleSwayRamp(deltaTime)
	local target = (isLocked and not hasFallen) and 1 or 0
	local rampSpeed = IDLE_SWAY.RAMP_TIME > 0 and (1 / IDLE_SWAY.RAMP_TIME) or 999
	local alpha = math.clamp(rampSpeed * deltaTime, 0, 1)

	idleSwayRamp = idleSwayRamp + (target - idleSwayRamp) * alpha
end

local function getIdleSwayOffset(clock)
	if not IDLE_SWAY.ENABLED or idleSwayRamp <= 0.001 then return nil end

	local t = clock * IDLE_SWAY.FREQUENCY

	local rx = math.noise(t, idleNoiseSeed, 0) * 2 * math.rad(IDLE_SWAY.ROTATION.X) * idleSwayRamp
	local ry = math.noise(t, idleNoiseSeed, 1) * 2 * math.rad(IDLE_SWAY.ROTATION.Y) * idleSwayRamp
	local rz = math.noise(t, idleNoiseSeed, 2) * 2 * math.rad(IDLE_SWAY.ROTATION.Z) * idleSwayRamp

	local tx = math.noise(t, idleNoiseSeed, 3) * 2 * IDLE_SWAY.TRANSLATION.X * idleSwayRamp
	local ty = math.noise(t, idleNoiseSeed, 4) * 2 * IDLE_SWAY.TRANSLATION.Y * idleSwayRamp
	local tz = math.noise(t, idleNoiseSeed, 5) * 2 * IDLE_SWAY.TRANSLATION.Z * idleSwayRamp

	return CFrame.new(tx, ty, tz) * CFrame.Angles(rx, ry, rz)
end

-- ================================================================
-- NORMAL CAMERA LOCK
-- ================================================================

local function computeLockCFrame()
	local selfRoot = getRoot(player)
	if not selfRoot then return nil end

	local heightOffset = Vector3.new(0, LOCK.FOCUS_HEIGHT, 0)
	local selfPos = selfRoot.Position + heightOffset

	local opponentRoot = getRoot(opponentPlayer)
	local targetPos = opponentRoot
		and (opponentRoot.Position + heightOffset)
		or (selfPos + selfRoot.CFrame.LookVector * LOCK.FALLBACK_DISTANCE)

	local flatDir = Vector3.new(targetPos.X - selfPos.X, 0, targetPos.Z - selfPos.Z)

	if flatDir.Magnitude < 0.01 then
		flatDir = selfRoot.CFrame.LookVector * Vector3.new(1, 0, 1)
		if flatDir.Magnitude < 0.01 then return nil end
	end

	flatDir = flatDir.Unit
	local rightDir = Vector3.new(-flatDir.Z, 0, flatDir.X)

	if LOCK.MODE == "Side" then
		local midPos = selfPos:Lerp(targetPos, currentFocusBias)
		local camPos = midPos + rightDir * LOCK.SIDE_DISTANCE + Vector3.new(0, LOCK.SIDE_HEIGHT, 0)

		return CFrame.lookAt(camPos, midPos)
	end

	local focusPos = selfPos:Lerp(targetPos, currentFocusBias)
	local camPos = selfPos
	- flatDir * LOCK.DISTANCE
		+ Vector3.new(0, LOCK.HEIGHT, 0)
		+ rightDir * LOCK.SHOULDER_OFFSET

	return CFrame.lookAt(camPos, focusPos)
end

-- ================================================================
-- FALLEN CAMERA
-- ================================================================

-- Kamera ditempatkan di depan wajah (HEAD ---> CAMERA), lalu kamera
-- melihat kembali ke HEAD.
local function getFallenCamCFrame(head)
	local lookVector = head.CFrame.LookVector
	local heightOffset = Vector3.new(0, FALLEN_CAM.HEIGHT, 0)

	local camPos = head.Position + lookVector * FALLEN_CAM.DISTANCE + heightOffset
	local focusPos = head.Position + heightOffset

	return CFrame.lookAt(camPos, focusPos)
end

-- Forward declaration: dibutuhkan karena beginFallenCamera() dapat
-- memanggil triggerRiseBlink().
local triggerRiseBlink

local function beginFallenCamera()
	if not FALLEN_CAM.ENABLED then
		hasFallen = true
		return
	end

	-- Kalau sudah FALLEN_CAM, jangan restart timer (fall + KOEvent
	-- bisa saja datang berdekatan).
	if hasFallen then return end

	hasFallen = true
	fallenCFrame = nil
	fallenToken = fallenToken + 1
	local myToken = fallenToken

	local holdDuration = FALLEN_CAM.HOLD_DURATION or 2

	-- Fallback timer: idealnya event "rise" datang dari server, tapi
	-- kalau terlambat/tidak ada, kamera tidak boleh nyangkut selamanya.
	task.delay(holdDuration, function()
		if myToken ~= fallenToken then return end
		if not hasFallen then return end

		triggerRiseBlink()
	end)
end

-- ================================================================
-- SET CAMERA LOCK
-- ================================================================

local function setLocked(state)
	if state == isLocked then return end
	isLocked = state

	if state then
		defaultFOV = camera.FieldOfView
		camera.CameraType = Enum.CameraType.Scriptable
		currentFocusBias = LOCK.MODE == "Side" and 0.5 or LOCK.AIM_BIAS
		smoothedCFrame = computeLockCFrame() or camera.CFrame

		if LOCK.FOV then
			camera.FieldOfView = LOCK.FOV
		end
	else
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = defaultFOV
		smoothedCFrame = nil

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

-- ================================================================
-- RISE BLINK
-- ================================================================

triggerRiseBlink = function()
	-- Jangan blink kalau player tidak sedang FALLEN_CAM.
	if not hasFallen then return end

	fallenToken = fallenToken + 1 -- batalkan timer FALLEN_CAM
	blinkToken = blinkToken + 1   -- batalkan blink sebelumnya
	local myToken = blinkToken

	-- Tanpa BLINK: langsung cut.
	if not BLINK.ENABLED then
		hasFallen = false
		fallenCFrame = nil

		if isLocked then
			smoothedCFrame = computeLockCFrame() or camera.CFrame
			camera.FieldOfView = LOCK.FOV or defaultFOV
		end

		return
	end

	task.spawn(function()
		ensureBlinkGui()

		-- 1. Tutup layar
		local closeTween = TweenService:Create(
			blinkFrame,
			TweenInfo.new(BLINK.CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ BackgroundTransparency = 0 }
		)
		closeTween:Play()
		closeTween.Completed:Wait()
		if myToken ~= blinkToken then return end

		-- 2. Layar sudah hitam penuh - baru sekarang kamera dipotong
		-- kembali ke tengah, jadi player tidak melihat snap tersebut.
		hasFallen = false
		fallenCFrame = nil

		if isLocked then
			smoothedCFrame = computeLockCFrame() or camera.CFrame
			camera.FieldOfView = LOCK.FOV or defaultFOV
		end

		-- 3. Tahan hitam sebentar
		task.wait(BLINK.HOLD_TIME)
		if myToken ~= blinkToken then return end

		-- 4. Buka layar
		local openTween = TweenService:Create(
			blinkFrame,
			TweenInfo.new(BLINK.OPEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		openTween:Play()
	end)
end

-- ================================================================
-- RENDER LOOP
-- ================================================================

local function onRenderStep(deltaTime)
	local now = os.clock()

	-- Hitstop: selama hitstop, effectClock tidak maju.
	if now < hitstopUntil then
		-- no-op
	else
		if next(frozenTracksSet) ~= nil then
			releaseAnimations()
		end
		effectClock = effectClock + deltaTime
	end

	-- Trauma decay
	if trauma > 0 then
		trauma = math.max(0, trauma - SHAKE.DECAY * deltaTime)
	end

	if headTrauma > 0 then
		headTrauma = math.max(0, headTrauma - HEAD_FOLLOW.DECAY * deltaTime)
	end

	-- Kick
	updateKick(deltaTime)

	-- Attack cam
	if effectClock >= attackCamHoldUntil then
		attackCamTarget = 0
	end

	local attackSpeed = attackCamCancelled
		and (ATTACK_CAM and ATTACK_CAM.CANCEL_SPEED or 15)
		or (ATTACK_CAM and ATTACK_CAM.SPEED or 8)

	attackCamZoom = attackCamZoom
		+ (attackCamTarget - attackCamZoom) * math.clamp(attackSpeed * deltaTime, 0, 1)

	-- Dodge zoom
	if effectClock >= dodgeZoomHoldUntil then
		dodgeZoomTarget = 0
	end

	local dodgeSpeed = DODGE_FEEDBACK
		and (DODGE_FEEDBACK.ZOOM_RETURN_SPEED or DODGE_FEEDBACK.SPEED or 10)
		or 10

	dodgeZoom = dodgeZoom
		+ (dodgeZoomTarget - dodgeZoom) * math.clamp(dodgeSpeed * deltaTime, 0, 1)

	-- KO zoom
	local koSpeed = KO_FEEDBACK and (KO_FEEDBACK.ZOOM_IN_SPEED or 8) or 8

	if koZoomTarget > 0 and koZoom < koZoomTarget then
		koZoom = koZoom + (koZoomTarget - koZoom) * math.clamp(koSpeed * deltaTime, 0, 1)
	else
		local outSpeed = KO_FEEDBACK and (KO_FEEDBACK.ZOOM_OUT_SPEED or 5) or 5
		koZoom = koZoom + (koZoomTarget - koZoom) * math.clamp(outSpeed * deltaTime, 0, 1)
	end

	-- FFYL zoom
	if isFFYLActive then
		if effectClock >= ffylBurstUntil then
			ffylZoomTarget = FFYL_FEEDBACK and FFYL_FEEDBACK.ZOOM_SUSTAIN_DISTANCE or 1
		end
	else
		ffylZoomTarget = 0
	end

	local ffylZoomSpeed
	if isFFYLActive then
		ffylZoomSpeed = effectClock < ffylBurstUntil
			and (FFYL_FEEDBACK.ZOOM_IN_SPEED or 12)
			or (FFYL_FEEDBACK.ZOOM_SUSTAIN_SPEED or 4)
	else
		ffylZoomSpeed = FFYL_FEEDBACK.ZOOM_OUT_SPEED or 6
	end

	ffylZoom = ffylZoom
		+ (ffylZoomTarget - ffylZoom) * math.clamp(ffylZoomSpeed * deltaTime, 0, 1)

	-- FFYL camera bias
	local targetBias = isFFYLActive
		and (LOCK.FFYL and LOCK.FFYL.FOCUS_BIAS or 0.1)
		or (LOCK.MODE == "Side" and 0.5 or LOCK.AIM_BIAS)

	-- Config menggunakan BLEND_SPEED; tetap support BIAS_SPEED sebagai fallback.
	local biasSpeed = LOCK.FFYL
		and (LOCK.FFYL.BLEND_SPEED or LOCK.FFYL.BIAS_SPEED or 5)
		or 5

	currentFocusBias = currentFocusBias
		+ (targetBias - currentFocusBias) * math.clamp(biasSpeed * deltaTime, 0, 1)

	-- Sway ramps
	updateFFYLSwayRamp(deltaTime)
	updateIdleSwayRamp(deltaTime)

	-- Base camera
	if isLocked then
		if hasFallen and FALLEN_CAM.ENABLED then
			-- Fallen camera
			local character = player.Character
			local head = character and character:FindFirstChild("Head")

			if head then
				local targetFallenCFrame = getFallenCamCFrame(head)
				local moveSpeed = FALLEN_CAM.MOVE_SPEED or 3.2

				fallenCFrame = fallenCFrame
					and fallenCFrame:Lerp(targetFallenCFrame, math.clamp(moveSpeed * deltaTime, 0, 1))
					or targetFallenCFrame

				camera.CFrame = fallenCFrame
			end

			-- FOV close-up
			local fovSpeed = FALLEN_CAM.FOV_SPEED or 4
			local targetFOV = FALLEN_CAM.FOV or defaultFOV

			camera.FieldOfView = camera.FieldOfView
				+ (targetFOV - camera.FieldOfView) * math.clamp(fovSpeed * deltaTime, 0, 1)
		else
			-- Normal lock
			fallenCFrame = nil
			local targetCFrame = computeLockCFrame()

			if targetCFrame then
				if smoothedCFrame then
					local lerpSpeed = LOCK.SMOOTHNESS or 10
					smoothedCFrame = smoothedCFrame:Lerp(targetCFrame, math.clamp(lerpSpeed * deltaTime, 0, 1))
				else
					smoothedCFrame = targetCFrame
				end
			end

			if smoothedCFrame then
				local totalZoom = attackCamZoom - dodgeZoom - koZoom - ffylZoom
				camera.CFrame = smoothedCFrame * CFrame.new(0, 0, totalZoom)
			end

			-- Kembalikan FOV ke lock normal.
			if LOCK.FOV then
				local fovSpeed = FALLEN_CAM.FOV_SPEED or 4
				camera.FieldOfView = camera.FieldOfView
					+ (LOCK.FOV - camera.FieldOfView) * math.clamp(fovSpeed * deltaTime, 0, 1)
			end
		end
	end

	-- All camera offsets
	local finalCFrame = camera.CFrame

	local pillowOffset = getPillowFollowOffset(player.Character)
	if pillowOffset then finalCFrame = finalCFrame + pillowOffset end

	local headOffset = getHeadFollowOffset(player.Character)
	if headOffset then finalCFrame = finalCFrame + headOffset end

	local kickOffset = getKickOffset()
	if kickOffset then finalCFrame = finalCFrame * kickOffset end

	local shakeOffset = getShakeOffset(effectClock)
	if shakeOffset then finalCFrame = finalCFrame * shakeOffset end

	local ffylSway = getFFYLSwayOffset(effectClock)
	if ffylSway then finalCFrame = finalCFrame * ffylSway end

	local idleSway = getIdleSwayOffset(effectClock)
	if idleSway then finalCFrame = finalCFrame * idleSway end

	camera.CFrame = finalCFrame
end

RunService.RenderStepped:Connect(onRenderStep)

-- ================================================================
-- EVENT LISTENERS
-- ================================================================

-- Match state
syncMatchStateEvent.OnClientEvent:Connect(function(isPlaying)
	if isPlaying then
		resetCameraEffects()
		resetKick()
		setLocked(true)
	else
		-- Kalau lagi mid-FALLEN_CAM/BLINK (mis. "rise" dan match-state-false
		-- datang hampir bersamaan pas ganti ronde), jangan lepas kamera lock
		-- sekarang. Kalau dipaksa unlock di sini, kamera langsung snap ke
		-- kamera default SEBELUM layar sempat menghitam -- itu yang kelihatan
		-- seperti "animasi jatuh ngeblink/glitch". Biarkan blink yang urus
		-- transisi baliknya; kamera tetap locked selama proses itu berjalan.
		local isTransitioningFallen = hasFallen

		if not isTransitioningFallen then
			setLocked(false)
		end

		resetCameraEffects(isTransitioningFallen)
		resetKick()
		clearHitstop()
	end
end)

-- Opponent
if syncOpponentEvent then
	syncOpponentEvent.OnClientEvent:Connect(function(opponent)
		opponentPlayer = opponent
		if not opponent then
			resetCameraEffects()
		end
	end)
end

-- Attack result
attackResultEvent.OnClientEvent:Connect(function(actionType, success, extraData)
	if not success then return end

	if actionType == "hitConfirm" then
		-- Pukulan mendarat = momen slow-mo sebelumnya SELESAI. Ini satu-
		-- satunya pemutus slow-mo yang dimiliki karakter LAWAN di layar kita:
		-- cancelSlowmoForCharacter di tempat lain semuanya cuma dipanggil
		-- buat player.Character sendiri, sementara slow-mo dipasang ke DUA
		-- karakter. Client lawan memang membatalkan miliknya sendiri begitu
		-- dia input -- tapi itu di layar DIA, bukan di layar kita.
		--
		-- Tanpa ini, lawan bisa kelihatan merayap pelan di layar kita padahal
		-- hitbox di server jalan kecepatan penuh -- kita kena pukulan yang
		-- kelihatannya baru mulai diayun.
		cancelSlowmoForCharacter(player.Character)
		cancelSlowmoForCharacter(opponentPlayer and opponentPlayer.Character)
		dodgeZoomHoldUntil = 0

		-- extraData berisi "light" atau "heavy" (dikirim dari
		-- CombatController.resolveHit sebagai actionType asli serangan).
		if extraData == "light" then
			addTrauma(SHAKE.PRESETS.lightConfirm)
			addKick("lightConfirm")
			beginHitstop(HITSTOP.DURATION.lightConfirm, true)
		elseif extraData == "heavy" then
			addTrauma(SHAKE.PRESETS.heavyConfirm)
			addKick("heavyConfirm")
			beginHitstop(HITSTOP.DURATION.heavyConfirm, true)
		end

	elseif actionType == "lightHurt" then
		addTrauma(SHAKE.PRESETS.lightHurt)
		addHeadTrauma(SHAKE.PRESETS.lightHurt)
		addKick("lightHurt")
		cancelAttackCam()
		-- Kena damage = momen slow-mo selesai buat KEDUA karakter. Lawan ikut
		-- dibatalin di sini karena dia nggak punya pemutus lain di layar kita
		-- (lihat catatan panjang di cabang hitConfirm).
		cancelSlowmoForCharacter(player.Character)
		cancelSlowmoForCharacter(opponentPlayer and opponentPlayer.Character)
		dodgeZoomHoldUntil = 0
		beginHitstop(HITSTOP.DURATION.lightHurt, true)

	elseif actionType == "heavyHurt" then
		addTrauma(SHAKE.PRESETS.heavyHurt)
		addHeadTrauma(SHAKE.PRESETS.heavyHurt)
		addKick("heavyHurt")
		cancelAttackCam()
		-- Kena damage = momen slow-mo selesai buat KEDUA karakter. Lawan ikut
		-- dibatalin di sini karena dia nggak punya pemutus lain di layar kita
		-- (lihat catatan panjang di cabang hitConfirm).
		cancelSlowmoForCharacter(player.Character)
		cancelSlowmoForCharacter(opponentPlayer and opponentPlayer.Character)
		dodgeZoomHoldUntil = 0
		beginHitstop(HITSTOP.DURATION.heavyHurt, true)

	elseif actionType == "perfectDodge" or actionType == "perfectDodgeHit" then
		-- Flourish dipicu buat KEDUA pemain: yang berhasil baca dan yang
		-- kebaca. Perfect dodge itu momen sinematik bersama -- kalau cuma
		-- layar si pendodge yang melambat, penyerang nggak pernah lihat
		-- kenapa dia tiba-tiba kekunci.
		triggerDodgeFeedback("PERFECT")

	elseif actionType == "dodgeSuccess" then
		-- Dodge biasa dapat versi yang jauh lebih tipis & pendek. Tetap ada
		-- penekanannya, tapi nggak nyaingi perfect dodge -- bedanya harus
		-- kerasa langsung dari efeknya, bukan cuma dari teks.
		triggerDodgeFeedback("NORMAL")

	elseif actionType == "stun" then
		addTrauma(SHAKE.PRESETS.stun)
		addKick("stun")
		beginHitstop(HITSTOP.DURATION.stun)

	elseif actionType == "fall" then
		-- Kalah ronde / FFYL - salah satu trigger utama FALLEN_CAM.
		addTrauma(SHAKE.PRESETS.fall)
		addKick("fall")
		beginHitstop(HITSTOP.DURATION.fall)
		beginFallenCamera()

	elseif actionType == "rise" then
		-- Kalau server mengirim rise sebelum timer FALLEN_CAM selesai,
		-- langsung BLINK.
		triggerRiseBlink()

	elseif actionType == "defeat" then
		-- Defeat juga jadi trigger FALLEN_CAM.
		beginFallenCamera()
	end
end)

-- Local animation event
localAnimEvent.Event:Connect(function(actionType)
	-- Input baru (attack ATAU dodge) dari pemain sendiri -- batalin slowmo
	-- yang lagi aktif di karakter sendiri SEKARANG JUGA, biar animasi baru
	-- ini langsung main di speed normal, bukan nyangkut pelan/numpuk sama
	-- slowmo lama. Dicek duluan sebelum efek lain di bawah.
	if actionType == "heavy" or actionType == "light" or actionType == "dodge" then
		cancelSlowmoForCharacter(player.Character)
		dodgeZoomHoldUntil = 0 -- lepas juga camera-zoom dodge, biar gak nyangkut zoom-in doang
	end

	-- Saat serangan dimulai: TIDAK ada screen shake (trauma), hanya
	-- movement kamera kecil (addKick) mengikuti gerakan tangan. Shake
	-- baru muncul saat attackResultEvent mengonfirmasi hit.
	if actionType == "heavy" then
		addKick("heavySwing")
		triggerAttackCam("HEAVY")

	elseif actionType == "light" then
		addKick("lightSwing")
		triggerAttackCam("LIGHT")

	elseif actionType == "lightHurt" or actionType == "heavyHurt" then
		cancelAttackCam()
	end
end)

-- FFYL state
ffylStateEvent.OnClientEvent:Connect(function(active)
	isFFYLActive = active
	if active then
		triggerFFYLBurst()
	end
end)

-- KO event: ditembak ke KEDUA pemain (buat teks "K.O.!" di layar dua-
-- duanya), tapi FALLEN_CAM (zoom ke muka) cuma boleh jalan buat pemain
-- yang beneran kalah -- makanya wajib cek flag isLoser dari server, bukan
-- langsung beginFallenCamera() tanpa syarat.
if koEvent then
	koEvent.OnClientEvent:Connect(function(label, isLoser)
		if isLoser then
			beginFallenCamera()
		end

		triggerKOFeedback()
	end)
end

-- Character added
player.CharacterAdded:Connect(function()
	resetCameraEffects()
	resetKick()
	clearHitstop()
	hasFallen = false
end)