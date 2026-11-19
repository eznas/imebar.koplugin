--[[--
imebar.koplugin — 软键盘上方候选字条 + 自带拼音增强引擎（系统级）。

自带引擎（ime_engine.lua，stock generic_ime.lua 的补丁副本）提供：数字编号
候选、数字 2-9 + 0 选字、←/→ 翻页、模糊拼音、记忆词、自定义词组、v 模式。
候选完整串（含舞台字，如 "你[2拟3尼…]"）显示在键盘上方的整屏宽条带，
输入框组合期实时显拼音字母、选字提交时覆盖为汉字 —— 不再被长候选撑爆。
不依赖 imeplus，可单独取代它。

引擎生效方式：加载期把自带引擎放进 package.loaded[".../generic_ime"]。
require 先查 loaded 再查 preload，且 imebar 按路径排序先于 imeplus 加载，
故自带引擎稳定优先；imeplus 同时安装时其 preload 不会被触发（仅记一条 warn）。
磁盘零改动、不改任何系统文件、不改 imeplus 文件。

运行时包裹（磁盘零改动）：
  VirtualKeyboard:init         → 延迟包 IME 类方法（此时引擎已在 loaded）
  IME:getHintChars             → 完整串推给条带（内容不变跳过重绘）
  IME:clear_stack              → 提交/重置时清条带
  VirtualKeyboard:setVisibility / onClose / setKeyboardLayout → 条带显隐 + 引擎门控

门控：仅当开关开启、zh_CN 拼音布局、且条带真正显示（hasRoom）时接管；
否则 getHintChars 纯透传、引擎走原生内联候选（开关关闭 / 非拼音布局 /
全屏框如 vterm / Terminal 命令通道 100% 回退）。条带 UI 抛错也不影响
引擎门控（barFollowKeyboard 把门控赋值放在 guarded 之外）。

版本护栏：pcall(require) + 方法存在性检查，任一不符则静默失效、回退原生
（绝不闪退）。不读取系统源码文件。
]]

local logger = require("logger")
local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local ENGINE_MODULE = "ui/data/keyboardlayouts/generic_ime"
local ENABLED_KEY = "imebar_enabled"
local bar = nil
local installed = false
local ime_wrapped = false
-- vterm 等全屏终端复用引擎增强模式，但候选串画在它自己预留的条带上：
-- 注册进来的 sink 取代条带 widget 成为候选出口（不新建 widget、不盖功能键）。
local external_sink = nil
-- vterm widget 本体模式：imebar 的 ImeBar widget 锚定到 vterm 预留条带位，
-- 直接由它绘候选（取代 vterm 自绘条）。external_widget=true 时候选走 widget，
-- 不走 sink；显示期间屏蔽 barFollowKeyboard 对全屏框的自动 close。
local external_widget = false

local function enabled()
    return G_reader_settings and G_reader_settings:nilOrTrue(ENABLED_KEY)
end

-- 纯显示/增强特性绝不能拖垮文字输入：条带相关调用一律 pcall 兜底。
local function guarded(f)
    local ok, err = pcall(f)
    if not ok then logger.warn("imebar: ", tostring(err)) end
end

-- 当前是否该接管候选显示（条带挂上了，或外部终端注册了候选出口）。
local function active()
    return installed and enabled() and ((bar and bar._shown) or external_sink ~= nil)
end

-- vterm widget 本体模式：让 imebar 的 widget 显示在调用方（vterm）预留的
-- 条带矩形里。字体两边都用 cfont（见 vterm_view bar_face），故几何天然一致，
-- 无需注入 face/重算。kb = 键盘实例（提供 inputbox 给触摸回调）；
-- rect = {x,y,w,h} 屏幕坐标。返回 false 表示插件未就绪。
local function mountExternal(kb, rect)
    if not installed or not enabled() or not bar then return false end
    if type(rect) ~= "table" or not rect.x or not rect.y or not rect.w or not rect.h then
        return false
    end
    external_widget = true
    bar._external_rect = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    guarded(function() bar:show(kb) end)
    local IME = package.loaded[ENGINE_MODULE]
    if IME then
        IME.imebar_inline_code = true
        -- 与 sink 模式同理：v 缓冲预览走 widget 条带，但缓冲正文仍须逐键写输入框，
        -- v 缓冲只走条带、不逐键写输入框：逐键写时单空格追加的 " " 恰等于所按
        -- 字符，会被 vterm 差分当成直通字符发 PTY（单空格上屏）。提交改由 vCommit
        -- 末尾的 _vtCommitDraft() 显式完成，整串一次发，输入框在组合期保持干净。
        IME.imebar_external_vmode = false
    end
    return true
