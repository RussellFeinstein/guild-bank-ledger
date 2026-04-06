--- mock_ace.lua — Ace3 library mocks for busted tests
-- Provides LibStub, AceAddon-3.0, AceDB-3.0, AceConsole-3.0, AceEvent-3.0 stubs.

local MockAce = {}

-- Track registered events and slash commands
MockAce.registeredEvents = {}
MockAce.registeredMessages = {}
MockAce.registeredSlashCommands = {}
MockAce.sentMessages = {}

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

return MockAce
