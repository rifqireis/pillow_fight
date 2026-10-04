-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : MatchmakingService
    Layer      : Service (ServerScriptService/Core/Service)
    Deskripsi  : Mengelola antrean arena teleporter, sistem penguncian arena,
                 sinkronisasi UI countdown, penguncian pergerakan & posisi tunggu pemain,
                 serta mekanisme pembatalan antrean via lompatan (Jump).
    Penulis    : Vikri Abdullah [Epik]
    Tanggal    : 27 Juni 2026
    Diubah     : 17 Agustus 2026 -- Fase 6: tambah remote BotButtonVisibilityEvent
                 (auto-created, satu arah server->client) buat nyalain/nyembuniin
                 tombol "Lawan Bot" di client -- ditembak tiap kali pemain
                 masuk/keluar dari kondisi "sendirian di antrean". Lihat
                 showBotButton/hideBotButton.
                 17 Agustus 2026 -- item #8: skip RepeatOpponentService.isPairOnCooldown
                 di addPlayerToQueue kalau salah satu pihak bot (UserId bot
                 selalu baru, gak mungkin kena cooldown) -- ngindarin yield
                 DataStore yang gak perlu, penting buat jalur tombol "Lawan Bot"
                 yang niatnya instant.
    Versi      : 3.3
    Dependensi : PlayerStateRepository, GameplayConfig, ArenaService, RemoteSafety
]]

local MatchmakingService = {}

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local PlayerStateRepository = require(ServerScriptService.Core.Repository.PlayerStateRepository)
local GameplayConfig = require(ReplicatedStorage.Configs.GameplayConfig)
local BotConfig = require(ReplicatedStorage.Configs.BotConfig)
local RemoteSafety = require(ServerScriptService.Core.Service.RemoteSafety)

local ArenaService -- Require secara lazy untuk menghindari circular dependency
local BotService -- Require secara lazy (auto-trigger bot 15 detik -- lihat startAutoMatchTimer)
local RepeatOpponentService -- Require secara lazy (Layer 3 -- lihat addPlayerToQueue)

-- Fase 6: remote show/hide tombol "Lawan Bot" ke client. Beda dari
-- RequestBotMatchEvent (yang WAJIB dibuat manual di Studio -- lihat catatan
-- di task.spawn paling bawah file ini), remote ini AMAN dibikin otomatis
-- lewat getOrCreateRemote: cuma sinyal SATU ARAH server->client (boolean
-- show/hide), gak ada input dari client yang perlu divalidasi/rawan
-- dispoof, jadi gak perlu jaga-jaga instance manual kayak RequestBotMatchEvent.
--
-- Dibuat SINKRON di module-load time (bukan di dalam task.spawn) supaya gak
-- ada jendela race di mana addPlayerToQueue/removePlayerFromQueue kepanggil
-- (mis. pemain langsung nginjek teleporter begitu server baru nyala) SEBELUM
-- remote-nya sempat ke-create -- polanya sama kayak EnergyService/BalanceService
-- yang juga WaitForChild("Remotes") sinkron di top-level module.
local function getOrCreateRemote(parent, name)
	local remote = parent:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = parent
	end
	return remote
end

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local BotButtonVisibilityEvent = getOrCreateRemote(remotesFolder, "BotButtonVisibilityEvent")

-- Nongolin/nyembuniin tombol "Lawan Bot" di client pemain tertentu.
-- RemoteSafety.fire sudah otomatis no-op kalau targetnya bot (proxy table,
-- bukan Instance Player asli), jadi aman dipanggil tanpa guard tambahan di
-- pemanggilnya -- termasuk saat loop ke seluruh isi queue yang mungkin
-- berisi campuran pemain asli & bot.
local function showBotButton(player)
	RemoteSafety.fire(BotButtonVisibilityEvent, player, true)
end

local function hideBotButton(player)
	RemoteSafety.fire(BotButtonVisibilityEvent, player, false)
end

local arenaTeleporterQueues = {}
local activeCountdowns = {}
local arenaOccupiedStates = {}
local autoMatchTimers = {} -- per-arena timer thread, lihat startAutoMatchTimer

