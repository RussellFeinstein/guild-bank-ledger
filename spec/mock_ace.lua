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

--- Copy defaults in, the way AceDB does at login.
--
-- Transcribed branch for branch from Libs/AceDB-3.0/AceDB-3.0.lua:88-131,
-- for the same reason removeDefaults below it is: a partial port is how this
-- mock came to model a fresh install and never an upgrade. Three things it
-- was missing, each with its own case in spec/savedvariables_spec.lua.
--
-- A vivified table starts EMPTY and has the template copied into it. The old
-- version deep-copied the template, which copies the literal "*" key along
-- with everything else, so every table declaring a nested wildcard was born
-- holding a phantom entry. guilds["*"].playerStats is the one that matters:
-- seven production sites walk it with pairs, five of them migrations.
--
-- The already-existing-tables loop applies the template to tables ALREADY in
-- the file, which is the upgrade path. Without it a key stripped at logout
-- never comes back at the next login.
--
-- The scalar wildcard, the nil-key guard and the ** merge are unreachable
-- from this addon's defaults and are ported anyway; see removeDefaults.
local function applyDefaults(target, defaults)
    if type(defaults) ~= "table" then return end
    for k, v in pairs(defaults) do
        if k == "*" or k == "**" then
            if type(v) == "table" then
                setmetatable(target, {
                    __index = function(t, k2)
                        if k2 == nil then return nil end
                        local tbl = {}
                        applyDefaults(tbl, v)
                        rawset(t, k2, tbl)
                        return tbl
                    end,
                })
                -- handle already existing tables in the SV
                for dk, dv in pairs(target) do
                    if not rawget(defaults, dk) and type(dv) == "table" then
                        applyDefaults(dv, v)
                    end
                end
            else
                -- a non-table wildcard is just a value every key answers with
                setmetatable(target, {
                    __index = function(t, k2) return k2 ~= nil and v or nil end,
                })
            end
        elseif type(v) == "table" then
            if not rawget(target, k) then rawset(target, k, {}) end
            if type(target[k]) == "table" then
                applyDefaults(target[k], v)
                if defaults["**"] then
                    applyDefaults(target[k], defaults["**"])
                end
            end
        else
            if rawget(target, k) == nil then
                rawset(target, k, v)
            end
        end
    end
end

