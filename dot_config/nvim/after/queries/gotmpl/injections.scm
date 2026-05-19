; extends
;
; Inject the inner language of compound filetypes (e.g. `json.gotmpl`,
; `yaml.gotmpl`, `toml.gotmpl`) into the literal text regions between gotmpl
; template directives. `inject-inner-ft!` is a custom directive registered in
; lua/config/options.lua; it reads the buffer's filetype, strips the trailing
; `.gotmpl`, and sets `injection.language` to whatever remains. For plain
; `gotmpl` filetypes (no compound), the directive is a no-op and the text
; renders without injection — fine for `.chezmoiignore.tmpl`, `Brewfile.tmpl`,
; symlink templates, etc., where the inner language isn't a thing.
;
; `injection.combined` merges all `(text)` ranges into one virtual document
; so the inner parser sees the JSON/YAML/TOML as a continuous file rather
; than one isolated fragment per `{{...}}` boundary.
((text) @injection.content
  (#set! injection.combined)
  (#inject-inner-ft!))
