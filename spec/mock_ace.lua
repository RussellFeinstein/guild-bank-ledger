--- mock_ace.lua — Ace3 library mocks for busted tests
-- Provides LibStub, AceAddon-3.0, AceDB-3.0, AceConsole-3.0, AceEvent-3.0 stubs.

local MockAce = {}

-- Track registered events, slash commands, and comms
MockAce.registeredEvents = {}
MockAce.registeredMessages = {}
MockAce.registeredSlashCommands = {}
MockAce.sentMessages = {}
MockAce.registeredComms = {}
MockAce.sentCommMessages = {}
MockAce._serialized = {}
MockAce._serializedCounter = 0

-- The addon object (set after NewAddon)
MockAce.addon = nil

-- AceDB instance
MockAce.dbInstance = nil

---------------------------------------------------------------------------
-- Setup / teardown
---------------------------------------------------------------------------

function MockAce.reset()
    MockAce.registeredEvents = {}
    MockAce.registeredMessages = {}
    MockAce.registeredSlashCommands = {}
    MockAce.sentMessages = {}
    MockAce.registeredComms = {}
    MockAce.sentCommMessages = {}
    MockAce._serialized = {}
    MockAce._serializedCounter = 0
    MockAce.addon = nil
    MockAce.dbInstance = nil
end

---------------------------------------------------------------------------
-- AceDB mock
---------------------------------------------------------------------------

local function deepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = deepCopy(v)
    end
    return copy
end

local function applyDefaults(target, defaults)
    if type(defaults) ~= "table" then return end
    for k, v in pairs(defaults) do
        if k == "*" then
            -- Wildcard default: set metatable for auto-vivification
            setmetatable(target, {
                __index = function(t, key)
                    local new = deepCopy(v)
                    if type(new) == "table" then
                        applyDefaults(new, v)
                    end
                    rawset(t, key, new)
                    return new
                end,
            })
        elseif type(v) == "table" then
            if target[k] == nil then
                target[k] = {}
            end
            if type(target[k]) == "table" then
                applyDefaults(target[k], v)
            end
        else
            if target[k] == nil then
                target[k] = v
            end
        end
    end
end

local function createAceDB(svName, defaults)
    local db = {
        _svName = svName,
        _callbacks = {},
        global = {},
        profile = {},
        RegisterCallback = function(self, target, event, method)
            self._callbacks[event] = { target = target, method = method }
        end,
    }

    if defaults then
        if defaults.global then
            applyDefaults(db.global, defaults.global)
        end
        if defaults.profile then
            applyDefaults(db.profile, defaults.profile)
        end
    end

    MockAce.dbInstance = db
    return db
end

---------------------------------------------------------------------------
-- Mixin helpers
---------------------------------------------------------------------------

local eventMixin = {
    RegisterEvent = function(self, event, method)
        MockAce.registeredEvents[event] = method or event
    end,
    UnregisterEvent = function(self, event)
        MockAce.registeredEvents[event] = nil
    end,
    UnregisterAllEvents = function(self)
        MockAce.registeredEvents = {}
    end,
    RegisterMessage = function(self, message, method)
        MockAce.registeredMessages[message] = method or message
    end,
    UnregisterMessage = function(self, message)
        MockAce.registeredMessages[message] = nil
    end,
    SendMessage = function(self, message, ...)
        table.insert(MockAce.sentMessages, { message = message, args = { ... } })
    end,
}

local consoleMixin = {
    RegisterChatCommand = function(self, command, method)
        MockAce.registeredSlashCommands[command] = method
    end,
    Print = function(self, ...)
        -- Delegate to global print
        print("|cff33ff99GuildBankLedger|r:", ...)
    end,
}

local commMixin = {
    RegisterComm = function(self, prefix, method)
        MockAce.registeredComms[prefix] = method
    end,
    SendCommMessage = function(self, prefix, text, distribution, target, prio, callbackFn, callbackArg)
        local totalBytes = text and #text or 0
        table.insert(MockAce.sentCommMessages, {
            prefix = prefix,
            text = text,
            distribution = distribution,
            target = target,
            prio = prio,
        })
        -- Simulate immediate completion so callback-based logic fires in tests
        if callbackFn then
            callbackFn(callbackArg, totalBytes, totalBytes)
        end
    end,
}

