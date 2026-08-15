-- Enterprise GitHub Copilot auth for GHE data-residency tenants (*.ghe.com).
--
-- WHY THIS EXISTS
-- Consumers of Copilot's REST API (avante.nvim, CopilotChat, ...) expect a long-lived
-- OAuth token in the legacy plaintext ~/.config/github-copilot/hosts.json. The modern
-- Copilot Language Server used by copilot.lua v3 stores that token ENCRYPTED in
-- auth.db and offers no way to read it back, so that file no longer exists.
--
-- This module owns the missing half independently of any chat plugin: it runs the
-- device flow against the enterprise host, caches the resulting token, and publishes
-- it as hosts.json. It deliberately does NOT do the short-lived bearer exchange —
-- avante's copilot provider already derives the correct
-- https://api.<tenant>.ghe.com/copilot_internal/v2/token endpoint on its own.
--
-- USAGE
--   :CopilotEnterpriseLogin    run/re-run the device flow (interactive, one-time)
--   :CopilotEnterpriseStatus   show where the token came from and where it's published

-- NOTE: plenary.curl is required lazily inside the two functions that need it. Requiring
-- it at file scope would drag plenary into startup, since the plugin specs load this
-- module while building the lazy.nvim spec tree.

local M = {}

-- Device-flow / OAuth host for the tenant. The only tenant-specific knob.
M.host = 'intel-foundry.ghe.com'

-- GitHub Copilot's editor OAuth app. Same client id copilot.lua uses; not a secret.
M.client_id = 'Iv1.b507a08c87ecfe98'

-- Copilot's device flow uses an empty scope.
M.scope = ''

-- Our own token cache. Plaintext, 0600 — same trust model as the hosts.json we publish.
M.cache_path = vim.fn.stdpath 'data' .. '/copilot-enterprise/oauth.txt'

-- Token caches written by plugins we may be replacing. Read once, so migrating off
-- them doesn't force a re-authentication. Nothing here is required to exist.
M.legacy_cache_paths = {
  vim.fn.stdpath 'data' .. '/copilot_chat_enterprise/oauth.txt',
}

---Mirror of avante's providers/copilot.lua config-dir resolution, so we publish
---hosts.json exactly where it looks for it.
---@return string
local function config_dir()
  local xdg = vim.fn.expand '$XDG_CONFIG_HOME'
  if xdg and xdg ~= '$XDG_CONFIG_HOME' and vim.fn.isdirectory(xdg) > 0 then
    return xdg
  end
  return vim.fn.expand '~/.config'
end

---@return string
function M.hosts_json_path()
  return config_dir() .. '/github-copilot/hosts.json'
end

---@param path string
---@return string|nil
local function read_file(path)
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local body = vim.trim(fd:read '*a' or '')
  fd:close()
  return body ~= '' and body or nil
end

---Write `body` to `path` with 0600 permissions, creating parent dirs.
---@param path string
---@param body string
---@return boolean
local function write_private(path, body)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':p:h'), 'p')
  local fd = io.open(path, 'w')
  if not fd then
    return false
  end
  fd:write(body)
  fd:close()
  pcall(vim.loop.fs_chmod, path, 384) -- 0600
  return true
end

---The cached OAuth token, adopting a legacy plugin's cache on first run.
---@return string|nil token
---@return string|nil source  path the token was read from
function M.token()
  local cached = read_file(M.cache_path)
  if cached then
    return cached, M.cache_path
  end

  for _, legacy in ipairs(M.legacy_cache_paths) do
    local token = read_file(legacy)
    if token then
      write_private(M.cache_path, token) -- adopt it; the legacy plugin can now be removed
      return token, legacy
    end
  end

  return nil, nil
end

---The token hosts.json currently advertises for our tenant, if any.
---@return string|nil
local function published_token()
  local body = read_file(M.hosts_json_path())
  if not body then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= 'table' then
    return nil
  end
  local entry = decoded[M.host]
  return type(entry) == 'table' and entry.oauth_token or nil
end

---Publish `token` as hosts.json in the shape Copilot API consumers expect.
---@param token string
---@return boolean
function M.publish(token)
  local payload = vim.json.encode {
    [M.host] = { user = vim.env.USER or 'unknown', oauth_token = token },
  }
  return write_private(M.hosts_json_path(), payload)
end

