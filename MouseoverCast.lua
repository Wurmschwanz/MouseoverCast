-- MouseoverCast v1.0.0
-- Vanilla WoW 1.12 / OctoWoW
-- Requires SuperWoW + ClassicAPI for macro-free actionbar mouseover casting.

local ADDON_NAME = "MouseoverCast"
local VERSION = "1.0.0"

local OriginalUseAction = UseAction
local OriginalCastSpell = CastSpell
local OriginalCastSpellByName = CastSpellByName

local frame = CreateFrame("Frame", "MouseoverCastEventFrame")

local DEFAULTS = {
    enabled = 1,
    offensive = 0,
    allowPets = 1,
    allHelpful = 0,
    quiet = 0,
}

local knownHealingNames = {}

-- One representative spell ID per friendly spell family. GetSpellInfo() from
-- ClassicAPI returns the localized name, so this works on non-English clients.
-- This list intentionally includes heals plus targeted defensive/protection
-- abilities, while leaving ordinary long-duration buffs untouched.
local healingFamilySpellIDs = {
    -- Priest
    2050,   -- Lesser Heal
    2054,   -- Heal
    2060,   -- Greater Heal
    2061,   -- Flash Heal
    139,    -- Renew
    17,     -- Power Word: Shield

    -- Druid
    5185,   -- Healing Touch
    8936,   -- Regrowth
    774,    -- Rejuvenation
    18562,  -- Swiftmend

    -- Paladin
    635,    -- Holy Light
    19750,  -- Flash of Light
    633,    -- Lay on Hands
    20473,  -- Holy Shock
    1022,   -- Blessing of Protection
    1044,   -- Blessing of Freedom
    6940,   -- Blessing of Sacrifice

    -- Shaman
    331,    -- Healing Wave
    8004,   -- Lesser Healing Wave
    1064,   -- Chain Heal
    974,    -- Earth Shield (Vanilla+ servers, if available)
}

-- Extra names for common Vanilla+ healing spells. These are only fallbacks;
-- the normal Vanilla heals above are localized automatically from spell IDs.
local extraHealingNames = {
    ["Lifebloom"] = 1,
    ["Nourish"] = 1,
    ["Circle of Healing"] = 1,
    ["Blühendes Leben"] = 1,
    ["Pflege"] = 1,
    ["Kreis der Heilung"] = 1,
}

local function Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff4fd1ffMouseoverCast:|r " .. msg)
    end
end

local function ApplyDefaults()
    if type(MouseoverCastDB) ~= "table" then
        MouseoverCastDB = {}
    end

    for key, value in pairs(DEFAULTS) do
        if MouseoverCastDB[key] == nil then
            MouseoverCastDB[key] = value
        end
    end
end

local function HasClassicAPI()
    return type(GetActionInfo) == "function"
        and type(GetSpellInfo) == "function"
        and type(IsHelpfulSpell) == "function"
        and type(IsHarmfulSpell) == "function"
end

local function HasSuperWoW()
    if SUPERWOW_VERSION then
        return true
    end

    -- SuperWoW's extended CastSpellByName accepts a second unit argument.
    -- There is no safe stock-1.12 feature probe for the extra C argument,
    -- so SUPERWOW_VERSION remains the primary detection path.
    return false
end

local function BuildHealingNameCache()
    knownHealingNames = {}

    if type(GetSpellInfo) == "function" then
        for _, spellID in ipairs(healingFamilySpellIDs) do
            local name = GetSpellInfo(spellID)
            if name then
                knownHealingNames[name] = 1
            end
        end
    end

    for name, value in pairs(extraHealingNames) do
        knownHealingNames[name] = value
    end
end

local function UnitIsValidFriendly(unit)
    if not unit or not UnitExists(unit) then
        return false
    end

    if not UnitCanAssist("player", unit) then
        return false
    end

    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then
        return false
    elseif UnitIsDead and UnitIsDead(unit) then
        return false
    end

    if MouseoverCastDB and MouseoverCastDB.allowPets ~= 1 then
        if UnitPlayerControlled and UnitPlayerControlled(unit) and not UnitIsPlayer(unit) then
            return false
        end
    end

    return true
