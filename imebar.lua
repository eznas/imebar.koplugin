--[[--
imebar — 软键盘上方的候选字条。

一条白底、顶部细灰线的横条，显示输入法引擎的候选窗口（组词草稿 +
编号候选，形如 "你好[2妮 3泥…]"）。候选由 main.lua 包 IME:getHintChars
拆出后推给本条，输入框里只剩舞台字 —— 候选不再挤在单行框里被裁掉。

几何直觉来自 vterm.koplugin/vterm_view.lua 的候选字条：条高按 CJK 墨高
+ 西文降部算（不用整行 line height，否则字离键盘太远还白吃一行），
TextWidget 只用来测量/绘制并垂直居中。

ponytail: 整条 setDirty("ui") 刷新，没做 vterm 那套 80ms 合并与 Geom 局部
脏区。一条窄带够用；若真机出现拖影/闪，再加局部刷新。
ponytail: 候选字符串由引擎给，本条不解析组合态、不碰输入路由。
ponytail: 对话框容器底沿正好等于键盘顶沿（inputdialog.lua:445），全屏对话框
的按钮行会被条带盖住，故 hasRoom() 在这种情形直接不显示条带（也顺带不干扰
vterm 自绘条 —— 条带不显示时 main.lua 完全不碰引擎）。
]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local Screen = require("device").screen

local ImeBar = Widget:extend{
    name = "imebar",
    -- 纯显示；modal 键盘始终在它上面，条带不会成为 top_widget 抢事件。
    is_always_active = false,
}

function ImeBar:init()
    self.face = Font:getFace("cfont")
    -- CJK 墨高 + 西文降部 + 余量，对齐 vterm_view.lua:141-151。
    -- 字形测量失败（缺 CJK 字体等）不能拖垮整个插件，pcall 后回退字号。
    local g_cjk, g_desc
    pcall(function()
        g_cjk = RenderText:getGlyph(self.face, 0x5019, false) -- 候
        g_desc = RenderText:getGlyph(self.face, 0x67, false)  -- g
    end)
    local ink_h = (g_cjk and g_cjk.bb and g_cjk.bb:getHeight()) or self.face.size
    local ink_t = (g_cjk and g_cjk.t) or 0
    local desc = (g_desc and g_desc.bb and math.max(0, g_desc.bb:getHeight() - g_desc.t)) or 0
    self.bar_h = math.max(6, ink_h + desc + 6)
    self.ink_h = ink_h
    self.ink_t = ink_t
    -- 文字左右间隙：按 KOReader 惯例走 scaleBySize（逻辑像素 → 物理像素）。
    -- fb:scaleBySize 用 min(屏宽,屏高)/600 折算 —— 模拟器(600 宽)=10px，
    -- 真机(1072 宽, 300ppi)≈18px。写死物理像素在真机上只有 0.85mm，
    -- 肉眼几乎不可见（用户实测「没影响」的根因）。
    self.text_gap = Screen:scaleBySize(10)
    self.text = ""
    self._hint = nil
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = self.bar_h }
    -- 把条带的精确几何发布给自带引擎（共享同一个类表），供 visiblePageSize
    -- 折算每页候选数。用条带自己的 face.size，避免引擎另取字体时机不一致
    -- 导致字号算错、候选数缩不下来（真机「前半截被裁」的根因）。
    local engine = package.loaded["ui/data/keyboardlayouts/generic_ime"]
    if type(engine) == "table" then
        engine._imebar_geo = {
            avail_w = self.dimen.w - 2 * self.text_gap, -- 与 paintTo 的 max_width 一致
            face_size = self.face.size,
        }
    end
end

-- 键盘顶沿 = 屏高 - 键盘高；条带压在它正上方（绝对屏幕坐标）。
local function barY(keyboard, bar_h)
    local kb_h = keyboard.dimen and keyboard.dimen.h or 0
    return Screen:getHeight() - kb_h - bar_h
end

function ImeBar:placeAbove(keyboard)
    local y = math.max(0, barY(keyboard, self.bar_h))
    self.dimen.y = y
    self.dimen.x = 0
    self.dimen.w = Screen:getWidth()
    self.dimen.h = self.bar_h
end

