-- Copyright 2015-2016 CloudFlare
-- Copyright 2014-2015 Aaron Westendorf

local json = require("cjson")
local http = require("resty.http")

local uri         = ngx.var.uri
local uri_args    = ngx.req.get_uri_args()
local scheme      = ngx.var.scheme

local client_id         = ngx.var.ngo_client_id
local client_secret     = ngx.var.ngo_client_secret
local token_secret      = ngx.var.ngo_token_secret
local domain            = ngx.var.ngo_domain
local cb_scheme         = ngx.var.ngo_callback_scheme or scheme
local cb_server_name    = ngx.var.ngo_callback_host or ngx.var.server_name
local cb_uri            = ngx.var.ngo_callback_uri or "/_oauth"
local cb_url            = cb_scheme .. "://" .. cb_server_name .. cb_uri
local redirect_url      = cb_scheme .. "://" .. cb_server_name .. ngx.var.request_uri
local signout_uri       = ngx.var.ngo_signout_uri or "/_signout"
local extra_validity    = tonumber(ngx.var.ngo_extra_validity or "0")
local whitelist         = ngx.var.ngo_whitelist or ""
local blacklist         = ngx.var.ngo_blacklist or ""
local secure_cookies    = ngx.var.ngo_secure_cookies == "true" or false
local http_only_cookies = ngx.var.ngo_http_only_cookies == "true" or false
local set_user          = ngx.var.ngo_user or false
local set_email         = ngx.var.ngo_email or false
local set_name          = ngx.var.ngo_name or false
local email_as_user     = ngx.var.ngo_email_as_user == "true" or false
local set_groups        = ngx.var.ngo_groups or false
local allowed_groups    = ngx.var.ngo_allowed_groups or ""

if whitelist:len() == 0 then
  whitelist = nil
end

if blacklist:len() == 0 then
  blacklist = nil
end

if allowed_groups:len() == 0 then
  allowed_groups = nil
end

local function handle_token_uris(email, name, groups, token, expires)
  if uri == "/_token.json" then
    ngx.header["Content-type"] = "application/json; charset=utf-8"
    ngx.say(json.encode({
      email   = email,
      name    = name,
      groups  = groups,
      token   = token,
      expires = expires,
    }))
    ngx.exit(ngx.OK)
  end

  if uri == "/_token.txt" then
    ngx.header["Content-type"] = "text/plain; charset=utf-8"
    ngx.say("email: " .. email .. "\n" .. "name: " .. name .. "\n" .. "groups: " .. groups .. "\n" .. "token: " .. token .. "\n" .. "expires: " .. expires .. "\n")
    ngx.exit(ngx.OK)
  end

  if uri == "/_token.curl" then
    ngx.header["Content-type"] = "text/plain; charset=utf-8"
    ngx.say("-H \"OauthEmail: " .. email .. "\" -H \"OauthName: " .. name .. "\" -H \"OauthGroups: " .. groups .. "\" -H \"OauthAccessToken: " .. token .. "\" -H \"OauthExpires: " .. expires .. "\"\n")
    ngx.exit(ngx.OK)
  end
end


local function on_auth(email, name, groups, token, expires)
  local oauth_domain = email:match("[^@]+@(.+)")

  if not (whitelist or blacklist) then
    if domain:len() ~= 0 then
      if not string.find(" " .. domain .. " ", " " .. oauth_domain .. " ", 1, true) then
        ngx.log(ngx.ERR, email .. " is not on " .. domain)
        return ngx.exit(ngx.HTTP_FORBIDDEN)
      end
    end
  end

  if whitelist then
    if not string.find(" " .. whitelist .. " ", " " .. email .. " ", 1, true) then
      ngx.log(ngx.ERR, email .. " is not in whitelist")
      return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
  end

  if blacklist then
    if string.find(" " .. blacklist .. " ", " " .. email .. " ", 1, true) then
      ngx.log(ngx.ERR, email .. " is in blacklist")
      return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
  end

  if allowed_groups then
    local allow_group = false
    for group in groups:gmatch("%S+") do
      if string.find(" " .. allowed_groups .. " ", " " .. group .. " ", 1, true) then
        allow_group = true
	break
      end
    end
    if not allow_group then
      ngx.log(ngx.ERR, "none of the user groups (" .. groups .. ") are present in allowed_groups")
      return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
  end

  if set_user then
    if email_as_user then
      ngx.var.ngo_user = email
    else
      ngx.var.ngo_user = email:match("([^@]+)@.+")
    end
  end

  if set_email then
    ngx.var.ngo_email = email
  end

  if set_name then
    ngx.var.ngo_name = name
  end

  if set_groups then
    ngx.var.ngo_groups = groups
  end

  handle_token_uris(email, name, groups, token, expires)
end

local function request_access_token(code)
  local request = http.new()

  request:set_timeout(7000)

  local res, err = request:request_uri("https://accounts.google.com/o/oauth2/token", {
    method = "POST",
    body = ngx.encode_args({
      code          = code,
      client_id     = client_id,
      client_secret = client_secret,
      redirect_uri  = cb_url,
      grant_type    = "authorization_code",
    }),
    headers = {
      ["Content-type"] = "application/x-www-form-urlencoded"
    },
    ssl_verify = true,
  })
  if not res then
    return nil, (err or "auth token request failed: " .. (err or "unknown reason"))
  end

  if res.status ~= 200 then
    return nil, "received " .. res.status .. " from https://accounts.google.com/o/oauth2/token: " .. res.body
  end

  return json.decode(res.body)
end


