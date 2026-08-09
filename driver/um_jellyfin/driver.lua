-- Universal minidriver for Jellyfin.
--
-- Logic is the Control4 universal minidriver template, unchanged; only the
-- app data at the bottom differs. The driver launches nothing itself - it
-- publishes a service ID per platform and passes commands through to the
-- bound TV driver, which does the launching.
--
-- UM_SONY_TV is the app TITLE as the TV reports it in getApplicationList;
-- verified against the Bravia at 192.0.2.20, which lists "Jellyfin" with
-- uri com.sony.dtv.org.jellyfin.androidtv...StartupActivity.
-- UM_NV_SHIELD is the Android package name.

-- Copyright 2020 Wirepath Home Systems, LLC. All Rights Reserved.

JSON = require ('json')

UNIVERSAL_APP_VER = 2
APP_BINDING = 3101
CURRENT_SELECTED_DEVICE = 1000
CURRENT_AUDIO_PATH = 1007

function formatParams(tParams)
	tParams = tParams or {}
	local out = {}
	for k,v in pairs(tParams) do
		table.insert(out, k .. ": " .. tostring(v))
	end
	return table.concat(out, ", ")
end

function OnDriverDestroyed ()
	C4:UnregisterSystemEvent (C4SystemEvents.OnPIP, 0)
end

function OnDriverInit ()
	C4:RegisterSystemEvent (C4SystemEvents.OnPIP, 0)
end

function OnDriverLateInit ()
	local appData = JSON:decode (JSON_APP_DATA)

	if (not (appData and appData.appName and appData.serviceIds)) then
		C4:UpdateProperty ('App Name', 'Error decoding app data')
		return
	end

	-- AddVariable only creates; on an existing driver instance the variable already
	-- exists and keeps its old value, so a changed app name in JSON_APP_DATA would
	-- never reach the TV driver. SetVariable forces the current value, making the
	-- driver self-healing when an app is renamed. (Safe here: SetVariable must not
	-- be called during OnDriverInit, but this is OnDriverLateInit.)
	C4:AddVariable ('APP_NAME', appData.appName, 'STRING', true, false)
	C4:SetVariable ('APP_NAME', appData.appName)

	for source, serviceId in pairs (appData.serviceIds) do
		C4:AddVariable (source, serviceId, 'STRING', true, false)
		C4:SetVariable (source, serviceId)
	end

	C4:UpdateProperty ('App Name', appData.appName)

	RegisterRooms ()
end

function OnSystemEvent (event)
	local eventname = string.match (event, '.-name="(.-)"')
	print("OnSystemEvent: " .. eventname)
	if (eventname == 'OnPIP') then
		ConnectedDevices = (C4:GetBoundConsumerDevices (C4:GetProxyDevices (), APP_BINDING))
		RegisterRooms ()
	end
end

function OnWatchedVariableChanged (idDevice, idVariable, strValue)
	print("OnWatchedVariableChanged[" .. idDevice .. "/" .. idVariable .. "]: " .. strValue)
	if (RoomIDs and RoomIDs [idDevice]) then
		local roomId = tonumber (idDevice)
		if (idVariable == CURRENT_SELECTED_DEVICE) then
			local deviceId = tonumber (strValue) or 0
			RoomIDSources [roomId] = deviceId

		elseif (idVariable == CURRENT_AUDIO_PATH) then
			RoomIDRoutes [roomId] = {}
			for id in string.gmatch (strValue or '', '<id>(.-)</id>') do
				table.insert (RoomIDRoutes [roomId], tonumber (id))
			end
			RoomIDTargets = RoomIDTargets or {}
			RoomIDTargets [roomId] = nil
			ConnectedDevices = ConnectedDevices or (C4:GetBoundConsumerDevices (C4:GetProxyDevices (), APP_BINDING))
			if (ConnectedDevices) then
				for _, id in ipairs (RoomIDRoutes [roomId]) do
					if (ConnectedDevices [id]) then
						RoomIDTargets [roomId] = id
						break
					end
				end
			end
		end
	end
end

function RegisterRooms ()
	print("RegisterRooms() called")
	RoomIDs = C4:GetDevicesByC4iName ('roomdevice.c4i')
	RoomIDSources = {}
	RoomIDRoutes = {}
	for roomId, _ in pairs (RoomIDs) do
		RoomIDSources [roomId] = tonumber (C4:GetDeviceVariable (roomId, CURRENT_SELECTED_DEVICE)) or 0
		RoomIDRoutes [roomId] = {}
		for id in string.gmatch (C4:GetDeviceVariable (roomId, CURRENT_AUDIO_PATH) or '', '<id>(.-)</id>') do
			table.insert (RoomIDRoutes [roomId], tonumber (id))
		end
		C4:UnregisterVariableListener (roomId, CURRENT_SELECTED_DEVICE)
		C4:RegisterVariableListener (roomId, CURRENT_SELECTED_DEVICE)

		C4:UnregisterVariableListener (roomId, CURRENT_AUDIO_PATH)
		C4:RegisterVariableListener (roomId, CURRENT_AUDIO_PATH)
	end
end

function ReceivedFromProxy (idBinding, strCommand, tParams)
	strCommand = strCommand or ''
	tParams = tParams or {}

	print("ReceivedFromProxy[" .. idBinding .. "]: " .. strCommand .. " (" .. formatParams(tParams) .. ")")
	local roomId = tonumber (tParams.ROOMID) or tonumber (tParams.ROOM_ID)

	if (roomId) then
		if (RoomIDTargets [roomId]) then
			tParams.PASSTHROUGH_COMMAND = strCommand
			print("Sending Passthrough[" .. roomId .. "] (" .. formatParams(tParams) .. ")")
			C4:SendToDevice (RoomIDTargets [roomId], 'PASSTHROUGH', tParams)
		end
	end
end




JSON_APP_DATA = [[{
	"serviceIds": {
		"UM_SONY_TV": "Jellyfin",
		"UM_NV_SHIELD": "org.jellyfin.androidtv"
	},
	"appName": "Jellyfin"
}]]
