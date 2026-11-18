--[[
    S+M — APEX CIRCLE AIMBOT
    Blox Fruits PvP | Circular FOV Precision | Clean Menu
    https://github.com/M4Th777/SM-AIMxPvP

    loadstring(game:HttpGet("https://raw.githubusercontent.com/M4Th777/SM-AIMxPvP/main/main.lua"))()

    v8 — CIRCLE FOV ENGINE
    - Circular FOV preciso (matemática exata: WorldToScreen + distância radial)
    - Só mira/trava alvos DENTRO do círculo
    - Círculo 100% editável: raio, cor, espessura, segments, fill, pulso
    - Menu limpo: apenas "S + M" no canto superior esquerdo (arrastável)
    - Input puro (VIM) + auto-cast com cooldown real
    - Facção Pirate/Marine + Bounty + HP real
    - Soru guiado + unload seguro (Delete)
    - Offsets Roblox version-2c6fd5e09aaf4cfa aplicados na lógica de câmera/character
]]

local SCRIPT_NAME = "S + M"

-- ════════════════════════════════════════════════════════════════
-- OFFSETS (version-2c6fd5e09aaf4cfa) — referência para cálculos precisos
-- Camera.FieldOfView: 296 | Camera.ViewportSize: 708 | Camera.Position: 228
-- Humanoid.Health: 388 | Humanoid.MaxHealth: 416 | Humanoid.HumanoidRootPart: 1120
-- Humanoid.MoveDirection: 308 | Humanoid.Walkspeed: 456
-- Player.Team: 736 | Player.DisplayName: 288 | Player.UserId: 184
-- Workspace.CurrentCamera: 1184 | Workspace.World: 1016
-- Primitive.AssemblyLinearVelocity: 224 | Primitive.Position: 212
-- ════════════════════════════════════════════════════════════════

-- ══════════════ CONFIG ══════════════
local CONFIG = {
    Keys = {
        AimToggle   = Enum.KeyCode.RightShift,   -- Liga/Desliga aimbot
        AutoToggle  = Enum.KeyCode.RightAlt,     -- Auto-cast ON/OFF
        MenuToggle  = Enum.KeyCode.RightControl, -- Menu
        Unload      = Enum.KeyCode.Delete,       -- Unload seguro
        CycleTarget = Enum.KeyCode.G,            -- Ciclar alvo
        Soru        = Enum.KeyCode.R,            -- Soru guiado
        Skills      = { Enum.KeyCode.Z, Enum.KeyCode.X, Enum.KeyCode.C, Enum.KeyCode.V, Enum.KeyCode.F },
    },

    -- ─── CÍRCULO FOV (CORE DO ÁPICE) ───
    Circle = {
        Enabled       = true,
        Radius        = 180,        -- pixels (raio do círculo na tela)
        Color         = Color3.fromRGB(0, 255, 180), -- Verde-neon
        Thickness     = 2,
        Transparency  = 0.15,
        FillEnabled   = false,
        FillTransparency = 0.92,
        FillColor     = Color3.fromRGB(0, 255, 180),
        PulseEnabled  = true,       -- Pulso sutil quando alvo travado
        PulseSpeed    = 2.5,        -- Hz
        Segments      = 128,        -- Suavidade (64-256)
        DynamicRadius = false,      -- Se true, escala com FOV da câmera
        ShowCrosshair = true,       -- Mira central minimalista
        CrosshairSize = 6,
        CrosshairGap  = 4,
    },

    -- ─── ALVO / TARGETING ───
    Target = {
        MaxDistance     = 600,      -- studs
        TeamCheck       = true,
        FriendCheck     = true,
        FactionCheck    = true,     -- Pirate vs Marine
        OnlyPvP         = true,
        HitPart         = "Head",   -- "Head" | "HumanoidRootPart" | "Closest"
        Priority        = "Health", -- "Health" | "Distance" | "Threat" (HP% + Dist + Bounty)
        WallCheck       = false,    -- Raycast antes de travar (pode dar false positive)
        Prediction      = true,
        PredictX        = 1.05,     -- Multiplicador lead (ping * vel)
        MaxLead         = 8.0,      -- Teto studs
    },

    -- ─── AIMBOT (CÂMERA) ───
    Aim = {
        Enabled     = true,
        Smooth      = 0.0,          -- 0 = snap instantâneo | >0 = lerp
        SmoothMethod = "Exponential", -- "Linear" | "Exponential"
        Easing      = 0.12,         -- Para Exponential (0.05-0.25)
        HoldToAim   = true,         -- Só mira enquanto segura skill / Auto ligado
    },

    -- ─── AUTO-CAST (INPUT PURO VIM) ───
    Auto = {
        Enabled        = false,
        HoldTime       = 0.045,     -- Duração keydown
        GapTime        = 0.11,      -- Intervalo entre casts
        MaxAngle       = 4.5,       -- Graus máx para castar (precisão extrema)
        AlignFrames    = 1,
        CooldownFallback = 3.5,
        WallCheck      = false,
        SmartOrder     = true,      -- Prioriza skills por range/cooldown real
    },

    -- ─── SORU (DASH GUIADO) ───
    Soru = {
        Enabled     = true,
        MaxDistance = 45,
        Behind      = 2.8,
        UpOffset    = 0,
        Steps       = 4,
        Lerp        = 0.38,
        Cooldown    = 0.55,
    },

    -- ─── MARCADOR VISUAL ───
    Marker = {
        Enabled      = true,
        Color        = Color3.fromRGB(255, 50, 80),
        ShowHP       = true,
        ShowDistance = true,
        ShowBounty   = true,
        ShowFaction  = true,
    },

    -- ─── UI / MENU ───
    UI = {
        Position       = "TopLeft",   -- "TopLeft" | "TopRight" | "BottomLeft" | "BottomRight"
        Scale          = 1.0,
        AccentColor    = Color3.fromRGB(0, 255, 180),
        BackgroundColor = Color3.fromRGB(8, 8, 12),
        PanelColor      = Color3.fromRGB(14, 14, 18),
        BorderColor     = Color3.fromRGB(35, 35, 45),
        TextColor       = Color3.fromRGB(240, 240, 245),
        MutedColor      = Color3.fromRGB(110, 110, 125),
        Font            = Enum.Font.GothamMedium,
        BoldFont        = Enum.Font.GothamBold,
        Rounding        = 8,
        AnimationSpeed  = 0.18,
    },

    Persist = { Enabled = true, Path = "SM_APEX_Circle.json" },
}

