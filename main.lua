--[[
    S+AIMxPvP — APEX v6 (INPUT PURO)
    Aimbot nas skills + Soru guiado (R) + Menu mínimo + Lista de exclusão
    https://github.com/M4Th777/SM-AIMxPvP

    EXECUTAR VIA LOADSTRING:
    loadstring(game:HttpGet("https://raw.githubusercontent.com/M4Th777/SM-AIMxPvP/main/main.lua"))()

    v6 — INPUT PURO (VirtualInputManager) + auto-cast com cooldown real

    CONTROLES:
      RightShift   = Aimbot ON/OFF
      RightAlt     = AUTO-CAST ON/OFF (aperta a skill por você, via input nativo)
      RightControl = Abre/fecha menu
      End          = Descarregar script
      Z X C V F    = Skills (ao segurar: mira trava no alvo)
      R            = Soru guiado no alvo (respeita distância máx. real)
      MB4 / MB5    = Ciclar alvo / Ocultar menu (modo legit)

    POR QUE INPUT PURO:
      A tecla é enviada pelo VirtualInputManager, então quem trata o cast é o
      próprio jogo (MovesetClientRunner -> CommF_). O servidor valida como se
      você tivesse apertado. Nada de FireServer em remote de skill.
]]

local SCRIPT_NAME = "S+AIMxPvP"

-- ══════════════ CONFIG ══════════════
local CONFIG = {
    Keys = {
        Aim    = Enum.KeyCode.RightShift,
        Menu   = Enum.KeyCode.RightControl,
        Unload = Enum.KeyCode.End,
        Soru   = Enum.KeyCode.R,
        Auto   = Enum.KeyCode.RightAlt,
        Skills = { Enum.KeyCode.Z, Enum.KeyCode.X, Enum.KeyCode.C, Enum.KeyCode.V, Enum.KeyCode.F },
    },
    Target = {
        MaxDistance = 600,
        TeamCheck   = true,
        FriendCheck = true,
        OnlyPvP     = true,
    },
    Aim = {
        Enabled   = true,
        HitPart   = "Head",        -- "Head" | "HumanoidRootPart"
        Predict   = true,
        PredictX  = 1.0,           -- força da predição (ping x velocidade)
        MaxLead   = 6.0,           -- teto da correção em studs (evita over-shoot em strafe)
        Smooth    = 0.0,           -- 0 = snap (máxima precisão)
        Indicator = true,
    },
    Auto = {
        Enabled    = false,        -- ligado só pelo RightAlt (não assusta no farm)
        HoldTime   = 0.05,         -- quanto tempo a tecla fica pressionada
        GapTime    = 0.12,         -- intervalo mínimo entre envios
        MaxAngle   = 6.0,          -- só aperta se a mira estiver a <= X graus do alvo
        AlignFrames = 1,           -- frames alinhados exigidos antes de apertar
        CooldownFallback = 4.0,    -- cooldown usado se o jogo não informar o real
        WallCheck  = false,        -- não casta com parede na frente (pode dar falso negativo)
    },
    Soru = {
        Enabled     = true,
        MaxDistance = 45,          -- alcance real do Soru (sem ir além)
        Behind      = 3.0,         -- studs atrás do alvo
        UpOffset    = 0.0,
        Steps       = 4,           -- frames do movimento guiado (não é snap)
        Lerp        = 0.35,        -- fator por step (guiado suave, nunca TP direto)
        Cooldown    = 0.6,
    },
    Marker = {
        Enabled = true,
        Color   = Color3.fromRGB(255, 60, 60),
    },
    Persist = { Enabled = true, Path = "BF_APEX_v5.json" },
}

-- ══════════════ BOOT ══════════════
local genv = (type(getgenv) == "function") and getgenv() or _G
if genv.BF_APEX and type(genv.BF_APEX.Destroy) == "function" then
    pcall(genv.BF_APEX.Destroy)
