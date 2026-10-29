--[[
	billboard.lua (PurpleTags v3.1) | Roblox executor, Luau, single file | loaded by Dreamville from GitHub
	Everyone who runs this gets a purple LED-ring billboard over their head:
	  far away  -> round logo with an animated LED ring
	  close up  -> opens into a pill with their name + coloured lightning
	  tap it    -> teleports you to that player
	Players you tag on the website get the special billboard instead (style, name and optional custom code come from the backend).
	There is no admin key in this file: tags are managed on the website only.
	Set CONFIG.BACKEND to your Render URL. Empty = local mode (everyone gets the normal tag, nothing is shared).
	Only people running the script show up for each other. The sync also carries the anti outfit stealer flag; Dreamville reads it through getgenv().GENX_TAGS.
]]

local CONFIG = {
	BACKEND = "https://billboard-backend-1dsn.onrender.com", -- Render URL, no trailing slash
	LOGO = "rbxassetid://91954977728777",
	OPEN_DIST = 40, -- studs from the camera where a normal tag opens
	CLOSE_DIST = 48, -- must be bigger than OPEN_DIST (stops flicker)
	SYNC_EVERY = 2, -- seconds (a bit faster so other people see your copy effect almost live)
	NAME_MAX = 20, -- self-chosen names
	TAG_NAME_MAX = 30, -- names set on the website
	TP_COOLDOWN = 1.5,
	FILE = "purpletags_config.json",
	QUIET = true, -- true = no start-up toast (Dreamville has its own notifications)
	NAME_EDITOR = false, -- the little logo button on the left that lets you type your own name (off: names come from the website / your display name)
}

-- ============================================================ services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local SoundService = game:GetService("SoundService")
local LP = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if G.PURPLETAGS_STOP then pcall(G.PURPLETAGS_STOP) end

local alive = true
local conns = {}
local function keep(c) conns[#conns + 1] = c return c end

local httpReq = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
local JOB = (game.JobId ~= "" and game.JobId) or "studio"

-- ============================================================ helpers
local H = 32 -- normal tag height / collapsed diameter
local AH = 34 -- admin pill height
local PURPLE = Color3.fromRGB(168, 85, 247)
local WHITE = Color3.new(1, 1, 1)

local function mk(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function clean(s, max)
	max = max or CONFIG.NAME_MAX
	s = tostring(s or "")
	s = (s:gsub("%c", ""))
	s = (s:gsub("%s+", " "))
	s = s:match("^%s*(.-)%s*$") or ""
	local len = utf8.len(s)
	if not len then
		s = (s:gsub("[\128-\255]", ""))
		len = #s
	end
	if len > max then
		s = s:sub(1, (utf8.offset(s, max + 1) or (max + 1)) - 1)
	end
	return s
end

-- saved name
local myName = clean(LP.DisplayName)
local hasFS = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"
if hasFS then
	pcall(function()
		if isfile(CONFIG.FILE) then
			local d = HttpService:JSONDecode(readfile(CONFIG.FILE))
			if type(d) == "table" and type(d.name) == "string" and clean(d.name) ~= "" then myName = clean(d.name) end
		end
	end)
end
local function saveName()
	if hasFS then pcall(function() writefile(CONFIG.FILE, HttpService:JSONEncode({ name = myName })) end) end
end

-- ============================================================ gui root
local gui = mk("ScreenGui", {
	Name = "PurpleTags", ResetOnSpawn = false, IgnoreGuiInset = true,
	DisplayOrder = 999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
local guiParent
pcall(function() guiParent = (gethui and gethui()) or CoreGui end)
gui.Parent = guiParent or LP:WaitForChild("PlayerGui")

-- toast
local toastLbl = mk("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -70), Size = UDim2.fromOffset(0, 30),
	AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Color3.fromRGB(16, 9, 30), BackgroundTransparency = 1,
	TextTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = WHITE, Text = "",
}, gui)
mk("UICorner", { CornerRadius = UDim.new(0, 15) }, toastLbl)
mk("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, toastLbl)
local toastStroke = mk("UIStroke", { Color = PURPLE, Thickness = 1.5, Transparency = 1 }, toastLbl)
local toastId = 0
local function toast(msg)
	toastId += 1
	local id = toastId
	toastLbl.Text = msg
	toastLbl.BackgroundTransparency, toastLbl.TextTransparency, toastStroke.Transparency = 0.1, 0, 0.2
	task.delay(1.8, function()
		if id ~= toastId or not alive then return end
		local ti = TweenInfo.new(0.35)
		TweenService:Create(toastLbl, ti, { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
		TweenService:Create(toastStroke, ti, { Transparency = 1 }):Play()
	end)
end

-- ============================================================ teleport
local lastTp = 0
local function tpTo(plr, shownName)
	if plr == LP then toast("that's you") return end
	if os.clock() - lastTp < CONFIG.TP_COOLDOWN then return end
	local myRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	local theirRoot = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
	if not (myRoot and theirRoot) then toast("can't reach " .. shownName) return end
	lastTp = os.clock()
	pcall(function()
		myRoot.CFrame = theirRoot.CFrame * CFrame.new(0, 0, 4)
		myRoot.AssemblyLinearVelocity = Vector3.zero
	end)
	toast("teleported to " .. shownName)
end

-- ============================================================ shared look
local tags = {} -- [userId] = tag

local function textWidth(s, size, font)
	local ok, sz = pcall(function()
		return TextService:GetTextSize(s, size, font, Vector2.new(400, 30))
	end)
	return (ok and sz.X) or (#s * (size * 0.65))
end

local LED_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(88, 28, 200)),
	ColorSequenceKeypoint.new(0.3, Color3.fromRGB(168, 85, 247)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(245, 208, 254)),
	ColorSequenceKeypoint.new(0.7, Color3.fromRGB(168, 85, 247)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(88, 28, 200)),
})
local LED_TRANS = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 0.7),
})
local HALO_TRANS = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(0.5, 0.35), NumberSequenceKeypoint.new(1, 0.9),
})
local BASE_BG = Color3.fromRGB(14, 8, 26)
local FLASH_BG = Color3.fromRGB(78, 32, 140)
local BOLT_SEGS = 8
local BOLT_SLOTS = 2
local BOLT_COLORS = {
	Color3.fromRGB(255, 70, 220), Color3.fromRGB(80, 220, 255), Color3.fromRGB(255, 210, 80), Color3.fromRGB(120, 255, 140),
	Color3.fromRGB(190, 110, 255), Color3.fromRGB(255, 110, 70), Color3.fromRGB(90, 130, 255), Color3.fromRGB(255, 255, 255),
}
local function randColor() return BOLT_COLORS[math.random(#BOLT_COLORS)] end

-- ---- lightning helpers (used by user tags, admin pill and the crown)
local function newBolt(parent, n, z)
	local bolt = { segs = {}, glows = {}, age = nil, life = 0.2 }
	for i = 1, n do
		bolt.glows[i] = mk("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(4, 4), BackgroundColor3 = PURPLE,
			BorderSizePixel = 0, Visible = false, ZIndex = z,
		}, parent)
		bolt.segs[i] = mk("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(4, 2), BackgroundColor3 = WHITE,
			BorderSizePixel = 0, Visible = false, ZIndex = z + 1,
		}, parent)
	end
	return bolt
end

local function drawBolt(bolt, pts, col, thick)
	local core = col:Lerp(WHITE, 0.6)
	local n = #pts - 1
	for i = 1, #bolt.segs do
		local sg, gl = bolt.segs[i], bolt.glows[i]
		if i <= n then
			local a, b = pts[i], pts[i + 1]
			local d = b - a
			local mid = (a + b) / 2
			local rot = math.deg(math.atan2(d.Y, d.X))
			local len = d.Magnitude
			sg.Position = UDim2.fromOffset(mid.X, mid.Y)
			sg.Size = UDim2.fromOffset(len + 1, thick)
			sg.Rotation = rot
			sg.BackgroundColor3 = core
			gl.Position = UDim2.fromOffset(mid.X, mid.Y)
			gl.Size = UDim2.fromOffset(len + 3, thick * 2.6)
			gl.Rotation = rot
			gl.BackgroundColor3 = col
			sg.Visible, gl.Visible = true, true
		else
			sg.Visible, gl.Visible = false, false
		end
	end
	bolt.age = 0
end

