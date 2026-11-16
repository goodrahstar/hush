# Apple's built-in on-device models (as of 2026-11-15)

These are machine-learning models that ship inside macOS/iOS and that an app can call with no model file of its own, the same way Hush uses `SNClassifySoundRequest(classifierIdentifier: .version1)`.

**How each item was checked**
- **Ran locally**: called on this Mac (macOS 15.6.1, Swift 6.2.4, SDK 26.2), and the numbers come from that run. Scripts: `/private/tmp/claude-501/-Users-rahulkumar-Desktop/4bcb9b2b-ba95-4a6e-9d40-01d20ed82640/scratchpad/probe.swift`, `probe2.swift`, `probe3.swift`.
- **SDK**: the API and its `@available` minimum OS were read from the macOS 26.2 SDK headers or swiftinterface. It was not run, because this Mac is on macOS 15.
- **Docs**: Apple documentation or WWDC session pages only. WWDC26 items ship in the "27" OS releases.

"OS-managed assets" means the OS downloads the model on first use (Speech, Translation, contextual embeddings, tap-to-segment). Your app bundles nothing, but the first call can wait on a download.

---

## Audio

| Model | Framework / entry point | What it does | Outputs | Min OS | Checked |
|---|---|---|---|---|---|
| Sound classifier v1 | SoundAnalysis: `SNClassifySoundRequest(classifierIdentifier: .version1)` + `SNAudioStreamAnalyzer` / `SNAudioFileAnalyzer` | Classifies everyday sounds (speech, baby crying, dog bark, alarms, instruments and more) | `SNClassificationResult`: label + confidence, per time window (window duration is configurable) | macOS 12 / iOS 15 (request API macOS 10.15) | Ran locally: **303 labels** |
| Audio feature print (embedding) | CreateMLComponents: `AudioFeaturePrint`; Create ML `MLSoundClassifier` (on Mac) | Apple's pre-trained audio embedding. Build your own few-shot sound classifier on top of it, in-app | Embedding vectors per window | macOS 13 / iOS 16 | SDK |
| Music Understanding (WWDC26) | Music Understanding: `MusicUnderstandingSession`, `analyze()` / `analyze(for:)` | Analyses music on-device in six areas: key, rhythm, structure, pace, instrument activity, loudness | `KeyResult` (tonic and mode over time), `RhythmResult` (beats, bars, tempo), `StructureResult` (sections such as verse or chorus, plus segments and phrases), `PaceResult`, `InstrumentActivityResult`, `LoudnessResult` (integrated, momentary and short-term, every 100 ms; a streaming API too) | iOS / macOS 27 | Docs (WWDC26 session 253) |
| Accessibility "Sound Recognition" | none (Settings feature) | The system alerts for sounds like doorbells and alarms | Not exposed to apps. SoundAnalysis is the developer path | n/a | Docs |

## Vision (images and video)

All of these are `VN…Request` classes (older API), with Swift equivalents without the `VN` prefix (macOS 15 / iOS 18), run through `VNImageRequestHandler` / `ImageRequestHandler`.

