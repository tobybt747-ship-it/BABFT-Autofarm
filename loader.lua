--[[
	Auto Farm Premium - loader for
	https://github.com/tobybt747-ship-it/BABFT-Autofarm

	Paste the single line from README.md instead of this file if you prefer.
	Paste this file if the raw URL is blocked in your executor.
]]

local URLS = {
	"https://raw.githubusercontent.com/tobybt747-ship-it/BABFT-Autofarm/refs/heads/main/premium.lua",
	"https://raw.githubusercontent.com/tobybt747-ship-it/BABFT-Autofarm/main/premium.lua",
}

local LOCAL = { "premium.lua", "workspace/premium.lua" }

local function fromDisk()
	if type(readfile) ~= "function" then
		return nil
	end
	for i = 1, #LOCAL do
		local ok, contents = pcall(readfile, LOCAL[i])
		if ok and contents and #contents > 0 then
			return contents
		end
	end
	return nil
end

local function fromNetwork()
	if type(game) ~= "table" or type(game.HttpGet) ~= "function" then
		return nil
	end
	for i = 1, #URLS do
		local ok, contents = pcall(function()
			return game:HttpGet(URLS[i])
		end)
		if ok and contents and #contents > 0 then
			return contents
		end
	end
	return nil
end

local source = fromNetwork() or fromDisk()

if not source then
	warn("Auto Farm Premium: could not fetch premium.lua and none was found locally.")
	return
end

warn("Auto Farm Premium: loaded " .. #source .. " bytes")

local chunk, compileError = loadstring(source, "AutoFarmPremium")
if not chunk then
	warn("Auto Farm Premium failed to compile: " .. tostring(compileError))
	return
end

local ok, runtimeError = pcall(chunk)
if not ok then
	warn("Auto Farm Premium threw while starting: " .. tostring(runtimeError))
end