end

local function UnitIsValidEnemy(unit)
    if not unit or not UnitExists(unit) then
        return false
    end

    if not UnitCanAttack("player", unit) then
        return false
    end

    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then
        return false
    elseif UnitIsDead and UnitIsDead(unit) then
        return false
    end

    return true
end

local function ResolveFrameUnit(f)
    local depth = 0

    while f and depth < 6 do
        if f.unit and type(f.unit) == "string" and UnitExists(f.unit) then
            return f.unit
        end

        if f.label and f.id then
            local candidate = tostring(f.label) .. tostring(f.id)
            if UnitExists(candidate) then
                return candidate
            end
        end

        local name = nil
        if f.GetName then
            name = f:GetName()
        end

        if name then
            -- Lua 5.0 compatibility: use string.find captures instead of string.match.
            local _, _, n = string.find(name, "^PartyMemberFrame(%d+)PetFrame")
            if n and UnitExists("partypet" .. n) then
                return "partypet" .. n
            end

            _, _, n = string.find(name, "^PartyMemberFrame(%d+)")
            if n and UnitExists("party" .. n) then
                return "party" .. n
            end

            _, _, n = string.find(name, "^RaidMemberFrame(%d+)")
            if n and UnitExists("raid" .. n) then
                return "raid" .. n
            end

            if string.find(name, "PlayerFrame", 1, true) and UnitExists("player") then
                return "player"
            end

            if string.find(name, "PetFrame", 1, true) and UnitExists("pet") then
                return "pet"
            end

            if string.find(name, "TargetFrame", 1, true) and UnitExists("target") then
                return "target"
            end
        end

        if f.GetParent then
            f = f:GetParent()
        else
            f = nil
        end

        depth = depth + 1
    end

    return nil
end

local function ResolveMouseoverUnit()
    -- SuperWoW exposes true 3D/nameplate mouseover as a normal unit token.
    if UnitExists("mouseover") then
        return "mouseover"
    end

    -- Unit-frame fallback for frames that expose .unit, .label/.id, or use
    -- standard Blizzard frame names.
    if GetMouseFocus then
        local focus = GetMouseFocus()
        local unit = ResolveFrameUnit(focus)
        if unit then
            return unit
        end
    end

    return nil
end

local function IsHealingSpell(spellID, spellName)
    if not spellID or not spellName then
        return false
    end

    if MouseoverCastDB and MouseoverCastDB.allHelpful == 1 then
        return IsHelpfulSpell(spellID) and true or false
    end

    return knownHealingNames[spellName] == 1
end

local function BuildCastName(name, rank)
    if not name then
        return nil
    end

    if rank and rank ~= "" then
        return name .. "(" .. rank .. ")"
    end

    return name
end

local function TryMouseoverCastBySpellID(spellID)
    if not MouseoverCastDB then
        return false
    end

    if MouseoverCastDB.enabled ~= 1 and MouseoverCastDB.offensive ~= 1 then
        return false
    end

    if not HasClassicAPI() or not HasSuperWoW() then
        return false
    end

    local name, rank = GetSpellInfo(spellID)
    if not name then
        return false
    end

    local unit = ResolveMouseoverUnit()
    if not unit then
        return false
    end

    local shouldCast = false

    -- Friendly mouseover healing/protection. Only approved heal and defensive
    -- spell families are redirected, so ordinary buffs keep normal behavior.
    if MouseoverCastDB.enabled == 1 and IsHealingSpell(spellID, name) and UnitIsValidFriendly(unit) then
        shouldCast = true
    end

    -- Offensive mouseover casting. ClassicAPI classifies harmful spells from
    -- Spell.dbc, so this covers damage spells, DoTs and hostile CC without a
    -- hard-coded class/spell list. Auto attack, items and macros never reach
    -- this path because GetActionInfo() only forwards spell actions.
    if not shouldCast and MouseoverCastDB.offensive == 1 and IsHarmfulSpell(spellID) and UnitIsValidEnemy(unit) then
        shouldCast = true
    end

    if not shouldCast then
        return false
    end

    local castName = BuildCastName(name, rank)
    if not castName then
        return false
    end

    -- SuperWoW extension: CastSpellByName(spell, unit)
    OriginalCastSpellByName(castName, unit)
    return true
