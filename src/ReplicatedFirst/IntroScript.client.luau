-- @ScriptType: LocalScript
--[[
Nama File   : IntroLoadingScreen.lua
Layer       : Client / UI
Deskripsi   : Menangani tampilan layar pemuatan (intro loading screen), 
              termasuk transisi elemen GUI dan pemuatan awal (preload) 
              seluruh aset game serta animasi combat.
Penulis     : GREEN PENDAP / Yusuf Ahayy
Tanggal     : 17 Agustus 2026
Versi       : 1.1 (Fix ZIndex loadingText ketutup loadingImage)
]]

local ReplicatedFirst   = game:GetService("ReplicatedFirst")
local ContentProvider   = game:GetService("ContentProvider")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local introGui = ReplicatedFirst:WaitForChild("IntroGui"):Clone()
introGui.Parent = playerGui

local bg = introGui:WaitForChild("Background")

local gameName = bg:WaitForChild("GameName") :: ImageLabel
local studioName = bg:WaitForChild("StudioName") :: ImageLabel
local loadingImage = bg:WaitForChild("LoadingImage") :: ImageLabel
local loadingText = bg:WaitForChild("LoadingText") :: TextLabel

-- FIX: loadingText ketutup loadingImage karena ZIndex-nya sama/lebih kecil.
-- Paksa loadingText selalu di atas loadingImage, apapun urutan Z aslinya
-- di Studio (jadi aman meskipun loadingImage.ZIndex diubah manual nanti).
loadingText.ZIndex = loadingImage.ZIndex + 1

gameName.ImageTransparency = 1
studioName.ImageTransparency = 1
loadingImage.ImageTransparency = 1
loadingText.TextTransparency = 1

gameName.Visible = false
studioName.Visible = false
loadingImage.Visible = false
loadingText.Visible = false

local introAssets = {gameName, studioName, loadingImage}
ContentProvider:PreloadAsync(introAssets)

local tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

gameName.Visible = true
studioName.Visible = true

local fadeInGame = TweenService:Create(gameName, tweenInfo, {ImageTransparency = 0})
local fadeInStudio = TweenService:Create(studioName, tweenInfo, {ImageTransparency = 0})

fadeInGame:Play()
fadeInStudio:Play()
fadeInStudio.Completed:Wait()

task.wait(2)

local fadeOutGame = TweenService:Create(gameName, tweenInfo, {ImageTransparency = 1})
local fadeOutStudio = TweenService:Create(studioName, tweenInfo, {ImageTransparency = 1})

fadeOutGame:Play()
fadeOutStudio:Play()
fadeOutStudio.Completed:Wait()

gameName.Visible = false
studioName.Visible = false

loadingImage.Visible = true
loadingText.Visible = true

local fadeInLoadingImg = TweenService:Create(loadingImage, tweenInfo, {ImageTransparency = 0})
local fadeInLoadingTxt = TweenService:Create(loadingText, tweenInfo, {TextTransparency = 0})

fadeInLoadingImg:Play()
fadeInLoadingTxt:Play()
fadeInLoadingTxt.Completed:Wait()

if not game:IsLoaded() then
	loadingText.Text = "Connecting..."
	game.Loaded:Wait()
end

local gameAssets = workspace:GetDescendants()
for _, item in ipairs(playerGui:GetDescendants()) do
	table.insert(gameAssets, item)
end

local AnimationConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("AnimationConfig"))

local function collectAnimationIds(configTable, into)
	for _, animData in pairs(configTable) do
		if type(animData) == "table" then
			for _, animId in ipairs(animData) do
				if animId ~= "" then table.insert(into, animId) end
			end
		elseif type(animData) == "string" and animData ~= "" then
			table.insert(into, animData)
		end
	end
end

local animationIds = {}
collectAnimationIds(AnimationConfig.COMBAT_ANIMATIONS, animationIds)
collectAnimationIds(AnimationConfig.HURT_ANIMATIONS, animationIds)
collectAnimationIds(AnimationConfig.FFYL_ANIMATIONS, animationIds)

if AnimationConfig.DEFEAT_ANIMATION and AnimationConfig.DEFEAT_ANIMATION ~= "" then
	table.insert(animationIds, AnimationConfig.DEFEAT_ANIMATION)
end
if AnimationConfig.MATCH_IDLE and AnimationConfig.MATCH_IDLE ~= "" then
	table.insert(animationIds, AnimationConfig.MATCH_IDLE)
end

for _, animId in ipairs(animationIds) do
	local animInstance = Instance.new("Animation")
	animInstance.AnimationId = animId
	table.insert(gameAssets, animInstance)
end

local hitEffectAssetsFolder = ReplicatedStorage:FindFirstChild("Assets")
local hitEffectModel = hitEffectAssetsFolder and hitEffectAssetsFolder:FindFirstChild("HitEffect")
if hitEffectModel then
	for _, descendant in ipairs(hitEffectModel:GetDescendants()) do
		if
			descendant:IsA("ParticleEmitter")
			or descendant:IsA("Decal")
			or descendant:IsA("Texture")
			or descendant:IsA("MeshPart")
			or descendant:IsA("SpecialMesh")
			or descendant:IsA("Sound")
		then
			table.insert(gameAssets, descendant)
		end
	end
end

local totalAssets = #gameAssets
local loadedAssets = 0

if totalAssets > 0 then
	ContentProvider:PreloadAsync(gameAssets, function(contentId, status)
		loadedAssets += 1
		local percent = math.clamp(math.floor((loadedAssets / totalAssets) * 100), 0, 100)
		loadingText.Text = "Loading Assets: " .. percent .. "%"
	end)
end

loadingText.Text = "Loading Assets: 100%"

loadingText.Text = "Done!"
task.wait(1)

local fadeInfo = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

if bg:IsA("CanvasGroup") then
	local fadeBg = TweenService:Create(bg, fadeInfo, {GroupTransparency = 1})
	fadeBg:Play()
	fadeBg.Completed:Wait()
else
	local fadeImg = TweenService:Create(loadingImage, fadeInfo, {ImageTransparency = 1})
	local fadeTxt = TweenService:Create(loadingText, fadeInfo, {TextTransparency = 1})
	fadeImg:Play()
	fadeTxt:Play()
	fadeImg.Completed:Wait()
end

introGui:Destroy()