end

local function unmountExternal()
    external_widget = false
    if not bar then return end
    guarded(function() bar:close() end)
    bar._external_rect = nil
    bar._external_face = nil
    local IME = package.loaded[ENGINE_MODULE]
    if IME then
        IME.imebar_inline_code = false
        IME.imebar_external_vmode = false
    end
end

-- 外部候选出口（vterm 全屏框）：候选串画在 vterm 自己预留的条带位，
-- 不新建 widget、不盖功能键。sink 只需 setText(s, hint)；setText("") 清显示。
-- 注册即打开引擎增强模式（imebar_inline_code），注销交还原生路径。
local function setExternalSink(sink)
    -- 注销(nil)永远生效：即使插件中途被禁用，过期门控也不能留在开位。
    if sink and (not installed or not enabled()) then return false end
    external_sink = (type(sink) == "table" and type(sink.setText) == "function") and sink or nil
    local IME = package.loaded[ENGINE_MODULE]
    if IME then
        IME.imebar_inline_code = external_sink ~= nil
        -- 外部终端里 v 缓冲仍写输入框（提交走 vterm 差分规则），只有拼音候选
        -- 走 sink；避免「输入框干净+一次性写整串」被差分误判为组词不发送。
        IME.imebar_external_vmode = external_sink ~= nil
    end
    return true
end

-- UI 语言：KOReader 界面语言为中文 → 中文菜单/文案，否则英文菜单。
-- 语言来源：设置项 language；未设置（跟随系统）时用 gettext 当前语言
-- （pcall 包裹：gettext 在 stub 环境可能是纯函数，取不到 current_lang）。
local function isZhUi()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if not lang or lang == "C" then
        local ok, cur = pcall(function() return _.current_lang end)
        lang = ok and cur or nil
    end
    return tostring(lang or ""):find("^zh") ~= nil
end

-- 双语文案：按界面语言取中文或英文（插件不依赖 .po 翻译）。
local function L(zh, en)
    if isZhUi() then return zh end
    return en
end

-- 条带是拼音候选 UI：只在拼音键盘布局（zh_CN，自带引擎服务的那块）显示。
local PINYIN_LAYOUT = "zh_CN"
local function pinyinLayout(layout)
    return (layout or (G_reader_settings
        and G_reader_settings:readSetting("keyboard_layout"))) == PINYIN_LAYOUT
end

-- 条带跟随键盘显隐：show 时同步引擎「输入框显拼音码」门控。
-- 门控赋值放在 guarded 之外：即便条带 UI 抛错（字体/几何异常），
-- 引擎也绝不会卡在过期的 inline_code 上往输入框误写拼音码。
-- 唯一状态来源 = bar._shown（vterm 全屏框 hasRoom=false → 恒 false）。
local function barFollowKeyboard(kb, show)
    -- widget 本体模式（vterm）：键盘 onClose（收键盘/toggleKeyboard 重建）必须
    -- 关掉锚定 widget，否则它残留在屏幕中间/下方。unmountExternal 会复位门控并
    -- 清 _shown；展开后新 view 的 paintTo 会重新 mount 到新条带位。
    -- show=true 不在这里 mount —— 由 vterm 拿到新几何后调 mountExternal。
    if external_widget then
        if not show then unmountExternal() end
        return
    end
    local IME = package.loaded[ENGINE_MODULE]
    if show then
        guarded(function() bar:show(kb) end)
    else
        guarded(function() bar:close() end)
    end
    -- 外部终端（vterm）注册了候选出口时，inline_code 归 sink 管，别被
    -- setVisibility 的全屏框 hasRoom=false 结果覆盖回 false。
    if IME and not external_sink then
        IME.imebar_inline_code = (show and bar._shown == true) or false
    end
end

