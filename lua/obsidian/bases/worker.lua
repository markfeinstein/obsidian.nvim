local compat = require "obsidian.bases.compat"

local M = {}

local PROTOCOL_VERSION = 1
local PACKAGE_VERSION = "0.2.0"
local DEFAULT_REQUEST_TIMEOUT = 10000
local process
local process_generation = 0
local next_id = 0
local pending = {}
---@type { node: string?, worker: string?, dependency: string?, request_timeout: integer? }
local overrides = {}

---@class obsidian.bases.WorkerError
---@field kind "missing_runtime"|"worker_failure"|"protocol_error"|"timeout"
---@field message string

---@class obsidian.bases.WorkerRequest
---@field callback (fun(result: table?, err: obsidian.bases.WorkerError?))|nil
---@field active boolean
---@field timer uv.uv_timer_t|nil

---@param request obsidian.bases.WorkerRequest
local function close_timer(request)
  local timer = request.timer
  request.timer = nil
  if not timer then
    return
  end
  pcall(function()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end)
end

---@param request obsidian.bases.WorkerRequest
---@param result table|nil
---@param err obsidian.bases.WorkerError|nil
local function schedule_result(request, result, err)
  close_timer(request)
  vim.schedule(function()
    local callback = request.callback
    if not request.active or not callback then
      return
    end
    request.active = false
    request.callback = nil
    callback(result, err)
  end)
end

---@param err obsidian.bases.WorkerError
local function fail_pending(err)
  local requests = pending
  pending = {}
  for _, request in pairs(requests) do
    schedule_result(request, nil, err)
  end
end

---@param err obsidian.bases.WorkerError
local function terminate_process(err)
  process_generation = process_generation + 1
  local current = process
  process = nil
  if current then
    pcall(function()
      current:kill(15)
    end)
  end
  fail_pending(err)
end

local function runtime_paths()
  local worker_path = overrides.worker
  if not worker_path then
    worker_path = vim.api.nvim_get_runtime_file("runtime/obsidian-bases-worker.mjs", false)[1]
  end
  local root = worker_path and vim.fs.dirname(vim.fs.dirname(worker_path)) or nil
  return {
    node = overrides.node or vim.fn.exepath "node",
    worker = worker_path,
    dependency = overrides.dependency
      or (root and vim.fs.joinpath(root, "node_modules", "obsidian-bases-expression", "package.json") or nil),
  }
end

---@return integer
local function request_timeout()
  return math.max(1, math.floor(tonumber(overrides.request_timeout) or DEFAULT_REQUEST_TIMEOUT))
end

---@return boolean
---@return obsidian.bases.WorkerError|nil
local function available()
  local paths = runtime_paths()
  if paths.node == "" then
    return false, { kind = "missing_runtime", message = "Node.js is not available" }
  end
  if not compat.capabilities().system then
    return false, { kind = "missing_runtime", message = "vim.system() is not available" }
  end
  if not paths.worker or not vim.uv.fs_stat(paths.worker) then
    return false, { kind = "missing_runtime", message = "Bases evaluator worker was not found" }
  end
  if not paths.dependency or not vim.uv.fs_stat(paths.dependency) then
    return false,
      {
        kind = "missing_runtime",
        message = "obsidian-bases-expression@"
          .. PACKAGE_VERSION
          .. " is not installed; run npm install in the plugin directory",
      }
  end
  return true, nil
end

local function dispatch_line(line)
  if vim.trim(line) == "" then
    return
  end
  local ok, response = pcall(vim.json.decode, line)
  if not ok or type(response) ~= "table" then
    terminate_process { kind = "protocol_error", message = "evaluator returned invalid JSON" }
    return
  end
  local request = pending[response.id]
  if not request then
    return
  end
  pending[response.id] = nil
  if response.ok then
    schedule_result(request, response.result, nil)
  else
    schedule_result(request, nil, {
      kind = "worker_failure",
      message = response.error and response.error.message or "evaluator request failed",
    })
  end
end

