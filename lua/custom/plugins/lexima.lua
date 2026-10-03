return {
  'cohama/lexima.vim',
  -- No further initialization needed, as this is a real "vim" not a lua plugin
  init = function()
    -- Don't auto-insert the closing (, ", [, etc. when typing the opening one.
    -- Endwise rules (auto `end`/`endif`) are left enabled.
    vim.g.lexima_enable_basic_rules = 0
  end,
}
