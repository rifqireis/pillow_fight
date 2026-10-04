-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : BotService
    Layer      : Service (ServerScriptService/Core/Service)
	Penulis    : Yusuf Ahayy
    Deskripsi  : Membuat & menghapus "pemain semu" (bot) -- Lua table biasa
                 yang MENIRU bentuk Player asli secukupnya (field .Name,
                 .UserId, .Character, .IsBot, .Backpack) supaya bisa lolos
                 lewat SEMUA sistem yang ada (MatchmakingService, ArenaService,
                 CombatController, EnergyService, dst) tanpa perlu ubah sistem
                 itu satu-satu -- kecuali titik yang memang HARUS beda karena
                 bot tidak punya client asli (sudah dipatch pakai
                 RemoteSafety.isBot() di ArenaService).

                 Bot BUKAN Instance Player -- jadi:
                 - Players:GetPlayers() TIDAK akan pernah berisi bot.
                 - Players.PlayerRemoving TIDAK PERNAH nyala buat bot --
                   makanya BotService.destroy() WAJIB dipanggil manual
                   (lihat ArenaService.endMatch/abortMatch, fase berikutnya)
                   buat bersihin PlayerStateRepository & karakter fisiknya.
                   Tanpa ini, entry bot nyangkut selamanya di memori server.
                 - LeaderboardService sudah otomatis skip bot lewat
                   isRealPlayer() (UserId negatif), jadi tidak perlu guard
                   tambahan di sana.
    Tanggal    : 17 Agustus 2026
    Dependensi : BotConfig, PlayerStateRepository
]]

local BotService = {}

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local BotConfig = require(ReplicatedStorage.Configs.BotConfig)
local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local BotAnimationService = require(ServerScriptService.Core.Service.BotAnimationService)

-- Registry bot yang lagi aktif (dipakai isBotPlayer buat validasi cepat,
-- dan buat cleanup darurat kalau server mau shutdown selagi ada bot main).
local activeBots = {}

-- Counter buat mastiin tiap bot dapat UserId unik walau beberapa bot aktif
-- BERSAMAAN di arena berbeda (lihat catatan BotConfig.USERID_BASE).
local nextBotSuffix = 0

local botsFolder = Workspace:FindFirstChild("Bots")
if not botsFolder then
	botsFolder = Instance.new("Folder")
	botsFolder.Name = "Bots"
	botsFolder.Parent = Workspace
end

local function generateBotUserId()
	nextBotSuffix += 1
	return BotConfig.USERID_BASE - nextBotSuffix
end

-- Rig dummy polos bot (KEPUTUSAN 17 Agustus 2026: bukan lagi clone avatar
-- lewat CreateHumanoidModelFromUserId -- sengaja no skin/outfit/accessory
-- sama sekali, biar (1) gak ada dependency ke avatar API/DataStore apapun,
-- (2) gak ada ambiguitas visual pas lawan mirror skin sendiri, (3) bot
-- jelas keliatan "ini bot" dari tampilan luar). Tetap kasih Humanoid +
-- HumanoidRootPart yang valid biar semua sistem (equip tool, hitbox, seat)
-- tetap jalan normal.
--
-- PATCH 17 Agustus 2026: rig lama cuma HumanoidRootPart (invisible) + satu
-- Torso kotak -- makanya keliatan "cuma kotak doang", bukan bentuk dummy.
-- Yang lebih parah: rig itu gak punya "Right Arm", padahal
-- Humanoid:EquipTool() BUTUH part "Right Arm" (R6) buat bikin grip Motor6D
-- ke Handle tool -- tanpa itu, EquipTool gagal nempelin Pillow ke karakter
-- sama sekali. Efeknya persis dua bug yang dilaporkan: bantal gak kelihatan,
-- dan HitboxService.getPillowPart() gak nemu apa-apa di character bot
-- ("Bantal Sparring Bot tidak ditemukan" -> fallback tanpa deteksi
-- tabrakan). StreakDisplayService juga cari "Head" buat naro label, yang
-- juga gak ada di rig lama.
--
-- Sekarang rig dibikin R6 lengkap (HumanoidRootPart, Torso, Head, Left/Right
-- Arm, Left/Right Leg) dengan Motor6D standar (RootJoint, Neck, Shoulder,
-- Hip) supaya (1) EquipTool jalan normal & Pillow kepegang di tangan kanan
-- kayak pemain asli, (2) bentuknya kebaca sebagai dummy manusia motong-motong
-- kotak, bukan satu kotak gepeng, (3) siap dipakai animasi (fase berikutnya)
-- karena Motor6D-nya udah sesuai rig R6 default. Warna abu polos tetap
-- dipertahankan (tanpa skin/outfit) sesuai keputusan awal.
local DUMMY_COLOR = Color3.fromRGB(163, 162, 165)

