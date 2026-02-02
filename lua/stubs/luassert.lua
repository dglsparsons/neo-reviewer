---@meta

---@class luassert.stub_return
---@field was_called fun(times: integer): nil
---@field was_called_with fun(...): nil
---@field was_not_called fun(): nil

---@class luassert.comparators
---@field equal fun(expected: any, actual: any): nil
---@field same fun(expected: any, actual: any): nil

---@class luassert
---@field is_true fun(value: any, message?: string): nil
---@field is_false fun(value: any): nil
---@field is_truthy fun(value: any): nil
---@field is_nil fun(value: any): nil
---@field is_not_nil fun(value: any): nil
---@field is_function fun(value: any): nil
---@field is_table fun(value: any): nil
---@field are luassert.comparators
---@field has_no_errors fun(fn: function): nil
---@field has_error fun(fn: function): nil
---@field fail fun(msg: string): nil
---@field matches fun(pattern: string, value: string): nil
---@field stub fun(tbl: table): luassert.stub_return
local luassert

---@type luassert
-- Tests override the global assert with luassert; keep type info for LuaLS.
---@diagnostic disable-next-line: assign-type-mismatch
assert = assert
