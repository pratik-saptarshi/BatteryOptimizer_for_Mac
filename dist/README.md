The binary in this folder was built on an M1 Macbook Pro from [hholtmann/smcFanControl]( https://github.com/hholtmann/smcFanControl ) by running:

```shell
git clone --depth 1 https://github.com/hholtmann/smcFanControl.git
cd smcFanControl
make
```

Running the above command requires xcode to be installed, either fully of trough `xcode-select`.

The original license of that repository is included here as `./LICENSE`.

## Provenance gap

The exact smcFanControl commit these binaries were built from was not recorded. The command above builds whatever `HEAD` was at the time (`--depth 1`), so the build cannot be reproduced exactly, and the corresponding source for these GPL-2.0 binaries is not pinned to a commit. `smc_intel` was recompiled on an Intel MacBook in v2.0.14 (commit 292090b); its source commit is also unknown.

SHA256 of the shipped binaries:

| file | sha256 |
|---|---|
| `smc` | `e3b4392c966dee700f3e1d6cc3812c0d487954c3d6d77b91f521a9590aadae44` |
| `smc_intel` | `3af72bf3c6c7be8bd5dbec215b58650519e3f8dc11a7c68a2c0298913379c1f1` |
