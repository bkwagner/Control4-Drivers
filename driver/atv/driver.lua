--[[
	Google TV (streamer / dongle) - media_player proxy.

	All logic lives in lib/driver_core.lua, shared with the television variant in
	driver/atv_tv. This file exists because DriverWorks requires a driver.lua at the
	c4z root; keeping it to one line means there is only ever one copy to fix.
]]

require('lib.driver_core')
