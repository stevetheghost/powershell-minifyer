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

## Things you might trip over

- `.env.example` is also skipped, because `.env.*` is excluded to keep secrets out.
- Folders named `bin`, `build` or `out` are skipped even if they hold real source. For example, a Node CLI's `bin/cli.js` would be left out. You can override the list with `-ExcludeDirs`.
- The minifier uses regex, not a full parser, so rare cases can get past it (for example, nested template strings in JS). When that happens it only removes less; it shouldn't damage your code.
