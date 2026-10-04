-- @ScriptType: ModuleScript
--[[
    Nama File  : AvatarUtil
    Layer      : Client (UI)
    Deskripsi  : Helper buat isi ImageLabel dengan foto profil (avatar headshot)
                 seorang pemain lewat Players:GetUserThumbnailAsync. Dipakai
                 bareng oleh BalanceBarClient (HpLeft/diri sendiri) dan
                 OpponentBarClient (HpRight/lawan).
    Tanggal    : 08 Agustus 2026
    Versi      : 1.0
    Dependensi : -
]]

local Players = game:GetService("Players")

local AvatarUtil = {}

-- imageLabel     : ImageLabel yang mau diisi
-- userId         : UserId pemain yang fotonya mau diambil
-- thumbnailType  : opsional, default Enum.ThumbnailType.HeadShot
-- thumbnailSize  : opsional, default Enum.ThumbnailSize.Size100x100
--
-- GetUserThumbnailAsync itu YIELDING (nunggu response dari Roblox), jadi
-- dibungkus task.spawn (biar gak nge-freeze UI thread) + pcall (biar gak
-- crash kalau requestnya gagal, mis. koneksi lambat).
function AvatarUtil.setThumbnail(imageLabel, userId, thumbnailType, thumbnailSize)
	if not imageLabel or not userId then return end

	thumbnailType = thumbnailType or Enum.ThumbnailType.HeadShot
	thumbnailSize = thumbnailSize or Enum.ThumbnailSize.Size100x100

	-- Tandai userId yang lagi diminta. Kalau lawan ganti lagi (ronde baru/
	-- rematch cepat) SEBELUM request lama ini selesai, hasil basi itu gak
	-- boleh nimpa foto pemain yang sekarang seharusnya tampil.
	imageLabel:SetAttribute("AvatarRequestUserId", userId)

	task.spawn(function()
		local ok, content = pcall(Players.GetUserThumbnailAsync, Players, userId, thumbnailType, thumbnailSize)

		if not imageLabel.Parent then return end -- UI sempat dihancurkan selagi nunggu
		if imageLabel:GetAttribute("AvatarRequestUserId") ~= userId then return end -- hasil basi

		if ok then
			imageLabel.Image = content
		else
			warn("[AvatarUtil] Gagal ambil thumbnail untuk UserId " .. tostring(userId))
		end
	end)
end

-- Kosongkan gambar (dipakai saat opponent nil / balik ke lobby)
function AvatarUtil.clear(imageLabel)
	if not imageLabel then return end
	imageLabel:SetAttribute("AvatarRequestUserId", nil)
	imageLabel.Image = ""
end

return AvatarUtil