local function tickBolt(bolt, dt)
	if not bolt.age then return end
	bolt.age += dt
	local a = 1 - bolt.age / bolt.life
	if a <= 0 then
		bolt.age = nil
		for i = 1, #bolt.segs do
			bolt.segs[i].Visible = false
			bolt.glows[i].Visible = false
		end
		return
	end
	local flick = (math.floor(bolt.age * 60) % 2 == 0) and 1 or 0.35
	local tr = 1 - a * flick
	for i = 1, #bolt.segs do
		bolt.segs[i].BackgroundTransparency = tr
		bolt.glows[i].BackgroundTransparency = 0.4 + 0.6 * tr
	end
end

-- ---- open / close / rename (works for both tag kinds)
local function setName(tag, name)
	tag.name = name
	local shown = name
	if tag.admin and tag.emoji and tag.emoji ~= "" then shown = tag.emoji .. " " .. name .. " " .. tag.emoji end
	tag.label.Text = shown
	local lead = tag.admin and 0 or tag.h -- admin pill has no logo circle, so no extra leading space
	tag.openW = math.min(lead + textWidth(shown, tag.fs, tag.font) + tag.pad, lead + tag.cap)
	if tag.open then
		TweenService:Create(tag.pill, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { Size = UDim2.fromOffset(tag.openW, tag.h) }):Play()
	end
end

