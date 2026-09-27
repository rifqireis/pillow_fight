-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : ArenaService.lua
    Layer      : Service
    Deskripsi  : Mengatur siklus match, sistem ronde (Best of 3), dan skor.
    Tanggal    : 03 Juli 2026
    Versi      : 1.2

    Changelog v1.2:
    - notifyKO sekarang mengirim flag isLoser (parameter ke-3) di KOEvent.
      KOEvent tetap ditembak ke KEDUA pemain (buat nampilin teks "K.O.!" di
      layar dua-duanya), tapi CameraController butuh tahu siapa yang beneran
      kalah supaya FALLEN_CAM (kamera zoom ke muka) cuma jalan buat pemain
      yang kalah, bukan buat pemenang juga.
]]

local ArenaService = {}

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local StarterPack = game:GetService("StarterPack")

local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local GameplayConfig = require(ReplicatedStorage.Configs.GameplayConfig)
local BalanceConfig = require(ReplicatedStorage.Configs.BalanceConfig)
local EnergyConfig = require(ReplicatedStorage.Configs.EnergyConfig)
local KOConfig = require(ReplicatedStorage.Configs.KOConfig) -- dipakai notifyKO untuk pilih label acak
local AnimationConfig = require(ReplicatedStorage.Configs.AnimationConfig)

-- Dependencies that will be required lazily to avoid circular dependencies
local MatchmakingService

-- State untuk tracking match yang aktif
local activeMatches = {}
-- Struktur activeMatches[arenaName] = {
--    players = {player1, player2},
--    scores = {0, 0},
--    currentRound = 1
-- }

local ArenaAnnouncementEvent
local SyncMatchStateEvent
local SyncOpponentEvent
local MusicStateEvent
local TeleporterLabelHideEvent -- nyalain lagi label billboard begitu match beneran kelar/batal

local SyncEnergyEvent
local SyncBalanceEvent
local SyncOpponentStatsEvent
local FFYLStateEvent
local KOEvent -- remote untuk teks KO + trigger slowmo/zoom di client
-- Nyala TRUE sejak startMatch sampai match beneran kelar/batal (mencakup
-- seluruh ronde + jeda transisi di antaranya). Dipakai client (InputController)
-- buat MATIKAN tombol Reset bawaan Roblox selama pemain masih "ada di match" --
-- ini nutup bug lama: klik Reset di tengah match bikin karakter lama hancur
-- lalu character baru muncul padahal ArenaService masih anggap match jalan.
local MatchLockEvent

-- Ready-handshake ronde (lihat ArenaService.init & startRound)
local RoundReadyEvent
local pendingReadyAcks = {} -- pendingReadyAcks[player] = true begitu client fire ack balik

local LeaderboardService = require(ServerScriptService.Core.Service.LeaderboardService)
local RemoteSafety = require(ServerScriptService.Core.Service.RemoteSafety)
local BotService -- lazy require (lihat catatan circular dependency di dekat startMatch)
local BotAIService -- lazy require


local function getOrCreateRemote(parent, name)
	local remote = parent:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = parent
	end
	return remote
end

function ArenaService.init()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
	ArenaAnnouncementEvent = getOrCreateRemote(remotesFolder, "ArenaAnnouncementEvent")
	SyncMatchStateEvent = getOrCreateRemote(remotesFolder, "SyncMatchStateEvent")
	-- Dipakai client (CameraController) untuk mengunci kamera ke lawan
	SyncOpponentEvent = getOrCreateRemote(remotesFolder, "SyncOpponentEvent")
	MusicStateEvent = getOrCreateRemote(remotesFolder, "MusicStateEvent")
	-- Dibuat juga (dengan nama sama) oleh MatchmakingService begitu antrean
	-- penuh; siapa pun jalan duluan yang bikin instance-nya, sisanya tinggal
	-- FindFirstChild lewat getOrCreateRemote.
	TeleporterLabelHideEvent = getOrCreateRemote(remotesFolder, "TeleporterLabelHideEvent")

	SyncEnergyEvent = getOrCreateRemote(remotesFolder, "SyncEnergyEvent")
	SyncBalanceEvent = getOrCreateRemote(remotesFolder, "SyncBalanceEvent")
	-- Stat lawan untuk panel BattleUI.HpRight
	SyncOpponentStatsEvent = getOrCreateRemote(remotesFolder, "SyncOpponentStatsEvent")
	FFYLStateEvent = getOrCreateRemote(remotesFolder, "FFYLStateEvent")
	-- Dibuat (bukan WaitForChild) karena sebelumnya remote ini belum pernah
	-- dibuat sama sekali oleh siapa pun -- itu sebab KOTextClient dan
	-- CameraController (yang sudah WaitForChild ini dengan timeout 15 detik)
	-- tidak pernah menerima sinyalnya.
	KOEvent = getOrCreateRemote(remotesFolder, "KOEvent")
	MatchLockEvent = getOrCreateRemote(remotesFolder, "MatchLockEvent")

	-- Ready-handshake ronde: client fire balik event yang sama begitu terima
	-- prompt-nya, dipakai buat nunggu kedua pemain beneran siap (bukan asumsi)
	-- sebelum countdown mulai. Lihat catatan GameplayConfig.ROUND_READY_TIMEOUT.
	RoundReadyEvent = getOrCreateRemote(remotesFolder, "RoundReadyEvent")
	RoundReadyEvent.OnServerEvent:Connect(function(player)
		pendingReadyAcks[player] = true
	end)

	MatchmakingService = require(ServerScriptService.Core.Service.MatchmakingService)

	-- Jaring pengaman server: kalau karakter seorang pemain benar-benar
	-- di-recreate (CharacterAdded) padahal dia masih tercatat main di
	-- activeMatches, itu HANYA bisa terjadi lewat tombol Reset/exploit atau
	-- karakter mati (fall damage dll) -- bukan alur normal, karena pergantian
	-- ronde di ArenaService selalu pakai PivotTo (character yang sama), tidak
	-- pernah lewat respawn. Perlakukan sebagai match yang harus diselesaikan
	-- paksa, dengan aturan yang sama seperti AFK.
	local function watchForUnexpectedRespawn(player)
		player.CharacterAdded:Connect(function()
			ArenaService.handleUnexpectedRespawn(player)
		end)
	end

	Players.PlayerAdded:Connect(watchForUnexpectedRespawn)
	for _, player in ipairs(Players:GetPlayers()) do
		watchForUnexpectedRespawn(player)
	end

	print("[ArenaService] Berhasil diinisialisasi.")
end

local function announceTo(players, message, duration)
	if not ArenaAnnouncementEvent then return end

	for _, player in ipairs(players) do
		RemoteSafety.fire(ArenaAnnouncementEvent, player, message, duration)
	end
end

local function announce(arenaName, message, duration)
	local matchInfo = activeMatches[arenaName]
	if matchInfo then
		announceTo(matchInfo.players, message, duration)
	end
end

-- Wrapper publik dari announceTo -- dipakai layanan lain (mis.
-- MatchmakingService untuk pesan cooldown farming Layer 3) yang perlu kirim
-- banner pesan ke pemain di LUAR konteks match yang sedang aktif di
-- activeMatches (mis. pemain masih di antrean/lobby, belum match).
function ArenaService.announceToPlayers(players, message, duration)
	announceTo(players, message, duration)
end

-- Pindahkan BGM pemain. state: "lobby" atau "arena".
local function setMusicState(players, state)
	if not MusicStateEvent then return end

	for _, player in ipairs(players) do
		RemoteSafety.fire(MusicStateEvent, player, state)
	end
end

-- CFrame asli tiap titik spawn arena, direkam saat pertama kali dipakai.
local spawnOrigins = {}

