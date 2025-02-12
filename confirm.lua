--@ module = true

local gui = require('gui')
local overlay = require('plugins.overlay')
local specs = reqscript('internal/confirm/specs')
local widgets = require("gui.widgets")

------------------------
-- API

function get_state()
    return specs.config.data
end

function set_enabled(id, enabled)
    for _, conf in pairs(specs.config.data) do
        if conf.id == id then
            if conf.enabled ~= enabled then
                conf.enabled = enabled
                specs.config:write()
            end
            break
        end
    end
end

------------------------
-- Overlay

PromptWindow = defclass(PromptWindow, widgets.Window)
PromptWindow.ATTRS {
    frame={w=47, h=12},
    conf=DEFAULT_NIL,
    propagate_fn=DEFAULT_NIL,
}

function PromptWindow:init()
    self:addviews{
        widgets.WrappedLabel{
            frame={t=0, l=0, r=0},
            text_to_wrap=self.conf.message,
        },
        widgets.HotkeyLabel{
            frame={b=1, l=0},
            label='Yes, proceed',
            key='SELECT',
            auto_width=true,
            on_activate=self:callback('proceed'),
        },
        widgets.HotkeyLabel{
            frame={b=1, l=32},
            label='Settings',
            key='CUSTOM_SHIFT_S',
            auto_width=true,
            on_activate=self:callback('settings'),
        },
        widgets.HotkeyLabel{
            frame={b=0, l=0},
            label='Pause confirmations while on this screen',
            key='CUSTOM_SHIFT_P',
            auto_width=true,
            visible=self.conf.pausable,
            on_activate=self:callback('pause'),
        },
    }
end

function PromptWindow:proceed()
    self.parent_view:dismiss()
    self.propagate_fn()
end

function PromptWindow:settings()
    self.parent_view:dismiss()
    dfhack.run_script('gui/confirm', self.conf.id)
end

function PromptWindow:pause()
    self.parent_view:dismiss()
    self.propagate_fn(true)
end

PromptScreen = defclass(PromptScreen, gui.ZScreenModal)
PromptScreen.ATTRS {
    focus_path='confirm/prompt',
    conf=DEFAULT_NIL,
    propagate_fn=DEFAULT_NIL,
}

function PromptScreen:init()
    self:addviews{
        PromptWindow{
            frame_title=self.conf.title,
            conf=self.conf,
            propagate_fn=self.propagate_fn,
        }
    }
end

local function get_contexts()
    local contexts, contexts_set = {}, {}
    for id, conf in pairs(specs.REGISTRY) do
        if not contexts_set[id] then
            contexts_set[id] = true
            table.insert(contexts, conf.context)
        end
    end
    return contexts
end

ConfirmOverlay = defclass(ConfirmOverlay, overlay.OverlayWidget)
ConfirmOverlay.ATTRS{
    desc='Detects dangerous actions and prompts with confirmation dialogs.',
    default_pos={x=1,y=1},
    default_enabled=true,
    overlay_only=true,  -- not player-repositionable
    hotspot=true,       -- need to unpause when we're not in target contexts
    overlay_onupdate_max_freq_seconds=300,
    viewscreens=get_contexts(),
}

function ConfirmOverlay:init()
    for id, conf in pairs(specs.REGISTRY) do
        if conf.intercept_frame then
            self:addviews{
                widgets.Panel{
                    view_id=id,
                    frame=copyall(conf.intercept_frame),
                    frame_style=conf.debug_frame and gui.FRAME_INTERIOR or nil,
                }
            }
        end
    end
end

function ConfirmOverlay:preUpdateLayout()
    self.frame.w, self.frame.h = dfhack.screen.getWindowSize()
    -- reset frames if any of them have been pushed out of position
    for id, conf in pairs(specs.REGISTRY) do
        if conf.intercept_frame then
            self.subviews[id].frame = copyall(conf.intercept_frame)
        end
    end
end

function ConfirmOverlay:overlay_onupdate()
    if self.paused_conf and
        not dfhack.gui.matchFocusString(self.paused_conf.context,
                dfhack.gui.getDFViewscreen(true))
    then
        self.paused_conf = nil
        self.overlay_onupdate_max_freq_seconds = 300
    end
end

function ConfirmOverlay:matches_conf(conf, keys, scr)
    local matched_keys = false
    for _, key in ipairs(conf.intercept_keys) do
        if keys[key] then
            matched_keys = true
            break
        end
    end
    if not matched_keys then return false end
    local mouse_offset
    if keys._MOUSE_L and conf.intercept_frame then
        local mousex, mousey = self.subviews[conf.id]:getMouseFramePos()
        if not mousex then
            return false
        end
        mouse_offset = xy2pos(mousex, mousey)
    end
    if not dfhack.gui.matchFocusString(conf.context, scr) then return false end
    return not conf.predicate or conf.predicate(keys, mouse_offset)
end

function ConfirmOverlay:onInput(keys)
    if self.paused_conf or self.simulating then
        return false
    end
    local scr = dfhack.gui.getDFViewscreen(true)
    for id, conf in pairs(specs.REGISTRY) do
        if specs.config.data[id].enabled and self:matches_conf(conf, keys, scr) then
            local mouse_pos = xy2pos(dfhack.screen.getMousePos())
            local propagate_fn = function(pause)
                if conf.on_propagate then
                    conf.on_propagate()
                end
                if pause then
                    self.paused_conf = conf
                    self.overlay_onupdate_max_freq_seconds = 0
                end
                if keys._MOUSE_L then
                    df.global.gps.mouse_x = mouse_pos.x
                    df.global.gps.mouse_y = mouse_pos.y
                end
                self.simulating = true
                gui.simulateInput(scr, keys)
                self.simulating = false
            end
            PromptScreen{conf=conf, propagate_fn=propagate_fn}:show()
            return true
        end
    end
end

function ConfirmOverlay:render(dc)
    if gui.blink_visible(500) then
        return
    end
    ConfirmOverlay.super.render(self, dc)
end

OVERLAY_WIDGETS = {
    overlay=ConfirmOverlay,
}

------------------------
-- CLI

local function do_list()
    print('Available confirmation prompts:')
    local confs, max_len = {}, 10
    for id, conf in pairs(specs.REGISTRY) do
        max_len = math.max(max_len, #id)
        table.insert(confs, conf)
    end
    table.sort(confs, function(a,b) return a.id < b.id end)
    for _, conf in ipairs(confs) do
        local fmt = '%' .. tostring(max_len) .. 's: %s %s'
        print((fmt):format(conf.id,
            specs.config.data[conf.id].enabled and '(enabled) ' or '(disabled)',
            conf.title))
    end
end

local function do_enable_disable(args, enable)
    if args[1] == 'all' then
        for id in pairs(specs.REGISTRY) do
            set_enabled(id, enable)
        end
    else
        for _, id in ipairs(args) do
            if not specs.REGISTRY[id] then
                qerror('confirmation prompt id not found: ' .. tostring(id))
            end
            set_enabled(id, enable)
        end
    end
end

local function main(args)
    local command = table.remove(args, 1)

    if not command or command == 'list' then
        do_list()
    elseif command == 'enable' or command == 'disable' then
        do_enable_disable(args, command == 'enable')
    elseif command == 'help' then
        print(dfhack.script_help())
    else
        dfhack.printerr('unknown command: ' .. tostring(command))
    end
end

if not dfhack_flags.module then
    main{...}
end
