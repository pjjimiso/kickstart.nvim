return {
  'OXY2DEV/markview.nvim',
  lazy = false,
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'echasnovski/mini.icons',
  },
  opts = {},
  config = function(_, opts)
    require('markview').setup(opts)

    -- Buffer-local keymap for toggling Markview in Normal mode
    vim.api.nvim_create_autocmd('FileType', {
      pattern = { 'markdown' },
      callback = function(event)
        vim.keymap.set('n', '<leader>mt', '<cmd>Markview toggle<CR>', { buffer = event.buf, desc = '[M]arkdown [T]oggle' })
      end,
    })
  end,
}
