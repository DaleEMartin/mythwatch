# Mythwatch

A native Apple TV client for MythTV. Work in progress.

See `docs/SPEC.md` for the specification and `docs/TASKS.md` for the task list.
Licensed under the MIT licence (see `LICENSE`).

## Building the app

The app embeds VideoLAN's VLCKit, which is not kept in git. Fetch it once after cloning:

```
Tools/fetch-vlckit.sh            # tvOS framework into Vendor/ (add --ios for the iPhone one)
```

See `docs/VLCKIT.md` for the chosen version and why, and `THIRD_PARTY_NOTICES.md` for its licence.
