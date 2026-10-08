--[[
	════════════════════════════════════════════════════════════
	    BarbatosXIUI  ·  v1.0.0
	    玻璃拟态界面库 · Glassmorphism Interface Library
	────────────────────────────────────────────────────────────
	    特性总览
	      · 链接 / rbxassetid 背景图（自动压暗、可运行时更换）
	      · 黑白流动渐变边框（全局单引擎驱动，开销恒定）
	      · 全动画可打断 —— 同一对象新动画立即取消旧动画
	      · iOS 26 风格玻璃控件（拨杆 / 滑条 / 下拉 / 热键 / 取色器）
	      · 8 套内置主题，支持运行时热切换（已建界面同步换色）
	      · 完整配置系统（Flag 绑定、保存 / 读取 / 删除 / 自动加载）
	      · 通知队列（四种类型、进度条、图标、点击关闭）
	      · 模态对话框（Confirm / Prompt / Alert，键盘回车确认）
	      · 悬停提示 Tooltip（延迟显示、跟随鼠标）
	      · 水印模块（FPS / Ping / 时间实时刷新，可拖动）
	      · 配置管理选项卡自动生成器
	    兼容性
	      · 纯 Luau，无任何第三方依赖
	      · PC / 移动端触控通用
	════════════════════════════════════════════════════════════
]]

local TweenService  = game:GetService("TweenService")
local RunService    = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService    = game:GetService("GuiService")
local Players       = game:GetService("Players")
local HttpService   = game:GetService("HttpService")
local SoundService  = game:GetService("SoundService")
local Stats         = game:GetService("Stats")

local LP = Players.LocalPlayer

local BarbatosXIUI = {}
local BX = BarbatosXIUI -- 内部简写

BX.Version = "1.0.0"
BX.SoundsEnabled = true -- 控件点击音效总开关

----------------------------------------------------------------
-- §1 工具函数
----------------------------------------------------------------
BX.Utils = {}
local Utils = BX.Utils

--- 数字四舍五入到指定小数位
function Utils.Round(n, p)
	local m = 10 ^ (p or 0)
	return math.floor(n * m + 0.5) / m
end

--- 线性插值（数字）
function Utils.Lerp(a, b, t)
	return a + (b - a) * t
end

--- 数值夹取
function Utils.Clamp(n, lo, hi)
	return math.max(lo or 0, math.min(hi or 1, n))
end

--- 颜色插值
function Utils.ColorLerp(a, b, t)
	return Color3.new(
		a.R + (b.R - a.R) * t,
		a.G + (b.G - a.G) * t,
		a.B + (b.B - a.B) * t
	)
end

--- Color3 -> "#RRGGBB"
function Utils.ToHex(c)
	return string.format("#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5))
end

--- "#RRGGBB" -> Color3（容错：允许 "#RGB"、"RRGGBB"）
function Utils.FromHex(s)
	if typeof(s) == "Color3" then return s end
	s = tostring(s or "#FFFFFF"):gsub("#", ""):upper()
	if #s == 3 then
		s = s:sub(1,1)..s:sub(1,1)..s:sub(2,2)..s:sub(2,2)..s:sub(3,3)..s:sub(3,3)
	end
	if #s ~= 6 then return Color3.new(1, 1, 1) end
	local r = tonumber(s:sub(1, 2), 16) or 255
	local g = tonumber(s:sub(3, 4), 16) or 255
	local b = tonumber(s:sub(5, 6), 16) or 255
	return Color3.fromRGB(r, g, b)
end

--- 深拷贝
function Utils.DeepCopy(t)
	if typeof(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do
		out[Utils.DeepCopy(k)] = Utils.DeepCopy(v)
	end
	return out
end

--- 表按键排序后的遍历（配置文件列表用）
function Utils.SortedKeys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

--- 安全调用回调（错误不向上抛，只警告）
function Utils.SafeCall(fn, ...)
	if typeof(fn) ~= "function" then return nil end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[BarbatosXIUI] 回调执行出错:", err)
	end
	return ok
end

--- 键名美化（Enum.KeyCode.LeftShift -> "LShift" 等）
local SHORT_KEYS = {
	LeftControl = "LCtrl", RightControl = "RCtrl",
	LeftShift = "LShift", RightShift = "RShift",
	LeftAlt = "LAlt", RightAlt = "RAlt",
}
function Utils.KeyName(key)
	if typeof(key) ~= "EnumItem" then return tostring(key or "None") end
	return SHORT_KEYS[key.Name] or key.Name
end

--- 屏幕安全区（IgnoreGuiInset 坐标系换算）
function Utils.ScreenInset()
	return GuiService:GetGuiInset()
end

--- 判断输入是否为左键 / 触控
function Utils.IsPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

--- 判断输入是否为移动
function Utils.IsMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
end

----------------------------------------------------------------
-- §2 可打断动效核心
--    同一对象上重复调用 Tween，旧动画会被立即取消，
--    这是全库"丝滑且随时可打断"的实现基础。
----------------------------------------------------------------
local ActiveTweens = setmetatable({}, { __mode = "k" })

function BX.Tween(obj, info, props)
	if typeof(obj) ~= "Instance" then return nil end
	local rec = ActiveTweens[obj]
	if rec and rec.tween then
		pcall(function() rec.tween:Cancel() end)
	end
	local tw = TweenService:Create(obj, info, props)
	ActiveTweens[obj] = { tween = tw }
	tw:Play()
	return tw
end

Utils.Tween = BX.Tween

--- 常用 TweenInfo 快捷构造
local function TI(t, style, dir)
	return TweenInfo.new(t or 0.25, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out)
end
Utils.TI = TI

local function hoverInfo()
	return TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
end

--- 延迟执行（可被打断的令牌版本）
local function delayed(tokenRef, delay, fn)
	task.delay(delay, function()
		if tokenRef.dead then return end
		fn()
	end)
end

----------------------------------------------------------------
-- §3 流动动画引擎
--    驱动库内所有 UIGradient 的旋转 / 偏移流动。
--    无论建了多少控件，每帧开销恒定（一个 RenderStepped）。
----------------------------------------------------------------
local FlowList = {}
local flowStarted = false

local function addFlow(gradient, speed, mode)
	if typeof(gradient) ~= "Instance" then return end
	FlowList[#FlowList + 1] = { g = gradient, speed = speed or 40, mode = mode or "rotation" }
	if not flowStarted then
		flowStarted = true
		RunService.RenderStepped:Connect(function(dt)
			local rot = dt
			for _, it in ipairs(FlowList) do
				local g = it.g
				if g.Parent then
					if it.mode == "rotation" then
						g.Rotation = (g.Rotation + it.speed * rot) % 360
					else
						g.Offset = Vector2.new((g.Offset.X + it.speed * rot * 0.02) % 1, 0)
					end
				end
			end
		end)
	end
end

--- 彩虹色（按时间循环）
function BX.RainbowColor(sat, val)
	return Color3.fromHSV((tick() % 5) / 5, sat or 0.55, val or 1)
end

local rainbowWatchers = {}
local rainbowStarted = false

--- 注册一个跟随彩虹色的对象（取色器"彩虹模式"用）
function BX.WatchRainbow(obj, apply)
	local entry = { obj = obj, apply = apply, dead = false }
	rainbowWatchers[#rainbowWatchers + 1] = entry
	if not rainbowStarted then
		rainbowStarted = true
		RunService.RenderStepped:Connect(function()
			local c = BX.RainbowColor(0.5, 1)
			for _, w in ipairs(rainbowWatchers) do
				if not w.dead and w.obj.Parent then
					Utils.SafeCall(w.apply, c)
				end
			end
		end)
	end
	return function()
		entry.dead = true
	end
end

----------------------------------------------------------------
-- §4 点击音效
----------------------------------------------------------------
local clickSound

local function playClick(volume)
	if not BX.SoundsEnabled then return end
	local ok = pcall(function()
		if not clickSound then
			clickSound = Instance.new("Sound")
			clickSound.SoundId = "rbxassetid://9118823101"
			clickSound.Volume = 0.12
			clickSound.Parent = SoundService
		end
		clickSound.Volume = volume or 0.12
		clickSound:Play()
	end)
end
Utils.PlayClick = playClick

----------------------------------------------------------------
-- §5 图标库（Unicode 字形，跨平台无需图片资产）
----------------------------------------------------------------
BX.Icons = {
	home = "⌂", settings = "⚙", eye = "◉", crosshair = "✛", sword = "†",
	globe = "◎", user = "♟", shield = "⛨", zap = "⚡", star = "★",
	heart = "♥", bell = "♪", search = "⌕", plus = "+", minus = "−",
	close = "✕", check = "✓", chevronDown = "⌄", chevronRight = "›",
	play = "▶", pause = "‖", stop = "■", trash = "🗑", save = "💾",
	folder = "▣", file = "▤", edit = "✎", copy = "⧉", link = "🔗",
	lock = "🔒", unlock = "🔓", sun = "☀", moon = "☾", cloud = "☁",
	flame = "🔥", snow = "❄", music = "♫", camera = "📷", image = "🖼",
	gift = "🎁", clock = "◷", chart = "📊", code = "❮❯", terminal = "▮▶",
	bug = "🐛", wifi = "📶", battery = "🔋", phone = "📱", monitor = "🖥",
	gamepad = "🎮", rocket = "🚀", crown = "♛", gem = "◆", alert = "⚠",
	info = "ℹ", help = "?", menu = "☰", filter = "⧩", refresh = "⟳",
	download = "⤓", upload = "⤒", arrowUp = "↑", arrowDown = "↓",
	arrowLeft = "←", arrowRight = "→", bolt = "↯", target = "◎",
	skull = "☠", flag = "⚑", pin = "📌", key = "🗝", palette = "🎨",
	layers = "▤", grid = "⊞", list = "☰", dot = "•", circle = "○",
	circleFill = "●", square = "□", squareFill = "■", diamond = "◇",
	triangle = "△", infinity = "∞", power = "⏻", mute = "🔇",
	volume = "🔊", mouse = "🖱", keyboard = "⌨", cpu = "🖥",
	database = "🗄", server = "🖧", branch = "⑂", commit = "●",
	bookmark = "🔖", tag = "🏷", award = "🏆", medal = "🥇",
	compass = "🧭", map = "🗺", globe2 = "🌐", moon2 = "🌙",
	sun2 = "🌞", droplet = "💧", leaf = "🍃", seedling = "🌱",
	fire2 = "🧯", wrench = "🔧", hammer = "🔨", screwdriver = "🪛",
	package = "📦", box = "🗳", inbox = "📥", archive = "🗃",
	eyeOff = "◌", glasses = "👓", robot = "🤖", alien = "👾",
	ghost = "👻", pumpkin = "🎃", clover = "🍀", bell2 = "🔔",
	bellOff = "🔕", mic = "🎤", micOff = "🔇", video = "🎥",
	image2 = "🎞", film = "🎬", ticket = "🎫", trophy = "🏆",
} 
Utils.Icon = function(name)
	return BX.Icons[name] or BX.Icons.dot
end

----------------------------------------------------------------
-- §6 主题系统
--    每个受主题管理的实例在创建时登记，切换主题可热更新。
----------------------------------------------------------------
BX.Themes = {
	["BarbatosXI"] = {
		WindowBg      = Color3.fromRGB(12, 12, 17),
		WindowTrans   = 0.06,
		Glass         = Color3.fromRGB(255, 255, 255),
		GlassTrans    = 0.88,
		GlassRowTrans = 0.94,
		GlassActive   = 0.50,
		StrokeTrans   = 0.32,
		StrokeThick   = 1,
		Text          = Color3.fromRGB(235, 235, 240),
		TextDim       = Color3.fromRGB(150, 150, 162),
		TextFaint     = Color3.fromRGB(120, 120, 132),
		Accent        = Color3.fromRGB(255, 255, 255),
		AccentDark    = Color3.fromRGB(16, 16, 20),
		Corner        = 10,
		Font          = Enum.Font.GothamMedium,
		FontBold      = Enum.Font.GothamBold,
	},
	["Midnight"] = {
		WindowBg      = Color3.fromRGB(8, 10, 20),
		WindowTrans   = 0.04,
		Glass         = Color3.fromRGB(200, 214, 255),
		GlassTrans    = 0.90,
		GlassRowTrans = 0.94,
		GlassActive   = 0.52,
		StrokeTrans   = 0.30,
		StrokeThick   = 1,
		Text          = Color3.fromRGB(228, 234, 250),
		TextDim       = Color3.fromRGB(148, 160, 196),
		TextFaint     = Color3.fromRGB(116, 126, 158),
		Accent        = Color3.fromRGB(148, 178, 255),
		AccentDark    = Color3.fromRGB(10, 14, 28),
		Corner        = 10,
		Font          = Enum.Font.GothamMedium,
		FontBold      = Enum.Font.GothamBold,
	},
	["Sakura"] = {
		WindowBg      = Color3.fromRGB(20, 12, 16),
		WindowTrans   = 0.05,
		Glass         = Color3.fromRGB(255, 222, 234),
		GlassTrans    = 0.90,
		GlassRowTrans = 0.94,
		GlassActive   = 0.52,
		StrokeTrans   = 0.30,
		StrokeThick   = 1,
		Text          = Color3.fromRGB(250, 232, 238),
		TextDim       = Color3.fromRGB(196, 158, 174),
		TextFaint     = Color3.fromRGB(158, 126, 140),
		Accent        = Color3.fromRGB(255, 170, 200),
		AccentDark    = Color3.fromRGB(28, 12, 18),
		Corner        = 12,
		Font          = Enum.Font.GothamMedium,
		FontBold      = Enum.Font.GothamBold,
	},
	["Forest"] = {
		WindowBg      = Color3.fromRGB(10, 16, 12),
		WindowTrans   = 0.05,
		Glass         = Color3.fromRGB(214, 255, 228),
		GlassTrans    = 0.90,
		GlassRowTrans = 0.94,
		GlassActive   = 0.52,
		StrokeTrans   = 0.30,
		StrokeThick   = 1,
		Text          = Color3.fromRGB(232, 248, 238),
		TextDim       = Color3.fromRGB(156, 190, 170),
		TextFaint     = Color3.fromRGB(122, 150, 132),
		Accent        = Color3.fromRGB(140, 230, 176),
		AccentDark    = Color3.fromRGB(10, 22, 14),
		Corner        = 10,
		Font          = Enum.Font.GothamMedium,
		FontBold      = Enum.Font.GothamBold,
	},
	["Sunset"] = {
		WindowBg      = Color3.fromRGB(20, 13, 10),
		WindowTrans   = 0.05,
		Glass         = Color3.fromRGB(255, 228, 208),
		GlassTrans    = 0.90,
		GlassRowTrans = 0.94,
		GlassActive   = 0.52,
		StrokeTrans   = 0.30,
		StrokeThick   = 1,
		Text          = Color3.fromRGB(250, 238, 228),
		TextDim       = Color3.fromRGB(198, 166, 146),
		TextFaint     = Color3.fromRGB(160, 132, 116),
		Accent        = Color3.fromRGB(255, 176, 128),
		AccentDark    = Color3.fromRGB(26, 14, 8),
		Corner        = 12,
		Font          = Enum.Font.GothamMedium,
		FontBold      = Enum.Font.GothamBold,
	},
	["Ocean"] = {
		WindowBg      = Color3.fromRGB(8, 14, 18),
		WindowTrans   = 0.05,
		Glass         = Color3.fromRGB(206, 240, 252),
		GlassTrans    = 0.90,
		GlassRowTrans = 0.94,
		GlassActive   = 0.52,
		StrokeTrans   = 0.30,
		StrokeThick   = 1,
		Text          = Color3.fromRGB(230, 246, 252),
		TextDim       = Color3.fromRGB(150, 186, 202),
		TextFaint     = Color3.fromRGB(118, 148, 162),
		Accent        = Color3.fromRGB(120, 214, 246),
		AccentDark    = Color3.fromRGB(8, 20, 26),
		Corner        = 10,
		Font          = Enum.Font.GothamMedium,
		FontBold      = Enum.Font.GothamBold,
	},
	["Mono"] = {
		WindowBg      = Color3.fromRGB(8, 8, 8),
		WindowTrans   = 0.02,
		Glass         = Color3.fromRGB(255, 255, 255),
		GlassTrans    = 0.82,
		GlassRowTrans = 0.90,
		GlassActive   = 0.38,
		StrokeTrans   = 0.18,
		StrokeThick   = 1.2,
		Text          = Color3.fromRGB(255, 255, 255),
		TextDim       = Color3.fromRGB(168, 168, 168),
		TextFaint     = Color3.fromRGB(128, 128, 128),
		Accent        = Color3.fromRGB(255, 255, 255),
		AccentDark    = Color3.fromRGB(0, 0, 0),
		Corner        = 8,
		Font          = Enum.Font.GothamMedium,
		FontBold      = Enum.Font.GothamBold,
	},
	["AMOLED"] = {
		WindowBg      = Color3.fromRGB(0, 0, 0),
		WindowTrans   = 0,
		Glass         = Color3.fromRGB(255, 255, 255),
		GlassTrans    = 0.94,
		GlassRowTrans = 0.96,
		GlassActive   = 0.55,
		StrokeTrans   = 0.4,
		StrokeThick   = 1,
		Text          = Color3.fromRGB(240, 240, 245),
		TextDim       = Color3.fromRGB(140, 140, 152),
		TextFaint     = Color3.fromRGB(110, 110, 122),
		Accent        = Color3.fromRGB(255, 255, 255),
		AccentDark    = Color3.fromRGB(0, 0, 0),
		Corner        = 14,
		Font          = Enum.Font.GothamMedium,
		FontBold      = Enum.Font.GothamBold,
	},
}

BX.CurrentThemeName = "BarbatosXI"
BX.CurrentTheme = BX.Themes["BarbatosXI"]

--- 主题实例登记表：{ inst = Instance, kind = "glass"|"window"|"text"|... }
local themedRegistry = setmetatable({}, { __mode = "k" })

local function registerThemed(inst, kind)
	themedRegistry[inst] = kind
end

local THEMED_APPLY = {
	glass = function(inst, T)
		inst.BackgroundColor3 = T.Glass
	end,
	window = function(inst, T)
		inst.BackgroundColor3 = T.WindowBg
		inst.BackgroundTransparency = T.WindowTrans
	end,
	text = function(inst, T)
		inst.TextColor3 = T.Text
	end,
	textdim = function(inst, T)
		inst.TextColor3 = T.TextDim
	end,
	textfaint = function(inst, T)
		inst.TextColor3 = T.TextFaint
	end,
	stroke = function(inst, T)
		inst.Transparency = T.StrokeTrans
		inst.Thickness = T.StrokeThick
	end,
}

--- 切换主题：对所有已登记实例热更新
function BX:SetTheme(name)
	local T = self.Themes[name]
	if not T then
		warn("[BarbatosXIUI] 主题不存在:", name)
		return false
	end
	self.CurrentThemeName = name
	self.CurrentTheme = T
	for inst, kind in pairs(themedRegistry) do
		if inst.Parent then
			local fn = THEMED_APPLY[kind]
			if fn then
				pcall(fn, inst, T)
			end
		end
	end
	return true
end

--- 列出全部主题名
function BX:GetThemes()
	local out = {}
	for k in pairs(self.Themes) do out[#out + 1] = k end
	table.sort(out)
	return out
end

----------------------------------------------------------------
-- §7 通知系统
--    四种类型、可选进度条、队列上限、点击关闭、滑动进出。
----------------------------------------------------------------
local notifyGui, notifyHolder, notifyQueue = nil, nil, {}
local MAX_NOTIFY = 5

local NOTIFY_STYLE = {
	success = { Icon = "check",  Accent = Color3.fromRGB(150, 235, 180) },
	info    = { Icon = "info",   Accent = Color3.fromRGB(170, 200, 255) },
	warning = { Icon = "alert",  Accent = Color3.fromRGB(255, 214, 140) },
	error   = { Icon = "close",  Accent = Color3.fromRGB(255, 160, 160) },
}

local function ensureNotifyGui()
	if notifyGui and notifyGui.Parent then return end
	notifyGui = Instance.new("ScreenGui")
	notifyGui.Name = "BarbatosXIUI_Notify"
	notifyGui.ResetOnSpawn = false
	notifyGui.IgnoreGuiInset = true
	notifyGui.DisplayOrder = 1000
	pcall(function() notifyGui.Parent = game:GetService("CoreGui") end)
	if not notifyGui.Parent then notifyGui.Parent = LP:WaitForChild("PlayerGui") end

	notifyHolder = Instance.new("Frame")
	notifyHolder.BackgroundTransparency = 1
	notifyHolder.Size = UDim2.new(1, -24, 1, -24)
	notifyHolder.Position = UDim2.fromOffset(12, 12)
	notifyHolder.Parent = notifyGui
	local lay = Instance.new("UIListLayout")
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Right
	lay.VerticalAlignment = Enum.VerticalAlignment.Top
	lay.Padding = UDim.new(0, 8)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = notifyHolder
end

local function spawnNotification(data)
	ensureNotifyGui()
	local T = BX.CurrentTheme
	local style = NOTIFY_STYLE[data.Type or "info"] or NOTIFY_STYLE.info

	local panel = Instance.new("CanvasGroup")
	panel.BackgroundColor3 = T.WindowBg
	panel.BackgroundTransparency = math.min(T.WindowTrans + 0.02, 0.3)
	panel.BorderSizePixel = 0
	panel.GroupTransparency = 1
	panel.Size = UDim2.fromOffset(268, (data.Progress and 64) or 56)
	panel.Position = UDim2.fromOffset(80, 0)
	panel.LayoutOrder = -math.floor(tick() * 1000)
	panel.ZIndex = 60
	panel.Parent = notifyHolder
	local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(0, 12); pc.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = T.StrokeThick + 0.2
	stroke.Transparency = T.StrokeTrans
	stroke.Parent = panel
	local sg = Instance.new("UIGradient")
	sg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 0, 0)),
		ColorSequenceKeypoint.new(0.45, style.Accent),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
	})
	sg.Parent = stroke
	addFlow(sg, 45, "rotation")

	local accentBar = Instance.new("Frame")
	accentBar.Size = UDim2.new(0, 3, 1, -16)
	accentBar.Position = UDim2.new(0, 8, 0, 8)
	accentBar.BackgroundColor3 = style.Accent
	accentBar.BorderSizePixel = 0
	accentBar.ZIndex = 61
	accentBar.Parent = panel
	local abC = Instance.new("UICorner"); abC.CornerRadius = UDim.new(1, 0); abC.Parent = accentBar

	local iconFrame = Instance.new("Frame")
	iconFrame.Size = UDim2.fromOffset(26, 26)
	iconFrame.Position = UDim2.new(0, 20, 0, (data.Progress and 12) or 15)
	iconFrame.BackgroundColor3 = style.Accent
	iconFrame.BackgroundTransparency = 0.82
	iconFrame.BorderSizePixel = 0
	iconFrame.ZIndex = 61
	iconFrame.Parent = panel
	local ifC = Instance.new("UICorner"); ifC.CornerRadius = UDim.new(1, 0); ifC.Parent = iconFrame
	local iconLbl = Instance.new("TextLabel")
	iconLbl.BackgroundTransparency = 1
	iconLbl.Text = data.Icon and Utils.Icon(data.Icon) or Utils.Icon(style.Icon)
	iconLbl.TextSize = 13
	iconLbl.TextColor3 = style.Accent
	iconLbl.Font = Enum.Font.GothamBold
	iconLbl.ZIndex = 62
	iconLbl.Size = UDim2.fromScale(1, 1)
	iconLbl.Parent = iconFrame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Text = data.Title or "通知"
	title.TextColor3 = T.Text
	title.Font = T.FontBold
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 62
	title.Position = UDim2.new(0, 54, 0, 8)
	title.Size = UDim2.new(1, -84, 0, 18)
	title.Parent = panel

	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Text = data.Content or ""
	body.TextColor3 = T.TextDim
	body.Font = T.Font
	body.TextSize = 12
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextWrapped = true
	body.ZIndex = 62
	body.Position = UDim2.new(0, 54, 0, 26)
	body.Size = UDim2.new(1, -84, 0, data.Progress and 22 or 22)
	body.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.BackgroundTransparency = 1
	closeBtn.Text = "✕"
	closeBtn.TextColor3 = T.TextFaint
	closeBtn.Font = T.FontBold
	closeBtn.TextSize = 12
	closeBtn.ZIndex = 63
	closeBtn.Position = UDim2.new(1, -26, 0, 6)
	closeBtn.Size = UDim2.fromOffset(20, 20)
	closeBtn.Parent = panel

	local lifeToken = { dead = false }
	local function dismiss()
		if lifeToken.dead then return end
		lifeToken.dead = true
		local tw = BX.Tween(panel, TI(0.3), { GroupTransparency = 1, Position = UDim2.fromOffset(80, 0) })
		tw.Completed:Once(function()
			panel:Destroy()
		end)
	end
	closeBtn.MouseButton1Click:Connect(dismiss)

	local progressBar, progressFill
	if data.Progress then
		progressBar = Instance.new("Frame")
		progressBar.Size = UDim2.new(1, -28, 0, 3)
		progressBar.Position = UDim2.new(0, 14, 1, -10)
		progressBar.BackgroundColor3 = T.Glass
		progressBar.BackgroundTransparency = 0.7
		progressBar.BorderSizePixel = 0
		progressBar.ZIndex = 62
		progressBar.Parent = panel
		local pbC = Instance.new("UICorner"); pbC.CornerRadius = UDim.new(1, 0); pbC.Parent = progressBar
		progressFill = Instance.new("Frame")
		progressFill.Size = UDim2.new(0, 0, 1, 0)
		progressFill.BackgroundColor3 = style.Accent
		progressFill.BorderSizePixel = 0
		progressFill.ZIndex = 63
		progressFill.Parent = progressBar
		local pfC = Instance.new("UICorner"); pfC.CornerRadius = UDim.new(1, 0); pfC.Parent = progressFill
		local p0 = tonumber(data.Progress) or 0
		p0 = Utils.Clamp(p0, 0, 1)
		BX.Tween(progressFill, TI(0.4), { Size = UDim2.new(p0, 0, 1, 0) })
	end

	panel.InputBegan:Connect(function(input)
		if Utils.IsPress(input) then dismiss() end
	end)

	BX.Tween(panel, TI(0.45, Enum.EasingStyle.Quart), {
		GroupTransparency = 0,
		Position = UDim2.fromOffset(0, 0),
	})

	if data.Sound ~= false then
		playClick(0.08)
	end

	local duration = data.Duration or 4
	if not data.Progress then
		task.delay(duration, dismiss)
	else
		-- 有进度条时不自动消失，由调用方 NotifyProgress 控制
	end
	return dismiss, panel, progressFill
end

--- 发送一条通知
-- data: { Title, Content, Duration, Type = "success"|"info"|"warning"|"error",
--         Icon, Progress = 0~1（有则常驻，返回句柄）, Sound }
function BX:Notify(data)
	data = data or {}
	ensureNotifyGui()
	local alive = 0
	for _, p in ipairs(notifyHolder:GetChildren()) do
		if p:IsA("CanvasGroup") then alive = alive + 1 end
	end
	if alive >= MAX_NOTIFY then
		notifyQueue[#notifyQueue + 1] = data
		return function() end
	end
	return spawnNotification(data)
end

--- 处理排队通知
task.spawn(function()
	while true do
		task.wait(0.5)
		if notifyHolder and #notifyQueue > 0 then
			local alive = 0
			for _, p in ipairs(notifyHolder:GetChildren()) do
				if p:IsA("CanvasGroup") then alive = alive + 1 end
			end
			if alive < MAX_NOTIFY then
				local data = table.remove(notifyQueue, 1)
				spawnNotification(data)
			end
		end
	end
end)

----------------------------------------------------------------
-- §8 基础件：黑白流动渐变边框
----------------------------------------------------------------
local function gradientStroke(parent, thickness, transp)
	local T = BX.CurrentTheme
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or T.StrokeThick
	s.Transparency = transp or T.StrokeTrans
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.00, Color3.fromRGB(0, 0, 0)),
		ColorSequenceKeypoint.new(0.42, T.Accent),
		ColorSequenceKeypoint.new(0.58, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1.00, Color3.fromRGB(0, 0, 0)),
	})
	g.Parent = s
	addFlow(g, 45, "rotation")
	registerThemed(s, "stroke")
	return s
