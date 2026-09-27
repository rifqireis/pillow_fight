-- @ScriptType: ModuleScript
--[[
Nama File   : AnimationConfig.lua
Layer       : Config
Deskripsi   : Konfigurasi ID Animasi, waktu fading, kecepatan, dan bobot
              untuk combat, idle, hurt, dan FFYL state.
Penulis     : Abdul Vaiz / Yusuf Ahayyy
Tanggal     : 24 Juli 2026
Versi       : 2.0
]]

local AnimationConfig = {
	COMBAT_ANIMATIONS = {
		light = {
			"rbxassetid://135912594331138",
			"rbxassetid://72876642954964",
		},
		heavy = "rbxassetid://113010584767643",
		dodge = "rbxassetid://97517769562422",
		start = "rbxassetid://137832380252406",
		fall = "rbxassetid://72510874824720",
		rise = "rbxassetid://81136546242495",
		stun = "rbxassetid://125770292136800",
	},

	HURT_ANIMATIONS = {
		lightHurt = {
			"rbxassetid://93324829086690",
			"rbxassetid://118904890270224",
		},
		heavyHurt = "rbxassetid://138853415494480",
	},

	FFYL_ANIMATIONS = {
		startFFYL = "rbxassetid://90288246713366",
		endFFYL   = "rbxassetid://123514296806029",
	},

	DEFEAT_ANIMATION = "rbxassetid://123112398953969",
	MATCH_IDLE = "rbxassetid://117911095686069",

	FADE_TIME = {
		DEFAULT  = 0.15,
		ATTACK   = 0.1,
		HURT     = 0.08,
		DODGE    = 0.1,
		STUN     = 0.2,
		RISE     = 0.2,
		IDLE     = 0.25,
		FFYL     = 0.15,
		DEFEAT   = 0.2,
		STOP     = 0.2,
	},

	SPEED = {
		light     = 1.0,
		heavy     = 1.0,
		dodge     = 1.15,
		stun      = 1.0,
		fall      = 1.0,
		rise      = 1.0,
		start     = 1.0,
		lightHurt = 1.1,
		heavyHurt = 0.9,
		startFFYL = 1.0,
		endFFYL   = 1.0,
		defeat    = 1.0,
	},

	WEIGHT = {
		light     = 1.0,
		heavy     = 1.0,
		dodge     = 1.0,
		stun      = 1.0,
		fall      = 1.0,
		rise      = 1.0,
		start     = 1.0,
		lightHurt = 0.85,
		heavyHurt = 1.0,
		startFFYL = 1.0,
		endFFYL   = 1.0,
		defeat    = 1.0,
	},
}

return AnimationConfig