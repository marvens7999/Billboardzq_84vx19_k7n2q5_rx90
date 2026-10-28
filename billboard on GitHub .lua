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
	SYNC_EVERY = 4, -- seconds
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

-- ============================================================ sync loop
local function doSync()
	local payload = { j = JOB, u = LP.UserId, n = myName, x = myAnti and 1 or 0, hid = enabled and 0 or 1 }
	local ok, res = pcall(httpReq, {
		Url = CONFIG.BACKEND .. "/sync", Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode(payload),
	})
	if not ok or type(res) ~= "table" or res.StatusCode ~= 200 then return nil end
	local ok2, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
	if ok2 and type(data) == "table" and type(data.users) == "table" then
		local set = {}
		for uidStr, v in pairs(data.users) do
			if type(v) == "table" and (v.x == 1 or v.x == true) then set[tonumber(uidStr) or 0] = true end
		end
		antiSet = set
		lastSyncOk = os.clock()
		return data.users
	end
	return nil
end

-- shared with Dreamville: the anti outfit stealer reads the last sync from memory, so checking costs no request
G.GENX_TAGS = {
	setAnti = function(on) myAnti = on and true or false kick = true end, -- kick = sync right now
	getAnti = function() return myAnti end,
	setEnabled = function(on) enabled = on and true or false if not enabled then clearAll() end kick = true end,
	getEnabled = function() return enabled end,
	isAnti = function(userId) return antiSet[userId] == true end,
	connected = function() return lastSyncOk > 0 and os.clock() - lastSyncOk < 20 end,
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
				nextAt = os.clock() + math.min(60, CONFIG.SYNC_EVERY * (2 ^ math.min(fails, 3)))
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
	pcall(function() RunService:UnbindFromRenderStep("PurpleTagsStep") end)
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	pcall(function() gui:Destroy() end)
	G.PURPLETAGS_STOP = nil
	G.GENX_TAGS = nil
end

if not CONFIG.QUIET then
	toast(live and "PurpleTags: live" or "PurpleTags: local mode (no backend)")
end