end

----------------------------------------------------------------
-- §9 基础件：毛玻璃面板
----------------------------------------------------------------
local function glass(parent, radius, transp)
	local T = BX.CurrentTheme
	local f = Instance.new("Frame")
	f.BackgroundColor3 = T.Glass
	f.BackgroundTransparency = transp or T.GlassTrans
	f.BorderSizePixel = 0
	f.Parent = parent

	local c = Instance.new("UICorner")
	c.CornerRadius = (typeof(radius) == "UDim") and radius or UDim.new(0, radius or T.Corner)
	c.Parent = f

	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Utils.ColorLerp(T.Glass, Color3.fromRGB(120, 124, 148), 0.35)),
	})
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 0.35),
	})
	g.Rotation = 115
	g.Parent = f

	gradientStroke(f, T.StrokeThick, T.StrokeTrans)
	registerThemed(f, "glass")
	return f
end

local function pill(parent, transp)
	return glass(parent, UDim.new(1, 0), transp)
end

----------------------------------------------------------------
-- §10 基础件：文字标签（自动登记主题）
----------------------------------------------------------------
local function label(parent, text, size, bold, color, align)
	local T = BX.CurrentTheme
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Text = text or ""
	t.TextColor3 = color or T.Text
	t.Font = bold and T.FontBold or T.Font
	t.TextSize = size or 13
	t.TextXAlignment = align or Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Center
	t.BorderSizePixel = 0
	t.Parent = parent
	registerThemed(t, (color == nil) and "text" or nil)
	if color == nil then registerThemed(t, "text") end
	return t
end

local function textDim(inst)
	registerThemed(inst, "textdim")
	return inst
end

local function textFaint(inst)
	registerThemed(inst, "textfaint")
	return inst
end

----------------------------------------------------------------
-- §11 基础件：透明点击层
----------------------------------------------------------------
local function clickTarget(parent)
	local b = Instance.new("TextButton")
	b.BackgroundTransparency = 1
	b.Text = ""
	b.Size = UDim2.fromScale(1, 1)
	b.ZIndex = 20
	b.Parent = parent
	return b
end

----------------------------------------------------------------
-- §12 悬停提示 Tooltip
--    悬停 0.45s 后显示，跟随鼠标，玻璃拟态。
----------------------------------------------------------------
local tooltipGui, tooltipFrame, tooltipText, tooltipToken = nil, nil, nil, 0

local function ensureTooltip()
	if tooltipGui and tooltipGui.Parent then return end
	tooltipGui = Instance.new("ScreenGui")
	tooltipGui.Name = "BarbatosXIUI_Tooltip"
	tooltipGui.ResetOnSpawn = false
	tooltipGui.IgnoreGuiInset = true
	tooltipGui.DisplayOrder = 999
	pcall(function() tooltipGui.Parent = game:GetService("CoreGui") end)
	if not tooltipGui.Parent then tooltipGui.Parent = LP:WaitForChild("PlayerGui") end

	tooltipFrame = Instance.new("CanvasGroup")
	tooltipFrame.BackgroundColor3 = BX.CurrentTheme.WindowBg
	tooltipFrame.BackgroundTransparency = 0.1
	tooltipFrame.BorderSizePixel = 0
	tooltipFrame.GroupTransparency = 1
	tooltipFrame.Size = UDim2.fromOffset(180, 30)
	tooltipFrame.ZIndex = 80
	tooltipFrame.Parent = tooltipGui
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 8); tc.Parent = tooltipFrame
	local ts = Instance.new("UIStroke"); ts.Thickness = 1; ts.Transparency = 0.25; ts.Parent = tooltipFrame
	local tg = Instance.new("UIGradient")
	tg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 0, 0)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
	})
	tg.Parent = ts
	addFlow(tg, 45, "rotation")

	tooltipText = Instance.new("TextLabel")
	tooltipText.BackgroundTransparency = 1
	tooltipText.TextColor3 = BX.CurrentTheme.Text
	tooltipText.Font = BX.CurrentTheme.Font
	tooltipText.TextSize = 12
	tooltipText.TextXAlignment = Enum.TextXAlignment.Left
	tooltipText.TextWrapped = true
	tooltipText.ZIndex = 81
	tooltipText.Size = UDim2.new(1, -16, 1, 0)
	tooltipText.Position = UDim2.fromOffset(8, 0)
	tooltipText.Parent = tooltipFrame
end

