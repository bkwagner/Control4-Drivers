--[[
	Control4 proxy command -> Android TV key code.

	The command names are the canonical Control4 set (see the command list in
	sample_drivers/idc_controller in the DriverWorks SDK). Anything a Navigator,
	a Halo, or an SR-260 can send arrives at ReceivedFromProxy under one of these
	names; unrecognised commands are passed through by the proxy, so the driver
	must tolerate names not in this table.

	VOLUME IS DELIBERATELY NOT MAPPED. On this hardware volume routes over CEC to
	the TV or receiver, which Control4 already controls directly - the device
	reports volume_max = 0 and has no volume state of its own. Mapping
	START_VOL_UP / MUTE_TOGGLE here would create two things fighting over the same
	volume. The key codes remain in lib/keycodes.lua if this is ever wanted.
]]

local keycodes = require('lib.keycodes')

local K = keycodes.KEYCODE
local D = keycodes.DIRECTION

local M = {}

--[[
	command -> { key = <code>, hold = <bool> }

	hold marks the START_/STOP_ pairs. Control4 sends START_x on press and STOP_x
	on release, which maps onto the protocol's START_LONG / END_LONG directions -
	so holding scan-forward on the remote actually scrubs rather than firing once.
]]
M.COMMANDS = {
	-- D-pad and navigation
	UP                = { key = K.KEYCODE_DPAD_UP },
	DOWN              = { key = K.KEYCODE_DPAD_DOWN },
	LEFT              = { key = K.KEYCODE_DPAD_LEFT },
	RIGHT             = { key = K.KEYCODE_DPAD_RIGHT },
	ENTER             = { key = K.KEYCODE_DPAD_CENTER },
	CANCEL            = { key = K.KEYCODE_BACK },
	BACK              = { key = K.KEYCODE_BACK },
	EXIT              = { key = K.KEYCODE_HOME },
	MENU              = { key = K.KEYCODE_MENU },
	INFO              = { key = K.KEYCODE_INFO },
	GUIDE             = { key = K.KEYCODE_GUIDE },
	CONTROL4          = { key = K.KEYCODE_HOME },

	-- Transport
	PLAY              = { key = K.KEYCODE_MEDIA_PLAY },
	PAUSE             = { key = K.KEYCODE_MEDIA_PAUSE },
	PLAYPAUSE         = { key = K.KEYCODE_MEDIA_PLAY_PAUSE },
	STOP              = { key = K.KEYCODE_MEDIA_STOP },
	RECORD            = { key = K.KEYCODE_MEDIA_RECORD },
	SKIP_FWD          = { key = K.KEYCODE_MEDIA_NEXT },
	SKIP_REV          = { key = K.KEYCODE_MEDIA_PREVIOUS },
	START_SCAN_FWD    = { key = K.KEYCODE_MEDIA_FAST_FORWARD, hold = true },
	STOP_SCAN_FWD     = { key = K.KEYCODE_MEDIA_FAST_FORWARD, hold = true },
	START_SCAN_REV    = { key = K.KEYCODE_MEDIA_REWIND,       hold = true },
	STOP_SCAN_REV     = { key = K.KEYCODE_MEDIA_REWIND,       hold = true },

	-- Paging and channels
	START_PAGE_UP     = { key = K.KEYCODE_PAGE_UP,      hold = true },
	STOP_PAGE_UP      = { key = K.KEYCODE_PAGE_UP,      hold = true },
	START_PAGE_DOWN   = { key = K.KEYCODE_PAGE_DOWN,    hold = true },
	STOP_PAGE_DOWN    = { key = K.KEYCODE_PAGE_DOWN,    hold = true },
	START_CH_UP       = { key = K.KEYCODE_CHANNEL_UP,   hold = true },
	STOP_CH_UP        = { key = K.KEYCODE_CHANNEL_UP,   hold = true },
	START_CH_DOWN     = { key = K.KEYCODE_CHANNEL_DOWN, hold = true },
	STOP_CH_DOWN      = { key = K.KEYCODE_CHANNEL_DOWN, hold = true },

	-- Number pad
	NUMBER_0          = { key = K.KEYCODE_0 },
	NUMBER_1          = { key = K.KEYCODE_1 },
	NUMBER_2          = { key = K.KEYCODE_2 },
	NUMBER_3          = { key = K.KEYCODE_3 },
	NUMBER_4          = { key = K.KEYCODE_4 },
	NUMBER_5          = { key = K.KEYCODE_5 },
	NUMBER_6          = { key = K.KEYCODE_6 },
	NUMBER_7          = { key = K.KEYCODE_7 },
	NUMBER_8          = { key = K.KEYCODE_8 },
	NUMBER_9          = { key = K.KEYCODE_9 },
	STAR              = { key = K.KEYCODE_STAR },
	POUND             = { key = K.KEYCODE_POUND },

	-- Coloured buttons
	PROGRAM_A         = { key = K.KEYCODE_PROG_RED },
	PROGRAM_B         = { key = K.KEYCODE_PROG_GREEN },
	PROGRAM_C         = { key = K.KEYCODE_PROG_YELLOW },
	PROGRAM_D         = { key = K.KEYCODE_PROG_BLUE },

	-- Misc
	POWER             = { key = K.KEYCODE_POWER },
	CLOSED_CAPTIONED  = { key = K.KEYCODE_CAPTIONS },
	RECALL            = { key = K.KEYCODE_BACK },
	PVR               = { key = K.KEYCODE_TV },
	CUSTOM_1          = { key = K.KEYCODE_SEARCH },
	CUSTOM_2          = { key = K.KEYCODE_SETTINGS },
	CUSTOM_3          = { key = K.KEYCODE_ZOOM_IN },
	EJECT             = { key = K.KEYCODE_MEDIA_EJECT },
	OPEN_CLOSE        = { key = K.KEYCODE_MEDIA_CLOSE },
}

--[[
	Resolve a proxy command to key code and direction.

	Returns keyCode, direction - or nil if the command is not mapped, which is a
	normal outcome the caller should log rather than treat as an error.
]]
function M.resolve(command)
	local entry = M.COMMANDS[command]
	if (entry == nil) then return nil, nil end

	if (entry.hold) then
		-- START_x begins the hold, STOP_x ends it.
		if (string.sub(command, 1, 6) == 'START_') then
			return entry.key, D.START_LONG
		end
		return entry.key, D.END_LONG
	end

	return entry.key, D.SHORT
end

--- Names of every mapped command, for logging and diagnostics.
function M.commandNames()
	local names = {}
	for name, _ in pairs(M.COMMANDS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return M
