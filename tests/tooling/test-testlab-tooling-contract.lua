-- Offline: the testlab's PowerShell drivers match the Lua mod.
--  * every mailbox verb the mod handles is accepted by send-testlab-command.ps1
--    (and nothing else is), and
--  * every module the mod loads ships in testlab/darktide_testlab or is copied
--    from mods/darktidevr by testlab-desktop-session.ps1.
-- arg[1]: repository root
local root=assert(arg[1])
local function read(path)
    local file=assert(io.open(root..'/'..path,'r'),path);local text=file:read('*a');file:close();return text
end
local function exists(path) local file=io.open(root..'/'..path,'r');if file then file:close();return true end end
local lua=read('testlab/darktide_testlab/scripts/mods/darktide_testlab/darktide_testlab.lua')
local send=read('tools/stereo/send-testlab-command.ps1')
local session=read('tools/stereo/testlab-desktop-session.ps1')
local verbs,accepted={},{}
for verb in lua:gmatch('verb=="(%w+)"') do verbs[verb]=true end
local set=assert(send:match('%[ValidateSet%(([^%)]*)%)%]%[string%]%s*%$Command'),'Command ValidateSet')
for verb in set:gmatch("'(%w+)'") do accepted[verb]=true end
for verb in pairs(verbs) do assert(accepted[verb],'send-testlab-command.ps1 cannot send '..verb) end
for verb in pairs(accepted) do assert(verbs[verb],'send-testlab-command.ps1 accepts '..verb..' which the mod does not handle') end
local canonical={}
local list=assert(session:match('%$canonical=@%((.-)%)\n'),'canonical copy list')
for name in list:gmatch("'darktidevr_([%w_]+)%.lua'") do
    canonical[name]=true
    assert(exists('mods/darktidevr/scripts/mods/darktidevr/darktidevr_'..name..'.lua'),'copy source missing: '..name)
end
local needed={}
for name in lua:gmatch('io_dofile%("darktide_testlab/scripts/mods/darktide_testlab/([%w_]+)"%)') do needed[name]=true end
-- run_case: local function load(suffix) ... "melee_"..suffix
assert(lua:find('io_dofile("darktide_testlab/scripts/mods/darktide_testlab/melee_"..suffix)',1,true),'run_case loader changed')
for suffix in lua:gmatch('load%("([%w_]+)"%)') do needed['melee_'..suffix]=true end
local count=0
for name in pairs(needed) do
    count=count+1
    local shipped=exists('testlab/darktide_testlab/scripts/mods/darktide_testlab/'..name..'.lua')
    assert(shipped or canonical[name],'testlab loads '..name..' but neither ships it nor copies darktidevr_'..name..'.lua')
end
assert(needed.melee_contact and needed.melee_probe and needed.melee_gesture_aim and needed.damage_ledger and
    needed.ranged_sweep,'module discovery is incomplete')
-- The failure-case driver only names scenarios the testlab ships.
local failures=read('tools/stereo/test-testlab-failure-cases.ps1')
local scenarios=0
for name in failures:gmatch("scenario='([%w_]+%.tsv)'") do
    scenarios=scenarios+1
    assert(exists('testlab/darktide_testlab/'..name),'failure-case driver names a missing scenario: '..name)
end
assert(scenarios==6,'failure-case scenario discovery: '..scenarios)
-- The testlab is separate from the mod (user, 24 October: friends do not need
-- the test environment): it lives outside mods/, the VR mod never asks for it
-- by name, and the release package lists none of it.
assert(not exists('mods/darktide_testlab/darktide_testlab.mod'),'the testlab is back inside mods/')
local vr=read('mods/darktidevr/scripts/mods/darktidevr/darktidevr.lua')
assert(not vr:find('get_mod("darktide_testlab")',1,true),'the VR mod calls into the testlab')
assert(lua:find('controller_input_filters.darktide_testlab',1,true),'the testlab no longer registers its input filter')
assert(not read('tools/release/runtime-package-files.psd1'):lower():find('testlab',1,true),'the release package lists testlab files')
print('testlab_tooling_contract=pass verbs='..(function() local n=0;for _ in pairs(verbs) do n=n+1 end;return n end)()..' modules='..count..' failure_scenarios='..scenarios)
