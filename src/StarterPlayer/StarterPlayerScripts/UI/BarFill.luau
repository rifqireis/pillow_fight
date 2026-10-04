-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
-- @ScriptType: ModuleScript
--[[
    Nama File  : BarFill
    Layer      : Client (UI)
    Deskripsi  : Helper bar yang MEMOTONG gambar dari ujung, bukan menggepengkannya.

                 Cara lama mengecilkan Size bar, jadi seluruh gambar ikut
                 mengkerut — bagian tebal bar langsung menipis padahal drain-nya
                 baru sedikit. Di sini ukuran bar TIDAK PERNAH diubah; yang
                 diubah cuma UIGradient di dalamnya, yang menutup bagian sisa
                 dengan transparansi. Bentuk asli gambar jadi utuh dan bagian
                 tipis di ujung habis lebih dulu, persis seperti aslinya.

                 Arah potong ikut UIGradient.Rotation di Studio:
                   0   -> habis dari kanan (panel HpLeft)
                   180 -> habis dari kiri  (panel HpRight yang dicerminkan)

                 Ada dua mode isi:
                   "edge"   -> tumbuh dari satu ujung ke ujung lain (default,
                               dipakai bar balance & energy)
                   "center" -> tumbuh dari tengah melebar ke dua sisi sekaligus
                               (dipakai bar FFYL)
    Tanggal    : 01 Agustus 2026
    Diubah     : 02 Agustus 2026 (mode "center")
    Versi      : 1.1
]]

local RunService = game:GetService("RunService")

local BarFill = {}
BarFill.__index = BarFill

-- Jarak minimum antar keypoint. NumberSequence menolak keypoint dengan waktu
-- yang sama, jadi potongannya diberi celah setipis mungkin biar tetap terlihat
-- seperti garis potong lurus.
local EPSILON = 0.001

-- Makin besar makin cepat bar menyusul nilai target.
local SMOOTHING = 14