-- 从完整串拆出末尾 "[候选…]" 段，返回 (候选段, 舞台字)。
-- 舞台字（各帧 .char 拼接）在前，候选括号段由引擎拼在最后。
local function splitCandidates(full)
    if type(full) ~= "string" then return nil, full end
    local s = full:find("%[", 1)
    if not s then return nil, full end
    local last = s
    local nxt = full:find("%[", s + 1)
    while nxt do last = nxt; nxt = full:find("%[", last + 1) end
    return full:sub(last), full:sub(1, last - 1)
end

-- 加载期占位：让自带引擎成为所有 layout require(".../generic_ime") 的返回值。
-- 必须在任何 VirtualKeyboard / layout 创建之前调用。
-- 用 dofile 绝对相对路径而非 require("ime_engine")：后者会被 package.path 上
-- 其它插件的同名文件（imeplus.koplugin/ime_engine.lua）抢先命中。
-- 若 loaded 里已是有效引擎（如 selftest 预装、cwd 不同的测试环境），直接复用。
local function installEngine()
    local engine = package.loaded[ENGINE_MODULE]
    if not (type(engine) == "table"
        and type(engine.getHintChars) == "function"
        and type(engine.clear_stack) == "function"
        and engine.fuzzy_presets) then
        local ok
        ok, engine = pcall(dofile, "plugins/imebar.koplugin/ime_engine.lua")
        if not ok or type(engine) ~= "table"
            or type(engine.getHintChars) ~= "function"
            or type(engine.clear_stack) ~= "function" then
            logger.warn("imebar: self engine load failed, native IME stays (", tostring(engine), ")")
            return false
        end
    end
    -- 互斥警告：imeplus 若已加载（先占位 preload/loaded），提示但 imebar 仍优先。
    if package.preload[ENGINE_MODULE] or (package.loaded[ENGINE_MODULE]
        and package.loaded[ENGINE_MODULE] ~= engine) then
        logger.warn("imebar: another IME plugin (imeplus?) detected; imebar takes priority. "
            .. "Disable imeplus to avoid confusion.")
    end
    package.loaded[ENGINE_MODULE] = engine
    return true
end

-- 延迟挂钩：VirtualKeyboard:init 里 layout 已 require 完，此时
-- package.loaded[ENGINE_MODULE] 就是自带引擎类。
local function wrapIME()
    if ime_wrapped then return end
    local IME = package.loaded[ENGINE_MODULE]
    if type(IME) ~= "table"
        or type(IME.getHintChars) ~= "function"
        or type(IME.clear_stack) ~= "function" then
        return
    end

    local orig_getHintChars = IME.getHintChars
    IME.getHintChars = function(self, inputbox)
        local full = orig_getHintChars(self, inputbox)
        if not active() then return full end
        -- orig 已按完整串设好 hint_char_count/on_stage_char_count。
        -- 条带显完整串（含舞台字）；输入框只写舞台字：hint_char_count 清零
        -- （下次删除不再回删候选括号），on_stage_char_count 保留（舞台字可删）。
        local candi, stage = splitCandidates(full)
        local sink = external_sink
        guarded(function()
            if sink then
                sink.setText(full) -- 外部终端：完整串画在它自己的条带位
            elseif full ~= "" then
                -- 第三参 = 当前页布局（同一时刻取数，状态一致），条带据此算
                -- 触摸命中矩形；视觉不变，闭包里不写 ...（看不到外层 vararg）
                bar:setCandidates(full, nil, self:getBarLayout(inputbox))
            else
                bar:clearCandidates()
            end
        end)
        if candi then
            self.hint_char_count = 0
            return stage
        end
        return full
    end

    local orig_clear_stack = IME.clear_stack
    IME.clear_stack = function(self, ...)
        if active() then
            local sink = external_sink
            guarded(function()
                if sink then sink.setText("") else bar:clearCandidates() end
            end)
        end
        return orig_clear_stack(self, ...)
    end

    -- v 模式缓冲推条带（引擎钩子）：s = 去 v 的缓冲串；hint=true 表示
    -- 空缓冲，条带显示灰字操作提示（检测到输入后引擎改推正常文本，提示消除）。
    -- 输入框在 v 模式保持干净，提交时引擎一次性写入整串。
    IME.imebar_bar_push = function(s, hint)
        guarded(function()
            local sink = external_sink
            if hint then
                local hint_text = L("[En] 双击空格/回车结束输入",
                    "[En] Double space or Enter to finish")
                if sink then sink.setText(hint_text, true); return end
                if bar._shown then bar:setCandidates(hint_text, true) end
            else
                if sink then sink.setText(s or "", false); return end
                if bar._shown then bar:setCandidates(s or "") end
            end
        end)
    end

    ime_wrapped = true
    logger.dbg("imebar: self IME engine wrapped")