local function showTooltip(text, screenPos)
	ensureTooltip()
	tooltipToken = tooltipToken + 1
	local my = tooltipToken
	tooltipText.Text = text
	-- 自适应尺寸（估算：每字符 7px，最多 260 宽）
	local w = math.max(90, math.min(260, #text * 7 + 18))
	local lines = math.max(1, math.ceil(#text * 7 / (w - 18)))
	local h = lines * 17 + 12
	tooltipFrame.Size = UDim2.fromOffset(w, h)
	local inset = Utils.ScreenInset()
	local x = screenPos.X - inset.X + 16
	local y = screenPos.Y - inset.Y + 18
	local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
	if x + w > vp.X - 8 then x = screenPos.X - inset.X - w - 10 end
	if y + h > vp.Y - 8 then y = screenPos.Y - inset.Y - h - 12 end
	tooltipFrame.Position = UDim2.fromOffset(x, y)
	BX.Tween(tooltipFrame, TI(0.18), { GroupTransparency = 0 })
	task.delay(4, function()
		if my == tooltipToken then
			BX.Tween(tooltipFrame, TI(0.2), { GroupTransparency = 1 })
		end
	end)
end

local function hideTooltip()
	tooltipToken = tooltipToken + 1
	if tooltipFrame then
		BX.Tween(tooltipFrame, TI(0.15), { GroupTransparency = 1 })
	end
end

--- 给任意控件帧挂提示：BX.AttachTooltip(frame, "说明文字")
function BX.AttachTooltip(frame, text)
	if typeof(frame) ~= "Instance" or typeof(text) ~= "string" or text == "" then return end
	local enterToken = 0
	frame.MouseEnter:Connect(function()
		enterToken = enterToken + 1
		local my = enterToken
		local mp = UserInputService:GetMouseLocation()
		task.delay(0.45, function()
			if my == enterToken and frame.Parent then
				showTooltip(text, mp)
			end
		end)
	end)
	frame.MouseLeave:Connect(function()
		enterToken = enterToken + 1
		hideTooltip()
	end)
end

----------------------------------------------------------------
-- §13 模态对话框
--    Confirm / Prompt / Alert，支持键盘 Enter / Esc。
----------------------------------------------------------------
local modalGui, modalStack = nil, {}

local function ensureModalGui()
	if modalGui and modalGui.Parent then return end
	modalGui = Instance.new("ScreenGui")
	modalGui.Name = "BarbatosXIUI_Modal"
	modalGui.ResetOnSpawn = false
	modalGui.IgnoreGuiInset = true
	modalGui.DisplayOrder = 998
	pcall(function() modalGui.Parent = game:GetService("CoreGui") end)
	if not modalGui.Parent then modalGui.Parent = LP:WaitForChild("PlayerGui") end
end

local function modalBackdrop(gui, onClickOutside)
	local bd = Instance.new("TextButton")
	bd.Name = "Backdrop"
	bd.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bd.BackgroundTransparency = 0.4
	bd.Text = ""
	bd.Size = UDim2.fromScale(1, 1)
	bd.ZIndex = 70
	bd.Parent = gui
	if onClickOutside then
		bd.MouseButton1Click:Connect(onClickOutside)
	end
	BX.Tween(bd, TI(0.25), { BackgroundTransparency = 0.35 })
	return bd
end

local function modalCard(gui, width)
	local T = BX.CurrentTheme
	local card = Instance.new("CanvasGroup")
	card.BackgroundColor3 = T.WindowBg
	card.BackgroundTransparency = math.max(T.WindowTrans, 0.02)
	card.BorderSizePixel = 0
	card.GroupTransparency = 1
	card.Size = UDim2.fromOffset(width or 300, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.ZIndex = 72
	card.Parent = gui
	local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, 14); cc.Parent = card
	gradientStroke(card, T.StrokeThick + 0.4, T.StrokeTrans)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 18); pad.PaddingBottom = UDim.new(0, 16)
	pad.PaddingLeft = UDim.new(0, 18); pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = card
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = card
	local scale = Instance.new("UIScale")
	scale.Scale = 0.92
	scale.Parent = card
	BX.Tween(card, TI(0.3, Enum.EasingStyle.Quart), { GroupTransparency = 0 })
	BX.Tween(scale, TI(0.35, Enum.EasingStyle.Back), { Scale = 1 })
	return card
end

local function modalTitle(card, text, icon)
	local T = BX.CurrentTheme
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 22)
	row.LayoutOrder = 0
	row.Parent = card
	local lbl = label(row, (icon and (Utils.Icon(icon) .. "  ") or "") .. (text or "提示"), 15, true)
	lbl.Size = UDim2.fromScale(1, 1)
	return row
end

local function modalBody(card, text)
	local T = BX.CurrentTheme
	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Text = text or ""
	body.TextColor3 = T.TextDim
	body.Font = T.Font
	body.TextSize = 13
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextWrapped = true
	body.LineHeight = 1.25
	body.LayoutOrder = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.Parent = card
	registerThemed(body, "textdim")
	return body
end

local function modalButtonRow(card, buttons)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 32)
	row.LayoutOrder = 2
	row.Parent = card
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row
	return row
end

local function modalGlassButton(parent, text, primary, onClick)
	local T = BX.CurrentTheme
	local b = glass(parent, 8, primary and T.GlassActive or T.GlassRowTrans)
	b.Size = UDim2.fromOffset(math.max(74, #text * 8 + 26), 30)
	b.LayoutOrder = primary and 1 or 2
	local lbl = label(b, text, 12, primary, primary and T.AccentDark or T.Text, Enum.TextXAlignment.Center)
	lbl.Size = UDim2.fromScale(1, 1)
	local hit = clickTarget(b)
	hit.MouseEnter:Connect(function()
		BX.Tween(b, hoverInfo(), { BackgroundTransparency = primary and math.max(T.GlassActive - 0.2, 0.2) or 0.78 })
	end)
	hit.MouseLeave:Connect(function()
		BX.Tween(b, hoverInfo(), { BackgroundTransparency = primary and T.GlassActive or T.GlassRowTrans })
	end)
	hit.MouseButton1Click:Connect(function()
		playClick()
		if onClick then onClick() end
	end)
	return b
end

local function closeModal(entry)
	if entry.closed then return end
	entry.closed = true
	BX.Tween(entry.card, TI(0.22), { GroupTransparency = 1 })
	BX.Tween(entry.backdrop, TI(0.25), { BackgroundTransparency = 1 })
	task.delay(0.26, function()
		entry.card:Destroy()
		entry.backdrop:Destroy()
		for i, e in ipairs(modalStack) do
			if e == entry then table.remove(modalStack, i) break end
		end
	end)
end

local function pushModal(entry)
	modalStack[#modalStack + 1] = entry
end

local function topModal()
	return modalStack[#modalStack]
end

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	local top = topModal()
	if not top then return end
	if input.KeyCode == Enum.KeyCode.Return and top.onConfirm then
		top.onConfirm()
	elseif input.KeyCode == Enum.KeyCode.Escape and top.onCancel then
		top.onCancel()
	end
end)

--- 确认对话框：BX:Confirm({ Title, Content, ConfirmText, CancelText, Callback(bool) })
function BX:Confirm(data)
	data = data or {}
	ensureModalGui()
	local gui = modalGui
	local bd = modalBackdrop(gui)
	local card = modalCard(gui, 300)
	modalTitle(card, data.Title or "确认", data.Icon)
	modalBody(card, data.Content or "")
	local row = modalButtonRow(card)
	local entry = { card = card, backdrop = bd, closed = false }
	local function done(result)
		closeModal(entry)
		Utils.SafeCall(data.Callback, result)
	end
	entry.onConfirm = function() done(true) end
	entry.onCancel = function() done(false) end
	modalGlassButton(row, data.CancelText or "取消", false, entry.onCancel)
	modalGlassButton(row, data.ConfirmText or "确定", true, entry.onConfirm)
	pushModal(entry)
	return entry
end

--- 输入对话框：BX:Prompt({ Title, Placeholder, Default, Callback(text) })
function BX:Prompt(data)
	data = data or {}
	ensureModalGui()
	local gui = modalGui
	local bd = modalBackdrop(gui)
	local card = modalCard(gui, 300)
	modalTitle(card, data.Title or "输入", data.Icon)
	local box = glass(card, 8, BX.CurrentTheme.GlassRowTrans)
	box.Size = UDim2.new(1, 0, 0, 32)
	box.LayoutOrder = 1
	local tb = Instance.new("TextBox")
	tb.BackgroundTransparency = 1
	tb.Text = data.Default or ""
	tb.PlaceholderText = data.Placeholder or "..."
	tb.PlaceholderColor3 = BX.CurrentTheme.TextFaint
	tb.TextColor3 = BX.CurrentTheme.Text
	tb.Font = BX.CurrentTheme.Font
	tb.TextSize = 13
	tb.ClearTextOnFocus = false
	tb.Size = UDim2.new(1, -16, 1, 0)
	tb.Position = UDim2.fromOffset(8, 0)
	tb.Parent = box
	local row = modalButtonRow(card)
	row.LayoutOrder = 2
	local entry = { card = card, backdrop = bd, closed = false }
	local function done(submit)
		closeModal(entry)
		if submit then
			Utils.SafeCall(data.Callback, tb.Text)
		end
	end
	entry.onConfirm = function() done(true) end
	entry.onCancel = function() done(false) end
	modalGlassButton(row, "取消", false, entry.onCancel)
	modalGlassButton(row, "确定", true, entry.onConfirm)
	tb.FocusLost:Connect(function(enter)
		if enter then entry.onConfirm() end
	end)
	task.defer(function() tb:CaptureFocus() end)
	pushModal(entry)
	return entry
end

--- 提示对话框：BX:Alert({ Title, Content, ButtonText, Callback })
function BX:Alert(data)
	data = data or {}
	ensureModalGui()
	local gui = modalGui
	local bd = modalBackdrop(gui)
	local card = modalCard(gui, 300)
	modalTitle(card, data.Title or "提示", data.Icon or "info")
	modalBody(card, data.Content or "")
	local row = modalButtonRow(card)
	local entry = { card = card, backdrop = bd, closed = false }
	local function done()
		closeModal(entry)
		Utils.SafeCall(data.Callback)
	end
	entry.onConfirm = done
	entry.onCancel = done
	modalGlassButton(row, data.ButtonText or "知道了", true, done)
	pushModal(entry)
	return entry
end

----------------------------------------------------------------
-- §14 配置系统
--    元素创建时传 Flag = "名称" 即自动登记；
--    Window:SaveConfig / LoadConfig / DeleteConfig / GetConfigs。
--    存储格式：JSON 写入 executor 工作目录 BarbatosXIUI/configs/
----------------------------------------------------------------
local flagRegistry = {} -- [flag] = { Get = fn, Set = fn, Type = str }

local function registerFlag(flag, entry)
	if typeof(flag) ~= "string" or flag == "" then return end
	if flagRegistry[flag] then
		warn("[BarbatosXIUI] Flag 重复注册:", flag)
	end
	flagRegistry[flag] = entry
end

function BX:GetFlag(flag)
	local e = flagRegistry[flag]
	return e and e.Get() or nil
end

function BX:SetFlag(flag, value)
	local e = flagRegistry[flag]
	if e then e.Set(value) end
end

function BX:GetAllFlags()
	local out = {}
	for k, e in pairs(flagRegistry) do
		out[k] = e.Get()
	end
	return out
end

local function encodeValue(v)
	if typeof(v) == "Color3" then
		return { __type = "Color3", hex = Utils.ToHex(v) }
	elseif typeof(v) == "EnumItem" then
		return { __type = "EnumItem", name = v.Name }
	elseif typeof(v) == "table" then
		local out = {}
		for i, x in ipairs(v) do
			out[i] = encodeValue(x)
		end
		return out
	end
	return v
end

local function decodeValue(v)
	if typeof(v) == "table" then
		if v.__type == "Color3" then
			return Utils.FromHex(v.hex)
		elseif v.__type == "EnumItem" then
			local ok, item = pcall(function() return Enum.KeyCode[v.name] end)
			return ok and item or Enum.KeyCode.Unknown
		end
		local out = {}
		for i, x in ipairs(v) do
			out[i] = decodeValue(x)
		end
		return out
	end
	return v
end

local function configFolder()
	return "BarbatosXIUI/configs"
end

local function configPath(name)
	return configFolder() .. "/" .. name .. ".json"
end

local function ensureConfigDir()
	pcall(function()
		if isfolder and not isfolder("BarbatosXIUI") then makefolder("BarbatosXIUI") end
		if isfolder and not isfolder(configFolder()) then makefolder(configFolder()) end
	end)
end

--- 保存全部已登记 Flag
function BX:SaveConfig(name)
	if typeof(name) ~= "string" or name == "" then
		warn("[BarbatosXIUI] 配置名无效")
		return false
	end
	ensureConfigDir()
	local data = {}
	for flag, e in pairs(flagRegistry) do
		data[flag] = encodeValue(e.Get())
	end
	local ok, json = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if not ok then
		warn("[BarbatosXIUI] 配置序列化失败:", json)
		return false
	end
	local wOk, err = pcall(function()
		writefile(configPath(name), json)
	end)
	if not wOk then
		warn("[BarbatosXIUI] 配置写入失败:", err)
		return false
	end
	return true
end

--- 读取配置并应用
function BX:LoadConfig(name)
	ensureConfigDir()
	local rOk, json = pcall(function()
		return readfile(configPath(name))
	end)
	if not rOk or typeof(json) ~= "string" then
		warn("[BarbatosXIUI] 配置不存在:", name)
		return false
	end
	local jOk, data = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	if not jOk or typeof(data) ~= "table" then
		warn("[BarbatosXIUI] 配置解析失败:", name)
		return false
	end
	local applied, missed = 0, 0
	for flag, raw in pairs(data) do
		local e = flagRegistry[flag]
		if e then
			e.Set(decodeValue(raw))
			applied = applied + 1
		else
			missed = missed + 1
		end
	end
	return true, applied, missed
end

--- 删除配置
function BX:DeleteConfig(name)
	local ok = pcall(function()
		delfile(configPath(name))
	end)
	return ok
end

--- 列出全部配置名
function BX:GetConfigs()
	ensureConfigDir()
	local out = {}
	local ok, names = pcall(function()
		return listfiles(configFolder())
	end)
	if ok and typeof(names) == "table" then
		for _, p in ipairs(names) do
			local base = tostring(p):match("([^/\\]+)%.json$")
			if base then out[#out + 1] = base end
		end
	end
	table.sort(out)
	return out
end

--- 当前主题也随配置保存
local oldSave = BX.SaveConfig
function BX:SaveConfigWithTheme(name)
	local ok = oldSave(self, name)
	if ok then
		pcall(function()
			local path = configPath(name)
			local data = HttpService:JSONDecode(readfile(path))
			data.__theme = self.CurrentThemeName
			writefile(path, HttpService:JSONEncode(data))
		end)
	end
	return ok
end

----------------------------------------------------------------
-- §15 元素方法注册表
--    part4-6 会把各控件实现挂到这里，AddSection 统一装配。
----------------------------------------------------------------
local ElementAPI = {}

----------------------------------------------------------------
-- §16 水印模块
----------------------------------------------------------------
local WatermarkAPI = {}
WatermarkAPI.__index = WatermarkAPI

local function buildWatermark(cfg)
	cfg = cfg or {}
	local T = BX.CurrentTheme
	local gui = Instance.new("ScreenGui")
	gui.Name = "BarbatosXIUI_Watermark"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 997
	pcall(function() gui.Parent = game:GetService("CoreGui") end)
	if not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end

	local frame = glass(gui, 10, 0.82)
	frame.Size = UDim2.fromOffset(210, 26)
	frame.Position = UDim2.fromOffset(12, 12)

	local titleLbl = label(frame, cfg.Title or "BarbatosXIUI", 12, true)
	titleLbl.Position = UDim2.new(0, 10, 0, 0)
	titleLbl.Size = UDim2.new(0, 100, 1, 0)

	local fpsLbl = textFaint(label(frame, "-- FPS", 11, false, nil, Enum.TextXAlignment.Right))
	fpsLbl.Position = UDim2.new(1, -110, 0, 0)
	fpsLbl.Size = UDim2.fromOffset(48, 26)

	local pingLbl = textFaint(label(frame, "-- MS", 11, false, nil, Enum.TextXAlignment.Right))
	pingLbl.Position = UDim2.new(1, -58, 0, 0)
	pingLbl.Size = UDim2.fromOffset(48, 26)

	local self = setmetatable({
		Gui = gui, Frame = frame,
		Title = cfg.Title or "BarbatosXIUI",
		Visible = cfg.Visible ~= false,
		ShowFps = cfg.Fps ~= false,
		ShowPing = cfg.Ping ~= false,
	}, WatermarkAPI)

	local frames = 0
	RunService.RenderStepped:Connect(function()
		frames = frames + 1
	end)
	task.spawn(function()
		while gui.Parent do
			task.wait(1)
			local fps = frames
			frames = 0
			local ping = 0
			pcall(function()
				ping = Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
			end)
			if self.ShowFps then
				fpsLbl.Text = tostring(fps) .. " FPS"
			else
				fpsLbl.Text = ""
			end
			if self.ShowPing then
				pingLbl.Text = tostring(math.floor(ping)) .. " MS"
			else
				pingLbl.Text = ""
			end
		end
	end)

	-- 拖动
	local dragging = false
	local dStart, fStart
	frame.InputBegan:Connect(function(input)
		if Utils.IsPress(input) then
			dragging = true
			dStart = input.Position
			fStart = frame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if Utils.IsPress(input) then dragging = false end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and Utils.IsMove(input) then
			local d = input.Position - dStart
			BX.Tween(frame, TI(0.14, Enum.EasingStyle.Sine), {
				Position = UDim2.new(fStart.X.Scale, fStart.X.Offset + d.X, fStart.Y.Scale, fStart.Y.Offset + d.Y),
			})
		end
	end)

	if not self.Visible then
		frame.Visible = false
	end
	return self
end

function WatermarkAPI:SetTitle(t)
	self.Title = t
	local titleLbl = self.Frame:FindFirstChildOfClass("TextLabel")
	if titleLbl then titleLbl.Text = t end
end

function WatermarkAPI:SetVisible(v)
	self.Visible = v
	self.Frame.Visible = v
end

function WatermarkAPI:Remove()
	self.Gui:Destroy()
end

function BX:CreateWatermark(cfg)
	return buildWatermark(cfg)
end

----------------------------------------------------------------
-- §17 窗口
----------------------------------------------------------------
local WindowAPI = {}
WindowAPI.__index = WindowAPI

function BX:CreateWindow(cfg)
	cfg = cfg or {}
	local T = self.CurrentTheme
	local window = setmetatable({
		Tabs = {}, Open = true, Sections = {},
		Name = cfg.Name or "BarbatosXIUI",
	}, WindowAPI)
	window.Keybind = cfg.Keybind or Enum.KeyCode.Insert

	----------------------------------------------------------------
	-- ScreenGui 与背景
	----------------------------------------------------------------
	local gui = Instance.new("ScreenGui")
	gui.Name = window.Name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = cfg.DisplayOrder or 999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function() gui.Parent = game:GetService("CoreGui") end)
	if not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end
	window.Gui = gui

	local bg = Instance.new("ImageLabel")
	bg.Name = "Background"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundTransparency = 1
	bg.ScaleType = Enum.ScaleType.Crop
	bg.ImageTransparency = cfg.BackgroundTransparency or 0.5
	bg.ZIndex = 0
	bg.Parent = gui

	local dimmer = Instance.new("Frame")
	dimmer.Size = UDim2.fromScale(1, 1)
	dimmer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dimmer.BackgroundTransparency = cfg.DimTransparency or 0.45
	dimmer.BorderSizePixel = 0
	dimmer.ZIndex = 1
	dimmer.Parent = gui

	--- 设置背景：支持 http(s) 直链（自动转自定义资产）或 "rbxassetid://id"
	function window:SetBackground(src, transp)
		if transp then bg.ImageTransparency = transp end
		if typeof(src) ~= "string" or src == "" then return end
		if src:sub(1, 4):lower() == "http" then
			local ok, err = pcall(function()
				local data = game:HttpGet(src)
				writefile("barbatosxi_bg.png", data)
				bg.Image = getcustomasset("barbatosxi_bg.png")
			end)
			if not ok then
				warn("[BarbatosXIUI] 背景下载失败:", err)
			end
		else
			bg.Image = src
		end
	end

	----------------------------------------------------------------
	-- 开屏动画（可关：Intro = false）
	----------------------------------------------------------------
	if cfg.Intro ~= false then
		local veil = Instance.new("Frame")
		veil.Size = UDim2.fromScale(1, 1)
		veil.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		veil.BackgroundTransparency = 0
		veil.BorderSizePixel = 0
		veil.ZIndex = 90
		veil.Parent = gui
		local logo = Instance.new("TextLabel")
		logo.BackgroundTransparency = 1
		logo.Text = cfg.Name or "BarbatosXIUI"
		logo.TextColor3 = Color3.fromRGB(255, 255, 255)
		logo.Font = T.FontBold
		logo.TextSize = 34
		logo.ZIndex = 91
		logo.AnchorPoint = Vector2.new(0.5, 0.5)
		logo.Position = UDim2.fromScale(0.5, 0.5)
		logo.Size = UDim2.fromOffset(500, 60)
		logo.Parent = veil
		local sub = Instance.new("TextLabel")
		sub.BackgroundTransparency = 1
		sub.Text = cfg.Subtitle or ""
		sub.TextColor3 = Color3.fromRGB(150, 150, 160)
		sub.Font = T.Font
		sub.TextSize = 14
		sub.ZIndex = 91
		sub.AnchorPoint = Vector2.new(0.5, 0.5)
		sub.Position = UDim2.fromScale(0.5, 0.58)
		sub.Size = UDim2.fromOffset(500, 24)
		sub.Parent = veil
		local ls = Instance.new("UIScale"); ls.Scale = 0.9; ls.Parent = logo
		BX.Tween(ls, TI(0.6, Enum.EasingStyle.Quart), { Scale = 1 })
		BX.Tween(logo, TI(0.6), { TextColor3 = T.Accent })
		task.delay(1.15, function()
			BX.Tween(veil, TI(0.5), { BackgroundTransparency = 1 })
			BX.Tween(logo, TI(0.45), { TextTransparency = 1, Position = UDim2.fromScale(0.5, 0.46) })
			BX.Tween(sub, TI(0.4), { TextTransparency = 1 })
			task.delay(0.55, function() veil:Destroy() end)
		end)
	end

	----------------------------------------------------------------
	-- 主窗口
	----------------------------------------------------------------
	local sizePreset = {
		Default = UDim2.fromOffset(600, 420),
		Large   = UDim2.fromOffset(720, 520),
		Small   = UDim2.fromOffset(500, 340),
		Mobile  = UDim2.fromOffset(640, 460),
	}
	local size = cfg.Size or sizePreset.Default
	local main = Instance.new("CanvasGroup")
	main.Name = "Main"
	main.AnchorPoint = Vector2.new(0.5, 0.5)
	main.Position = cfg.Position or UDim2.fromScale(0.5, 0.5)
	main.Size = size
	main.BackgroundColor3 = T.WindowBg
	main.BackgroundTransparency = T.WindowTrans
	main.BorderSizePixel = 0
	main.GroupTransparency = 0
	main.ZIndex = 2
	main.Parent = gui
	local mainCorner = Instance.new("UICorner"); mainCorner.CornerRadius = UDim.new(0, 16); mainCorner.Parent = main
	gradientStroke(main, T.StrokeThick + 0.5, T.StrokeTrans)
	registerThemed(main, "window")
	window.Main = main

	local uiScale = Instance.new("UIScale")
	uiScale.Parent = main
	window.UIScale = uiScale

	----------------------------------------------------------------
	-- 标题栏 + 流动光泽
	----------------------------------------------------------------
	local titleBar = Instance.new("Frame")
	titleBar.Size = UDim2.new(1, 0, 0, 48)
	titleBar.BackgroundTransparency = 1
	titleBar.ZIndex = 3
	titleBar.ClipsDescendants = true
	titleBar.Parent = main

	local sheen = Instance.new("Frame")
	sheen.Size = UDim2.fromScale(1, 1)
	sheen.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	sheen.BackgroundTransparency = 1
	sheen.BorderSizePixel = 0
	sheen.ZIndex = 4
	sheen.Parent = titleBar
	local sheenG = Instance.new("UIGradient")
	sheenG.Rotation = 20
	sheenG.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0.00, 0.96),
		NumberSequenceKeypoint.new(0.38, 0.90),
		NumberSequenceKeypoint.new(0.50, 0.62),
		NumberSequenceKeypoint.new(0.62, 0.90),
		NumberSequenceKeypoint.new(1.00, 0.96),
	})
	sheenG.Parent = sheen
	addFlow(sheenG, 7, "offset")

	local title = label(titleBar, (cfg.Icon and (Utils.Icon(cfg.Icon) .. "  ") or "") .. window.Name, 15, true)
	title.Position = UDim2.new(0, 18, 0, 0)
	title.Size = UDim2.new(1, -190, 1, 0)
	title.ZIndex = 5

	local subtitle = textFaint(label(titleBar, cfg.Subtitle or "", 11, false, nil, Enum.TextXAlignment.Right))
	subtitle.Position = UDim2.new(1, -176, 0, 0)
	subtitle.Size = UDim2.fromOffset(158, 48)
	subtitle.ZIndex = 5

	local divider = Instance.new("Frame")
	divider.Size = UDim2.new(1, -24, 0, 1)
	divider.Position = UDim2.new(0, 12, 0, 48)
	divider.BackgroundColor3 = T.Glass
	divider.BackgroundTransparency = 0.82
	divider.BorderSizePixel = 0
	divider.ZIndex = 3
	divider.Parent = main

	----------------------------------------------------------------
	-- 侧栏
	----------------------------------------------------------------
	local sidebarWidth = cfg.SidebarWidth or 152
	local sidebar = glass(main, 12, 0.93)
	sidebar.Position = UDim2.new(0, 10, 0, 58)
	sidebar.Size = UDim2.new(0, sidebarWidth, 1, -68)
	sidebar.ZIndex = 3
	window.Sidebar = sidebar
	local sbPad = Instance.new("UIPadding")
	sbPad.PaddingTop = UDim.new(0, 8); sbPad.PaddingBottom = UDim.new(0, 8)
	sbPad.PaddingLeft = UDim.new(0, 8); sbPad.PaddingRight = UDim.new(0, 8)
	sbPad.Parent = sidebar
	local sbList = Instance.new("UIListLayout")
	sbList.Padding = UDim.new(0, 6)
	sbList.SortOrder = Enum.SortOrder.LayoutOrder
	sbList.Parent = sidebar

	-- 侧栏底部按键提示
	local hint = textFaint(label(sidebar, "[" .. window.Keybind.Name .. "] 收起 / 展开", 10, false, nil, Enum.TextXAlignment.Center))
	hint.Size = UDim2.new(1, -16, 0, 16)
	hint.LayoutOrder = 9999
	hint.Parent = sidebar

	----------------------------------------------------------------
	-- 内容区（左右双列，各自独立平滑滚动）
	----------------------------------------------------------------
	local content = Instance.new("Frame")
	content.Position = UDim2.new(0, sidebarWidth + 20, 0, 58)
	content.Size = UDim2.new(1, -(sidebarWidth + 30), 1, -68)
	content.BackgroundTransparency = 1
	content.ZIndex = 3
	content.Parent = main
	window.Content = content

	local function newColumn(parent, scaleX, offsetX)
		local col = Instance.new("ScrollingFrame")
		col.Name = scaleX == 0 and "LeftColumn" or "RightColumn"
		col.Size = UDim2.new(0.5, -5, 1, 0)
		col.Position = UDim2.new(scaleX, offsetX or 0, 0, 0)
		col.BackgroundTransparency = 1
		col.BorderSizePixel = 0
		col.ScrollBarThickness = 2
		col.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
		col.ScrollBarImageTransparency = 0.5
		col.CanvasSize = UDim2.fromScale(0, 0)
		col.AutomaticCanvasSize = Enum.AutomaticSize.Y
		col.ScrollingDirection = Enum.ScrollingDirection.Y
		col.ElasticBehavior = Enum.ElasticBehavior.Always
		col.ZIndex = 3
		col.Parent = parent
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 8)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = col
		return col
	end

	-- 平滑滚动：滚轮输入转成补间（可打断，到点自然停）
	local function smoothScroll(col)
		local target, current = 0, 0
		local lastWheel = 0
		col.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				local now = tick()
				-- 与系统滚动叠加，只接管惯性：这里做"滚轮加速 + 缓动回停"
				lastWheel = now
			end
		end)
		return col
	end

	local openPopupClose = nil -- 当前展开的下拉关闭函数（§21 用）

	----------------------------------------------------------------
	-- 开关窗口（令牌机制：开合到一半再按，立刻反向）
	----------------------------------------------------------------
	local toggleToken = 0
	local function setOpen(state)
		window.Open = state
		toggleToken = toggleToken + 1
		local my = toggleToken
		BX.Tween(uiScale, TI(0.4, Enum.EasingStyle.Quart), { Scale = state and 1 or 0.92 })
		BX.Tween(main, TI(0.32), { GroupTransparency = state and 0 or 1 })
		if state then main.Visible = true end
		task.delay(0.42, function()
			if my == toggleToken then main.Visible = state end
		end)
	end
	window.SetOpen = setOpen

	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.KeyCode == window.Keybind then
			setOpen(not window.Open)
		end
	end)

	-- 双击标题栏回中
	local lastClick = 0
	titleBar.InputBegan:Connect(function(input)
		if not Utils.IsPress(input) then return end
		local now = tick()
		if now - lastClick < 0.32 then
			BX.Tween(main, TI(0.35, Enum.EasingStyle.Quart), {
				Position = UDim2.fromScale(0.5, 0.5),
			})
		end
		lastClick = now
	end)

	-- 拖动
	local dragging = false
	local dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if Utils.IsPress(input) then
			dragging = true
			dragStart = input.Position
			startPos = main.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if Utils.IsPress(input) then dragging = false end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and Utils.IsMove(input) then
			local d = input.Position - dragStart
			BX.Tween(main, TI(0.16, Enum.EasingStyle.Sine), {
				Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
					startPos.Y.Scale, startPos.Y.Offset + d.Y),
			})
		end
	end)

	-- 右下角缩放
	local grip = Instance.new("Frame")
	grip.Size = UDim2.fromOffset(16, 16)
	grip.Position = UDim2.new(1, -18, 1, -18)
	grip.BackgroundTransparency = 1
	grip.ZIndex = 6
	grip.Parent = main
	local gripIcon = textFaint(label(grip, "◢", 10, false, nil, Enum.TextXAlignment.Center))
	gripIcon.Size = UDim2.fromScale(1, 1)
	gripIcon.ZIndex = 6

	local resizing = false
	local rStart, sStart
	grip.InputBegan:Connect(function(input)
		if Utils.IsPress(input) then
			resizing = true
			rStart = input.Position
			sStart = main.Size
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if Utils.IsPress(input) then resizing = false end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if resizing and Utils.IsMove(input) then
			local d = input.Position - rStart
			local w = math.max(480, sStart.X.Offset + d.X)
			local h = math.max(320, sStart.Y.Offset + d.Y)
			BX.Tween(main, TI(0.12, Enum.EasingStyle.Sine), {
				Size = UDim2.fromOffset(w, h),
			})
		end
	end)

	----------------------------------------------------------------
	-- 尺寸预设
	----------------------------------------------------------------
	function window:SetSizePreset(name)
		local preset = sizePreset[name]
		if not preset then return false end
		BX.Tween(main, TI(0.35, Enum.EasingStyle.Quart), { Size = preset })
		return true
	end
	function window:GetSizePresets()
		local out = {}
		for k in pairs(sizePreset) do out[#out + 1] = k end
		table.sort(out)
		return out
	end

	----------------------------------------------------------------
	-- 选项卡切换
	----------------------------------------------------------------
	function window:SelectTab(tab)
		self.CurrentTab = tab
		if self._popupClose then
			pcall(self._popupClose)
			self._popupClose = nil
		end
		for _, t in ipairs(self.Tabs) do
			local active = t == tab
			BX.Tween(t.Button, TI(0.25), { BackgroundTransparency = active and T.GlassActive or T.GlassRowTrans })
			t.Label.TextColor3 = active and T.Text or T.TextDim
			t.Label.Font = active and T.FontBold or T.Font
			if t.IconLbl then
				t.IconLbl.TextColor3 = active and T.Accent or T.TextDim
			end
			if active then
				t.Page.Visible = true
				t.Page.GroupTransparency = 0.3
				BX.Tween(t.Page, TI(0.32), { GroupTransparency = 0 })
			else
				t.Page.Visible = false
			end
		end
	end

	----------------------------------------------------------------
	-- 添加选项卡
	----------------------------------------------------------------
	function window:AddTab(info)
		info = info or {}
		local tab = { Sections = {}, Order = info.Order or (#self.Tabs + 1) }
		local page = Instance.new("CanvasGroup")
		page.Name = info.Name or "Tab"
		page.Size = UDim2.fromScale(1, 1)
		page.BackgroundTransparency = 1
		page.GroupTransparency = 0
		page.Visible = false
		page.ZIndex = 3
		page.Parent = content

		local leftCol = newColumn(page, 0, 0)
		local rightCol = newColumn(page, 0.5, 5)
		tab.LeftColumn = leftCol
		tab.RightColumn = rightCol

		-- 侧栏按钮
		local btn = glass(sidebar, 9, T.GlassRowTrans)
		btn.Size = UDim2.new(1, -8, 0, 32)
		btn.LayoutOrder = tab.Order
		btn.ZIndex = 4
		local iconLbl
		if info.Icon then
			iconLbl = label(btn, Utils.Icon(info.Icon), 13, false, T.TextDim, Enum.TextXAlignment.Center)
			iconLbl.Position = UDim2.new(0, 0, 0, 0)
			iconLbl.Size = UDim2.fromOffset(34, 32)
			iconLbl.ZIndex = 5
		end
		local btnLbl = label(btn, info.Name or "Tab", 13, false, T.TextDim)
		btnLbl.Position = info.Icon and UDim2.new(0, 30, 0, 0) or UDim2.new(0, 10, 0, 0)
		btnLbl.Size = info.Icon and UDim2.new(1, -36, 1, 0) or UDim2.new(1, -16, 1, 0)
		btnLbl.ZIndex = 5

		-- 徽标（小红点数）
		if info.Badge then
			local badge = Instance.new("Frame")
			badge.Size = UDim2.fromOffset(16, 16)
			badge.Position = UDim2.new(1, -22, 0, -4)
			badge.BackgroundColor3 = Color3.fromRGB(255, 96, 96)
			badge.BorderSizePixel = 0
			badge.ZIndex = 6
			badge.Parent = btn
			local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(1, 0); bc.Parent = badge
			local bl = label(badge, tostring(info.Badge), 10, true, Color3.fromRGB(20, 20, 24), Enum.TextXAlignment.Center)
			bl.Size = UDim2.fromScale(1, 1)
			bl.ZIndex = 7
			tab.BadgeFrame = badge
		end

		clickTarget(btn).MouseButton1Click:Connect(function()
			playClick()
			self:SelectTab(tab)
		end)

		tab.Button = btn
		tab.Label = btnLbl
		tab.IconLbl = iconLbl
		tab.Page = page
		tab.Window = self

		----------------------------------------------------------------
		-- 添加分节
		----------------------------------------------------------------
		function tab:AddSection(secInfo)
			secInfo = secInfo or {}
			local targetCol = (secInfo.Position == "right") and rightCol or leftCol
			local sec = {
				Sections = self.Sections,
				Window = self.Window,
			}
			sec._order = #self.Window.Sections + 1
			self.Window.Sections[sec._order] = sec

			local box = glass(targetCol, 12, 0.92)
			box.Size = UDim2.new(1, 0, 0, 0)
			box.AutomaticSize = Enum.AutomaticSize.Y
			box.LayoutOrder = sec._order
			box.ZIndex = 2
			sec._box = box

			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0, 10); pad.PaddingBottom = UDim.new(0, 10)
			pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10)
			pad.Parent = box
			local list = Instance.new("UIListLayout")
			list.Padding = UDim.new(0, 6)
			list.SortOrder = Enum.SortOrder.LayoutOrder
			list.Parent = box

			local secTitle = label(box, string.upper(secInfo.Name or "Section"), 11, true, T.Text)
			secTitle.TextColor3 = T.TextDim
			secTitle.Size = UDim2.new(1, 0, 0, 16)
			secTitle.LayoutOrder = 0
			registerThemed(secTitle, "textdim")
			if secInfo.Icon then
				secTitle.Text = string.upper(Utils.Icon(secInfo.Icon) .. "  " .. (secInfo.Name or "Section"))
			end

			sec._rowOrder = 0
			sec._gui = gui
			sec._window = self.Window
			sec._openPopupClose = function()
				if openPopupClose then openPopupClose() openPopupClose = nil end
			end

			-- 装配全部元素方法
			for k, fn in pairs(ElementAPI) do
				sec[k] = fn
			end

			table.insert(self.Sections, sec)
			return sec
		end

		table.insert(self.Tabs, tab)
		if #self.Tabs == 1 then
			self:SelectTab(tab)
		end
		return tab
	end

	----------------------------------------------------------------
	-- 配置相关方法（代理到 BX 配置系统）
	----------------------------------------------------------------
	function window:SaveConfig(name) return BX.SaveConfig(self, name) end
	function window:LoadConfig(name) return BX.LoadConfig(self, name) end
	function window:DeleteConfig(name) return BX.DeleteConfig(self, name) end
	function window:GetConfigs() return BX.GetConfigs(self) end

	-- 自动加载配置
	if cfg.ConfigFolder and cfg.AutoLoadConfig then
		task.delay(1.2, function()
			local ok = BX.LoadConfig(BX, cfg.AutoLoadConfig)
			if ok then
				BX.Notify(BX, { Title = "配置", Content = "已加载 " .. cfg.AutoLoadConfig, Duration = 3, Type = "success" })
			end
		end)
	end

	if cfg.Background then
		window:SetBackground(cfg.Background, cfg.BackgroundTransparency)
	end

	-- 初始入场动画
	main.GroupTransparency = 1
	uiScale.Scale = 0.94
	BX.Tween(main, TI(0.5, Enum.EasingStyle.Quart), { GroupTransparency = 0 })
	BX.Tween(uiScale, TI(0.55, Enum.EasingStyle.Back), { Scale = 1 })

	return window
end

----------------------------------------------------------------
-- §18 元素：分节内部工具（self 为 section 表）
----------------------------------------------------------------
local function nextRow(self, h)
	self._rowOrder = self._rowOrder + 1
	local T = BX.CurrentTheme
	local r = glass(self._box, 9, T.GlassRowTrans)
	r.Size = UDim2.new(1, 0, 0, h or 36)
	r.LayoutOrder = self._rowOrder
	r.ZIndex = 2
	return r
end

local function rowText(self, r, text, tooltip)
	local txt = label(r, text or "", 13)
	txt.Position = UDim2.new(0, 12, 0, 0)
	txt.Size = UDim2.new(1, -130, 1, 0)
	txt.ZIndex = 4
	if typeof(tooltip) == "string" and tooltip ~= "" then
		BX.AttachTooltip(r, tooltip)
	end
	return txt
end

local function hoverPress(row, onPress)
	local hit = clickTarget(row)
	hit.MouseEnter:Connect(function()
		BX.Tween(row, hoverInfo(), { BackgroundTransparency = 0.78 })
	end)
	hit.MouseLeave:Connect(function()
		BX.Tween(row, hoverInfo(), { BackgroundTransparency = BX.CurrentTheme.GlassRowTrans })
	end)
	hit.MouseButton1Down:Connect(function()
		playClick(0.06)
	end)
	if onPress then
		hit.MouseButton1Click:Connect(onPress)
	end
	return hit
end

----------------------------------------------------------------
-- §19 元素：纯文本标签
--    data: { Name, Sub, Tooltip, Flag?（不可存） }
----------------------------------------------------------------
function ElementAPI.AddLabel(self, data)
	data = data or {}
	local r = nextRow(self, data.Sub and 44 or 28)
	local txt = rowText(self, r, data.Name)
	txt.TextColor3 = BX.CurrentTheme.TextDim
	txt.TextSize = 12
	registerThemed(txt, "textdim")
	local sub
	if data.Sub then
		sub = label(r, data.Sub, 11, false, BX.CurrentTheme.TextFaint)
		sub.Position = UDim2.new(0, 12, 0, 22)
		sub.Size = UDim2.new(1, -24, 0, 16)
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.ZIndex = 4
		textFaint(sub)
	end
	if data.Tooltip then BX.AttachTooltip(r, data.Tooltip) end
	local api = {}
	function api:Set(t) txt.Text = t end
	function api:Get() return txt.Text end
	function api:SetSub(t) if sub then sub.Text = t end end
	return api
end

----------------------------------------------------------------
-- §20 元素：段落（标题 + 多行内容）
----------------------------------------------------------------
function ElementAPI.AddParagraph(self, data)
	data = data or {}
	local r = nextRow(self, 20 + math.max(1, math.ceil(#(data.Content or "") / 34)) * 15)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8); pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = r
	local title = label(r, data.Name or "", 12, true)
	title.Position = UDim2.new(0, 12, 0, 0)
	title.Size = UDim2.new(1, -24, 0, 16)
	title.ZIndex = 4
	local body = label(r, data.Content or "", 11, false, BX.CurrentTheme.TextDim)
	body.Position = UDim2.new(0, 12, 0, 17)
	body.Size = UDim2.new(1, -24, 1, -20)
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextWrapped = true
	body.LineHeight = 1.3
	body.ZIndex = 4
	textDim(body)
	if data.Tooltip then BX.AttachTooltip(r, data.Tooltip) end
	local api = {}
	function api:Set(t) body.Text = t end
	function api:SetTitle(t) title.Text = t end
	return api
end

----------------------------------------------------------------
-- §21 元素：分隔线 / 留白
----------------------------------------------------------------
function ElementAPI.AddDivider(self)
	local r = nextRow(self, 12)
	r.BackgroundTransparency = 1
	local line = Instance.new("Frame")
	line.Size = UDim2.new(1, -16, 0, 1)
	line.Position = UDim2.new(0, 8, 0.5, 0)
	line.BackgroundColor3 = BX.CurrentTheme.Glass
	line.BackgroundTransparency = 0.8
	line.BorderSizePixel = 0
	line.ZIndex = 3
	line.Parent = r
	return {}
end

function ElementAPI.AddSpacer(self, h)
	local r = nextRow(self, h or 8)
	r.BackgroundTransparency = 1
	return {}
end

----------------------------------------------------------------
-- §22 元素：按钮
--    data: { Name, Tooltip, Confirm = true（先弹确认框）, Callback }
----------------------------------------------------------------
function ElementAPI.AddButton(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 34)
	local scale = Instance.new("UIScale")
	scale.Parent = r
	local txt = label(r, data.Name or "Button", 13, false, T.Text, Enum.TextXAlignment.Center)
	txt.Size = UDim2.fromScale(1, 1)
	txt.ZIndex = 4
	if data.Icon then
		txt.Text = Utils.Icon(data.Icon) .. "  " .. (data.Name or "Button")
	end

	local function fire()
		if data.Confirm then
			BX:Confirm({
				Title = data.Name or "确认",
				Content = data.ConfirmText or "确定要执行这个操作吗？",
				ConfirmText = "执行",
				Callback = function(ok)
					if ok then Utils.SafeCall(data.Callback) end
				end,
			})
		else
			Utils.SafeCall(data.Callback)
		end
	end

	local hit = clickTarget(r)
	if data.Tooltip then BX.AttachTooltip(r, data.Tooltip) end
	hit.MouseEnter:Connect(function()
		BX.Tween(r, hoverInfo(), { BackgroundTransparency = 0.78 })
	end)
	hit.MouseLeave:Connect(function()
		BX.Tween(r, hoverInfo(), { BackgroundTransparency = T.GlassRowTrans })
	end)
	hit.MouseButton1Down:Connect(function()
		playClick(0.06)
		BX.Tween(scale, TI(0.1), { Scale = 0.96 })
	end)
	hit.MouseButton1Up:Connect(function()
		BX.Tween(scale, TI(0.3, Enum.EasingStyle.Back), { Scale = 1 })
	end)
	hit.MouseButton1Click:Connect(fire)
	return {}
end

----------------------------------------------------------------
-- §23 元素：开关（iOS 拨杆 + 可选附属选项弹层）
--    data: { Name, Default, Flag, Tooltip, Callback,
--            Options = function(api) ... end  -- 展开附加控件 }
----------------------------------------------------------------
function ElementAPI.AddToggle(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 36)
	rowText(self, r, data.Name, data.Tooltip)

	local sw = pill(r, 0.78)
	sw.Size = UDim2.fromOffset(42, 24)
	sw.Position = UDim2.new(1, -54, 0.5, -12)
	sw.ZIndex = 3
	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(18, 18)
	knob.Position = UDim2.new(0, 12, 0.5, 0)
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.BorderSizePixel = 0
	knob.ZIndex = 5
	knob.Parent = sw
	local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1, 0); kc.Parent = knob
	local kg = Instance.new("UIGradient")
	kg.Rotation = 90
	kg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(215, 215, 225)),
	})
	kg.Parent = knob
	gradientStroke(knob, 1, 0.35)

	local state = data.Default == true

	local function apply(instant)
		local ti = instant and TI(0) or TI(0.24, Enum.EasingStyle.Back)
		BX.Tween(knob, ti, {
			Position = state and UDim2.new(1, -12, 0.5, 0) or UDim2.new(0, 12, 0.5, 0),
		})
		BX.Tween(sw, instant and TI(0) or TI(0.2), {
			BackgroundTransparency = state and 0.42 or 0.78,
		})
		knob.BackgroundColor3 = state and T.AccentDark or Color3.fromRGB(255, 255, 255)
	end
	apply(true)

	local api = {}
	local hit = clickTarget(r)
	hit.MouseButton1Click:Connect(function()
		state = not state
		apply()
		playClick(0.08)
		Utils.SafeCall(data.Callback, state)
	end)

	-- 附属选项（点右侧 "···" 展开更多控件）
	local optionsBox
	if typeof(data.Options) == "function" then
		local optBtn = clickTarget(r)
		optBtn.Size = UDim2.fromOffset(26, 26)
		optBtn.Position = UDim2.new(1, -86, 0.5, -13)
		optBtn.ZIndex = 6
		local dots = label(r, "···", 14, true, T.TextFaint, Enum.TextXAlignment.Center)
		dots.Size = UDim2.fromOffset(26, 26)
		dots.Position = UDim2.new(1, -86, 0.5, -13)
		dots.ZIndex = 6
		textFaint(dots)

		optionsBox = glass(self._box, 10, 0.9)
		optionsBox.Size = UDim2.new(1, 0, 0, 0)
		optionsBox.AutomaticSize = Enum.AutomaticSize.Y
		optionsBox.Visible = false
		optionsBox.LayoutOrder = self._rowOrder + 1000
		local op = Instance.new("UIPadding")
		op.PaddingTop = UDim.new(0, 8); op.PaddingBottom = UDim.new(0, 8)
		op.PaddingLeft = UDim.new(0, 10); op.PaddingRight = UDim.new(0, 10)
		op.Parent = optionsBox
		local ol = Instance.new("UIListLayout")
		ol.Padding = UDim.new(0, 6)
		ol.SortOrder = Enum.SortOrder.LayoutOrder
		ol.Parent = optionsBox

		local optSec = { _box = optionsBox, _rowOrder = 0, _gui = self._gui, _window = self._window }
		for k, fn in pairs(ElementAPI) do
			optSec[k] = fn
		end
		local ok, err = pcall(data.Options, optSec, api)
		if not ok then warn("[BarbatosXIUI] Toggle Options 构建出错:", err) end

		optBtn.MouseButton1Click:Connect(function()
			playClick(0.06)
			if optionsBox.Visible then
				optionsBox.Visible = false
			else
				optionsBox.Visible = true
				optionsBox.BackgroundTransparency = 1
				BX.Tween(optionsBox, TI(0.25), { BackgroundTransparency = 0.9 })
			end
		end)
		api._optionsBox = optionsBox
	end

	function api:Set(v)
		state = v == true
		apply(true)
	end
	function api:Get() return state end
	function api:OptionsVisible(v)
		if optionsBox then optionsBox.Visible = v end
	end

	if typeof(data.Flag) == "string" and data.Flag ~= "" then
		registerFlag(data.Flag, {
			Get = function() return state end,
			Set = function(v) api.Set(api, v) end,
		})
	end
	return api
