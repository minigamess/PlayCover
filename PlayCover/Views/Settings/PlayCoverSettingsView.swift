//
//  SettingsView.swift
//  PlayCover
//
//  Created by Andrew Glaze on 7/16/22.
//

import SwiftUI

struct PlayCoverSettingsView: View {
    @EnvironmentObject var storeVM: StoreVM

    private enum Tabs: Hashable {
        case ipasource, keyCover, install, uninstall
    }

    var body: some View {
        TabView {
            IPASourceSettings()
                .tabItem {
                    Label("preferences.tab.ipasource", systemImage: "list.bullet")
                }
                .tag(Tabs.ipasource)
                .environmentObject(storeVM)
            KeyCoverSettings.shared
                .tabItem {
                    Label("KeyCover", systemImage: "key.fill")
                }
                .tag(Tabs.keyCover)
            InstallSettings.shared
                .tabItem {
                    Label("preferences.tab.install", systemImage: "arrow.down.app")
                }
                .tag(Tabs.install)
            UninstallSettings.shared
                .tabItem {
                  Label("preferences.tab.uninstall", systemImage: "trash.square")
                }
                .tag(Tabs.uninstall)
        }
    }
}