end

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UserInput   = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Replicated  = game:GetService("ReplicatedStorage")
local StatsSvc    = game:GetService("Stats")
local Workspace   = workspace
local LocalPlayer = Players.LocalPlayer

local SkillSet = {}
for _, k in ipairs(CONFIG.Keys.Skills) do SkillSet[k] = true end

local State = {
    Locked     = nil,
    Held       = 0,
    MenuOpen   = true,
    Unloaded   = false,
    Ignore     = {},   -- UserId -> true (excluído do aimbot)
    FriendCache = {},
    Conns      = {},
    Dot        = nil,
    TickTarget = 0,
    TickList   = 0,
    LastSoru   = 0,
    SoruStep   = nil,  -- corpo em movimento guiado
    -- ── input puro / auto-cast ──
    SlotOrder  = {},   -- ordem de prioridade dos slots (1..5)
    SlotKey    = {},   -- slot -> Enum.KeyCode
    SlotCd     = {},   -- slot -> os.clock() em que fica pronto
    SlotBusy   = {},   -- slot -> true enquanto a skill está ativa
    NextPress  = 0,
    AlignCount = 0,
    KeyDown    = {},   -- KeyCode -> true se já seguramos
    InputOk    = nil,  -- nil = não testado | true/false
}

local function track(c) table.insert(State.Conns, c) return c end
local function notify(m) print("[APEX] " .. tostring(m)) end

-- ══════════════ INPUT PURO ══════════════
-- A tecla entra pelo VirtualInputManager: quem trata o cast é o jogo, não a gente.
-- Ordem de tentativa: VIM (4 args) -> VIM (3 args) -> keypress/keyrelease do executor.
local VIM = nil
do
    local ok, svc = pcall(function() return game:GetService("VirtualInputManager") end)
    if ok and svc then VIM = svc end
end

local function sendKey(key, down)
    if State.InputOk == false then
        -- já falhou de todo jeito antes; não insiste
        return false
    end
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
    notify("Input nativo indisponível — AUTO-CAST desligado (só mira).")
    CONFIG.Auto.Enabled = false
    return false
end

-- Aceita tanto { [KeyCode] = slot } quanto { {key = KeyCode, slot = n} } / array
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
            if key ~= nil and slot ~= nil then
                local kc = key
                if type(kc) == "string" then
                    kc = (Enum.KeyCode[kc]) or nil
                elseif typeof and typeof(kc) == "EnumItem" then
                    kc = kc
                end
                if kc and type(slot) == "number" then
                    out[slot] = kc
                end
            end
        end
    end

    -- fallback: binds fixos do script
    if next(out) == nil then
        for i, k in ipairs(CONFIG.Keys.Skills) do out[i] = k end
        notify("Binds dinâmicos indisponíveis — usando Z X C V F.")
    else
        notify("Binds lidos do jogo.")
    end

    local order = {}
    for slot in pairs(out) do table.insert(order, slot) end
    table.sort(order)
    State.SlotKey = out
    State.SlotOrder = order
end

