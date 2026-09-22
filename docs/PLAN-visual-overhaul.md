# Visual overhaul: the direction before the rebuild

Written 2026-09-21 against `main` at `eda34ea` (v0.40.0), from three read-only surveys run the same
day: the UI code, the docs and tracker, and a web research pass. It is the design the visual
overhaul is built from, at the level of the set: the chassis, the tab groups, the tokens, the
component vocabulary, the accessibility contract, the test seam and the migration order. Each
migration step's PR carries its own render spec for the views it moves; this document does not
carry them, so #204 stays open and un-designed at the view level until its step is planned.

Three calls were put to Russell on 2026-09-21 and decided, each open to reversal in review of this
doc: the chassis is Blizzard's current frame templates, migrated tab by tab, with AceGUI retired as
each tab moves; the nine flat tabs become four groups; and nothing is filed on the tracker until
this doc has been read, so section 10 is a proposal rather than a record.

Every number below was measured on that commit with the command beside it or with the file and
line quoted. The URLs in section 12 were read by the research pass on 2026-09-21 and not by the
author of this doc directly, which is why each finding names the page it came from.

## 1. What this decides, and what it leaves alone

Decided here: the look, the chassis, the information architecture, the colour and type tokens,
the component vocabulary, the accessibility contract every rebuilt view signs, the seam the tests
assert on, and the order the tabs move in.

Left alone: the Restock journey (`docs/PLAN-restock-ux.md` stands; the overhaul restyles its rows,
banner and controls and changes none of its states or words), the Sort flow (#55's own design
pass, which runs before Sort moves), the data layer, the sync protocol, and the log pop-ups
(`feedback_logs_on_demand`: logs open on demand and are never furniture).

The point of view, in one line: **a dense, technical ledger that looks like it shipped with the
game.** Native chrome, one gold, monochrome tables, state carried by text, identity from
restraint and density rather than from a skin.

## 2. The current state, measured

The repo holds no screenshot of the addon (no image file exists outside `Libs/`, and neither
README nor the CurseForge description embeds one), so the current look is described from the code.

**The shell.** `AceGUI:Create("Frame")` (`UI/UI.lua:19`). AceGUI's Frame draws a black backdrop
behind the 32px `Interface\DialogFrame\UI-DialogBox-Border` and the `UI-DialogBox-Header` title
plaque (`Libs/AceGUI-3.0/widgets/AceGUIContainer-Frame.lua:166-224`), with a status bar at the
bottom that nothing ever writes to: there is no `SetStatusText` call in the repo. Tabs are an AceGUI
`TabGroup` drawing the pre-Dragonflight `OptionsFrame` tab textures, right-aligned by a
monkey-patch of `BuildTabs` with hardcoded offsets (`UI/UI.lua:190-221`). Buttons are
`UIPanelButtonTemplate`, scrollbars `UIPanelScrollBarTemplate`. No Blizzard frame template or
texture is used anywhere outside `Libs/`. This is the 2008 dialog look, and ElvUI ships a dedicated
Ace3 skin module precisely because it is that recognisable (section 12).

**The widget census.** 240 `AceGUI:Create` sites over twelve widget types: Label 113, Button 33,
SimpleGroup 30, EditBox 16, Dropdown 11, CheckBox 11, ScrollFrame 9, Heading 7, InteractiveLabel 5,
TabGroup 2, Frame 2, MultiLineEditBox 1 (`grep -oh 'AceGUI:Create("[A-Za-z]*")' UI/*.lua src/*.lua`).
7,895 lines under `UI/`.

**Colour.** Six semantic keys (`WITHDRAW`, `DEPOSIT`, `MOVE`, `ALERT`, `NEUTRAL`, `FOCUS`) in four
colourblind palettes plus a high-contrast set (`UI/Accessibility.lua:39-108`), read through
`GetAccessibleColor` (`:147-154`). Beside them, 130 literal `|cffRRGGBB` codes across 21 distinct
hexes (`grep -ohiE '\|cff[0-9a-f]{6}' UI/*.lua`), 44 of them in `UI/LayoutEditor.lua`, 22 in
`UI/SortView.lua`. Success alone is spelled `00ff88`, `55ff55` and `88ff88`; warning is `ffcc00`,
`ffaa55` and `ff8800`; muted is six greys (`888888`, `999999`, `a0a0a0`, `aaaaaa`, `cccccc`,
`666666`). The palette reaches the Gold Log summary, the Consumption net columns and the Restock
status, and nothing else, so the colourblind and high-contrast modes the README advertises change
three places on screen. `UI/ChangelogView.lua:17-24` carries its own `SECTION_COLORS` table. The
`colorHex` helper that turns a palette colour into a `|cff` code is written three times with two
rounding rules (`UI/UI.lua:753-755`, `UI/UI.lua:1138-1140`, `UI/RestockView.lua:39-44`).

**Triple encoding.** `GetTxTypeDisplay` (`UI/Accessibility.lua:209-235`) returns colour, icon and
label for a transaction type, and `A11Y.ICONS` (`:111-115`) maps the three types to Blizzard
textures. The Transactions and Gold Log rows render the label only (`UI/LedgerView.lua:184`,
`UI/UI.lua:870`); `A11Y.ICONS` has no production consumer. The Sort tab's markers
(`UI/SortView.lua:29-33`) are three coloured ASCII characters and deliberately bypass the palette
(`:22-28`). The Restock row is the one place all three encodings reach the screen
(`UI/RestockView.lua:51-70`, rendered at `:419-434`).

