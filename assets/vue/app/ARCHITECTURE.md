# App Layer

- Owns app-wide runtime concerns that cross feature boundaries.
- Contains persistent client state and bootstrap logic only.
- Must not depend on feature-specific scene or domain modules.

Current ownership:
- Theme preference persistence and bootstrap