-- ══════════════ BOOT ══════════════
local genv = (type(getgenv) == "function") and getgenv() or _G
if genv.SM_APEX and type(genv.SM_APEX.Destroy) == "function" then
    pcall(genv.SM_APEX.Destroy)
end

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UserInput   = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Replicated  = game:GetService("ReplicatedStorage")
local StatsSvc    = game:GetService("Stats")
local TweenService = game:GetService("TweenService")
local Workspace   = workspace
local LocalPlayer = Players.LocalPlayer

local SkillSet = {}
for _, k in ipairs(CONFIG.Keys.Skills) do SkillSet[k] = true end

-- ══════════════ STATE ══════════════
local State = {
    Locked       = nil,
    Held         = 0,
    MenuOpen     = true,
    Unloaded     = false,
    Ignore       = {},      -- UserId -> true
    FriendCache  = {},
    FactionCache = {},
    Conns        = {},
    -- Aim
    AimActive    = false,
    LastAimPos   = nil,
    -- Circle
    CircleObj    = nil,
    CrosshairObj = nil,
    PulsePhase   = 0,
    -- Auto-cast
    SlotOrder    = {},
    SlotKey      = {},
    SlotCd       = {},
    SlotBusy     = {},
    SlotRange    = {},
    SlotType     = {},      -- "Melee" | "Projectile" | "AoE" | "Beam"
    NextPress    = 0,
    AlignCount   = 0,
    KeyDown      = {},
    InputOk      = nil,
    -- Soru
    LastSoru     = 0,
    SoruStep     = nil,
    -- UI
    UIElems      = {},
    DragData     = nil,
}

local function track(c) table.insert(State.Conns, c) return c end
local function notify(m) print("[S+M] " .. tostring(m)) end

-- ══════════════ VIM / INPUT PURO ══════════════
local VIM = nil
do
    local ok, svc = pcall(function() return game:GetService("VirtualInputManager") end)
    if ok and svc then VIM = svc end
end

local function sendKey(key, down)
    if State.InputOk == false then return false end
    if VIM then
        local ok = pcall(function() VIM:SendKeyEvent(down, key, false, true) end)
        if ok then State.InputOk = true return true end
        ok = pcall(function() VIM:SendKeyEvent(down, key, false) end)
        if ok then State.InputOk = true return true end
    end
    local fn = down and keypress or keyrelease
    if type(fn) == "function" then
        local ok = pcall(fn, key)
        if ok then State.InputOk = true return true end
    end
    State.InputOk = false
    notify("VIM indisponível — Auto-cast desligado.")
    CONFIG.Auto.Enabled = false
    return false
end

-- ══════════════ BINDS DINÂMICOS + COOLDOWN REAL ══════════════
local function resolveSkillSlots()
    local ok, kb = pcall(function()
        local mods = Replicated:FindFirstChild("Modules")
        local data = mods and mods:FindFirstChild("Data")
        local ab   = data and data:FindFirstChild("AbilityKeybinds")
        if ab then return require(ab) end
    end)

    local out = {}
    if ok and type(kb) == "table" then
        for a, b in pairs(kb) do
            local key, slot
            if type(a) == "number" then slot = a key = b
            elseif type(b) == "number" then key = a slot = b end
            if key and slot then
                local kc = key
                if type(kc) == "string" then kc = Enum.KeyCode[kc] end
                if kc and type(slot) == "number" then out[slot] = kc end
            end
        end
    end

    if next(out) == nil then
        for i, k in ipairs(CONFIG.Keys.Skills) do out[i] = k end
        notify("Binds fixos: Z X C V F")
    else
        notify("Binds dinâmicos carregados.")
    end

    local order = {}
    for slot in pairs(out) do table.insert(order, slot) end
    table.sort(order)
    State.SlotKey = out
    State.SlotOrder = order
end

