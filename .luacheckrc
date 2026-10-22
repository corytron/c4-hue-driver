-- Controller drivers run under LuaJIT (5.1 semantics), see docs/design.md.
std = "lua51"
max_line_length = 120

-- Globals the DriverWorks runtime provides to every driver.
read_globals = {
	"C4",
	"Properties",
	"C4SystemEvents",
}

files["src/hue_bridge/driver.lua"] = {
	-- DriverWorks entry points are globals the controller calls by name.
	globals = {
		"OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "OnDriverRemovedFromProject",
		"ExecuteCommand", "OnPropertyChanged", "ReceivedFromProxy", "OnBindingChanged", "OnBindingValidate",
		"OnSystemEvent",
		-- CUSTOM_SELECT list functions named in the bridge's driver.xml.
		"HueLightList", "RoomList", "RelinkDeviceList", "ForgetDeviceList", "HueRoomList", "MappingTargetList",
	},
}

files["src/hue_light/driver.lua"] = files["src/hue_bridge/driver.lua"]

files["tests"] = {
	std = "+busted",
	globals = { "C4", "Properties" },
	-- The fake C4 methods mirror the real colon-call signatures.
	self = false,
}
