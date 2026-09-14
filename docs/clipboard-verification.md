# Clipboard verification record

Deterministic checks completed in the current checkout:

- `filesail-clipboard-codec-test`: URI round trips for spaces, Unicode,
  literal percent signs, hashes, encoded line breaks, deduplication, MIME
  precedence, and rejection of malformed/non-local/mixed inputs.
- `filesail-clipboard` protocol smoke: partial NDJSON framing, multiple
  requests, bounded input, and a missing Wayland display capability response.
- Full `ctest --test-dir build --output-on-failure`: all repository tests pass.
- Bounded standalone launch: reached `INFO: Configuration Loaded`; the
  timeout terminated the test host and no FileSail test processes remain.
- On the current Wayland session, the helper selected
  `ext-data-control-v1` and seat global `40` without creating a helper window.

Still requiring release acceptance on disposable source/destination trees:

- bidirectional Copy/Cut with Nautilus and a second FileSail process;
- Niri and Hyprland acceptance, including compositor permission/configuration;
- clipboard-manager persistence after the last FileSail window exits;
- owner-exit, focus-change, text-field shortcut, volume-removal, and delayed
  transfer race scenarios.

These desktop checks are intentionally not represented as passing unit tests;
they need an isolated Wayland seat and must not replace the user's clipboard.