end

-- Global action-bar hook. This is what allows normal spell buttons to behave
-- like mouseover heals without converting them into macros.
function UseAction(slot, checkCursor, onSelf)
    -- In Lua, numeric 0 is truthy. Treat only an explicit 1/true as self-cast.
    local explicitSelfCast = (onSelf == 1 or onSelf == true)
    if MouseoverCastDB and (MouseoverCastDB.enabled == 1 or MouseoverCastDB.offensive == 1) and not explicitSelfCast and HasClassicAPI() then
        local actionType, actionID = GetActionInfo(slot)
        if actionType == "spell" and actionID then
            if TryMouseoverCastBySpellID(actionID) then
                return
            end
        end
    end

    return OriginalUseAction(slot, checkCursor, onSelf)
end

-- Also support clicking a healing spell directly in the spellbook.
function CastSpell(spellBookSlot, bookType)
    if MouseoverCastDB and (MouseoverCastDB.enabled == 1 or MouseoverCastDB.offensive == 1) and HasClassicAPI() then
        local _, _, _, _, _, _, _, _, _, spellID = GetSpellInfo(spellBookSlot, bookType)
        if spellID and TryMouseoverCastBySpellID(spellID) then
            return
        end
    end

    return OriginalCastSpell(spellBookSlot, bookType)
end

local optionsPanel = nil
local optionsHealing = nil
local optionsOffensive = nil
local optionsNavButton = nil
local optionsNavLabel = nil
local nativeContentScroll = nil
local optionsHooked = nil
local optionProbeElapsed = 0
local hookedNavButtons = {}

local function RefreshNativeControlsOption()
    if not MouseoverCastDB then
        return
    end

    if optionsHealing then
        if MouseoverCastDB.enabled == 1 then
            optionsHealing:SetChecked(1)
        else
            optionsHealing:SetChecked(nil)
        end
    end

    if optionsOffensive then
        if MouseoverCastDB.offensive == 1 then
            optionsOffensive:SetChecked(1)
        else
            optionsOffensive:SetChecked(nil)
        end
    end
end

local function GetFrameTextSafe(f)
    if not f then
        return nil
    end

    if f.GetText then
        local text = f:GetText()
        if text and text ~= "" then
            return text
        end
    end

    if f.GetRegions then
        local regions = { f:GetRegions() }
        for _, region in ipairs(regions) do
            if region and region.GetText then
                local text = region:GetText()
                if text and text ~= "" then
                    return text
                end
            end
        end
    end

    return nil
end

local function GetTextRegionSafe(f)
    if not f or not f.GetRegions then
        return nil
    end

    local regions = { f:GetRegions() }
    for _, region in ipairs(regions) do
        if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText then
            local text = region:GetText()
            if text and text ~= "" then
                return region
            end
        end
    end

    return nil
end

local function WalkChildren(root, callback, depth)
    if not root or not root.GetChildren then
        return
    end

    depth = depth or 0
    if depth > 8 then
        return
    end

    local children = { root:GetChildren() }
    for _, child in ipairs(children) do
        callback(child)
        WalkChildren(child, callback, depth + 1)
    end
end

local function FrameReallyVisible(f)
    if not f then
        return false
    end
    if f.IsVisible then
        return f:IsVisible()
    end
    if f.IsShown then
        return f:IsShown()
    end
    return true
end

local function FindLargestVisibleScrollFrame(root)
    local best = nil
    local bestArea = 0

    WalkChildren(root, function(child)
        if child and child.GetObjectType and child:GetObjectType() == "ScrollFrame" and FrameReallyVisible(child) then
            local w = child.GetWidth and child:GetWidth() or 0
            local h = child.GetHeight and child:GetHeight() or 0
            local area = w * h
            if w >= 220 and h >= 180 and area > bestArea then
                best = child
                bestArea = area
            end
        end
    end)

    return best
end

