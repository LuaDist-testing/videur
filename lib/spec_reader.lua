
-- reads the proxy server specs to generate the actual routing
-- rejects anything that's not
local cjson = require "cjson"
local rex = require "rex_posix"
local date = require "date"
local len = string.len
local util = require "util"


function get_location(spec_url, cached_spec)
    local last_updated = cached_spec:get("last-updated")

    -- update the spec if needed
    -- TODO: add a Last-Modified header + check every 5mn maybe
    -- TODO: make sure it gets reloaded on sighup


    -- TODO: we need a way to invalidate the cache
    if not last_updated then
        ngx.log(ngx.INFO, "Loading the api-spec file")

        local body, version, resources = nil
        -- we need to load it from the backend
        body = util.fetch_http_body(spec_url)
        cached_spec:set("raw_body", body)
        body = cjson.decode(body)    -- todo catch parse error

        -- grabbing the values and setting them in mem
        local service = body.service
        cached_spec:set('location', service.location)
        version = service.version
        cached_spec:set('version', service.version)

        for location, desc in pairs(service.resources) do
            local verbs = {}

            for verb, def in pairs(desc) do
                local definition = cjson.encode(def or {})
                local t, l = location:match('(%a+):(.*)')
                if t == 'regexp' then
                    cached_spec:set("regexp:" .. verb .. ":" .. l, definition)
                else
                    cached_spec:set(verb .. ":" .. location, definition)
                end
                verbs[verb] = true
            end
            cached_spec:set("verbs:" .. location, util.implode(",", verbs))
        end
        last_updated = os.time()
        cached_spec:set("last-updated", last_updated)
        return service.location
    else
        return cached_spec:get('location')
    end
end


function _repl_var(match, captures)
    local res = 'ngx.var.' .. match
    res = res .. ' or ""'
    return res
end


function _repl_header(match, captures)
    local res = 'ngx.var.http_' .. match
    res = res .. ' or ""'
    return res
end


function convert_match(expr)
    -- TODO: take care of the ipv4 and ipv6 fields
    local expr = expr:lower()
    expr = expr:gsub("-", "_")
    expr = rex.gsub(expr, 'header:([a-zA-Z\\-_0-9]+)', _repl_header)
    expr = rex.gsub(expr, 'var:([a-zA-Z\\-_0-9]+)', _repl_var)
    expr = expr:gsub("and", " .. ':::' .. ")
    expr = "return " .. expr
    return loadstring(expr)
end


function match(spec_url, cached_spec)
    -- get the location from the spec url
    local location = get_location(spec_url, cached_spec)

    -- now let's see if we have a direct match
    local method = ngx.req.get_method()
    local key = method .. ":" .. ngx.var.uri
    local cached_value = cached_spec:get(key)

    if not cached_value then
        -- we don't - we can try a regexp match now
        for __, expr in ipairs(cached_spec:get_keys()) do
            local t, v, l = expr:match('(%a+):(.*):(.*)')
            if t == 'regexp' then
                if rex.match(ngx.var.uri, l) and v == method then
                    cached_value = cached_spec:get(expr)
                    break
                end
            end
        end

        if not cached_value then
            -- we don't!
            -- if we are serving / we can send back a page
            -- TODO: whitelist of URLS ?
            if ngx.var.uri == '/' then
                ngx.say("Welcome to Nginx/Videur")
                return ngx.exit(200)
            else
                local existing_verbs = cached_spec:get("verbs:/dashboard")

                if not existing_verbs then
                    return ngx.exit(ngx.HTTP_NOT_FOUND)
                else
                    -- XXX that does not seem to be applied
                    ngx.header['Allow'] = existing_verbs
                    return ngx.exit(ngx.HTTP_NOT_ALLOWED)
                end
            end
        end
    end

    --
    -- checking the query arguments
    --
    local definition = cjson.decode(cached_value)
    local params = definition.parameters or {}
    local limits = definition.limits or {}
    local args = ngx.req.get_uri_args()

    -- let's check if we have all required args first
    local provided_args = util.Keys(args)

    for key, value in pairs(params) do
        if value.required and not provided_args[key] then
            return util.bad_request("Missing " .. key)
        end
    end

    -- now let's validate the args we got
    -- TODO: we should build all those regexps when we read the spec file
    -- and have them loaded in the cache so we don't
    -- do it again
    for key, val in pairs(args) do
        local constraint = params[key]
        if constraint then
            if constraint['validation'] then
                local validation = constraint['validation']
                local t, v = validation:match('(%a+):(.*)')
                if not t then
                    -- not a prefix:
                    t = validation
                    v = ''
                end

                if t == 'regexp' then
                    if not rex.match(val, v) then
                        -- the value does not match the constraints
                        return util.bad_request("Field does not match " .. key)
                    end
                elseif t == 'digits' then
                    local pattern = '[0-9]{' .. v .. '}'
                    if not rex.match(val, pattern) then
                        -- the value does not match the constraints
                        return util.bad_request("Field does not match " .. key)
                    end
                elseif t == 'values' then
                    local pattern = '(' .. v .. ')'
                    if not rex.match(val, pattern) then
                        -- the value does not match the constraints
                        return util.bad_request("Field does not match " .. key)
                    end
                elseif t == 'datetime' then
                    if not pcall(function() date(val) end) then
                        return util.bad_request("Field is not RFC3339 " .. key)
                    end
                else
                    -- XXX should be detected at indexing time
                    return util.bad_request("Bad rule " .. t)
                end
            end
        else
            -- this field was not declared
            return util.bad_request("Unknown field " .. key)
        end
    end

    -- let's prepare the limits by converting the match value
    -- into a lua expression
    -- XXX should be cached too...
    local parsed_limits = {max_body_size = limits.max_body_size}
    for key, value in pairs(limits) do
        if key == 'rates' then
            local rates = value
            for __, rate in pairs(rates) do
                rate.match = convert_match(rate.match)
            end
            parsed_limits.rates = rates
        end
    end

    return location, parsed_limits, params
end


-- public interface
return {
  match = match
}