end

local function install()
    if not installEngine() then return false end

    local ok_vk, VirtualKeyboard = pcall(require, "ui/widget/virtualkeyboard")
    local ok_bar, ImeBar = pcall(require, "imebar")
    if not (ok_vk and ok_bar) then
        logger.warn("imebar: require failed, native input stays (",
            tostring(VirtualKeyboard), ", ", tostring(ImeBar), ")")
        return false
    end
    if type(VirtualKeyboard.setVisibility) ~= "function"
        or type(VirtualKeyboard.onClose) ~= "function"
        or type(VirtualKeyboard.init) ~= "function"
        or type(VirtualKeyboard.setKeyboardLayout) ~= "function"
        or type(ImeBar) ~= "table" then
        logger.warn("imebar: core API mismatch, native input stays")
        return false
    end

    bar = ImeBar:new{}

    -- 触摸选字回调（条带 onGesture 命中后调，均经 bar 侧 pcall 包裹）：
    -- 候选 n（1=舞台字，10=0 键位）→ 引擎活实例的 tapSelectCandidate（数字
    -- 选字的提交行，绕开自定义码前缀吞数字的分支）；翻页 → 重放键盘 →/←
    -- 的既有路径（wrappedAddChars 的翻页分支，条带只在有编号候选时才有矩形）。
    bar._on_candidate = function(n, kb)
        local engine = package.loaded[ENGINE_MODULE]
        local ime = type(engine) == "table" and engine._live
        if ime and kb.inputbox then
            ime:tapSelectCandidate(kb.inputbox, n)
            -- vterm 等全屏终端：触摸直接调引擎绕过了键盘事件边界，候选字只进
            -- 草稿不发 PTY（键盘选字则经 addChars.func → _vtKeyEventEnd 自动收口）。
            -- 有补提交方法就调它，普通输入框没有此方法则无感（原生 InputDialog
            -- 的草稿本来就地显示、不需发 PTY）。
            local commit = kb.inputbox._vtCommitDraft
            if type(commit) == "function" then commit(kb.inputbox) end
        end
    end
    bar._on_page = function(dir, kb)
        if kb.inputbox then
            kb.inputbox:addChars(dir == "next" and "→" or "←")
        end
    end

    -- VirtualKeyboard:init 里 layout（含 IME 类）刚 require 完，正是挂钩时机。
    local orig_init = VirtualKeyboard.init
    VirtualKeyboard.init = function(self, ...)
        local ret = orig_init(self, ...)
        if installed then guarded(wrapIME) end
        return ret
    end

    -- setVisibility 是所有显隐路径的收口；非拼音布局（英文等）不显示条带。
    local orig_setVisibility = VirtualKeyboard.setVisibility
    VirtualKeyboard.setVisibility = function(self, toggle)
        local ret = orig_setVisibility(self, toggle)
        if not installed or self.lock_visibility then return ret end
        barFollowKeyboard(self, toggle and enabled() and pinyinLayout())
        return ret
    end

    -- onClose 是隐藏路径的另一收口（DPad/Back 直接走它）。close 幂等。
    local orig_onClose = VirtualKeyboard.onClose
    VirtualKeyboard.onClose = function(self)
        local ret = orig_onClose(self)
        if installed then barFollowKeyboard(self, false) end
        return ret
    end

    -- setKeyboardLayout 是布局切换的收口（🌐 循环键/布局对话框都汇到这里）：
    -- init() 按新布局重建键盘但不走 setVisibility，条带需在此显式跟随。
    local orig_setLayout = VirtualKeyboard.setKeyboardLayout
    VirtualKeyboard.setKeyboardLayout = function(self, layout)
        local ret = orig_setLayout(self, layout)
        if installed then
            barFollowKeyboard(self, self.visible and enabled() and pinyinLayout(layout))
        end
        return ret
    end

    return true
end

do
    local ok, res = pcall(install)
    installed = ok and res == true
