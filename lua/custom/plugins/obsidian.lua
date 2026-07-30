return {
  'obsidian-nvim/obsidian.nvim',
  version = '*',
  ft = 'markdown', -- load when you open a markdown file
  opts = {
    legacy_commands = false, -- use the modern `:Obsidian <subcommand>` interface
    workspaces = {
      { name = 'personal', path = '~/pj_notes' }, -- Obsidian Sync vault
      { name = 'work', path = '~/work_notes' }, -- OneDrive work vault
    },
  },
}
