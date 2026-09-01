if vim.g.loaded_agent_manager == 1 then
  return
end
vim.g.loaded_agent_manager = 1

local function manager()
  return require("agent_manager")
end

vim.api.nvim_create_user_command("AgentManager", function()
  manager().open()
end, { desc = "Open the Agent Manager workspace" })

vim.api.nvim_create_user_command("AgentManagerStart", function(args)
  local provider = args.args ~= "" and args.args or "codex"
  manager().open()
  manager().start({
    provider = provider,
    cwd = vim.fs.root(0, { ".git" }) or vim.uv.cwd(),
    workspace_strategy = "shared",
  })
end, {
  nargs = "?",
  complete = function()
    return { "codex", "claude" }
  end,
  desc = "Start one embedded Codex or Claude agent",
})

vim.api.nvim_create_user_command("AgentManagerSend", function(args)
  manager().prompt_ui(args.args)
end, { nargs = "*", desc = "Send a prompt to the selected agent" })

vim.api.nvim_create_user_command("AgentManagerSteer", function(args)
  manager().steer_ui(args.args)
end, { nargs = "*", desc = "Steer the selected active turn" })

vim.api.nvim_create_user_command("AgentManagerInterrupt", function()
  manager().confirm_interrupt()
end, { desc = "Confirm and interrupt the selected active turn" })

vim.api.nvim_create_user_command("AgentManagerHealth", function()
  vim.cmd("checkhealth agent_manager")
end, { desc = "Show Agent Manager health diagnostics" })

vim.api.nvim_create_user_command("AgentManagerClose", function()
  manager().close()
end, { desc = "Close the Agent Manager workspace" })
