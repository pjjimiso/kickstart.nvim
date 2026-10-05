-- CopilotChat with enterprise (*.ghe.com) auth.
--
-- DEPRECATED: superseded by avante.nvim (see avante.lua). Kept only until that
-- migration settles — delete this file and its <leader>c* keymaps to finish the job.
--
-- The device flow and token cache that used to live here now live in
-- custom.copilot_enterprise, shared with avante. This file keeps only the part that is
-- genuinely CopilotChat-specific: exchanging the long-lived OAuth token for a
-- short-lived bearer and shaping CopilotChat's request headers. (CopilotChat v4.7.4
-- hardcodes github.com for that exchange, which is why the override is still needed.)

-- NOTE: custom.copilot_enterprise is required inside the functions below, not at file
-- scope — lazy.nvim evaluates this file when building its spec tree, and a file-scope
-- require would pull the module (and plenary) into startup.

-- oauth -> short-lived-bearer exchange hosts, tried in order. Enterprise first for a
-- data-residency tenant; api.github.com as a fallback for EMU/business routing.
local function exchange_hosts()
  return { 'api.' .. require('custom.copilot_enterprise').host, 'api.github.com' }
end

---Exchange an OAuth token for a short-lived Copilot bearer + resolved base URL.
---@return table|nil body, string|nil used_host, string|nil err
local function exchange(oauth)
  local curl = require 'CopilotChat.utils.curl'
  local last_err
  for _, host in ipairs(exchange_hosts()) do
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
  local oauth = require('custom.copilot_enterprise').token()
  assert(oauth, 'no enterprise Copilot token — run :CopilotEnterpriseLogin')

  local body, used_host, err = exchange(oauth)
  assert(body, 'CopilotChat token exchange failed (' .. tostring(err) .. '). Re-run :CopilotEnterpriseLogin if the token was revoked.')

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
  -- Work-only (enterprise tenant), and deprecated even there.
  cond = function()
    return require('custom.machine').is_work()
  end,
  dependencies = {
    'zbirenbaum/copilot.lua',
    { 'nvim-lua/plenary.nvim', branch = 'master' },
  },
  -- NOTE: intentionally NO `build = 'make tiktoken'` — luarocks isn't installed on this
  -- system, so token counts fall back to estimates.
  cmd = { 'CopilotChat', 'CopilotChatToggle', 'CopilotChatModels', 'CopilotChatPrompts' },
  opts = {
    model = 'claude-sonnet-5',
    providers = {
      copilot = {
        get_headers = enterprise_get_headers,
      },
    },
  },
  keys = {
    -- Moved off <leader>a*, which now belongs to avante.
    { '<leader>cc', '<cmd>CopilotChatToggle<cr>', desc = 'AI: toggle Copilot Chat (deprecated)' },
    { '<leader>cx', '<cmd>CopilotChatStop<cr>', desc = 'AI: stop Copilot Chat response' },
  },
}