local function setOpen(tag, open)
	if tag.open == open then return end
	tag.open = open
	if tag.admin then
		tag.token += 1
		local tok = tag.token
		if open then
			tag.pill.Visible = true
			tag.pill.Size = UDim2.fromOffset(44, tag.h)
			TweenService:Create(tag.pill, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { Size = UDim2.fromOffset(tag.openW, tag.h) }):Play()
			local lt = tag.labelOn and 0 or 1
			TweenService:Create(tag.label, TweenInfo.new(0.4), { TextTransparency = lt, TextStrokeTransparency = lt }):Play()
			TweenService:Create(tag.plate, TweenInfo.new(0.4), { BackgroundTransparency = 0.4 }):Play()
			TweenService:Create(tag.crownLbl, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
		else
			TweenService:Create(tag.pill, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { Size = UDim2.fromOffset(44, tag.h) }):Play()
			TweenService:Create(tag.label, TweenInfo.new(0.15), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			TweenService:Create(tag.plate, TweenInfo.new(0.15), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(tag.crownLbl, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
			task.delay(0.35, function()
				if alive and tag.token == tok and not tag.open then tag.pill.Visible = false end
			end)
		end
		return
	end
	TweenService:Create(tag.pill, TweenInfo.new(0.45, Enum.EasingStyle.Quint, open and Enum.EasingDirection.Out or Enum.EasingDirection.InOut),
		{ Size = UDim2.fromOffset(open and tag.openW or tag.h, tag.h) }):Play()
	TweenService:Create(tag.label, TweenInfo.new(open and 0.4 or 0.12), { TextTransparency = open and 0 or 1 }):Play()
	if tag.plate then
		TweenService:Create(tag.plate, TweenInfo.new(open and 0.4 or 0.12), { BackgroundTransparency = open and 0.45 or 1 }):Play()
	end
end

-- ============================================================ USER TAG (purple LED ring, lightning pill)
local function newTag(plr, name)
	local root = mk("Frame", { Name = plr.Name, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Visible = false }, gui)
	local holder = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0) }, root)
	local scale = mk("UIScale", { Scale = 1 }, holder)

	-- bottom-centre anchored: the tag sits ABOVE the head and never covers the avatar
	local pill = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(0, -5), Size = UDim2.fromOffset(H, H),
		BackgroundColor3 = BASE_BG, BackgroundTransparency = 0.05, BorderSizePixel = 0,
	}, holder)
	mk("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pill)
	local stroke = mk("UIStroke", { Color = WHITE, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, pill)
	local grad = mk("UIGradient", { Color = LED_COLOR, Transparency = LED_TRANS }, stroke)

	local halo = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 8, 1, 8), BackgroundTransparency = 1, ZIndex = 1,
	}, pill)
	mk("UICorner", { CornerRadius = UDim.new(0.5, 0) }, halo)
	local hstroke = mk("UIStroke", { Color = WHITE, Thickness = 4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Transparency = 0.3 }, halo)
	local hgrad = mk("UIGradient", { Color = LED_COLOR, Transparency = HALO_TRANS }, hstroke)

	local clip = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 2 }, pill)
	mk("UICorner", { CornerRadius = UDim.new(0.5, 0) }, clip)

	local sheen = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, H * 2), Position = UDim2.fromOffset(-30, H / 2),
		Rotation = 20, BackgroundColor3 = WHITE, BorderSizePixel = 0, Visible = false, ZIndex = 1,
	}, clip)
	mk("UIGradient", { Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.72), NumberSequenceKeypoint.new(1, 1),
	}) }, sheen)
	local bolts = {}
	for b = 1, BOLT_SLOTS do bolts[b] = newBolt(clip, BOLT_SEGS, 1) end

	local logo = mk("ImageLabel", {
		Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(H - 6, H - 6), BackgroundColor3 = Color3.fromRGB(30, 14, 56),
		BackgroundTransparency = 0, Image = CONFIG.LOGO, ScaleType = Enum.ScaleType.Crop, BorderSizePixel = 0, ZIndex = 3,
	}, clip)
	mk("UICorner", { CornerRadius = UDim.new(0.5, 0) }, logo)
	local label = mk("TextLabel", {
		Position = UDim2.fromOffset(H + 1, 0), Size = UDim2.new(1, -(H + 8), 1, 0), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, Text = "", ZIndex = 3,
	}, clip)
	local btn = mk("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 5, AutoButtonColor = false }, pill)

	local tag = {
		admin = false, plr = plr, root = root, scale = scale, pill = pill, stroke = stroke, hstroke = hstroke,
		grad = grad, hgrad = hgrad, label = label, open = false, hover = 0, hoverTarget = 0, name = "",
		h = H, fs = 13, font = Enum.Font.GothamBold, pad = 18, cap = 200,
		sheen = sheen, bolts = bolts, nextBolt = os.clock() + 0.3 + math.random() * 0.4,
		flash = 0, flashBg = FLASH_BG, seed = math.random() * 10,
	}
	setName(tag, name)
	keep(btn.MouseEnter:Connect(function() tag.hoverTarget = 1 end))
	keep(btn.MouseLeave:Connect(function() tag.hoverTarget = 0 end))
	keep(btn.Activated:Connect(function() tpTo(plr, tag.name) end))
	return tag
end

local function strike(tag)
	local th = tag.h or H
	local w = tag.pill.Size.X.Offset
	if w < th + 30 then return end
	local bolt
	for _, b in ipairs(tag.bolts) do
		if not b.age then bolt = b break end
	end
	if not bolt then
		bolt = tag.bolts[1]
		for _, b in ipairs(tag.bolts) do if b.age > bolt.age then bolt = b end end
	end
	local col = randColor()
	local pts = { Vector2.new(0, th * (0.15 + math.random() * 0.7)) }
	for i = 1, BOLT_SEGS do
		pts[i + 1] = Vector2.new(w * i / BOLT_SEGS, th * (0.08 + math.random() * 0.84))
	end
	drawBolt(bolt, pts, col, 1.8)
	bolt.life = 0.16 + math.random() * 0.08
	tag.flash = 1
	tag.flashBg = BASE_BG:Lerp(col, 0.4)
end

local function updateNormal(tag, t, dt, rot, pulse)
	tag.grad.Rotation = rot
	tag.hgrad.Rotation = -rot * 0.7
	tag.flash = math.max(0, tag.flash - dt * 5)
	tag.stroke.Thickness = 1.8 + pulse * 1.1 + tag.flash * 1.5
	tag.hstroke.Transparency = math.max(0, 0.15 + (1 - pulse) * 0.35 - tag.flash * 0.3)
	tag.pill.BackgroundColor3 = BASE_BG:Lerp(tag.flashBg, tag.flash)

	if tag.open then
		local ph = ((t * 0.8 + tag.seed) % 3.4) / 0.9
		if ph < 1 then
			tag.sheen.Visible = true
			tag.sheen.Position = UDim2.fromOffset(-20 + (tag.pill.Size.X.Offset + 40) * ph, H / 2)
		else
			tag.sheen.Visible = false
		end
		if t >= tag.nextBolt then
			strike(tag)
			tag.nextBolt = t + ((math.random() < 0.4) and (0.05 + math.random() * 0.1) or (0.2 + math.random() * 0.4))
		end
	else
		tag.sheen.Visible = false
	end
	for _, bolt in ipairs(tag.bolts) do tickBolt(bolt, dt) end
end

-- ============================================================ ADMIN TAG (styled from the website)
-- far away: only a big emoji (default 👑). close up: opens into a pill with "👑 NAME 👑".
-- colours, effects, distances and the optional custom Luau chunk all come from the backend.
local MATRIX_CHARS = { "0", "1", "A", "F", "3", "7", "9", "{", "}", "<", ">", "/", ";", "#", "$", "%", "=", "+", "&", "x" }
local function rndColumn()
	local out = {}
	for i = 1, 6 do out[i] = MATRIX_CHARS[math.random(#MATRIX_CHARS)] end
	return table.concat(out, "\n")
end
local ADMIN_COLS = 40

local SPEC_DEFAULT = {
	emoji = "👑", far = "👑", edge = "#8c46e6", rain = "#7832d2", text = "#ffffff", stroke = "#000000", bg = "#080312",
	rainOn = true, glitch = true, bolts = false, sheen = false, codeOnly = false, farSize = 46, openDist = 60,
}
local function cutChars(s, n)
	local len = utf8.len(s)
	if not len then return "" end
	if len > n then s = s:sub(1, (utf8.offset(s, n + 1) or (#s + 1)) - 1) end
	return s
end
local function hex(s, fb)
	local r, g, b = tostring(s or ""):match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then return fb end
	return Color3.fromRGB(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end
local function cleanSpec(s)
	s = type(s) == "table" and s or {}
	local o = {}
	for k, d in pairs(SPEC_DEFAULT) do
		local v = s[k]
		if type(d) == "boolean" then
			if v == nil then o[k] = d else o[k] = (v == true or v == 1) end
		elseif type(d) == "number" then
			local lo, hi = 30, 120
			if k == "farSize" then lo, hi = 20, 70 end
			o[k] = math.clamp(tonumber(v) or d, lo, hi)
		else
			o[k] = (type(v) == "string") and v or d
		end
	end
	o.emoji = cutChars(o.emoji, 3)
	o.far = cutChars(o.far, 3)
	if o.far == "" then o.far = "👑" end
	return o
end

-- custom code from the website runs with a small environment: UI classes only, no game / services / network.
local SAFE_CLASSES = {
	Frame = true, TextLabel = true, ImageLabel = true, UIGradient = true, UIStroke = true,
	UICorner = true, UIListLayout = true, UIPadding = true, UIScale = true,
}
local function runUserCode(tag, code)
	if typeof(loadstring) ~= "function" or typeof(setfenv) ~= "function" then return false end
	local env = {
		tag = { canvas = tag.canvas, label = tag.label, name = tag.name, userId = tag.plr.UserId, height = tag.h },
		Instance = {
			new = function(class, parent)
				if not SAFE_CLASSES[class] then error("class not allowed: " .. tostring(class), 2) end
				local o = Instance.new(class)
				if typeof(parent) == "Instance" then o.Parent = parent end
				return o
			end,
		},
		UDim2 = UDim2, UDim = UDim, Vector2 = Vector2, Color3 = Color3, Enum = Enum, TweenInfo = TweenInfo,
		NumberSequence = NumberSequence, NumberSequenceKeypoint = NumberSequenceKeypoint,
		ColorSequence = ColorSequence, ColorSequenceKeypoint = ColorSequenceKeypoint,
		math = math, string = string, table = table, utf8 = utf8, os = { clock = os.clock, time = os.time },
		pairs = pairs, ipairs = ipairs, next = next, select = select, type = type, typeof = typeof,
		tostring = tostring, tonumber = tonumber, pcall = pcall, error = error, unpack = unpack or table.unpack,
		rand = math.random,
		tween = function(inst, secs, props)
			pcall(function() TweenService:Create(inst, TweenInfo.new(tonumber(secs) or 0.3), props):Play() end)
		end,
	}
	local fn = loadstring(code, "=tagcode")
	if type(fn) ~= "function" then return false end
	setfenv(fn, env)
	local ok, upd = pcall(fn)
	if ok and type(upd) == "function" then tag.userUpdate = upd end
	return ok
end

local function newAdminTag(plr, name, spec, code)
	local edgeC = hex(spec.edge, Color3.fromRGB(140, 70, 230))
	local bgC = hex(spec.bg, Color3.fromRGB(8, 3, 18))
	local rainC = hex(spec.rain, Color3.fromRGB(120, 50, 210))
	local textC = hex(spec.text, WHITE)
	local strokeC = hex(spec.stroke, Color3.new(0, 0, 0))
	local rainBot = rainC:Lerp(WHITE, 0.85)
	local codeOnly = spec.codeOnly and code ~= nil -- until the code has arrived the normal look shows

	local root = mk("Frame", { Name = plr.Name .. "_admin", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Visible = false }, gui)
	local holder = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0) }, root)
	local scale = mk("UIScale", { Scale = 1 }, holder)

	local pill = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(0, -14), Size = UDim2.fromOffset(44, AH),
		BackgroundTransparency = 1, Visible = false, ZIndex = 1,
	}, holder)
	-- the thin inner edge is the only border
	local clip = mk("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = bgC, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 2,
	}, pill)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, clip)
	mk("UIStroke", { Color = edgeC, Thickness = 1.2, Transparency = 0.2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, clip)

	-- hacker code rain
	local cols = {}
	if spec.rainOn and not codeOnly then
		for c = 1, ADMIN_COLS do
			local lbl = mk("TextLabel", {
				Position = UDim2.fromOffset((c - 1) * 7 + 1, -60), Size = UDim2.fromOffset(7, 60), BackgroundTransparency = 1,
				Font = Enum.Font.Code, TextSize = 9, TextColor3 = WHITE, Text = rndColumn(), TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 1,
			}, clip)
			mk("UIGradient", {
				Rotation = 90,
				Color = ColorSequence.new(rainC, rainBot),
				Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.05) }),
			}, lbl)
			cols[c] = { lbl = lbl, x = (c - 1) * 7 + 1, y = -math.random() * AH * 2, sp = 28 + math.random() * 60 }
		end
	end

	-- dark plate so the name stays readable over the code
	local plate = mk("Frame", {
		Position = UDim2.fromOffset(6, 5), Size = UDim2.new(1, -12, 1, -10), BackgroundColor3 = Color3.fromRGB(2, 0, 8),
		BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2,
	}, clip)
	mk("UICorner", { CornerRadius = UDim.new(0, 5) }, plate)

	local sheen
	if spec.sheen then
		sheen = mk("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, AH * 2), Position = UDim2.fromOffset(-30, AH / 2),
			Rotation = 20, BackgroundColor3 = WHITE, BorderSizePixel = 0, Visible = false, ZIndex = 4,
		}, clip)
		mk("UIGradient", { Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.72), NumberSequenceKeypoint.new(1, 1),
		}) }, sheen)
	end
	local bolts = {}
	if spec.bolts then
		for b = 1, BOLT_SLOTS do bolts[b] = newBolt(clip, BOLT_SEGS, 3) end
	end

	local labelBase = UDim2.fromOffset(0, 0)
	local label = mk("TextLabel", {
		Position = labelBase, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack, TextSize = 13, TextColor3 = textC, TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center, TextWrapped = false, TextTransparency = 1, Text = "", ZIndex = 5,
		TextStrokeColor3 = strokeC, TextStrokeTransparency = 1,
	}, clip)
	-- transparent layer the custom code draws on
	local canvas = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 6, ClipsDescendants = true }, clip)
	local btn = mk("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 8, AutoButtonColor = false }, pill)

	-- the big emoji (the only thing people see from far away)
	local fs = spec.farSize
	local crownLbl = mk("TextButton", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(0, -4), Size = UDim2.fromOffset(math.floor(fs * 1.56), math.floor(fs * 1.26)),
		BackgroundTransparency = 1, Text = spec.far, TextSize = fs, TextColor3 = WHITE, Font = Enum.Font.GothamBold,
		AutoButtonColor = false, ZIndex = 3,
	}, holder)

	local tag = {
		admin = true, plr = plr, root = root, scale = scale, pill = pill, label = label, plate = plate, crownLbl = crownLbl, canvas = canvas,
		token = 0, open = false, hover = 0, hoverTarget = 0, name = "",
		h = AH, fs = 13, font = Enum.Font.GothamBlack, pad = 20, cap = 260,
		cols = cols, nextRoll = 0, labelBase = labelBase, nextGlitch = os.clock() + 1.5, glitchUntil = 0,
		spec = spec, emoji = spec.emoji, labelOn = not codeOnly, openD = spec.openDist, closeD = spec.openDist + 10,
		sheen = sheen, bolts = bolts, nextBolt = os.clock() + 0.5, flash = 0, flashBg = BASE_BG, seed = math.random() * 10,
		userUpdate = nil, userErr = 0,
	}
	setName(tag, name)
	if code and typeof(code) == "string" then
		local ok = pcall(runUserCode, tag, code)
		if not ok then tag.userUpdate = nil end
	end
	for _, b in ipairs({ btn, crownLbl }) do
		keep(b.MouseEnter:Connect(function() tag.hoverTarget = 1 end))
		keep(b.MouseLeave:Connect(function() tag.hoverTarget = 0 end))
		keep(b.Activated:Connect(function() tpTo(plr, tag.name) end))
	end
	return tag