**Type.** `GetScaledFont` (`UI/Accessibility.lua:178-183`) returns `db.profile.ui.font` and a
size clamped to 8-24 (`:163-174`); 18 `SetFont` sites read it (RestockView 10, AboutView 6,
ChangelogView 1, UI.lua 1), against 27 `SetFontObject(GameFontNormalSmall)` and 4
`SetFontObject(GameFontNormalLarge)` sites that do not, and every AceGUI widget that sets neither.
`ui.scale`, `ui.lockFrame` and `ui.colorblindMode` are declared in the defaults
(`src/Core.lua:127-129`) and read nowhere. No font size, contrast or colourblind setting has an
in-game control (#65): AceConfig is in the `.toc` and never registered, and the minimap tooltip
promises "Right-click: Options" (`UI/UI.lua:1530`) with no right-click handler (`:1522-1526`).

**Tables and rendering.** Every table is a `ScrollFrame` of `SimpleGroup` rows holding fixed-pixel
`Label`s with word wrap off (`UI/LedgerView.lua:208-222`; column widths at `:13-21`,
`UI/UI.lua:562-567`, `:992-1008`). There is no virtualised list. Pagination is computed at 100
rows (`UI/LedgerView.lua:69`, `UI/UI.lua:570`) with no controls, so page 2 cannot be reached
(`TODO` at `UI/LedgerView.lua:224` and `UI/UI.lua:896`). Every filter change, sort click and
progress event on a non-Sort tab is a full `ReleaseChildren` and rebuild of up to about 700
widgets; the Layout tab hides the flicker behind `SetAlpha(0)` and a `C_Timer.After(0)`
(`UI/LayoutEditor.lua:556-574`). The four officer checkboxes and the personal-prefs row are
rebuilt above every tab (`UI/UI.lua:326-331`, `AddSettingsRow` at `:430`, `AddPersonalSettingsRow`
at `:496`), above Transactions and About alike.

**Keyboard.** `RegisterFocusable` is called from `UI/SortView.lua`, `UI/RestockView.lua` and
`UI/ChangelogView.lua` (two pagination buttons, no key handler), and from no other tab. The focus
ring (`UI/Accessibility.lua:296-363`) draws on frames AceGUI pools, so a ring can return on
whatever recycles the frame (#164). `_NavKey` and the activate wrapper are duplicated between Sort
and Restock.

**Conventions.** Section headings are a `Heading` widget on Sort, Restock and Layout, a
`|cffffcc00` Label on Consumption, Sync and the Gold Log summary, and a `GameFontNormalLarge` Label
on About and Changelog. Spacing is `" "` Labels and a 20px spacer Label. The sort indicator is
` [asc]` / ` [desc]` text in four copies; the six-entry date-range list is copied three times;
`itemLabel` is written three times. `||` is used as a visual divider in three files, rendering as a
single pipe.

**What the tracker already asks for.** #204 (the History views were never designed as a set: one
vocabulary, a pagination model, five accessibility dimensions per element); #206 (the Layout tab
audit); #55 (the Sort tab flow); #214 (the Restock tab half of rebuild step 2, next in #188's
order); #65 (no in-game accessibility control); #164 (rings on pooled frames); #86 (cell rendering
onto column definitions); #43, #63, #88. ROADMAP gate 2 for v1.0: keyboard navigation end to end
across every widget, focus indicators verified, palettes validated against WCAG AAA.

## 3. The point of view, and the banned list

The research pass (section 12) found the generic AI-generated look named the same way by six
2025-26 sources, and the cure named the same way too: pick a point of view, lock its tokens, make
every colour mean something, build hierarchy from weight and contrast rather than decoration, and
keep a banned list that fails review. The data-table sources agree with each other on alignment,
rules and colour. What follows is those rules applied to a ledger inside the game client.

**The look.** The frame is the game's own: the Warband bank, the Auction House and Baganator all
draw the same nine-slice border, and the ledger should read as one of them. Inside it, one colour
carries emphasis (Blizzard's gold, `NORMAL_FONT_COLOR`, and only for labels, column headers,
section titles and the selected tab), values are white, secondary text is a warm grey that is not
the disabled grey, and the tables are monochrome except where a colour means something: the
transaction type, a player's class, an item's quality, a status. Numbers are right-aligned in the
number font. Rows are separated by alignment and a 1px rule, never by stripes. Density is a
setting.

The family resemblance to the WGA Raid Hub is structural, not chromatic. Kat's warm comps
(`#13110e` ground, `#ede6d8` ink, muted gold `#d9a441`, Barlow and Cinzel) are a website palette and
are not copied into the client; what the two share is warm dark, gold held in reserve, dense tables
and state carried by text. The In-Game Guild Pane mockup drawn for kat on 2026-09-20 is the native
reading of the same idea, with one web shortcut corrected below: it put the tabs in the title bar,
and the native idiom is tabs below the frame.

