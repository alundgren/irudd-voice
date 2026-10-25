# Brand

The app icon is `App/IruddVoice/AppIcon.icon`, an Icon Composer package (the
macOS 26+ layered Liquid Glass format). Xcode compiles it into the app's
`Assets.car` and `AppIcon.icns` (`ASSETCATALOG_COMPILER_APPICON_NAME =
AppIcon`).

**Concept:** two sound bars turn into a prompt chevron, with a green
insertion line under it: your voice becomes a prompt. It's original
artwork, with no SF Symbols or third-party marks, under the project's MIT
licence.

| File | What |
| --- | --- |
| `master.svg` | The 1024×1024 flat design with background and foreground groups |
| `appearances.png` | `ictool` renders of the `.icon` in Default, Dark, Tinted and Clear at 1024, 32 and 16 px |
| `icon-128.png` | For the README |
| `social-preview.png` | 1280×640, for the GitHub repo's social preview (Settings → General) |

To render the icon without opening Icon Composer:

```sh
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" App/IruddVoice/AppIcon.icon --export-image --output-file /tmp/icon.png \
  --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1 --design-generation 27
```

Renditions: `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight`,
`ClearDark`.