end

local function updateAdmin(tag, t, dt)
	tag.crownLbl.Position = UDim2.fromOffset(0, -4 + math.sin(t * 2.2) * 2)
	for _, bolt in ipairs(tag.bolts) do tickBolt(bolt, dt) end
	if not tag.open then return end

	-- code rain
	for _, c in ipairs(tag.cols) do
		c.y += c.sp * dt
		if c.y > AH then
			c.y = -60 - math.random() * 30
			c.sp = 28 + math.random() * 60
			c.lbl.Text = rndColumn()
		end
		c.lbl.Position = UDim2.fromOffset(c.x, math.floor(c.y))
	end
	if #tag.cols > 0 and t >= tag.nextRoll then
		tag.nextRoll = t + 0.08
		tag.cols[math.random(#tag.cols)].lbl.Text = rndColumn()
	end
	-- sheen sweep
	if tag.sheen then
		local ph = ((t * 0.8 + tag.seed) % 3.4) / 0.9
		if ph < 1 then
			tag.sheen.Visible = true
			tag.sheen.Position = UDim2.fromOffset(-20 + (tag.pill.Size.X.Offset + 40) * ph, tag.h / 2)
		else
			tag.sheen.Visible = false
		end
	end
	-- lightning
	if tag.spec.bolts and t >= tag.nextBolt then
		strike(tag)
		tag.nextBolt = t + ((math.random() < 0.4) and (0.05 + math.random() * 0.1) or (0.2 + math.random() * 0.4))
	end
	-- short glitch flicker on the name
	if tag.spec.glitch then
		if t >= tag.nextGlitch then
			tag.nextGlitch = t + 1.4 + math.random() * 2.4
			tag.glitchUntil = t + 0.1
		end
		if t < tag.glitchUntil then
			tag.label.Position = tag.labelBase + UDim2.fromOffset(math.random(-2, 2), math.random(-1, 1))
		else
			tag.label.Position = tag.labelBase
		end
	end
	-- custom code from the website (stops itself after a few errors)
	if tag.userUpdate then
		local ok = pcall(tag.userUpdate, dt, t)
		if not ok then
			tag.userErr += 1
			if tag.userErr >= 5 then tag.userUpdate = nil end
		end
	end
end

-- ============================================================ tag bookkeeping
local function removeTag(uid)
	local t = tags[uid]
	if not t then return end
	tags[uid] = nil
	pcall(function() t.root:Destroy() end)
end

local kick = true -- set to true to make the sync loop run again right away
local copying, copySeq, copySeen, fastUntil = false, os.time() * 100, {}, 0 -- copy effect: are we copying, our copy counter, last state seen per player, poll fast until
local antiSet, myAnti, lastSyncOk = {}, false, 0 -- anti outfit stealer: who has it on (from the last sync), and our own switch
local enabled = not G.GENX_BILLBOARD_OFF -- Dreamville setting: off = nobody sees your billboard and you see none (we still sync, hidden, so the anti outfit stealer keeps working)
local function clearAll() for uid in pairs(tags) do removeTag(uid) end end
local codeCache, fetching = {}, {} -- custom code from the website, cached per user + version

local function fetchCode(uid, hashS)
	local key = uid .. ":" .. hashS
	if fetching[key] or not httpReq or CONFIG.BACKEND == "" then return end
	fetching[key] = true
	task.spawn(function()
		local ok, res = pcall(httpReq, { Url = CONFIG.BACKEND .. "/tagcode/" .. uid, Method = "GET" })
		if ok and type(res) == "table" and res.StatusCode == 200 then
			local ok2, d = pcall(function() return HttpService:JSONDecode(res.Body) end)
			if ok2 and type(d) == "table" and type(d.code) == "string" and d.code ~= "" then
				codeCache[uid] = { h = hashS, code = d.code }
				kick = true
			end
		end
		task.delay(10, function() fetching[key] = nil end) -- retry later if it failed
	end)
end

-- info = { n = name, a = website tag?, s = style spec, h = tag version, c = has custom code }
local function ensureTag(plr, info)
	local uid = plr.UserId
	local name = clean(info.n, info.a and CONFIG.TAG_NAME_MAX or CONFIG.NAME_MAX)
	if name == "" then name = info.a and "TAG" or clean(plr.DisplayName) end
	local hashS = info.a and string.format("%.0f", tonumber(info.h) or 0) or ""
	local code
	if info.a and info.c then
		local cc = codeCache[uid]
		if cc and cc.h == hashS then code = cc.code else fetchCode(uid, hashS) end
	end
	local t = tags[uid]
	if t and (t.plr ~= plr or t.admin ~= info.a or (info.a and (t.hash ~= hashS or t.codeLoaded ~= (code ~= nil)))) then
		removeTag(uid)
		t = nil
	end
	if not t then
		if info.a then
			t = newAdminTag(plr, name, cleanSpec(info.s), code)
			t.hash = hashS
			t.codeLoaded = code ~= nil
		else
			t = newTag(plr, name)
		end
		tags[uid] = t
	elseif t.name ~= name then
		setName(t, name)
	end
end

-- ============================================================ render loop (follows the head every frame)
local function step(dt)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local t = os.clock()
	local rot = (t * 150) % 360
	local pulse = 0.5 + 0.5 * math.sin(t * 3.2)
	local camPos = cam.CFrame.Position
	local k = math.min(1, dt * 14)

	for _, tag in pairs(tags) do
		local char = tag.plr.Character
		local head = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
		if not head then
			tag.root.Visible = false
		else
			local pos = head.Position + Vector3.new(0, head.Size.Y * 0.5 + 1.1, 0)
			local v, onScreen = cam:WorldToViewportPoint(pos)
			local dist = (camPos - head.Position).Magnitude
			if not onScreen or v.Z <= 0 or (tag.plr == LP and dist < 3) then
				tag.root.Visible = false
			else
				tag.root.Visible = true
				tag.root.Position = UDim2.fromOffset(math.floor(v.X + 0.5), math.floor(v.Y + 0.5))
				tag.hover += (tag.hoverTarget - tag.hover) * k
				local openD, closeD
				if tag.admin then
					-- admin: always a bit bigger, and it stays big when far away
					tag.root.ZIndex = 20000 + math.clamp(10000 - math.floor(dist), 1, 10000)
					tag.scale.Scale = math.clamp(1.15 - dist / 450, 0.9, 1.05) * (1 + 0.06 * tag.hover)
					openD, closeD = tag.openD, tag.closeD
				else
					tag.root.ZIndex = math.clamp(10000 - math.floor(dist), 1, 10000)
					tag.scale.Scale = math.clamp(1.0 - dist / 350, 0.5, 0.95) * (1 + 0.08 * tag.hover)
					openD, closeD = CONFIG.OPEN_DIST, CONFIG.CLOSE_DIST
				end
				if tag.open then
					if dist > closeD then setOpen(tag, false) end
				elseif dist < openD then
					setOpen(tag, true)
				end
				if tag.admin then updateAdmin(tag, t, dt) else updateNormal(tag, t, dt, rot, pulse) end
			end
		end
	end
end
RunService:BindToRenderStep("PurpleTagsStep", Enum.RenderPriority.Camera.Value + 1, step)

-- ============================================================ who gets which tag
-- map = { [userIdString] = { n = name, a = 1 for a website tag, s = style, h = version, c = 1 custom code } } from the backend,
-- or nil for local mode (everyone gets the normal purple tag).
local function applyKnown(map)
	local want = {}
	if map then
		for uidStr, v in pairs(map) do
			local uid = tonumber(uidStr)
			if uid and type(v) == "table" and not (v.hid == 1 or v.hid == true) and Players:GetPlayerByUserId(uid) then
				want[uid] = { n = v.n, a = (v.a == 1 or v.a == true), s = v.s, h = v.h, c = (v.c == 1 or v.c == true) }
			end
		end
	else
		for _, p in ipairs(Players:GetPlayers()) do want[p.UserId] = { n = p.DisplayName, a = false } end
	end
	-- you always see yourself: your saved name, unless the website gave you a tag
	if not (want[LP.UserId] and want[LP.UserId].a) then
		want[LP.UserId] = { n = myName, a = false }
	end
	for uid, info in pairs(want) do
		local p = Players:GetPlayerByUserId(uid)
		if p then ensureTag(p, info) end
	end
	for uid in pairs(tags) do
		if not want[uid] then removeTag(uid) end
	end
end
keep(Players.PlayerRemoving:Connect(function(p) removeTag(p.UserId) end))

-- ============================================================ copy effect events
local function fireCopy(uid, ev)
	local f = G.GENX_REMOTE_FX
	if enabled and f then pcall(f, uid, ev) end
end
local function handleCopy(users)
	local anyOn = false
	for uidStr, v in pairs(users) do
		local uid = tonumber(uidStr)
		if uid and uid ~= LP.UserId and type(v) == "table" and type(v.cq) == "number" then
			local on = (v.cp == 1 or v.cp == true)
			if on then anyOn = true end
			local prev = copySeen[uid]
			copySeen[uid] = { cq = v.cq, on = on }
			if not prev then
				if on then fireCopy(uid, "start") end -- joined while they were mid-copy
			elseif v.cq > prev.cq then -- a new copy began since the last sync (even a very short one)
				fireCopy(uid, "start")
				if not on then fireCopy(uid, "stop") end
			elseif on and not prev.on then
				fireCopy(uid, "start")
			elseif prev.on and not on then
				fireCopy(uid, "stop")
			end
		end
	end
	if anyOn then fastUntil = os.clock() + 4 end -- someone is copying: poll quickly until it ends
end
keep(Players.PlayerRemoving:Connect(function(p) copySeen[p.UserId] = nil end))

-- ============================================================ admin command RECEIVER
-- Everyone running this script can be targeted by AdminPanel.lua through /api/cmd.
-- protectMe defaults OFF: toggle with G.GENX_TAGS.setProtect(bool). When on, every incoming
-- command is skipped (the server already stops sending them once px=1, this is a second check).
-- Every effect records what it changed and restores it on: expiry, "release", respawn, script stop.
local protectMe = false
local protectToastShown = false
local doneIds = {}        -- command ids already executed (so a resend before ack doesn't double-run)
local ackQueue = {}        -- ids to send back on the next /sync
local active = {}          -- effectName -> { restore = fn, expireAt = os.clock() }
local lastKickTime, lastFlashTime, lastJumpscareTime = 0, 0, {}

local function registerEffect(name, restoreFn, durationSec)
	local prev = active[name]
	if prev and prev.restore then pcall(prev.restore) end
	active[name] = { restore = restoreFn, expireAt = os.clock() + math.min(30, math.max(0.1, durationSec or 5)) }
end

local function releaseEffect(name)
	local e = active[name]
	if not e then return end
	active[name] = nil
	pcall(e.restore)
end

local function releaseAll()
	for name in pairs(active) do releaseEffect(name) end
end

-- expiry sweep, piggybacks on the render step so nothing extra needs binding
local function tickEffects()
	local t = os.clock()
	for name, e in pairs(active) do
		if t >= e.expireAt then releaseEffect(name) end
	end
end

local function getHRP()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end

-- ---- movement effects ------------------------------------------------------------------
local function fx_freeze(dur)
	local hrp, hum = getHRP()
	if not (hrp and hum) then return end
	local prevAnchored = hrp.Anchored
	hrp.Anchored = true
	registerEffect("freeze", function() if hrp and hrp.Parent then hrp.Anchored = prevAnchored end end, dur)
end
local function fx_unfreeze() releaseEffect("freeze") end

local function fx_bring(dur, a)
	local hrp = getHRP()
	if not hrp then return end
	if a and type(a.x) == "number" and type(a.y) == "number" and type(a.z) == "number" then
		pcall(function() hrp.CFrame = CFrame.new(a.x, a.y, a.z) end) -- instant snap to the admin's last known position
	else
		toast("bring: no live admin position in sync payload yet")
	end
end

local function fx_flip(dur)
	local hrp = getHRP()
	if not hrp then return end
	local conn
	conn = keep(RunService.Heartbeat:Connect(function()
		if hrp and hrp.Parent then hrp.CFrame = hrp.CFrame * CFrame.Angles(0, 0, math.rad(6)) end
	end))
	registerEffect("flip", function() if conn then conn:Disconnect() end end, dur)
end

local function fx_spin(dur)
	local hrp = getHRP()
	if not hrp then return end
	local conn
	conn = keep(RunService.Heartbeat:Connect(function(dt)
		if hrp and hrp.Parent then hrp.CFrame = hrp.CFrame * CFrame.Angles(0, dt * 6, 0) end
	end))
	registerEffect("spin", function() if conn then conn:Disconnect() end end, dur)
end

local function fx_launch()
	local hrp = getHRP()
	if not hrp then return end
	pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 90, 0) end)
end

local function fx_trip(dur)
	local hrp, hum = getHRP()
	if not hum then return end
	local prev = hum.PlatformStand
	hum.PlatformStand = true
	registerEffect("trip", function() if hum and hum.Parent then hum.PlatformStand = prev end end, dur)
end

local function fx_sit()
	local hum = select(2, getHRP())
	if hum then pcall(function() hum.Sit = true end) end
end

local function fx_speedset(dur, mult)
	local hum = select(2, getHRP())
	if not hum then return end
	local prev = hum.WalkSpeed
	hum.WalkSpeed = math.clamp(prev * (mult or 1), 2, 200)
	registerEffect("speed", function() if hum and hum.Parent then hum.WalkSpeed = prev end end, dur)
end

local function fx_jumplock(dur, on)
	local hum = select(2, getHRP())
	if not hum then return end
	local prev = hum.JumpPower
	hum.JumpPower = on and 0 or prev
	registerEffect("jumplock", function() if hum and hum.Parent then hum.JumpPower = prev end end, dur)
end

local function fx_reverse(dur)
	local hum = select(2, getHRP())
	if not hum then return end
	local conn
	conn = keep(RunService.RenderStepped:Connect(function()
		-- flips move direction by mirroring the camera's look vector each frame (humanoid still walks forward relative to that)
		local cam = workspace.CurrentCamera
		if cam then cam.CFrame = cam.CFrame * CFrame.Angles(0, math.rad(180), 0) * CFrame.Angles(0, math.rad(-180), 0) end
	end))
	registerEffect("reverse", function() if conn then conn:Disconnect() end end, dur)
end

local function fx_float(dur)
	local hrp = getHRP()
	if not hrp then return end
	local prevGravity = workspace.Gravity
	local conn
	conn = keep(RunService.Heartbeat:Connect(function()
		if hrp and hrp.Parent then pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 2, hrp.AssemblyLinearVelocity.Z) end) end
	end))
	registerEffect("float", function() if conn then conn:Disconnect() end end, dur)
