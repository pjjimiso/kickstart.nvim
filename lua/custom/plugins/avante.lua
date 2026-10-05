-- avante.nvim — enterprise Copilot + Claude Max (via ACP)
--
-- MACHINE SPLIT (custom.machine): on the work box the default provider is the GHE
-- copilot tenant; on the personal laptop it's claude-code (ACP -> claude CLI on the
-- personal Claude subscription) and all the enterprise-token plumbing is skipped.
--
-- 1. copilot — avante already has correct GHE Cloud support: providers/copilot.lua
--    derives the token-exchange URL from `endpoint`, so intel-foundry.ghe.com yields
--    https://api.intel-foundry.ghe.com/copilot_internal/v2/token. What it CANNOT do is
--    find the long-lived OAuth token: it reads the legacy plaintext
--    ~/.config/github-copilot/hosts.json, and copilot.lua v3 stores that token
--    ENCRYPTED in auth.db instead, so the file doesn't exist. Without it avante errors
--    with "You must setup copilot with either copilot.lua or copilot.vim".
--
--    custom.copilot_enterprise fills exactly that gap — it owns the device flow and
--    publishes hosts.json itself. No chat plugin required; run
--    :CopilotEnterpriseLogin once (it will silently adopt CopilotChat's cached token
--    if one is still lying around, so migrating costs no re-auth).
--
-- 2. claude-code (ACP) — avante spawns the claude-agent-acp adapter, which drives the
--    real `claude` CLI already logged into the Max subscription. No token handling in
--    Lua, no third-party use of subscription credentials. Requires:
--        npm install -g @agentclientprotocol/claude-agent-acp
--
-- PROXY: avante shells out via plenary.curl, so the lowercase https_proxy/no_proxy env
-- vars cover every request. Do NOT move the proxy into a `proxy = ...` provider field —
-- avante's Claude OAuth endpoints ignore that field. (The ACP route sidesteps the issue
-- entirely, since the claude CLI does its own networking.)

-- NOTE: custom.copilot_enterprise is required inside init/config rather than here.
-- lazy.nvim evaluates this file while building its spec tree, so a file-scope require
-- would pull the module (and plenary) into startup.

-- WORKAROUND (upstream avante bug): avante.config's __index only falls through to
-- _options when the key is ABSENT from the table, but providers.refresh() does a raw
-- `Config.provider = name` when switching to an ACP provider (providers/init.lua:234).
-- That raw key then shadows every later Config.override(), so switching *away* from
-- claude-code dies with "Failed to find provider: claude-code" — i.e. once you select an
-- ACP provider you can never leave it. Clearing the raw key restores the fallthrough.
local function switch_provider()
  rawset(require 'avante.config', 'provider', nil)
  vim.cmd 'AvanteSwitchProvider'
end