-- Simpan JumpPower/JumpHeight/UseJumpPower asli tiap pemain sebelum kita
-- nolkan selama dia "dibekukan" (frozen) di arena. Perlu ini juga -- bukan
-- cuma Controls:Disable() di client -- soalnya tombol Jump bawaan Roblox di
-- HP (TouchJump) itu nyembunyiin dirinya sendiri berdasarkan JumpPower/
-- JumpHeight humanoid > 0, BUKAN berdasarkan Controls:Disable(). Kalau cuma
-- dikunci di client, tombol Jump di Android tetap nongol keliatan walau
-- gak ngefek ke gerakan.
local playerJumpOriginals = {}

local fallMovementOriginals = {}

-- FIX (bot melayang di atas bambu, round 1 sendiri udah salah -- rig bot itu
-- custom dari ServerStorage.BotAssets.AIBotHebat, PROPORSINYA BEDA sama
-- avatar Roblox biasa). Sebelumnya offset berdiri di-hardcode Vector3.new(0,
-- 3, 0) buat SEMUA karakter -- angka itu cuma kebetulan pas buat rig avatar
-- standar (HipHeight~2 + setengah tinggi root~1 = 3), TAPI SALAH untuk rig
-- manapun yang proporsinya beda. Bot custom kena ini karena HipHeight
-- rig-nya belum tentu sama dengan avatar standar.
--
-- Hitung offset dari data rig itu sendiri (bukan angka tebakan) supaya
-- otomatis benar buat player asli MAUPUN bot custom dengan proporsi apapun:
-- HipHeight = jarak dari bawah HumanoidRootPart ke lantai saat berdiri
-- normal, ditambah setengah tinggi root part itu sendiri (karena CFrame
-- part itu diukur dari TENGAH part, bukan dari bawahnya).
local function getStandingOffset(humanoid, rootPart)
	local hipHeight = humanoid and humanoid.HipHeight
	-- R6 gak pakai HipHeight (beda sama R15) -- nilainya selalu 0 buat rig
	-- R6, baik player asli maupun bot (kebuktiin dari SPAWN-DEBUG: keduanya
	-- HipHeight=0.00). Anggap 0/nil sebagai "gak reliable", fallback ke
	-- proporsi standar R6 (Torso 2 stud + Legs 2 stud = HRP berdiri 3 stud
	-- di atas lantai -> setengah Torso(1) + Legs(2) = HipHeight efektif 2).
	if not hipHeight or hipHeight <= 0 then
		hipHeight = 2
	end
	local halfRootHeight = (rootPart and rootPart.Size.Y / 2) or 1
	local adjust = GameplayConfig.STANDING_HEIGHT_ADJUST or 0
	return hipHeight + halfRootHeight + adjust
end

-- FIX (akar masalah "kepala/badan gak singkron", hit effect nongol di atas,
-- posisi player vs bot naik-turun random -- lihat SPAWN-DEBUG log):
-- Model:PivotTo(cframe) naro PrimaryPart model itu PERSIS di cframe yang
-- dikasih -- BUKAN HumanoidRootPart. Ternyata character.PrimaryPart di
-- project ini ke-set ke "Head" (baik player asli maupun bot, kebuktiin dari
-- log SPAWN-DEBUG), kemungkinan besar dari StarterCharacter template atau
-- rig template bot yang emang salah setting di Studio. Efeknya: tiap
-- PivotTo(spawnPart.CFrame + offset) itu naro KEPALA di titik target,
-- sedangkan HumanoidRootPart (tempat hitbox & kaki nempel) ikut kegeser
-- sejauh jarak Head-ke-Root -- persis gejala yang dilaporkan.
--
-- Paksa PrimaryPart = HumanoidRootPart tiap sebelum PivotTo supaya kode ini
-- self-heal, gak peduli lagi StarterCharacter/rig template-nya bener atau
-- kelewat salah di-set di Studio.
local function ensureRootIsPrimaryPart(character, rootPart)
	if character and rootPart and character.PrimaryPart ~= rootPart then
		character.PrimaryPart = rootPart
	end
end

-- Ambil titik spawn arena sekaligus kembalikan ke posisi aslinya. Titik
-- spawn bisa bergeser kalau sempat ke-dorong pas frame chaos.
local function getArenaSpawns(arenaName)
	local arenaTeleporterFolder = GameplayConfig.getArenaTeleporterFolder(arenaName)
	if not arenaTeleporterFolder then return nil end

	local spawns = {
		arenaTeleporterFolder:WaitForChild("SpawnPoint1"),
		arenaTeleporterFolder:WaitForChild("SpawnPoint2")
	}

	for _, spawnPart in ipairs(spawns) do
		if spawnOrigins[spawnPart] == nil then
			spawnOrigins[spawnPart] = spawnPart.CFrame

			-- FIX (root cause jarak nge-gap round 2+ / lihat log HitboxDebug
			-- rootToRoot 7.26 -> 11.54 abis ronde ganti): SpawnPoint1/2 dulu
			-- fungsinya Seat yang emang didudukin, jadi kalau sempat kesenggol
			-- badan yang lagi jatuh (releaseLoserForFall un-anchor loser tiap
			-- endRound) gak kerasa efeknya. Sekarang part ini murni titik
			-- ACUAN CFrame buat PivotTo -- kalau dia gak Anchored, badan yang
			-- jatuh/settle di dekatnya bisa dorong dia geser, dan reset CFrame
			-- manual di bawah bisa ke-overwrite lagi sama physics step
			-- berikutnya selama masih ada collision overlap. Anchor sekali di
			-- sini supaya titik acuan ini gak akan PERNAH bisa digeser fisika
			-- apapun lagi, seumur hidup server.
			spawnPart.Anchored = true
		else
			spawnPart.CFrame = spawnOrigins[spawnPart]
		end
	end

	return spawns
end

-- Bekukan (anchored=true) atau lepas (anchored=false) sekumpulan pemain di
-- tempat mereka berdiri sekarang.
--
-- Ini pengganti mekanisme Seat:Sit()/SeatWeld/SetNetworkOwner yang lama
-- (lihat riwayat git kalau penasaran) -- efeknya sama persis (pemain gak
-- bisa gerak/kedorong) tapi tanpa perlu weld apa pun. RootPart yang
-- Anchored=true itu murni dikontrol server, jadi:
--   - gak butuh network ownership dance (part anchored gak "disimulasikan"
--     di client, jadi gak ada yang perlu direbut/dikembalikan),
--   - PivotTo pada part yang Anchored gak pernah nyeret apa pun (gak ada
--     weld yang bisa nyangkut ke part lain),
--   - gak ada race nunggu weld putus -- tinggal set properti, langsung efektif.
local function freezePlayers(players, anchored)
	for _, player in ipairs(players) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = humanoid and humanoid.RootPart
		if not rootPart then continue end

		rootPart.Anchored = anchored
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero

		if anchored then
			if playerJumpOriginals[player] == nil then
				playerJumpOriginals[player] = {
					UseJumpPower = humanoid.UseJumpPower,
					JumpPower = humanoid.JumpPower,
					JumpHeight = humanoid.JumpHeight,
				}
			end
			humanoid.JumpPower = 0
			humanoid.JumpHeight = 0
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		elseif playerJumpOriginals[player] then
			local original = playerJumpOriginals[player]
			humanoid.UseJumpPower = original.UseJumpPower
			humanoid.JumpPower = original.JumpPower
			humanoid.JumpHeight = original.JumpHeight
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			playerJumpOriginals[player] = nil
		end
	end
end

