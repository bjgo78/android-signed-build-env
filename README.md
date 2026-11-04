# android-signed-build-env

One script to set up and maintain `vendor/lineage-priv/keys` for signed LineageOS
(and Lineage-based ROM) builds. Tested with LineageOS 22.2 and 23.2.

Based on the idea of
[306bobby-android/crDroid-build-signed-script](https://github.com/306bobby-android/crDroid-build-signed-script).

## Usage

Copy `create-signed-env.sh` into the root of the source tree (where `build/envsetup.sh` is)
and run it from there.

| Command | What it does |
| --- | --- |
| `./create-signed-env.sh` | No keys yet: asks for the certificate subject and generates them. Keys exist: keeps them and only repairs `keys.mk` / `BUILD.bazel`. |
| `./create-signed-env.sh --subject "/C=US/O=Me/CN=me"` | Generates keys without the prompts. |
| `./create-signed-env.sh --backup [file]` | Packs the keys into a tarball (default: `~/android-keys-<date>.tar.gz`, mode 600). |
| `./create-signed-env.sh --restore file` | Restores keys from a backup into a fresh tree, then checks them. |
| `./create-signed-env.sh --check` | Verifies all certificates, `keys.mk` and `BUILD.bazel`, prints the releasekey fingerprint. |

The script never overwrites existing keys.

## What it creates

- Certificates: `bluetooth media networkstack nfc platform releasekey sdk_sandbox shared testkey verifiedboot`,
  generated with the tree's own `development/tools/make_key`, without a password
  (inline signing during the build cannot use passwords).
- `keys.mk`:
  ```make
  PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey
  PRODUCT_MAINLINE_BLUETOOTH_SEPOLICY_DEV_CERTIFICATES := vendor/lineage-priv/keys/
  ```
  The second line matters on Android 16. Without it, Bluetooth's SELinux `seinfo` is
  built for the test key while the app is signed with your key. Zygote then aborts
  `com.android.bluetooth` on every start (`seapp_context_lookup_internal: No match for
  app with uid 1002, seinfo default:privapp...`) and Bluetooth stays off.
- `BUILD.bazel` with the `android_certificate_directory` filegroup.

`vendor/lineage`'s `common.mk` already does `-include vendor/lineage-priv/keys/keys.mk`.

## Keep the same keys

Every build must be signed with the same keys, or it cannot be dirty-flashed over the
previous one. For a clean tree: `--restore` your backup instead of generating new keys.

**Never commit the keys.** The `.gitignore` here blocks `*.pk8`, `*.pem` and the backup tarballs.