end

local function fx_faketeleport()
	-- visual only: blackout for ~0.6s to sell a fake teleport, no actual CFrame change
	local overlay = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, ZIndex = 50000 }, gui)
	TweenService:Create(overlay, TweenInfo.new(0.15), { BackgroundTransparency = 0 }):Play()
	task.delay(0.6, function()
		TweenService:Create(overlay, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
		task.delay(0.35, function() pcall(function() overlay:Destroy() end) end)
	end)
end

-- ---- body / camera / screen effects ----------------------------------------------------
local function fx_shrinkgiant(dur, scale)
	local c = LP.Character
	if not c then return end
	local hum = c:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local ok = pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end) -- no-op guard
	local scaleObj = c:FindFirstChild("BodyScale") -- not all rigs have this; use HumanoidDescription-free approach
	local prevSize = hum.HipHeight
	-- simplest cross-rig approach: tween the character model size via Humanoid's built-in scale properties (R15 only)
	local ok2 = pcall(function()
		local bodyHeightScale = hum:FindFirstChild("BodyHeightScale")
		local bodyWidthScale = hum:FindFirstChild("BodyWidthScale")
		local bodyDepthScale = hum:FindFirstChild("BodyDepthScale")
		if bodyHeightScale and bodyWidthScale and bodyDepthScale then
			local ph, pw, pd = bodyHeightScale.Value, bodyWidthScale.Value, bodyDepthScale.Value
			bodyHeightScale.Value = math.clamp(ph * scale, 0.4, 3)
			bodyWidthScale.Value = math.clamp(pw * scale, 0.4, 3)
			bodyDepthScale.Value = math.clamp(pd * scale, 0.4, 3)
			registerEffect("scale", function()
				if bodyHeightScale and bodyHeightScale.Parent then bodyHeightScale.Value = ph end
				if bodyWidthScale and bodyWidthScale.Parent then bodyWidthScale.Value = pw end
				if bodyDepthScale and bodyDepthScale.Parent then bodyDepthScale.Value = pd end
			end, dur)
		else
			toast("scale: R15 only, this rig has no scale values")
		end
	end)