---@return boolean
---@return obsidian.bases.WorkerError|nil
local function ensure_process()
  if process then
    return true, nil
  end
  local ok, err = available()
  if not ok then
    return false, err
  end
  local paths = runtime_paths()
  process_generation = process_generation + 1
  local generation = process_generation
  local stdout_buffer = ""
  local stderr_buffer = ""
  local started, start_err = compat.system({ paths.node, paths.worker }, {
    stdin = true,
    text = true,
    stdout = function(_, data)
      if process_generation ~= generation or not data then
        return
      end
      stdout_buffer = stdout_buffer .. data
      while true do
        local newline = stdout_buffer:find("\n", 1, true)
        if not newline then
          break
        end
        local line = stdout_buffer:sub(1, newline - 1)
        stdout_buffer = stdout_buffer:sub(newline + 1)
        dispatch_line(line)
      end
    end,
    stderr = function(_, data)
      if process_generation == generation and data then
        stderr_buffer = (stderr_buffer .. data):sub(-4000)
      end
    end,
  }, function(result)
    if process_generation ~= generation then
      return
    end
    process = nil
    local detail = vim.trim(stderr_buffer)
    local message = ("Bases evaluator exited with code %s"):format(result.code)
    if detail ~= "" then
      message = message .. ": " .. detail
    end
    fail_pending { kind = "worker_failure", message = message }
  end)
  if not started then
    return false, { kind = "missing_runtime", message = start_err or "failed to start Bases evaluator" }
  end
  process = started
  return true, nil
end

---@return { available: boolean, name: string, version: string, error: obsidian.bases.WorkerError? }
function M.status()
  local ok, err = available()
  return {
    available = ok,
    name = "local-node",
    version = PACKAGE_VERSION,
    error = err,
  }
end

---@param params table
---@param callback fun(result: table?, err: obsidian.bases.WorkerError?)
---@return fun() cancel
function M.evaluate(params, callback)
  ---@type obsidian.bases.WorkerRequest
  local worker_request = { callback = callback, active = true, timer = nil }
  local id
  local function cancel()
    if not worker_request.active then
      return
    end
    worker_request.active = false
    worker_request.callback = nil
    if id and pending[id] == worker_request then
      local has_active_sibling = false
      for other_id, other_request in pairs(pending) do
        if other_id ~= id and other_request.active then
          has_active_sibling = true
          break
        end
      end
      if not has_active_sibling then
        pending[id] = nil
        close_timer(worker_request)
        terminate_process {
          kind = "worker_failure",
          message = "Bases evaluator restarted after a request was cancelled",
        }
      end
      -- When active sibling requests share this worker, keep the cancelled
      -- request's deadline armed in case it is the request blocking them.
    else
      close_timer(worker_request)
    end
  end

  local ok, err = ensure_process()
  if not ok then
    schedule_result(
      worker_request,
      nil,
      err or { kind = "missing_runtime", message = "Bases evaluator is unavailable" }
    )
    return cancel
  end

  next_id = next_id + 1
  id = next_id
  pending[id] = worker_request
  local timeout = request_timeout()
  worker_request.timer = vim.defer_fn(function()
    if pending[id] ~= worker_request then
      return
    end
    pending[id] = nil
    schedule_result(worker_request, nil, {
      kind = "timeout",
      message = ("Bases evaluator timed out after %dms"):format(timeout),
    })
    terminate_process {
      kind = "worker_failure",
      message = "Bases evaluator restarted after another request timed out",
    }
  end, timeout)

  local encoded, request = pcall(vim.json.encode, {
    version = PROTOCOL_VERSION,
    id = id,
    method = "evaluate",
    params = params,
  })
  if not encoded then
    pending[id] = nil
    schedule_result(worker_request, nil, { kind = "protocol_error", message = tostring(request) })
    return cancel
  end

  local wrote, write_err = pcall(function()
    if not process then
      error("Bases evaluator process is unavailable", 0)
    end
    process:write(request .. "\n")
  end)
  if not wrote then
    pending[id] = nil
    schedule_result(worker_request, nil, { kind = "worker_failure", message = tostring(write_err) })
    terminate_process {
      kind = "worker_failure",
      message = "Bases evaluator restarted after a write failure",
    }
  end
  return cancel
end

function M.stop()
  terminate_process { kind = "worker_failure", message = "Bases evaluator stopped" }
end

---@param paths table|nil
function M._set_paths(paths)
  M.stop()
  overrides = paths or {}
end

return M