-- BUG FIX (animasi "rise" pemain ASLI patah/gak selesai): fix race condition
-- di komentar bawah (dekat startRound) SEBELUM ini cuma diterapkan buat bot
-- (BotAnimationService.play mengembalikan track.Length yang dipakai buat
-- nunggu). Untuk pemain asli, animasi rise ditembak ke client lewat
-- AttackResultEvent tanpa nunggu apa-apa sama sekali -- jadi begitu
-- teleportPlayersToSpawn langsung jalan detik itu juga, karakter yang lagi
-- MAIN animasi "rise" (ada root motion, bangun dari lantai) tiba-tiba
-- di-PivotTo + di-Sit paksa ke bambu di tengah animasi -> keliatan patah/
-- ke-skip/gak selesai. Persis gejala yang dilaporkan.
--
-- Fix: load animasi "rise" itu sendiri (server-side, cuma buat baca
-- .Length asli dari asset-nya, gak pernah beneran ditampilkan/diputar ke
-- siapa-siapa) sekali saja lalu cache hasilnya, supaya startRound bisa
-- nunggu durasi yang sama persis kayak yang dipakai buat bot.
local cachedRiseAnimLength = nil

local function getRiseAnimationLength(humanoid)
	if cachedRiseAnimLength then return cachedRiseAnimLength end

	local riseId = AnimationConfig.COMBAT_ANIMATIONS and AnimationConfig.COMBAT_ANIMATIONS.rise
	if not riseId or riseId == "" then return nil end

	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then return nil end

	local anim = Instance.new("Animation")
	anim.AnimationId = riseId

	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not track then
		anim:Destroy()
		return nil
	end

	-- Warm-up sekilas (weight 0, fade 0) biar Length ke-populate penuh dari
	-- asset-nya -- sama pola yang dipakai warmUpTracks() di client & di
	-- BotAnimationService.attach().
	pcall(function()
		track:Play(0, 0, 1)
		track:Stop(0)
	end)

	if track.Length and track.Length > 0 then
		cachedRiseAnimLength = track.Length
	end

	track:Destroy()
	anim:Destroy()

	return cachedRiseAnimLength
end

local function releaseLoserForFall(player)
	if not player then return end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	if not fallMovementOriginals[player] then
		fallMovementOriginals[player] = {
			WalkSpeed = humanoid.WalkSpeed,
			AutoRotate = humanoid.AutoRotate,
		}
	end

	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid.WalkSpeed = 0
	humanoid.AutoRotate = false

	-- FIX (karakter "merosot"/geser turun & animasi fall kepotong): dulu
	-- fungsi ini nge-lepas Anchored supaya karakter beneran jatuh kena
	-- gravity Roblox, BARENGAN sama animasi "fall" yang udah punya root
	-- motion sendiri (dua-duanya sama-sama nyoba nentuin posisi karakter di
	-- waktu yang sama -- baku rebut, hasilnya keliatan meleset/geser, dan
	-- gampang keputus kalau ronde berikutnya PivotTo dia sebelum animasinya
	-- kelar main).
	--
	-- Sekarang karakter TETAP Anchored di tempat -- gak ada fisika jatuh
	-- beneran sama sekali. Animasi "fall"/"defeat" (root motion-nya sendiri
	-- yang bikin keliatan "ambruk") yang sepenuhnya ngurus visualnya,
	-- ditembak terpisah dari sini lewat AttackResultEvent/BotAnimationService
	-- (lihat endRound). Root part gak disentuh -- biar gak ada peluang dia
	-- kegeser sama sekali selain lewat animasi.
end

local function teleportPlayersToSpawn(arenaName, players)
	local spawns = getArenaSpawns(arenaName)
	if not spawns then return end

	for index, player in ipairs(players) do
		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			local spawnPart = spawns[index]
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if not humanoid then continue end

			local rootPart = humanoid.RootPart

			-- Lepas beku dulu (kalau memang lagi beku) sebelum PivotTo -- bukan
			-- karena PivotTo bermasalah kalau Anchored (part Anchored bebas
			-- dipindah, gak ada weld yang ikut kesered), tapi biar urutannya
			-- gampang dibaca: pindah dulu ke posisi baru, baru bekukan lagi
			-- di situ lewat freezePlayers di bawah.
			if rootPart then
				rootPart.Anchored = false
			end

			local standingOffset = getStandingOffset(humanoid, rootPart)

			ensureRootIsPrimaryPart(character, rootPart)
			character:PivotTo(spawnPart.CFrame + Vector3.new(0, standingOffset, 0))

			-- WalkSpeed/AutoRotate yang di-nol-in releaseLoserForFall (loser
			-- ronde sebelumnya) belum ke-restore otomatis -- restore manual
			-- di sini sebelum freezePlayers ngunci dia lagi jadi Anchored.
			if fallMovementOriginals[player] then
				local original = fallMovementOriginals[player]
				humanoid.WalkSpeed = original.WalkSpeed
				humanoid.AutoRotate = original.AutoRotate
				fallMovementOriginals[player] = nil
			end

			freezePlayers({ player }, true)
		end
	end
end

-- Kalau pemain kehilangan Pillow-nya di tengah sesi (ke-drop, ke-Destroy,
-- atau karakternya sempat respawn beneran di luar alur normal PivotTo),
-- StarterPack CUMA akan ngisi ulang Backpack pas respawn asli -- sedangkan
-- pergantian ronde di ArenaService gak pernah lewat respawn. Tanpa fallback
-- ini, pemain yang sekali kehilangan Pillow-nya bakal main tanpa Pillow
-- SELAMANYA sampai server restart. Makanya di sini kita clone ulang dari
-- StarterPack begitu tool-nya gak ketemu di character maupun Backpack.
local function getPillowTemplate(toolName)
	local template = StarterPack:FindFirstChild(toolName)
	if not template then
		warn("[ArenaService] Template tool '" .. toolName .. "' tidak ditemukan di StarterPack.")
	end
	return template
end

local function equipPillow(players)
	local toolName = GameplayConfig.PILLOW_TOOL_NAME

	for _, player in ipairs(players) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- Bot bukan Player asli (Lua table, bukan Instance) -- gak punya
			-- method :FindFirstChildOfClass. BotService.create() nyimpen
			-- referensi Backpack-nya langsung di field .Backpack, dipakai
			-- di sini sebagai gantinya.
			local backpack = RemoteSafety.isBot(player)
				and player.Backpack
				or player:FindFirstChildOfClass("Backpack")
			local pillow = character:FindFirstChild(toolName)
				or (backpack and backpack:FindFirstChild(toolName))

			if not pillow then
				local template = getPillowTemplate(toolName)
				if template and backpack then
					pillow = template:Clone()
					pillow.Parent = backpack
					warn("[ArenaService] Pillow '" .. toolName .. "' hilang, di-clone ulang dari StarterPack untuk " .. player.Name)
				end
			end

			if pillow then
				humanoid:EquipTool(pillow)
			else
				warn("[ArenaService] Tool '" .. toolName .. "' tidak ditemukan untuk " .. player.Name .. " (StarterPack juga gak punya template-nya)")
			end
		end
	end
end

local function unequipPillow(players)
	for _, player in ipairs(players) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:UnequipTools()
		end
	end
end

