# Gian iOS

Native Swift and SwiftUI client for Gian Remote.

Gian iOS connects to an authorized Remote server and paired Gian Hosts.
Agent execution and model-backed translation run on the Host; the iOS app
does not bundle an Agent runtime or model credentials.

## Status

This repository contains an early development source snapshot, not a signed
application release. Build, simulator, device, and live-service acceptance
have not been certified for this snapshot.

## Requirements

- Xcode with Swift 6.2 and the iOS 26 SDK.
- iOS 26 or later for the application.
- A compatible Gian Remote server and an authorized Host for live use.
- Your own Apple signing team for installation on a device.

Open `Gian.xcodeproj` and select the `Gian` scheme. The application references
the local `GianCore` Swift package. Preview services use fictional data and
are selected explicitly; they are not a fallback for live connection errors.

## Source Layout

- `App/`: application entry point and service composition.
- `UI/`: native screens, components, transcript rendering, and previews.
- `Sources/GianCore/`: state, Remote transport, synchronization, and storage.
- `Sources/CSQLite/`: system SQLite bindings.
- `Resources/`: application icon and asset catalog.
- `Tests/`: Core, presentation, and UI test sources.

## Scope

The client includes conversation directories and local history, live-update
and reconnect handling, drafts, image and file handling, inline interactions,
and Host-backed translation. Remote capabilities depend on the connected Host.
User messages and translated content retain their original or selected language.

System push notifications, APNs, Live Activities, and Dynamic Island
integrations are outside the current scope.
