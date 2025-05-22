# DepCopy - Function Dependency Collector for Neovim

A Neovim plugin that recursively extracts function definitions and their dependencies using TreeSitter and LSP, perfect for code analysis, documentation, and to trim down context for LLM..

## Features

- **Smart Function Detection**: Uses TreeSitter to accurately identify function definitions under cursor
- **Recursive Dependency Resolution**: Follows function calls using LSP to collect all dependencies
- **Project Boundary Enforcement**: Automatically stops at virtual environments and non-project files
- **Structured Output**: Saves all collected functions with file paths to `/tmp/depcopy.txt`
- **Configurable**: Customizable recursion depth, whitelist/blacklist paths, and debug logging
- **Cursor State Management**: Automatically returns to original position after processing

## Installation
Vim Plug:
```vim
Plug 'DhirajBhakta/depcopy.nvim'
```

## Basic Usage

1. Position your cursor anywhere within a function definition
2. Run the command or call the function programmatically
3. Check `/tmp/depcopy.txt` for the collected function definitions

### Lua API

```lua
-- Collect dependencies for function under cursor
require("depcopy").copy_func_with_deps()
```

### Creating a Command

Add this to your Neovim configuration:

```lua
vim.api.nvim_create_user_command('DepCopy', function()
  require('depcopy').copy_func_with_deps()
end, { desc = 'Copy function and its dependencies' })
```

### Creating a Keybinding

```lua
vim.keymap.set('n', '<leader>dc', function()
  require('depcopy').copy_func_with_deps()
end, { desc = 'Copy function dependencies' })
```

## Configuration

```lua
require("depcopy").setup({
  -- Maximum recursion depth to prevent infinite loops
  recursionDepth = 3,

  -- Enable detailed debug logging
  debug = false,

  -- Only process files matching these paths (empty = all project files)
  whitelist = {
    "/path/to/specific/directory",
    "/another/allowed/path"
  },

  -- Never process files matching these paths
  blacklist = {
    "/path/to/exclude",
    "test_files/"
  }
})
```

## Output Format

The plugin saves results to `/tmp/depcopy.txt` in the following format:

```
FILE: /path/to/your/project/main.py
``py
def main_function(param1, param2):
    """Main function documentation."""
    result = helper_function(param1)
    return process_data(result, param2)
``
===


FILE: /path/to/your/project/helpers.py
``py
def helper_function(data):
    """Helper function documentation."""
    return validate_input(data) * 2
``
===
```

## How It Works

1. **Function Detection**: Uses TreeSitter to identify the complete function definition under your cursor
2. **Call Analysis**: Scans the function body for all function calls using TreeSitter AST traversal
3. **LSP Navigation**: Places cursor on each function call and uses LSP's "go to definition" to jump to dependencies
4. **Recursive Processing**: Repeats the process for each discovered function
5. **Boundary Checking**: Automatically stops when encountering:
   - Virtual environment paths (`.venv/`, `venv/`, `site-packages/`, etc.)
   - Files outside the current project directory
   - Paths in the blacklist
   - Maximum recursion depth reached

## Requirements

- Neovim 0.8+
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with appropriate language parsers
- Active LSP server for your programming language
- TreeSitter parser for your target language

## Language Support

Currently works for Python, but the TreeSitter-based approach makes it adaptable to any language with:
- Function definition nodes in the syntax tree
- Function call nodes in the syntax tree
- Working LSP server for "go to definition"

## Troubleshooting

### No function detected
- Ensure your cursor is positioned within a function definition
- Verify TreeSitter parser is installed for your language: `:TSInstall python`

### Dependencies not found
- Check that your LSP server is running: `:LspInfo`
- Ensure LSP supports "go to definition" for your language
- Verify function calls are in the same project (not external libraries)

### Debug Mode

Enable debug logging to troubleshoot issues:

```lua
require("depcopy").setup({ debug = true })
```

Check `:messages` for debug logs

# Limitations , TODO
only supports Python functions, but can be extended to handle classes given definition can trimmed down to bare minimum
