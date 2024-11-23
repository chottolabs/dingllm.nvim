local M = {}
local ns_id = vim.api.nvim_create_namespace 'dingllm'

local function get_api_key(name)
  return os.getenv(name)
end

function M.get_lines_until_cursor()
  local current_buffer = vim.api.nvim_get_current_buf()
  local current_window = vim.api.nvim_get_current_win()
  local cursor_position = vim.api.nvim_win_get_cursor(current_window)
  local row = cursor_position[1]

  local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

  return table.concat(lines, '\n')
end

function M.get_visual_selection()
  local _, srow, scol = unpack(vim.fn.getpos 'v')
  local _, erow, ecol = unpack(vim.fn.getpos '.')

  if vim.fn.mode() == 'V' then
    if srow > erow then
      return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
    else
      return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
    end
  end

  if vim.fn.mode() == 'v' then
    if srow < erow or (srow == erow and scol <= ecol) then
      return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
    else
      return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
    end
  end

  if vim.fn.mode() == '\22' then
    local lines = {}
    if srow > erow then
      srow, erow = erow, srow
    end
    if scol > ecol then
      scol, ecol = ecol, scol
    end
    for i = srow, erow do
      table.insert(lines, vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1])
    end
    return lines
  end
end

function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
  local url = opts.url
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local data = {
    system = system_prompt,
    messages = { { role = 'user', content = prompt } },
    model = opts.model,
    stream = true,
    max_tokens = 4096,
  }
  local args = {
    '-s', '--fail-with-body', '-N', --silent, with errors, unbuffered output
    '-X', 'POST',
    '-H', 'Content-Type: application/json',
    '-d', vim.json.encode(data)
  }
  if api_key then
    table.insert(args, '-H')
    table.insert(args, 'x-api-key: ' .. api_key)
    table.insert(args, '-H')
    table.insert(args, 'anthropic-version: 2023-06-01')
  end
  table.insert(args, url)
  return args
end

function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
  local url = opts.url
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local data = {
    messages = { { role = 'system', content = system_prompt }, { role = 'user', content = prompt } },
    model = opts.model,
    temperature = 0.7,
    stream = true,
  }
  local args = {
    '-s', '--fail-with-body', '-N', --silent, with errors, unbuffered output
    '-X', 'POST',
    '-H', 'Content-Type: application/json',
    '-d', vim.json.encode(data)
  }
  if api_key then
    table.insert(args, '-H')
    table.insert(args, 'Authorization: Bearer ' .. api_key)
  end
  table.insert(args, url)
  return args
end

function M.write_string_at_extmark(str, extmark_id)
  vim.schedule(function()
    local extmark = vim.api.nvim_buf_get_extmark_by_id(0, ns_id, extmark_id, { details = false })
    local row, col = extmark[1], extmark[2]

    vim.cmd("undojoin")
    local lines = vim.split(str, '\n')
    vim.api.nvim_buf_set_text(0, row, col, row, col, lines)
  end)
end

local function get_prompt(opts)
  local replace = opts.replace
  local visual_lines = M.get_visual_selection()
  local prompt = ''

  if visual_lines then
    prompt = table.concat(visual_lines, '\n')
    if replace then
      vim.api.nvim_command 'normal! c'
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', false, true, true), 'nx', false)
    end
  else
    prompt = M.get_lines_until_cursor()
  end

  return prompt
end

function M.handle_anthropic_spec_data(data_stream)
  local content = ''
  for event, data in data_stream:gmatch('event: ([%w_]+)\ndata: (%b{})%s+') do
    if event == 'content_block_delta' then
      local json = vim.json.decode(data)
      if json.delta and json.delta.text then
        content = content .. json.delta.text
      end
    elseif event == 'content_block_start' then
    elseif event == 'content_block_stop' then
    elseif event == 'message_start' then
      vim.print(data)
    elseif event == 'message_delta' then
    elseif event == 'ping' then
    elseif event == 'error' then
      vim.print(data)
    else
      vim.print(data)
    end
  end
  return content
end

function M.handle_openai_spec_data(data_stream)
  local content = ''

  for data in data_stream:gmatch('data: (%b{})%s+') do
    if data and data:match '"delta":' then
      local json = vim.json.decode(data)
      -- sglang server returns the role as one of the events and it becomes `vim.NIL`, so we have to handle it here
      if json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content and json.choices[1].delta.content ~= vim.NIL then
        content = content .. json.choices[1].delta.content
      else
        vim.print(data)
      end
    end
  end

  return content
end

local group = vim.api.nvim_create_augroup('DING_LLM_AutoGroup', { clear = true })

--- Makes a no-op change to the buffer
--- This is used before making changes to avoid calling undojoin after undo.
local function noop()
  vim.api.nvim_buf_set_text(0, 0, 0, 0, 0, {})
end

local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
  vim.api.nvim_clear_autocmds { group = group }
  local prompt = get_prompt(opts)
  local system_prompt = opts.system_prompt or 'You are a tsundere uwu anime. Yell at me for not setting my configuration for my llm plugin correctly'
  local args = make_curl_args_fn(opts, prompt, system_prompt)

  local crow, _ = unpack(vim.api.nvim_win_get_cursor(0))
  local stream_end_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, crow - 1, -1, {})

  if active_job then
    active_job:kill(9)
    active_job = nil
  end

  noop()
  local captured_stdout
  active_job = vim.system(
    vim.list_extend({ 'curl' }, args),
    {
      stdout = function(err, data)
        if data == nil then
          return
        end

        captured_stdout = data
        local content = handle_data_fn(data)
        M.write_string_at_extmark(content, stream_end_extmark_id)
      end,
    },
    function(obj)
      vim.schedule(function()
        if obj.code and obj.code ~= 0 then
          vim.notify(
            ('[curl] (exit code: %d) %s'):format(obj.code, captured_stdout),
            vim.log.levels.ERROR
          )
        end
      end)
    end
  )

  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DING_LLM_Escape',
    callback = function()
      if active_job then
        active_job:kill(9)
        print 'LLM streaming cancelled'
        active_job = nil
      end
    end,
  })

  vim.api.nvim_set_keymap('n', '<Esc>', ':doautocmd User DING_LLM_Escape<CR>', { noremap = true, silent = true })
  return active_job
end

return M
