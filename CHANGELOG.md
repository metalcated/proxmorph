# Changelog

All notable changes to ProxMorph will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Enterprise Slate flagship theme**: adds a professional vCenter/Clarity-inspired workspace for PVE, PBS, and PDM with a blue-gray command shell, dense inventory hierarchy, quiet full-row selection, restrained dark cyan-blue actions, flatter panels, compact menus, coordinated telemetry colors, deliberate typography, keyboard focus states, and reduced-motion support. The implementation uses ProxMorph's current ExtJS/PWT contracts and original assets rather than obsolete vCenter selectors or VMware artwork.
- **Proxmox VE 9.2.6+ compatibility preflight**: validates the package version and every patched runtime contract (`proxmoxlib.js` theme map, index loader/insertion point, and `Nodes.pm` sensor anchor) before modifying Proxmox-owned files. Future versions with unchanged contracts remain supported; changed layouts fail closed.
- **Inventory View for PVE**: adds optional node → resource pool → guest and resource pool → guest hierarchies, plus a modal for showing or hiding VMs, containers, templates, storage, SDN/network resources, stopped guests, and grouping. Includes expand/collapse actions and uses no new browser-local persistence.
- **vCenter-style icon navigation**: optionally replaces the native view picker with Datacenter, Inventory, Storage, and Connectivity icons. Each icon uses the same compact, transparent 34×28 toolbar-button treatment as the surrounding native controls, with explicit optical centering, an accessible name, and a hierarchy tooltip; the controls retain native Proxmox resource routing, with narrowly scoped presentation records only for cluster-wide vNets omitted from the native resource feed.
- **Connections vNet browser**: loads permission-filtered vNets from Proxmox's authenticated SDN endpoint, shows them once at Datacenter level, and routes selection to native Subnets, Permissions, and Edit components without exposing them in unrelated views.
- **Authenticated Inventory View preferences**: saves modal settings per Proxmox username through a protected PVE API and a private pmxcfs JSON file, making the same hierarchy and visibility choices available from every cluster node without browser `localStorage`.
- **Per-view tree expansion memory**: preserves expanded and collapsed resource-tree branches independently while switching among Datacenter, Inventory, Storage, and Connectivity views during the active PVE page session.
- **Tree context expansion actions**: appends **Expand all** / **Collapse all** to the native Datacenter context menu and branch-scoped equivalents to node menus, keeping existing Proxmox actions and the per-view expansion memory intact.
- **Theme-native Inventory settings modal**: organizes navigation, hierarchy, visible resources, and account scope into compact sections; removes the warning-only `.pmx-hint` treatment and uses the selected theme's own surface, border, text, and accent tokens.
- **Per-account typography controls**: adds Proxmox-default and vCenter-inspired native font choices plus 13 px, 14 px, and 15 px content scales. The setting applies across every ProxMorph theme, follows the authenticated PVE account through pmxcfs, preserves Font Awesome icons and monospace consoles, and falls back safely when a saved value is no longer supported.
- **Optional hierarchy emphasis**: adds an account-saved setting that makes the Datacenter or cluster root one text step larger and gives expandable tree branches a slightly stronger weight in ProxMorph themes. It is enabled by default and can be disabled without changing the selected font, text scale, tree structure, or stock Proxmox themes.
- **Shared PVE modernization layer**: gives every ProxMorph PVE theme a fluid semantic component system for stable control density, borderless action toolbars, quiet active surfaces, elevated menus, focused forms, and structured data grids while retaining each theme's own palette.
- **Native noVNC clipboard workflow**: enhances Proxmox's supported `clipboard=vnc` transport with theme-aware toolbar actions, an Option/Alt + right-click console menu that preserves normal guest right-click, and opt-in Ctrl+C/Ctrl+V capture. Clipboard preferences follow the authenticated PVE account while clipboard text remains memory-only and is cleared on disconnect.
- **Full transactional backup and restore**: creates timestamped, checksummed, per-product snapshots before every mutating operation; restores failed/interrupted operations automatically; adds `backup`, `list-backups`, and version-guarded `restore` commands; and preserves remote cluster sensor files before deployment.
- **Baseline-driven full uninstall**: restores the clean pre-install snapshot when package versions match, retains an uninstall rollback snapshot, and safely reinstalls the current web packages when a same-version baseline is unavailable.
- **No-write dry run**: accepts `--dry-run` before or after supported commands; validates runtime and backup integrity, resolves restore IDs, and previews planned backup/file/package/service/remote-node actions without creating even an operation lock.

### Changed
- Bumped the installer version to 2.21.2.
- **Enterprise Slate interaction palette**: reserves its darker cyan-blue for primary actions, links, meters, and deliberate hover states. Selection surfaces are now neutral blue-gray, form and keyboard focus use a slate border, and the stationary Documentation action keeps a restrained dark outline.
- **Transactional novnc-pve coverage**: compatibility preflight, dry run, full backup/restore, uninstall, package-version guards, and the APT update hook now cover the noVNC template and ProxMorph console assets.
- **Simplified PVE sensor setup**: replaces the manual `apt install lm-sensors && sensors-detect` prerequisite and sensor-filter follow-up with one informed opt-in. ProxMorph installs `lm-sensors` noninteractively, reuses existing readings, and only runs `sensors-detect --auto` when required; individual filtering remains available through `sensors configure`.
- **Sensor package rollback**: backups now record optional `lm-sensors` state and ownership. Transaction rollback, restore, and uninstall reinstate or remove the package as needed while retaining a copy that existed before ProxMorph.
- Inventory View now defaults to guest resources only; storage and connectivity remain available in their dedicated views or can be explicitly enabled in the modal.
- The APT update hook now snapshots newly installed package files before re-patching and restores them automatically if re-patching fails.
- Interactive menu actions now return to the main menu after success, cancellation, or failure instead of ending the installer; command-line subcommands remain one-shot.

