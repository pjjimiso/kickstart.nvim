-- Markdown / Typst heading folding.
-- Adapted from https://github.com/linkarzu/dotfiles-latest (neobean/lua/config/keymaps.lua)

-- Called by Neovim's folding engine for each line of a markdown buffer.
function _G.markdown_foldexpr()
  local lnum = vim.v.lnum
  local line = vim.fn.getline(lnum)
  local heading = line:match '^(#+)%s'
  if heading then
    local level = #heading
    if level == 1 then
      if lnum == 1 then
        return '>1'
      else
        local frontmatter_end = vim.b.frontmatter_end
        if frontmatter_end and (lnum == frontmatter_end + 1) then
          return '>1'
        end
      end
    elseif level >= 2 and level <= 6 then
      return '>' .. level
    end
  end
  return '='
end

function _G.typst_foldexpr()
  local lnum = vim.v.lnum
  local line = vim.fn.getline(lnum)
  local heading = line:match '^(=+)%s'
  if heading then
    local level = #heading
    if level >= 1 and level <= 6 then
      return '>' .. level
    end
  end
  return '='
end

local function set_markdown_folding()
  vim.opt_local.foldmethod = 'expr'
  vim.opt_local.foldexpr = 'v:lua.markdown_foldexpr()'
  vim.opt_local.foldlevel = 99
  vim.opt_local.foldtext = ''

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local found_first = false
  local frontmatter_end = nil
  for i, line in ipairs(lines) do
    if line == '---' then
      if not found_first then
        found_first = true
      else
        frontmatter_end = i
        break
      end
    end
  end
  vim.b.frontmatter_end = frontmatter_end
end

local function set_typst_folding()
  vim.opt_local.foldmethod = 'expr'
  vim.opt_local.foldexpr = 'v:lua.typst_foldexpr()'
  vim.opt_local.foldlevel = 99
end

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'markdown',
  callback = set_markdown_folding,
})

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'typst',
  callback = set_typst_folding,
})

local function fold_headings_of_level(level)
  vim.cmd 'keepjumps normal! gg'
  local total_lines = vim.fn.line '$'
  for line = 1, total_lines do
    local line_content = vim.fn.getline(line)
    if vim.bo.filetype == 'typst' then
      if line_content:match('^' .. string.rep('=', level) .. '%s') then
        vim.cmd(string.format('keepjumps call cursor(%d, 1)', line))
        local current_foldlevel = vim.fn.foldlevel(line)
        if current_foldlevel > 0 then
          if vim.fn.foldclosed(line) == -1 then
            vim.cmd 'normal! za'
          end
        end
      end
    else
      if line_content:match('^' .. string.rep('#', level) .. '%s') then
        vim.cmd(string.format('keepjumps call cursor(%d, 1)', line))
        local current_foldlevel = vim.fn.foldlevel(line)
        if current_foldlevel > 0 then
          if vim.fn.foldclosed(line) == -1 then
            vim.cmd 'normal! za'
          end
        end
      end
    end
  end
end

local function fold_markdown_headings(levels)
  local saved_view = vim.fn.winsaveview()
  for _, level in ipairs(levels) do
    fold_headings_of_level(level)
  end
  vim.cmd 'nohlsearch'
  vim.fn.winrestview(saved_view)
end

vim.keymap.set('n', 'zj', function()
  vim.cmd 'silent update'
  vim.cmd 'edit!'
  vim.cmd 'normal! zR'
  fold_markdown_headings { 6, 5, 4, 3, 2, 1 }
  vim.cmd 'normal! zz'
end, { desc = '[P]Fold all headings level 1 or above' })

vim.keymap.set('n', 'zk', function()
  vim.cmd 'silent update'
  vim.cmd 'edit!'
  vim.cmd 'normal! zR'
  fold_markdown_headings { 6, 5, 4, 3, 2 }
  vim.cmd 'normal! zz'
end, { desc = '[P]Fold all headings level 2 or above' })

vim.keymap.set('n', 'zl', function()
  vim.cmd 'silent update'
  vim.cmd 'edit!'
  vim.cmd 'normal! zR'
  fold_markdown_headings { 6, 5, 4, 3 }
  vim.cmd 'normal! zz'
end, { desc = '[P]Fold all headings level 3 or above' })

vim.keymap.set('n', 'z;', function()
  vim.cmd 'silent update'
  vim.cmd 'edit!'
  vim.cmd 'normal! zR'
  fold_markdown_headings { 6, 5, 4 }
  vim.cmd 'normal! zz'
end, { desc = '[P]Fold all headings level 4 or above' })

vim.keymap.set('n', '<CR>', function()
  local line = vim.fn.line '.'
  local foldlevel = vim.fn.foldlevel(line)
  if foldlevel == 0 then
    vim.notify('No fold found', vim.log.levels.INFO)
  else
    vim.cmd 'normal! za'
    vim.cmd 'normal! zz'
  end
end, { desc = '[P]Toggle fold' })

vim.keymap.set('n', 'zu', function()
  vim.cmd 'silent update'
  vim.cmd 'edit!'
  vim.cmd 'normal! zR'
  vim.cmd 'normal! zz'
end, { desc = '[P]Unfold all headings level 2 or above' })

vim.keymap.set('n', 'zi', function()
  vim.cmd 'silent update'
  vim.cmd 'normal gk'
  vim.cmd 'normal! za'
  vim.cmd 'normal! zz'
end, { desc = '[P]Fold the heading cursor currently on' })
