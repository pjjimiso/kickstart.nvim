return {
  'zbirenbaum/copilot.lua',
  -- Loads on BOTH machines; only the auth endpoint differs (custom.machine):
  --   work      Intel GHE tenant (enterprise subscription)
  --   personal  regular github.com (personal subscription) — run :Copilot auth once
  opts = function()
    local opts = {
      suggestion = { enabled = false },
      panel = { enabled = false },
      filetypes = {
        markdown = true,
        help = true,
      },
    }
    if require('custom.machine').is_work() then
      opts.auth_provider_url = 'https://' .. require('custom.copilot_enterprise').host .. '/'
    end
    return opts
  end,
}