### Fixed
- **Uniform icon-switcher rhythm**: gives the native Tree Settings-to-Datacenter gap and Connectivity-to-settings gap the same 4 px spacing already used between the four view buttons.
- **Enterprise Slate selection edges**: removes the cyan leading borders from data rows, resource inventory, object navigation, and PDM lists; removes active-tab edge indicators; and prevents grid focus from drawing a clipped cyan top/right perimeter.
- **Cross-theme icon switcher alignment**: gives the native Tree Settings button, four view shortcuts, and ProxMorph settings button the same 34×28 geometry, removes inherited inner-wrapper padding and borders, centers every Font Awesome glyph in a fixed 16×16 optical box, and compensates for glyph-shape differences without theme-specific offsets.
- **Stock-theme style isolation**: scopes account typography and the shared PVE modernization layer to stylesheets that expose ProxMorph semantic theme tokens. Proxmox's native Default, Light, and Dark themes retain their original account menu, controls, grids, tabs, colors, and spacing after ProxMorph is installed.
- **Expanded hardware sensor coverage**: displays selected chipset, NIC, ACPI, additional NVMe temperature, and power-meter readings instead of silently ignoring them. Sensor detection and configuration list those readings, and multi-socket CPU packages are labeled individually.
- **Expandable navigation subsections**: backports upstream `e0bc882` across all 20 non-UniFi themes. Selected-item text and icon colors now target only the selected item's direct row, so nested VM, container, Firewall, Permissions, HA, and SDN entries retain readable theme colors.
- **Typography-driven toolbar overlap**: keeps control padding inside ExtJS-measured widths and refreshes the application layout as soon as saved account typography loads, preventing header actions from colliding at larger text sizes.
- **Large-text action-bar stability**: allows navigation, resources, menus, and data content to reach 15 px while capping compact action labels at 14 px and keeping their measured chrome at 30 px. This prevents the large setting from stretching fixed ExtJS toolbars into adjacent controls.
- **Duplicate action and tab highlighting**: removes the modernization layer's active underline, theme-provided tab underline pseudo-elements, split-button seams, and docked-toolbar bottom rule. Active actions and tabs now use one restrained theme-tinted surface.
- **Uniform data-row selection**: replaces the rounded first-cell pill and accent edge with one continuous, theme-tinted row background across type and value cells.
- **Focused hardware icon overlap**: keeps SVG-backed hardware and resource icons in the row's flex layout when ExtJS marks the selected cell as focused, preventing the icon from becoming absolutely positioned over its label.
- **Modern-font legibility**: sets the vCenter-inspired interface to a deliberate 400 body weight with native font smoothing, while retaining 500-weight section headings. This avoids the inherited 300-weight rendering that made dark-theme labels and values appear faint.
- **Hardware and resource row alignment**: vertically centers image and Font Awesome icons with their labels and values, preserves row height across selection, and restores a subtle divider between type and value columns.
- **macOS browser context-menu leak**: remembers the detected Option + secondary-click through Safari's later `contextmenu` event, which can report different button/modifier details, and suppresses the browser menu without affecting normal guest right-click. Unavailable clipboard actions now state the required VM Display setting, guest vdagent, and full stop/start directly in the console menu.
- **noVNC enhancement startup**: initializes from the stable `noVNC_container` instead of waiting for a nonexistent `noVNC_canvas` ID. Upstream noVNC creates its un-ID'd canvas dynamically after page startup, which previously caused every ProxMorph console enhancement to exit before binding. The install and APT-hook compatibility checks now validate the stable container contract.
- **macOS noVNC clipboard menu gesture**: replaces the browser-reserved Shift + right-click trigger with Option/Alt + right-click and intercepts the full modified secondary-click sequence before noVNC, preventing both the native browser menu and an unintended guest click.
- **Complete appearance coverage for PVE detail views**: extends account-selected typography to the VM/CT navigation treelist, default ExtJS menu/button/form/title subclasses, tags, progress text, empty states, and floating layers. Menus, dropdowns, tooltips, navigation labels, headers, and empty states now resolve their base colors through each ProxMorph theme's semantic tokens while preserving theme-specific hover, selected, and accent states.
- **Native context-menu regression**: appends tree actions through the existing Datacenter and node menu item configurations instead of overriding their initialization methods, restoring the original Proxmox right-click menus.
- **Red tree-corner marker**: commits the presentation-only hostname label after switching icon views so ExtJS does not render its red unsaved-record indicator on the Datacenter row.
- **Powered-off guest visibility control**: restores the compact modal's easily missed `Stopped guests` checkbox as an explicit full-width **Show powered-off VMs and containers** control while retaining the same account-saved preference and filtering behavior.
- **Missing Connections vNets**: supplements the native cluster resource feed, which contains zones and fabrics but omits vNet configuration records, while preserving a safe zones/fabrics-only fallback if the endpoint or UI contracts change.
- **PDM Catppuccin Frappé and Macchiato**: restored the missing dark-mode semantic selector so their surface variables are valid CSS and apply on Proxmox Datacenter Manager.
- **Stale PDM restore protection**: `reinstall` no longer copies the original first-install `index.hbs` over a newer PDM package; it restores the currently installed UI package before reapplying themes.

## [2.8.1] - 2026-07-19