**The banned list**, written into review. Each line says why.

- Gradients, glass, glow, drop shadows as separators: named as the loudest generic tells by every
  source in section 12, and the client's own frames use none of them.
- Rounded cards, nested panels, a coloured stripe down a card's edge: the "cardocalypse" and the
  accent-stripe tell; a stripe reads as an alert where there is none.
- Pill badges as decoration: a badge carries state or nothing; the count pill on a tab is state.
- Zebra rows: they fight hover and selection, and every table source in section 12 says rules
  after alignment instead.
- Centred columns: text left, numbers right, headers aligned with their column.
- Pulsing dots, bouncing hover, page-load reveals: motion only for a state change that takes
  longer than 100 ms.
- Colour as the only carrier of a state: the accessibility rule this repo already has.
- Grey for a healthy state: the 2026-08-10 lesson, where a grey "syncing" tag read as dead within
  days of shipping. Disabled and de-emphasised are the same colour in UI idiom.
- Unicode glyphs or emoji as encoding: in-game strings are ASCII (`spec/ascii_strings_spec.lua`),
  and a glyph that does not draw leaves a row carried by colour alone.
- Generic thin-line icons: icons are the client's atlases and the items' own icons.
- Web fonts: the client has Friz Quadrata, Arial Narrow, Morpheus and Skurri, and an addon can ship
  a TTF; this one does not, because the point is to look native.

## 4. Tokens

One module, `UI/Theme.lua`, and every colour and font read in `UI/` goes through it. Text roles map
onto Blizzard's font colour globals so the game and every skin agree; status roles keep the
existing palettes; class and quality colours come from the game. Nothing under `UI/` may hold a
`|cff` literal once the sweep in step 0 lands (section 8 has the spec that enforces it).

**The ground.** Blizzard's inset background is a texture and a skin can fade the nine-slice, so the
table area gets a solid backdrop GBL owns: `#141210`, a warm near-black. Every ratio below is
against it (WCAG 2.1 relative luminance; the script is `contrast.js` in the spike's scratchpad, and
the pure-Lua version of the same formula is the spec in section 8). The previous palette comment
documents its ratios "against dark backgrounds (~#1a1a1a)"; the new ground is darker, so every
existing key reads higher here than there.

| Token | Value | Maps to | Role | Ratio |
|---|---|---|---|---|
| `ground` | `#141210` | GBL's own | table and inset backdrop | |
| `heading` | `#FFD100` | `NORMAL_FONT_COLOR` | labels, column headers, section titles, the selected tab, nothing else | 12.79 |
| `ink` | `#FFFFFF` | `HIGHLIGHT_FONT_COLOR` | values | 18.69 |
| `muted` | `#B5AB9C` | GBL's own | secondary text, never a state | 8.25 |
| `disabled` | `#808080` | `GRAY_FONT_COLOR` | disabled controls only | 4.73 |
| `rule` | `#2B2620` | GBL's own | 1px separators | 1.25 (decorative) |
| `hover` | white at 6% | over `ground` | row under the cursor | |
| `selected` | gold at 12% | over `ground` | selected row | |
| `focus` | `#FFFF00` | `FOCUS` | the ring | 17.40 |

`muted` sits 1.74:1 away from `disabled`, which is the point of it: the two must never read as the
same grey. `disabled` is Blizzard's own value and clears 4.5:1 on this ground; it is not used for
anything that is merely secondary.

**Status keys**, unchanged in value, on the new ground:

| Key | normal | protanopia | deuteranopia | tritanopia |
|---|---|---|---|---|
| WITHDRAW | `#E64D4D` 4.92 | `#E6994D` 8.03 | `#E6994D` 8.03 | `#E64D4D` 4.92 |
| DEPOSIT | `#4DCC66` 9.03 | `#4D99E6` 6.24 | `#4D99E6` 6.24 | `#4DCC66` 9.03 |
| MOVE | `#4D80E6` 4.94 | `#4D80E6` 4.94 | `#9966CC` 4.56 | `#E6994D` 8.03 |
| ALERT | `#FFB300` 10.41 | same | same | same |
| NEUTRAL | `#CCCCCC` 11.64 | same | same | same |

Every normal-mode key clears AA (4.5:1) on this ground. On the documented `#1a1a1a` the
deuteranopia MOVE falls to 4.25 and fails AA, which the darker ground repairs.

**The high-contrast set does not meet its own claim.** `UI/Accessibility.lua:73` says "7:1+ contrast
(WCAG AAA)", the CurseForge description says "High contrast mode (WCAG AAA)", and ROADMAP gate 2
says the palettes will be validated against AAA. Measured: HC `WITHDRAW #FF3333` is 5.77 on pure
black, 4.78 on `#1a1a1a` and 5.14 on the new ground; HC `MOVE #6699FF` is 7.57, 6.27 and 6.73; the
deuteranopia HC `MOVE #B366FF` is 6.26, 5.19 and 5.57; the protanopia and deuteranopia HC
`DEPOSIT #3399FF` is 7.14, 5.92 and 6.35. A saturated red cannot reach 7:1 on any dark ground, so
the claim was never true on the client. Candidate replacements that do reach 7:1 on the new ground
and on `#1a1a1a`: `WITHDRAW #FF8080` (7.70 / 7.17), `MOVE #7FA8FF` (7.96 / 7.42), deuteranopia
`MOVE #CC99FF` (8.51 / 7.93), protanopia and deuteranopia `DEPOSIT #66B2FF` (8.34 / 7.77). These
are proposals for the accessibility milestone to validate on screen, and the doc claim is corrected
when the values land, not before (section 10 files it).