local function resetPlayerStats(players)
	for index, player in ipairs(players) do
		PlayerStateRepository.set(player, "isPlaying", false)
		PlayerStateRepository.set(player, "isAlive", true)
		PlayerStateRepository.set(player, "isFFYL", false)
		PlayerStateRepository.set(player, "ffylSurvivalCount", 0)
		PlayerStateRepository.set(player, "balance", BalanceConfig.MAX_BALANCE)
		PlayerStateRepository.set(player, "energy", EnergyConfig.MAX_ENERGY)
		PlayerStateRepository.set(player, "isStun", false)

		-- Fresh combat state setiap ronde. Jangan bawa cooldown/swing/anti-GB
		-- dari ronde sebelumnya ke ronde berikutnya.
		PlayerStateRepository.set(player, "cooldowns", {})
		PlayerStateRepository.set(player, "lastDodgeTime", 0)
		PlayerStateRepository.set(player, "swingId", 0)
		PlayerStateRepository.set(player, "windowActionCount", 0)

		local EnergyService = require(ServerScriptService.Core.Service.EnergyService)
		EnergyService.resetPlayer(player)


		-- flinchUntil itu timestamp MASA DEPAN (bukan "kapan terakhir kena"),
		-- jadi wajib dinolkan tiap ronde. Kalau tidak, pemain yang di detik
		-- terakhir ronde lalu kena pukul / kena perfect dodge bisa masuk ronde
		-- baru dalam keadaan masih terkunci sampai ~0.45 detik pertama.
		PlayerStateRepository.set(player, "flinchUntil", 0)


		-- Reset jam AFK setiap ronde baru mulai, supaya jeda transisi/countdown
		-- ronde sebelumnya tidak ikut terhitung sebagai "diam" di ronde ini.
		PlayerStateRepository.set(player, "lastActionTime", os.clock())

		-- isFFYL di atas baru saja dimatikan, jadi bom waktu FFYLService tidak
		-- akan menutup panelnya. Tutup manual, kalau tidak panel FFYL milik
		-- pemain yang masih kritis saat ronde berganti akan nyangkut di layar.
		if FFYLStateEvent then
			RemoteSafety.fire(FFYLStateEvent, player, false)
		end

		RemoteSafety.fire(SyncEnergyEvent, player, EnergyConfig.MAX_ENERGY)

		if SyncEnergyEvent then
			RemoteSafety.fire(SyncEnergyEvent, player, EnergyConfig.MAX_ENERGY)
		end
		if SyncBalanceEvent then
			RemoteSafety.fire(SyncBalanceEvent, player, BalanceConfig.MAX_BALANCE)
		end

		-- Beri tahu client siapa lawannya sebelum match state aktif,
		-- agar camera lock langsung punya target di frame pertama.
		local opponent = players[(index == 1) and 2 or 1]
		if SyncOpponentEvent then
			RemoteSafety.fire(SyncOpponentEvent, player, opponent)
		end

		-- Isi ulang panel HpRight milik lawan. Tanpa ini panel lawan masih
		-- menampilkan sisa nilai ronde sebelumnya sampai stat pertama berubah.
		if SyncOpponentStatsEvent and opponent then	
			RemoteSafety.fire(SyncOpponentStatsEvent, opponent, "balance", BalanceConfig.MAX_BALANCE)
			RemoteSafety.fire(SyncOpponentStatsEvent, opponent, "energy", EnergyConfig.MAX_ENERGY)
		end

		if SyncMatchStateEvent then
			RemoteSafety.fire(SyncMatchStateEvent, player, false)
		end
	end
end

-- memulai countdown
local function runCountdown(arenaName, seconds)
	for i = seconds, 1, -1 do
		announce(arenaName, tostring(i), 1)
		task.wait(1)
	end
	announce(arenaName, "FIGHT!", 1)
end

-- Nunggu kedua pemain fire balik RoundReadyEvent (konfirmasi client udah
-- terima teleport & siap) sebelum caller lanjut ke animasi/countdown.
-- Ini yang nutup celah lag/ms beda-beda: tanpa ini, server langsung asumsi
-- "pasti udah sampai" begitu PivotTo dipanggil, padahal replikasi ke client
-- yang koneksinya lebih lambat bisa telat beberapa ratus ms -- jadi client
-- itu masih lihat frame lama pas countdown "3" udah keburu muncul.
-- Ada batas atas (ROUND_READY_TIMEOUT) supaya 1 pemain dengan koneksi
-- jelek/mati gak bikin match nyangkut selamanya -- match dipaksa lanjut
-- anyway begitu timeout, cuma di-warn siapa yang telat/gak jawab.
local function waitForPlayersReady(arenaName, matchInfo)
	for _, player in ipairs(matchInfo.players) do
		pendingReadyAcks[player] = nil
	end

	if RoundReadyEvent then
		for _, player in ipairs(matchInfo.players) do
			RemoteSafety.fire(RoundReadyEvent, player)
		end
	end

	-- Bot gak punya client buat fire balik ack-nya -- tandai siap SEKARANG
	-- JUGA (gak ada network delay buat ditunggu sama sekali).
	for _, player in ipairs(matchInfo.players) do
		if RemoteSafety.isBot(player) then
			pendingReadyAcks[player] = true
		end
	end

	local deadline = os.clock() + GameplayConfig.ROUND_READY_TIMEOUT
	while os.clock() < deadline do
		-- Match bisa dibatalkan (pemain keluar) selagi kita nunggu ack ini.
		if activeMatches[arenaName] ~= matchInfo then return end

		local allReady = true
		for _, player in ipairs(matchInfo.players) do
			if not pendingReadyAcks[player] then
				allReady = false
				break
			end
		end

		if allReady then return end
		task.wait()
	end

	for _, player in ipairs(matchInfo.players) do
		if not pendingReadyAcks[player] then
			warn("[ArenaService] " .. player.Name .. " tidak fire RoundReadyEvent dalam " .. GameplayConfig.ROUND_READY_TIMEOUT .. "s (lag/koneksi lambat?) -- ronde " .. arenaName .. " dipaksa lanjut anyway.")
		end
	end
end

-- ================================================================
-- ANTI-AFK (Layer 1) & ANTI-GB (Layer 2)
-- ================================================================
-- CATATAN: karakter duduk terus sepanjang match (analog/movement nonaktif),
-- jadi tidak ada lagi watcher berbasis MoveDirection/Jumping seperti versi
-- lama -- itu tidak akan pernah terpicu baik pemain aktif maupun tidak.
-- "Aktivitas" di sini murni action combat (light/heavy/dodge), yang sudah
-- diupdate langsung oleh CombatController lewat PlayerStateRepository
-- ("lastActionTime" & "windowActionCount"), jadi tidak perlu listener apa pun
-- di sini -- cukup baca state-nya secara berkala.

local function stopAfkWatcher(matchInfo)
	matchInfo.afkWatcherActive = false
end

-- Loop background Layer 1: cek berkala apakah ada pemain yang sama sekali
-- tidak beraction selama AFK_TIMEOUT detik. Cuma aktif selama ronde benar-benar
-- berjalan (matchInfo.roundActive) -- tidak dicek selama countdown/transisi.
local function startAfkWatcher(arenaName, matchInfo)
	task.spawn(function()
		while activeMatches[arenaName] == matchInfo and matchInfo.afkWatcherActive do
			task.wait(GameplayConfig.AFK_CHECK_INTERVAL)

			if activeMatches[arenaName] ~= matchInfo or not matchInfo.afkWatcherActive then
				return
			end

			if not matchInfo.roundActive then
				-- Sedang countdown/jeda antar ronde, jangan dianggap AFK dulu.
				continue
			end

			local now = os.clock()
			local afkFlags = {}
			local anyAfk = false

			for i, player in ipairs(matchInfo.players) do
				local state = PlayerStateRepository.get(player)
				local lastAction = (state and state.lastActionTime) or now
				afkFlags[i] = (now - lastAction) >= GameplayConfig.AFK_TIMEOUT
				if afkFlags[i] then anyAfk = true end
			end

			if anyAfk then
				ArenaService.handleAfk(arenaName, afkFlags)
				return
			end
		end
	end)
end

