# tf-docs.nvim

[![GitHub Release](https://img.shields.io/github/release/mhiro2/tf-docs.nvim?style=flat)](https://github.com/mhiro2/tf-docs.nvim/releases/latest)
[![CI](https://github.com/mhiro2/tf-docs.nvim/actions/workflows/ci.yaml/badge.svg)](https://github.com/mhiro2/tf-docs.nvim/actions/workflows/ci.yaml)

Open the *correct* Terraform documentation for the symbol under your cursor, with workspace-aware resolution:

- Resolves provider **namespace/name** from the current module's `required_providers`
- Resolves provider **version** from the workspace's `.terraform.lock.hcl`
- Opens Registry, Developer, or source docs for **provider-backed blocks and modules**
- Optional best-effort deep-link to an **attribute / nested block anchor**

This is designed to eliminate repeated Google searches and reduce context switching while authoring Terraform.

## 🎬 Demo

### Select a supported Terraform block from a list and open docs

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
  - `ephemeral "<TYPE>" "<NAME>" { ... }`
  - `action "<TYPE>" "<NAME>" { ... }`
  - `list "<TYPE>" "<NAME>" { ... }` in `.tfquery.hcl` files
  - `module "<NAME>" { source = "..." }` *(best-effort)*
- 🧭 Resolve provider source (`namespace/name`) from the buffer's module directory
- 🔒 Resolve provider version from the detected workspace root
- 🔗 Best-effort deep linking to the argument/block under cursor (`#anchor`, allowlist-based)
- 🌐 Open URLs via `vim.ui.open()` (cross-platform)
- 📋 Copy resolved URL to clipboard
- 👀 Peek resolved info (URL + trace) in a floating window
- 📋 List all supported Terraform blocks in the current buffer
- 🧪 Print a resolution trace for debugging
- 🧹 Clear internal caches

## ✅ Requirements

- Neovim **0.12+**
- Terraform/HCL Treesitter parser(s) are optional
  - If available, tf-docs uses Treesitter for more accurate cursor context detection
  - Without them, tf-docs falls back to a built-in stateful HCL structure scanner

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
  Resolve a supported block under the cursor and open its documentation URL.
* `:TfDocCopyUrl`
  Resolve and copy the URL to your clipboard.
* `:TfDocDebug`
  Print a resolution trace (module directory, workspace root, provider
  source/version, kind/type, URL). The
  URL is resolved synchronously, so it reflects the registry-corrected slug only
  when it is already cached (see [How the docs slug is resolved](#how-the-docs-slug-is-resolved));
  otherwise it shows the heuristic URL.
* `:TfDocPeek`
  Show a lightweight "peek" UI (resolved URL + trace) in a floating window. Same
  synchronous behavior as `:TfDocDebug` regarding the slug.
* `:TfDocList`
  List all supported Terraform blocks in the current buffer. Select one to open its documentation.
* `:TfDocVersion`
  Display provider versions from the workspace root's `.terraform.lock.hcl` in a floating window.
* `:TfDocClearCache`
  Clear all internal resolution caches. Provider and lockfile caches normally
  refresh themselves when files change, including changes made outside Neovim.

## 🧩 Lua API

For keymaps and integrations, prefer the public functions on the `tf-docs`
module over requiring internal modules (`tf-docs.resolver`, `tf-docs.ui`, …),
whose layout may change without notice. `open`/`copy_url`/`peek`/`list`/`resolve`
take an optional `bufnr` (defaults to the current buffer) followed by an
optional scope `opts` table. `resolve` additionally accepts a precomputed
cursor `context`; `clear_cache` takes no arguments.

```lua
local tf = require("tf-docs")

tf.open()        -- resolve the symbol under the cursor and open its docs
tf.copy_url()    -- resolve and copy the docs URL to the clipboard
tf.peek()        -- show the resolved URL + trace in a floating window
tf.list()        -- pick a supported block in the buffer and open its docs
tf.clear_cache() -- clear all internal resolution caches

-- resolve() returns the URL (or nil) and a trace without opening a browser
-- or showing the "unresolved" notification, so callers can route the result
-- themselves (e.g. K between tf-docs and LSP hover; see Installation).
-- It is synchronous: the URL carries the registry-corrected slug only when
-- that slug is already cached, otherwise the heuristic URL. open/copy_url/list
-- additionally perform the (async) registry lookup before acting.
local url, trace = tf.resolve()

-- Every action accepts explicit scopes for monorepo integrations. Normally
-- these are inferred from the buffer path and root_markers.
local scopes = {
  module_dir = "/repo/modules/network",
  workspace_root = "/repo/environments/production",
}
tf.open(0, scopes)
tf.copy_url(0, scopes)
tf.peek(0, scopes)
tf.list(0, scopes)
url, trace = tf.resolve(0, scopes)
```

The trace distinguishes `module_dir` (where `required_providers` is read) from
`workspace_root` (where `.terraform.lock.hcl` is read).

## ⚙️ Configuration

Default configuration is intentionally conservative. You can override via:

```lua
require("tf-docs").setup({
  -- Workspace-root markers. The nearest marker directory wins; this order only
  -- breaks ties between markers in the same directory.
  root_markers = { ".terraform.lock.hcl", "terraform.tf", "main.tf", ".git" },

  -- Optional monorepo scope hook used by commands and Lua actions.
  scope_resolver = nil,

  default_namespace = "hashicorp",
  default_version = "latest",

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

  -- Resolve the real docs slug via the Terraform Registry API.
  --
  -- The registry doc-page slug is the filename the provider authors chose, not a
  -- deterministic transform of the type: most hashicorp/google resources drop the
  -- prefix (google_compute_instance -> "compute_instance") but some keep it
  -- (google_service_account -> "google_service_account"), and resource vs data
  -- source can differ. When enabled, tf-docs asks the registry for the real slug,
  -- caches it for the session, and only falls back to the prefix-stripping
  -- heuristic if the API does not answer within `registry_timeout_ms`.
  -- Requires `curl`. Set to false to always use the (offline) heuristic.
  enable_registry_lookup = true,
  registry_timeout_ms = 1500,

  -- Module docs (best-effort)
  --
  -- If the cursor is inside:
  --   module "x" { source = "..." }
  -- tf-docs tries to resolve a URL from `source`:
  -- - Terraform Registry modules: "namespace/name/provider" or "registry.terraform.io/..."
  -- - VCS/URL sources: "https://...", "ssh://git@...", "git@host:org/repo",
  --   "github.com/org/repo", and "bitbucket.org/org/repo" are normalized to a
  --   browsable repository URL (the git:: prefix, "?ref=" query, "//subdir",
  --   trailing ".git", and URL credentials are stripped).
  -- Resolved URLs and traces never retain URL userinfo or query parameters.
  -- The source must be a direct, static quoted literal. Input-variable, local,
  -- and other expressions are reported as unresolved instead of being guessed.
  -- If it can't build a URL, it falls back to "unresolved".
  -- Only http(s) URLs are opened; any other scheme is refused.
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

tf-docs treats Terraform's two filesystem scopes separately:

* The **module directory** is the directory containing the current buffer.
  All Terraform configuration files directly in that directory (`*.tf` and
  `*.tf.json`) are scanned for `required_providers`. Modified in-memory files,
  including new buffers that do not exist on disk yet, take precedence over
  disk.
* The **workspace root** is found by walking upward from the module directory.
  The nearest directory containing any `root_markers` entry wins; marker order
  only breaks ties in the same directory. Its `.terraform.lock.hcl` supplies
  provider versions.

For file discovery and ordering, tf-docs follows Terraform's loading rules:
basenames starting with `.`, ending with `~`, or wrapped in `#` are ignored;
normal files are processed first; and `override.tf`, `override.tf.json`,
`*_override.tf`, and `*_override.tf.json` are applied
afterward in filename order. A provider declaration without an explicit
`source` clears an earlier source and uses the implied `hashicorp/<local-name>`
address.

For monorepos where path-based discovery is insufficient, `scope_resolver`
can return `module_dir`, `workspace_root`, or both for each buffer. It applies
to `:TfDocOpen`, `:TfDocCopyUrl`, `:TfDocDebug`, `:TfDocPeek`, `:TfDocList`, and
`:TfDocVersion`, as well as the Lua actions. Explicit Lua action options take
precedence over the callback, and any still-missing field is discovered
automatically.

For example, a callback can read a buffer-local scope set by another plugin:

```lua
require("tf-docs").setup({
  scope_resolver = function(bufnr)
    -- { module_dir = "/repo/module", workspace_root = "/repo/env" }
    return vim.b[bufnr].tf_docs_scope
  end,
})
```

For a type like `google_compute_instance`:

1. Provider name is inferred from the prefix: `google`
   - If `provider = <alias>` is set in the block, that alias is preferred
2. The module directory's `required_providers` is consulted to resolve
   `source = "namespace/name"`
3. The workspace root's `.terraform.lock.hcl` is consulted to resolve the version
4. URL is generated for that `(namespace, name, version)` and opened

Terraform's exact built-in types bypass this provider flow and Registry lookup:

* `terraform_data` opens the official Terraform Developer resource page
* `terraform_remote_state` opens the official Terraform Developer data-source page

Their trace reports `terraform.io/builtin/terraform` as the provider source.

Fallbacks:

* If `required_providers` is missing: `hashicorp/<provider>` (configurable)
* If lockfile is missing: `latest` (configurable)
* If the provider has no version entry in `.terraform.lock.hcl`, or has more
  than one, tf-docs still resolves a URL using the fallback (or first) version
  and an info-level notice explains which fallback was used

### How the docs slug is resolved

The last path segment of a docs URL (the "slug") is **not** a deterministic
transform of the provider-backed block type — it is the documentation filename the
provider authors chose. Most resources drop the provider prefix
(`google_compute_instance` → `compute_instance`), but some keep it
(`google_service_account` → `google_service_account`), and the same name can
differ between a resource and a data source.

With `enable_registry_lookup = true` (default), tf-docs asks the Terraform
Registry API for the real slug, trying the prefix-stripped slug first and then
the full type name, and caches the answer for the session. If the API does not
respond within `registry_timeout_ms`, it falls back to the prefix-stripping
heuristic so opening docs never blocks — the network result still backfills the
cache, so the next open for that provider version is instant and correct.

This requires `curl` and only applies to the public Terraform Registry
(`namespace/name` sources). Set `enable_registry_lookup = false` to always use
the offline heuristic.

### Provider hints and overrides

If a provider-backed block includes `provider = <alias>`, tf-docs prefers that
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

### Ephemeral resource, action, and list resource

`ephemeral` requires Terraform 1.10+; `action` and `list` require Terraform 1.14+.

```hcl
ephemeral "aws_ssm_parameter" "database_password" {
  name = "/secrets/database/password"
}

action "aws_events_put_events" "publish" {
  config {
    # ...
  }
}

# In a .tfquery.hcl file
list "aws_vpc" "existing" {
  provider = aws
}
```

These open the corresponding provider documentation categories:

* `.../docs/ephemeral-resources/ssm_parameter`
* `.../docs/actions/events_put_events`
* `.../docs/list-resources/vpc`

### Terraform built-ins

```hcl
resource "terraform_data" "bootstrap" {
  input = "ready"
}

data "terraform_remote_state" "network" {
  backend = "local"
}
```

These exact built-in types open their official Terraform Developer pages rather
than the discontinued `hashicorp/terraform` provider pages:

* `https://developer.hashicorp.com/terraform/language/resources/terraform-data`
* `https://developer.hashicorp.com/terraform/language/state/remote-state-data`

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

### “No supported Terraform block under cursor”

* Ensure your buffer filetype is `terraform` or `hcl`:

  * `:set filetype?`
* If detection is inaccurate in complex files, ensure a `terraform` or `hcl` Treesitter parser is available on your `runtimepath`

### Wrong provider namespace or version

* Check `:TfDocDebug` output
* Ensure:

  * `terraform { required_providers { ... } }` exists in a `.tf` or `.tf.json`
    file directly in the module directory
  * `.terraform.lock.hcl` exists in the detected workspace root
* For monorepos, inspect both `module directory` and `workspace root` in
  `:TfDocDebug`. The nearest marker directory wins; use `scope_resolver` for
  commands or explicit scope options on any Lua action when an integration
  needs different scopes.

### Cache invalidation

tf-docs caches parsed `required_providers`, lockfile data, Registry responses,
and Treesitter context. Required-provider and lockfile entries carry filesystem
signatures, so creation, replacement, and updates made by `terraform init`, Git,
another editor, or a terminal are detected on the next resolution. Negative
entries for missing files refresh when those files appear. Modified in-memory
`.tf` and `.tf.json` module files take precedence over disk, including new
buffers that have not been saved yet.

The cache is also proactively cleared when you write:

* `.terraform.lock.hcl`
* any `.tf` or `.tf.json` file

You can clear every cache manually with `:TfDocClearCache` when troubleshooting.

### Health check

Use `:checkhealth tf-docs` to verify your environment (Neovim version, `vim.ui.open`, optional Treesitter parser availability).

### Linux/macOS/Windows open behavior

* This plugin uses `vim.ui.open()` (available since Neovim 0.10.0).
* If `vim.ui.open()` fails, tf-docs logs the error via `vim.notify` (see `:messages`).
* If your system cannot open URLs, verify your Neovim build and OS integration.

## ❓ FAQ

### Why not just use Terraform CLI for schema?

This plugin focuses on opening the right Terraform documentation quickly and avoids external dependencies by default.

### Isn’t there already a plugin for this?

Yes—several plugins open Terraform docs. `tf-docs.nvim` differentiates by being **workspace-aware** (namespace + lockfile version) and by focusing on cursor-context-first UX.

## 📄 License

MIT License. See [LICENSE](./LICENSE).
