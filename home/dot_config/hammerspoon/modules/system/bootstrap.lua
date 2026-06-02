--- system/bootstrap.lua
--- First-run bootstrap: configures `package.path` for the modules directory
--- and installs essential Spoons (SpoonInstall, EmmyLua, RecursiveBinder).
---
--- Usage:
---   require("system.bootstrap").init()

local M = {}

--- Set up module search paths and install required Spoons.
--- Adds `modules/?.lua` and `modules/?/init.lua` to `package.path`, then
--- bootstraps SpoonInstall from GitHub if absent and loads EmmyLua and
--- RecursiveBinder via SpoonInstall.
function M.init()
	local modulesDir = hs.configdir .. "/modules/?.lua;"
	local modulesInitDir = hs.configdir .. "/modules/?/init.lua;"
	package.path = package.path .. ";" .. modulesDir .. modulesInitDir

	-- Automatically install/load SpoonInstall
	if not hs.spoons.isInstalled("SpoonInstall") then
		hs.printf("SpoonInstall not found. Bootstrapping...")

		-- Define the URL for the SpoonInstall.spoon zip
		local spoonInstallUrl = "https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpoonInstall.spoon.zip"

		-- Create Spoons directory if needed and download/unzip the spoon
		hs.execute(
			string.format(
				"mkdir -p %s/Spoons && curl -L %s | tar -xz -C %s/Spoons",
				hs.configdir,
				spoonInstallUrl,
				hs.configdir
			)
		)
	end
  hs.printf("SpoonInstall present and installed")

	-- Load SpoonInstall
	hs.loadSpoon("SpoonInstall")
	spoon.SpoonInstall.use_syncinstall = true

	local Install = spoon.SpoonInstall

	Install:andUse("EmmyLua")
end

return M
