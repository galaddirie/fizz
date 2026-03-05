# Workflow Editor Feature

- Owns editable workflow authoring.
- Contains editor contracts, controllers, scene adapters, and editor-specific UI composition.
- May depend on `app/` and `shared/`, but not on other features.

Migration rule:
- The root feature contract is grouped state slices plus a discriminated action union.
- Feature internals dispatch the grouped action union directly. Do not add adapter layers back in.
