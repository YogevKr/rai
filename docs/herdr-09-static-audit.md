# Candidate43 static finding audit

The historical Sources-only report contains 95 gating findings. It does not represent 95 confirmed defects.
The report also contains 269 findings on new symbols. Those findings do not affect its exit status.
This audit does not replace the full branch review or include an iOS quality gate.

| Finding | Count | Assessment |
| --- | ---: | --- |
| Recent change history | 48 | Maintenance signal from changed symbols and commit history. |
| Duplication | 20 | Mostly typed RPC wrappers, constructors, cleanup, and platform color conversion. |
| New clone of reused helper | 2 | Similar extraction and cleanup syntax across different owners. |
| Dead code | 3 | Source references disprove all three findings. |
| Complexity | 3 | Actual growth in request routing, RPC handling, and event recovery. |
| Nesting | 1 | Actual growth in event recovery. |
| Length | 18 | Actual growth, including entire Swift types measured against a 60-line threshold. |

## False dead-code findings

`FullDiskAccessGuidance` serves its view at lines 32 and 49 of `Sources/RaiApp/FullDiskAccessGuidance.swift`.
`TranscriptIndex.invalidate` serves the bridge at `Sources/RaiApp/RaiBridgeServer.swift:1574`.
`HerdrClient.sendInput` serves the bridge and probe at `Sources/RaiApp/RaiBridgeServer.swift:1082` and `Sources/RaiProbe/RaiProbe.swift:83`.

## Material maintenance risks

`RaiModel.startEventLoop` combines subscription recovery, snapshots, connection generations, and workspace-close endpoint preparation.
Its cognitive complexity grew from 9 to 42. Nesting grew from 3 to 6.
The reviewed code checks cancellation and connection generation. It closes subscriptions and resumes startup continuations.
No new correctness defect emerged from this focused check.

`HerdrClient.call` combines socket ownership, decoding, and retry policy. Its cognitive complexity grew from 16 to 19.
Writes use one attempt. Read methods can explicitly enable retries.
The bridge request handler also grew. Its existing routing complexity remains a maintenance risk.

The large `RaiModel`, bridge protocol, and terminal view types remain maintenance risks.
Small wrappers and constructors do not require consolidation solely because their syntax matches.
Platform color adapters use different native color types. Similar arithmetic alone does not establish an incorrect implementation.

## Result

The historical gate remains failed. This audit does not suppress or accept its findings.
The focused inspection found scanner false positives and maintenance risks, without establishing a new release defect.
No source changed. No tests were rerun for this read-only inspection.

Report: `/tmp/rai-close-final-quality.log`.
Structured audit: `/tmp/rai-static95-audit.json`.

## Candidate44 phone scan

The phone scan reports 32 gating branch findings against Git HEAD.
It includes existing type size, complexity, and churn findings.
The notification close fix adds one private state flag and an idempotence guard.
The scan does not report a clean quality gate.
Log: `/tmp/rai09-candidate44-ios-quality.log`.

## Candidate63 input correction

The scoped input report retains eight gating findings. They concern aggregate class length, fixture dispatch, and test-fixture similarity.
The correction batches adjacent committed text while preserving target, revision, epoch, key, paste, and popup boundaries.
Forty focused tests passed, with one optional native-Herdr skip. Both original models failed the burst regression.
Scoped Codex review found no actionable correctness or security issue.

The release retains these maintenance findings. Splitting existing model classes would expand this input correction without improving its verified behavior.
The change extracts a shared phone test surface to remove exact fixture duplication.
No quality suppression or unrelated model rewrite changes the reported gate result.

Evidence: `input67-fix-verification.json`, `input67-quality-delta-v2.xml`, and `input67-autoreview.json` in the lab root.
This classification does not establish a clean static quality gate or completed app validation.