--- Strip every value that still equals its default, the way AceDB does
--- before the SavedVariables file is written.
--
-- Transcribed branch for branch from Libs/AceDB-3.0/AceDB-3.0.lua:134-176.
-- Three of its branches are unreachable from this addon's own defaults and
-- are ported anyway, because a partial port is how the read path came to
-- model a login and never a logout: the "**" table branch, the "*" scalar
-- branch, and the blocker argument that only "**" passes. GBL declares two
-- "*" table wildcards and no "**" at all (src/Core.lua, guilds and
-- playerStats). spec/savedvariables_spec.lua covers all three synthetically
-- and diffs this whole function against the real library.
--
-- The metatable clear on the first line is load-bearing twice over: it stops
-- the walk creating subtables through the very wildcard it is stripping, and
-- it is what lets a spec assert a key is absent without the read putting it
-- back.
local function removeDefaults(db, defaults, blocker)
    setmetatable(db, nil)
    for k, v in pairs(defaults) do
        if k == "*" or k == "**" then
            if type(v) == "table" then
                for key, value in pairs(db) do
                    if type(value) == "table" then
                        -- not named in the defaults: strip the whole template
                        if defaults[key] == nil and (not blocker or blocker[key] == nil) then
                            removeDefaults(value, v)
                            if next(value) == nil then
                                db[key] = nil
                            end
                        -- named: strip only ** content, blocking the key table
                        elseif k == "**" then
                            removeDefaults(value, v, defaults[key])
                        end
                    end
                end
            elseif k == "*" then
                for key, value in pairs(db) do
                    if defaults[key] == nil and v == value then
                        db[key] = nil
                    end
                end
            end
        elseif type(v) == "table" and type(db[k]) == "table" then
            removeDefaults(db[k], v, blocker and blocker[k])
            if next(db[k]) == nil then
                db[k] = nil
            end
        else
            if db[k] == defaults[k] and (not blocker or blocker[k] == nil) then
                db[k] = nil
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

    -- A session boundary, which the mock could not express before #77.
    -- _simulateLogout strips in place, so db.global and db.profile become
    -- the on-disk image; _simulateLogin is the next login over that file.
    -- Run the pair to model an upgrade: what AceDB does to a guild ALREADY
    -- in the file is a different path from what it does to a fresh one.
    db._defaults = defaults

    db._simulateLogout = function(self)
        local d = self._defaults
        if d then
            if d.global then removeDefaults(self.global, d.global) end
            if d.profile then removeDefaults(self.profile, d.profile) end
        end
        return self
    end

    db._simulateLogin = function(self)
        local d = self._defaults
        if d then
            if d.global then applyDefaults(self.global, d.global) end
            if d.profile then applyDefaults(self.profile, d.profile) end
        end
        return self
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
    -- Expose a cross-mock event-fire hook so spec/mock_wow.lua can raise
    -- events (e.g. GUILDBANKBAGSLOTS_CHANGED fired by PickupGuildBankItem)
    -- without needing a hard require on MockAce.
    _G.__MockAce_fireEvent = MockAce.fireEvent

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
            -- Real AceGUI widgets carry the type on `type` (each widget's
            -- Constructor sets self.type = Type), and production code
            -- branches on it to tell a CheckBox from a Button. The mock's
            -- own `_type` predates that and existing specs read it, so both
            -- are set rather than renaming one.
            type = widgetType,
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
            -- Real AceGUI widgets store the flag as `disabled` (see
            -- AceGUIWidget-CheckBox.lua and -Button.lua, both `self.disabled
            -- = disabled`), and the widget's own OnClick handler reads it to
            -- refuse a click. Production code that consults the flag must
            -- therefore read `disabled`, so the mock has to spell it the same
            -- way or a guard passes here and does nothing in game.
            disabled = false,
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
        -- Real AceGUI:Release fires the widget's OnRelease callback and then
        -- releases its children, so a reference production code keeps to a
        -- widget can be dropped from that callback; the mock does the same
        -- (#214, the Restock gold line), or a guard written against it can
        -- go neither red nor green here.
        widget.ReleaseChildren = function(self)
            local children = self._children
            self._children = {}
            for _, child in ipairs(children) do
                child:Fire("OnRelease")
                child:ReleaseChildren()
            end
        end
        widget.Release = function(self)
            self:Fire("OnRelease")
            self:ReleaseChildren()
        end
        -- Real AceGUI EditBox has SetFocus (keyboard focus into the box) and
        -- Button has SetAutoWidth; both are what the Restock tab calls (#214).
        widget.SetFocus = function(self) self._hasFocus = true end
        widget.SetAutoWidth = function(self, on) self._autoWidth = on end
        widget.Show = function(self) self._shown = true end
        widget.Hide = function(self) self._shown = false end
        -- Mock underlying WoW frame (for IsShown checks)
        local mockFrame = {
            _hookScripts = {},
            _anchors     = {},
            IsShown = function() return widget._shown end,
            SetClampedToScreen = function() end,
            SetPoint = function(self, ...)
                self._anchors[#self._anchors + 1] = { ... }
            end,
            ClearAllPoints = function(self) self._anchors = {} end,
            GetLeft   = function() return 0 end,
            GetBottom = function() return 0 end,
            GetWidth  = function() return widget._width or 1000 end,
            GetHeight = function() return widget._height or 600 end,
            SetResizeBounds = function(self, w, h)
                self._resizeBounds = { w, h }
            end,
            SetMinResize = function(self, w, h)
                self._minResize = { w, h }
            end,
            SetScript = function(self, event, func)
                self._hookScripts[event] = { func }
            end,
            HookScript = function(self, event, func)
                self._hookScripts[event] = self._hookScripts[event] or {}
                table.insert(self._hookScripts[event], func)
            end,
            -- Real AceGUI widget frames can hold textures; the focus ring is
            -- drawn on this frame, so a spec that never had CreateTexture
            -- could not tell a drawn indicator from a stubbed one.
            CreateTexture = function(self)
                self._textureCount = (self._textureCount or 0) + 1
                local MW = _G.__MockWoW_makeTexture
                if MW then return MW() end
                local tex = { _shown = true }
                tex.SetColorTexture = function(_, r, g, b, a) tex._color = { r, g, b, a } end
                tex.SetPoint = function() end
                tex.ClearAllPoints = function() end
                tex.SetHeight = function() end
                tex.SetWidth = function() end
                tex.SetDrawLayer = function() end
                tex.Show = function() tex._shown = true end
                tex.Hide = function() tex._shown = false end
                tex.IsShown = function() return tex._shown end
                return tex
            end,
            CreateFontString = function()
                local fs = { _text = "" }
                -- Record args like the AceGUI Label mock: WoW 12.0.7 rejects a
                -- nil third arg to SetFont, so specs assert _setFont[3] is set.
                fs.SetFont = function(_, font, height, flags)
                    fs._setFont = { font, height, flags }
                end
                fs.SetPoint = function() end
                fs.SetText = function(_, t) fs._text = t end
                fs.GetText = function() return fs._text end
                return fs
            end,
        }
        widget.frame = mockFrame
        -- Mock AceGUI Frame sizer sub-frames (exposed for HookScript calls)
        local function mockSizer()
            return {
                _hookScripts = {},
                HookScript = function(self, event, func)
                    self._hookScripts[event] = self._hookScripts[event] or {}
                    table.insert(self._hookScripts[event], func)
                end,
            }
        end
        widget.sizer_se = mockSizer()
        widget.sizer_s  = mockSizer()
        widget.sizer_e  = mockSizer()
        widget.SetDisabled = function(self, d) self.disabled = d end
        widget.SetLayout = function() end
        widget.SetTitle = function(self, t) self._title = t end
        widget.SetStatusText = function(self, t) self._statusText = t end
        widget.SetAutoAdjustHeight = function() end
        -- Real AceGUI stores it as `status` and asserts it is a table (a
        -- container reads its own state back out of it); `_statusTable` is
        -- the mock's older accessor and existing specs read it.
        widget.SetStatusTable = function(self, t)
            assert(type(t) == "table")
            self._statusTable = t
            self.status = t
        end
        widget.EnableResize = function() end
        -- Mock AceGUI Container helpers used by post-resize layout cascade.
        widget.DoLayout    = function() end
        widget.OnWidthSet  = function() end
        widget.OnHeightSet = function() end
        -- Stand-in for the AceGUI Container's inner `content` frame.
        -- A small mock frame is enough; production code only uses it as a
        -- SetPoint target, and the parent's mock SetPoint accepts any args.
        widget.content = { _isMockContent = true }
        widget.SetFullHeight = function() end
        widget.SetFontObject = function() end
        widget.SetJustifyH = function() end
        widget.SetFont = function(self, font, height, flags)
            -- Record args so specs can assert the call shape. Real WoW (12.0.7)
            -- rejects a nil third arg ("bad argument #3 to 'SetFont'"), which
            -- blanks an AceGUI tab; tests check _setFont[3] is non-nil.
            self._setFont = { font, height, flags }
        end
        widget.DisableButton = function() end
        widget.ClearFocus = function() end
        -- Real AceGUI Label and InteractiveLabel expose the FontString they
        -- draw with as `widget.label` (both Constructors set self.label), and
        -- production code reaches through it for the calls the widget itself
        -- does not wrap: every ledger, gold-log and consumption cell calls
        -- `lbl.label:SetWordWrap(false)`. The mock had no such field, so any
        -- spec that rendered one of those three tabs threw on the first cell,
        -- which is part of why the Own Transactions mode went four years
        -- without a test (#222). Given to every widget, like the rest of the
        -- mock's methods, rather than only to the two types that carry it.
        -- Its calls are recorded on the FontString itself, never on the
        -- widget: widget:SetFont and widget:SetText write _setFont and
        -- _text, and aliasing them here would let a label:SetFont call
        -- satisfy an assertion about the widget's own SetFont flags (the
        -- WoW 12.0.7 nil-third-arg pin in about_spec and restockview_spec).
        widget.label = {
            _text = "",
            SetWordWrap = function() end,
            SetJustifyH = function() end,
            SetFont = function(self, font, height, flags)
                self._setFont = { font, height, flags }
            end,
            SetText = function(self, text) self._text = text end,
            GetText = function(self) return self._text end,
        }

        ------------------------------------------------------------------
        -- TabGroup only.
        --
        -- These are gated on the type because this constructor is shared by
        -- every widget and real AceGUI only puts them on a TabGroup. A Frame
        -- with a SelectTab is not a harmless extra: UI/UI.lua points the main
        -- frame's status table at `self.db.profile.ui`, so `mainFrame:SelectTab(x)`
        -- errors in game and would have written `selected` straight into the
        -- SavedVariables profile here, with no fire and nothing to notice it.
        ------------------------------------------------------------------
        if widgetType == "TabGroup" then
            -- Real AceGUI's Constructor initialises all three
            -- (AceGUIContainer-TabGroup.lua), so a group whose SetTabs was
            -- never called still has a list to walk, a status table to record
            -- into and a title to read. `localstatus` is the load-bearing one:
            -- nothing calls SetStatusTable on a tab group, so it is the only
            -- table `status.selected` can land in, and dropping it errors
            -- every UI spec from inside SelectTab. `tabs` is insurance for the
            -- first spec that selects on a group with no SetTabs; a mutation
            -- pass showed nothing needs it today, because BuildTabs makes the
            -- list and every SelectTab the suite makes runs on a bar
            -- RebuildTabs built.
            widget.tabs = {}
            widget.localstatus = {}
            widget.titletext = { GetText = function() return "" end }

            -- The library's split, and it matters: production REPLACES
            -- BuildTabs (UI/UI.lua wraps it to right-align the utility tabs)
            -- and calls the original from the wrapper. With the frame work
            -- inside SetTabs, a wrapper that forgot the original still left a
            -- populated tab list and no spec could tell. In the client the
            -- list is built here and nowhere else, so forgetting it opens the
            -- window with no tab buttons and no content.
            widget.SetTabs = function(self, tabs)
                -- The mock's older accessor for the tab list specs read.
                self._tabs = tabs
                self.tablist = tabs
                self:BuildTabs()
            end

            widget.BuildTabs = function(self)
                local tablist = self.tablist
                if not tablist then return end
                for i, def in ipairs(tablist) do
                    if not self.tabs[i] then
                        self.tabs[i] = {
                            _points = {},
                            ClearAllPoints = function(t) t._points = {} end,
                            SetPoint = function(t, ...) table.insert(t._points, {...}) end,
                            GetWidth = function() return 80 end,
                            GetFontString = function()
                                return { GetStringWidth = function() return 40 end }
                            end,
                            SetText = function() end,
                            SetDisabled = function() end,
                            SetSelected = function(t, sel) t.selected = sel end,
                            Show = function(t) t._shown = true end,
                            Hide = function(t) t._shown = false end,
                            IsShown = function(t) return t._shown end,
                        }
                    end
                    self.tabs[i].value = def.value
                    self.tabs[i]:Show()
                end
                -- Real BuildTabs hides the frames past the new list but leaves
                -- their `value` on them, and SelectTab walks every frame,
                -- hidden ones included. So a bar that shrank (a demotion,
                -- sync_only arriving over HELLO) can still match a stale
                -- value. That was reachable from OpenRestockTab until #244 put
                -- a membership check on it; no production caller reaches it
                -- deliberately now, so the specs that want the behaviour drive
                -- this widget's SelectTab directly. Replicated rather than
                -- corrected: a mock stricter than the library hides what the
                -- client would do.
                for i = #tablist + 1, #self.tabs do
                    self.tabs[i]:Hide()
                end
            end

            -- Real SelectTab, followed step for step: mark the matching tab
            -- frame and clear the rest, record the value on the status table
            -- whether or not anything matched, and fire OnGroupSelected ONLY
            -- when the value is one the group currently holds. It was
            -- `self._selectedTab = tab` and nothing else, so every production
            -- tab switch was a no-op under test (#121): RebuildTabs selecting
            -- the default tab, RefreshUI's unbuilt branch, the Consumption
            -- player link, OpenRestockTab, and the Layout tab's inner group
            -- building its own content.
            --
            -- Two things not to change. The fire is guarded, or a spec builds
            -- a tab the group does not hold. And nothing is released here:
            -- production's GBL:SelectTab calls ReleaseChildren itself, so a
            -- release here would release twice.
            widget.SelectTab = function(self, tab)
                local status = self.status or self.localstatus
                local found
                for _, t in ipairs(self.tabs) do
                    if t.value == tab then
                        t:SetSelected(true)
                        found = true
                    else
                        t:SetSelected(false)
                    end
                end
                status.selected = tab
                -- The mock's own accessor, older than the fan-out. Written
                -- above the guard like status.selected, so it records a
                -- selection the group refused; read GBL.activeTab to tell a
                -- refused selection from one that built something.
                self._selectedTab = tab
                if found then self:Fire("OnGroupSelected", tab) end
            end
        end

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