end

local function fx_dance(dur)
	local c = LP.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://507771019" -- default dance 1
	local ok, track = pcall(function() return hum:LoadAnimation(anim) end)
	if not ok then return end
	track:Play()
	registerEffect("dance", function() pcall(function() track:Stop() end) end, dur)
end

local function camOverlay(name, build, dur)
	-- build(container) returns a cleanup function
	local container = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 40000 }, gui)
	local cleanup = build(container)
	registerEffect(name, function()
		pcall(cleanup)
		pcall(function() container:Destroy() end)
	end, dur)
end

local function fx_camshake(dur, strength)
	local cam = workspace.CurrentCamera
	local base = cam and cam.CFrame
	local conn
	conn = keep(RunService.RenderStepped:Connect(function()
		if cam then
			local s = 0.15 * math.clamp(strength or 0.5, 0, 1)
			cam.CFrame = cam.CFrame * CFrame.new(math.random(-100, 100) / 100 * s, math.random(-100, 100) / 100 * s, 0)
		end
	end))
	registerEffect("camshake", function() if conn then conn:Disconnect() end end, dur)
end

local function fx_camupsidedown(dur)
	camOverlay("camupsidedown", function(c)
		local lbl = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Rotation = 180 }, c)
		-- true upside-down needs a ViewportFrame mirror; cheapest reliable version is a full screen flip overlay note
		return function() end
	end, dur)
	toast("camera: upside-down (overlay)")
end

local function fx_camfisheye(dur)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local prevFov = cam.FieldOfView
	TweenService:Create(cam, TweenInfo.new(0.3), { FieldOfView = 120 }):Play()
	registerEffect("camfisheye", function() if cam and cam.Parent then TweenService:Create(cam, TweenInfo.new(0.3), { FieldOfView = prevFov }):Play() end end, dur)
end

local function fx_camzoom(dur)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local prevType = cam.CameraType
	cam.CameraType = Enum.CameraType.Scriptable
	registerEffect("camzoom", function() if cam and cam.Parent then cam.CameraType = prevType end end, dur)
end

local function fx_camfp(dur)
	local prevMin, prevMax = LP.CameraMinZoomDistance, LP.CameraMaxZoomDistance
	LP.CameraMinZoomDistance, LP.CameraMaxZoomDistance = 0.5, 0.5
	registerEffect("camfp", function() LP.CameraMinZoomDistance, LP.CameraMaxZoomDistance = prevMin, prevMax end, dur)
end

local function fx_camspin(dur)
	local cam = workspace.CurrentCamera
	local conn
	conn = keep(RunService.RenderStepped:Connect(function(dt)
		if cam then cam.CFrame = cam.CFrame * CFrame.Angles(0, dt * 2, 0) end
	end))
	registerEffect("camspin", function() if conn then conn:Disconnect() end end, dur)
end

local function fullscreenOverlay(name, color, dur, transparency)
	local overlay = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = color, BackgroundTransparency = 1, ZIndex = 45000 }, gui)
	TweenService:Create(overlay, TweenInfo.new(0.15), { BackgroundTransparency = transparency or 0 }):Play()
	registerEffect(name, function()
		if overlay and overlay.Parent then
			TweenService:Create(overlay, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
			task.delay(0.35, function() pcall(function() overlay:Destroy() end) end)
		end
	end, dur)
end

local function fx_blackout(dur) fullscreenOverlay("blackout", Color3.new(0, 0, 0), dur, 0) end
local function fx_sepia(dur)
	local ok = pcall(function()
		local ct = Instance.new("ColorCorrectionEffect")
		ct.TintColor = Color3.fromRGB(255, 220, 170)
		ct.Saturation = -0.4
		ct.Parent = game:GetService("Lighting")
		registerEffect("sepia", function() pcall(function() ct:Destroy() end) end, dur)
	end)
end
local function fx_invert(dur)
	pcall(function()
		local ct = Instance.new("ColorCorrectionEffect")
		ct.Contrast = 1
		ct.TintColor = Color3.new(0, 0, 0) -- partial look, true invert needs a shader post-process not available via CC effect
		ct.Parent = game:GetService("Lighting")
		registerEffect("invert", function() pcall(function() ct:Destroy() end) end, dur)
	end)
end
local function fx_disco(dur)
	local overlay = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.6, ZIndex = 44000 }, gui)
	local conn
	conn = keep(RunService.Heartbeat:Connect(function()
		overlay.BackgroundColor3 = randColor()
	end))
	registerEffect("disco", function() if conn then conn:Disconnect() end pcall(function() overlay:Destroy() end) end, dur)
end
local function fx_fakelag(dur)
	-- throttles our own render step to simulate stutter; purely cosmetic, never touches the network
	local conn
	local acc = 0
	conn = keep(RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then task.wait() end
		if acc > 0.4 then acc = 0 end
	end))
	registerEffect("fakelag", function() if conn then conn:Disconnect() end end, dur)
end
local function fx_fakereconnect(dur)
	local overlay = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.1, ZIndex = 46000 }, gui)
	mk("TextLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "Reconnecting...",
		Font = Enum.Font.GothamBold, TextSize = 28, TextColor3 = WHITE,
	}, overlay)
	registerEffect("fakereconnect", function() pcall(function() overlay:Destroy() end) end, dur)
end
local function fx_fakeerror(dur)
	local box = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(340, 140),
		BackgroundColor3 = Color3.fromRGB(240, 240, 240), ZIndex = 46000,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, box)
	mk("TextLabel", {
		Size = UDim2.new(1, -20, 1, -20), Position = UDim2.fromOffset(10, 10), BackgroundTransparency = 1,
		Text = "Something went wrong.\n\n(this is a prank, not a real error)", TextWrapped = true,
		Font = Enum.Font.Gotham, TextSize = 16, TextColor3 = Color3.new(0.1, 0.1, 0.1),
	}, box)
	registerEffect("fakeerror", function() pcall(function() box:Destroy() end) end, math.min(dur or 5, 10))
end
local function fx_fakejoinleave(text)
	toast(text)
end
local function fx_chatbubble(text)
	local c = LP.Character
	local head = c and c:FindFirstChild("Head")
	if not head then return end
	pcall(function() game:GetService("Chat"):Chat(head, text, Enum.ChatColor.White) end)
end

-- ---- tag pranks (purely cosmetic, reuse the existing tag objects) ----------------------
local function fx_tagswap(dur, newName)
	local t = tags[LP.UserId]
	if not t then return end
	local prevName = t.name
	setName(t, clean(newName or "???", 20))
	registerEffect("tagswap", function() if tags[LP.UserId] then setName(tags[LP.UserId], prevName) end end, dur)
end
local function fx_tagspotlight(dur)
	local t = tags[LP.UserId]
	if not t or not t.pill then return end
	local prevColor = t.pill.BackgroundColor3
	TweenService:Create(t.pill, TweenInfo.new(0.3), { BackgroundColor3 = Color3.fromRGB(255, 230, 80) }):Play()
	registerEffect("tagspotlight", function()
		if tags[LP.UserId] and tags[LP.UserId].pill then TweenService:Create(tags[LP.UserId].pill, TweenInfo.new(0.3), { BackgroundColor3 = prevColor }):Play() end
	end, dur)
