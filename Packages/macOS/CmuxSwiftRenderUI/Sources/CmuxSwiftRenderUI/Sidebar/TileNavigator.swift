import SwiftUI

/// A compact navigator over existing spaces and their live tiles.
public struct TileNavigator: View {
  /// An immutable space label, independent of the host's observable stores.
  public struct Space: Identifiable {
    public let id: UUID
    public let title: String
    public init(id: UUID, title: String) {
      self.id = id
      self.title = title
    }
  }
  /// A live surface represented by its exact host identity.
  public struct Item: Identifiable {
    public let id: UUID
    public let title: String
    public let icon: String
    public let asset: String?
    public let selected: Bool
    public init(id: UUID, title: String, icon: String, asset: String?, selected: Bool) {
      self.id = id
      self.title = title
      self.icon = icon
      self.asset = asset
      self.selected = selected
    }
  }
  /// A tile and its ordered tabs.
  public struct Tile: Identifiable {
    public let id: UUID
    public let items: [Item]
    public init(id: UUID, items: [Item]) {
      self.id = id
      self.items = items
    }
  }
  /// Commands are resolved by the host against its current live layout.
  public enum Action {
    case selectSpace(UUID)
    case newSpace
    case focus(UUID)
    case close(UUID)
    case move(UUID, UUID)
    case terminal, browser, splitRight, splitDown
  }
  private let spaces: [Space]
  private let selectedSpace: UUID
  private let tiles: [Tile]
  private let perform: (Action) -> Void
  @State private var expanded = true
  @State private var hovered: UUID?

  /// Creates a navigator from value snapshots and a host action dispatcher.
  public init(
    spaces: [Space], selectedSpace: UUID, tiles: [Tile], perform: @escaping (Action) -> Void
  ) {
    self.spaces = spaces
    self.selectedSpace = selectedSpace
    self.tiles = tiles
    self.perform = perform
  }
  private func label(_ key: String) -> String {
    NSLocalizedString("tiles." + key, bundle: .module, comment: "Tile navigator")
  }
  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        if expanded {
          Menu {
            ForEach(spaces) { space in
              Button {
                perform(.selectSpace(space.id))
              } label: {
                if space.id == selectedSpace {
                  Label(space.title, systemImage: "checkmark")
                } else {
                  Text(space.title)
                }
              }
            }
            Divider()
            Button(label("newSpace")) { perform(.newSpace) }
          } label: {
            Text(label("spaces")).font(.system(size: 12, weight: .semibold))
          }.menuStyle(.borderlessButton)
          Spacer(minLength: 0)
        }
        Button {
          expanded.toggle()
        } label: {
          Image(systemName: "sidebar.right").frame(width: 26, height: 28)
        }.buttonStyle(.plain).help(label("toggle"))
      }.padding(.horizontal, 8).frame(height: 36)
      if expanded {
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text(spaces.first(where: { $0.id == selectedSpace })?.title ?? "")
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
              .padding(.horizontal, 6)
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
              tileGroup(tile, index: index)
            }
          }.padding(6)
        }
        Divider()
        HStack(spacing: 4) {
          control("terminal", "terminal", .terminal)
          control("globe", "browser", .browser)
          Spacer(minLength: 0)
          control("rectangle.split.2x1", "splitRight", .splitRight)
          control("rectangle.split.1x2", "splitDown", .splitDown)
        }.padding(6)
      } else {
        Spacer(minLength: 0)
      }
    }.frame(width: expanded ? 190 : 42).frame(maxHeight: .infinity)
      .background(.background.opacity(0.35))
  }
  private func tileGroup(_ tile: Tile, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label("tile") + " " + String(index + 1))
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.bottom, 3)
      ForEach(tile.items) { item in
        itemRow(item, tile: tile)
      }
    }.padding(3).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
      .dropDestination(for: String.self) { values, _ in
        guard let value = values.first,
          value.hasPrefix("cmux-tile:" + selectedSpace.uuidString + ":"),
          let id = UUID(uuidString: String(value.suffix(36))),
          tiles.contains(where: { $0.items.contains(where: { $0.id == id }) })
        else { return false }
        perform(.move(id, tile.id))
        return true
      }
  }
  private func itemRow(_ item: Item, tile: Tile) -> some View {
    HStack(spacing: 6) {
      HStack(spacing: 7) {
        if let asset = item.asset {
          Image(asset).resizable().scaledToFit().frame(width: 14, height: 14)
        } else {
          Image(systemName: item.icon).frame(width: 14)
        }
        Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
      }.contentShape(Rectangle())
        .onTapGesture { perform(.focus(item.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { perform(.focus(item.id)) }
      Button {
        perform(.close(item.id))
      } label: {
        Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 22)
      }.buttonStyle(.plain).opacity(hovered == item.id ? 1 : 0)
        .help(label("close"))
    }.font(.system(size: 12)).padding(.leading, 6).padding(.trailing, 2).frame(height: 30)
      .background(
        item.selected
          ? Color.primary.opacity(0.12) : hovered == item.id ? Color.primary.opacity(0.06) : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .onHover { hovered = $0 ? item.id : hovered == item.id ? nil : hovered }
      .onDrag {
        NSItemProvider(
          object: ("cmux-tile:" + selectedSpace.uuidString + ":" + item.id.uuidString) as NSString)
      }
      .contextMenu {
        ForEach(Array(tiles.enumerated()), id: \.element.id) { targetIndex, target in
          if target.id != tile.id {
            Button(label("move") + " " + String(targetIndex + 1)) {
              perform(.move(item.id, target.id))
            }
          }
        }
        Button(label("close")) { perform(.close(item.id)) }
      }
  }
  private func control(_ icon: String, _ key: String, _ action: Action) -> some View {
    Button {
      perform(action)
    } label: {
      Image(systemName: icon).frame(width: 28, height: 28)
    }
    .buttonStyle(.plain).help(label(key)).accessibilityLabel(label(key))
  }
}