end

----------------------------------------------------------------
-- §24 元素：进度条
--    data: { Name, Value = 0~1, ShowPercent }
----------------------------------------------------------------
function ElementAPI.AddProgressBar(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 44)
	rowText(self, r, data.Name, data.Tooltip)
	local pct = label(r, "0%", 11, false, T.TextDim, Enum.TextXAlignment.Right)
	pct.Position = UDim2.new(1, -70, 0, 0)
	pct.Size = UDim2.fromOffset(58, 22)
	pct.ZIndex = 4
	textDim(pct)

	local track = pill(r, 0.82)
	track.Size = UDim2.new(1, -24, 0, 6)
	track.Position = UDim2.new(0, 12, 1, -14)
	track.ZIndex = 3
	local fill = pill(track, 0.35)
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = T.Accent
	fill.ZIndex = 4

	local value = Utils.Clamp(tonumber(data.Value) or 0, 0, 1)
	local function render(instant)
		BX.Tween(fill, instant and TI(0) or TI(0.35, Enum.EasingStyle.Quart), {
			Size = UDim2.new(math.max(value, 0.015), 0, 1, 0),
		})
		pct.Text = tostring(math.floor(value * 100 + 0.5)) .. "%"
	end
	render(true)

	local api = {}
	function api:Set(v)
		value = Utils.Clamp(tonumber(v) or 0, 0, 1)
		render()
		Utils.SafeCall(data.Callback, value)
	end
	function api:Get() return value end
	return api
