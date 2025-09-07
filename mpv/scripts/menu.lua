local mp = require 'mp'
local options = require 'mp.options'
local utils = require 'mp.utils'

-- 默认配置值
local opts = {
    max_visible_items = 12,

    base_w = 1280,
    base_h = 720,

    item_width = 260,
    item_height = 48,

    selected_item_bg_color = "444444",
    selected_item_alpha = "30",
    selected_item_text_color = "FFFFFF",

    menu_bg_color = "222222",
    menu_text_color = "FFFFFF",
    menu_bg_alpha = "60",

    scrollbar_width = 3,
    scrollbar_color = "222222",
    scrollbar_alpha = "40",
    scrollbar_hide_delay = 0.6,

    -- 默认键
    mbtn_left = "MBTN_LEFT",
    mbtn_right = "MBTN_RIGHT",
    wheel_up = "WHEEL_UP",
    wheel_down = "WHEEL_DOWN",
    esc = "ESC",

    -- 菜单数据文件(json)
    menu_data_file = "~~/script-opts/menu_data.json",
}

-- 读取配置文件
options.read_options(opts, "menu")

-- 读取菜单数据文件
local function load_menu_data()
    local path = mp.command_native({"expand-path", opts.menu_data_file})
    local file = io.open(path, "r")
    
    if not file then
        mp.msg.warn("无法打开菜单配置文件: " .. path)
        return nil
    end
    
    local content = file:read("*all")
    file:close()
    
    local json = utils.parse_json(content)
    if not json then
        mp.msg.warn("解析菜单配置文件失败: " .. path)
        return nil
    end
    
    return json
end

-- 加载菜单数据
local menu_data = load_menu_data()

-- 如果加载数据失败，则使用默认数据
if not menu_data then
    
    local menu_data = {
        {
            title = "声音控制",
            items = {
                {title = "音量+", command = "add volume 10"},
                {title = "音量-", command = "add volume -10"},
                {title = "静音", command = "cycle mute"},
            }
        },
        {
            title = "播放控制",
            items = {
                {title = "暂停/播放", command = "cycle pause"},
                {title = "下一帧", command = "frame-step"},
                {title = "上一帧", command = "frame-back-step"},
            }
        },
        {
            title = "播放速度",
            items = {
                {title = "加速", command = "multiply speed 1.1"},
                {title = "减速", command = "multiply speed 0.9"},
                {title = "重置", command = "set speed 1.0"},
            }
        },
        {title = "播放列表", command = "show-text ${playlist}"},
        {title = "打开文件", command = "show-text 假装已经打开了"},
        {title = "退出", command = "quit"},
    }

end

-- RGB到BGR转换函数
local function rgb_to_bgr(rgb_hex)
    if not rgb_hex or #rgb_hex ~= 6 then return rgb_hex end
    -- 提取RGB分量并重新排列为BGR
    local r = rgb_hex:sub(1, 2)
    local g = rgb_hex:sub(3, 4)
    local b = rgb_hex:sub(5, 6)
    return b .. g .. r
end

-- 转换所有颜色值为BGR格式，这样在使用时就不需要再转换了
opts.menu_bg_color = rgb_to_bgr(opts.menu_bg_color)
opts.menu_text_color = rgb_to_bgr(opts.menu_text_color)
opts.selected_item_bg_color = rgb_to_bgr(opts.selected_item_bg_color)
opts.selected_item_text_color = rgb_to_bgr(opts.selected_item_text_color)
opts.scrollbar_color = rgb_to_bgr(opts.scrollbar_color)

