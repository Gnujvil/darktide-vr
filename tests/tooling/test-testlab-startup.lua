local Startup=dofile(assert(arg[1]))
local continues,starts,selections=0,0,0
local input={is_null_service=function() return false end}
local blocked={is_null_service=function() return true end}
local title={_continue=function() continues=continues+1 end}
local request={armed=true}
assert(not Startup.title(request,title,blocked,0))
assert(not Startup.title(request,title,input,1))
assert(Startup.title(request,title,input,2))
assert(not Startup.title(request,title,input,4) and continues==1)
local view={_widgets_by_name={play_button={content={visible=true,hotspot={disabled=false,
    pressed_callback=function() starts=starts+1 end}}}},
    _character_list_widgets={{content={profile={name='Existing'}}}},
    _on_character_widget_selected=function(_,index) assert(index==1); selections=selections+1 end}
request={armed=true,character='Existing'}
local popup={_active_popups={{}}}
assert(not Startup.character(request,view,input,popup,0))
assert(not Startup.character(request,view,input,{},1))
assert(not Startup.character(request,view,input,{},2) and selections==1 and starts==0)
assert(Startup.character(request,view,input,{},3) and starts==1)
assert(not Startup.character(request,view,input,{},4) and starts==1)
local missing={armed=true,character='DoesNotExist'}
assert(not Startup.character(missing,view,input,{},1))
assert(not Startup.character(missing,view,input,{},2) and missing.failed=='character_not_found' and starts==1)
local disabled={armed=true}
view._input_disabled=true
assert(not Startup.character(disabled,view,input,{},1))
view._input_disabled=false
assert(not Startup.character(disabled,view,input,{},2))
assert(not Startup.character(disabled,view,blocked,{},4))
assert(not Startup.character(disabled,view,input,{},5))
assert(Startup.character(disabled,view,input,{},6))
-- archetype:<name> selects the first character of that class.
local picked
view={_widgets_by_name=view._widgets_by_name,
    _character_list_widgets={{content={profile={name='Zealot',archetype={name='zealot'}}}},
        {content={profile={name='Big',archetype={name='ogryn'}}}}},
    _on_character_widget_selected=function(_,index) picked=index end}
local by_class={armed=true,character='archetype:ogryn'}
assert(not Startup.character(by_class,view,input,{},10))
assert(not Startup.character(by_class,view,input,{},11) and picked==2,'archetype did not select the ogryn')
local no_class={armed=true,character='archetype:psyker'}
assert(not Startup.character(no_class,view,input,{},20))
assert(not Startup.character(no_class,view,input,{},21) and no_class.failed=='character_not_found')
print('testlab_startup=pass stock_gates settle named_character archetype popup null_service one_shot')
