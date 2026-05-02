# Security

`cmd` handles clipboard data, images, files, keyboard events, and Accessibility permissions. Security and privacy issues should be treated as release blockers.

## Privacy Principles

- Clipboard contents must not be written to diagnostics logs.
- Diagnostics should contain only operational metadata such as event names, durations, counts, and state changes.
- Sensitive-looking text should be hidden and eligible for expiry.
- Password manager and concealed pasteboard writes should not be captured.
- Local storage should remain inside the app's Application Support directory.

## Local Storage

Runtime data is stored under:

```text
~/Library/Application Support/cmd
```

Diagnostics are stored under:

```text
~/Library/Application Support/cmd/Diagnostics/cmd.log
```

Media payloads are stored under:

```text
~/Library/Application Support/cmd/Media
```

Do not attach these files to public issues unless you have manually inspected and redacted them.

## Reporting A Vulnerability

Open a private security advisory or contact the project owner directly. Include:

- macOS version.
- App version or commit.
- Steps to reproduce.
- Whether the issue involves clipboard contents, Accessibility, paste behavior, storage, or diagnostics.

Do not include secrets, API keys, passwords, private images, or private clipboard contents in a public report.
