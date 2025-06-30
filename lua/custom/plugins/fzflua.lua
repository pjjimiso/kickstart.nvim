return {
  'ibhagwan/fzf-lua',
  -- optional for icon support
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  -- or if using mini.icons/mini.nvim
  -- dependencies = { "echasnovski/mini.icons" },
  opts = {},
  keys = {
    {
      '<leader>ff',
      function()
        require('fzf-lua').files()
      end,
      desc = 'Find Files in project directory',
    },
    {
      '<leader>fg',
      function()
        require('fzf-lua').live_grep()
      end,
      desc = 'Find using grep in project directory',
    },
    {
      '<leader>fc',
      function()
        require('fzf-lua').files { cwd = vim.fn.stdpath 'config' }
      end,
      desc = 'Find in Neovim configuration directory',
    },
    {
      '<leader>ft',
      function()
        require('fzf-lua').tmux_buffers()
      end,
      desc = 'Find in Tmux buffers',
    },
    {
      '<leader>fb',
      function()
        require('fzf-lua').blines()
      end,
      desc = 'Find in current buffer',
    },
  },
}