---Ensure hosts.json matches the cached token. Idempotent and cheap: rewrites only
---when they differ, so a rotated token propagates but an unchanged one costs nothing.
---Safe to call on every startup.
---@return boolean published  whether a usable token is now published
function M.sync()
  local token = M.token()
  if not token then
    return false
  end
  if published_token() == token then
    return true
  end
  return M.publish(token)
end

---Block for `ms`, pumping the event loop. Returns false if the user pressed <C-c>.
---@param ms integer
---@return boolean
local function sleep(ms)
  local _, reason = vim.wait(ms, function()
    return false
  end, 100)
  return reason ~= -2 -- -2 is interrupted; -1 is the timeout we want
end

---@return table device  decoded device/code response
local function request_device_code()
  local curl = require 'plenary.curl'
  local res = curl.post('https://' .. M.host .. '/login/device/code', {
    body = { client_id = M.client_id, scope = M.scope },
    headers = { accept = 'application/json' },
  })
  assert(res and res.status == 200, ('device/code failed on %s: HTTP %s %s'):format(M.host, res and res.status, res and res.body))

  local ok, device = pcall(vim.json.decode, res.body)
  assert(ok and type(device) == 'table' and device.device_code, 'unexpected device/code response: ' .. tostring(res.body))
  return device
end

---Poll the token endpoint until the user authorizes, or the code expires.
---@param device table
---@return string token
local function poll_for_token(device)
  local curl = require 'plenary.curl'
  local interval = math.max(tonumber(device.interval) or 5, 1)
  local waited, deadline = 0, tonumber(device.expires_in) or 900

  while waited < deadline do
    if not sleep(interval * 1000) then
      error 'cancelled'
    end
    waited = waited + interval

    local res = curl.post('https://' .. M.host .. '/login/oauth/access_token', {
      body = {
        client_id = M.client_id,
        device_code = device.device_code,
        grant_type = 'urn:ietf:params:oauth:grant-type:device_code',
      },
      headers = { accept = 'application/json' },
    })

    local ok, data = pcall(vim.json.decode, res and res.body or '')
    data = (ok and type(data) == 'table') and data or {}

    if data.access_token then
      return data.access_token
    elseif data.error == 'authorization_pending' then
      -- keep waiting
    elseif data.error == 'slow_down' then
      interval = tonumber(data.interval) or (interval + 5)
    else
      error('device-flow error: ' .. tostring(data.error_description or data.error or (res and res.body)))
    end
  end

  error(('device flow timed out after %ds'):format(deadline))
end

---Run the interactive device flow, then cache and publish the token.
---@return boolean ok
function M.login()
  local ok, err = pcall(function()
    local device = request_device_code()
    local uri = device.verification_uri or ('https://' .. M.host .. '/login/device')

    pcall(vim.fn.setreg, '+', device.user_code)
    vim.notify(
      ('Copilot enterprise sign-in\n  open: %s\n  code: %s  (copied to +)\n\nWaiting for authorization — <C-c> to cancel.'):format(uri, device.user_code),
      vim.log.levels.WARN
    )
    pcall(vim.ui.open, uri)

    local token = poll_for_token(device)
    assert(write_private(M.cache_path, token), 'could not write ' .. M.cache_path)
    assert(M.publish(token), 'could not write ' .. M.hosts_json_path())
  end)

  if not ok then
    vim.notify('Copilot enterprise sign-in failed: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  vim.notify('Copilot enterprise sign-in complete. Published ' .. M.hosts_json_path(), vim.log.levels.INFO)
  return true
end

function M.status()
  local token, source = M.token()
  local lines = {
    'host:      ' .. M.host,
    'token:     ' .. (token and ('present (%d chars) from %s'):format(#token, source) or 'MISSING — run :CopilotEnterpriseLogin'),
    'published: ' .. (published_token() == token and token ~= nil and 'yes' or 'no') .. ' -> ' .. M.hosts_json_path(),
  }
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
end

---Register user commands. Idempotent.
function M.setup()
  vim.api.nvim_create_user_command('CopilotEnterpriseLogin', function()
    M.login()
  end, { desc = 'Run the enterprise Copilot device flow and publish hosts.json' })

  vim.api.nvim_create_user_command('CopilotEnterpriseStatus', function()
    M.status()
  end, { desc = 'Show enterprise Copilot token/publish status' })
end

return M
