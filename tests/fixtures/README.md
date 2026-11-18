# Test fixtures

All files here were written for this project. None is a copy of a device file.

| File | Content | SHA-256 |
|---|---|---|
| `key2-base.kcm` | Stands in for the KEY2 stock `/vendor/usr/keychars/stmpe.kcm`. LF line endings. | `b64e3cc4…24e0` |
| `key2-base.kl` | Stands in for the KEY2 stock `/vendor/usr/keylayout/stmpe.kl`. No trailing newline. | `a6224942…f05f` |
| `key2-v03-live.kcm` | `key2-base.kcm` with eleven SYM assignments, in the form module v0.3 writes (including its `# KEY2_GUI` markers). | `6bce1b2b…74a8` |
| `synthetic-key2.kcm` | A small KEY2-like map whose Alt rules have no `lalt`. | `8721a519…f4a6` |

## What follows the device and what does not

The KEY2 files are BlackBerry's copyrighted data, so they are not included.
The fixtures keep the properties the tests depend on and choose everything else freely.

Taken from the device as facts:

- The KL scan code to key code pairs (they are fixed by the hardware), and the irregular spacing and missing final newline of the device file.
- The KCM key set and order, the keyboard type, the property lists of each rule (`alt, lalt`, `shift, capslock`, `base, capslock`, `lalt+lshift` on key 4, and so on), and where comments and section headings appear.
- The kinds of character escapes (`\uXXXX`, `\\`, `\'`, `\"`, `\n`, a space).
- The private-use character `\uE141` that the device assigns to the microphone key.
- The characters of keys 4, 0, SPACE and ENTER other than those listed below (they are the characters printed on the keys or fixed by their function).

Chosen for this project:

- The Alt and SYM characters of the letter keys, and the Shift and SYM characters of key 4.
- All comment text.

Stock AOSP keyboard maps (`Generic.kcm`, `Virtual.kcm`, `Generic.kl`) are downloaded by `tools/kcm-host/build.sh` and used as additional real-world inputs.
They are not stored in the repository.
