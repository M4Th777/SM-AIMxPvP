--[[
    APEX V5 -- reliability, diagnostics and scheduling patch to V4
    Uma unica geracao: 1 ScreenGui, 1 ciclo de vida, sem duplicatas.
    Teclado apenas (zero dependencia de botoes laterais do mouse).

    BINDS
      LeftShift     = liga/desliga o aim assist
      RightControl  = abre/fecha o menu
      G             = trocar alvo
      R             = Soru guiado no alvo
      Insert        = modo legit (oculta HUD)
      Delete        = descarregar
      Z X C V F     = skills (segurar = mira engatada)

    NOTA TECNICA: isto move a CAMERA do cliente. Nao torna a skill
    teleguiada no servidor; o acerto continua validado pelo jogo.
]]

--!nocheck

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInput  = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Replicated = game:GetService("ReplicatedStorage")
local Stats      = game:GetService("Stats")
local Workspace  = workspace

local LocalPlayer = Players.LocalPlayer

-- guard de reentrada: derruba QUALQUER instancia anterior antes de recomecar.
-- roda de forma diferida para nao interferir no estado do script novo.
local PREV = nil
do
    local env = (type(getgenv) == "function") and getgenv() or _G
    PREV = env.APEX
end

-- ============================================================================
-- CONFIG
-- ============================================================================
local CFG = {
    Aim = {
        Enabled     = true,
        Smooth      = 0.0,      -- 0 = snap | >0 = suavizacao exponencial
        FOVRadius   = 200,      -- raio quando FullViewportFOV=false
        FullViewportFOV = true, -- cobertura da viewport; filtro angular continua independente
        -- dois parametros distintos, de proposito:
        AcquisitionAngle  = 30, -- angulo maximo p/ ENTRAR em rastreamento (graus)
        TrackingTolerance = 45, -- angulo maximo p/ PERMANECER rastreando (graus)
        CameraMode  = "Always",   -- "Hold" (segurar skill) | "Always"
        Predict     = true,
        MaxLead     = 10,
        Indicator   = true,
        OcclusionGrace = 0.8,   -- s p/ tolerar oclusao antes de LOST
    },
    Target = {
        MaxDistance = 759.24,  -- perfil visual da captura
        NearOnly = true,     -- trava somente alvos proximos
        NearDistance = 196,   -- raio de aquisicao automatica, em studs
        ReleaseDistance = 666, -- perde alvo atual apenas apos ultrapassar este raio
        ManualCycleOffscreen = true,
        TeamCheck   = true,
        FriendCheck = true,
        Hysteresis  = 0.15,
        Reference   = "Camera", -- "Camera" | "Cursor"
    },
    Soru = {
        Enabled   = true,
        Distance  = 11.68,
        MaxDist   = 60,
        Threshold = 8,
        Cooldown  = 0.5,
    },
    Visual = {
        Circle    = true,
        Crosshair = false,
        Marker    = true,
        Accent    = Color3.fromRGB(255, 75, 190),
    },
    Ignore = {},
}

local SKILL_SET = {}
for _, k in ipairs({ Enum.KeyCode.Z, Enum.KeyCode.X, Enum.KeyCode.C, Enum.KeyCode.V, Enum.KeyCode.F }) do
    SKILL_SET[k] = true
end

-- ============================================================================
-- STATE
-- ============================================================================
local S = {
    Locked     = nil,
    ManualCycle = false, -- permite selecionar alvo fora do viewport via G
    -- maquina de estados explicita de rastreamento
    TrackState = "IDLE",    -- IDLE | ACQUIRING | TRACKING | OCCLUDED | LOST
    StateSince = 0,         -- timestamp da ultima transicao
    OccludedAt = 0,         -- quando entrou em OCCLUDED
    Diag       = {          -- metricas MEDIDAS (nao simuladas)
        AngularError = -1,
        UpdatedAt = 0,
        Visible = false,
        Steps = 0,
        AcquireReason = "NOT_ATTEMPTED",
        CandidateCount = 0,
        EligibleCount = 0,
    },
    RefPoint   = nil,       -- ponto de referencia unico (viewport space)
    HeldKeys   = {},
    HeldCount  = 0,
    Hidden     = false,
    Unloaded   = false,
    WasEngaged = false,
    PrevMouse  = nil,
    Conn       = {},
    Circle     = nil,
    Crosshair  = nil,
    Indicator  = nil,
    MarkerHL   = nil,
    MarkerBB   = nil,
    TickTarget = 0,
    TickList   = 0,
    LastSoru   = 0,
    Pulse      = 0,
    TickUI     = 0,
    TickDiag   = 0,
    Perf = {
        tracking = { calls = 0, totalMs = 0, peakMs = 0, lastMs = 0 },
        ui = { calls = 0, totalMs = 0, peakMs = 0, lastMs = 0 },
        diagnostics = { calls = 0, totalMs = 0, peakMs = 0, lastMs = 0 },
        indicator = { calls = 0, totalMs = 0, peakMs = 0, lastMs = 0 },
        frame = { calls = 0, totalMs = 0, peakMs = 0, lastMs = 0 },
    },
    GUI        = nil,
    Rows       = {},
}

local function track(c) table.insert(S.Conn, c) return c end
local function log(m) print("[APEX] " .. tostring(m)) end

-- Metric helper: fixed accumulators, no allocations on the hot path.
local function measure(bucket, fn)
    local start = os.clock()
    local ok, err = pcall(fn)
    local elapsed = (os.clock() - start) * 1000
    local m = S.Perf[bucket]
    m.calls = m.calls + 1
    m.lastMs = elapsed
    m.totalMs = m.totalMs + elapsed
    if elapsed > m.peakMs then m.peakMs = elapsed end
    if not ok then
        S.Diag.LastError = tostring(err)
        S.Diag.ErrorCount = (S.Diag.ErrorCount or 0) + 1
        warn("[APEX/" .. bucket .. "] " .. tostring(err))
    end
end


-- expoe o Destroy JA no inicio: se o resto do script falhar ou for recarregado,
-- o guard de reentrada consegue derrubar esta instancia e nao acumular loops
local impl = { destroy = nil }
local function destroy() if impl.destroy then impl.destroy() end end
do
    local env = (type(getgenv) == "function") and getgenv() or _G
    env.APEX = { Destroy = destroy, State = S }
end

