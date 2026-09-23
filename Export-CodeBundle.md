# Export-CodeBundle.ps1

## How to run it

```bash
pwsh ./Export-CodeBundle.ps1 -Path ~/dev/SomeProject
```

The output goes to `./SomeProject-bundle.txt` unless you pass `-OutFile`. Add `-Verbose` to see which files are added or skipped.

## What it does

- **Finding files:** if the folder is a git repo and git is installed, it gets the file list from `git ls-files`, so `.gitignore` works exactly as git applies it. Otherwise it reads the `.gitignore` files itself and skips ignored folders as it goes. `-NoGitignore` turns this off.
- **Skipping files:**
  - Git and package folders like `node_modules`, `.gradle`, `vendor` and `.venv`, plus build folders like `bin`, `obj`, `build`, `dist` and `target`.
  - Lock files, gradle wrapper files, `.npmrc` and git dotfiles.
  - Binary files, detected by file extension or by a null byte in the first 8 KB.
- **Minifying code:** it removes comments, blank lines, trailing spaces and indentation, and collapses extra spaces. Line breaks are kept. Text inside strings is never changed, so a `//` inside a URL stays put.
  - It knows the string rules for each language, such as C# `@"..."`, triple-quoted strings, JS template strings and regex literals, Go raw strings, and PowerShell here-strings.
  - It covers about 20 language families: JS/TS, C#, Java/Kotlin/Swift, C/C++, Go, Rust, PHP, Python, Ruby, shell, PowerShell, SQL, CSS/SCSS, Lua, R, Groovy/Gradle/Dart, JSON and HTML/XML.
  - **Python** keeps its indentation (it needs it to run), shrunk to 1 space per level.
  - **JSON** has all whitespace outside strings removed.
- **Other text files** (markdown, YAML, etc.) are copied as they are, except that trailing spaces are removed and runs of blank lines become one.
- **Output format:** the file opens with one line telling the other AI that the code is minified. Each file then starts with a `==> path <==` header. When it finishes, the script prints the file count, the size before and after, and a rough token estimate.

## Aggressive mode

```bash
pwsh ./Export-CodeBundle.ps1 -Path ~/dev/SomeProject -Aggressive
```

`-Aggressive` also removes line breaks and the spaces next to punctuation, where the language allows it. The output uses fewer tokens but is harder to read. Text inside strings is still never changed.

| Languages | What `-Aggressive` does |
|---|---|
| Java, C#, C/C++, Rust | Each file goes onto one line, and spaces next to `{ } ( ) [ ] ; , =` are removed. C and C# `#if`/`#define` lines stay on their own lines. |
| CSS, SCSS, LESS | Each file goes onto one line, and spaces next to `{ } ; ,` and after `:` are removed. Spaces around `(` stay, because `and (max-width…)` needs them. |
| JS/TS, Kotlin, Scala, Go, Groovy/Gradle, Dart, PHP | A line break can end a statement in these languages, so only the safe ones are removed: breaks after `{ ( [ , ; =`, and before `} ) ]` or a `.method()` chain. Spaces next to punctuation are removed as for Java. |
| Swift | Only the safe line breaks are removed. Spaces stay, because Swift rejects uneven spacing around operators. |
| XML (`.xml`, `.csproj`, `.config`, `.xaml`, …) | Each file goes onto one line, with no whitespace between tags or around attribute `=`. The `<?xml …?>` declaration is dropped. |
| HTML, Vue, Svelte | Whitespace between tags is removed. Line breaks elsewhere stay, because `<script>` blocks are JavaScript. |
| JSON | No change: the default mode already removes all whitespace outside strings. |

Other languages (Python, Ruby, shell, PowerShell, SQL, …) are minified the same way as without `-Aggressive`.

## Things you might trip over

- `.env.example` is also skipped, because `.env.*` is excluded to keep secrets out.
- Folders named `bin`, `build` or `out` are skipped even if they hold real source. For example, a Node CLI's `bin/cli.js` would be left out. You can override the list with `-ExcludeDirs`.
- With `-Aggressive`, whitespace between HTML/XML tags is removed, so text like `<b>a</b> <i>b</i>` reads as `ab`. That's fine for code, but it could matter if the other AI is reviewing page text.
- The minifier uses regex, not a full parser, so rare cases can get past it (for example, nested template strings in JS). When that happens it only removes less; it shouldn't damage your code.