**Game conventions carried, never load-bearing.** Class colours (`C_ClassColor`) and quality
colours (`ITEM_QUALITY_COLORS`) are the client's and are kept for recognition. Four of them fall
under 4.5:1 on the ground: Death Knight `#C41E3A` 3.20, Demon Hunter `#A330C9` 3.40, Shaman and
Rare `#0070DD` 3.88, Epic `#A335EE` 3.83. The rule that makes this acceptable is that the name is
the encoding and the colour is a convention: a player's row is identified by the name text, an
item by its name and icon, and nothing a member has to do depends on telling `#0070DD` from
`#A330C9`. High-contrast mode does not lift them, which matches the client.

**Type.** Words in Friz Quadrata (`FRIZQT__.TTF`, the `GameFont*` family), numbers in Arial Narrow
(`ARIALN.TTF`, the `NumberFont*` family) in right-anchored FontStrings, because no bundled font is
monospaced and tabular alignment has to come from the anchor. GBL creates its own font objects once
with `CreateFont`, copied from `GameFontNormal`, `GameFontHighlight` and `NumberFontNormal`, at three
steps of the existing `fontSize` setting (small = size - 2, base = size, large = size + 4, clamped
inside 8-24), and re-sizes them when the setting changes. Every native widget GBL builds is given
one of those objects, which is how the setting reaches everything at once instead of 18 labels.
Whether a native template's FontStrings follow a re-sized font object is item 3 of the step 1
probe.

**Spacing and density.** Row height is the base font size plus padding: compact adds 6, regular
adds 10, so at size 12 a row is 18 or 22 logical pixels. Cell padding 6 horizontal. Section gap 12.
Density is a setting (section 5, Settings) with regular as the default and compact for the ledger
power user, which section 12's table sources recommend over choosing one.

## 5. Components