local function FindButtonByText(root, wanted1, wanted2)
    local found = nil
    WalkChildren(root, function(child)
        if found or not child or not child.GetObjectType or child:GetObjectType() ~= "Button" then
            return
        end

        local text = GetFrameTextSafe(child)
        if text == wanted1 or (wanted2 and text == wanted2) then
            found = child
        end
    end)
    return found
end

local function CreateStandaloneOptionsPanel(root, anchorScroll)
    if optionsPanel then
        if anchorScroll then
            optionsPanel:ClearAllPoints()
            optionsPanel:SetPoint("TOPLEFT", anchorScroll, "TOPLEFT", 0, 0)
            optionsPanel:SetPoint("BOTTOMRIGHT", anchorScroll, "BOTTOMRIGHT", 0, 0)
        end
        return optionsPanel
    end

    local panel = CreateFrame("Frame", "MouseoverCastOptionsPanel", root)
    panel:SetFrameLevel((anchorScroll and anchorScroll.GetFrameLevel and anchorScroll:GetFrameLevel() or root:GetFrameLevel()) + 2)
    if anchorScroll then
        panel:SetPoint("TOPLEFT", anchorScroll, "TOPLEFT", 0, 0)
        panel:SetPoint("BOTTOMRIGHT", anchorScroll, "BOTTOMRIGHT", 0, 0)
    else
        panel:SetPoint("TOPLEFT", root, "TOPLEFT", 210, -42)
        panel:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -28, 48)
    end

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, -22)
    title:SetText("MouseoverCast")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    subtitle:SetWidth(330)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Macro-free mouseover casting. Normal target casting is used whenever no valid mouseover target exists.")

    local heal = CreateFrame("CheckButton", "MouseoverCastOptionsHealing", panel, "UICheckButtonTemplate")
    heal:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -4, -24)
    local healText = getglobal("MouseoverCastOptionsHealingText")
    if healText then
        healText:SetText("Mouseover Healing")
        healText:SetTextColor(1, 0.82, 0)
    end
    heal:SetScript("OnClick", function()
        if this:GetChecked() then
            MouseoverCastDB.enabled = 1
        else
            MouseoverCastDB.enabled = 0
        end
    end)
    heal:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Mouseover Healing", 1, 1, 1)
        GameTooltip:AddLine("Healing and supported protection spells cast on the friendly unit under your mouse cursor. With no valid friendly mouseover, normal casting is used.", 0.8, 0.8, 0.8, 1)
        GameTooltip:Show()
    end)
    heal:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local offensive = CreateFrame("CheckButton", "MouseoverCastOptionsOffensive", panel, "UICheckButtonTemplate")
    offensive:SetPoint("TOPLEFT", heal, "BOTTOMLEFT", 0, -8)
    local offensiveText = getglobal("MouseoverCastOptionsOffensiveText")
    if offensiveText then
        offensiveText:SetText("Mouseover Offensive Spells")
        offensiveText:SetTextColor(1, 0.82, 0)
    end
    offensive:SetScript("OnClick", function()
        if this:GetChecked() then
            MouseoverCastDB.offensive = 1
        else
            MouseoverCastDB.offensive = 0
        end
    end)
    offensive:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Mouseover Offensive Spells", 1, 1, 1)
        GameTooltip:AddLine("Harmful spells cast on the hostile unit under your mouse cursor while your current target stays selected. With no valid hostile mouseover, normal casting is used.", 0.8, 0.8, 0.8, 1)
        GameTooltip:Show()
    end)
    offensive:SetScript("OnLeave", function() GameTooltip:Hide() end)

    optionsPanel = panel
    optionsHealing = heal
    optionsOffensive = offensive
    panel:Hide()
    RefreshNativeControlsOption()
    return panel
end

local function UnlockOtherNavButtons(parent)
    if not parent or not parent.GetChildren then
        return
    end

    local children = { parent:GetChildren() }
    for _, child in ipairs(children) do
        if child ~= optionsNavButton and child.UnlockHighlight then
            child:UnlockHighlight()
        end
    end
end

local function HideStandalonePanel()
    if optionsPanel then
        optionsPanel:Hide()
    end
    if optionsNavButton and optionsNavButton.UnlockHighlight then
        optionsNavButton:UnlockHighlight()
    end
    if nativeContentScroll then
        nativeContentScroll:Show()
    end
