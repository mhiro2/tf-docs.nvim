# tf-docs.nvim

[![GitHub Release](https://img.shields.io/github/release/mhiro2/tf-docs.nvim?style=flat)](https://github.com/mhiro2/tf-docs.nvim/releases/latest)
[![CI](https://github.com/mhiro2/tf-docs.nvim/actions/workflows/ci.yaml/badge.svg)](https://github.com/mhiro2/tf-docs.nvim/actions/workflows/ci.yaml)

Open the *correct* Terraform documentation for the symbol under your cursor, with workspace-aware resolution:

- Resolves provider **namespace/name** from `required_providers`
- Resolves provider **version** from `.terraform.lock.hcl`
- Opens Terraform Registry docs for **resource / data source / module**
- Optional best-effort deep-link to an **attribute / nested block anchor**

This is designed to eliminate repeated Google searches and reduce context switching while authoring Terraform.

## 🎬 Demo

### Select a resource/data source/module from a list and open docs

<img src="https://github.com/user-attachments/assets/3632bc1a-7d29-4e37-83a9-73b94642e9f8" width="100%" alt="TfDocList: list and select" />

### Peek the resolved info without leaving Neovim

<img src="https://github.com/user-attachments/assets/7fce2021-aca3-4205-b8a4-b54fad63e620" width="100%" alt="TfDocPeek: quick preview" />

### Open the docs for the symbol under the cursor

> [!NOTE]
> this opens your external browser via `vim.ui.open()`.

<img src="https://github.com/user-attachments/assets/a3d5f753-caa4-4e6f-8866-e46e66b217e5" width="100%" alt="TfDocOpen: opens browser" />

## ✨ Features

- 🔎 Open the right Terraform docs for the symbol under your cursor:
  - `resource "<TYPE>" "<NAME>" { ... }`
  - `data "<TYPE>" "<NAME>" { ... }`
  - `module "<NAME>" { source = "..." }` *(best-effort)*
- 🧭 Resolve provider source (`namespace/name`) from `required_providers`
- 🔒 Resolve provider version from `.terraform.lock.hcl`
- 🔗 Best-effort deep linking to the argument/block under cursor (`#anchor`, allowlist-based)
- 🌐 Open URLs via `vim.ui.open()` (cross-platform)
- 📋 Copy resolved URL to clipboard
- 👀 Peek resolved info (URL + trace) in a floating window
- 📋 List all resources/data sources/modules in the current buffer
- 🧪 Print a resolution trace for debugging
- 🧹 Clear internal caches

## ✅ Requirements

- Neovim **0.12+**
- Terraform/HCL Treesitter parser(s) are optional
  - If available, tf-docs uses Treesitter for more accurate cursor context detection
  - Without them, tf-docs falls back to built-in line-based parsing

No external commands are required for the default workflow.

## 📦 Installation

Using lazy.nvim:

```lua
{
  "mhiro2/tf-docs.nvim",
  ft = { "terraform", "hcl" },
  config = function()
    require("tf-docs").setup()

    -- Keymaps
    --
    -- Note: many LSP setups map `K` to hover. To avoid conflicts, either:
    -- 1) Use a different key:
    vim.keymap.set("n", "gK", "<cmd>TfDocOpen<cr>", { desc = "Terraform: open docs" })
    --
    -- 2) Or keep `K` and route it (tf-docs -> hover).
    --
    -- Important: if your LSP config sets `K` in `on_attach`, it will override a FileType
    -- mapping. In that case, bind after LSP attaches via `LspAttach` (this wins reliably):
    --
    -- vim.api.nvim_create_autocmd("LspAttach", {
    --   callback = function(args)
    --     local buf = args.buf
    --     local ft = vim.bo[buf].filetype
    --     if ft ~= "terraform" and ft ~= "hcl" then
    --       return
    --     end
    --
    --     -- Ensure we run after other attach handlers
    --     vim.schedule(function()
    --       vim.keymap.set("n", "K", function()
    --         local tf = require("tf-docs")
    --         -- resolve() returns (url|nil, trace) without opening anything,
    --         -- so we can route to LSP hover when there's no docs to open.
    --         local url = tf.resolve(0)
    --         if url and url ~= "" then
    --           tf.open(0)
    --           return
    --         end
    --         if vim.lsp and vim.lsp.buf and vim.lsp.buf.hover then
    --           vim.lsp.buf.hover()
    --         end
    --       end, { buffer = buf, desc = "Terraform: docs or hover" })
    --     end)
    --   end,
    -- })

    vim.keymap.set("n", "gY", "<cmd>TfDocCopyUrl<cr>", { desc = "Terraform: copy docs URL" })
  end,
}
```

If you want the optional Treesitter-based context detection, make sure a `terraform` or `hcl` parser is available on your `runtimepath`. With Neovim 0.12 this can be provided by any parser manager or by manually placing `parser/terraform.*` or `parser/hcl.*` on the `runtimepath`.

Now place the cursor inside a Terraform block and press `gK` (or `K` if you opted into the routing mapping above).

## 🧰 Commands

* `:TfDocOpen`
  Resolve context (resource/data/module) and open the Terraform Registry URL.
* `:TfDocCopyUrl`
  Resolve and copy the URL to your clipboard.
* `:TfDocDebug`
  Print a resolution trace (root, provider source/version, kind/type, final URL).
* `:TfDocPeek`
  Show a lightweight "peek" UI (resolved URL + trace) in a floating window.
* `:TfDocList`
  List all resources/data sources/modules in the current buffer. Select one to open its documentation.
* `:TfDocVersion`
  Display resolved provider versions from `.terraform.lock.hcl` in a floating window.
* `:TfDocClearCache`
  Clear internal caches (root/provider/lockfile resolution). Use this after changing `required_providers` or `.terraform.lock.hcl`.

## 🧩 Lua API

For keymaps and integrations, prefer the public functions on the `tf-docs`
module over requiring internal modules (`tf-docs.resolver`, `tf-docs.ui`, …),
whose layout may change without notice. `open`/`copy_url`/`peek`/`list`/`resolve`
take an optional `bufnr` (defaults to the current buffer); `resolve` also
accepts an `opts` table, and `clear_cache` takes no arguments.

```lua
local tf = require("tf-docs")

tf.open()        -- resolve the symbol under the cursor and open its docs
tf.copy_url()    -- resolve and copy the docs URL to the clipboard
tf.peek()        -- show the resolved URL + trace in a floating window
tf.list()        -- pick a resource/data/module in the buffer and open its docs
tf.clear_cache() -- clear internal caches (root/provider/lockfile resolution)

-- resolve() returns the URL (or nil) and a trace without opening a browser
-- or showing the "unresolved" notification, so callers can route the result
-- themselves (e.g. K between tf-docs and LSP hover; see Installation).
local url, trace = tf.resolve()
```

## ⚙️ Configuration

Default configuration is intentionally conservative. You can override via:

```lua
require("tf-docs").setup({
  -- Root detection markers (priority order; first match wins).
  root_markers = { ".terraform.lock.hcl", "terraform.tf", "main.tf", ".git" },

  default_namespace = "hashicorp",
  default_version = "latest",

  -- Files to scan for required_providers (best-effort, per root)
  required_providers_files = { "versions.tf", "providers.tf", "main.tf", "terraform.tf" },

  -- Best-effort attribute/block anchor links
  enable_anchor = true,
  anchor_providers_allowlist = {
    "hashicorp/aws",
    "hashicorp/google",
    "hashicorp/azurerm",
  },

  -- Override inferred provider name.
  -- Example: { google-beta = "google" }
  provider_overrides = {},

  -- Module docs (best-effort)
  --
  -- If the cursor is inside:
  --   module "x" { source = "..." }
  -- tf-docs tries to resolve a URL from `source`:
  -- - Terraform Registry modules: "namespace/name/provider" or "registry.terraform.io/..."
  -- - VCS/URL sources: "https://...", "ssh://...", "git@..." (with light cleanup)
  -- If it can't build a URL, it falls back to "unresolved".
  enable_module_docs = true,

  -- UI backend for selection (e.g., `:TfDocList`).
  -- "auto": Detect and use external UI plugins (telescope/fzf-lua/snacks) if available, otherwise use built-in.
  -- "builtin": Always use built-in simple float window UI.
  ui_select_backend = "auto", -- "auto" | "builtin"

  -- Notification threshold. Useful when debugging (`:TfDocDebug`), otherwise you can ignore it.
  log_level = "warn", -- "debug" | "info" | "warn" | "error"
})
```

### How provider resolution works

For a type like `google_compute_instance`:

1. Provider name is inferred from the prefix: `google`
   - If `provider = <alias>` is set in the block, that alias is preferred
2. `required_providers` is consulted to resolve `source = "namespace/name"`
3. `.terraform.lock.hcl` is consulted to resolve the version
4. URL is generated for that `(namespace, name, version)` and opened

Fallbacks:

* If `required_providers` is missing: `hashicorp/<provider>` (configurable)
* If lockfile is missing: `latest` (configurable)

### Provider hints and overrides

If a resource/data block includes `provider = <alias>`, tf-docs prefers that
alias when inferring the provider. You can normalize aliases via
`provider_overrides` before URL building (e.g. `google-beta` -> `google`).

### UI customization for `:TfDocList`

The `:TfDocList` command uses a built-in simple float window UI by default. You can customize this behavior:

* **Auto (default)**: Automatically detects and uses external UI plugins if installed:
  - `telescope-ui-select.nvim`
  - `fzf-lua` (with `ui_select = true`)
  - `snacks.nvim` (picker)
* **Built-in**: Always use the built-in cursor-relative float window

If you prefer a specific UI:

```lua
require("tf-docs").setup({
  ui_select_backend = "builtin", -- or "auto" (default)
})
```

The built-in UI supports:
- Navigation: `j`/`k` or `<C-n>`/`<C-p>`
- Confirm: `<CR>`
- Cancel: `<Esc>` or `q`

## 📚 Examples

### Resource

```hcl
resource "google_compute_instance" "vm" {
  # cursor anywhere inside this block
}
```

Opens:

* `https://registry.terraform.io/providers/hashicorp/google/<version>/docs/resources/compute_instance`

### Data source

```hcl
data "aws_ami" "ubuntu" {
  # ...
}
```

Opens:

* `https://registry.terraform.io/providers/hashicorp/aws/<version>/docs/data-sources/ami`

### Custom provider source

```hcl
terraform {
  required_providers {
    mycloud = {
      source = "mycorp/mycloud"
    }
  }
}

resource "mycloud_instance" "x" {}
```

Opens:

* `https://registry.terraform.io/providers/mycorp/mycloud/<version>/docs/resources/instance`

### Anchors (best-effort)

If your cursor is on `boot_disk` inside `google_compute_instance`, tf-docs may append:

* `#boot_disk-1`

Anchor behavior is not guaranteed across all providers and is intentionally limited by allowlist.

## 🛠️ Troubleshooting

### “No terraform resource/data/module under cursor”

* Ensure your buffer filetype is `terraform` or `hcl`:

  * `:set filetype?`
* If detection is inaccurate in complex files, ensure a `terraform` or `hcl` Treesitter parser is available on your `runtimepath`

### Wrong provider namespace or version

* Check `:TfDocDebug` output
* Ensure:

  * `terraform { required_providers { ... } }` exists in files listed in `required_providers_files`
  * `.terraform.lock.hcl` exists in the detected root
* Monorepo: confirm root detection matches your intended module (marker order wins)

### Cache invalidation

tf-docs caches root/provider/lockfile resolution. The cache is automatically
cleared when you write:

* `.terraform.lock.hcl`
* any file listed in `required_providers_files`

You can also clear caches manually with `:TfDocClearCache`.

### Health check

Use `:checkhealth tf-docs` to verify your environment (Neovim version, `vim.ui.open`, optional Treesitter parser availability).

### Linux/macOS/Windows open behavior

* This plugin uses `vim.ui.open()` (available since Neovim 0.10.0).
* If `vim.ui.open()` fails, tf-docs logs the error via `vim.notify` (see `:messages`).
* If your system cannot open URLs, verify your Neovim build and OS integration.

## ❓ FAQ

### Why not just use Terraform CLI for schema?

This plugin focuses on opening the right Terraform Registry docs quickly and avoids external dependencies by default.

### Isn’t there already a plugin for this?

Yes—several plugins open Terraform docs. `tf-docs.nvim` differentiates by being **workspace-aware** (namespace + lockfile version) and by focusing on cursor-context-first UX.

## 📄 License

MIT License. See [LICENSE](./LICENSE).
