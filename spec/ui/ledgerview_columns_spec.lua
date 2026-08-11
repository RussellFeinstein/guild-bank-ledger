------------------------------------------------------------------------
-- ledgerview_columns_spec.lua — Tests for UI/LedgerView.lua column visibility
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

local GBL

describe("LedgerView columns", function()
    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    describe("GetVisibleColumns", function()
        it("keeps the Location column when moves are hidden", function()
            local cols = GBL:GetVisibleColumns({ hideMoves = true })
            local keys = {}
            for _, col in ipairs(cols) do
                keys[col.key] = true
            end
            assert.is_true(keys.tab)
            assert.equals(#GBL.LEDGER_COLUMNS, #cols)
        end)

        it("returns every defined column when no filters are set", function()
            local cols = GBL:GetVisibleColumns(nil)
            assert.equals(#GBL.LEDGER_COLUMNS, #cols)
        end)
    end)
end)
