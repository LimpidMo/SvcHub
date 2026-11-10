# Module Build

The packing script is `tools/pack.py` (Python standard library only, zero dependencies):

```powershell
python tools/pack.py --check    # validate required files + script exec bits only
python tools/pack.py            # release build → dist/SvcHub_v<version>.zip
python tools/pack.py --tag dev  # test build → dist/SvcHub_v<version>_dev.zip
```

- The version is read from the `version` field of `module.prop`, producing `dist/SvcHub_v<version>.zip`; duplicate names are not overwritten — a `_1`/`_2` suffix is appended
- New module files must be added to the `REQUIRED_FILES` list in `tools/pack.py` (currently 25, including the seven `lib/` modules)
- Run `sh tools/check.sh` before packing (syntax + duplicate functions + lib unit tests + i18n + file list)
- Each build overwrites `dist/SHA256.txt` (one line: hash + package name)
