local _G = _G
local depcopySettings = { debug = true, recursionDepth = 20, whitelist = {}, blacklist = {} }
local function setup(opts)
    depcopySettings.recursionDepth = opts.recursionDepth or 3
    depcopySettings.whitelist = opts.whitelist or {}
    depcopySettings.blacklist = opts.blacklist or {}
    depcopySettings.debug = opts.debug or false
end

local function log_debug(message, ...)
    if depcopySettings.debug then
        vim.notify(string.format("[DepCopy] Debug: " .. message, ...), vim.log.levels.DEBUG)
    end
end



local copy_func_with_deps

-- CURSOR STATE ....................................................................
local original_state = nil
local function save_cursor_state()
    original_state = {
        buf = vim.api.nvim_get_current_buf(),
        win = vim.api.nvim_get_current_win(),
        pos = vim.api.nvim_win_get_cursor(0),
        filepath = vim.api.nvim_buf_get_name(0)
    }
    log_debug("Saved cursor state - buf:%d, win:%d, pos:[%d,%d], file:%s", original_state.buf, original_state.win,
        original_state.pos[1], original_state.pos[2], original_state.filepath)
end

local function restore_cursor_state()
    if not original_state then
        vim.notify("[DepCopy] Warning: No original state to restore", vim.log.levels.WARN)
        return false
    end

    local success = pcall(function()
        if vim.api.nvim_buf_is_valid(original_state.buf) then
            vim.api.nvim_set_current_buf(original_state.buf)
            if vim.api.nvim_win_is_valid(original_state.win) then
                vim.api.nvim_set_current_win(original_state.win)
            end
            vim.api.nvim_win_set_cursor(0, original_state.pos)
        end
    end)

    log_debug("Cursor restoration " .. (success and "succeeded" or "failed"))

    return success
end

-- PATH CHECKING ..................................................................
local function get_current_buffer_filepath()
    local bufnr = vim.api.nvim_get_current_buf()
    local filepath = vim.api.nvim_buf_get_name(bufnr)

    if not vim.api.nvim_buf_is_valid(bufnr) then
        log_debug("Current buffer is not valid")
        return nil
    end

    if filepath == "" then
        vim.cmd('sleep 100m')
        filepath = vim.api.nvim_buf_get_name(bufnr)
    end

    log_debug("Current buffer filepath: '%s'", filepath)
    return filepath
end

local function is_venv_path(filepath)
    if not filepath or filepath == "" then
        log_debug("No filepath provided for project root check")
        return false
    end
    local normalized_path = vim.fn.resolve(filepath)
    -- Common venv directory names
    local venv_patterns = { "/%.venv/", "/venv/", "/virtualenv/", "/%.virtualenv/", "/env/", "/site%-packages/" }

    for _, pattern in ipairs(venv_patterns) do
        if normalized_path:match(pattern) then
            return true
        end
    end
    return false
end

