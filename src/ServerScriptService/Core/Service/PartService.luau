-- @ScriptType: ModuleScript
--[[
    Nama File  : PartService.luau
    Layer      : Service (ServerScriptService/Core/Service)
    Deskripsi  : Mengelola deteksi part berbasis CollectionService (Tag) di Workspace,
                 serta efek visual kelip warna-warni (disco effect).
]]

local CollectionService = game:GetService("CollectionService")

local PartService = {}

-- Tag default yang dicari di Workspace
local DEFAULT_TAG = "part"

-- Kecepatan default kelip (0.2 detik)
local DEFAULT_INTERVAL = 0.1

-- Menyimpan referensi part yang sedang aktif berkedip (mencegah loop ganda)
local activeBlinkingParts: { [BasePart]: boolean } = {}

--- Menghasilkan warna cerah acak (Vibrant Colors) menggunakan format HSV
local function getWarnaAcak(): Color3
	return Color3.fromHSV(math.random(), 1, 1)
end

--- Memastikan suatu instance adalah BasePart dan berada di dalam Workspace
local function isValidWorkspacePart(instance: Instance): boolean
	return instance:IsA("BasePart") and instance:IsDescendantOf(workspace)
end

--- Mengambil semua BasePart yang memiliki tag tertentu di dalam Workspace
-- @param tagName string? (Default: "part")
-- @return { BasePart } Daftar part yang valid di Workspace
function PartService.AmbilSemuaPartDenganTag(tagName: string?): { BasePart }
	local tag = tagName or DEFAULT_TAG
	local hasil: { BasePart } = {}

	-- Ambil semua instance dengan tag utama
	local taggedList = CollectionService:GetTagged(tag)

	-- Dukung juga variasi huruf kapital (misal "Part" dan "part") agar tidak gagal karena typo
	local alternateTag = if tag == "part" then "Part" elseif tag == "Part" then "part" else nil
	if alternateTag then
		for _, inst in ipairs(CollectionService:GetTagged(alternateTag)) do
			if not table.find(taggedList, inst) then
				table.insert(taggedList, inst)
			end
		end
	end

	for _, inst in ipairs(taggedList) do
		-- Filter HANYA yang merupakan BasePart dan berada di dalam Workspace
		if isValidWorkspacePart(inst) then
			table.insert(hasil, inst :: BasePart)
		end
	end

	-- Fallback cerdas: jika belum ada part ber-tag, cari part bernama "Part" di Workspace
	if #hasil == 0 then
		local fallbackPart = workspace:FindFirstChild("Part")
		if fallbackPart and isValidWorkspacePart(fallbackPart) then
			table.insert(hasil, fallbackPart :: BasePart)
		end
	end

	return hasil
end

--- Membuat Part berkedip warna-warni secara terus-menerus setiap interval detik
-- @param targetPart BasePart (Part yang ingin dikelipkan)
-- @param interval number? (Jeda waktu, default 0.2 detik)
function PartService.GantiWarna(targetPart: BasePart, interval: number?)
	if not isValidWorkspacePart(targetPart) then
		warn("[PartService] Target part tidak valid atau tidak berada di Workspace:", targetPart)
		return
	end

	-- Mencegah part menjalankan beberapa loop kelip secara bersamaan
	if activeBlinkingParts[targetPart] then
		return
	end
	activeBlinkingParts[targetPart] = true

	local jeda = interval or DEFAULT_INTERVAL

	-- 1. Efek Neon agar part menyala terang
	targetPart.Material = Enum.Material.Neon

	-- 2. Pasang PointLight jika belum ada agar memancarkan cahaya ke sekitar
	local light = targetPart:FindFirstChildOfClass("PointLight")
	if not light then
		light = Instance.new("PointLight")
		light.Brightness = 2
		light.Range = 15
		light.Parent = targetPart
	end

	-- 3. Jalankan loop di thread terpisah (task.spawn)
	task.spawn(function()
		while targetPart and targetPart.Parent and activeBlinkingParts[targetPart] do
			local warnaBaru = getWarnaAcak()
			targetPart.Color = warnaBaru

			if light and light.Parent == targetPart then
				light.Color = warnaBaru
			end

			task.wait(jeda)
		end
		activeBlinkingParts[targetPart] = nil
	end)
end

--- Menghentikan efek kelip pada part tertentu
-- @param targetPart BasePart
function PartService.HentikanKelip(targetPart: BasePart)
	if activeBlinkingParts[targetPart] then
		activeBlinkingParts[targetPart] = nil
	end
end

--- Memulai pendeteksi part dengan Tag di Workspace
-- Mengambil semua part yang sudah ada + mendengarkan part baru yang diberi tag secara realtime
-- @param tagName string? (Default: "part")
-- @param interval number? (Default: 0.2 detik)
function PartService.MulaiPendeteksi(tagName: string?, interval: number?)
	local tag = tagName or DEFAULT_TAG
	local jeda = interval or DEFAULT_INTERVAL

	print(string.format("[PartService] 🔍 Memulai pendeteksi untuk tag '%s' di Workspace...", tag))

	-- 1. Ambil semua part yang SUDAH ADA saat ini di Workspace dengan tag tersebut
	local partsSaatIni = PartService.AmbilSemuaPartDenganTag(tag)
	print(string.format("[PartService] ✅ Ditemukan %d part dengan tag '%s' di Workspace:", #partsSaatIni, tag))

	for i, part in ipairs(partsSaatIni) do
		print(string.format("   [%d] %s (Lokasi: %s)", i, part:GetFullName(), tostring(part.Position)))
		PartService.GantiWarna(part, jeda)
	end

	-- Helper untuk memasang listener penambahan dan pelepasan tag secara realtime
	local function pasangListener(targetTag: string)
		-- 2. Deteksi REALTIME jika ada part baru yang diberi tag saat game berjalan
		CollectionService:GetInstanceAddedSignal(targetTag):Connect(function(inst)
			task.wait() -- Jeda singkat jika part baru di-clone ke Workspace
			if isValidWorkspacePart(inst) then
				print(string.format("[PartService] ➕ Part baru ber-tag '%s' terdeteksi di Workspace: %s", targetTag, inst:GetFullName()))
				PartService.GantiWarna(inst :: BasePart, jeda)
			end
		end)

		-- 3. Deteksi jika tag dicopot dari instance
		CollectionService:GetInstanceRemovedSignal(targetTag):Connect(function(inst)
			if inst:IsA("BasePart") then
				print(string.format("[PartService] ➖ Tag '%s' dilepas dari: %s", targetTag, inst:GetFullName()))
				PartService.HentikanKelip(inst)
			end
		end)
	end

	pasangListener(tag)
	if tag == "part" then
		pasangListener("Part")
	end
end

--- Inisialisasi otomatis Service saat server mulai
function PartService.init()
	PartService.MulaiPendeteksi(DEFAULT_TAG, DEFAULT_INTERVAL)
end

return PartService