local function normSlot(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "number" and v >= 1 and v <= 8 then return v end
    end
end

local function hookBindable(name, fn)
    local ev = Replicated:FindFirstChild("Events")
    local b = ev and ev:FindFirstChild(name)
    if b and b:IsA("BindableEvent") then track(b.Event:Connect(fn)) return true end
    return false
end

local function bindSkillSignals()
    local a = hookBindable("ActivatedSkill", function(...)
        local s = normSlot(...)
        if s then State.SlotBusy[s] = true end
    end)
    hookBindable("DeactivatedSkill", function(...)
        local s = normSlot(...)
        if s then State.SlotBusy[s] = nil end
    end)
    local c = hookBindable("PlaySkillCooldownAnimation", function(...)
        local s = normSlot(...)
        if s then
            local dur
            for i = 1, select("#", ...) do
                local v = select(i, ...)
                if type(v) == "number" and v ~= s then dur = v break end
            end
            State.SlotCd[s] = os.clock() + (tonumber(dur) or CONFIG.Auto.CooldownFallback)
        end
    end)
    if a or c then notify("Cooldown real conectado.") end
end

-- ══════════════ FRUITSKILLS / MOVESET (range, tipo, hitbox) ══════════════
local function loadFruitSkills()
    local ok, fs = pcall(function()
        return require(Replicated:FindFirstChild("FruitSkills"))
    end)
    if ok and type(fs) == "table" then
        -- FruitSkills[fruta][slot] = {Cooldown, Range, Hitbox, Type, ...}
        notify("FruitSkills carregado.")
        return fs
    end
    notify("FruitSkills indisponível.")
    return nil
end

local FruitSkillsData = loadFruitSkills()

local function getSkillMeta(slot)
    if not FruitSkillsData then return nil end
    -- Tenta achar a fruta equipada
    local char = LocalPlayer.Character
    if not char then return nil end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return nil end
    local fruitName = tool.Name
    local fruitData = FruitSkillsData[fruitName]
    if not fruitData then return nil end
    return fruitData[tostring(slot)] or fruitData[slot]
end

-- ══════════════ UTIL ══════════════
local function pingSec()
    local ok, p = pcall(function()
        return StatsSvc.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    if ok and type(p) == "number" then return math.clamp(p, 0.015, 0.45) end
    return 0.08
end

local function charOf(p)
    if not p then return nil end
    local c = p.Character
    if not c or not c.Parent then return nil end
    local h = c:FindFirstChild("HumanoidRootPart")
    local u = c:FindFirstChildOfClass("Humanoid")
    if h and h:IsA("BasePart") and u and u.Health > 0 then return c, h, u end
end
local function alive(p) local _, _, u = charOf(p) return u ~= nil end

local function getFaction(p)
    if p.Team and p.Team.Name then
        local n = p.Team.Name:lower()
        if n:find("pirate") then return "Pirate" end
        if n:find("marine") then return "Marine" end
    end
    local a = p:GetAttribute("Faction") or p:GetAttribute("Team")
    if a then
        local n = tostring(a):lower()
        if n:find("pirate") then return "Pirate" end
        if n:find("marine") then return "Marine" end
    end
    local ls = p:FindFirstChild("leaderstats")
    if ls then
        for _, name in ipairs({"Team", "Faction"}) do
            local v = ls:FindFirstChild(name)
            if v and v.Value then
                local n = tostring(v.Value):lower()
                if n:find("pirate") then return "Pirate" end
                if n:find("marine") then return "Marine" end
            end
        end
    end
    return nil
end

local function ally(p)
    if p == LocalPlayer then return true end
    if CONFIG.Target.TeamCheck and p.Team and LocalPlayer.Team and p.Team == LocalPlayer.Team then return true end
    if CONFIG.Target.FactionCheck then
        local myFac = getFaction(LocalPlayer)
        local theirFac = getFaction(p)
        if myFac and theirFac and myFac == theirFac then return true end
    end
    if CONFIG.Target.FriendCheck then
        local c = State.FriendCache[p.UserId]
        if c ~= nil then return c end
        local ok, r = pcall(function() return LocalPlayer:IsFriendsWith(p.UserId) end)
        State.FriendCache[p.UserId] = ok and r or false
        return State.FriendCache[p.UserId]
    end
    return false
end

local function pvpOn(p)
    if not CONFIG.Target.OnlyPvP then return true end
    local a = p:GetAttribute("PvPEnabled") or p:GetAttribute("PvP")
    if a ~= nil then return a == true end
    local ls = p:FindFirstChild("leaderstats")
    if ls then
        for _, n in ipairs({"PvpEnabled", "IsPvP", "PvP"}) do
            local v = ls:FindFirstChild(n)
            if v and v:IsA("BoolValue") then return v.Value end
        end
    end
    return true
end

local function bountyOf(p)
    local ls = p:FindFirstChild("leaderstats")
    if ls then
        for _, n in ipairs({"Bounty/Honor", "Bounty", "Honor"}) do
            local v = ls:FindFirstChild(n)
            if v and v:IsA("NumberValue") then return v.Value end
        end
    end
    return 0
end

local function ignored(p) return State.Ignore[tostring(p.UserId)] == true end

-- ══════════════ PERSISTÊNCIA ══════════════
local function saveCfg()
    if not CONFIG.Persist.Enabled or State.Unloaded then return end
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(CONFIG.Persist.Path, HttpService:JSONEncode({ Ignore = State.Ignore }))
    end)
end
local function loadCfg()
    if not CONFIG.Persist.Enabled or type(readfile) ~= "function" then return end
    local ok, c = pcall(readfile, CONFIG.Persist.Path)
    if not ok then return end
    local ok2, d = pcall(function() return HttpService:JSONDecode(c) end)
    if ok2 and type(d) == "table" and type(d.Ignore) == "table" then
        for k, v in pairs(d.Ignore) do State.Ignore[k] = v end
    end
end
loadCfg()

-- ══════════════ CÍRCULO FOV — MATEMÁTICA EXATA ══════════════
-- Converte graus FOV da câmera para raio em pixels
local function calculateCircleRadius()
    local cam = Workspace.CurrentCamera
    if not cam then return CONFIG.Circle.Radius end
    if CONFIG.Circle.DynamicRadius then
        local vp = cam.ViewportSize
        local camFov = cam.FieldOfView -- graus
        local targetFov = CONFIG.Target.FOVDeg or 90 -- graus do aimbot
        -- Raio em pixels = tan(targetFov/2) / tan(camFov/2) * min(vp.X, vp.Y) / 2
        local ratio = math.tan(math.rad(targetFov / 2)) / math.tan(math.rad(camFov / 2))
        return math.min(vp.X, vp.Y) * 0.5 * ratio
    end
    return CONFIG.Circle.Radius
end

-- Verifica se posição mundial está DENTRO do círculo FOV
local function isInCircle(worldPos)
    if not CONFIG.Circle.Enabled then return true end
    local cam = Workspace.CurrentCamera
    if not cam then return false end
    local screenPos, onScreen = cam:WorldToViewportPoint(worldPos)
    if not onScreen then return false end
    local vp = cam.ViewportSize
    local center = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
    local offset = Vector2.new(screenPos.X, screenPos.Y) - center
    local radius = calculateCircleRadius()
    return offset.Magnitude <= radius
end

-- Ângulo entre câmera e posição (graus)
local function angleToTarget(worldPos)
    local cam = Workspace.CurrentCamera
    if not cam then return 180 end
    local dir = worldPos - cam.CFrame.Position
    if dir.Magnitude < 1e-4 then return 0 end
    local cos = math.clamp(cam.CFrame.LookVector:Dot(dir.Unit), -1, 1)
    return math.deg(math.acos(cos))
end

-- ══════════════ ALVO — SELEÇÃO INTELIGENTE ══════════════
local function validTargets()
    local out = {}
    local _, mr = charOf(LocalPlayer)
    if not mr then return out end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Parent and not ignored(p) then
            local _, r, u = charOf(p)
            if r then
                local d = (r.Position - mr.Position).Magnitude
                if d <= CONFIG.Target.MaxDistance and not ally(p) and pvpOn(p) and isInCircle(r.Position) then
                    local hp = u.Health
                    local maxHp = u.MaxHealth
                    local hpPct = maxHp > 0 and (hp / maxHp) or 1
                    local bounty = bountyOf(p)
                    local fac = getFaction(p)
                    table.insert(out, {
                        p = p, d = d, u = u,
                        hp = hp, maxHp = maxHp, hpPct = hpPct,
                        bounty = bounty, faction = fac,
                        angle = angleToTarget(r.Position),
                        screenPos = Workspace.CurrentCamera and Workspace.CurrentCamera:WorldToViewportPoint(r.Position)
                    })
                end
            end
        end
    end
    return out
end

local function pickTarget()
    if State.Locked and alive(State.Locked) and pvpOn(State.Locked) and isInCircle((State.Locked.Character and State.Locked.Character:FindFirstChild("HumanoidRootPart") and State.Locked.Character.HumanoidRootPart.Position) or Vector3.new()) then
        return
    end
    local list = validTargets()
    if #list == 0 then State.Locked = nil return end

    local mode = CONFIG.Target.Priority
    table.sort(list, function(a, b)
        if mode == "Health" then
            return a.hpPct < b.hpPct -- Menor HP% primeiro
        elseif mode == "Distance" then
            return a.d < b.d
        elseif mode == "Threat" then
            -- Score: HP% (peso 0.5) + Distância normalizada (0.3) + Bounty normalizado (0.2)
            local scoreA = a.hpPct * 0.5 + math.clamp(a.d / CONFIG.Target.MaxDistance, 0, 1) * 0.3 + math.clamp(a.bounty / 5000000, 0, 1) * 0.2
            local scoreB = b.hpPct * 0.5 + math.clamp(b.d / CONFIG.Target.MaxDistance, 0, 1) * 0.3 + math.clamp(b.bounty / 5000000, 0, 1) * 0.2
            return scoreA < scoreB
        end
        return a.hpPct < b.hpPct
    end)

    if State.Locked ~= list[1].p then
        State.Locked = list[1].p
        notify("Target: " .. State.Locked.DisplayName .. " [" .. (list[1].faction or "?") .. "] " .. math.floor(list[1].hpPct * 100) .. "% HP")
    end
end

local function cycleTarget()
    local list = validTargets()
    if #list == 0 then notify("Nenhum alvo no círculo.") return end
    local idx = 0
    if State.Locked then
        for i, t in ipairs(list) do if t.p == State.Locked then idx = i break end end
    end
    local nx = idx % #list + 1
    State.Locked = list[nx].p
    notify("Ciclo: " .. State.Locked.DisplayName .. " (" .. nx .. "/" .. #list .. ")")
end

-- ══════════════ AIM ENGINE ══════════════
local function aimActive()
    return CONFIG.Aim.Enabled and not State.Unloaded and (State.Held > 0 or CONFIG.Auto.Enabled)
end

local function getAimPoint()
    if not State.Locked or not alive(State.Locked) then return nil end
    local _, r = charOf(State.Locked)
    if not r then return nil end

    local part = r
    if CONFIG.Target.HitPart == "Head" then
        local hd = State.Locked.Character and State.Locked.Character:FindFirstChild("Head")
        if hd and hd:IsA("BasePart") then part = hd end
    elseif CONFIG.Target.HitPart == "Closest" then
        local head = State.Locked.Character and State.Locked.Character:FindFirstChild("Head")
        if head and head:IsA("BasePart") then
            local cam = Workspace.CurrentCamera
            if cam then
                local headDist = (head.Position - cam.CFrame.Position).Magnitude
                local hrpDist = (r.Position - cam.CFrame.Position).Magnitude
                if headDist < hrpDist then part = head end
            end
        end
    end

    local pos = part.Position
    if CONFIG.Target.Prediction then
        local lead = r.AssemblyLinearVelocity * (pingSec() * CONFIG.Target.PredictX)
        local m = lead.Magnitude
        if m > CONFIG.Target.MaxLead and m > 0 then
            lead = lead * (CONFIG.Target.MaxLead / m)
        end
        pos = pos + lead
    end
    return pos
end

local function aimError()
    local pos = getAimPoint()
    local cam = Workspace.CurrentCamera
    if not pos or not cam then return 180 end
    local d = pos - cam.CFrame.Position
    if d.Magnitude < 1e-4 then return 0 end
    local cos = math.clamp(cam.CFrame.LookVector:Dot(d.Unit), -1, 1)
    return math.deg(math.acos(cos))
end

local function aimFrame()
    if not aimActive() then return end
    local pos = getAimPoint()
    if not pos then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local des = CFrame.lookAt(cam.CFrame.Position, pos)

    if CONFIG.Aim.Smooth > 0 then
        if CONFIG.Aim.SmoothMethod == "Exponential" then
            local alpha = 1 - math.exp(-CONFIG.Aim.Easing * (1 / RunService.RenderStepped:Wait()))
            cam.CFrame = cam.CFrame:Lerp(des, alpha)
        else
            cam.CFrame = cam.CFrame:Lerp(des, math.clamp(1 - CONFIG.Aim.Smooth, 0.02, 1))
        end
    else
        cam.CFrame = des
    end
end
RunService:BindToRenderStep("SM_CIRCLE_AIM", Enum.RenderPriority.Camera.Value + 1, aimFrame)

-- ══════════════ AUTO-CAST ══════════════
local function wallBlocked()
    local pos = getAimPoint()
    local _, mr = charOf(LocalPlayer)
    if not pos or not mr then return false end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local ig = {}
    if LocalPlayer.Character then table.insert(ig, LocalPlayer.Character) end
    if State.Locked and State.Locked.Character then table.insert(ig, State.Locked.Character) end
    rp.FilterDescendantsInstances = ig
    return Workspace:Raycast(mr.Position, pos - mr.Position, rp) ~= nil
end

local function pressKey(key)
    if State.KeyDown[key] then return end
    if not sendKey(key, true) then return end
    State.KeyDown[key] = true
    task.delay(CONFIG.Auto.HoldTime, function()
        if State.KeyDown[key] then
            sendKey(key, false)
            State.KeyDown[key] = nil
        end
    end)
end

local function autoTick()
    if not CONFIG.Auto.Enabled or State.Unloaded or not CONFIG.Aim.Enabled then return end
    if not State.Locked or not alive(State.Locked) then return end

    local now = os.clock()
    if now < State.NextPress then return end

    local err = aimError()
    if err == nil or err > CONFIG.Auto.MaxAngle then
        State.AlignCount = 0
        return
    end
    State.AlignCount = State.AlignCount + 1
    if State.AlignCount < CONFIG.Auto.AlignFrames then return end

    -- Ordem inteligente: prioriza skills prontas por range/tipo
    local order = State.SlotOrder
    if CONFIG.Auto.SmartOrder then
        local myPos = (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") and LocalPlayer.Character.HumanoidRootPart.Position)
        local targetPos = getAimPoint()
        local dist = myPos and targetPos and (myPos - targetPos).Magnitude or 999
        order = {}
        for _, slot in ipairs(State.SlotOrder) do
            local meta = getSkillMeta(slot)
            local range = meta and meta.Range or 999
            local ready = not State.SlotBusy[slot] and (State.SlotCd[slot] or 0) <= now
            if ready then
                -- Prioriza skills que alcançam o alvo
                if dist <= (range + 5) then
                    table.insert(order, 1, slot)
                else
                    table.insert(order, slot)
                end
            end
        end
    end

    for _, slot in ipairs(order) do
        local key = State.SlotKey[slot]
        if key and not State.SlotBusy[slot] and (State.SlotCd[slot] or 0) <= now then
            if CONFIG.Auto.WallCheck and wallBlocked() then return end
            State.SlotCd[slot] = now + CONFIG.Auto.CooldownFallback
            State.NextPress = now + CONFIG.Auto.GapTime
            pressKey(key)
            return
        end
    end
end

-- ══════════════ SORU ══════════════
local function fireTpFix()
    pcall(function()
        local rem = Replicated:FindFirstChild("Remotes")
        local fx = rem and rem:FindFirstChild("CheckTeleportGlitchFix")
        if fx and fx:IsA("RemoteEvent") then fx:FireServer() end
    end)
end

local function soruStart()
    if not CONFIG.Soru.Enabled then return end
    if not State.Locked or not alive(State.Locked) then return end
    local _, mr = charOf(LocalPlayer)
    local _, tr = charOf(State.Locked)
    if not mr or not tr then return end
    local d = (tr.Position - mr.Position).Magnitude
    local now = os.clock()
    if now - State.LastSoru < CONFIG.Soru.Cooldown then return end
    if d > CONFIG.Soru.MaxDistance then
        notify("Soru: fora de alcance (" .. math.floor(d) .. "m)")
        return end
    if d <= CONFIG.Soru.Behind + 1 then return end
    State.LastSoru = now
    State.SoruStep = { steps = CONFIG.Soru.Steps, target = State.Locked }
end

local function soruFrame()
    local s = State.SoruStep
    if not s then return end
    if s.steps <= 0 or not alive(s.target) then State.SoruStep = nil return end
    local _, mr = charOf(LocalPlayer)
    local _, tr = charOf(s.target)
    if not mr or not tr then State.SoruStep = nil return end
    local dest = tr.CFrame * CFrame.new(0, CONFIG.Soru.UpOffset, CONFIG.Soru.Behind)
    mr.CFrame = mr.CFrame:Lerp(dest, CONFIG.Soru.Lerp)
    mr.AssemblyLinearVelocity = Vector3.zero
    s.steps = s.steps - 1
    if s.steps <= 0 then
        mr.CFrame = dest
        fireTpFix()
        State.SoruStep = nil
    end
end

-- ══════════════ CÍRCULO VISUAL (RENDER) ══════════════
local function createCircle()
    local c = Instance.new("Frame")
    c.Name = "SM_Circle"
    c.BackgroundTransparency = 1
    c.AnchorPoint = Vector2.new(0.5, 0.5)
    c.ZIndex = 0
    c.Visible = CONFIG.Circle.Enabled

    local stroke = Instance.new("UIStroke")
    stroke.Name = "CircleStroke"
    stroke.Color = CONFIG.Circle.Color
    stroke.Thickness = CONFIG.Circle.Thickness
    stroke.Transparency = CONFIG.Circle.Transparency
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = c

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = c

    if CONFIG.Circle.FillEnabled then
        c.BackgroundColor3 = CONFIG.Circle.FillColor
        c.BackgroundTransparency = CONFIG.Circle.FillTransparency
    end

    return c
end

local function createCrosshair()
    local c = Instance.new("Frame")
    c.Name = "SM_Crosshair"
    c.BackgroundTransparency = 1
    c.AnchorPoint = Vector2.new(0.5, 0.5)
    c.Position = UDim2.fromScale(0.5, 0.5)
    c.ZIndex = 10
    c.Visible = CONFIG.Circle.ShowCrosshair

    local size = CONFIG.Circle.CrosshairSize
    local gap = CONFIG.Circle.CrosshairGap
    local color = CONFIG.Circle.Color
    local thickness = 1.5

    -- 4 linhas
    local function line(pos, sz, rot)
        local l = Instance.new("Frame")
        l.BackgroundColor3 = color
        l.BorderSizePixel = 0
        l.Size = sz
        l.Position = pos
        l.Rotation = rot
        l.ZIndex = 10
        l.Parent = c
        Instance.new("UICorner", l).CornerRadius = UDim.new(0, 1)
        return l
    end

    line(UDim2.fromOffset(-gap - size, 0), UDim2.fromOffset(size, thickness), 0)      -- Left
    line(UDim2.fromOffset(gap, 0), UDim2.fromOffset(size, thickness), 0)               -- Right
    line(UDim2.fromOffset(0, -gap - size), UDim2.fromOffset(thickness, size), 90)      -- Up
    line(UDim2.fromOffset(0, gap), UDim2.fromOffset(thickness, size), 90)              -- Down

    return c
end

local function updateCircle()
    if not State.CircleObj then State.CircleObj = createCircle() end
    local circle = State.CircleObj
    if not circle then return end

    local cam = Workspace.CurrentCamera
    if not cam then circle.Visible = false return end

    local radius = calculateCircleRadius()
    local diameter = radius * 2
    circle.Size = UDim2.fromOffset(diameter, diameter)
    circle.Position = UDim2.fromScale(0.5, 0.5)
    circle.Visible = CONFIG.Circle.Enabled

    circle.CircleStroke.Color = CONFIG.Circle.Color
    circle.CircleStroke.Thickness = CONFIG.Circle.Thickness
    circle.CircleStroke.Transparency = CONFIG.Circle.Transparency

    if CONFIG.Circle.FillEnabled then
        circle.BackgroundColor3 = CONFIG.Circle.FillColor
        circle.BackgroundTransparency = CONFIG.Circle.FillTransparency
    else
        circle.BackgroundTransparency = 1
    end

    -- Pulso quando travado
    if CONFIG.Circle.PulseEnabled and State.Locked and alive(State.Locked) then
        State.PulsePhase = State.PulsePhase + CONFIG.Circle.PulseSpeed * RunService.RenderStepped:Wait()
        local pulse = 1 + 0.08 * math.sin(State.PulsePhase)
        circle.Size = UDim2.fromOffset(diameter * pulse, diameter * pulse)
    end
end

local function updateCrosshair()
    if not State.CrosshairObj then State.CrosshairObj = createCrosshair() end
    local ch = State.CrosshairObj
    if not ch then return end
    ch.Visible = CONFIG.Circle.ShowCrosshair and CONFIG.Circle.Enabled
end

-- ══════════════ MARCADOR ══════════════
local MK = { hl = nil, bb = nil, pr = nil, tx = nil }

local function clearMarker()
    if MK.hl then pcall(function() MK.hl:Destroy() end) end
    if MK.bb then pcall(function() MK.bb:Destroy() end) end
    MK.hl, MK.bb, MK.pr, MK.tx = nil, nil, nil, nil
end

local function updateMarker()
    clearMarker()
    local p = State.Locked
    if not p or not alive(p) or not CONFIG.Marker.Enabled then return end
    local c = p.Character
    if not c then return end

    local hl = Instance.new("Highlight")
    hl.Name = "SM_Mark"
    hl.Adornee = c
    hl.FillColor = CONFIG.Marker.Color
    hl.OutlineColor = CONFIG.Marker.Color
    hl.FillTransparency = 0.78
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = c
    MK.hl = hl
    MK.pr = p

    local hd = c:FindFirstChild("Head")
    if hd then
        local bb = Instance.new("BillboardGui")
        bb.Name = "SM_Tag"
        bb.Adornee = hd
        bb.Size = UDim2.fromOffset(200, 48)
        bb.StudsOffset = Vector3.new(0, 3.5, 0)
        bb.AlwaysOnTop = true
        bb.Parent = hd

        local tx = Instance.new("TextLabel")
        tx.Size = UDim2.new(1, 0, 1, 0)
        tx.BackgroundTransparency = 1
        tx.Font = CONFIG.UI.BoldFont
        tx.TextSize = 11
        tx.TextColor3 = CONFIG.UI.TextColor
        tx.TextStrokeTransparency = 0.3
        tx.TextXAlignment = Enum.TextXAlignment.Center
        tx.Parent = bb
        MK.bb = bb
        MK.tx = tx
    end
end

local function markerTick()
    if MK.pr and MK.tx and alive(MK.pr) then
        local _, _, u = charOf(MK.pr)
        local hp = u and math.floor(u.Health) or 0
        local maxHp = u and math.floor(u.MaxHealth) or 100
        local pct = math.floor((hp / math.max(maxHp, 1)) * 100)
        local dist = 0
        local _, mr = charOf(LocalPlayer)
        local _, tr = charOf(MK.pr)
        if mr and tr then dist = math.floor((tr.Position - mr.Position).Magnitude) end
        local bounty = bountyOf(MK.pr)
        local fac = getFaction(MK.pr) or "?"
        local facColor = fac == "Pirate" and Color3.fromRGB(255, 150, 50) or (fac == "Marine" and Color3.fromRGB(50, 140, 255) or CONFIG.UI.TextColor)

        local parts = { MK.pr.DisplayName .. "  " .. pct .. "%" }
        if CONFIG.Marker.ShowDistance then table.insert(parts, dist .. "m") end
        if CONFIG.Marker.ShowBounty then table.insert(parts, "$" .. bounty) end
        if CONFIG.Marker.ShowFaction then table.insert(parts, "[" .. fac .. "]") end

        MK.tx.Text = table.concat(parts, "  ·  ")
    end
    updateCircle()
    updateCrosshair()
end

-- ══════════════ UI — MINIMAL "S + M" ══════════════
local TZ = {
    bg        = CONFIG.UI.BackgroundColor,
    panel     = CONFIG.UI.PanelColor,
    line      = CONFIG.UI.BorderColor,
    txt       = CONFIG.UI.TextColor,
    mut       = CONFIG.UI.MutedColor,
    accent    = CONFIG.UI.AccentColor,
}

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "SM_Apex"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
do
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then pcall(function() ScreenGui.Parent = cg end) end
    if not ScreenGui.Parent then
        local pg = LocalPlayer:WaitForChild("PlayerGui", 10)
        if pg then ScreenGui.Parent = pg end
    end
end

local function New(cls, props, parent)
    local o = Instance.new(cls)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end
local function corner(o, r) New("UICorner", { CornerRadius = UDim.new(0, r or CONFIG.UI.Rounding) }, o) end

-- Container principal (arrastável)
local Main = New("Frame", {
    Name = "Main",
    Size = UDim2.fromOffset(220, 140),
    BackgroundColor3 = TZ.bg,
    BorderSizePixel = 0,
    Active = true,
    Visible = true,
    ZIndex = 100,
}, ScreenGui)
corner(Main)
New("UIStroke", { Color = TZ.line, Thickness = 1 }, Main)

-- Título "S + M" (drag handle)
local Title = New("TextLabel", {
    Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = TZ.panel,
    Text = "  S + M",
    Font = CONFIG.UI.BoldFont,
    TextSize = 13,
    TextColor3 = TZ.accent,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Main)
corner(Title)

do
    local drag, dStart, mStart
    Title.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            drag = true dStart = i.Position mStart = Main.Position
        end
    end)
    track(UserInput.InputChanged:Connect(function(i)
        if drag and i.UserInputType == Enum.UserInputType.MouseMovement then
            local d = i.Position - dStart
            Main.Position = UDim2.new(mStart.X.Scale, mStart.X.Offset + d.X, mStart.Y.Scale, mStart.Y.Offset + d.Y)
        end
    end))
    track(UserInput.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
    end))
end

-- Status linha única
local StatusLbl = New("TextLabel", {
    Size = UDim2.new(1, -16, 0, 20),
    Position = UDim2.fromOffset(8, 36),
    BackgroundTransparency = 1,
    Font = CONFIG.UI.Font,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Main)

local TargetLbl = New("TextLabel", {
    Size = UDim2.new(1, -16, 0, 18),
    Position = UDim2.fromOffset(8, 58),
    BackgroundTransparency = 1,
    Font = CONFIG.UI.Font,
    TextSize = 10,
    TextColor3 = TZ.mut,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "target: none",
}, Main)

-- Configs rápidas (sliders compactos)
local function makeRow(label, y, getter, setter, min, max, step, fmt)
    local Lbl = New("TextLabel", {
        Size = UDim2.new(0.5, -4, 0, 18), Position = UDim2.fromOffset(8, y),
        BackgroundTransparency = 1, Font = CONFIG.UI.Font, TextSize = 10,
        TextColor3 = TZ.mut, TextXAlignment = Enum.TextXAlignment.Left,
        Text = label,
    }, Main)
    local Val = New("TextLabel", {
        Size = UDim2.new(0.25, 0, 0, 18), Position = UDim2.new(0.5, 4, 0, y),
        BackgroundTransparency = 1, Font = CONFIG.UI.BoldFont, TextSize = 10,
        TextColor3 = TZ.txt, TextXAlignment = Enum.TextXAlignment.Right,
        Text = fmt(getter()),
    }, Main)
    local Slider = New("TextButton", {
        Size = UDim2.new(0.25, -12, 0, 18), Position = UDim2.new(0.75, 4, 0, y),
        BackgroundColor3 = TZ.panel, Text = "", AutoButtonColor = false,
    }, Main)
    corner(Slider)
    New("UIStroke", { Color = TZ.line, Thickness = 1 }, Slider)

    local fill = New("Frame", {
        Size = UDim2.fromScale((getter() - min) / (max - min), 1),
        BackgroundColor3 = TZ.accent, BorderSizePixel = 0,
    }, Slider)
    corner(fill)

    local dragging = false
    Slider.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true end
    end)
    track(UserInput.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local rel = math.clamp((i.Position.X - Slider.AbsolutePosition.X) / Slider.AbsoluteSize.X, 0, 1)
            local val = min + rel * (max - min)
            val = math.floor(val / step + 0.5) * step
            val = math.clamp(val, min, max)
            setter(val)
            Val.Text = fmt(val)
            fill.Size = UDim2.fromScale((val - min) / (max - min), 1)
        end
    end))
    track(UserInput.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end))