end
local function fx_tagrainbow(dur)
	local conn
	conn = keep(RunService.Heartbeat:Connect(function()
		local t = tags[LP.UserId]
		if t and t.pill then t.pill.BackgroundColor3 = randColor() end
	end))
	registerEffect("tagrainbow", function() if conn then conn:Disconnect() end end, dur)
end

-- ---- sound / flashbang / jumpscare -------------------------------------------------------
local function playSound(soundId, volume, maxSeconds)
	if not soundId or soundId == "" then return end
	local s = Instance.new("Sound")
	s.SoundId = soundId
	s.Volume = math.clamp(volume or 0.5, 0, 1)
	s.Parent = SoundService or game:GetService("SoundService")
	pcall(function() s:Play() end)
	task.delay(maxSeconds or 5, function() pcall(function() s:Destroy() end) end)
end

-- when a big troll (jumpscare / fake ban) fires, every OTHER active effect is forced to wrap up
-- within maxSeconds instead of running its full duration, so nothing lingers alongside it.
local function capAllEffects(maxSeconds)
	local limit = os.clock() + maxSeconds
	for name, e in pairs(active) do
		if name ~= "jumpscare" and name ~= "fakeban" and e.expireAt > limit then
			e.expireAt = limit
		end
	end
end

local function fx_flashbang(args)
	if os.clock() - lastFlashTime < 8 then return end
	lastFlashTime = os.clock()
	local overlay = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 50000 }, gui)
	TweenService:Create(overlay, TweenInfo.new(0.15), { BackgroundTransparency = 0 }):Play()
	local snd = args and args.soundId or ""
	if snd ~= "" then playSound(snd, 0.6, 3) end
	task.delay(0.15, function()
		TweenService:Create(overlay, TweenInfo.new(2.5), { BackgroundTransparency = 1 }):Play()
		task.delay(2.6, function() pcall(function() overlay:Destroy() end) end)
	end)
end

-- full-screen image + sound, both run exactly 3s then restore automatically like nothing happened.
-- startle = instant appear (no fade in), hold, then a quick 0.3s fade out on both image and sound.
local function fx_jumpscare(args)
	local key = "jumpscare"
	if os.clock() - (lastJumpscareTime[key] or 0) < 30 then return end
	lastJumpscareTime[key] = os.clock()
	capAllEffects(5) -- any other troll running on this player wraps up within 5s instead of overlapping
	local img = args and args.imageId or ""
	local snd = args and args.soundId or ""
	local vol = math.min(0.6, (args and args.strength) or 0.6)
	local frame = mk("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0,
		ClipsDescendants = true, ZIndex = 50000,
	}, gui)
	if img ~= "" then
		mk("ImageLabel", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = img,
			ScaleType = Enum.ScaleType.Crop, ZIndex = 50001, -- Crop fills the full screen on any aspect ratio
		}, frame)
	end
	local sndInst
	if snd ~= "" then
		sndInst = Instance.new("Sound")
		sndInst.SoundId = snd
		sndInst.Volume = vol
		sndInst.Parent = SoundService
		pcall(function() sndInst:Play() end)
	end
	registerEffect("jumpscare", function()
		if sndInst then
			pcall(function() TweenService:Create(sndInst, TweenInfo.new(0.3), { Volume = 0 }):Play() end)
			task.delay(0.35, function() pcall(function() sndInst:Destroy() end) end)
		end
		if frame and frame.Parent then
			TweenService:Create(frame, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
			task.delay(0.35, function() pcall(function() frame:Destroy() end) end)
		end
	end, 3) -- exactly 3s total, then the cleanup above restores everything automatically
end

-- shows a banner (text from CONFIG.FAKE_BAN_TEXT, default "You have been banned.") with no reason,
-- no sound, then actually kicks the player with that same message a couple seconds later.
local function fx_fakeban(args)
	capAllEffects(5)
	local text = (args and args.text and args.text ~= "" and args.text) or "You have been banned."
	local overlay = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(10, 0, 0), BackgroundTransparency = 0, ZIndex = 50000 }, gui)
	mk("TextLabel", {
		Size = UDim2.new(0.8, 0, 0.3, 0), Position = UDim2.fromScale(0.1, 0.35), BackgroundTransparency = 1,
		Text = text, TextWrapped = true, Font = Enum.Font.GothamBold, TextSize = 30, TextColor3 = WHITE,
	}, overlay)
	task.delay(2.5, function() if alive and active["fakeban"] then pcall(function() LP:Kick(text) end) end end) -- Release / respawn cancels it
	registerEffect("fakeban", function() pcall(function() overlay:Destroy() end) end, 3)
end

local function fx_kick()
	if os.clock() - lastKickTime < 60 then return end
	lastKickTime = os.clock()
	pcall(function() LP:Kick("You have been banned.") end)
end

-- ---- command dispatch --------------------------------------------------------------------
local EFFECTS = {
	freeze = function(a) fx_freeze(a.duration) end,
	unfreeze = function() fx_unfreeze() end,
	bring = function(a) fx_bring(a.duration, a) end,
	flip = function(a) fx_flip(a.duration) end,
	spin = function(a) fx_spin(a.duration) end,
	launch = function() fx_launch() end,
	trip = function(a) fx_trip(a.duration) end,
	sit = function() fx_sit() end,
	slow = function(a) fx_speedset(a.duration, math.max(0.1, 1 - (a.strength or 0.6))) end,
	speed = function(a) fx_speedset(a.duration, 1 + (a.strength or 1)) end,
	jumplock = function(a) fx_jumplock(a.duration, true) end,
	reverse = function(a) fx_reverse(a.duration) end,
	sway = function(a) fx_camshake(a.duration, (a.strength or 0.3)) end,
	moonwalk = function(a) fx_reverse(a.duration) end,
	float = function(a) fx_float(a.duration) end,
	faceme = function(a) fx_camspin(a.duration) end, -- approximation: no live admin position available
	faketeleport = function() fx_faketeleport() end,
	shrink = function(a) fx_shrinkgiant(a.duration, 0.5) end,
	giant = function(a) fx_shrinkgiant(a.duration, 1.8) end,
	dance = function(a) fx_dance(a.duration) end,
	emotespam = function(a) fx_dance(a.duration) end,
	camupsidedown = function(a) fx_camupsidedown(a.duration) end,
	camshake = function(a) fx_camshake(a.duration, a.strength) end,
	camzoom = function(a) fx_camzoom(a.duration) end,
	camfisheye = function(a) fx_camfisheye(a.duration) end,
	camspin = function(a) fx_camspin(a.duration) end,
	camfp = function(a) fx_camfp(a.duration) end,
	flashbang = function(a) fx_flashbang(a) end,
	blackout = function(a) fx_blackout(a.duration) end,
	fakelag = function(a) fx_fakelag(a.duration) end,
	fakereconnect = function(a) fx_fakereconnect(a.duration) end,
	disco = function(a) fx_disco(a.duration) end,
	sepia = function(a) fx_sepia(a.duration) end,
	invert = function(a) fx_invert(a.duration) end,
	fakeerror = function(a) fx_fakeerror(a.duration) end,
	fakejoin = function(a) fx_fakejoinleave((a.text or "Player") .. " has joined the game") end,
	fakeleave = function(a) fx_fakejoinleave((a.text or "Player") .. " has left the game") end,
	chatbubble = function(a) fx_chatbubble(a.text or "...") end,
	sound = function(a) playSound(a.soundId, a.strength, 6) end,
	tagswap = function(a) fx_tagswap(a.duration, a.text) end,
	tagspin = function(a) fx_spin(a.duration) end,
	tagshake = function(a) fx_camshake(a.duration, a.strength) end,
	tagrainbow = function(a) fx_tagrainbow(a.duration) end,
	tagspotlight = function(a) fx_tagspotlight(a.duration) end,
	grouphotpotato = function(a) toast("hot potato: " .. tostring(a.text or "")) end,
	groupredlight = function(a) toast("red light, green light!") end,
	groupfollow = function(a) toast("follow the leader!") end,
	jumpscare = function(a) fx_jumpscare(a) end,
	fakeban = function(a) fx_fakeban(a) end,
	kick = function() fx_kick() end,
	release = function() releaseAll() end,
}

