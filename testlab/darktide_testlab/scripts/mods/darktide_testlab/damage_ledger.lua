-- Per-run ledger of the local player's own stock attacks. Engine-independent:
-- the adapter reports what the run pressed, each native attack (sweep) that
-- started, and every Attack.execute the player's attacks dealt. Answers "did
-- that press damage anything?", which a log of presses alone cannot.
--
-- Summary: presses=light+heavy+scripted, the attack inputs the run sent,
-- excluding charges the runtime cancelled (charge_cancel, the physical route
-- only; counted apart). On the stock route letting go fires the charge
-- (charge_release, the trigger is the attack button): that press is an attack.
-- Linking: a native attack belongs to the newest attack input the run sent
-- before it, if that input is not linked yet and was let go at most WINDOW
-- seconds earlier (a held charge is still open). Once a newer input is linked,
-- an older unlinked one was never answered (no native attack started for it),
-- unless it is a charge still held, or let go after that newer input.
local Ledger={}
Ledger.WINDOW=1.0
Ledger.HIT_ROWS=256
Ledger.PRESS_ROWS=256
Ledger.ATTACK_ROWS=256
-- Inputs that ask for an attack, as opposed to a push or a weapon special.
Ledger.ATTACK_KINDS={light=true,heavy=true,scripted=true}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
-- Attack.execute(target,profile,...) takes key/value pairs; keep the ones a
-- hit row reports. Never alters or retains the native argument list.
local KEYS={attacking_unit=true,attack_type=true,hit_zone_name=true,damage_type=true,
    is_critical_strike=true,charge_level=true,target_index=true,target_number=true}
function Ledger.metadata(...)
    local out={}
    local n=select("#",...)
    for i=1,n-1,2 do
        local key,value=select(i,...)
        if KEYS[key] then out[key]=value end
    end
    return out
end
function Ledger.damaging(hit) return (finite(hit.damage) and hit.damage>0) or hit.result=="died" end
Ledger.SUMMARY_FORMAT="presses=%d light=%d heavy=%d scripted=%d specials=%d pushes=%d cancelled=%d cancelled_attacked=%d "..
    "attacks=%d attacks_pressed=%d attacks_unpressed=%d attacks_damaged=%d hits=%d damaging_hits=%d head_hits=%d "..
    "weakspot_hits=%d critical_hits=%d kills=%d damage=%.3f presses_damaged=%d presses_no_damage=%d "..
    "presses_no_attack=%d presses_attack_no_damage=%d orphan_hits=%d dropped_rows=%d"
-- One key=value token: engine unit names ("[Unit '#ID[..]']") contain spaces.
local function word(value) return (tostring(value):gsub("[%s=]+","_")) end
function Ledger.hit_text(hit)
    return string.format("hit=%d t=%.3f attack=%s action=%s target=%s breed=%s unit=%s zone=%s damage=%s result=%s killed=%s weakspot=%s critical=%s attack_type=%s damage_type=%s health_after=%s",
        hit.index or 0,hit.t or -1,word(hit.attack),word(hit.action),word(hit.target),word(hit.breed),
        word(hit.unit),word(hit.zone),word(hit.damage),word(hit.result),tostring(hit.result=="died"),
        word(hit.weakspot),word(hit.critical),word(hit.attack_type),word(hit.damage_type),word(hit.health_after))