end

local function ShowStandalonePanel()
    local root = getglobal("OptionsFrame")
    if not root then
        return
    end

    -- Remember the native right-hand content area while it is visible, then
    -- replace only that area. The left navigation, search bar and OK/Cancel
    -- buttons remain untouched.
    local liveScroll = FindLargestVisibleScrollFrame(root)
    if liveScroll and liveScroll ~= optionsPanel then
        nativeContentScroll = liveScroll
    end

    if not nativeContentScroll then
        return
    end

    CreateStandaloneOptionsPanel(root, nativeContentScroll)
    optionsPanel:ClearAllPoints()
    optionsPanel:SetPoint("TOPLEFT", nativeContentScroll, "TOPLEFT", 0, 0)
    optionsPanel:SetPoint("BOTTOMRIGHT", nativeContentScroll, "BOTTOMRIGHT", 0, 0)

    nativeContentScroll:Hide()
    optionsPanel:Show()
    RefreshNativeControlsOption()

    if optionsNavButton then
        UnlockOtherNavButtons(optionsNavButton:GetParent())
        if optionsNavButton.LockHighlight then
            optionsNavButton:LockHighlight()
        end
    end
end

local function HookNativeNavigationButtons(navParent)
    if not navParent or not navParent.GetChildren then
        return
    end

    local children = { navParent:GetChildren() }
    for _, child in ipairs(children) do
        if child ~= optionsNavButton and child.GetObjectType and child:GetObjectType() == "Button" and GetFrameTextSafe(child) then
            if not hookedNavButtons[child] then
                local old = child:GetScript("OnClick")
                hookedNavButtons[child] = 1
                child:SetScript("OnClick", function()
                    HideStandalonePanel()
                    if old then
                        old()
                    end
                    -- Octo may swap/rebuild the right-hand ScrollFrame after
                    -- the click. Forget the old pointer so the next MouseoverCast
                    -- click discovers the live one again.
                    nativeContentScroll = FindLargestVisibleScrollFrame(getglobal("OptionsFrame")) or nativeContentScroll
                end)
            end
        end
    end
end