-- Mode "edge": bagian yang terlihat membentang dari ujung awal sampai ratio.
local function buildEdgeMask(ratio)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(ratio, 0),
		NumberSequenceKeypoint.new(ratio + EPSILON, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- Mode "center": bagian yang terlihat adalah pita selebar ratio yang selalu
-- berpusat di tengah bar, jadi isinya melebar ke kiri dan ke kanan bersamaan.
-- Gradien WARNA tidak ikut digeser, tetap terikat ke lebar penuh bar — itulah
-- kenapa pita kecil di tengah menampilkan warna tengah gradien.
local function buildCenterMask(ratio)
	local half = ratio / 2
	local low  = 0.5 - half
	local high = 0.5 + half

	local keypoints = {}

	-- Sisi kiri. Kalau pita sudah hampir menyentuh ujung, keypoint penutupnya
	-- dilewati — NumberSequence wajib mulai tepat di 0 dan tidak boleh mundur.
	if low <= EPSILON then
		table.insert(keypoints, NumberSequenceKeypoint.new(0, 0))
	else
		table.insert(keypoints, NumberSequenceKeypoint.new(0, 1))
		table.insert(keypoints, NumberSequenceKeypoint.new(low - EPSILON, 1))
		table.insert(keypoints, NumberSequenceKeypoint.new(low, 0))
	end

	-- Sisi kanan, cerminan dari sisi kiri.
	if high >= 1 - EPSILON then
		table.insert(keypoints, NumberSequenceKeypoint.new(1, 0))
	else
		table.insert(keypoints, NumberSequenceKeypoint.new(high, 0))
		table.insert(keypoints, NumberSequenceKeypoint.new(high + EPSILON, 1))
		table.insert(keypoints, NumberSequenceKeypoint.new(1, 1))
	end

	return NumberSequence.new(keypoints)
end

local function buildMask(ratio, mode)
	if ratio <= EPSILON then
		return NumberSequence.new(1) -- habis: seluruh bar disembunyikan
	end
	if ratio >= 1 - EPSILON then
		return NumberSequence.new(0) -- penuh: seluruh bar terlihat
	end

	if mode == "center" then
		return buildCenterMask(ratio)
	end

	return buildEdgeMask(ratio)
end

-- fill  : GuiObject bar (ImageLabel/Frame) yang ukurannya dibiarkan penuh
-- label : nama untuk pesan warn kalau UIGradient-nya belum dibuat di Studio
-- mode  : "edge" (default) atau "center"
function BarFill.new(fill, label, mode)
	if not fill then return nil end

	local gradient = fill:FindFirstChildOfClass("UIGradient")
	if not gradient then
		warn("[BarFill] " .. (label or fill:GetFullName()) .. " butuh UIGradient di dalamnya")
		return nil
	end

	local self = setmetatable({
		gradient	= gradient,
		mode		= mode or "edge",
		current		= 1,
		target		= 1,

		-- Tween durasi-tetap (dipakai lewat :tweenTo()) -- beda dari :set()
		-- yang speed-based (makin jauh makin cepat, waktunya gak pasti).
		-- Ini WAJIB kelar persis dalam `tweenDuration` detik, dengan kurva
		-- easing (bukan garis lurus) biar keliatan smooth pas ngerem di ujung.
		tweenActive   = false,
		tweenFrom     = 1,
		tweenStart    = 0,
		tweenDuration = 0,
		tweenEase     = nil,
	}, BarFill)

	self.connection = RunService.Heartbeat:Connect(function(deltaTime)
		self:_step(deltaTime)
	end)

	return self
end

-- Easing default buat :tweenTo() -- ease-out cubic: gerak cepat di awal,
-- ngerem halus pas mendekati akhir. Kurva ini yang bikin "efek grafik smooth"
-- pas BalanceBase turun, bukan garis lurus/linear yang berhenti mendadak.
local function easeOutCubic(t)
	local inv = 1 - t
	return 1 - (inv * inv * inv)
end

function BarFill:_apply(ratio)
	self.gradient.Transparency = buildMask(ratio, self.mode)
end

function BarFill:_step(deltaTime)
	if self.tweenActive then
		local t = self.tweenDuration > 0
			and (os.clock() - self.tweenStart) / self.tweenDuration
			or 1

		if t >= 1 then
			self.tweenActive = false
			self.current = self.target
			self:_apply(self.current)
		else
			local eased = self.tweenEase(t)
			self.current = self.tweenFrom + (self.target - self.tweenFrom) * eased
			self:_apply(self.current)
		end
		return
	end

	local diff = self.target - self.current
	if math.abs(diff) < EPSILON then
		if self.current ~= self.target then
			self.current = self.target
			self:_apply(self.current)
		end
		return
	end

	self.current += diff * math.min(deltaTime * SMOOTHING, 1)
	self:_apply(self.current)
end

-- Geser halus ke nilai baru, KECEPATAN sebanding jarak sisa (dipakai untuk
-- bar yang butuh "ngejar cepat kalau jauh, pelan-pelan kalau udah deket"
-- tanpa peduli berapa lama itu makan waktu -- mis. energy bar, atau naik
-- balance base pas recovery).
function BarFill:set(ratio)
	self.tweenActive = false
	self.target = math.clamp(ratio, 0, 1)
end

-- Geser ke nilai baru dalam DURASI TETAP (detik), pakai kurva easing.
-- Beda sama :set() -- ini dijamin kelar persis di `duration` detik, mau
-- jaraknya jauh atau deket, jadi kerasa konsisten/predictable. Dipakai
-- untuk BalanceBase pas nyusut.
function BarFill:tweenTo(ratio, duration, easingFn)
	self.tweenActive   = true
	self.tweenFrom      = self.current
	self.tweenStart     = os.clock()
	self.tweenDuration  = math.max(duration or 0, EPSILON)
	self.tweenEase      = easingFn or easeOutCubic
	self.target          = math.clamp(ratio, 0, 1)
end

-- Langsung lompat tanpa animasi (dipakai saat kena pukul / reset ronde)
function BarFill:snap(ratio)
	self.tweenActive = false
	self.target = math.clamp(ratio, 0, 1)
	self.current = self.target
	self:_apply(self.current)
end

return BarFill