| Model | Entry point | What it does | Outputs | Min OS | Checked |
|---|---|---|---|---|---|
| Image classifier | `VNClassifyImageRequest` / `ClassifyImageRequest` | Scene and object taxonomy | Label + confidence | macOS 10.15 / iOS 13 | Ran locally: **1,303 labels**, revisions 1–2 |
| Image feature print | `VNGenerateImageFeaturePrintRequest` | Image embedding for similarity search and custom classifiers | Vector (768 floats in rev 2) + `computeDistance` | macOS 10.15 / iOS 13 | Ran locally: 768 elements |
| Saliency (attention, objectness) | `VNGenerateAttentionBasedSaliencyImageRequest`, `…ObjectnessBased…` | Where the eye goes / where objects are | Heat-map pixel buffer + salient bounding boxes | macOS 10.15 / iOS 13 | Ran locally |
| Aesthetics score | `CalculateImageAestheticsScoresRequest` (Swift only) | Rates photo quality and flags "utility" images such as screenshots and receipts | `overallScore` (−1…1), `isUtility` | macOS 15 / iOS 18 | Ran locally |
| Text recognition (OCR) | `VNRecognizeTextRequest` / `RecognizeTextRequest` | Printed and handwritten text, fast or accurate | Strings + candidates + confidence + boxes | macOS 10.15 / iOS 13 | Ran locally: **18 languages** (accurate), 6 (fast) |
| Document structure | `RecognizeDocumentsRequest` | Reads a document as paragraphs, lists and **tables**, plus detected data such as emails and phones | Structured document observation | macOS 26 / iOS 26 | SDK + WWDC25 session 272 |
| Document segmentation | `VNDetectDocumentSegmentationRequest` | Finds the document or receipt in a photo | Quad + mask | macOS 12 / iOS 15 | Ran locally (rev 1 present) |
| Lens smudge | `DetectLensSmudgeRequest` | Is this frame blurry from a dirty lens? | Smudge observation + confidence | macOS 26 / iOS 26 | SDK |
| Face detection, landmarks, capture quality | `VNDetectFaceRectanglesRequest`, `…FaceLandmarksRequest`, `…FaceCaptureQualityRequest` | Faces, 76-point landmarks, which shot of a face is best | Boxes, points, roll/yaw/pitch, quality 0…1 | macOS 10.13–10.15 / iOS 11–13 | Ran locally (capture quality revisions 1–3) |
| Human body pose 2D / 3D | `VNDetectHumanBodyPoseRequest`, `VNDetectHumanBodyPose3DRequest` | Skeleton from an image | 19 joints (2D) / 17 joints in metres (3D) + confidence | 2D macOS 11 / iOS 14; 3D macOS 14 / iOS 17 | Ran locally: 19 / 17 joints |
| Hand pose | `VNDetectHumanHandPoseRequest` | Hand skeleton, for gestures | 21 joints + chirality | macOS 11 / iOS 14 | Ran locally: 21 joints |
| Animals + animal pose | `VNRecognizeAnimalsRequest`, `VNDetectAnimalBodyPoseRequest` | Cat or dog detection; quadruped skeleton | Boxes + label; 25 joints | macOS 10.15 / iOS 13; pose macOS 14 / iOS 17 | Ran locally: Cat, Dog; 25 joints |
| Person segmentation | `VNGeneratePersonSegmentationRequest`, `VNGeneratePersonInstanceMaskRequest`, Core Image `CIPersonSegmentation` | Person matte, or a separate mask per person (up to 4) | Mask pixel buffers | macOS 12 / iOS 15; instances macOS 14 / iOS 17 | Ran locally (filter + request present) |
| Subject lifting (foreground instances) | `VNGenerateForegroundInstanceMaskRequest` | "Lift subject from background" | Per-instance masks + masked image | macOS 14 / iOS 17 | Ran locally (rev 1 present) |
| Tap-to-segment (WWDC26) | `GenerateIterativeSegmentationRequest` | Segment any object from a tap, box, lasso or scribble, with refine and subtract | Mask pixel buffer | iOS / macOS 27 (also new: Vision on watchOS) | Docs (WWDC26 session 237). OS-managed asset: `downloadAssets` / `assetStatus` |
| Barcodes, horizon, rectangles, contours, trajectories, optical flow, human rectangles | `VNDetectBarcodesRequest`, `…HorizonRequest`, etc. | Classic detectors, some ML-based | Payloads, angles, shapes | various, macOS 10.13+ | Ran locally (24 barcode symbologies) |
| Live Text / Visual Look Up | VisionKit: `ImageAnalyzer` + `ImageAnalysisOverlayView` (Mac) / `ImageAnalysisInteraction` (iOS) | System OCR, data detectors, subject lifting and "look up" UI | `ImageAnalysis.transcript`, subjects, interactive overlay | macOS 13 / iOS 16 | Ran locally: read "Hello Hush 2026" |
| Live camera scanner | VisionKit: `DataScannerViewController` | Live text and barcode scanning in the camera | Recognised items stream | iOS 16 (not macOS) | Docs |
| Sensitive content (nudity) | SensitiveContentAnalysis: `SCSensitivityAnalyzer` | Detects nudity in images and video | `isSensitive` bool | macOS 14 / iOS 17 | Ran locally: API present; policy = disabled until the user turns on Sensitive Content Warning, and the app needs an entitlement |

