# Third-party code bundled in Owlink

Owlink is BSD-2-Clause ([LICENSE](../LICENSE)). The manual's
[Licences](MANUAL.md#licences) section credits everything else Owlink uses
(llama.cpp, the Dracula theme's colours, the downloadable models). This note
records the files copied into the repository as they were published, so
each can be checked against its source.

## Updates: Sparkle 2

Not copied into the repository: SwiftPM fetches it as a binary target
(Package.swift), like llama.cpp. Release 2.10.1's
`Sparkle-for-Swift-Package-Manager.zip`, SHA-256
`4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a` (the
checksum in that release's own Package.swift; SwiftPM checks it on every
fetch). MIT. A release build embeds `Sparkle.framework` and its `LICENSE` as
`Contents/Resources/Sparkle-LICENSE.txt` (Scripts/bundle-app.sh --release).
How updates are turned on: [updates.md](updates.md).

## Markdown preview: Mermaid and KaTeX

Used only by the Markdown preview, only while its **Allow JavaScript** is on,
and only for a document with a ```mermaid block or math. They sit in
`Resources/Preview` and in the app at `Owlink.app/Contents/Resources/Preview`
(Scripts/bundle-app.sh), and the preview loads them from there through its own
`cedric-asset://vendor/` scheme handler (Sources/CedricCore/PreviewRich.swift
lists the only files it serves). Nothing is fetched from the network.

| Library | Version | License | Source |
|---|---|---|---|
| [Mermaid](https://github.com/mermaid-js/mermaid) | 12.3.0 | MIT, © 2014–2022 Knut Sveidqvist ([mermaid/LICENSE](../Resources/Preview/mermaid/LICENSE)) | https://registry.npmjs.org/mermaid/-/mermaid-12.3.0.tgz |
| [KaTeX](https://github.com/KaTeX/KaTeX) | 0.19.1 | MIT, © 2013–2020 Khan Academy and other contributors ([katex/LICENSE](../Resources/Preview/katex/LICENSE)) | https://registry.npmjs.org/katex/-/katex-0.19.1.tgz |

The npm tarballs, as downloaded on 2026-11-26:

| Tarball | SHA-256 | npm integrity |
|---|---|---|
| mermaid-12.3.0.tgz | `be0684e8d20bfc874df12c0f04927a5c482f57f2200eec54cca52a4583fd4040` | `sha512-4113TdXeLAsMruJ79OpFL5O8+LTFXhQqZ260rF3tgUmiNAtRm4Uume04I+65PRN6yZ69J4f8rVYWW8zRk65UYw==` |
| katex-0.19.1.tgz | `24da5a599eb2fcede2e270b99a6ff48bca816beecc95feeb84e8cccbd1bb34fd` | `sha512-jG8uKntjSEcm2EpQOh0XturpPuuC9r3Sq5HLHdsFdWZT27E672SF19QEi+of0/YeOy15lDgRhKvr5614uRrEfA==` |

The files taken from them, unchanged (tarball path `package/dist/…` for the
code, `package/LICENSE` for the licences). Of KaTeX's fonts only the WOFF2
files are kept: WebKit loads the first format `katex.min.css` lists, WOFF2,
so the WOFF and TTF copies would never be read.

| File in Resources/Preview | Bytes | SHA-256 |
|---|---|---|
| `mermaid/mermaid.min.js` | 5537838 | `336df803d87a38b70a01e736e666c8f7601d2ce42f5e47c8fafe5d721074b9a3` |
| `mermaid/LICENSE` | 1089 | `ec9fb67dcb25eccc416ed56e1aab819222c805a2a4bfe4cb19e7556bf2ffde80` |
| `katex/katex.min.js` | 273081 | `fa140498b8cfc8302cbe5e7cb1bdbc1f952bc38b3fa258ede09e73edbf9a74bc` |
| `katex/katex.min.css` | 24793 | `00e0b094171b07f58422075f469b4feac2b2f7bce1aeec943c08da4d697f4dcf` |
| `katex/LICENSE` | 1107 | `766ccc1f306c885aa45542a9846bbd0a505b27a0374f146778171c2254ce18e3` |
| `katex/fonts/KaTeX_AMS-Regular.woff2` | 28076 | `0cdd387c9590a1a9f9794560022dbb59654a7d86f187aa0c81495ad42d3a7308` |
| `katex/fonts/KaTeX_Caligraphic-Bold.woff2` | 6912 | `de7701e42cf1f4cf0b766c03fb27977207eee2f4fd5d76fa82188406da43ea4c` |
| `katex/fonts/KaTeX_Caligraphic-Regular.woff2` | 6908 | `5d53e70ad607c2352162dec9e0923fb54ecdafaccbf604cd8dcf7d00facb989b` |
| `katex/fonts/KaTeX_Fraktur-Bold.woff2` | 11348 | `74444efd593c005e3f4573b44524704c0af0a937fe911cca9e94068d0d140d3f` |
| `katex/fonts/KaTeX_Fraktur-Regular.woff2` | 11316 | `51814d270d06ff0255dba0799994fa4d8c84d11f09951d47595f4abb1f3602dc` |
| `katex/fonts/KaTeX_Main-Bold.woff2` | 25324 | `0f60d1b897938ec918c8ce073092411baf9438f6739465693ff18b0f9d20b021` |
| `katex/fonts/KaTeX_Main-BoldItalic.woff2` | 16780 | `99cd42a3c072d918f2f44984a807cf7aa16e13545fd0875fc07c6c65f99e715b` |
| `katex/fonts/KaTeX_Main-Italic.woff2` | 16988 | `97479ca6cce906abc961ecac96faa5f9ca2e61b8e7670d475826bcdee9a7c267` |
| `katex/fonts/KaTeX_Main-Regular.woff2` | 26272 | `c2342cd8b869e01752a9321dc17213fc40d4d04c79688c1d43f2cf316abd7866` |
| `katex/fonts/KaTeX_Math-BoldItalic.woff2` | 16400 | `dc47344dbb6cb5b655c8460d561f4df5f501b90c804ad3c6cec65fe322351ab1` |
| `katex/fonts/KaTeX_Math-Italic.woff2` | 16440 | `7af58c5ec8f132a2ddde9027c6d7814decce4d3b822a11192a42a20e2e973264` |
| `katex/fonts/KaTeX_SansSerif-Bold.woff2` | 12216 | `e99ae51144bf1232efcc1bfe5add36262c6866b0faab24fa75740e1b98577a62` |
| `katex/fonts/KaTeX_SansSerif-Italic.woff2` | 12028 | `00b26ac825e2095056396e0553b8ac26d3f8ad158c3826e28b4c45b385c4714a` |
| `katex/fonts/KaTeX_SansSerif-Regular.woff2` | 10344 | `68e8c73ef42afd3ccec58bf0fba302cce448938e7fc020a5e31f8a952eee1342` |
| `katex/fonts/KaTeX_Script-Regular.woff2` | 9644 | `036d4e95149b69ff9bcc0cd55771efeb25ffa3947293e69acd78d5ac328c684b` |
| `katex/fonts/KaTeX_Size1-Regular.woff2` | 5468 | `6b47c40166b6dbe21a5dfca7718413f2147fd2399be1ba605d8ad39cedf25dfe` |
| `katex/fonts/KaTeX_Size2-Regular.woff2` | 5208 | `d04c54219f9eaec6d4d4fd42dfb28785975a4794d6b2fc71e566b9cd6db842dd` |
| `katex/fonts/KaTeX_Size3-Regular.woff2` | 3624 | `73d591271b1604960cb10bb90fee021670af7297017e0e98480b332d11f51995` |
| `katex/fonts/KaTeX_Size4-Regular.woff2` | 4928 | `a4af7d414440a1c1790825cfb700cf9cf43b0f2c4b04f0ebc523011ad9853ec0` |
| `katex/fonts/KaTeX_Typewriter-Regular.woff2` | 13568 | `71d517d67827787cfabdf186914cc3358eda539e37931941f2b2fd4a21f68c0b` |

Together 6,097,700 bytes (Mermaid 5,538,927; KaTeX 558,773). Owlink's own
glue, `Resources/Preview/owlink-rich.js`, is not third-party code.

To check a file: `shasum -a 256 Resources/Preview/<file>`. To update: download
the new tarball from the registry, compare its `sha512` with
`npm view <name>@<version> dist.integrity`, copy the same files, and update
the tables above.
