local addonName, ns = ...

----------------------------------------------------------------------
-- Defaults
----------------------------------------------------------------------
local defaults = {
    threshold = 0.5,
    locked = true,
    position = {
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = -200,
    },
}

local db

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local BAR_WIDTH = 150
local BAR_HEIGHT = 16

----------------------------------------------------------------------
-- Curves (rebuilt when threshold changes)
----------------------------------------------------------------------
local colorCurve      -- ColorCurve: red → yellow → green based on health %
local alertCurve      -- Curve: outputs 1.0 below threshold, 0.0 at/above
local visibilityCurve -- Curve: outputs 1.0 below 100%, 0.0 at full health
local deathCurve      -- Curve: outputs 1.0 at ~0% health, 0.0 above

local function BuildCurves()
    -- Linear color gradient: red at 0%, yellow at 30%, green at 70%+
    colorCurve = C_CurveUtil.CreateColorCurve()
    colorCurve:SetType(Enum.LuaCurveType.Linear)
    colorCurve:AddPoint(0.0, CreateColor(1, 0, 0))   -- red
    colorCurve:AddPoint(0.3, CreateColor(1, 1, 0))   -- yellow
    colorCurve:AddPoint(0.7, CreateColor(0, 1, 0))   -- green

    -- Step threshold: visible below threshold, hidden at/above
    alertCurve = C_CurveUtil.CreateCurve()
    alertCurve:SetType(Enum.LuaCurveType.Step)
    alertCurve:AddPoint(0.0, 1.0)           -- below threshold → alpha 1
    alertCurve:AddPoint(db.threshold, 0.0)  -- at/above threshold → alpha 0

    -- Bar visibility: shown when damaged, hidden at full health
    visibilityCurve = C_CurveUtil.CreateCurve()
    visibilityCurve:SetType(Enum.LuaCurveType.Step)
    visibilityCurve:AddPoint(0.0, 1.0)  -- below 100% → alpha 1
    visibilityCurve:AddPoint(1.0, 0.0)  -- at 100% → alpha 0

    -- Death indicator: visible at 0% health, hidden above
    deathCurve = C_CurveUtil.CreateCurve()
    deathCurve:SetType(Enum.LuaCurveType.Step)
    deathCurve:AddPoint(0.0, 1.0)    -- at 0% → alpha 1 (dead)
    deathCurve:AddPoint(0.005, 0.0)  -- above ~0% → alpha 0 (alive)
end

----------------------------------------------------------------------
-- UI Elements
----------------------------------------------------------------------
local container    -- top-level parent, shown/hidden based on pet existence
local healthBar    -- StatusBar displaying pet health
local deathOverlay -- skull + text shown when pet is dead
local alertFrame   -- fullscreen red vignette, alpha-driven by alertCurve
local dragHandle   -- shown when unlocked for repositioning
local petLabel     -- "Pet" text centered on the bar

