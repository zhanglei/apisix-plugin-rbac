
local core     = require("apisix.core")
local ck       = require("resty.cookie")
local consumer = require("apisix.consumer")
local json     = require("apisix.core.json")
local ngx_re = require("ngx.re")
local cjson = require("cjson")
local http     = require("resty.http")
local ipairs   = ipairs
local ngx      = ngx
local ngx_time = ngx.time
local plugin_name = "wolf-rbac"


local schema = {
    type = "object",
    properties = {
        appid = {type = "string"},
        server = { type = 'string'},
    }
}


local _M = {
    version = 0.1,
    priority = 2555,
    type = 'auth',
    name = plugin_name,
    schema = schema,
}


local create_consume_cache
do
    local consumer_ids = {}

    function create_consume_cache(consumers)
        core.table.clear(consumer_ids)

        for _, consumer in ipairs(consumers.nodes) do
            core.log.info("consumer node: ", core.json.delay_encode(consumer))
            consumer_ids[consumer.auth_conf.appid] = consumer
        end

        return consumer_ids
    end

end -- do

local token_version = 'V1'
local function create_rbac_token(appid, wolf_token)
    return token_version .. "#" .. appid .. "#" .. wolf_token
end

local function parse_rbac_token(rbac_token) 
    local res, err = ngx_re.split(rbac_token, "#", nil, nil, 3)
    if not res then
        return { err=err}
    end

    if res[1] ~= token_version then
        return { err='invalid rbac token: version'}
    end
    local appid = res[2]
    local wolf_token = res[3]

    return {appid = appid, wolf_token = wolf_token}
end

local function new_headers()
    local t = {}
    local lt = {}
    local _mt = {
        __index = function(t, k)
            return rawget(lt, string.lower(k))
        end,
        __newindex = function(t, k, v)
            rawset(t, k, v)
            rawset(lt, string.lower(k), v)
        end,
     }
    return setmetatable(t, _mt)
end

-- timeout in ms
local function http_req(method, uri, body, myheaders, timeout)
    if myheaders == nil then myheaders = new_headers() end

    local httpc = http.new()
    if timeout then
        httpc:set_timeout(timeout)
    end

    local params = {method = method, headers = myheaders, body=body, ssl_verify=false}
    local res, err = httpc:request_uri(uri, params)
    if err then
        core.log.error("FAIL REQUEST [ ",core.json.delay_encode({method=method, uri=uri, body=body, headers=myheaders}), " ] failed! res is nil, err:", err)
        return nil, err
    end

    return res
end

local function http_get(uri, myheaders, timeout)
    return http_req("GET", uri, nil, myheaders, timeout)
end

local function http_post(uri, body, myheaders, timeout)
    return http_req("POST", uri, body, myheaders, timeout)
end

local function http_put(uri,  body, myheaders, timeout)
    return http_req("PUT", uri, body, myheaders, timeout)
end

function _M.check_schema(conf)
    core.log.info("input conf: ", core.json.delay_encode(conf))

    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if not conf.appid then
        conf.appid = 'unset'
    end
    if not conf.server then
        conf.server = 'http://127.0.0.1:10080'
    end

    return true
end


local function fetch_rbac_token()
    local args = ngx.req.get_uri_args()
    if args and args.rbac_token then
        return args.rbac_token
    end

    local headers = ngx.req.get_headers()
    if headers.Authorization then
        return headers.Authorization
    end
    if headers['x-rbac-token'] then
        return headers['x-rbac-token']
    end
    local cookie, err = ck:new()
    if not cookie then
        return nil, err
    end
    local val, err = cookie:get("x-rbac-token")
    return val, err
end

local function loadjson(str)
    local ok, jso = pcall(function() return cjson.decode(str) end)
    if ok then
        return jso
    else
        return nil, jso
    end
end

local function check_url_permission(server, appid, action, resName, clientIP, wolf_token)
    local retry_max = 3
    local errmsg = nil;
    local userInfo = nil
    local res = nil
    local err = nil
    local access_check_url = server .. "/wolf/rbac/access_check"
    local headers = new_headers()
    headers["x-rbac-token"] = wolf_token
    headers["Content-Type"] = "application/json; charset=utf-8"
    local args = { appID = appid, resName = resName, action = action, clientIP=clientIP}
    local url = access_check_url .. "?" .. ngx.encode_args(args)
    local timeout = 1000 * 10

    for i = 1, retry_max do
        -- TODO: read apisix info.
        res, err = http_get(url, headers, timeout)
        if err then
            errmsg = 'check permission failed!' .. tostring(err)
            break
        else
            core.log.info("check permission request:", url, ", status:", res.status, ",body:", core.json.delay_encode(res.body))
            if res.status < 500 then
                break
            else
                core.log.info("request [curl -v ", url, "] failed! status:", res.status)
                if i < retry_max then
                    ngx.sleep(100)
                end
            end
        end
    end

    if err then
        core.log.error("fail request: ", url, ", err:", err)
        return {status=500, err="request to wolf-server failed, err:" .. tostring(err)}
    elseif res.status == 200 or res.status == 401 then
        local body, err = loadjson(res.body)
	    if err then
            errmsg = 'check permission failed! parse response json failed!'
            core.log.error( "loadjson(", res.body, ") failed! err:", err)
            return {status=res.status, err=errmsg}
        else
            userInfo = body.data.userInfo
            errmsg = body.reason
            return {status=res.status, err=errmsg, userInfo=userInfo}
        end
    else
        return {status=500, err='request to wolf-server failed, status:' .. tostring(res.status)}
    end
end