-- State penguncian pergerakan per pemain
local playerJumpConnections = {}
local playerDiedConnections = {}
local playerOriginalWalkSpeed = {}

-- Helper: Mencari arena tempat pemain sedang terdaftar dalam antrean
local function findPlayerCurrentQueueArena(player)
	for arenaTeleporterName, queue in pairs(arenaTeleporterQueues) do
		if table.find(queue, player) then
			return arenaTeleporterName
		end
	end
	return nil
end

-- Helper: Mengambil TextLabel dari BillboardGui teleporter
local function getCountdownLabel(arenaTeleporterName)
	local folder = GameplayConfig.getArenaTeleporterFolder(arenaTeleporterName)
	if not folder then return nil end

	local teleporter = folder:FindFirstChild("Teleporter")
	if teleporter then
		local gui = teleporter:FindFirstChildOfClass("BillboardGui")
		if gui then
			return gui:FindFirstChildOfClass("TextLabel")
		end
	end
	return nil
end

-- Helper: Mengambil CFrame titik tunggu (WaitPoint1/WaitPoint2) di dalam teleporter
local function getWaitPointCFrame(arenaTeleporterName, slotIndex)
	local folder = GameplayConfig.getArenaTeleporterFolder(arenaTeleporterName)
	if not folder then return nil end

	local teleporter = folder:FindFirstChild("Teleporter")
	if not teleporter then return nil end

	local waitPointName = "WaitPoint" .. slotIndex
	local waitPoint = teleporter:FindFirstChild(waitPointName)
	if not waitPoint then return nil end

	if waitPoint:IsA("BasePart") then
		return waitPoint.CFrame
	elseif waitPoint:IsA("Attachment") then
		return waitPoint.WorldCFrame
	end

	return nil
end

-- Membuka kunci pergerakan pemain dan melepas listener event
local function unlockPlayerMovement(player)
	if playerJumpConnections[player] then
		playerJumpConnections[player]:Disconnect()
		playerJumpConnections[player] = nil
	end

	if playerDiedConnections[player] then
		playerDiedConnections[player]:Disconnect()
		playerDiedConnections[player] = nil
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = playerOriginalWalkSpeed[player] or 16
		humanoid.AutoRotate = true
		humanoid.Jump = false
	end

	playerOriginalWalkSpeed[player] = nil
end

local removePlayerFromQueueInternal

-- Mengunci pergerakan pemain di titik tunggu dan mendaftarkan listener batal (Jump)
local function lockPlayerMovement(player, arenaTeleporterName, slotIndex)
	local character = player.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart then return end

	-- Putuskan koneksi lama dulu (fungsi ini bisa dipanggil ulang saat reposisi antrean)
	if playerJumpConnections[player] then
		playerJumpConnections[player]:Disconnect()
		playerJumpConnections[player] = nil
	end
	if playerDiedConnections[player] then
		playerDiedConnections[player]:Disconnect()
		playerDiedConnections[player] = nil
	end

	local waitCFrame = getWaitPointCFrame(arenaTeleporterName, slotIndex)
	if waitCFrame then
		local modelSize = character:GetExtentsSize()
		local standOffsetY = (modelSize.Y / 2) + 0.05

		local standPosition = waitCFrame.Position + Vector3.new(0, standOffsetY, 0)
		local facingTarget = standPosition + waitCFrame.LookVector
		local finalCFrame = CFrame.lookAt(standPosition, facingTarget)

		rootPart.CFrame = finalCFrame
	end

	-- Simpan WalkSpeed asli cuma sekali; kalau sudah terkunci (dipanggil ulang saat
	-- reposisi antrean), jangan timpa dengan 0
	if playerOriginalWalkSpeed[player] == nil then
		playerOriginalWalkSpeed[player] = humanoid.WalkSpeed
	end
	humanoid.WalkSpeed = 0
	humanoid.AutoRotate = false

	-- BUG FIX (kaki gak rapat/nyangkut di pose jalan atau lompat pas nunggu
	-- di titik antrean): WalkSpeed=0 doang gak bikin Animate LocalScript
	-- langsung balik ke pose idle -- kalau pemain kebetulan lagi jalan/
	-- lompat PERSIS saat masuk antrean, humanoid state-nya masih "Running"/
	-- "Jumping" (dan rootPart masih punya sisa velocity dari sebelumnya),
	-- jadi animasinya nyangkut di pose itu walau badannya udah gak bisa
	-- gerak lagi. Bersihin sisa velocity + paksa state ke "Landed" supaya
	-- Animate langsung baca ulang & snap ke idle stance.
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	humanoid:ChangeState(Enum.HumanoidStateType.Landed)

	playerJumpConnections[player] = humanoid.StateChanged:Connect(function(_, newState)
		if newState ~= Enum.HumanoidStateType.Jumping then return end

		local currentArena = findPlayerCurrentQueueArena(player)
		if not currentArena or arenaOccupiedStates[currentArena] then return end

		removePlayerFromQueueInternal(player, currentArena)
	end)

	playerDiedConnections[player] = humanoid.Died:Connect(function()
		MatchmakingService.removePlayerFromAllQueues(player)
	end)