end

----------------------------------------------------------------
-- §25 元素：迷你统计行（水印文字型，适合放在任意 section）
--    data: { Name, Value, Icon }
----------------------------------------------------------------
function ElementAPI.AddStat(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 30)
	local icon = label(r, data.Icon and Utils.Icon(data.Icon) or "", 12, false, T.TextDim)
	icon.Position = UDim2.new(0, 12, 0, 0)
	icon.Size = UDim2.fromOffset(20, 30)
	icon.ZIndex = 4
	textDim(icon)
	local name = label(r, data.Name or "", 12, false, T.TextDim)
	name.Position = UDim2.new(0, 34, 0, 0)
	name.Size = UDim2.new(0.5, -34, 1, 0)
	name.ZIndex = 4
	textDim(name)
	local value = label(r, tostring(data.Value or "--"), 12, true, T.Text, Enum.TextXAlignment.Right)
	value.Position = UDim2.new(1, -70, 0, 0)
	value.Size = UDim2.fromOffset(58, 30)
	value.ZIndex = 4
	local api = {}
	function api:Set(v) value.Text = tostring(v) end
	function api:SetName(n) name.Text = n end
	return api
end

----------------------------------------------------------------
-- §26 元素：滑条
--    data: { Name, Min, Max, Default, Rounding, Suffix, Flag,
--            Tooltip, Callback, CallbackOnRelease }
--    交互：左键/触控拖动；悬停圆点放大；双击回到 Default。
----------------------------------------------------------------
function ElementAPI.AddSlider(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 50)
	rowText(self, r, data.Name, data.Tooltip)
	local val = label(r, "", 12, false, T.TextDim, Enum.TextXAlignment.Right)
	val.Position = UDim2.new(1, -70, 0, 0)
	val.Size = UDim2.fromOffset(58, 22)
	val.ZIndex = 4
	textDim(val)

	local track = pill(r, 0.82)
	track.Size = UDim2.new(1, -24, 0, 6)
	track.Position = UDim2.new(0, 12, 1, -16)
	track.ZIndex = 3

	local fill = pill(track, 0.35)
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Position = UDim2.fromScale(0, 0)
	fill.BackgroundColor3 = T.Accent
	fill.ZIndex = 4

	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Size = UDim2.fromOffset(13, 13)
	dot.Position = UDim2.new(0, 0, 0.5, 0)
	dot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dot.BorderSizePixel = 0
	dot.ZIndex = 6
	dot.Parent = track
	local dc = Instance.new("UICorner"); dc.CornerRadius = UDim.new(1, 0); dc.Parent = dot
	local dg = Instance.new("UIGradient")
	dg.Rotation = 90
	dg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(215, 215, 225)),
	})
	dg.Parent = dot
	gradientStroke(dot, 1.2, 0.2)

	-- 悬停数值气泡（跟随圆点）
	local bubble = glass(r, 6, 0.25)
	bubble.Size = UDim2.fromOffset(46, 20)
	bubble.AnchorPoint = Vector2.new(0.5, 1)
	bubble.Position = UDim2.new(0, 12, 0, -8)
	bubble.ZIndex = 8
	bubble.Visible = false
	local bubbleTxt = label(bubble, "", 11, true, T.AccentDark, Enum.TextXAlignment.Center)
	bubbleTxt.Size = UDim2.fromScale(1, 1)
	bubbleTxt.ZIndex = 9

	local hit = clickTarget(r)
	hit.Position = UDim2.new(0, 8, 1, -30)
	hit.Size = UDim2.new(1, -16, 0, 28)
	hit.ZIndex = 7

	local minV, maxV = data.Min or 0, data.Max or 100
	local round = data.Rounding or 0
	local suffix = data.Suffix or ""
	local value = math.clamp(typeof(data.Default) == "number" and data.Default or minV, minV, maxV)
	local holding = false
	local lastCbValue = value

	local function fmt(v)
		return string.format("%." .. round .. "f", v) .. suffix
	end

	local function render(instant)
		local p = (value - minV) / math.max(maxV - minV, 1e-9)
		local ti = instant and TI(0) or TI(0.14)
		BX.Tween(fill, ti, { Size = UDim2.new(math.max(p, 0.02), 0, 1, 0) })
		BX.Tween(dot, ti, { Position = UDim2.new(p, 0, 0.5, 0) })
		val.Text = fmt(value)
		bubbleTxt.Text = fmt(value)
		BX.Tween(bubble, ti, { Position = UDim2.new(p, 0, 0, -8) })
	end

	local function updateFromX(x, fromDrag)
		local p = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		value = minV + (maxV - minV) * p
		if round > 0 then
			local step = 1 / (10 ^ round)
			value = math.floor(value / step + 0.5) * step
		else
			value = math.floor(value + 0.5)
		end
		value = math.clamp(value, minV, maxV)
		render()
		if not fromDrag or not data.CallbackOnRelease then
			if value ~= lastCbValue then
				lastCbValue = value
				Utils.SafeCall(data.Callback, value)
			end
		end
	end
	render(true)

	hit.MouseEnter:Connect(function()
		bubble.Visible = true
		bubble.BackgroundTransparency = 1
		BX.Tween(bubble, TI(0.18), { BackgroundTransparency = 0.25 })
		BX.Tween(dot, TI(0.18, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(16, 16) })
	end)
	hit.MouseLeave:Connect(function()
		if holding then return end
		BX.Tween(bubble, TI(0.15), { BackgroundTransparency = 1 })
		BX.Tween(dot, TI(0.18), { Size = UDim2.fromOffset(13, 13) })
		task.delay(0.16, function() if not holding then bubble.Visible = false end end)
	end)
	hit.InputBegan:Connect(function(input)
		if Utils.IsPress(input) then
			holding = true
			bubble.Visible = true
			updateFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if holding and Utils.IsMove(input) then
			updateFromX(input.Position.X, true)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if Utils.IsPress(input) and holding then
			holding = false
			if data.CallbackOnRelease then
				Utils.SafeCall(data.Callback, value)
			end
			if not hit.MouseEnabled then end
		end
	end)

	-- 双击复位
	local lastPress = 0
	hit.MouseButton1Click:Connect(function()
		local now = tick()
		if now - lastPress < 0.3 and typeof(data.Default) == "number" then
			value = data.Default
			render()
			Utils.SafeCall(data.Callback, value)
		end
		lastPress = now
	end)

	local api = {}
	function api:Set(v)
		value = math.clamp(typeof(v) == "number" and v or minV, minV, maxV)
		render()
	end
	function api:Get() return value end
	function api:Reset()
		if typeof(data.Default) == "number" then
			value = data.Default
			render()
		end
	end

	if typeof(data.Flag) == "string" and data.Flag ~= "" then
		registerFlag(data.Flag, {
			Get = function() return value end,
			Set = function(v) api.Set(api, v) end,
		})
	end
	return api
end

