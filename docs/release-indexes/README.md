# Signed fprmeta and qosmeta indexes

`fprmeta` and `qosmeta` install versions listed in the Homebrew tap's
`toolchains/fprisc.json` and `toolchains/qos-portable.json`. Each index has a
sibling `.json.sig` OpenSSH signature in namespace `fprmeta-index`, identity
`fpr-release`. The public key is `toolchains/release.pub` in the tap and
`tools/fprmeta/release.pub` here. The private key stays with the owner; it is
never stored in Git.

This directory keeps a copy of the last published index pair and the unsigned
entry files for releases that are not in that index yet.

## Adding a release

From an FP-RISC checkout, with a tap checkout and the `fpr-release` key on this
machine:

```sh
fpr sol tools/publish-release-index.sol --tap /path/to/homebrew-tap --key /path/to/fpr-release \
  fprisc:0.14.0 fprisc:0.15.0 qos:0.5.0 qos:0.6.0
```

The script fetches each GitHub release's `release.json` and `SHA256SUMS`,
checks them against the published archive (SHA-256 and size), writes the
`*-entry.json` files here, appends the entries to the tap indexes in version
order, signs the exact index bytes with `/usr/bin/ssh-keygen`, verifies the
signatures, and prints the `git` commands to publish the tap. The private key
is only passed as a path to `ssh-keygen` on this machine; the script does not
read or copy it.

A bare `VERSION` means `fprisc:VERSION`. `qos:VERSION` and
`qos-portable:VERSION` are the QOS Portable SDK (tag `desktop-vVERSION`).

`--entry-only` writes the entry files without signing. `--assets DIR` uses
already-downloaded `release.json`, `SHA256SUMS` and archives instead of the
network. `--dry-run` validates without writing the indexes. The key comment
must be `fpr-release`.

Do not change an existing archive hash; publish a new version instead.
Metadata corrections (minimum OS, requirements, yanked) must be signed again.

After the tap has the signed index, `fprmeta install 0.15.0` and
`qosmeta install 0.6.0` work, and the waiting entry files can be deleted.
