--- keybindings/tree.lua
--- Stateless operations on the binding tree data structure.
--- Provides construction, lookup, and traversal functions
--- for hierarchical keybinding nodes (groups, actions, sticky).

local BindingTree = {}

---------------------------------------------------------------------------
-- Key normalization
---------------------------------------------------------------------------

--- Normalize a key + modifiers into a unique lookup string.
--- Sorts modifiers alphabetically, joins with "+", appends "+key".
--- The result is used as the key in BindingNode.children tables.
--- @param mods string[]|nil  Array of modifier strings (e.g. {"cmd","shift"})
--- @param key  string        Key name (e.g. "r", "tab", "space")
--- @return string            Normalized key string (e.g. "cmd+shift+r")
function BindingTree.normalizeKey(mods, key)
	local k = string.lower(key)
	if not mods or #mods == 0 then
		return k
	end
	local sorted = {}
	for _, m in ipairs(mods) do
		table.insert(sorted, string.lower(m))
	end
	table.sort(sorted)
	return table.concat(sorted, "+") .. "+" .. k
end

--- Convert eventtap boolean flags to a sorted modifier name array.
--- @param flags { cmd?: boolean, ctrl?: boolean, alt?: boolean, shift?: boolean }
--- @return string[]  Sorted array of active modifier names
function BindingTree.flagsToMods(flags)
	local mods = {}
	for _, name in ipairs({ "alt", "cmd", "ctrl", "shift" }) do
		if flags[name] then
			table.insert(mods, name)
		end
	end
	return mods
end

---------------------------------------------------------------------------
-- Node construction
---------------------------------------------------------------------------

--- Create a new tree node with defaults.
--- @param spec table  Partial node fields (type, key, mods, desc, icon, action, parent, isGlobalHotkey)
--- @return BindingNode
--- @private
local function makeNode(spec)
	return {
		type = spec.type or "group",
		key = spec.key or "",
		mods = spec.mods or {},
		desc = spec.desc or "",
		icon = spec.icon,
		action = spec.action,
		parent = spec.parent,
		children = {},
		isGlobalHotkey = spec.isGlobalHotkey or false,
	}
end

---------------------------------------------------------------------------
-- Tree construction
---------------------------------------------------------------------------

--- Insert a single binding spec into a parent node.
--- Recursively processes group children.
--- @param parent      BindingNode  Parent node to insert into
--- @param spec        table        Binding specification from the user's config
--- @param isRootLevel boolean      Whether parent is the root node
--- @private
local function insertBinding(parent, spec, isRootLevel)
	local mods = spec.mods or {}
	local key = spec.key
	local nk = BindingTree.normalizeKey(mods, key)

	local nodeType
	if spec.group then
		nodeType = "group"
	elseif spec.sticky then
		nodeType = "sticky"
	else
		nodeType = "action"
	end

	local node = makeNode({
		type = nodeType,
		key = string.lower(key),
		mods = mods,
		desc = spec.desc or "",
		icon = spec.icon,
		action = spec.action,
		parent = parent,
		isGlobalHotkey = isRootLevel and #mods > 0,
	})

	parent.children[nk] = node

	if spec.group then
		for _, childSpec in ipairs(spec.group) do
			insertBinding(node, childSpec, false)
		end
	end
end

--- Create a new root node for the binding tree.
--- @return BindingNode  Root group node with no parent
function BindingTree.newRoot()
	return makeNode({ type = "group", key = "", desc = "root" })
end

--- Parse an array of declarative binding specs and insert them into the tree.
--- @param root         BindingNode  Root node
--- @param bindingSpecs table[]      Array of binding spec tables
function BindingTree.addBindings(root, bindingSpecs)
	for _, spec in ipairs(bindingSpecs) do
		insertBinding(root, spec, BindingTree.isRoot(root))
	end
end

---------------------------------------------------------------------------
-- Tree queries
---------------------------------------------------------------------------

--- Find a child node matching a key press.
--- @param node  BindingNode  Current node to search in
--- @param key   string       Key name from event (e.g. "r", "tab")
--- @param flags table        Modifier flags from event:getFlags()
--- @return BindingNode|nil   Matching child node, or nil
function BindingTree.findChild(node, key, flags)
	local mods = BindingTree.flagsToMods(flags or {})
	local nk = BindingTree.normalizeKey(mods, key)
	return node.children[nk]
end

--- Get a sorted array of child nodes for display.
--- Sort order: groups first, then actions, then sticky.
--- Within each type: non-global before global hotkeys.
--- Within each sub-group: alphabetically by key name.
--- @param node BindingNode   Node whose children to list
--- @return BindingNode[]     Sorted array of child nodes
function BindingTree.getChildren(node)
	local list = {}
	for _, child in pairs(node.children) do
		table.insert(list, child)
	end

	local typePriority = { group = 1, action = 2, sticky = 3 }

	table.sort(list, function(a, b)
		local ta = typePriority[a.type] or 99
		local tb = typePriority[b.type] or 99
		if ta ~= tb then
			return ta < tb
		end

		if a.isGlobalHotkey ~= b.isGlobalHotkey then
			return not a.isGlobalHotkey
		end

		return a.key < b.key
	end)

	return list
end

--- Check if a node is the root of the tree.
--- @param node BindingNode  Node to check
--- @return boolean
function BindingTree.isRoot(node)
	return node.parent == nil
end

return BindingTree