end

-- Menata ulang slot semua pemain yang tersisa di antrean sesuai posisi terbaru mereka
-- di array (WaitPoint1, WaitPoint2, dst). Wajib dipanggil tiap kali ada pemain yang
-- keluar dari antrean, supaya slot yang kosong di depan tidak bikin pemain lain
-- "menumpuk" di slot yang sama.
local function repositionQueue(arenaTeleporterName)
	local queue = arenaTeleporterQueues[arenaTeleporterName]
	if not queue then return end

	for index, remainingPlayer in ipairs(queue) do
		lockPlayerMovement(remainingPlayer, arenaTeleporterName, index)
	end
end

-- Membatalkan hitung mundur antrean
local function cancelCountdown(arenaTeleporterName)
	if not activeCountdowns[arenaTeleporterName] then return end

	task.cancel(activeCountdowns[arenaTeleporterName])
	activeCountdowns[arenaTeleporterName] = nil

	local textLabel = getCountdownLabel(arenaTeleporterName)
	if textLabel then
		textLabel.Text = ""
	end

	print("[MatchmakingService] Countdown di " .. arenaTeleporterName .. " dibatalkan.")
end

-- Membatalkan timer auto-trigger bot (dipanggil kapan pun kondisi antrean
-- berubah -- pemain baru join, pemain keluar, atau match sudah mulai --
-- biar timer lama gak nyala nyasar buat kondisi yang udah gak berlaku).
local function cancelAutoMatchTimer(arenaTeleporterName)
	if not autoMatchTimers[arenaTeleporterName] then return end

	task.cancel(autoMatchTimers[arenaTeleporterName])
	autoMatchTimers[arenaTeleporterName] = nil
end

-- Menyalakan timer: kalau slot ke-2 masih kosong setelah
-- BotConfig.AUTO_MATCH_WAIT_SECONDS detik, otomatis isi pakai bot supaya
-- pemain yang sendirian gak nunggu tanpa lawan selamanya di server sepi.
local function startAutoMatchTimer(arenaTeleporterName)
	if autoMatchTimers[arenaTeleporterName] then return end -- sudah jalan, idempoten

	autoMatchTimers[arenaTeleporterName] = task.delay(BotConfig.AUTO_MATCH_WAIT_SECONDS, function()
		autoMatchTimers[arenaTeleporterName] = nil

		-- Re-cek kondisi SETELAH nunggu -- banyak hal bisa berubah selama
		-- 15 detik (arena kepakai, pemain keluar, dst). Cuma lanjut bikin
		-- bot kalau kondisinya PERSIS masih "1 pemain sendirian nunggu",
		-- biar gak ada bot nyasar/nyangkut dibikin buat kondisi yang udah
		-- gak relevan lagi.
		if arenaOccupiedStates[arenaTeleporterName] then return end

		local queue = arenaTeleporterQueues[arenaTeleporterName]
		if not queue or #queue ~= 1 then return end

		print("[MatchmakingService] " .. arenaTeleporterName .. " sendirian " .. BotConfig.AUTO_MATCH_WAIT_SECONDS .. "s -- auto-isi slot ke-2 pakai bot.")

		BotService = BotService or require(ServerScriptService.Core.Service.BotService)
		local bot = BotService.create()

		MatchmakingService.addPlayerToQueue(bot, arenaTeleporterName)
	end)