### Added
- **Release checksums and provenance**: every release now publishes a `SHA256SUMS` manifest and a GitHub build-provenance attestation. The installer verifies the downloaded tarball against `SHA256SUMS` and refuses to install on a mismatch or when the manifest is missing (fail closed). Verify a release yourself with `sha256sum -c` and `gh attestation verify` before running; see the README "Verify before you run" section.
- **`PROXMORPH_RELEASE_BASE`**: point the installer at an internal mirror of the release artifacts (air-gapped or policy-controlled installs). Checksum verification still applies against the mirrored `SHA256SUMS`.
- **README audit transparency**: documented exactly what the installer changes on the system, the review-then-run clone path, and honest framing of what checksums vs. attestation guarantee.

### Security
- The release download path is no longer trust-on-first-download: artifacts are integrity-checked against a published manifest before extraction as root.

## [2.8.0] - 2026-07-18

### Added
- **Server-side default theme** (#52): set a default theme for browsers that have not picked one yet with `./install.sh default-theme <key>` (menu option 8). New visitors get the default on first load, a user's own selection always wins. Works on PVE, PBS and PDM, survives Proxmox updates via the APT hook. Clear with `./install.sh default-theme none`.
- **UniFi OLED theme** (#46): true-black variant of UniFi with pure `#000000` backgrounds and a tuned blue accent, built for OLED panels. PVE/PBS + PDM, includes a chart patcher.

## [2.7.3] - 2026-06-12

### Fixed
- **All themes** — Task Viewer window no longer loses its scrollbar. The blanket `.x-window .x-panel-body { overflow: visible !important }` rule was overriding ExtJS's own inline `overflow: auto` on scrollable panel bodies (`.x-scroller`). Fixed by scoping the rule to `:not(.x-scroller)`. Issue [#49](https://github.com/IT-BAER/proxmorph/issues/49)
- **All themes** — CT and VM creation dialog tabs are no longer pushed off-screen. `position: relative !important` on `.x-tab` was overriding ExtJS box layout's absolute positioning, causing each tab's offset to double-count (natural flow position + intended left = tabs spreading ~1.5× wider than the container). Removed the offending declaration. Issue [#50](https://github.com/IT-BAER/proxmorph/issues/50)
- **Catppuccin Latte** — Text on colored elements (progress bar fill, active buttons, badges) is now visible. `--ctp-on-accent` was set to `var(--ctp-base)` (`#eff1f5`, near-white), which is invisible on the light Latte background. Changed to `#ffffff` for proper contrast against vivid Latte accent fills (mauve, red, yellow). Issue [#51](https://github.com/IT-BAER/proxmorph/issues/51)

## [2.7.2] - 2026-04-16

### Fixed
- **Sensors** — Added pre-patch Perl syntax check on Nodes.pm before applying the sensor patch. If Nodes.pm is already broken (e.g. from the v2.7.0 APT-hook heredoc bug), the user now gets an actionable error: *"Run 'apt install --reinstall pve-manager' to restore it, then re-run ProxMorph install."* instead of a misleading post-patch rollback message. Issue [#47](https://github.com/IT-BAER/proxmorph/issues/47)
- **Sensors** — Rollback on post-patch syntax failure now restores from `Nodes.pm.original` backup when available, falling back to sed marker removal only if no backup exists.

## [2.7.1] - 2026-04-05

### Fixed
- **APT Hook** — Fixed broken heredoc escaping in `post-update.sh` that caused the Nodes.pm sensor patch to be injected as a single malformed line, breaking Perl syntax and preventing `pveproxy` from starting after a PVE update. Issue [#45](https://github.com/IT-BAER/proxmorph/issues/45)
  - Added Perl syntax check (`perl -c`) after patching with automatic rollback if validation fails

## [2.7.0] - 2026-04-01

### Added
- **Sensor Selector** — Interactive per-sensor filtering for hardware monitoring. Issue [#44](https://github.com/IT-BAER/proxmorph/issues/44)
  - `enumerate_sensors()` discovers all available sensors (CPU, NVMe, HDD, Fan) via `sensors -j`
  - `configure_sensor_filter()` interactive multi-select menu to choose which sensors to display
  - Filter stored in `/opt/proxmorph/.sensors-filter` (chip:label format), synced to cluster nodes
  - `manage-sensors` menu gains option 4) Configure sensor selection
  - `sensors configure` CLI subcommand for non-interactive reconfiguration
  - Backwards-compatible: missing/empty filter file shows all sensors
- **proxmorph-sensors.js** (v1.2.0) — Client-side sensor filtering
  - Reads `sensorsFilter` from API on each render (no first-load flash)
  - CPU cores shown individually when filter selects specific cores without Package sensor
  - APT hook updated to persist filter across PVE updates

## [2.6.0] - 2026-03-16

### Added
- **Proxmox Datacenter Manager (PDM) Support** — Full theme support for PDM 1.x:
  - New `install.sh` product detection: auto-detects PDM alongside PVE and PBS
  - 22 PDM-specific CSS override themes injected as `<link>` tags into `index.hbs`, activated via JavaScript based on `localStorage` selection
  - `proxmorph-pdm-base.css` — always-on component styling (rounded corners, shadows, button/panel/grid refinements)
  - `pdm-theme-selector.js` — MutationObserver-based patch that injects ProxMorph themes into PDM's native Theme dialog dropdown alongside built-in Desktop/Crisp options
  - PDM themes use CSS custom property overrides to remap `--pwt-color-*` tokens from the WASM-loaded base theme
  - Inline `<script>` in `index.hbs` activates saved theme before WASM loads (prevents flash of default theme)
  - APT hook updated with PDM-specific repatch logic (CSS re-injection + JS patch re-copy)
  - Clean uninstall: removes theme directory, JS patches, and injected `index.hbs` block; restores backup

### Changed
- **Installer** (`install.sh`):
  - Now supports PVE 8.x/9.x, PBS 3.x/4.x, **and PDM 1.x**
  - `manage-sensors` command now shows interactive menu instead of requiring subcommand
  - `verify` command (option 7) added to diagnose installation issues
  - `pveproxy` restart changed from background to synchronous for reliability
  - Prominent cache warning displayed after install/uninstall

### Fixed
- **Catppuccin Latte light theme icon/logo inversions** — Theme was generated from dark Catppuccin Mocha and retained dark-mode `filter: invert()` rules on loading indicators, folder icons, image-based icons (`.fa-ceph`, `.fa-sdn`, `.pve-itype-icon-qemu`, etc.), hardware icons, counter-invert cells, and the Proxmox logo. All are now `filter: none` as required by a light theme.
- **Sensors: Perl taint mode error on node status API** — Issue [#38](https://github.com/IT-BAER/proxmorph/issues/38):
  - The `Nodes.pm` patch now sets `local $ENV{PATH} = '/usr/bin:/bin';` before all backtick (`sensors -j`, `upsc`) calls, satisfying Perl's `-T` taint mode requirement that `$ENV{PATH}` be untainted before external command execution
  - The UPS device name (`$ups_name`), obtained from tainted backtick output, is now validated and untainted via regex (`/^([\w@.-]+)$/`) before being passed to the `upsc` command — prevents an additional taint violation in the UPS data collection path
  - Affected users: anyone running ProxMorph sensors on a Proxmox host where `Nodes.pm` still has the old patch; fix requires re-running `install.sh` (or `install.sh manage-sensors disable && install.sh manage-sensors enable`) to re-apply the corrected patch
- **Sensors: sed regex escaping for UPS untaint** — Issue [#38](https://github.com/IT-BAER/proxmorph/issues/38):
  - GNU sed's `i\` command drops backslash before unknown escapes (`\w` → `w`)
  - `patch_nodes_pm()` bash double-quoted sed now uses 4 backslashes (`\\\\w`)
  - APT hook post-update heredoc (3-level escaping chain) now uses 8 backslashes for correct `\w` output
- **Theme visibility after install** — Issue [#40](https://github.com/IT-BAER/proxmorph/issues/40):
  - Added `verify` command (option 7) to diagnose installation issues (checks theme files, theme_map entries, JS patches, index template)
  - Changed `pveproxy` restart from background (`&`) to synchronous to ensure theme_map changes take effect before user checks browser
  - Added prominent cache warning after install/uninstall reminding users to hard-refresh (Ctrl+Shift+R)
  - Fixed `sed` delimiter in `patch_theme_map` to use `|` instead of `/` for consistency with uninstall path handling
## [2.5.1] - 2026-03-05

### Added
- **Cluster-aware sensor deployment** — Installer now detects PVE cluster nodes and deploys the sensor API patch to all remote nodes automatically
  - Uses `pvecm nodes` to discover cluster members, scp to copy patched `Nodes.pm`, and restarts `pveproxy` on each node
  - Version check ensures local and remote PVE versions match before deploying
  - `sensors disable` cleanly removes the patch from all cluster nodes
  - Prompts before deploying to remote nodes; can be skipped to run `install.sh` on each node individually

### Fixed
- **System Log scroll to bottom** — Issue [#36](https://github.com/IT-BAER/proxmorph/issues/36):
  - Removed `scroll-behavior: smooth !important` from `.x-panel-body-default` in UniFi and UniFi Light themes
  - This CSS rule broke ExtJS's synchronous scroll position tracking — the JournalView `scrollTo()` call would animate instead of applying instantly, causing the position read-back to return 0 and preventing auto-scroll to the newest log entries
  - The `html { scroll-behavior: smooth }` rule is preserved for page-level smooth scrolling
- **Sensor row hidden when not enabled** — Sensor row in node Status panel now hides completely when the API patch is not applied, instead of showing "N/A"
- **Missing VMs/LXCs in backup job dialog** — Issue [#37](https://github.com/IT-BAER/proxmorph/issues/37):
  - The `.x-form-trigger-wrap-default` height rule (`height: 28px !important`) was matching the VMSelector grid body, collapsing it to a single visible row
  - Added `:not(.x-grid-body)` exclusion to the selector in UniFi and UniFi Light themes

## [2.5.0] - 2026-03-05

### Added
- **Native Hardware Sensor Monitoring** — Issue [#22](https://github.com/IT-BAER/proxmorph/issues/22):
  - New `proxmorph-sensors.js` patch injects CPU/Storage thermal readings, fan speeds, and UPS status directly into the node Summary dashboard
  - Auto-detects `lm-sensors` hardware: coretemp (Intel), k10temp (AMD), NVMe, SATA/drivetemp, and fan sensors
  - Optional UPS monitoring via `upsc` (Network UPS Tools) — shows status, charge, load, and runtime
  - Color-coded temperature warnings (yellow at 80°C, red at 95°C) using theme CSS variables (`--pm-warning`, `--pm-error`)
  - Installer auto-detects available sensors and prompts to enable during `install.sh` — patches `Nodes.pm` API to expose `sensors -j` output
  - Fully optional: can be enabled/disabled independently via `install.sh manage-sensors`
  - Graceful degradation: shows "N/A" when lm-sensors is not installed or no sensors detected
- **UniFi Light Theme** — contributed by [@OiCkilL](https://github.com/OiCkilL) ([PR #34](https://github.com/IT-BAER/proxmorph/pull/34)):
  - Light variant of the UniFi theme with Tier 3 comprehensive coverage
  - Includes custom chart patching (`unifi-light-charts.js`) for consistent light-mode chart colors

### Fixed
- **Blue Slate Theme** — Issue [#25](https://github.com/IT-BAER/proxmorph/issues/25):
  - **Complete v2.0.0 overhaul** — ported all Tier 2 fixes from the Dracula reference theme (1068 → 1568 lines)
  - Fixed close "X" button white background — added `background-color: transparent` on `.x-panel-header-default .x-tool-tool-el` and `.x-window-header-default .x-tool-img`
  - Ported FontAwesome tool icon replacements (close, gear, refresh, collapse/expand, maximize/restore, zoom) with hover, disabled, and inline FA states
  - Added global border-radius architecture (reset-everything/re-apply pattern) replacing simple `border-radius: 6px`
  - Fixed hardware icon text invisible — changed `invert(90%)` → `invert(100%)` with double-cancellation on `.x-grid-cell-inner` children + transparent borders on `<td>` cells
  - Added 28px button height consistency with `:not()` exclusions, `.x-btn-wrap` flex centering, icon-only button fix, `.fa-desktop` translateY (Issue #17 port)
  - Added custom checkbox/radio styling with SVG checkmark and animated radio dot
  - Added dropdown/boundlist fixes: `border: none`, `outline: none`, `cursor: pointer` (Issue #24 port)
  - Added menu item flexbox reordering for icon-left layout (Issue #24 port)
  - Added column panel `max-width: none` fix (Issue #23 port)
  - Added segmented button radius consistency
  - Added console/terminal, legend/chart, progress bar, date picker, tag edit, APT repo, markdown `.pmx-md`, `.pmx-hint`, and usage bar styling
  - Added smooth transitions on grid rows, tree items, menus, boundlists, tabs, splitters, tooltips, progress bars
  - Added Firefox scrollbar support (`scrollbar-width: thin`)
  - Added keyboard focus outline removal, `cursor: pointer` on interactive elements
  - Added `display: none !important` respect for hidden dialog buttons
  - Added login dialog border cleanup
- **20 Themes** — Issue [#24](https://github.com/IT-BAER/proxmorph/issues/24):
  - Fixed dropdown context menu icons aligned to the right instead of left — root cause: CSS targeted non-existent `.x-menu-item-link-default` class; changed selector to `.x-menu-item-default > .x-menu-item-link` across all affected themes
  - Fixed ugly dotted focus borders on boundlist dropdown items (e.g. Server View selector) — added `border: none !important` and `outline: none !important` to `.x-boundlist-item` rules
  - Standardized boundlist item padding (`4px 8px`) and cursor (`pointer`) across all themes for consistent dropdown appearance
- **9 Theme Families** — Issue [#17](https://github.com/IT-BAER/proxmorph/issues/17):
  - Fixed icons misaligned in larger top-bar buttons (Create VM, Create CT, root@pam) across all UniFi-based themes except UniFi itself
  - Ported 5 missing CSS blocks from the UniFi reference: `.x-btn-wrap` flex centering, `.x-btn-inner` flex centering, dropdown arrow alignment, icon-only button fix, and `.fa-desktop` translateY compensation
  - Affected base themes: Catppuccin Mocha, Dracula, Tokyo Night, Nord Dark/Light, Solarized Dark/Light, Gruvbox Dark/Light (plus all generated variants)
- **All Themes (22 files)** — Issue [#18](https://github.com/IT-BAER/proxmorph/issues/18):
  - Fixed panel title text being clipped by removing `overflow: hidden !important` from `.x-panel` rules across all themes
  - Fixed Hardware tab text becoming invisible on SVG-icon rows (`pve-itype-icon-*`) due to `filter: invert()` — changed to `invert(100%)` with double-cancellation on `.x-grid-cell-inner` children for perfect text brightness matching (7 dark themes + variants)
  - Fixed bright border artifacts on inverted Hardware icon rows — added `border-color: transparent !important` on affected `<td>` cells (7 dark themes + variants)
  - Fixed SCSI Controller icon (`fa-database`) being incorrectly dimmed — removed `.fa-database::before` from the broad icon color override selector in all 13 base themes
  - Fixed panel title/header text clipped by border-radius — added `overflow: visible !important` on `.x-title-text`, `.x-title-text-default`, `.x-panel-header`, and `.x-panel-header-default` across all 11 non-UniFi base themes (root cause: global `.x-border-box *` border-radius interacting with ExtJS native `overflow: hidden`)
- **19 Themes** — Issue [#28](https://github.com/IT-BAER/proxmorph/issues/28):
  - Fixed table hover/selection border-radius inconsistencies — removed `border-radius: var(--pm-radius-lg) !important` from `.x-grid-item-over` and `.x-grid-item-selected` rules across all derivative themes (Catppuccin ×5, Dracula ×6, Nord ×2, Solarized ×2, Gruvbox ×2, Tokyo Night, Blue Slate)
  - Removed dedicated `border-radius: 8px !important` grid rounding block from GitHub Dark
  - Root cause: UniFi's rounded hover/selection looked fine with its complex grid handling, but derivatives ported the radius without the supporting rules, causing visual artifacts (hover backgrounds bleeding into adjacent row borders)
  - Fixed hardware grid icon rendering across all 17 dark themes — replaced `filter: invert(100%)` + counter-invert approach with CSS `mask-image` SVG rendering for all `pve-itype-icon-*` (VM Hardware) and `pmx-itype-icon-*` (LXC Resources) grid cells; icons now render original SVG shapes in theme text color via `background-color: currentColor` with proper spacing matching FontAwesome icons (18px width, 10px right margin)
  - Fixed LXC Resources tab darkened text on Memory and Cores rows — PVE 9.x uses `pmx-itype-icon-*` classes (not `pve-itype-icon-*`) on LXC Resources grid cells; the Issue #18 fix only targeted `pve-` prefixed selectors
  - Icon types covered: cpu, memory, cdrom, pci, serial, die (VM Hardware via `/pve2/images/*.svg`) + processor, memory (LXC Resources via `../images/*.svg`)
  - Fixed grid container border-radius clipping first/last row hover backgrounds — removed `border-radius: 12px !important` from `.x-panel-default .x-grid` and `.x-container .x-grid-view` selectors (keeping only `.pve-info-grid`), and changed `.x-grid, .x-grid-view` re-apply rule from `var(--pm-radius-lg)` to `0` across all 22 themes; root cause: `overflow: hidden` on `.x-grid` combined with `border-radius` clipped hover/selection backgrounds at rounded corners of first and last grid rows
- **All Themes (21 files)** — Issue [#30](https://github.com/IT-BAER/proxmorph/issues/30):
  - Fixed toolbar buttons (Shutdown, Console, More, etc.) vibrating/changing width when dropdown menus open — added `padding: 4px 8px !important` to `.x-btn-default-toolbar-small.x-btn.x-btn-menu-active` and `.x-btn-default-toolbar-small.x-btn.x-btn-pressed` rules across all themes; root cause: ExtJS default CSS increases padding from `4px 8px` to `4px 10px` on menu-active/pressed state, causing a 4px total width increase

## [2.4.1] - 2026-02-26

### Added
- **All Themes (19 files)** — Ported FontAwesome tool icon replacements from UniFi v5.86:
  - Replaced sprite-based ExtJS tool icons (close, gear, refresh, collapse/expand, maximize/restore, zoom) with crisp FontAwesome glyphs
  - Added hover, disabled, and inline FontAwesome states for consistent tool icon theming

### Fixed
- **All Themes (21 files)** — Fixed Documentation button height mismatch (Issue [#15](https://github.com/IT-BAER/proxmorph/issues/15)):
  - Documentation/Help inline buttons (`proxmox-inline-button`) were 24px while Create VM/CT/root buttons were 28px — added explicit `height: 28px`, `display: flex`, `align-items: center`, and consistent padding to `.proxmox-inline-button` across all themes
- **All Themes (19 files)** — Issue [#23](https://github.com/IT-BAER/proxmorph/issues/23):
  - Fixed summary panel data values (Status, CPU, Memory, etc.) being invisible on node/VM/storage summary pages — removed `max-width: calc(50% - 10px)` constraint on `.x-panel.x-column` that clipped ExtJS-calculated inner widths, restoring native stacked vertical layout
- **UniFi Theme** — Issue [#19](https://github.com/IT-BAER/proxmorph/issues/19), Issue [#20](https://github.com/IT-BAER/proxmorph/issues/20):
  - Fixed Maximum/Average segmented toggle buttons having incorrect rounded interior corners and hover border overlapping adjacent button
  - Fixed hover glow effect on Max/Avg toggle being cut off due to missing padding/overflow
- **Blue Slate Theme** — Issue [#26](https://github.com/IT-BAER/proxmorph/issues/26):
  - Fixed inconsistent dotted borders between dropdown list elements
- **UniFi Theme** (v5.94) — Issue [#11](https://github.com/IT-BAER/proxmorph/issues/11):
  - Fixed PBS summary panel clipping after "Boot Mode" row — reduced widget padding (5px→3px) and added PBS-specific body padding rule
  - Fixed CPU/RAM icons not loading on PBS — changed absolute paths (`/pve2/`, `/pwt/`) to relative paths (`../images/`) for PVE+PBS compatibility
  - Fixed grid status icons (`.good`/`.warning`/`.critical`) showing grey instead of green/yellow/red — added specificity-matched color overrides after the broad `.fa` color rule
  - Increased navigation tree icon-to-label gap (margin-left 20px→28px) for better readability

## [2.4.0] - 2026-02-25

### Added
- **7 New Theme Collections** — contributed by [@W0CHP](https://github.com/W0CHP) ([PR #12](https://github.com/IT-BAER/proxmorph/pull/12)):
  - Gruvbox Dark — warm retro groove colors with yellow accent
  - Gruvbox Light — light variant of Gruvbox palette
  - Nord Dark — arctic, bluish-cold palette from Nord
  - Nord Light — light variant of Nord palette
  - Solarized Dark — dark variant of precision colors for machines
  - Solarized Light — light variant of Solarized palette
  - Tokyo Night — dark theme inspired by Tokyo's neon lights

### Changed
- **Installer** (`install.sh`) — contributed by [@W0CHP](https://github.com/W0CHP):
  - Now prioritizes local script directory over `/opt/proxmorph` cache for development workflows
  - Syncs themes and JS patches to `/opt/proxmorph/` cache when installing from local source
  - Improved theme discovery for dynamic registration

### Fixed
- **Light Themes** (Nord/Gruvbox/Solarized Light):
  - Removed dark mode icon inversions (`filter: invert(90%)`) that caused icons to appear washed out
  - Removed logo inversion (`filter: invert(1) hue-rotate(180deg)`) for proper display on light backgrounds
  - Removed brightness filters designed for dark backgrounds
- **Variable Prefixes** (all new themes):
  - Replaced inherited `--drac-*` prefix with theme-specific prefixes (`--grv-*`, `--nord-*`, `--sol-*`, `--tn-*`)

## [2.3.0] - 2026-02-21

### Added
- **Catppuccin Theme Collection** (5 themes):
  - Catppuccin Mocha — darkest flavor with mauve accent
  - Catppuccin Macchiato — mid-dark flavor with blue-tinted base
  - Catppuccin Frappé — lightest dark flavor with muted blue base
  - Catppuccin Latte — official light variant with purple accent
  - Catppuccin Mocha Teal — Mocha palette with teal accent
- **Dracula Theme Collection** (6 themes):
  - Dracula — classic dark with purple accent
  - Dracula Pink — pink accent variant
  - Dracula Cyan — cyan accent variant
  - Dracula Midnight — near-black backgrounds from Dracula UI spec
  - Dracula Green — forest-tinted backgrounds with green accent
  - Dracula Orange — warm-tinted backgrounds with orange accent
- **Variant Generator** (`generate-variants.ps1`) for creating theme variants from templates
- Screenshots for all 14 themes in README gallery

### Fixed
- **UniFi Theme** — Issue [#9](https://github.com/IT-BAER/proxmorph/issues/9):
  - Fixed shrunken text boxes in Notes edit and other input fields (PR [#10](https://github.com/IT-BAER/proxmorph/pull/10) by [@drafty46](https://github.com/drafty46))
- **Chart Layout** (all new themes + GitHub Dark):
  - Fixed RRD chart panels stacking in single column instead of 2-column grid
  - Root cause: `padding: 0 !important` on `.x-panel` overrode ExtJS inline `padding: 5px`, triggering a scrollbar-induced sub-pixel overflow feedback loop (2×790px panels > 1579.6px container)
  - Solution: Added `.x-panel.x-column` rule with `max-width: calc(50% - 10px)`, `margin: 5px`, and `padding: 5px` to prevent overflow
  - Removed `:not(.x-draw-container)` from column border selector — chart panels (proxmoxRRDChart) have the `.x-draw-container` class and were incorrectly excluded from card styling

## [2.2.5] - 2026-01-26

### Fixed
- **UniFi Theme (v5.93)** — Issue [#1](https://github.com/IT-BAER/proxmorph/issues/1):
  - Fixed task viewer/log viewer issues: content not visible on open, scrollbar not clickable, no auto-scroll to bottom
  - Root cause: `overflow: visible !important` rule on `.x-window .x-panel-body` completely broke native ExtJS scroll handling
  - Solution: **Removed the problematic overflow rule entirely** - the rule was added for "modal clipping" but caused more issues than it solved
  - Increased scrollbar width from 8px to 12px for better clickability (was hard to click near window edge)
- **UniFi Theme (v5.90)**:
  - Fixed migrate icon missing in resource tree when VM/CT is being migrated
  - Root cause: `.running::after` rule (green status dot) has `content: "\f111" !important` which overrides `.lock-migrate::after` content when both classes are present
  - Solution: Added more specific `.running.lock-migrate::after` selector that shows the migrate icon (paper-plane) with amber color
  - Also added rules for `.lock-backup` and `.lock-suspending` states
- **UniFi Theme (v5.89)** — Issue [#3](https://github.com/IT-BAER/proxmorph/issues/3):
  - Fixed delete dialog warning text "Referenced disks will always be destroyed." being cut off
  - Root cause: ExtJS box layout set narrow container width (236px) causing text wrap, then 0px height due to absolute positioning
  - Solution: Added `white-space: nowrap` to `.pmx-hint` to keep text on single line

## [2.2.4] - 2026-01-21

### Fixed
- **Installer** — Issue [#5](https://github.com/IT-BAER/proxmorph/issues/5):
  - Fixed `sed` delimiter issue during uninstall that caused "extra characters after command" error (PR #6 by @jiriteach)
  - Root cause: Marker text `<!-- /ProxMorph JS Patches -->` contained `/` which conflicted with sed's default delimiter
  - Solution: Use `|` as alternate delimiter and properly escape special regex characters
- **UniFi Theme (v5.88)** — Issue [#4](https://github.com/IT-BAER/proxmorph/issues/4):
  - Fixed "Finish Edit" checkmark button appearing on tags when not in edit mode
  - Root cause: `.x-btn-default-small { display: flex !important }` overrode Proxmox's inline `display: none`
  - Solution: Added rule to respect inline `display: none` styles for dynamically hidden buttons
  - Fixed dark text on tags in edit mode (e.g., teal `testesteste` tag had black text)
  - Tags now always use light text (#F9FAFA) when in edit mode, regardless of `proxmox-tag-dark` classification
  - Fixed "More" button position in IPs section not visible (was positioned off-screen)
  - Corrected transform value from -430px to -242px to align with current PVE 9.x layout

## [2.2.3] - 2026-01-20

### Fixed
- **Installer**:
  - Improved PVE version detection to report specific manager version (e.g., v9.1.4) instead of metapackage version (v9.1.0)
  - Suppressed misleading "Themes directory not found" error during one-liner (`curl | bash`) installations
  - Added robust guards for script path detection via `BASH_SOURCE`

## [2.2.2] - 2026-01-20

### Added
- **Proxmox Backup Server (PBS) Support** — Issue [#2](https://github.com/IT-BAER/proxmorph/issues/2):
  - The installer now officially supports PBS (v3.x/4.x)
  - Auto-detects product (PVE or PBS) and adjusts paths automatically
  - Native integration with PBS theme selector
  - Persistence across PBS updates via apt hook
  - JavaScript patches support for PBS template format (.hbs)

## [2.2.1] - 2026-01-20

### Fixed
- **Apt Hook**:
  - Fixed `[[: not found` syntax error in `post-update.sh` by enforcing POSIX compliance (ensures compatibility with `dash`/`sh`)
- **GitHub Dark Theme**:
  - **Tree/Toolbox Highlights**:
    - Ported authentic UniFi highlight mechanism (using pseudo-elements) to fix "double background" and text artifacts
  - **Structural Alignment**:
    - Ported UniFi border structures (radius, padding, layout) to Windows, Panels, and Fieldsets while preserving GitHub colors
  - **Resource Tree**:
    - Removed default blue focus borders
    - Aligned cell padding with UniFi standards
- **UniFi Theme (v5.85)**:
  - Fixed horizontal scrollbar in resource tree (1px overflow caused by CSS specificity conflict)
  - Added scrollbar corner styling to eliminate white square artifact at corner intersection
- **UniFi Theme (v5.87)**:
  - Fixed "More" button position in IPs section of Summary panel for variable IP count
  - Button now correctly positioned next to "IPs" label regardless of whether 1, 2, or more IPs are displayed
  - Root cause: ExtJS dynamically sets button's `top` based on container height
  - Solution: Anchor to `top: 0` then use consistent transform for fine positioning
  - Added overflow:visible to parent containers to prevent clipping

### Added
- **UniFi Theme (v5.86)**:
  - Replaced sprite-based ExtJS tool icons with crisp FontAwesome icons:
    - Zoom out (undo zoom), collapse/expand panel chevrons
    - Maximize/restore window icons
    - Gear (settings) and refresh icons
  - Distinct icons for collapse vs expand states (chevron direction indicates action)
  - Added styling for generic inline FontAwesome tool icons (e.g., "Reset form data" button)
  - Fixed disabled tool icon mask overlay (transparent background, non-blocking pointer events)
- **Chart Hover Dots**:
  - Added subtle white border (1px) to chart data point dots when hovered
  - Improves visibility of hover state against colored fills

## [2.2.0] - 2026-01-18

### Added
- **JavaScript Chart Patching**:
  - Implemented `unifi-charts.js` to dynamically patch Proxmox RRD charts
  - Adds true UniFi color palette validation (Green/Blue) to charts
  - Solves "Network Traffic" chart blending issues by layering areas correctly
- **Installation**:
  - `install.sh` now installs JavaScript patches to `/usr/share/pve-manager/js/proxmorph/`
  - persistence across PVE updates via APT hook (post-update re-patching)

## [2.1.1] - 2026-01-18

### Fixed
- **UniFi Theme**: 
  - Fixed "More" button alignment in guest summary panel
  - Corrected width and layout of confirmation dialogs (message boxes)
  - Fixed window header close icon positioning
  - Fixed checkbox label visibility and alignment in dialogs

## [2.0.2] - 2026-01-14

### Fixed
- Column panel gap in dialog forms (Edit Network Device, etc.)
  - Added visible 25px gap between left and right form columns
  - Removed width override that was forcing columns to full width
  - Removed padding reset that was eliminating the gap

## [2.0.1] - 2026-01-13

### Fixed
- Resource grid labels (Memory, Cores) no longer appear dark gray
  - Root cause: `filter: invert(90%)` on TD cells was inverting both icons AND text
  - Solution: Isolated filter to icons via `::before` pseudo-elements
- FontAwesome icons in resource grid (Swap, Root Disk) now use bright color (#DEE0E3)

## [2.0.0] - 2026-01-13

### Changed
- **BREAKING**: Removed SASS build system in favor of direct CSS patching
- Theme creation now uses PowerShell scripts that patch the original Proxmox CSS
- GitHub Dark theme completely rewritten using official GitHub CSS variables

### Added
- `generate_github_dark.ps1` - PowerShell script to generate GitHub Dark theme
- `themes/original-proxmox-dark.css` - Base Proxmox Dark CSS for patching

### Removed
- SASS source files (`sass/` directory)
- `build.sh` - No longer needed
- Emerald Night theme (deprecated)

## [1.1.1] - 2026-01-13

### Fixed
- LXC/QEMU container icons in treelist navigation now have transparent background
- Grid table headers no longer clipped on panels with title bars (VNets, etc.)
- Summary page widget panels (Health, Guests, Resources) now have rounded borders

## [1.1.0] - 2026-01-12

### Added
- Modal dialog open animations with background blur effect
- Custom FontAwesome tree expander arrows (chevrons)
- Custom checkboxes and radio buttons (UniFi-style)
- FontAwesome close button icons (replacing pixelated sprites)
- Smooth scrolling throughout the interface

### Changed
- Resource tree tags now match search table tag height (19px)
- Grid table cells now vertically center text
- Treelist items use consistent 4px border-radius
- Reduced window shadow intensity for cleaner look
- Improved status panel padding alignment
- Login modal form fields now use full width
- Login modal footer uses flexbox for proper spacing

### Fixed
- Hidden ExtJS shadow element causing hard shadow edges
- Boundlist dropdown clipping issues
- Icon-only button width issues
- Segmented button text visibility on pressed state
- Modal dialog content being cut off
- Tab focus border removed for cleaner look
- Bulk Actions dropdown button styling
- Floating grid picker border-radius

## [1.0.0] - 2026-01-08

### Added
- Initial release of ProxMorph theme collection
- UniFi-inspired dark theme for Proxmox VE 8.x/9.x
- Blue Slate minimal baseline theme
- Automatic integration with Proxmox Color Theme selector
- Install/uninstall script with backup functionality