-- Loop background Layer 2: tiap GB_WINDOW_DURATION detik, cek berapa action
-- tiap pemain dalam window itu. Window di bawah GB_MIN_ACTIONS dianggap
-- "buruk"; GB_BAD_WINDOWS_LIMIT window buruk berturut-turut -> match
-- di-invalidate. Satu window yang memenuhi ambang mereset streak ke 0.
local function startGbWatcher(arenaName, matchInfo)
	matchInfo.gbBadStreak = { 0, 0 }

	-- Reset counter di awal supaya window pertama tidak kebawa action dari
	-- sebelum watcher ini mulai (mis. sisa ronde sebelumnya).
	for _, player in ipairs(matchInfo.players) do
		PlayerStateRepository.set(player, "windowActionCount", 0)
	end

	task.spawn(function()
		while activeMatches[arenaName] == matchInfo and matchInfo.afkWatcherActive do
			task.wait(GameplayConfig.GB_WINDOW_DURATION)

			if activeMatches[arenaName] ~= matchInfo or not matchInfo.afkWatcherActive then
				return
			end

			if not matchInfo.roundActive then
				-- Sedang countdown/jeda antar ronde -- jangan hitung window ini,
				-- tapi tetap reset counter supaya window berikutnya bersih.
				for _, player in ipairs(matchInfo.players) do
					PlayerStateRepository.set(player, "windowActionCount", 0)
				end
				continue
			end

			for i, player in ipairs(matchInfo.players) do
				local state = PlayerStateRepository.get(player)
				local actionCount = (state and state.windowActionCount) or 0

				if actionCount < GameplayConfig.GB_MIN_ACTIONS then
					matchInfo.gbBadStreak[i] = matchInfo.gbBadStreak[i] + 1
				else
					matchInfo.gbBadStreak[i] = 0
				end

				PlayerStateRepository.set(player, "windowActionCount", 0)
			end

			for i, player in ipairs(matchInfo.players) do
				if matchInfo.gbBadStreak[i] >= GameplayConfig.GB_BAD_WINDOWS_LIMIT then
					ArenaService.handleSuspiciousPattern(arenaName, player)
					return
				end
			end
		end
	end)
end

-- Tentukan konsekuensi AFK: ronde 1 (atau kedua-duanya AFK sekaligus) ->
-- match dibatalkan/invalid. Ronde 2+ dengan cuma 1 pemain AFK -> lawannya
-- otomatis menang match.
function ArenaService.handleAfk(arenaName, afkFlags)
	local matchInfo = activeMatches[arenaName]
	if not matchInfo then return end

	local bothAfk = afkFlags[1] and afkFlags[2]

	if bothAfk or matchInfo.currentRound <= 1 then
		local reason = bothAfk
			and "BOTH PLAYERS AFK - MATCH CANCELLED"
			or "AFK DETECTED - MATCH CANCELLED"
		print("[ArenaService] AFK terdeteksi di " .. arenaName .. " (ronde " .. matchInfo.currentRound .. ") -- match dibatalkan.")
		ArenaService.invalidateMatch(arenaName, reason)
	else
		local afkIndex = afkFlags[1] and 1 or 2
		local winnerIndex = (afkIndex == 1) and 2 or 1
		local afkPlayer = matchInfo.players[afkIndex]
		print("[ArenaService] " .. (afkPlayer and afkPlayer.Name or "?") .. " AFK di ronde " .. matchInfo.currentRound .. " -- lawan menang otomatis.")
		announce(arenaName, (afkPlayer and afkPlayer.Name or "Opponent") .. " IS AFK - OPPONENT WINS", 3)
		ArenaService.endMatch(arenaName, winnerIndex)
	end
end

-- Layer 2: pemain terdeteksi pola aktivitas rendah tidak wajar (bukan zero
-- total seperti Layer 1) selama beberapa window berturut-turut. Match
-- langsung di-invalidate untuk KEDUA pemain, sama seperti Layer 1 -- tapi
-- pemain yang memicu ini juga kena tambahan suspicionCount di akunnya
-- (PunishmentService, persisten lewat DataStore -- lihat design doc §5, §7).
function ArenaService.handleSuspiciousPattern(arenaName, player)
	local matchInfo = activeMatches[arenaName]
	if not matchInfo then return end

	print("[ArenaService] Pola aktivitas tidak wajar terdeteksi dari " .. player.Name .. " di " .. arenaName .. " -- match dibatalkan.")

	local PunishmentService = require(ServerScriptService.Core.Service.PunishmentService)
	PunishmentService.recordSuspiciousMatch(player)

	ArenaService.invalidateMatch(arenaName, "SUSPICIOUS ACTIVITY DETECTED - MATCH CANCELLED")
end

-- Sama seperti handleAfk, tapi dipicu saat karakter pemain di-recreate
-- (Reset button / exploit / mati di luar sistem balance) di tengah match.
function ArenaService.handleUnexpectedRespawn(player)
	for arenaName, matchInfo in pairs(activeMatches) do
		local playerIndex = table.find(matchInfo.players, player)
		if playerIndex then
			print("[ArenaService] " .. player.Name .. " respawn/reset di tengah match " .. arenaName .. " -- diperlakukan sebagai bug, match diselesaikan paksa.")

			if matchInfo.currentRound <= 1 then
				ArenaService.invalidateMatch(arenaName, "PLAYER RESPAWNED - MATCH CANCELLED")
			else
				local winnerIndex = (playerIndex == 1) and 2 or 1
				announce(arenaName, player.Name .. " LEFT THE FIGHT - OPPONENT WINS", 3)
				ArenaService.endMatch(arenaName, winnerIndex)
			end
			return
		end
	end
end