local function CreateUI()
    ----------------------------------------------------------------
    -- Container
    ----------------------------------------------------------------
    container = CreateFrame("Frame", "PetHealthAlertFrame", UIParent)
    container:SetSize(BAR_WIDTH, BAR_HEIGHT)
    container:SetClampedToScreen(true)
    container:SetMovable(true)
    container:RegisterForDrag("LeftButton")
    container:SetScript("OnDragStart", function(self)
        if not db.locked then
            self:StartMoving()
        end
    end)
    container:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        db.position = {
            point = point,
            relativePoint = relativePoint,
            x = x,
            y = y,
        }
    end)
    container:Hide()

    ----------------------------------------------------------------
    -- Health bar (StatusBar)
    ----------------------------------------------------------------
    healthBar = CreateFrame("StatusBar", nil, container)
    healthBar:SetAllPoints()
    healthBar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
    healthBar:SetMinMaxValues(0, 1)
    healthBar:SetValue(1)

    -- Dark background behind the bar
    local bg = healthBar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.7)

    -- Thin border around the bar
    local border = CreateFrame("Frame", nil, healthBar, "BackdropTemplate")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetBackdrop({
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 8,
    })
    border:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    -- Label
    petLabel = healthBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    petLabel:SetPoint("CENTER")
    petLabel:SetText("Pet")
    petLabel:SetTextColor(1, 1, 1)

    ----------------------------------------------------------------
    -- Death overlay (large skull over character when pet is dead)
    ----------------------------------------------------------------
    deathOverlay = CreateFrame("Frame", "PetHealthAlertDeath", UIParent)
    deathOverlay:SetSize(64, 64)
    deathOverlay:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    deathOverlay:SetFrameStrata("HIGH")
    deathOverlay:SetAlpha(0)

    -- Large skull icon
    local skull = deathOverlay:CreateTexture(nil, "ARTWORK")
    skull:SetAllPoints()
    skull:SetTexture("Interface/TargetingFrame/UI-TargetingFrame-Skull")
    skull:SetVertexColor(1, 0.3, 0.3)

    -- "PET DEAD" label below skull
    local deathLabel = deathOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    deathLabel:SetPoint("TOP", deathOverlay, "BOTTOM", 0, -4)
    deathLabel:SetText("PET DEAD")
    deathLabel:SetTextColor(1, 0.2, 0.2)

    -- Pulse animation
    local ag = skull:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.4)
    fade:SetToAlpha(1.0)
    fade:SetDuration(0.5)
    fade:SetSmoothing("IN_OUT")
    ag:Play()

    ----------------------------------------------------------------
    -- Fullscreen vignette alert (red screen glow when pet is low)
    ----------------------------------------------------------------
    alertFrame = CreateFrame("Frame", "PetHealthAlertVignette", UIParent)
    alertFrame:SetFrameStrata("BACKGROUND")
    alertFrame:SetFrameLevel(0)
    alertFrame:SetAllPoints(UIParent)
    alertFrame:SetAlpha(0)

    -- WoW's built-in low-health red vignette texture
    local vignette = alertFrame:CreateTexture(nil, "BACKGROUND")
    vignette:SetAllPoints()
    vignette:SetTexture("Interface/FULLSCREENTEXTURES/LowHealth")
    vignette:SetVertexColor(1, 0, 0)

    -- Pulse animation so the glow throbs when visible
    local ag = vignette:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.1)
    fade:SetToAlpha(0.3)
    fade:SetDuration(0.6)
    fade:SetSmoothing("IN_OUT")
    ag:Play()

    ----------------------------------------------------------------
    -- Drag handle (visible when unlocked)
    ----------------------------------------------------------------
    dragHandle = CreateFrame("Frame", nil, container)
    dragHandle:SetPoint("BOTTOMLEFT", container, "TOPLEFT", 0, 2)
    dragHandle:SetPoint("BOTTOMRIGHT", container, "TOPRIGHT", 0, 2)
    dragHandle:SetHeight(12)

    local handleBg = dragHandle:CreateTexture(nil, "BACKGROUND")
    handleBg:SetAllPoints()
    handleBg:SetColorTexture(0.2, 0.6, 1.0, 0.6)

    local handleText = dragHandle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    handleText:SetPoint("CENTER")
    handleText:SetText("Drag")
    handleText:SetTextColor(1, 1, 1)

    dragHandle:Hide()
end

----------------------------------------------------------------------
-- Spec helper
----------------------------------------------------------------------
local UNBREAKABLE_BOND_SPELL_ID = 1223323

local function IsPetHunter()
    local _, classFile = UnitClass("player")
    if classFile ~= "HUNTER" then return false end
    local spec = GetSpecialization()
    -- Beast Mastery always has a pet
    if spec == 1 then return true end
    -- Marksmanship with Unbreakable Bond talent has a pet
    if spec == 2 and IsPlayerSpell(UNBREAKABLE_BOND_SPELL_ID) then return true end
    return false
end

----------------------------------------------------------------------
-- Health update (safe with secret values)
----------------------------------------------------------------------
local function UpdateHealthBar()
    if not UnitExists("pet") then
        container:Hide()
        alertFrame:SetAlpha(0)
        -- Pet hunter with no pet in combat or targeting hostile → pet is dead
        local showDeath = IsPetHunter()
            and (UnitAffectingCombat("player")
              or (UnitExists("target") and UnitCanAttack("player", "target")))
        deathOverlay:SetAlpha(showDeath and 1 or 0)
        return
    end

    container:Show()

    -- Color: secret ColorMixin evaluated from health %
    local color = UnitHealthPercent("pet", true, colorCurve)
    healthBar:GetStatusBarTexture():SetVertexColor(color:GetRGB())

    -- Bar fill: secret number in [0, 1]
    local value = UnitHealthPercent("pet", true, CurveConstants.ZeroToOne)
    healthBar:SetValue(value)

    -- Hide the bar when pet is at full health
    local barAlpha = UnitHealthPercent("pet", true, visibilityCurve)
    healthBar:SetAlpha(barAlpha)

    -- Show skull overlay when pet is dead (0% health)
    local deathAlpha = UnitHealthPercent("pet", true, deathCurve)
    deathOverlay:SetAlpha(deathAlpha)

    -- Vignette visibility: secret alpha (1.0 below threshold, 0.0 above)
    local alertAlpha = UnitHealthPercent("pet", true, alertCurve)
    alertFrame:SetAlpha(alertAlpha)