local function CreateStandaloneNavButton(root)
    if optionsNavButton then
        return true
    end

    local helpButton = FindButtonByText(root, "Help", "Hilfe")
    if not helpButton then
        return false
    end

    local navParent = helpButton:GetParent()
    if not navParent then
        return false
    end

    local button = CreateFrame("Button", "MouseoverCastOptionsNavButton", navParent)
    button:SetWidth(helpButton:GetWidth() or 150)
    button:SetHeight(helpButton:GetHeight() or 20)

    -- Match Octo's native vertical row spacing exactly. Anchoring directly to
    -- Help's bottom made the custom row a few pixels too tight. Instead, find
    -- the nearest native navigation button above Help and reuse the actual
    -- top-to-top distance between those two native rows. This automatically
    -- follows UI scale and any font/layout changes.
    local nativeRowStep = nil
    if navParent.GetChildren and helpButton.GetTop then
        local helpTop = helpButton:GetTop()
        local helpLeft = helpButton.GetLeft and helpButton:GetLeft() or nil
        local bestAboveTop = nil
        local siblings = { navParent:GetChildren() }
        for _, sibling in ipairs(siblings) do
            if sibling ~= helpButton and sibling ~= button and sibling.GetObjectType and sibling:GetObjectType() == "Button" and GetFrameTextSafe(sibling) and sibling.GetTop then
                local siblingTop = sibling:GetTop()
                local siblingLeft = sibling.GetLeft and sibling:GetLeft() or nil
                if helpTop and siblingTop and siblingTop > helpTop then
                    -- Stay in the same navigation column.
                    if not helpLeft or not siblingLeft or math.abs(siblingLeft - helpLeft) < 8 then
                        if not bestAboveTop or siblingTop < bestAboveTop then
                            bestAboveTop = siblingTop
                        end
                    end
                end
            end
        end
        if helpTop and bestAboveTop then
            nativeRowStep = bestAboveTop - helpTop
        end
    end

    if nativeRowStep and nativeRowStep > 0 and nativeRowStep < 40 then
        button:SetPoint("TOPLEFT", helpButton, "TOPLEFT", 0, -nativeRowStep)
    else
        -- Safe fallback for unusual skins: native rows are normally ~20 px apart.
        local fallbackStep = (helpButton:GetHeight() or 16) + 3
        button:SetPoint("TOPLEFT", helpButton, "TOPLEFT", 0, -fallbackStep)
    end

    -- Clone the visual style of Octo's native Help navigation row instead
    -- of approximating it. This keeps MouseoverCast indistinguishable from
    -- the surrounding Interface menu entries across UI scales/font packs.
    local helpHighlight = helpButton.GetHighlightTexture and helpButton:GetHighlightTexture() or nil
    local helpHighlightPath = helpHighlight and helpHighlight.GetTexture and helpHighlight:GetTexture() or nil
    if helpHighlightPath then
        button:SetHighlightTexture(helpHighlightPath)
    else
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    end

    local highlight = button:GetHighlightTexture()
    if highlight then
        if helpHighlight and helpHighlight.GetAlpha then
            highlight:SetAlpha(helpHighlight:GetAlpha() or 1)
        else
            highlight:SetAlpha(1)
        end
        if helpHighlight and helpHighlight.GetTexCoord then
            local ulx, uly, llx, lly, urx, ury, lrx, lry = helpHighlight:GetTexCoord()
            if ulx then
                highlight:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
            end
        end
        if helpHighlight and helpHighlight.GetBlendMode and highlight.SetBlendMode then
            local mode = helpHighlight:GetBlendMode()
            if mode then highlight:SetBlendMode(mode) end
        end
    end

    local helpLabel = GetTextRegionSafe(helpButton)
    local label = button:CreateFontString(nil, "ARTWORK")

    -- Copy the exact native font, size, flags, color and shadow from Help.
    if helpLabel then
        if helpLabel.GetFont then
            local font, size, flags = helpLabel:GetFont()
            if font and size then
                label:SetFont(font, size, flags)
            end
        end
        if helpLabel.GetTextColor then
            local r, g, b, a = helpLabel:GetTextColor()
            if r then label:SetTextColor(r, g, b, a or 1) end
        end
        if helpLabel.GetShadowColor and label.SetShadowColor then
            local r, g, b, a = helpLabel:GetShadowColor()
            if r then label:SetShadowColor(r, g, b, a or 1) end
        end
        if helpLabel.GetShadowOffset and label.SetShadowOffset then
            local x, y = helpLabel:GetShadowOffset()
            if x and y then label:SetShadowOffset(x, y) end
        end

        -- Reuse Help's internal anchor offsets, but anchor them to our row.
        if helpLabel.GetPoint then
            local point, relativeTo, relativePoint, x, y = helpLabel:GetPoint(1)
            if point then
                label:SetPoint(point, button, relativePoint or point, x or 0, y or 0)
            end
        end
    end

    if not label:GetPoint(1) then
        label:SetPoint("LEFT", button, "LEFT", 14, 0)
    end
    label:SetText("MouseoverCast")

    button:SetScript("OnClick", function()
        ShowStandalonePanel()
    end)

    optionsNavButton = button
    optionsNavLabel = label
    HookNativeNavigationButtons(navParent)
    button:Show()
    return true
end

local function HookOptionsFrameLifecycle(root)
    if optionsHooked or not root then
        return
    end

    local oldShow = root:GetScript("OnShow")
    root:SetScript("OnShow", function()
        if oldShow then oldShow() end
        -- Always reopen on Octo's native page. MouseoverCast remains one click
        -- away in the left navigation and never leaves the native content hidden.
        if optionsPanel then optionsPanel:Hide() end
        if optionsNavButton and optionsNavButton.UnlockHighlight then optionsNavButton:UnlockHighlight() end
        nativeContentScroll = FindLargestVisibleScrollFrame(root) or nativeContentScroll
        if nativeContentScroll then nativeContentScroll:Show() end
        CreateStandaloneNavButton(root)
    end)

    local oldHide = root:GetScript("OnHide")
    root:SetScript("OnHide", function()
        HideStandalonePanel()
        if oldHide then oldHide() end
    end)

    optionsHooked = 1