end

-- Menjalankan teleportasi dan memutus sesi matchmaking ke permainan
local function teleportToArena(arenaTeleporterName)
	local queue = arenaTeleporterQueues[arenaTeleporterName]
	if not queue or #queue < GameplayConfig.MAX_TELEPORTER_PLAYERS then return end

	print("[MatchmakingService] Memulai pertandingan di arena " .. arenaTeleporterName)

	arenaOccupiedStates[arenaTeleporterName] = true

	for _, player in ipairs(queue) do
		PlayerStateRepository.set(player, "isInMatchmaking", false)
		unlockPlayerMovement(player)
	end

	local textLabel = getCountdownLabel(arenaTeleporterName)
	if textLabel then
		textLabel.Text = "MATCH START!"
		task.delay(1, function()
			if textLabel.Text == "MATCH START!" then
				textLabel.Text = ""
			end
		end)
	end

	ArenaService = ArenaService or require(ServerScriptService.Core.Service.ArenaService)
	ArenaService.startMatch(arenaTeleporterName, table.clone(queue))

	table.clear(queue)
	activeCountdowns[arenaTeleporterName] = nil
end

-- Memulai hitung mundur pembuatan pertandingan
local function startMatchmakingCountdown(arenaTeleporterName)
	if activeCountdowns[arenaTeleporterName] then return end

	print("[MatchmakingService] Teleporter " .. arenaTeleporterName .. " penuh. Countdown dimulai.")

	activeCountdowns[arenaTeleporterName] = task.spawn(function()
		local timeLeft = GameplayConfig.MATCHMAKING_COUNTDOWN
		local textLabel = getCountdownLabel(arenaTeleporterName)

		while timeLeft > 0 do
			if textLabel then
				textLabel.Text = "Starting in: " .. tostring(timeLeft) .. "s"
			end
			task.wait(1)
			timeLeft = timeLeft - 1
		end

		teleportToArena(arenaTeleporterName)
	end)
end

