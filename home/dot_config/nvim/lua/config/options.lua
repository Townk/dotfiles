--------------------------------------------------------------------------------
-- Global Options and Feature Toggles
--------------------------------------------------------------------------------
-- These options are loaded before lazy.nvim startup, so they affect plugin
-- initialization. LazyVim provides sensible defaults (see link below), and
-- we override specific options here.
--
-- Default LazyVim options:
--   https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
--
-- WHY each option is set:
--------------------------------------------------------------------------------

-- Disable auto-formatting on save (prefer manual formatting with <leader>cf)
-- WHY: Gives explicit control over when code is reformatted, avoiding unwanted
-- changes during rapid editing or when working with poorly-formatted codebases
vim.g.autoformat = false

-- Disable Snacks.nvim animations (dashboard, notifications, etc.)
-- WHY: Animations add visual delay and can cause flicker on some terminals.
-- Disabling improves perceived responsiveness and reduces visual noise.
vim.g.snacks_animate = false

-- Use blink.cmp as the main completion engine instead of nvim-cmp
-- WHY: blink.cmp is faster and has better snippet integration. This tells
-- LazyVim to configure blink.cmp properly instead of nvim-cmp.
vim.g.lazyvim_blink_main = true

-- Disable mini.pairs auto-pairing plugin (use nvim-autopairs instead)
-- WHY: nvim-autopairs has more robust behavior with certain edge cases and
-- better integration with blink.cmp's completion flow.
vim.g.minipairs_disable = true

-- Default comment-wrap width for the smart-comment-wrap local plugin
-- WHY: Without this, the plugin only activates when `comments_width` is set
-- via .editorconfig. Setting a global default makes auto-wrap work for any
-- file; per-project .editorconfig values still override it.
vim.g.comments_width = 80

-- Set Python LSP to basedpyright (instead of pyright)
-- WHY: basedpyright is a faster, more actively maintained fork of pyright
-- with better type inference and fewer false positives.
vim.g.lazyvim_python_lsp = "basedpyright"

-- Set Python linter/formatter to ruff (instead of pylint/black)
-- WHY: ruff is 10-100x faster than traditional Python tools and combines
-- linting + formatting in one tool, simplifying the toolchain.
vim.g.lazyvim_python_ruff = "ruff"

