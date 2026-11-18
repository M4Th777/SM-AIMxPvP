--[[
    APEX HYBRID — Blox Fruits PvP Aim Assist + Silent Aim
    Versão: 2026-11-18 | Cliente: 0.748.0.7481526
    
    Arquitetura híbrida (ápice):
    • Camera Assist (FOV Lock + LockCenter + Hold-to-aim + Smooth exponential)
    • Silent Aim (Namecall rewrite: ShootGunEvent + RemoteEvent + TAP)
    • Soru Seguro (Interpolação 4 steps + CheckTeleportGlitchFix obrigatório)
    • Cooldown Real (Bindables: PlaySkillCooldownAnimation + ActivatedSkill)
    • Target Selector (ReadPlayerData 2Hz + Dual-origin + Threat Score)
    • Visual Unificado (Circle FOV + Crosshair + Target Marker + Status HUD)
    • Input Unificado (Z/X/C/V/F/R + RightShift/RightAlt/RightCtrl/Delete/G/MB4/MB5)
    • Auto-Cast Opcional (RightAlt, respeita CD real + aimError ≤ 4.5°)
    • Persistência JSON + Unload Limpo
    
    Controles:
    RightShift   = Aim Assist ON/OFF
    RightAlt     = Auto-Cast ON/OFF
    RightCtrl    = Menu (arrastável pelo título "APEX")
    Delete       = Unload Seguro
    G            = Ciclar Alvo
    R            = Soru Guiado
    Z X C V F    = Skills (Hold = Aim Assist ativo)
    MB4          = Ciclar Alvo
    MB5          = Esconder/Mostrar Menu
]]

--!strict
--!optimize 2

local RunService      = game:GetService("RunService")
local UserInput       = game:GetService("UserInputService")
local Players         = game:GetService("Players")
local Replicated      = game:GetService("ReplicatedStorage")
local HttpService     = game:GetService("HttpService")
local TweenService    = game:GetService("TweenService")
local Stats           = game:GetService("Stats")
local Workspace       = workspace
local LocalPlayer     = Players.LocalPlayer
local Camera          = Workspace.CurrentCamera

local VIM = game:GetService("VirtualInputManager")

-- ============================================================================
-- CONFIGURAÇÃO CENTRAL (ÚNICO PONTO DE AJUSTE)
-- ============================================================================
local CONFIG = {
    -- Camera Assist (FOV Lock)
    Aim = {
        Enabled       = true,
        Smooth        = 0.12,        -- Exponential factor (0.08-0.15 = legítimo)
        MaxAngle      = 4.5,         -- Graus: só assiste se alvo dentro disso
        FOVRadius     = 180,         -- Pixels (Circle FOV)
        LockMouse     = true,        -- LockCenter quando travado
        WallCheck     = false,       -- Raycast antes de travar
        HoldToAim     = true,        -- Só assiste enquanto segura skill/aim key
        DynamicFOV    = false,       -- Escala com zoom da câmera
    },

    -- Silent Aim (Packet Rewrite)
    Silent = {
        Enabled       = true,
        MaxAngle      = 4.5,         -- Mesmo do Aim
        GunEnabled    = true,        -- ShootGunEvent
        SkillEnabled  = true,        -- RemoteEvent (skills Z/X/C/V/F)
        TapEnabled    = true,        -- TAP guns (Musket/Slingshot/etc.)
    },

    -- Target Selector
    Target = {
        MaxDistance     = 600,       -- Studs
        TeamCheck       = true,
        FactionCheck    = true,      -- Pirates vs Marines
        FriendCheck     = true,      -- IsFriendsWith (cache)
        Priority        = "Threat",  -- "Health" | "Distance" | "Threat"
        ReadPlayerDataHz = 2,        -- Hz para ReadPlayerData
        DualOrigin      = true,      -- Usa serverPos + clientPos
    },

    -- Soru (Flash Step / Dash R)
    Soru = {
        Enabled     = true,
        Key         = Enum.KeyCode.R,
        MaxDist     = 45,
        Behind      = 2.8,
        UpOffset    = 0,
        Steps       = 4,
        Lerp        = 0.38,
        Cooldown    = 0.55,
    },

    -- Auto-Cast (Opcional, RightAlt)
    AutoCast = {
        Enabled       = false,
        MaxAngle      = 4.5,
        AlignFrames   = 1,
        HoldTime      = 0.045,       -- Duração keydown
        GapTime       = 0.11,        -- Intervalo entre casts
        SmartOrder    = true,        -- Prioriza skills que alcançam alvo
        WallCheck     = false,
    },

    -- Visual (Circle FOV + Crosshair + Marker)
    Visual = {
        Circle = {
            Enabled          = true,
            Radius           = 180,
            Color            = Color3.fromRGB(0, 255, 180),
            Thickness        = 2,
            Transparency     = 0.15,
            FillEnabled      = false,
            FillTransparency = 0.92,
            PulseEnabled     = true,
            PulseSpeed       = 2.5,
            Segments         = 128,
        },
        Crosshair = {
            Enabled   = true,
            Size      = 6,
            Gap       = 4,
            Thickness = 1.5,
        },
        Marker = {
            Enabled      = true,
            Color        = Color3.fromRGB(255, 50, 80),
            ShowHP       = true,
            ShowDist     = true,
            ShowBounty   = true,
            ShowFaction  = true,
            UpdateRate   = 6,        -- Hz
        },
    },

    -- UI / Menu
    UI = {
        Position        = "TopLeft", -- TopLeft | TopRight | BottomLeft | BottomRight
        Scale           = 1.0,
        Accent          = Color3.fromRGB(0, 255, 180),
        BgColor         = Color3.fromRGB(8, 8, 12),
        PanelColor      = Color3.fromRGB(14, 14, 18),
        BorderColor     = Color3.fromRGB(35, 35, 45),
        TextColor       = Color3.fromRGB(240, 240, 245),
        MutedColor      = Color3.fromRGB(110, 110, 125),
        Font            = Enum.Font.GothamMedium,
        BoldFont        = Enum.Font.GothamBold,
        Rounding        = 8,
        AnimSpeed       = 0.18,
    },

    -- Persistência
    Persist = {
        Enabled = true,
        Path    = "ApexHybrid_Config.json",
    },

    -- Keys
    Keys = {
        AimToggle    = Enum.KeyCode.RightShift,
        AutoToggle   = Enum.KeyCode.RightAlt,
        MenuToggle   = Enum.KeyCode.RightControl,
        Unload       = Enum.KeyCode.Delete,
        CycleTarget  = Enum.KeyCode.G,
        Soru         = Enum.KeyCode.R,
        SkillKeys    = { Enum.KeyCode.Z, Enum.KeyCode.X, Enum.KeyCode.C, Enum.KeyCode.V, Enum.KeyCode.F },
    },
}