function ArenaService.startRound(arenaName)
	local matchInfo = activeMatches[arenaName]
	if not matchInfo then return end

	-- Buka lagi guard endRound (lihat catatan roundEnding di endRound) supaya
	-- ronde baru ini nanti bisa diakhiri secara normal.
	matchInfo.roundEnding = false

	-- Untuk ronde 2+: kirim animasi rise ke pemain yang kalah sebelumnya
	-- SEBELUM teleport agar transisi dari defeat → rise mulus tanpa pop.
	-- Kalau dikirim setelah teleport, karakter akan snap ke atas (ke posisi
	-- seat) lalu turun lagi saat animasi rise dimulai dari lantai.
	local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local AttackResultEvent = Remotes and Remotes:FindFirstChild("AttackResultEvent")

	if matchInfo.currentRound > 1 and matchInfo.lastLoser then
		local lastLoser = matchInfo.lastLoser
		if RemoteSafety.isBot(lastLoser) then
			BotAnimationService = BotAnimationService or require(ServerScriptService.Core.Service.BotAnimationService)
			local riseTrack = BotAnimationService.play(lastLoser, "rise")

			-- FIX (race condition -- "karakter bot naik ke atas" pas ronde 2+):
			-- teleportPlayersToSpawn() di bawah manggil unseatPlayers() dulu,
			-- yang buat WINNER nunggu humanoid.SeatPart-nya bener-bener nil
			-- (loop task.wait sampai 1 detik, tergantung fisika lagi cepat/
			-- lambat clear seat weld). Delay itu NONDETERMINISTIC dan gak ada
			-- hubungannya sama animasi rise si bot sama sekali -- kadang
			-- kelar duluan sebelum animasi rise sempat main, kadang malah
			-- masih di tengah-tengah animasi pas tiba-tiba di-PivotTo +
			-- di-Sit paksa ke titik spawn baru. Animasi "rise" ini sendiri
			-- adalah animasi bangun dari posisi jatuh (ada root motion), jadi
			-- kalau reposisi paksa itu motong di tengah animasi, hasilnya
			-- keliatan kayak karakter "mental/naik ke atas" -- persis gejala
			-- yang dilaporkan, dan "kadang doang" karena memang race,
			-- bukan konsisten.
			--
			-- Fix-nya: tunggu animasi rise ini BENERAN kelar (pakai
			-- track.Length asli dari asset-nya, bukan angka tebakan) sebelum
			-- lanjut ke teleportPlayersToSpawn. Dibatasi ke maksimal 1.5
			-- detik sebagai jaga-jaga kalau asset animasinya somehow belum
			-- ke-load sempurna (Length == 0) atau kepanjangan -- supaya
			-- start ronde tetap gak nyangkut lama-lama nunggu.
			if riseTrack then
				task.wait(math.clamp(riseTrack.Length, 0.3, 1.5))
			end
		elseif AttackResultEvent then
			RemoteSafety.fire(AttackResultEvent, lastLoser, "rise", true)

			-- Sama seperti cabang bot di atas: tunggu animasi "rise" BENERAN
			-- kelar dulu sebelum teleportPlayersToSpawn mereposisi paksa --
			-- kalau tidak, animasi ke-cut di tengah root motion (patah/gak
			-- selesai/ke-skip), baik itu ke bot MAUPUN ke pemain asli.
			local lastLoserCharacter = lastLoser.Character
			local lastLoserHumanoid = lastLoserCharacter and lastLoserCharacter:FindFirstChildOfClass("Humanoid")
			local riseLength = lastLoserHumanoid and getRiseAnimationLength(lastLoserHumanoid)
			task.wait(math.clamp(riseLength or 1, 0.3, 1.5))
		end
	end

	teleportPlayersToSpawn(arenaName, matchInfo.players)

	-- Nunggu kedua client konfirmasi siap sebelum lanjut ke reset stats/UI/
	-- countdown. Lihat catatan di waitForPlayersReady().
	waitForPlayersReady(arenaName, matchInfo)
	if activeMatches[arenaName] ~= matchInfo then return end

	resetPlayerStats(matchInfo.players)
	equipPillow(matchInfo.players)

	-- Mainkan animasi idle/duduk kita SEGERA setelah pemain duduk di seat
	-- arena, jangan tunggu countdown selesai. Kalau tidak, pemain akan
	-- kelihatan pakai animasi duduk bawaan Roblox (jelek) selama countdown,
	-- baru ganti ke MATCH_IDLE pas "FIGHT!" -- keliatan pop/berubah tiba-tiba.
	for _, player in ipairs(matchInfo.players) do
		if RemoteSafety.isBot(player) then
			BotAnimationService = BotAnimationService or require(ServerScriptService.Core.Service.BotAnimationService)
			BotAnimationService.play(player, "idle")
		elseif AttackResultEvent then
			RemoteSafety.fire(AttackResultEvent, player, "idle", true)
		end
	end

	announce(arenaName, "ROUND " .. matchInfo.currentRound, 2)

	-- Ronde 1: Animasi 'start' (masuk arena) untuk semua pemain
	-- Ronde 2+: rise sudah dikirim di atas sebelum teleport
	if matchInfo.currentRound == 1 and AttackResultEvent then
		for _, player in ipairs(matchInfo.players) do
			RemoteSafety.fire(AttackResultEvent, player, "start", true)
		end
	end

	task.wait(2)

	runCountdown(arenaName, 3)

	-- Match bisa dibatalkan (pemain keluar) selama jeda 2 detik + countdown
	-- 3 detik di atas. Tanpa guard ini, coroutine startRound yang sedang
	-- "tidur" di task.wait/runCountdown gak tau match sudah di-abort duluan
	-- (activeMatches[arenaName] sudah nil, pemain yang tersisa sudah
	-- dibalikin ke lobby) -- begitu wait-nya kelar dia asal lanjut nyalain
	-- isPlaying=true & SyncMatchStateEvent(true) lagi buat pemain yang udah
	-- di lobby (makanya balance/energy decay jalan lagi padahal bukan match),
	-- plus opponent target sudah di-nol-in duluan sama abortMatch tanpa
	-- di-resend di sini -- makanya kamera lock nyoba ngunci ke target
	-- kosong/invalid dan "kepental" ke tempat yang bukan arena.
	if activeMatches[arenaName] ~= matchInfo then return end

	-- Paksa equip ulang bantal tepat sebelum match beneran dimulai. Selama
	-- jeda 2 detik + countdown 3 detik di atas (~5 detik), pemain masih bisa
	-- nge-unequip bantal manual (pencet nomor slot tool / backspace). Tanpa
	-- ini, begitu "FIGHT!" dan isPlaying jadi true, pemain bisa saja sudah
	-- kosong tangan padahal match sudah berjalan.
	equipPillow(matchInfo.players)

	-- Mulai match
	matchInfo.roundActive = true

	for _, player in ipairs(matchInfo.players) do
		PlayerStateRepository.set(player, "isPlaying", true)

		if SyncMatchStateEvent then
			RemoteSafety.fire(SyncMatchStateEvent, player, true)
		end

		-- Bot gak punya client yang "mikir" sendiri -- nyalain AI decision
		-- loop server-side di sini, persis di titik yang sama tempat pemain
		-- asli mulai bisa menyerang (isPlaying baru jadi true).
		if RemoteSafety.isBot(player) then
			BotAIService = BotAIService or require(ServerScriptService.Core.Service.BotAIService)
			local opponent = ArenaService.getOpponent(player)
			BotAIService.start(player, opponent)
		end
	end

	print("[ArenaService] Arena " .. arenaName .. " - Round " .. matchInfo.currentRound .. " dimulai!")
end


function ArenaService.endMatch(arenaName, winnerIndex)
	local matchInfo = activeMatches[arenaName]
	if not matchInfo then return end

	-- Match sudah pasti berakhir dari sini -- hentikan pengecekan AFK sekarang
	-- juga supaya tidak nyelonong lagi selagi menunggu task.wait di bawah.
	stopAfkWatcher(matchInfo)

	local winner = matchInfo.players[winnerIndex]
	local loser = matchInfo.players[winnerIndex == 1 and 2 or 1]

	-- Match vs Bot TIDAK dicatat ke Wins/WinStreak/leaderboard ataupun
	-- tracking anti-farming -- bot cuma buat latihan/ngisi slot pas server
	-- sepi, bukan lawan sungguhan, jadi jangan sampai bisa disalahgunakan
	-- buat farming rekor.
	local isBotMatch = matchInfo.isBotMatch

	if winner then
		if not isBotMatch then
			LeaderboardService.recordWin(winner)
		end
		announce(arenaName, winner.Name .. " WINS THE MATCH!", 2.6)
		print("[ArenaService] " .. winner.Name .. " memenangkan match di " .. arenaName)
	end

	-- Animasi "defeat" (FellLose) sudah ditembak dari endRound tepat saat
	-- skor BO3 diketahui menyentuh 2, jadi di sini tinggal urus pencatatan loss.
	if loser and not isBotMatch then
		LeaderboardService.recordLoss(loser)
	end

	-- Layer 3 (§6 design doc): catat hasil match ini untuk tracking streak
	-- repeat-opponent farming per PASANGAN akun. Sengaja dipanggil di sini
	-- (match beneran selesai dengan win/loss), BUKAN di invalidateMatch/
	-- abortMatch -- match yang di-invalidate (AFK/GB/dll) tidak punya
	-- pemenang wajar dan tidak boleh ikut dihitung ke streak farming.
	if winner and loser and not isBotMatch then
		local RepeatOpponentService = require(ServerScriptService.Core.Service.RepeatOpponentService)
		RepeatOpponentService.recordMatchResult(winner, loser)
	end

	task.wait(2.6)

	-- Match bisa dibatalkan (pemain keluar) selama jeda di atas
	if activeMatches[arenaName] ~= matchInfo then return end

	-- Lepas bantal sebelum kembali ke lobby
	unequipPillow(matchInfo.players)

	-- Lepas beku dulu, kalau tidak titik spawn arena ikut ke-anggap "nempel"
	-- dan match berikutnya di arena ini bisa spawn di posisi yang salah.
	freezePlayers(matchInfo.players, false)

	-- Kembalikan titik spawn arena ke posisi aslinya
	getArenaSpawns(arenaName)

	-- Teleport kembali ke lobby
	local lobbySpawn = Workspace:FindFirstChild("Lobby") or Workspace:FindFirstChild("SpawnLocation")
	setMusicState(matchInfo.players, "lobby")

	for _, player in ipairs(matchInfo.players) do
		PlayerStateRepository.set(player, "isPlaying", false)

		if SyncMatchStateEvent then
			RemoteSafety.fire(SyncMatchStateEvent, player, false)
		end

		-- Match beneran kelar -- buka lagi tombol Reset yang dikunci sejak startMatch.
		if MatchLockEvent then
			RemoteSafety.fire(MatchLockEvent, player, false)
		end

		-- Match beneran udah kelar -- balik ke lobby, nyalain lagi label teleporter.
		if TeleporterLabelHideEvent then
			RemoteSafety.fire(TeleporterLabelHideEvent, player, false)
		end

		-- Bersihkan target camera lock saat kembali ke lobby
		if SyncOpponentEvent then
			RemoteSafety.fire(SyncOpponentEvent, player, nil)
		end

		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") and lobbySpawn then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local rootPart = humanoid and humanoid.RootPart
			local standingOffset = getStandingOffset(humanoid, rootPart)
			ensureRootIsPrimaryPart(character, rootPart)
			character:PivotTo(lobbySpawn.CFrame + Vector3.new(0, standingOffset, 0))

			-- BUG FIX (loser gak bisa gerak lagi di lobby setelah match beneran
			-- kelar): releaseLoserForFall nge-nol-in WalkSpeed/AutoRotate loser
			-- ronde terakhir. Restore ini SEBELUMNYA cuma dilakukan di
			-- teleportPlayersToSpawn (dipanggil pas mulai ronde BERIKUTNYA) --
			-- tapi kalau ronde ini SEKALIGUS mengakhiri match, gak ada ronde
			-- berikutnya yang manggil itu, jadi WalkSpeed loser nyangkut di 0
			-- selamanya walau dia sudah balik ke lobby. Restore manual di sini.
			if humanoid and fallMovementOriginals[player] then
				local original = fallMovementOriginals[player]
				humanoid.WalkSpeed = original.WalkSpeed
				humanoid.AutoRotate = original.AutoRotate
				fallMovementOriginals[player] = nil
			end
		end
	end

	-- Bot gak pernah nyalain Players.PlayerRemoving -- beda sama pemain asli,
	-- cleanup-nya (stop AI loop + destroy karakter fisik + hapus state) WAJIB
	-- dipanggil manual di sini, atau bot bakal nyangkut selamanya di memori.
	-- Loop terpisah (bukan numpang di loop di atas) karena bot gak ikut
	-- kena RemoteSafety.fire/PivotTo di atas -- ngirit baca, gak masalah.
	for _, player in ipairs(matchInfo.players) do
		if RemoteSafety.isBot(player) then
			BotAIService = BotAIService or require(ServerScriptService.Core.Service.BotAIService)
			BotAIService.stop(player)

			BotService = BotService or require(ServerScriptService.Core.Service.BotService)
			BotService.destroy(player)
		end
	end

	activeMatches[arenaName] = nil

	-- Bebaskan arena
	if MatchmakingService then
		MatchmakingService.freeArena(arenaName)
	end
