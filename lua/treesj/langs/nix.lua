local lang_utils = require('treesj.langs.utils')
local ts = require('vim.treesitter')
local ts_query = require('vim.treesitter.query')

local function get_node_text(node)
  local getter = ts.get_node_text or ts_query.get_node_text
  local text = getter(node, 0)
  if type(text) == 'table' then
    return table.concat(text, '\n')
  end
  return text
end

local function get_child_by_tsnode(tsj, tsnode)
  for child in tsj:iter_children() do
    if child:tsnode() == tsnode then
      return child
    end
  end
end

local function get_attr_segments(attrpath_tsn)
  local segments = {}

  if not attrpath_tsn then
    return segments
  end

  for child in attrpath_tsn:iter_children() do
    if child:named() then
      table.insert(segments, get_node_text(child))
    end
  end

  return segments
end

local function merge_segments(...)
  local merged = {}

  for _, tbl in ipairs({ ... }) do
    if tbl then
      vim.list_extend(merged, tbl)
    end
  end

  return table.concat(merged, '.')
end

local function build_nested_attrset(segments, value_text)
  local result = value_text

  for i = #segments, 1, -1 do
    result = string.format('{ %s = %s; }', segments[i], result)
  end

  return result
end

-- NOTE: defined lower down
local get_single_binding

local function collect_binding_chain(binding_tsn)
  local segments = {}
  local current = binding_tsn
  local expression

  while current do
    local path_tsn = current:field('attrpath')[1]
    if not path_tsn then
      break
    end

    vim.list_extend(segments, get_attr_segments(path_tsn))

    expression = current:field('expression')[1]
    if not expression or expression:type() ~= 'attrset_expression' then
      break
    end

    current = get_single_binding(expression)
  end

  return segments, expression
end

---Find the attr segment boundary that is under the cursor (on a dot)
---Returns the number of segments on the left side of the boundary
---If cursor is not on a dot, returns nil
local function get_cursor_boundary_index(attrpath_tsn)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  local left_segments = 0
  for child in attrpath_tsn:iter_children() do
    if child:type() == '.' then
      local sr, sc, er, ec = child:range()
      if row >= sr and row <= er and col >= sc and col < ec then
        return left_segments
      end
    elseif child:named() then
      left_segments = left_segments + 1
    end
  end
end

local function get_binding_parts(tsj)
  local tsnode = tsj:tsnode()
  local path_tsn = tsnode:field('attrpath')[1]
  local expr_tsn = tsnode:field('expression')[1]

  return get_child_by_tsnode(tsj, path_tsn), get_child_by_tsnode(tsj, expr_tsn)
end

local function get_binding_set(expr_tsn)
  for child in expr_tsn:iter_children() do
    if child:type() == 'binding_set' then
      return child
    end
  end
end

-- NOTE: declared previously, for mutual recursion
function get_single_binding(expr_tsn)
  local binding_set = get_binding_set(expr_tsn)
  if not binding_set then
    return
  end

  local binding

  for child in binding_set:iter_children() do
    if child:named() then
      if child:type() ~= 'binding' or binding then
        return
      end
      binding = child
    end
  end

  return binding
end

local function join_enable(tsn)
  local expr = tsn:field('expression')[1]
  if not expr or expr:type() ~= 'attrset_expression' then
    return false
  end

  local inner = get_single_binding(expr)
  if not inner then
    return false
  end

  local path = inner:field('attrpath')[1]
  local value = inner:field('expression')[1]

  return path ~= nil and value ~= nil
end

local function split_enable(tsn)
  local path = tsn:field('attrpath')[1]
  return path and #get_attr_segments(path) > 1 or false
end

local function omit_non_attrpath(child)
  return child:type() ~= 'attrpath'
end

local function split_attrpath(tsj)
  local path, value = get_binding_parts(tsj)
  if not path or not value then
    return
  end

  local segments = get_attr_segments(path:tsnode())
  if #segments < 2 then
    return
  end

  local preset = tsj:preset('split') or {}
  local recursive = preset.recursive
  if recursive then
    local head = segments[1]
    local tail = { unpack(segments, 2) }

    path:update_text(head)
    value:update_text(build_nested_attrset(tail, value:text()))
    return
  end

  local boundary = get_cursor_boundary_index(path:tsnode())
  -- If cursor isn't on a dot, keep previous behaviour (split the rightmost attr)
  if not boundary or boundary <= 0 or boundary >= #segments then
    boundary = #segments - 1
  end

  local left = { unpack(segments, 1, boundary) }
  local right = { unpack(segments, boundary + 1) }

  path:update_text(merge_segments(left))

  local new_value = string.format('{ %s = %s; }', merge_segments(right), value:text())
  value:update_text(new_value)
end

local function join_attrpath(tsj)
  local path, value = get_binding_parts(tsj)
  if not path or not value then
    return
  end

  local expr_tsn = value:tsnode()
  if expr_tsn:type() ~= 'attrset_expression' then
    return
  end

  local preset = tsj:preset('join') or {}
  local recursive = preset.recursive

  if recursive then
    local segments, final_expr = collect_binding_chain(tsj:tsnode())
    if not final_expr or vim.tbl_isempty(segments) then
      return
    end

    path:update_text(merge_segments(segments))
    value:update_text(get_node_text(final_expr))

    -- Prevent subsequent recursive formatting from re-processing the already
    -- flattened chain.
    tsj:update_preset({ recursive_ignore = { 'binding', 'binding_set' } }, 'join')
  else
    local inner = get_single_binding(expr_tsn)
    if not inner then
      return
    end

    local inner_path = inner:field('attrpath')[1]
    local inner_value = inner:field('expression')[1]
    if not inner_path or not inner_value then
      return
    end

    local merged_path = merge_segments(
      get_attr_segments(path:tsnode()),
      get_attr_segments(inner_path)
    )

    path:update_text(merged_path)
    value:update_text(get_node_text(inner_value))
  end
end

return {
  list_expression = lang_utils.set_preset_for_list({
    both = {
      separator = '',
    },
  }),
  attrset_expression = {
    target_nodes = { 'binding_set' },
  },
  binding = lang_utils.set_default_preset({
    both = {
      omit = { omit_non_attrpath },
    },
    split = {
      enable = split_enable,
      format_tree = split_attrpath,
    },
    join = {
      enable = join_enable,
      format_tree = join_attrpath,
      allow_join_on_single_line = true,
      recursive = false,
    },
  }),
  binding_set = lang_utils.set_preset_for_dict({
    both = {
      non_bracket_node = true,
      separator = '',
      force_insert = ';',
    },
  }),
  formals = lang_utils.set_preset_for_args({
    both = {
      omit = { 'formal', 'ellipses' },
    },
    split = {
      separator = '',
      inner_indent = 'normal',
    },
    join = {
      separator = ',',
      space_in_brackets = true,
    },
  }),
  let_expression = lang_utils.set_default_preset({
    both = {
      omit = { 'binding_set' },
    },
    split = {
      recursive = true,
      inner_indent = 'normal',
      last_indent = 'inner',
    },
    join = {
      space_in_brackets = true,
      space_separator = true,
    },
  }),
}