## Language (text)

| Model | Entry point | What it does | Outputs | Min OS | Checked |
|---|---|---|---|---|---|
| Language identification | NaturalLanguage: `NLLanguageRecognizer` | Detects a text's language | Dominant language + probabilities | macOS 10.14 / iOS 12 | Ran locally: Portuguese text gave `pt` at 0.9999 |
| Sentiment | `NLTagger(tagSchemes: [.sentimentScore])` | Positive or negative score per sentence or paragraph | −1.0…1.0 | macOS 10.15 / iOS 13 | Ran locally (scored "I love it" at 1.0) |
| Named entities | `NLTagger` `.nameType` | People, places, organisations | Tags per token range | macOS 10.14 / iOS 12 | Ran locally: Tim Cook = person, Cupertino = place |
| Part of speech, lemma, tokens, script | `NLTagger` `.lexicalClass`, `.lemma`, `NLTokenizer` | Linguistic tagging | Tags | macOS 10.14 / iOS 12 | Ran locally: 7 schemes for English |
| Word embeddings | `NLEmbedding.wordEmbedding(for:)` | Word similarity and nearest neighbours | 300-d vectors, distance, neighbours | macOS 10.15 / iOS 13 | Ran locally: English 300-d, 57k words; en/es/fr/de/it/pt |
| Sentence embeddings | `NLEmbedding.sentenceEmbedding(for:)` | Sentence similarity | 512-d vector | macOS 11 / iOS 14 | Ran locally: 512-d |
| Contextual (BERT-style) embeddings | `NLContextualEmbedding` | Per-token transformer embeddings, multilingual | 512-d per token, max 256 tokens | macOS 14 / iOS 17 | Ran locally (assets were present). OS-managed asset |
| BERT transfer learning | Create ML `MLTextClassifier` `.transferLearning(.bertEmbedding, …)` | Train a text classifier on Apple's embedding | Your labels | macOS 14 | Ran locally (type exists) |
| Translation | Translation: `TranslationSession`, `LanguageAvailability`, SwiftUI `.translationPresentation` / `.translationTask` | On-device machine translation | Translated strings | macOS 15 / iOS 18 (system sheet macOS 14.4 / iOS 17.4) | Ran locally: **21 languages**, en→pt "supported". OS-managed asset |
| Handwriting recognition (WWDC26) | PencilKit: `PKStrokeRecognizer` (actor) | Turns PencilKit strokes into text, with an "indexable content" form for search | Best text, indexable string, `recognizerVersion` | iOS / iPadOS / macOS / visionOS 27 | Docs (WWDC26 session 203): 29 languages, model ships with the OS |
| Semantic search | Core Spotlight: `CSUserQuery`, semantic index; WWDC26 adds `SpotlightSearchTool` for Foundation Models | Meaning-based search over content your app indexes | Ranked items | macOS 15 / iOS 18; tool 27 | Ran locally (`CSUserQuery` present); tool from docs (session 246) |

## Speech