-- 菜单状态变量，存储菜单的当前状态
local state = {
    visible = false,        -- 菜单是否可见
    active_menu = nil,      -- 当前激活的子菜单（主菜单的索引）
    hovered_item = nil,     -- 当前鼠标悬停的菜单项
    mouse_x = 0,            -- 鼠标X坐标（ASS坐标）
    mouse_y = 0,            -- 鼠标Y坐标（ASS坐标）
    menu_x = 0,             -- 主菜单X坐标（ASS坐标）
    menu_y = 0,             -- 主菜单Y坐标（ASS坐标）
    sub_menu_x = 0,         -- 子菜单X坐标（ASS坐标）
    sub_menu_y = 0,         -- 子菜单Y坐标（ASS坐标）
    item_width = opts.item_width,       -- 菜单项宽度
    item_height = opts.item_height,       -- 菜单项高度
    scroll_offset = 0,      -- 主菜单滚动偏移量
    scroll_bar_visible = false, -- 是否显示滚动条
    scroll_bar_fade_timer = nil, -- 滚动条淡出定时器
    scroll_bar_should_hide = false, -- 是否应该隐藏滚动条
}

-- 菜单渲染相关的全局变量
local overlay = nil         -- OSD覆盖层，用于渲染菜单
local update_timer = nil    -- 定时器，用于更新菜单状态

-- 获取窗口和ASS画布尺寸信息
-- 这个函数尝试获取mpv播放器的窗口尺寸和ASS画布尺寸，以及它们之间的转换关系
local function get_dimensions()
    local dim = mp.get_property_native("osd-dimensions")  -- 获取OSD尺寸信息
    if not dim then
        -- 如果获取失败，返回默认值
        return {
            ass_w = opts.base_w,       -- 默认ASS画布宽度
            ass_h = opts.base_h,        -- 默认ASS画布高度
            ml = 0,             -- 默认左边距
            mt = 0,             -- 默认上边距
            scale_x = 1.0,      -- 默认X轴缩放比例
            scale_y = 1.0,      -- 默认Y轴缩放比例
        }
    end
    
    -- 从OSD尺寸信息中提取ASS画布尺寸和边距
    local ass_w = dim.w        -- ASS画布宽度
    local ass_h = dim.h        -- ASS画布高度
    local ml = dim.ml or 0     -- 左边距
    local mt = dim.mt or 0     -- 上边距
    local mr = dim.mr or 0     -- 右边距
    local mb = dim.mb or 0     -- 下边距
    
    -- 计算缩放比例：基准分辨率与ASS画布尺寸的比值
    -- 这个比例用于在基准坐标和ASS坐标之间进行转换
    local scale_x = opts.base_w / ass_w
    local scale_y = opts.base_h / ass_h
    
    -- 返回所有尺寸和比例信息
    return {
        ass_w = ass_w,         -- ASS画布宽度
        ass_h = ass_h,         -- ASS画布高度
        ml = ml,               -- 左边距
        mt = mt,               -- 上边距
        scale_x = scale_x,     -- X轴缩放比例
        scale_y = scale_y,     -- Y轴缩放比例
    }
end

