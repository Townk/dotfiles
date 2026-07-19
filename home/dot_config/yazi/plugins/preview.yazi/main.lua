--- @since 26.5.6
-- preview.yazi — thin shim over ~/.local/bin/preview (the single preview
-- brain shared with fzf). Asks the script for a raster (--pixels) and
-- paints it with yazi's native image API, with the script's text block
-- below. Registered only for raster mimes; text types go through piper.

local M = {}

local SCRIPT = os.getenv 'HOME' .. '/.local/bin/preview'

local function fail(job, s)
  ya.preview_widget(job, ui.Text.parse(s):area(job.area):wrap(ui.Wrap.YES))
end

function M:peek(job)
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
  if raster ~= '' and fs.cha(Url(raster)) then
    local img_area = ui.Rect {
      x = area.x,
      y = area.y,
      w = area.w,
      h = text ~= '' and math.floor(area.h * 6 / 10) or area.h,
    }
    local rendered = ya.image_show(Url(raster), img_area)
    image_h = rendered and rendered.h or 0
  end

  -- Always claim the text widget, even when empty — otherwise a previous
  -- file's text lingers under an image-only preview.
  ya.preview_widget(job, {
    ui.Text
      .parse(text)
      :area(ui.Rect { x = area.x, y = area.y + image_h, w = area.w, h = area.h - image_h })
      :wrap(ui.Wrap.NO),
  })
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