local function buildFallbackCharacter()
	local model = Instance.new("Model")

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.CanCollide = false
	root.CFrame = CFrame.new(0, 0, 0)
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Color = DUMMY_COLOR
	torso.CFrame = root.CFrame
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.Color = DUMMY_COLOR
	head.CFrame = root.CFrame * CFrame.new(0, 1.5, 0)
	head.Parent = model

	local leftArm = Instance.new("Part")
	leftArm.Name = "Left Arm"
	leftArm.Size = Vector3.new(1, 2, 1)
	leftArm.Color = DUMMY_COLOR
	leftArm.CFrame = root.CFrame * CFrame.new(-1.5, 0, 0)
	leftArm.Parent = model

	local rightArm = Instance.new("Part")
	rightArm.Name = "Right Arm"
	rightArm.Size = Vector3.new(1, 2, 1)
	rightArm.Color = DUMMY_COLOR
	rightArm.CFrame = root.CFrame * CFrame.new(1.5, 0, 0)
	rightArm.Parent = model

	local leftLeg = Instance.new("Part")
	leftLeg.Name = "Left Leg"
	leftLeg.Size = Vector3.new(1, 2, 1)
	leftLeg.Color = DUMMY_COLOR
	leftLeg.CFrame = root.CFrame * CFrame.new(-0.5, -2, 0)
	leftLeg.Parent = model

	local rightLeg = Instance.new("Part")
	rightLeg.Name = "Right Leg"
	rightLeg.Size = Vector3.new(1, 2, 1)
	rightLeg.Color = DUMMY_COLOR
	rightLeg.CFrame = root.CFrame * CFrame.new(0.5, -2, 0)
	rightLeg.Parent = model

	-- RootJoint (HumanoidRootPart <-> Torso) WAJIB Motor6D, bukan
	-- WeldConstraint -- Roblox pakai nama & tipe ini buat nentuin "PrimaryPart
	-- gerak" si rig itu R6 asli, bukan cuma model nempel.
	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0 = root
	rootJoint.Part1 = torso
	rootJoint.C0 = CFrame.new(0, 0, 0)
	rootJoint.C1 = CFrame.new(0, 0, 0)
	rootJoint.Parent = root

	local neck = Instance.new("Motor6D")
	neck.Name = "Neck"
	neck.Part0 = torso
	neck.Part1 = head
	neck.C0 = CFrame.new(0, 1, 0)
	neck.C1 = CFrame.new(0, -0.5, 0)
	neck.Parent = torso

	local leftShoulder = Instance.new("Motor6D")
	leftShoulder.Name = "Left Shoulder"
	leftShoulder.Part0 = torso
	leftShoulder.Part1 = leftArm
	leftShoulder.C0 = CFrame.new(-1, 0.5, 0)
	leftShoulder.C1 = CFrame.new(0.5, 0.5, 0)
	leftShoulder.Parent = torso

	local rightShoulder = Instance.new("Motor6D")
	rightShoulder.Name = "Right Shoulder"
	rightShoulder.Part0 = torso
	rightShoulder.Part1 = rightArm
	rightShoulder.C0 = CFrame.new(1, 0.5, 0)
	rightShoulder.C1 = CFrame.new(-0.5, 0.5, 0)
	rightShoulder.Parent = torso

	local leftHip = Instance.new("Motor6D")
	leftHip.Name = "Left Hip"
	leftHip.Part0 = torso
	leftHip.Part1 = leftLeg
	leftHip.C0 = CFrame.new(-1, -1, 0)
	leftHip.C1 = CFrame.new(-0.5, 1, 0)
	leftHip.Parent = torso

	local rightHip = Instance.new("Motor6D")
	rightHip.Name = "Right Hip"
	rightHip.Part0 = torso
	rightHip.Part1 = rightLeg
	rightHip.C0 = CFrame.new(1, -1, 0)
	rightHip.C1 = CFrame.new(0.5, 1, 0)
	rightHip.Parent = torso

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.Parent = model

	model.PrimaryPart = root
	return model
end

