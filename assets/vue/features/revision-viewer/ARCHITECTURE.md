# Revision Viewer Feature

- Owns read-only workflow history and revision application flows.
- Reuses shared scene primitives instead of maintaining a separate canvas abstraction.
- May depend on `app/` and `shared/`, but not on other features.

Migration rule:
- The root feature contract is grouped state slices plus a discriminated action union.
- Feature internals consume grouped revision slices directly. Do not reintroduce prop adapters.
