# Sidebar interaction lab

Build the existing renderer in isolation through Glaeda:

```sh
glaeda-apple warm --project . --profile sidebar-lab
```

The profile creates `Sidebar Lab.app` in its managed derived-data directory.
It does not run the cmux reload script or terminate a running cmux instance.
An optional local `.glaeda/sidebar-lab/work.js` is bundled as the replay source;
keep real conversation metadata private and out of Git.

The lab offers Original, Direct, and Off hover modes. Direct opts rows into the
native tracking-layer feedback; Original uses the existing SwiftUI hover path.
Actions are logged, not dispatched to cmux. Live workspace data is not reproduced,
so success here is not proof that the complete cmux host is fixed.

Observed managed build durations on the development Mac, September 13, 2026:

| Build | Seconds |
| --- | ---: |
| Cold lab | 149.22 |
| Unchanged warm lab | 4.15 |
| Renderer and lab changes | 22.03 |
| Lab-only logging change | 8.91 |

These are build durations, not interaction latency measurements. The full app
build still exhibited broad recompilation despite retaining its Glaeda cache;
the lab reduces the iteration scope rather than repairing that invalidation.

The app appends mode changes and main-loop timer lateness to
`sidebar-lab-latency.log` beside the app bundle. Timer gaps can include scheduling,
mode switches, and other work: they are diagnostic evidence, not isolated hover
latency. Compare pointer interaction in both modes and validate the candidate
inside cmux before claiming the beachball is resolved.

The lab opens at 270 points wide and can be resized down to 230 points, so real
titles truncate without fabricated history entries.

The lab also has independent **Reveal titles** and **Details** checkboxes.
Title reveal uses the opt-in `Text(...).nativeMarquee(0.15)` renderer modifier,
scrolls only overflowing titles, and checks macOS Reduce Motion before starting.
It scrolls once and holds at the end, with no bounce or loop, then resets immediately on pointer exit. The native title currently uses a numeric
system font size; it is an experimental Work-sidebar component, not a replacement
for the general styled text renderer.

Direct-hover rows can provide a reactive `hoverDetails` string. After 0.25 seconds
it appears in a compact, arrowless card aligned with the top of the hovered row.
The card flips left if necessary and stays within the screen.
The pending presentation is cancelled on exit or removal. In this replay lab,
“Not linked in this window” describes the lab's empty workspace context, not the
actual running applications. These options are not yet installed in full cmux.

## Live promotion (September 13)

`ConversationSidebarView` is now shared by the lab and the real custom-sidebar
renderer. A sidebar containing exactly `// cmux:conversation-sidebar` mounts it.
`terminal-kit recent --native-sidebar` installs/selects that entry after installing
a compatible cmux build. The regular Work sidebar remains available separately.

The reader invokes the installed `~/.local/bin/terminal-kit recent --json` in a
background task every 15 seconds while mounted. One in-flight refresh is shared
within a process; failed reads preserve previous rows and display a refresh error.
Metadata crosses into JavaScript as data, without restarting its retained runtime.
The lab still logs actions. The app uses its existing window-scoped command dispatch.

Pins retain inherited/manual order. Projects sort by newest activity; chats sort
newest first within projects. All providers merges exact resolved working folders.
Provider-specific views preserve source group names. The list shows
all loaded chats per project in one continuous scroll; search includes
collapsed projects. There is no per-project cap or Show more control. Discovery currently
bounds recent records to 200 plus inherited pins.

Each mounted sidebar owns its filter, search, last creation provider and scroll
state. Key monitors only act for their owning key window. These preferences are
not yet persisted across app restarts. New chat and explicit resume use existing
workspace creation; linked sessions focus their current panel. Native provider
rename/archive/fork and bidirectional pin writes are not implemented by this step.

The scrollbar has no rail, with a 16% white rounded thumb. Provider choices use
compact grey rows and a four-square grid for All providers.

Conversation rows open on the first click: focus an existing linked terminal or resume the conversation in a new terminal. Repeated clicks are guarded while creation is pending. Rows use the native grey hover overlay; the former inline Resume disclosure is removed.