-- 非全屏对话框是居中的，容器底部自然留出空隙给条带；全屏框（含 vterm，
-- 它自绘候选条）的 frame 底沿贴着键盘顶沿，条带会盖住按钮行 —— 直接跳过。
-- fullscreen 是 dialog 上的直接标志，不需要测量未绘制的 widget，稳健。
-- ponytail: 极少数「非全屏但很高」的多行框（如自定义词组表）仍可能与条带
-- 重叠；真机若出现再按 frame 高度加一条判据。
function ImeBar:hasRoom(keyboard)
    local dialog = keyboard.inputbox and keyboard.inputbox.parent
    if dialog and dialog.fullscreen then return false end
    -- 「命令通道」输入框（TermInputText：字符直传 PTY）不叠加条带，否则
    -- IME 包装会让终端 BusyBox 空转（pinyinplus README 实证）。
    -- 判据只用 min_buffer_size：stock inputtext.lua:80 正是用它区分终端
    -- （注释「not Terminal plugin input」）。strike_callback 不能用作判据 ——
    -- 普通 InputDialog 的多行「转到行」功能也设它（inputdialog.lua:1040），
    -- 按它误杀会让这类系统输入框的条带凭空消失。
    local ib = keyboard.inputbox
    if ib and ib.min_buffer_size ~= nil then
        return false
    end
    return barY(keyboard, self.bar_h) >= 0
end

function ImeBar:invalidate()
    if not self._shown then return end
    -- 重绘本条 + 让上方键盘/对话框连带重绘（uimanager.lua:1232-1257）
    UIManager:setDirty(self, "ui", self.dimen)
end

-- 候选字符串（引擎 getHintChars 拆出的括号段，带方括号）。
-- hint=true 时用灰字画（v 模式空缓冲的操作提示），黑字是正常候选。
-- 内容没变就跳过整条重绘 —— e-ink 刷新是功耗大头，引擎在边界翻页/重入
-- 时会用同一串重复调用（参考 pinyinplus 的宽度签名去重思路）。
function ImeBar:setCandidates(s, hint)
    s = (type(s) == "string") and s or ""
    hint = hint == true
    if self.text == s and self._hint == hint then return end
    self.text = s
    self._hint = hint
    self:invalidate()
end

function ImeBar:clearCandidates()
    if self.text == "" and not self._hint then return end
    self.text = ""
    self._hint = nil
    self:invalidate()
end

function ImeBar:show(keyboard)
    if self._shown then
        local old_y = self.dimen and self.dimen.y
        self:placeAbove(keyboard)
        -- 已显示时，只有几何真的变了（键盘高度变化导致条带挪位）才重绘。
        -- 布局切换 / 重复显隐的全条 setDirty("ui") 是白刷一次 e-ink 波形。
        if not old_y or old_y ~= self.dimen.y then self:invalidate() end
        return
    end
    if not self:hasRoom(keyboard) then return end
    self:placeAbove(keyboard)
    -- UIManager:show 会按新 widget 字段覆写全局双击/点按间隔，先继承键盘的。
    self.disable_double_tap = keyboard.disable_double_tap
    self.tap_interval_override = keyboard.tap_interval_override
    self._shown = true
    UIManager:show(self, "ui", self.dimen, 0, self.dimen.y)
end

function ImeBar:close()
    if not self._shown then return end
    self._shown = false
    UIManager:close(self)
    self.text = ""
    self._hint = nil
end

-- 条带被关掉时自己补一条覆盖本区域的刷新：对话框底沿贴着键盘顶沿，条带
-- 恰在两者的缝隙里，下方没有 widget 会在屏幕刷新里带上这条区域 ——
-- UIManager:close 不带 mode 不入刷新队列，全靠各 widget 的 onCloseWidget
-- 自补（VirtualKeyboard:onCloseWidget 同款套路）。缺了它，点框外收键盘
-- 时条带在 e-ink 上残留（bb 其实已擦掉，是屏幕刷新没盖到）。
function ImeBar:onCloseWidget()
    if not self.dimen then return end
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function ImeBar:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x, y, w, 2, Blitbuffer.COLOR_LIGHT_GRAY)
    if self.text == "" then return end
    local tw = TextWidget:new{
        text = self.text,
        face = self.face,
        fgcolor = self._hint and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK,
        max_width = w - 2 * self.text_gap, -- 左右各留 text_gap（scaleBySize 后）
        -- 从右截断（保住舞台字在前）：引擎已按条带宽度缩减候选数，正常不会
        -- 触发；万一超宽也绝不能丢舞台字（用户报的「前半截被裁」就是这个）。
        truncate_left = false,
    }
    local baseline = y + math.max(0, math.floor((h - (self.ink_h or 0)) / 2)) + (self.ink_t or 0)
    tw:paintTo(bb, x + self.text_gap, baseline - tw:getBaseline())
    tw:free()
end

return ImeBar