end

-- Linhas de config
makeRow("Circle Radius", 80, function() return CONFIG.Circle.Radius end, function(v) CONFIG.Circle.Radius = v end, 40, 500, 5, function(v) return v .. "px" end)
makeRow("Max Angle", 100, function() return CONFIG.Auto.MaxAngle end, function(v) CONFIG.Auto.MaxAngle = v end, 1, 20, 0.5, function(v) return v .. "°" end)
makeRow("Smooth", 120, function() return CONFIG.Aim.Smooth end, function(v) CONFIG.Aim.Smooth = v end, 0, 0.5, 0.02, function(v) return string.format("%.2f", v) end)

-- Toggle buttons row
local function makeToggle(text, y, get, set)
    local btn = New("TextButton", {
        Size = UDim2.new(0.5, -10, 0, 22), Position = UDim2.fromOffset(8 + (text:find("Auto") and 110 or 0), y),
        BackgroundColor3 = TZ.panel, Text = text .. ": " .. (get() and "ON" or "OFF"),
        Font = CONFIG.UI.BoldFont, TextSize = 10, TextColor3 = TZ.txt,
        AutoButtonColor = false,
    }, Main)
    corner(btn)
    New("UIStroke", { Color = TZ.line, Thickness = 1 }, btn)
    btn.MouseButton1Click:Connect(function()
        set(not get())
        btn.Text = text .. ": " .. (get() and "ON" or "OFF")
        btn.TextColor3 = get() and TZ.accent or TZ.txt
    end)
    return btn