end

-- Batalkan match yang tidak akan pernah selesai (mis. salah satu pemain disconnect).
-- Tanpa ini activeMatches dan arenaOccupiedStates tidak pernah dibersihkan, jadi
-- arena tersebut terkunci permanen sampai server restart.
function ArenaService.abortMatch(arenaName, leavingPlayer, reasonMessage)
	local matchInfo = activeMatches[arenaName]
	if not matchInfo then return end

	stopAfkWatcher(matchInfo)

	-- Hapus duluan: supaya getOpponent/handlePlayerDefeated tidak lagi melihat match
	-- ini, dan kalau kedua pemain keluar barengan abort tidak jalan dua kali.
	activeMatches[arenaName] = nil

	print("[ArenaService] Match di " .. arenaName .. " dibatalkan. Alasan: " .. (reasonMessage or "pemain keluar"))

	-- Sisa pemain yang masih benar-benar ada di server
	local remaining = {}
	for _, player in ipairs(matchInfo.players) do
		if player ~= leavingPlayer and player.Parent then
			table.insert(remaining, player)
		end
	end

	announceTo(remaining, reasonMessage or "OPPONENT LEFT - MATCH CANCELLED", 3)

	unequipPillow(remaining)
	freezePlayers(remaining, false)

	-- Kembalikan titik spawn arena ke posisi aslinya
	getArenaSpawns(arenaName)

	local lobbySpawn = Workspace:FindFirstChild("Lobby") or Workspace:FindFirstChild("SpawnLocation")
	local FFYLService = require(ServerScriptService.Core.Service.FFYLService)

	setMusicState(remaining, "lobby")

	for _, player in ipairs(remaining) do
		PlayerStateRepository.set(player, "isPlaying", false)
		PlayerStateRepository.set(player, "isAlive", true)
		PlayerStateRepository.set(player, "isFFYL", false)
		PlayerStateRepository.set(player, "isStun", false)

		-- Kalau dia kebetulan sedang FFYL, timer-nya tidak akan menemukan match lagi
		-- sehingga UI-nya nyangkut di layar. Tutup manual.
		FFYLService.cleanupUI(player)

		if SyncMatchStateEvent then
			RemoteSafety.fire(SyncMatchStateEvent, player, false)
		end

		-- Match dibatalkan -- buka lagi tombol Reset yang dikunci sejak startMatch.
		if MatchLockEvent then
			RemoteSafety.fire(MatchLockEvent, player, false)
		end

		-- Match dibatalkan -- balik ke lobby, nyalain lagi label teleporter.
		if TeleporterLabelHideEvent then
			RemoteSafety.fire(TeleporterLabelHideEvent, player, false)
		end

		-- Bersihkan target camera lock saat kembali ke lobby
		if SyncOpponentEvent then
			RemoteSafety.fire(SyncOpponentEvent, player, nil)
		end

		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") and lobbySpawn then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local rootPart = humanoid and humanoid.RootPart
			local standingOffset = getStandingOffset(humanoid, rootPart)
			ensureRootIsPrimaryPart(character, rootPart)
			character:PivotTo(lobbySpawn.CFrame + Vector3.new(0, standingOffset, 0))

			-- Sama seperti fix di endMatch: kalau pemain ini sempat jadi loser
			-- (releaseLoserForFall) sebelum match dibatalkan, WalkSpeed/AutoRotate
			-- dia masih ke-nol-in. Restore di sini juga supaya gak nyangkut.
			if humanoid and fallMovementOriginals[player] then
				local original = fallMovementOriginals[player]
				humanoid.WalkSpeed = original.WalkSpeed
				humanoid.AutoRotate = original.AutoRotate
				fallMovementOriginals[player] = nil
			end
		end
	end

	-- Bot gak pernah nyalain Players.PlayerRemoving, dan bot juga gak ikut
	-- masuk ke `remaining` di atas (dia gak punya .Parent, jadi kefilter --
	-- lihat catatan RemoteSafety.lua). Makanya cleanup bot WAJIB loop
	-- terpisah di sini pakai matchInfo.players (list asli, belum difilter),
	-- BUKAN numpang di `remaining`. Ini juga wajib ada di abortMatch, bukan
	-- cuma endMatch -- match yang di-abort (AFK/disconnect/dll) juga harus
	-- bersihin bot, kalau tidak dia nyangkut selamanya di memori server.
	for _, player in ipairs(matchInfo.players) do
		if RemoteSafety.isBot(player) then
			BotAIService = BotAIService or require(ServerScriptService.Core.Service.BotAIService)
			BotAIService.stop(player)

			BotService = BotService or require(ServerScriptService.Core.Service.BotService)
			BotService.destroy(player)
		end
	end

	-- Bebaskan arena
	if MatchmakingService then
		MatchmakingService.freeArena(arenaName)
	end
end

