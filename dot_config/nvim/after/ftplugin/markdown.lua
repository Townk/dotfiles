--------------------------------------------------------------------------------
-- Markdown bullet-list wrap alignment
--------------------------------------------------------------------------------
-- Vim's stock markdown ftplugin sets:
--   comments=fb:*,fb:-,fb:+,n:>
--
-- The `fb:` entries make the `c`-flag wrap path treat `*`/`-`/`+` as comment
-- leaders. The `f` ("first line only") then suppresses the leader on
-- continuation lines — but as a side effect, vim also stops applying the
-- `n`-flag (`formatlistpat`) indent that would otherwise align the next line
-- under the text following the marker. Numbered lists don't appear in
-- `comments`, which is exactly why they already wrap with the right indent.
--
-- `formatlistpat` already matches `-`/`*`/`+`, so dropping the `fb:` entries
-- restores symmetric bullet/numbered behaviour for `gw` and insert-mode
-- auto-wrap. The blockquote entry (`n:>`) is preserved.
--
-- Known vim limitation (affects bullets AND numbered lists identically):
-- `n` only aligns the FIRST continuation line. If a single bullet wraps to
-- three or more lines, lines 3+ flatten back to column 0. Fixing that would
-- require a custom `formatexpr`.
--------------------------------------------------------------------------------
local kept = {}
for entry in vim.bo.comments:gmatch("[^,]+") do
  if not entry:match("^fb:[%-%*%+]$") then
    kept[#kept + 1] = entry
  end
end
vim.bo.comments = table.concat(kept, ",")

--------------------------------------------------------------------------------
-- Custom formatexpr for full list-continuation alignment
--------------------------------------------------------------------------------
-- The `comments` fix above gets the FIRST continuation line indented under
-- the marker, but vim's built-in formatter still flattens lines 3+. The
-- custom formatexpr in lua/utils/markdown_format.lua reformats the whole
-- list paragraph and indents EVERY continuation line; non-list paragraphs
-- (and insert-mode auto-wrap) fall back to the internal formatter.
--
-- Caveat: `gw` deliberately bypasses 'formatexpr' (vim quirk — only `gq`
-- honours it). The buffer-local remap below routes `gw` through `gq` so
-- both keys reach the custom formatter. Cursor handling differs slightly
-- (`gw` preserves position, `gq` may move it), but it's barely visible
-- for prose.
--------------------------------------------------------------------------------
vim.bo.formatexpr = "v:lua.require'utils.markdown_format'.format()"
vim.keymap.set({ "n", "x" }, "gw", "gq", {
  buffer = true,
  desc = "Format (via formatexpr)",
})

--------------------------------------------------------------------------------
-- Insert-mode auto-wrap: keep continuation lines indented past line 3
--------------------------------------------------------------------------------
-- Vim's `n` formatoption uses 'formatlistpat' to recognise list items and
-- indent the next line under the text following the marker — but only for
-- two or three continuation lines, after which it loses context and the
-- wrap collapses back to column 0. That hurts the most while typing inside
-- a long bullet: cursor jumps to column 0 partway through the paragraph.
--
-- Extending 'formatlistpat' with `^\s\s\+` makes vim treat ANY line starting
-- with two-or-more whitespace as a "list item" in its own right, so each
-- wrapped continuation line itself satisfies the pattern and the indent
-- propagates. Effects on the surrounding cases:
--   - Plain paragraphs (col-0 text): unaffected, no leading whitespace.
--   - Numbered lists: ALL continuation lines stay at the post-marker column,
--     not just the first one or two.
--   - Nested bullets / 4-space code-block indents: continuation indent is
--     preserved, which is what you want for prose; code blocks aren't
--     auto-wrapped anyway when textwidth=0 on those lines.
-- 'gq' / 'gw' still go through the custom formatexpr above; this only
-- affects vim's internal insert-mode auto-wrap path.
--------------------------------------------------------------------------------
vim.bo.formatlistpat = [[^\s*\d\+\.\s\+\|^\s*[-*+]\s\+\|^\s\s\+]]

--------------------------------------------------------------------------------
-- <C-CR>: Insert next list item / quote line
--------------------------------------------------------------------------------
-- In insert mode, Ctrl+Enter inserts a new line BELOW the cursor's line
-- (leaving the current line intact even when the cursor sits mid-content)
-- and drops the cursor at the start of the new line's content column. The
-- new line's prefix mirrors the enclosing list item or block quote:
--   `- foo`   →  `- ` on the next line
--   `* foo`   →  `* `
--   `+ foo`   →  `+ `
--   `1. foo`  →  `2. ` (number incremented)
--   `1) foo`  →  `2) `
--   `> foo`   →  `> ` (quotes repeat the marker on every line)
-- Indent is preserved, so nested bullets keep their depth.
--
-- Implementation: treesitter walks parents from the cursor to find the
-- enclosing `list_item` or `block_quote` node. That means it works on a
-- direct marker line OR anywhere inside a wrapped list item (the AST
-- already knows continuation lines belong to their parent item), and it
-- correctly ignores text that LOOKS like a list inside a fenced code
-- block (the AST puts that under `fenced_code_block`, not `list_item`).
-- Works for markdown.gotmpl compound filetypes too, since
-- `vim.treesitter.get_node` honours language injections.
--
-- Falls back to plain Enter if no list/quote ancestor is found, so vim's
-- native autoindent/commentstring still kicks in for non-list text.
--
-- Note: <C-CR> requires a terminal that distinguishes Ctrl+Enter from
-- plain Enter (kitty keyboard protocol, modifyOtherKeys, etc.).
--------------------------------------------------------------------------------
vim.keymap.set("i", "<C-CR>", function()
  local row = vim.fn.line(".")
  local col = vim.fn.col(".") - 1 -- treesitter positions are 0-indexed

  -- Find the smallest AST node at the cursor (handles markdown injected
  -- into other languages, e.g. our markdown.gotmpl compound filetype),
  -- then walk up looking for the enclosing list_item or block_quote. The
  -- AST already knows continuation lines belong to their parent item, so
  -- there's no manual walk-back the way the regex version had to do.
  local item_node, quote_node
  local ok, node = pcall(vim.treesitter.get_node, { pos = { row - 1, col } })
  if ok and node then
    while node do
      local t = node:type()
      if t == "list_item" then
        item_node = node
        break -- innermost list_item wins
      end
      if t == "block_quote" and not quote_node then
        quote_node = node
      end
      node = node:parent()
    end
  end

  -- Returns the 0-indexed buffer position at which `nvim_buf_set_lines`
  -- should insert a new sibling line — i.e. just past the node's last
  -- line. Treesitter ranges are end-exclusive: `(end_row, 0)` means the
  -- node ended at the end of `end_row - 1`, so we use `end_row` directly
  -- as the insert index. If the node ends mid-line, `end_row + 1` is the
  -- next line.
  local function insert_after(node)
    local _, _, end_row, end_col = node:range()
    if end_col == 0 then
      return end_row
    end
    return end_row + 1
  end

  local next_prefix
  local insert_idx
  if item_node then
    -- list_item's start position is the column of the marker. Read the
    -- marker text directly off the buffer line — the AST identifies the
    -- right item, the line gives us the literal marker (preserving
    -- whitespace and increment behaviour).
    local item_row, item_col = item_node:range()
    local line = vim.fn.getline(item_row + 1)
    local indent = line:sub(1, item_col)
    local after = line:sub(item_col + 1)
    local bullet = after:match("^([%-%*%+]%s+)")
    if bullet then
      next_prefix = indent .. bullet
    else
      local num, sep, sp = after:match("^(%d+)([%.%)])(%s+)")
      if num then
        next_prefix = indent .. tostring(tonumber(num) + 1) .. sep .. sp
      end
    end
    -- Insert AFTER the whole item, not after the cursor's line — when
    -- the cursor sits on a line that's not the item's last (mid-wrap, or
    -- before nested children), inserting at row+1 would split the item
    -- in two.
    insert_idx = insert_after(item_node)
  elseif quote_node then
    -- Block-quote marker repeats on every line (no increment). Read it
    -- off the quote's starting line so the cursor can be on any line in
    -- the quote — including a continuation.
    local q_row = quote_node:start()
    local line = vim.fn.getline(q_row + 1)
    local q_indent, qmark = line:match("^(%s*)(>%s*)")
    if qmark then
      next_prefix = q_indent .. qmark
    end
    insert_idx = insert_after(quote_node)
  end

  if next_prefix and insert_idx then
    -- Defer the buffer mutation: when nvim_buf_set_lines runs inside an
    -- insert-mode mapping, vim's internal cursor (the "where will the next
    -- typed char go" position) doesn't always re-sync with what
    -- nvim_win_set_cursor sets. vim.schedule pushes the work past the
    -- current event-loop tick so insert mode picks up the new cursor.
    vim.schedule(function()
      vim.api.nvim_buf_set_lines(0, insert_idx, insert_idx, false, { next_prefix })
      vim.api.nvim_win_set_cursor(0, { insert_idx + 1, #next_prefix })
    end)
  else
    -- No marker on the current line → defer to vim's native Enter so
    -- autoindent / commentstring behaviour stays intact.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, true, true), "n", false)
  end
end, { buffer = true, desc = "Insert next list item / quote line" })