return {
  'yetone/avante.nvim',
  event = 'VeryLazy',
  -- Downloads prebuilt Rust libraries from GitHub releases; needs make + curl + tar and
  -- the Intel proxy reachable. If the prebuilt .so fails to load under NixOS, build from
  -- source instead: build = 'make BUILD_FROM_SOURCE=true' (adds a cargo dependency).
  build = 'make',
  dependencies = {
    { 'nvim-lua/plenary.nvim', branch = 'master' },
    'MunifTanjim/nui.nvim',
    'zbirenbaum/copilot.lua',
  },

  -- Runs at startup so :CopilotEnterpriseLogin exists before avante itself loads.
  -- Registered on every machine, not just detected-work ones: running it on a fresh
  -- work box is what flips custom.machine's detection to 'work' (via the token cache).
  init = function()
    require('custom.copilot_enterprise').setup()
  end,

  config = function()
    local is_work = require('custom.machine').is_work()

    -- ~/.npm-global/bin only reaches PATH in a fresh login shell (home-manager
    -- sessionPath), so resolve the ACP adapter up front and fall back to its known
    -- install path — otherwise it silently fails to spawn in an already-open session.
    local acp_cmd = vim.fn.exepath 'claude-agent-acp'
    if acp_cmd == '' then
      acp_cmd = vim.env.HOME .. '/.npm-global/bin/claude-agent-acp'
    end

    -- avante spawns ACP agents with a FROM-SCRATCH environment containing only PATH
    -- (libs/acp_client.lua:398-415), so anything the child needs must be listed here.
    -- Two omissions are fatal on this box: without HOME the claude CLI can't find its
    -- Max credentials under ~/.claude, and without the proxy vars every request hangs
    -- behind proxy-chain.intel.com — which is exactly the "spins forever" symptom.
    -- (avante's own codex default re-adds HOME/PATH for the same reason.)
    local function acp_env(extra)
      local env = {}
      for _, name in ipairs {
        'HOME',
        'USER',
        'LANG',
        'XDG_CONFIG_HOME',
        'XDG_DATA_HOME',
        'XDG_CACHE_HOME',
        'http_proxy',
        'https_proxy',
        'no_proxy',
        'all_proxy',
        'HTTP_PROXY',
        'HTTPS_PROXY',
        'NO_PROXY',
        'ALL_PROXY',
      } do
        local value = vim.env[name]
        if value and value ~= '' then
          env[name] = value
        end
      end
      return vim.tbl_extend('force', env, extra or {})
    end

    -- Publish the cached enterprise token as hosts.json before avante's copilot
    -- provider goes looking for it. No-ops when already in sync. Work machine only —
    -- the personal laptop has no GHE tenant to talk to.
    if is_work and not require('custom.copilot_enterprise').sync() then
      vim.notify('avante: no enterprise Copilot token — run :CopilotEnterpriseLogin', vim.log.levels.WARN)
    end

    require('avante').setup {
      -- Work: GHE Copilot. Personal: claude CLI over ACP (Max subscription).
      provider = is_work and 'copilot' or 'claude-code',

      providers = {
        -- Enterprise copilot config only exists on the work machine, so a stray
        -- :AvanteSwitchProvider copilot on the laptop can't half-work.
        copilot = is_work and {
          -- Drives _get_chat_auth_url() -> https://api.intel-foundry.ghe.com/copilot_internal/v2/token.
          -- If the tenant turns out to exchange on api.github.com instead (EMU routing),
          -- delete this line — the default endpoint routes there. avante commits to one
          -- host with no fallback, so this is the knob to flip if auth fails.
          endpoint = 'https://' .. require('custom.copilot_enterprise').host,
          model = 'claude-sonnet-5',
          -- proxy/allow_insecure intentionally unset: env https_proxy covers all paths.
        } or nil,

        -- Native Anthropic API provider. Not the active Claude path (ACP is, below), but
        -- pinned to Opus 5 so :AvanteSwitchProvider claude does the right thing.
        claude = {
          model = 'claude-opus-5',
        },
      },

      acp_providers = {
        ['claude-code'] = {
          command = acp_cmd,
          args = {},
          env = acp_env {
            NODE_NO_WARNINGS = '1',
            -- Default model for the Claude Code session.
            ANTHROPIC_MODEL = 'claude-opus-5',
            -- Point the adapter at the nix-profile claude CLI holding the Max login.
            ACP_PATH_TO_CLAUDE_CODE_EXECUTABLE = vim.fn.exepath 'claude',
            -- NOTE: deliberately NOT passing ANTHROPIC_API_KEY. If it were set, the CLI
            -- would bill the API instead of using the Max subscription credentials.
            -- avante's own default here is 'bypassPermissions' (no prompt before edits).
            ACP_PERMISSION_MODE = 'default',
          },
        },
      },

      -- Keymaps stay at avante's defaults (<leader>aa ask, <leader>ae edit,
      -- <leader>at toggle, ...). CopilotChat moved to <leader>c* to make room.
    }

    -- Replace avante's own :AvanteSwitchProvider with an ACP-safe version, so the fix
    -- applies however the switch is invoked, not just via <leader>ap. Body mirrors
    -- plugin/avante.lua; the only addition is the rawset. Scheduled so it lands after
    -- avante has sourced its plugin/ files and defined the original.
    vim.schedule(function()
      vim.api.nvim_create_user_command('AvanteSwitchProvider', function()
        local Config = require 'avante.config'
        rawset(Config, 'provider', nil)
        local providers = vim.tbl_keys(Config.providers)
        vim.list_extend(providers, vim.tbl_keys(Config.acp_providers))
        vim.ui.select(providers, { prompt = 'Provider> ' }, function(choice, idx)
          if idx ~= nil then
            require('avante.api').switch_provider(vim.trim(choice))
          end
        end)
      end, { nargs = 0, desc = 'avante: switch provider (ACP-safe)' })
    end)
  end,

  keys = {
    { '<leader>ap', switch_provider, desc = 'AI: avante switch provider' },
    { '<leader>am', '<cmd>AvanteModels<cr>', desc = 'AI: avante pick model' },
  },
}