-- ============================================================================
-- UTIL
-- ============================================================================
local function charOf(p)
    if not p then return nil end
    local c = p.Character
    if not c or not c.Parent then return nil end
    return c
end

local function hrpOf(p)
    local c = charOf(p)
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function humOf(p)
    local c = charOf(p)
    return c and c:FindFirstChildOfClass("Humanoid")
end

-- CORRIGIDO: atribui o Humanoid corretamente (antes ficava sempre nil)
local function isAlive(p)
    local h = humOf(p)
    return h ~= nil and h.Health > 0
end

local function isAlly(p)
    if p == LocalPlayer then return true end
    if CFG.Target.TeamCheck and p.Team and LocalPlayer.Team and p.Team == LocalPlayer.Team then
        return true
    end
    if CFG.Target.FriendCheck then
        local cached = S.FriendCache and S.FriendCache[p.UserId]
        if cached ~= nil then return cached end
        local ok, res = pcall(function() return LocalPlayer:IsFriendsWith(p.UserId) end)
        S.FriendCache = S.FriendCache or {}
        S.FriendCache[p.UserId] = ok and res or false
        return S.FriendCache[p.UserId]
    end
    return false
end

local function isIgnored(p) return CFG.Ignore[tostring(p.UserId)] == true end

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

local function ping()
    local ok, v = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    if ok and type(v) == "number" then return math.clamp(v, 0.02, 0.4) end
    return 0.1
end

local function cam() return Workspace.CurrentCamera end

local function angleTo(pos)
    local c = cam()
    if not c then return 180 end
    local d = pos - c.CFrame.Position
    if d.Magnitude < 0.01 then return 0 end
    return math.deg(math.acos(math.clamp(c.CFrame.LookVector:Dot(d.Unit), -1, 1)))
end

-- ── ESPACO DE COORDENADAS ────────────────────────────────────────────────
-- Um unico ponto de referencia, em espaco de VIEWPORT.
-- Cursor vem em espaco de GUI, entao descontamos o inset (GetGuiInset).
-- O circulo e desenhado a partir do MESMO ponto, convertido de volta.
local function guiInset()
    local ok, x, y = pcall(function()
        local gs = game:GetService("GuiService")
        local a, b = gs:GetGuiInset()
        return a.X, a.Y
    end)
    if ok and type(x) == "number" then return x, y end
    return 0, 0
end

local function mouseViewportPoint()
    local ok, loc = pcall(function()
        return UserInput:GetMouseLocation()
    end)
    if not ok or not loc then return nil end
    local ix, iy = guiInset()
    return Vector2.new(loc.X - ix, loc.Y - iy)
end

local function cameraCenterPoint()
    local c = cam()
    if not c then return nil end
    local vp = c.ViewportSize
    return Vector2.new(vp.X * 0.5, vp.Y * 0.5)
end

-- atualiza S.RefPoint segundo a referencia configurada
local function refreshReference()
    local mode = CFG.Target.Reference
    if mode == "Cursor" then
        S.RefPoint = mouseViewportPoint() or cameraCenterPoint()
    else
        S.RefPoint = cameraCenterPoint()
    end
    return S.RefPoint
end

local function inFOVScreen(pos)
    local c = cam()
    if not c then return false end
    local sp, onScreen = c:WorldToViewportPoint(pos)
    if not onScreen then return false end
    if CFG.Aim.FullViewportFOV then return true end
    local ref = S.RefPoint or cameraCenterPoint()
    if not ref then return false end
    return (Vector2.new(sp.X, sp.Y) - ref).Magnitude <= CFG.Aim.FOVRadius
end

-- ============================================================================
-- MAQUINA DE ESTADOS DO RASTREAMENTO
-- ============================================================================
-- IDLE -> ACQUIRING -> TRACKING -> OCCLUDED -> LOST -> IDLE
-- Regras:
--   * so ACQUIRING escolhe alvo novo
--   * TRACKING mantem identidade; reavalia so se o alvo sair da tolerancia
--   * OCCLUDED e temporario e expira em CFG.Aim.OcclusionGrace
--   * LOST devolve a IDLE apos limpar o alvo
local STATES = { IDLE = true, ACQUIRING = true, TRACKING = true, OCCLUDED = true, LOST = true }

-- forwards: a maquina de estados roda antes do modulo de marcador ser definido
local clearMarker
local drawMarker
local paintMarkerText

local function setState(new)
    if not STATES[new] or S.TrackState == new then return end
    S.TrackState = new
    S.StateSince = os.clock()
    if new == "OCCLUDED" then S.OccludedAt = S.StateSince end
    if S.RefreshDiag then S.RefreshDiag() end
end

local function clearTarget()
    S.Locked = nil
    S.ManualCycle = false
    if clearMarker then clearMarker() end
    S.Diag.AngularError = -1
    S.Diag.Visible = false
end

-- visibilidade barata: raycast sem whitelist do jogo
local function hasLineOfSight(pl)
    local myChar, myRoot = charOf(LocalPlayer), hrpOf(LocalPlayer)
    local targetRoot = hrpOf(pl)
    if not myRoot or not targetRoot then return false end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    if myChar then table.insert(ignore, myChar) end
    local tc = charOf(pl)
    if tc then table.insert(ignore, tc) end
    params.FilterDescendantsInstances = ignore
    local hit = Workspace:Raycast(myRoot.Position, targetRoot.Position - myRoot.Position, params)
    return hit == nil
end

-- ============================================================================
-- SELECAO DE ALVO
-- ============================================================================
local function effectiveMaxDistance()
    if CFG.Target.NearOnly then
        return math.min(CFG.Target.MaxDistance, CFG.Target.NearDistance)
    end
    return CFG.Target.MaxDistance
end

-- Dois limites: aquisicao de novos alvos e manutencao do alvo atual.
-- ReleaseDistance nunca ultrapassa MaxDistance nem fica abaixo de NearDistance.
local function effectiveReleaseDistance()
    if not CFG.Target.NearOnly then return CFG.Target.MaxDistance end
    return math.min(CFG.Target.MaxDistance,
        math.max(CFG.Target.NearDistance, CFG.Target.ReleaseDistance))
end

local function candidates(includeOffscreen)
    local out = {}
    local myRoot = hrpOf(LocalPlayer)
    if not myRoot then return out end

    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer and isAlive(pl) and not isIgnored(pl) and not isAlly(pl) then
            local root = hrpOf(pl)
            if root then
                local dist = (root.Position - myRoot.Position).Magnitude
                if dist <= effectiveMaxDistance() and (includeOffscreen or inFOVScreen(root.Position)) then
                    table.insert(out, { pl = pl, dist = dist, hp = (humOf(pl) or {}).Health or 0 })
                end
            end
        end
    end
    return out