function _M.rewrite(conf, ctx)
    local url = ctx.var.uri
    local action = ngx.req.get_method()
    local clientIP = core.request.get_ip(ctx)
    local permItem = {action=action, url = url, clientIP = clientIP}

	local rbac_token, err = fetch_rbac_token()
	if rbac_token == nil then
		core.log.warn("no permission to access ", core.json.delay_encode(permItem), ", need login!")
        return 401, {message = "Missing rbac token in request"}
	elseif rbac_token == "logouted" then
		core.log.warn("logouted, no permission to access [", core.json.delay_encode(permItem), "], need login!")
        return 401, {message = "Missing rbac token in request"}
    end

    local tokenInfo =parse_rbac_token(rbac_token)
    core.log.info("token info: ", core.json.delay_encode(tokenInfo))
    if tokenInfo.err then
        return 401, {message = 'invalid rbac token: parse failed'}
    end


    local appid = tokenInfo.appid
    local wolf_token = tokenInfo.wolf_token
    permItem.appid = appid
    permItem.wolf_token = wolf_token

    local consumer_conf = consumer.plugin(plugin_name)
    if not consumer_conf then
        return 401, {message = "Missing related consumer"}
    end

    local consumers = core.lrucache.plugin(plugin_name, "consumers_key",
            consumer_conf.conf_version,
            create_consume_cache, consumer_conf)

    core.log.info("------ consumers: ", core.json.delay_encode(consumers))
    local consumer = consumers[appid]
    if not consumer then
        core.log.error("consumer [", appid, "] not found")
        return 401, {message = "Invalid appid in JWT token"}
    end
    core.log.info("consumer: ", core.json.delay_encode(consumer))
    local server = consumer.auth_conf.server

    local url = ctx.var.uri
    local action = ngx.req.get_method()
    local clientIP = core.request.get_ip(ctx)
    local permItem = {appid=appid, action=action, url = url, clientIP = clientIP, wolf_token=wolf_token}

    local res = check_url_permission(server, appid, action, url, clientIP, wolf_token)
	core.log.info(" check_url_permission(", core.json.delay_encode(permItem), ") res: ",core.json.delay_encode(res))

	local username = nil
    local nickname = nil
    if type(res.userInfo) == 'table' then
        local userInfo = res.userInfo
        core.response.set_header("X-UserId", userInfo.id)
        core.response.set_header("X-Username", userInfo.username)
        core.response.set_header("X-nickname", ngx.escape_uri(userInfo.nickname) or userInfo.username)
        ctx.userInfo = userInfo
		username = userInfo.username
        nickname = userInfo.nickname
	end

	if res.status == 200 then
		---
	else
        -- no permission.
        core.log.error(" check_url_permission(", core.json.delay_encode(permItem), ") failed, res: ",core.json.delay_encode(res))
        return 401, {message = res.err, username=username, nickname=nickname}
    end
    core.log.info("hit wolf-rbac rewrite")
end

local function get_args(name, kind)
    local args
    ngx.req.read_body()
    if string.find(ngx.req.get_headers()["Content-Type"] or "",
                    "application/json", 0) then
        args = json.decode(ngx.req.get_body_data())
    else
        args = ngx.req.get_post_args()
    end
    return args;
end

local function login()
    local args = get_args()
    if not args or not args.appid then
        return core.response.exit(400, {message = "appid is missing"})
    end

    local appid = args.appid

    local consumer_conf = consumer.plugin(plugin_name)
    if not consumer_conf then
        return core.response.exit(404)
    end

    local consumers = core.lrucache.plugin(plugin_name, "consumers_key",
            consumer_conf.conf_version,
            create_consume_cache, consumer_conf)

    core.log.info("------ consumers: ", core.json.delay_encode(consumers))
    local consumer = consumers[appid]
    if not consumer then
        core.log.info("request appid [", appid, "] not found")
        return core.response.exit(404, {message = "appid [" + appid + "] not found"})
    end

    core.log.info("consumer: ", core.json.delay_encode(consumer))

    local uri = consumer.auth_conf.server .. '/wolf/rbac/login.rest'
    local headers = new_headers()
    headers["Content-Type"] = "application/json; charset=utf-8"
    local timeout = 1000 * 5
    local request_debug = core.json.delay_encode({method='POST', uri=uri, body=args, headers=headers,timeout=timeout})
    core.log.info("login request [", request_debug, "] ....")
    local res, err = http_post(uri, core.json.encode(args), headers, timeout)
    if err then
        core.log.error("login request [", request_debug, "] failed! err: ", err)
        return core.response.exit(500, {message = "request to wolf-server failed! err:" .. tostring(err)})
    end
    if res.status ~= 200 then
        core.log.error("login request [", request_debug, "] failed! status: ", res.status)
        return core.response.exit(500, {message = "request to wolf-server failed! status:" .. tostring(res.status) })
    end
    local body = json.decode(res.body)
    if not body then
        core.log.error("login request [", request_debug, "] failed! response body is nil")
        return core.response.exit(500, {message = "request to wolf-server failed!"})
    end
    if not body.ok then
        core.log.error("user login [", request_debug, "] failed! response body:", core.json.delay_encode(body))
        return core.response.exit(200, {message = body.reason})
    end
    core.log.info("user login [", request_debug, "] success! response body:", core.json.delay_encode(body))

    local userInfo = body.data.userInfo
    local wolf_token = body.data.token;

    local rbac_token = create_rbac_token(appid, wolf_token)
    core.response.exit(200, {rbac_token=rbac_token, user_info=userInfo})
end

function _M.api()
    return {
        {
            methods = {"POST"},
            uri = "/apisix/plugin/wolf-rbac/login",
            handler = login,
        }
    }
end


return _M