-- ============================================================================
-- ESTADO GLOBAL
-- ============================================================================
local State = {
    -- Aim
    LockedTarget      = nil,
    HeldSkills        = 0,
    AimActive         = false,
    LastAimPos        = nil,
    -- Silent Aim Attributes
    SilentAttr        = {
        Gun   = "Apex_Gun",
        Skill = "Apex_Skill",
        Tap   = "Apex_Tap",
    },
    -- Target
    TargetCache       = {},          -- Player -> {serverPos, serverVel, hp, maxHp, level, race, fruit, bounty, faction, updated}
    FriendCache       = {},
    IgnoreList        = {},
    -- Soru
    SoruActive        = false,
    SoruStep          = nil,
    LastSoru          = 0,
    -- Cooldowns
    SlotKey           = {},          -- slot -> KeyCode
    SlotOrder         = {},          -- sorted slots
    SlotCD            = {},          -- slot -> os.clock() ready time
    SlotBusy          = {},          -- slot -> bool
    SlotRange         = {},          -- slot -> range (studs)
    SlotType          = {},          -- slot -> "Melee"|"Sword"|"Gun"|"Fruit"|"JobTool"
    NextAutoCast      = 0,
    AlignCount        = 0,
    KeyDown           = {},
    -- Visual
    CircleObj         = nil,
    CrosshairObj      = nil,
    MarkerHL          = nil,
    MarkerBB          = nil,
    MarkerTarget      = nil,
    PulsePhase        = 0,
    -- Auto-Cast
    AutoCastEnabled   = false,
    -- UI
    MenuOpen          = true,
    DragData          = nil,
    UIElements        = {},
    -- Connections
    Connections       = {},
    -- Runtime
    Unloaded          = false,
    InputOK           = nil,
}

-- ============================================================================
-- UTILITÁRIOS
-- ============================================================================
local function track(conn) table.insert(State.Connections, conn) return conn end
local function notify(msg) print("[Apex] " .. tostring(msg)) end

local function pingSec()
    local ok, p = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    return ok and math.clamp(p, 0.015, 0.45) or 0.08
end

local function getHRP(char)
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHead(char)
    return char and char:FindFirstChild("Head")
end

local function getHumanoid(char)
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function isAlive(player)
    local char = player.Character
    local hum = getHumanoid(char)
    return hum and hum.Health > 0
end

local function getFaction(player)
    if player.Team and player.Team.Name then
        local n = player.Team.Name:lower()
        if n:find("marine") then return "Marine" end
        if n:find("pirate") then return "Pirate" end
    end
    local attr = player:GetAttribute("Faction") or player:GetAttribute("Team")
    if attr then
        local n = tostring(attr):lower()
        if n:find("marine") then return "Marine" end
        if n:find("pirate") then return "Pirate" end
    end
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        for _, name in ipairs({"Team", "Faction"}) do
            local v = ls:FindFirstChild(name)
            if v and v.Value then
                local n = tostring(v.Value):lower()
                if n:find("marine") then return "Marine" end
                if n:find("pirate") then return "Pirate" end
            end
        end
    end
    return nil
end

local function isAlly(player)
    if player == LocalPlayer then return true end
    if CONFIG.Target.TeamCheck and player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team then return true end
    if CONFIG.Target.FactionCheck then
        local myFac = getFaction(LocalPlayer)
        local theirFac = getFaction(player)
        if myFac and theirFac and myFac == theirFac then return true end
    end
    if CONFIG.Target.FriendCheck then
        local cached = State.FriendCache[player.UserId]
        if cached ~= nil then return cached end
        local ok, res = pcall(function() return LocalPlayer:IsFriendsWith(player.UserId) end)
        State.FriendCache[player.UserId] = ok and res or false
        return State.FriendCache[player.UserId]
    end
    return false
end

local function isIgnored(player)
    return State.IgnoreList[tostring(player.UserId)] == true
end

local function getBounty(player)
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        for _, name in ipairs({"Bounty/Honor", "Bounty", "Honor"}) do
            local v = ls:FindFirstChild(name)
            if v and v:IsA("NumberValue") then return v.Value end
        end
    end
    return 0
end

local function angleTo(pos)
    local cam = Workspace.CurrentCamera
    if not cam then return 180 end
    local dir = pos - cam.CFrame.Position
    if dir.Magnitude < 0.01 then return 0 end
    local cos = math.clamp(cam.CFrame.LookVector:Dot(dir.Unit), -1, 1)
    return math.deg(math.acos(cos))
end

local function worldToScreen(pos)
    local cam = Workspace.CurrentCamera
    if not cam then return nil, false end
    return cam:WorldToViewportPoint(pos)
end

local function inFOVCircle(pos)
    if not CONFIG.Aim.Enabled then return true end
    local screenPos, onScreen = worldToScreen(pos)
    if not onScreen then return false end
    local vp = Camera.ViewportSize
    local center = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
    local offset = Vector2.new(screenPos.X, screenPos.Y) - center
    local radius = CONFIG.Aim.FOVRadius
    if CONFIG.Aim.DynamicFOV then
        local camFov = Camera.FieldOfView
        local targetFov = 90
        local ratio = math.tan(math.rad(targetFov / 2)) / math.tan(math.rad(camFov / 2))
        radius = math.min(vp.X, vp.Y) * 0.5 * ratio
    end
    return offset.Magnitude <= radius
end

local function threatScore(t)
    local hpPct = t.maxHp > 0 and (t.hp / t.maxHp) or 1
    local distNorm = math.clamp(t.dist / CONFIG.Target.MaxDistance, 0, 1)
    local bountyNorm = math.clamp(t.bounty / 5000000, 0, 1)
    return hpPct * 0.5 + distNorm * 0.3 + bountyNorm * 0.2
end

-- ============================================================================
-- PERSISTÊNCIA
-- ============================================================================
local function saveConfig()
    if not CONFIG.Persist.Enabled or State.Unloaded or not writefile then return end
    pcall(function()
        writefile(CONFIG.Persist.Path, HttpService:JSONEncode({
            IgnoreList = State.IgnoreList,
            CircleRadius = CONFIG.Visual.Circle.Radius,
            MaxAngle = CONFIG.Silent.MaxAngle,
            Smooth = CONFIG.Aim.Smooth,
            AutoCast = CONFIG.AutoCast.Enabled,
        }))
    end)