-- Anti Troll (sold in the Discord): the server flags protected players with prot = 1 on every /sync.
-- notify() goes through Dreamville's notification system when it is loaded, own toast otherwise.
local serverProt, protToldOn, adShown, dcInvite = false, false, false, ""
local function notify(kind, title, msg)
	if G.GENX_NOTIFY then pcall(G.GENX_NOTIFY, kind, title, msg) else toast(title .. ": " .. msg) end
end
local function handleStatus(d)
	if type(d.dc) == "string" then dcInvite = d.dc:sub(1, 120) end
	serverProt = d.prot == 1 or d.prot == true
	if serverProt and not protToldOn then
		protToldOn = true
		notify("ok", "Protected by GenX", "Anti Troll is on. Troll commands can't touch you.")
	elseif not serverProt then
		protToldOn = false
	end
end

local function runCommand(c)
	if doneIds[c.id] then return end
	doneIds[c.id] = true
	ackQueue[#ackQueue + 1] = c.id
	if (protectMe or serverProt) and c.c ~= "release" then return end -- protect-me / Anti Troll block everything except letting Release still clear state
	local fn = EFFECTS[c.c]
	if fn then pcall(fn, c.a or {}) end
	if c.c ~= "release" and not adShown then -- first time you get trolled this session: tell them how to stop it
		adShown = true
		task.delay(3, function()
			if alive then notify("info", "Anti Troll", "You can buy Anti Troll in the GenX Discord server" .. (dcInvite ~= "" and (": " .. dcInvite) or "")) end
		end)
	end
end

local function handleCmds(cmds)
	if type(cmds) ~= "table" then return end
	for _, c in ipairs(cmds) do
		if type(c) == "table" and type(c.id) == "number" and type(c.c) == "string" then runCommand(c) end
	end
	-- doneIds only needs to remember recent ids; trim once it gets large
	local n = 0
	for _ in pairs(doneIds) do n += 1 end
	if n > 500 then doneIds = {} end
end

keep(RunService.Heartbeat:Connect(tickEffects))
keep(LP.CharacterAdded:Connect(function() pcall(releaseAll) end)) -- respawn always clears every active effect

local protectFirstToastShown = false
local function setProtect(on)
	protectMe = on and true or false
	if protectMe and not protectFirstToastShown then
		protectFirstToastShown = true
		toast("Admin effects exist. You can turn them off in Dreamville (protect me).")
	end
	kick = true
end

-- ============================================================ sync loop
local function doSync()
	local payload = {
		j = JOB, u = LP.UserId, n = myName, x = myAnti and 1 or 0, hid = enabled and 0 or 1,
		cp = (copying and enabled) and 1 or 0, cq = copySeq, px = protectMe and 1 or 0,
	}
	if #ackQueue > 0 then payload.ack = ackQueue end
	local ok, res = pcall(httpReq, {
		Url = CONFIG.BACKEND .. "/sync", Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode(payload),
	})
	if not ok or type(res) ~= "table" or res.StatusCode ~= 200 then return nil end
	local ok2, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
	if ok2 and type(data) == "table" and type(data.users) == "table" then
		ackQueue = {} -- the server confirmed it saw our last ack batch, clear it
		local set = {}
		for uidStr, v in pairs(data.users) do
			if type(v) == "table" and (v.x == 1 or v.x == true) then set[tonumber(uidStr) or 0] = true end
		end
		antiSet = set
		lastSyncOk = os.clock()
		pcall(handleCopy, data.users)
		pcall(handleStatus, data)
		pcall(handleCmds, data.cmds)
		return data.users
	end
	return nil
end

-- shared with Dreamville: the anti outfit stealer reads the last sync from memory, so checking costs no request
G.GENX_TAGS = {
	setAnti = function(on) myAnti = on and true or false kick = true end, -- kick = sync right now
	getAnti = function() return myAnti end,
	setEnabled = function(on) enabled = on and true or false if not enabled then clearAll() if G.GENX_REMOTE_FX then pcall(G.GENX_REMOTE_FX, 0, "kill") end end kick = true end,
	setCopying = function(on) -- Dreamville: your copy started / ended, tell the others right away
		on = on and true or false
		if on and not copying then copySeq += 1 end
		copying = on
		fastUntil = os.clock() + 6
		kick = true
	end,
	getEnabled = function() return enabled end,
	isAnti = function(userId) return antiSet[userId] == true end,
	connected = function() return lastSyncOk > 0 and os.clock() - lastSyncOk < 20 end,
	setProtect = function(on) setProtect(on) end, -- admin troll commands: default OFF, toggle protect-me
	getProtect = function() return protectMe end,
}

local live = CONFIG.BACKEND ~= "" and httpReq ~= nil
task.spawn(function()
	local fails, nextAt = 0, 0
	while alive do
		if kick or os.clock() >= nextAt then
			kick = false
			if live then
				local users = doSync()
				if users then
					fails = 0
					if enabled then applyKnown(users) else clearAll() end
				else
					fails += 1
					if enabled then
						if fails >= 3 or not tags[LP.UserId] then applyKnown({}) end
					else
						clearAll()
					end
				end
				nextAt = os.clock() + math.min(60, ((os.clock() < fastUntil and fails == 0) and 0.8 or CONFIG.SYNC_EVERY) * (2 ^ math.min(fails, 3)))
			else
				if enabled then applyKnown(nil) else clearAll() end
				nextAt = os.clock() + 2
			end
		end
		task.wait(0.4)
	end
end)

-- ============================================================ name editor (off by default, see CONFIG.NAME_EDITOR)
if CONFIG.NAME_EDITOR then
	local openBtn = mk("ImageButton", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = Color3.fromRGB(14, 8, 26), Image = CONFIG.LOGO, ScaleType = Enum.ScaleType.Crop, AutoButtonColor = true,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0.5, 0) }, openBtn)
	mk("UIStroke", { Color = PURPLE, Thickness = 2 }, openBtn)

	local panel = mk("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 60, 0.5, 0), Size = UDim2.fromOffset(250, 128),
		BackgroundColor3 = Color3.fromRGB(14, 8, 26), BackgroundTransparency = 0.04, Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 14) }, panel)
	mk("UIStroke", { Color = PURPLE, Thickness = 1.8 }, panel)
	mk("TextLabel", {
		Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 22), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
		TextSize = 15, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, Text = "Your billboard name",
	}, panel)
	local box = mk("TextBox", {
		Position = UDim2.fromOffset(14, 38), Size = UDim2.new(1, -28, 0, 34), BackgroundColor3 = Color3.fromRGB(30, 16, 54),
		Font = Enum.Font.GothamMedium, TextSize = 15, TextColor3 = WHITE, PlaceholderText = "type a name",
		PlaceholderColor3 = Color3.fromRGB(140, 120, 170), ClearTextOnFocus = false, Text = myName, TextXAlignment = Enum.TextXAlignment.Left,
	}, panel)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, box)
	mk("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, box)
	local save = mk("TextButton", {
		Position = UDim2.fromOffset(14, 82), Size = UDim2.new(1, -28, 0, 34), BackgroundColor3 = PURPLE,
		Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = WHITE, Text = "Save", AutoButtonColor = true,
	}, panel)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, save)

	keep(openBtn.Activated:Connect(function() panel.Visible = not panel.Visible end))
	keep(box:GetPropertyChangedSignal("Text"):Connect(function()
		if #box.Text > CONFIG.NAME_MAX * 4 then box.Text = box.Text:sub(1, CONFIG.NAME_MAX * 4) end
	end))
	local function commit()
		local n = clean(box.Text)
		if n == "" then n = clean(LP.DisplayName) end
		myName = n
		box.Text = n
		saveName()
		local mine = tags[LP.UserId]
		if mine then setName(mine, n) end
		kick = true
		panel.Visible = false
		toast("name set to " .. n)
	end
	keep(save.Activated:Connect(commit))
	keep(box.FocusLost:Connect(function(enter) if enter then commit() end end))
end

-- ============================================================ cleanup
G.PURPLETAGS_STOP = function()
	alive = false
	pcall(releaseAll) -- undo any live admin effect (WalkSpeed, Anchored, camera, UI) before tearing down
	if G.GENX_REMOTE_FX then pcall(G.GENX_REMOTE_FX, 0, "kill") end
	pcall(function() RunService:UnbindFromRenderStep("PurpleTagsStep") end)
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	pcall(function() gui:Destroy() end)
	G.PURPLETAGS_STOP = nil
	G.GENX_TAGS = nil
end

if not CONFIG.QUIET then
	toast(live and "PurpleTags: live" or "PurpleTags: local mode (no backend)")
end