end

-- Aquire: escolhe um alvo novo. Usa AcquisitionAngle como porta de entrada.
local function acquire()
    setState("ACQUIRING")
    refreshReference()          -- garante referencia valida mesmo fora do loop

    if not isAlive(LocalPlayer) then
        S.Diag.AcquireReason = "LOCAL_CHARACTER_INVALID"
        clearTarget()
        setState("IDLE")
        return
    end

    local list = candidates()
    S.Diag.CandidateCount = #list
    S.Diag.EligibleCount = 0
    if #list == 0 then
        S.Diag.AcquireReason = "NO_CANDIDATES"
        clearTarget()
        setState("IDLE")
        return
    end

    -- filtra por angulo de AQUISICAO (nao pela tolerancia de rastreamento)
    local eligible = {}
    for _, t in ipairs(list) do
        local root = hrpOf(t.pl)
        if root and angleTo(root.Position) <= CFG.Aim.AcquisitionAngle then
            table.insert(eligible, t)
        end
    end

    S.Diag.EligibleCount = #eligible
    if #eligible == 0 then
        S.Diag.AcquireReason = "ANGLE_FILTER"
        clearTarget()
        setState("IDLE")
        return
    end

    table.sort(eligible, function(a, b) return a.hp + a.dist * 0.1 < b.hp + b.dist * 0.1 end)
    S.Locked = eligible[1].pl
    S.ManualCycle = false
    S.Diag.AcquireReason = "ACQUIRED"
    S.Diag.Steps = 0
    if drawMarker then drawMarker() end
    setState("TRACKING")
end

-- Mantem: valida o alvo atual sem trocar de identidade.
local function maintain()
    local pl = S.Locked
    if not pl then setState("ACQUIRING") acquire() return end

    if not isAlive(pl) then
        clearTarget()
        setState("LOST")
        return
    end

    local root = hrpOf(pl)
    local myRoot = hrpOf(LocalPlayer)
    if not root or not myRoot then
        clearTarget()
        setState("LOST")
        return
    end

    local dist = (root.Position - myRoot.Position).Magnitude
    if dist > effectiveReleaseDistance() then
        clearTarget()
        setState("LOST")
        return
    end

    -- fora da tolerancia de RASTREAMENTO? perde
    if not S.ManualCycle and angleTo(root.Position) > CFG.Aim.TrackingTolerance then
        clearTarget()
        setState("LOST")
        return
    end

    local visible = hasLineOfSight(pl)
    S.Diag.Visible = visible
    S.Diag.AngularError = angleTo(root.Position)
    S.Diag.UpdatedAt = os.clock()
    S.Diag.Steps = S.Diag.Steps + 1

    local now = os.clock()
    if visible then
        if S.TrackState == "OCCLUDED" then
            setState("TRACKING")   -- recuperou
        end
    else
        if S.TrackState ~= "OCCLUDED" then
            setState("OCCLUDED")
        elseif now - S.OccludedAt > CFG.Aim.OcclusionGrace then
            clearTarget()
            setState("LOST")
        end
    end
end

-- avanca a maquina; chamada periodica (nao decide camera)
local function stepTracking()
    if S.Unloaded then return end
    if not CFG.Aim.Enabled or S.Hidden then
        if S.TrackState ~= "IDLE" and S.TrackState ~= "LOST" then
            clearTarget()
            setState("IDLE")
        end
        return
    end

    local st = S.TrackState
    if st == "IDLE" or st == "ACQUIRING" then
        acquire()
    elseif st == "TRACKING" or st == "OCCLUDED" then
        maintain()
    elseif st == "LOST" then
        clearTarget()
        setState("IDLE")
    end
end

-- Forward declarations acima compartilhadas com a maquina de estados.