end

local function loadConfig()
    if not CONFIG.Persist.Enabled or not readfile then return end
    local ok, content = pcall(readfile, CONFIG.Persist.Path)
    if not ok then return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if ok2 and data then
        State.IgnoreList = data.IgnoreList or {}
        if data.CircleRadius then CONFIG.Visual.Circle.Radius = data.CircleRadius end
        if data.MaxAngle then CONFIG.Silent.MaxAngle = data.MaxAngle end
        if data.Smooth then CONFIG.Aim.Smooth = data.Smooth end
        if data.AutoCast ~= nil then CONFIG.AutoCast.Enabled = data.AutoCast end
    end
end

-- ============================================================================
-- BINDS DINÂMICOS (AbilityKeybinds)
-- ============================================================================
local function resolveSkillSlots()
    local ok, kb = pcall(function()
        local mods = Replicated:FindFirstChild("Modules")
        local data = mods and mods:FindFirstChild("Data")
        local ab = data and data:FindFirstChild("AbilityKeybinds")
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
        for i, k in ipairs(CONFIG.Keys.SkillKeys) do out[i] = k end
        notify("Binds fixos: Z X C V F")
    else
        notify("Binds dinâmicos carregados")
    end
    local order = {}
    for slot in pairs(out) do table.insert(order, slot) end
    table.sort(order)
    State.SlotKey = out
    State.SlotOrder = order
end

-- ============================================================================
-- COOLDOWN REAL (Bindables)
-- ============================================================================
local function normSlot(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "number" and v >= 1 and v <= 8 then return v end
    end
end

local function hookBindables()
    local Events = Replicated:FindFirstChild("Events")
    if not Events then return end
    
    local a = Events:FindFirstChild("ActivatedSkill")
    if a and a:IsA("BindableEvent") then
        track(a.Event:Connect(function(...)
            local s = normSlot(...)
            if s then State.SlotBusy[s] = true end
        end))
    end
    
    local b = Events:FindFirstChild("DeactivatedSkill")
    if b and b:IsA("BindableEvent") then
        track(b.Event:Connect(function(...)
            local s = normSlot(...)
            if s then State.SlotBusy[s] = nil end
        end))
    end
    
    local c = Events:FindFirstChild("PlaySkillCooldownAnimation")
    if c and c:IsA("BindableEvent") then
        track(c.Event:Connect(function(...)
            local s = normSlot(...)
            if s then
                local dur
                for i = 1, select("#", ...) do
                    local v = select(i, ...)
                    if type(v) == "number" and v ~= s then dur = v break end
                end
                State.SlotCD[s] = os.clock() + (tonumber(dur) or 3.5)
            end
        end))
    end
    notify("Cooldown real conectado via Bindables")
end

-- ============================================================================
-- FRUIT SKILLS / MOVESET (Range, Tipo, Hitbox)
-- ============================================================================
local FruitSkillsData = nil

local function loadFruitSkills()
    local ok, fs = pcall(function()
        return require(Replicated:FindFirstChild("FruitSkills"))
    end)
    if ok and type(fs) == "table" then
        FruitSkillsData = fs
        notify("FruitSkills carregado")
    else
        notify("FruitSkills indisponível")
    end
end

local function getSkillMeta(slot)
    if not FruitSkillsData then return nil end
    local char = LocalPlayer.Character
    if not char then return nil end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return nil end
    local fruitName = tool.Name
    local fruitData = FruitSkillsData[fruitName]
    if not fruitData then return nil end
    return fruitData[tostring(slot)] or fruitData[slot]
end

local function updateSlotRanges()
    for _, slot in ipairs(State.SlotOrder) do
        local meta = getSkillMeta(slot)
        if meta then
            State.SlotRange[slot] = meta.Range or 999
            State.SlotType[slot] = meta.Type or "Unknown"
        else
            State.SlotRange[slot] = 999
            State.SlotType[slot] = "Unknown"
        end
    end
end

-- ============================================================================
-- TARGET SELECTOR (ReadPlayerData + Dual-Origin)
-- ============================================================================
local NetFolder = nil
local ReadPlayerDataRF = nil

local function initRemotes()
    local modules = Replicated:FindFirstChild("Modules")
    NetFolder = modules and modules:FindFirstChild("Net")
    if NetFolder then
        ReadPlayerDataRF = NetFolder:FindFirstChild("RF/ReadPlayerData")
    end
    if not ReadPlayerDataRF then
        notify("AVISO: RF/ReadPlayerData não encontrado em Modules.Net")
    end
end

local function fetchPlayerData(target)
    if not ReadPlayerDataRF then return nil end
    local ok, data = pcall(function()
        return ReadPlayerDataRF:InvokeServer(target)
    end)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

local function updateTargetCache()
    if not CONFIG.Target.DualOrigin then return end
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer and isAlive(plr) and not isIgnored(plr) and not isAlly(plr) then
            local cache = State.TargetCache[plr]
            local now = os.clock()
            if not cache or (now - (cache.updated or 0)) >= (1 / CONFIG.Target.ReadPlayerDataHz) then
                local data = fetchPlayerData(plr)
                if data then
                    local hrp = getHRP(plr.Character)
                    State.TargetCache[plr] = {
                        serverPos = data.Position or (hrp and hrp.Position),
                        serverVel = data.Velocity or (hrp and hrp.AssemblyLinearVelocity),
                        hp = data.Health,
                        maxHp = data.MaxHealth,
                        level = data.Level,
                        race = data.Race,
                        fruit = data.Fruit,
                        bounty = getBounty(plr),
                        faction = getFaction(plr),
                        updated = now,
                    }
                end
            end
        end
    end
end

local function getBestTarget()
    local myChar = LocalPlayer.Character
    local myHRP = getHRP(myChar)
    if not myHRP then return nil end
    
    local candidates = {}
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer and plr.Character and isAlive(plr) and not isIgnored(plr) and not isAlly(plr) then
            local hrp = getHRP(plr.Character)
            local head = getHead(plr.Character)
            if hrp then
                local dist = (hrp.Position - myHRP.Position).Magnitude
                if dist <= CONFIG.Target.MaxDistance and inFOVCircle(hrp.Position) then
                    local cache = State.TargetCache[plr]
                    local hp, maxHp
                    if cache and cache.hp then
                        hp, maxHp = cache.hp, cache.maxHp
                    else
                        local hum = getHumanoid(plr.Character)
                        hp, maxHp = hum.Health, hum.MaxHealth
                    end
                    local hpPct = maxHp > 0 and (hp / maxHp) or 1
                    local bounty = getBounty(plr)
                    local faction = getFaction(plr)
                    table.insert(candidates, {
                        player = plr,
                        dist = dist,
                        hp = hp,
                        maxHp = maxHp,
                        hpPct = hpPct,
                        bounty = bounty,
                        faction = faction,
                        hrp = hrp,
                        head = head,
                        cache = cache,
                    })
                end
            end
        end
    end
    
    if #candidates == 0 then return nil end
    
    local mode = CONFIG.Target.Priority
    table.sort(candidates, function(a, b)
        if mode == "Health" then
            return a.hpPct < b.hpPct
        elseif mode == "Distance" then
            return a.dist < b.dist
        else -- Threat
            return threatScore(a) < threatScore(b)
        end
    end)
    
    return candidates[1]
end

local function cycleTarget()
    local myChar = LocalPlayer.Character
    local myHRP = getHRP(myChar)
    if not myHRP then return end
    
    local list = {}
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer and plr.Character and isAlive(plr) and not isIgnored(plr) and not isAlly(plr) then
            local hrp = getHRP(plr.Character)
            if hrp then
                local dist = (hrp.Position - myHRP.Position).Magnitude
                if dist <= CONFIG.Target.MaxDistance and inFOVCircle(hrp.Position) then
                    table.insert(list, plr)
                end
            end
        end
    end
    
    if #list == 0 then notify("Nenhum alvo no FOV") return end
    
    local idx = 1
    if State.LockedTarget then
        for i, plr in ipairs(list) do if plr == State.LockedTarget then idx = i break end end
    end
    idx = idx % #list + 1
    State.LockedTarget = list[idx]
    notify("Alvo: " .. State.LockedTarget.DisplayName .. " (" .. idx .. "/" .. #list .. ")")
end

-- ============================================================================
-- SORU SEGURO (Interpolação + CheckTeleportGlitchFix)
-- ============================================================================
local CheckTeleportFixRE = nil

local function initTeleportFix()
    local remotes = Replicated:FindFirstChild("Remotes")
    CheckTeleportFixRE = remotes and remotes:FindFirstChild("CheckTeleportGlitchFix")
end

local function fireTeleportFix()
    if CheckTeleportFixRE and CheckTeleportFixRE:IsA("RemoteEvent") then
        pcall(function() CheckTeleportFixRE:FireServer() end)
    end
end

local function startSoru()
    if not CONFIG.Soru.Enabled then return end
    if not State.LockedTarget or not isAlive(State.LockedTarget) then return end
    local myHRP = getHRP(LocalPlayer.Character)
    local tHRP = getHRP(State.LockedTarget.Character)
    if not myHRP or not tHRP then return end
    
    local dist = (tHRP.Position - myHRP.Position).Magnitude
    local now = os.clock()
    if now - State.LastSoru < CONFIG.Soru.Cooldown then return end
    if dist > CONFIG.Soru.MaxDist then notify("Soru: fora de alcance (" .. math.floor(dist) .. "m)") return end
    if dist <= CONFIG.Soru.Behind + 1 then return end
    
    State.LastSoru = now
    State.SoruActive = true
    State.SoruStep = {
        steps = CONFIG.Soru.Steps,
        target = State.LockedTarget,
        startTime = now,
    }
end

local function soruStep(dt)
    if not State.SoruActive or not State.SoruStep then return end
    local step = State.SoruStep
    if not isAlive(step.target) then State.SoruActive = false State.SoruStep = nil return end
    
    local myHRP = getHRP(LocalPlayer.Character)
    local tHRP = getHRP(step.target.Character)
    if not myHRP or not tHRP then State.SoruActive = false State.SoruStep = nil return end
    
    local dest = tHRP.CFrame * CFrame.new(0, CONFIG.Soru.UpOffset, CONFIG.Soru.Behind)
    myHRP.CFrame = myHRP.CFrame:Lerp(dest, CONFIG.Soru.Lerp)
    myHRP.AssemblyLinearVelocity = Vector3.zero
    step.steps = step.steps - 1
    
    if step.steps <= 0 then
        myHRP.CFrame = dest
        fireTeleportFix()
        task.wait(0.1)
        State.SoruActive = false
        State.SoruStep = nil
    end
end

-- ============================================================================
-- SILENT AIM (Namecall Hook)
-- ============================================================================
local function installSilentAimHook()
    if not hookmetamethod or not getnamecallmethod then
        notify("hookmetamethod/getnamecallmethod indisponíveis")
        return false
    end
    
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if method:lower() ~= "fireserver" then
            return oldNamecall(self, ...)
        end
        
        if not CONFIG.Silent.Enabled or not State.LockedTarget or not isAlive(State.LockedTarget) then
            return oldNamecall(self, ...)
        end
        
        local targetPart = getHead(State.LockedTarget.Character) or getHRP(State.LockedTarget.Character)
        if not targetPart then return oldNamecall(self, ...) end
        
        local args = {...}
        local name = self.Name
        
        -- 1) ShootGunEvent (Guns) - args: Vector3 pos, {BasePart[] parts}
        if CONFIG.Silent.GunEnabled and name == "RE/ShootGunEvent" and typeof(args[1]) == "Vector3" and type(args[2]) == "table" then
            LocalPlayer:SetAttribute(State.SilentAttr.Gun, targetPart)
            return oldNamecall(self, targetPart.Position, {targetPart})
        end
        
        -- 2) Tool RemoteEvent (Skills Z/X/C/V/F) - args: Vector3 pos
        if CONFIG.Silent.SkillEnabled and name == "RemoteEvent" then
            if typeof(args[1]) == "Vector3" and not args[2] then
                LocalPlayer:SetAttribute(State.SilentAttr.Skill, targetPart)
                return oldNamecall(self, targetPart.Position)
            elseif args[1] == "TAP" and typeof(args[2]) == "Vector3" then
                -- 3) TAP Guns (Musket/Slingshot) - args: "TAP", Vector3 pos
                if CONFIG.Silent.TapEnabled then
                    LocalPlayer:SetAttribute(State.SilentAttr.Tap, targetPart)
                    return oldNamecall(self, "TAP", targetPart.Position)
                end
            end
        end
        
        return oldNamecall(self, ...)
    end)
    
    track(function() if hookmetamethod then hookmetamethod(game, "__namecall", oldNamecall) end end)
    notify("Silent Aim hook instalado")
    return true