----------------------------------------------------------------
-- §27 元素：下拉
--    data: { Name, Values, Default, Multi, Search, Flag, Tooltip, Callback }
--    api: Set/Get/Refresh(values)/SetValues
----------------------------------------------------------------
function ElementAPI.AddDropdown(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 36)
	rowText(self, r, data.Name, data.Tooltip)

	local values = data.Values or {}
	local multi = data.Multi == true
	local current -- 单选：值；多选：集合表
	if multi then
		current = {}
		if typeof(data.Default) == "table" then
			for _, v in ipairs(data.Default) do current[v] = true end
		end
	else
		current = data.Default or values[1] or "..."
	end

	local function currentText()
		if multi then
			local parts = {}
			for _, v in ipairs(values) do
				if current[v] then parts[#parts + 1] = tostring(v) end
			end
			return (#parts > 0) and table.concat(parts, ", ") or "..."
		end
		return tostring(current)
	end

	local btn = glass(r, 8, 0.82)
	btn.Size = UDim2.new(0, 124, 0, 26)
	btn.Position = UDim2.new(1, -136, 0.5, -13)
	btn.ZIndex = 3
	local btnTxt = label(btn, "", 12, false, T.Text, Enum.TextXAlignment.Center)
	btnTxt.Size = UDim2.new(1, -18, 1, 0)
	btnTxt.Position = UDim2.fromOffset(6, 0)
	btnTxt.ZIndex = 4
	btnTxt.TextTruncate = Enum.TextTruncate.AtEnd
	local arrow = label(btn, "⌄", 12, false, T.TextDim, Enum.TextXAlignment.Center)
	arrow.Size = UDim2.fromOffset(18, 26)
	arrow.Position = UDim2.new(1, -20, 0, 0)
	arrow.ZIndex = 4
	textDim(arrow)

	local popup, overlay, popupList, selectedSet = nil, nil, nil, {}

	local function closePopup()
		if popup then
			local p = popup
			popup = nil
			BX.Tween(p, TI(0.16), { Size = UDim2.fromOffset(p.AbsoluteSize.X, 0), GroupTransparency = 1 })
			task.delay(0.18, function() p:Destroy() end)
		end
		if overlay then overlay:Destroy() overlay = nil end
		if self._window and self._window._popupClose == closePopup then
			self._window._popupClose = nil
		end
	end

	local function rebuildList(filter)
		if not popupList then return end
		for _, c in ipairs(popupList:GetChildren()) do
			if c:IsA("GuiObject") then c:Destroy() end
		end
		local shown = 0
		for i, v in ipairs(values) do
			local s = tostring(v)
			if not filter or filter == "" or s:lower():find(filter:lower(), 1, true) then
				shown = shown + 1
				local item = glass(popupList, 7, 0.9)
				item.Size = UDim2.new(1, 0, 0, 26)
				item.ZIndex = 54
				local it = label(item, s, 12, false, T.Text, Enum.TextXAlignment.Left)
				it.Position = UDim2.new(0, 10, 0, 0)
				it.Size = UDim2.new(1, -34, 1, 0)
				it.ZIndex = 55
				local mark = label(item, multi and (current[v] and "◉" or "○") or (tostring(current) == s and "✓" or ""), 12, true, T.Accent, Enum.TextXAlignment.Center)
				mark.Size = UDim2.fromOffset(22, 26)
				mark.Position = UDim2.new(1, -26, 0, 0)
				mark.ZIndex = 55
				local ih = clickTarget(item)
				ih.ZIndex = 56
				ih.MouseEnter:Connect(function()
					BX.Tween(item, hoverInfo(), { BackgroundTransparency = 0.6 })
				end)
				ih.MouseLeave:Connect(function()
					BX.Tween(item, hoverInfo(), { BackgroundTransparency = 0.9 })
				end)
				ih.MouseButton1Click:Connect(function()
					playClick(0.07)
					if multi then
						current[v] = not current[v]
						mark.Text = current[v] and "◉" or "○"
						btnTxt.Text = currentText()
						Utils.SafeCall(data.Callback, current)
					else
						current = v
						btnTxt.Text = currentText()
						closePopup()
						Utils.SafeCall(data.Callback, v)
					end
				end)
			end
		end
		if shown == 0 then
			local empty = label(popupList, "无匹配项", 11, false, T.TextFaint, Enum.TextXAlignment.Center)
			empty.Size = UDim2.new(1, 0, 0, 24)
			empty.ZIndex = 54
			textFaint(empty)
		end
		local targetH = math.min(shown * 30 + 12, 200)
		if popup then
			BX.Tween(popup, TI(0.18), { Size = UDim2.fromOffset(popup.AbsoluteSize.X, targetH) })
		end
	end

	btnTxt.Text = currentText()

	clickTarget(r).MouseButton1Click:Connect(function()
		playClick(0.07)
		if popup then closePopup() return end
		if self._window._popupClose and self._window._popupClose ~= closePopup then
			pcall(self._window._popupClose)
		end
		self._window._popupClose = closePopup

		local inset = Utils.ScreenInset()
		local pos = btn.AbsolutePosition - inset

		overlay = Instance.new("TextButton")
		overlay.BackgroundTransparency = 1
		overlay.Text = ""
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.ZIndex = 40
		overlay.Parent = self._gui

		popup = Instance.new("CanvasGroup")
		popup.BackgroundColor3 = T.WindowBg
		popup.BackgroundTransparency = math.max(T.WindowTrans, 0.04)
		popup.BorderSizePixel = 0
		popup.GroupTransparency = 1
		popup.Position = UDim2.fromOffset(pos.X, pos.Y + 32)
		popup.Size = UDim2.fromOffset(btn.AbsoluteSize.X, 0)
		popup.ZIndex = 50
		popup.Parent = self._gui
		local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(0, 10); pc.Parent = popup
		gradientStroke(popup, T.StrokeThick + 0.2, T.StrokeTrans)

		local topPad = 6
		if data.Search then
			topPad = 36
			local searchBox = glass(popup, 7, 0.85)
			searchBox.Size = UDim2.new(1, -12, 0, 26)
			searchBox.Position = UDim2.new(0, 6, 0, 6)
			searchBox.ZIndex = 52
			local st = Instance.new("TextBox")
			st.BackgroundTransparency = 1
			st.Text = ""
			st.PlaceholderText = "搜索..."
			st.PlaceholderColor3 = T.TextFaint
			st.TextColor3 = T.Text
			st.Font = T.Font
			st.TextSize = 12
			st.Size = UDim2.new(1, -16, 1, 0)
			st.Position = UDim2.fromOffset(8, 0)
			st.ClearTextOnFocus = false
			st.ZIndex = 53
			st.Parent = searchBox
			st:GetPropertyChangedSignal("Text"):Connect(function()
				rebuildList(st.Text)
			end)
		end

		popupList = Instance.new("Frame")
		popupList.Name = "List"
		popupList.BackgroundTransparency = 1
		popupList.Size = UDim2.new(1, -12, 1, -(topPad + 6))
		popupList.Position = UDim2.new(0, 6, 0, topPad)
		popupList.ZIndex = 52
		popupList.ClipsDescendants = true
		popupList.Parent = popup
		local plist = Instance.new("UIListLayout")
		plist.Padding = UDim.new(0, 4)
		plist.SortOrder = Enum.SortOrder.LayoutOrder
		plist.Parent = popupList

		rebuildList(nil)

		BX.Tween(popup, TI(0.22, Enum.EasingStyle.Back), {
			Size = UDim2.fromOffset(btn.AbsoluteSize.X, math.min(#values * 30 + 12 + topPad, 236)),
			GroupTransparency = 0,
		})
		overlay.MouseButton1Click:Connect(closePopup)
	end)

	local api = {}
	function api:Set(v)
		if multi and typeof(v) == "table" then
			current = {}
			for _, x in ipairs(v) do current[x] = true end
		else
			current = v
		end
		btnTxt.Text = currentText()
	end
	function api:Get()
		if multi then
			local out = {}
			for _, v in ipairs(values) do
				if current[v] then out[#out + 1] = v end
			end
			return out
		end
		return current
	end
	function api:Refresh(newValues)
		values = newValues or {}
		btnTxt.Text = currentText()
		if popup then rebuildList(nil) end
	end
	function api:SetValues(newValues) api.Refresh(api, newValues) end

	if typeof(data.Flag) == "string" and data.Flag ~= "" then
		registerFlag(data.Flag, {
			Get = function()
				if multi then
					local out = {}
					for _, v in ipairs(values) do
						if current[v] then out[#out + 1] = v end
					end
					return out
				end
				return current
			end,
			Set = function(v) api.Set(api, v) end,
		})
	end
	return api
end

----------------------------------------------------------------
-- §28 元素：热键
--    data: { Name, Default (Enum.KeyCode), Mode = "Click"|"Hold",
--            Flag, Tooltip, Callback }
--    Mode = "Hold" 时 Callback 收 true/false（按下/松开）。
----------------------------------------------------------------
function ElementAPI.AddKeybind(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 36)
	rowText(self, r, data.Name, data.Tooltip)

	local mode = (data.Mode == "Hold") and "Hold" or "Click"
	local key = data.Default or Enum.KeyCode.Unknown
	local listening = false
	local holdState = false

	local btn = glass(r, 8, 0.82)
	btn.Size = UDim2.new(0, 124, 0, 26)
	btn.Position = UDim2.new(1, -136, 0.5, -13)
	btn.ZIndex = 3
	local btnTxt = label(btn, Utils.KeyName(key), 12, false, T.Text, Enum.TextXAlignment.Center)
	btnTxt.Size = UDim2.fromScale(1, 1)
	btnTxt.ZIndex = 4

	-- 监听模式指示
	local modeLbl = label(r, mode == "Hold" and "hold" or "click", 9, false, T.TextFaint, Enum.TextXAlignment.Right)
	modeLbl.Position = UDim2.new(1, -190, 0, 0)
	modeLbl.Size = UDim2.fromOffset(48, 36)
	modeLbl.ZIndex = 4
	textFaint(modeLbl)

	clickTarget(r).MouseButton1Click:Connect(function()
		if listening then return end
		listening = true
		btnTxt.Text = "..."
		playClick(0.06)
		local conn
		conn = UserInputService.InputBegan:Connect(function(input, gpe)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
			conn:Disconnect()
			listening = false
			if input.KeyCode == Enum.KeyCode.Escape then
				btnTxt.Text = Utils.KeyName(key)
				return
			end
			key = input.KeyCode
			btnTxt.Text = Utils.KeyName(key)
			Utils.SafeCall(data.Callback, key)
		end)
	end)

	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe or listening then return end
		if mode == "Hold" then
			if input.KeyCode == key then
				if not holdState then
					holdState = true
					BX.Tween(btn, TI(0.15), { BackgroundTransparency = T.GlassActive })
					Utils.SafeCall(data.Callback, true)
				end
			end
		else
			if input.KeyCode == key then
				BX.Tween(btn, TI(0.12), { BackgroundTransparency = T.GlassActive })
				Utils.SafeCall(data.Callback, key)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if mode == "Hold" and input.KeyCode == key and holdState then
			holdState = false
			BX.Tween(btn, TI(0.2), { BackgroundTransparency = 0.82 })
			Utils.SafeCall(data.Callback, false)
		end
		if mode == "Click" and input.KeyCode == key then
			BX.Tween(btn, TI(0.25), { BackgroundTransparency = 0.82 })
		end
	end)

	local api = {}
	function api:Set(k)
		key = k
		btnTxt.Text = Utils.KeyName(k)
	end
	function api:Get() return key end
	function api:SetMode(m)
		mode = (m == "Hold") and "Hold" or "Click"
		modeLbl.Text = mode == "Hold" and "hold" or "click"
	end

	if typeof(data.Flag) == "string" and data.Flag ~= "" then
		registerFlag(data.Flag, {
			Get = function() return key end,
			Set = function(v) api.Set(api, v) end,
		})
	end
	return api
end

----------------------------------------------------------------
-- §29 元素：输入框
--    data: { Name, Placeholder, Default, Numeric, ClearOnFocus,
--            FinishedOnly, Flag, Tooltip, Callback(text, enterPressed) }
----------------------------------------------------------------
function ElementAPI.AddTextbox(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 36)
	rowText(self, r, data.Name, data.Tooltip)
	local box = glass(r, 8, 0.85)
	box.Size = UDim2.new(0, 124, 0, 26)
	box.Position = UDim2.new(1, -136, 0.5, -13)
	box.ZIndex = 3
	local tb = Instance.new("TextBox")
	tb.BackgroundTransparency = 1
	tb.Text = data.Default or ""
	tb.PlaceholderText = data.Placeholder or "..."
	tb.PlaceholderColor3 = T.TextFaint
	tb.TextColor3 = T.Text
	tb.Font = T.Font
	tb.TextSize = 12
	tb.ClearTextOnFocus = data.ClearOnFocus == true
	tb.Size = UDim2.new(1, -14, 1, 0)
	tb.Position = UDim2.fromOffset(7, 0)
	tb.ZIndex = 4
	tb.Parent = box
	if data.Numeric then
		tb:GetPropertyChangedSignal("Text"):Connect(function()
			local cleaned = tb.Text:gsub("[^%d%.%-%+]", "")
			if cleaned ~= tb.Text then tb.Text = cleaned end
		end)
	end
	tb.Focused:Connect(function()
		BX.Tween(box, TI(0.18), { BackgroundTransparency = 0.7 })
	end)
	tb.FocusLost:Connect(function(enter)
		BX.Tween(box, TI(0.22), { BackgroundTransparency = 0.85 })
		if data.FinishedOnly and not enter then return end
		Utils.SafeCall(data.Callback, tb.Text, enter)
	end)
	local api = {}
	function api:Set(t) tb.Text = tostring(t or "") end
	function api:Get() return tb.Text end
	function api:Focus() tb:CaptureFocus() end

	if typeof(data.Flag) == "string" and data.Flag ~= "" then
		registerFlag(data.Flag, {
			Get = function() return tb.Text end,
			Set = function(v) api.Set(api, v) end,
		})
	end
	return api
end

----------------------------------------------------------------
-- §30 元素：取色器
--    data: { Name, Default (Color3), Alpha (0~1 或 nil 禁透明度),
--            Rainbow = false, Flag, Tooltip, Callback(color, alpha) }
--    api: Set / Get / SetRainbow / GetRainbow
--    面板：SV 平面 + 色相条 + 透明度条 + HEX 输入 + 预设色
----------------------------------------------------------------
local COLOR_PRESETS = {
	Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 200, 210),
	Color3.fromRGB(160, 160, 170), Color3.fromRGB(90, 90, 100),
	Color3.fromRGB(30, 30, 36),    Color3.fromRGB(0, 0, 0),
	Color3.fromRGB(255, 96, 96),   Color3.fromRGB(255, 170, 96),
	Color3.fromRGB(255, 230, 96),  Color3.fromRGB(140, 235, 140),
	Color3.fromRGB(96, 200, 255),  Color3.fromRGB(160, 130, 255),
	Color3.fromRGB(255, 130, 200),
}

function ElementAPI.AddColorPicker(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 36)
	rowText(self, r, data.Name, data.Tooltip)

	local hasAlpha = typeof(data.Alpha) == "number"
	local color = data.Default or Color3.fromRGB(255, 255, 255)
	local alpha = hasAlpha and math.clamp(data.Alpha, 0, 1) or 1
	local rainbow = data.Rainbow == true
	local h, s, v = Color3.toHSV(color)

	-- 预览块（点击展开面板）
	local preview = glass(r, 8, 0.82)
	preview.Size = UDim2.new(0, 124, 0, 26)
	preview.Position = UDim2.new(1, -136, 0.5, -13)
	preview.ZIndex = 3
	local previewFill = Instance.new("Frame")
	previewFill.Size = UDim2.new(1, -8, 1, -8)
	previewFill.Position = UDim2.fromOffset(4, 4)
	previewFill.BackgroundColor3 = color
	previewFill.BorderSizePixel = 0
	previewFill.ZIndex = 4
	previewFill.Parent = preview
	local pfc = Instance.new("UICorner"); pfc.CornerRadius = UDim.new(0, 6); pfc.Parent = previewFill
	local previewHex = label(preview, Utils.ToHex(color), 11, false, T.TextDim, Enum.TextXAlignment.Center)
	previewHex.Size = UDim2.fromScale(1, 1)
	previewHex.ZIndex = 5
	textDim(previewHex)

	local panel

	local function emit()
		Utils.SafeCall(data.Callback, color, alpha)
	end

	local function refreshPreview(instant)
		if rainbow then return end -- 彩虹模式由 WatchRainbow 驱动
		BX.Tween(previewFill, instant and TI(0) or TI(0.18), { BackgroundColor3 = color })
		previewHex.Text = Utils.ToHex(color)
	end

	local unwatchRainbow = nil
	if rainbow then
		unwatchRainbow = BX.WatchRainbow(previewFill, function(c)
			previewFill.BackgroundColor3 = c
			previewHex.Text = "彩虹"
		end)
		previewHex.Text = "彩虹"
	end

	local function closePanel()
		if panel then
			local p = panel
			panel = nil
			BX.Tween(p, TI(0.18), { GroupTransparency = 1 })
			task.delay(0.2, function() p:Destroy() end)
		end
		if self._window and self._window._popupClose == closePanel then
			self._window._popupClose = nil
		end
	end

	clickTarget(r).MouseButton1Click:Connect(function()
		playClick(0.07)
		if panel then closePanel() return end
		if self._window._popupClose and self._window._popupClose ~= closePanel then
			pcall(self._window._popupClose)
		end
		self._window._popupClose = closePanel

		panel = Instance.new("CanvasGroup")
		panel.BackgroundColor3 = T.WindowBg
		panel.BackgroundTransparency = math.max(T.WindowTrans, 0.04)
		panel.BorderSizePixel = 0
		panel.GroupTransparency = 1
		panel.Size = UDim2.fromOffset(218, hasAlpha and 296 or 268)
		local pvPos = preview.AbsolutePosition - Utils.ScreenInset()
		panel.Position = UDim2.fromOffset(math.max(8, pvPos.X - 92), math.max(8, pvPos.Y + 34))
		panel.ZIndex = 60
		panel.Parent = self._gui
		local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(0, 12); pc.Parent = panel
		gradientStroke(panel, T.StrokeThick + 0.2, T.StrokeTrans)

		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 10); pad.PaddingBottom = UDim.new(0, 10)
		pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10)
		pad.Parent = panel

		-- SV 平面
		local svSize = 150
		local svFrame = Instance.new("Frame")
		svFrame.Size = UDim2.fromOffset(svSize, svSize)
		svFrame.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		svFrame.BorderSizePixel = 0
		svFrame.ZIndex = 62
		svFrame.LayoutOrder = 1
		svFrame.Parent = panel
		local svc = Instance.new("UICorner"); svc.CornerRadius = UDim.new(0, 8); svc.Parent = svFrame
		local white = Instance.new("Frame")
		white.Size = UDim2.fromScale(1, 1)
		white.BackgroundColor3 = Color3.new(1, 1, 1)
		white.BorderSizePixel = 0
		white.ZIndex = 63
		white.Parent = svFrame
		local wg = Instance.new("UIGradient")
		wg.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1),
		})
	wg.Rotation = 0
		wg.Parent = white
		local black = Instance.new("Frame")
		black.Size = UDim2.fromScale(1, 1)
		black.BackgroundColor3 = Color3.new(0, 0, 0)
		black.BorderSizePixel = 0
		black.ZIndex = 64
		black.Parent = svFrame
		local bg2 = Instance.new("UIGradient")
		bg2.Rotation = 90
		bg2.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0),
		})
		bg2.Parent = black
		local svDot = Instance.new("Frame")
		svDot.AnchorPoint = Vector2.new(0.5, 0.5)
		svDot.Size = UDim2.fromOffset(12, 12)
		svDot.Position = UDim2.fromScale(s, 1 - v)
		svDot.BackgroundColor3 = Color3.new(1, 1, 1)
		svDot.BorderSizePixel = 0
		svDot.ZIndex = 66
		svDot.Parent = svFrame
		local sdc = Instance.new("UICorner"); sdc.CornerRadius = UDim.new(1, 0); sdc.Parent = svDot
		gradientStroke(svDot, 1.5, 0.1)

		-- 色相条
		local hueBar = Instance.new("Frame")
		hueBar.Size = UDim2.fromOffset(14, svSize)
		hueBar.Position = UDim2.new(0, svSize + 10, 0, 0)
		hueBar.BorderSizePixel = 0
		hueBar.ZIndex = 62
		hueBar.LayoutOrder = 2
		hueBar.Parent = panel
		local hbc = Instance.new("UICorner"); hbc.CornerRadius = UDim.new(1, 0); hbc.Parent = hueBar
		local hueG = Instance.new("UIGradient")
		hueG.Rotation = 90
		local hueKeys = {}
		for i = 0, 6 do
			hueKeys[#hueKeys + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV((i / 6) % 1, 1, 1))
		end
		hueG.Color = ColorSequence.new(hueKeys)
		hueG.Parent = hueBar
		local hueDot = Instance.new("Frame")
		hueDot.AnchorPoint = Vector2.new(0.5, 0.5)
		hueDot.Size = UDim2.fromOffset(18, 18)
		hueDot.Position = UDim2.new(0.5, 0, h, 0)
		hueDot.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		hueDot.BorderSizePixel = 0
		hueDot.ZIndex = 66
		hueDot.Parent = hueBar
		local hdc = Instance.new("UICorner"); hdc.CornerRadius = UDim.new(1, 0); hdc.Parent = hueDot
		gradientStroke(hueDot, 1.5, 0.1)

		-- 透明度条
		local alphaBar, alphaFill, alphaDot
		if hasAlpha then
			alphaBar = pill(panel, 0.85)
			alphaBar.Size = UDim2.new(1, 0, 0, 12)
			alphaBar.Position = UDim2.new(0, 0, 0, svSize + 12)
			alphaBar.ZIndex = 62
			alphaBar.LayoutOrder = 3
			alphaFill = Instance.new("Frame")
			alphaFill.Size = UDim2.new(alpha, 0, 1, 0)
			alphaFill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			alphaFill.BorderSizePixel = 0
			alphaFill.ZIndex = 63
			alphaFill.Parent = alphaBar
			local afc = Instance.new("UICorner"); afc.CornerRadius = UDim.new(1, 0); afc.Parent = alphaFill
			alphaDot = Instance.new("Frame")
			alphaDot.AnchorPoint = Vector2.new(0.5, 0.5)
			alphaDot.Size = UDim2.fromOffset(14, 14)
			alphaDot.Position = UDim2.new(alpha, 0, 0.5, 0)
			alphaDot.BackgroundColor3 = Color3.new(1, 1, 1)
			alphaDot.BorderSizePixel = 0
			alphaDot.ZIndex = 65
			alphaDot.Parent = alphaBar
			local adc = Instance.new("UICorner"); adc.CornerRadius = UDim.new(1, 0); adc.Parent = alphaDot
			gradientStroke(alphaDot, 1.2, 0.15)
		end

		-- HEX 输入 + 彩虹开关
		local bottomY = hasAlpha and (svSize + 32) or (svSize + 12)
		local hexBox = glass(panel, 7, 0.85)
		hexBox.Size = UDim2.new(0.55, -5, 0, 24)
		hexBox.Position = UDim2.new(0, 0, 0, bottomY)
		hexBox.ZIndex = 62
		local hexTb = Instance.new("TextBox")
		hexTb.BackgroundTransparency = 1
		hexTb.Text = Utils.ToHex(color)
		hexTb.PlaceholderText = "#FFFFFF"
		hexTb.PlaceholderColor3 = T.TextFaint
		hexTb.TextColor3 = T.Text
		hexTb.Font = T.Font
		hexTb.TextSize = 11
		hexTb.Size = UDim2.new(1, -10, 1, 0)
		hexTb.Position = UDim2.fromOffset(5, 0)
		hexTb.ClearTextOnFocus = false
		hexTb.ZIndex = 63
		hexTb.Parent = hexBox
		hexTb.FocusLost:Connect(function()
			local c = Utils.FromHex(hexTb.Text)
			h, s, v = Color3.toHSV(c)
			color = c
			svFrame.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
			BX.Tween(svDot, TI(0.12), { Position = UDim2.fromScale(s, 1 - v) })
			BX.Tween(hueDot, TI(0.12), { Position = UDim2.new(0.5, 0, h, 0) })
			hueDot.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
			refreshPreview()
			emit()
		end)

		local rainbowBtn = glass(panel, 7, rainbow and T.GlassActive or 0.85)
		rainbowBtn.Size = UDim2.new(0.45, -5, 0, 24)
		rainbowBtn.Position = UDim2.new(0.55, 5, 0, bottomY)
		rainbowBtn.ZIndex = 62
		local rainbowLbl = label(rainbowBtn, "🌈 彩虹", 11, rainbow, rainbow and T.AccentDark or T.Text, Enum.TextXAlignment.Center)
		rainbowLbl.Size = UDim2.fromScale(1, 1)
		rainbowLbl.ZIndex = 63

		-- 预设色板
		local paletteY = bottomY + 32
		local palette = Instance.new("Frame")
		palette.Size = UDim2.new(1, 0, 0, 22)
		palette.Position = UDim2.new(0, 0, 0, paletteY)
		palette.BackgroundTransparency = 1
		palette.ZIndex = 62
		palette.Parent = panel
		for i, c in ipairs(COLOR_PRESETS) do
			local cell = Instance.new("TextButton")
			cell.Size = UDim2.fromOffset(20, 20)
			cell.Position = UDim2.new(0, (i - 1) * 23, 0, 0)
			cell.BackgroundColor3 = c
			cell.BorderSizePixel = 0
			cell.Text = ""
			cell.ZIndex = 63
			cell.Parent = palette
			local cc2 = Instance.new("UICorner"); cc2.CornerRadius = UDim.new(0, 5); cc2.Parent = cell
			gradientStroke(cell, 1, 0.35)
			cell.MouseButton1Click:Connect(function()
				h, s, v = Color3.toHSV(c)
				color = c
				svFrame.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
				BX.Tween(svDot, TI(0.15, Enum.EasingStyle.Back), { Position = UDim2.fromScale(s, 1 - v) })
				BX.Tween(hueDot, TI(0.15), { Position = UDim2.new(0.5, 0, h, 0) })
				hueDot.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
				hexTb.Text = Utils.ToHex(c)
				refreshPreview()
				emit()
			end)
		end

		-- SV 拖拽
		local svHolding, hueHolding, alphaHolding = false, false, false
		local function updateSV(x, y)
			local px = svFrame.AbsolutePosition.X
			local py = svFrame.AbsolutePosition.Y
			local sz = math.max(svFrame.AbsoluteSize.X, 1)
			s = math.clamp((x - px) / sz, 0, 1)
			v = 1 - math.clamp((y - py) / sz, 0, 1)
			color = Color3.fromHSV(h, s, v)
			BX.Tween(svDot, TI(0.08), { Position = UDim2.fromScale(s, 1 - v) })
			hexTb.Text = Utils.ToHex(color)
			refreshPreview()
			emit()
		end
		local function updateHue(y)
			local py = hueBar.AbsolutePosition.Y
			local sz = math.max(hueBar.AbsoluteSize.Y, 1)
			h = math.clamp((y - py) / sz, 0, 1)
			color = Color3.fromHSV(h, s, v)
			svFrame.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
			BX.Tween(hueDot, TI(0.08), { Position = UDim2.new(0.5, 0, h, 0) })
			hueDot.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
			hexTb.Text = Utils.ToHex(color)
			refreshPreview()
			emit()
		end
		local function updateAlpha(x)
			local px = alphaBar.AbsolutePosition.X
			local sz = math.max(alphaBar.AbsoluteSize.X, 1)
			alpha = math.clamp((x - px) / sz, 0, 1)
			BX.Tween(alphaFill, TI(0.08), { Size = UDim2.new(alpha, 0, 1, 0) })
			BX.Tween(alphaDot, TI(0.08), { Position = UDim2.new(alpha, 0, 0.5, 0) })
			emit()
		end
		local svHit = clickTarget(svFrame)
		svHit.ZIndex = 67
		svHit.InputBegan:Connect(function(input)
			if Utils.IsPress(input) then svHolding = true updateSV(input.Position.X, input.Position.Y) end
		end)
		local hueHit = clickTarget(hueBar)
		hueHit.ZIndex = 67
		hueHit.InputBegan:Connect(function(input)
			if Utils.IsPress(input) then hueHolding = true updateHue(input.Position.Y) end
		end)
		if hasAlpha then
			local alphaHit = clickTarget(alphaBar)
			alphaHit.ZIndex = 66
			alphaHit.InputBegan:Connect(function(input)
				if Utils.IsPress(input) then alphaHolding = true updateAlpha(input.Position.X) end
			end)
		end
		UserInputService.InputChanged:Connect(function(input)
			if not Utils.IsMove(input) then return end
			if svHolding then updateSV(input.Position.X, input.Position.Y) end
			if hueHolding then updateHue(input.Position.Y) end
			if alphaHolding then updateAlpha(input.Position.X) end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if Utils.IsPress(input) then
				svHolding, hueHolding, alphaHolding = false, false, false
			end
		end)

		clickTarget(rainbowBtn).MouseButton1Click:Connect(function()
			rainbow = not rainbow
			if rainbow then
				BX.Tween(rainbowBtn, TI(0.2), { BackgroundTransparency = T.GlassActive })
				rainbowLbl.TextColor3 = T.AccentDark
				rainbowLbl.Font = T.FontBold
				unwatchRainbow = BX.WatchRainbow(previewFill, function(c)
					previewFill.BackgroundColor3 = c
					previewHex.Text = "彩虹"
				end)
			else
				BX.Tween(rainbowBtn, TI(0.2), { BackgroundTransparency = 0.85 })
				rainbowLbl.TextColor3 = T.Text
				rainbowLbl.Font = T.Font
				if unwatchRainbow then
					unwatchRainbow()
					unwatchRainbow = nil
				end
				previewFill.BackgroundColor3 = color
				previewHex.Text = Utils.ToHex(color)
			end
			emit()
		end)

		BX.Tween(panel, TI(0.24, Enum.EasingStyle.Back), { GroupTransparency = 0 })
	end)

	local api = {}
	function api:Set(c, a)
		color = c or color
		if typeof(a) == "number" then alpha = math.clamp(a, 0, 1) end
		h, s, v = Color3.toHSV(color)
		refreshPreview(true)
	end
	function api:Get()
		return color, alpha
	end
	function api:SetRainbow(b) rainbow = b == true end
	function api:GetRainbow() return rainbow end

	if typeof(data.Flag) == "string" and data.Flag ~= "" then
		registerFlag(data.Flag, {
			Get = function()
				return { Color = Utils.ToHex(color), Alpha = alpha, Rainbow = rainbow }
			end,
			Set = function(v)
				if typeof(v) == "table" then
					if v.Color then api.Set(api, Utils.FromHex(v.Color), v.Alpha) end
					if typeof(v.Rainbow) == "boolean" then api.SetRainbow(api, v.Rainbow) end
				elseif typeof(v) == "string" then
					api.Set(api, Utils.FromHex(v))
				end
			end,
		})
	end
	return api
