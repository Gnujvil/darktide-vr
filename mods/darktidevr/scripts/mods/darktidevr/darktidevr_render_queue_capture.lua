-- Capture attribution around one stock ScriptWorld.render traversal. The
-- stock renderer owns shading, LOD, world updates and viewport iteration.
local Queue = {}
local function pack(...) return {n=select('#',...),...} end
function Queue.new(options)
    local scope
    local api={}
    function api.native(render,world,camera,viewport,shading,...)
        local current=scope
        local eye
        if current and current.world==world then eye=current.eyes[viewport] end
        if eye==nil then return render(world,camera,viewport,shading,...) end
        assert(not current.in_flight,'nested_eye_submission')
        assert(not options.left_first or eye==0 or current.seen[0],'left_eye_must_render_first')
        assert(not current.seen[eye],'duplicate_eye_submission')
        current.seen[eye]=true
        current.in_flight=true
        local target=options.before_eye(eye,camera,viewport,world)
        local results=pack(render(world,camera,viewport,shading,...))
        options.after_eye(eye,target)
        current.in_flight=false
        return unpack(results,1,results.n)
    end
    function api.run(world,left,right,render,...)
        assert(not scope,'nested_render_queue_scope')
        assert(world and left and right and left~=right,'distinct_eye_viewports_required')
        scope={world=world,eyes={[left]=0,[right]=1},seen={}}
        local current=scope
        local results=pack(pcall(render,world,...))
        scope=nil
        local complete=current.seen[0] and current.seen[1] and not current.in_flight
        if not results[1] or not complete then
            local reset_ok,reset_error=pcall(options.reset)
            if not results[1] then error(results[2],0) end
            if not reset_ok then error(reset_error,0) end
            error('incomplete_eye_submissions',0)
        end
        return unpack(results,2,results.n)
    end
    return api
end
return Queue