end

-- ============================================================================
-- VIM INPUT (Auto-Cast + Soru)
-- ============================================================================
local function sendKey(key, down)
    if State.InputOK == false then return false end
    local ok = pcall(function() VIM:SendKeyEvent(down, key, false, true) end)
    if ok then State.InputOK = true return true end
    ok = pcall(function() VIM:SendKeyEvent(down, key, false) end)
    if ok then State.InputOK = true return true end
    local fn = down and keypress or keyrelease
    if type(fn) == "function" then
        ok = pcall(fn, key)
        if ok then State.InputOK = true return true end
    end
    State.InputOK = false
    return false
end

local function pressKey(key, holdTime)
    if State.KeyDown[key] then return end
    if not sendKey(key, true) then return end
    State.KeyDown[key] = true
    task.delay(holdTime or CONFIG.AutoCast.HoldTime, function()
        if State.KeyDown[key] then
            sendKey(key, false)
            State.KeyDown[key] = nil
        end
    end)
end

local function autoCastTick()
    if not State.AutoCastEnabled or State.Unloaded then return end
    if not State.LockedTarget or not isAlive(State.LockedTarget) then return end
    
    local now = os.clock()
    if now < State.NextAutoCast then return end
    
    -- Verifica aim error
    local targetPart = getHead(State.LockedTarget.Character) or getHRP(State.LockedTarget.Character)
    if not targetPart then return end
    local err = angleTo(targetPart.Position)
    if err > (CONFIG.AutoCast.MaxAngle or 4.5) then
        State.AlignCount = 0
        return
    end
    State.AlignCount = State.AlignCount + 1
    if State.AlignCount < (CONFIG.AutoCast.AlignFrames or 1) then return end
    
    -- Wall check opcional
    if CONFIG.AutoCast.WallCheck then
        local myHRP = getHRP(LocalPlayer.Character)
        if myHRP then
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            local ignore = {LocalPlayer.Character}
            if State.LockedTarget.Character then table.insert(ignore, State.LockedTarget.Character) end
            params.FilterDescendantsInstances = ignore
            if Workspace:Raycast(myHRP.Position, targetPart.Position - myHRP.Position, params) then
                return
            end
        end
    end
    
    -- Smart order: skills que alcançam o alvo primeiro
    local order = State.SlotOrder
    if CONFIG.AutoCast.SmartOrder then
        local myPos = getHRP(LocalPlayer.Character) and getHRP(LocalPlayer.Character).Position
        local targetPos = targetPart.Position
        local dist = myPos and targetPos and (myPos - targetPos).Magnitude or 999
        order = {}
        for _, slot in ipairs(State.SlotOrder) do
            local ready = not State.SlotBusy[slot] and (State.SlotCD[slot] or 0) <= now
            local range = State.SlotRange[slot] or 999
            if ready then
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
        if key and not State.SlotBusy[slot] and (State.SlotCD[slot] or 0) <= now then
            State.SlotCD[slot] = now + 3.5
            State.NextAutoCast = now + CONFIG.AutoCast.GapTime
            pressKey(key)
            return
        end
    end
