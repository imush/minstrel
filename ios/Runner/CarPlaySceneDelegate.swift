import CarPlay
import UIKit

/// The CarPlay screen: Recent and Library tabs over the Dart car library,
/// which keeps it to audio. Playback itself is the app's usual Now Playing.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private let bridge = CarPlayBridge.shared
  private var interface: CPInterfaceController?
  private var tabBar: CPTabBarTemplate?
  /// The tab lists, by node id, so they can be refreshed in place.
  private var tabs: [String: CPListTemplate] = [:]
  private let images = NSCache<NSURL, UIImage>()

  func templateApplicationScene(
    _ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController
  ) {
    interface = interfaceController
    bridge.onChanged = { [weak self] id in self?.changed(id) }
    let tabBar = CPTabBarTemplate(templates: [loadingList()])
    self.tabBar = tabBar
    interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
    loadTabs()
  }

  func templateApplicationScene(
    _ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    bridge.onChanged = nil
    interface = nil
    tabBar = nil
    tabs = [:]
  }

  private func changed(_ id: String) {
    if id.isEmpty {
      loadTabs()
    } else if let list = tabs[id] {
      fill(list, id)
    }
  }

  private func loadTabs() {
    bridge.nodes("roots") { [weak self] roots in
      guard let self, let tabBar = self.tabBar else { return }
      var tabs: [String: CPListTemplate] = [:]
      let templates = roots.map { root -> CPListTemplate in
        let list = self.tabs[root.id] ?? self.list(for: root)
        list.tabTitle = root.title
        list.tabImage = UIImage(systemName: root.id == "history" ? "clock" : "music.note.list")
        tabs[root.id] = list
        return list
      }
      let fresh = templates.filter { list in !self.tabs.values.contains { $0 === list } }
      self.tabs = tabs
      tabBar.updateTemplates(templates)
      for (id, list) in tabs where fresh.contains(where: { $0 === list }) {
        self.fill(list, id)
      }
    }
  }

  private func loadingList() -> CPListTemplate {
    let list = CPListTemplate(title: "Minstrel", sections: [])
    list.emptyViewTitleVariants = ["Loading…"]
    return list
  }

  private func list(for node: CarNode) -> CPListTemplate {
    let list = CPListTemplate(title: node.title, sections: [])
    list.emptyViewTitleVariants = ["Loading…"]
    return list
  }

  private func fill(_ list: CPListTemplate, _ id: String) {
    bridge.nodes("children", id: id) { [weak self] nodes in
      guard let self else { return }
      let shown = nodes.prefix(CPListTemplate.maximumItemCount)
      list.emptyViewTitleVariants = [id == "library" ? "No music servers found" : "Nothing here"]
      list.updateSections([CPListSection(items: shown.map(self.item))])
    }
  }

  private func item(_ node: CarNode) -> CPListItem {
    let item = CPListItem(text: node.title, detailText: node.subtitle)
    if node.browsable { item.accessoryType = .disclosureIndicator }
    item.handler = { [weak self] _, completion in
      self?.select(node, completion) ?? completion()
    }
    if let url = node.art { loadImage(url, into: item) }
    return item
  }

  private func select(_ node: CarNode, _ completion: @escaping () -> Void) {
    guard let interface else { return completion() }
    if node.browsable {
      let list = list(for: node)
      fill(list, node.id)
      interface.pushTemplate(list, animated: true) { _, _ in completion() }
    } else if node.playable {
      bridge.call("play", ["id": node.id]) { [weak self] _ in
        completion()
        self?.showNowPlaying()
      }
    } else {
      completion()
    }
  }

  private func showNowPlaying() {
    guard let interface, interface.topTemplate !== CPNowPlayingTemplate.shared else { return }
    interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
  }

  private func loadImage(_ url: URL, into item: CPListItem) {
    if let image = images.object(forKey: url as NSURL) {
      item.setImage(image)
      return
    }
    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      let scaled = Self.scaled(image, to: CPListItem.maximumImageSize)
      DispatchQueue.main.async {
        self.images.setObject(scaled, forKey: url as NSURL)
        item.setImage(scaled)
      }
    }.resume()
  }

  /// Album art can be large; the car shows a thumbnail.
  private static func scaled(_ image: UIImage, to size: CGSize) -> UIImage {
    let factor = min(size.width / image.size.width, size.height / image.size.height, 1)
    let target = CGSize(width: image.size.width * factor, height: image.size.height * factor)
    return UIGraphicsImageRenderer(size: target).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
  }
}