Each component names the Blizzard template it is built on. All of them are in use on this client by
Baganator, Auctionator or Syndicator at `## Interface: 120100` (counts of files that name them
across the installed Baganator, Auctionator, Syndicator, Plumber, Cell, RCLootCouncil, Details and
TradeSkillMaster): `ButtonFrameTemplate` 22, `ButtonFrameTemplate_HidePortrait` 11,
`PanelTabButtonTemplate` 2, `WowScrollBoxList` 10, `MinimalScrollBar` 9,
`CreateScrollBoxListLinearView` 10, `CreateTableBuilder` 3 (Auctionator's
`Imports_ModernAH/TableBuilder.lua` is four aliases of Blizzard's `TableBuilderMixin` family),
`WowStyle1DropdownTemplate` 6, `SearchBoxTemplate` 5, `InsetFrameTemplate` 7,
`UIPanelDynamicResizeButtonTemplate` 39, `Settings.RegisterCanvasLayoutCategory` 5. Two names have
no local user and are unverified: `WowStyle1FilterDropdownTemplate` and
`Settings.RegisterVerticalLayoutCategory`. The step 1 probe settles both; the design below is
written so that neither is load-bearing.

**Shell.** A frame inheriting `ButtonFrameTemplate` with the portrait hidden through
`ButtonFrameTemplate_HidePortrait`, the way Baganator's guild view does
(`SingleViews/GuildView.xml:2`). The title is "GuildBankLedger" with the `[DEV]` suffix on a dev
build, in the template's own title FontString. The frame is movable and resizable with the
existing 810x500 floor and its position persisted through the same `db.profile.ui` keys
(`top`, `left`, `width`, `height`) AceGUI writes today, so a saved layout survives the move.
Escape closes it through `UISpecialFrames` as now (#40). Content sits in an inset holding the
`ground` backdrop. A footer line at the bottom of the inset, in `muted`, carries what the empty
AceGUI status bar never did: the sync state in the round-line vocabulary ("Synced 2 min ago, 14
peers" / "Sync off"), the last scan ("Scanned 09:41"), and the row count of the table on screen.
The version label moves into the footer's right end and keeps its update-available colour and
text.

**Tab strip.** Four `PanelTabButtonTemplate` tabs hung below the frame's bottom edge, the way the
Character and Collections frames hang theirs: History, Bank, Sync, Help. Access gating stays a
property of the list: a `sync_only` member gets Sync and Help; a member without sort access gets
History, Sync and Help; Bank appears when `HasSortAccess()` holds and its Layout view when
`HasLayoutWrite()` holds. The selection fallback is the one `RebuildTabs` has today and
`spec/ui/tab_visibility_spec.lua` pins. Tab widths come from the font object, not a constant;
the probe measures the strip at font size 8 and 24.

**In-tab switch.** Inside History and Bank, a row of text buttons under the title (Transactions,
Gold, Players; Sort, Layout, Restock), selected one in `heading`, others in `ink`, drawn as a
segmented control from three `UIPanelButtonTemplate` buttons with the selected one disabled-styled
in gold. Not a second tab strip: the frame has one tab strip and it is at the bottom.

**Table.** `UI/Table.lua`, one component every ledger, list and plan view is built from. Its input
is a column definition list (key, header text, width or fill, alignment, font role, sort
comparator, cell renderer) and a data provider; its output is a `WowScrollBoxList` with a
`MinimalScrollBar` and a `CreateTableBuilder` table whose header container sorts on click and
marks the sorted column with a Blizzard sort arrow atlas plus the header text in `heading`.
Numbers right-aligned in the number font, text left, headers aligned with their column. A 1px
`rule` under each row, `hover` under the cursor, `selected` on the selected row. Row height from
the density setting. Frames are reused by the scroll view, so every cell renderer overwrites
every field it can set (the wiki's own warning). `GBL.LEDGER_COLUMNS` (`UI/LedgerView.lua:13-21`)
is the first column definition list it consumes, once #86 moves the cell text dispatch onto it.

**Filter row.** `SearchBoxTemplate` for search; `WowStyle1DropdownTemplate` through `MenuUtil` for
date range and category (the 11.0 menu system; `UIDropDownMenu` is deprecated); the type filter as
the filter variant if the probe finds it and as a plain dropdown with checkmarks through
`MenuUtil.CreateCheckbox` otherwise; a `UICheckButtonTemplate` for "Hide moves"; one Reset button
with one wording on every view. One date-range list, defined once. The six-entry list #204 says is
copied three times is the first thing this row retires.

**Status cell.** One renderer for every cell that carries a state: an icon (an atlas or the
`A11Y.ICONS` texture), the text, and the palette colour on the text, in that order, from
`GetTxTypeDisplay` on the ledgers, `GetRestockStatusDisplay` on Restock, and a Sort equivalent of
`STATUS_MARKER` that returns the same three fields. The three markers Sort draws today (`>`, `+`,
`x`) become "running", "issued" and "refused" with an atlas each; the text is what a capture reader
greps for, so it stays a word.

**Banner.** Restock's, as `docs/PLAN-restock-ux.md` section 4 has it: one line in `ink` under the
in-tab switch, the disabled reason text-carried, the gold line updated by `SetText` on
`PLAYER_MONEY`. The Sort tab's amber unviewable line (#137) is the same component in `ALERT`.

**Empty state.** One sentence in `muted`, centred in the table area, and nothing else: "No
transactions match these filters", "Scan the bank to see what it holds" (#43), "No peers seen this
session". No illustration, no icon.

**Settings.** A canvas category registered with `Settings.RegisterCanvasLayoutCategory` and
`Settings.RegisterAddOnCategory`, the route Baganator, Auctionator, Syndicator and Plumber all take
here; the vertical layout is used instead if the probe finds it registered on 12.1. Its controls,
in order: font size (8-24), density (compact / regular), high contrast, colourblind palette (auto
from the CVar, or one of the four), show minimap button, open with the guild bank, lock the bank
while scanning, auto re-scan, mute Silvermoon Citizen chatter. That is `#65`'s four missing
controls plus the five that today rebuild above every tab (`UI/UI.lua:326-331`), which leave the
tabs. The minimap button's right-click opens this category, which makes its tooltip true. Guild-wide
access control stays on the Sync tab, GM-gated, because it is guild state and not a preference.

**Focus ring.** The existing four-edge ring (`UI/Accessibility.lua:296-363`) in `focus`, drawn on
frames GBL creates and owns. While a tab still runs on AceGUI inside the bridge (section 9, step
1), the ring can still land on a pooled frame and #164's `ClearFocusOrder` call on tab change is
the fix for that window; once a tab has moved, its frames are not pooled and the leak has no
producer.

**Skins.** Under the default UI the addon is native by construction. It is skinnable, not skinned:
EllesmereUI takes a registration (`EllesmereUI.RegisterSkin("GuildBankLedger", function(S) ... end)`,
`EllesmereUIBlizzardSkin_SkinAPI.lua:5`) and ElvUI has its own, and Baganator ships one file per
skin. Those files are written when someone asks, after the chassis lands, and each one recolours
chrome only: `heading`, `ink`, `muted`, `disabled` and the status keys stay GBL's under every skin.

## 6. The views on the chassis

What each view keeps, what changes, and which open item each absorbs. Render specs ride the PR of
the step that moves the view.

**History > Transactions.** The Table with the seven columns of `GBL.LEDGER_COLUMNS`: Time, Player
in the class colour with the name as the identifier, Action as the status cell (icon, text, colour:
the triple encoding the README has claimed since v0.3.0), Item with its icon in the quality colour,
Count right-aligned in the number font, Category as a display name rather than the `gem_red` key,
Tab. The filter row above. No pages: the list is virtualised, the footer carries "1,204 of 12,310
rows", and the 100-row cap goes. That answers #204's pagination-model question and Russell confirms
it in review. Absorbs #204's Transactions half, #86, #63 (the season entry in the one date list),
#43 (the empty state).

**History > Gold.** The same Table with the Gold Log columns and the summary as a fixed right-hand
column in `muted` labels and `ink` values, repairs and withdrawals told apart by the status cell's
text (#204's "a member cannot tell a manual gold withdrawal from a repair").

**History > Players.** The Consumption view under #204's member-facing framing: the guild totals as
a row of label-and-value pairs (label in `muted`, value in `ink`, the label folded into the value
where it reads better: "47 flasks" rather than "Flasks: 47"), then the per-player Table. Whether the
tab is called Players is #204's call; the view keeps every column it has.

**Bank > Sort.** The preview and progress list as a Table whose rows are ops, the status cell in
the first column, the op text as `formatOpRow` writes it today (`UI/SortView.lua:42-51`), the amber
unviewable line above the list, Deficits and Unplaced below it with the per-row reason from
`SortReasonText` (#45). The controls (Preview, Execute, Cancel, Scan bank, Open Sort Log, Include
bags) in one row. Moves after #55's design pass, which may change what the rows say; this doc
changes only how they are drawn.

**Bank > Layout.** The eight bank tabs and Sort Access as the in-tab switch's second row rather
than a nested TabGroup, which retires the nested-ScrollFrame constraint
(`project_nested_tabgroup_scroll`). Rows per #206's audit, which rides this step.

**Bank > Restock.** `docs/PLAN-restock-ux.md` sections 3 to 8 as written: the list in every state,
`RESTOCK_STATUS_TEXT` through the status cell, the banner, the budget box and confirm-at-price
beside it, PRICED with Confirm and Cancel in the controls row. #214 is that tab half, and it is
built on the chassis rather than before it (section 9).

**Sync.** The peer list as a Table: name, version, state as a status cell whose text is the
existing tag vocabulary (`UI/SyncStatus.lua:50-66`) with `||` retired in favour of a second column,
last HELLO. Enable, auto-sync and chat log as the tab's own checkboxes; access control in its own
group below, GM-gated.

**Help.** Changelog and About on one tab under the in-tab switch. About keeps its Ko-fi and
CurseForge links; Changelog keeps `CHANGELOG_DATA`, its section colours move into the palette as
`heading`, `DEPOSIT`, `ALERT`, `WITHDRAW`, `muted` and one purple for Security, and its pagination
becomes the Table's own scrolling.

## 7. Accessibility contract

Every view moved onto the chassis signs this table for each element class before its PR opens, in
the shape `docs/PLAN-restock-ux.md` section 12 uses. The chassis makes it one mechanism: one key
handler on the shell (`EnableKeyboard` with propagation when nothing is focused, so the keys reach
the game until Tab enters the walk), one focus order per view registered through
`RegisterFocusable`, `Escape` clearing focus before it closes the frame.

| Element | Keyboard path | Focus ring | Colour fallback | Font scaling | Screen-reader text |
|---|---|---|---|---|---|
| Tab strip | Tab enters; Left/Right move; Enter/Space select | ring on the tab button | selected tab text in `heading` and the frame title says the view | tab from the font object | tab text |
| In-tab switch | in the walk after the strip; Left/Right; Enter | ring | selected in `heading`, others `ink` | button from the font object | button text |
| Filter controls | in the walk in reading order; Enter opens a dropdown, Escape closes it | ring | each dropdown shows its value as text | from the font object | label plus value |
| Table header | in the walk; Enter sorts; the sort arrow plus "sorted by X" in the footer | ring on the header button | arrow atlas plus footer text | header from the font object | header text plus sort state |
| Table rows | Up/Down move the selected row; Enter activates a row action | `selected` fill plus ring | status cells carry text | row height from the font | the row's cell texts |
| Buttons | in the walk; Enter/Space | ring | disabled state is `disabled` plus the reason on the banner | from the font object | button text |
| Checkboxes | in the walk; Space toggles | ring | text label always | from the font object | label plus state |
| Banner | not focusable; read as text | none | text-carried | from the font object | the line |
| Footer | not focusable | none | text-carried | from the font object | the line |

The verification pass (ROADMAP gate 2) runs after the last view moves, on screen, per the standing
rule that a claim about a UI is made after the pixels are seen: tabbing advances through every
element above on every view, the ring is visible on each, every state reads with colour off, the
frame is usable at font size 8 and 24 without clipping.

## 8. Testing strategy

The seam specs assert on is `UI/Table.lua`'s input, not its frames: column definitions, the rows
the data provider yields, the sort a header click produces, the alignment and font role each column
declares. `spec/ui/ledgerview_columns_spec.lua` already asserts on `GetVisibleColumns`; #86 moves
the cell text dispatch onto the same definitions and is the first step for that reason.

`spec/mock_wow.lua` gains recording stubs for `CreateScrollBoxListLinearView`, `ScrollUtil`,
`CreateDataProvider`, `CreateTableBuilder` and the `Settings` namespace, each storing what it was
given so a spec can read the rows and columns back. A stub is a claim about a call shape and not
about the client (the mocks-lie standing rule), so every template is also exercised in game at the
first reachable point of each step, and the PR says which ones were.

Two new specs guard the tokens. A `|cff`-literal ban over the file list in the `.toc` under `UI/`,
in the shape of `spec/ascii_strings_spec.lua` (comments stripped first), with `UI/Theme.lua` the
one exemption. And a contrast spec that computes WCAG 2.1 relative luminance in pure Lua and
asserts every `Theme` text token and every palette key at or above 4.5:1 against `ground`, and
every high-contrast key at or above 7:1 once the section 4 replacements land; until then the HC
assertion is written and marked pending with the four failing values named, so the gate cannot
be forgotten.

GBL's own tab strip retires the mock's `SelectTab` no-op (`project_ui_smoke_test_gaps`, #121): a
tab select is a GBL function that builds the view, so `spec/ui/tab_visibility_spec.lua`'s rebuild
assertions can read a built tree instead of pcall-ing builders that crash on the mock's missing
`.label`.

Test-first applies to every build step in section 9 and not to this doc: each step's plan opens
with its test list, red before green, the way `docs/PLAN-restock-ux.md` section 13 prescribes.

## 9. Migration order and cost

Cost is a band, not a figure: S is a session, M a few sessions, L a milestone-sized item. Each step
is one PR with its own stamp, closes its issue, and ends with a screenshot in the PR body and the
in-game check it promised.

- **Step 0, `UI/Theme.lua` and the literal sweep (M).** The token table, the three font objects,
  `colorHex` written once, the 130 literals routed through the palette, the two specs from section
  8. No visual change beyond consistency, so it ships alone and first, and every later step reads
  tokens instead of adding literals. Absorbs #44.
- **Step 1, shell, tab strip, footer, Settings (M).** Opens with a 40-line in-game probe frame: the
  templates in section 5 exist on 12.1 and render under EllesmereUI's Blizzard skin, the tab strip
  at font sizes 8 and 24, a re-sized font object propagating to a template's FontStrings, and
  whether `WowStyle1FilterDropdownTemplate` and `Settings.RegisterVerticalLayoutCategory` are
  registered. Then the shell, with each un-migrated tab body hosted inside the inset the way
  AceGUI's own `BlizOptionsGroup` container hosts AceGUI content in a native panel
  (`Libs/AceGUI-3.0/widgets/AceGUIContainer-BlizOptionsGroup.lua:59-128`: a `SimpleGroup`-shaped
  container sized from `OnWidthSet` and `OnHeightSet`). The `AddFillChild` registry
  (`UI/UI.lua:129-150`) goes with the AceGUI Frame. Absorbs #65 and the minimap tooltip promise.
- **Step 2, `UI/Table.lua` and Transactions (L).** The Table component, #86, and the reference view
  in section 6, with the filter row. The render spec for Transactions rides this PR. Absorbs #63
  and #43.
- **Step 3, Gold and Players (M).** Two more column lists on the same Table; the summary column;
  #204 closes here with its own verification.
- **Step 4, Sync and Help (S).** The peer Table, the checkboxes, the access-control group; About and
  Changelog under one tab.
- **Step 5, Restock (M).** #214 on the chassis. The rows, banner and controls per
  `docs/PLAN-restock-ux.md`; nothing in that design changes.
- **Step 6, Sort (M, after #55).** The plan Table and the status cell, once #55 has decided the
  flow.
- **Step 7, Layout (L).** #206's sweep on the chassis; the nested TabGroup goes.
- **Step 8, the accessibility verification pass.** ROADMAP gate 2, over every rebuilt view, on
  screen.

The order follows dependency and then value: tokens before anything reads them, the shell before
any tab can move, the Table before any table view, the reference view before the ones that copy
it, and the two views with open design passes (Sort, Layout) last so they move once.

## 10. What this does to the tracker (a proposal; nothing is filed)

A **Visual overhaul** milestone, whose description carries the section 9 order, absorbing History
views rework (#204, #86, #63, #43) and taking #65, #164 and #44 from Accessibility to v1.0, since
each is a consequence of the chassis. Accessibility to v1.0 keeps its verification pass as step 8
and runs after the milestone, which is the placement #188 already gives History views rework.

The one order change this asks of #188: steps 0 to 2 before #214, so the Restock tab half is built
once, on the chassis, instead of on AceGUI and then again. #214 was next in the order; under this
proposal it becomes step 5. If Russell would rather see the Restock tab finished first, the cost is
one more rebuild of that tab and nothing else in this doc changes.

Issues to file when the doc is accepted, one clause each, in the tracker's table shape:

| # | Issue | Runs | What |
|---|---|---|---|
| 1 | Theme tokens and the literal sweep | beside | `UI/Theme.lua`, three font objects, 130 literals routed, the two token specs (absorbs #44) |
| 2 | Native shell, tab strip, footer, Settings | after 1 | `ButtonFrameTemplate` shell hosting AceGUI bodies, four tabs, footer line, Settings category (closes #65) |
| 3 | Table component and Transactions | after 2 | `UI/Table.lua` on `WowScrollBoxList` and TableBuilder, #86, the reference view (closes #63, #43) |
| 4 | Gold and Players on the Table | after 3 | two column lists, the summary column (closes #204) |
| 5 | Sync and Help on the chassis | after 3 | peer Table, checkboxes, access-control group, About and Changelog under one tab |
| 6 | Restock tab on the chassis | after 3 | #214's content, built once |
| 7 | Sort tab on the chassis | after 3 and #55 | plan Table, status cell |
| 8 | Layout tab on the chassis | after 3 | #206's sweep |
| 9 | High-contrast palette values that reach 7:1 | beside | the four section 4 replacements validated on screen; the AAA claim corrected in three docs |

Item 9 is filed regardless of the rest: the claim is on the CurseForge page today.

## 11. Open questions

- **Which view does each role open first, and how often.** The four groups and the Help tab are a
  plausible default, not observed usage (the 2026-09-01 lesson: a genre-plausible structure is an
  assumed field). Before step 1, Russell answers from the guild for the GM, an officer with sort
  access and a plain member; the answer decides the default tab per role and whether Help is a tab
  or a button in the title bar.
- **Players or Consumption**, #204's call.
- **No pages**, section 6's answer to #204's pagination model, to confirm.
- **The guild's split between the default UI and skins**, which decides how soon a skin file is
  worth writing.
- **The probe's five readings** (section 9, step 1), which decide the filter dropdown and the
  Settings layout and confirm the font-object propagation the type section rests on.

## 12. Sources

Read by the research pass on 2026-09-21. Primary sources preferred; where the pass could see only a
search snippet it said so, and those are left out here.

The generic look and its cure: Anthropic, "Improving frontend design through Skills"
(https://claude.com/blog/improving-frontend-design-through-skills); James Anderson, "The Purple
Gradient Problem" (https://dev.to/james_anderson_h/the-purple-gradient-problem-why-ai-ui-all-looks-alike-and-how-to-fix-it-3j65);
925 Studios, "AI Slop Fonts and Gradients: The Tells" (https://www.925studios.co/blog/ai-slop-design-tells);
Paul Bakaus, impeccable.style slop catalogue (https://impeccable.style/slop/); Alan West, "Blame
Tailwind's indigo-500" (https://dev.to/alanwest/why-every-ai-built-website-looks-the-same-blame-tailwinds-indigo-500-3h2p);
SmoothUI, "AI Design Slop" (https://smoothui.dev/blog/ai-design-slop).

Tables and density: Matt Strom-Awn, "Design better data tables" (https://mattstromawn.com/writing/tables/)
and "UI Density" (https://mattstromawn.com/writing/ui-density/); GitHub Primer DataTable guidelines
(https://primer.style/product/components/data-table/guidelines/); Pencil and Paper, enterprise data
tables (https://www.pencilandpaper.io/articles/ux-pattern-analysis-enterprise-data-tables); Linear,
"How we redesigned the Linear UI" (https://linear.app/now/how-we-redesigned-the-linear-ui); a
summary of Refactoring UI (https://www.sglavoie.com/posts/book-summary-refactoring-ui/); TSM 4.10 UI
design (https://blog.tradeskillmaster.com/tsm-4-10-ui-design/); Fireart 2026 trends
(https://fireart.studio/blog/the-best-web-design-trends/); MyDesigner, "Dense Interfaces Are Back"
(https://mydesigner.gg/blog/dense-interfaces-information-hierarchy-2026).

The client: 8.1 UI template changes (https://us.forums.blizzard.com/en/wow/t/8-1-ui-templates-addon-changes/46266);
`SharedUIPanelTemplates.xml` (https://github.com/tekkub/wow-ui-source/blob/live/SharedXML/SharedUIPanelTemplates.xml);
Making scrollable frames (https://warcraft.wiki.gg/wiki/Making_scrollable_frames); Patch 11.0.0 API
changes (https://warcraft.wiki.gg/wiki/Patch_11.0.0/API_changes); the Blizzard menu implementation
guide (https://warcraft.wiki.gg/wiki/Blizzard_Menu_implementation_guide); Creating a settings menu
(https://warcraft.wiki.gg/wiki/Creating_a_settings_menu); Edit Mode (https://warcraft.wiki.gg/wiki/Edit_Mode);
Patch 12.0.0 API changes (https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes); UIOBJECT Font
(https://warcraft.wiki.gg/wiki/UIOBJECT_Font); Class colors (https://warcraft.wiki.gg/wiki/Class_colors);
Quality (https://warcraft.wiki.gg/wiki/Quality); alternatives to AceGUI
(https://us.forums.blizzard.com/en/wow/t/alternatives-to-ace-gui/582371); ElvUI's Ace3 skin
(https://git.tukui.org/elvui/elvui/-/blob/c3d1e58302d1b23bcf05fabeb88efe82f97b36b6/ElvUI/Modules/Skins/Addons/Ace3.lua);
Details-Framework (https://github.com/Tercioo/Details-Framework); Baganator
(https://www.curseforge.com/wow/addons/baganator); BetterBags (https://www.curseforge.com/wow/addons/better-bags).

Local precedents, read directly: Baganator `SingleViews/GuildView.xml` and `Skins/*.lua`;
Auctionator `Source/Components/ResultsListing/Templates/ResultsListing.xml`,
`Source/Components/ResultsListing/Mixins/ResultsListing.lua` and `Imports_ModernAH/TableBuilder.lua`;
EllesmereUIBlizzardSkin `EllesmereUIBlizzardSkin_SkinAPI.lua`; the In-Game Guild Pane artifact
(2026-09-20/21) and kat's WGA Raid Hub Look comps.