--------------------------------------------------------------------------------
-- Clipboard over SSH (OSC 52 copy out, reverse-tunnel paste in)
--------------------------------------------------------------------------------
-- WHY: LazyVim disables system-clipboard sync when SSH_CONNECTION is set
-- (`opt.clipboard = ""`) to avoid Neovim's built-in OSC 52 provider, whose
-- *paste* half queries the terminal and then hangs ("Waiting for OSC 52
-- response...") because Zellij deliberately refuses OSC 52 reads. The fallout:
-- plain `y` never reached the host clipboard, and `"*y` froze until Ctrl-C.
--
-- On SSH we re-enable `unnamedplus` and supply both halves explicitly:
--   copy  → write-only OSC 52: yanks travel up through WezTerm to the host
--           (Mac) clipboard. No terminal query, so no hang.
--   paste → read the host clipboard back through a reverse SSH tunnel instead
--           of OSC 52 (which Zellij refuses). The Mac runs a tiny listener
--           (clipboard-bridge launchd service) that serves `pbpaste`; SSH
--           reverse-forwards it to a user-only unix socket on this host (see
--           ~/.ssh/config.d/clipboard.config), and we read it with `nc -U`.
--           The socket lives under $HOME/.local/state/runtime/chezmoi-system/
--           (not directly in $HOME) so it doesn't clutter the home directory;
--           chezmoi creates that directory on apply.
--           When the tunnel is down (socket missing, no nc, or a non-tunnelled
--           SSH session) we fall back to the unnamed register, preserving the
--           old no-hang behavior. Gated to SSH so local Neovim keeps pbcopy.
if vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT or vim.env.SSH_TTY then
    vim.opt.clipboard = "unnamedplus"
    local osc52 = require("vim.ui.clipboard.osc52")
    local sock = (vim.env.HOME or "") .. "/.local/state/runtime/chezmoi-system/clipboard-bridge.sock"
    local uv = vim.uv or vim.loop
    local function paste()
        if vim.fn.executable("nc") == 1 and uv.fs_stat(sock) then
            local out = vim.fn.systemlist({ "nc", "-U", "-w", "1", sock })
            if vim.v.shell_error == 0 then
                return { out, "v" }
            end
        end
        return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
    end
    vim.g.clipboard = {
        name = "osc52-write-tunnel-read",
        copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
        paste = { ["+"] = paste, ["*"] = paste },
    }
end

-- Define the paths to add. Adjust the Homebrew path if necessary (e.g., to /usr/local/bin for Intel Macs).
local homebrew_bin = "/opt/homebrew/bin"
-- The default mise shims directory.
local mise_shims = vim.env.HOME .. "/.local/share/mise/shims"

-- Function to add a path to the environment PATH variable if it's not already present
local function add_to_path(path_to_add)
    -- Get the current PATH value
    local current_path = vim.env.PATH or ""

    -- Check if the path is already in the PATH string (handles both Windows and Unix path separators)
    if not string.find(current_path, path_to_add, 1, true) then
        -- Prepend the new path to prioritize Homebrew/mise binaries
        vim.env.PATH = path_to_add .. ":" .. current_path
    end
end

-- Add the specific paths
add_to_path(homebrew_bin)
add_to_path(mise_shims)

--------------------------------------------------------------------------------
-- Chezmoi / Go-template filetype detection
--------------------------------------------------------------------------------
-- WHY: Chezmoi source files end in `.tmpl` and use Go's text/template syntax
-- (`{{ if eq .profile "personal" }}…{{ end }}`) wrapped around an inner format
-- (JSON, TOML, shell, etc.). Without help, nvim treats them as a single
-- opaque filetype, losing JSON/TOML highlighting, indent, folds, and LSP.
--
-- We set a compound filetype like `json.gotmpl` so vim runs both ftplugins,
-- and register the `gotmpl` treesitter parser to handle these compound types
-- so template directives get their own highlighting while the surrounding
-- text inherits its native parser via gotmpl's injection queries.
--
-- Templates without a recognizable inner-language suffix (e.g. Brewfile.tmpl,
-- symlink_*.tmpl, .chezmoiignore.tmpl) fall back to plain `gotmpl`.
--------------------------------------------------------------------------------
-- Two non-obvious things about these patterns:
--   1) Don't include `$` at the end — vim.filetype.add wraps each user
--      pattern with `^...$` internally (see runtime/lua/vim/filetype.lua),
--      so a trailing `$` becomes a *literal* dollar character and never
--      matches a real filename.
--   2) Inner-language patterns need an explicit `priority` above 0 so the
--      specific match (`.json.tmpl` -> json.gotmpl) wins over the catch-all
--      (`.tmpl` -> gotmpl). Default priority is 0, ties are resolved by
--      table iteration order (i.e. unstable).
vim.filetype.add({
  -- Exact-basename matches go in the `filename` table; they win over
  -- the `pattern` table below without needing a priority. Use these
  -- for Ruby DSL files chezmoi templates (Brewfile, Gemfile, …) that
  -- have no extension before `.tmpl` to pattern-match on.
  filename = {
    ["Brewfile.tmpl"]  = "ruby.gotmpl",
    -- Plain-text package manifests with `# comments` and bare lines.
    -- `conf` has no treesitter parser, so the inner content falls back
    -- to classical vim syntax — fine for these formats.
    ["Cargofile.tmpl"] = "conf.gotmpl",
    ["Gofile.tmpl"]    = "conf.gotmpl",
    ["Npmfile.tmpl"]   = "conf.gotmpl",
    ["Uvfile.tmpl"]    = "conf.gotmpl",
  },
  pattern = {
    [".*%.json%.tmpl"]  = { "json.gotmpl",     { priority = 10 } },
    [".*%.jsonc%.tmpl"] = { "jsonc.gotmpl",    { priority = 10 } },
    [".*%.ya?ml%.tmpl"] = { "yaml.gotmpl",     { priority = 10 } },
    [".*%.toml%.tmpl"]  = { "toml.gotmpl",     { priority = 10 } },
    [".*%.sh%.tmpl"]    = { "bash.gotmpl",     { priority = 10 } },
    [".*%.bash%.tmpl"]  = { "bash.gotmpl",     { priority = 10 } },
    [".*%.zsh%.tmpl"]   = { "zsh.gotmpl",      { priority = 10 } },
    [".*%.lua%.tmpl"]   = { "lua.gotmpl",      { priority = 10 } },
    [".*%.py%.tmpl"]    = { "python.gotmpl",   { priority = 10 } },
    [".*%.rb%.tmpl"]    = { "ruby.gotmpl",     { priority = 10 } },
    [".*%.md%.tmpl"]    = { "markdown.gotmpl", { priority = 10 } },
    [".*%.kdl%.tmpl"]   = { "kdl.gotmpl",      { priority = 10 } },
    [".*%.tmpl"]        = "gotmpl",
  },
})

vim.treesitter.language.register("gotmpl", {
  "json.gotmpl",
  "jsonc.gotmpl",
  "yaml.gotmpl",
  "toml.gotmpl",
  "bash.gotmpl",
  "zsh.gotmpl",
  "lua.gotmpl",
  "python.gotmpl",
  "ruby.gotmpl",
  "markdown.gotmpl",
  "kdl.gotmpl",
  -- `conf` has no treesitter parser; this register makes treesitter
  -- enable the gotmpl parser for the compound filetype so `{{...}}`
  -- directives still get highlighted. The literal regions fall back
  -- to classical vim syntax.
  "conf.gotmpl",
})

-- Inject the inner language of compound filetypes (json.gotmpl, yaml.gotmpl,
-- toml.gotmpl, ...) into the gotmpl parser's literal `(text)` nodes so the
-- surrounding JSON/YAML/TOML is highlighted underneath the template directives.
-- Without this, gotmpl is the only parser running and the inner format renders
-- as plain text. The `(text)` nodes are exactly the non-`{{...}}` regions of
-- the buffer, so combining them yields one continuous virtual document in the
-- inner language. The companion query lives at
-- `after/queries/gotmpl/injections.scm`.
vim.treesitter.query.add_directive("inject-inner-ft!", function(_, _, source, _, metadata)
  if type(source) == "number" then
    local ft = vim.bo[source].filetype or ""
    local inner = ft:match("^(.-)%.gotmpl$")
    if inner and inner ~= "" then
      metadata["injection.language"] = inner
    end
  end
end, {})

