--------------------------------------------------------------------------------
-- Git Integration Tools
--------------------------------------------------------------------------------
-- This file configures Git workflow plugins:
--   - Neogit: Magit-style Git interface (staging, committing, log viewing)
--   - Diffview: Advanced diff and merge tool
--   - Blame: Inline git blame annotations
--
-- WHY Neogit: Provides a powerful staging interface similar to Magit (Emacs),
-- making it easy to stage hunks, lines, or files interactively.
--------------------------------------------------------------------------------

return {
  {
    "NeogitOrg/neogit",
    lazy = true,
    dependencies = {
      "nvim-lua/plenary.nvim",
      "sindrets/diffview.nvim",
      "folke/snacks.nvim",
    },
    cmd = "Neogit",
    keys = {
      { "<leader>gg", "<cmd>Neogit<cr>", desc = "Neogit (Root Dir)" },
      { "<leader>gG", "<cmd>Neogit cwd=%:p:h<cr>", desc = "Neogit (cwd)" },
      {
        "<leader>gl",
        function()
          require("neogit").action("log", "log_current")()
        end,
        desc = "Neogit (git log)",
      },
    },
    opts = {
      graph_style = (vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT or vim.env.SSH_TTY) and "unicode" or "kitty",
    },
  },

  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
    opts = {
      keymaps = {
        view = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
        file_panel = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
        file_history_panel = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
      },
    },
  },

  {
    "FabijanZulj/blame.nvim",
    lazy = false,
    keys = {
      { "<leader>gb", "<CMD>BlameToggle window<CR>", { desc = "Git Blame" } },
    },
    opts = {},
  },
}
