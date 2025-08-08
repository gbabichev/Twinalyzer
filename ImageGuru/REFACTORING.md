# Refactoring Notes

This pass keeps behavior identical while making files easier to navigate:

- `Panels.swift` — contains the UI panels as an extension on `ContentView`.
- `PreviewImage.swift` — holds `ImageCache` and `PreviewImage` (downsampled preview).
- `Models.swift` — adds `TableRow`, the flattened match-row for the table.
- `ImageDownsampling.swift` — isolates the reusable `downsampledNSImage` helper.

**Next step candidate** (optional):
- Introduce `AppViewModel: ObservableObject` and move analysis state from `ContentView` into it.
- Wire calls in `Panels.swift` to `vm` (e.g., `vm.processImages()`), keeping selection state in the view.
