--[[
    Nama File  : ShopConfig
    Layer      : Config (Shared)
    Deskripsi  : Konfigurasi ID item, asset, atau product yang dijual di Shop Page.
]]

local ShopConfig = {
	-- Mapping nama objek di UI (ItemCard1, StarterBundle, dll) ke ID Roblox
	-- Tipe yang didukung: "Asset", "Product" (Developer Product), atau "GamePass"
	ITEMS = {
		["ItemCard1"] = {
			Id = 1940550895,      -- Ganti dengan ID Asset/Product kamu
			Type = "GamePass"     -- "Product" / "GamePass" / "Asset"
		},
		["ItemCard2"] = {
			Id = 123456789,
			Type = "Product"
		},
		["ItemCard3"] = {
			Id = 123456789,
			Type = "GamePass"
		},
		["ItemCard4"] = {
			Id = 123456789,
			Type = "Asset"
		},
		["ItemCard5"] = {
			Id = 123456789,
			Type = "Product"
		},
		["StarterBundle"] = {
			Id = 123456789,
			Type = "Product"
		},
	}
}

return ShopConfig