end

local aimBtn = makeToggle("Aim", 142, function() return CONFIG.Aim.Enabled end, function(v) CONFIG.Aim.Enabled = v; StatusLbl.Text = "aim: " .. (v and "ON" or "OFF") end)
local autoBtn = makeToggle("Auto", 142, function() return CONFIG.Auto.Enabled end, function(v) CONFIG.Auto.Enabled = v end)
local circleBtn = makeToggle("Circle", 166, function() return CONFIG.Circle.Enabled end, function(v) CONFIG.Circle.Enabled = v end)
local facBtn = makeToggle("Faction", 166, function() return CONFIG.Target.FactionCheck end, function(v) CONFIG.Target.FactionCheck = v end)

local function refreshStatus()
    StatusLbl.Text = "aim: " .. (CONFIG.Aim.Enabled and "ON" or "OFF")
        .. "  ·  auto: " .. (CONFIG.Auto.Enabled and "ON" or "OFF")
        .. "  ·  circle: " .. (CONFIG.Circle.Enabled and "ON" or "OFF")
    StatusLbl.TextColor3 = CONFIG.Aim.Enabled and TZ.accent or TZ.mut
end
refreshStatus()

function UI.refreshTarget()
    TargetLbl.Text = State.Locked and ("target: " .. State.Locked.DisplayName .. " [" .. (getFaction(State.Locked) or "?") .. "]") or "target: none"
    TargetLbl.TextColor3 = State.Locked and TZ.txt or TZ.mut