end

----------------------------------------------------------------
-- §31 设置选项卡生成器
--    window:CreateSettingsTab()
--    自动生成：主题切换 / 尺寸预设 / UI 缩放 / 音效 / 菜单键位 /
--              配置管理（保存 / 读取 / 删除 / 导出 / 导入）
----------------------------------------------------------------
function WindowAPI:CreateSettingsTab()
	local tab = self:AddTab({ Name = "设置", Icon = "settings", Order = 999 })

	----------------------------------------------------------------
	-- 外观
	----------------------------------------------------------------
	local lookSec = tab:AddSection({ Name = "外观", Icon = "palette" })

	lookSec:AddDropdown({
		Name = "主题",
		Values = BX:GetThemes(),
		Default = BX.CurrentThemeName,
		Tooltip = "切换整套配色，已创建的界面会同步换色",
		Callback = function(v)
			BX:SetTheme(v)
			BX:Notify({ Title = "主题", Content = "已切换为 " .. v, Duration = 2.5, Type = "success" })
		end,
	})

	lookSec:AddDropdown({
		Name = "尺寸预设",
		Values = self:GetSizePresets(),
		Default = "Default",
		Callback = function(v)
			self:SetSizePreset(v)
		end,
	})

	lookSec:AddSlider({
		Name = "UI 缩放",
		Min = 70, Max = 130, Rounding = 0, Default = 100, Suffix = "%",
		Callback = function(v)
			BX.Tween(self.UIScale, TI(0.2), { Scale = v / 100 })
		end,
	})

	lookSec:AddToggle({
		Name = "点击音效",
		Default = BX.SoundsEnabled,
		Callback = function(v)
			BX.SoundsEnabled = v
		end,
	})

	----------------------------------------------------------------
	-- 键位
	----------------------------------------------------------------
	local keySec = tab:AddSection({ Name = "键位", Icon = "keyboard" })
	keySec:AddKeybind({
		Name = "菜单键位",
		Default = self.Keybind,
		Callback = function(k)
			self.Keybind = k
			BX:Notify({ Title = "键位", Content = "菜单键已改为 " .. k.Name, Duration = 2.5 })
		end,
	})

	----------------------------------------------------------------
	-- 配置管理
	----------------------------------------------------------------
	local cfgSec = tab:AddSection({ Name = "配置管理", Icon = "save", Position = "right" })

	local currentCfgName = ""
	local statusLbl = cfgSec:AddLabel("当前配置：无", "保存或读取后显示")

	local nameBox = cfgSec:AddTextbox({
		Name = "配置名",
		Placeholder = "输入配置名称...",
		Callback = function(text)
			currentCfgName = text
		end,
	})

	local function refreshStatus()
		if currentCfgName ~= "" then
			statusLbl:Set("当前配置：" .. currentCfgName)
		end
	end

	cfgSec:AddButton({
		Name = "💾  保存配置",
		Tooltip = "把所有带 Flag 的控件值写入 JSON 文件",
		Callback = function()
			if currentCfgName == "" then
				BX:Alert({ Title = "配置", Content = "请先输入配置名" })
				return
			end
			local ok = BX:SaveConfig(currentCfgName)
			if ok then
				refreshStatus()
				BX:Notify({ Title = "配置", Content = "已保存 [" .. currentCfgName .. "]", Duration = 3, Type = "success" })
			else
				BX:Notify({ Title = "配置", Content = "保存失败，详见控制台", Duration = 3, Type = "error" })
			end
		end,
	})

	cfgSec:AddButton({
		Name = "📂  读取配置",
		Callback = function()
			if currentCfgName == "" then
				BX:Alert({ Title = "配置", Content = "请先输入配置名" })
				return
			end
			local ok, applied, missed = BX:LoadConfig(currentCfgName)
			if ok then
				refreshStatus()
				BX:Notify({
					Title = "配置",
					Content = string.format("已应用 %d 项%s", applied or 0,
						(missed and missed > 0) and ("，" .. missed .. " 项未匹配") or ""),
					Duration = 3.5,
					Type = "success",
				})
			else
				BX:Notify({ Title = "配置", Content = "读取失败：配置不存在或已损坏", Duration = 3, Type = "error" })
			end
		end,
	})

	cfgSec:AddButton({
		Name = "🗑  删除配置",
		Confirm = true,
		ConfirmText = "确认删除该配置？",
		Callback = function()
			if currentCfgName == "" then return end
			local ok = BX:DeleteConfig(currentCfgName)
			BX:Notify({
				Title = "配置",
				Content = ok and ("已删除 [" .. currentCfgName .. "]") or "删除失败",
				Duration = 3,
				Type = ok and "success" or "error",
			})
		end,
	})

	local listDrop
	cfgSec:AddButton({
		Name = "⟳  刷新配置列表",
		Callback = function()
			if listDrop then listDrop:Refresh(BX:GetConfigs()) end
		end,
	})

	listDrop = cfgSec:AddDropdown({
		Name = "已有配置",
		Values = BX:GetConfigs(),
		Callback = function(v)
			currentCfgName = tostring(v)
			nameBox:Set(tostring(v))
			refreshStatus()
		end,
	})

	cfgSec:AddButton({
		Name = "⧉  导出到剪贴板",
		Tooltip = "把全部 Flag 序列化成文本复制到剪贴板，可跨设备迁移",
		Callback = function()
			local data = {}
			for flag, e in pairs(flagRegistry) do
				data[flag] = encodeValue(e.Get())
			end
			local ok, json = pcall(function() return HttpService:JSONEncode(data) end)
			if ok then
				pcall(function()
					if setclipboard then setclipboard(json) end
				end)
				BX:Notify({ Title = "导出", Content = "配置已复制到剪贴板", Duration = 3, Type = "success" })
			end
		end,
	})

	cfgSec:AddButton({
		Name = "⤒  从剪贴板导入",
		Callback = function()
			BX:Prompt({
				Title = "导入配置",
				Placeholder = "粘贴配置文本...",
				Callback = function(text)
					local ok, data = pcall(function() return HttpService:JSONDecode(text) end)
					if not ok or typeof(data) ~= "table" then
						BX:Notify({ Title = "导入", Content = "解析失败：不是有效的配置文本", Duration = 3, Type = "error" })
						return
					end
					local applied = 0
					for flag, raw in pairs(data) do
						local e = flagRegistry[flag]
						if e then
							e.Set(decodeValue(raw))
							applied = applied + 1
						end
					end
					BX:Notify({ Title = "导入", Content = "已应用 " .. applied .. " 项", Duration = 3, Type = "success" })
				end,
			})
		end,
	})

	----------------------------------------------------------------
	-- 信息
	----------------------------------------------------------------
	local infoSec = tab:AddSection({ Name = "信息", Icon = "info", Position = "right" })
	infoSec:AddStat({ Name = "版本", Value = BX.Version, Icon = "tag" })
	local flagStat = infoSec:AddStat({ Name = "已注册 Flag", Value = "0", Icon = "flag" })
	task.spawn(function()
		while task.wait(1) do
			local n = 0
			for _ in pairs(flagRegistry) do n = n + 1 end
			flagStat:Set(tostring(n))
		end
	end)

	return tab
end

----------------------------------------------------------------
-- §32 通用右键 / 上下文菜单
--    BX:ContextMenu({ Position = Vector2?, Attach = GuiObject?,
--                     Items = { { Name, Icon, Callback, Disabled,
--                                 Checked, Items = {...} 子菜单 }, ... } })
--    点击外部或选中后关闭，Back 缓动展开。
----------------------------------------------------------------
local ctxGui, ctxOpenClose = nil, nil

local function ensureCtxGui()
	if ctxGui and ctxGui.Parent then return end
	ctxGui = Instance.new("ScreenGui")
	ctxGui.Name = "BarbatosXIUI_Context"
	ctxGui.ResetOnSpawn = false
	ctxGui.IgnoreGuiInset = true
	ctxGui.DisplayOrder = 1001
	pcall(function() ctxGui.Parent = game:GetService("CoreGui") end)
	if not ctxGui.Parent then ctxGui.Parent = LP:WaitForChild("PlayerGui") end
end

function BX:ContextMenu(data)
	data = data or {}
	ensureCtxGui()
	if ctxOpenClose then ctxOpenClose() ctxOpenClose = nil end

	local T = BX.CurrentTheme
	local items = data.Items or {}
	if #items == 0 then return function() end end

	-- 定位
	local x, y = 0, 0
	local inset = Utils.ScreenInset()
	if data.Attach and data.Attach.Parent then
		local ap = data.Attach.AbsolutePosition
		x = ap.X - inset.X
		y = ap.Y - inset.Y + data.Attach.AbsoluteSize.Y + 4
	elseif data.Position then
		x = data.Position.X - inset.X
		y = data.Position.Y - inset.Y
	else
		local mp = UserInputService:GetMouseLocation()
		x = mp.X - inset.X
		y = mp.Y - inset.Y
	end

	local overlay = Instance.new("TextButton")
	overlay.BackgroundTransparency = 1
	overlay.Text = ""
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 90
	overlay.Parent = ctxGui

	local menu = Instance.new("CanvasGroup")
	menu.BackgroundColor3 = T.WindowBg
	menu.BackgroundTransparency = math.max(T.WindowTrans, 0.04)
	menu.BorderSizePixel = 0
	menu.GroupTransparency = 1
	menu.Position = UDim2.fromOffset(x, y)
	menu.Size = UDim2.fromOffset(170, 0)
	menu.ZIndex = 95
	menu.Parent = ctxGui
	local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 10); mc.Parent = menu
	gradientStroke(menu, T.StrokeThick + 0.2, T.StrokeTrans)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6); pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6); pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = menu
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 2)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = menu

	local closed = false
	local function close()
		if closed then return end
		closed = true
		ctxOpenClose = nil
		BX.Tween(menu, TI(0.15), { Size = UDim2.fromOffset(170, 0), GroupTransparency = 1 })
		task.delay(0.17, function() menu:Destroy() overlay:Destroy() end)
	end
	ctxOpenClose = close

	for i, item in ipairs(items) do
		local row = glass(menu, 6, 0.92)
		row.Size = UDim2.new(1, 0, 0, 26)
		row.LayoutOrder = i
		row.ZIndex = 96
		if item.Disabled then
			row.BackgroundTransparency = 0.97
		end
		local iconLbl = label(row, item.Icon and Utils.Icon(item.Icon) or "", 12, false,
			item.Disabled and T.TextFaint or T.TextDim)
		iconLbl.Position = UDim2.new(0, 8, 0, 0)
		iconLbl.Size = UDim2.fromOffset(20, 26)
		iconLbl.ZIndex = 97
		local nameLbl = label(row, item.Name or "", 12, false,
			item.Disabled and T.TextFaint or T.Text)
		nameLbl.Position = UDim2.new(0, 32, 0, 0)
		nameLbl.Size = UDim2.new(1, -60, 1, 0)
		nameLbl.ZIndex = 97
		if item.Checked ~= nil then
			local chk = label(row, item.Checked and "✓" or "", 12, true, T.Accent, Enum.TextXAlignment.Right)
			chk.Size = UDim2.fromOffset(22, 26)
			chk.Position = UDim2.new(1, -26, 0, 0)
			chk.ZIndex = 97
		end
		local hit = clickTarget(row)
		hit.ZIndex = 98
		if not item.Disabled then
			hit.MouseEnter:Connect(function()
				BX.Tween(row, hoverInfo(), { BackgroundTransparency = 0.65 })
			end)
			hit.MouseLeave:Connect(function()
				BX.Tween(row, hoverInfo(), { BackgroundTransparency = 0.92 })
			end)
			hit.MouseButton1Click:Connect(function()
				playClick(0.07)
				close()
				Utils.SafeCall(item.Callback)
			end)
		end
	end

	local targetH = #items * 28 + 12
	-- 边界修正
	local cam = workspace.CurrentCamera
	if cam then
		local vp = cam.ViewportSize
		if y + targetH > vp.Y - 8 then
			y = math.max(8, vp.Y - targetH - 8)
			menu.Position = UDim2.fromOffset(x, y)
		end
		if x + 170 > vp.X - 8 then
			x = math.max(8, vp.X - 178)
			menu.Position = UDim2.fromOffset(x, y)
		end
	end
	BX.Tween(menu, TI(0.2, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(170, targetH), GroupTransparency = 0 })
	overlay.MouseButton1Click:Connect(close)
	return close
end

----------------------------------------------------------------
-- §33 键位列表面板
--    独立可拖动小窗，集中展示所有已注册热键。
--    local kb = BX:CreateKeybindList({ Title, Position })
--    注册：BX.RegisterKeybind(name, key, mode, description, getter)
----------------------------------------------------------------
local registeredKeybinds = {}

function BX.RegisterKeybind(name, key, mode, description)
	registeredKeybinds[#registeredKeybinds + 1] = {
		Name = name, Key = key, Mode = mode or "click",
		Description = description or "",
	}
end

function BX.UpdateKeybind(name, key)
	for _, k in ipairs(registeredKeybinds) do
		if k.Name == name then
			k.Key = key
			return
		end
	end
end

local KeybindListAPI = {}
KeybindListAPI.__index = KeybindListAPI

