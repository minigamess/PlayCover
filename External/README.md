# Vendored dependencies

## PlayTools

Upstream: https://github.com/PlayCover/PlayTools  
Pinned commit: see `PlayTools/UPSTREAM_COMMIT`

PlayTools is **vendored** under `External/PlayTools` so local fixes (e.g. native dialog mouse pass-through) live in this repo and are not wiped by `carthage update`.

### Build flow (`build-install-local.sh`)

1. Sync `External/PlayTools` → `Carthage/Checkouts/PlayTools`
2. `carthage build` (no re-fetch / no checkout reset)
3. Build & install PlayCover

### Update upstream PlayTools

```bash
cd External/PlayTools
# re-clone or pull a newer commit, then:
# write new hash to UPSTREAM_COMMIT
# commit the External/PlayTools tree in PlayCover
```
