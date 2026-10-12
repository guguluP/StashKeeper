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
import Security

enum CloudSyncGate {
    static let containerID = "iCloud.com.piyushpatnaik.StashKeeper"

    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
        )
        return value != nil
    }
}