end

-- ============================================================================
-- VISUAL: CIRCLE FOV + CROSSHAIR + MARKER
-- ============================================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ApexHybrid_Visuals"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() ScreenGui.Parent = game:GetService("CoreGui") end)
if not ScreenGui.Parent then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local function new(cls, props, parent)
    local o = Instance.new(cls)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local function corner(obj, r) new("UICorner", { CornerRadius = UDim.new(0, r or CONFIG.UI.Rounding) }, obj) end

-- Circle FOV
local function createCircle()
    local c = new("Frame", {
        Name = "Apex_Circle",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        ZIndex = 0,
        Visible = CONFIG.Visual.Circle.Enabled,
    }, ScreenGui)
    
    local stroke = new("UIStroke", {
        Name = "Stroke",
        Color = CONFIG.Visual.Circle.Color,
        Thickness = CONFIG.Visual.Circle.Thickness,
        Transparency = CONFIG.Visual.Circle.Transparency,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, c)
    
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, c)
    
    if CONFIG.Visual.Circle.FillEnabled then
        c.BackgroundColor3 = CONFIG.Visual.Circle.Color
        c.BackgroundTransparency = CONFIG.Visual.Circle.FillTransparency
    end
    
    return c, stroke
end

-- Crosshair
local function createCrosshair()
    local c = new("Frame", {
        Name = "Apex_Crosshair",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        ZIndex = 10,
        Visible = CONFIG.Visual.Crosshair.Enabled,
    }, ScreenGui)
    
    local size = CONFIG.Visual.Crosshair.Size
    local gap = CONFIG.Visual.Crosshair.Gap
    local color = CONFIG.Visual.Circle.Color
    local thick = CONFIG.Visual.Crosshair.Thickness
    
    local function line(pos, sz, rot)
        local l = new("Frame", {
            BackgroundColor3 = color,
            BorderSizePixel = 0,
            Size = sz,
            Position = pos,
            Rotation = rot,
            ZIndex = 10,
        }, c)
        new("UICorner", { CornerRadius = UDim.new(0, 1) }, l)
    end
    
    line(UDim2.fromOffset(-gap - size, 0), UDim2.fromOffset(size, thick), 0)
    line(UDim2.fromOffset(gap, 0), UDim2.fromOffset(size, thick), 0)
    line(UDim2.fromOffset(0, -gap - size), UDim2.fromOffset(thick, size), 90)
    line(UDim2.fromOffset(0, gap), UDim2.fromOffset(thick, size), 90)
    
    return c
end

-- Target Marker (Highlight + Billboard)
local function clearMarker()
    if State.MarkerHL then pcall(function() State.MarkerHL:Destroy() end) end
    if State.MarkerBB then pcall(function() State.MarkerBB:Destroy() end) end
    State.MarkerHL, State.MarkerBB, State.MarkerTarget = nil, nil, nil
end

local function updateMarker()
    clearMarker()
    local plr = State.LockedTarget
    if not plr or not isAlive(plr) or not CONFIG.Visual.Marker.Enabled then return end
    local char = plr.Character
    if not char then return end
    
    -- Highlight
    local hl = new("Highlight", {
        Name = "Apex_Marker",
        Adornee = char,
        FillColor = CONFIG.Visual.Marker.Color,
        OutlineColor = CONFIG.Visual.Marker.Color,
        FillTransparency = 0.78,
        OutlineTransparency = 0,
        DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
    }, char)
    State.MarkerHL = hl
    State.MarkerTarget = plr
    
    -- Billboard
    local head = char:FindFirstChild("Head")
    if head then
        local bb = new("BillboardGui", {
            Name = "Apex_Tag",
            Adornee = head,
            Size = UDim2.fromOffset(200, 48),
            StudsOffset = Vector3.new(0, 3.5, 0),
            AlwaysOnTop = true,
        }, head)
        
        local txt = new("TextLabel", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = CONFIG.UI.BoldFont,
            TextSize = 11,
            TextColor3 = CONFIG.UI.TextColor,
            TextStrokeTransparency = 0.3,
            TextXAlignment = Enum.TextXAlignment.Center,
        }, bb)
        
        State.MarkerBB = bb
    end