| Model | Entry point | What it does | Outputs | Min OS | Checked |
|---|---|---|---|---|---|
| Classic speech recognition | Speech: `SFSpeechRecognizer` + `requiresOnDeviceRecognition = true` | Speech to text, live or from a file | Transcript, segments, timestamps, confidence, alternatives | on-device macOS 10.15 / iOS 13 | Ran locally: 63 locales; **4 on-device right now** (en-US, en-ID, en-PH, en-SA). Others need dictation assets |
| Voice analytics | `SFTranscriptionSegment.voiceAnalytics` | Pitch, jitter, shimmer and voicing per segment | Feature arrays | macOS 10.15 / iOS 13 | Docs |
| SpeechAnalyzer + SpeechTranscriber (WWDC25) | `SpeechAnalyzer` with `SpeechTranscriber` modules | New long-form, low-latency transcription model (what Notes and Voice Memos use) | Volatile and final results as `AttributedString` with audio time ranges | macOS 26 / iOS 26 | SDK. Models via `AssetInventory` (OS-managed) |
| DictationTranscriber | `DictationTranscriber` | Dictation-style transcription with punctuation | Same as above | macOS 26 / iOS 26 | SDK |
| SpeechDetector | `SpeechDetector` module | Voice activity detection: is someone speaking? | Speech-detected results | macOS 26 / iOS 26 | SDK |
| Generated subtitles (WWDC26) | AVKit / AVFoundation playback (automatic) | Live on-device subtitles from audio, or translated from existing subtitles | Subtitle track | iOS / macOS 27 | Docs (session 256). Not a callable model; playback feature only |
| Text to speech | AVFoundation: `AVSpeechSynthesizer`, `AVSpeechSynthesisVoice`; Personal Voice | Neural TTS; the user's own Personal Voice with permission | Audio buffers | old; Personal Voice macOS 14 / iOS 17 | Ran locally: 191 voices, 46 languages |

## Generative

| Model | Entry point | What it does | Outputs | Min OS | Checked |
|---|---|---|---|---|---|
| Apple on-device LLM (~3B) | FoundationModels: `SystemLanguageModel.default`, `LanguageModelSession`, `@Generable`, `Tool` | Text generation, summarising, extraction, tagging (`.contentTagging` use case), tool calling, guided structured output | Text, or typed Swift structs (streamed) | macOS 26 / iOS 26 (Apple Intelligence devices) | SDK. Not runnable on this macOS 15 Mac |
| Foundation Models additions (WWDC26) | Same framework | Rebuilt on-device model with **image input**; `OCRTool` and `BarcodeReaderTool` (Vision-backed); context and token APIs (26.4); `PrivateCloudComputeLanguageModel` (server, 32k context); third-party providers via the `LanguageModel` protocol; Evaluations framework | as above | iOS / macOS 27 (token APIs 26.4) | Docs (sessions 241, 237) |
| Image Playground / ImageCreator | ImagePlayground: `ImageCreator` (code), `.imagePlaygroundSheet` (UI) | Text- or photo-to-image in Animation, Illustration and Sketch styles | `CGImage`s | sheet macOS 15.1 / iOS 18.1; `ImageCreator` macOS 15.4 / iOS 18.4 | Ran locally: `ImageCreator` started with styles animation, illustration, sketch. **Note:** at WWDC26 Apple moved Image Playground to a Private Cloud Compute model and **deprecated `ImageCreator`**, so from the 27 releases it is no longer on-device |
| Writing Tools | UIKit / AppKit / SwiftUI: `writingToolsBehavior`, `UIWritingToolsCoordinator` | System proofread, rewrite and summarise inside your text views | Edits to your text (system UI) | macOS 15.1 / iOS 18.1 | Docs. You opt in or out; you can't call the model directly |
| Genmoji | `NSAdaptiveImageGlyph` | Show and store user-made Genmoji | Glyph images | macOS 15.1 / iOS 18.1 | Docs (display only, not generation) |
| Visual Intelligence | VisualIntelligence: `IntentValueQuery` + `SemanticContentDescriptor` | Your app appears in camera and screenshot visual search results | You return matches | iOS 26 | Docs. The system calls you; you don't call the model |

## Motion, health, spatial, other

