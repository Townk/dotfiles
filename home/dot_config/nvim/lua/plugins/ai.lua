--------------------------------------------------------------------------------
-- AI Assistant Integration
--------------------------------------------------------------------------------
-- This file configures OpenCode, an AI coding assistant that integrates with
-- NeoVim. Custom keybindings provide quick access to AI help with context.
--
-- Keybinding Pattern:
--   <leader>a* = AI commands (normal mode)
--   ga* = AI commands (visual mode - works on selections)
--
-- The @this prefix automatically includes the current buffer/selection as context.
--------------------------------------------------------------------------------

return {
  {
    "NickvanDyke/opencode.nvim",
    dependencies = {
      { "folke/snacks.nvim" },
    },
    config = function()
      vim.g.opencode_opts = {}
      vim.o.autoread = true

      vim.keymap.set("n", "<leader>ao", function()
        require("opencode").toggle()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "opencode_terminal" then
            vim.api.nvim_set_current_win(win)
            break
          end
        end
      end, { desc = "Toggle opencode" })

      vim.keymap.set("n", "<leader>aa", function()
        require("opencode").ask("@this: ", { submit = true })
      end, { desc = "Ask opencode" })

      vim.keymap.set("n", "<leader>al", function()
        return require("opencode").operator("@this ") .. "_"
      end, { expr = true, desc = "Add line to opencode" })

      vim.keymap.set("n", "<leader>ax", function()
        require("opencode").select()
      end, { desc = "Execute opencode action…" })

      vim.keymap.set("x", "gaa", function()
        require("opencode").ask("@this: ", { submit = true })
      end, { desc = "Ask opencode" })

      vim.keymap.set("x", "gao", function()
        return require("opencode").operator("@this ")
      end, { expr = true, desc = "Add range to opencode" })

      vim.keymap.set("x", "gax", function()
        require("opencode").select()
      end, { desc = "Execute opencode action…" })

      vim.api.nvim_create_autocmd("TermOpen", {
        group = vim.api.nvim_create_augroup("OpenCodeKeys", { clear = true }),
        callback = function(args)
          if vim.bo[args.buf].filetype == "opencode_terminal" then
            vim.keymap.set("t", "<S-C-b>", function()
              require("opencode").command("session.half.page.up")
            end, { buffer = args.buf, silent = true, desc = "Scroll messages up by half a page" })
            vim.keymap.set("t", "<S-C-f>", function()
              require("opencode").command("session.half.page.down")
            end, { buffer = args.buf, silent = true, desc = "Scroll messages down by half a page" })
            vim.keymap.set("t", "<S-C-g>", function()
              require("opencode").command("session.last")
            end, { buffer = args.buf, silent = true, desc = "Jump to last message in session" })
          end
        end,
      })
    end,
  },
}
