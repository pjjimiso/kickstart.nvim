-- Which machine this config is running on, for the AI-plugin split:
--   'work'     Intel box — GHE-tenant Copilot (suggestions + avante provider)
--   'personal' personal laptop — personal github.com Copilot for suggestions,
--              Claude Max via the claude CLI (ACP) as avante's provider
--
-- 'personal' is the default. Nothing environmental reliably distinguishes the two
-- (even /etc/hosts carries the intel.com FQDN on both, courtesy of shared NixOS
-- config), so the work box must opt in explicitly, by ONE of:
--
--   export NVIM_AI_PROFILE=work            # env var, e.g. home-manager sessionVariables
--   echo work > ~/.local/share/nvim/machine-profile   # per-machine file, never synced
--   :CopilotEnterpriseLogin                # its token cache marks the machine from then on

local M = {}

local profile

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

local function detect()
  local override = vim.env.NVIM_AI_PROFILE
  if override == 'work' or override == 'personal' then
    return override
  end

  -- stdpath('data') is per-machine state, not part of the synced config repo.
  local marker = read_file(vim.fn.stdpath 'data' .. '/machine-profile')
  if marker == 'work' or marker == 'personal' then
    return marker
  end

  -- The enterprise Copilot token cache is only ever minted on the work box, so once
  -- :CopilotEnterpriseLogin has run there this is automatic.
  if vim.loop.fs_stat(vim.fn.stdpath 'data' .. '/copilot-enterprise/oauth.txt') then
    return 'work'
  end

  return 'personal'
end

---@return 'work'|'personal'
function M.profile()
  if not profile then
    profile = detect()
  end
  return profile
end

---@return boolean
function M.is_work()
  return M.profile() == 'work'
end

return M
