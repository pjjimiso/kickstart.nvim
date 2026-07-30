-- Enterprise (GitHub Enterprise Cloud data-residency, *.ghe.com) auth for CopilotChat.
--
-- WHY THIS EXISTS: the modern Copilot Language Server (used by copilot.lua v3) stores
-- its OAuth token ENCRYPTED in ~/.config/github-copilot/auth.db (SQLite, token_ciphertext),
-- decryptable only by that server. CopilotChat v4.7.4 instead expects a legacy plaintext
-- apps.json/hosts.json (gone) and hardcodes github.com for both device-flow sign-in and
-- token exchange. So CopilotChat cannot reuse copilot.lua's credentials and must sign in
-- INDEPENDENTLY against the enterprise host. This override reimplements just that: a device
-- flow + token exchange pointed at your tenant, caching CopilotChat's own token.
--
-- ITERATION KNOBS: the three constants below are the only things likely to need tweaking if
-- the first sign-in errors. The device-flow error body is surfaced verbatim so we can adjust.

local AUTH_HOST = 'intel-foundry.ghe.com' -- device-flow / oauth host (copilot.lua's auth_provider_url)
local CLIENT_ID = 'Iv1.b507a08c87ecfe98' -- GitHub Copilot's editor OAuth app (same id copilot.lua uses)
local SCOPE = '' -- copilot device flow uses an empty scope
-- oauth -> short-lived-bearer exchange hosts, tried in order. Enterprise first for a
-- data-residency tenant; api.github.com as a fallback for EMU/business routing.
local EXCHANGE_HOSTS = { 'api.' .. AUTH_HOST, 'api.github.com' }

-- Where we cache CopilotChat's own long-lived enterprise OAuth token (plaintext, same
-- trust model as CopilotChat's built-in tokens.json).
local OAUTH_CACHE = vim.fn.stdpath 'data' .. '/copilot_chat_enterprise/oauth.txt'

local function read_cached_oauth()
  local fd = io.open(OAUTH_CACHE, 'r')
  if not fd then
    return nil
  end
  local tok = vim.trim(fd:read '*a' or '')
  fd:close()
  return tok ~= '' and tok or nil
end

local function write_cached_oauth(tok)
  vim.fn.mkdir(vim.fn.fnamemodify(OAUTH_CACHE, ':p:h'), 'p')
  local fd = io.open(OAUTH_CACHE, 'w')
  if fd then
    fd:write(tok)
    fd:close()
    -- keep the token file private
    pcall(vim.loop.fs_chmod, OAUTH_CACHE, 384) -- 0600
  end
end

-- Interactive device flow against the ENTERPRISE host. Returns the OAuth token.
local function enterprise_device_flow()
  local curl = require 'CopilotChat.utils.curl'
  local sleep = require('plenary.async.util').sleep
  local notify = require 'CopilotChat.utils.notify'

  -- 1. Request a device + user code.
  local res, err = curl.post('https://' .. AUTH_HOST .. '/login/device/code', {
    body = { client_id = CLIENT_ID, scope = SCOPE },
    headers = { ['Accept'] = 'application/json' },
  })
  assert(not err, 'device/code request failed (host ' .. AUTH_HOST .. '): ' .. tostring(err))
  local ok, code = pcall(vim.json.decode, res.body)
  assert(ok and code and code.device_code, 'unexpected device/code response: ' .. tostring(res.body))

  -- 2. Show the user where to authorize.
  local verify = code.verification_uri or ('https://' .. AUTH_HOST .. '/login/device')
  notify.publish(notify.MESSAGE, '[copilot-enterprise] Visit ' .. verify .. ' and enter code: ' .. code.user_code)
  notify.publish(notify.STATUS, '[copilot-enterprise] Waiting for authorization...')
  vim.schedule(function()
    vim.notify('CopilotChat enterprise sign-in:\n  ' .. verify .. '\n  code: ' .. code.user_code, vim.log.levels.WARN)
  end)

  -- 3. Poll for the token.
  local interval = math.max(code.interval or 5, 1)
  local deadline = (code.expires_in or 900)
  local waited = 0
  while waited < deadline do
    sleep(interval * 1000)
    waited = waited + interval
    local presp = curl.post('https://' .. AUTH_HOST .. '/login/oauth/access_token', {
      json_response = true,
      body = {
        client_id = CLIENT_ID,
        device_code = code.device_code,
        grant_type = 'urn:ietf:params:oauth:grant-type:device_code',
      },
      headers = { ['Accept'] = 'application/json' },
    })
    local data = presp and presp.body
    if type(data) == 'string' then
      local dok, decoded = pcall(vim.json.decode, data)
      data = dok and decoded or {}
    end
    data = data or {}
    if data.access_token then
      notify.publish(notify.MESSAGE, '')
      notify.publish(notify.STATUS, '')
      return data.access_token
    elseif data.error == 'authorization_pending' then
    -- keep waiting
    elseif data.error == 'slow_down' then
      interval = interval + (data.interval and 0 or 5)
      if data.interval then
        interval = data.interval
      end
    else
      error('enterprise device-flow error: ' .. tostring(data.error or vim.inspect(data)))
    end
  end
  error('enterprise device-flow timed out after ' .. deadline .. 's')
end

local function get_enterprise_oauth(force)
  if not force then
    local cached = read_cached_oauth()
    if cached then
      return cached
    end
  end
  local tok = enterprise_device_flow()
  write_cached_oauth(tok)
  return tok
end

-- Exchange an OAuth token for a short-lived Copilot bearer + resolved base URL.
-- Returns (token_body, used_host) or (nil, nil, err).
local function exchange(oauth)
  local curl = require 'CopilotChat.utils.curl'
  local last_err
  for _, host in ipairs(EXCHANGE_HOSTS) do
    local response, err = curl.get('https://' .. host .. '/copilot_internal/v2/token', {
      json_response = true,
      headers = { ['Authorization'] = 'Token ' .. oauth },
    })
    if not err and response and response.body and response.body.token then
      return response.body, host
    end
    last_err = err or ('no token from ' .. host)
  end
  return nil, nil, last_err
end

local function enterprise_get_headers()
  -- Try cached OAuth token first; if the exchange rejects it (revoked/expired), force a
  -- fresh device-flow sign-in exactly once.
  local oauth = get_enterprise_oauth(false)
  local body, used_host, err = exchange(oauth)
  if not body then
    oauth = get_enterprise_oauth(true)
    body, used_host, err = exchange(oauth)
  end
  assert(body, 'CopilotChat enterprise token exchange failed: ' .. tostring(err))

  local base_url = (body.endpoints and body.endpoints.api and body.endpoints.api:gsub('/$', '')) or 'https://api.githubcopilot.com'
  vim.schedule(function()
    vim.notify('CopilotChat: authed via ' .. used_host .. ' -> ' .. base_url, vim.log.levels.INFO)
  end)

  local v = vim.version()
  return {
    ['Authorization'] = 'Bearer ' .. body.token,
    ['Editor-Version'] = string.format('Neovim/%d.%d.%d', v.major, v.minor, v.patch),
    ['Editor-Plugin-Version'] = 'CopilotChat.nvim/*',
    ['Copilot-Integration-Id'] = 'vscode-chat',
    ['x-github-api-version'] = '2025-10-01',
    ['x-copilot-base-url'] = base_url,
  },
    body.expires_at
end

return {
  'CopilotC-Nvim/CopilotChat.nvim',
  dependencies = {
    'zbirenbaum/copilot.lua',
    { 'nvim-lua/plenary.nvim', branch = 'master' },
  },
  -- NOTE: intentionally NO `build = 'make tiktoken'` — `make`/luarocks aren't
  -- installed on this system, so token counts fall back to estimates.
  cmd = { 'CopilotChat', 'CopilotChatToggle', 'CopilotChatModels', 'CopilotChatPrompts' },
  opts = {
    model = 'claude-sonnet-5',
    providers = {
      copilot = {
        get_headers = enterprise_get_headers,
      },
    },
    -- model is left to the interactive picker (:CopilotChatModels) for now
    -- once you pick one, pin it here as `model = '<id>'`
  },
  keys = {
    { '<leader>aa', '<cmd>CopilotChatToggle<cr>', desc = 'AI: toggle Copilot Chat' },
    { '<leader>ax', '<cmd>CopilotChatStop<cr>', desc = 'AI: stop current response' },
  },
}