-- Batalkan match tanpa ada pemain yang benar-benar disconnect (dipakai untuk
-- kasus AFK ronde 1 & respawn/reset bug ronde 1) -- kedua pemain masih ada di
-- server dan sama-sama kembali ke lobby, tidak ada win/loss yang dicatat.
function ArenaService.invalidateMatch(arenaName, reasonMessage)
	ArenaService.abortMatch(arenaName, nil, reasonMessage)
end

-- Dipanggil dari PlayerRemoving. Cari match yang melibatkan pemain ini, lalu batalkan.
function ArenaService.handlePlayerLeaving(player)
	playerJumpOriginals[player] = nil
	fallMovementOriginals[player] = nil

	for arenaName, matchInfo in pairs(activeMatches) do
		if table.find(matchInfo.players, player) then
			ArenaService.abortMatch(arenaName, player)
			return
		end
	end
end

function ArenaService.endRound(arenaName, winnerIndex)
	local matchInfo = activeMatches[arenaName]
	if not matchInfo then return end

	-- FIX (race condition -- double-KO): kalau kedua pemain sama-sama gagal
	-- FFYL nyaris bersamaan, FFYLService.handleFailure bisa memanggil
	-- handlePlayerDefeated -> endRound DUA KALI untuk ronde yang sama sebelum
	-- salah satunya sempat menandai ronde ini selesai (task.wait di bawah
	-- bikin fungsi ini yield, jadi guard `roundActive = false` doang tidak
	-- cukup -- reentry kedua tetap lolos karena dia baca matchInfo yang sama
	-- SEBELUM reentry pertama sempat set roundEnding). Tanpa guard ini, skor
	-- kedua pemain bisa ke-increment sekaligus untuk 1 kejadian yang sama,
	-- dan startRound/endMatch bisa terpanggil dobel secara paralel.
	if matchInfo.roundEnding then return end
	matchInfo.roundEnding = true

	-- Jangan cek AFK selama jeda antar ronde di bawah (announce, task.wait, dst).
	matchInfo.roundActive = false

	-- PATCH 10: hentikan semua sesi AI bot saat ronde berakhir.
	-- Bukan hanya loser: winner bot juga tidak perlu mempertahankan decision
	-- loop / AttackStarted listener selama fase fall + jeda ronde. Ronde
	-- berikutnya akan membuat sesi baru lewat BotAIService.start().
	for _, roundPlayer in ipairs(matchInfo.players) do
		if RemoteSafety.isBot(roundPlayer) then
			BotAIService.stop(roundPlayer)
		end
	end

	matchInfo.scores[winnerIndex] = matchInfo.scores[winnerIndex] + 1
	local winner = matchInfo.players[winnerIndex]
	local loser = matchInfo.players[(winnerIndex == 1) and 2 or 1]

	matchInfo.lastLoser = loser

	if winner then
		announce(arenaName, winner.Name .. " wins the round!", 3)
	end

	-- Skor BO3 sudah ter-update di atas, jadi di sinilah titik yang paling
	-- tepat untuk menentukan animasi kalah loser mau pakai yang mana.
	--   - Skor winner sudah >= 2  -> ronde ini SEKALIGUS mengakhiri match -> "defeat" (FellLose)
	--   - Skor winner belum 2     -> ini cuma kalah ronde biasa, match lanjut -> "fall" (New Fell)
	if loser then
		local lossAnimType = (matchInfo.scores[winnerIndex] >= 2) and "defeat" or "fall"
		local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local AttackResultEvent = Remotes and Remotes:FindFirstChild("AttackResultEvent")

		-- Hanya loser yang dilepas dari seat. Winner tetap duduk.
		releaseLoserForFall(loser)

		if RemoteSafety.isBot(loser) then
			BotAnimationService = BotAnimationService or require(ServerScriptService.Core.Service.BotAnimationService)
			BotAnimationService.play(loser, lossAnimType)
		elseif AttackResultEvent then
			RemoteSafety.fire(AttackResultEvent, loser, lossAnimType, true)
		end
	end

	-- Matikan isPlaying agar decay balance berhenti sementara
	for _, player in ipairs(matchInfo.players) do
		PlayerStateRepository.set(player, "isPlaying", false)
	end

	task.wait(3)

	-- Match bisa dibatalkan (pemain keluar) selama jeda di atas
	if activeMatches[arenaName] ~= matchInfo then return end

	-- Best of 3, berarti cari yang sudah 2 poin
	if matchInfo.scores[winnerIndex] >= 2 then
		ArenaService.endMatch(arenaName, winnerIndex)
	else
		matchInfo.currentRound = matchInfo.currentRound + 1
		ArenaService.startRound(arenaName)
	end
end

-- Mengembalikan lawan dari player yang sedang dalam match yang sama.
-- Dipakai CombatController untuk menentukan siapa yang kena pukulan.
function ArenaService.getOpponent(player)
	for _, matchInfo in pairs(activeMatches) do
		local players = matchInfo.players
		if players[1] == player then
			return players[2]
		elseif players[2] == player then
			return players[1]
		end
	end
	return nil
end

-- Ditembak saat seorang pemain kalah FFYL (bukan kalah ronde biasa).
-- Kedua pemain di match yang sama menerima label yang SAMA (diundi di sini,
-- server), supaya teks KO yang tampil di layar mereka identik.
-- Dipanggil dari FFYLService.handleFailure.
function ArenaService.notifyKO(loser)
	for _, matchInfo in pairs(activeMatches) do
		if table.find(matchInfo.players, loser) then
			local label = "K.O.!"
			if KOConfig and KOConfig.LABELS and #KOConfig.LABELS > 0 then
				label = KOConfig.LABELS[math.random(1, #KOConfig.LABELS)]
			end

			if KOEvent then
				-- Teks "K.O.!" tetap tampil di layar KEDUA pemain, tapi kirim
				-- juga flag isLoser supaya CameraController tahu kamera siapa
				-- yang boleh zoom ke muka (FALLEN_CAM) -- cuma yang kalah.
				for _, player in ipairs(matchInfo.players) do
					RemoteSafety.fire(KOEvent, player, label, player == loser)
				end
			end
			return
		end
	end
end

-- Dipanggil oleh BalanceService atau CombatService saat health/balance habis
function ArenaService.handlePlayerDefeated(player)
	for arenaName, matchInfo in pairs(activeMatches) do
		for i, p in ipairs(matchInfo.players) do
			if p == player then
				local winnerIndex = (i == 1) and 2 or 1
				ArenaService.endRound(arenaName, winnerIndex)
				return
			end
		end
	end
end

-- Mulai match pertama kali saat teleport dari Matchmaking
function ArenaService.startMatch(arenaName, players)
	-- Match vs Bot ditandai di sini (BUKAN di-derive ulang tiap butuh) supaya
	-- endMatch tetap bisa tau ini match bot walau bot-nya udah di-destroy
	-- duluan (mis. race dengan abortMatch) -- lihat isBotMatch di endMatch.
	local isBotMatch = false
	for _, player in ipairs(players) do
		if RemoteSafety.isBot(player) then
			isBotMatch = true
			break
		end
	end

	local matchInfo = {
		players = players,
		scores = {0, 0},
		currentRound = 1,
		roundActive = false,
		isBotMatch = isBotMatch,	
	}
	activeMatches[arenaName] = matchInfo

	print("[ArenaService] Match di " .. arenaName .. " dimulai!")

	setMusicState(players, "arena")

	-- Kunci tombol Reset di client selama pemain masih ada di match ini
	-- (semua ronde + jeda transisi), dan mulai pantau AFK (Layer 1) & GB (Layer 2).
	for _, player in ipairs(players) do
		if MatchLockEvent then
			RemoteSafety.fire(MatchLockEvent, player, true)
		end
	end
	matchInfo.afkWatcherActive = true
	startAfkWatcher(arenaName, matchInfo)
	startGbWatcher(arenaName, matchInfo)

	ArenaService.startRound(arenaName)
end

return ArenaService