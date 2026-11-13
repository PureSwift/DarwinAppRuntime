# SwiftUI renderer — Design

**Status:** implemented (`DarwinUI`), with these differences from the
design below:

- **macOS 12 navigation** shows the top level with a toolbar back button,
  since `NavigationView` is a split view on macOS; macOS 13+ uses
  `NavigationStack`.
- **IME composition** has no `UITextField` representable yet (§6): edits,
  marked text included, are sent as they happen.
- **One window** (§9): the host app shows the first renderer the guest still
  holds. Releasing a renderer removes its scene from `RendererScenes`.

The player (§9.4) for iOS 15+ and macOS 12+ is `DarwinUI`. It implements
AppRuntime's `Renderer` contract (§9.3), turns render IR trees into SwiftUI
views, and reports what the user does through `RendererDelegate`. The guest
owns state and identity; the player owns layout, input, animation and
accessibility. The vocabulary, events and byte format are defined in
AppRuntime's `Documentation/RenderIR.md`; this document is how this player
implements them.

## 1. Shape

```
guest ──apply / replaceSubtree──► SwiftUIRenderer ──► RenderStore ──► NodeView(…) (SwiftUI)
  ▲                                                                        │
  └─────────────── event / rowCount / row ◄──── user input ◄───────────────┘
```

- **`SwiftUIRenderer`** is the `Renderer` contract implementation. `make`
  receives the guest's `RendererDelegate`. `apply` and `replaceSubtree`
  decode with `RenderCodec`, on the main thread, and update the store.
- **`RenderStore`** holds one `NodeModel` per node ID.
- **`NodeView`** draws one node from its model, and its children through
  their own models.

## 2. Store and invalidation

The guest sends the smallest changed subtrees, and the store keeps SwiftUI's
invalidation to those subtrees:

- **`NodeModel`** is an `ObservableObject` (Observation needs iOS 17 /
  macOS 14)
  with one `@Published var node: RenderNode`, holding the node without its
  children's content. Children are referenced by ID.
- **`RenderStore`** maps `[RenderNode.ID: NodeModel]`.
  - `apply(tree)` reuses the model for every ID still present, updates the
    ones whose node changed, creates models for new IDs, and drops the rest.
  - `replaceSubtree(id, tree)` does the same for that subtree only.
  - An unchanged node keeps its model and doesn't publish, so its view
    isn't re-evaluated.
