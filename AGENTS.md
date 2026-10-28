# Repository Agent Instructions

## Keep bilingual READMEs synchronized

- These instructions apply throughout this repository. Whenever you modify a Chinese or English README, update its existing counterpart in the same task, without waiting for a separate request.
- Identify pairs in the same directory using the repository's naming conventions, such as `README.md` / `README_CN.md` or `readme.md` / `README_CN.md`. Check actual filenames and casing; do not treat backup or copy files as counterparts.
- Use the user's edited version as the source for that change. Synchronize meaning and completeness in both directions, including instructions, prerequisites, examples, commands, tables, screenshots, warnings, and commented-out content. Keep equivalent content visible or hidden in both versions.
- Preserve language-specific titles, navigation, anchors, and links: Chinese documents should link to Chinese counterparts where available, and English documents to English counterparts. Language-switch links must point to the other language. Content consistency does not require byte-identical text.
- Preserve unrelated user edits. If both versions contain conflicting edits and the intended source is unclear, ask the user before overwriting either version.
- If no counterpart exists, do not create a translation unless requested; mention that the README is unpaired.
- Before finishing, compare the affected sections in both versions for equivalent content, matching commands and examples, valid links, and consistent Markdown structure. Report the synchronization in the completion summary.