local function is_project_file(filepath)
    if not filepath or filepath == "" then
        log_debug("filepath is nil or empty, for project root check")
        return false
    end

    local normalized_path = vim.fn.resolve(filepath)
    log_debug("Checking project file: %s (normalized: %s)", filepath, normalized_path)

    if #depcopySettings.whitelist > 0 then
        for _, allowed_path in ipairs(depcopySettings.whitelist) do
            if normalized_path:match(vim.fn.resolve(allowed_path)) then
                log_debug(string.format("File '%s' allowed by whitelist", filepath))
                return true
            end
        end
        log_debug(string.format("File '%s' not in whitelist", filepath))
        return false
    end

    for _, blocked_path in ipairs(depcopySettings.blacklist) do
        if normalized_path:match(vim.fn.resolve(blocked_path)) then
            log_debug(string.format("File '%s' blocked by blacklist", filepath))
            return false
        end
    end

    if is_venv_path(normalized_path) then
        log_debug("File '%s' rejected - in virtual environment", filepath)
        return false
    end

    local project_root = vim.fn.getcwd()
    log_debug("root=%s", project_root)
    local is_in_project = normalized_path:sub(1, #project_root) == project_root

    if not is_in_project then
        return false
    end

    return true
end





-- CORE .....................................................................
local function wait_for_lsp_jump(max_wait_ms)
    max_wait_ms = max_wait_ms or 1000
    local start_time = vim.loop.hrtime()
    local timeout = max_wait_ms * 1000000 -- Convert to nanoseconds

    while (vim.loop.hrtime() - start_time) < timeout do
        vim.cmd('sleep 50m')
        local filepath = get_current_buffer_filepath()
        if filepath and filepath ~= "" then
            return filepath
        end
    end

    return get_current_buffer_filepath()
end

local function _get_function_via_treesitter()
    local ts_utils = require("nvim-treesitter.ts_utils")
    local bufnr = vim.api.nvim_get_current_buf()
    local filepath = vim.api.nvim_buf_get_name(bufnr)

    local node = ts_utils.get_node_at_cursor()
    while node and node:type() ~= "function_definition" do
        node = node:parent()
    end

    if not node then
        vim.notify("[DepCopy] Error: No function definition found under cursor", vim.log.levels.ERROR)
        return
    end

    -- Get the function name
    local func_name = nil
    for child in node:iter_children() do
        if child:type() == "identifier" then
            func_name = vim.treesitter.get_node_text(child, bufnr)
            break
        end
    end

    local start_row, _, end_row, _ = node:range()
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    local func_text = table.concat(lines, "\n")
    local calls = {}
    local function walk(n)
        if n:type() == "call" then
            local call_node = n:child(0)
            if call_node and (call_node:type() == "identifier" or call_node:type() == "attribute") then
                local call_name = vim.treesitter.get_node_text(call_node, bufnr)
                if call_name and not call_name:match("^(if|while|for|print|len|str|int|float|list|dict|set|tuple)$") then
                    local call_row, call_col = call_node:range()
                    vim.api.nvim_win_set_cursor(0, { call_row + 1, call_col })
                    local params = vim.lsp.util.make_position_params()
                    vim.lsp.buf_request(bufnr, 'textDocument/definition', params, function(err, result)
                        if not err and result and not vim.tbl_isempty(result) then
                            local location = result[1] or result
                            local def_filepath = vim.uri_to_fname(location.uri or location.targetUri)

                            if bufnr == vim.api.nvim_get_current_buf() and is_project_file(def_filepath) then
                                table.insert(calls, {
                                    name = call_name,
                                    node = call_node,
                                    row = call_row + 1,
                                    col = call_col + 1,
                                })
                            end
                        end
                    end)
                    vim.cmd('sleep 50m')
                end
            end
        end
        for child in n:iter_children() do
            walk(child)
        end
    end
    walk(node)

    local file = io.open("/tmp/depcopy.txt", "a")
    file:write(string.format("\nFILE: %s\n```py\n%s\n```\n===\n\n\n", filepath, func_text))
    file:close()

    return {
        name = func_name,
        node = node,
        filepath = filepath,
        content = func_text,
        calls = calls,
        start_line = start_row + 1,
        end_line = end_row + 1
    }
end

local function jump_to_definition_and_process(call_info, current_depth)
    if current_depth >= depcopySettings.recursionDepth then
        log_debug("Skipping '%s' - max recursion depth reached", call_info.name)
        return
    end
    local pre_jump_file = get_current_buffer_filepath()
    if not pre_jump_file or not is_project_file(pre_jump_file) then
        log_debug("Skipping '%s' - current file before jump is outside project boundaries or empty", call_info.name)
        return
    end

    log_debug("Attempting set cursor to '%s' {%s,%s} at depth %d", call_info.name, call_info.row, call_info.col - 1,
        current_depth)
    vim.api.nvim_win_set_cursor(0, { call_info.row, call_info.col + #call_info.name - 1 })
    local before_jump = {
        buf = vim.api.nvim_get_current_buf(),
        win = vim.api.nvim_get_current_win(),
        pos = vim.api.nvim_win_get_cursor(0),
        filepath = pre_jump_file
    }
    log_debug("Attempting jump to definition '%s' at depth %d from %s", call_info.name, current_depth, pre_jump_file)
    vim.lsp.buf.definition()
    local jumped_filepath = wait_for_lsp_jump(1000)

    -- Check if jump was successful by comparing positions
    local after_jump = {
        buf = vim.api.nvim_get_current_buf(),
        pos = vim.api.nvim_win_get_cursor(0),
        filepath = jumped_filepath
    }
    local jump_successful = (before_jump.buf ~= after_jump.buf) or
        (before_jump.pos[1] ~= after_jump.pos[1]) or
        (before_jump.pos[2] ~= after_jump.pos[2]) or
        (before_jump.filepath ~= after_jump.filepath)

    if jump_successful and jumped_filepath and jumped_filepath ~= "" then
        log_debug("Successfully jumped to '%s' in file '%s', processing recursively", call_info.name, jumped_filepath)
        -- Check if the jumped-to file should be processed
        if not is_project_file(jumped_filepath) then
            log_debug("Skipping processing of '%s' - jumped to file '%s' outside project boundaries",
                call_info.name, jumped_filepath)
        else
            copy_func_with_deps(current_depth)
        end
    else
        log_debug("Jump failed for '%s' - no definition found", call_info.name)
    end
    log_debug("BACKTRACKING: Restoring to %s after processing %s", before_jump.filepath, call_info.name)
    local restore_success = pcall(function()
        if vim.api.nvim_buf_is_valid(before_jump.buf) then
            vim.api.nvim_set_current_buf(before_jump.buf)
            if vim.api.nvim_win_is_valid(before_jump.win) then
                vim.api.nvim_set_current_win(before_jump.win)
            end
            vim.api.nvim_win_set_cursor(0, before_jump.pos)
        end
    end)
    local restored_file = get_current_buffer_filepath()
    log_debug("BACKTRACKING: Restore %s, current file is now '%s'",
        restore_success and "SUCCESS" or "FAILED", restored_file or "EMPTY")
end

copy_func_with_deps = function(current_depth)
    current_depth = current_depth or 0
    if current_depth == 0 then
        os.remove("/tmp/depcopy.txt")
        save_cursor_state()
    end
    local func = _get_function_via_treesitter()
    if not func then
        vim.notify("No function detected at cursor.")
        if current_depth == 0 then
            restore_cursor_state()
            vim.cmd('sleep 500m')
        end
        return
    end
    log_debug("\n\n\nProcessing function '%s' at depth %d with %d calls: %s", func.name or "unknown", current_depth,
        #func.calls, table.concat(vim.tbl_map(function(call) return call.name end, func.calls), ", "))
    local visited = {}
    for _, call in ipairs(func.calls) do
        if not visited[call.name] then
            visited[call.name] = true
            log_debug("Processing call to '%s'", call.name)
            jump_to_definition_and_process(call, current_depth + 1)
        end
    end

    -- Restore cursor state only at the top level
    if current_depth == 0 then
        restore_cursor_state()
        vim.cmd('sleep 500m')
    end
end

return {
    setup = setup,
    copy_func_with_deps = copy_func_with_deps
}