end

local function ProbeNativeOptions()
    local root = getglobal("OptionsFrame")
    if not root then
        return false
    end

    HookOptionsFrameLifecycle(root)
    local ok = CreateStandaloneNavButton(root)

    if root:IsShown() and not optionsPanel then
        nativeContentScroll = FindLargestVisibleScrollFrame(root) or nativeContentScroll
        if nativeContentScroll then
            CreateStandaloneOptionsPanel(root, nativeContentScroll)
        end
    end

    return ok
end

SLASH_MOUSEOVERCAST1 = "/moc"
SLASH_MOUSEOVERCAST2 = "/mouseovercast"
SLASH_MOUSEOVERCAST3 = "/moh"
SLASH_MOUSEOVERCAST4 = "/mouseoverheal"
SlashCmdList["MOUSEOVERCAST"] = function(msg)
    local command = string.lower(msg or "")
    -- Vanilla/1.12 clients can pass leading/trailing whitespace to slash handlers.
    command = string.gsub(command, "^%s+", "")
    command = string.gsub(command, "%s+$", "")

    if command == "on" then
        MouseoverCastDB.enabled = 1
        RefreshNativeControlsOption()
        Print("enabled.")
        return
    elseif command == "off" then
        MouseoverCastDB.enabled = 0
        RefreshNativeControlsOption()
        Print("disabled.")
        return
    elseif command == "offensive on" or command == "offense on" then
        MouseoverCastDB.offensive = 1
        RefreshNativeControlsOption()
        Print("offensive mouseover casting enabled.")
        return
    elseif command == "offensive off" or command == "offense off" then
        MouseoverCastDB.offensive = 0
        RefreshNativeControlsOption()
        Print("offensive mouseover casting disabled.")
        return
    elseif command == "status" or command == "" then
        local state = MouseoverCastDB.enabled == 1 and "enabled" or "disabled"
        local offensiveState = MouseoverCastDB.offensive == 1 and "enabled" or "disabled"
        local navState = optionsNavButton and "yes" or "not attached yet"
        Print("healing=" .. state .. ", offensive=" .. offensiveState .. ". Interface nav=" .. navState .. ". SuperWoW=" .. (HasSuperWoW() and "yes" or "no") .. ", ClassicAPI=" .. (HasClassicAPI() and "yes" or "no"))
        return
    elseif command == "ui" then
        local root = getglobal("OptionsFrame")
        Print("UI scan: OptionsFrame=" .. (root and "yes" or "no")
            .. ", NavButton=" .. (optionsNavButton and "yes" or "no")
            .. ", RightContent=" .. (nativeContentScroll and "yes" or "no"))
        ProbeNativeOptions()
        return
    end

    Print("Commands: /moc on, /moc off, /moc offensive on, /moc offensive off, /moc status, /moc ui")
end

frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        ApplyDefaults()
        BuildHealingNameCache()
        ProbeNativeOptions()

        if not HasClassicAPI() then
            Print("ClassicAPI was not detected. Mouseover casting will stay inactive until ClassicAPI is loaded.")
        elseif not HasSuperWoW() then
            Print("SuperWoW was not detected. Mouseover casting will stay inactive until SuperWoW is loaded.")
        elseif MouseoverCastDB.quiet ~= 1 then
            Print("v" .. VERSION .. " loaded. Settings: Interface > MouseoverCast.")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        BuildHealingNameCache()
        ProbeNativeOptions()
    elseif event == "ADDON_LOADED" then
        -- The OctoWoW Options UI may be load-on-demand. Retry after every
        -- addon load; this becomes a no-op as soon as the checkbox exists.
        ProbeNativeOptions()
    end
end)

-- Some OctoWoW builds instantiate OptionsFrame lazily. Probe lightly until
-- the left-side MouseoverCast entry exists; no work is done afterwards.
frame:SetScript("OnUpdate", function()
    if optionsNavButton then
        return
    end
    optionProbeElapsed = optionProbeElapsed + (arg1 or 0)
    if optionProbeElapsed >= 0.20 then
        optionProbeElapsed = 0
        ProbeNativeOptions()
    end
end)
