# Repo notes for Claude / agents

A collection of Hammerspoon Spoons. Each `<Name>.spoon/` directory is
a self-contained Spoon with its own `init.lua`, `docs.json`, README,
and a `spoon-manifest.json` that mirrors the Spoon's public surface
for external tooling (the **MacSpoonsTweaks** macOS app — separate
repo — renders config UI from these manifests).

## spoon-manifest.json must stay in sync with init.lua

`<Name>.spoon/spoon-manifest.json` is the source of truth for external
tooling. The manifest's `default`s, `lifecycle` flags, and `hotkeys`
list must match what the Spoon's `init.lua` actually exposes.

When you change a Spoon's code, update its manifest in the **same
commit**:

| Code change                                                  | Manifest fix                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------- |
| `obj.someField = X` default changes                          | `config[].default` for `key == "someField"`                   |
| Add a new `obj.someField` configurable                       | Append a new entry to `config[]` with type/default/description |
| Remove `obj.someField`                                       | Remove the matching `config[]` entry                          |
| Add `function obj:start()` / `:stop()` / `:toggle()` / `:configure()` | Flip the matching `lifecycle.has<X>` to `true`                |
| Remove one of those methods                                  | Flip the matching `lifecycle.has<X>` to `false`               |
| Add a `:bindHotkeys` action                                  | Append the action name to `hotkeys[].action`                  |
| Remove a `:bindHotkeys` action                               | Remove the matching `hotkeys[]` entry                         |
| Spoon has meaningful active/inactive state (`:start`/`:stop`) | Set top-level `activateHotkey: { mods, key }` — the chord MacSpoonsTweaks binds to call `:start`/`:stop` from outside `bindHotkeys`. Spoons whose hotkeys are pure operations (e.g. MoveSpaces) skip this field and keep their `hotkeys[]` entries instead. |
| Change `obj.name` / `obj.version`                            | Update `name` / `version` at the top of the manifest          |

Nested config (e.g. `MouseTrackpadTweaks.middleClick`) follows the
same rule for every leaf field inside the recursive `object` tree.

### Why

External tools regenerate config forms, install scripts, and update
checks from the manifests. A drift between `init.lua` and the
manifest produces broken UI silently — wrong defaults shown to users,
unknown-field errors when they hit Apply, etc. The manifest is part
of the Spoon's public interface; treat it as such.

### Validating manually

For a sanity check, open both files side by side and confirm:

1. `name` / `version` match `obj.name` / `obj.version`.
2. Every `obj.<key> = <default>` at the top of `init.lua` appears in
   the manifest's `config[]` with the same default.
3. Every `function obj:<method>()` you find for `start`, `stop`,
   `toggle`, `configure` is reflected in `lifecycle`.
4. Every `mapping.<action>` referenced inside `function obj:bindHotkeys`
   is in the `hotkeys[]` list with a sensible default chord.