-- 计算菜单位置
-- 这个函数计算主菜单和子菜单在ASS画布上的位置
local function calculate_menu_position(active_menu)
    local dims = get_dimensions()  -- 获取尺寸信息
    
    -- 计算主菜单尺寸（使用基准坐标系统）
    local menu_width = state.item_width
    -- 使用可见项数而不是总项数计算高度
    local visible_items = math.min(#menu_data, opts.max_visible_items)
    local menu_height = visible_items * state.item_height
    -- 如果菜单高度大于窗口高度，计算窗口内最多可以放几个item
    if menu_height > dims.ass_h then
        visible_items = math.floor(dims.ass_h / state.item_height)
        menu_height = visible_items * state.item_height
    end
     
    -- 计算主菜单位置（在基准坐标系统中居中）
    local base_menu_x = (opts.base_w - menu_width * dims.scale_x) / 2
    local base_menu_y = (opts.base_h - menu_height * dims.scale_y) / 2
    
    -- 转换为ASS坐标并应用缩放
    local menu_x = (base_menu_x / dims.scale_x + dims.ml) * dims.scale_x - opts.item_width / 2 * dims.scale_x
    local menu_y = (base_menu_y / dims.scale_y + dims.mt) * dims.scale_y - opts.item_height / 2 * dims.scale_y
    -- local menu_x = (base_menu_x / dims.scale_x + dims.ml) * dims.scale_x
    -- local menu_y = (base_menu_y / dims.scale_y + dims.mt) * dims.scale_y
    
    -- 计算子菜单位置
    local sub_menu_x, sub_menu_y = nil, nil
    if active_menu then
        local sub_items = menu_data[active_menu].items
        local sub_menu_height = #sub_items * state.item_height
        
        sub_menu_x = menu_x + menu_width * dims.scale_x
        -- 子菜单位置与主菜单选中项对齐
        local selected_main_item_index = nil
        if state.hovered_item and state.hovered_item.main_index == active_menu then
            selected_main_item_index = state.hovered_item.main_index
        end
        
        if selected_main_item_index then
            -- 计算选中项在可视区域的位置
            local visible_index = selected_main_item_index - state.scroll_offset
            sub_menu_y = menu_y + (visible_index - 1) * state.item_height * dims.scale_y
        else
            sub_menu_y = menu_y + (active_menu - 1 - state.scroll_offset) * state.item_height * dims.scale_y
        end
    end
    
    return menu_x, menu_y, sub_menu_x, sub_menu_y
end

-- 获取鼠标在ASS坐标中的位置
-- 这个函数将鼠标的屏幕坐标转换为ASS画布上的坐标
local function get_mouse_ass_position()
    local mouse_x, mouse_y = mp.get_mouse_pos()  -- 获取鼠标屏幕坐标
    local dims = get_dimensions()                -- 获取尺寸信息
    
    -- 获取窗口位置（相对于屏幕）
    local window_x = mp.get_property_number("window-x", 0)
    local window_y = mp.get_property_number("window-y", 0)
    
    -- 计算鼠标在窗口内的相对位置
    local relative_x = mouse_x - window_x
    local relative_y = mouse_y - window_y
    
    -- 直接将窗口坐标转换为ASS坐标，不需要中间步骤
    local ass_x = (relative_x * opts.base_w / (dims.ass_w * dims.scale_x) + dims.ml) * dims.scale_x
    local ass_y = (relative_y * opts.base_h / (dims.ass_h * dims.scale_y) + dims.mt) * dims.scale_y
    
    return ass_x, ass_y
end

-- 显示菜单
-- 这个函数在右键点击时被调用，初始化菜单状态并显示菜单
function show_menu()
    if state.visible then return end  -- 如果菜单已经显示，直接返回
    state.visible = true          -- 设置菜单为可见状态
    state.active_menu = nil       -- 初始化没有激活的子菜单
    state.hovered_item = nil      -- 初始化没有悬停的菜单项
    state.scroll_offset = 0       -- 重置滚动偏移
    state.scroll_bar_visible = #menu_data > opts.max_visible_items  -- 根据菜单项数量决定是否显示滚动条
    state.scroll_bar_should_hide = true  -- 重置滚动条隐藏状态
    if state.scroll_bar_fade_timer then
        state.scroll_bar_fade_timer:kill()
        state.scroll_bar_fade_timer = nil
    end
    state.menu_x, state.menu_y = calculate_menu_position(nil)  -- 计算主菜单位置
    update_display()              -- 更新菜单显示
    start_tracking()              -- 开始跟踪鼠标移动

    -- 正确的方式：启用 menu 组
    mp.command("disable-section default")
    mp.command("enable-section menu")
    
end

-- 隐藏菜单
-- 这个函数在菜单需要被隐藏时调用（如执行菜单项命令或按ESC键）
function hide_menu()
    if not state.visible then return end  -- 如果菜单已经隐藏，直接返回
    state.visible = false         -- 设置菜单为不可见状态
    state.active_menu = nil       -- 清除激活的子菜单
    state.hovered_item = nil      -- 清除悬停的菜单项
    state.scroll_offset = 0       -- 重置滚动偏移
    state.scroll_bar_should_hide = false  -- 重置滚动条隐藏状态
    if state.scroll_bar_fade_timer then
        state.scroll_bar_fade_timer:kill()
        state.scroll_bar_fade_timer = nil
    end
    if overlay then
        overlay:remove()          -- 移除OSD覆盖层
        overlay = nil
    end
    if update_timer then
        update_timer:kill()       -- 停止定时器
        update_timer = nil
    end

    -- 正确的方式：禁用 menu 组，启用 default 组
    mp.command("disable-section menu")
    mp.command("enable-section default")

end

-- 开始跟踪鼠标移动
-- 这个函数启动一个定时器，定期更新鼠标位置和菜单状态
function start_tracking()
    if update_timer then update_timer:kill() end  -- 如果已存在定时器，先停止它
    update_timer = mp.add_periodic_timer(0.01, update_hover_state)  -- 每0.01秒更新一次悬停状态
end

-- 检查鼠标是否在菜单系统的缓冲区域（用于防止子菜单意外消失）
function is_mouse_in_menu_buffer_zone()
    if not state.active_menu then return false end
    
    local dims = get_dimensions()
    local item_width = state.item_width * dims.scale_x
    local item_height = state.item_height * dims.scale_y
    
    -- 定义一个缓冲区域，当鼠标在这个区域内时保持子菜单显示
    local buffer = 16 * math.max(dims.scale_x, dims.scale_y)  -- 20像素的缓冲区
    
    -- 检查是否在主菜单附近
    local visible_items = math.min(#menu_data, opts.max_visible_items)
    local menu_top = state.menu_y - buffer
    local menu_bottom = state.menu_y + (visible_items * item_height) + buffer
    local menu_left = state.menu_x - buffer
    local menu_right = state.menu_x + item_width + buffer
    
    -- 检查是否在子菜单附近
    local sub_menu_top, sub_menu_bottom, sub_menu_left, sub_menu_right
    if state.sub_menu_x and state.sub_menu_y then
        local sub_items = menu_data[state.active_menu].items
        sub_menu_top = state.sub_menu_y - buffer
        sub_menu_bottom = state.sub_menu_y + (#sub_items * item_height) + buffer
        sub_menu_left = state.sub_menu_x - buffer
        sub_menu_right = state.sub_menu_x + item_width + buffer
    end
    
    -- 检查鼠标是否在主菜单或子菜单的缓冲区域内
    local in_main_buffer = state.mouse_x >= menu_left and state.mouse_x <= menu_right and
                          state.mouse_y >= menu_top and state.mouse_y <= menu_bottom
                          
    local in_sub_buffer = sub_menu_top and sub_menu_bottom and sub_menu_left and sub_menu_right and
                         state.mouse_x >= sub_menu_left and state.mouse_x <= sub_menu_right and
                         state.mouse_y >= sub_menu_top and state.mouse_y <= sub_menu_bottom
    
    return in_main_buffer or in_sub_buffer
end

-- 更新鼠标悬停状态
-- 这个函数定期被调用，检查鼠标位置并更新菜单状态
function update_hover_state()
    if not state.visible then return end  -- 如果菜单不可见，不执行任何操作
    
    -- 获取鼠标在ASS坐标中的位置
    state.mouse_x, state.mouse_y = get_mouse_ass_position()
    
    -- 检查鼠标是否悬停在某个菜单项上
    local hovered_item = get_hovered_item()
    
    -- 处理子菜单显示逻辑
    local should_show_submenu = false
    local target_submenu = nil
    
    if hovered_item then
        -- 只有当悬停在有子菜单的主菜单项上时，才显示子菜单
        if hovered_item.has_sub and not hovered_item.sub_index then
            should_show_submenu = true
            target_submenu = hovered_item.main_index
        -- 如果悬停在子菜单项上，保持当前子菜单显示
        elseif hovered_item.sub_index then
            should_show_submenu = true
            target_submenu = hovered_item.main_index
        -- 如果悬停在没有子菜单的主菜单项上，隐藏子菜单
        else
            should_show_submenu = false
            target_submenu = nil
        end
    else
        -- 鼠标不在任何菜单项上，检查是否在菜单系统的扩展区域内
        should_show_submenu = is_mouse_in_menu_buffer_zone()
        if not should_show_submenu then
            target_submenu = nil
        end
    end
    
    -- 更新子菜单状态
    if should_show_submenu and target_submenu then
        if target_submenu ~= state.active_menu then
            state.active_menu = target_submenu
            state.menu_x, state.menu_y, state.sub_menu_x, state.sub_menu_y = calculate_menu_position(state.active_menu)
        end
    else
        -- 在任何其他情况下，隐藏子菜单
        if state.active_menu then
            state.active_menu = nil
            state.menu_x, state.menu_y = calculate_menu_position(nil)
            state.sub_menu_x, state.sub_menu_y = nil, nil
        end
    end
    
    -- 如果悬停的菜单项发生变化，更新菜单显示
    if hovered_item ~= state.hovered_item then
        state.hovered_item = hovered_item
        -- 处理主菜单滚动
        if hovered_item and not hovered_item.sub_index then
            ensure_item_visible(hovered_item.main_index)
        end
        update_display()
    end
end

-- 确保菜单项在可视区域内
function ensure_item_visible(item_index)
    if #menu_data <= opts.max_visible_items then return end
    
    -- 如果选中项在当前可视区域上方
    if item_index <= state.scroll_offset then
        state.scroll_offset = item_index - 1
        show_scroll_bar_temporarily()
    -- 如果选中项在当前可视区域下方
    elseif item_index > state.scroll_offset + opts.max_visible_items then
        state.scroll_offset = item_index - opts.max_visible_items
        show_scroll_bar_temporarily()
    end
    
    -- 确保滚动偏移在有效范围内
    local max_scroll = #menu_data - opts.max_visible_items
    state.scroll_offset = math.max(0, math.min(state.scroll_offset, max_scroll))
end

-- 处理鼠标滚轮事件，向上滚动
function scroll_up()
    if not state.visible or #menu_data <= opts.max_visible_items then return end
    
    state.scroll_offset = math.max(0, state.scroll_offset - 1)
    show_scroll_bar_temporarily()
    update_display()
end

-- 处理鼠标滚轮事件，向下滚动
function scroll_down()
    if not state.visible or #menu_data <= opts.max_visible_items then return end
    
    local max_scroll = #menu_data - opts.max_visible_items
    state.scroll_offset = math.min(max_scroll, state.scroll_offset + 1)
    show_scroll_bar_temporarily()
    update_display()
end

-- 显示滚动条并设置定时隐藏
-- 显示滚动条并设置定时隐藏
function show_scroll_bar_temporarily()
    if not state.visible or #menu_data <= opts.max_visible_items then return end
    
    -- 显示滚动条
    state.scroll_bar_should_hide = false
    
    -- 如果已有定时器，先取消
    if state.scroll_bar_fade_timer then
        state.scroll_bar_fade_timer:kill()
    end
    
    -- 创建新的定时器，配置的时间后隐藏滚动条
    state.scroll_bar_fade_timer = mp.add_timeout(opts.scrollbar_hide_delay, function()
        state.scroll_bar_should_hide = true
        update_display()
        state.scroll_bar_fade_timer = nil
    end)
end

-- 获取鼠标悬停的菜单项
-- 这个函数检查鼠标位置，确定它是否悬停在某个菜单项上
function get_hovered_item()
    -- 获取当前尺寸信息
    local dims = get_dimensions()
    
    -- 获取菜单位置和尺寸（已转换为ASS坐标）
    local menu_x = state.menu_x
    local menu_y = state.menu_y
    local item_width = state.item_width * dims.scale_x  -- 考虑缩放的菜单项宽度
    local item_height = state.item_height * dims.scale_y  -- 考虑缩放的菜单项高度
    local mouse_x = state.mouse_x   -- 鼠标X坐标（ASS坐标）
    local mouse_y = state.mouse_y   -- 鼠标Y坐标（ASS坐标）
    
    -- 计算可见菜单项数量
    local visible_items = math.min(#menu_data, opts.max_visible_items)

    -- 首先检查子菜单项（如果子菜单可见）
    if state.active_menu then
        local sub_items = menu_data[state.active_menu].items
        local sub_menu_x = state.sub_menu_x
        local sub_menu_y = state.sub_menu_y
        
        -- 遍历所有子菜单项，检查鼠标是否悬停在任何一个上
        for i, item in ipairs(sub_items) do
            local item_top = sub_menu_y + (i - 1) * item_height
            local item_bottom = item_top + item_height
            if mouse_x >= sub_menu_x and mouse_x < sub_menu_x + item_width and
               mouse_y >= item_top and mouse_y < item_bottom then
                return {main_index = state.active_menu, sub_index = i}
            end
        end

        -- 检查主菜单和子菜单之间的间隙区域
        -- 如果鼠标在主菜单和子菜单之间的区域内，保持子菜单显示
        local active_main_item_top = menu_y + (state.active_menu - 1 - state.scroll_offset) * item_height
        local active_main_item_bottom = active_main_item_top + item_height
        local gap_left = menu_x + item_width
        local gap_right = sub_menu_x
        local gap_top = math.min(active_main_item_top, sub_menu_y)
        local gap_bottom = math.max(active_main_item_bottom, sub_menu_y + #sub_items * item_height)
        
        if gap_right > gap_left and  -- 确保区域有效
           mouse_x >= gap_left and mouse_x < gap_right and
           mouse_y >= gap_top and mouse_y < gap_bottom then
            return {main_index = state.active_menu, has_sub = true}
        end
    end

    -- 然后检查主菜单项（只检查可见的项）
    for i = state.scroll_offset + 1, math.min(state.scroll_offset + opts.max_visible_items, #menu_data) do
        local visible_index = i - state.scroll_offset
        local item = menu_data[i]
        local item_top = menu_y + (visible_index - 1) * item_height
        local item_bottom = item_top + item_height
        if mouse_x >= menu_x and mouse_x < menu_x + item_width and
           mouse_y >= item_top and mouse_y < item_bottom then
            return {main_index = i, has_sub = item.items and #item.items > 0}
        end
    end
    
    return nil  -- 鼠标没有悬停在任何菜单项上
end

-- 更新菜单显示
-- 这个函数负责渲染菜单的视觉表现
-- 更新菜单显示
-- 这个函数负责渲染菜单的视觉表现
function update_display()
    if not state.visible then return end  -- 如果菜单不可见，不执行任何操作
    
    -- 如果OSD覆盖层不存在，创建一个
    if not overlay then
        overlay = mp.create_osd_overlay("ass-events")
    end

    local dims = get_dimensions()  -- 获取尺寸信息
    
    -- 获取菜单位置和尺寸
    local menu_x = state.menu_x
    local menu_y = state.menu_y
    local item_width = opts.item_width * dims.scale_x  -- 考虑缩放的菜单项宽度
    local item_height = opts.item_height * dims.scale_y  -- 考虑缩放的菜单项高度
    local active_menu = state.active_menu
    
    -- 计算可见菜单项数量
    local visible_items = math.min(#menu_data, opts.max_visible_items)
    local menu_height = visible_items * item_height

    local ass = ""  -- ASS文本，用于渲染菜单

    -- 绘制主菜单背景
    ass = ass .. string.format(
        "{\\an7}{\\pos(%d,%d)}{\\bord0}{\\shad0}{\\alpha&H%s&}{\\c&H%s&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}\n",
        menu_x, menu_y, opts.menu_bg_alpha, opts.menu_bg_color, item_width, item_width, menu_height, menu_height
    )
    
    -- 绘制滚动条（如果需要且应该显示）
    if state.scroll_bar_visible and not state.scroll_bar_should_hide then
        local scroll_bar_width = opts.scrollbar_width * dims.scale_x
        local scroll_bar_x = menu_x + item_width - scroll_bar_width
        local total_items = #menu_data
        local visible_ratio = visible_items / total_items
        local scroll_bar_height = menu_height * visible_ratio
        local scroll_ratio = state.scroll_offset / (total_items - visible_items)
        local scroll_bar_y = menu_y + scroll_ratio * (menu_height - scroll_bar_height)
        
        ass = ass .. string.format(
            "{\\an7}{\\pos(%d,%d)}{\\bord0}{\\shad0}{\\alpha&H%s&}{\\c&H%s&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}\n",
            scroll_bar_x, scroll_bar_y, opts.scrollbar_alpha, opts.scrollbar_color, scroll_bar_width, scroll_bar_width, scroll_bar_height, scroll_bar_height
        )
    end

    -- 绘制主菜单项（只绘制可见的项）
    -- 绘制主菜单项（只绘制可见的项）
    for i = state.scroll_offset + 1, math.min(state.scroll_offset + opts.max_visible_items, #menu_data) do
        local visible_index = i - state.scroll_offset
        local item = menu_data[i]
        local item_y = menu_y + (visible_index - 1) * item_height
        local is_hovered = state.hovered_item and state.hovered_item.main_index == i and not state.hovered_item.sub_index
        -- 修改：即使鼠标移到子菜单，主菜单的选中项也要保持选中状态
        local is_selected = state.active_menu and state.active_menu == i
        local bg_color = (is_hovered or is_selected) and opts.selected_item_bg_color or opts.menu_bg_color
        local text_color = (is_hovered or is_selected) and opts.selected_item_text_color or opts.menu_text_color
        local bg_alpha = (is_hovered or is_selected) and opts.selected_item_alpha or opts.menu_bg_alpha
        
        -- 如果菜单项被悬停或选中，绘制悬停背景
        if is_hovered or is_selected then
            ass = ass .. string.format(
                "{\\an7}{\\pos(%d,%d)}{\\bord0}{\\shad0}{\\alpha&H%s&}{\\c&H%s&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}\n",
                menu_x, item_y, opts.selected_item_alpha, opts.selected_item_bg_color, item_width, item_width, item_height, item_height
            )
        end
        
        -- 绘制菜单项文本
        local display_text = item.title
        local has_submenu = item.items and #item.items > 0
        
        -- 绘制文本（不包含 > 符号）
        ass = ass .. string.format(
            "{\\an7}{\\pos(%d,%d)}{\\fs%d}{\\c&H%s&}%s",
            menu_x + 32 * dims.scale_x, -- 左侧有16的padding
            item_y + (item_height - 32 * dims.scale_y) / 2,
            30 * dims.scale_x,
            text_color,
            display_text
        )
        
        -- 如果有子菜单，单独绘制 > 符号在右侧
        if has_submenu then
            -- 使用单独的ASS事件来绘制 > 符号
            ass = ass .. string.format(
                "\n{\\an9}{\\pos(%d,%d)}{\\fs%d}{\\c&H%s&}>",
                menu_x + item_width - 16 * dims.scale_x - (state.scroll_bar_visible and 12 * dims.scale_x or 0),  -- 右侧有16的padding
                item_y + (item_height - 24 * dims.scale_y) / 2,
                20 * dims.scale_x,
                text_color
            )
        end
        
        -- 添加换行符结束当前菜单项
        ass = ass .. "\n"
    end

    -- 如果有激活的子菜单，绘制子菜单
    if active_menu then
        local sub_menu_x = state.sub_menu_x
        local sub_menu_y = state.sub_menu_y
        local sub_items = menu_data[active_menu].items
        local sub_menu_height = #sub_items * item_height
        
        -- 绘制子菜单背景
        ass = ass .. string.format(
            "{\\an7}{\\pos(%d,%d)}{\\bord0}{\\shad0}{\\alpha&H%s&}{\\c&H%s&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}\n",
            sub_menu_x, sub_menu_y, opts.menu_bg_alpha, opts.menu_bg_color, item_width, item_width, sub_menu_height, sub_menu_height
        )
        
        -- 绘制子菜单项
        -- 绘制子菜单项
        for i, item in ipairs(sub_items) do
            local item_y = sub_menu_y + (i - 1) * item_height
            local is_hovered = state.hovered_item and state.hovered_item.main_index == active_menu and state.hovered_item.sub_index == i
            -- 修改：子菜单的选中项与主菜单保持一致
            local is_selected = state.active_menu and state.active_menu == active_menu
            local bg_color = is_hovered and opts.selected_item_bg_color or opts.menu_bg_color
            local text_color = is_hovered and opts.selected_item_text_color or opts.menu_text_color
            local bg_alpha = is_hovered and opts.selected_item_alpha or opts.menu_bg_alpha
            
            -- 如果子菜单项被悬停，绘制悬停背景
            if is_hovered then
                ass = ass .. string.format(
                    "{\\an7}{\\pos(%d,%d)}{\\bord0}{\\shad0}{\\alpha&H%s&}{\\c&H%s&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}\n",
                    sub_menu_x, item_y, opts.selected_item_alpha, opts.selected_item_bg_color, item_width, item_width, item_height, item_height
                )
            end
            
            -- 绘制子菜单项文本
            local display_text = item.title
            ass = ass .. string.format(
                "{\\an7}{\\pos(%d,%d)}{\\fs%d}{\\c&H%s&}%s\n",
                sub_menu_x + 16 * dims.scale_x, 
                -- item_y + math.floor(item_height / 2) - 9 * dims.scale_y, 
                item_y + (item_height - 30 * dims.scale_y) / 2,
                30 * dims.scale_x,  -- 字体大小也需要缩放
                text_color, 
                display_text
            )
        end
    end

    -- 将ASS文本设置到OSD覆盖层并更新显示
    overlay.data = ass
    overlay:update()
end

-- 执行菜单命令
-- 这个函数在点击菜单项时被调用，执行相应的命令
function execute_menu()
    if not state.visible or not state.hovered_item then
        hide_menu()  -- 如果菜单不可见或没有悬停的菜单项，隐藏菜单
        return
    end
    
    local main_index = state.hovered_item.main_index
    local sub_index = state.hovered_item.sub_index
    
    -- 如果点击的是子菜单项
    if sub_index then
        local sub_items = menu_data[main_index].items
        local item = sub_items[sub_index]
        if item and item.command then
            mp.command(item.command)  -- 执行子菜单项命令
            hide_menu()              -- 隐藏菜单
        end
    -- 如果点击的是主菜单项（且没有子菜单）
    else
        local item = menu_data[main_index]
        if not (item.items and #item.items > 0) and item.command then
            mp.command(item.command)  -- 执行主菜单项命令
            hide_menu()              -- 隐藏菜单
        end
    end
end

-- 键绑定，右键打开菜单，Esc关闭菜单，左键执行, 滚轮键滚动
-- mbtn_left = "MBTN_LEFT"
-- mbtn_right = "MBTN_RIGHT"
-- wheel_up = "WHEEL_UP"
-- wheel_down = "WHEEL_DOWN"
-- esc = "ESC"
mp.add_key_binding(opts.mbtn_left, "execute_menu", execute_menu, {input_section = "menu"})
mp.add_key_binding(opts.mbtn_right, "show_menu", show_menu)
mp.add_key_binding(opts.wheel_up, "scroll_up", scroll_up, {input_section = "menu"})
mp.add_key_binding(opts.wheel_down, "scroll_down", scroll_down, {input_section = "menu"})
mp.add_key_binding(opts.esc, "hide_menu", hide_menu, {input_section = "menu"})