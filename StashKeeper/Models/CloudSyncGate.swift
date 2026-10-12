//
//  CloudSyncGate.swift
//  StashKeeper
//
//  Private iCloud sync for this Apple ID's devices. The container is
//  opened only when the running app actually has the iCloud entitlement.
//  A widget, or a profile that has not enabled the container yet, keeps
//  the local App Group store.
//

import Foundation

enum CloudSyncGate {
    static let containerID = "iCloud.com.piyushpatnaik.StashKeeper"

    static var isEntitled: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }
}
