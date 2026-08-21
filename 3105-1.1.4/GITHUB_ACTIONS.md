# GitHub Actions

This repository builds automatically on every push to `main` or `master`.

The workflow produces an **unsigned IPA** and an Xcode archive. No Apple signing certificates or provisioning profiles are stored in the repository.

After a successful run, open **Actions → Build 3105 (unsigned IPA) → Artifacts** and download the `3105-unsigned-build-...` artifact.

A manual `workflow_dispatch` trigger is also retained for testing.