end
-- vterm 等全屏终端通过 package.loaded 发现辣条并注册外部候选出口（它按路径
-- dofile 插件 main，拿不到返回值）。用独立键名，别覆盖 require("imebar") 的 widget 模块。
package.loaded["imebar_api"] = {
    setExternalSink = setExternalSink,
    mountExternal = mountExternal,   -- vterm widget 本体模式：把辣条 widget 锚到 vterm 条带位
    unmountExternal = unmountExternal,
}
if not installed then
    logger.warn("imebar: install failed, native input stays")
else
    pcall(function() require("ui/plugin/insert_menu").add("imebar") end)
end

local ImeBarPlugin = WidgetContainer:extend{
    name = "imebar",
}

local CUSTOM_WORDS_FILE = "plugins/imebar.koplugin/custom_words.lua"

local function loadCustomWordsAsText()
    local ok, entries = pcall(dofile, CUSTOM_WORDS_FILE)
    if not ok or type(entries) ~= "table" then return "" end
    local lines = {}
    for _, e in ipairs(entries) do
        if type(e) == "string" then
            lines[#lines+1] = e
        elseif type(e) == "table" and type(e[1]) == "string" then
            lines[#lines+1] = e[2] and (e[1] .. " " .. e[2]) or e[1]
        end
    end
    return table.concat(lines, "\n")
end

local function saveCustomWordsFromText(text)
    local lines = { "return {" }
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local word, pinyin = line:match("^(%S+)%s+(%S+)$")
            if not word then word = line:match("^(%S+)$") end
            if word then
                if pinyin then lines[#lines+1] = string.format('    { %q, %q },', word, pinyin)
                else lines[#lines+1] = string.format('    %q,', word) end
            end
        end
    end
    lines[#lines+1] = "}"
    local f = io.open(CUSTOM_WORDS_FILE, "w")
    if not f then return false end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    return true
end

-- 自定义词组表编辑器，对齐 imeplus：查找/查找下一个（从光标处循环匹配）、
-- 完整格式说明、保存结果 InfoMessage 提示。
function ImeBarPlugin:editCustomWords()
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local Screen = require("device").screen
    -- search state: last query + index, so tapping 查找 again cycles matches
    local search_query, search_from = nil, 0
    local dialog
    -- move the editor cursor to the next match of search_query (cycling); the
    -- TextBoxWidget scrolls to the caret automatically. Returns match count used.
    local function jumpToMatch(from)
        local text = dialog:getInputText()
        local pos = nil
        local start = from or 1
        while true do
            local s, e = text:find(search_query, start, true)
            if not s then break end
            pos = s
            break
        end
        if not pos then return false end
        -- the cursor is a charlist index: count UTF-8 chars before the match
        local charpos = 1
        local i = 1
        while i < pos do
            local b = text:byte(i)
            local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
            charpos = charpos + 1
            i = i + len
        end
        local input_widget = dialog._input_widget
        if input_widget and input_widget.text_widget then
            input_widget.charpos = charpos
            input_widget.text_widget:moveCursorToCharPos(charpos)
            input_widget:resyncPos()
        end
        return true
    end
    dialog = InputDialog:new{
        title = L("自定义词组表", "Custom phrases"),
        description = L(
            "格式: 自定义词组 [输入码] , 例如:\n" ..
            "拼音辣条\n" ..
            "https://github.com/eznas ez\n" ..
            "#英文/混合词必须带输入码",
            "Format: phrase [code], e.g.\n" ..
            "拼音辣条\n" ..
            "https://github.com/eznas ez\n" ..
            "# ASCII/mixed phrases must have a code"),
        input = loadCustomWordsAsText(),
        input_type = "text",
        multiline = true,
        allow_newline = true, -- Enter inserts "\n" instead of confirming the dialog
        text_height = math.floor(Screen:getHeight() * 0.4),
        buttons = {
            {
                {
                    text = L("查找", "Find"),
                    callback = function()
                        local SearchDialog = require("ui/widget/inputdialog")
                        local search_dialog
                        search_dialog = SearchDialog:new{
                            title = L("查找词组", "Find phrase"),
                            input = search_query or "",
                            input_type = "text",
                            buttons = {
                                {
                                    {
                                        text = L("取消", "Cancel"),
                                        callback = function()
                                            UIManager:close(search_dialog)
                                        end,
                                    },
                                    {
                                        text = L("查找下一个", "Find next"),
                                        callback = function()
                                            search_query = search_dialog:getInputText()
                                            if not search_query or search_query == "" then
                                                UIManager:close(search_dialog)
                                                return
                                            end
                                            -- search from just after the caret, wrap around
                                            local input_widget = dialog._input_widget
                                            local text = dialog:getInputText()
                                            local caret_byte = 1
                                            if input_widget and input_widget.charpos then
                                                -- convert charpos back to a byte offset
                                                local n = input_widget.charpos - 1
                                                local i = 1
                                                while n > 0 and i <= #text do
                                                    local b = text:byte(i)
                                                    local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
                                                    i = i + len
                                                    n = n - 1
                                                end
                                                caret_byte = i
                                            end
                                            UIManager:close(search_dialog)
                                            local from = (search_from or 0) >= 1 and caret_byte or 1
                                            local ok = jumpToMatch(from)
                                            if not ok then
                                                ok = jumpToMatch(1) -- wrap around
                                            end
                                            if not ok then
                                                UIManager:show(InfoMessage:new{
                                                    text = L("未找到：", "Not found: ") .. search_query,
                                                    timeout = 2,
                                                })
                                            else
                                                search_from = 1
                                            end
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(search_dialog)
                        search_dialog:onShowKeyboard()
                    end,
                    keep_menu_open = true,
                },
                {
                    text = L("取消", "Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = L("保存", "Save"),
                    callback = function()
                        local text = dialog:getInputText()
                        if saveCustomWordsFromText(text) then
                            UIManager:close(dialog)
                            -- 热重载活 IME 实例的词表：引擎是模块级单例，init 只跑一次，
                            -- 不重载就得重启 KOReader 清 require 缓存才生效。
                            local IME = package.loaded[ENGINE_MODULE]
                            if IME and type(IME.reloadCustomWords) == "function" then
                                guarded(IME.reloadCustomWords)
                            end
                            UIManager:show(InfoMessage:new{
                                text = L("已保存自定义词组表，立即生效。", "Saved. Takes effect immediately."),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = L("保存失败：无法写入 custom_words.lua。", "Save failed: cannot write custom_words.lua."),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ImeBarPlugin:init()
    -- v2026.07：插件实例须自注册进菜单 widget 列表，否则 addToMainMenu 不会被调用。
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function ImeBarPlugin:addToMainMenu(menu_items)
    if not installed then return end
    local ok_engine, engine = pcall(require, ENGINE_MODULE)
    local presets = ok_engine and engine.fuzzy_presets or {}
    local rule_items = {}
    for _, p in ipairs(presets) do
        local id, label, default = p.id, p.label, p.default == true
        rule_items[#rule_items+1] = {
            text = label,
            checked_func = function()
                local saved = G_reader_settings:readSetting("imebar_fuzzy_rules")
                if saved then return saved[id] == true end
                return default
            end,
            callback = function()
                local saved = G_reader_settings:readSetting("imebar_fuzzy_rules")
                if not saved then
                    saved = {}
                    for _, q in ipairs(presets) do saved[q.id] = q.default == true end
                end
                saved[id] = not (saved[id] == true)
                G_reader_settings:saveSetting("imebar_fuzzy_rules", saved)
            end,
            keep_menu_open = true,
        }
    end

    menu_items.imebar = {
        text = L("拼音辣条", "Pinyin Input Bar"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                -- 勾选框区点击即开关模糊拼音；点行进二级菜单编辑模糊规则
                text = L("模糊拼音", "Fuzzy pinyin"),
                checked_func = function() return G_reader_settings:readSetting("imebar_fuzzy", true) end,
                checkmark_callback = function()
                    G_reader_settings:saveSetting("imebar_fuzzy",
                        not G_reader_settings:readSetting("imebar_fuzzy", true))
                end,
                sub_item_table = rule_items,
            },
            { text = L("自定义词组表", "Custom phrases"), callback = function() self:editCustomWords() end, keep_menu_open = true },
            {
                text = L("关于", "About"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    local InfoMessage = require("ui/widget/infomessage")
                    local meta = dofile("plugins/imebar.koplugin/_meta.lua")
                    -- 分段用空白行隔离，段落短小便于扫读
                    UIManager:show(InfoMessage:new{
                        text = L("拼音辣条 (imebar)", "Pinyin Input Bar (imebar)")
                            .. "  v" .. meta.version .. "\n"
                            .. L("自带拼音引擎，候选显示在软键盘上方。", "Self-contained pinyin IME with a candidate bar.")
                            .. "\nhttps://github.com/eznas/imebar.koplugin"
                    })
                end,
                keep_menu_open = true,
            },
        },
    }
end

-- 最小自检：stub 环境下跑一遍包裹逻辑，跑不过即 assert 失败。
function ImeBarPlugin:demo()
    assert(installed, "imebar: hooks not installed")
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local IME = package.loaded[ENGINE_MODULE]
    assert(type(IME) == "table", "self engine not installed")
    assert(type(VirtualKeyboard.init) == "function", "init wrap missing")

    VirtualKeyboard.init(VirtualKeyboard) -- 触发 wrapIME
    assert(ime_wrapped, "IME not wrapped")
    assert(type(IME.getHintChars) == "function", "getHintChars wrap missing")

    local saved = G_reader_settings:readSetting(ENABLED_KEY)
    local saved_layout = G_reader_settings:readSetting("keyboard_layout")
    G_reader_settings:saveSetting(ENABLED_KEY, false)
    G_reader_settings:saveSetting("keyboard_layout", "zh_CN")

    local kb = setmetatable({
        lock_visibility = false,
        disable_double_tap = true,
        dimen = { x = 0, y = 0, w = 100, h = 100 },
        inputbox = { parent = { fullscreen = false } },
    }, { __index = VirtualKeyboard })

    VirtualKeyboard.setVisibility(kb, true)
    assert(bar._shown ~= true, "bar shown while disabled")

    G_reader_settings:saveSetting(ENABLED_KEY, true)
    VirtualKeyboard.setVisibility(kb, true)
    assert(bar._shown == true, "bar not shown on setVisibility(true)")
    -- 引擎门控字段随条带显隐切换（拼音码显示模式只在条带显示时开启）
    assert(IME.imebar_inline_code == true, "inline-code gate not opened with bar")

    VirtualKeyboard.setVisibility(kb, false)
    assert(bar._shown == false, "bar not closed on setVisibility(false)")
    assert(IME.imebar_inline_code == false, "inline-code gate not closed with bar")
    VirtualKeyboard.setVisibility(kb, false) -- 幂等
    assert(bar._shown == false, "close is not idempotent")

    -- 布局切换跟随：非拼音布局隐藏条带，切回拼音布局恢复（键盘在屏上时）
    kb.visible = true
    VirtualKeyboard.setKeyboardLayout(kb, "en")
    assert(bar._shown == false, "bar not hidden on non-pinyin layout")
    assert(IME.imebar_inline_code == false, "inline-code gate open on non-pinyin layout")
    VirtualKeyboard.setKeyboardLayout(kb, "zh_CN")
    assert(bar._shown == true, "bar not restored on pinyin layout")
    assert(IME.imebar_inline_code == true, "inline-code gate not restored on pinyin layout")
    VirtualKeyboard.setVisibility(kb, false)
    assert(bar._shown == false, "bar not closed at end")

    -- 菜单语言：中文界面出中文菜单，非中文出英文菜单
    local saved_lang = G_reader_settings:readSetting("language")
    local items = {}
    G_reader_settings:saveSetting("language", "zh_CN")
    self:addToMainMenu(items)
    assert(items.imebar.text == "拼音辣条", "zh UI must show Chinese menu: " .. tostring(items.imebar.text))
    G_reader_settings:saveSetting("language", "en")
    items = {}
    self:addToMainMenu(items)
    assert(items.imebar.text == "Pinyin Input Bar", "non-zh UI must show English menu: " .. tostring(items.imebar.text))
    if saved_lang == nil then G_reader_settings:delSetting("language")
    else G_reader_settings:saveSetting("language", saved_lang) end

    if saved == nil then G_reader_settings:delSetting(ENABLED_KEY)
    else G_reader_settings:saveSetting(ENABLED_KEY, saved) end
    if saved_layout == nil then G_reader_settings:delSetting("keyboard_layout")
    else G_reader_settings:saveSetting("keyboard_layout", saved_layout) end
    return true
end

return ImeBarPlugin