| Model | Entry point | What it does | Outputs | Min OS | Checked |
|---|---|---|---|---|---|
| Activity classification | Core Motion: `CMMotionActivityManager` | Stationary, walking, running, cycling or driving | `CMMotionActivity` + confidence | iOS 7 / watchOS. **Not on macOS** | SDK: header marks it `API_UNAVAILABLE(macos)`; the probe would not compile on Mac |
| Fall detection | Core Motion: `CMFallDetectionManager` | Apple Watch fall events | Events | watchOS 7.1 | Docs |
| Health-derived metrics | HealthKit: e.g. `appleWalkingSteadiness`, sleep stages (`asleepREM`, etc.), `appleSleepingBreathingDisturbances` | Apple's models run on Watch or iPhone; you read the results | Samples | walking steadiness iOS 15; sleep stages iOS 16; breathing disturbances iOS 18 (macOS 13–15 SDK) | SDK (identifiers present) |
| Scene understanding | ARKit: scene reconstruction mesh with classification, plane classification, people occlusion, body tracking; RoomPlan `RoomCaptureSession` | Classified 3D mesh (wall, floor, table…), 3D room model | Anchors, meshes, `CapturedRoom` | iOS 13–16 (LiDAR for mesh); visionOS | Docs. Not on macOS |
| Object Capture | RealityKit: `PhotogrammetrySession` | Photos to 3D model | USDZ | macOS 12 / iOS 17 | Docs |
| Camera system effects | AVFoundation: Portrait, Studio Light, Voice Isolation, Center Stage | System video and mic effects | Read-only status; the user toggles them in Control Center | macOS 12+ | Docs. Not callable |
| Core ML / Core AI | Core ML; Core AI (new at WWDC26) | Run *your own* models | n/a | — | Docs. No built-in models; included for completeness |

---

## Good fits for Hush-style apps

1. **`SpeechDetector` + `SpeechTranscriber` (macOS 26).** Know when the sound is a person talking, and optionally what they said. It adds to the 303-label `speech` class and stays fully on-device.
2. **`AudioFeaturePrint` (CreateMLComponents, macOS 13).** Let users record 5–10 examples of their own sound (their kettle, their dog) and train a personal classifier in-app on Apple's audio embedding.
3. **Music Understanding (macOS 27).** When SoundAnalysis says "music", get loudness (integrated, momentary or short-term), tempo, energy and key. Good for "too loud for too long" or ambience features.
4. **Foundation Models (macOS 26).** Turn a stream of sound labels and confidences into a plain-language summary ("dog barked 4 times between 2–3 am") using guided `@Generable` output.
5. **`NLEmbedding.sentenceEmbedding` / `NLContextualEmbedding`.** Let users type a sound in their own words ("someone knocking") and map it to the nearest of the 303 labels by meaning.

## Sources

- WWDC26 session list: https://developer.apple.com/videos/wwdc2026/
- What's new in the Foundation Models framework (WWDC26, 241): https://developer.apple.com/videos/play/wwdc2026/241/
- What's new in image understanding (WWDC26, 237): https://developer.apple.com/videos/play/wwdc2026/237/
- Meet the Music Understanding framework (WWDC26, 253): https://developer.apple.com/videos/play/wwdc2026/253/
- Read between the strokes with PencilKit (WWDC26, 203): https://developer.apple.com/videos/play/wwdc2026/203/
- Discover generated subtitles (WWDC26, 256): https://developer.apple.com/videos/play/wwdc2026/256/
- Create high-quality images using Image Playground (WWDC26, 375): https://developer.apple.com/videos/play/wwdc2026/375/
- LLM search using Core Spotlight (WWDC26, 246): https://developer.apple.com/videos/play/wwdc2026/246/
- What's new in iOS 27 (WWDC26 guide): https://developer.apple.com/wwdc26/guides/ios/
- WWDC25 updates: https://developer.apple.com/documentation/updates/wwdc2025
- Read documents using the Vision framework (WWDC25, 272): https://developer.apple.com/videos/play/wwdc2025/272/
- Apple SDK headers and swiftinterfaces in Xcode's MacOSX26.2.sdk (local)
