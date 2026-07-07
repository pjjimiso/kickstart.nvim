return {
  "zbirenbaum/copilot.lua",
  opts = {
    suggestion = {
      enabled = true,
      auto_trigger = true,
      -- Hide the ghost text while the blink.cmp menu is open, so <Tab> is
      -- unambiguous: it only accepts a Copilot suggestion when the menu is closed.
      hide_during_completion = true,
      keymap = {
        accept = "<Tab>", -- accept the full (possibly multi-line) inline suggestion
        next = "<M-]>",
        prev = "<M-[>",
      },
    },
    auth_provider_url = "https://intel-foundry.ghe.com/",
    filetypes = {
      markdown = true,
      help = true,
    },
  },
}