end

-- FAB para reabrir
local Fab = New("TextButton", {
    Size = UDim2.fromOffset(30, 30), Position = UDim2.new(0, 8, 0.5, -15),
    BackgroundColor3 = TZ.bg, Text = "S+M", Font = CONFIG.UI.BoldFont,
    TextSize = 10, TextColor3 = TZ.accent, Visible = false,
}, ScreenGui)
corner(Fab, 15)
New("UIStroke", { Color = TZ.line, Thickness = 1 }, Fab)
Fab.MouseButton1Click:Connect(function() State.MenuOpen = true Main.Visible = true Fab.Visible = false end)

-- Posição inicial
local function applyUIPosition()
    local vp = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
    local pos = CONFIG.UI.Position
    if pos == "TopLeft" then Main.Position = UDim2.fromOffset(16, 16)
    elseif pos == "TopRight" then Main.Position = UDim2.fromOffset(vp.X - 236, 16)
    elseif pos == "BottomLeft" then Main.Position = UDim2.fromOffset(16, vp.Y - 156)
    elseif pos == "BottomRight" then Main.Position = UDim2.fromOffset(vp.X - 236, vp.Y - 156) end
end
applyUIPosition()

-- ══════════════ INPUT ══════════════
track(UserInput.InputBegan:Connect(function(input, gpe)
    local it = input.UserInputType

    -- Skills (hold = aim)
    if it == Enum.UserInputType.Keyboard and SkillSet[input.KeyCode] then
        State.Held = State.Held + 1
        pickTarget()
        return
    end

    -- Mouse lateral
    if it == Enum.UserInputType.MouseButton4 then cycleTarget() return end
    if it == Enum.UserInputType.MouseButton5 then State.MenuOpen = false Main.Visible = false Fab.Visible = true return end

    if gpe then return end

    if input.KeyCode == CONFIG.Keys.AimToggle then
        CONFIG.Aim.Enabled = not CONFIG.Aim.Enabled
        aimBtn.Text = "Aim: " .. (CONFIG.Aim.Enabled and "ON" or "OFF")
        refreshStatus()
        notify("Aim: " .. (CONFIG.Aim.Enabled and "ON" or "OFF"))
        return
    end
    if input.KeyCode == CONFIG.Keys.AutoToggle then
        if State.InputOk == false then notify("VIM indisponível") return end
        CONFIG.Auto.Enabled = not CONFIG.Auto.Enabled
        autoBtn.Text = "Auto: " .. (CONFIG.Auto.Enabled and "ON" or "OFF")
        refreshStatus()
        notify("Auto: " .. (CONFIG.Auto.Enabled and "ON" or "OFF"))
        return
    end
    if input.KeyCode == CONFIG.Keys.MenuToggle then
        State.MenuOpen = not State.MenuOpen
        Main.Visible = State.MenuOpen
        Fab.Visible = not State.MenuOpen
        return
    end
    if input.KeyCode == CONFIG.Keys.Unload then cleanup() return end
    if input.KeyCode == CONFIG.Keys.CycleTarget then cycleTarget() return end
    if input.KeyCode == CONFIG.Keys.Soru then soruStart() return end
end))