end

local function markerTick()
    if State.MarkerTarget and State.MarkerBB and isAlive(State.MarkerTarget) then
        local char = State.MarkerTarget.Character
        local hum = getHumanoid(char)
        local hp = hum and math.floor(hum.Health) or 0
        local maxHp = hum and math.floor(hum.MaxHealth) or 100
        local pct = math.floor((hp / math.max(maxHp, 1)) * 100)
        
        local dist = 0
        local myHRP = getHRP(LocalPlayer.Character)
        local tHRP = getHRP(char)
        if myHRP and tHRP then dist = math.floor((tHRP.Position - myHRP.Position).Magnitude) end
        
        local bounty = getBounty(State.MarkerTarget)
        local faction = getFaction(State.MarkerTarget) or "?"
        local facColor = faction == "Pirate" and Color3.fromRGB(255, 150, 50)
            or faction == "Marine" and Color3.fromRGB(50, 140, 255)
            or CONFIG.UI.TextColor
        
        local parts = { State.MarkerTarget.DisplayName .. "  " .. pct .. "%" }
        if CONFIG.Visual.Marker.ShowDist then table.insert(parts, dist .. "m") end
        if CONFIG.Visual.Marker.ShowBounty then table.insert(parts, "$" .. bounty) end
        if CONFIG.Visual.Marker.ShowFaction then table.insert(parts, "[" .. faction .. "]") end
        
        local txt = State.MarkerBB:FindFirstChildOfClass("TextLabel")
        if txt then txt.Text = table.concat(parts, "  ·  ") end
    end
end

local function updateCircleVisual()
    if not State.CircleObj then State.CircleObj = select(1, createCircle()) end
    local circle = State.CircleObj
    if not circle then return end
    
    local radius = CONFIG.Visual.Circle.Radius
    if CONFIG.Aim.DynamicFOV then
        local camFov = Camera.FieldOfView
        local targetFov = 90
        local ratio = math.tan(math.rad(targetFov / 2)) / math.tan(math.rad(camFov / 2))
        radius = math.min(Camera.ViewportSize.X, Camera.ViewportSize.Y) * 0.5 * ratio
    end
    local diam = radius * 2
    circle.Size = UDim2.fromOffset(diam, diam)
    circle.Position = UDim2.fromScale(0.5, 0.5)
    circle.Visible = CONFIG.Visual.Circle.Enabled
    
    local stroke = circle:FindFirstChild("Stroke")
    if stroke then
        stroke.Color = CONFIG.Visual.Circle.Color
        stroke.Thickness = CONFIG.Visual.Circle.Thickness
        stroke.Transparency = CONFIG.Visual.Circle.Transparency
    end
    
    if CONFIG.Visual.Circle.FillEnabled then
        circle.BackgroundColor3 = CONFIG.Visual.Circle.Color
        circle.BackgroundTransparency = CONFIG.Visual.Circle.FillTransparency
    else
        circle.BackgroundTransparency = 1
    end
    
    -- Pulse when locked
    if CONFIG.Visual.Circle.PulseEnabled and State.LockedTarget and isAlive(State.LockedTarget) then
        local dt = RunService.RenderStepped:Wait()
        State.PulsePhase = State.PulsePhase + CONFIG.Visual.Circle.PulseSpeed * dt
        local pulse = 1 + 0.08 * math.sin(State.PulsePhase)
        circle.Size = UDim2.fromOffset(diam * pulse, diam * pulse)
    end
end

local function updateCrosshairVisual()
    if not State.CrosshairObj then State.CrosshairObj = createCrosshair() end
    if State.CrosshairObj then
        State.CrosshairObj.Visible = CONFIG.Visual.Crosshair.Enabled and CONFIG.Visual.Circle.Enabled
    end
end

-- ============================================================================
-- UI / MENU (Minimal "APEX" Draggable)
-- ============================================================================
local TZ = {
    bg = CONFIG.UI.BgColor, panel = CONFIG.UI.PanelColor, line = CONFIG.UI.BorderColor,
    txt = CONFIG.UI.TextColor, mut = CONFIG.UI.MutedColor, accent = CONFIG.UI.AccentColor,
}

local Main = new("Frame", {
    Name = "Apex_Menu",
    Size = UDim2.fromOffset(220, 150),
    BackgroundColor3 = TZ.bg,
    BorderSizePixel = 0,
    Active = true,
    Visible = true,
    ZIndex = 100,
    Selectable = true,
}, ScreenGui)
corner(Main)
new("UIStroke", { Color = TZ.line, Thickness = 1 }, Main)