-- Menambahkan pemain ke antrean arena
function MatchmakingService.addPlayerToQueue(player, arenaTeleporterName)
	if arenaOccupiedStates[arenaTeleporterName] then
		return
	end

	if not arenaTeleporterQueues[arenaTeleporterName] then
		arenaTeleporterQueues[arenaTeleporterName] = {}
	end

	local queue = arenaTeleporterQueues[arenaTeleporterName]
	if #queue >= GameplayConfig.MAX_TELEPORTER_PLAYERS then return end
	if table.find(queue, player) then return end

	local playerState = PlayerStateRepository.get(player)
	if playerState and playerState.isInMatchmaking then return end

	-- FIX (race condition -- lihat catatan di bawah): tandai pemain ini
	-- SEDANG diproses SEBELUM melakukan apa pun yang bisa nge-yield
	-- coroutine (cek cooldown Layer 3 di bawah manggil DataStore lewat
	-- RepeatOpponentService.isPairOnCooldown, yang yield saat cache-miss).
	--
	-- Kenapa ini penting: teleporter.Touched di MatchController nembak
	-- BERKALI-KALI dalam 1 frame yang sama -- sekali per BasePart karakter
	-- (R15 punya belasan part) yang nyentuh pad teleporter secara bersamaan.
	-- Guard isInMatchmaking di MatchController cuma snapshot sinkron; kalau
	-- flag ini baru di-set TRUE setelah yield di bawah, beberapa Touched
	-- yang nembak nyaris bersamaan bisa lolos SEMUA guard sebelum salah
	-- satunya sempat benar-benar insert ke queue. Akibatnya 1 pemain bisa
	-- ke-insert DOBEL ke queue yang sama (queue jadi 3 pemain padahal
	-- MAX_TELEPORTER_PLAYERS = 2) -- ini yang bikin ArenaService:243 crash
	-- "attempt to index nil with 'IsA'" (spawns cuma ada 2 slot, tapi
	-- player ke-3 minta spawns[3] yang nil).
	--
	-- Dengan flag di-set SINKRON di sini (sebelum yield manapun), semua
	-- Touched lain buat pemain yang SAMA bakal langsung ke-block oleh
	-- guard `playerState.isInMatchmaking` di atas.
	PlayerStateRepository.set(player, "isInMatchmaking", true)

	-- Layer 3 (§6 design doc, anti-farming.md): sebelum benar-benar
	-- dimasukkan, cek apakah pemain ini sedang cooldown farming terhadap
	-- salah satu pemain yang SUDAH ada di antrean teleporter ini. Codebase
	-- ini tidak punya "pool" kandidat matchmaking untuk dicoba gantian
	-- (lihat catatan implementasi di RepeatOpponentService.lua) -- jadi yang
	-- paling pas cuma menolak join-nya di sini. Pemain yang sudah menunggu
	-- TIDAK ikut terusir; pemain yang ditolak tetap bebas antre di
	-- teleporter lain / lawan pemain lain.
	--
	-- OPTIMISASI (17 Agustus 2026, item #8): skip pengecekan ini sepenuhnya
	-- kalau salah satu pihak (yang mau masuk ATAU yang udah di queue) adalah
	-- bot. UserId bot SELALU baru tiap kali di-create (lihat
	-- BotConfig.USERID_BASE + nextBotSuffix di BotService), jadi gak akan
	-- PERNAH kena cooldown -- isPairOnCooldown pasti balikin false di ujungnya
	-- juga, cuma kebuang 1x DataStore:GetAsync (yield) yang gak perlu. Ini
	-- penting terutama buat jalur tombol "Lawan Bot" (requestBotMatch) yang
	-- niatnya emang instant, jangan ada delay DataStore yang gak berguna.
	BotService = BotService or require(ServerScriptService.Core.Service.BotService)
	if not BotService.isBotPlayer(player) then
		RepeatOpponentService = RepeatOpponentService or require(ServerScriptService.Core.Service.RepeatOpponentService)
		for _, queuedPlayer in ipairs(queue) do
			if not BotService.isBotPlayer(queuedPlayer) then
				local onCooldown, remainingSeconds = RepeatOpponentService.isPairOnCooldown(player, queuedPlayer)
				if onCooldown then
					local remainingMinutes = math.max(1, math.ceil(remainingSeconds / 60))
					print("[MatchmakingService] " .. player.Name .. " ditolak masuk antrean " .. arenaTeleporterName .. " -- cooldown farming vs " .. queuedPlayer.Name .. " (" .. remainingMinutes .. " menit tersisa).")

					-- Rollback: batal masuk queue, jangan biarkan flag nyangkut true
					-- padahal pemain ini gak jadi ke-insert.
					PlayerStateRepository.set(player, "isInMatchmaking", false)

					ArenaService = ArenaService or require(ServerScriptService.Core.Service.ArenaService)
					ArenaService.announceToPlayers(
						{ player },
						"MATCHED WITH THIS OPPONENT TOO OFTEN - TRY SOMEONE ELSE (" .. remainingMinutes .. "m)",
						4
					)
					return
				end
			end
		end
	end

	-- Re-cek kapasitas & duplikat SETELAH yield di atas -- selagi kita
	-- nunggu DataStore, bisa saja pemain LAIN keburu ngisi slot terakhir,
	-- atau (dalam kasus ekstrem) pemain ini sendiri sempat ke-proses lewat
	-- jalur lain. Jangan sampai lolos ke table.insert kalau kondisinya udah
	-- berubah.
	if #queue >= GameplayConfig.MAX_TELEPORTER_PLAYERS or table.find(queue, player) then
		PlayerStateRepository.set(player, "isInMatchmaking", false)
		return
	end

	table.insert(queue, player)
	print("[MatchmakingService] " .. player.Name .. " memasuki antrean " .. arenaTeleporterName)

	local slotIndex = #queue
	lockPlayerMovement(player, arenaTeleporterName, slotIndex)

	if #queue == GameplayConfig.MAX_TELEPORTER_PLAYERS then
		-- Slot penuh (baik ke-isi pemain asli maupun bot) -- tombol "Lawan
		-- Bot" gak relevan lagi buat siapa pun di antrean ini, sembunyikan
		-- ke semua isi queue (bot otomatis di-skip lewat RemoteSafety.fire).
		for _, queuedPlayer in ipairs(queue) do
			hideBotButton(queuedPlayer)
		end

		-- Gak perlu nunggu lagi, batalkan timer auto-bot kalau kebetulan
		-- masih aktif.
		cancelAutoMatchTimer(arenaTeleporterName)
		startMatchmakingCountdown(arenaTeleporterName)
	elseif #queue == 1 then
		-- Pemain pertama & sendirian di antrean ini -- nongolin tombol
		-- "Lawan Bot" (client yang nentuin tampil-tidaknya secara visual,
		-- tapi sinyalnya aman ditembak ke siapa pun lewat RemoteSafety) &
		-- mulai hitung mundur AUTO_MATCH_WAIT_SECONDS buat auto-isi bot
		-- kalau gak ada yang nyusul.
		showBotButton(player)
		startAutoMatchTimer(arenaTeleporterName)
	end
end

-- BUGFIX (17 Agustus 2026): Kondisi antrean bisa jadi TEPAT 1 sisa peserta
-- setelah seseorang keluar dengan DUA cara -- (a) pemain asli yang sendirian
-- keluar sebelum bot sempat ikut, ATAU (b) pemain asli keluar SETELAH bot
-- sudah kepasang jadi slot ke-2 (mis. disconnect/jump-cancel selagi
-- countdown 3 detik masih jalan) -- kasus (b) ini yang sebelumnya kelewat:
-- table.remove di atas cuma nyabut si pemain lewat identity match, bot yang
-- udah nempel di queue TETAP ada, jadi #queue balik ke 1 tapi isinya bot,
-- bukan orang. Tanpa guard ini, auto-timer 15 detik nyala lagi buat bot itu
-- SENDIRI, dan begitu habis waktu, server bikin bot KEDUA buat dipasangin --
-- hasilnya bot vs bot ngabisin slot arena tanpa ada pemain sungguhan.
--
-- Jadi sebelum restart auto-timer, cek dulu sisa 1 peserta itu bot atau
-- bukan (BotService.isBotPlayer). Kalau bot -- buang dari queue & destroy,
-- JANGAN nyalain timer (gak ada gunanya nunggu buat dipasangin bot lain).
-- Kalau pemain asli -- perilaku lama tetap jalan (nyalain auto-timer).
local function handleSoloQueueAfterRemoval(arenaTeleporterName, queue)
	if #queue ~= 1 then return end

	BotService = BotService or require(ServerScriptService.Core.Service.BotService)
	if BotService.isBotPlayer(queue[1]) then
		local orphanBot = queue[1]
		table.remove(queue, 1)
		print("[MatchmakingService] Bot " .. tostring(orphanBot.Name) .. " ketinggalan sendirian di " .. arenaTeleporterName .. " -- dibuang & di-destroy, gak dipasangin bot lain.")
		BotService.destroy(orphanBot)
		return
	end

	-- Sisa 1 peserta itu pemain asli -- situasinya baru aja balik jadi
	-- "sendirian nunggu di antrean" (mis. lawannya barusan keluar), jadi
	-- nongolin lagi tombol "Lawan Bot" buat dia sebelum nyalain auto-timer.
	showBotButton(queue[1])
	startAutoMatchTimer(arenaTeleporterName)
end

-- Menghapus pemain dari antrean arena spesifik
function MatchmakingService.removePlayerFromQueue(player, arenaTeleporterName)
	if arenaOccupiedStates[arenaTeleporterName] then return end

	local queue = arenaTeleporterQueues[arenaTeleporterName]
	if not queue then return end

	local index = table.find(queue, player)
	if not index then return end

	table.remove(queue, index)
	PlayerStateRepository.set(player, "isInMatchmaking", false)
	unlockPlayerMovement(player)
	-- Pemain ini keluar antrean sepenuhnya (bukan cuma kegeser slot) --
	-- tombol "Lawan Bot" gak relevan lagi buat dia, tutup aja. Kalau
	-- sebelumnya dia gak lagi sendirian (jadi tombolnya emang udah gak
	-- kelihatan), ini cuma no-op di client.
	hideBotButton(player)
	print("[MatchmakingService] " .. player.Name .. " meninggalkan antrean " .. arenaTeleporterName)

	-- Reposisi sisa pemain di antrean supaya nggak numpuk di 1 slot
	repositionQueue(arenaTeleporterName)

	if #queue < GameplayConfig.MAX_TELEPORTER_PLAYERS then
		cancelCountdown(arenaTeleporterName)
	end

	-- Kondisi antrean berubah -- batalkan timer auto-bot yang lama, lalu
	-- tangani sisa antrean (lihat handleSoloQueueAfterRemoval: bisa jadi
	-- nyalain ulang timer buat pemain asli yang sendirian, ATAU buang bot
	-- yang ketinggalan sendirian -- lihat catatan bugfix di atas).
	cancelAutoMatchTimer(arenaTeleporterName)
	handleSoloQueueAfterRemoval(arenaTeleporterName, queue)
end

removePlayerFromQueueInternal = MatchmakingService.removePlayerFromQueue

-- Menghapus pemain dari seluruh antrean (dipakai saat disconnect atau reset)
function MatchmakingService.removePlayerFromAllQueues(player)
	for arenaTeleporterName, queue in pairs(arenaTeleporterQueues) do
		local index = table.find(queue, player)
		if index then
			table.remove(queue, index)
			PlayerStateRepository.set(player, "isInMatchmaking", false)
			unlockPlayerMovement(player)
			-- Sama kayak removePlayerFromQueue: dia keluar antrean
			-- sepenuhnya, tutup tombol "Lawan Bot" buat dia.
			hideBotButton(player)
			print("[MatchmakingService] " .. player.Name .. " keluar dari game, dicabut dari antrean " .. arenaTeleporterName)

			-- Reposisi sisa pemain di antrean supaya nggak numpuk di 1 slot
			repositionQueue(arenaTeleporterName)

			if #queue < GameplayConfig.MAX_TELEPORTER_PLAYERS then
				cancelCountdown(arenaTeleporterName)
			end

			-- Sama kayak removePlayerFromQueue: reset timer auto-bot sesuai
			-- kondisi antrean terbaru, DAN pakai guard orphan-bot yang sama
			-- (lihat catatan bugfix di handleSoloQueueAfterRemoval). Jalur ini
			-- (disconnect via PlayerRemoving) justru yang paling sering kena
			-- kasus (b) -- pemain kabur pas countdown 3 detik masih jalan,
			-- ninggalin bot sendirian di queue.
			cancelAutoMatchTimer(arenaTeleporterName)
			handleSoloQueueAfterRemoval(arenaTeleporterName, queue)
		end
	end
end

-- Guard rapid double-fire tombol "Lawan Bot" -- lihat catatan di dalam
-- requestBotMatch soal kenapa ini perlu.
local pendingBotRequests = {} -- pendingBotRequests[arenaTeleporterName] = true selagi lagi diproses

-- Fase 5: shortcut manual buat pemain yang lagi SENDIRIAN nunggu di antrean
-- -- langsung isi slot ke-2 pakai bot, gak usah nunggu
-- BotConfig.AUTO_MATCH_WAIT_SECONDS. Numpang jalur yang SAMA PERSIS kayak
-- auto-trigger di startAutoMatchTimer (BotService.create() +
-- addPlayerToQueue) biar semua guard/anti-abuse/cleanup yang udah ada
-- (isBotMatch, RepeatOpponentService, isInMatchmaking, dst) otomatis
-- kepakai juga di sini tanpa duplikasi logic.
--
-- Dipanggil dari OnServerEvent RequestBotMatchEvent -- `player` di sini
-- SELALU Instance Player asli yang beneran fire remote-nya (gak bisa
-- dispoof dari client), jadi gak perlu validasi identitas tambahan --
-- cukup validasi STATE antreannya.
function MatchmakingService.requestBotMatch(player)
	local arenaTeleporterName = findPlayerCurrentQueueArena(player)
	if not arenaTeleporterName then
		-- Pemain gak lagi kedaftar di antrean mana pun (mis. tombol sempat
		-- kepencet pas race UI belum sempat hide, atau match udah keburu
		-- mulai) -- diamkan aja, client-side juga udah nge-guard tombol
		-- cuma nongol pas lagi di antrean.
		return
	end

	if arenaOccupiedStates[arenaTeleporterName] then return end

	local queue = arenaTeleporterQueues[arenaTeleporterName]
	if not queue or #queue ~= 1 then
		-- Slot ke-2 udah keisi (pemain lain / bot lain nyusul duluan) atau
		-- state race lain -- gak usah bikin bot tambahan yang gak perlu.
		return
	end

	-- addPlayerToQueue di bawah bisa YIELD (cek cooldown farming lewat
	-- RepeatOpponentService, yang nyentuh DataStore saat cache-miss).
	-- Tanpa guard ini, antara request PERTAMA mulai proses dan bot
	-- pertamanya beneran ke-insert ke queue, ada jendela waktu di mana
	-- request KEDUA (dobel-klik/spam tombol) masih lolos cek "#queue == 1"
	-- di atas -- karena bot pertama belum sempat masuk queue -- dan bisa
	-- bikin 2 bot dibuat berebut 1 slot yang sama. Flag ini nutup jendela
	-- itu; selalu dibersihkan lewat pcall di bawah biar gak nyangkut true
	-- selamanya kalau addPlayerToQueue somehow error.
	if pendingBotRequests[arenaTeleporterName] then return end
	pendingBotRequests[arenaTeleporterName] = true

	print("[MatchmakingService] " .. player.Name .. " minta lawan bot manual (tombol) di " .. arenaTeleporterName)

	-- Batalkan timer auto-trigger 15 detik yang mungkin masih jalan --
	-- addPlayerToQueue juga bakal cancel ini pas queue penuh, tapi cancel
	-- di sini duluan biar niatnya eksplisit & gak gantung ke efek samping.
	cancelAutoMatchTimer(arenaTeleporterName)

	BotService = BotService or require(ServerScriptService.Core.Service.BotService)
	local bot = BotService.create()

	local ok, err = pcall(function()
		MatchmakingService.addPlayerToQueue(bot, arenaTeleporterName)
	end)
	pendingBotRequests[arenaTeleporterName] = nil

	if not ok then
		warn("[MatchmakingService] requestBotMatch gagal insert bot: " .. tostring(err))
		BotService.destroy(bot)
	end
end

-- Membebaskan status arena agar dapat digunakan kembali
function MatchmakingService.freeArena(arenaTeleporterName)
	arenaOccupiedStates[arenaTeleporterName] = false

	local textLabel = getCountdownLabel(arenaTeleporterName)
	if textLabel then
		textLabel.Text = ""
	end

	print("[MatchmakingService] " .. arenaTeleporterName .. " telah kosong dan siap digunakan kembali.")
end

-- Cleanup otomatis jika pemain meninggalkan permainan
Players.PlayerRemoving:Connect(function(player)
	MatchmakingService.removePlayerFromAllQueues(player)
end)

-- Fase 5: sambungkan tombol "Lawan Bot" client ke requestBotMatch. Remote
-- ini dibuat MANUAL di Studio (ReplicatedStorage/Remotes/RequestBotMatchEvent,
-- gak kelihatan lewat export zip) -- pakai WaitForChild, bukan getOrCreateRemote,
-- karena instance-nya emang harus udah ada duluan, bukan dibikin runtime.
task.spawn(function()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
	local RequestBotMatchEvent = remotesFolder:WaitForChild("RequestBotMatchEvent")

	RequestBotMatchEvent.OnServerEvent:Connect(function(player)
		MatchmakingService.requestBotMatch(player)
	end)
end)

return MatchmakingService