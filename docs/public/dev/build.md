# 模块构建

打包脚本为 `tools/pack.py`（Python 标准库零依赖）：

```powershell
python tools/pack.py --check    # 只校验必需文件齐全 + 脚本 exec 位
python tools/pack.py            # 打正式包 → dist/SvcHub_v<version>.zip
python tools/pack.py --tag dev  # 打测试包 → dist/SvcHub_v<version>_dev.zip
```

- 版本号读 `module.prop` 的 `version` 字段，产出 `dist/SvcHub_v<version>.zip`；同名不覆盖，递增 `_1`/`_2`
- 新增模块文件需同步补 `tools/pack.py` 的 `REQUIRED_FILES` 清单
- 每次打包覆盖写 `dist/SHA256.txt`（单行：哈希 + 包名）