-- PATCH 17 Agustus 2026 (custom skin): kalau ada Model rig custom di
-- ServerStorage.BotAssets.BotRigTemplate, dia yang dipakai (clone) --
-- rig dummy kotak polos di atas jadi FALLBACK doang kalau template
-- belum ditaruh / ke-delete, biar BotService.create() gak pernah error
-- gara-gara asset ilang.
--
-- SYARAT rig custom biar tetap jalan sama semua sistem yang ada
-- (EquipTool, HitboxService, animasi, StreakDisplayService):
--   - R6 (bukan R15) -- Motor6D/AnimationConfig dibangun buat R6.
--   - Part wajib ada: HumanoidRootPart, Torso, Head, Left Arm,
--     Right Arm, Left Leg, Right Leg (Right Arm WAJIB buat EquipTool
--     nge-grip Pillow).
--   - Motor6D nama standar: RootJoint, Neck, Left Shoulder,
--     Right Shoulder, Left Hip, Right Hip.
--   - Humanoid.RigType = R6, Model.PrimaryPart = HumanoidRootPart.
local function getRigTemplate()
	local botAssets = ServerStorage:FindFirstChild("BotAssets")
	if not botAssets then return nil end

	local template = botAssets:FindFirstChild("AIBotHebat")
	if not template or not template:IsA("Model") then return nil end

	return template
end

-- Bikin karakter fisik bot (rig + Humanoid + HumanoidRootPart) dan
-- taruh sementara jauh di bawah map -- ArenaService.teleportPlayersToSpawn
-- (dan MatchmakingService.lockPlayerMovement selagi masih di antrean) yang
-- bakal PivotTo dia ke titik yang benar begitu dibutuhkan.
local function buildCharacter(botName, userId)
	local template = getRigTemplate()
	local character = template and template:Clone() or buildFallbackCharacter()

	if not character.PrimaryPart then
		character.PrimaryPart = character:FindFirstChild("HumanoidRootPart")
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.RigType = Enum.HumanoidRigType.R6
	end

	character.Name = botName .. "_" .. tostring(userId)
	character.Parent = botsFolder

	if character.PrimaryPart then
		character:PivotTo(CFrame.new(0, -500, 0))
	end

	return character
end

-- Buat satu bot baru & langsung daftarin state-nya ke PlayerStateRepository
-- (bypass PlayerDataService/DataStore -- bot gak punya data permanen).
function BotService.create()
	local botName = BotConfig.NAMES[math.random(1, #BotConfig.NAMES)]
	local userId = generateBotUserId()

	local character = buildCharacter(botName, userId)

	-- Wadah tool pengganti Backpack asli (Player.Backpack cuma ada di
	-- Instance Player beneran) -- lihat catatan equipPillow di ArenaService.
	local backpack = Instance.new("Folder")
	backpack.Name = "Backpack"
	backpack.Parent = character

	local botPlayer = {
		Name = botName,
		UserId = userId,
		IsBot = true,
		Character = character,
		Backpack = backpack,
	}

	PlayerStateRepository.init(botPlayer)
	activeBots[botPlayer] = true

	-- WAJIB: tanpa ini, Animator bot gak pernah di-load track-nya, jadi
	-- BotAnimationService.play() (dipanggil dari BotAIService) selalu
	-- no-op karena animState[botPlayer] kosong -- bot keliatan diam
	-- walau swing/hit di HitboxService jalan normal.
	BotAnimationService.attach(botPlayer)

	print("[BotService] Bot dibuat: " .. botName .. " (UserId " .. userId .. ")")

	return botPlayer
end

-- Hapus bot: destroy karakter fisik + bersihkan state-nya dari
-- PlayerStateRepository. WAJIB dipanggil manual di titik yang biasanya
-- ke-trigger oleh Players.PlayerRemoving untuk pemain asli (match
-- selesai/dibatalkan) -- bot gak pernah nyalain event itu sama sekali.
function BotService.destroy(botPlayer)
	if not botPlayer or not activeBots[botPlayer] then return end

	if botPlayer.Character then
		botPlayer.Character:Destroy()
	end

	BotAnimationService.detach(botPlayer)
	PlayerStateRepository.remove(botPlayer)
	activeBots[botPlayer] = nil

	print("[BotService] Bot dihapus: " .. tostring(botPlayer.Name))
end

-- Snapshot bot yang sedang aktif, supaya service server yang memakai
-- Players:GetPlayers() bisa ikut memproses bot.
function BotService.getActivePlayers()
	local result = {}

	for botPlayer in pairs(activeBots) do
		if botPlayer and botPlayer.Character then
			table.insert(result, botPlayer)
		end
	end

	return result
end


function BotService.isBotPlayer(player)
	return player ~= nil and activeBots[player] == true
end

return BotService