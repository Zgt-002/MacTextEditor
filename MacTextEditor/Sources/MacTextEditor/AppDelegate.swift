import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController!
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindowController = MainWindowController()
        mainWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        buildMenus()
        if !pendingOpenURLs.isEmpty {
            mainWindowController.open(urls: pendingOpenURLs)
            pendingOpenURLs.removeAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let mainWindowController else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        mainWindowController.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenus() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于MacTextEditor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出MacTextEditor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        fileMenu.addItem(item("新建", #selector(MainWindowController.newDocument), "n"))
        fileMenu.addItem(item("打开…", #selector(MainWindowController.openDocuments), "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("保存", #selector(MainWindowController.saveDocument), "s"))
        let saveAll = item("全部保存", #selector(MainWindowController.saveAllDocuments), "s")
        saveAll.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAll)
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("关闭标签", #selector(MainWindowController.closeActiveDocument), "w"))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(responderItem("撤销", Selector(("undo:")), "z"))
        editMenu.addItem(responderItem("重做", Selector(("redo:")), "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(responderItem("剪切", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(responderItem("复制", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(responderItem("粘贴", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(responderItem("全选", #selector(NSText.selectAll(_:)), "a"))

        let searchItem = NSMenuItem()
        mainMenu.addItem(searchItem)
        let searchMenu = NSMenu(title: "查找")
        searchItem.submenu = searchMenu
        searchMenu.addItem(item("查找…", #selector(MainWindowController.showFindPanel), "f"))
        searchMenu.addItem(item("替换…", #selector(MainWindowController.showReplacePanel), "h"))
        searchMenu.addItem(.separator())
        let smartHighlight = item(
            "智能高亮选中内容",
            #selector(MainWindowController.toggleSmartHighlight(_:)),
            ""
        )
        smartHighlight.state = .on
        searchMenu.addItem(smartHighlight)
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = mainWindowController
        return item
    }

    private func responderItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}