end

----------------------------------------------------------------------
-- Position management
----------------------------------------------------------------------
local function RestorePosition()
    container:ClearAllPoints()
    local p = db.position
    container:SetPoint(p.point, UIParent, p.relativePoint, p.x, p.y)
end

local function SetLocked(locked)
    db.locked = locked
    container:EnableMouse(not locked)
    if locked then
        dragHandle:Hide()
    else
        dragHandle:Show()
    end
end

----------------------------------------------------------------------
-- Slash commands: /pha
----------------------------------------------------------------------
local function HandleSlashCommand(msg)
    local cmd, arg = msg:lower():match("^(%S+)%s*(.*)")
    cmd = cmd or msg:lower()

    if cmd == "unlock" then
        SetLocked(false)
        print("|cff00ccffPetHealthAlert:|r Unlocked. Drag to reposition.")
    elseif cmd == "lock" then
        SetLocked(true)
        print("|cff00ccffPetHealthAlert:|r Locked.")
    elseif cmd == "toggle" then
        SetLocked(not db.locked)
        print("|cff00ccffPetHealthAlert:|r " .. (db.locked and "Locked." or "Unlocked."))
    elseif cmd == "threshold" then
        local pct = tonumber(arg)
        if pct and pct > 0 and pct < 100 then
            db.threshold = pct / 100
            BuildCurves()
            UpdateHealthBar()
            print("|cff00ccffPetHealthAlert:|r Alert threshold set to " .. pct .. "%.")
        else
            print("|cff00ccffPetHealthAlert:|r Usage: /pha threshold 50  (value between 1-99)")
        end
    elseif cmd == "reset" then
        db.position = CopyTable(defaults.position)
        RestorePosition()
        print("|cff00ccffPetHealthAlert:|r Position reset to default.")
    else
        print("|cff00ccffPetHealthAlert|r commands:")
        print("  /pha lock        - Lock frame position")
        print("  /pha unlock      - Unlock frame for dragging")
        print("  /pha toggle      - Toggle lock state")
        print("  /pha threshold # - Set alert threshold (1-99, default 50)")
        print("  /pha reset       - Reset position to default")
    end
end

----------------------------------------------------------------------
-- Event handler
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded ~= addonName then return end

        -- Initialise saved variables
        if not PetHealthAlertDB then
            PetHealthAlertDB = CopyTable(defaults)
        end
        db = PetHealthAlertDB

        -- Backfill any keys added in newer versions
        for k, v in pairs(defaults) do
            if db[k] == nil then
                db[k] = type(v) == "table" and CopyTable(v) or v
            end
        end

        BuildCurves()
        CreateUI()
        RestorePosition()
        SetLocked(db.locked)

        -- Register slash commands
        SLASH_PETHEALTHALERT1 = "/pha"
        SLASH_PETHEALTHALERT2 = "/pethealthalert"
        SlashCmdList["PETHEALTHALERT"] = HandleSlashCommand

        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN"
        or event == "PLAYER_ENTERING_WORLD"
        or event == "UNIT_PET"
        or event == "PLAYER_REGEN_DISABLED"
        or event == "PLAYER_REGEN_ENABLED"
        or event == "PLAYER_TARGET_CHANGED"
        or event == "PLAYER_SPECIALIZATION_CHANGED"
        or event == "TRAIT_CONFIG_UPDATED" then
        UpdateHealthBar()

    elseif event == "UNIT_HEALTH" then
        UpdateHealthBar()
    end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_PET")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterUnitEvent("UNIT_HEALTH", "pet")
eventFrame:SetScript("OnEvent", OnEvent)