local serializerMixin = {
    Serialize = function(self, ...)
        MockAce._serializedCounter = MockAce._serializedCounter + 1
        local id = MockAce._serializedCounter
        MockAce._serialized[id] = { ... }
        return "SER:" .. id
    end,
    Deserialize = function(self, str)
        if type(str) ~= "string" then return false, "not a string" end
        local id = tonumber(str:match("^SER:(%d+)$"))
        if id and MockAce._serialized[id] then
            return true, unpack(MockAce._serialized[id])
        end
        return false, "invalid serialized data"
    end,
}

---------------------------------------------------------------------------
-- Install LibStub + Ace library mocks
---------------------------------------------------------------------------

function MockAce.install()
    -- LibStub
    local libs = {}

    _G.LibStub = setmetatable({}, {
        __call = function(self, libName, silent)
            if libs[libName] then
                return libs[libName]
            end
            if silent then return nil end
            error("Cannot find a library instance of \"" .. libName .. "\"")
        end,
    })

    _G.LibStub.GetLibrary = function(self, libName, silent)
        return _G.LibStub(libName, silent)
    end

    _G.LibStub.NewLibrary = function(self, libName, version)
        local lib = libs[libName] or {}
        libs[libName] = lib
        return lib
    end

    -- AceAddon-3.0
    local AceAddon = { addons = {} }
    libs["AceAddon-3.0"] = AceAddon

    AceAddon.NewAddon = function(self, name, ...)
        local addon = {
            _name = name,
            _modules = {},
            _mixins = { ... },
        }

        -- Apply mixins
        for k, v in pairs(eventMixin) do
            addon[k] = v
        end
        for k, v in pairs(consoleMixin) do
            addon[k] = v
        end
        for k, v in pairs(commMixin) do
            addon[k] = v
        end
        for k, v in pairs(serializerMixin) do
            addon[k] = v
        end

        -- Module support
        addon.NewModule = function(self2, modName, ...)
            local mod = {
                _name = modName,
            }
            for k, v in pairs(eventMixin) do
                mod[k] = v
            end
            self2._modules[modName] = mod
            return mod
        end

        addon.GetModule = function(self2, modName)
            return self2._modules[modName]
        end

        AceAddon.addons[name] = addon
        MockAce.addon = addon
        return addon
    end

    AceAddon.GetAddon = function(self, name)
        return self.addons[name]
    end

    -- AceDB-3.0
    local AceDB = {}
    libs["AceDB-3.0"] = AceDB

    AceDB.New = function(self, svName, defaults, defaultProfile)
        return createAceDB(svName, defaults)
    end

    -- AceEvent-3.0 (mixin, already applied via NewAddon)
    libs["AceEvent-3.0"] = {}

    -- AceConsole-3.0 (mixin, already applied via NewAddon)
    libs["AceConsole-3.0"] = {}

    -- AceComm-3.0 (mixin, already applied via NewAddon)
    libs["AceComm-3.0"] = {}

    -- AceSerializer-3.0 (mixin, already applied via NewAddon)
    libs["AceSerializer-3.0"] = {}

    -- AceGUI-3.0 mock (stub widgets as plain Lua tables)
    local AceGUI = {}
    libs["AceGUI-3.0"] = AceGUI

    local function createMockWidget(widgetType)
        local widget = {
            _type = widgetType,
            _callbacks = {},
            _children = {},
            _text = "",
            _value = nil,
            _label = "",
            _list = {},
            _width = 0,
            _height = 0,
            _fullWidth = false,
            _shown = true,
            _disabled = false,
            _title = "",
            _statusText = "",
        }
        widget.SetCallback = function(self, event, func)
            self._callbacks[event] = func
        end
        widget.Fire = function(self, event, ...)
            if self._callbacks[event] then
                self._callbacks[event](self, event, ...)
            end
        end
        widget.SetText = function(self, text) self._text = text end
        widget.GetText = function(self) return self._text end
        widget.SetValue = function(self, value) self._value = value end
        widget.GetValue = function(self) return self._value end
        widget.SetLabel = function(self, label) self._label = label end
        widget.SetList = function(self, list) self._list = list end
        widget.SetWidth = function(self, w) self._width = w end
        widget.SetHeight = function(self, h) self._height = h end
        widget.SetFullWidth = function(self, fw) self._fullWidth = fw end
        widget.SetRelativeWidth = function(self, rw) self._relWidth = rw end
        widget.AddChild = function(self, child)
            table.insert(self._children, child)
            child._parent = self
        end
        widget.ReleaseChildren = function(self) self._children = {} end
        widget.Release = function() end
        widget.Show = function(self) self._shown = true end
        widget.Hide = function(self) self._shown = false end
        -- Mock underlying WoW frame (for IsShown checks)
        widget.frame = {
            IsShown = function() return widget._shown end,
            SetClampedToScreen = function() end,
            CreateFontString = function()
                local fs = { _text = "" }
                fs.SetFont = function() end
                fs.SetPoint = function() end
                fs.SetText = function(_, t) fs._text = t end
                fs.GetText = function() return fs._text end
                return fs
            end,
        }
        widget.SetDisabled = function(self, d) self._disabled = d end
        widget.SetLayout = function() end
        widget.SetTitle = function(self, t) self._title = t end
        widget.SetStatusText = function(self, t) self._statusText = t end
        widget.SetAutoAdjustHeight = function() end
        widget.SetStatusTable = function() end
        widget.EnableResize = function() end
        widget.SetTabs = function(self, tabs) self._tabs = tabs end
        widget.SelectTab = function(self, tab) self._selectedTab = tab end
        widget.SetFullHeight = function() end
        widget.SetFontObject = function() end
        widget.SetJustifyH = function() end
        widget.SetFont = function() end
        return widget
    end

    AceGUI.Create = function(_self, widgetType)
        return createMockWidget(widgetType)
    end
    AceGUI.RegisterWidgetType = function() end
    AceGUI.ClearFocus = function() end

    -- AceConfig-3.0 mock
    libs["AceConfig-3.0"] = {
        RegisterOptionsTable = function() end,
    }

    -- AceConfigDialog-3.0 mock
    libs["AceConfigDialog-3.0"] = {
        Open = function() end,
        Close = function() end,
    }

    -- AceConfigCmd-3.0 mock
    libs["AceConfigCmd-3.0"] = {
        CreateChatCommand = function() end,
    }

    -- LibDataBroker-1.1 mock
    local LDB = {
        _objects = {},
    }
    LDB.NewDataObject = function(self, name, obj)
        self._objects[name] = obj
        return obj
    end
    libs["LibDataBroker-1.1"] = LDB
    MockAce.ldb = LDB

    -- LibDBIcon-1.0 mock
    local LDBIcon = {
        _registered = {},
    }
    LDBIcon.Register = function(self, name, obj, dbTable)
        self._registered[name] = { obj = obj, db = dbTable }
    end
    LDBIcon.Show = function() end
    LDBIcon.Hide = function() end
    libs["LibDBIcon-1.0"] = LDBIcon
    MockAce.ldbIcon = LDBIcon

    -- LibDeflate mock (identity transform for testing)
    libs["LibDeflate"] = {
        CompressDeflate = function(_, data) return data end,
        DecompressDeflate = function(_, data) return data end,
        EncodeForWoWAddonChannel = function(_, data) return data end,
        DecodeForWoWAddonChannel = function(_, data) return data end,
    }
end

--- Fire an event on the addon object (simulates WoW event dispatch).
function MockAce.fireEvent(event, ...)
    local addon = MockAce.addon
    if not addon then return end

    local handler = MockAce.registeredEvents[event]
    if handler then
        local method = type(handler) == "string" and addon[handler] or addon[event]
        if method then
            method(addon, event, ...)
        end
    end
end

--- Fire a message on the addon object.
function MockAce.fireMessage(message, ...)
    local addon = MockAce.addon
    if not addon then return end

    local handler = MockAce.registeredMessages[message]
    if handler then
        local method = type(handler) == "string" and addon[handler] or addon[message]
        if method then
            method(addon, message, ...)
        end
    end
end

--- Simulate receiving an AceComm message from another player.
-- @param prefix string AceComm prefix
-- @param message string Serialized message text
-- @param distribution string "GUILD" or "WHISPER"
-- @param sender string Sender name
function MockAce.fireComm(prefix, message, distribution, sender)
    local addon = MockAce.addon
    if not addon then return end

    local handler = MockAce.registeredComms[prefix]
    if handler and addon[handler] then
        addon[handler](addon, prefix, message, distribution, sender)
    end
end

return MockAce
