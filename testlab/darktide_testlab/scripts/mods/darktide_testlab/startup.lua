-- Uses the same stock readiness gates/callbacks as darktidevr_menu_input.
-- No keyboard injection, authentication override or character creation.
local Startup={}
function Startup.title(request,view,input,t)
    if not request.armed or request.title_done or view._continue_triggered or view.closing_view then return false end
    if not input or input:is_null_service() or type(view._continue)~="function" then
        request.title_ready=nil; return false
    end
    request.title_ready=request.title_ready or t
    if t-request.title_ready<1 then return false end
    request.title_done=true
    view:_continue()
    return true
end
function Startup.character(request,view,input,ui,t)
    if not request.armed or request.character_done or request.failed then return false end
    if request.owner and request.owner~=view then request.failed="character_view_replaced"; return false end
    request.owner=view
    local buttons=view._widgets_by_name
    local play=buttons and buttons.play_button and buttons.play_button.content
    local blocked=not input or input:is_null_service() or view._input_disabled or
        view._profiles_wait_overlay_active or view._server_migration_element or view._is_main_menu_open or
        (ui and ui._active_popups and ui._active_popups[1])
    if blocked or not play or not play.visible or not play.hotspot or play.hotspot.disabled then
        request.ready_since=nil; return false
    end
    request.ready_since=request.ready_since or t
    if t-request.ready_since<1 then return false end
    if request.character and not request.selected then
        -- A character name, or "archetype:<name>" for the first character of
        -- that class (archetype:ogryn).
        local archetype=request.character:match("^archetype:(%S+)$")
        local index
        for i,widget in ipairs(view._character_list_widgets or {}) do
            local profile=widget.content and widget.content.profile
            if profile and (archetype and profile.archetype and profile.archetype.name==archetype or
                    not archetype and profile.name==request.character) then index=i; break end
        end
        if not index or type(view._on_character_widget_selected)~="function" then
            request.failed="character_not_found"; return false
        end
        request.selected=true; request.ready_since=t
        view:_on_character_widget_selected(index,true)
        return false
    end
    local callback=play.hotspot.pressed_callback
    if type(callback)~="function" then return false end
    request.character_done=true
    callback()
    return true
end
return Startup