-- Title bar (drag handle)
local Title = new("TextLabel", {
    Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = TZ.panel,
    Text = "  APEX",
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

-- Status line
local StatusLbl = new("TextLabel", {
    Size = UDim2.new(1, -16, 0, 20),
    Position = UDim2.fromOffset(8, 36),
    BackgroundTransparency = 1,
    Font = CONFIG.UI.Font,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Main)

local TargetLbl = new("TextLabel", {
    Size = UDim2.new(1, -16, 0, 18),
    Position = UDim2.fromOffset(8, 58),
    BackgroundTransparency = 1,
    Font = CONFIG.UI.Font,
    TextSize = 10,
    TextColor3 = TZ.mut,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "alvo: nenhum",
}, Main)

-- Config rows (sliders)
local function makeRow(label, y, getter, setter, min, max, step, fmt)
    new("TextLabel", {
        Size = UDim2.new(0.5, -4, 0, 18), Position = UDim2.fromOffset(8, y),
        BackgroundTransparency = 1, Font = CONFIG.UI.Font, TextSize = 10,
        TextColor3 = TZ.mut, TextXAlignment = Enum.TextXAlignment.Left,
        Text = label,
    }, Main)
    
    local Val = new("TextLabel", {
        Size = UDim2.new(0.25, 0, 0, 18), Position = UDim2.new(0.5, 4, 0, y),
        BackgroundTransparency = 1, Font = CONFIG.UI.BoldFont, TextSize = 10,
        TextColor3 = TZ.txt, TextXAlignment = Enum.TextXAlignment.Right,
        Text = fmt(getter()),
    }, Main)
    
    local Slider = new("TextButton", {
        Size = UDim2.new(0.25, -12, 0, 18), Position = UDim2.new(0.75, 4, 0, y),
        BackgroundColor3 = TZ.panel, Text = "", AutoButtonColor = false,
    }, Main)
    corner(Slider)
    new("UIStroke", { Color = TZ.line, Thickness = 1 }, Slider)
    
    local fill = new("Frame", {
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

makeRow("Circle Radius", 80, function() return CONFIG.Visual.Circle.Radius end, function(v) CONFIG.Visual.Circle.Radius = v end, 40, 500, 5, function(v) return v .. "px" end)
makeRow("Max Angle", 100, function() return CONFIG.Silent.MaxAngle end, function(v) CONFIG.Silent.MaxAngle = v end, 1, 20, 0.5, function(v) return v .. "°" end)
makeRow("Smooth", 120, function() return CONFIG.Aim.Smooth end, function(v) CONFIG.Aim.Smooth = v end, 0, 0.5, 0.02, function(v) return string.format("%.2f", v) end)

-- Toggle buttons
local function makeToggle(text, y, get, set, xOffset)
    local btn = new("TextButton", {
        Size = UDim2.new(0.5, -10, 0, 22), Position = UDim2.fromOffset(8 + (xOffset or 0), y),
        BackgroundColor3 = TZ.panel, Text = text .. ": " .. (get() and "ON" or "OFF"),
        Font = CONFIG.UI.BoldFont, TextSize = 10, TextColor3 = TZ.txt,
        AutoButtonColor = false,
    }, Main)
    corner(btn)
    new("UIStroke", { Color = TZ.line, Thickness = 1 }, btn)
    btn.MouseButton1Click:Connect(function()
        set(not get())
        btn.Text = text .. ": " .. (get() and "ON" or "OFF")
        btn.TextColor3 = get() and TZ.accent or TZ.txt
        saveConfig()
    end)
    return btn
end

local aimBtn = makeToggle("Aim", 144, function() return CONFIG.Aim.Enabled end, function(v) CONFIG.Aim.Enabled = v end, 0)
local autoBtn = makeToggle("Auto", 144, function() return State.AutoCastEnabled end, function(v) State.AutoCastEnabled = v autoBtn.Text = "Auto: " .. (v and "ON" or "OFF") end, 110)
local circleBtn = makeToggle("Circle", 168, function() return CONFIG.Visual.Circle.Enabled end, function(v) CONFIG.Visual.Circle.Enabled = v end, 0)
local factionBtn = makeToggle("Faction", 168, function() return CONFIG.Target.FactionCheck end, function(v) CONFIG.Target.FactionCheck = v end, 110)

local function refreshStatus()
    StatusLbl.Text = "aim: " .. (CONFIG.Aim.Enabled and "ON" or "OFF")
        .. "  ·  auto: " .. (State.AutoCastEnabled and "ON" or "OFF")
        .. "  ·  circle: " .. (CONFIG.Visual.Circle.Enabled and "ON" or "OFF")
    StatusLbl.TextColor3 = CONFIG.Aim.Enabled and TZ.accent or TZ.mut
end

local function refreshTargetUI()
    TargetLbl.Text = State.LockedTarget and ("alvo: " .. State.LockedTarget.DisplayName .. " [" .. (getFaction(State.LockedTarget) or "?") .. "]") or "alvo: nenhum"
    TargetLbl.TextColor3 = State.LockedTarget and TZ.txt or TZ.mut
end

-- FAB to reopen
local Fab = new("TextButton", {
    Size = UDim2.fromOffset(30, 30), Position = UDim2.new(0, 8, 0.5, -15),
    BackgroundColor3 = TZ.bg, Text = "APEX", Font = CONFIG.UI.BoldFont,
    TextSize = 10, TextColor3 = TZ.accent, Visible = false,
}, ScreenGui)
corner(Fab, 15)
new("UIStroke", { Color = TZ.line, Thickness = 1 }, Fab)
Fab.MouseButton1Click:Connect(function()
    State.MenuOpen = true Main.Visible = true Fab.Visible = false
end)

local function applyUIPosition()
    local vp = Camera and Camera.ViewportSize or Vector2.new(1920, 1080)
    local pos = CONFIG.UI.Position
    if pos == "TopLeft" then Main.Position = UDim2.fromOffset(16, 16)
    elseif pos == "TopRight" then Main.Position = UDim2.fromOffset(vp.X - 236, 16)
    elseif pos == "BottomLeft" then Main.Position = UDim2.fromOffset(16, vp.Y - 166)
    elseif pos == "BottomRight" then Main.Position = UDim2.fromOffset(vp.X - 236, vp.Y - 166) end
end

-- ============================================================================
-- INPUT HANDLER (Unificado)
-- ============================================================================
local SkillSet = {}
for _, k in ipairs(CONFIG.Keys.SkillKeys) do SkillSet[k] = true end

track(UserInput.InputBegan:Connect(function(input, gpe)
    local it = input.UserInputType
    
    -- Skills (hold = aim assist ativo)
    if it == Enum.UserInputType.Keyboard and SkillSet[input.KeyCode] then
        State.HeldSkills = State.HeldSkills + 1
        if not State.LockedTarget then
            local best = getBestTarget()
            if best then State.LockedTarget = best.player refreshTargetUI() updateMarker() end
        end
        return
    end
    
    -- Mouse buttons
    if it == Enum.UserInputType.MouseButton4 then cycleTarget() return end
    if it == Enum.UserInputType.MouseButton5 then
        State.MenuOpen = not State.MenuOpen
        Main.Visible = State.MenuOpen
        Fab.Visible = not State.MenuOpen
        return end
    
    if gpe then return end
    
    -- RightShift = Aim Toggle
    if input.KeyCode == CONFIG.Keys.AimToggle then
        CONFIG.Aim.Enabled = not CONFIG.Aim.Enabled
        aimBtn.Text = "Aim: " .. (CONFIG.Aim.Enabled and "ON" or "OFF")
        refreshStatus()
        notify("Aim Assist: " .. (CONFIG.Aim.Enabled and "ON" or "OFF"))
        return
    end
    
    -- RightAlt = Auto-Cast Toggle
    if input.KeyCode == CONFIG.Keys.AutoToggle then
        if State.InputOK == false then notify("VIM indisponível") return end
        State.AutoCastEnabled = not State.AutoCastEnabled
        autoBtn.Text = "Auto: " .. (State.AutoCastEnabled and "ON" or "OFF")
        refreshStatus()
        notify("Auto-Cast: " .. (State.AutoCastEnabled and "ON" or "OFF"))
        return
    end
    
    -- RightCtrl = Menu Toggle
    if input.KeyCode == CONFIG.Keys.MenuToggle then
        State.MenuOpen = not State.MenuOpen
        Main.Visible = State.MenuOpen
        Fab.Visible = not State.MenuOpen
        return
    end
    
    -- Delete = Unload
    if input.KeyCode == CONFIG.Keys.Unload then cleanup() return end
    
    -- G = Cycle Target
    if input.KeyCode == CONFIG.Keys.CycleTarget then cycleTarget() return end
    
    -- R = Soru
    if input.KeyCode == CONFIG.Keys.Soru then startSoru() return end
end))

track(UserInput.InputEnded:Connect(function(input)
    if SkillSet[input.KeyCode] and State.HeldSkills > 0 then
        State.HeldSkills = State.HeldSkills - 1
    end
end))

-- ============================================================================
// CAMERA ASSIST (RenderStepped - High Priority)
// ============================================================================
local function cameraAssist(dt)
    if not CONFIG.Aim.Enabled or State.Unloaded then return end
    if State.HeldSkills == 0 and not State.AutoCastEnabled then return end
    if not State.LockedTarget or not isAlive(State.LockedTarget) then return end
    
    local targetPart = getHead(State.LockedTarget.Character) or getHRP(State.LockedTarget.Character)
    if not targetPart then return end
    
    -- Verifica se ainda está no FOV e ângulo
    if not inFOVCircle(targetPart.Position) then
        State.LockedTarget = nil
        clearMarker()
        refreshTargetUI()
        return
    end
    
    local err = angleTo(targetPart.Position)
    if err > CONFIG.Aim.MaxAngle then return end
    
    -- Camera assist suave (exponential)
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local desired = CFrame.lookAt(cam.CFrame.Position, targetPart.Position)
    local dot = cam.CFrame.LookVector:Dot((targetPart.Position - cam.CFrame.Position).Unit)
    if dot > 0.9995 then return end -- já alinhado
    
    if CONFIG.Aim.Smooth > 0 then
        local alpha = 1 - math.exp(-CONFIG.Aim.Smooth * dt)
        cam.CFrame = cam.CFrame:Lerp(desired, alpha)
    else
        cam.CFrame = desired
    end
    
    -- Lock mouse se configurado
    if CONFIG.Aim.LockMouse then
        UserInput.MouseBehavior = Enum.MouseBehavior.LockCenter
    end
end

-- ============================================================================
// MAIN LOOP (Heartbeat)
// ============================================================================
track(RunService.Heartbeat:Connect(function(dt)
    if State.Unloaded then return end
    local now = os.clock()
    
    -- Target picker (10 Hz)
    if now - (State._tickTarget or 0) > 0.1 then
        State._tickTarget = now
        if State.LockedTarget and not (isAlive(State.LockedTarget) and inFOVCircle(getHRP(State.LockedTarget.Character) and getHRP(State.LockedTarget.Character).Position or Vector3.new())) then
            State.LockedTarget = nil
            clearMarker()
            refreshTargetUI()
        end
        if not State.LockedTarget then
            local best = getBestTarget()
            if best then State.LockedTarget = best.player refreshTargetUI() updateMarker() end
        else
            refreshTargetUI()
        end
    end
    
    -- Target cache update (ReadPlayerData)
    if now - (State._tickCache or 0) > (1 / CONFIG.Target.ReadPlayerDataHz) then
        State._tickCache = now
        updateTargetCache()
        updateSlotRanges()
    end
    
    -- Marker + Circle + Crosshair (Visual.Marker.UpdateRate Hz)
    if now - (State._tickVisual or 0) > (1 / CONFIG.Visual.Marker.UpdateRate) then
        State._tickVisual = now
        markerTick()
        updateCircleVisual()
        updateCrosshairVisual()
    end
    
    -- Soru step
    soruStep(dt)
    
    -- Auto-cast
    autoCastTick()
    
    saveConfig()
end))

-- Camera Assist no RenderStepped (prioridade Camera + 1)
RunService:BindToRenderStep("Apex_CameraAssist", Enum.RenderPriority.Camera.Value + 1, cameraAssist)

-- ============================================================================
// CLEANUP / UNLOAD
// ============================================================================
function cleanup()
    if State.Unloaded then return end
    State.Unloaded = true
    
    pcall(function() RunService:UnbindFromRenderStep("Apex_CameraAssist") end)
    for _, c in ipairs(State.Connections) do pcall(function() c:Disconnect() end) end
    State.Connections = {}
    
    -- Restore character state
    pcall(function()
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum:ChangeState(Enum.HumanoidStateType.Running) end
        local cam = Workspace.CurrentCamera
        if cam then cam.CameraType = Enum.CameraType.Custom end
        UserInput.MouseBehavior = Enum.MouseBehavior.Default
    end)
    
    clearMarker()
    if State.CircleObj then pcall(function() State.CircleObj:Destroy() end) end
    if State.CrosshairObj then pcall(function() State.CrosshairObj:Destroy() end) end
    pcall(function() ScreenGui:Destroy() end)
    
    _G.ApexHybrid = nil
    notify("Unloaded")
end

-- ============================================================================
// INIT
// ============================================================================
loadConfig()
resolveSkillSlots()
hookBindables()
loadFruitSkills()
initRemotes()
initTeleportFix()

installSilentAimHook()

-- Visual init
State.CircleObj = select(1, createCircle())
State.CrosshairObj = createCrosshair()
updateCircleVisual()
updateCrosshairVisual()

applyUIPosition()
refreshStatus()
refreshTargetUI()

notify("APEX HYBRID carregado")
notify("RightShift=Aim | RightAlt=Auto | RightCtrl=Menu | Delete=Unload | G=Cycle | R=Soru | MB4/MB5=Menu")

_G.ApexHybrid = {
    Destroy = cleanup,
    Config = CONFIG,
    State = State,
    GetTarget = function() return State.LockedTarget end,
    SetAimEnabled = function(v) CONFIG.Aim.Enabled = v end,
    SetAutoCast = function(v) State.AutoCastEnabled = v end,
    SetSilentEnabled = function(v) CONFIG.Silent.Enabled = v end,
}