local function cycleTarget()
    local list = candidates(CFG.Target.ManualCycleOffscreen)
    if #list == 0 then log("sem alvo dentro da distancia") return end
    table.sort(list, function(a, b)
        return a.pl.UserId < b.pl.UserId
    end)
    local idx = 0
    if S.Locked then
        for i, t in ipairs(list) do if t.pl == S.Locked then idx = i break end end
    end
    local nx = (idx % #list) + 1
    clearTarget()
    S.Locked = list[nx].pl
    S.ManualCycle = true
    log("alvo " .. nx .. "/" .. #list .. ": " .. S.Locked.DisplayName)
    if drawMarker then drawMarker() end
    setState("TRACKING")   -- ciclo manual entra direto em rastreamento
end

-- ============================================================================
-- SORU
-- ============================================================================
local function soru()
    if not CFG.Soru.Enabled or not S.Locked or not isAlive(S.Locked) then return end
    local myRoot = hrpOf(LocalPlayer)
    local tRoot = hrpOf(S.Locked)
    if not myRoot or not tRoot then return end

    local now = os.clock()
    if now - S.LastSoru < CFG.Soru.Cooldown then return end

    local dist = (tRoot.Position - myRoot.Position).Magnitude
    if dist > CFG.Soru.MaxDist then log("soru fora de alcance") return end
    if dist < CFG.Soru.Threshold then log("soru: ja perto") return end

    S.LastSoru = now
    local dest = tRoot.CFrame * CFrame.new(0, 0, CFG.Soru.Distance)
    myRoot.CFrame = dest
    myRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)

    pcall(function()
        local rem = Replicated:FindFirstChild("Remotes")
        local fix = rem and rem:FindFirstChild("CheckTeleportGlitchFix")
        if fix and fix:IsA("RemoteEvent") then fix:FireServer() end
    end)
end

-- ============================================================================
-- HELPERS DE UI (definidos ANTES do uso)
-- ============================================================================
local function new(class, props, parent)
    local o = Instance.new(class)
    if props then
        for k, v in pairs(props) do o[k] = v end
    end
    if parent then o.Parent = parent end
    return o
end

local function corner(obj, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = obj
    return c
end

local function stroke(obj, color, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color
    s.Thickness = thickness or 1
    s.Parent = obj
    return s
end

-- ============================================================================
-- HUD (circulo + crosshair)
-- ============================================================================
local function makeCircle()
    local f = new("Frame", {
        Name = "FOV",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Visible = CFG.Visual.Circle,
        Active = false,
        ZIndex = 2,
    })
    local s = Instance.new("UIStroke")
    s.Name = "Ring"
    s.Color = CFG.Visual.Accent
    s.Thickness = 1.5
    s.Transparency = 0.35
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = f
    corner(f, 99999)
    return f
end

local function makeCrosshair()
    local c = new("Frame", {
        Name = "APEX_XHAIR",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(9, 9),
        Visible = CFG.Visual.Crosshair,
        Active = false,
        ZIndex = 3,
    })
    local dot = new("Frame", {
        Size = UDim2.fromOffset(3, 3),
        Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = CFG.Visual.Accent,
        BorderSizePixel = 0,
    }, c)
    corner(dot, 99999)
    return c
end

local function drawCircle()
    if not S.Circle then return end
    local c = cam()
    local d = CFG.Aim.FOVRadius * 2
    if CFG.Aim.FullViewportFOV and c then
        local v = c.ViewportSize
        d = math.ceil(math.sqrt(v.X*v.X + v.Y*v.Y))
    end
    S.Circle.Size = UDim2.fromOffset(d, d)
    S.Circle.Visible = CFG.Visual.Circle and not S.Hidden

    -- ancora o circulo no MESMO ponto usado na aquisicao
    local ref = S.RefPoint
    if ref then
        local ix, iy = guiInset()          -- volta para espaco de GUI
        S.Circle.Position = UDim2.fromOffset(ref.X + ix, ref.Y + iy)
    end

    local ring = S.Circle:FindFirstChild("Ring")
    if ring then ring.Color = CFG.Visual.Accent end
end

-- ============================================================================
-- MARCADOR
-- ============================================================================
local function makeIndicator()
    local d = new("Frame", {
        Name = "APEX_IND",
        Size = UDim2.fromOffset(6, 6),
        BackgroundColor3 = CFG.Visual.Accent,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 5,
    })
    corner(d, 99999)
    return d
end

local function updateIndicator()
    if not S.Indicator then return end
    if not CFG.Aim.Indicator or S.Hidden or not S.Locked or not isAlive(S.Locked) then
        S.Indicator.Visible = false
        return
    end
    local root = hrpOf(S.Locked)
    local c = cam()
    if not root or not c then S.Indicator.Visible = false return end
    local sp, onScreen = c:WorldToViewportPoint(root.Position)
    if onScreen and sp.Z > 0 then
        S.Indicator.Position = UDim2.fromOffset(math.floor(sp.X) - 3, math.floor(sp.Y) - 3)
        S.Indicator.Visible = true
    else
        S.Indicator.Visible = false
    end
end

clearMarker = function()
    if S.MarkerHL then pcall(function() S.MarkerHL:Destroy() end) end
    if S.MarkerBB then pcall(function() S.MarkerBB:Destroy() end) end
    S.MarkerHL, S.MarkerBB = nil, nil
end

paintMarkerText = function()
    if not S.Locked or not S.MarkerBB then return end
    local h = humOf(S.Locked)
    if not h then return end
    local tx = S.MarkerBB:FindFirstChildOfClass("TextLabel")
    if not tx then return end
    local pct = math.floor((h.Health / math.max(h.MaxHealth, 1)) * 100)
    tx.Text = string.format("%s  %d%%  $%d", S.Locked.DisplayName, pct, bountyOf(S.Locked))
end

drawMarker = function()
    clearMarker()
    if not CFG.Visual.Marker or S.Hidden or not S.Locked or not isAlive(S.Locked) then return end
    local ch = charOf(S.Locked)
    if not ch then return end

    local hl = new("Highlight", {
        Name = "APEX_MARK",
        Adornee = ch,
        FillColor = CFG.Visual.Accent,
        OutlineColor = CFG.Visual.Accent,
        FillTransparency = 0.8,
        OutlineTransparency = 0,
        DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
    }, ch)
    S.MarkerHL = hl

    -- billboard de informacoes (criado junto, para paintMarkerText ter alvo)
    local headPart = ch:FindFirstChild("Head")
    if headPart then
        local bb = new("BillboardGui", {
            Name = "APEX_TAG",
            Adornee = headPart,
            Size = UDim2.fromOffset(190, 34),
            StudsOffset = Vector3.new(0, 3, 0),
            AlwaysOnTop = true,
        }, headPart)
        new("TextLabel", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 11,
            TextColor3 = CFG.Visual.Accent,
            TextStrokeTransparency = 0.4,
            TextXAlignment = Enum.TextXAlignment.Center,
            Text = "",
        }, bb)
        S.MarkerBB = bb
    end
    paintMarkerText()
end

-- ============================================================================
-- MENU
-- ============================================================================
local TZ = {
    bg = Color3.fromRGB(10, 10, 16),
    panel = Color3.fromRGB(18, 18, 28),
    line = Color3.fromRGB(90, 45, 170),
    txt = Color3.fromRGB(245, 245, 255),
    muted = Color3.fromRGB(170, 170, 190),
    accent = CFG.Visual.Accent,
}

local function toggleRow(parent, label, tableRef, key, onChange)
    local row = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundColor3 = TZ.panel,
        Text = "",
        AutoButtonColor = false,
    }, parent)
    corner(row, 5)

    new("TextLabel", {
        Size = UDim2.new(1, -48, 1, 0),
        Position = UDim2.fromOffset(8, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = TZ.txt,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = label,
    }, row)

    local pill = new("Frame", {
        Size = UDim2.fromOffset(30, 15),
        Position = UDim2.new(1, -38, 0.5, -7),
        BackgroundColor3 = tableRef[key] and TZ.accent or Color3.fromRGB(54, 43, 77),
    }, row)
    corner(pill, 99999)

    local knob = new("Frame", {
        Size = UDim2.fromOffset(11, 11),
        Position = tableRef[key] and UDim2.new(1, -13, 0.5, -5) or UDim2.new(0, 2, 0.5, -5),
        BackgroundColor3 = Color3.new(1, 1, 1),
    }, pill)
    corner(knob, 99999)

    row.MouseButton1Click:Connect(function()
        tableRef[key] = not tableRef[key]
        local on = tableRef[key]
        pill.BackgroundColor3 = on and TZ.accent or Color3.fromRGB(54, 43, 77)
        knob.Position = on and UDim2.new(1, -13, 0.5, -5) or UDim2.new(0, 2, 0.5, -5)
        if onChange then onChange(on) end
    end)
    return row
end

local function sliderRow(parent, label, tableRef, key, minV, maxV, suffix, onChange)
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 40),
        BackgroundTransparency = 1,
    }, parent)

    local valueLbl = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        Position = UDim2.fromOffset(6, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = TZ.accent,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = label,
    }, row)

    local numLbl = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 13),
        Position = UDim2.fromOffset(6, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = TZ.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local bar = new("Frame", {
        Size = UDim2.new(0.92, 0, 0, 4),
        Position = UDim2.new(0.04, 0, 0, 30),
        BackgroundColor3 = TZ.line,
    }, row)
    corner(bar, 99999)

    local fill = new("Frame", {
        Size = UDim2.new((tableRef[key] - minV) / (maxV - minV), 0, 1, 0),
        BackgroundColor3 = TZ.accent,
    }, bar)
    corner(fill, 99999)

    local function refresh()
        numLbl.Text = string.format("%.2f", tableRef[key]) .. (suffix or "")
        fill.Size = UDim2.new((tableRef[key] - minV) / (maxV - minV), 0, 1, 0)
    end
    refresh()

    local dragging = false
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true end
    end)
    track(UserInput.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end))
    track(UserInput.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local a = math.clamp((i.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
            tableRef[key] = minV + (maxV - minV) * a
            refresh()
            if onChange then onChange(tableRef[key]) end
        end
    end))
    return row
end

function buildUI()
    if S.GUI then return end

    local gui = new("ScreenGui", {
        Name = "Sofia_HUD",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    S.GUI = gui

    local parented = pcall(function() gui.Parent = LocalPlayer:WaitForChild("PlayerGui", 10) end)
    if not parented or not gui.Parent then
        local ok2 = pcall(function() gui.Parent = game:GetService("CoreGui") end)
        if not ok2 then log("FALHA: sem parent para a GUI") return end
    end

    S.Circle = makeCircle()
    S.Circle.Parent = gui
    drawCircle()

    S.Crosshair = makeCrosshair()
    S.Crosshair.Parent = gui

    S.Indicator = makeIndicator()
    S.Indicator.Parent = gui

    local main = new("Frame", {
        Size = UDim2.fromOffset(240, 300),
        Position = UDim2.new(0.5, -120, 0.5, -150),
        BackgroundColor3 = TZ.bg,
        BorderSizePixel = 0,
        Active = true,
    }, gui)
    corner(main, 10)
    stroke(main, Color3.fromRGB(140, 82, 255), 1)

    local title = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundColor3 = TZ.panel,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = TZ.accent,
        Text = "  ソフィア",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, main)
    corner(title, 10)

    -- arrastar
    local dragging, dragStart, startPos
    title.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = i.Position
            startPos = main.Position
        end
    end)
    track(UserInput.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local d = i.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    track(UserInput.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end))

    -- abas
    local tabBar = new("Frame", {
        Size = UDim2.new(1, -16, 0, 20),
        Position = UDim2.fromOffset(8, 30),
        BackgroundTransparency = 1,
    }, main)
    local tabLayout = new("UIListLayout", {
        Padding = UDim.new(0, 4),
        FillDirection = Enum.FillDirection.Horizontal,
    }, tabBar)

    local pages = {}
    local tabButtons = {}
    local current = nil

    local function showPage(name)
        if current == name then return end
        current = name
        for n, page in pairs(pages) do
            page.Visible = (n == name)
        end
        for n, btn in pairs(tabButtons) do
            btn.BackgroundColor3 = (n == name) and Color3.fromRGB(140, 82, 255) or TZ.panel
            btn.TextColor3 = (n == name) and Color3.fromRGB(10, 10, 16) or TZ.txt
        end
        if S.RefreshDiag then S.RefreshDiag() end
    end

    local function makeTab(name, label, order)
        local btn = new("TextButton", {
            Size = UDim2.new(0, 70, 1, 0),
            BackgroundColor3 = TZ.panel,
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextColor3 = TZ.txt,
            Text = label,
            AutoButtonColor = false,
            LayoutOrder = order,
        }, tabBar)
        corner(btn, 4)
        btn.MouseButton1Click:Connect(function() showPage(name) end)
        tabButtons[name] = btn

        local page = new("ScrollingFrame", {
            Size = UDim2.new(1, -16, 1, -84),
            Position = UDim2.fromOffset(8, 54),
            BackgroundTransparency = 1,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = TZ.line,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false,
        }, main)
        local lay = new("UIListLayout", { Padding = UDim.new(0, 3) }, page)
        pcall(function() lay.SortOrder = Enum.SortOrder.LayoutOrder end)
        pages[name] = page
        return page
    end

    -- rodape fixo (fora das paginas, nunca cortado)
    local footer = new("TextLabel", {
        Size = UDim2.new(1, -16, 0, 14),
        Position = UDim2.new(0, 8, 1, -18),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 8,
        TextColor3 = TZ.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "LShift aim · RCtrl menu · G alvo · R soru · Ins legit · Del unload",
    }, main)

    local cfgPage = makeTab("config", "CONFIG", 1)
    local playersPage = makeTab("players", "PLAYERS", 2)
    local diagPage = makeTab("diag", "DIAG", 3)

    -- status compacto no rodape da janela
    local statusBar = new("TextLabel", {
        Size = UDim2.new(1, -16, 0, 14),
        Position = UDim2.new(0, 8, 1, -34),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = TZ.accent,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "aim: ON",
    }, main)

    S.Refresh = function()
        statusBar.Text = string.format("aim: %s | %s | %s",
            CFG.Aim.Enabled and "ON" or "OFF",
            S.TrackState,
            S.Locked and S.Locked.DisplayName or "sem alvo")
        statusBar.TextColor3 = CFG.Aim.Enabled and TZ.accent or TZ.muted
    end

    toggleRow(cfgPage, "Aim assist", CFG.Aim, "Enabled", function() S.Refresh() end)
    toggleRow(cfgPage, "Predicao", CFG.Aim, "Predict")
    toggleRow(cfgPage, "Indicador", CFG.Aim, "Indicator")
    toggleRow(cfgPage, "Circulo FOV", CFG.Visual, "Circle", function() drawCircle() end)
    toggleRow(cfgPage, "Marcador", CFG.Visual, "Marker", function() drawMarker() end)
    toggleRow(cfgPage, "Soru", CFG.Soru, "Enabled")
    toggleRow(cfgPage, "Checar time", CFG.Target, "TeamCheck")
    toggleRow(cfgPage, "Checar amigos", CFG.Target, "FriendCheck")

    -- ciclos: referencia de mira e modo de camera
    local function cycleRow(page, label, tableRef, key, options, order)
        local row = new("TextButton", {
            Size = UDim2.new(1, 0, 0, 24),
            BackgroundColor3 = TZ.panel,
            Text = "",
            AutoButtonColor = false,
            LayoutOrder = order,
        }, page)
        corner(row, 5)
        new("TextLabel", {
            Size = UDim2.new(0.55, 0, 1, 0),
            Position = UDim2.fromOffset(8, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            TextColor3 = TZ.txt,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = label,
        }, row)
        local val = new("TextLabel", {
            Size = UDim2.new(0.4, 0, 1, 0),
            Position = UDim2.new(0.58, 0, 0, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 10,
            TextColor3 = TZ.accent,
            TextXAlignment = Enum.TextXAlignment.Right,
            Text = tostring(tableRef[key]),
        }, row)
        row.MouseButton1Click:Connect(function()
            local idx = 1
            for i, o in ipairs(options) do if o == tableRef[key] then idx = i break end end
            tableRef[key] = options[(idx % #options) + 1]
            val.Text = tostring(tableRef[key])
            refreshReference()
            if S.RefreshDiag then S.RefreshDiag() end
            drawCircle()
        end)
        return row
    end

    local referenceRow = cycleRow(cfgPage, "Referencia", CFG.Target, "Reference", { "Camera", "Cursor" }, 20)
    S.RefreshReferenceLabel = function()
        if referenceRow and referenceRow.Parent then
            for _, child in ipairs(referenceRow:GetChildren()) do
                if child:IsA("TextLabel") and child.TextXAlignment == Enum.TextXAlignment.Right then
                    child.Text = CFG.Target.Reference
                    break
                end
            end
        end
    end
    cycleRow(cfgPage, "Modo camera", CFG.Aim, "CameraMode", { "Hold", "Always" }, 21)
    toggleRow(cfgPage, "FOV tela inteira", CFG.Aim, "FullViewportFOV", function() drawCircle() end)
    toggleRow(cfgPage, "Somente proximos", CFG.Target, "NearOnly")
    sliderRow(cfgPage, "Distancia proxima", CFG.Target, "NearDistance", 10, 759, "st", nil)
    sliderRow(cfgPage, "Soltar alvo apos", CFG.Target, "ReleaseDistance", 20, 759, "st", nil)
    sliderRow(cfgPage, "FOV (px)", CFG.Aim, "FOVRadius", 60, 500, "px", function() drawCircle() end)
    sliderRow(cfgPage, "Suavidade", CFG.Aim, "Smooth", 0, 0.9, "", nil)
    sliderRow(cfgPage, "Angulo aquisicao", CFG.Aim, "AcquisitionAngle", 5, 90, "deg", nil)
    sliderRow(cfgPage, "Tolerancia rastreio", CFG.Aim, "TrackingTolerance", 5, 120, "deg", nil)
    sliderRow(cfgPage, "Distancia max", CFG.Target, "MaxDistance", 100, 1500, "st", nil)
    sliderRow(cfgPage, "Soru dist", CFG.Soru, "Distance", 1, 12, "st", nil)

    -- lista de jogadores em pagina propria, sem altura fixa
    local listHint = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 8,
        TextColor3 = TZ.muted,
        Text = "clique = ignorar / liberar",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, playersPage)
    listHint.LayoutOrder = 0

    S.RefreshList = function()
        for _, r in ipairs(S.Rows) do
            if r.Parent then r:Destroy() end
        end
        S.Rows = {}
        local count = 0
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= LocalPlayer then
                count = count + 1
                local ally = isAlly(pl)
                local ignored = isIgnored(pl)
                local h = humOf(pl)
                local hp = h and math.floor(h.Health) or 0

                local color = TZ.txt
                if ignored then color = Color3.fromRGB(220, 90, 90)
                elseif ally then color = Color3.fromRGB(90, 200, 130) end

                local row = new("TextButton", {
                    Size = UDim2.new(1, 0, 0, 18),
                    BackgroundColor3 = TZ.bg,
                    BackgroundTransparency = 0.35,
                    Font = Enum.Font.Gotham,
                    TextSize = 9,
                    TextColor3 = color,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    AutoButtonColor = false,
                    Text = string.format("%s%s  %dHP  $%d", ignored and "[x] " or "", pl.DisplayName, hp, bountyOf(pl)),
                }, playersPage)
                corner(row, 3)
                row.LayoutOrder = count + 10

                row.MouseButton1Click:Connect(function()
                    local id = tostring(pl.UserId)
                    if CFG.Ignore[id] then CFG.Ignore[id] = nil else CFG.Ignore[id] = true end
                    if S.Locked == pl then S.Locked = nil clearMarker() end
                    S.RefreshList()
                    S.Refresh()
                end)
                table.insert(S.Rows, row)
            end
        end
    end

    S.RefreshList()
    S.Refresh()
    drawMarker()

    -- pagina de diagnostico: metricas MEDIDAS em execucao
    local diagLabels = {}
    local function diagLine(label, order)
        local r = new("Frame", { Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1 }, diagPage)
        r.LayoutOrder = order
        new("TextLabel", {
            Size = UDim2.new(0.5, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 9,
            TextColor3 = TZ.muted,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = label,
        }, r)
        local value = new("TextLabel", {
            Size = UDim2.new(0.5, 0, 1, 0),
            Position = UDim2.new(0.5, 0, 0, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextColor3 = TZ.txt,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = "-",
        }, r)
        diagLabels[label] = value
        return value
    end

    diagLine("estado", 1)
    diagLine("alvo", 2)
    diagLine("referencia", 3)
    diagLine("visivel", 4)
    diagLine("erro angular", 5)
    diagLine("atualizado ha", 6)
    diagLine("passos", 7)

    S.RefreshDiag = function()
        local function set(label, txt, color)
            local l = diagLabels[label]
            if l then l.Text = txt l.TextColor3 = color or TZ.txt end
        end
        local stateColor = TZ.txt
        if S.TrackState == "TRACKING" then stateColor = TZ.accent
        elseif S.TrackState == "OCCLUDED" then stateColor = Color3.fromRGB(230, 190, 90)
        elseif S.TrackState == "LOST" then stateColor = Color3.fromRGB(220, 90, 90) end
        set("estado", S.TrackState, stateColor)
        set("alvo", S.Locked and S.Locked.DisplayName or "-")
        set("referencia", CFG.Target.Reference)
        set("visivel", S.Diag.Visible and "VISIVEL" or "OCLUSO")
        set("erro angular", S.Diag.AngularError >= 0 and string.format("%.1f deg", S.Diag.AngularError) or "-")
        set("atualizado ha", S.Diag.UpdatedAt > 0
            and string.format("%d ms", math.floor((os.clock() - S.Diag.UpdatedAt) * 1000)) or "-")
        set("passos", tostring(S.Diag.Steps))
    end

    showPage("config")
end

impl.destroy = function()
    if S.Unloaded then return end
    S.Unloaded = true
    -- so desvincula o render step se ainda formos o dono da API
    local env = (type(getgenv) == "function") and getgenv() or _G
    if env.APEX == nil or env.APEX.Destroy == destroy then
        pcall(function() RunService:UnbindFromRenderStep("APEX_CAM") end)
    end
    for _, c in ipairs(S.Conn) do pcall(function() c:Disconnect() end) end
    S.Conn = {}
    if clearMarker then pcall(clearMarker) end
    if S.GUI then pcall(function() S.GUI:Destroy() end) end
    S.GUI, S.Circle = nil, nil
    pcall(function()
        UserInput.MouseBehavior = Enum.MouseBehavior.Default
        UserInput.MouseIconEnabled = true
        local c = cam()
        if c then c.CameraType = Enum.CameraType.Custom end
    end)
    S.HeldKeys = {}
    S.HeldCount = 0
    S.WasEngaged = false
    if env.APEX and env.APEX.Destroy == destroy then
        env.APEX = nil
    end
    log("descarregado")
end

-- ============================================================================
-- CAMERA (render step)
-- ============================================================================
local function restoreMouse()
    pcall(function()
        UserInput.MouseBehavior = S.PrevMouse or Enum.MouseBehavior.Default
        UserInput.MouseIconEnabled = true
    end)
end

-- Decide se a camera deve seguir. Separado da maquina de estados:
-- a maquina diz QUAL alvo; aqui so dizemos SE movemos a camera.
local function shouldFollow()
    if not CFG.Aim.Enabled or S.Unloaded or S.Hidden then return false end
    if S.TrackState ~= "TRACKING" then return false end
    -- Cursor: apenas referencia de selecao; nao captura nem move a camera.
    if CFG.Target.Reference == "Cursor" then return false end
    if not S.Locked or not isAlive(S.Locked) then return false end
    if CFG.Aim.CameraMode == "Always" then return true end
    return S.HeldCount > 0        -- modo Hold
end

local function cameraStep(dt)
    if not shouldFollow() then
        if S.WasEngaged then
            S.WasEngaged = false
            restoreMouse()
        end
        return
    end

    local h = humOf(S.Locked)
    if not h then return end

    local part = S.Locked.Character:FindFirstChild("Head") or hrpOf(S.Locked)
    if not part then return end

    local err = angleTo(part.Position)
    S.Diag.AngularError = err

    -- tolerancia de RASTREAMENTO: fora disso nao puxa a camera
    if not S.ManualCycle and err > CFG.Aim.TrackingTolerance then return end

    local pos = part.Position
    if CFG.Aim.Predict then
        local root = hrpOf(S.Locked)
        if root then
            local lead = root.AssemblyLinearVelocity * ping()
            if lead.Magnitude > CFG.Aim.MaxLead then
                lead = lead.Unit * CFG.Aim.MaxLead
            end
            pos = pos + lead
        end
    end

    local c = cam()
    if not c then return end

    if not S.WasEngaged then
        S.WasEngaged = true
        pcall(function() S.PrevMouse = UserInput.MouseBehavior end)
    end

    local desired = CFrame.lookAt(c.CFrame.Position, pos)
    if CFG.Aim.Smooth > 0 then
        local alpha = 1 - math.pow(CFG.Aim.Smooth, dt * 60)
        c.CFrame = c.CFrame:Lerp(desired, math.clamp(alpha, 0.02, 1))
    else
        c.CFrame = desired
    end

    pcall(function()
        UserInput.MouseBehavior = Enum.MouseBehavior.LockCenter
        UserInput.MouseIconEnabled = false
    end)
end

-- ============================================================================
-- INPUT
-- ============================================================================
track(UserInput.InputBegan:Connect(function(input, processed)
    if SKILL_SET[input.KeyCode] then
        if not S.HeldKeys[input.KeyCode] then
            S.HeldKeys[input.KeyCode] = true
            S.HeldCount = S.HeldCount + 1
        end
        if S.TrackState == "IDLE" or S.TrackState == "LOST" then stepTracking() end
        return
    end

    if processed then return end

    -- Alt esquerdo: alterna exclusivamente a referencia Camera / Cursor.
    -- O cameraStep restaura o mouse quando Cursor deixa de acompanhar.
    if input.KeyCode == Enum.KeyCode.LeftAlt then
        CFG.Target.Reference = (CFG.Target.Reference == "Camera") and "Cursor" or "Camera"
        refreshReference()
        if CFG.Target.Reference == "Cursor" and S.WasEngaged then
            S.WasEngaged = false
            restoreMouse()
        end
        drawCircle()
        if S.Refresh then S.Refresh() end
        if S.RefreshDiag then S.RefreshDiag() end
        if S.RefreshReferenceLabel then S.RefreshReferenceLabel() end
        log("referencia " .. CFG.Target.Reference)
        return
    end

    if input.KeyCode == Enum.KeyCode.LeftShift then
        CFG.Aim.Enabled = not CFG.Aim.Enabled
        log("aim " .. (CFG.Aim.Enabled and "ON" or "OFF"))
        if S.Refresh then S.Refresh() end
        return
    end

    if input.KeyCode == Enum.KeyCode.RightControl then
        if S.GUI then S.GUI.Enabled = not S.GUI.Enabled end
        return
    end

    if input.KeyCode == Enum.KeyCode.G then
        cycleTarget()
        if S.Refresh then S.Refresh() end
        return
    end

    if input.KeyCode == Enum.KeyCode.R then
        soru()
        return
    end

    if input.KeyCode == Enum.KeyCode.Insert then
        S.Hidden = not S.Hidden
        if S.GUI then S.GUI.Enabled = not S.Hidden end
        drawCircle() drawMarker()
        return
    end

    if input.KeyCode == Enum.KeyCode.Delete then
        destroy()
        return
    end
end))

track(UserInput.InputEnded:Connect(function(input)
    if SKILL_SET[input.KeyCode] and S.HeldKeys[input.KeyCode] then
        S.HeldKeys[input.KeyCode] = nil
        S.HeldCount = math.max(0, S.HeldCount - 1)
    end
end))

-- ============================================================================
-- LOOP
-- ============================================================================
-- Scheduler: targeting (8.3 Hz), UI (4 Hz), diagnostics (2 Hz), list (0.5 Hz).
-- UI work does not execute inside the target update. Profiling records actual cost.
track(RunService.Heartbeat:Connect(function(dt)
    if S.Unloaded then return end
    local now = os.clock()
    refreshReference()

    if now - S.TickTarget >= 0.12 then
        S.TickTarget = now
        measure("tracking", function()
            local before = S.Locked
            stepTracking()
            if before ~= S.Locked then
                if clearMarker then clearMarker() end
                if drawMarker then drawMarker() end
            end
        end)
    end

    if now - S.TickUI >= 0.25 then
        S.TickUI = now
        measure("ui", function()
            if S.Refresh then S.Refresh() end
        end)
    end

    if now - S.TickDiag >= 0.5 then
        S.TickDiag = now
        measure("diagnostics", function()
            if S.RefreshDiag then S.RefreshDiag() end
        end)
    end

    if now - S.TickList >= 2 then
        S.TickList = now
        measure("ui", function()
            if S.RefreshList then S.RefreshList() end
            if paintMarkerText then paintMarkerText() end
        end)
    end

    measure("indicator", updateIndicator)
end))

-- ============================================================================
-- PROJETEIS (separado do rastreamento de camera)
-- ============================================================================
-- Interface explicita: o rastreamento apenas aponta a camera. Uma habilidade
-- homing precisa de trajetoria propria. Isto cobre projeteis que VOCE crie
-- (experiencia propria); para skills do Blox Fruits nao ha garantia, pois o
-- servidor pode recalcular a trajetoria.
local Projectile = {}
Projectile.__index = Projectile

function Projectile.new(part, opts)
    opts = opts or {}
    return setmetatable({
        part = part,
        speed = opts.speed or 120,
        turnRate = opts.turnRate or 6,
        lifetime = opts.lifetime or 3,
        homing = opts.homing ~= false,
        target = opts.target,
        born = os.clock(),
        dead = false,
    }, Projectile)
end

function Projectile:update(dt)
    if self.dead or not self.part or not self.part.Parent then
        self.dead = true
        return
    end
    if os.clock() - self.born > self.lifetime then
        self.dead = true
        return
    end

    local dir = self.part.CFrame.LookVector

    if self.homing and self.target and isAlive(self.target) then
        local root = hrpOf(self.target)
        if root then
            local goal = (root.Position - self.part.Position)
            if goal.Magnitude > 0.1 then
                local want = goal.Unit
                -- correcao limitada: nao gira mais que turnRate por segundo
                local maxTurn = math.rad(self.turnRate) * dt * 60
                local angle = math.acos(math.clamp(dir:Dot(want), -1, 1))
                if angle > maxTurn then
                    local axis = dir:Cross(want)
                    if axis.Magnitude > 1e-4 then
                        want = (CFrame.fromAxisAngle(axis.Unit, maxTurn) * dir)
                    end
                end
                dir = want
            end
        end
    end

    local step = dir * self.speed * dt
    self.part.CFrame = CFrame.lookAt(self.part.Position + step, self.part.Position + step + dir)
end

-- Controle autorizado para um ambiente proprio: o cliente so preve;
-- o servidor deve confirmar o impacto.
function Projectile.spawn(parent, origin, opts)
    local part = Instance.new("Part")
    part.Size = Vector3.new(1, 1, 2)
    part.Anchored = true
    part.CanCollide = false
    part.CFrame = CFrame.lookAt(origin, origin + Vector3.new(0, 0, -1))
    part.Parent = parent
    return Projectile.new(part, opts)
end

-- ============================================================================
-- BOOT
-- ============================================================================
buildUI()
RunService:BindToRenderStep("APEX_CAM", Enum.RenderPriority.Camera.Value + 1, cameraStep)

genv_apex = nil
if type(getgenv) == "function" then
    local env = getgenv()
    env.APEX = {
        Destroy = destroy,
        Config = CFG,
        State = S,
        Projectile = Projectile,
        Cycle = cycleTarget,
        SetTarget = function(p)
            clearTarget()
            S.Locked = p
            drawMarker()
            setState("TRACKING")
        end,
        ClearTarget = function() clearTarget() setState("IDLE") end,
        Pick = stepTracking,
        Acquire = acquire,
        GetState = function() return S.TrackState end,
        SetState = setState,
        RefPoint = function() return S.RefPoint end,
        Performance = function()
            -- Snapshot, never expose mutable counters directly.
            local out = {}
            for name, m in pairs(S.Perf) do
                out[name] = {
                    calls = m.calls,
                    lastMs = m.lastMs,
                    averageMs = m.calls > 0 and (m.totalMs / m.calls) or 0,
                    peakMs = m.peakMs,
                }
            end
            return out
        end,
        ResetPerformance = function()
            for _, m in pairs(S.Perf) do
                m.calls, m.totalMs, m.lastMs, m.peakMs = 0, 0, 0, 0
            end
        end,
        Probe = function()
            return {
                locked = S.Locked,
                tick = S.TickTarget,
                unloaded = S.Unloaded,
                conns = #S.Conn,
                held = S.HeldCount,
                acquireReason = S.Diag.AcquireReason,
                candidates = S.Diag.CandidateCount,
                eligible = S.Diag.EligibleCount,
                errorCount = S.Diag.ErrorCount or 0,
                lastError = S.Diag.LastError,
                stateSince = S.StateSince,
                lastTrackingMs = S.Perf.tracking.lastMs,
                trackState = S.TrackState,
            }
        end,
    }
end

-- so agora derruba a instancia anterior (depois de tudo registrado)
if PREV and type(PREV.Destroy) == "function" then
    pcall(PREV.Destroy)
end
PREV = nil

log("carregado | LShift aim | RCtrl menu | G alvo | R soru | Ins legit | Del unload")
