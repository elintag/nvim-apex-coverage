---@diagnostic disable: undefined-global

local M = {}
local Job = require('plenary.job')

-- Create our own notification system
local notify = {
    error = function(msg)
        vim.notify(msg, vim.log.levels.ERROR, { title = 'Apex Coverage' })
    end,
    info = function(msg)
        vim.notify(msg, vim.log.levels.INFO, { title = 'Apex Coverage' })
    end,
    success = function(msg)
        vim.notify(msg, vim.log.levels.INFO, { title = 'Apex Coverage' })
    end,
}

local coverage_data = {
    class_coverage_map = {},
    method_coverage_map = {},
    total_coverage_map = {},
}

-- Constants
local REFRESH_DATA = 'Refresh Data'
local TOTAL_COVERAGE = 'Total Coverage'

-- Check if current file is an Apex class or trigger
local function is_valid_apex_file()
    local filename = vim.fn.expand('%:p')
    local ext = vim.fn.fnamemodify(filename, ':e'):lower()
    return ext == 'cls' or ext == 'trigger'
end

-- Get current class name
local function get_current_class_name()
    local filename = vim.fn.expand('%:t')
    return vim.fn.fnamemodify(filename, ':r')
end

-- Execute SOQL query using sf cli with plenary.job
local function execute_soql_query(query)
    -- Use plenary.job for async command execution
    local args = { 'data', 'query', '-t', '-q', query, '--json' }
    local job = Job:new({
        command = 'sf',
        args = args,
    })

    local ok, result_code = pcall(function()
        return job:sync(30000) -- 30 second timeout
    end)

    -- Command executed successfully
    if ok then
        -- Get the output and concatenate it properly
        local output = table.concat(job:result(), '')
        if not output or output == '' then
            return {}
        end

        local success, parsed_result = pcall(vim.fn.json_decode, output)
        if success then
            if parsed_result.result then
                -- Return empty array if no records found, rather than failing
                return parsed_result.result.records or {}
            end
        else
            notify.error('Failed to parse JSON output from sf cli')
        end
    else
        -- Command execution failed
        local error_output = table.concat(job:stderr_result(), '\n')
        if error_output ~= '' then
            notify.error('Error executing query: ' .. error_output)
        else
            notify.error('Failed to execute SOQL query')
        end
    end

    return {}
end

-- Get code coverage data from Salesforce
local function fetch_coverage_data(class_name)
    -- Show loading notification
    notify.info('Fetching coverage data for ' .. class_name .. '...')

    -- Query for individual test method coverage
    local query1 = [[SELECT ApexTestClass.Name, TestMethodName, NumLinesCovered, NumLinesUncovered, Coverage
                  FROM ApexCodeCoverage
                  WHERE ApexClassOrTrigger.name = ']] .. class_name .. [['
                  ORDER BY createddate DESC LIMIT 20]]

    -- Query for aggregated coverage
    local query2 = [[SELECT ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered, Coverage
                  FROM ApexCodeCoverageAggregate
                  WHERE ApexClassOrTrigger.Name = ']] .. class_name .. [[']]

    -- Run queries
    local method_coverage = execute_soql_query(query1)
    local total_coverage = execute_soql_query(query2)

    -- Process results
    if method_coverage and #method_coverage > 0 then
        local method_map = {}
        for _, record in ipairs(method_coverage) do
            local key = record.ApexTestClass.Name .. '.' .. record.TestMethodName
            method_map[key] = record
        end

        coverage_data.method_coverage_map[class_name] = method_map
        coverage_data.total_coverage_map[class_name] = total_coverage

        notify.success('Coverage data fetched successfully')
        return true
    end

    return false
end

-- Highlight covered and uncovered lines
local function highlight_coverage(coverage_data)
    -- Clean existing highlighting
    vim.cmd('sign unplace * group=ApexCoverage')

    if not coverage_data then
        notify.error('No coverage data available')
        return
    end

    vim.cmd([[
    sign define ApexCoveredLine text=󰗠 texthl=Added
    sign define ApexUncoveredLine text= texthl=Removed
  ]])

    -- Get covered and uncovered lines from the table
    local coveredLines = coverage_data.coveredLines or {}
    local uncoveredLines = coverage_data.uncoveredLines or {}

    -- Place signs for covered lines
    for _, line_num in ipairs(coveredLines) do
        vim.fn.sign_place(0, 'ApexCoverage', 'ApexCoveredLine', '%', { lnum = line_num })
    end

    -- Place signs for uncovered lines
    for _, line_num in ipairs(uncoveredLines) do
        vim.fn.sign_place(0, 'ApexCoverage', 'ApexUncoveredLine', '%', { lnum = line_num })
    end
