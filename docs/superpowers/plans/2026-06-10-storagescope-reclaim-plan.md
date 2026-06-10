# StorageScope Reclaim Plan Implementation Receipt

**Goal:** Make StorageScope feel more guided and safer by separating scan thresholds from display filters, adding a Reclaim Plan overview, and strengthening cleanup confirmation context.

**Architecture:** Add small pure services in `StorageScopeCore` for scan threshold policy and reclaim-plan summarization, with Swift Testing coverage before UI wiring. Keep SwiftUI changes scoped to overview and confirmation surfaces, and leave broader `ScanStore` refactors for a later tranche.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Swift Testing, SwiftPM.

---

### Task 1: Scan Threshold Policy

**Files:**
- Create: `Sources/StorageScopeCore/Services/ScanOptionPolicy.swift`
- Test: `Tests/StorageScopeCoreTests/FileSystemScannerTests.swift`
- Modify: `Sources/StorageScope/Stores/ScanStore.swift`

- [x] Add tests proving interactive scan thresholds are stable and not derived from display filters.
- [x] Implement `ScanOptionPolicy.interactiveScanThresholds(displayThreshold:)`.
- [x] Update `ScanStore.scan(_:)` to use the policy constants instead of `sizeFilter.threshold`.
- [x] Run focused policy coverage through the combined focused test pass.

### Task 2: Reclaim Plan Builder

**Files:**
- Create: `Sources/StorageScopeCore/Services/ReclaimPlanBuilder.swift`
- Test: `Tests/StorageScopeCoreTests/FileSystemScannerTests.swift`
- Modify: `Sources/StorageScope/Stores/ScanStore.swift`

- [x] Add tests for verified reclaim, review-only reclaim, and inaccessible-count summaries.
- [x] Implement `ReclaimPlan`, `ReclaimPlanSection`, and `ReclaimPlanBuilder.build(scan:visibleCleanupCandidates:)`.
- [x] Add `ScanStore.reclaimPlan`.
- [x] Run focused reclaim-plan coverage through the combined focused test pass.

### Task 3: Guided Overview And Confirmation

**Files:**
- Modify: `Sources/StorageScope/Views/OverviewView.swift`
- Modify: `Sources/StorageScope/Services/FileActionService.swift`
- Modify: `Sources/StorageScope/Stores/ScanStore.swift`

- [x] Add a Reclaim Plan panel above the existing storage map.
- [x] Make overview actions jump to Cleanup Review or Folder Tree as appropriate.
- [x] Enrich batch Trash confirmation with estimated reclaim, confidence summary, and up to five paths.
- [x] Run `swift test --scratch-path /tmp/storagescope-spm-full-next`.

### Task 4: Proof And Publish

**Files:**
- Modify: `state.yaml`
- Possibly update: `docs/images/storagescope-overview.png`

- [x] Run `script/public_upload_audit.sh`.
- [x] Run `./script/build_and_run.sh --verify`.
- [x] Leave the public screenshot unchanged because there was no reliable automated scanned-state screenshot harness for the sandbox folder-picker flow.
- [ ] Commit tracked changes and push `HEAD:main`.
