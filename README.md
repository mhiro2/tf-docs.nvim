# tf-docs.nvim

[![GitHub Release](https://img.shields.io/github/release/mhiro2/tf-docs.nvim?style=flat)](https://github.com/mhiro2/tf-docs.nvim/releases/latest)
[![CI](https://github.com/mhiro2/tf-docs.nvim/actions/workflows/ci.yaml/badge.svg)](https://github.com/mhiro2/tf-docs.nvim/actions/workflows/ci.yaml)

Open the *correct* Terraform documentation for the symbol under your cursor, with workspace-aware resolution:

- Resolves provider **namespace/name** from `required_providers`
- Resolves provider **version** from `.terraform.lock.hcl`
- Opens Terraform Registry docs for **resource / data source / module**
- Optional best-effort deep-link to an **attribute / nested block anchor**

This is designed to eliminate repeated Google searches and reduce context switching while authoring Terraform.

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
- 🧪 Print a resolution trace for debugging
- 🧹 Clear internal caches

## ✅ Requirements

- Neovim **0.10+**
- `nvim-treesitter` with Terraform/HCL parser(s)
  - Most users should install the `terraform` parser
  - Some environments also benefit from the `hcl` parser
  - Install parsers via `:TSInstall terraform` (and optionally `:TSInstall hcl`)

No external commands are required for the default workflow.

## 📦 Installation

Using lazy.nvim:

```lua
{
  "mhiro2/tf-docs.nvim",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
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
    --         local ok_resolver, resolver = pcall(require, "tf-docs.resolver")
    --         local ok_ui, ui = pcall(require, "tf-docs.ui")
    --         if ok_resolver and ok_ui then
    --           local ok, url = pcall(function()
    --             local u = resolver.resolve(0) -- url|nil, trace
    --             return u
    --           end)
    --           if ok and url and url ~= "" then
    --             ui.open(url)
    --             return
    --           end
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

If you manage Treesitter parsers via `ensure_installed`, you can also do:

```lua
require("nvim-treesitter.configs").setup({
  ensure_installed = { "hcl", "terraform" },
})
```

Now place the cursor inside a Terraform block and press `gK` (or `K` if you opted into the routing mapping above).

## 🧰 Commands

* `:TfDocOpen`
  Resolve context (resource/data/module) and open the Terraform Registry URL.
* `:TfDocCopyUrl`
  Resolve and copy the URL to your clipboard.
* `:TfDocDebug`
  Print a resolution trace (root, provider source/version, kind/type, final URL).
* `:TfDocPeek`
  Show a lightweight “peek” UI (resolved URL + trace) in a floating window.
* `:TfDocClearCache`
  Clear internal caches (root/provider/lockfile resolution). Use this after changing `required_providers` or `.terraform.lock.hcl`.

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
* Ensure `nvim-treesitter` parser is installed:

  * `:TSInstall terraform`
  * (optional) `:TSInstall hcl`

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

Use `:checkhealth tf-docs` to verify your environment (Neovim version, `vim.ui.open`, Treesitter parser availability).

### Linux/macOS/Windows open behavior

* This plugin uses `vim.ui.open()` (Neovim 0.10+).
* If `vim.ui.open()` fails, tf-docs logs the error via `vim.notify` (see `:messages`).
* If your system cannot open URLs, verify your Neovim build and OS integration.

## ❓ FAQ

### Why not just use Terraform CLI for schema?

This plugin focuses on opening the right Terraform Registry docs quickly and avoids external dependencies by default.

### Isn’t there already a plugin for this?

Yes—several plugins open Terraform docs. `tf-docs.nvim` differentiates by being **workspace-aware** (namespace + lockfile version) and by focusing on cursor-context-first UX.

## 📄 License

MIT License. See [LICENSE](./LICENSE).