end

-- Clean existing coverage highlighting
local function clean_coverage()
    vim.cmd('sign unplace * group=ApexCoverage')
end

-- Create selection menu
local function show_coverage_selection(class_name)
    if not coverage_data.method_coverage_map[class_name] then
        notify.error('No coverage data found for ' .. class_name)
        return
    end

    local options = { REFRESH_DATA }

    -- Add total coverage option
    if coverage_data.total_coverage_map[class_name] and #coverage_data.total_coverage_map[class_name] > 0 then
        local total_record = coverage_data.total_coverage_map[class_name][1]
        local total_pct = (
            total_record.NumLinesCovered / (total_record.NumLinesCovered + total_record.NumLinesUncovered)
        ) * 100
        table.insert(options, TOTAL_COVERAGE .. ' - ' .. string.format('%.2f', total_pct) .. '%')
    end

    -- Add per-method coverage options
    for key, record in pairs(coverage_data.method_coverage_map[class_name]) do
        local method_pct = (record.NumLinesCovered / (record.NumLinesCovered + record.NumLinesUncovered)) * 100
        table.insert(options, key .. ' - ' .. string.format('%.2f', method_pct) .. '%')
    end

    -- Show selection menu using vim.ui.select
    vim.ui.select(options, {
        prompt = 'Select Test Method Coverage:',
        format_item = function(item)
            return item
        end,
    }, function(selected)
        if not selected then
            return
        end

        if selected == REFRESH_DATA then
            coverage_data.method_coverage_map[class_name] = nil
            coverage_data.total_coverage_map[class_name] = nil
            M.get_coverage()
        elseif selected:sub(1, #TOTAL_COVERAGE) == TOTAL_COVERAGE then
            highlight_coverage(coverage_data.total_coverage_map[class_name][1].Coverage)
        else
            local method_name = selected:match('^(.+) %- ')
            if method_name and coverage_data.method_coverage_map[class_name][method_name] then
                highlight_coverage(coverage_data.method_coverage_map[class_name][method_name].Coverage)
            end
        end
    end)
end

-- Function to clean coverage signs
function M.clean_coverage()
    clean_coverage()
    notify.info('Apex coverage signs cleared')
end

-- Main function to get coverage
function M.get_coverage()
    -- Check if current file is valid
    if not is_valid_apex_file() then
        notify.error('Not an Apex Class or Trigger')
        return
    end

    -- Clean existing coverage
    clean_coverage()

    -- Get current class name
    local class_name = get_current_class_name()

    -- Check if we need to fetch data
    if not coverage_data.method_coverage_map[class_name] then
        local success = fetch_coverage_data(class_name)
        if not success then
            notify.error('No coverage found for ' .. class_name .. '. Run tests first!')
            return
        end
    end

    -- Show selection menu
    show_coverage_selection(class_name)
end

-- Setup function to register the user command
function M.setup()
    vim.api.nvim_create_user_command('ApexCoverage', function()
        M.get_coverage()
    end, {
        desc = 'Show Apex code coverage for current class/trigger',
        force = true,
    })

    vim.api.nvim_create_user_command('ApexCoverageClean', function()
        M.clean_coverage()
    end, {
        desc = 'Clear Apex code coverage signs',
        force = true,
    })

    -- Merge user options with defaults
    local defaults = {
        mappings = {
            coverage = '<leader>tc',
            clean = '<leader>tC',
        },
    }
    local config = vim.tbl_deep_extend('force', defaults, opts or {})

    -- Add leader tc shortcut for ApexCoverage
    vim.keymap.set('n', config.mappings.coverage, ':ApexCoverage<CR>', {
        desc = 'Show Apex code coverage for current class/trigger',
        silent = true,
    })

    -- Add leader tC shortcut for ApexCoverageClean
    vim.keymap.set('n', config.mappings.clean, ':ApexCoverageClean<CR>', {
        desc = 'Clear Apex code coverage signs',
        silent = true,
    })

    return M
end

return M
