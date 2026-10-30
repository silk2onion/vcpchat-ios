VChat Native (formerly VCPChat iOS)
Copyright 2026 VCPChat iOS contributors

This project is adapted from, and shares protocol behavior with:

- VCPMobile by MRiecy (Nova), https://github.com/MRiecy/VCPMobile
  Copyright 2026 MRiecy (Nova)
  Studied at commit a8482b607df13a74e7f8d63a2b0f751221eaaf1a
- VCPChat by lioensky, https://github.com/lioensky/VCPChat
  Studied at commits 942ad422b678fb87f46a70eb3de4e64bb9e5bdf4
  and 1fadcf1531151cd7c5070fc1737d944133918dba
- VCPToolBox by lioensky, https://github.com/lioensky/VCPToolBox
  Native SSE/WebSocket integration studied at commit 0c919a3

The repository retains the Creative Commons Attribution-NonCommercial-ShareAlike
4.0 International license. Give appropriate credit, link the license, and indicate
changes. Commercial use is not permitted; distributed adaptations use CC BY-NC-SA 4.0.
The license text is in LICENSE:
https://creativecommons.org/licenses/by-nc-sa/4.0/

The current application is a Swift 6 / SwiftUI native rewrite. The earlier
Tauri/Vue implementation, desktop wallpapers/portraits and MobileSync browser
adapters remain in Git history but are not shipped in this native Phase 1 target.
The application icon is retained from the earlier iOS client.

GRDB.swift 7.0.0 is a separate dependency, distributed under its MIT license:
https://github.com/groue/GRDB.swift/blob/v7.0.0/LICENSE