local function request_directory_custom_groups(token, email)
  local request = http.new()

  request:set_timeout(7000)

  local res, err = request:request_uri("https://www.googleapis.com/admin/directory/v1/users/" .. email .. "?projection=full&viewType=domain_public", {
    headers = {
      ["Authorization"] = "Bearer " .. token,
    },
    ssl_verify = true,
  })
  if not res then
    return nil, "auth info request failed: " .. (err or "unknown reason")
  end

  if res.status ~= 200 then
    return nil, "received " .. res.status .. " from https://www.googleapis.com/admin/directory/v1/users/" .. email .. "?projection=full&viewType=domain_public"
  end

  local user_details = json.decode(res.body)
  local groups = ""
  for i, group in ipairs(user_details["customSchemas"]["BW_SAML"]["bwUserGroups"]) do
    groups = groups .. " " .. group["value"]
  end

  return groups
end

local function request_profile(token)
  local request = http.new()

  request:set_timeout(7000)

  local res, err = request:request_uri("https://www.googleapis.com/oauth2/v2/userinfo", {
    headers = {
      ["Authorization"] = "Bearer " .. token,
    },
    ssl_verify = true,
  })
  if not res then
    return nil, "auth info request failed: " .. (err or "unknown reason")
  end

  if res.status ~= 200 then
    return nil, "received " .. res.status .. " from https://www.googleapis.com/oauth2/v2/userinfo"
  end

  return json.decode(res.body)
end

local function is_authorized()
  local headers = ngx.req.get_headers()

  local expires = tonumber(ngx.var.cookie_OauthExpires) or 0
  local email   = ngx.unescape_uri(ngx.var.cookie_OauthEmail or "")
  local name    = ngx.unescape_uri(ngx.var.cookie_OauthName or "")
  local groups  = ngx.unescape_uri(ngx.var.cookie_OauthGroups or "")
  local token   = ngx.unescape_uri(ngx.var.cookie_OauthAccessToken or "")

  if expires == 0 and headers["oauthexpires"] then
    expires = tonumber(headers["oauthexpires"])
  end

  if email:len() == 0 and headers["oauthemail"] then
    email = headers["oauthemail"]
  end

  if name:len() == 0 and headers["oauthname"] then
    name = headers["oauthname"]
  end

  if groups:len() == 0 and headers["oauthgroups"] then
    groups = headers["oauthgroups"]
  end

  if token:len() == 0 and headers["oauthaccesstoken"] then
    token = headers["oauthaccesstoken"]
  end

  local expected_token = ngx.encode_base64(ngx.hmac_sha1(token_secret, cb_server_name .. email .. groups .. expires))

  if token == expected_token and expires and expires > ngx.time() - extra_validity then
    on_auth(email, name, groups, expected_token, expires)
    return true
  else
    return false
  end
end

local function redirect_to_auth()
  -- google seems to accept space separated domain list in the login_hint, so use this undocumented feature.
  return ngx.redirect("https://accounts.google.com/o/oauth2/auth?" .. ngx.encode_args({
    client_id     = client_id,
    scope         = "email profile https://www.googleapis.com/auth/admin.directory.user.readonly",
    response_type = "code",
    redirect_uri  = cb_url,
    state         = redirect_url,
    login_hint    = domain,
  }))
end

local function authorize()
  if uri ~= cb_uri then
    return redirect_to_auth()
  end

  if uri_args["error"] then
    ngx.log(ngx.ERR, "received " .. uri_args["error"] .. " from https://accounts.google.com/o/oauth2/auth")
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end

  local token, token_err = request_access_token(uri_args["code"])
  if not token then
    ngx.log(ngx.ERR, "got error during access token request: " .. token_err)
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end

  local profile, profile_err = request_profile(token["access_token"])
  if not profile then
    ngx.log(ngx.ERR, "got error during profile request: " .. profile_err)
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end

  local expires      = ngx.time() + token["expires_in"]
  local cookie_tail  = ";version=1;path=/;Max-Age=" .. extra_validity + token["expires_in"]
  if secure_cookies then
    cookie_tail = cookie_tail .. ";secure"
  end
  if http_only_cookies then
    cookie_tail = cookie_tail .. ";httponly"
  end

  local email      = profile["email"]
  local name       = profile["name"]

  local groups, groups_err = request_directory_custom_groups(token["access_token"], email)
  if not groups then
    ngx.log(ngx.ERR, "got error during groups request: " .. groups_err)
    groups = ""
  end

  local user_token = ngx.encode_base64(ngx.hmac_sha1(token_secret, cb_server_name .. email .. groups .. expires))

  on_auth(email, name, groups, user_token, expires)

  ngx.header["Set-Cookie"] = {
    "OauthEmail="       .. ngx.escape_uri(email) .. cookie_tail,
    "OauthName="        .. ngx.escape_uri(name) .. cookie_tail,
    "OauthGroups="      .. ngx.escape_uri(groups) .. cookie_tail,
    "OauthAccessToken=" .. ngx.escape_uri(user_token) .. cookie_tail,
    "OauthExpires="     .. expires .. cookie_tail,
  }

  return ngx.redirect(uri_args["state"])
end

local function handle_signout()
  if uri == signout_uri then
    ngx.header["Set-Cookie"] = "OauthAccessToken==deleted; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT"
    return ngx.redirect("/")
  end
end

handle_signout()

if not is_authorized() then
  authorize()
end

-- if already authenticated, but still receives a /_oauth request, redirect to the correct destination
if uri == "/_oauth" then
  return ngx.redirect(uri_args["state"])
end
