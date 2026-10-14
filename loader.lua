--[[
	ONE-LINE LOADER (local, no network)
	====================================
	Put premium.lua in your executor's workspace folder, then paste this whole
	file into Xeno's executor and hit Execute.

	- No HttpGet, no network, no paste site.
	- Works in Xeno and in any executor that implements readfile.
	- If premium.lua sits next to this loader, it is found automatically.

	For a single-line paste instead of this file, see loader-oneliner.lua.
]]

local SCRIPT_NAME = "premium.lua"

local function findSource()
	if type(readfile) ~= "function" then
		return nil, "this executor has no readfile()"
	end

	local candidates = {
		SCRIPT_NAME,
		"workspace/" .. SCRIPT_NAME,
		"AutoBuild/" .. SCRIPT_NAME,
	}

	for i = 1, #candidates do
		local ok, contents = pcall(readfile, candidates[i])
		if ok and contents and #contents > 0 then
			return contents, candidates[i]
		end
	end

	-- Fall back to any .lua already sitting in the workspace folder.
	if type(listfiles) == "function" then
		local ok, files = pcall(listfiles, ".")
		if ok and files then
			for i = 1, #files do
				local entry = tostring(files[i])
				if string.lower(entry):find(".lua", 1, true) then
					local readOk, contents = pcall(readfile, entry)
					if readOk and contents and #contents > 0 then
						return contents, entry
					end
				end
			end
		end
	end

	return nil, "could not find " .. SCRIPT_NAME .. " in the workspace folder"
end

local source, where = findSource()

if not source then
	warn("Auto Farm Premium: " .. tostring(where))
	warn("Save premium.lua into your executor's workspace folder and re-run this loader.")
	return
end

warn("Auto Farm Premium: loading " .. tostring(where) .. " (" .. #source .. " bytes)")

local chunk, compileError = loadstring(source, "AutoFarmPremium")
if not chunk then
	warn("Auto Farm Premium failed to compile: " .. tostring(compileError))
	return
end

local ok, runtimeError = pcall(chunk)
if not ok then
	warn("Auto Farm Premium threw while starting: " .. tostring(runtimeError))
end