end
function Ledger.new(options)
    options=options or {}
    local window=options.window or Ledger.WINDOW
    local presses,attacks,hits={},{},{}
    local open
    local dropped={presses=0,attacks=0,hits=0}
    local totals={hits=0,damaging=0,head=0,weakspot=0,critical=0,kills=0,damage=0,orphans=0}
    local api={}
    -- kind: light|heavy|scripted (attack inputs), push, special.
    -- A special is a one-frame pulse on its own button: pass released=t.
    function api.press(t,kind,released)
        if not finite(t) then return nil end
        if #presses>=Ledger.PRESS_ROWS then dropped.presses=dropped.presses+1;return nil end
        local press={index=#presses+1,t=t,kind=kind or "light",released=released}
        presses[#presses+1]=press
        return press
    end
    -- The attack button let go: closes the newest held attack/push input.
    function api.release(t)
        for i=#presses,1,-1 do
            local press=presses[i]
            if press.kind~="special" and not press.released then press.released=t;return press end
        end
    end
    -- A charge let go without a swing: the run meant no attack.
    function api.cancel(t,reason)
        for i=#presses,1,-1 do
            local press=presses[i]
            if Ledger.ATTACK_KINDS[press.kind] then
                if not press.cancelled then press.cancelled=reason or "cancelled";press.cancel_t=t end
                return press
            end
        end
    end
    local function link(t)
        local answered -- press time of the newest input already answered
        for i=#presses,1,-1 do
            local press=presses[i]
            if press.t<=t+1e-9 then
                if press.attack then answered=answered or press.t
                else
                    local released=press.released
                    local recent=not released or t-released<=window+1e-9
                    -- Behind an answered input only a charge still held (or let
                    -- go after it) can still be waiting for its attack.
                    if recent and (not answered or not released or released>=answered) then return press end
                    if not answered then return nil end
                end
            end
        end
    end
    function api.attack_start(key,t,action,kind)
        if open then open.finished=open.finished or "superseded" end
        local attack={index=#attacks+1,key=key,t=t,action=tostring(action),kind=tostring(kind),
            hits=0,damage=0,kills=0,head=0,damaging=0}
        if #attacks>=Ledger.ATTACK_ROWS then
            dropped.attacks=dropped.attacks+1
            -- Still counted against its press; only the row is not kept.
            attack.index=nil
        else attacks[#attacks+1]=attack end
        local press=link(t)
        if press then press.attack=attack;attack.press=press end
        open=attack
        return attack
    end
    function api.attack_finish(key,t,reason)
        if open and open.key==key then
            open.finished=reason or "finished";open.finish_t=t;open=nil
        end
    end
    function api.open() return open end
    -- hit: {t,action,target,breed,unit,zone,damage,result,weakspot,critical,attack_type,health_after}
    function api.hit(hit)
        local attack=open
        local damaging=Ledger.damaging(hit)
        totals.hits=totals.hits+1
        if damaging then totals.damaging=totals.damaging+1 end
        if hit.zone=="head" then totals.head=totals.head+1 end
        if hit.weakspot==true then totals.weakspot=totals.weakspot+1 end
        if hit.critical==true then totals.critical=totals.critical+1 end
        if hit.result=="died" then totals.kills=totals.kills+1 end
        if finite(hit.damage) and hit.damage>0 then totals.damage=totals.damage+hit.damage end
        if attack then
            attack.hits=attack.hits+1
            if damaging then attack.damaging=attack.damaging+1 end
            if finite(hit.damage) and hit.damage>0 then attack.damage=attack.damage+hit.damage end
            if hit.result=="died" then attack.kills=attack.kills+1 end
            if hit.zone=="head" then attack.head=attack.head+1 end
            hit.attack=attack.index or "dropped"
            hit.action=attack.action
        else
            totals.orphans=totals.orphans+1
            hit.attack="none"
        end
        hit.index=totals.hits
        if #hits<Ledger.HIT_ROWS then hits[#hits+1]=hit else dropped.hits=dropped.hits+1 end
        return hit
    end
    local function outcome(press)
        if press.cancelled then return press.attack and "cancelled_attacked" or "cancelled" end
        if not press.attack then return "no_attack" end
        if press.attack.damaging>0 then return "damaged" end
        return "attack_no_damage"
    end
    function api.summary()
        local s={presses=0,light=0,heavy=0,scripted=0,specials=0,pushes=0,cancelled=0,cancelled_attacked=0,
            attacks=0,attacks_pressed=0,attacks_unpressed=0,attacks_damaged=0,
            presses_damaged=0,presses_no_damage=0,presses_no_attack=0,presses_attack_no_damage=0,
            hits=totals.hits,damaging_hits=totals.damaging,head_hits=totals.head,weakspot_hits=totals.weakspot,
            critical_hits=totals.critical,kills=totals.kills,damage=totals.damage,orphan_hits=totals.orphans,
            dropped_rows=dropped.presses+dropped.attacks+dropped.hits}
        for _,press in ipairs(presses) do
            if press.kind=="special" then s.specials=s.specials+1
            elseif press.kind=="push" then s.pushes=s.pushes+1
            elseif Ledger.ATTACK_KINDS[press.kind] then
                local result=outcome(press)
                if result=="cancelled" or result=="cancelled_attacked" then
                    s.cancelled=s.cancelled+1
                    if result=="cancelled_attacked" then s.cancelled_attacked=s.cancelled_attacked+1 end
                else
                    s[press.kind]=s[press.kind]+1
                    s.presses=s.presses+1
                    if result=="damaged" then s.presses_damaged=s.presses_damaged+1
                    else
                        s.presses_no_damage=s.presses_no_damage+1
                        if result=="no_attack" then s.presses_no_attack=s.presses_no_attack+1
                        else s.presses_attack_no_damage=s.presses_attack_no_damage+1 end
                    end
                end
            end
        end
        for _,attack in ipairs(attacks) do
            s.attacks=s.attacks+1
            if attack.press then s.attacks_pressed=s.attacks_pressed+1 else s.attacks_unpressed=s.attacks_unpressed+1 end
            if attack.damaging>0 then s.attacks_damaged=s.attacks_damaged+1 end
        end
        s.attacks=s.attacks+dropped.attacks
        return s
    end
    function api.summary_text()
        local s=api.summary()
        return string.format(Ledger.SUMMARY_FORMAT,s.presses,s.light,s.heavy,s.scripted,s.specials,s.pushes,s.cancelled,
            s.cancelled_attacked,s.attacks,s.attacks_pressed,s.attacks_unpressed,s.attacks_damaged,s.hits,s.damaging_hits,
            s.head_hits,s.weakspot_hits,s.critical_hits,s.kills,s.damage,s.presses_damaged,s.presses_no_damage,
            s.presses_no_attack,s.presses_attack_no_damage,s.orphan_hits,s.dropped_rows)
    end
    -- One line per input: which native attack (if any) answered it, and what it did.
    function api.press_rows()
        local rows={}
        for _,press in ipairs(presses) do
            local attack=press.attack
            rows[#rows+1]=string.format("press=%d t=%.3f kind=%s released=%s attack=%s action=%s attack_t=%s hits=%d damage=%.3f kills=%d outcome=%s cancel=%s",
                press.index,press.t,press.kind,press.released and string.format("%.3f",press.released) or "held",
                attack and tostring(attack.index or "dropped") or "none",attack and attack.action or "none",
                attack and string.format("%.3f",attack.t) or "none",attack and attack.hits or 0,attack and attack.damage or 0,
                attack and attack.kills or 0,
                (Ledger.ATTACK_KINDS[press.kind] and outcome(press)) or press.kind,tostring(press.cancelled or "none"))
        end
        return rows
    end
    function api.attack_rows()
        local rows={}
        for _,attack in ipairs(attacks) do
            rows[#rows+1]=string.format("attack=%d t=%.3f action=%s kind=%s press=%s press_kind=%s hits=%d damaging_hits=%d head_hits=%d damage=%.3f kills=%d finished=%s",
                attack.index,attack.t,attack.action,attack.kind,attack.press and tostring(attack.press.index) or "none",
                attack.press and attack.press.kind or "none",attack.hits,attack.damaging,attack.head,attack.damage,attack.kills,
                tostring(attack.finished or "open"))
        end
        return rows
    end
    function api.hits() return hits end
    return api
end
return Ledger