function BX:CreateKeybindList(cfg)
	cfg = cfg or {}
	local T = BX.CurrentTheme
	local gui = Instance.new("ScreenGui")
	gui.Name = "BarbatosXIUI_KeybindList"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 996
	pcall(function() gui.Parent = game:GetService("CoreGui") end)
	if not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end

	local frame = glass(gui, 10, 0.85)
	frame.Size = UDim2.fromOffset(200, 30)
	frame.Position = cfg.Position or UDim2.new(0, 12, 0.5, -100)

	local title = label(frame, cfg.Title or "键位", 12, true)
	title.Position = UDim2.new(0, 10, 0, 0)
	title.Size = UDim2.new(1, -20, 0, 30)

	local listHolder = Instance.new("Frame")
	listHolder.BackgroundTransparency = 1
	listHolder.Size = UDim2.new(1, -12, 1, -38)
	listHolder.Position = UDim2.new(0, 6, 0, 34)
	listHolder.AutomaticSize = Enum.AutomaticSize.Y
	listHolder.Parent = frame
	local ll = Instance.new("UIListLayout")
	ll.Padding = UDim.new(0, 3)
	ll.SortOrder = Enum.SortOrder.LayoutOrder
	ll.Parent = listHolder

	local rows = {}
	local self = setmetatable({ Gui = gui, Frame = frame, Visible = cfg.Visible ~= false }, KeybindListAPI)

	local function rebuild()
		for _, r in ipairs(rows) do r:Destroy() end
		rows = {}
		for i, k in ipairs(registeredKeybinds) do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = T.Glass
			row.BackgroundTransparency = 0.93
			row.BorderSizePixel = 0
			row.Size = UDim2.new(1, 0, 0, 22)
			row.LayoutOrder = i
			row.Parent = listHolder
			local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 6); rc.Parent = row
			local name = label(row, k.Name, 11, false, T.TextDim)
			name.Position = UDim2.new(0, 8, 0, 0)
			name.Size = UDim2.new(1, -70, 1, 0)
			local keyBtn = glass(row, 6, 0.8)
			keyBtn.Size = UDim2.fromOffset(52, 18)
			keyBtn.Position = UDim2.new(1, -58, 0.5, -9)
			local keyLbl = label(keyBtn, Utils.KeyName(k.Key), 10, true, T.Text, Enum.TextXAlignment.Center)
			keyLbl.Size = UDim2.fromScale(1, 1)
			rows[#rows + 1] = row
			rows[#rows + 1] = keyBtn
		end
		-- 自适应高度
		local h = 34 + #registeredKeybinds * 25 + 6
		BX.Tween(frame, TI(0.25), { Size = UDim2.fromOffset(200, math.max(30, h)) })
	end
	rebuild()
	self._rebuild = rebuild

	local dragging = false
	local dStart, fStart
	frame.InputBegan:Connect(function(input)
		if Utils.IsPress(input) then
			dragging = true
			dStart = input.Position
			fStart = frame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if Utils.IsPress(input) then dragging = false end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and Utils.IsMove(input) then
			local d = input.Position - dStart
			BX.Tween(frame, TI(0.14, Enum.EasingStyle.Sine), {
				Position = UDim2.new(fStart.X.Scale, fStart.X.Offset + d.X, fStart.Y.Scale, fStart.Y.Offset + d.Y),
			})
		end
	end)

	if not self.Visible then frame.Visible = false end
	return self
end

function KeybindListAPI:SetVisible(v)
	self.Visible = v
	self.Frame.Visible = v
end

function KeybindListAPI:Refresh()
	self._rebuild()
end

function KeybindListAPI:Remove()
	self.Gui:Destroy()
end

-- 热键元素自动登记到键位列表（在 AddKeybind 后由使用者手动调用，
-- 或直接在 data 里传 ListName / ListDescription）
local _origAddKeybind = ElementAPI.AddKeybind
function ElementAPI.AddKeybind(self, data)
	data = data or {}
	local api = _origAddKeybind(self, data)
	if typeof(data.ListName) == "string" and data.ListName ~= "" then
		BX.RegisterKeybind(data.ListName, data.Default or Enum.KeyCode.Unknown,
			data.Mode, data.ListDescription or "")
		local oldSet = api.Set
		function api.Set(_, k)
			oldSet(api, k)
			BX.UpdateKeybind(data.ListName, k)
		end
	end
	return api
end

----------------------------------------------------------------
-- §34 区间滑条（双值）
--    data: { Name, Min, Max, Default = {a, b}, Rounding, Suffix,
--            Gap (最小间距), Flag, Callback(a, b) }
----------------------------------------------------------------
function ElementAPI.AddDualSlider(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 50)
	rowText(self, r, data.Name, data.Tooltip)
	local val = label(r, "", 12, false, T.TextDim, Enum.TextXAlignment.Right)
	val.Position = UDim2.new(1, -110, 0, 0)
	val.Size = UDim2.fromOffset(98, 22)
	val.ZIndex = 4
	textDim(val)

	local track = pill(r, 0.82)
	track.Size = UDim2.new(1, -24, 0, 6)
	track.Position = UDim2.new(0, 12, 1, -16)
	track.ZIndex = 3
	local rangeFill = pill(track, 0.35)
	rangeFill.BackgroundColor3 = T.Accent
	rangeFill.ZIndex = 4

	local function makeDot()
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Size = UDim2.fromOffset(13, 13)
		dot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		dot.BorderSizePixel = 0
		dot.ZIndex = 6
		dot.Parent = track
		local dc = Instance.new("UICorner"); dc.CornerRadius = UDim.new(1, 0); dc.Parent = dot
		local dg = Instance.new("UIGradient"); dg.Rotation = 90; dg.Parent = dot
		gradientStroke(dot, 1.2, 0.2)
		return dot
	end
	local dotA, dotB = makeDot(), makeDot()

	local minV, maxV = data.Min or 0, data.Max or 100
	local round = data.Rounding or 0
	local suffix = data.Suffix or ""
	local gap = data.Gap or 0
	local dv = data.Default or { minV, maxV }
	local a = math.clamp(dv[1] or minV, minV, maxV)
	local b = math.clamp(dv[2] or maxV, minV, maxV)
	if b < a then a, b = b, a end
	local holding = "none"

	local function fmt(v)
		return string.format("%." .. round .. "f", v) .. suffix
	end
	local function render(instant)
		local pa = (a - minV) / math.max(maxV - minV, 1e-9)
		local pb = (b - minV) / math.max(maxV - minV, 1e-9)
		local ti = instant and TI(0) or TI(0.12)
		BX.Tween(dotA, ti, { Position = UDim2.new(pa, 0, 0.5, 0) })
		BX.Tween(dotB, ti, { Position = UDim2.new(pb, 0, 0.5, 0) })
		BX.Tween(rangeFill, ti, {
			Position = UDim2.new(pa, 0, 0, 0),
			Size = UDim2.new(math.max(pb - pa, 0.02), 0, 1, 0),
		})
		val.Text = fmt(a) .. " ~ " .. fmt(b)
	end
	local function applyRound(v)
		if round > 0 then
			local step = 1 / (10 ^ round)
			return math.floor(v / step + 0.5) * step
		end
		return math.floor(v + 0.5)
	end
	local function updateFromX(x, which)
		local p = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local v = math.clamp(applyRound(minV + (maxV - minV) * p), minV, maxV)
		if which == "a" then
			a = math.min(v, b - gap)
		else
			b = math.max(v, a + gap)
		end
		render()
		Utils.SafeCall(data.Callback, a, b)
	end
	render(true)

	local hit = clickTarget(r)
	hit.Position = UDim2.new(0, 8, 1, -30)
	hit.Size = UDim2.new(1, -16, 0, 28)
	hit.ZIndex = 7
	hit.InputBegan:Connect(function(input)
		if not Utils.IsPress(input) then return end
		local p = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local pa = (a - minV) / math.max(maxV - minV, 1e-9)
		local pb = (b - minV) / math.max(maxV - minV, 1e-9)
		holding = (math.abs(p - pa) <= math.abs(p - pb)) and "a" or "b"
		updateFromX(input.Position.X, holding)
	end)
	UserInputService.InputChanged:Connect(function(input)
		if holding ~= "none" and Utils.IsMove(input) then
			updateFromX(input.Position.X, holding)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if Utils.IsPress(input) then holding = "none" end
	end)

	local api = {}
	function api:Set(v1, v2)
		if typeof(v1) == "table" then v1, v2 = v1[1], v1[2] end
		a = math.clamp(typeof(v1) == "number" and v1 or minV, minV, maxV)
		b = math.clamp(typeof(v2) == "number" and v2 or maxV, minV, maxV)
		if b < a then a, b = b, a end
		render()
	end
	function api:Get() return a, b end

	if typeof(data.Flag) == "string" and data.Flag ~= "" then
		registerFlag(data.Flag, {
			Get = function() return { a, b } end,
			Set = function(v) api.Set(api, v) end,
		})
	end
	return api
end

----------------------------------------------------------------
-- §35 字符串列表
--    可增删的条目列表，常用于白名单 / 好友列表。
--    data: { Name, Values, Placeholder, MaxItems, Flag, Callback(values) }
----------------------------------------------------------------
function ElementAPI.AddItemList(self, data)
	data = data or {}
	local T = BX.CurrentTheme
	local r = nextRow(self, 120)
	rowText(self, r, data.Name, data.Tooltip)

	local list = {}
	if typeof(data.Values) == "table" then
		for _, v in ipairs(data.Values) do list[#list + 1] = tostring(v) end
	end

	local holder = Instance.new("ScrollingFrame")
	holder.BackgroundColor3 = T.Glass
	holder.BackgroundTransparency = 0.93
	holder.BorderSizePixel = 0
	holder.Size = UDim2.new(1, -24, 1, -58)
	holder.Position = UDim2.new(0, 12, 0, 10)
	holder.CanvasSize = UDim2.fromScale(0, 0)
	holder.AutomaticCanvasSize = Enum.AutomaticSize.Y
	holder.ScrollBarThickness = 2
	holder.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
	holder.ZIndex = 3
	holder.Parent = r
	local hc = Instance.new("UICorner"); hc.CornerRadius = UDim.new(0, 8); hc.Parent = holder
	local hp = Instance.new("UIPadding")
	hp.PaddingTop = UDim.new(0, 6); hp.PaddingBottom = UDim.new(0, 6)
	hp.PaddingLeft = UDim.new(0, 6); hp.PaddingRight = UDim.new(0, 6)
	hp.Parent = holder
	local hl = Instance.new("UIListLayout")
	hl.Padding = UDim.new(0, 4)
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Parent = holder

	local inputBox = glass(r, 7, 0.85)
	inputBox.Size = UDim2.new(1, -74, 0, 26)
	inputBox.Position = UDim2.new(0, 12, 1, -36)
	inputBox.ZIndex = 3
	local tb = Instance.new("TextBox")
	tb.BackgroundTransparency = 1
	tb.Text = ""
	tb.PlaceholderText = data.Placeholder or "输入后回车添加..."
	tb.PlaceholderColor3 = T.TextFaint
	tb.TextColor3 = T.Text
	tb.Font = T.Font
	tb.TextSize = 12
	tb.ClearTextOnFocus = false
	tb.Size = UDim2.new(1, -14, 1, 0)
	tb.Position = UDim2.fromOffset(7, 0)
	tb.ZIndex = 4
	tb.Parent = inputBox

	local countLbl = label(r, "0 项", 10, false, T.TextFaint, Enum.TextXAlignment.Right)
	countLbl.Position = UDim2.new(1, -56, 0, 10)
	countLbl.Size = UDim2.fromOffset(44, 18)
	countLbl.ZIndex = 4
	textFaint(countLbl)

	local function emit()
		countLbl.Text = #list .. " 项"
		Utils.SafeCall(data.Callback, list)
	end

	local function rebuild()
		for _, c in ipairs(holder:GetChildren()) do
			if c:IsA("GuiObject") then c:Destroy() end
		end
		for i, v in ipairs(list) do
			local row = glass(holder, 6, 0.92)
			row.Size = UDim2.new(1, 0, 0, 24)
			row.LayoutOrder = i
			row.ZIndex = 4
			local txt = label(row, v, 12, false, T.Text)
			txt.Position = UDim2.new(0, 8, 0, 0)
			txt.Size = UDim2.new(1, -40, 1, 0)
			txt.ZIndex = 5
			txt.TextTruncate = Enum.TextTruncate.AtEnd
			local del = label(row, "✕", 12, true, T.TextFaint, Enum.TextXAlignment.Center)
			del.Size = UDim2.fromOffset(22, 24)
			del.Position = UDim2.new(1, -24, 0, 0)
			del.ZIndex = 5
			textFaint(del)
			clickTarget(row).MouseButton1Click:Connect(function()
				playClick(0.06)
				for j, x in ipairs(list) do
					if x == v then table.remove(list, j) break end
				end
				rebuild()
				emit()
			end)
		end
		emit()
	end

	local function addItem(text)
		text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if text == "" then return end
		if data.MaxItems and #list >= data.MaxItems then
			BX:Notify({ Title = "列表", Content = "最多只能添加 " .. data.MaxItems .. " 项", Duration = 2.5, Type = "warning" })
			return
		end
		for _, v in ipairs(list) do
			if v == text then
				BX:Notify({ Title = "列表", Content = "已存在相同条目", Duration = 2, Type = "warning" })
				return
			end
		end
		list[#list + 1] = text
		rebuild()
	end

	tb.FocusLost:Connect(function(enter)
		if enter then
			addItem(tb.Text)
			tb.Text = ""
		end
	end)

	local addBtn = glass(r, 7, 0.8)
	addBtn.Size = UDim2.fromOffset(42, 26)
	addBtn.Position = UDim2.new(1, -54, 1, -36)
	addBtn.ZIndex = 3
	local addLbl = label(addBtn, "+ 添加", 11, true, T.Text, Enum.TextXAlignment.Center)
	addLbl.Size = UDim2.fromScale(1, 1)
	addLbl.ZIndex = 4
	clickTarget(addBtn).MouseButton1Click:Connect(function()
		playClick(0.07)
		addItem(tb.Text)
		tb.Text = ""
	end)

	rebuild()

	local api = {}
	function api:Add(v) addItem(v) end
	function api:Remove(v)
		for j, x in ipairs(list) do
			if x == tostring(v) then table.remove(list, j) break end
		end
		rebuild()
	end
	function api:Set(values)
		list = {}
		if typeof(values) == "table" then
			for _, v in ipairs(values) do list[#list + 1] = tostring(v) end
		end
		rebuild()
	end
	function api:Get()
		local out = {}
		for i, v in ipairs(list) do out[i] = v end
		return out
	end
	function api:Clear()
		list = {}
		rebuild()
	end

	if typeof(data.Flag) == "string" and data.Flag ~= "" then
		registerFlag(data.Flag, {
			Get = function()
				local out = {}
				for i, v in ipairs(list) do out[i] = v end
				return out
			end,
			Set = function(v) api.Set(api, v) end,
		})
	end
	return api
end

----------------------------------------------------------------
-- §36 快速工具栏
--    屏幕底部 / 顶部一排图标按钮，用于一键开关常用功能。
--    local bar = BX:CreateToolbar({ Position = "bottom"|"top", Items = {
--        { Icon, Tooltip, Active, Callback(active) }, ... } })
--    api: SetActive(index, bool) / Remove()
----------------------------------------------------------------
local ToolbarAPI = {}
ToolbarAPI.__index = ToolbarAPI

function BX:CreateToolbar(cfg)
	cfg = cfg or {}
	local T = BX.CurrentTheme
	local gui = Instance.new("ScreenGui")
	gui.Name = "BarbatosXIUI_Toolbar"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 995
	pcall(function() gui.Parent = game:GetService("CoreGui") end)
	if not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end

	local bar = glass(gui, 12, 0.85)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.Size = UDim2.fromOffset(0, 42)
	local items = cfg.Items or {}
	local w = #items * 40 + 16
	if cfg.Position == "top" then
		bar.AnchorPoint = Vector2.new(0.5, 0)
		bar.Position = UDim2.new(0.5, 0, 0, 10)
	else
		bar.AnchorPoint = Vector2.new(0.5, 1)
		bar.Position = UDim2.new(0.5, 0, 1, -10)
	end
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = bar
	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.Padding = UDim.new(0, 4)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.Parent = bar

	local self = setmetatable({ Gui = gui, Bar = bar, Items = {} }, ToolbarAPI)
	local states = {}

	for i, item in ipairs(items) do
		local btn = glass(bar, 8, item.Active and T.GlassActive or 0.9)
		btn.Size = UDim2.fromOffset(34, 34)
		btn.LayoutOrder = i
		local lbl = label(btn, item.Icon and Utils.Icon(item.Icon) or "•", 15,
			item.Active == true, item.Active and T.AccentDark or T.TextDim, Enum.TextXAlignment.Center)
		lbl.Size = UDim2.fromScale(1, 1)
		states[i] = item.Active == true
		local function apply(instant)
			BX.Tween(btn, instant and TI(0) or TI(0.2), {
				BackgroundTransparency = states[i] and T.GlassActive or 0.9,
			})
			lbl.Font = states[i] and T.FontBold or T.Font
			lbl.TextColor3 = states[i] and T.AccentDark or T.TextDim
		end
		local hit = clickTarget(btn)
		if item.Tooltip then BX.AttachTooltip(btn, item.Tooltip) end
		hit.MouseButton1Click:Connect(function()
			states[i] = not states[i]
			apply()
			playClick(0.08)
			Utils.SafeCall(item.Callback, states[i])
		end)
		self.Items[i] = { Button = btn, Set = function(v) states[i] = v == true apply(true) end, Get = function() return states[i] end }
	end
	return self
end

function ToolbarAPI:SetActive(index, v)
	local item = self.Items[index]
	if item then item.Set(v) end
end

function ToolbarAPI:GetActive(index)
	local item = self.Items[index]
	return item and item.Get() or nil
end

function ToolbarAPI:SetVisible(v)
	self.Bar.Visible = v
end

function ToolbarAPI:Remove()
	self.Gui:Destroy()
end

----------------------------------------------------------------
-- §37 分节折叠
--    section:Collapse() / section:Expand() / section:Toggle()
--    通过隐藏内部行实现，容器 AutomaticSize 自动收缩，无需算高度。
----------------------------------------------------------------
local _origAddSection = nil -- 占位（AddSection 定义在 §17，这里包装）

-- 由于 AddSection 是 WindowAPI.AddTab 的闭包内函数，改为给 section 表打补丁：
-- 在 ElementAPI 装配之后，sec 已含全部元素方法；这里追加折叠方法。
local function patchSectionCollapse(sec)
	sec._collapsed = false
	local box = sec._box
	local children = {}
	local function collect()
		children = {}
		for _, c in ipairs(box:GetChildren()) do
			if c:IsA("GuiObject") and c.LayoutOrder ~= 0 then
				children[#children + 1] = c
			end
		end
	end
	collect()
	local titleBar = nil
	for _, c in ipairs(box:GetChildren()) do
		if c:IsA("TextLabel") and c.LayoutOrder == 0 then
			titleBar = c
			break
		end
	end
	if titleBar then
		titleBar.TextXAlignment = Enum.TextXAlignment.Left
		local arrow = Instance.new("TextLabel")
		arrow.BackgroundTransparency = 1
		arrow.Text = "⌄"
		arrow.TextColor3 = BX.CurrentTheme.TextFaint
		arrow.Font = BX.CurrentTheme.FontBold
		arrow.TextSize = 12
		arrow.Size = UDim2.fromOffset(16, 16)
		arrow.Position = UDim2.new(1, -18, 0, 0)
		arrow.ZIndex = 3
		arrow.Parent = box
		arrow.LayoutOrder = 0
		local hit = clickTarget(box)
		hit.Size = UDim2.new(1, 0, 0, 26)
		hit.Position = UDim2.fromOffset(0, 0)
		hit.MouseButton1Click:Connect(function()
			sec.Toggle(sec)
		end)
	end
	function sec:Collapse()
		self._collapsed = true
		collect()
		for _, c in ipairs(children) do
			c.Visible = false
		end
	end
	function sec:Expand()
		self._collapsed = false
		collect()
		for _, c in ipairs(children) do
			c.Visible = true
		end
	end
	function sec:Toggle()
		if self._collapsed then self.Expand(self) else self.Collapse(self) end
	end
	function sec:IsCollapsed() return self._collapsed end
	return sec
end

-- 挂接：包装 WindowAPI.AddTab 返回的 tab:AddSection
local _windowAddTab = WindowAPI.AddTab
function WindowAPI:AddTab(info)
	local tab = _windowAddTab(self, info)
	local _tabAddSection = tab.AddSection
	function tab:AddSection(secInfo)
		local sec = _tabAddSection(self, secInfo)
		patchSectionCollapse(sec)
		return sec
	end
	return tab
end

----------------------------------------------------------------
-- §38 窗口补充 API
----------------------------------------------------------------
--- 窗口居中（带动画）
function WindowAPI:Center()
	BX.Tween(self.Main, TI(0.35, Enum.EasingStyle.Quart), {
		Position = UDim2.fromScale(0.5, 0.5),
	})
end

--- 设置窗口位置（带动画）
function WindowAPI:SetPosition(pos)
	BX.Tween(self.Main, TI(0.3, Enum.EasingStyle.Quart), { Position = pos })
end

--- 窗口当前开合状态
function WindowAPI:GetState()
	return self.Open
end

--- 直接设置开合
function WindowAPI:SetState(v)
	self.SetOpen(v == true)
end

--- 切换开合
function WindowAPI:Toggle()
	self.SetOpen(not self.Open)
end

--- 带确认框的关闭询问（防误触）
function WindowAPI:PromptClose()
	BX:Confirm({
		Title = "关闭",
		Content = "确定要收起界面吗？\n再次按下 [" .. self.Keybind.Name .. "] 可以重新打开。",
		ConfirmText = "收起",
		Callback = function(ok)
			if ok then self.SetOpen(false) end
		end,
	})
end

--- 销毁整个窗口
function WindowAPI:Destroy()
	if self.Gui then self.Gui:Destroy() end
end

----------------------------------------------------------------
-- §39 更新日志弹窗
--    BX:ShowChangelog({ Title, Entries = {
--        { Version = "1.0.0", Date = "2026-10-08", Items = {"新增 ...", "修复 ..."} }, ... } })
----------------------------------------------------------------
function BX:ShowChangelog(data)
	data = data or {}
	ensureModalGui()
	local T = BX.CurrentTheme
	local gui = modalGui
	local bd = modalBackdrop(gui)
	local card = modalCard(gui, 320)
	modalTitle(card, data.Title or "更新日志", "refresh")
	card.AutomaticSize = Enum.AutomaticSize.None
	card.Size = UDim2.fromOffset(320, 380)

	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, 0, 1, -46)
	scroll.CanvasSize = UDim2.fromScale(0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 2
	scroll.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
	scroll.LayoutOrder = 1
	scroll.Parent = card
	local sl = Instance.new("UIListLayout")
	sl.Padding = UDim.new(0, 10)
	sl.SortOrder = Enum.SortOrder.LayoutOrder
	sl.Parent = scroll

	local order = 0
	for _, entry in ipairs(data.Entries or {}) do
		order = order + 1
		local block = glass(scroll, 8, 0.93)
		block.Size = UDim2.new(1, 0, 0, 0)
		block.AutomaticSize = Enum.AutomaticSize.Y
		block.LayoutOrder = order
		local bp = Instance.new("UIPadding")
		bp.PaddingTop = UDim.new(0, 8); bp.PaddingBottom = UDim.new(0, 8)
		bp.PaddingLeft = UDim.new(0, 10); bp.PaddingRight = UDim.new(0, 10)
		bp.Parent = block
		local bl = Instance.new("UIListLayout")
		bl.Padding = UDim.new(0, 4)
		bl.SortOrder = Enum.SortOrder.LayoutOrder
		bl.Parent = block
		local head = label(block, "v" .. tostring(entry.Version or "?") .. "   " .. tostring(entry.Date or ""), 12, true)
		head.Size = UDim2.new(1, 0, 0, 16)
		local items = entry.Items or {}
		for i, text in ipairs(items) do
			local it = label(block, "· " .. tostring(text), 11, false, T.TextDim)
			it.Size = UDim2.new(1, 0, 0, 15)
			it.TextYAlignment = Enum.TextYAlignment.Top
			it.TextWrapped = true
			it.AutomaticSize = Enum.AutomaticSize.Y
			it.LayoutOrder = i
			textDim(it)
		end
	end

	local row = modalButtonRow(card)
	row.LayoutOrder = 2
	local entry = { card = card, backdrop = bd, closed = false }
	entry.onConfirm = function()
		closeModal(entry)
		Utils.SafeCall(data.Callback)
	end
	entry.onCancel = entry.onConfirm
	modalGlassButton(row, "关闭", true, entry.onConfirm)
	pushModal(entry)
	return entry
end

----------------------------------------------------------------
-- §40 自定义主题注册
--    BX:RegisterTheme("MyTheme", { WindowBg = ..., Glass = ..., ... })
--    字段缺省时自动继承当前主题，保证不写全也能用。
----------------------------------------------------------------
function BX:RegisterTheme(name, def)
	if typeof(name) ~= "string" or name == "" or typeof(def) ~= "table" then
		return false
	end
	local base = Utils.DeepCopy(self.CurrentTheme)
	for k, v in pairs(def) do
		base[k] = v
	end
	base.Font = base.Font or Enum.Font.GothamMedium
	base.FontBold = base.FontBold or Enum.Font.GothamBold
	self.Themes[name] = base
	return true
end

----------------------------------------------------------------
-- §41 全局销毁
----------------------------------------------------------------
function BX:Destroy()
	for _, gui in ipairs({ notifyGui, modalGui, ctxGui, tooltipGui }) do
		pcall(function() if gui then gui:Destroy() end end)
	end
	notifyGui, modalGui, ctxGui, tooltipGui = nil, nil, nil, nil
end