- **`NodeView(model)`** observes only its own model. It renders its children
  as `ForEach(childIDs, id: \.self) { NodeView(store.model($0)) }`, so
  SwiftUI's identity follows the guest's node IDs (`.id(node.id)` in the
  design's terms). Native state, such as a scroll position, a text field's
  focus or a toggle mid-animation, survives every update that keeps the ID.

So an update costs a decode, a walk over the replaced subtree, and SwiftUI
re-evaluating the views whose nodes changed.

## 3. Nodes

| IR type | SwiftUI |
|---|---|
| `Text` | `Text(verbatim:)` |
| `Image` | `Image(systemName:)`, `Image(name, bundle: appResources)`; `resizable` → `.resizable()` |
| `Label` | `Label(title, systemImage:)` |
| `Spacer` | `Spacer(minLength:)` |
| `Divider` | `Divider()` |
| `Color` | the color (§5) |
| `VStack`, `HStack`, `ZStack` | the same, with the IR's alignment and spacing |
| `ScrollView` | `ScrollView(axes, showsIndicators:)` |
| `Button` | `Button(role:action:) { children }`; the action sends `tap` |
| `Toggle` | `Toggle(isOn:)` over a synced binding (§6) |
| `TextField` | `TextField` / `SecureField`; submit through `.onSubmit` |
| `Slider` | `Slider(value:in:step:)` |
| `Stepper` | `Stepper(value:in:step:) { label }` |
| `ProgressView` | `ProgressView(value:total:)` / `ProgressView()` |
| `Picker` | `Picker(selection:content:label:)` with the options tagged by index (§6), and `.pickerStyle` from `style`; `wheel` only on iOS |
| `List` (eager) | `List { rows }` |
| `List` (lazy) | `List { ForEach(0..<count) { LazyRow(index) } }` (§7) |
| `Section` | `Section(header:footer:)` |
| `Form` | `Form { children }` |
| `Menu` | `Menu { children } label: { Label(title, systemImage:) }` |
| `LazyVStack`, `LazyHStack` | the lazy stacks over `LazyRow`s; eager ones as stacks |
| `LazyVGrid`, `LazyHGrid` | the lazy grids, over `LazyRow`s or the children. Grid items are made safe for SwiftUI: an adaptive minimum of at least a point, a maximum of at least the minimum |
| `TabView`, `Tab` | `TabView(selection:)`: each tab's content with `.tabItem` from its title and image, tagged by index (§6). A `Tab` elsewhere shows its content |
| `Sheet` | its first child with `.sheet` presenting the second (`.fullScreenCover` on iOS). On macOS the content is at least 320 × 240, and Escape dismisses it |
| `Alert` | its first child with `.alert(title, isPresented:) { buttons } message:`, or `.confirmationDialog(title, isPresented:, titleVisibility:)` when `style` is `dialog`. A button is its text (the first `Text` or `Label` in it) and role |
| `ToolbarItem` | its level's toolbar (§8); nothing in content |
| `NavStack`, `NavLevel`, `NavigationLink` | §8 |
| anything else | `EmptyView()`, logged once per type: the vocabulary is add-only |

## 4. Modifiers

A node's modifiers fold in order over its view:
`modifiers.reduce(AnyView(base)) { apply($1, to: $0) }`.

- `AnyView` is the price of applying a list known only at run time. It's
  cheap here, because the store already limits which views re-evaluate.
- Unknown kinds are ignored.
- SwiftUI already passes the inherited modifiers (`font`,
  `foregroundColor`, `tint`, `lineLimit`, `multilineTextAlignment`,
  `disabled`) down to descendants, which matches the IR's inheritance rule,
  so they map one to one.

| IR kind | SwiftUI |
|---|---|
| `padding` | `.padding(EdgeInsets(…))` |
| `frame` | `.frame(width:height:alignment:)`, or the min/ideal/max form when any of those are present; `∞` is `.infinity` |
| `offset` | `.offset(x:y:)` |
| `background` | `.background(color)` |
| `foregroundColor` | `.foregroundColor(_:)` |
| `tint` | `.tint(_:)` |
| `opacity`, `cornerRadius`, `shadow` | the same |
| `border` | `.border(_:width:)` |
| `font` | `Font` from `style` (`.largeTitle`, …) or `.system(size:weight:design:)`, plus `.italic()` |
| `fontWeight`, `italic` | `.font` adjustments; `.fontWeight` |
| `lineLimit`, `multilineTextAlignment` | the same |
| `disabled` | `.disabled(_:)` |
| `onTapGesture` | `.onTapGesture(count:)`, sending `tap` |
| `accessibilityLabel` | `.accessibilityLabel(_:)` |
| `accessibilityIdentifier` | `.accessibilityIdentifier(_:)` |

## 5. Colors and fonts

- **Named colors** map to the platform's semantic colors, so they follow
  light and dark appearance and accessibility settings:
  `primary` → `Color.primary`, `red` → `Color(UIColor.systemRed)`
  (`NSColor.systemRed` on macOS), and so on. Every named color in the IR,
  `mint`, `cyan` and `brown` included, exists on iOS 15 / macOS 12.
- A **`[name, opacity]`** color applies `.opacity`.
- A **fixed color** (`0xAARRGGBB`) becomes `Color(.sRGB, red:green:blue:opacity:)`.
- Font **styles** scale with Dynamic Type. Fixed **sizes** don't, matching
  SwiftUI's own `.system(size:)`.

## 6. Events and control sync

- **Taps** call `delegate.event(id, kind: tap, payload: [])`.
- **Value changes** encode the new value as a payload: a bool, string,
  double or int.
- Every event is a synchronous `rt_call` into the guest. The guest answers
  with `replaceSubtree` (or `apply`) before the call returns, because its
  update goes out in `GuestExecutor.whenIdle`. So by the time the action
  closure returns, the store holds the guest's answer.

**Control sync** (§9.5). The guest's state is the source of truth, but a
control has to stay responsive while the user is using it:

- Each control's model keeps `rendered`: the value from the last node it
  showed.
- The control's binding reads a local value. On write, it updates the local
  value and sends `change`.
- When a new node arrives, the local value is replaced only if the node's
  value differs from `rendered`, which then becomes the new value.

The result:

- Typing `abc` in a field the guest echoes unchanged never resets the
  cursor.
- A guest that rejects input (clamps a slider, filters characters) wins,
  because its value differs from what was last rendered.
- Text field edits during IME composition (marked text) are sent when
  composition ends. That needs a `UITextField` representable on iOS 15–16;
  later SwiftUI reports composition itself.

**Selection and presentation** use the same sync.

- A `Picker`'s or `TabView`'s value is the selected index, or `-1` when the
  guest's selection matches no option, which SwiftUI shows as nothing
  selected. Options and tabs are tagged with their index.
- A `Sheet`'s or `Alert`'s value is `isPresented`. SwiftUI sets it to
  `false` when the presentation goes away by itself (a swipe, Escape, an
  alert's button), which sends `change` with `false`. Only the guest
  presents.
- An alert's button sends `tap` first, then SwiftUI dismisses the alert,
  which sends `change`.
- The guest removes a sheet's content as soon as the sheet is dismissed,
  while the sheet is still sliding away. So the store holds the content
  shown in a sheet: when the guest removes it, its models and lazy rows are
  kept aside until the sheet's content view disappears, and the sheet slides
  away with its content instead of blank.

## 7. Lazy containers

A node with `count` has no children. `LazyRow(list, index)`:

1. on first appearance calls `delegate.row(listID, index)`, a synchronous
   call that returns an encoded subtree, and decodes it into the store under
   a row scope;
2. caches rows by `(list ID, index, revision)`.

When `revision` changes, the player drops the cache. SwiftUI only
re-evaluates the rows on screen, and each fetches its row again: exactly
the rows the host shows, as the IR intends. `count` comes from the node;
`rowCount` is for players whose recyclers ask for it separately.

Row subtrees live in the same store, so a row's controls and links work like
any other node. Events from a row reach the guest's per-row handlers by node
ID.

Row IDs follow the row's data, so when items move, two rows can hold the same
IDs until both are refreshed: a refreshed or dropped row doesn't remove the
models of IDs that another row still has.

## 8. Navigation

A `NavStack` node's children are its `NavLevel`s, root first.

- **iOS 16+ / macOS 13+:** a `NavigationStack(path:)` whose path is the
  level indices after the root, with `navigationDestination(for: Int.self)`
  showing a level's `NodeView`.
  - When the guest adds a level, the player appends to the path; SwiftUI
    animates the push.
  - When the user goes back (back button, swipe, menu), the path shrinks.
    The player sends `pop` with the number of levels left, and shows what
    SwiftUI shows until the guest's update arrives. That's during the
    `pop` call itself, so in practice at once.
- **iOS 15 / macOS 12:** a `NavigationView` with a chain of
  `NavigationLink(isActive:)`, one per level. Setting a link's `isActive` to
  false is the back navigation that sends `pop`.
- **Titles:** `navigationTitle` from each level's `title`.
- **`NavigationLink` nodes** in a level render as buttons styled like links
  (with a chevron in a `List`) that send `tap`. The guest then adds the
  level, so the player never pushes on its own. One source of truth.

**Toolbars.** A level's `ToolbarItem` children are its toolbar, not its
content. The items at each placement go in one `ToolbarItemGroup`, in a
`.toolbar` of their own: before iOS 16 and macOS 13, a toolbar builder can't
leave out an empty group. `bottomBar` is iOS only, and an unknown placement
is `automatic`.

## 9. Platforms

- **iOS:** one `UIWindowScene` per renderer, hosting a
  `UIHostingController(rootView: NodeView(root))`.
- **macOS:** an `NSWindow` with an `NSHostingView`. A `List` uses the inset
  style. The window's title is the root `NavLevel`'s title when there is
  one.
- **iPad multitasking and macOS window resizing** need nothing special:
  layout is the player's, and the guest never sees sizes. `GeometryReader`
  isn't in the IR yet.

## 10. Testing

- **Store tests**, without SwiftUI or a guest:
  - `apply` and `replaceSubtree` keep models for surviving IDs;
  - unchanged nodes don't publish;
  - row caches drop on a new revision.
- **Event tests** with a recording `RendererDelegate`: actions send the
  right ID, kind and payload, and the control-sync rule holds when the guest
  echoes, clamps or ignores a value.
- **Rendering tests** host `NodeView` in a `UIHostingController` and walk the
  view hierarchy and accessibility tree, without snapshot images, which are
  brittle across OS versions.
- **End to end:** XCUITest on the simulator with AppRuntime's `ExampleUI`,
  as in `HostRuntime.md` §10.

## 11. Open questions

- **Animation.** The IR has no animation or transition kinds yet.
  SwiftUI's default implicit animations apply to inserted and removed views;
  whether a guest needs to say more waits for the vocabulary.
- **Text input details:** keyboard type, content type, autocapitalization
  and submit labels need IR props.
- **Dynamic Type limits and right-to-left layout** come for free from
  SwiftUI, but need testing with a real app.