-- Cooldown REAL: o jogo avisa pelo Bindable PlaySkillCooldownAnimation.
-- Sem isso, o auto-cast usa CooldownFallback e nunca dá spam.
local function normSlot(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "number" and v >= 1 and v <= 8 then return v end
    end
end

local function hookBindable(name, fn)
    local ev = Replicated:FindFirstChild("Events")
    local b = ev and ev:FindFirstChild(name)
    if b and b:IsA("BindableEvent") then
        track(b.Event:Connect(fn))
        return true
    end
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

-- Declaradas cedo; GUI e MK são preenchidos depois, antes de qualquer input do usuário
local UI = {}
local MK = { hl = nil, bb = nil, pr = nil, tx = nil }
local updateMarker
local clearMarkerSafe

notify("Iniciando...")

-- ══════════════ UTIL ══════════════
local function pingSec()
    local ok, p = pcall(function()
        return StatsSvc.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    if ok and type(p) == "number" then return math.clamp(p, 0.02, 0.5) end
    return 0.1
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

local function ally(p)
    if p == LocalPlayer then return true end
    if CONFIG.Target.TeamCheck and p.Team and LocalPlayer.Team and p.Team == LocalPlayer.Team then
        return true
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
        for _, n in ipairs({ "PvpEnabled", "IsPvP", "PvP" }) do
            local v = ls:FindFirstChild(n)
            if v and v:IsA("BoolValue") then return v.Value end
        end
    end
    return true -- fallback: não bloqueia
end

local function bountyOf(p)
    local ls = p:FindFirstChild("leaderstats")
    if ls then
        for _, n in ipairs({ "Bounty/Honor", "Bounty", "Honor" }) do
            local v = ls:FindFirstChild(n)
            if v and v:IsA("NumberValue") then return v.Value end
        end
    end
    return 0
end

local function ignored(p) return State.Ignore[tostring(p.UserId)] == true end

-- ══════════════ PERSISTÊNCIA (apenas lista de exclusão) ══════════════
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

-- ══════════════ ALVO ══════════════
local function validTargets()
    local out = {}
    local _, mr = charOf(LocalPlayer)
    if not mr then return out end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Parent and not ignored(p) then
            local _, r, u = charOf(p)
            if r then
                local d = (r.Position - mr.Position).Magnitude
                if d <= CONFIG.Target.MaxDistance and not ally(p) and pvpOn(p) then
                    table.insert(out, { p = p, d = d, u = u })
                end
            end
        end
    end
    return out
end

local function pick()
    if State.Locked and alive(State.Locked) and pvpOn(State.Locked) then return end
    local list = validTargets()
    if #list == 0 then State.Locked = nil return end
    table.sort(list, function(a, b) return (a.u.Health + a.d * 0.1) < (b.u.Health + b.d * 0.1) end)
    if State.Locked ~= list[1].p then
        State.Locked = list[1].p
        notify("Alvo: " .. State.Locked.DisplayName)
    end
end

local function cycleTarget()
    local list = validTargets()
    if #list == 0 then notify("Sem alvo válido no alcance.") return end
    local idx = 0
    if State.Locked then
        for i, t in ipairs(list) do if t.p == State.Locked then idx = i break end end
    end
    local nx = idx % #list + 1
    State.Locked = list[nx].p
    updateMarker()
    UI.refreshTarget()
    notify("Alvo: " .. State.Locked.DisplayName .. " (" .. nx .. "/" .. #list .. ")")
end

-- ══════════════ AIM (render, acima da câmera) ══════════════
-- Com AUTO ligado a mira fica sempre engajada; sem AUTO, só enquanto você segura skill.
local function aimActive()
    return CONFIG.Aim.Enabled and not State.Unloaded and (State.Held > 0 or CONFIG.Auto.Enabled)
end

-- Ponto de mira: cabeça/HRP + lead de predição limitado por MaxLead.
-- O teto importa: sem ele, alvo em strafe com ping alto gera over-shoot e a skill whiffa.
local function getAimPoint()
    if not State.Locked or not alive(State.Locked) then return nil end
    local _, r = charOf(State.Locked)
    if not r then return nil end
    local part = r
    if CONFIG.Aim.HitPart == "Head" then
        local hd = State.Locked.Character and State.Locked.Character:FindFirstChild("Head")
        if hd and hd:IsA("BasePart") then part = hd end
    end
    local pos = part.Position
    if CONFIG.Aim.Predict then
        local lead = r.AssemblyLinearVelocity * (pingSec() * CONFIG.Aim.PredictX)
        local m = lead.Magnitude
        if m > CONFIG.Aim.MaxLead and m > 0 then
            lead = lead * (CONFIG.Aim.MaxLead / m)
        end
        pos = pos + lead
    end
    return pos
end

-- Desvio angular (graus) entre a câmera e o ponto de mira
local function aimError()
    local pos = getAimPoint()
    local cam = Workspace.CurrentCamera
    if not pos or not cam then return nil end
    local d = pos - cam.CFrame.Position
    if d.Magnitude < 1e-3 then return 0 end
    return math.deg(math.acos(math.clamp(cam.CFrame.LookVector:Dot(d.Unit), -1, 1)))
end

local function aimFrame()
    if not aimActive() then return end
    local pos = getAimPoint()
    if not pos then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local des = CFrame.lookAt(cam.CFrame.Position, pos)
    if CONFIG.Aim.Smooth > 0 then
        cam.CFrame = cam.CFrame:Lerp(des, math.clamp(1 - CONFIG.Aim.Smooth, 0.05, 1))
    else
        cam.CFrame = des
    end
end
RunService:BindToRenderStep("APEX_AIM", Enum.RenderPriority.Camera.Value + 1, aimFrame)

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

    -- só aperta se a mira já convergiu: cast com câmera torta = whiff
    local err = aimError()
    if err == nil or err > CONFIG.Auto.MaxAngle then
        State.AlignCount = 0
        return
    end
    State.AlignCount = State.AlignCount + 1
    if State.AlignCount < CONFIG.Auto.AlignFrames then return end

    for _, slot in ipairs(State.SlotOrder) do
        local key = State.SlotKey[slot]
        if key and not State.SlotBusy[slot] and (State.SlotCd[slot] or 0) <= now then
            if CONFIG.Auto.WallCheck and wallBlocked() then return end
            -- trava o slot na hora; o bindable do jogo sobrescreve com o cooldown real
            State.SlotCd[slot] = now + CONFIG.Auto.CooldownFallback
            State.NextPress = now + CONFIG.Auto.GapTime
            pressKey(key)
            return
        end
    end
end


-- ══════════════ SORU (guiado, só no R, respeita alcance real) ══════════════
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
        notify("Fora do alcance do Soru (" .. math.floor(d) .. "m > " .. CONFIG.Soru.MaxDistance .. "m)")
        return
    end
    if d <= CONFIG.Soru.Behind + 1 then return end -- já está colado
    State.LastSoru = now
    -- Movimento guiado: Steps x Lerp nos próximos frames (não é TP seco)
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
    -- guia: interpola até o ponto final (sem teleporte direto)
    mr.CFrame = mr.CFrame:Lerp(dest, CONFIG.Soru.Lerp)
    mr.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    s.steps = s.steps - 1
    if s.steps <= 0 then
        mr.CFrame = dest
        fireTpFix()
        State.SoruStep = nil
    end
end

-- ══════════════ MARCADOR ══════════════
local function clearMarker()
    if MK.hl then pcall(function() MK.hl:Destroy() end) end
    if MK.bb then pcall(function() MK.bb:Destroy() end) end
    MK.hl, MK.bb, MK.pr, MK.tx = nil, nil, nil, nil
end
clearMarkerSafe = clearMarker
updateMarker = function()
    clearMarker()
    local p = State.Locked
    if not p or not alive(p) or not CONFIG.Marker.Enabled then return end
    local c = p.Character
    if not c then return end
    local hl = Instance.new("Highlight")
    hl.Name = "APEX_Mark"
    hl.Adornee = c
    hl.FillColor = CONFIG.Marker.Color
    hl.OutlineColor = CONFIG.Marker.Color
    hl.FillTransparency = 0.75
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = c
    MK.hl = hl
    MK.pr = p
    local hd = c:FindFirstChild("Head")
    if hd then
        local bb = Instance.new("BillboardGui")
        bb.Name = "APEX_Tag"
        bb.Adornee = hd
        bb.Size = UDim2.fromOffset(140, 36)
        bb.StudsOffset = Vector3.new(0, 3, 0)
        bb.AlwaysOnTop = true
        bb.Parent = hd
        local tx = Instance.new("TextLabel")
        tx.Size = UDim2.new(1, 0, 1, 0)
        tx.BackgroundTransparency = 1
        tx.Font = Enum.Font.GothamBold
        tx.TextSize = 12
        tx.TextColor3 = CONFIG.Marker.Color
        tx.TextStrokeTransparency = 0.4
        tx.Parent = bb
        MK.bb = bb
        MK.tx = tx
    end
end
local function markerTick()
    if MK.pr and MK.tx and alive(MK.pr) then
        local _, _, u = charOf(MK.pr)
        MK.tx.Text = string.format("%s  %d%%", MK.pr.DisplayName or MK.pr.Name,
            math.floor((u.Health / math.max(u.MaxHealth, 1)) * 100))
    end
end

-- ══════════════ DOT (pontinho, opcional) ══════════════
local function dotTick()
    if not CONFIG.Aim.Indicator or not aimActive() or not State.Locked or not alive(State.Locked) then
        if State.Dot then State.Dot.Visible = false end
        return
    end
    if not State.Dot then
        local d = Instance.new("Frame")
        d.Name = "APEX_Dot"
        d.Size = UDim2.fromOffset(5, 5)
        d.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        d.BorderSizePixel = 0
        d.Visible = false
        d.ZIndex = 9
        local cn = Instance.new("UICorner")
        cn.CornerRadius = UDim.new(1, 0)
        cn.Parent = d
        d.Parent = ScreenGui
        State.Dot = d
    end
    local _, r = charOf(State.Locked)
    local cam = Workspace.CurrentCamera
    if not r or not cam then State.Dot.Visible = false return end
    local v, on = cam:WorldToViewportPoint(r.Position)
    State.Dot.Visible = on and v.Z > 0
    if State.Dot.Visible then State.Dot.Position = UDim2.fromOffset(v.X - 2, v.Y - 2) end
end

-- ══════════════ GUI (mínima: status + alvo + exclusão) ══════════════
local TZ = {
    bg    = Color3.fromRGB(10, 10, 12),
    panel = Color3.fromRGB(18, 18, 22),
    line  = Color3.fromRGB(40, 40, 48),
    txt   = Color3.fromRGB(235, 235, 240),
    mut   = Color3.fromRGB(120, 120, 130),
    on    = Color3.fromRGB(90, 200, 130),
    off   = Color3.fromRGB(200, 90, 90),
}

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "APEX_v5"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
do
    local ok, c = pcall(function() return game:GetService("CoreGui") end)
    if ok and c then
        local w = pcall(function() ScreenGui.Parent = c end)
        if w and ScreenGui.Parent == c then notify("GUI: CoreGui") end
    end
    if not ScreenGui.Parent then
        local pg = LocalPlayer:WaitForChild("PlayerGui", 10)
        if pg then
            ScreenGui.Parent = pg
            notify("GUI: PlayerGui")
        else
            notify("ERRO: não foi possível parentar a GUI!")
        end
    end
end

local function New(cls, pr, par)
    local o = Instance.new(cls)
    for k, v in pairs(pr) do o[k] = v end
    o.Parent = par
    return o
end
local function corner(o, r) New("UICorner", { CornerRadius = UDim.new(0, r or 6) }, o) end

local Main = New("Frame", {
    Name = "Main",
    Size = UDim2.fromOffset(260, 300),
    Position = UDim2.new(0.5, -130, 0.5, -150),
    BackgroundColor3 = TZ.bg,
    BorderSizePixel = 0,
    Active = true,
    Visible = true,
}, ScreenGui)
corner(Main, 10)
New("UIStroke", { Color = TZ.line, Thickness = 1 }, Main)

-- título + drag
local Title = New("TextLabel", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundColor3 = TZ.panel,
    Text = "  " .. SCRIPT_NAME,
    Font = Enum.Font.GothamBold,
    TextSize = 13,
    TextColor3 = TZ.txt,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Main)
corner(Title, 10)
New("UIStroke", { Color = TZ.line, Thickness = 1 }, Title)
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

-- STATUS: aimbot on/off + alvo
local AimLbl = New("TextLabel", {
    Size = UDim2.new(1, -16, 0, 22),
    Position = UDim2.fromOffset(8, 36),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Main)
local TargetLbl = New("TextLabel", {
    Size = UDim2.new(1, -16, 0, 20),
    Position = UDim2.fromOffset(8, 58),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = TZ.mut,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "alvo: nenhum",
}, Main)

function UI.refreshAim()
    AimLbl.Text = "aim: " .. (CONFIG.Aim.Enabled and "ON" or "OFF")
        .. "  ·  auto: " .. (CONFIG.Auto.Enabled and "ON" or "OFF")
    if not CONFIG.Aim.Enabled then
        AimLbl.TextColor3 = TZ.off
    elseif CONFIG.Auto.Enabled then
        AimLbl.TextColor3 = TZ.on
    else
        AimLbl.TextColor3 = TZ.txt
    end
end
function UI.refreshTarget()
    TargetLbl.Text = State.Locked and ("alvo: " .. State.Locked.DisplayName) or "alvo: nenhum"
    TargetLbl.TextColor3 = State.Locked and TZ.txt or TZ.mut
end
UI.refreshAim()
UI.refreshTarget()

-- LISTA DE EXCLUSÃO (clique = excluir/incluir do aimbot)
local ListTitle = New("TextLabel", {
    Size = UDim2.new(1, -16, 0, 16),
    Position = UDim2.fromOffset(8, 82),
    BackgroundTransparency = 1,
    Text = "— EXCLUIR DO AIMBOT (clique) —",
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    TextColor3 = TZ.mut,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Main)

local PList = New("ScrollingFrame", {
    Size = UDim2.new(1, -16, 1, -104),
    Position = UDim2.fromOffset(8, 100),
    BackgroundColor3 = TZ.panel,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = TZ.line,
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
}, Main)
corner(PList, 6)
New("UIStroke", { Color = TZ.line, Thickness = 1 }, PList)
New("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, PList)

State.Rows = {}
local function refreshList()
    for _, r in ipairs(State.Rows) do if r.Parent then r:Destroy() end end
    State.Rows = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Parent then
            local isA = ally(p)
            local isI = ignored(p)
            local pv = pvpOn(p)
            local _, _, u = charOf(p)
            local hp = u and math.floor(u.Health) or 0
            local col = TZ.txt
            if isI then col = TZ.off
            elseif isA then col = TZ.on end
            local tag = pv and "PvP" or "OFF"
            local row = New("TextButton", {
                Size = UDim2.new(1, 0, 0, 20),
                BackgroundColor3 = TZ.bg,
                Text = string.format("  %s%s  ·  %dHP  ·  $%d  ·  %s",
                    (isI and "[X] " or ""), p.DisplayName or p.Name, hp, bountyOf(p), tag),
                TextColor3 = col,
                Font = Enum.Font.Gotham,
                TextSize = 10,
                TextXAlignment = Enum.TextXAlignment.Left,
                AutoButtonColor = false,
            }, PList)
            corner(row, 4)
            row.MouseButton1Click:Connect(function()
                local id = tostring(p.UserId)
                State.Ignore[id] = not State.Ignore[id] or nil
                if State.Ignore[id] then
                    notify("Excluído do aimbot: " .. p.DisplayName)
                    if State.Locked == p then State.Locked = nil updateMarker() UI.refreshTarget() clearMarker() end
                else
                    State.Ignore[id] = nil
                    notify("Incluído de volta: " .. p.DisplayName)
                end
                saveCfg()
                refreshList()
            end)
            table.insert(State.Rows, row)
        end
    end
end
track(Players.PlayerAdded:Connect(function() refreshList() end))
-- Não apaga a exclusão ao sair: a lista é persistida por UserId e precisa sobreviver ao relog.
track(Players.PlayerRemoving:Connect(function() refreshList() end))

-- FAB (reabre se fechar)
local Fab = New("TextButton", {
    Size = UDim2.fromOffset(34, 34),
    Position = UDim2.new(0, 10, 0.5, -17),
    BackgroundColor3 = TZ.bg,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextColor3 = TZ.txt,
    Text = "SM",
    Visible = false,
}, ScreenGui)
corner(Fab, 17)
New("UIStroke", { Color = TZ.line, Thickness = 1 }, Fab)
Fab.MouseButton1Click:Connect(function() State.MenuOpen = true UI.updateVis() end)

function UI.updateVis()
    Main.Visible = State.MenuOpen
    Fab.Visible = not State.MenuOpen
end
UI.updateVis()

-- ══════════════ INPUT ══════════════
track(UserInput.InputBegan:Connect(function(input, gpe)
    local it = input.UserInputType

    -- skills passam SEMPRE (mesmo gpe=true)
    if it == Enum.UserInputType.Keyboard and SkillSet[input.KeyCode] then
        State.Held = State.Held + 1
        pick()
        return
    end

    -- botões laterais do mouse (antes do gpe: mouse lateral não é "game processed")
    if it == Enum.UserInputType.MouseButton4 then
        cycleTarget()
        return
    end
    if it == Enum.UserInputType.MouseButton5 then
        State.MenuOpen = false
        UI.updateVis()
        return
    end

    if gpe then return end

    if input.KeyCode == CONFIG.Keys.Aim then
        CONFIG.Aim.Enabled = not CONFIG.Aim.Enabled
        UI.refreshAim()
        notify("Aimbot: " .. (CONFIG.Aim.Enabled and "ON" or "OFF"))
        return
    end
    if input.KeyCode == CONFIG.Keys.Auto then
        if State.InputOk == false then
            notify("AUTO-CAST indisponível neste executor (sem VirtualInputManager).")
            return
        end
        CONFIG.Auto.Enabled = not CONFIG.Auto.Enabled
        State.AlignCount = 0
        UI.refreshAim()
        notify("Auto-cast: " .. (CONFIG.Auto.Enabled and "ON" or "OFF"))
        return
    end
    if input.KeyCode == CONFIG.Keys.Menu then
        State.MenuOpen = not State.MenuOpen
        UI.updateVis()
        return
    end
    if input.KeyCode == CONFIG.Keys.Unload then
        cleanup()
        return
    end
    if input.KeyCode == CONFIG.Keys.Soru then
        soruStart() -- soru só aqui: guiado, uma vez por aperto
        return
    end
end))

track(UserInput.InputEnded:Connect(function(input)
    if SkillSet[input.KeyCode] and State.Held > 0 then
        State.Held = State.Held - 1
    end
end))

-- ══════════════ LOOP ══════════════
track(RunService.Heartbeat:Connect(function()
    if State.Unloaded then return end
    local now = os.clock()
    if now - State.TickTarget > 0.1 then
        State.TickTarget = now
        pick()
        if State.Locked and MK.pr ~= State.Locked then updateMarker() UI.refreshTarget() end
        if not State.Locked and MK.pr then clearMarker() UI.refreshTarget() end
    end
    if now - State.TickList > 2.0 then
        State.TickList = now
        refreshList()
        markerTick()
    end
    soruFrame()
    dotTick()
    autoTick()
end))

-- ══════════════ CLEANUP ══════════════
function cleanup()
    if State.Unloaded then return end
    State.Unloaded = true
    pcall(function() RunService:UnbindFromRenderStep("APEX_AIM") end)
    for _, c in ipairs(State.Conns) do pcall(function() c:Disconnect() end) end
    clearMarker()
    if State.Dot then pcall(function() State.Dot:Destroy() end) end
    pcall(function() ScreenGui:Destroy() end)
    genv.BF_APEX = nil
    notify("Descarregado.")
end
genv.BF_APEX = { Destroy = cleanup }

refreshList()
UI.refreshAim()
UI.refreshTarget()
UI.updateVis()

-- Inicializa input puro (descobre binds do jogo e conecta sinais de cooldown real)
resolveSkillSlots()
bindSkillSignals()

notify("Carregado. RightShift=Aim | RightAlt=Auto | RightCtrl=menu | End=unload | R=Soru | MB4=ciclar | MB5=legit")
