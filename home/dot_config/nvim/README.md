# NeoVim Configuration

A customized NeoVim setup based on [LazyVim](https://github.com/LazyVim/LazyVim), optimized for development productivity with intelligent tooling, custom UI enhancements, and workflow automation.

## 📚 Architecture Overview

This configuration follows LazyVim's modular structure with custom extensions:

```
~/.config/nvim/
├── init.lua                      # Entry point - bootstraps lazy.nvim
├── README.md                     # This file
│
├── lua/
│   ├── config/                   # Core NeoVim configuration
│   │   ├── lazy.lua              # lazy.nvim plugin manager setup
│   │   ├── options.lua           # Vim options and global settings
│   │   ├── keymaps.lua           # Custom keybindings
│   │   └── autocmds.lua          # Autocommands for behavior automation
│   │
│   ├── plugins/                  # Plugin specifications (lazy.nvim format)
│   │   ├── core.lua              # UI/UX plugins (colorscheme, statusline, dashboard)
│   │   ├── editor.lua            # Editor enhancements (auto-save, alignment, movement)
│   │   ├── coding.lua            # Development tools (LSP, completion, debugging)
│   │   ├── ai.lua                # AI assistant integration (OpenCode)
│   │   ├── git.lua               # Git tooling (Neogit, blame)
│   │   ├── nav.lua               # Navigation helpers (smart-splits)
│   │   └── markdown.lua          # Markdown preview (Peek)
│   │
│   └── lualine/                  # Custom statusline configuration
│       ├── themes/
│       │   └── doom-modeline.lua # Custom theme with dynamic color extraction
│       └── components/           # Custom statusline components
│           ├── dynamic-fqn.lua   # Intelligent file path display
│           ├── vim-mode.lua      # Mode indicator with search count
│           ├── diagnostics.lua   # LSP diagnostic counter
│           ├── lsp.lua           # LSP status with spinner
│           ├── opencode.lua      # AI assistant status
│           ├── treesitter.lua    # Treesitter highlight indicator
│           └── macro-recording.lua # Macro recording indicator
│
└── local-plugins/                # Custom local plugins (not published)
    └── smart-comment-wrap/       # Intelligent comment wrapping with treesitter
```

## 🎯 Key Features

### Custom UI/UX
- **Catppuccin Mocha Theme** - Warm, soothing color palette
- **Doom-style Statusline** - Information-dense lualine with custom components
- **ARIA-Compliant File Explorer** - Snacks explorer with W3C accessibility standards
- **Smart File Path Display** - Abbreviates long paths intelligently based on project root

### Productivity Enhancements
- **Semicolon Command Palette** - `;` for command mode, `:` for next search match (swap)
- **Smart Comment Wrapping** - Auto-wraps comments at custom width using treesitter
- **Auto-save on Focus Loss** - Never lose changes when switching windows
- **Intelligent Completion** - Blink.cmp with smart tab behavior and snippet detection

### Development Tools
- **Multi-Language LSP** - Python (basedpyright + ruff), TypeScript, Kotlin, Lua, and more
- **Debugger Integration** - nvim-dap with custom F-key mappings during debug sessions
- **Git Integration** - Neogit for staging/committing, blame.nvim for line history
- **AI Assistance** - OpenCode integration for AI-powered coding help

### Navigation & Editing
- **Smart Window Navigation** - Seamless movement between NeoVim splits and tmux panes
- **Visual Block Movement** - Alt+Arrow keys to move selections
- **Code Transformation** - TreeSJ for split/join, Coerce for case conversion

## 🔧 Configuration Customization

### Options (`lua/config/options.lua`)
Global settings and feature toggles:
- `autoformat = false` - Manual formatting control
- `snacks_animate = false` - Disable animations for performance
- `lazyvim_blink_main = true` - Use blink.cmp as main completion engine
- `minipairs_disable = true` - Use nvim-autopairs instead

### Keymaps (`lua/config/keymaps.lua`)
Custom keybindings beyond LazyVim defaults:
- `;` / `:` - Swapped for faster command access
- `gV` - Reselect last paste/change region
- `gX` - Jump to treesitter context start
- `Ctrl+;` - Quick lua command entry
- `Ctrl+Alt+;` - Lua eval mode

### Autocmds (`lua/config/autocmds.lua`)
Automated behavior:
- **Number Toggle** - Relative numbers in normal mode, absolute in insert mode
- Skips non-file buffers (terminal, help, etc.) to avoid UI glitches

## 📦 Plugin Categories

### Core UI (`lua/plugins/core.lua`)
- **catppuccin/nvim** - Colorscheme
- **lualine.nvim** - Statusline with custom doom-modeline theme
- **snacks.nvim** - Dashboard, explorer, picker, notifications
- **noice.nvim** - Enhanced command line UI
- **trouble.nvim** - Pretty diagnostics list

### Editor Enhancements (`lua/plugins/editor.lua`)
- **auto-save.nvim** - Automatic saving on text change
- **mini.align** - Text alignment helper (`gl` / `gL`)
- **mini.move** - Move lines/selections with Alt+arrows
- **treesj** - Split/join code blocks intelligently
- **coerce.nvim** - Case conversion (`<leader>co*`)
- **nvim-tcss** - Tailwind CSS class sorting

### Coding Tools (`lua/plugins/coding.lua`)
- **lazydev.nvim** - Lua development with NeoVim API docs
- **nvim-lspconfig** - LSP configurations for multiple languages
- **nvim-dap** - Debug adapter protocol with custom F-key bindings
- **blink.cmp** - Completion engine with smart tab/snippet logic
- **nvim-autopairs** - Auto-close brackets/quotes

### AI Integration (`lua/plugins/ai.lua`)
- **opencode.nvim** - AI coding assistant with custom keybindings
  - `<leader>ao` - Toggle OpenCode terminal
  - `<leader>aa` - Ask with `@this` context
  - `gaa` (visual) - Ask about selection

### Git Tools (`lua/plugins/git.lua`)
- **neogit** - Magit-style git interface
- **diffview.nvim** - Diff/merge tool
- **blame.nvim** - Inline git blame

### Navigation (`lua/plugins/nav.lua`)
- **smart-splits.nvim** - Smart window/tmux pane navigation
  - `Ctrl+h/j/k/l` or `Ctrl+Arrows` - Move between panes
  - `Ctrl+Shift+h/j/k/l` or `Ctrl+Shift+Arrows` - Resize panes

### Markdown (`lua/plugins/markdown.lua`)
- **peek.nvim** - Live markdown preview in browser

## 🎨 Statusline Components

Custom lualine components in `lua/lualine/components/`:

| Component | Purpose |
|-----------|---------|
| **dynamic-fqn** | Shows abbreviated file path with project root awareness |
| **vim-mode** | Mode indicator with integrated search count display |
| **diagnostics** | LSP diagnostic counts with colored severity icons |
| **lsp** | LSP client status with loading spinner animation |
| **opencode** | AI assistant connection status indicator |
| **treesitter** | Shows if treesitter highlighting is active |
| **macro-recording** | Displays currently recording macro register |

### Performance Optimizations
- **Caching** - File paths, colors, and tree structures cached to avoid recomputation
- **Lazy Evaluation** - Components only compute when visible
- **Optimized Diagnostics** - Uses `count()` instead of `get()` to avoid object allocation
- **Smart Refresh** - Selective redraw triggers only when data changes

## 🚀 Getting Started

### Prerequisites
- NeoVim >= 0.9.0
- Git
- A [Nerd Font](https://www.nerdfonts.com/) for icons
- Node.js (for some LSP servers)
- Python 3 with `pip` (for Python development)

### Installation
1. Backup existing config: `mv ~/.config/nvim ~/.config/nvim.bak`
2. Clone this config: `git clone <your-repo> ~/.config/nvim`
3. Launch NeoVim: `nvim`
4. Wait for lazy.nvim to install plugins automatically
5. Run `:checkhealth` to verify setup

### Post-Install
- Install LSP servers: `:Mason` (auto-installed: basedpyright, ruff, stylua, etc.)
- Check for updates: `:Lazy sync`
- View extras: `:LazyExtras` (optional language/framework support)

## 📝 Maintenance Notes

### When You Return After 6 Months...

**Where to Find Things:**
- **Keybinding not working?** → Check `lua/config/keymaps.lua`
- **Option behaving oddly?** → Check `lua/config/options.lua` for WHY it's set
- **Plugin not loading?** → Check `lua/plugins/*.lua` files
- **Statusline component broken?** → Check `lua/lualine/components/*.lua`
- **Custom plugin issue?** → Check `local-plugins/*/lua/`

**Common Customizations:**
1. **Add new plugin** → Create spec in appropriate `lua/plugins/*.lua` file
2. **Change colorscheme** → Edit `lua/plugins/core.lua` colorscheme setting
3. **Modify statusline** → Edit `lua/lualine/themes/doom-modeline.lua`
4. **Add keybinding** → Add to `lua/config/keymaps.lua` with descriptive comment
5. **Install LSP server** → Add to `ensure_installed` in `lua/plugins/coding.lua`

**Troubleshooting:**
- `:checkhealth` - Diagnose issues
- `:Lazy` - Plugin manager status
- `:Mason` - LSP/tool installation status
- `:LspInfo` - LSP client status for current buffer
- `:messages` - View error messages

## 🔗 References

- [LazyVim Documentation](https://lazyvim.github.io/)
- [lazy.nvim Plugin Manager](https://github.com/folke/lazy.nvim)
- [NeoVim Documentation](https://neovim.io/doc/)
- [W3C WAI-ARIA Tree View Pattern](https://www.w3.org/WAI/ARIA/apg/patterns/treeview/) - Used in file explorer

## 📄 License

This configuration is for personal use. Individual plugins have their own licenses.
