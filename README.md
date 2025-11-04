# Chamaileon
A cross-platform keyboard driven Email application.

This is early days. This application is in heavy development with a lot changing. Using it means participating in the development process.
If you have questions or issues, please open a discussion.

### Dependencies
DVUI (UI) - https://david-vanderson.github.io/

SuperHTML - https://github.com/kristoff-it/superhtml

SDL 3

## Building
After cloning the repo, building is simple if you already have [Zig](https://ziglang.org) installed. Chamaileon uses 0.15.2 right now.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/chamaileon

# If you want to put it in your local prefix
zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```


## Libraries
Chamaileon exports the following libraries

- IMAP: Connect and communicate with IMAP servers
- Mani: Text manipulation and conversion (utf-7, quoated-printable, etc.)

#### Future plans
- WebView Widget: (WIP) DVUI widget for viewing HTML
- Markdown Widget: DVUI widget for viewing Markdown

### Adding to your zig project
Fetch with the zig cli
```sh
zig fetch --save git+https://github.com/Southporter/Chamaileon
```
Add to your build.zig
```zig
// in your build.zig
const chamaileon = b.dependency("chamaileon", .{
    .target = target,
    .optimize = optimize,
});
const imap = chamaileon.module("imap");
your_module.addImport("imap", imap);
your_module.addImport("mani", chamaileon.module("mani");
```

### Roadmap
- [x] Connect to IMAP servers
- [x] StartTLS/TLS support
- [x] Authenticate Plain support
- [x] Capabilities parsing
- [x] Listing Mailboxes
- [x] Selecting a mailbox
- [x] Fetching email previews
- [x] Fetching full emails
  - [x] Plain Text
  - [x] HTML
  - [ ] Calendar
  - [ ] Attachments
- [ ] NOOP updates
- [ ] Reconnecting
- [ ] Onboarding (Form for server, connection type, username, password, authentication method)
- [ ] Add OAuth authentication
  - [ ] Gmail
- [ ] Moving Emails
  - [ ] Marking Spam
  - [ ] Deleting (move to trash)
  - [ ] Starring
     