track(UserInput.InputEnded:Connect(function(input)
    if SkillSet[input.KeyCode] and State.Held > 0 then State.Held = State.Held - 1 end
end))

-- ══════════════ MAIN LOOP ══════════════
track(RunService.Heartbeat:Connect(function()
    if State.Unloaded then return end
    local now = os.clock()

    -- Target picker (100ms)
    if now - (State.TickTarget or 0) > 0.1 then
        State.TickTarget = now
        pickTarget()
        if State.Locked and MK.pr ~= State.Locked then updateMarker() UI.refreshTarget() end
        if not State.Locked and MK.pr then clearMarker() UI.refreshTarget() end
    end

    -- Lista + marker + circle (2s)
    if now - (State.TickList or 0) > 2.0 then
        State.TickList = now
        markerTick()
    end

    soruFrame()
    autoTick()
end))

-- ══════════════ CLEANUP ══════════════
function cleanup()
    if State.Unloaded then return end
    State.Unloaded = true
    pcall(function() RunService:UnbindFromRenderStep("SM_CIRCLE_AIM") end)
    for _, c in ipairs(State.Conns) do pcall(function() c:Disconnect() end) end
    clearMarker()
    if State.CircleObj then pcall(function() State.CircleObj:Destroy() end) end
    if State.CrosshairObj then pcall(function() State.CrosshairObj:Destroy() end) end
    pcall(function() ScreenGui:Destroy() end)
    genv.SM_APEX = nil
    notify("Unloaded.")
end
genv.SM_APEX = { Destroy = cleanup }

-- ══════════════ INIT ══════════════
resolveSkillSlots()
bindSkillSignals()
State.CircleObj = createCircle()
State.CircleObj.Parent = ScreenGui
State.CrosshairObj = createCrosshair()
State.CrosshairObj.Parent = ScreenGui
updateCircle()
updateCrosshair()

notify("S+M APEX loaded. RightShift=Aim | RightAlt=Auto | RightCtrl=Menu | Delete=Unload | G=Cycle | R=Soru | MB4/MB5=Mouse")
