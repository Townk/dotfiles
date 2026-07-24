--- @since 26.5.6
-- preview-shim.yazi — thin shim over ~/.local/bin/preview (the single
-- preview brain shared with fzf). Asks the script for a raster (--pixels)
-- and paints it with yazi's native image API, with the script's text block
-- below. Registered only for raster mimes; text types go through piper.
--
-- Named "preview-shim" deliberately: the name "preview" collides with a
-- yazi-internal module, which silently shadows a user plugin — peek then
-- dies with "error converting Lua nil to table" and preload tasks never
-- complete.

local M = {}

local SCRIPT = os.getenv 'HOME' .. '/.local/bin/preview'

local function fail(job, s)
  ya.preview_widget(job, ui.Text.parse(s):area(job.area):wrap(ui.Wrap.YES))
end

-- Direct-to-tty sixel branch (tmux with a sixel-capable OUTER terminal, e.g.
-- WezTerm): yazi's own adapter picks Iip here, whose passthrough overlay tmux
-- wipes on every repaint (upstream sxyazi/yazi#2689/#1064 territory). Native
-- sixel written straight to the tty goes through tmux's grid instead:
-- pane-local coordinates, and tmux owns + redraws the placement. Ratatui only
-- repaints diffed cells, so the blank image region stays untouched between
-- frames and the placement survives; hovering a text file rewrites the cells
-- and clears it naturally. The 50ms delay lets yazi's frame (which blanks the
-- region) land before the sixel does.
local tty_sixel -- nil = undecided; cached after first probe
local function use_tty_sixel()
  if tty_sixel == nil then
    tty_sixel = false
    if os.getenv 'TMUX' then
      local out = Command('zsh')
        :arg({ '-fc', 'source "$HOME/.local/lib/image-protocol-support.zsh"; get_terminal_image_protocol' })
        :stdout(Command.PIPED)
        :stderr(Command.NULL)
        :output()
      tty_sixel = (out and out.status.success and out.stdout:find 'Sixel') and true or false
    end
  end
  return tty_sixel
end

local function draw_tty_sixel(raster, rect)
  -- Synchronous (wait): the caller sequences this AFTER yazi's frame has
  -- settled; an async fire-and-forget here could interleave with a newer
  -- peek's draw.
  -- ECH-erase every row of the rect first: writing over the cells destroys
  -- the previous placement tmux-side and marks the region dirty, so tmux
  -- re-transmits it to the client — without this, a new sixel with an
  -- IDENTICAL footprint lands on "unchanged" cells and tmux's client diff
  -- never repaints it (the old image stays on glass).
  -- The whole draw (erase + CUP + sixel + restore) is assembled in a temp
  -- file and written to the tty in ONE dd pass: chafa streaming a multi-
  -- hundred-KB DCS in small chunks straight at the pty races yazi's own
  -- renderer writes, and a yazi chunk landing mid-DCS corrupts the image
  -- (verified: the same draws work under script(1)'s serializing relay).
  local row0, col0 = rect.y + 1, rect.x + 1
  local script = string.format(
    [[t=$(mktemp) || exit 1; { printf '\0337'; i=0; while [ "$i" -lt %d ]; do printf '\033[%%d;%dH\033[%dX' $((%d + i)); i=$((i+1)); done; printf '\033[%d;%dH'; chafa -f sixel --passthrough none --probe off -s %dx%d "$1" 2>/dev/null; printf '\0338'; } >"$t"; dd if="$t" of=/dev/tty bs=4m 2>/dev/null; rm -f "$t"]],
    rect.h, -- loop count
    col0, -- ECH cursor column (row is the shell-computed %d)
    rect.w, -- ECH width
    row0, -- ECH row base for $((row0 + i))
    row0, -- CUP row for the sixel
    col0, -- CUP col for the sixel
    rect.w, -- chafa cell width
    rect.h -- chafa cell height
  )
  local child = Command('sh'):arg({ '-c', script, 'sh', tostring(raster) }):spawn()
  if child then
    child:wait()
  end
end

local function peek_impl(job)
  local output, err = Command(SCRIPT)
    :arg({
      '--pixels',
      '--skip',
      tostring(job.skip),
      '-W',
      tostring(job.area.w),
      '-H',
      tostring(job.area.h),
      tostring(job.file.path),
    })
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :output()

  if not output then
    return fail(job, 'preview: ' .. tostring(err))
  end
  if not output.status.success then
    return fail(job, 'preview exited ' .. tostring(output.status.code) .. '\n' .. output.stderr)
  end

  local raster, text = output.stdout:match '^([^\n]*)\n(.*)$'
  raster = raster or ''
  text = text or ''

  local area = job.area
  local image_h = 0
  local tty_draw_area
  if raster ~= '' and fs.cha(Url(raster)) then
    -- Give the image every row the text block doesn't need, floored at
    -- half the pane (same split the old mediainfo plugin used).
    local text_h = 0
    if text ~= '' then
      local _, newlines = text:gsub('\n', '')
      text_h = newlines + 1
    end
    local img_h = area.h
    if text_h > 0 then
      img_h = math.max(math.floor(area.h / 2), area.h - text_h)
    end
    local img_area = ui.Rect {
      x = area.x,
      y = area.y,
      w = area.w,
      h = img_h,
    }
    if use_tty_sixel() then
      -- Defer the actual draw to after the text widget is queued (below):
      -- the frame that paints it also blanks the image region, and any
      -- frame landing AFTER our sixel would wipe the tmux placement.
      tty_draw_area = img_area
      image_h = img_h
    else
      local rendered = ya.image_show(Url(raster), img_area)
      image_h = rendered and rendered.h or 0
    end
  end

  -- Always claim the text widget, even when empty — otherwise a previous
  -- file's text lingers under an image-only preview.
  ya.preview_widget(job, {
    ui.Text
      .parse(text)
      :area(ui.Rect { x = area.x, y = area.y + image_h, w = area.w, h = area.h - image_h })
      :wrap(ui.Wrap.NO),
  })

  if tty_draw_area then
    -- Let the widget frame (which blanks the region via ratatui's cell diff)
    -- land first, THEN place the sixel — tmux owns the placement from there
    -- and later no-op frames don't touch the (unchanged, blank) cells under
    -- it. ya.sleep is an await point: if the user has hovered on, yazi
    -- cancels this superseded peek task here, so stale draws never fire.
    ya.sleep(0.15)
    draw_tty_sixel(raster, tty_draw_area)
  end
end

-- pcall guard: a Lua error inside peek paints a readable traceback in the
-- pane instead of yazi's terse "Lua error during peek" toast.
function M:peek(job)
  local ok, perr = pcall(peek_impl, job)
  if not ok then
    fail(job, 'preview-shim peek error:\n' .. tostring(perr))
  end
end

-- Seek pages/frames: bump skip and re-peek (same shape as yazi's built-in
-- video/pdf previewers). The script clamps: pdf sticks on the last page,
-- video caps at 95%.
function M:seek(job)
  local h = cx.active.current.hovered
  if h and h.url == job.file.url then
    ya.emit('peek', {
      math.max(0, cx.active.preview.skip + job.units),
      only_if = job.file.url,
    })
  end
end

-- Preloader: warm the raster cache while the file is still just hovered
-- nearby (replaces the mediainfo plugin's preloader role).
function M:preload(job)
  local output = Command(SCRIPT)
    :arg({ '--pixels', '--skip', '0', tostring(job.file.path) })
    :stdout(Command.NULL)
    :stderr(Command.NULL)
    :output()
  return output ~= nil
end

return M
